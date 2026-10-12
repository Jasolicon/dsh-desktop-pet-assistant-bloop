#nullable enable
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Blop.Core;

namespace Blop.Cases;

/// <summary>
/// 行为用例表跑分器：读仓库根的 <c>behavior-cases/*.json</c>，逐条断言。
/// </summary>
/// <remarks>
/// 为什么不用 xUnit：用例表是整个迁移的**裁判**，它要能被三份实现用同一种方式跑
/// （PowerShell 那侧跑在 <c>DesktopGuide.ps1 -SelfTest</c> 里）。一个零依赖的控制台程序最省事：
/// 不用还原包、不用联网，失败就返回非 0 退出码。
/// </remarks>
public static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            // 中文输出：net48 控制台默认走系统码页，不设的话管道里读出来是乱码
            try { Console.OutputEncoding = Encoding.UTF8; } catch { }
            if (args.Length > 0 && args[0] == "--capture-smoke") return CaptureSmoke();
            if (args.Length > 0 && args[0] == "--brain-smoke") return BrainSmoke();
            if (args.Length > 0 && args[0] == "--brain-oneshot-smoke") return BrainOneShotSmoke();
            if (args.Length > 0 && args[0] == "--loop-smoke") return LoopSmoke();
            return RunAll(args) == 0 ? 0 : 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 2;
        }
    }

    /// <summary>
    /// 跑完所有用例表，返回失败条数（0 = 全过）。
    /// </summary>
    /// <remarks>
    /// 做成 public 是为了让"内存编译"那条验证路也能调它（见 blop-net/verify-addtype.ps1）：
    /// 这台机器开着 Smart App Control，**新编出来的 exe 会被它拦**（事件日志 id 3118），
    /// 所以本地验证经常只能走 Add-Type 内存编译 —— 跑的是同一份源码、同一张表。
    /// </remarks>
    public static int RunAll(string[] args)
    {
        var casesDir = ResolveCasesDir(args);
        if (casesDir is null) throw new InvalidOperationException("找不到 behavior-cases 目录（可以在仓库根跑，或把它的路径传进来）");

        var pass = 0;
        var fail = 0;
        Console.WriteLine($"用例表目录：{casesDir}");

        RunGate(Path.Combine(casesDir, "gate.json"), ref pass, ref fail);
        RunPaths(Path.Combine(casesDir, "paths.json"), ref pass, ref fail);
        RunFingerprint(Path.Combine(casesDir, "fingerprint.json"), ref pass, ref fail);

        Console.WriteLine($"全部用例表：{pass}/{pass + fail} 项通过");
        return fail;
    }

    /// <summary>挖洞掩码的几何用例（与 PowerShell 侧自检 5y 跑的是同一张表）。</summary>
    private static void RunFingerprint(string path, ref int pass, ref int fail)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var root = doc.RootElement;

        Console.WriteLine("=== fingerprint.json：挖洞掩码的几何 ===");
        foreach (var c in root.GetProperty("cases").EnumerateArray())
        {
            var captured = Rect(c.GetProperty("captured"));
            var self = c.TryGetProperty("selfEmpty", out var se) && se.GetBoolean()
                ? Rectangle.Empty
                : Rect(c.GetProperty("self"));

            var got = Fingerprint.MaskFor(captured, self);
            var want = c.GetProperty("expectMask").GetString()!;
            var ok = got == want;
            if (ok) pass++; else fail++;
            var cells = got.Split('1').Length - 1;
            Console.WriteLine($"  {(ok ? "✔" : "✘")} {c.GetProperty("id").GetString(),-24} 挖掉 {cells,-2} 格");
            if (!ok)
            {
                Console.WriteLine($"      期望 {want}");
                Console.WriteLine($"      实际 {got}　—— {c.GetProperty("why").GetString()}");
            }
        }
    }

    private static Rectangle Rect(JsonElement o)
        => new Rectangle(
            o.GetProperty("x").GetInt32(),
            o.GetProperty("y").GetInt32(),
            o.GetProperty("w").GetInt32(),
            o.GetProperty("h").GetInt32());

    /// <summary>
    /// 抓屏冒烟：这条路径没法做"假世界"用例（它真的要看屏幕），所以做成显式的自检命令 ——
    /// 用例表保证逻辑，这条保证"在这台机器上真能抓到"。
    /// </summary>
    private static int CaptureSmoke()
    {
        ScreenCapture.EnsureDpiAware();
        var screen = ScreenCapture.PrimaryScreenBounds();
        Console.WriteLine($"主屏（DPI 感知下的物理像素）：{screen.Width}x{screen.Height}");

        var full = ScreenCapture.Grab(1024, 60);
        Console.WriteLine($"整屏：抓到 {full.Width}x{full.Height}，JPEG 约 {full.JpegBase64.Length * 3 / 4 / 1024} KB，指纹 {full.Fingerprint}");

        var self = new Rectangle(screen.Width - 900, screen.Height - 520, 860, 500);
        var masked = ScreenCapture.Grab(1024, 60, null, self);
        Console.WriteLine($"挖掉右下 860x500：指纹 {masked.Fingerprint}，挖掉 {masked.MaskedCells}/64 格");
        Console.WriteLine($"两次指纹距离：{Fingerprint.Distance(full.Fingerprint, masked.Fingerprint)}");

        var region = ScreenCapture.Grab(1024, 60, new Rectangle(0, 0, 600, 400));
        Console.WriteLine($"框选 600x400 → 实际抓 {region.Captured.Width}x{region.Captured.Height}，缩到 {region.Width}x{region.Height}");

        var bad = ScreenCapture.Grab(1024, 60, new Rectangle(0, 0, 3, 3));
        Console.WriteLine($"非法区域 3x3 → 退回整屏 {bad.Captured.Width}x{bad.Captured.Height}");
        return 0;
    }

    /// <summary>
    /// 环路冒烟：跑几轮「采样 → 闸门 → 大脑」，打印每轮结果与统计。
    /// </summary>
    /// <remarks>
    /// 用假大脑（不花一分钱），验的是环路本身：第一轮应当放行并说话（保险丝），
    /// 紧接着几轮应当被闸门拦下（画面几乎没变）—— 这正是"绝大多数轮次不花钱"的证据。
    /// 配置直接读 PS 版的 config.json，顺便验我们的配置解析读得对。
    /// </remarks>
    private static int LoopSmoke()
    {
        var casesDir = ResolveCasesDir(Array.Empty<string>())
                       ?? throw new InvalidOperationException("找不到 behavior-cases 目录");
        var root = Path.GetDirectoryName(casesDir) ?? AppContext.BaseDirectory;
        var runDir = Path.Combine(AppContext.BaseDirectory, "run");
        Directory.CreateDirectory(runDir);

        var cfgPath = Path.Combine(root, "desktop-guide", "config.json");
        var cfg = BotConfig.Load(cfgPath);
        Console.WriteLine("配置：" + cfgPath);
        Console.WriteLine("  speakStyle=" + cfg.SpeakStyle + " sampleSeconds=" + cfg.SampleSeconds +
                          " judgeMinSeconds=" + cfg.JudgeMinSeconds + " roastMinSeconds=" + cfg.RoastMinSeconds);
        var monitor = new PetMonitor(cfg, new FakeBrain(),
            Path.Combine(runDir, "decisions.jsonl"), Path.Combine(runDir, "shots"));
        for (var i = 1; i <= 4; i++)
        {
            var tick = monitor.Tick();
            Console.WriteLine($"#{i}  {tick.Kind,-7} {tick.Reason}" +
                              (string.IsNullOrEmpty(tick.Text) ? "" : "  →  " + tick.Text));
            System.Threading.Thread.Sleep(1200);
        }

        Console.WriteLine($"统计：说了 {monitor.SpokeCount} 次，沉默 {monitor.SilentCount} 次，本地拦下 {monitor.SkipCount} 次");
        Console.WriteLine("判断记录：" + Path.Combine(runDir, "decisions.jsonl"));
        return 0;
    }

    /// <summary>
    /// 一次性大脑冒烟：起一个 <c>dsh headless</c> 进程，问一句**带截图**的，打印答案与用时。
    /// </summary>
    /// <remarks>
    /// 这条路**实测能通**（常驻 sdk 会话那条从我们的进程里起不来，见 README「DSH 现状」）：
    /// <c>--expose-internals &lt;cli.js&gt; headless --patch &lt;最小 patch&gt; "提示词"</c>，
    /// 答案打在 stdout 最后一行。会真的花一次模型调用。
    /// </remarks>
    private static int BrainOneShotSmoke()
    {
        var casesDir = ResolveCasesDir(Array.Empty<string>())
                       ?? throw new InvalidOperationException("找不到 behavior-cases 目录");
        var root = Path.GetDirectoryName(casesDir) ?? AppContext.BaseDirectory;
        var runDir = Path.Combine(AppContext.BaseDirectory, "run");
        Directory.CreateDirectory(runDir);

        var paths = new Paths(new SystemPathWorld(), root);
        var dsh = paths.Dsh();
        Console.WriteLine("exe    ：" + dsh.Exe);
        Console.WriteLine("cli.js ：" + dsh.Cli);
        if (string.IsNullOrEmpty(dsh.Exe) || string.IsNullOrEmpty(dsh.Cli))
        {
            Console.Error.WriteLine("DSH 没解出来（应用没开？或装在不常见的位置 → 设 DG_DSH_ROOT）");
            return 2;
        }

        var patch = BrainPatch.Write(Path.Combine(runDir, "brain-patch.yml"));
        ScreenCapture.EnsureDpiAware();
        var shot = ScreenCapture.Grab(1024, 60);
        var shotPath = Path.Combine(runDir, "brain-shot.jpg");
        File.WriteAllBytes(shotPath, Convert.FromBase64String(shot.JpegBase64));
        Console.WriteLine("截图   ：" + shot.Width + "x" + shot.Height + " → " + shotPath);

        var prompt = "这是我电脑屏幕的一张缩略图，文件路径是 " + shotPath +
                     "（请用你的读图工具打开它）。用一句话说你看到了什么，20 字以内。";
        var r = DshOneShot.Ask(new OneShotOptions
        {
            Exe = dsh.Exe,
            Cli = dsh.Cli,
            Patch = patch,
            Prompt = prompt,
            Cwd = root,
            TimeoutSeconds = 240,
            CmdHop = Environment.GetEnvironmentVariable("DG_NO_CMD_HOP") != "1",
        });
        Console.WriteLine("用时   ：" + r.Seconds + "s，退出码=" + r.ExitCode + (r.TimedOut ? "（超时）" : ""));
        Console.WriteLine("答案   ：「" + r.Text + "」");
        if (r.Text.Length == 0 && r.Stderr.Length > 0)
        {
            Console.WriteLine("stderr ：" + r.Stderr.Substring(0, Math.Min(400, r.Stderr.Length)));
        }

        return r.Ok ? 0 : 2;
    }

    /// <summary>
    /// 大脑冒烟：起常驻 DSH 会话 → 问一句纯文字 → 再问一句**带截图**的。
    /// </summary>
    /// <remarks>
    /// 这条会真的花一次模型调用（两轮，每次几厘钱），所以不做成用例表 ——
    /// 用例表管"逻辑对不对"，这条管"在这台机器上真的能连上、真的能看见图"。
    /// 带截图那一轮是关键：**内联图片**是常驻会话相对 CLI 的主要好处（CLI 只能让模型读路径、多花一轮）。
    /// </remarks>
    private static int BrainSmoke()
    {
        var casesDir = ResolveCasesDir(Array.Empty<string>())
                       ?? throw new InvalidOperationException("找不到 behavior-cases 目录");
        Console.WriteLine("identity=" + System.Security.Principal.WindowsIdentity.GetCurrent().Name +
                          "  user=" + Environment.UserName +
                          "  isAdmin=" + new System.Security.Principal.WindowsPrincipal(
                              System.Security.Principal.WindowsIdentity.GetCurrent())
                              .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator));
        var root = Path.GetDirectoryName(casesDir) ?? AppContext.BaseDirectory;
        var paths = new Paths(new SystemPathWorld(), root);
        var dsh = paths.Dsh();
        Console.WriteLine("DSH 根  ：" + dsh.Root);
        Console.WriteLine("exe     ：" + dsh.Exe);
        Console.WriteLine("cli.js  ：" + dsh.Cli);
        if (string.IsNullOrEmpty(dsh.Exe) || string.IsNullOrEmpty(dsh.Cli))
        {
            Console.Error.WriteLine("DSH 没解出来，先跑用例表看路径解析");
            return 2;
        }

        var opt = new DshSessionOptions
        {
            Exe = dsh.Exe,
            Cli = dsh.Cli,
            // 允许用环境变量覆盖会话的工作目录，方便和 dsh-sdk.ps1 做逐字段对照
            Cwd = Environment.GetEnvironmentVariable("DG_BRAIN_CWD") ?? root,
            SessionId = "pet-brain-smoke",
        };
        using var session = new DshSession(opt);
        try
        {
            // 起常驻会话：**失败就重试几次** —— DSH 的 profile 启动阶段偶尔会撞上
            // "别的 DSH 进程正在写同一份 profile"，重试一下就好（这也是生产里该有的行为）。
            var sw = Stopwatch.StartNew();
            var started = false;
            for (var attempt = 1; attempt <= 3 && !started; attempt++)
            {
                try
                {
                    session.Start(90);
                    started = true;
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"第 {attempt} 次启动失败：{ex.Message.Split('\n')[0]}");
                    var tail = session.StderrTail;
                    if (tail != "（空）") Console.WriteLine("  stderr：" + tail.Split('\n')[0]);
                    System.Threading.Thread.Sleep(2000);
                }
            }

            if (!started) throw new InvalidOperationException("三次都没起来");
            Console.WriteLine($"initialize：{sw.Elapsed.TotalSeconds:F1}s（状态 {session.Status}）");

            var r1 = session.Prompt("只回复两个字：可用", null, 180);
            Console.WriteLine($"第一轮（纯文字）：{r1.Seconds}s → 「{r1.Text}」{(r1.TimedOut ? "（超时）" : "")}");

            ScreenCapture.EnsureDpiAware();
            var shot = ScreenCapture.Grab(1024, 60);
            var shotPath = Path.Combine(Path.GetTempPath(), "blop-brain-smoke.jpg");
            File.WriteAllBytes(shotPath, Convert.FromBase64String(shot.JpegBase64));
            var r2 = session.Prompt(
                "这是我屏幕的一张缩略图。用一句话说你看到了什么，20 字以内。",
                new[] { shotPath },
                180);
            Console.WriteLine($"第二轮（带截图 {shot.Width}x{shot.Height}）：{r2.Seconds}s → 「{r2.Text}」{(r2.TimedOut ? "（超时）" : "")}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("失败：" + ex.Message);
            Console.Error.WriteLine("这次 Start 的实参快照：");
            Console.Error.WriteLine(session.LastStartDiagnostics);
            Console.Error.WriteLine("子进程 stderr 末尾：");
            Console.Error.WriteLine(session.StderrTail);
            return 2;
        }
    }

    /// <summary>
    /// 路径解析用例表：把"外部世界"当成输入喂给 <see cref="Paths"/>。
    /// </summary>
    /// <remarks>
    /// 这是 <c>desktop-guide/paths.ps1</c> 的规则第一次能被真正钉住 ——
    /// 以前只能测"在这台机器上解得出来"，测不到"装在别处、或者只装了 DSH 没装 node"。
    /// </remarks>
    private static void RunPaths(string path, ref int pass, ref int fail)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var root = doc.RootElement;
        var defaults = root.GetProperty("defaults");

        Console.WriteLine("=== paths.json：路径解析 ===");
        foreach (var c in root.GetProperty("cases").EnumerateArray())
        {
            var worldElement = c.TryGetProperty("world", out var w) ? w : default;
            var world = new FakePathWorld(worldElement, defaults);
            var paths = new Paths(world, defaults.GetProperty("root").GetString()!);
            var input = c.TryGetProperty("input", out var i) ? i : default;
            var expect = c.GetProperty("expect");
            var ask = c.GetProperty("ask").GetString()!;

            var ok = true;
            string shown;
            switch (ask)
            {
                case "tokens":
                {
                    var value = Str(input, "value") ?? "";
                    var dshRoot = Str(input, "dshRoot") ?? "";
                    var got = paths.ExpandTokens(value, dshRoot);
                    ok = got == (Str(expect, "value") ?? "");
                    shown = $"「{value}」→「{got}」";
                    break;
                }
                case "home":
                {
                    var got = paths.Home(Str(input, "over"));
                    ok = got == (Str(expect, "value") ?? "");
                    shown = $"→「{got}」";
                    break;
                }
                case "lockPath":
                {
                    var got = paths.LockPath();
                    ok = got == (Str(expect, "value") ?? "");
                    shown = $"→「{got}」";
                    break;
                }
                case "dshRoot":
                {
                    var got = paths.DshRoot(Str(input, "configured"));
                    ok = got == (Str(expect, "value") ?? "");
                    shown = $"→「{got}」";
                    break;
                }
                case "node":
                {
                    var got = paths.Node(Str(input, "configured"));
                    ok = got == (Str(expect, "value") ?? "");
                    shown = $"→「{got}」";
                    break;
                }
                case "edge":
                {
                    var got = paths.Edge(Str(input, "configured"));
                    ok = got == (Str(expect, "value") ?? "");
                    shown = $"→「{got}」";
                    break;
                }
                case "petImage":
                {
                    var got = paths.PetImage(Str(input, "configured"));
                    ok = got == (Str(expect, "value") ?? "");
                    shown = $"→「{got}」";
                    break;
                }
                case "dsh":
                {
                    var got = paths.Dsh(
                        Str(input, "rootCfg"), Str(input, "exeCfg"), Str(input, "cliCfg"), Str(input, "cmdCfg"));
                    var want = new DshPaths(
                        Str(expect, "root") ?? "", Str(expect, "exe") ?? "", Str(expect, "cli") ?? "", Str(expect, "cmd") ?? "");
                    ok = got == want;
                    shown = $"root=「{got.Root}」exe=「{got.Exe}」cli=「{got.Cli}」cmd=「{got.Cmd}」";
                    break;
                }
                default:
                    throw new InvalidOperationException($"用例表里有不认识的 ask：{ask}");
            }

            if (ok) pass++; else fail++;
            Console.WriteLine($"  {(ok ? "✔" : "✘")} {c.GetProperty("id").GetString(),-34} {shown}");
            if (!ok) Console.WriteLine($"      期望：{expect.GetRawText()}　—— {c.GetProperty("why").GetString()}");
        }
    }

    private static string? Str(JsonElement o, string key)
        => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString()
            : null;

    private static void RunGate(string path, ref int pass, ref int fail)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        var root = doc.RootElement;
        var defaults = root.GetProperty("defaults");

        Console.WriteLine("=== gate.json：本地闸门 ===");
        foreach (var c in root.GetProperty("cases").EnumerateArray())
        {
            var input = new GateInput
            {
                HasShot = Bool(c, defaults, "hasShots"),
                Standby = Bool(c, defaults, "standby"),
                Style = Str(c, defaults, "style"),
                SinceSeconds = NumOr(c, defaults, "sinceSeconds"),
                SilentStreak = (int)NumOr(c, defaults, "silentStreak"),
                WindowChanged = Bool(c, defaults, "windowChanged"),
                FingerprintDistance = NumOr(c, defaults, "fpDistance"),
                IdleSeconds = NumOr(c, defaults, "idleSeconds"),
                ProfileJudgeSeconds = c.TryGetProperty("profileJudge", out var pj) && pj.ValueKind == JsonValueKind.Number
                    ? (int)pj.GetDouble()
                    : null,
                Config = BuildConfig(c, defaults),
            };

            var reason = Gate.Decide(input);
            var allow = string.IsNullOrEmpty(reason);
            var expect = c.GetProperty("expect");
            var wantAllow = expect.GetProperty("allow").GetBoolean();
            var ok = allow == wantAllow;
            string? expectedText = null;
            if (ok && !wantAllow && expect.TryGetProperty("reason", out var wantRe))
            {
                expectedText = wantRe.GetString()!;
                ok = Regex.IsMatch(reason, expectedText);
            }

            if (ok) pass++; else fail++;
            var shown = allow ? "''（放行）" : $"「{reason}」";
            Console.WriteLine($"  {(ok ? "✔" : "✘")} {c.GetProperty("id").GetString(),-32} → {shown}");
            if (!ok)
            {
                Console.WriteLine(wantAllow
                    ? "      期望：放行"
                    : $"      期望：拦住且原因匹配 /{expectedText}/");
            }
        }
    }

    /// <summary>用例表里没写的键取 defaults；config 是"先 defaults 再被用例覆盖"。</summary>
    private static GateConfig BuildConfig(JsonElement c, JsonElement defaults)
    {
        var d = defaults.GetProperty("config");
        var cfg = new GateConfig
        {
            JudgeMinSeconds = (int)d.GetProperty("judgeMinSeconds").GetDouble(),
            JudgeMinFpDelta = (int)d.GetProperty("judgeMinFpDelta").GetDouble(),
            JudgeMaxGapSeconds = (int)d.GetProperty("judgeMaxGapSeconds").GetDouble(),
            JudgeIdleSkipSeconds = (int)d.GetProperty("judgeIdleSkipSeconds").GetDouble(),
            SilentBackoffMax = (int)d.GetProperty("silentBackoffMax").GetDouble(),
            RoastMinSeconds = d.GetProperty("roastMinSeconds").GetDouble(),
            RoastBackoffMax = (int)d.GetProperty("roastBackoffMax").GetDouble(),
        };
        if (!c.TryGetProperty("config", out var over)) return cfg;

        return cfg with
        {
            JudgeMinSeconds = (int)NumOr(over, "judgeMinSeconds", cfg.JudgeMinSeconds),
            JudgeMinFpDelta = (int)NumOr(over, "judgeMinFpDelta", cfg.JudgeMinFpDelta),
            JudgeMaxGapSeconds = (int)NumOr(over, "judgeMaxGapSeconds", cfg.JudgeMaxGapSeconds),
            JudgeIdleSkipSeconds = (int)NumOr(over, "judgeIdleSkipSeconds", cfg.JudgeIdleSkipSeconds),
            SilentBackoffMax = (int)NumOr(over, "silentBackoffMax", cfg.SilentBackoffMax),
            RoastMinSeconds = NumOr(over, "roastMinSeconds", cfg.RoastMinSeconds),
            RoastBackoffMax = (int)NumOr(over, "roastBackoffMax", cfg.RoastBackoffMax),
        };
    }

    private static double NumOr(JsonElement o, JsonElement defaults, string key)
        => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble()
            : defaults.GetProperty(key).GetDouble();

    private static double NumOr(JsonElement o, string key, double fallback)
        => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : fallback;

    private static bool Bool(JsonElement c, JsonElement defaults, string key)
    {
        if (c.TryGetProperty(key, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False)
            return v.GetBoolean();
        return defaults.GetProperty(key).GetBoolean();
    }

    private static string Str(JsonElement c, JsonElement defaults, string key)
        => c.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString()!
            : defaults.GetProperty(key).GetString()!;

    /// <summary>从当前目录往上找带 behavior-cases 的那一层（跑测试时不必关心工作目录）。</summary>
    private static string? ResolveCasesDir(string[] args)
    {
        if (args.Length > 0 && Directory.Exists(args[0])) return args[0];
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "behavior-cases");
            if (Directory.Exists(candidate)) return candidate;
            dir = dir.Parent;
        }

        return null;
    }
}

