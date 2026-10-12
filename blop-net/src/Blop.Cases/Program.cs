#nullable enable
using System;
using System.IO;
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

        Console.WriteLine($"全部用例表：{pass}/{pass + fail} 项通过");
        return fail;
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
