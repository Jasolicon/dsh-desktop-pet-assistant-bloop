#nullable enable
using System;
using System.IO;
using System.Text.Json;

namespace Blop.Core;

/// <summary>
/// 桌宠的配置（<c>config.json</c> 里这边用得上的那些键）。
/// </summary>
/// <remarks>
/// 刻意**不做严格校验**：读不出来、缺键、值类型不对都退回默认值 ——
/// 配置文件是给人手改的，一个逗号写错不该让桌宠起不来（PowerShell 版也是这个立场）。
/// 默认值和 <c>desktop-guide/config.json</c> 对齐，这样两边行为一致。
/// </remarks>
public sealed record BotConfig
{
    public string PetImage { get; init; } = "";
    /// <summary>气泡显示多少秒。</summary>
    public int ShowSeconds { get; init; } = 12;
    /// <summary>采样节拍（秒）：每次只算指纹，闸门放行时才抓高质量截图。</summary>
    public int SampleSeconds { get; init; } = 2;
    /// <summary>非损友模式下"自动看一眼"的节奏（分钟）。</summary>
    public int AutoMinutes { get; init; } = 1;
    public string SpeakStyle { get; init; } = "coach";
    public int JudgeMinSeconds { get; init; } = 60;
    public int JudgeMinFpDelta { get; init; } = 12;
    public int SilentBackoffMax { get; init; } = 4;
    public int JudgeIdleSkipSeconds { get; init; } = 600;
    public int JudgeMaxGapSeconds { get; init; } = 300;
    public double RoastMinSeconds { get; init; } = 15;
    public int RoastBackoffMax { get; init; } = 2;

    public GateConfig ToGateConfig() => new GateConfig
    {
        JudgeMinSeconds = JudgeMinSeconds,
        JudgeMinFpDelta = JudgeMinFpDelta,
        JudgeMaxGapSeconds = JudgeMaxGapSeconds,
        JudgeIdleSkipSeconds = JudgeIdleSkipSeconds,
        SilentBackoffMax = SilentBackoffMax,
        RoastMinSeconds = RoastMinSeconds,
        RoastBackoffMax = RoastBackoffMax,
    };

    public static BotConfig Load(string path)
    {
        var cfg = new BotConfig();
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return cfg;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var r = doc.RootElement;
            if (r.ValueKind != JsonValueKind.Object) return cfg;
            return cfg with
            {
                PetImage = Str(r, "petImage", cfg.PetImage),
                ShowSeconds = Int(r, "showSeconds", cfg.ShowSeconds),
                SampleSeconds = Math.Max(1, Int(r, "sampleSeconds", cfg.SampleSeconds)),
                AutoMinutes = Math.Max(1, Int(r, "autoMinutes", cfg.AutoMinutes)),
                SpeakStyle = Str(r, "speakStyle", cfg.SpeakStyle),
                JudgeMinSeconds = Int(r, "judgeMinSeconds", cfg.JudgeMinSeconds),
                JudgeMinFpDelta = Int(r, "judgeMinFpDelta", cfg.JudgeMinFpDelta),
                SilentBackoffMax = Int(r, "silentBackoffMax", cfg.SilentBackoffMax),
                JudgeIdleSkipSeconds = Int(r, "judgeIdleSkipSeconds", cfg.JudgeIdleSkipSeconds),
                JudgeMaxGapSeconds = Int(r, "judgeMaxGapSeconds", cfg.JudgeMaxGapSeconds),
                RoastMinSeconds = Num(r, "roastMinSeconds", cfg.RoastMinSeconds),
                RoastBackoffMax = Int(r, "roastBackoffMax", cfg.RoastBackoffMax),
            };
        }
        catch
        {
            return cfg;   // 配置坏了就当没配，别把桌宠弄挂
        }
    }

    private static string Str(JsonElement r, string key, string fallback)
        => r.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? fallback : fallback;

    private static int Int(JsonElement r, string key, int fallback)
        => r.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : fallback;

    private static double Num(JsonElement r, string key, double fallback)
        => r.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : fallback;
}
