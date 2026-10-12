#nullable enable
using System.Text.RegularExpressions;

namespace Blop.Core;

/// <summary>
/// 沉默判定口径（<c>desktop-guide/DesktopGuide.ps1</c> 的 <c>Test-SilentText</c> /
/// <c>Get-JudgeSkipReason</c> 的 C# 版）。
/// </summary>
/// <remarks>
/// 四个 advisor 大脑输出的文字不一样（"（它选择不说）" / "（它选择没说）" / 裸哨兵词 SILENT /
/// "你在做：…"），判定口径统一在这里。判错的后果很重：沉默被当成发言 → 自动模式下把"没说"
/// 弹成气泡、退避不生效、沉默率偏低；而沉默率按项目总纲是要攒的标注资产。
///
/// ⚠️ 口径由 <c>behavior-cases/silence.json</c> 钉住（PowerShell 侧自检 5l 跑同一张表）。
/// 表里那条 `'silent'`（小写）不是笔误：PS 用的 <c>-match</c> 不区分大小写，所以这里也要 IgnoreCase。
/// </remarks>
public static class SilentText
{
    private static readonly Regex Sentinel = new Regex(@"^\W*[A-Z_]*SILENT\W*$", RegexOptions.IgnoreCase);
    private static readonly Regex Doing = new Regex(@"^你在做[:：]");

    /// <summary>"（它选择" 前缀 —— 只有前缀、没有后半也算沉默。</summary>
    private const string SilentPrefix = "（它选择";

    public static bool IsSilent(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        var t = text!.Trim();
        if (Sentinel.IsMatch(t)) return true;
        if (t.StartsWith(SilentPrefix)) return true;
        return Doing.IsMatch(t);
    }

    /// <summary>「这一轮没判成」（<c>SKIP: 理由</c>）里的理由；没有就是空串。</summary>
    public static string SkipReason(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "";
        foreach (var row in text!.Replace("\r\n", "\n").Split('\n'))
        {
            var t = row.Trim();
            var m = Regex.Match(t, "^SKIP[:：]\\s*", RegexOptions.IgnoreCase);
            if (m.Success) return t.Substring(m.Length).Trim();
        }

        return "";
    }
}
