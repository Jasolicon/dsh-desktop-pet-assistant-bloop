#nullable enable
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Text;

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
    /// <summary>一格的边长比例：一格落在这个矩形里的面积 ≥ 这个比例就挖掉。</summary>
    /// <remarks>
    /// 取 0.30 而不是"碰一点就挖"：桌宠是圆角 + 透明背景，边缘那几格只被压住一角，
    /// 挖掉它们等于白丢分辨率。
    /// </remarks>
    private const double SelfOverlapToMask = 0.30;

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

    /// <summary>
    /// 8×8 网格的挖洞掩码（64 字符，'1' = 这一格算桌宠自己那块，指纹里固定写 '0'）。
    /// </summary>
    /// <remarks>
    /// 为什么要挖：抓屏和指纹都是整屏的，**里面就有桌宠自己**。它弹一次气泡就会让那几格变化 ——
    /// 等于"我自己说了一句话"被当成"画面变了"，下一轮更容易再开口（越说越想说的正反馈）。
    /// 实测某些位置下它自己弹一次就够触发一次判断（指纹差 26，而阈值是 12）。
    ///
    /// 纯几何：只取决于"截到的矩形"和"桌宠自己的矩形"，不碰位图、不读系统状态 ——
    /// 所以能被 behavior-cases/fingerprint.json 直接钉死（三份实现共用一份）。
    /// </remarks>
    public static string MaskFor(Rectangle captured, Rectangle self)
    {
        var sb = new StringBuilder(64);
        var cellW = captured.Width / 8.0;
        var cellH = captured.Height / 8.0;
        for (var y = 0; y < 8; y++)
        {
            for (var x = 0; x < 8; x++)
            {
                var masked = false;
                if (!self.IsEmpty && cellW > 0 && cellH > 0)
                {
                    var cell = Rectangle.FromLTRB(
                        captured.X + (int)Math.Floor(x * cellW), captured.Y + (int)Math.Floor(y * cellH),
                        captured.X + (int)Math.Ceiling((x + 1) * cellW), captured.Y + (int)Math.Ceiling((y + 1) * cellH));
                    var inter = Rectangle.Intersect(cell, self);
                    if (inter.Width > 0 && inter.Height > 0 &&
                        inter.Width * (double)inter.Height / (cell.Width * (double)cell.Height) >= SelfOverlapToMask)
                    {
                        masked = true;
                    }
                }

                sb.Append(masked ? '1' : '0');
            }
        }

        return sb.ToString();
    }

    /// <summary>把一张图缩成 8×8 并取每格亮度（0–255，行优先）。</summary>
    public static byte[] Luminance8x8(Bitmap img)
    {
        using var tiny = new Bitmap(8, 8);
        using (var g = Graphics.FromImage(tiny))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
            g.DrawImage(img, 0, 0, 8, 8);
        }

        var lum = new byte[64];
        for (var y = 0; y < 8; y++)
        {
            for (var x = 0; x < 8; x++)
            {
                var c = tiny.GetPixel(x, y);
                lum[y * 8 + x] = (byte)((c.R * 30 + c.G * 59 + c.B * 11) / 100);
            }
        }

        return lum;
    }

    /// <summary>
    /// 把 64 格亮度量化成指纹字符串：<c>'0'(48)</c> 到 <c>'?'(63)</c>，**不是** '0'..'F'。
    /// </summary>
    /// <remarks>
    /// 挖掉的格子固定写 '0'：它对"差值之和"贡献 0，字符串相等比较里也永远相等 ——
    /// 于是 <see cref="Distance"/> 和"指纹变没变"两条路都自动忽略它，调用方不用改。
    /// </remarks>
    public static string FromLuminance(byte[] lum, string mask)
    {
        if (lum.Length != 64) throw new ArgumentException("亮度数组必须是 64 格", nameof(lum));
        var sb = new StringBuilder(64);
        for (var i = 0; i < 64; i++)
        {
            var masked = mask.Length == 64 && mask[i] == '1';
            sb.Append(masked ? '0' : (char)(48 + lum[i] / 16));
        }

        return sb.ToString();
    }

    /// <summary>从一张位图算指纹（缩到 8×8 → 每格亮度 → 量化，挖掉的格子固定 '0'）。</summary>
    public static string Of(Bitmap img, Rectangle captured, Rectangle self)
        => FromLuminance(Luminance8x8(img), MaskFor(captured, self));
}
