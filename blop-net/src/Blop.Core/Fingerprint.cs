#nullable enable
using System;

namespace Blop.Core;

/// <summary>
/// 8×8 画面指纹（64 格，每格量化成 16 级灰度）。
/// </summary>
/// <remarks>
/// 与 PowerShell 版逐字一致的口径：生成时是 <c>(char)(48 + lum / 16)</c>，
/// 所以字符是 '0'(48) 到 '?'(63)，**不是** '0'..'F'。
/// 比对用"字符码绝对差之和"，不是相不相等 —— 时钟跳一秒、光标闪一下也会变字符，
/// 只看相不相等会让闸门白起一次模型调用。
/// </remarks>
public static class Fingerprint
{
    /// <summary>两个指纹差多少：0 = 一模一样，最大 64×15 = 960。</summary>
    /// <remarks>
    /// 长度不等于 64 或者有一边为空时返回 999（"当它变了很多"）——
    /// 这是从 PowerShell 版 <c>Get-FpDistance</c> 直接搬过来的约定，别改成抛异常：
    /// 抓屏失败时闸门要能继续跑，而不是让整个观察循环挂掉。
    /// </remarks>
    public static int Distance(string? a, string? b)
    {
        // 显式写 a is null / a.Length == 0，而不是 string.IsNullOrEmpty ——
        // net48 的 BCL 没有 `[NotNullWhen(false)]` 注解，用 IsNullOrEmpty 的话
        // 编译器（开 Nullable + TreatWarningsAsErrors）会认为下一行 a 仍然可能为 null。
        if (a is null || b is null || a.Length == 0 || b.Length == 0 || a.Length != b.Length) return 999;
        var d = 0;
        for (var i = 0; i < a.Length; i++) d += Math.Abs(a[i] - b[i]);
        return d;
    }
}
