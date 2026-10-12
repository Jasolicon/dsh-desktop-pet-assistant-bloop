#nullable enable
using System;

namespace Blop.Core;

/// <summary>这一轮判断要交给大脑的东西。</summary>
public sealed record JudgmentRequest(
    string ForegroundProcess,
    string ForegroundTitle,
    double IdleSeconds,
    double SinceLastJudgedSeconds,
    string SpeakStyle,
    string ShotPath);

/// <summary>
/// "该说一句什么"的来源。
/// </summary>
/// <remarks>
/// 这一层刻意做成接口：**我们希望的大脑是 DSH 那一侧**（它跑在 DSH 应用自己的运行时里，
/// 我们只管看屏幕和显示）。所以壳里不直接依赖任何 DSH 启动方式 —— 谁接上来都行：
/// 文件协议（DSH 侧来问我们）、一次性进程、将来别的都行。
/// 返回 null 或空串 = 这一轮不说（和 SILENT 同义）。
/// </remarks>
public interface IBrain
{
    string? Judge(JudgmentRequest request);
}

/// <summary>
/// 假大脑：不调模型，按输入拼一句话。
/// </summary>
/// <remarks>
/// 用途是**把环路验通**（抓屏 → 闸门 → 气泡 → 判断记录）而不花一分钱、不等模型。
/// 它故意把前台窗口写进句子里，这样一眼能看出链路上的每一段都真的接到了。
/// </remarks>
public sealed class FakeBrain : IBrain
{
    private int _n;

    public string? Judge(JudgmentRequest request)
    {
        _n++;
        if (string.IsNullOrEmpty(request.ForegroundTitle)) return null;   // 什么都没看到就不硬说
        return "（假大脑 #" + _n + "）你在用「" + Clip(request.ForegroundTitle, 18) + "」，我看着呢。";
    }

    private static string Clip(string s, int max) => s.Length <= max ? s : s.Substring(0, max) + "…";
}
