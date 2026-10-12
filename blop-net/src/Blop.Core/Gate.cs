#nullable enable
using System;

namespace Blop.Core;

/// <summary>
/// 闸门用到的配置（对应 desktop-guide/config.json 里的那几个键）。
/// </summary>
public sealed record GateConfig
{
    public int JudgeMinSeconds { get; init; } = 60;
    public int JudgeMinFpDelta { get; init; } = 12;
    public int JudgeMaxGapSeconds { get; init; } = 300;
    public int JudgeIdleSkipSeconds { get; init; } = 600;
    public int SilentBackoffMax { get; init; } = 4;

    /// <summary>损友模式的节拍（默认 15 秒一句）。</summary>
    public double RoastMinSeconds { get; init; } = 15;

    /// <summary>损友模式连续沉默时，间隔最多放宽到 (1+这个值) 倍。</summary>
    public int RoastBackoffMax { get; init; } = 2;
}

/// <summary>
/// 闸门这一轮看到的状态。全部由调用方给（**不从系统读**）——
/// 这样同一组输入在任何机器、任何实现上都必须得到同一个结论。
/// </summary>
public sealed record GateInput
{
    /// <summary>抓屏环形缓冲里有没有图（抓屏是异步的，启动头一两拍可能是空的）。</summary>
    public bool HasShot { get; init; } = true;

    /// <summary>待机中（黑屏 / 锁屏 / 睡眠）。</summary>
    public bool Standby { get; init; }

    /// <summary>说话风格：guard / coach / roast / scout。</summary>
    public string Style { get; init; } = "coach";

    /// <summary>距上次**判断**过了多少秒（不是采样）。</summary>
    public double SinceSeconds { get; init; } = 600;

    /// <summary>连续多少次判成「没什么可说」。</summary>
    public int SilentStreak { get; init; }

    /// <summary>前台窗口与上次判断时相比换没换。</summary>
    public bool WindowChanged { get; init; }

    /// <summary>画面指纹距离（0..960）。</summary>
    public double FingerprintDistance { get; init; }

    /// <summary>用户已经多少秒没动键鼠。</summary>
    public double IdleSeconds { get; init; }

    /// <summary>任务档给的判断间隔秒数（null = 用配置里的 judgeMinSeconds）。</summary>
    public int? ProfileJudgeSeconds { get; init; }

    public GateConfig Config { get; init; } = new();
}

/// <summary>
/// **本地闸门**：值不值得为这一轮起一次模型调用。
/// </summary>
/// <remarks>
/// 返回空串 = 值得（放行）；返回一句话 = 先别问，那句话就是原因（会写进判断记录，
/// 让用户翻得到"它为什么没说"）。
///
/// 为什么要独立成一层：一次自动判断的成本不是"一句话"，而是"起一个完整会话 + 带截图的一次
/// 模型调用"，实测 8–25 秒、真金白银；而绝大多数轮次的答案是"没事，不用说话"。
/// 而"值不值得问"这件事不需要模型 —— 屏幕变没变、窗口换没换、人还在不在，本地代码全都知道。
///
/// 与 <c>desktop-guide/DesktopGuide.ps1</c> 的 <c>Test-WorthAutoJudge</c> 是同一条口径，
/// 由 <c>behavior-cases/gate.json</c> 逐条钉住（两份实现跑同一张表）。
/// </remarks>
public static class Gate
{
    public static string Decide(GateInput s)
    {
        var cfg = s.Config;

        if (s.Standby) return "待机中";
        // 抓屏是异步的：还没有图就先别问，否则模型会拿到「没有截图」的一轮，判断质量反而更差。
        if (!s.HasShot) return "还没有画面（抓屏是异步的，等第一张下来）";

        var fpDist = (int)s.FingerprintDistance;
        var winChanged = s.WindowChanged;
        // 0 当没填（PowerShell 那边是 `if ($cfg.judgeMinFpDelta)`，0 也是假值）
        var delta = cfg.JudgeMinFpDelta != 0 ? cfg.JudgeMinFpDelta : 12;
        // 判断间隔跟着任务档走：游戏档问得勤（20s），视频/桌面档放得宽（180/300s）
        var quiet = s.ProfileJudgeSeconds is > 0
            ? s.ProfileJudgeSeconds.Value
            : (cfg.JudgeMinSeconds != 0 ? cfg.JudgeMinSeconds : 60);
        // 连续沉默就退避：它越说"不用"，我们越少去问它（也别对着无聊画面一直付费）
        var mult = 1 + Math.Min(s.SilentStreak, cfg.SilentBackoffMax - 1);
        var need = quiet * mult;
        var since = s.SinceSeconds;

        // 保险丝：不管画面多"静"，隔太久也得看一眼。没有这道的话，用户在一个窗口里连续工作
        //（8×8 指纹本来就看不出一行代码的变化），闸门会一直跳过 —— 省是省了，但桌宠等于停了。
        var maxGap = (double)(cfg.JudgeMaxGapSeconds != 0 ? cfg.JudgeMaxGapSeconds : 300);
        if (since >= maxGap) return "";

        var idle = Round(s.IdleSeconds);

        // ---- 损友模式：门控放宽两处 ----
        //   ① 间隔不看任务档的 judgeMinSeconds，改看 roastMinSeconds
        //   ② **画面没变也允许开口** —— 直播里"又在刷同一个页面""挂机二十分钟了"本身就是内容
        // 代价是真的花钱（每轮一次模型调用），所以留两个刹车：人不在不开口、连着几次没得说就退避。
        if (s.Style == "roast")
        {
            var roastGap = cfg.RoastMinSeconds;
            var roastNeed = roastGap * (1 + Math.Min(s.SilentStreak, Math.Max(0, cfg.RoastBackoffMax)));
            if (since < roastNeed)
                return $"距上次开口只有 {Round(since)}s（损友模式最短 {(int)roastNeed}s 一句）";
            if (idle >= cfg.JudgeIdleSkipSeconds)
                return $"人不在（{idle}s 没有键鼠输入）—— 吐槽也得有人在看";
            return "";
        }

        // ---- 找事模式：**画面没变也要能开口**，但节拍一分都不放松 ----
        // 为什么画面那关要拆掉：「我能替你干这个」不依赖画面变化 —— 用户坐着不动、盯着一屏发愁，
        // 往往正是可以派活的时候。为什么别的都不拆：主动提活比吐槽更需要克制，
        // 所以间隔照旧走 judgeMinSeconds + 退避，人不在照样不开口。
        // ⇒ 这一段和下面普通路径的唯一区别，就是少了"指纹几乎没变就跳过"那一关。
        if (s.Style == "scout")
        {
            if (since < need)
                return $"距上次判断只有 {Round(since)}s（连续 {s.SilentStreak} 次没说 → 间隔放宽到 {need}s）";
            if (idle >= cfg.JudgeIdleSkipSeconds && !winChanged)
                return $"人不在（{idle}s 没有键鼠输入，窗口也没换）—— 提活也得有人在";
            return "";
        }

        if (!winChanged && fpDist < delta)
            return $"画面几乎没变（差异 {fpDist} < {delta}），前台窗口也没换";
        if (since < need)
            return $"距上次判断只有 {Round(since)}s（连续 {s.SilentStreak} 次没说 → 间隔放宽到 {need}s）";
        if (idle >= cfg.JudgeIdleSkipSeconds && !winChanged)
            return $"人不在（{idle}s 没有键鼠输入，窗口也没换）";
        return "";
    }

    /// <summary>
    /// 按 PowerShell 的 <c>[int]</c> 语义取整（四舍五入到偶数），不是截断 ——
    /// 两边的原因文字要逐字相同，差 1 秒就会让用例表红（这个坑在 PowerShell 那侧踩过一次）。
    /// </summary>
    private static int Round(double v) => (int)Math.Round(v, MidpointRounding.ToEven);
}
