#nullable enable
using System;

namespace Blop.Core;

/// <summary>
/// 把"这一轮的观察"拼成一句问大脑的话。
/// </summary>
/// <remarks>
/// 这是 PS 版 <c>advisor-core.ps1</c> 那套提示词的**精简版**：先只保留"看什么 + 说多少 +
/// 什么时候闭嘴"这三件最要紧的，等桥跑通了再把任务档提示、记忆、观察轨迹逐步补齐
///（那些都在 desktop-guide 里，不用重新发明）。
/// </remarks>
public static class BrainPrompt
{
    public static string Compose(JudgmentRequest req)
    {
        var style = StyleLine(req.SpeakStyle);
        return string.Join("\n", new[]
        {
            "你是桌面上的小助手。下面是这一屏的情况：",
            "- 前台窗口：" + (string.IsNullOrEmpty(req.ForegroundTitle) ? "（读不到标题）" : req.ForegroundTitle) +
            (string.IsNullOrEmpty(req.ForegroundProcess) ? "" : "（进程 " + req.ForegroundProcess + "）"),
            "- 用户已经 " + (int)req.IdleSeconds + " 秒没动键鼠；距上次判断 " + (int)req.SinceLastJudgedSeconds + " 秒。",
            "- 屏幕截图（缩略图）文件：" + req.ShotPath + "（用你的读图工具打开它再看）。",
            "",
            style,
            "",
            "硬性要求：一次不超过 60 个字（约两行）；纯文本，不要 Markdown（气泡不渲染）；",
            "不要客套、不要问「需要我帮忙吗」。觉得这一轮没什么值得说的，就只回复 SILENT。",
        });
    }

    private static string StyleLine(string style)
    {
        switch ((style ?? "").ToLowerInvariant())
        {
            case "guard":
                return "风格：保守。只在屏幕上存在可证明的错误、反复失败、或做法与目标明显冲突时才开口，否则 SILENT。";
            case "roast":
                return "风格：损友。像认识十年、嘴上不饶人的朋友：可以吐槽屏幕上那件事（不是人），" +
                       "一句拆台 +（有建议的话）一句有用的。";
            case "scout":
                return "风格：找事。不评论屏幕，而是找一件你**真能替用户做掉**的事提出来（「我来…」而不是「你应该…」）；" +
                       "提不出具体的活就 SILENT。";
            default:
                return "风格：陪练。屏幕上是一个需要决定的局面时，直接给出你推荐的那一个，并给一句话理由。";
        }
    }
}
