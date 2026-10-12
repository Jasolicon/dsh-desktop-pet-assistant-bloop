#nullable enable
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Windows.Forms;
using Blop.Core;

namespace Blop.App;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        // net8 上要显式告诉 WinForms 用 PerMonitorV2（net48 那边由 App.config 的 DpiAwareness 定，
        // 见 App.config 里的注释：WinForms 会在创建第一个窗口之前把 DPI 感知定死，晚一步就改不动）
#if NET6_0_OR_GREATER
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
#endif
        // DPI 感知必须在**任何屏幕 API 之前**：进程若不是 DPI 感知的，坐标会被系统乘 2
        //（"右下角"根本不是你算的位置），而且逐像素 alpha 的分层窗口会完全不合成、退化成一块底色。
        ScreenCapture.EnsureDpiAware();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var root = AppContext.BaseDirectory;                        // {root} = 程序目录（assets 拷在这儿）
        var paths = new Paths(new SystemPathWorld(), root);
        var runDir = Path.Combine(paths.Home(), "run");             // 状态根：DG_HOME → 程序目录
        Directory.CreateDirectory(runDir);
        WriteStartupLog(runDir, paths);

        // 已在跑时的行为刻意分两种（照 PS 版的约定）：
        //   默认**静默退出** —— 开机启动 / 连点两下快捷方式都不该弹出个框等着人来点；
        //   带 --notify-if-running 才弹一个说明（双击启动那条路会带它）。
        // 另外 --no-lock 是自检/调试用（这台机器上同时跑 PowerShell 版和 .NET 版时要用它）。
        var noLock = Has(args, "--no-lock");

        // 壳的自检：建窗体 → 渲染一帧存 PNG → 打印 DPI/尺寸/ExStyle → 立刻退出。
        // 为什么要它：桌宠是常驻后台窗体程序，出问题时既没有控制台也没有弹窗，只能靠猜；
        // 而"无声地跑着"没法进自动化。这条命令让壳本身可以被脚本验证（也不会卡住脚本）。
        if (Has(args, "--shell-smoke")) return RunShellSmoke(runDir, paths);

        var instance = new SingleInstanceLock(paths.LockPath());
        if (!noLock && !instance.TryAcquire(out var holder))
        {
            AppendStartupLog(runDir, "已在运行（pid " + holder + "），这次退出");
            if (Has(args, "--notify-if-running"))
            {
                MessageBox.Show(
                    "已经有一只桌宠在跑了（pid " + holder + "）。\n" +
                    "同时只会有一只 —— 两只一起跑就是双份抓屏、双份模型开销。",
                    "泡泡 · Bloop",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }

            return 0;
        }

        try
        {
            var statePath = Path.Combine(runDir, "pet.json");
            var cfg = BotConfig.Load(Path.Combine(paths.Home(), "config.json"));
            // 大脑先接"假大脑"：它不花钱、不等模型，专门用来把环路验通
            //（真大脑接 DSH 那一侧，走文件协议/插件 —— 见 blop-net/README 的「DSH 现状」）。
            Rectangle selfRect = Rectangle.Empty;
            var monitor = new PetMonitor(
                cfg,
                new FakeBrain(),
                Path.Combine(paths.Home(), "logs", "decisions.jsonl"),
                Path.Combine(runDir, "shots"),
                () => selfRect);
            var form = new PetForm(LoadPet(paths.PetImage(cfg.PetImage)), PetState.Load(statePath), cfg, monitor);
            selfRect = form.Bounds;   // 抓屏掩码要挖掉"桌宠自己那块"，用窗口在屏幕上的矩形
            AppendStartupLog(runDir, $"form={form.Width}x{form.Height} at ({form.Location.X},{form.Location.Y})");
            Application.Run(form);
        }
        catch (Exception ex)
        {
            MessageBox.Show("起不来：" + ex.Message, "泡泡 · Bloop", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            if (!noLock) instance.Release();
        }

        return 0;
    }

    private static bool Has(string[] args, string flag)
    {
        foreach (var a in args)
        {
            if (string.Equals(a, flag, StringComparison.OrdinalIgnoreCase)) return true;
        }

        return false;
    }

    private static int RunShellSmoke(string runDir, Paths paths)
    {
        var preview = Path.Combine(runDir, "pet-preview.png");
        var report = Path.Combine(runDir, "shell-smoke.txt");
        var cfg = BotConfig.Load(Path.Combine(paths.Home(), "config.json"));
        Rectangle selfRect = Rectangle.Empty;
        var monitor = new PetMonitor(
            cfg,
            new FakeBrain(),
            Path.Combine(paths.Home(), "logs", "decisions.jsonl"),
            Path.Combine(runDir, "shots"),
            () => selfRect);
        using var form = new PetForm(
            LoadPet(paths.PetImage(cfg.PetImage)), PetState.Load(Path.Combine(runDir, "pet.json")), cfg, monitor);
        var _ = form.Handle;   // 句柄要真的建出来，ExStyle 才读得到
        selfRect = form.Bounds;
        // 自检也画一次气泡：这样预览图里能直接看到气泡长什么样（所见即分层窗口所得）
        form.ShowBubble("这是一句测试气泡：现在用的是假大脑，只验环路。", 600);
        form.SavePreview(preview);
        var screen = ScreenCapture.PrimaryScreenBounds();
        var lines = new[]
        {
            "systemDpi=" + ScreenCapture.SystemDpi,
            "dpiAwareCall=" + ScreenCapture.DpiAwareCallSucceeded,
            "screen=" + screen.Width + "x" + screen.Height,
            "form=" + form.Width + "x" + form.Height + " at (" + form.Location.X + "," + form.Location.Y + ")",
            "exstyle=0x" + form.ExStyle.ToString("X8"),
            "noActivate=" + ((form.ExStyle & LayeredNative.WsExNoActivate) != 0),
            "layered=" + ((form.ExStyle & LayeredNative.WsExLayered) != 0),
            "preview=" + preview,
        };
        // WinExe 没有控制台（Console.WriteLine 落不了地），所以报告写文件 —— 脚本读这个文件
        File.WriteAllText(report, string.Join(Environment.NewLine, lines));
        return 0;
    }

    /// <summary>角色图；一张都读不到就画一只圆脸（别让它因为缺素材就起不来）。</summary>
    private static Bitmap LoadPet(string imagePath)
    {
        if (!string.IsNullOrEmpty(imagePath))
        {
            try
            {
                return new Bitmap(imagePath);
            }
            catch
            {
                // 读不出来就退回画的那只
            }
        }

        var bmp = new Bitmap(240, 240);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var body = new SolidBrush(Color.FromArgb(255, 120, 170, 220));
        g.FillEllipse(body, 12, 24, 216, 200);
        using var eyes = new SolidBrush(Color.FromArgb(255, 40, 60, 90));
        g.FillEllipse(eyes, 78, 100, 18, 24);
        g.FillEllipse(eyes, 148, 100, 18, 24);
        return bmp;
    }

    /// <summary>
    /// 起不来时唯一能看的东西：把"环境长什么样"写一行到 run\startup.log。
    /// </summary>
    /// <remarks>
    /// 桌宠是常驻后台的窗体程序，出问题时既没有控制台也没有弹窗 —— 没有这一行的话，
    /// "它怎么没起来"只能靠猜。内容刻意只有一行：DPI 感知是否生效、屏幕多大、状态根在哪。
    /// </remarks>
    private static void WriteStartupLog(string runDir, Paths paths)
    {
        try
        {
            var screen = ScreenCapture.PrimaryScreenBounds();
            var wa = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 0, 0);
            var lines = new[]
            {
                DateTime.Now.ToString("o"),
                "dpiAwareCall=" + ScreenCapture.DpiAwareCallSucceeded,
                "systemDpi=" + ScreenCapture.SystemDpi,
                "screen=" + screen.Width + "x" + screen.Height,
                "workArea=" + wa.Width + "x" + wa.Height,
                "home=" + paths.Home(),
                "petImage=" + paths.PetImage(null),
            };
            File.WriteAllText(Path.Combine(runDir, "startup.log"), string.Join(Environment.NewLine, lines));
        }
        catch
        {
            // 连日志都写不了就算了，别让它成为起不来的原因
        }
    }

    private static void AppendStartupLog(string runDir, string line)
    {
        try
        {
            File.AppendAllText(Path.Combine(runDir, "startup.log"), Environment.NewLine + line);
        }
        catch
        {
        }
    }
}
