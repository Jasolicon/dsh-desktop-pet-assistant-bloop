#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Blop.Core;

/// <summary>DSH 的三个入口（解不出的项是空串）。</summary>
public sealed record DshPaths(string Root, string Exe, string Cli, string Cmd)
{
    public static readonly DshPaths Empty = new("", "", "", "");
}

/// <summary>
/// 机器相关路径的**唯一**解析点（<c>desktop-guide/paths.ps1</c> 的 C# 版）。
/// </summary>
/// <remarks>
/// 解析链（所有路径一律按这个顺序）：
///   1. 显式配置（config.json / agents.json / 调用方传进来的值）
///   2. 环境变量（DG_* 一族）
///   3. 自动探测：PATH → 正在运行的 DSH 进程 → 常见安装位置
///
/// 约定：**找不到就返回空串**，永不抛异常 —— 由调用方决定怎么降级
///（少了 node 还能跑，只是语音输入不可用；少了 DSH 才真的什么都做不了）。
/// </remarks>
public sealed class Paths
{
    private readonly IPathWorld _w;

    /// <param name="world">外部世界（真实环境，或用例表里的假世界）</param>
    /// <param name="root">程序自己所在的目录（配置里的 <c>{root}</c>）</param>
    public Paths(IPathWorld world, string root)
    {
        _w = world;
        Root = root ?? "";
    }

    /// <summary>程序目录（<c>{root}</c>）。</summary>
    public string Root { get; }

    /// <summary>展开配置里的占位符，让配置文件不用写死机器路径。</summary>
    /// <remarks>
    /// 未知占位符**原样保留**（方便排查拼写错误 —— 静默替换成空串会让配置看起来"生效了但其实没有"）。
    /// <c>{dshRoot}</c> 只有在能算出根目录时才替换。
    /// </remarks>
    public string ExpandTokens(string? value, string? dshRoot = null)
    {
        if (string.IsNullOrWhiteSpace(value)) return "";
        var t = value!;
        var map = new List<KeyValuePair<string, string>>
        {
            new KeyValuePair<string, string>("{root}", Root),
            new KeyValuePair<string, string>("{dshHome}", DshHome()),
            new KeyValuePair<string, string>("{userProfile}", _w.Env("USERPROFILE")),
            new KeyValuePair<string, string>("{programFiles}", _w.Env("ProgramFiles")),
            new KeyValuePair<string, string>("{programFilesX86}", _w.Env("ProgramFiles(x86)")),
        };
        var root = !string.IsNullOrEmpty(dshRoot) ? dshRoot! : DshRoot("");
        if (!string.IsNullOrEmpty(root)) map.Add(new KeyValuePair<string, string>("{dshRoot}", root));
        foreach (var kv in map)
        {
            if (!string.IsNullOrEmpty(kv.Value)) t = t.Replace(kv.Key, kv.Value);
        }

        return t;
    }

    /// <summary><c>DSH_HOME</c>，未设则 <c>%USERPROFILE%\.dsh</c>。</summary>
    public string DshHome()
    {
        var fromEnv = _w.Env("DSH_HOME");
        if (!string.IsNullOrEmpty(fromEnv)) return fromEnv;
        var profile = _w.Env("USERPROFILE");
        return string.IsNullOrEmpty(profile) ? "" : Path.Combine(profile, ".dsh");
    }

    /// <summary>状态根目录：参数覆盖 → <c>DG_HOME</c> → 程序目录。</summary>
    /// <remarks>
    /// 特意**不**自动回落到 <c>&lt;DSH_HOME&gt;\bloop</c>：那样会在用户没准备的时候把已有状态"搬走"，
    /// 表现就是"配置突然重置了"。谁要外置（插件外壳）谁显式设 DG_HOME。
    /// </remarks>
    public string Home(string? over = null)
    {
        if (!string.IsNullOrEmpty(over)) return over!;
        var fromEnv = _w.Env("DG_HOME");
        if (!string.IsNullOrEmpty(fromEnv)) return fromEnv;
        return Root;
    }

    /// <summary>状态文件的完整路径。</summary>
    public string HomePath(string name, string? over = null) => Join(Home(over), name);

    /// <summary>机器级实例锁的路径 —— **故意不放在状态根里**。</summary>
    /// <remarks>
    /// 桌宠有两种形态（独立运行 / DSH 插件），两种形态的状态根不同，各自的 <c>run\pet.pid</c>
    /// 互相看不见 —— 同时起就是两只桌宠、双份抓屏、双份模型开销。所以锁放在和形态无关的位置。
    /// </remarks>
    public string LockPath()
    {
        var baseDir = _w.Env("LOCALAPPDATA");
        if (string.IsNullOrEmpty(baseDir)) baseDir = _w.Env("TEMP");
        if (string.IsNullOrEmpty(baseDir)) return "";
        return Path.Combine(baseDir, "Bloop", "pet.lock");
    }

    /// <summary>DSH 安装根：配置 → DG_DSH_ROOT/DSH_ROOT → PATH 上的 dsh 往上找 → 运行中的进程 → 常见位置。</summary>
    public string DshRoot(string? configured = null)
    {
        var explicitPath = ExpandTokens(configured, "");
        if (!string.IsNullOrEmpty(explicitPath) && _w.Exists(explicitPath)) return Normalize(explicitPath);

        foreach (var name in new[] { "DG_DSH_ROOT", "DSH_ROOT" })
        {
            var v = _w.Env(name);
            if (!string.IsNullOrEmpty(v) && _w.Exists(v)) return Normalize(v);
        }

        // 从 PATH 上的 dsh.cmd 往上走，找到带 resources 的那一层
        var cmd = _w.PathOf("dsh");
        if (!string.IsNullOrEmpty(cmd))
        {
            var d = Path.GetDirectoryName(cmd) ?? "";
            for (var i = 0; i < 6 && !string.IsNullOrEmpty(d); i++)
            {
                if (_w.Exists(Path.Combine(d, "resources"))) return Normalize(d);
                var parent = Path.GetDirectoryName(d) ?? "";
                if (string.IsNullOrEmpty(parent) || parent == d) break;
                d = parent;
            }
        }

        // 从正在运行的 DSH 进程反推：装在哪儿就在哪儿跑，这是最可靠的信号 ——
        // 也因此不需要把某台机器的安装盘符写进代码（原来写死了 D:\DeepSeekHarness）。
        var running = _w.RunningHarnessRoot();
        if (!string.IsNullOrEmpty(running) && _w.Exists(Path.Combine(running, "resources"))) return Normalize(running);

        var pf = _w.Env("ProgramFiles");
        var pf86 = _w.Env("ProgramFiles(x86)");
        var local = _w.Env("LOCALAPPDATA");
        var candidates = new List<string>();
        if (!string.IsNullOrEmpty(pf)) candidates.Add(Path.Combine(pf, "DeepSeek Harness"));
        if (!string.IsNullOrEmpty(pf86)) candidates.Add(Path.Combine(pf86, "DeepSeek Harness"));
        if (!string.IsNullOrEmpty(local))
        {
            candidates.Add(Path.Combine(local, @"Programs\DeepSeek Harness"));
            candidates.Add(Path.Combine(local, "DeepSeekHarness"));
        }

        return FirstExisting(candidates);
    }

    /// <summary>一次把 DSH 的三个入口都解出来。</summary>
    /// <remarks>
    /// ⚠️ <c>cli.js</c> 在 <c>app.asar</c> **归档里面** —— 文件系统看不见它（逐级测到 <c>app.asar\</c> 就是 False），
    /// 但 Electron 读得到。所以这一项**不能**用"必须真实存在"的语义：显式给了就直接用，
    /// 没给就从挂载点推（只校验 app.asar 这个文件在不在）。
    /// </remarks>
    public DshPaths Dsh(string? rootCfg = null, string? exeCfg = null, string? cliCfg = null, string? cmdCfg = null)
    {
        var root = DshRoot(rootCfg);

        var exe = FirstExisting(new[]
        {
            ExpandTokens(exeCfg, root),
            ExpandTokens(_w.Env("DG_DSH_EXE"), root),
        });
        if (string.IsNullOrEmpty(exe) && !string.IsNullOrEmpty(root))
        {
            exe = FirstExisting(new[]
            {
                Path.Combine(root, "DeepSeek Harness.exe"),
                Path.Combine(root, "DeepSeekHarness.exe"),
            });
            if (string.IsNullOrEmpty(exe))
            {
                exe = _w.ListFiles(root, "*.exe").FirstOrDefault(
                    f => Path.GetFileName(f).IndexOf("Harness", StringComparison.OrdinalIgnoreCase) >= 0) ?? "";
            }
        }

        var cli = ExpandTokens(cliCfg, root);
        if (string.IsNullOrEmpty(cli)) cli = ExpandTokens(_w.Env("DG_DSH_CLI"), root);
        if (string.IsNullOrEmpty(cli) && !string.IsNullOrEmpty(root))
        {
            const string inner = @"dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js";
            if (_w.Exists(Path.Combine(root, @"resources\app.asar")))
                cli = Path.Combine(root, @"resources\app.asar", inner);
            else if (_w.Exists(Path.Combine(root, @"resources\app.asar.unpacked")))
                cli = Path.Combine(root, @"resources\app.asar.unpacked", inner);
        }

        var cmd = FirstExisting(new[]
        {
            ExpandTokens(cmdCfg, root),
            ExpandTokens(_w.Env("DG_DSH_CMD"), root),
        });
        if (string.IsNullOrEmpty(cmd) && !string.IsNullOrEmpty(root))
        {
            cmd = FirstExisting(new[] { Path.Combine(root, @"resources\runtime\cli\bin\dsh.cmd") });
            if (string.IsNullOrEmpty(cmd)) cmd = _w.PathOf("dsh");
        }

        return new DshPaths(root, exe, cli, cmd);
    }

    /// <summary>node.exe：配置 → DG_NODE → PATH → 常见安装位置（语音输入要用它跑 .cjs）。</summary>
    public string Node(string? configured = null)
    {
        var hit = FirstExisting(new[] { configured ?? "", _w.Env("DG_NODE") });
        if (!string.IsNullOrEmpty(hit)) return hit;
        var onPath = _w.PathOf("node");
        if (!string.IsNullOrEmpty(onPath) && _w.Exists(onPath)) return onPath;
        var pf = _w.Env("ProgramFiles");
        var pf86 = _w.Env("ProgramFiles(x86)");
        var local = _w.Env("LOCALAPPDATA");
        var candidates = new List<string>();
        if (!string.IsNullOrEmpty(pf)) candidates.Add(Path.Combine(pf, @"nodejs\node.exe"));
        if (!string.IsNullOrEmpty(pf86)) candidates.Add(Path.Combine(pf86, @"nodejs\node.exe"));
        if (!string.IsNullOrEmpty(local)) candidates.Add(Path.Combine(local, @"Programs\nodejs\node.exe"));
        return FirstExisting(candidates);
    }

    /// <summary>msedge.exe：配置 → DG_EDGE → 常见安装位置 → PATH。</summary>
    public string Edge(string? configured = null)
    {
        var hit = FirstExisting(new[] { configured ?? "", _w.Env("DG_EDGE") });
        if (!string.IsNullOrEmpty(hit)) return hit;
        var pf = _w.Env("ProgramFiles");
        var pf86 = _w.Env("ProgramFiles(x86)");
        var local = _w.Env("LOCALAPPDATA");
        var candidates = new List<string>();
        if (!string.IsNullOrEmpty(pf86)) candidates.Add(Path.Combine(pf86, @"Microsoft\Edge\Application\msedge.exe"));
        if (!string.IsNullOrEmpty(pf)) candidates.Add(Path.Combine(pf, @"Microsoft\Edge\Application\msedge.exe"));
        if (!string.IsNullOrEmpty(local)) candidates.Add(Path.Combine(local, @"Microsoft\Edge\Application\msedge.exe"));
        hit = FirstExisting(candidates);
        if (!string.IsNullOrEmpty(hit)) return hit;
        var onPath = _w.PathOf("msedge");
        return !string.IsNullOrEmpty(onPath) && _w.Exists(onPath) ? onPath : "";
    }

    /// <summary>桌宠角色图：配置 → DG_PET_IMAGE → 本目录 <c>assets\pet.png</c>。</summary>
    /// <remarks>**只认自己的素材**，不指向任何别人装的插件目录；都没有就返回空串（调用方退回代码绘制的圆脸）。</remarks>
    public string PetImage(string? configured = null)
    {
        var hit = FirstExisting(new[] { ExpandTokens(configured, ""), _w.Env("DG_PET_IMAGE") });
        if (!string.IsNullOrEmpty(hit)) return hit;
        return FirstExisting(new[] { Path.Combine(Root, @"assets\pet.png") });
    }

    private string FirstExisting(IEnumerable<string> candidates)
    {
        foreach (var c in candidates)
        {
            if (!string.IsNullOrEmpty(c) && _w.Exists(c)) return c;
        }

        return "";
    }

    /// <summary>绝对化（等价 Resolve-Path）：解析不出就原样返回，从不抛。</summary>
    private static string Normalize(string path)
    {
        try
        {
            return Path.GetFullPath(path);
        }
        catch
        {
            return path;
        }
    }

    private static string Join(string dir, string name)
    {
        try
        {
            return string.IsNullOrEmpty(dir) ? name : Path.Combine(dir, name);
        }
        catch
        {
            return name;
        }
    }
}
