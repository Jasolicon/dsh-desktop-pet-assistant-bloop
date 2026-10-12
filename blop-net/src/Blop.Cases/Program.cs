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
internal static class Program
{
    private static int Main(string[] args)
    {
        var casesDir = ResolveCasesDir(args);
        if (casesDir is null)
        {
            Console.Error.WriteLine("找不到 behavior-cases 目录（可以在仓库根跑，或把它的路径当第一个参数传进来）");
            return 2;
        }

        var pass = 0;
        var fail = 0;
        Console.WriteLine($"用例表目录：{casesDir}");

        RunGate(Path.Combine(casesDir, "gate.json"), ref pass, ref fail);

        Console.WriteLine($"闸门用例表：{pass}/{pass + fail} 项通过");
        return fail == 0 ? 0 : 1;
    }

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
