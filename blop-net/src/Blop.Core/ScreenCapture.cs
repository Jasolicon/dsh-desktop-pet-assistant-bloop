#nullable enable
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;

namespace Blop.Core;

/// <summary>一次抓屏的结果。</summary>
/// <param name="JpegBase64">给模型看的那张图（已缩到 maxWidth 以内）。</param>
/// <param name="Fingerprint">从**同一张缩略图**算出来的 8×8 指纹（别再为它重抓一次全屏）。</param>
/// <param name="Mask">这次挖洞的掩码（64 字符，'1' = 桌宠自己那块）。</param>
/// <param name="MaskedCells">挖掉几格（自检/排查用）。</param>
/// <param name="Captured">这次抓的实际屏幕矩形（区域非法时是整屏）。</param>
public sealed record GrabResult(
    string JpegBase64,
    string Fingerprint,
    string Mask,
    int MaskedCells,
    int Width,
    int Height,
    Rectangle Captured);

/// <summary>
/// 抓屏（<c>desktop-guide/DesktopGuide.ps1</c> 里 <c>Capture</c> 那个类的 C# 版）。
/// </summary>
/// <remarks>
/// 两个刻意的做法：
///   ① **一次 StretchBlt 直接"抓屏 + 缩放"** —— 老写法先 new 一张全屏位图（2880×1800 约 20MB）
///      再插值缩小，采样率一提到 0.6 秒（游戏档）那次分配和大图插值就成了主开销。GDI 一步到位。
///   ② 指纹从这张**已经缩小的图**上算 —— 不要再为了 8×8 重抓一次全屏。
/// </remarks>
public static class ScreenCapture
{
    /// <summary>区域太小/越界就当没框（退回整屏）—— 别抓出一张 3×3 的图去喂模型。</summary>
    private const int MinRegionSize = 16;

    /// <summary>必须在任何屏幕 API 之前调一次（见 <see cref="NativeMethods.EnsureDpiAware"/>）。</summary>
    public static void EnsureDpiAware() => NativeMethods.EnsureDpiAware();

    public static Rectangle PrimaryScreenBounds() => NativeMethods.PrimaryScreenBounds();

    /// <summary>上一次 <see cref="EnsureDpiAware"/> 是否成功（诊断用，见 startup.log）。</summary>
    public static bool DpiAwareCallSucceeded => NativeMethods.DpiAwareCallSucceeded;

    /// <summary>系统 DPI（96 = 100%，192 = 200%）。</summary>
    public static uint SystemDpi => NativeMethods.GetDpiForSystem();

    /// <param name="maxWidth">长边缩到这个宽度以内（越小越快，但可能看不到关键变化）。</param>
    /// <param name="jpegQuality">JPEG 质量（1–100）。</param>
    /// <param name="region">监控区域；<c>null</c> 或非法（太小/越界）时抓整屏。</param>
    /// <param name="self">桌宠自己的屏幕矩形（含它刚弹出来的气泡），用来把它自己挖掉；不需要就传 Empty。</param>
    public static GrabResult Grab(int maxWidth = 1024, long jpegQuality = 60, Rectangle? region = null, Rectangle self = default)
    {
        var (small, bounds) = CaptureScaled(region, maxWidth);
        using (small)
        {
            var mask = Fingerprint.MaskFor(bounds, self);
            var fingerprint = Fingerprint.FromLuminance(Fingerprint.Luminance8x8(small), mask);
            return new GrabResult(
                ToJpegBase64(small, jpegQuality),
                fingerprint,
                mask,
                CountMasked(mask),
                small.Width,
                small.Height,
                bounds);
        }
    }

    /// <summary>
    /// 只算指纹、**不编码 JPEG**：采样节拍用它（每 2 秒看一眼），闸门放行时才抓高质量截图。
    /// </summary>
    /// <remarks>
    /// 这是从 Electron 版学来的一处优化：截图是给模型看的，而模型只在放行时被叫到 ——
    /// 采样只算 160px 缩略图的指纹，采样率就能调密而不烧 CPU。
    /// </remarks>
    public static string FingerprintOnly(Rectangle? region = null, Rectangle self = default)
    {
        var (small, bounds) = CaptureScaled(region, 160);
        using (small)
        {
            return Blop.Core.Fingerprint.Of(small, bounds, self);
        }
    }

    /// <summary>抓屏 + 缩放（一次 StretchBlt）。返回的位图由调用方负责 Dispose。</summary>
    private static (Bitmap Bitmap, Rectangle Bounds) CaptureScaled(Rectangle? region, int maxWidth)
    {
        var screen = PrimaryScreenBounds();
        var bounds = screen;
        if (region is { } r)
        {
            var hit = Rectangle.Intersect(screen, r);
            if (hit.Width >= MinRegionSize && hit.Height >= MinRegionSize) bounds = hit;
        }

        // 目标尺寸：宽度封顶，高度按比例 —— 高至少 1，免得零高位的 Bitmap 抛异常
        var width = Math.Max(1, Math.Min(maxWidth, bounds.Width));
        var height = Math.Max(1, (int)Math.Round(bounds.Height * (width / (double)bounds.Width)));

        var small = new Bitmap(width, height);
        using (var g = Graphics.FromImage(small))
        {
            var dstDc = g.GetHdc();
            var srcDc = NativeMethods.GetDC(IntPtr.Zero);
            try
            {
                NativeMethods.SetStretchBltMode(dstDc, NativeMethods.Halftone);
                NativeMethods.StretchBlt(dstDc, 0, 0, width, height, srcDc, bounds.X, bounds.Y, bounds.Width, bounds.Height, NativeMethods.SrcCopy);
            }
            finally
            {
                NativeMethods.ReleaseDC(IntPtr.Zero, srcDc);
                g.ReleaseHdc(dstDc);
            }
        }

        return (small, bounds);
    }

    private static string ToJpegBase64(Bitmap bmp, long quality)
    {
        var codec = JpegCodec();
        using var ps = new EncoderParameters(1);
        ps.Param[0] = new EncoderParameter(Encoder.Quality, quality);
        using var ms = new MemoryStream();
        bmp.Save(ms, codec, ps);
        return Convert.ToBase64String(ms.ToArray());
    }

    private static ImageCodecInfo JpegCodec()
    {
        foreach (var c in ImageCodecInfo.GetImageEncoders())
        {
            if (c.MimeType == "image/jpeg") return c;
        }

        throw new InvalidOperationException("找不到 JPEG 编码器");
    }

    private static int CountMasked(string mask)
    {
        var n = 0;
        foreach (var ch in mask)
        {
            if (ch == '1') n++;
        }

        return n;
    }
}
