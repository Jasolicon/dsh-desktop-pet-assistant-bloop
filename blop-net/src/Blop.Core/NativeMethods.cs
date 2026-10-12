#nullable enable
using System;
using System.Runtime.InteropServices;

namespace Blop.Core;

/// <summary>抓屏与 DPI 要用到的那几个 Win32 调用（<c>desktop-guide</c> 里内嵌 C# 那套的等价物）。</summary>
internal static class NativeMethods
{
    public const int SmCxScreen = 0;
    public const int SmCyScreen = 1;
    public const int Halftone = 4;
    public const int SrcCopy = 0x00CC0020;
    private static readonly IntPtr PerMonitorAwareV2 = new IntPtr(-4);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForSystem();

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDc);

    [DllImport("gdi32.dll")]
    public static extern bool StretchBlt(
        IntPtr hdcDest, int xDest, int yDest, int wDest, int hDest,
        IntPtr hdcSrc, int xSrc, int ySrc, int wSrc, int hSrc, int rop);

    [DllImport("gdi32.dll")]
    public static extern int SetStretchBltMode(IntPtr hdc, int mode);

    /// <summary>
    /// **必须在任何屏幕 API 之前调用**。进程若不是 DPI 感知的：① 给的坐标会被系统乘 2 再落地
    /// （"右下角"根本不是你算的位置）；② 逐像素 alpha 的分层窗口会完全不合成，退化成一块空白底色
    ///（实测：加上这一句之后分层窗口立刻正常）。
    /// </summary>
    public static void EnsureDpiAware()
    {
        try
        {
            DpiAwareCallSucceeded = SetProcessDpiAwarenessContext(PerMonitorAwareV2);
        }
        catch
        {
            // 老系统上没这个 API，忽略 —— 退化成系统缩放，不该为此崩掉
            DpiAwareCallSucceeded = false;
        }
    }

    /// <summary>
    /// 上一次 <see cref="EnsureDpiAware"/> 是否成功。**诊断用**：
    /// 返回 false 通常意味着"进程的 DPI 感知早就定下来了"（清单或 app.config 已经设过），
    /// 这时要看的是那个来源，而不是这一句。
    /// </summary>
    public static bool DpiAwareCallSucceeded { get; private set; }

    /// <summary>主屏尺寸（DPI 感知下就是物理像素）。</summary>
    public static System.Drawing.Rectangle PrimaryScreenBounds()
        => new System.Drawing.Rectangle(0, 0, GetSystemMetrics(SmCxScreen), GetSystemMetrics(SmCyScreen));
}
