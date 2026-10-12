#nullable enable
using System;
using System.Runtime.InteropServices;

namespace Blop.App;

/// <summary>
/// 逐像素 alpha 的分层窗口要用到的那几个 Win32 调用。
/// </summary>
/// <remarks>
/// 为什么不用 WinForms 自带的 AllowTransparency / TransparencyKey：那两条一条是"整窗一个透明度"、
/// 一条是"某颜色变透明"（边缘有锯齿、也没法做半透明阴影），而我们要的是**每个像素各自的 alpha**
///（圆角、透明背景、以后的气泡阴影都靠它）。做法就是 PS 版那一套：自己画到 32bpp ARGB 位图上，
/// 再 UpdateLayeredWindow 推上去。
/// </remarks>
internal static class LayeredNative
{
    public const int WsExNoActivate = 0x08000000;   // 能点、能拖，但**不抢焦点**
    public const int WsExLayered = 0x00080000;      // 逐像素 alpha 的前提
    public const byte AcSrcOver = 0x00;
    public const byte AcSrcAlpha = 0x01;
    public const int UlwAlpha = 0x00000002;
    public const int GwlExStyle = -20;

    [StructLayout(LayoutKind.Sequential)]
    public struct Size
    {
        public int cx;
        public int cy;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BlendFunction
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hDc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hDc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hDc, IntPtr hObject);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UpdateLayeredWindow(
        IntPtr hwnd, IntPtr hdcDst, IntPtr pptDst, ref Size psize,
        IntPtr hdcSrc, ref Point pptSrc, int crKey, ref BlendFunction pblend, int dwFlags);
}
