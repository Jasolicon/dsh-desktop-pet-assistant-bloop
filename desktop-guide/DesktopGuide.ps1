# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# desktop-guide（桌宠版）—— 常驻桌面的「随时指导」小宠物
#
# 它在做什么：
#   一只常年待在桌面上的小宠物。后台悄悄观察你在用什么程序、停留多久，并周期性抓一张缩小的截图；
#   你想问它的时候（点它 / 按 Ctrl+Alt+G），它把最近一段观察交给「大脑」换回**一句**建议，用气泡说出来。
#
# 它不做什么：
#   不监听键盘输入、不读剪贴板、不记录窗口里的文字；截图只在内存里，落盘的只有窗口标题/进程/时间。
#   不抢焦点（WS_EX_NOACTIVATE），但可以点、可以拖。
#
# 交互：
#   左键点它        = 现在说一句
#   双击它          = 打断（停止朗读；正在思考也一并取消）
#   拖它            = 换位置（位置会被记住）
#   右键            = 菜单（现在说一句 / 自动发言 / 朗读 / 退出）
#   Ctrl+Alt+G      = 同「左键点它」
#
# 大脑（config.json 的 advisor）：命令行末尾会追加 payload.json 的路径，把它要说的话打到 stdout。
# 朗读（tts.ps1）：把结论句念出来。默认开，右键「朗读」可静音，双击宠物可打断。

param(
  [string]$Config = (Join-Path $PSScriptRoot 'config.json'),
  [switch]$SelfTest,
  [switch]$Dump,
  [switch]$VisibleTest,
  [int]$Seconds = 0
)

$ErrorActionPreference = 'Stop'

# ===========================================================================
# 必须在任何 WinForms / 屏幕 API 之前设置 DPI 感知。
# 这台机器是 200% 缩放（物理 2880x1800，逻辑 1440x900）。进程若是 DPI-unaware：
#   1. 给的坐标会被系统乘 2 再落地 —— "右下角"根本不是你算的那个位置；
#   2. 逐像素 alpha 的分层窗口（桌宠的透明圆角）会**完全不合成**，窗口退化成一块空白底色。
# 实测：加上这一句之后分层窗口立刻正常。踩过的坑，写在这里。
# ===========================================================================
if (-not ('DesktopGuide.Dpi' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DesktopGuide {
  public static class Dpi {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    public static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);
    public static uint Scale() {
      try { SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2); } catch { }
      try { return GetDpiForSystem(); } catch { return 96; }
    }
  }
}
'@
}
$script:Dpi = [DesktopGuide.Dpi]::Scale()
$script:UiScale = [Math]::Max(1.0, [double]$script:Dpi / 96.0)

# 让控制台里的中文不乱码（cmd / Windows Terminal 下默认会用系统码页）
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }

# 这个脚本用 PowerShell 7 的 Add-Type 引用方式（.NET Core）。Windows PowerShell 5.1 用的是
# .NET Framework，引用解析完全不同（会把原生 DLL 当托管程序集读，报 PE image 错）。
if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Host '需要 PowerShell 7（pwsh），当前是 Windows PowerShell ' -NoNewline
  Write-Host $PSVersionTable.PSVersion.ToString() -ForegroundColor Yellow
  Write-Host '请改用：pwsh -NoProfile -ExecutionPolicy Bypass -File "<本文件路径>"'
  exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 机器相关路径（DSH 装在哪、node/edge 在哪、角色图用哪张）统一走 paths.ps1。
# 别在本文件里写绝对路径 —— 换台机器就哑，而且报错只会说「找不到文件」。
if (-not (Get-Command Get-DgDshPaths -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'paths.ps1') }

# ---------------------------------------------------------------------------
# 原生互操作 + 桌宠本体（C#，因为要自绘和精确控制窗口样式）
# ---------------------------------------------------------------------------
if (-not ('DesktopGuide.PetForm' -as [type])) {
  $runtimeDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
  $refs = @(
    Get-ChildItem -LiteralPath $runtimeDir -Filter 'System.*.dll' |
      # 排除 System.Private.CoreLib 是有代价的：它是"真正装着类型"的那个程序集，
      # 其它 System.*.dll 多半只是转发壳，所以 List<T> / Thread / Task 这类类型
      # 在这个 C# 块里用不了（CS1069）。把它加进 -ReferencedAssemblies 也没用 ——
      # PowerShell 的 Add-Type 会自己再滤掉（实测）。
      # 结论：这个代码块里不要用 CoreLib 的类型；要异步就用 PowerShell 的 runspace
      # （见下面的 Reset-CaptureRunspace / Start-BackgroundCapture）。
      Where-Object { $_.Name -notlike '*.Native.dll' } |
      Select-Object -ExpandProperty FullName
  )
  $refs += [System.Windows.Forms.Form].Assembly.Location
  $refs = $refs | Select-Object -Unique

  Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace DesktopGuide {
  public static class Native {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WM_HOTKEY = 0x0312;
    public const int WM_NCHITTEST = 0x0084;
    public const int WM_LBUTTONDBLCLK = 0x0203;
    public const int WM_POWERBROADCAST = 0x0218;      // 睡眠/唤醒、显示器开关
    public const int WM_WTSSESSION_CHANGE = 0x02B1;   // 锁屏/解锁、远程会话连接
    public const int HTCLIENT = 1;
    public const int HTTRANSPARENT = -1;
    public const uint MOD_ALT = 0x0001;
    public const uint MOD_CONTROL = 0x0002;

    // ---- 待机识别（黑屏 / 锁屏 / 睡眠）----
    // 为什么不能靠"截图失败"来判断：那是**症状**，而且每 2 秒刷一条警告（实测刷满日志）。
    // 系统本来就有正式信号，窗口消息里直接给：
    //   WM_WTSSESSION_CHANGE  → 锁屏 / 解锁 / 远程会话连断
    //   WM_POWERBROADCAST     → 睡眠 / 唤醒、以及显示器开/关/变暗（PBT_POWERSETTINGCHANGE）
    public const int PBT_APMSUSPEND = 0x0004;
    public const int PBT_APMRESUMESUSPEND = 0x0007;
    public const int PBT_APMRESUMEAUTOMATIC = 0x0012;
    public const int PBT_POWERSETTINGCHANGE = 0x8013;
    public const int WTS_CONSOLE_CONNECT = 0x1;
    public const int WTS_CONSOLE_DISCONNECT = 0x2;
    public const int WTS_REMOTE_CONNECT = 0x3;
    public const int WTS_REMOTE_DISCONNECT = 0x4;
    public const int WTS_SESSION_LOCK = 0x7;
    public const int WTS_SESSION_UNLOCK = 0x8;
    public const int NOTIFY_FOR_THIS_SESSION = 0;
    public const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct POWERBROADCAST_SETTING { public Guid PowerSetting; public int DataLength; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUID { public uint a; public ushort b; public ushort c; public byte d; public byte e; public byte f; public byte g; public byte h; public byte i; public byte j; public byte k; }
    /// <summary>GUID_CONSOLE_DISPLAY_STATE = {6FE69556-704A-47A0-8F24-C28D936FDA47}</summary>
    public static readonly Guid GUID_CONSOLE_DISPLAY_STATE =
      new Guid(0x6FE69556, 0x704A, 0x47A0, 0x8F, 0x24, 0xC2, 0x8D, 0x93, 0x6F, 0xDA, 0x47);
    public const int DISPLAY_OFF = 0;
    public const int DISPLAY_ON = 1;
    public const int DISPLAY_DIMMED = 2;

    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSRegisterSessionNotification(IntPtr hWnd, int dwFlags);
    [DllImport("wtsapi32.dll")]
    public static extern bool WTSUnRegisterSessionNotification(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid PowerSettingGuid, int Flags);
    [DllImport("user32.dll")]
    public static extern bool UnregisterPowerSettingNotification(IntPtr Handle);

    // 分层窗口：用逐像素 alpha 画桌宠，边缘才不会有色键紫边。
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx; public int cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("gdi32.dll")] public static extern bool StretchBlt(IntPtr hdcDest, int xDest, int yDest, int wDest, int hDest,
      IntPtr hdcSrc, int xSrc, int ySrc, int wSrc, int hSrc, int rop);
    [DllImport("gdi32.dll")] public static extern int SetStretchBltMode(IntPtr hdc, int mode);
    public const int HALFTONE = 4;
    public const int SRCCOPY = 0x00CC0020;
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, IntPtr pptDst, ref SIZE psize,
      IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);

    public const byte AC_SRC_OVER = 0x00;
    public const byte AC_SRC_ALPHA = 0x01;
    public const int ULW_ALPHA = 0x00000002;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetLayeredWindowAttributes(IntPtr hwnd, out uint pcrKey, out byte pbAlpha, out uint pdwFlags);
    public const uint LWA_COLORKEY = 0x1;
    public const uint LWA_ALPHA = 0x2;

    public static string ForegroundTitle() {
      IntPtr h = GetForegroundWindow();
      if (h == IntPtr.Zero) return "";
      int len = GetWindowTextLength(h);
      if (len <= 0) return "";
      var sb = new StringBuilder(len + 2);
      GetWindowText(h, sb, sb.Capacity);
      return sb.ToString();
    }

    public static int ForegroundPid() {
      IntPtr h = GetForegroundWindow();
      if (h == IntPtr.Zero) return 0;
      uint pid;
      GetWindowThreadProcessId(h, out pid);
      return (int)pid;
    }

    /// <summary>
    /// 前台**窗口**句柄（不是进程）。为什么需要它：同一个进程里换窗口（两个资源管理器窗口、
    /// 两个浏览器窗口、VS Code 换工作区）pid 完全相同，只看 pid 会把这类切换整个漏掉 ——
    /// 而它对用户就是"换了个窗口"，同样值得立刻看一眼。返回 long 而不是 IntPtr：
    /// PowerShell 那侧要拿它做数值比较，IntPtr 的 -eq 语义容易出意外。
    /// </summary>
    public static long ForegroundHwnd() {
      IntPtr h = GetForegroundWindow();
      return h == IntPtr.Zero ? 0L : h.ToInt64();
    }

    // 列出可见的顶层窗口（标题 + 矩形），用来把 agent 说的"盯这个窗口"解析成真实坐标。
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    delegate bool EnumProc(IntPtr h, IntPtr p);
    // 距上次键鼠输入过了多久（毫秒）。Windows 自己就在算这个 —— 免费的 AFK 探测器。
    // 有了它才能把「等程序跑完」和「人不在」分开：前者画面可能在动但人没动，后者两者都静止。
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static int IdleMs() {
      var li = new LASTINPUTINFO();
      li.cbSize = (uint)Marshal.SizeOf(li);
      if (!GetLastInputInfo(ref li)) return -1;
      return (int)((uint)Environment.TickCount - li.dwTime);
    }

    // 现场问一次"现在是不是锁屏"：工作站锁上时输入桌面换成 Winlogon，普通进程打不开它。
    // 为什么需要这条**主动查询**：锁屏/显示器关是**消息**驱动的（WM_WTSSESSION_CHANGE /
    // PBT_POWERSETTINGCHANGE），消息漏一条，桌宠就会一直以为自己在待机。
    // 实测踩过：18:09 "锁屏 + 显示器已关"进来之后，解锁的通知没到，桌宠连着两小时没再看一眼屏幕，
    // 期间用户每次点它，模型只能拿到"窗口标题 + 时间线"、没有截图 —— 于是照标题脑补出
    // 一堆"把采集方式改成 Windows 10"之类的具体操作建议。
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr OpenInputDesktop(uint dwFlags, [MarshalAs(UnmanagedType.Bool)] bool fInherit, uint dwDesiredAccess);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool CloseDesktop(IntPtr hDesktop);
    public static bool IsLockedNow() {
      // 0x0100 = DESKTOP_SWITCHDESKTOP（切回输入桌面所需的权限）
      IntPtr h = OpenInputDesktop(0, false, 0x0100);
      if (h == IntPtr.Zero) return true;    // 打不开 = 锁屏或安全桌面（保守：当作在待机）
      CloseDesktop(h);
      return false;
    }

    public static string[] ListWindows() {
      var list = new System.Collections.ArrayList();
      EnumWindows((h, p) => {
        if (!IsWindowVisible(h)) return true;
        int ex = GetWindowLong(h, -20);
        if ((ex & 0x00000080) != 0) return true;          // WS_EX_TOOLWINDOW：跳过工具窗
        RECT r; GetWindowRect(h, out r);
        if (r.R - r.L < 200 || r.B - r.T < 150) return true;  // 太小的不算
        var sb = new StringBuilder(300);
        GetWindowText(h, sb, 300);
        var title = sb.ToString();
        if (title.Length == 0) return true;
        list.Add(title + "\u0001" + r.L + "," + r.T + "," + (r.R - r.L) + "," + (r.B - r.T));
        return true;
      }, IntPtr.Zero);
      return (string[])list.ToArray(typeof(string));
    }
  }

  public static class Capture {
    static ImageCodecInfo JpegCodec() {
      foreach (var c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") return c;
      throw new InvalidOperationException("找不到 JPEG 编码器");
    }
    public static string GrabJpegBase64(int maxWidth, long quality) {
      return GrabRectJpeg(Screen.PrimaryScreen.Bounds, maxWidth, quality);
    }
    // 带监控区域：只抓框选的矩形；区域非法（太小/越界）就退回全屏
    public static string GrabJpegBase64(int maxWidth, long quality, int rx, int ry, int rw, int rh) {
      var screen = Screen.PrimaryScreen.Bounds;
      var r = Rectangle.Intersect(screen, new Rectangle(rx, ry, rw, rh));
      if (r.Width < 16 || r.Height < 16) r = screen;
      return GrabRectJpeg(r, maxWidth, quality);
    }
    // 通用「变化检测」：把画面缩成 8x8 灰度取平均，得到一个指纹。
    // 不需要任何按应用的适配器 —— 指纹没变就说明画面没动，这样可以跳过一整轮模型调用。
    // 顺带得到「静止了多久」，那是一个领域无关的"可能卡住了"信号。
    public static string GrabFingerprint(int rx, int ry, int rw, int rh) {
      var screen = Screen.PrimaryScreen.Bounds;
      var r = Rectangle.Intersect(screen, new Rectangle(rx, ry, rw, rh));
      if (r.Width < 16 || r.Height < 16) r = screen;
      using (var small = new Bitmap(8, 8))
      using (var g = Graphics.FromImage(small)) {
        var full = new Bitmap(r.Width, r.Height);
        using (var g0 = Graphics.FromImage(full)) g0.CopyFromScreen(r.Location, Point.Empty, r.Size);
        g.InterpolationMode = InterpolationMode.HighQualityBilinear;
        g.DrawImage(full, 0, 0, 8, 8);
        full.Dispose();
        var sb = new StringBuilder(32);
        for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {
          var c = small.GetPixel(x, y);
          int lum = (c.R * 30 + c.G * 59 + c.B * 11) / 100;
          sb.Append((char)(48 + lum / 16));   // 每格量化成 16 级
        }
        return sb.ToString();
      }
    }

    static string GrabRectJpeg(Rectangle bounds, int maxWidth, long quality) {
      // ⚡ 一次 StretchBlt 直接"抓屏 + 缩放"到目标尺寸。
      // 老写法是先 new Bitmap(2880,1800)（约 20MB）+ CopyFromScreen 再 HighQualityBicubic 缩到 1024 宽 ——
      // 采样率一旦提到 0.6 秒（游戏档），那 20MB 分配和那次大图插值就成了 UI 线程的主要开销。
      // StretchBlt 让 GDI 一步到位，省掉整张全尺寸位图和第二次拷贝。
      int w = Math.Min(maxWidth, bounds.Width);
      int h = Math.Max(1, (int)Math.Round(bounds.Height * (w / (double)bounds.Width)));
      using (var small = new Bitmap(w, h))
      using (var g2 = Graphics.FromImage(small)) {
        IntPtr dstDc = g2.GetHdc();
        IntPtr srcDc = Native.GetDC(IntPtr.Zero);
        try {
          Native.SetStretchBltMode(dstDc, Native.HALFTONE);
          Native.StretchBlt(dstDc, 0, 0, w, h, srcDc, bounds.X, bounds.Y, bounds.Width, bounds.Height, Native.SRCCOPY);
        } finally {
          Native.ReleaseDC(IntPtr.Zero, srcDc);
          g2.ReleaseHdc(dstDc);
        }
        // 顺手从这张已经缩小过的图算指纹 —— 别再为了 8x8 去重抓一次全屏。
        LastFingerprint = FingerprintOf(small);
        var codec = JpegCodec();
        var ps = new EncoderParameters(1);
        ps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
        using (var ms = new MemoryStream()) {
          small.Save(ms, codec, ps);
          return Convert.ToBase64String(ms.ToArray());
        }
      }
    }

    /** 最近一次截图算出来的画面指纹（8x8 灰度量化）。GrabRectJpeg 每次抓图都会更新它。 */
    public static string LastFingerprint = "";


    static string FingerprintOf(Bitmap img) {
      using (var tiny = new Bitmap(8, 8))
      using (var g = Graphics.FromImage(tiny)) {
        g.InterpolationMode = InterpolationMode.HighQualityBilinear;
        g.DrawImage(img, 0, 0, 8, 8);
        var sb = new StringBuilder(32);
        for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {
          var c = tiny.GetPixel(x, y);
          int lum = (c.R * 30 + c.G * 59 + c.B * 11) / 100;
          sb.Append((char)(48 + lum / 16));
        }
        return sb.ToString();
      }
    }
  }

  // 桌宠：透明背景、置顶、不抢焦点、可点击、可拖动、自绘。
  /// 框选监控区域：铺满全屏的半透明罩子，拖出矩形 → 就是监控区域；Esc 取消。
  public class RegionPicker : Form {
    public Rectangle Selected = Rectangle.Empty;
    public bool Cancelled;
    Point start;
    bool dragging;
    Rectangle current;

    public RegionPicker() {
      FormBorderStyle = FormBorderStyle.None;
      ShowInTaskbar = false;
      TopMost = true;
      StartPosition = FormStartPosition.Manual;
      Bounds = SystemInformation.VirtualScreen;
      Cursor = Cursors.Cross;
      BackColor = Color.Black;
      Opacity = 0.35;
      DoubleBuffered = true;
      KeyPreview = true;
    }
    static Rectangle Normalize(Point a, Point b) {
      return new Rectangle(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));
    }
    protected override void OnMouseDown(MouseEventArgs e) { start = e.Location; dragging = true; current = new Rectangle(e.Location, Size.Empty); Invalidate(); }
    protected override void OnMouseMove(MouseEventArgs e) { if (!dragging) return; current = Normalize(start, e.Location); Invalidate(); }
    protected override void OnMouseUp(MouseEventArgs e) {
      if (!dragging) return;
      dragging = false;
      current = Normalize(start, e.Location);
      if (current.Width < 24 || current.Height < 24) Cancelled = true;
      else Selected = current;
      Close();
    }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Escape) { Cancelled = true; Close(); } base.OnKeyDown(e); }
    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics;
      g.Clear(Color.FromArgb(255, 10, 10, 14));
      if (current.Width > 0) {
        using (var b = new SolidBrush(Color.FromArgb(255, 245, 248, 252))) g.FillRectangle(b, current);
        using (var p = new Pen(Color.FromArgb(255, 60, 140, 240), 3f)) g.DrawRectangle(p, current);
      }
      using (var f = new Font("Microsoft YaHei UI", 13f, FontStyle.Bold))
      using (var tb = new SolidBrush(Color.White))
        g.DrawString("拖出一个矩形 = 只监控这一块     Esc / 拖太小 = 取消", f, tb, 40, 40);
    }
  }

  public class PetForm : Form {
    public event EventHandler AskRequested;
    public event EventHandler AutoChanged;
    public event EventHandler HistoryRequested;
    public event EventHandler CollapseRequested;
    public event EventHandler Moved;
    public event EventHandler AgentListRequested;
    /** 在「Agent 列表」里点了一条 → 把它设为后续派活的目标（LastAgentPicked = '' 表示每次新建） */
    public event EventHandler AgentPickRequested;
    public event EventHandler AgentStartRequested;
    /** 用户说"我是醒着的"：立刻重新看一眼（待机卡住时的手动出口） */
    public event EventHandler WakeRequested;
    public event EventHandler ModelSelected;
    public event EventHandler AccessSelected;
    public event EventHandler MainSessionRequested;
    public event EventHandler ChatRequested;
    public event EventHandler PickRegionRequested;
    public event EventHandler ClearRegionRequested;
    public event EventHandler FontRequested;
    /** 要开「所有设置」窗口（settings-window.ps1，一个窗口改完 config.json） */
    public event EventHandler SettingsRequested;
    public event EventHandler PromptRequested;
    public event EventHandler StyleGuardRequested;
    public event EventHandler StyleCoachRequested;
    public event EventHandler OptionChosen;
    /** 长按开始（该开麦了） / 长按结束（该停止录音并识别了） */
    public event EventHandler LongPressStarted;
    public event EventHandler LongPressEnded;
    /** 菜单里点了「语音输入」（看状态 / 下模型） */
    public event EventHandler VoiceRequested;
    /** 要一个文字输入框（打字派活，和语音同一条管线） */
    public event EventHandler TypeRequested;
    /** 要填 API key（供应商表：DeepSeek / MiniMax / OpenAI） */
    public event EventHandler ApiKeyRequested;
    /** 右键菜单刚打开 —— 打开菜单本身就是"用户在场"的信号 */
    public event EventHandler MenuOpened;
    /** 待机状态变了（显示器开关 / 锁屏 / 睡眠唤醒）—— 外层据此进入/退出待机 */
    public event EventHandler StandbyChanged;

    // ---- 待机识别的三个原始信号（由窗口消息维护，外层只读）----
    /** 显示器是不是亮着（GUID_CONSOLE_DISPLAY_STATE） */
    public bool PowerDisplayOn = true;
    /** 会话是不是锁着（WTS_SESSION_LOCK / 解锁） */
    public bool SessionLocked = false;
    /** 系统是不是睡着了（PBT_APMSUSPEND / 唤醒） */
    public bool Suspended = false;
    IntPtr displayNotify = IntPtr.Zero;
    /** 待机信号注册成功没有（诊断用：注册失败就只剩"连续抓屏失败"那条兜底路） */
    public bool StandbyHooked = false;
    /** 用户点了第几个选项；-1 = 超时/取消 */
    public int LastOptionIndex = -1;
    public event EventHandler Dropped;
    public event EventHandler TtsChanged;
    public event EventHandler InterruptRequested;
    public event EventHandler ReplayRequested;
    /** 拖进来的内容：文件路径（换行分隔）与纯文本 */
    public string DroppedFiles = "";
    public string DroppedText = "";
    /** 设置菜单里刚选了哪一个（模型名 / 权限名） */
    public string LastSettingValue = "";
    ToolStripMenuItem settingsMenu;
    /** 「更多 ▸」子菜单：把低频项收进去，顶层菜单才不至于比屏幕还高 */
    ToolStripMenuItem moreMenu;
    /** 「更多」里静态项的数量：动态项从这之后追加，刷新时按这个下标裁掉重建。
     *  不用 List<> 是因为这个 Add-Type 没引用 System.Collections（实测编译不过）。 */
    int moreStaticCount = -1;
    /** 菜单开着时鼠标跑远的计时起点：用来"移开就自动关" */
    DateTime menuAwaySince = DateTime.MinValue;
    /** 上一次从菜单里选了哪个模型起 agent */
    public string LastAgentModel = "";
    ToolStripMenuItem agentMenu;
    /** 上一次「问一句」是怎么触发的：click / hotkey */
    public string LastAskSource = "";
    /** 今天"看过了但决定不说"的次数，画成宠物身上的小角标。 */
    public int SilentCount = 0;

    // ---- 长按 = 语音输入 ----
    // 为什么要长按而不是单击：单击已经给了「现在说一句」。语音是"我要说"
    // 而不是"你来说"，必须有个不会误触、也不需要记快捷键的入口。
    // 阈值可配（LongPressMs），按住期间不动才算长按 —— 一动就变成拖动。
    System.Windows.Forms.Timer pressTimer;
    DateTime pressAt;
    bool longPressFired;
    /** 长按判定阈值（毫秒）。低于这个时长的按住仍然算普通点击。 */
    public int LongPressMs = 400;
    /** 在「Agent 列表」里选中的那条 agent（'' = 每次新建） */
    public string LastAgentPicked = "";

    // 逻辑尺寸（96 DPI 下的像素），实际使用时会乘 uiScale
    readonly double uiScale;
    int S(int v) { return (int)Math.Round(v * uiScale); }
    int BubbleTop { get { return S(10); } }
    int BubblePadX { get { return S(13); } }
    int BubblePadY { get { return S(13); } }
    int PetW { get { return S(150); } }
    int PetH { get { return S(146); } }
    int Gap { get { return S(2); } }
    int BottomPad { get { return S(4); } }
    int BtnH { get { return S(26); } }
    int BtnW { get { return S(40); } }
    int BtnGap { get { return S(5); } }
    // 图标用 Windows 自带的图标字体（Segoe Fluent Icons / Segoe MDL2 Assets），零素材。
    // \uE8BD 消息气泡(问一句) · \uE8F2 对话 · \uE765 键盘(打字派活) · \uE7A8 裁剪(框选) · \uE81C 历史(记录)
    static readonly string[] BtnIcons = new string[] { "\uE8BD", "\uE8F2", "\uE765", "\uE7A8", "\uE81C" };
    static readonly string[] BtnLabels = new string[] { "问一句", "对话", "打字派活", "框选监控区域", "看它判过什么" };
    // 长度跟着 BtnIcons 走，别再写死数字（写死的话加按钮会下标越界）
    Rectangle[] buttonRects = new Rectangle[5];
    int hotButton = -1;
    // 待选选项（agent 提出的、等用户点的是/否）
    string[] pendingOptions;
    Rectangle[] optionRects;
    DateTime optionDeadline = DateTime.MinValue;
    int optionTotalSeconds = 0;
    int hotOption = -1;
    // 选项排版结果（由 ComputeOptionLayout 算出，BubbleRect / LayoutButtons / 高度三者共用同一份）
    int optionCols = 0;
    int optionRows = 0;
    int optionBtnW = 0;

    Font bubbleFont;
    /**
     * 气泡**最下方**那行小字：余额 / 上次调用花了多少。
     * 刻意比正文小一号、颜色更淡 —— 它是"顺便看一眼"的信息，不该抢正文的注意力。
     */
    public string Footer = "";
    /** 从外面设置页脚：变了才重排 + 重画（没变就不做，省一次 Render）。 */
    public void SetFooter(string text) {
      text = text ?? "";
      if (Footer == text) return;
      Footer = text;
      FitToBubble();
      Render();
    }
    Font FooterFont() { return new Font(bubbleFont.FontFamily, (float)(bubbleFont.Size * 0.78)); }
    int FooterH() {
      if (string.IsNullOrEmpty(Footer)) return 0;
      using (var f = FooterFont()) {
        var sz = TextRenderer.MeasureText(Footer, f, new Size(Math.Max(40, Width - 2 * BubblePadX - 20), 400), TextFormatFlags.WordBreak);
        return sz.Height + S(3);
      }
    }
    readonly ToolStripMenuItem autoItem;
    readonly ToolStripMenuItem ttsItem;
    /** 「朗读」子菜单（挂在「设置」下） */
    ToolStripMenuItem ttsMenu;
    /** 「更多 → Agent 列表」那个子菜单（派活给谁） */
    ToolStripMenuItem agentListMenu;
    readonly Timer anim;
    string message = "";
    DateTime messageUntil = DateTime.MinValue;
    string state = "idle";        // idle | thinking | speaking | silent
    int tick = 5;   // 从非眨眼帧开始，免得第一眼看到的是闭眼
    bool dragging;
    bool moved;
    bool suppressClick;   // 双击的第二次抬起不要再当成一次「问一句」
    Point dragAnchor;
    bool hover;
    /** 常驻气泡右上角的 × 是否被悬停（只为了画得亮一点） */
    bool closeHot;
    /** 上一次画出来的 × 位置：命中判断用它，保证"画在哪、点在哪"是同一个矩形 */
    Rectangle closeRect = Rectangle.Empty;
    Bitmap surface;
    Image petImage;   // 有现成角色图就画图，没有就退回代码画的小圆脸

    public bool AutoEnabled {
      get { return autoItem.Checked; }
      set { autoItem.Checked = value; }
    }
    /** 「自动发言」那一行的文案。周期来自 config.json，所以由外层填，别在窗体里写死。 */
    public string AutoItemText {
      get { return autoItem.Text; }
      set { autoItem.Text = value; }
    }

    /** 「出声朗读」开关（菜单里的勾）。true = 会朗读，false = 静音。 */
    public bool TtsEnabled {
      get { return ttsItem.Checked; }
      set { ttsItem.Checked = value; }
    }

    /** 诊断用：上一次 UpdateLayeredWindow 是否成功、Render 被调用过几次。 */
    public bool LastPushOk = false;
    public int RenderCount = 0;

    public PetForm(double uiScale, string fontFamily, double fontSize) {
      this.uiScale = uiScale <= 0 ? 1.0 : uiScale;
      bubbleFont = new Font(
        string.IsNullOrEmpty(fontFamily) ? "Microsoft YaHei UI" : fontFamily,
        (float)((fontSize > 3 ? fontSize : 9.5) * this.uiScale));
      FormBorderStyle = FormBorderStyle.None;
      ShowInTaskbar = false;
      TopMost = true;
      StartPosition = FormStartPosition.Manual;
      Size = new Size(S(320), S(250));
      DoubleBuffered = true;
      SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
               ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);

      // ---- 右键菜单：**刻意做小** ----
      // 之前是二十来项平铺（设置/更多/对话/框选/字体/风格/朗读/自动发言/记录…），
      // 200% 缩放下比屏幕还高，点完想关都费劲。现在顶层只有 7 行，其余全收进两个子菜单。
      // 关闭方式也补了三条：AutoClose（点菜单外）、点宠物本体、鼠标移开一会儿。
      var menu = new ContextMenuStrip();
      menu.AutoClose = true;
      menu.ShowImageMargin = false;    // 去掉左侧图标留白，窄一截
      menu.DropShadowEnabled = true;

      var ask = menu.Items.Add("现在说一句");
      ask.Click += (s, e) => Fire(AskRequested);
      var chatEntry = menu.Items.Add("对话");
      chatEntry.Click += (s, e) => Fire(ChatRequested);
      var voiceEntry = menu.Items.Add("语音输入（长按宠物说话）");
      voiceEntry.Click += (s, e) => Fire(VoiceRequested);
      var typeEntry = menu.Items.Add("打字派活（和说话同一条路）");
      typeEntry.Click += (s, e) => Fire(TypeRequested);
      menu.Items.Add(new ToolStripSeparator());

      moreMenu = new ToolStripMenuItem("更多");
      moreMenu.DropDownItems.Add(MakeMenuItem("看它判过什么", HistoryRequested));
      moreMenu.DropDownItems.Add(MakeMenuItem("收起气泡", CollapseRequested));
      moreMenu.DropDownItems.Add(new ToolStripSeparator());
      moreMenu.DropDownItems.Add(MakeMenuItem("框选监控区域…", PickRegionRequested));
      moreMenu.DropDownItems.Add(MakeMenuItem("取消监控区域", ClearRegionRequested));
      // 待机卡住时的手动出口：系统通知漏发会让它一直以为在待机，菜单点这一下就重新看一眼。
      moreMenu.DropDownItems.Add(MakeMenuItem("我是醒着的（现在就看一眼）", WakeRequested));
      menu.Items.Add(moreMenu);

      settingsMenu = new ToolStripMenuItem("设置");
      menu.Items.Add(settingsMenu);

      menu.Items.Add(new ToolStripSeparator());
      var quit = menu.Items.Add("退出");
      quit.Click += (s, e) => Application.Exit();
      ContextMenuStrip = menu;
      menu.Opening += (s, e) => Fire(MenuOpened);   // 开菜单 = 用户在场

      // 朗读 / 自动发言这两项先建出来（AutoEnabled / TtsEnabled 属性靠它们存状态），
      // 挂在「设置」下；SetSettings 刷新时会连同其它项一起重建。
      // 周期由配置决定（config.json 的 autoMinutes），所以文案不写死在这里 ——
      // 外层启动时会用 AutoItemText 把真实周期填进来（以前写死"每 5 分钟"，
      // 配置改成 1 分钟后菜单还在说 5 分钟，等于骗用户）。
      autoItem = new ToolStripMenuItem("自动发言");
      autoItem.CheckOnClick = true;
      autoItem.CheckedChanged += (s, e) => Fire(AutoChanged);
      settingsMenu.DropDownItems.Add(autoItem);
      // 朗读：出声 / 静音、立刻打断、重读上一句。双击宠物本体同样是「打断」。
      ttsMenu = new ToolStripMenuItem("朗读");
      ttsItem = new ToolStripMenuItem("出声朗读");
      ttsItem.CheckOnClick = true;
      ttsItem.Checked = true;          // 先设默认值再挂事件，免得启动时误触发一次
      ttsItem.CheckedChanged += (s, e) => Fire(TtsChanged);
      ttsMenu.DropDownItems.Add(ttsItem);
      ttsMenu.DropDownItems.Add(MakeMenuItem("停止朗读（打断）", InterruptRequested));
      ttsMenu.DropDownItems.Add(MakeMenuItem("重读上一句", ReplayRequested));
      settingsMenu.DropDownItems.Add(ttsMenu);

      AllowDrop = true;   // 拖文件/文字/网址到宠物身上

      // 长按判定：按住不动超过 LongPressMs 就开麦。用 60ms 的细粒度定时器，
      // 因为 90ms 的动画定时器抖动太大，会让人分不清"按住"和"点一下"。
      pressTimer = new Timer();
      pressTimer.Interval = 60;
      pressTimer.Tick += (s, e) => {
        if (!dragging || moved || longPressFired) return;
        if ((DateTime.Now - pressAt).TotalMilliseconds < LongPressMs) return;
        longPressFired = true;
        pressTimer.Stop();
        Fire(LongPressStarted);
      };

      anim = new Timer();
      anim.Interval = 90;
      anim.Tick += (s, e) => {
        // 自检 / 收摊时会先 Dispose 再泵消息，这时还可能有最后一拍到 —— 先停掉再走
        if (IsDisposed || Disposing) { try { anim.Stop(); } catch { } return; }
        tick++;
        // 菜单开着时鼠标跑远 → 自动关。小屏上菜单会盖住一大片，
        // 不该逼用户去精确点那块空白。子菜单通常紧贴主菜单，所以判定范围放宽了 250px。
        if (ContextMenuStrip != null && ContextMenuStrip.Visible) {
          var zone = ContextMenuStrip.Bounds;
          zone.Inflate(250, 250);
          if (!zone.Contains(Cursor.Position)) {
            if (menuAwaySince == DateTime.MinValue) menuAwaySince = DateTime.Now;
            else if ((DateTime.Now - menuAwaySince).TotalMilliseconds > 800) { ContextMenuStrip.Close(); menuAwaySince = DateTime.MinValue; }
          } else menuAwaySince = DateTime.MinValue;
        } else menuAwaySince = DateTime.MinValue;
        // 选项倒计时到点 → 自动取消（当作"没选"）
        if (OptionPending() && DateTime.Now > optionDeadline) {
          ClearOptions();
          LastOptionIndex = -1;
          message = ""; state = "idle";
          FitToBubble();
          Render();
          var h = OptionChosen; if (h != null) h(this, EventArgs.Empty);
          return;
        }
        if (message != "" && DateTime.Now > messageUntil) { message = ""; state = "idle"; }
        Render();
      };
      anim.Start();
    }

    void Fire(EventHandler handler) { if (handler != null) handler(this, EventArgs.Empty); }

    /** 造一个「点了就 Fire(handler)」的菜单项。菜单项多了以后，这样比逐条写事件干净。 */
    ToolStripMenuItem MakeMenuItem(string text, EventHandler handler) {
      var item = new ToolStripMenuItem(text);
      item.Click += (s, e) => Fire(handler);
      return item;
    }

    /// 由外层把「可选的模型名」灌进来，生成「新建 agent ▸ 模型」子菜单。
    public void SetAgentModels(string[] names) {
      // 只重建「更多」里动态的那几项。**不再往顶层插** —— 顶层越插越长正是之前的问题。
      if (moreStaticCount < 0) moreStaticCount = moreMenu.DropDownItems.Count;
      while (moreMenu.DropDownItems.Count > moreStaticCount) {
        var last = moreMenu.DropDownItems[moreMenu.DropDownItems.Count - 1];
        moreMenu.DropDownItems.RemoveAt(moreMenu.DropDownItems.Count - 1);
        last.Dispose();
      }
      agentMenu = null;
      if (names == null || names.Length == 0) return;

      moreMenu.DropDownItems.Add(new ToolStripSeparator());

      agentMenu = new ToolStripMenuItem("新建 agent");
      foreach (var name in names) {
        var item = new ToolStripMenuItem(name);
        string captured = name;
        item.Click += (s, e) => { LastAgentModel = captured; Fire(AgentStartRequested); };
        agentMenu.DropDownItems.Add(item);
      }
      moreMenu.DropDownItems.Add(agentMenu);
      // 「Agent 列表」现在是**子菜单**：点其中一条 = 之后的派活都交给它（接着它的会话跑）。
      // 内容由 SetAgentList 填 —— 每次菜单弹出前刷新一次，因为 agent 一直在变。
      agentListMenu = new ToolStripMenuItem("Agent 列表（派活给谁）");
      moreMenu.DropDownItems.Add(agentListMenu);
      SetAgentList(new string[0], new string[0], "");
    }

    /// 填「Agent 列表」子菜单。ids 为空 = 只剩「每次新建」那一条（原来的行为）。
    public void SetAgentList(string[] ids, string[] labels, string current) {
      if (agentListMenu == null) return;
      // 先搬到临时数组再清空 —— 直接边遍历边 Dispose/Clear 会报
      // "Collection was modified; enumeration operation may not execute"（实测踩过）
      var old = new System.Collections.ArrayList();
      foreach (ToolStripItem it in agentListMenu.DropDownItems) old.Add(it);
      agentListMenu.DropDownItems.Clear();
      foreach (ToolStripItem it in old) it.Dispose();

      var fresh = new ToolStripMenuItem("每次新建（默认）");
      fresh.Checked = string.IsNullOrEmpty(current);
      fresh.Click += (s, e) => { LastAgentPicked = ""; Fire(AgentPickRequested); };
      agentListMenu.DropDownItems.Add(fresh);

      if (ids != null && ids.Length > 0) {
        agentListMenu.DropDownItems.Add(new ToolStripSeparator());
        for (int i = 0; i < ids.Length; i++) {
          string label = (labels != null && i < labels.Length) ? labels[i] : ids[i];
          var item = new ToolStripMenuItem(label);
          item.Checked = (ids[i] == current);
          string captured = ids[i];
          item.Click += (s, e) => { LastAgentPicked = captured; Fire(AgentPickRequested); };
          agentListMenu.DropDownItems.Add(item);
        }
      }
      agentListMenu.DropDownItems.Add(new ToolStripSeparator());
      agentListMenu.DropDownItems.Add(MakeMenuItem("在气泡里看进度…", AgentListRequested));
    }

    /** 自检用：当前「Agent 列表」子菜单里有什么（[x] 前缀 = 当前派活目标，--- = 分隔线） */
    public string[] AgentMenuLabels() {
      if (agentListMenu == null) return new string[0];
      // 只能用 ArrayList：Add-Type 会把 System.Private.CoreLib 从引用集里剔除，
      // 泛型 List<> 编译不过（这条硬限制文件里别处也踩过）。
      var list = new System.Collections.ArrayList();
      foreach (ToolStripItem it in agentListMenu.DropDownItems) {
        if (it is ToolStripSeparator) { list.Add("---"); continue; }
        var mi = it as ToolStripMenuItem;
        list.Add((mi != null && mi.Checked ? "[x] " : "") + it.Text);
      }
      return (string[])list.ToArray(typeof(string));
    }

    /// 「设置」子菜单：主 agent 用哪个模型、工作 agent 用哪档权限。
    public void SetSettings(string[] models, string currentModel, string[] accesses, string currentAccess) {
      // 整段重建「设置」的内容（含朗读 / 自动发言 —— 它们是同一批 item 实例，
      // AutoEnabled / TtsEnabled 两个属性就靠这两个实例存状态，所以不能换新的）
      settingsMenu.DropDownItems.Clear();

      var modelMenu = new ToolStripMenuItem("主 agent 模型");
      foreach (var name in models) {
        var item = new ToolStripMenuItem(name);
        item.Checked = (name == currentModel);
        string captured = name;
        item.Click += (s, e) => { LastSettingValue = captured; Fire(ModelSelected); };
        modelMenu.DropDownItems.Add(item);
      }
      settingsMenu.DropDownItems.Add(modelMenu);

      var accessMenu = new ToolStripMenuItem("工作 agent 权限");
      foreach (var name in accesses) {
        var item = new ToolStripMenuItem(name);
        item.Checked = (name == currentAccess);
        string captured = name;
        item.Click += (s, e) => { LastSettingValue = captured; Fire(AccessSelected); };
        accessMenu.DropDownItems.Add(item);
      }
      settingsMenu.DropDownItems.Add(accessMenu);

      settingsMenu.DropDownItems.Add(new ToolStripSeparator());

      var styleMenu = new ToolStripMenuItem("说话风格");
      styleMenu.DropDownItems.Add(MakeMenuItem("保守（只在明显问题时说）", StyleGuardRequested));
      styleMenu.DropDownItems.Add(MakeMenuItem("陪练（每次都给建议）", StyleCoachRequested));
      settingsMenu.DropDownItems.Add(styleMenu);
      settingsMenu.DropDownItems.Add(ttsMenu);
      settingsMenu.DropDownItems.Add(autoItem);

      settingsMenu.DropDownItems.Add(new ToolStripSeparator());
      settingsMenu.DropDownItems.Add(MakeMenuItem("所有设置…（一个窗口改完）", SettingsRequested));
      settingsMenu.DropDownItems.Add(MakeMenuItem("字体字号…", FontRequested));
      settingsMenu.DropDownItems.Add(MakeMenuItem("改 system prompt…", PromptRequested));
      settingsMenu.DropDownItems.Add(MakeMenuItem("填 API key…", ApiKeyRequested));

      settingsMenu.DropDownItems.Add(new ToolStripSeparator());
      settingsMenu.DropDownItems.Add(MakeMenuItem("主 agent 会话", MainSessionRequested));
    }

    // ---- 拖拽：把文件 / 文字 / 网址丢到宠物身上 ----
    protected override void OnDragEnter(DragEventArgs e) {
      if (e.Data != null && (e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent(DataFormats.UnicodeText))) {
        e.Effect = DragDropEffects.Copy;
      }
      // 不调用 base：base 会把 Effect 改回 None，拖拽就失效了
    }

    protected override void OnDragOver(DragEventArgs e) {
      if (e.Data != null && (e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent(DataFormats.UnicodeText))) {
        e.Effect = DragDropEffects.Copy;
      }
    }

    protected override void OnDragDrop(DragEventArgs e) {
      DroppedFiles = "";
      DroppedText = "";
      if (e.Data != null) {
        if (e.Data.GetDataPresent(DataFormats.FileDrop)) {
          var items = e.Data.GetData(DataFormats.FileDrop) as string[];
          if (items != null && items.Length > 0) DroppedFiles = string.Join("\n", items);
        }
        if (e.Data.GetDataPresent(DataFormats.UnicodeText)) {
          var text = e.Data.GetData(DataFormats.UnicodeText) as string;
          if (!string.IsNullOrEmpty(text)) DroppedText = text;
        }
      }
      Fire(Dropped);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams {
      get {
        var cp = base.CreateParams;
        cp.ExStyle |= Native.WS_EX_NOACTIVATE | Native.WS_EX_LAYERED;   // 可点击但不抢焦点；逐像素 alpha
        return cp;
      }
    }

    protected override void OnHandleCreated(EventArgs e) {
      base.OnHandleCreated(e);
      Native.RegisterHotKey(Handle, 1, Native.MOD_CONTROL | Native.MOD_ALT, 0x47); // Ctrl+Alt+G
      Native.RegisterHotKey(Handle, 2, Native.MOD_CONTROL | Native.MOD_ALT, 0x54); // Ctrl+Alt+T 打字派活
      // 待机识别：会话通知（锁屏/解锁）+ 显示器电源通知（亮/灭/变暗）
      bool wtsOk = false;
      try { wtsOk = Native.WTSRegisterSessionNotification(Handle, Native.NOTIFY_FOR_THIS_SESSION); } catch { }
      try {
        var g = Native.GUID_CONSOLE_DISPLAY_STATE;
        displayNotify = Native.RegisterPowerSettingNotification(Handle, ref g, Native.DEVICE_NOTIFY_WINDOW_HANDLE);
      } catch { }
      StandbyHooked = wtsOk && displayNotify != IntPtr.Zero;
    }

    protected override void OnHandleDestroyed(EventArgs e) {
      Native.UnregisterHotKey(Handle, 1);
      Native.UnregisterHotKey(Handle, 2);
      try { Native.WTSUnRegisterSessionNotification(Handle); } catch { }
      try { if (displayNotify != IntPtr.Zero) Native.UnregisterPowerSettingNotification(displayNotify); } catch { }
      base.OnHandleDestroyed(e);
    }

    protected override void WndProc(ref Message m) {
      // 双击 = 打断（停朗读；正想着也一并取消）。单击仍是「问一句」。
      // 双击的消息顺序是 按下→抬起→双击→抬起，第二次「抬起」必须吞掉，
      // 否则刚打断完又会立刻问一句（等于打断无效）。
      if (m.Msg == Native.WM_LBUTTONDBLCLK) { suppressClick = true; Fire(InterruptRequested); return; }
      if (m.Msg == Native.WM_HOTKEY && m.WParam.ToInt32() == 1) { LastAskSource = "hotkey"; Fire(AskRequested); return; }
      if (m.Msg == Native.WM_HOTKEY && m.WParam.ToInt32() == 2) { Fire(TypeRequested); return; }
      // ---- 待机信号：只在真的变了的时候通知外层，避免无谓刷新 ----
      if (m.Msg == Native.WM_WTSSESSION_CHANGE) {
        int ev = m.WParam.ToInt32();
        bool before = SessionLocked;
        if (ev == Native.WTS_SESSION_LOCK || ev == Native.WTS_CONSOLE_DISCONNECT || ev == Native.WTS_REMOTE_DISCONNECT) SessionLocked = true;
        else if (ev == Native.WTS_SESSION_UNLOCK || ev == Native.WTS_CONSOLE_CONNECT || ev == Native.WTS_REMOTE_CONNECT) SessionLocked = false;
        if (before != SessionLocked) Fire(StandbyChanged);
        base.WndProc(ref m);
        return;
      }
      if (m.Msg == Native.WM_POWERBROADCAST) {
        int ev = m.WParam.ToInt32();
        if (ev == Native.PBT_APMSUSPEND) { Suspended = true; Fire(StandbyChanged); }
        else if (ev == Native.PBT_APMRESUMESUSPEND || ev == Native.PBT_APMRESUMEAUTOMATIC) { Suspended = false; Fire(StandbyChanged); }
        else if (ev == Native.PBT_POWERSETTINGCHANGE) {
          try {
            var s = (Native.POWERBROADCAST_SETTING)Marshal.PtrToStructure(m.LParam, typeof(Native.POWERBROADCAST_SETTING));
            if (s.PowerSetting == Native.GUID_CONSOLE_DISPLAY_STATE) {
              // 数据紧跟在 GUID 之后（偏移 16），不要用 Marshal.SizeOf —— x64 下那个结构有对齐补白
              int state = Marshal.ReadInt32(m.LParam, 16);
              bool on = (state == Native.DISPLAY_ON);
              if (on != PowerDisplayOn) { PowerDisplayOn = on; Fire(StandbyChanged); }
            }
          } catch { }
        }
        base.WndProc(ref m);
        return;
      }
      if (m.Msg == Native.WM_NCHITTEST) {
        base.WndProc(ref m);
        if ((int)m.Result == Native.HTCLIENT) {
          int lp = m.LParam.ToInt32();
          var hit = PointToClient(new Point((short)(lp & 0xFFFF), (short)((lp >> 16) & 0xFFFF)));
          bool solid = surface != null && hit.X >= 0 && hit.Y >= 0 && hit.X < surface.Width && hit.Y < surface.Height
                       && surface.GetPixel(hit.X, hit.Y).A >= 16;
          if (!solid) m.Result = (IntPtr)Native.HTTRANSPARENT;   // 透明处点击穿过，不挡下面窗口
        }
        return;
      }
      base.WndProc(ref m);
    }

    // ---- 鼠标：点击=提问，拖动=搬家 ----
    protected override void OnMouseDown(MouseEventArgs e) {
      if (e.Button == MouseButtons.Left) {
        dragging = true; moved = false; dragAnchor = e.Location;
        pressAt = DateTime.Now; longPressFired = false;
        pressTimer.Start();
      }
      base.OnMouseDown(e);
    }

    protected override void OnMouseMove(MouseEventArgs e) {
      int ho = -1;
      if (OptionPending()) for (int i = 0; i < optionRects.Length; i++) if (optionRects[i].Contains(e.Location)) { ho = i; break; }
      if (ho != hotOption) { hotOption = ho; Render(); }
      int hb = -1;
      for (int i = 0; i < buttonRects.Length; i++) if (buttonRects[i].Contains(e.Location)) { hb = i; break; }
      if (hb != hotButton) { hotButton = hb; Render(); }
      bool hc = CloseVisible() && CloseRect().Contains(e.Location);
      if (hc != closeHot) { closeHot = hc; Render(); }
      if (dragging) {
        if (Math.Abs(e.X - dragAnchor.X) > 3 || Math.Abs(e.Y - dragAnchor.Y) > 3) {
          moved = true;
          pressTimer.Stop();   // 一旦动了就是拖动，不再算长按
          var p = PointToScreen(e.Location);
          Location = new Point(p.X - dragAnchor.X, p.Y - dragAnchor.Y);
        }
      } else if (!hover) { hover = true; Render(); }
      base.OnMouseMove(e);
    }

    protected override void OnMouseUp(MouseEventArgs e) {
      if (e.Button == MouseButtons.Left) {
        dragging = false;
        pressTimer.Stop();
        if (suppressClick) { suppressClick = false; base.OnMouseUp(e); return; }
        // 长按过了：这一次抬起只表示"录音结束"，不能再当成点击去问一句
        if (longPressFired) { longPressFired = false; Fire(LongPressEnded); base.OnMouseUp(e); return; }
        // 菜单开着时点宠物本体 = 关掉菜单。比"去点别处的空白"顺手得多，
        // 顺便避免这一下被当成「现在说一句」（菜单还开着就被点掉会很懵）。
        if (ContextMenuStrip != null && ContextMenuStrip.Visible) { ContextMenuStrip.Close(); base.OnMouseUp(e); return; }
        if (moved) { Fire(Moved); }
        else {
          // 常驻气泡右上角的 ×：点它就是「收起气泡」，和右键菜单那条走同一个事件
          if (CloseVisible() && CloseRect().Contains(e.Location)) {
            ClearMessage();
            Fire(CollapseRequested);
            base.OnMouseUp(e);
            return;
          }
          // 有待选选项时，点的是选项
          if (OptionPending()) {
            for (int oi = 0; oi < optionRects.Length; oi++) {
              if (optionRects[oi].Contains(e.Location)) {
                LastOptionIndex = oi;
                ClearOptions(); message = ""; state = "idle"; FitToBubble(); Render();
                Fire(OptionChosen);
                base.OnMouseUp(e);
                return;
              }
            }
          }
          // 先看是不是点在底部按钮条上
          int hit = -1;
          for (int i = 0; i < buttonRects.Length; i++) if (buttonRects[i].Contains(e.Location)) { hit = i; break; }
          switch (hit) {
            case 0: LastAskSource = "button"; Fire(AskRequested); break;
            case 1: Fire(ChatRequested); break;
            case 2: Fire(TypeRequested); break;      // 打字派活：和长按说话同一条下游
            case 3: Fire(PickRegionRequested); break;
            case 4: Fire(HistoryRequested); break;
            default: LastAskSource = "click"; Fire(AskRequested); break;
          }
        }
      }
      base.OnMouseUp(e);
    }

    protected override void OnMouseLeave(EventArgs e) { hover = false; Render(); base.OnMouseLeave(e); }

    // ---- 对外接口 ----
    public void ShowMessage(string text, int seconds) {
      message = text ?? "";
      messageUntil = seconds > 0 ? DateTime.Now.AddSeconds(seconds) : DateTime.MaxValue;
      state = message.StartsWith("（") ? "silent" : "speaking";
      FitToBubble();
      Render();
    }

    public void SetThinking() {
      message = "";
      state = "thinking";
      Render();
    }

    /** 录音中：红晕 + 气泡里写"正在听…"。松开才停，所以这里不设自动消失时间。 */
    public void ShowListening(string text) {
      message = text ?? "";
      messageUntil = DateTime.MaxValue;
      state = "listening";
      FitToBubble();
      Render();
    }

    /**
     * 待机中：屏幕关了 / 锁屏了 / 系统睡了。
     * 用一个刻意"安静"的外观（暗灰蓝、光晕很淡、不跳），因为它现在本来就不该打扰你。
     */
    public void ShowSleeping(string text) {
      message = text ?? "";
      messageUntil = DateTime.MaxValue;
      state = "sleeping";
      FitToBubble();
      Render();
    }

    /** 边等边显示进度：状态是思考中（琥珀光晕），气泡里写它此刻在干什么。 */
    public void ShowThinking(string text) {
      // 优先级规则：气泡同一时刻只能有一个主人。
      // 提问/审批在等用户回答时，气泡归它 —— 进度播报不许盖掉问题文字。
      // 不挡的话会出现"正在想… 23s"配着「允许/拒绝/稍后」三个按钮（实测踩过）：
      // 问题每秒被盖一次，按钮却还在，用户根本看不到自己在回答什么。
      if (OptionPending()) return;
      message = text ?? "";
      messageUntil = DateTime.MaxValue;
      state = "thinking";
      FitToBubble();
      Render();
    }

    /** agent 提出选项：气泡下面渲染成可点按钮，带倒计时，到点自动取消。 */
    public void ShowPrompt(string text, string[] options, int seconds) {
      message = text ?? "";
      messageUntil = DateTime.MaxValue;
      pendingOptions = (options == null || options.Length == 0) ? null : options;
      optionRects = pendingOptions == null ? null : new Rectangle[pendingOptions.Length];
      optionDeadline = seconds > 0 ? DateTime.Now.AddSeconds(seconds) : DateTime.MaxValue;
      optionTotalSeconds = seconds > 0 ? seconds : 0;
      hotOption = -1;
      state = "speaking";
      FitToBubble();
      Render();
    }
    bool OptionPending() { return pendingOptions != null && pendingOptions.Length > 0; }
    int OptionRemaining() {
      if (!OptionPending() || optionDeadline == DateTime.MaxValue) return -1;
      int s = (int)Math.Ceiling((optionDeadline - DateTime.Now).TotalSeconds);
      return s < 0 ? 0 : s;
    }
    void ClearOptions() { pendingOptions = null; optionRects = null; hotOption = -1; }

    /// 有提问/审批正在等用户回答 —— 外层据此决定要不要让进度播报/收起让路。
    public bool PromptPending { get { return OptionPending(); } }
    /** 自检用：常驻气泡右上角那个 × 在哪儿（不显示时是空矩形）。 */
    public Rectangle CloseButtonRect { get { return CloseVisible() ? CloseRect() : Rectangle.Empty; } }

    /// 收起提问：文字和选项一起清掉。
    /// 只清文字会留下还能点的按钮（气泡没了按钮还在），所以必须走这里。
    public void CancelPrompt() {
      ClearOptions();
      message = "";
      state = "idle";
      FitToBubble();
      Render();
    }

    public void ClearMessage() {
      message = "";
      state = "idle";
      FitToBubble();
      Render();
    }

    /** 字体 / 字号由外面控制（设置菜单里改）。 */
    public void SetTextFont(string family, double size) {
      try {
        var f = new Font(string.IsNullOrEmpty(family) ? "Microsoft YaHei UI" : family,
                         (float)((size > 3 ? size : 9.5) * uiScale));
        if (bubbleFont != null) bubbleFont.Dispose();
        bubbleFont = f;
      } catch { }
      Render();
    }
    public string GetFontFamily() { return bubbleFont == null ? "Microsoft YaHei UI" : bubbleFont.FontFamily.Name; }
    public double GetFontSize() { return bubbleFont == null ? 9.5 : bubbleFont.Size / uiScale; }

    /// 加载角色图（PNG，带透明通道最好）。路径为空或读失败就退回代码绘制。
    public void SetImage(string path) {
      try {
        if (!string.IsNullOrEmpty(path) && File.Exists(path)) {
          using (var stream = File.OpenRead(path))
          using (var src = Image.FromStream(stream)) {
            var copy = new Bitmap(src);          // 复制一份，流可以关掉
            petImage = CropAlpha(copy) ?? copy;  // 裁掉四周透明留白，让"图片上边缘"就是"角色头顶"
          }
        }
      } catch {
        petImage = null;
      }
      Render();
    }

    /// 裁掉四周的透明留白。
    /// 为什么必须做：角色图是 610x610 的正方形，四周一大圈全透明。
    /// 不裁的话，气泡是贴着"图片框上边缘"放的，而角色头顶在更下面 —— 中间就空出一大块，
    /// 看着像气泡飘得太高（实测就是这个观感问题）。
    static Bitmap CropAlpha(Bitmap src) {
      if (src == null) return null;
      int w = src.Width, h = src.Height;
      int minX = w, minY = h, maxX = -1, maxY = -1;
      var rect = new Rectangle(0, 0, w, h);
      var data = src.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      try {
        int stride = data.Stride;
        var buf = new byte[stride * h];
        System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, buf.Length);
        for (int y = 0; y < h; y++) {
          int row = y * stride;
          for (int x = 0; x < w; x++) {
            if (buf[row + x * 4 + 3] > 8) {   // BGRA 里的 A
              if (x < minX) minX = x;
              if (x > maxX) maxX = x;
              if (y < minY) minY = y;
              if (y > maxY) maxY = y;
            }
          }
        }
      } finally {
        src.UnlockBits(data);
      }
      if (maxX < 0) return null;   // 整张全透明，别裁
      var box = new Rectangle(minX, minY, maxX - minX + 1, maxY - minY + 1);
      if (box.Width == w && box.Height == h) return src;
      return src.Clone(box, PixelFormat.Format32bppArgb);
    }

    public void PlaceBottomRight(int pad) {
      var wa = Screen.PrimaryScreen.WorkingArea;
      Location = new Point(wa.Right - Width - pad, wa.Bottom - Height - pad);
    }

    void FitToBubble() {
      int oldBottom = Top + Height;
      int baseHeight = S(250);
      int target = baseHeight;
      if (!string.IsNullOrEmpty(message)) {
        int textW = Width - 2 * BubblePadX - 20;
        var size = TextRenderer.MeasureText(message, bubbleFont, new Size(textW, 2000), TextFormatFlags.WordBreak);
        int need = BubbleTop + size.Height + FooterH() + 2 * BubblePadY + OptionExtraH() + Gap + PetH + BottomPad + BtnH + BtnGap + 6;
        target = Math.Max(baseHeight, need);
      }
      // 关键：必须双向调整。只允许变高会导致窗口回不去，气泡在上、宠物在下，中间空一大块（实测踩过）。
      if (target != Height) {
        Height = target;
        Top = oldBottom - Height;   // 底边固定，宠物本身不跳
      }
    }

    // ---- 自绘：渲染到 ARGB 位图，再推给分层窗口（这样边缘才是真 alpha，不会有色键紫边）----
    /// 释放时必须把两个定时器停掉。它们是 **WinForms 定时器**（靠窗口消息驱动），
    /// Dispose 之后消息队列里还压着的那一拍照样会到，然后对着已释放的窗体渲染 →
    /// ObjectDisposedException 弹"未处理异常"（实测：自检里一泵消息就中）。
    protected override void Dispose(bool disposing) {
      if (disposing) {
        try { if (anim != null) { anim.Stop(); anim.Dispose(); } } catch { }
        try { if (pressTimer != null) { pressTimer.Stop(); pressTimer.Dispose(); } } catch { }
      }
      base.Dispose(disposing);
    }

    protected override void OnPaint(PaintEventArgs e) { Render(); }

    public void Render() {
      // 窗体已经释放就直接返回。**必须挡这一下**：anim / pressTimer 是 WinForms 定时器，
      // 它们是**窗口消息**驱动的 —— Dispose 之后消息队列里可能还压着一拍 Tick，
      // 谁在这时候泵一下消息（DoEvents），就会对已释放的窗体 CreateHandle →
      // ObjectDisposedException 直接弹"未处理异常"对话框（实测在自检里踩到）。
      // 同一个原因也要求在 Dispose 里把定时器停掉，见下面的 Dispose 重写。
      if (IsDisposed || Disposing) return;
      RenderCount++;
      if (surface == null || surface.Width != Width || surface.Height != Height) {
        if (surface != null) surface.Dispose();
        surface = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
      }
      using (var g = Graphics.FromImage(surface)) {
        g.Clear(Color.Transparent);
        DrawAll(g);
      }
      Push();
    }

    void Push() {
      IntPtr screenDc = Native.GetDC(IntPtr.Zero);
      IntPtr memDc = Native.CreateCompatibleDC(screenDc);
      IntPtr hBitmap = IntPtr.Zero;
      IntPtr oldBitmap = IntPtr.Zero;
      try {
        hBitmap = surface.GetHbitmap(Color.FromArgb(0));
        oldBitmap = Native.SelectObject(memDc, hBitmap);
        var size = new Native.SIZE();
        size.cx = surface.Width;
        size.cy = surface.Height;
        var src = new Native.POINT();
        var blend = new Native.BLENDFUNCTION();
        blend.BlendOp = Native.AC_SRC_OVER;
        blend.BlendFlags = 0;
        blend.SourceConstantAlpha = 255;
        blend.AlphaFormat = Native.AC_SRC_ALPHA;
        LastPushOk = Native.UpdateLayeredWindow(Handle, screenDc, IntPtr.Zero, ref size, memDc, ref src, 0, ref blend, Native.ULW_ALPHA);
      } finally {
        if (hBitmap != IntPtr.Zero) {
          Native.SelectObject(memDc, oldBitmap);
          Native.DeleteObject(hBitmap);
        }
        Native.DeleteDC(memDc);
        Native.ReleaseDC(IntPtr.Zero, screenDc);
      }
    }

    /// 自检用：把当前渲染结果存成带 alpha 的 PNG —— 所见即分层窗口所得。
    public void SavePreview(string path) {
      using (var bmp = new Bitmap(Width, Height, PixelFormat.Format32bppArgb))
      using (var g = Graphics.FromImage(bmp)) {
        g.Clear(Color.Transparent);
        DrawAll(g);
        bmp.Save(path, ImageFormat.Png);
      }
    }

    void DrawAll(Graphics g) {
      g.SmoothingMode = SmoothingMode.AntiAlias;

      int px = (Width - PetW) / 2;
      int py = Height - PetH - BottomPad - BtnH - BtnGap;   // 底部让给按钮条
      LayoutButtons();

      // 有现成角色图：画图 + 状态光晕，然后收工（下面的代码绘制是备用方案）
      if (petImage != null) {
        int bob = (int)(Math.Sin(tick / 12.0) * 3);
        var slot = new Rectangle(px - 16, py + 2 + bob, PetW + 32, PetH - 2);
        var dest = FitInto(petImage.Width, petImage.Height, slot);
        // 气泡按**角色图的实际上边缘**定位（不是按槽位），否则会飘太高
        if (!string.IsNullOrEmpty(message)) DrawBubble(g, dest.X + dest.Width / 2, dest.Top);
        DrawGlow(g, slot);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.DrawImage(petImage, dest);
        DrawButtons(g);
        return;
      }

      if (!string.IsNullOrEmpty(message)) DrawBubble(g, px + PetW / 2, py);
      // 影子
      using (var shadow = new SolidBrush(Color.FromArgb(38, 0, 0, 0)))
        g.FillEllipse(shadow, px + 8, py + PetH - 12, PetW - 16, 14);

      Color body;
      switch (state) {
        case "thinking": body = Color.FromArgb(201, 138, 43); break;
        case "speaking": body = Color.FromArgb(47, 127, 208); break;
        case "silent":   body = Color.FromArgb(110, 110, 120); break;
        case "listening": body = Color.FromArgb(208, 74, 74); break;
        case "sleeping": body = Color.FromArgb(96, 104, 118); break;
        default:         body = Color.FromArgb(92, 107, 127); break;
      }
      if (hover && state == "idle") body = Color.FromArgb(112, 130, 152);

      int breathe = (int)(Math.Sin(tick / 12.0) * 2);
      var bodyRect = new Rectangle(px, py + 6 + breathe, PetW, PetH - 10 - breathe);

      using (var path = new GraphicsPath())
      {
        path.AddEllipse(bodyRect);
        using (var br = new LinearGradientBrush(bodyRect, Lighten(body, 0.18), body, 90f))
          g.FillPath(br, path);
      }

      // 高光
      using (var hi = new SolidBrush(Color.FromArgb(48, 255, 255, 255)))
        g.FillEllipse(hi, bodyRect.X + 17, bodyRect.Y + 13, 30, 19);

      // 两只小手（说话时会抬起来一点）
      int handLift = state == "speaking" ? 7 : 0;
      using (var hand = new SolidBrush(Lighten(body, 0.05)))
      {
        int hy = bodyRect.Y + bodyRect.Height - 42 - handLift;
        g.FillEllipse(hand, bodyRect.X - 3, hy, 20, 15);
        g.FillEllipse(hand, bodyRect.Right - 17, hy, 20, 15);
      }

      // 眼睛
      bool blink = (tick % 47) < 3;
      int eyeY = bodyRect.Y + (int)(bodyRect.Height * 0.40);
      int eyeDx = 17;
      int eyeR = 9;
      int cx = bodyRect.X + bodyRect.Width / 2;
      foreach (int dx in new int[] { -eyeDx, eyeDx }) {
        var eye = new Rectangle(cx + dx - eyeR / 2, eyeY - eyeR / 2, eyeR, eyeR);
        if (blink) {
          using (var pen = new Pen(Color.FromArgb(250, 250, 252), 2f))
            g.DrawLine(pen, eye.Left, eye.Top + eyeR / 2, eye.Right, eye.Top + eyeR / 2);
        } else {
          using (var w = new SolidBrush(Color.FromArgb(250, 250, 252))) g.FillEllipse(w, eye);
          int lookX = dragging ? 1 : (tick / 40) % 2 == 0 ? -1 : 1;
          var pupil = new Rectangle(eye.X + eyeR / 2 - 3 + lookX, eye.Y + eyeR / 2 - 3, 6, 6);
          using (var b = new SolidBrush(Color.FromArgb(28, 30, 38))) g.FillEllipse(b, pupil);
        }
      }

      // 嘴（说话时是张开的）
      int mouthY = bodyRect.Y + (int)(bodyRect.Height * 0.66);
      using (var pen = new Pen(Color.FromArgb(235, 238, 244), 2f))
      using (var path = new GraphicsPath()) {
        if (state == "speaking") {
          path.AddEllipse(cx - 6, mouthY - 2, 12, 9);
          using (var b = new SolidBrush(Color.FromArgb(235, 238, 244))) g.FillPath(b, path);
        } else if (state == "thinking" || state == "silent") {
          g.DrawLine(pen, cx - 6, mouthY + 2, cx + 6, mouthY + 2);
        } else {
          path.AddArc(cx - 9, mouthY - 5, 18, 14, 20, 140);
          g.DrawPath(pen, path);
        }
      }

      // 思考中的三个点
      if (state == "thinking") {
        for (int i = 0; i < 3; i++) {
          int r = 4 + ((tick / 3 + i) % 3);
          using (var b = new SolidBrush(Color.FromArgb(200, 250, 250, 252)))
            g.FillEllipse(b, cx + 34 + i * 12, bodyRect.Y - 4 - r / 2, r, r);
        }
      }

      // 说话时的小声波
      if (state == "speaking") {
        using (var pen = new Pen(Color.FromArgb(210, 47, 127, 208), 2f))
          for (int i = 1; i <= 2; i++)
            g.DrawArc(pen, bodyRect.Right - 6 + i * 5, bodyRect.Y + bodyRect.Height / 2 - 12 - i * 3, 16, 24 + i * 6, -60, 120);
      }

      DrawButtons(g);
    }

    /// 沉默计数角标：把「我看过了，但决定不说」变成一个看得见的数字。
    void DrawBadge(Graphics g, Rectangle anchor) {
      return;   // 角标已按用户要求移除，这里留个空实现保持兼容
    }

    /// 底部一排半透明按钮：常用功能的可见入口
    void LayoutButtons() {
      // 有待选选项时，这一排按钮让给选项（不再显示功能图标条）
      if (OptionPending()) {
        ComputeOptionLayout();
        int n = pendingOptions.Length;
        var br = BubbleRect();
        int totalH = optionRows * BtnH + (optionRows - 1) * optionGapY;
        int oy = br.Bottom - BubblePadY - totalH;   // 贴在气泡底边内侧
        for (int i = 0; i < n; i++) {
          int row = i / optionCols, col = i % optionCols;
          int inRow = Math.Min(optionCols, n - row * optionCols);
          int rowW = inRow * optionBtnW + (inRow - 1) * optionGapX;
          int ox = br.X + (br.Width - rowW) / 2;
          optionRects[i] = new Rectangle(ox + col * (optionBtnW + optionGapX), oy + row * (BtnH + optionGapY), optionBtnW, BtnH);
        }
        return;
      }
      int total = BtnIcons.Length * BtnW + (BtnIcons.Length - 1) * BtnGap;
      int x = (Width - total) / 2;
      int y = Height - BottomPad - BtnH;
      for (int i = 0; i < BtnIcons.Length; i++) buttonRects[i] = new Rectangle(x + i * (BtnW + BtnGap), y, BtnW, BtnH);
    }

    void DrawButtons(Graphics g) {
      // 有待选选项 → 画选项按钮 + 倒计时
      if (OptionPending()) {
        using (var f = new Font(bubbleFont.FontFamily, (float)(bubbleFont.Size * 0.95)))
        using (var t2 = new Font(bubbleFont.FontFamily, (float)(bubbleFont.Size * 0.8))) {
          for (int i = 0; i < pendingOptions.Length; i++) {
            var r = optionRects[i];
            if (r.Width <= 0) continue;
            bool hot = i == hotOption;
            using (var path = new GraphicsPath()) {
              int rad = r.Height;
              path.AddArc(r.X, r.Y, rad, rad, 90, 180);
              path.AddArc(r.Right - rad, r.Y, rad, rad, 270, 180);
              path.CloseFigure();
              using (var b = new SolidBrush(hot ? AccentForOption(i, true) : AccentForOption(i, false))) g.FillPath(b, path);
            }
            // NoPrefix：标签里可能有 & 。EndEllipsis 只在"单个标签比气泡还宽"时才会用上，
            // 正常路径下 PromptLogicalWidth 已经把窗口撑到放得下整句。
            TextRenderer.DrawText(g, pendingOptions[i], f, r, Color.White,
              TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
              TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis);
          }
          // 倒计时不用文字 —— 直接在第一个按钮的整圈边框上跑一条进度环。
          DrawOptionProgress(g);
        }
        return;
      }
      string iconFamily = "Segoe Fluent Icons";
      try {
        bool found = false;
        foreach (var fam in FontFamily.Families) { if (fam.Name == iconFamily) { found = true; break; } }
        if (!found) iconFamily = "Segoe MDL2 Assets";   // Win10 的回退字体
      } catch { iconFamily = "Segoe MDL2 Assets"; }
      using (var iconFont = new Font(iconFamily, (float)(10.5 * uiScale)))
      using (var tipFont = new Font(bubbleFont.FontFamily, (float)(bubbleFont.Size * 0.9)))
      using (var fill = new SolidBrush(Color.FromArgb(hotButton >= 0 ? 165 : 96, 250, 251, 253)))
      using (var line = new Pen(Color.FromArgb(90, 255, 255, 255), 1f)) {
        for (int i = 0; i < BtnIcons.Length; i++) {
          var r = buttonRects[i];
          if (r.Width <= 0) continue;
          using (var path = new GraphicsPath()) {
            int rad = r.Height;
            path.AddArc(r.X, r.Y, rad, rad, 90, 180);
            path.AddArc(r.Right - rad, r.Y, rad, rad, 270, 180);
            path.CloseFigure();
            g.FillPath(fill, path);
            g.DrawPath(line, path);
          }
          TextRenderer.DrawText(g, BtnIcons[i], iconFont, r,
            i == hotButton ? Color.FromArgb(255, 26, 30, 40) : Color.FromArgb(205, 26, 30, 40),
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        // 悬停时在按钮条上方浮一条深色提示，说明这个图标是什么
        if (hotButton >= 0) {
          var hr = buttonRects[hotButton];
          var sz = TextRenderer.MeasureText(BtnLabels[hotButton], tipFont);
          int tw = sz.Width + S(16), th = S(22);
          int tx = Math.Max(S(4), Math.Min(hr.X + hr.Width / 2 - tw / 2, Width - tw - S(4)));
          int ty = hr.Y - th - S(4);
          using (var path = new GraphicsPath()) {
            int rad = S(11);
            var tr = new Rectangle(tx, ty, tw, th);
            path.AddArc(tr.X, tr.Y, rad * 2, th, 90, 180);
            path.AddArc(tr.Right - rad * 2, tr.Y, rad * 2, th, 270, 180);
            path.CloseFigure();
            using (var b = new SolidBrush(Color.FromArgb(235, 26, 30, 40))) g.FillPath(b, path);
          }
          TextRenderer.DrawText(g, BtnLabels[hotButton], tipFont, new Rectangle(tx, ty, tw, th), Color.FromArgb(250, 250, 252),
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
      }
    }

    /// 剩余比例 0..1：按毫秒算，进度环才会连续缩短，而不是一秒跳一格。
    double OptionFrac() {
      if (!OptionPending() || optionTotalSeconds <= 0 || optionDeadline == DateTime.MaxValue) return 1.0;
      double f = (optionDeadline - DateTime.Now).TotalSeconds / optionTotalSeconds;
      return f < 0 ? 0 : (f > 1 ? 1 : f);
    }

    static double Dist(PointF a, PointF b) { double dx = a.X - b.X, dy = a.Y - b.Y; return Math.Sqrt(dx * dx + dy * dy); }

    /// 倒计时可视化：不在气泡里写"X 秒后自动取消"，而是在第一个按钮的整圈边框上
    /// 跑一条进度环 —— 先垫一圈暗轨（表示总时长），再用白环表示剩余时间，越少越短。
    void DrawOptionProgress(Graphics g) {
      if (!OptionPending() || optionTotalSeconds <= 0 || optionDeadline == DateTime.MaxValue) return;
      var r = optionRects[0];
      if (r.Width <= 0) return;
      double frac = OptionFrac();
      int inset = Math.Max(1, S(2));
      var rr = Rectangle.Inflate(r, -inset, -inset);
      if (rr.Width <= 4 || rr.Height <= 4) return;
      float w = Math.Max(2f, S(3));
      using (var path = new GraphicsPath()) {
        int rad = rr.Height;
        path.AddArc(rr.X, rr.Y, rad, rad, 90, 180);
        path.AddArc(rr.Right - rad, rr.Y, rad, rad, 270, 180);
        path.CloseFigure();
        using (var track = new Pen(Color.FromArgb(70, 20, 26, 38), w)) g.DrawPath(track, path);
        if (frac <= 0.001) return;
        using (var flat = (GraphicsPath)path.Clone()) {
          flat.Flatten(null, 0.25f);
          var pts = flat.PathPoints;
          if (pts.Length < 2) return;
          // 从左上角起算（否则会从左半边开始跑，看着别扭）
          float topX = rr.X + rad / 2f, topY = rr.Y;
          int start = 0; double best = double.MaxValue;
          for (int i = 0; i < pts.Length; i++) {
            double dx = pts[i].X - topX, dy = pts[i].Y - topY;
            double d = dx * dx + dy * dy;
            if (d < best) { best = d; start = i; }
          }
          var ring = new PointF[pts.Length + 1];
          for (int i = 0; i < pts.Length; i++) ring[i] = pts[(start + i) % pts.Length];
          ring[pts.Length] = ring[0];   // 闭合：否则底部那条直边不计长度，整圈会缺口
          double total = 0;
          for (int i = 0; i < ring.Length - 1; i++) total += Dist(ring[i], ring[i + 1]);
          if (total <= 0) return;
          double want = total * frac, acc = 0;
          var seg = new System.Collections.ArrayList();
          seg.Add(ring[0]);
          for (int i = 0; i < ring.Length - 1; i++) {
            double L = Dist(ring[i], ring[i + 1]);
            if (acc + L <= want) { seg.Add(ring[i + 1]); acc += L; }
            else {
              double t = L > 0 ? (want - acc) / L : 0;
              seg.Add(new PointF((float)(ring[i].X + (ring[i + 1].X - ring[i].X) * t),
                                 (float)(ring[i].Y + (ring[i + 1].Y - ring[i].Y) * t)));
              break;
            }
          }
          if (seg.Count < 2) return;
          using (var bright = new Pen(Color.White, w)) {
            bright.StartCap = LineCap.Round; bright.EndCap = LineCap.Round; bright.LineJoin = LineJoin.Round;
            g.DrawLines(bright, (PointF[])seg.ToArray(typeof(PointF)));
          }
        }
      }
    }

    Color AccentForOption(int i, bool hot) {
      // 第一个选项按"肯定"上色，其余按中性；避免全是蓝色让人看不出主次
      int a = hot ? 255 : 205;
      if (i == 0) return Color.FromArgb(a, 47, 127, 208);
      return Color.FromArgb(a, 120, 128, 142);
    }
    void DrawBadgeOld(Graphics g, Rectangle anchor) {
      if (SilentCount <= 0) return;
      string badge = SilentCount > 99 ? "99+" : SilentCount.ToString();
      using (var f = new Font("Microsoft YaHei UI", (float)(8.0 * uiScale), FontStyle.Bold)) {
        var sz = TextRenderer.MeasureText(badge, f);
        // 注意：尺寸也要乘 uiScale —— 只缩放字体、不缩放胶囊，字就会撑破它（实测踩过）
        int bh = S(18);
        int bw = Math.Max(S(20), sz.Width + S(10));
        int bx = Math.Min(anchor.Right - bw + 6, Width - bw - 2);
        int by = Math.Max(2, anchor.Y - 2);
        var rect = new Rectangle(bx, by, bw, bh);
        using (var path = new GraphicsPath()) {
          int r = bh;
          path.AddArc(rect.X, rect.Y, r, r, 90, 180);
          path.AddArc(rect.Right - r, rect.Y, r, r, 270, 180);
          path.CloseFigure();
          using (var b = new SolidBrush(Color.FromArgb(170, 120, 124, 150))) g.FillPath(b, path);
        }
        TextRenderer.DrawText(g, badge, f, rect, Color.White,
          TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
      }
    }

    /// 状态光晕：图不能换色，就用背后一圈柔光表达 idle / thinking / speaking / silent
    void DrawGlow(Graphics g, Rectangle slot) {
      Color c;
      switch (state) {
        case "thinking": c = Color.FromArgb(150, 201, 138, 43); break;
        case "speaking": c = Color.FromArgb(150, 47, 127, 208); break;
        case "silent":   c = Color.FromArgb(110, 120, 124, 150); break;
        case "listening": c = Color.FromArgb(170, 226, 74, 74); break;
        case "sleeping": c = Color.FromArgb(60, 120, 130, 150); break;
        default:         c = Color.FromArgb(hover ? 90 : 0, 120, 160, 220); break;
      }
      if (c.A == 0) return;
      int grow = state == "thinking" ? 4 + (tick / 6) % 3
               : state == "listening" ? 3 + (tick / 4) % 4 : 2;
      var glow = new Rectangle(slot.X - grow, slot.Y - grow, slot.Width + grow * 2, slot.Height + grow * 2);
      using (var path = new GraphicsPath()) {
        path.AddEllipse(glow);
        using (var brush = new PathGradientBrush(path)) {
          brush.CenterColor = c;
          brush.SurroundColors = new Color[] { Color.FromArgb(0, c) };
          g.FillPath(brush, path);
        }
      }
    }

    /// 等比缩放并居中放进目标矩形
    static Rectangle FitInto(int srcW, int srcH, Rectangle slot) {
      double scale = Math.Min(slot.Width / (double)srcW, slot.Height / (double)srcH);
      int w = Math.Max(1, (int)Math.Round(srcW * scale));
      int h = Math.Max(1, (int)Math.Round(srcH * scale));
      return new Rectangle(slot.X + (slot.Width - w) / 2, slot.Bottom - h, w, h);
    }

    void DrawBubble(Graphics g, int tailX, int petTop) {
      // 高度统一交给 BubbleRect 算：有选项时它会多留一行，把按钮装进气泡里。
      var rect = BubbleRect();
      int textH = rect.Height - 2 * BubblePadY - OptionExtraH();
      // textH 现在含页脚高度；正文要按"减去页脚"来画，不然页脚会被挤到气泡外面
      int msgH = Math.Max(1, textH - FooterH());
      var tail = new Point(Math.Max(rect.Left + 26, Math.Min(tailX, rect.Right - 26)), petTop - Gap + 2);

      using (var path = new GraphicsPath()) {
        int r = 14;
        path.AddArc(rect.X, rect.Y, r, r, 180, 90);
        path.AddArc(rect.Right - r, rect.Y, r, r, 270, 90);
        path.AddArc(rect.Right - r, rect.Bottom - r, r, r, 0, 90);
        path.AddArc(rect.X, rect.Bottom - r, r, r, 90, 90);
        path.CloseFigure();
        // 小尾巴
        path.AddPolygon(new Point[] {
          new Point(tail.X - 9, rect.Bottom - 2),
          new Point(tail.X + 9, rect.Bottom - 2),
          new Point(tail.X, tail.Y)
        });
        using (var fill = new SolidBrush(Color.FromArgb(250, 251, 253))) g.FillPath(fill, path);
        using (var pen = new Pen(Color.FromArgb(212, 219, 230), 1.4f)) g.DrawPath(pen, path);
      }

      TextRenderer.DrawText(
        g, message, bubbleFont,
        new Rectangle(rect.X + 10, rect.Y + BubblePadY, rect.Width - 20 - CloseReserveW(), msgH),
        Color.FromArgb(31, 35, 42),
        TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
      // 最下方那行小字：余额 / 上次调用花了多少。比正文小一号、颜色更淡。
      if (!string.IsNullOrEmpty(Footer)) {
        using (var ff = FooterFont())
          TextRenderer.DrawText(
            g, Footer, ff,
            new Rectangle(rect.X + 10, rect.Y + BubblePadY + msgH + S(3), rect.Width - 20, Math.Max(1, textH - msgH)),
            Color.FromArgb(140, 148, 162),
            TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
      }
      // 常驻气泡的 ×（画在最后，保证不被文字盖住）
      if (CloseVisible()) {
        closeRect = CloseRect();
        using (var b = new SolidBrush(Color.FromArgb(closeHot ? 48 : 18, 20, 26, 38))) g.FillEllipse(b, closeRect);
        using (var p = new Pen(Color.FromArgb(closeHot ? 205 : 135, 62, 72, 88), Math.Max(1.5f, (float)S(2)))) {
          int m = S(6);
          g.DrawLine(p, closeRect.Left + m, closeRect.Top + m, closeRect.Right - m - 1, closeRect.Bottom - m - 1);
          g.DrawLine(p, closeRect.Right - m - 1, closeRect.Top + m, closeRect.Left + m, closeRect.Bottom - m - 1);
        }
      } else {
        closeRect = Rectangle.Empty;
      }
    }

    /// 有选项时气泡要多留的高度（几行按钮 + 行间距）；没有选项就是 0。
    int OptionExtraH() {
      if (!OptionPending()) return 0;
      ComputeOptionLayout();
      return optionRows * BtnH + (optionRows - 1) * optionGapY + S(6);
    }

    // ---- 常驻气泡的关闭按钮 ----
    // 卡片（「看它判过什么」）这类消息没有自动消失时间，以前只能右键 →「收起气泡」。
    // 现在在这类气泡的右上角画一个 ×：点它就是收起，和菜单那条走同一个事件。
    bool CloseVisible() {
      if (OptionPending() || string.IsNullOrEmpty(message)) return false;
      if (messageUntil != DateTime.MaxValue) return false;    // 会自动消失的气泡不用 ×，免得挡字
      return state == "speaking" || state == "silent";        // 排除 thinking / listening 这些过渡态
    }

    Rectangle CloseRect() {
      var r = BubbleRect();
      int d = S(18);
      return new Rectangle(r.Right - d - S(9), r.Y + S(8), d, d);
    }

    /// × 要占掉的正文宽度（按钮本身 + 一点间距）；不显示时返回 0
    int CloseReserveW() { return CloseVisible() ? S(18) + S(12) : 0; }

    /// 气泡矩形：DrawBubble 和 LayoutButtons 共用，保证按钮正好落在气泡内部。
    Rectangle BubbleRect() {
      int textW = Width - 2 * BubblePadX - 20 - CloseReserveW();
      int textH = 0;
      if (!string.IsNullOrEmpty(message)) {
        var measured = TextRenderer.MeasureText(message, bubbleFont, new Size(textW, 2000), TextFormatFlags.WordBreak);
        textH = measured.Height;
      }
      if (textH <= 0) textH = bubbleFont.Height;
      return new Rectangle(BubblePadX, BubbleTop, Width - 2 * BubblePadX, textH + FooterH() + 2 * BubblePadY + OptionExtraH());
    }

    /// 选项按钮宽度：按文字自适应，短词（"好"/"不用"）就不会被撑成一条大胶囊。
    int OptionBtnWidth() {
      int maxW = S(52);
      try {
        using (var f = new Font(bubbleFont.FontFamily, (float)(bubbleFont.Size * 0.95))) {
          foreach (var o in pendingOptions) {
            if (string.IsNullOrEmpty(o)) continue;
            var sz = TextRenderer.MeasureText(o, f);
            if (sz.Width + S(24) > maxW) maxW = sz.Width + S(24);
          }
        }
      } catch { }
      return maxW;
    }

    // ---- 选项按钮排版 ----
    // 老做法是"一行平铺、每个按钮都取最长标签的宽度"。DSH 的 ask_user_question 动不动给
    // 四个整句标签（"继续读完 README 并给你中文解读（推荐）"这种），一行的总宽轻松超过窗口，
    // 结果按钮画到窗口外面、右边的字被直接切掉（实测踩过）。
    // 现在改成：能一行放下就一行；放不下就按"每行最多能完整放下几个"折行，标签本身超宽才省略。
    int optionGapX { get { return S(8); } }
    int optionGapY { get { return S(6); } }
    /// 选项可用的内宽：气泡内缩一点，保证胶囊不会顶到气泡边框上。
    int optionInnerW {
      get {
        int w = Width - 2 * BubblePadX - 2 * S(10);
        return w < S(60) ? S(60) : w;
      }
    }

    void ComputeOptionLayout() {
      optionCols = 0; optionRows = 0; optionBtnW = 0;
      if (!OptionPending()) return;
      int n = pendingOptions.Length;
      int avail = optionInnerW;
      int ideal = OptionBtnWidth();
      int cols = (avail + optionGapX) / (ideal + optionGapX);
      if (cols < 1) cols = 1;
      if (cols > n) cols = n;
      optionBtnW = Math.Min(ideal, avail);
      optionCols = cols;
      optionRows = (n + cols - 1) / cols;
    }

    /// 外层（PowerShell）用：这组选项最少需要多宽的逻辑窗口，才能既不折行也不省略。
    /// 返回逻辑宽度（调用方按 UiScale 再乘）。只用来"能撑开就撑开"，撑不开时上面的排版会兜住。
    public double PromptLogicalWidth(string[] options) {
      int widest = 0;
      try {
        using (var f = new Font(bubbleFont.FontFamily, (float)(bubbleFont.Size * 0.95))) {
          if (options != null) {
            foreach (var o in options) {
              if (string.IsNullOrEmpty(o)) continue;
              var sz = TextRenderer.MeasureText(o, f);
              if (sz.Width > widest) widest = sz.Width;
            }
          }
        }
      } catch { }
      int need = widest + S(24) + 2 * BubblePadX + 2 * S(10) + S(6);
      return need / uiScale;
    }

    static Color Lighten(Color c, double amount) {
      return Color.FromArgb(
        c.A,
        Math.Min(255, (int)(c.R + (255 - c.R) * amount)),
        Math.Min(255, (int)(c.G + (255 - c.G) * amount)),
        Math.Min(255, (int)(c.B + (255 - c.B) * amount)));
    }
  }
}
'@ -ReferencedAssemblies $refs
}

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
$defaults = [ordered]@{
  sampleSeconds         = 2
  screenshotSeconds     = 5
  maxScreenshots        = 6
  screenshotMaxWidth    = 1024
  jpegQuality           = 60
  showSeconds           = 14
  timelineSize          = 40
  advisor               = ''
  advisorFast           = ''
  advisorTimeoutSeconds = 30
  warmupOnStart         = $true
  autoMinutes           = 5
  petImage              = ''
  region                = $null
  fontFamily            = 'Microsoft YaHei UI'
  fontSize              = 9.5
  speakStyle            = 'guard'
  ttsEnabled            = $true    # 是否朗读（菜单里的「出声朗读」，运行时可切，静音状态存在 pet.json）
  ttsEngine             = 'auto'   # auto | edge | speech。auto = 有 Edge 就用 Edge，否则退回本机音色
  ttsVoice              = ''       # 留空 = Edge 用默认可爱音色 / 本机用自动挑的中文音色
  ttsEdgeRate           = '+6%'    # Edge 语速（稍快显活泼）
  ttsEdgePitch          = '+12Hz'  # Edge 音高（略抬高显可爱）
  ttsEdgeVolume         = '+0%'
  ttsPython             = ''       # 留空 = 自动用 .tts\venv\Scripts\python.exe
  ttsRate               = 0        # -10..10，0 是正常语速
  ttsVolume             = 100      # 0..100
  ttsMaxChars           = 180      # 一句话最多读多少字，超了就在标点处截断
  ttsSkipStatus         = $true    # 「你在做：…」这类"我看见你了"的话不读
  # 语音输入（STT）：长按宠物说话。引擎是 DSH 自带的 sherpa-onnx + SenseVoice（本机、离线）
  sttEnabled            = $true
  sttLongPressMs        = 400      # 按住多久算"长按"（低于它仍然是普通点击）
  sttMaxSeconds         = 20       # 一次最多录多久，到点自动停止去识别
  sttMinSeconds         = 0.4      # 比这还短当作没说话
  sttLanguage           = 'auto'   # SenseVoice 语言提示：auto / zh / en / yue / ja / ko
  sttSampleRate         = 44100    # 录音采样率（识别前统一重采样到 16k）
  sttDevice             = -1       # -1 = 系统默认输入设备；换设备就填 MicRec 列出的序号
  sttModelDir           = ''       # 留空 = .stt\model
  sttNode               = ''       # 留空 = 自动找（DSH 自带运行时 → PATH）
  sttSherpaDir          = ''       # 留空 = .stt\sherpa\sherpa-onnx-node
  # 桌面应答器：DSH 要问人时（审批 / 提问 / 计划评审），气泡按钮等多久算放弃
  askSeconds            = 45
  # 对话界面：dsh = 直接开 DSH 自己的 Web 界面（推荐）；bubbles = 老的/自绘气泡栏
  chatUi                = 'dsh'
  webPort               = 4319
  webWindowWidth        = 560
  webWindowHeight       = 780
  webEdge               = ''
  # 语音派出去的任务用哪个模型 / 推理强度（留空 = 用 agents.json 里配的）
  petTaskModel          = ''
  petTaskEffort         = 'low'
  # 用户操作优先：用户动手时自动判断让位；停手这么多秒之后再把欠下的那次补上
  userQuietSeconds      = 6
  # 观察派出去的 agent（后台任务）：跑的时候把"它此刻在干什么"显示出来，并告诉主 agent
  observeAgents         = $true
  # 待机（黑屏/锁屏/睡眠）：连续抓不到屏幕几次就自己进待机；待机中每隔多久试探一次能否恢复
  captureFailLimit      = 3
  standbyProbeSeconds   = 30
  # 本地闸门：值不值得为这一轮起一次模型调用（省的是"起进程+带截图的一次模型调用"）
  judgeMinSeconds       = 60    # 两次判断之间至少隔多久（秒）
  judgeMinFpDelta       = 12    # 画面指纹差异小于它就当作"没变"（0..960）
  silentBackoffMax      = 4     # 连续"它决定不说"时，间隔最多放宽到几倍
  judgeIdleSkipSeconds  = 600   # 人多久没键鼠输入 + 窗口没换 → 别打扰
  judgeMaxGapSeconds    = 300   # 保险丝：不管画面多静，隔这么久也要看一眼（防止闸门把桌宠饿死）
  # 学习出来的采样率会被夹在这个区间里（防止学出 0.05 秒把机器烧了）
  minSampleSeconds      = 0.3
  maxSampleSeconds      = 60
  # 前台窗口看门狗的轮询间隔（毫秒）。注意这**不是**屏幕采样率本身，只是"多久发现一次换窗口"：
  # 越小，切过去的一瞬间越早被看见（游戏开局那种立刻要建议的场景）。开销是一次
  # GetForegroundWindow + 数值比较，测不出占用。默认 400。
  focusWatchMs          = 400
  # 定时播报余额（分钟；0 = 不播）。余额/上次调用/今天的数字另外**一直**显示在气泡最下方那行小字里。
  balanceBroadcastMinutes = 30
  # 两次采样之间画面指纹跳变超过这个值就算"漏掉了东西"（指纹总差上限 960）
  jumpDeltaThreshold    = 200
  # 语音录音（run\mic\mic-*.wav）最多留几个；每句 200–300KB，不删会一直涨
  micKeepFiles          = 20
  # 常驻大脑：一个进程持有 DSH 运行时，派任务时不再每轮起新进程（见 brain-sdk.ps1）
  brainTransport        = $true
  brainEffort           = 'low'
  brainSessionId        = 'pet-brain'
  # 任务规则表：决定"多久看一眼"和"这类任务该怎么帮"。
  # 为什么用规则表而不是问模型：判据（进程名/窗口标题）完全确定，写成可编辑的表比模型可靠、
  # 便宜、还能离线单测。hint 会**提前**写进提示词 —— 这就是"对这类任务提前给出工作建议"。
  logMinSeconds         = 2
  taskRules             = @(
    @{ name = '卡牌/回合制游戏'
      process = @('balatro', 'slay', 'sts', 'hearthstone', 'legends of runeterra', 'mtga', 'yugioh')
      sampleSeconds = 0.6; screenshotSeconds = 1.5; judgeMinSeconds = 20
      hint = '这是卡牌/回合制游戏。优先判断：当前手牌能凑出的牌型/连招、这一回合的最优出牌顺序、以及资源（费用、血量、手牌数）的风险；其次才是泛泛的"要不要小心"。不要复述界面上已有的数字。'
    }
    @{ name = '视频/播放'
      process = @('vlc', 'potplayer', 'mpv', 'mpc-hc', 'bilibili', 'youtube', 'iqiyi', 'netflix')
      title = @(' - VLC', 'YouTube', '哔哩哔哩')
      sampleSeconds = 8; screenshotSeconds = 20; judgeMinSeconds = 180
      hint = '这是视频/音频播放场景。除非画面里出现可证明的问题（报错、卡住、下错片源），否则保持沉默 —— 看片时被打断的代价很高。'
    }
    @{ name = '桌面/空闲'
      process = @('explorer', 'progman', 'workerw', 'searchhost')
      sampleSeconds = 10; screenshotSeconds = 30; judgeMinSeconds = 300
      hint = ''
    }
  )
}

$cfg = [ordered]@{}
foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }
if (Test-Path $Config) {
  $loaded = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($p in $loaded.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
} else {
  ($cfg | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Config -Encoding UTF8
}

$runDir = Join-Path $PSScriptRoot 'run'
$logDir = Join-Path $PSScriptRoot 'logs'
foreach ($d in @($runDir, $logDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
$payloadPath = Join-Path $runDir 'payload.json'
$advisorOut = Join-Path $runDir 'advisor.out.txt'
$advisorErr = Join-Path $runDir 'advisor.err.txt'
$petStatePath = Join-Path $runDir 'pet.json'
$logPath = Join-Path $logDir ("observe-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))

# 气泡是自绘纯文本控件，不编译 Markdown —— 进气泡之前先把它压成纯文本。
# （要么渲染、要么不渲染，这里选「不渲染」；理由写在 md-plain.ps1 头部。）
. (Join-Path $PSScriptRoot 'md-plain.ps1')
# 朗读（TTS）：只读「结论句」，双击桌宠可打断。所有状态都在 tts.ps1 里。
. (Join-Path $PSScriptRoot 'tts.ps1')
# 账本（充值播报）：自己查余额、自己记账，不依赖任何别的插件。见 ledger.ps1 头部。
. (Join-Path $PSScriptRoot 'ledger.ps1')
# 设置窗口：schema 驱动的图形界面，一个窗口改完 config.json 里的每个参数。见 settings-window.ps1 头部。
. (Join-Path $PSScriptRoot 'settings-window.ps1')

# ---------------------------------------------------------------------------
# 采集
# ---------------------------------------------------------------------------
$script:timeline = New-Object System.Collections.ArrayList
$script:shots = New-Object System.Collections.ArrayList
$script:currentKey = ''
$script:currentSince = Get-Date
$script:lastShotAt = [datetime]::MinValue
$script:advisorProc = $null
$script:lastUserAt = [datetime]::MinValue   # 用户最后一次动桌宠的时间（点击/长按/拖/菜单/选项…）
# 「派活给谁」：'' = 每次新建（默认）；否则是 agent 列表里选中的那条 ——
# 之后的语音 / 打字 / 拖文件派活都更新在这条记录上，并且接着它的会话跑（见 Start-PetTask）。
# 存在 run\pet.json 的 dispatchAgent 字段里，重启后还在。
$script:dispatchAgent = ''
$script:pendingAutoResume = $false          # 自动判断被用户打断过 → 等用户停手后再补一次
$script:thinking = $false
$script:suppressShow = $false
$script:autoAsk = $false
$script:history = New-Object System.Collections.ArrayList
$script:interactions = New-Object System.Collections.ArrayList
$script:advisorStarted = $null
$script:advisorT0 = $null
$script:lastStage = ''
$script:lastFp = ''
$script:stillSince = Get-Date
$script:lastJudgedFp = ''
$script:lastJudgedKey = ''                  # 上次判断时的前台窗口（判断"窗口换没换"）
$script:lastJudgedAt = [datetime]::MinValue # 上次**真的起了模型调用**的时间
$script:silentStreak = 0                    # 连续几次"它决定不说"——用来做退避
$script:judgeSkipped = 0                    # 本地闸门挡掉了多少次模型调用
$script:lastSkipReason = ''
$script:curProfile = $null          # 当前任务档（由 config.taskRules 判定）
$script:curTaskName = ''
$script:curTaskKey = ''
$script:appliedSampleMs = 0         # 上次**真正写进** $sampleTimer.Interval 的毫秒值（见 Sync-SampleCadence）
$script:lastObserveLogAt = [datetime]::MinValue
$script:silentTotal = 0   # 沉默总次数（从日志全量读出 + 运行时累加，不受内存缓冲上限影响）
$interactionPath = Join-Path $logDir 'interactions.jsonl'

function Add-Interaction {
  param([string]$Kind, [string]$Detail = '')
  $rec = [pscustomobject]@{ at = (Get-Date).ToString('o'); kind = $Kind; detail = $Detail; window = $script:currentKey }
  [void]$script:interactions.Add($rec)
  while ($script:interactions.Count -gt 200) { $script:interactions.RemoveAt(0) }
  try { Add-Content -LiteralPath $interactionPath -Encoding UTF8 -Value ($rec | ConvertTo-Json -Compress) } catch { }
}

function Load-Interactions {
  if (-not (Test-Path $interactionPath)) { return }
  foreach ($line in (Get-Content -LiteralPath $interactionPath -Encoding UTF8 | Select-Object -Last 200)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { [void]$script:interactions.Add(($line | ConvertFrom-Json)) } catch { }
  }
}

function Shorten-Text {
  param([string]$Text, [int]$Max = 34)
  $t = ($Text -replace '\s+', ' ').Trim()
  if ($t.Length -le $Max) { return $t }
  return $t.Substring(0, $Max - 1) + '…'
}

# 「它决定不说」的唯一判定口径。
#
# 为什么要抽出来：四个大脑对沉默的输出**文字不一致** ——
#   advisor-dsh.ps1 / advisor-minimax.ps1 写「（它选择没说）」
#   advisor-ollama.ps1 / advisor-openai.ps1 写「（它选择不说）」
# 老代码只匹配 '选择不说'，于是默认的 DSH 大脑（自动模式走的那条）**永远判不出沉默**：
# 退避（silentBackoffMax）不生效、沉默角标不涨、决策卡的沉默率恒偏低，
# 而且自动模式下还会把「（它选择没说）」当发言弹出来。
# 现在改成只看「（它选择」这个前缀族，文字怎么漂都不影响；四个大脑的输出也在源头统一成
# 「（它选择不说）」（见 advisor-dsh.ps1 / advisor-minimax.ps1）。
#
# 只认这一族，不认其它系统句（（大脑没有输出）/（它把监控范围调回整屏了）等）——
# 那些不是"决定不说"，不该进沉默统计。
$script:SILENT_PREFIX = '（它选择'
function Test-SilentText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  $t = $Text.Trim()
  # 大脑原样吐出哨兵词（还没来得及翻译）也算。
  # 允许前缀（SILENT / AMBIENT_SILENT / 任何 XXX_SILENT），免得别的插件换了哨兵词就漏判。
  if ($t -match '^\W*[A-Z_]*SILENT\W*$') { return $true }
  if ($t.StartsWith($script:SILENT_PREFIX)) { return $true }
  # 「你在做：xxx」= 看懂了但没给建议，同样算没说
  if ($t -match '^你在做[:：]') { return $true }
  return $false
}

# 判断记录按**周**切分：`logs\utterances-2026W41.jsonl`（ISO 周，避免跨年那周算错）。
# 为什么不删旧的：按项目总纲，「什么时候该沉默」的标注数据**就是护城河**，
# 它不是运行日志，是资产。所以只切分、不清理（一周几十 KB，留着不心疼）。
# 按周而不是按月：切分粒度小一点，翻最近几周的"它判过什么"更快，单文件也不会长到几 MB。
# 也顺带认老的 utterances.jsonl（迁移前写在一个文件里的那份）。
function Get-UtteranceLogs {
  param([int]$Newest = 0)
  $all = @()
  $legacy = Join-Path $logDir 'utterances.jsonl'
  if (Test-Path -LiteralPath $legacy) { $all += $legacy }
  $all += @(Get-ChildItem -LiteralPath $logDir -Filter 'utterances-*.jsonl' -File -ErrorAction SilentlyContinue |
      Sort-Object Name | Select-Object -ExpandProperty FullName)
  if ($all.Count -eq 0) { return @() }
  if ($Newest -gt 0) { $all = @($all | Select-Object -Last $Newest) }
  return $all
}

function Get-UtteranceLogPath {
  $d = Get-Date
  # ISOWeek 而不是 "第几周" 的简单算法：跨年那周（12/29 属于次年第 1 周）只有它算得对
  return (Join-Path $logDir ("utterances-{0}W{1:D2}.jsonl" -f `
        [System.Globalization.ISOWeek]::GetYear($d), [System.Globalization.ISOWeek]::GetWeekOfYear($d)))
}

function Load-History {
  $files = @(Get-UtteranceLogs -Newest 2)
  if ($files.Count -eq 0) { return }
  # 读最近 1–2 个月（够回填卡片和角标；再往前翻没意义）
  $lines = @()
  foreach ($f in $files) { $lines += @(Get-Content -LiteralPath $f -Encoding UTF8) }
  foreach ($line in ($lines | Select-Object -Last 30)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $o = $line | ConvertFrom-Json
      [void]$script:history.Add([pscustomobject]@{
          at     = $o.at
          text   = $o.text
          reason = $o.reason
          silent = (Test-SilentText $o.text)
          window = $o.window
        })
    } catch { }
  }
}

# 沉默总数必须从**整份日志**数，不能用内存里那 30 条 —— 否则角标会封顶在 30。
function Get-SilentTotalFromLog {
  $files = @(Get-UtteranceLogs)
  if ($files.Count -eq 0) { return 0 }
  $n = 0
  foreach ($f in $files) {
    foreach ($line in (Get-Content -LiteralPath $f -Encoding UTF8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { if (Test-SilentText (($line | ConvertFrom-Json).text)) { $n++ } } catch { }
    }
  }
  return $n
}

function Add-History {
  param([string]$Text, [string]$Reason, [bool]$Silent)
  [void]$script:history.Add([pscustomobject]@{
      at     = (Get-Date).ToString('o')
      text   = $Text
      reason = $Reason
      silent = $Silent
      window = $script:currentKey
    })
  while ($script:history.Count -gt 40) { $script:history.RemoveAt(0) }
  if ($Silent) { $script:silentTotal++ }
  $pet.SilentCount = [int]$script:silentTotal
}

# 卡片要宽一些才放得下；改宽度时保持右边缘不动，宠物不会横跳
function Set-PetWidth {
  param([int]$LogicalWidth, $Form = $null)   # 逻辑宽度，内部按 DPI 缩放
  $f = if ($Form) { $Form } else { $pet }    # 自检里传探针窗体，正常运行时用真身
  $w = [int][math]::Round($LogicalWidth * $script:UiScale)
  if ($f.Width -eq $w) { return }
  $delta = $w - $f.Width
  $f.Width = $w
  $f.Left = $f.Left - $delta
}

# 提问撑开前的宽度（没有提问在撑就是 $null）
$script:widthBeforePrompt = $null

# 选项按钮排一行要占多宽：先问 C# 那侧量一遍文字，把窗口撑到放得下整句。
# 撑不到（或标签本身比屏幕还长）也不怕 —— 气泡那侧会折行、最后才用省略号。
# 只撑不缩：短选项（"好 / 不用"）不该把气泡连着宠物一起缩窄。
# 撑开的宽度记在 $script:widthBeforePrompt 里，等这个问题答完/取消再还原（见 Restore-PetWidthAfterPrompt）。
function Set-PetWidthForOptions {
  param([string[]]$Options, [int]$Min = 0, [int]$Max = 620, $Form = $null)
  $f = if ($Form) { $Form } else { $pet }   # 自检里传探针窗体，正常运行时用真身
  $cur = [int][math]::Round($f.Width / $script:UiScale)
  $need = $cur
  try {
    if ($Options -and $Options.Count -gt 0) {
      $need = [int][math]::Ceiling([double]$f.PromptLogicalWidth($Options))
    }
  } catch { }
  if ($need -lt $Min) { $need = $Min }
  if ($need -lt $cur) { $need = $cur }
  if ($need -gt $Max) { $need = $Max }
  if ($need -ne $cur) {
    # 只在"这次提问开始撑"时记一次原宽，避免被后续调用覆盖成已经撑开的值
    # （自检传 -Form 探针窗体时不记账，免得污染运行时的还原值）
    if (-not $Form -and $null -eq $script:widthBeforePrompt) { $script:widthBeforePrompt = $cur }
    Set-PetWidth $need -Form $f
  }
}

# 提问结束（答了 / 超时 / 对面撤回）→ 把宽度还回去，别让宠物一直胖着。
function Restore-PetWidthAfterPrompt {
  if ($null -eq $script:widthBeforePrompt) { return }
  $w = $script:widthBeforePrompt
  $script:widthBeforePrompt = $null
  try { Set-PetWidth $w } catch { }
}

# 有现成角色图就用它。顺序在 paths.ps1 的 Get-DgPetImage 里：
    # config.petImage → DG_PET_IMAGE → 本目录 assets\pet.png。
    # 三条都没有就退回代码绘制的圆脸（自检预览里那张）。
function Resolve-PetImage {
  param([string]$Configured)
  return (Get-DgPetImage -Configured $Configured)
}

# 把「它判过什么 + 你用过它几次」画成一张卡片 —— 不用去翻日志。
# 抽成纯函数，自检里可以喂假数据直接看排版。
function Format-DecisionCard {
  param($History, $Interactions, [int]$Skipped = 0)
  $n = @($History).Count
  $sil = @($History | Where-Object { $_.silent }).Count
  $said = $n - $sil
  $rate = if ($n -gt 0) { [math]::Round(100.0 * $sil / $n) } else { 0 }

  # 触发方式（老记录只有 auto 字段，按它回推）
  $trig = @{}
  foreach ($h in $History) {
    $k = if (($h.PSObject.Properties.Name -contains 'trigger') -and $h.trigger) { $h.trigger }
         elseif ($h.auto) { 'auto' } else { 'manual' }
    $trig[$k] = 1 + [int]$trig[$k]
  }
  $timed = @($History | Where-Object { ($_.PSObject.Properties.Name -contains 'ms') -and $_.ms })
  $avg = if ($timed.Count -gt 0) { [math]::Round((($timed | Measure-Object -Property ms -Average).Average) / 1000.0, 1) } else { 0 }

  $inter = @{}
  foreach ($i in $Interactions) { $inter[$i.kind] = 1 + [int]$inter[$i.kind] }

  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add("判断 $n 次 · 说了 $said / 没说 $sil · 沉默率 $rate%")
  if ($n -eq 0) {
    [void]$lines.Add('还没有判断记录。点我一下，或者按 Ctrl+Alt+G。')
  } else {
    [void]$lines.Add("触发：手动 $([int]$trig['manual']) · 自动 $([int]$trig['auto']) · 预热 $([int]$trig['warmup'])")
    if ($Skipped -gt 0) { [void]$lines.Add("本地闸门省下 $Skipped 次模型调用（屏幕没变 / 刚判过 / 人不在）") }
    if ($avg -gt 0) { [void]$lines.Add("每次判断平均 $avg 秒") }
    $parts = @()
    if ($inter['ask']) { $parts += "问一句 $($inter['ask'])" }
    if ($inter['card']) { $parts += "看记录 $($inter['card'])" }
    if ($inter['drag']) { $parts += "拖动 $($inter['drag'])" }
    if ($inter['auto']) { $parts += "自动开关 $($inter['auto'])" }
    if ($parts.Count -gt 0) { [void]$lines.Add('交互：' + ($parts -join ' · ')) }
    [void]$lines.Add('———')
    foreach ($h in ($History | Select-Object -Last 4)) {
      $t = try { ([datetime]$h.at).ToString('HH:mm') } catch { '--:--' }
      if ($h.silent) {
        [void]$lines.Add("$t 没说 · $(Shorten-Text $h.reason 40)")
      } else {
        [void]$lines.Add("$t 说了 · $(Shorten-Text $h.text 40)")
      }
    }
  }
  return ($lines -join "`n")
}

function Show-DecisionCard {
  Set-PetWidth 430
  $pet.ShowMessage((Format-DecisionCard -History $script:history -Interactions $script:interactions -Skipped $script:judgeSkipped), 0)
}

function Get-ProcessNameSafe {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return '' }
  try { return (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName } catch { return '' }
}

function Add-TimelineEntry {
  param([string]$Process, [string]$Title)
  $key = "$Process|$Title"
  if ($key -ne $script:currentKey) {
    if ($script:currentKey -ne '') {
      $parts = $script:currentKey -split '\|', 2
      [void]$script:timeline.Add([pscustomobject]@{
          at      = $script:currentSince.ToString('o')
          seconds = [int]((Get-Date) - $script:currentSince).TotalSeconds
          process = $parts[0]
          title   = $parts[1]
        })
    }
    $script:currentKey = $key
    $script:currentSince = Get-Date
  }
  while ($script:timeline.Count -gt [int]$cfg.timelineSize) { $script:timeline.RemoveAt(0) }
}

# ===========================================================================
    # 账本（充值播报）：自己查余额 + 自己记账，**不依赖任何别的软件**
#
    # 桌宠这边要的是**播报**：余额涨了（有人充值）就在气泡里说一声，想看明细再点菜单。
    # 余额从 DeepSeek 公开接口自己查（要一个 API key，和 advisor-minimax/openai 同一套约定），
    # 每次看到余额就记一笔到我们自己的 ledger.json —— 于是"今天花了多少/是不是充值了"都算得出来。
# ===========================================================================
$script:ledgerStatePath = Join-Path $runDir 'ledger.json'
$script:ledgerLastBalance = $null
$script:lastBalanceAnnounceAt = Get-Date   # 定时播报余额的计时起点（启动时不立刻播一次）

function Load-LedgerState {
  if (Test-Path -LiteralPath $script:ledgerStatePath) {
    try { return (Get-Content -LiteralPath $script:ledgerStatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
  }
  return $null
}

function Save-LedgerState {
  param([double]$Balance)
  try {
    ([pscustomobject]@{ lastBalance = $Balance; at = (Get-Date).ToString('o') } |
      ConvertTo-Json -Compress) | Set-Content -LiteralPath $script:ledgerStatePath -Encoding UTF8
  } catch { }
}

function Show-LedgerCard {
  Set-PetWidth 460
  $l = Get-LedgerSnapshot
  $pet.ShowMessage((Format-LedgerCard -Ledger $l), 0)
}

function Update-Ledger {
  <#
    读一眼账本；余额**变大**就是充值 → 播报。
    阈值 rechargeMinDelta（默认 0.5 元）是为了避开余额观测的抖动，也避免几分钱的修正被当成充值。
    进程内第一次读到只做基线，不播报（否则每次重启都会"播报"一次历史充值）。
  #>
  param([switch]$Quiet)
  $l = Get-LedgerSnapshot
  if (-not $l -or $l.Source -eq 'none') {
    # 没有任何余额来源：只在第一次明说一遍，别每次轮询都念叨
    if (-not $script:ledgerWarned) {
      $script:ledgerWarned = $true
      Write-Host "[账本] $($l.Reason)"
    }
    return
  }
  # 记进**我们自己的**账本（不依赖任何插件）
  if ($l.Source -eq 'api') { try { Add-LedgerObservation -Balance $l.Balance -Currency $l.Currency } catch { } }
  $st = Load-LedgerState
  $prev = if ($script:ledgerLastBalance -ne $null) { [double]$script:ledgerLastBalance }
          elseif ($st -and ($st.PSObject.Properties.Name -contains 'lastBalance')) { [double]$st.lastBalance }
          else { $null }
  $script:ledgerLastBalance = $l.Balance
  Save-LedgerState -Balance $l.Balance
  if ($null -eq $prev) { return }

  $delta = $l.Balance - $prev
  $thr = [double]$(if ($cfg.rechargeMinDelta) { $cfg.rechargeMinDelta } else { 0.5 })
  if ($delta -ge $thr) {
    $msg = "充值到账 $(Format-Money $delta $l.Currency)，余额 $(Format-Money $l.Balance $l.Currency)"
    Add-Interaction 'recharge' ("+" + [math]::Round($delta, 2))
    if (-not $Quiet) {
      try { $pet.ShowMessage($msg, 20) } catch { }
      try { [void](Speak-Text $msg) } catch { }
    }
  }
}

#
# ---------------------------------------------------------------------------
# 待机（黑屏 / 锁屏 / 睡眠）
# 为什么要有这一段：屏幕关着时 GDI 抓屏会失败（"句柄无效"），而**失败只是症状** ——
# 之前桌宠会每 2 秒刷一条警告，还照样去问模型，模型拿到的是一张黑图或干脆没图，
# 判断自然全是垃圾。系统其实给了正式信号（都在窗口消息里）：
#   显示器电源 GUID_CONSOLE_DISPLAY_STATE · 会话锁屏 · 系统睡眠
# 这三个信号一起来，就能在"该不看"的时候干脆不看。
# ---------------------------------------------------------------------------
$script:standby = $false        # 当前是否待机
$script:standbyReason = ''      # signal = 系统信号；capture = 抓不到屏（信号没来时的兜底）
$script:captureFails = 0        # 连续抓屏失败次数
$script:lastStandbyProbe = [datetime]::MinValue

function Get-StandbyReason {
  $r = @()
  if ($pet.Suspended) { $r += '系统睡眠' }
  if ($pet.SessionLocked) { $r += '锁屏' }
  if (-not $pet.PowerDisplayOn) { $r += '显示器已关' }
  return ($r -join ' + ')
}

function Test-StandbyNow {
  return ($pet.Suspended -or $pet.SessionLocked -or (-not $pet.PowerDisplayOn))
}

# ---------------------------------------------------------------------------
# 后台抓屏（PowerShell runspace 版）
#
# 为什么不用 C# 开线程：PowerShell 的 Add-Type **会把 System.Private.CoreLib 从引用集里剔除**，
# 即使把它明确写进 -ReferencedAssemblies 也一样 —— 实测报
#   CS1069: 'Thread' ... has been forwarded to assembly 'System.Private.CoreLib'
#           Consider adding a reference to that assembly.
# 于是 Thread / Task / List<> 这类类型根本编译不过。这是硬限制，不是配置问题。
# 所以改用 PowerShell 自己的 runspace 做异步：抓屏仍调同一个 C# 实现，只是换线程跑。
#
# 效果：UI 线程每拍只做「取走上一次抓好的」+「下令抓下一张」，都是微秒级。
# ---------------------------------------------------------------------------
$script:capPs = $null
$script:capHandle = $null
$script:capBusy = $false
$script:capLastMs = 0
$script:capLastError = ''

function Reset-CaptureRunspace {
  <# 建一个**常驻** runspace（别每帧重建 —— 那本身要几十毫秒）。
      参数在建立时固定；用户改监控区域时会重建（改区域本来就会清空截图环）。 #>
  if ($script:capPs) { try { $script:capPs.Dispose() } catch { } ; $script:capPs = $null }
  $ps = [powershell]::Create()
  $null = $ps.AddScript({
      param($w, $q, $rx, $ry, $rw, $rh)
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      if ($rw -gt 0) { $b64 = [DesktopGuide.Capture]::GrabJpegBase64($w, $q, $rx, $ry, $rw, $rh) }
      else { $b64 = [DesktopGuide.Capture]::GrabJpegBase64($w, $q) }
      $sw.Stop()
      [pscustomobject]@{ jpeg = $b64; ms = $sw.ElapsedMilliseconds; fp = [DesktopGuide.Capture]::LastFingerprint }
    }).AddArgument([int]$cfg.screenshotMaxWidth).AddArgument([long]$cfg.jpegQuality)
  if ($cfg.region -and $cfg.region.w) {
    $null = $ps.AddArgument([int]$cfg.region.x).AddArgument([int]$cfg.region.y).AddArgument([int]$cfg.region.w).AddArgument([int]$cfg.region.h)
  } else {
    $null = $ps.AddArgument(0).AddArgument(0).AddArgument(0).AddArgument(0)
  }
  $script:capPs = $ps
  $script:capBusy = $false
  $script:capHandle = $null
}

function Start-BackgroundCapture {
  if ($script:capBusy -or -not $script:capPs) { return }
  $script:capBusy = $true
  try { $script:capHandle = $script:capPs.BeginInvoke() } catch { $script:capBusy = $false; $script:capHandle = $null }
}

function Complete-BackgroundCapture {
  <# 刚抓好一张就返回它（jpeg / 耗时 / 指纹）；还在抓或没在抓就返回 $null。 #>
  if (-not $script:capBusy -or -not $script:capHandle) { return $null }
  if (-not $script:capHandle.IsCompleted) { return $null }
  $script:capBusy = $false
  $handle = $script:capHandle
  $script:capHandle = $null
  try {
    $out = $script:capPs.EndInvoke($handle)
    # runspace 里抛的异常不会冒到这里，会落在它的 Error 流里 —— 必须自己捞，
    # 否则"抓不到屏"就没有任何信号了（截图环里只剩旧图，它会一直拿旧图判断）。
    if ($script:capPs.Streams.Error.Count -gt 0) {
      $script:capLastError = [string]$script:capPs.Streams.Error[0].ToString()
      $script:capPs.Streams.Error.Clear()
      return $null
    }
    if ($out -and $out.Count -gt 0 -and $out[0]) {
      $r = $out[0]
      if ($r.jpeg) { $script:capLastMs = [int]$r.ms; return $r }
    }
    # 跑完了却没有结果 = 也是一次失败（比如返回了空）
    $script:capLastError = '后台抓屏没有返回图像'
  } catch { $script:capLastError = $_.Exception.Message }
  return $null
}

# ---------------------------------------------------------------------------
# 任务采样表（会学习的那一张）
#
# 规则（供 Electron 版照搬，逻辑刻意保持简单、可移植）：
#   1. 表存在一个**独立 JSON 文件** task-samples.json 里，和手写的 config.taskRules 分开。
#      手写表是"部署方的意见"，学习表是"观察到的现实"；分开写，谁改谁不互相覆盖。
#   2. 键 = 进程名（小写）。一个进程一个条目，够用且不会长成一张烂表。
#   3. 采样率有两个来源：
#        - 模型建议：主 agent 可以在回复里多给一行 `SAMPLE: <秒>`，说这个环境多久看一次合适
#        - 用户行为：在同一个环境里**反复唤醒**（点它/长按/打字）说明当前太慢了 → 调低
#   4. 学习值**覆盖**手写规则里的采样率，但手写规则里的 hint（这类任务该怎么帮）保留。
# ---------------------------------------------------------------------------
$script:taskSamplesPath = Join-Path $PSScriptRoot 'task-samples.json'
$script:taskSamples = $null          # @{ <key> = @{ sampleSeconds; source; evidence; updatedAt; why } }
$script:wakeCounts = @{}             # 本进程内的唤醒计数（不进表，只是触发条件）
$script:jumpStreak = 0               # 连续几次采样之间画面大跳变（= 采样太慢的信号）

function Get-TaskKey {
  <# 任务键 = 进程名小写。取不到进程就退化成窗口标题里的一小段。 #>
  param([string]$Process = '', [string]$Title = '')
  if ($Process) { return $Process.ToLower() }
  if ($Title) { return ('title:' + $Title.ToLower().Substring(0, [Math]::Min(24, $Title.Length))) }
  return ''
}

function Load-TaskSamples {
  if ($script:taskSamples) { return $script:taskSamples }
  $script:taskSamples = @{}
  if (Test-Path -LiteralPath $script:taskSamplesPath) {
    try {
      $raw = Get-Content -LiteralPath $script:taskSamplesPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in @($raw.entries.PSObject.Properties)) {
        $script:taskSamples[$p.Name] = $p.Value
      }
    } catch {
      Write-Warning "读 task-samples.json 失败（当作空表继续）：$($_.Exception.Message)"
    }
  }
  return $script:taskSamples
}

function Save-TaskSamples {
  try {
    $obj = [pscustomobject]@{
      _note = '学习出来的采样率表：键=进程名(小写)。sampleSeconds 是"多久看一眼"，source 说明这条是怎么来的（model=主 agent 建议 / wake=用户反复唤醒后调低）。手写规则在 config.json 的 taskRules 里；学习值覆盖采样率，但不覆盖 hint。'
      entries = $script:taskSamples
    }
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $script:taskSamplesPath -Encoding UTF8
  } catch { Write-Warning "写 task-samples.json 失败：$($_.Exception.Message)" }
}

function Set-TaskSample {
  <#
    记录/更新一个任务键的采样率。
    - Seconds 会用 [minSampleSeconds, maxSampleSeconds] 夹住（免得学出 0.05 秒把机器烧了）
    - Source: 'model' | 'wake' | 'manual'
  #>
  param([string]$Key, [double]$Seconds, [string]$Source = 'model', [string]$Why = '')
  if (-not $Key -or $Seconds -le 0) { return }
  $lo = [double]$(if ($cfg.minSampleSeconds) { $cfg.minSampleSeconds } else { 0.3 })
  $hi = [double]$(if ($cfg.maxSampleSeconds) { $cfg.maxSampleSeconds } else { 60 })
  $v = [math]::Round([math]::Min($hi, [math]::Max($lo, $Seconds)), 2)
  [void](Load-TaskSamples)
  $old = $script:taskSamples[$Key]
  $ev = if ($old -and ($old.PSObject.Properties.Name -contains 'evidence')) { [int]$old.evidence + 1 } else { 1 }
  $script:taskSamples[$Key] = [pscustomobject]@{
    sampleSeconds = $v
    source        = $Source
    evidence      = $ev
    updatedAt     = (Get-Date).ToString('o')
    why           = $Why
  }
  Save-TaskSamples
  Add-Interaction 'sample_learn' "$Key → ${v}s（$Source）"
  return $v
}

function Note-ManualWake {
  <#
    【已废弃 —— 这条判据是错的，保留函数只为不破坏调用点，不再调低采样率】

    原来的想法：用户在同一环境里反复唤醒 = 采样太慢。
    但**有的提醒只需要看一眼就够，根本不产生交互** —— 拿"唤醒次数"当证据，
    等于把"安静地看了"判成"没在意"，还会把采样越调越快、越调越费。
    交互不是价值的代理变量，所以这里什么都不做了。
  #>
  param([string]$Key)
  return
}

function Note-SampleJump {
  <#
    **不需要任何交互的判据**：两次采样之间画面跳变很大 = 这中间发生过我们没看到的东西，
    说明采样太慢。连续 3 次大跳变就把这个键的采样率调低 30%。

    为什么用它而不是"用户叫了几次"：判断依据必须是**观察到的现实**（画面上有没有漏掉东西），
    不能是"用户理没理我" —— 因为好的提醒本来就可能只需要看一眼。
  #>
  param([string]$Key, [double]$Delta)
  if (-not $Key) { return }
  $thr = [double]$(if ($cfg.jumpDeltaThreshold) { $cfg.jumpDeltaThreshold } else { 200 })
  if ($Delta -lt $thr) { $script:jumpStreak = 0; return }
  $script:jumpStreak++
  if ($script:jumpStreak -lt 3) { return }
  $cur = $script:curProfile
  $base = if ($cur -and $cur.sample -gt 0) { [double]$cur.sample } else { [double]$cfg.sampleSeconds }
  $v = Set-TaskSample -Key $Key -Seconds ($base * 0.7) -Source 'jump' -Why "连续 3 次采样间画面跳变超过 $thr"
  $script:jumpStreak = 0
  try { $pet.ShowMessage("这个环境变化比我看得还快（连漏 3 次）—— 采样从 $([math]::Round($base,2))s 调到 ${v}s。", 6) } catch { }
}

function Get-TaskProfile {
  <#
    按**声明式规则表**（config.taskRules）判断当前是什么任务，返回这一档的采样节奏与提示。
    匹配顺序即优先级：进程名（子串、不分大小写）或窗口标题命中即算。
    没命中就走默认档（用 config 里的 sampleSeconds / screenshotSeconds / judgeMinSeconds）。
  #>
  param([string]$Process = '', [string]$Title = '')
  $def = [pscustomobject]@{
    name  = '默认'
    sample = [double]$(if ($cfg.sampleSeconds) { $cfg.sampleSeconds } else { 2 })
    shot   = [double]$(if ($cfg.screenshotSeconds) { $cfg.screenshotSeconds } else { 5 })
    judge  = [double]$(if ($cfg.judgeMinSeconds) { $cfg.judgeMinSeconds } else { 60 })
    hint   = ''
  }
  foreach ($r in @($cfg.taskRules)) {
    if (-not $r) { continue }
    $hit = $false
    foreach ($p in @($r.process)) {
      if ($p -and $Process -and $Process.ToLower().Contains(([string]$p).ToLower())) { $hit = $true; break }
    }
    if (-not $hit) {
      foreach ($p in @($r.title)) {
        if ($p -and $Title -and $Title.ToLower().Contains(([string]$p).ToLower())) { $hit = $true; break }
      }
    }
    if (-not $hit) { continue }
    $prof = $def.PSObject.Copy()
    if ($r.name) { $prof.name = [string]$r.name }
    if ($r.sampleSeconds) { $prof.sample = [double]$r.sampleSeconds }
    if ($r.screenshotSeconds) { $prof.shot = [double]$r.screenshotSeconds }
    if ($r.judgeMinSeconds) { $prof.judge = [double]$r.judgeMinSeconds }
    $prof.hint = [string]$r.hint
    $hitProf = $prof
    break
  }
  $prof = if ($hitProf) { $hitProf } else { $def }

  # ---- 学习表覆盖采样率（但**不覆盖**手写规则里的 hint）----
  # 顺序：手写规则定"这类任务该怎么帮"（hint），学习表定"多久看一眼"（sample）。
  $key = Get-TaskKey -Process $Process -Title $Title
  $learned = (Load-TaskSamples)[$key]
  if ($learned -and ($learned.PSObject.Properties.Name -contains 'sampleSeconds') -and $learned.sampleSeconds) {
    $prof.sample = [double]$learned.sampleSeconds
    if ($prof.name -eq '默认') { $prof.name = "学习：$key" }
  }
  return $prof
}

function Sync-SampleCadence {
  <#
    把"当前任务档"的采样节奏**真正落到定时器上**，每次采样都调。

    为什么单独抽出来：这段原来写在 Sample-Once 的 `if ($prof.name -ne $script:curTaskName)`
    里面，于是只有"换了一个**档名**"才会重设 Interval。两种情况下节奏是错的：

      1. 同一条规则下的两个进程（balatro → hearthstone 都命中「卡牌/回合制游戏」）：
         档名一样，不走重设 → 前一个进程的学习值（比如 0.42s）会被后一个继续沿用，
         而后者本该是规则里的 0.6s。反过来（0.3 → 0.6）也一样。
      2. 模型给了 `SAMPLE: <秒>`、或 Note-SampleJump 的跳变学习改了表之后：
         当前档的 Interval 不会刷新，要等下次换档才生效 —— 表现就是"调了但当时不生效"。

    做法：每次都算一遍目标毫秒值，和**上次真正应用的值**比，不同才写。
    写 Interval 会重排计时器，没必要每拍都写；比较是纯内存操作，可以不心疼地每拍做。
    返回值 = 本次生效的秒数（-1 = 这档不限制采样，保持原样）。
  #>
  param([double]$Sample)
  if ($Sample -le 0) { return -1 }
  # 下限 300ms 和原来一致：防的是"学出 0.05 秒把机器烧了"（config 里还有一层夹子）
  $ms = [int]([math]::Max(300, $Sample * 1000))
  if ($ms -eq $script:appliedSampleMs) { return $Sample }
  if ($sampleTimer) { try { $sampleTimer.Interval = $ms } catch { } }
  $script:appliedSampleMs = $ms
  return $Sample
}

function Enter-Standby {
  param([string]$Why = '信号', [string]$Kind = 'signal', [string]$Display = '')
  if ($script:standby) { return }
  $script:standby = $true
  $script:standbyReason = $Kind
  $script:lastStandbyProbe = Get-Date
  Add-Interaction 'standby' "$Kind|$Display"
  # 正在跑的**自动**判断是基于屏幕的：屏幕没了，它看到的是黑的（或者干脆没图），
  # 继续等一个基于黑屏的结论毫无意义 —— 停掉。
  if (Get-Command Stop-AutoAdvisorForUser -ErrorAction SilentlyContinue) {
    [void](Stop-AutoAdvisorForUser -What 'standby')
  }
  # 自动判断在待机期间没有意义（没屏幕可看）——停掉定时器，欠账也清掉：
  # 醒来会重新看一眼，比"补一次基于黑屏的判断"正确。
  if ($autoTimer) { try { $autoTimer.Stop() } catch { } }
  $script:pendingAutoResume = $false
  try { $pet.ShowSleeping("（待机中：$Display）屏幕亮了我再看。") } catch { }
  Write-Host "[待机] 进入：$Display"
}

function Exit-Standby {
  param([string]$Display = '信号恢复')
  if (-not $script:standby) { return }
  $script:standby = $false
  $script:standbyReason = ''
  Add-Interaction 'wake' $Display
  # 醒来第一件事：把过期的观测**全部作废**。不清的话，
  # 「停留了 8 小时」「画面静止 8 小时」这种数字会直接喂给模型（这个坑项目里踩过一次）。
  $script:shots.Clear()
  $script:lastFp = ''; $script:lastJudgedFp = $null
  $script:currentSince = Get-Date
  $script:stillSince = Get-Date
  $script:lastShotAt = [datetime]::MinValue
  $script:captureFails = 0
  if (Get-Command Sample-Once -ErrorAction SilentlyContinue) { try { Sample-Once } catch { } }
  if ($autoTimer -and $pet.AutoEnabled) { try { $autoTimer.Start() } catch { } }
  $script:pendingAutoResume = $true
  try { $pet.ShowMessage('（我醒了，重新看一眼）', 5) } catch { }
  Write-Host "[待机] 退出：$Display"
}

function Sync-Standby {
  <# 窗口消息说状态变了 → 结算一次（幂等，没变就什么都不做）。 #>
  $now = Test-StandbyNow
  if ($now -eq $script:standby) { return }
  if ($now) { Enter-Standby -Why 'signal' -Kind 'signal' -Display (Get-StandbyReason) }
  else { Exit-Standby -Display '信号恢复' }
}

function Try-WakeFromStandby {
  <#
    待机**自愈**：现场核一遍，不再信那三个缓存标志位。
    为什么要它：待机是消息驱动的，漏一条就会一直以为在待机 —— 实测踩过，锁屏通知进来、
    解锁通知没到，桌宠连着两小时没看过屏幕，用户点它时手上连一张截图都没有，
    模型只能照窗口标题"脑补"出具体操作步骤。

    三条都成立才醒：
      ① 最近有人动键鼠（离屏待机期间不可能有输入，所以有输入 = 机器在用）
      ② 现在不是锁屏（OpenInputDesktop 现场问，锁屏时普通进程打不开输入桌面）
      ③ 真的能抓到一张图
    醒来时把 Suspended / SessionLocked / PowerDisplayOn 一并校准 —— 不校准的话，
    下一个任意待机事件会立刻把它按回待机。
  #>
  param([string]$Why = '自检')
  if (-not $script:standby) { return $false }
  $idleS = [int]([DesktopGuide.Native]::IdleMs() / 1000)
  $probeIdle = [int]$(if ($cfg.standbyProbeIdleSeconds) { $cfg.standbyProbeIdleSeconds } else { 60 })
  if ($idleS -lt 0 -or $idleS -ge $probeIdle) { return $false }
  $lockedNow = $true
  try { $lockedNow = [DesktopGuide.Native]::IsLockedNow() } catch { }
  if ($lockedNow) { return $false }
  try {
    $probe = [DesktopGuide.Capture]::GrabJpegBase64([int]$cfg.screenshotMaxWidth, [long]$cfg.jpegQuality)
    if (-not $probe) { return $false }
  } catch { return $false }
  $pet.Suspended = $false
  $pet.SessionLocked = $false
  $pet.PowerDisplayOn = $true
  Exit-Standby -Display "自愈（$Why；距上次输入 ${idleS}s、未锁屏）"
  return $true
}

function Sample-Once {
  param([switch]$Force)   # -Force：焦点刚换过，立刻采（并且立刻截图）
  # 待机就什么都别做：不抓屏、不记轨迹、不涨"停留时间"。
  if ($script:standby) { return }
  $fgPid = [DesktopGuide.Native]::ForegroundPid()
  $title = [DesktopGuide.Native]::ForegroundTitle()
  $proc = Get-ProcessNameSafe -ProcessId $fgPid
  Add-TimelineEntry -Process $proc -Title $title

  # ---- 任务档：决定"多久看一眼"，以及"这类任务该怎么帮" ----
  $script:curTaskKey = Get-TaskKey -Process $proc -Title $title
  $prof = Get-TaskProfile -Process $proc -Title $title
  # curProfile **每次采样都刷新**：原来只在档名变化时刷，于是 Note-SampleJump 会拿
  # 上一个环境的 sample 当基准去乘 0.7（基准本身是旧的 → 越调越偏）。
  $script:curProfile = $prof
  # 采样节奏**每次都对账**，不是只在换档名时重设（理由见 Sync-SampleCadence 的注释）
  [void](Sync-SampleCadence -Sample ([double]$prof.sample))
  if ($prof.name -ne $script:curTaskName) {
    $script:curTaskName = $prof.name
    Add-Interaction 'task' ("$($prof.name)|采样 $($prof.sample)s|截图 $($prof.shot)s")
  }

  $now = Get-Date
  # 通用变化检测：把画面缩成 8x8 指纹。不需要任何按应用的适配器。
  try {
    # 直接复用刚才那次截图算出的指纹，不再为了 8x8 重抓一次全屏（那是每 2 秒 20MB 的浪费）。
    $fp = [DesktopGuide.Capture]::LastFingerprint
    if ($fp -ne $script:lastFp) { $script:lastFp = $fp; $script:stillSince = $now }
  } catch { }

  # **采样即截图**，而且抓屏在**后台线程**上做（见 Capture.BeginCapture 的注释）：
  #   UI 线程这一步只做两件极快的事 —— ① 取走上一次抓好的；② 下令抓下一张。
  #   所以 0.6 秒的采样档也不会卡界面（之前是每次同步抓 190ms，占掉约 1/3 的 UI 时间）。
  # 代价：进环的那张图最多比"现在"旧一个采样周期（游戏档 0.6 秒），完全可以接受。
  # ① 取走后台上一次抓好的那张（微秒级，不阻塞）
  if (-not $script:capPs) { try { Reset-CaptureRunspace } catch { } }
  $capRes = Complete-BackgroundCapture
  if ($capRes) {
    [void]$script:shots.Add([pscustomobject]@{ at = $now.ToString('o'); jpegBase64 = $capRes.jpeg })
    while ($script:shots.Count -gt [int]$cfg.maxScreenshots) { $script:shots.RemoveAt(0) }
    $script:lastShotAt = $now
    $script:captureFails = 0
    $fp = [string]$capRes.fp
    if ($fp) {
      # 先用**上一次**采样的指纹算跳变量，再更新 —— 顺序反了就没得比了
      if ($script:lastFp) { Note-SampleJump -Key $script:curTaskKey -Delta (Get-FpDistance $fp $script:lastFp) }
      if ($fp -ne $script:lastFp) { $script:lastFp = $fp; $script:stillSince = $now }
    }
  }
  # 抓屏失败的兜底（信号没来、但就是抓不到屏时，别一直拿旧图判断）：
  # 连续 captureFailLimit 次就自己进待机。
  if ($script:capLastError) {
    $capErr = $script:capLastError
    $script:capLastError = ''
    $script:captureFails++
    $limit = [int]$(if ($cfg.captureFailLimit) { $cfg.captureFailLimit } else { 3 })
    if ($script:captureFails -ge $limit) {
      Enter-Standby -Kind 'capture' -Display "连续 $($script:captureFails) 次抓不到屏幕"
    } else {
      Write-Warning "截图失败（第 $($script:captureFails)/$limit 次）：$capErr"
    }
  }
  # ② 下令抓下一张（也是微秒级；上一张还没抓完就自然跳过这一拍）
  Start-BackgroundCapture

  $record = [pscustomobject]@{
    at        = $now.ToString('o')
    process   = $proc
    title     = $title
    inWindowS = [int]($now - $script:currentSince).TotalSeconds
    shots     = $script:shots.Count
    task      = $script:curTaskName
  }
  # 游戏档会 0.6 秒采一次，但**观察日志不必跟着涨**：窗口没换就按 logMinSeconds 限流。
  # 不然一天能写几十万行（实测按 0.6s 算 ≈ 17 万行/天）。
  $logEvery = [double]$(if ($cfg.logMinSeconds) { $cfg.logMinSeconds } else { 2 })
  if ((($now - $script:lastObserveLogAt).TotalSeconds -ge $logEvery) -or $Force) {
    $script:lastObserveLogAt = $now
    Add-Content -LiteralPath $logPath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
  }
}

function Build-Payload {
  $now = Get-Date
  $parts = $script:currentKey -split '\|', 2
  return [pscustomobject]@{
    askedAt   = $now.ToString('o')
    current   = [pscustomobject]@{
      process   = $parts[0]
      title     = $parts[1]
      inWindowS = [int]($now - $script:currentSince).TotalSeconds
    }
    timeline  = @($script:timeline | Select-Object -Last 12)
    # 三个信号一起看，才能把「等程序跑完」「人不在」「在看」分开：
    human     = [pscustomobject]@{
      idleSeconds  = [int]([DesktopGuide.Native]::IdleMs() / 1000)
      fgCpuPercent = $(try {
          $hp = Get-Process -Id ([DesktopGuide.Native]::ForegroundPid()) -ErrorAction Stop
          $t1 = $hp.TotalProcessorTime.TotalMilliseconds
          Start-Sleep -Milliseconds 120
          $hp.Refresh()
          [int][math]::Round((($hp.TotalProcessorTime.TotalMilliseconds - $t1) / 120.0) * 100 / [Environment]::ProcessorCount)
        } catch { -1 })
    }
    screen    = [pscustomobject]@{
      stillSeconds = [int]((Get-Date) - $script:stillSince).TotalSeconds
      fingerprint  = $script:lastFp
      # 截图缓冲是不是空的 / 最新一张有多旧。没有截图时模型只能看到窗口标题，
      # 那条路上它特别容易"脑补"出具体操作步骤 —— 所以这两个数字要如实交给提示词。
      shotCount    = [int]$script:shots.Count
      shotAgeSeconds = $(if ($script:shots.Count -gt 0) {
          try { [int]((Get-Date) - [datetime]$script:shots[$script:shots.Count - 1].at).TotalSeconds } catch { -1 }
        } else { -1 })
    }
    shots     = @($script:shots | ForEach-Object { $_.jpegBase64 })
    shotTimes = @($script:shots | ForEach-Object { $_.at })
    # 子 agent 观察：后台正在跑的任务也交给主 agent —— 它判断"该不该开口"时
    # 得知道"用户已经派了活出去、正在跑"，否则会把"屏幕没动"误判成"人卡住了"。
    agents    = @(Get-ObservedAgents)
    # 当前任务档：主 agent 据此**提前**知道该怎么帮（例如卡牌游戏优先给牌型/最优出牌）
    task      = [pscustomobject]@{
      name = $script:curTaskName
      hint = $(if ($script:curProfile) { [string]$script:curProfile.hint } else { '' })
      sampleSeconds = $(if ($script:curProfile) { [double]$script:curProfile.sample } else { 0 })
      key  = $script:curTaskKey
    }
    userAwayS = $(if ($script:lastUserAt -eq [datetime]::MinValue) { -1 } else { [int]((Get-Date) - $script:lastUserAt).TotalSeconds })
    extras    = [pscustomobject]@{
      displayCount = [System.Windows.Forms.Screen]::AllScreens.Count
      primarySize  = "$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width)x$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)"
    }
  }
}

function Invoke-BuiltinAdvisor {
  param($Payload)
  $c = $Payload.current
  $mins = [math]::Round($c.inWindowS / 60.0, 1)
  return "【链路自检】当前：$($c.process)《$($c.title)》已停留 $mins 分钟；记录到 $($Payload.timeline.Count) 次窗口切换；缓冲截图 $($Payload.shots.Count) 张。"
}

function Get-FpDistance {
  <#
    两个指纹差多少。指纹是 64 格、每格量化成 16 级灰度 ——
    生成时是 `(char)(48 + lum/16)`，所以字符是 '0'(48) 到 '?'(63)，**不是 '0'..'F'**。
    直接按字符码求绝对差之和：0 = 一模一样，最大 64*15 = 960。
    之前只用"相不相等"判断，导致时钟跳一秒、光标闪一下就算"变了"——然后白起一次模型调用。
  #>
  param([string]$A, [string]$B)
  if (-not $A -or -not $B -or $A.Length -ne $B.Length) { return 999 }
  $d = 0
  for ($i = 0; $i -lt $A.Length; $i++) { $d += [math]::Abs([int][char]$A[$i] - [int][char]$B[$i]) }
  return $d
}

function Test-WorthAutoJudge {
  <#
    **本地闸门**：值不值得为这一轮起一次模型调用。
    返回 '' = 值得；返回一句话 = 先别问，那句话就是原因。

    为什么要这么做：一次自动判断的成本不是"一句话"，而是
      起一个 pwsh → 再起一个完整的 DSH 进程 → 带最多 6 张截图的一次模型调用，
      实测 8–25 秒、真金白银。而绝大多数轮次的答案是"没事，不用说话"。
    "值不值得问"这件事不需要模型判断——屏幕变没变、窗口换没换、人还在不在，
    本地代码全都知道（这也是项目一贯的立场：门控是确定性代码，模型只负责说什么）。
  #>
  if ($script:standby) { return '待机中' }
  # 抓屏改成异步之后，启动后头一两拍可能还没有图 —— 这时候先别问，
  # 否则主 agent 会拿到"没有截图"的一轮，判断质量反而更差。
  if ($script:shots.Count -eq 0) { return '还没有画面（抓屏是异步的，等第一张下来）' }
  $now = Get-Date
  $fpDist = Get-FpDistance $script:lastFp $script:lastJudgedFp
  $winChanged = ($script:lastJudgedKey -ne $script:currentKey)
  $delta = [int]$(if ($cfg.judgeMinFpDelta) { $cfg.judgeMinFpDelta } else { 12 })
  # 判断间隔也跟着任务档走：游戏档允许问得勤（20s），视频/桌面档放得很宽（180/300s）
  $quiet = [int]$(if ($script:curProfile -and $script:curProfile.judge -gt 0) { $script:curProfile.judge } else { if ($cfg.judgeMinSeconds) { $cfg.judgeMinSeconds } else { 60 } })
  # 连续沉默就退避：它越是说"不用"，我们就越少去问它
  $mult = 1 + [math]::Min($script:silentStreak, ([int]$cfg.silentBackoffMax - 1))
  $need = $quiet * $mult
  $since = if ($script:lastJudgedAt -eq [datetime]::MinValue) { [double]::MaxValue } else { ($now - $script:lastJudgedAt).TotalSeconds }

  # 保险丝：不管画面多"静"，隔太久也得看一眼。
  # 没有这道的话，用户在一个窗口里连续工作（8x8 指纹本来就看不出一行代码的变化），
  # 闸门会一直跳过 —— 省是省了，但桌宠等于停了。
  $maxGap = [double]$(if ($cfg.judgeMaxGapSeconds) { $cfg.judgeMaxGapSeconds } else { 300 })
  if ($since -ge $maxGap) { return '' }
  if ((-not $winChanged) -and ($fpDist -lt $delta)) {
    return "画面几乎没变（差异 $fpDist < $delta），前台窗口也没换"
  }
  if ($since -lt $need) {
    return "距上次判断只有 $([int]$since)s（连续 $($script:silentStreak) 次没说 → 间隔放宽到 $([int]$need)s）"
  }
  $idle = [int]([DesktopGuide.Native]::IdleMs() / 1000)
  if (($idle -ge [int]$cfg.judgeIdleSkipSeconds) -and (-not $winChanged)) {
    return "人不在（$($idle)s 没有键鼠输入，窗口也没换）"
  }
  return ''
}

function Start-Advisor {
  param([switch]$Auto)
  $script:advisorStarted = Get-Date
  # 待机中没屏幕可看，别浪费一次模型调用（手动问一句不受此限：用户点得到就说明人醒着）
  if ($Auto -and $script:standby) { return }
  # 已经有一轮在跑了 → 不要再起一个。
  # 以前没有这道闸，连点两下会起两个 advisor，第二个会去抢同一个会话的写句柄
  # （"already owned by an active write handle"），留下孤儿 dsh 进程。双击打断要依赖这一点。
  if ($script:thinking) { return }
  # **用户优先**：用户刚动过手（点/长按/拖/菜单/选项…）就不要自作主张地开口。
  # 记一笔"欠一次"，等用户停手 userQuietSeconds 秒后由 $priorityTimer 补上。
  if ($Auto -and $script:lastUserAt -ne [datetime]::MinValue) {
    $quiet = [double]$(if ($cfg.userQuietSeconds) { $cfg.userQuietSeconds } else { 6 })
    if (((Get-Date) - $script:lastUserAt).TotalSeconds -lt $quiet) {
      $script:pendingAutoResume = $true
      return
    }
  }
  # 状态没变 → 不必再判断一次。这是通用的省钱省时间做法（画面指纹来自 8x8 采样）。
  # 现在换成**本地闸门**（Test-WorthAutoJudge）：不只看画面变没变，还看窗口换没换、
  # 距上次多久、人还在不在、以及"它连着几次没说"的退避。
  if ($Auto) {
    $why = Test-WorthAutoJudge
    if ($why) {
      $script:judgeSkipped++
      # 同一个原因连续跳过只记第一条，免得把 interactions 日志刷爆
      if ($why -ne $script:lastSkipReason) { Add-Interaction 'judge_skip' $why; $script:lastSkipReason = $why }
      return
    }
    $script:lastSkipReason = ''
  }
  $script:lastJudgedFp = $script:lastFp
  $script:lastJudgedKey = $script:currentKey
  $script:lastJudgedAt = Get-Date
  $payload = Build-Payload
  ($payload | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $payloadPath -Encoding UTF8
  $script:autoAsk = [bool]$Auto

  # 双路径：
  #   手动「问一句」走 advisorFast —— 直接把图内嵌在请求里的一次调用（3-4 秒）
  #   自动检查走 advisor —— DSH 主 agent（有常驻记忆，但要启动进程 + 一轮读图工具，8-14 秒）
  # 为什么手动不能用 DSH：dsh-headless 的 CLI 没有附件入口（源码里只有 task），
  # 图只能靠 read_image 工具读，必然多一轮模型调用。实测过。
  # 配置里的命令可以带占位符（{root} 等），在这里展开 —— 这样 config.json 不用写死本机路径。
  $cmd = if (-not $Auto -and $cfg.advisorFast) { [string]$cfg.advisorFast } else { [string]$cfg.advisor }
  $cmd = Expand-DgTokens $cmd

  if ([string]::IsNullOrWhiteSpace($cmd)) {
    $pet.ShowMessage((Invoke-BuiltinAdvisor -Payload $payload), [int]$cfg.showSeconds)
    return
  }

  if (Test-Path $advisorOut) { Remove-Item -LiteralPath $advisorOut -Force }
  if (Test-Path $advisorErr) { Remove-Item -LiteralPath $advisorErr -Force }
  # 注意：不要把整条 advisor 命令再包一层引号 —— 它自己通常已经带引号（-File "路径"），
  # 外面再包一层会让 cmd /c 把它当成一个程序名，参数全丢。这里只给 payload 路径加引号。
  $cmdLine = '{0} "{1}"' -f $cmd, $payloadPath
  $script:advisorProc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdLine -NoNewWindow -PassThru -RedirectStandardOutput $advisorOut -RedirectStandardError $advisorErr
  $script:thinking = $true
  $script:advisorT0 = Get-Date
  $script:lastStage = ''
  # 通用阶段上报：任何 advisor 都可以往这个文件写一行当前阶段，桌宠优先读它。
  # 没有它的话，单次 HTTP 调用的路径（advisor-openai）全程只能显示"正在启动"。
  try { Remove-Item -LiteralPath (Join-Path $runDir 'stage.txt') -Force -ErrorAction SilentlyContinue } catch { }
  $pet.ShowThinking('正在看屏幕…')
}

function Complete-AdvisorIfDone {
  if (-not $script:thinking -or $null -eq $script:advisorProc) { return }
  if (-not $script:advisorProc.HasExited) {
    # 边等边报进度：读它的事件流尾部，把"在干什么 + 已经多久"写进气泡。
    # 这一步纯粹是为了体感 —— 8-14 秒里屏幕一动不动是最伤的体验。
    $elapsed = [int]((Get-Date) - $script:advisorT0).TotalSeconds
    $stage = '正在启动…'
    # 顺序很重要：**事件流优先，阶段文件兜底**。
    # 反过来会卡住 —— DSH 路径只在启动时写一次 stage.txt 就阻塞在等进程了，
    # 而它的事件流其实在持续更新。之前我写成"文件优先"且判断字符串写错，
    # 结果标签从始至终冻在"正在启动 DSH…"（实测踩过）。
    $mainOut = Join-Path $runDir 'main-agent.out.jsonl'
    if (Test-Path $mainOut) {
      foreach ($l in (Get-Content -LiteralPath $mainOut -Tail 8 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($l -match '"read_image"') { $stage = '正在看屏幕…' }
        elseif ($l -match '"type":"thinking"') { $stage = '正在想…' }
        elseif ($l -match '"type":"tool_call"') { $stage = '正在查资料…' }
      }
    }
    # 事件流还没吐东西（刚启动）→ 用 advisor 自己写的阶段
    $stageFile = Join-Path $runDir 'stage.txt'
    if ($stage -eq '正在启动…' -and (Test-Path $stageFile)) {
      try {
        $s = (Get-Content -LiteralPath $stageFile -Raw -Encoding UTF8).Trim()
        if ($s) { $stage = $s }
      } catch { }
    }
    $line = "$stage ${elapsed}s"
    if ($line -ne $script:lastStage) {
      $script:lastStage = $line
      try { $pet.ShowThinking($line) } catch { }
    }
    # 有提问/审批在等用户回答时，这一轮的"超时"不该算数 —— agent 是卡在等人，不是想太久。
    # 不挡的话：审批挂在气泡上到 30s 会被这里杀掉，用户还没点就没了。
    if (-not $pet.PromptPending -and
        ((Get-Date) - $script:advisorProc.StartTime).TotalSeconds -gt [double]$cfg.advisorTimeoutSeconds) {
      try { $script:advisorProc.Kill() } catch { }
      $script:thinking = $false
      $pet.ShowMessage('（想太久了，先不想了）', [int]$cfg.showSeconds)
    }
    return
  }
  $script:thinking = $false
  $text = ''
  if (Test-Path $advisorOut) { $text = (Get-Content -LiteralPath $advisorOut -Raw -Encoding UTF8) }
  $err = ''
  if (Test-Path $advisorErr) { $err = (Get-Content -LiteralPath $advisorErr -Raw -Encoding UTF8) }
  $text = $text.Trim()
  # 大脑习惯性输出 Markdown（**加粗**、# 标题、反引号…），气泡画不了它。
  # 先压成纯文本再解析 REASON / WATCH —— 顺带把 `WATCH: **Codex**` 这种也收拾干净。
  # 原始输出不丢：还躺在 run\advisor.out.txt 里，复盘要看原文就去那儿。
  $text = ConvertTo-PlainText $text

  if ([string]::IsNullOrWhiteSpace($text)) {
    if (-not $script:autoAsk) {
      $msg = if ([string]::IsNullOrWhiteSpace($err)) { '（大脑没有输出）' } else { "（大脑报错）$err" }
      $pet.ShowMessage($msg, [int]$cfg.showSeconds)
    }
    $script:autoAsk = $false
    return
  }

  # 大脑可以多回一行 "REASON: ..."，那行只进日志（用来复盘它的判断），不进气泡。
  $rows = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
  $reason = (($rows | Where-Object { $_ -match '^REASON[:：]' } | Select-Object -First 1) -replace '^REASON[:：]\s*', '')
  $watch = (($rows | Where-Object { $_ -match '^WATCH[:：]' } | Select-Object -First 1) -replace '^WATCH[:：]\s*', '')
  $optionsLine = (($rows | Where-Object { $_ -match '^OPTIONS[:：]' } | Select-Object -First 1) -replace '^OPTIONS[:：]\s*', '')
  $sampleLine = (($rows | Where-Object { $_ -match '^SAMPLE[:：]' } | Select-Object -First 1) -replace '^SAMPLE[:：]\s*', '')
  # 主 agent 建议的采样率 → 记进学习表（下次同一个环境就按这个看）
  if ($sampleLine -match '^\s*([0-9]+(\.[0-9]+)?)\s*$') {
    try { [void](Set-TaskSample -Key $script:curTaskKey -Seconds ([double]$matches[1]) -Source 'model' -Why '主 agent 建议') } catch { }
  }
  $shownText = ($rows | Where-Object { $_ -notmatch '^REASON[:：]' -and $_ -notmatch '^WATCH[:：]' -and $_ -notmatch '^OPTIONS[:：]' -and $_ -notmatch '^SAMPLE[:：]' } | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($shownText)) { $shownText = $text }
  if ($watch) { try { [void](Set-WatchFromAgent -Target $watch -Quiet) } catch { } }

  # 按月写进 utterances-YYYYMM.jsonl（每月自动换个文件，不需要重命名/轮转）
  Add-Content -LiteralPath (Get-UtteranceLogPath) -Encoding UTF8 -Value (([pscustomobject]@{
        at     = (Get-Date).ToString('o')
        auto   = $script:autoAsk
        trigger = $(if ($script:suppressShow) { 'warmup' } elseif ($script:autoAsk) { 'auto' } else { 'manual' })
        ms     = $(if ($script:advisorStarted) { [int]((Get-Date) - $script:advisorStarted).TotalMilliseconds } else { $null })
        text   = $shownText
        reason = $reason
        window = $script:currentKey
      }) | ConvertTo-Json -Compress)

  # 「你在做：xxx」= 没说话，只是在告诉用户"我看懂了"。自动模式下不打扰，手动问你时才显示。
  # 判定口径统一在 Test-SilentText —— 别再在这里写字符串匹配，四个大脑的输出文字不一致。
  $silent = Test-SilentText $shownText
  Add-History -Text $shownText -Reason $reason -Silent $silent
  if ($script:suppressShow) {
    $script:suppressShow = $false
  } elseif ($script:autoAsk -and $silent) {
    # 自动模式下它决定不说：不打扰，只留日志
    # 同时记账：连续沉默就退避（下一次要求更长间隔），这条完全由本地代码控制
    $script:silentStreak++
  } else {
    if ($script:autoAsk) { $script:silentStreak = 0 }
    # agent 给了选项 → 渲染成可点按钮 + 倒计时自动取消；否则普通气泡
    $opts = @()
    if ($optionsLine) { $opts = @($optionsLine -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($opts.Count -gt 0) {
      $script:pendingPrompt = $shownText
      $script:pendingOptions = $opts
      # 选项一整句一整句地来（模型的 OPTIONS: 那行）→ 先把气泡撑到放得下，
      # 放不下就由气泡那头折行；两种都不许溢出窗口。
      Set-PetWidthForOptions $opts
      $pet.ShowPrompt($shownText, $opts, [int]$(if ($cfg.optionSeconds) { $cfg.optionSeconds } else { 5 }))
    } else {
      $pet.ShowMessage($shownText, [int]$cfg.showSeconds)
    }
    # 朗读「结论句」。系统句（（…））、「你在做：…」、SILENT 都在 ConvertTo-Speakable 里被挡掉，
    # 所以这里直接丢进去即可 —— 该出声的只有真正的建议。
    [void](Speak-Text $shownText)
  }
  $script:autoAsk = $false
}

function Save-PetState {
  try {
    ([pscustomobject]@{
        x     = $pet.Location.X
        y     = $pet.Location.Y
        auto  = [bool]$pet.AutoEnabled
        muted = -not [bool]$pet.TtsEnabled   # 静音开关也记住，重启后不变
        # 派活交给哪条 agent（'' = 每次新建）。在「更多 → Agent 列表」里选。
        dispatchAgent = [string]$script:dispatchAgent
      } |
      ConvertTo-Json -Compress) | Set-Content -LiteralPath $petStatePath -Encoding UTF8
  } catch { }
}

function Load-PetState {
  if (-not (Test-Path $petStatePath)) { return $null }
  try { return (Get-Content -LiteralPath $petStatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ---------------------------------------------------------------------------
# 气泡页脚 / 定时播报余额 / 每次调用花了多少（定义在自检之前：自检里也要能调）
$script:lastCallCost = $null      # 上一次我们自己的调用花了多少（余额差）

function Get-BubbleFooter {
  <# 气泡最下方那行小字：余额 · 上次调用 · 今天。没有余额来源就返回空串（不占高度）。 #>
  $bits = @()
  try {
    $l = Get-LedgerSnapshot
    if ($l -and $l.Source -ne 'none') {
      $bits += "余额 $(Format-Money $l.Balance $l.Currency)"
      if ($script:lastCallCost -ne $null) { $bits += "上次调用 $(Format-Money ([double]$script:lastCallCost) $l.Currency)" }
      if ($l.TodayUsage -gt 0) { $bits += "今天 $(Format-Money $l.TodayUsage $l.Currency)" }
    }
  } catch { }
  if ($bits.Count -eq 0) { return '' }
  return ($bits -join ' · ')
}

function Update-BubbleFooter {
  <# 把页脚同步到窗口上（没变就不重画，省一次 Render）。 #>
  try { $pet.SetFooter((Get-BubbleFooter)) } catch { }
}

# 自检 / 导出（不需要界面）
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 打字派活的输入条：**一个长圆角输入框 + 一个发送按钮**，就这些。
#
# 为什么重做：老版本是「提示标签 + 多行大框 + 整宽按钮」三层叠在一个 460x200 的窗口里，
# 而这条路径只干一件事 —— 敲一句话派出去。三层里有两层是多余的：
# 提示挪进输入框的 placeholder，多行框换成单行长框。
#
# 视觉规则跟桌宠同一套：白底、蓝调（47,127,208 就是说话态的蓝）、圆角。
# 圆角是用 Region **真裁**出来的，不是画个圆角矩形假装 —— 不裁的话四角会是方底色。
#
# 键盘：Enter = 发送（AcceptButton），Esc = 取消（CancelButton）。
# 拖动：按住空白处可以拖走（无边框窗口没有标题栏，不给拖就没法挪）。
#
# ⚠️ 定义位置有约束：`if ($SelfTest)` 是**顶层代码**，在它之前执行。所以用它的那段自检
# （5j）要能跑，本函数必须定义在 `if ($SelfTest) {` **之前** —— 挪到后面会在自检里报
# "New-TaskInputForm 不是 cmdlet"。同理 Read-AgentTask 一起放在这儿。
# ---------------------------------------------------------------------------
function New-TaskInputForm {
  param(
    [string]$Title = '打字派活',
    [string]$Hint = '',
    [string]$OkText = '开工'
  )
  $s = [double]$script:UiScale
  $w = [int](560 * $s); $h = [int](64 * $s); $rad = [int](14 * $s)

  # 画边框要用到，供 Paint 处理器读（事件处理器里取局部变量不可靠，走 script 作用域）
  $script:TaskInputStyle = @{ Scale = $s; Radius = $rad }
  $script:TaskInputDrag = $null

  $f = New-Object System.Windows.Forms.Form
  $f.Text = $Title
  $f.FormBorderStyle = 'None'
  $f.StartPosition = 'CenterScreen'
  $f.TopMost = $true
  $f.ShowInTaskbar = $false
  $f.KeyPreview = $true
  $f.ClientSize = New-Object System.Drawing.Size $w, $h
  $f.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 251, 253)

  # 圆角外框：真裁四个角
  $outer = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = 2 * $rad
  $outer.AddArc(0, 0, $d, $d, 180, 90)
  $outer.AddArc($w - $d, 0, $d, $d, 270, 90)
  $outer.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
  $outer.AddArc(0, $h - $d, $d, $d, 90, 90)
  $outer.CloseFigure()
  $f.Region = New-Object System.Drawing.Region -ArgumentList $outer

  # 描边：Region 会裁掉最外一圈，所以往里缩半像素画
  $f.Add_Paint({
      param($sender, $e)
      $st = $script:TaskInputStyle
      if (-not $st) { return }
      $cw = $sender.ClientSize.Width; $ch = $sender.ClientSize.Height
      $rr = [int]$st.Radius; $dd = 2 * $rr
      $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $p = New-Object System.Drawing.Drawing2D.GraphicsPath
      $p.AddArc(0.5, 0.5, $dd, $dd, 180, 90)
      $p.AddArc($cw - $dd - 0.5, 0.5, $dd, $dd, 270, 90)
      $p.AddArc($cw - $dd - 0.5, $ch - $dd - 0.5, $dd, $dd, 0, 90)
      $p.AddArc(0.5, $ch - $dd - 0.5, $dd, $dd, 90, 90)
      $p.CloseFigure()
      $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 30, 40, 60)), ([float](1.0 * $st.Scale))
      try { $e.Graphics.DrawPath($pen, $p) } finally { $pen.Dispose(); $p.Dispose() }
    })

  # 输入框：**无边框**，视觉上就是外框的内侧（圆角由外层 Region 负责）
  $box = New-Object System.Windows.Forms.TextBox
  $box.BorderStyle = 'None'
  $box.Multiline = $false
  $box.BackColor = $f.BackColor
  $box.ForeColor = [System.Drawing.Color]::FromArgb(255, 26, 30, 40)
  $box.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([float](10.5 * $s))
  $btnW = [int](72 * $s)
  $box.Left = [int](18 * $s)
  $box.Width = $w - $box.Left - $btnW - [int](28 * $s)

  # 发送按钮：圆角药丸
  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = $OkText
  $ok.FlatStyle = 'Flat'
  $ok.UseVisualStyleBackColor = $false
  $ok.FlatAppearance.BorderSize = 0
  $ok.BackColor = [System.Drawing.Color]::FromArgb(255, 47, 127, 208)
  $ok.ForeColor = [System.Drawing.Color]::White
  $ok.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 62, 142, 222)
  $ok.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(255, 36, 108, 182)
  $ok.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([float](9.5 * $s))
  $btnH = [int](36 * $s)
  $ok.Size = New-Object System.Drawing.Size $btnW, $btnH
  $ok.Left = $w - $btnW - [int](14 * $s)
  $ok.Top = [int](($h - $btnH) / 2)
  $ok.DialogResult = 'OK'
  $pill = New-Object System.Drawing.Drawing2D.GraphicsPath
  $pd = $btnH
  $pill.AddArc(0, 0, $pd, $pd, 180, 90)
  $pill.AddArc($btnW - $pd, 0, $pd, $pd, 270, 90)
  $pill.AddArc($btnW - $pd, $btnH - $pd, $pd, $pd, 0, 90)
  $pill.AddArc(0, $btnH - $pd, $pd, $pd, 90, 90)
  $pill.CloseFigure()
  $ok.Region = New-Object System.Drawing.Region -ArgumentList $pill

  # 垂直居中：单行 TextBox 的高度由字体决定，放进去之后才知道
  $box.Top = [int](($h - $box.Height) / 2)

  # 提示语：**不用原生 PlaceholderText**。
  # 实测（截屏核对）：.NET 的 PlaceholderText 在控件获得焦点时就不画了，而这个框是自动聚焦的 ——
  # 结果提示语永远看不见，等于白写。所以改成一块盖在输入框上的 Label：有字就藏、没字就显。
  $hintLbl = New-Object System.Windows.Forms.Label
  $hintLbl.AutoSize = $false
  $hintLbl.Text = $Hint
  $hintLbl.Font = $box.Font
  $hintLbl.ForeColor = [System.Drawing.Color]::FromArgb(255, 152, 158, 170)
  $hintLbl.BackColor = $f.BackColor
  $hintLbl.TextAlign = 'MiddleLeft'
  # 这台机器 200% 缩放下输入框大约只放得下 16 个汉字；放不下时用省略号，别硬切一半
  $hintLbl.AutoEllipsis = $true
  $hintLbl.Cursor = 'IBeam'
  $hintLbl.Location = $box.Location
  $hintLbl.Size = New-Object System.Drawing.Size $box.Width, $box.Height
  $hintLbl.Visible = ($Hint -ne '')

  # Esc 取消：需要一个真按钮才能挂 CancelButton
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.DialogResult = 'Cancel'
  $cancel.Visible = $false
  $cancel.Size = New-Object System.Drawing.Size 1, 1

  $f.Controls.Add($box)
  $f.Controls.Add($hintLbl)
  $f.Controls.Add($ok)
  $f.Controls.Add($cancel)
  $f.AcceptButton = $ok
  $f.CancelButton = $cancel
  # 输入框与提示层挂到 Tag 上给调用方和事件处理器用 —— 事件处理器里取局部变量不可靠，走 Tag
  $f.Tag = @{ Box = $box; Hint = $hintLbl }
  $hintLbl.BringToFront()

  $f.Add_Shown({ param($sender, $e) try { $sender.Tag.Box.Focus() } catch { } })
  # 一有字就藏提示层（打字时它让开，露出光标）
  $box.Add_TextChanged({
      param($sender, $e)
      $ctx = $sender.Parent.Tag
      if ($ctx) { $ctx.Hint.Visible = [string]::IsNullOrEmpty($sender.Text) }
    })
  # 点提示语等于点输入框
  $hintLbl.Add_Click({ param($sender, $e) $ctx = $sender.Parent.Tag; if ($ctx) { try { $ctx.Box.Focus() } catch { } } })
  # 无边框窗口没有标题栏，按住空白处拖动
  $f.Add_MouseDown({ param($sender, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:TaskInputDrag = $e.Location } })
  $f.Add_MouseMove({
      param($sender, $e)
      if ($script:TaskInputDrag) {
        $sender.Left += $e.X - $script:TaskInputDrag.X
        $sender.Top += $e.Y - $script:TaskInputDrag.Y
      }
    })
  $f.Add_MouseUp({ param($sender, $e) $script:TaskInputDrag = $null })
  return $f
}

function Read-AgentTask {
  param([string]$Title = '新建 DSH agent', [string]$Hint = '它会自己在这个工作区里干活。', [string]$OkText = '开工')
  $f = New-TaskInputForm -Title $Title -Hint $Hint -OkText $OkText
  $box = if ($f.Tag) { $f.Tag.Box } else { $null }
  try {
    $result = $f.ShowDialog($pet)
    $text = if ($box) { [string]$box.Text } else { '' }
    if ($result -ne 'OK') { return '' }
    return $text.Trim()
  } finally {
    $f.Dispose()
  }
}

if ($SelfTest) {
  Write-Output '=== 1. 前台窗口 ==='
  $fgPid = [DesktopGuide.Native]::ForegroundPid()
  Write-Output ("pid={0}  process={1}  title={2}" -f $fgPid, (Get-ProcessNameSafe -ProcessId $fgPid), [DesktopGuide.Native]::ForegroundTitle())
  Write-Output '=== 2. 截图 ==='
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $b64 = [DesktopGuide.Capture]::GrabJpegBase64([int]$cfg.screenshotMaxWidth, [long]$cfg.jpegQuality)
  $sw.Stop()
  # 采样率最高的档是 0.6 秒一次，所以这个数字直接决定 UI 线程被占多少
  Write-Output ("抓屏+缩放+编码 {0} ms（约 {1} KB）—— 0.6s 采样档下这是每轮的主要开销" -f [int]$sw.Elapsed.TotalMilliseconds, [int]($b64.Length * 3 / 4 / 1024))
  $sw.Stop()
  Write-Output ("base64={0}  约 {1} KB  {2} ms" -f $b64.Length, [math]::Round($b64.Length * 3 / 4 / 1024, 1), $sw.ElapsedMilliseconds)
  Write-Output '=== 3. 桌宠构造 + 自绘 ==='
$probe = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $probe.Handle
  $img = Resolve-PetImage -Configured ([string]$cfg.petImage)
  if ($img) { $probe.SetImage($img); Write-Output "角色图：$img" }
  # 这段故意写成 Markdown：气泡是纯文本控件，必须先压成纯文本再上屏。
  # 预览图里应该是干净的中文，看不到 `**`、`#`、反引号 —— 顺便验证气泡会撑高、文字不裁剪。
  $mdSample = '**首选：**把定时轮询改成变化触发 —— 只喂 `最新那一张` 截图（# 延迟最大的坑）'
  $shownSample = ConvertTo-PlainText $mdSample
  Write-Output ("Markdown 原文 : {0}" -f $mdSample)
  Write-Output ("气泡里实际画 : {0}" -f $shownSample)
  $probe.ShowMessage($shownSample, 5)
  $out = Join-Path $runDir 'pet-preview.png'
  $probe.SavePreview($out)
  Write-Output ("桌宠窗口 {0}x{1}，带 alpha 的自绘预览已存：{2}" -f $probe.Width, $probe.Height, $out)
  $out2 = Join-Path $runDir 'pet-preview-idle.png'
$probe2 = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $probe2.Handle
  if ($img) { $probe2.SetImage($img) }
  $probe2.SavePreview($out2)
  Write-Output ("空闲态预览：{0}" -f $out2)
  $probe2.Dispose()
  $probe.Dispose()
  Write-Output '=== 4. 配置 ==='
  Write-Output ($cfg | ConvertTo-Json -Depth 3)
  Write-Output '=== 5. 判断卡片预览 ==='
$probe3 = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $probe3.Handle
  if ($img) { $probe3.SetImage($img) }
  $probe3.Width = [int][math]::Round(430 * $script:UiScale)
  $probe3.SilentCount = 128
  $fakeHistory = @(
    [pscustomobject]@{ at = '2026-10-04T13:51:00'; silent = $true; text = '（它选择不说）'; reason = '不确定屏幕上在发生什么'; trigger = 'manual'; ms = 4200 }
    [pscustomobject]@{ at = '2026-10-04T13:52:00'; silent = $false; text = '这个循环写了三遍，上面的判断可以合并'; reason = '重复代码'; trigger = 'auto'; ms = 5100 }
    [pscustomobject]@{ at = '2026-10-04T13:55:00'; silent = $true; text = '（它选择没说）'; reason = '用户只是在阅读文档'; trigger = 'auto'; ms = 3800 }
    [pscustomobject]@{ at = '2026-10-04T13:58:00'; silent = $true; text = '（它选择不说）'; reason = 'Codex 正在处理任务，属于正常等待'; trigger = 'manual'; ms = 6200 }
    [pscustomobject]@{ at = '2026-10-04T14:02:00'; silent = $true; text = '（它选择不说）'; reason = '锁屏状态，无可指出的问题'; trigger = 'auto'; ms = 3300 }
  )
  $fakeInteractions = @(
    [pscustomobject]@{ kind = 'ask' }, [pscustomobject]@{ kind = 'ask' }, [pscustomobject]@{ kind = 'ask' }
    [pscustomobject]@{ kind = 'card' }, [pscustomobject]@{ kind = 'card' }
    [pscustomobject]@{ kind = 'drag' }, [pscustomobject]@{ kind = 'auto' }
  )
  $card = Format-DecisionCard -History $fakeHistory -Interactions $fakeInteractions
  $probe3.ShowMessage($card, 0)
  $out3 = Join-Path $runDir 'pet-preview-card.png'
  $probe3.SavePreview($out3)
  Write-Output ("卡片 {0}x{1}，预览：{2}" -f $probe3.Width, $probe3.Height, $out3)
  $probe3.Dispose()
  Write-Output '=== 5p. 常驻气泡的关闭按钮（×）==='
  # 卡片这种"不会自己消失"的气泡，右上角要有一个 ×；会自己消失的气泡和
  # 正在等回答的选项气泡都不该有（前者没用，后者一收就把问题弄丢了）。
  $probeClose = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $probeClose.Handle
  $probeClose.ShowMessage('常驻消息（判断记录卡片就是这样）', 0)
  $cw = $probeClose.Width
  $cCard = $probeClose.CloseButtonRect
  $probeClose.ShowMessage('3 秒后自己消失的消息', 3)
  $cTimed = $probeClose.CloseButtonRect
  $probeClose.ShowPrompt('要我装对应的 skill 吗？', @('好', '不用'), 5)
  $cOpt = $probeClose.CloseButtonRect
  $probeClose.Dispose()
  $closeOk = [ordered]@{
    '卡片（常驻）有 ×'      = ($cCard.Width -gt 0)
    '× 不出气泡右边界'      = ($cCard.Right -le $cw - 4)
    '× 落在气泡顶部区域'    = ($cCard.Top -lt (24 * $script:UiScale))
    '自动消失的气泡没有 ×'  = ($cTimed.Width -eq 0)
    '等回答的选项气泡没有 ×' = ($cOpt.Width -eq 0)
  }
  foreach ($k in $closeOk.Keys) { Write-Output ("  {0} {1}" -f $(if ($closeOk[$k]) { '✔' } else { '✘' }), $k) }
  Write-Output ("  × {0}x{1} @({2},{3})｜气泡右侧留白 {4}px｜{5}/{6} 项通过" -f `
    $cCard.Width, $cCard.Height, $cCard.X, $cCard.Y, ($cw - $cCard.Right),
    @($closeOk.Values | Where-Object { $_ }).Count, $closeOk.Count)
  Write-Output '=== 5b. 选项交互预览 ==='
  $probe4 = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $probe4.Handle
  if ($img) { $probe4.SetImage($img) }
  $probe4.ShowPrompt('检测到你在玩 Balatro，要我装对应的 skill 吗？', @('好', '不用'), 5)
  $out4 = Join-Path $runDir 'pet-preview-options.png'
  $probe4.SavePreview($out4)
  Write-Output ("选项预览：{0}" -f $out4)
  # 再出一张「倒计时过半」的快照：进度条此刻应当只覆盖第一个按钮上边框的一部分，
  # 方便肉眼确认它确实随时间缩短（而不是一条静态装饰线）。
  $deadlineField = [DesktopGuide.PetForm].GetField('optionDeadline', [System.Reflection.BindingFlags]'NonPublic,Instance')
  if ($deadlineField) {
    $deadlineField.SetValue($probe4, (Get-Date).AddSeconds(2.5))
    $out4b = Join-Path $runDir 'pet-preview-options-mid.png'
    $probe4.SavePreview($out4b)
    Write-Output ("选项预览（过半）：{0}" -f $out4b)
  }
  $probe4.Dispose()
  # 这一张照着真实事故来：DSH 的 ask_user_question 给 4 个整句标签。
  # 老排版把它们平铺一行 → 总宽超过窗口，右边的字被窗口边缘切掉（用户截图里的那个）。
  # 现在应当折行、每个标签完整可读。
  $probe4b = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $probe4b.Handle
  if ($img) { $probe4b.SetImage($img) }
  $longOpts = @(
    '继续读完 README 并给你中文解读（推荐）'
    '接着之前中断的工作继续做'
    '解释某个具体文件或脚本'
    '其实是别的意思，我重新说一遍'
  )
  # 走一遍正常运行时用的那条路：窗口先压到 320（默认宽度附近），再让 Set-PetWidthForOptions 撑开。
  Set-PetWidth 320 -Form $probe4b
  Set-PetWidthForOptions $longOpts -Min 400 -Form $probe4b
  Write-Output ("长选项：不折行需要 {0:N0} 逻辑像素宽；320 起步被撑到 {1}" -f `
      [double]$probe4b.PromptLogicalWidth($longOpts), [int][math]::Round($probe4b.Width / $script:UiScale))
  $probe4b.ShowPrompt('你希望我做什么？', $longOpts, 45)
  $out4c = Join-Path $runDir 'pet-preview-options-long.png'
  $probe4b.SavePreview($out4c)
  Write-Output ("长选项预览（400 宽，应折行、不裁字）：{0}" -f $out4c)
  $probe4b.Dispose()
  Write-Output '=== 5c. 语音输入（录音中）预览 ==='
  $probe5 = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $probe5.Handle
  if ($img) { $probe5.SetImage($img) }
  $probe5.LongPressMs = [int]$cfg.sttLongPressMs
  $probe5.ShowListening('正在听…（松开结束，最多 20 秒）')
  $out5 = Join-Path $runDir 'pet-preview-listening.png'
  $probe5.SavePreview($out5)
  Write-Output ("录音中预览：{0}" -f $out5)
  $probe5.Dispose()
  Write-Output '=== 5e. 提问 vs 进度播报（优先级）==='
  # 复现截图里那个 bug：审批弹出后，负责"正在想… Ns"的进度播报每秒把问题文字盖掉。
  # 这里直接读私有字段 message 做断言，不靠肉眼看图。
  $probe7 = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $probe7.Handle
  if ($img) { $probe7.SetImage($img) }
  $question = "它要执行「pwsh」：往桌面写一个文件`n允许这一次吗？"
  $probe7.ShowPrompt($question, @('允许', '拒绝', '稍后'), 45)
  $msgField = [DesktopGuide.PetForm].GetField('message', [System.Reflection.BindingFlags]'NonPublic,Instance')
  $before = [string]$msgField.GetValue($probe7)
  $probe7.ShowThinking('正在想… 23s')
  $after = [string]$msgField.GetValue($probe7)
  $held = ($before -eq $after) -and ($after -eq $question)
  Write-Output ("守卫：ShowThinking 之后气泡文字 = 「{0}」  {1}" -f ($after -replace "`n", ' / '), $(if ($held) { '问题没被盖掉 ✔' } else { '被盖掉了 ✘' }))
  $out6 = Join-Path $runDir 'pet-preview-ask.png'
  $probe7.SavePreview($out6)
  Write-Output ("审批优先预览：{0}" -f $out6)
  $probe7.Dispose()
  Write-Output '=== 5d. 语音输入（STT）自检 ==='
  . (Join-Path $PSScriptRoot 'stt.ps1')
  [void](Initialize-Stt -Config $cfg)
  Write-Output (Get-SttStatus)
  Test-Stt -Count 1
  Write-Output ('输入设备：' + (([MicRec]::ListDevices()) -replace "`r?`n", ' | '))
  Write-Output '=== 5f. 右键菜单尺寸（太大 → 不方便关，所以要量）==='
  $mprobe = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $mprobe.Handle
  $mprobe.SetAgentModels(@('DeepSeek Flash', 'DeepSeek V4 Pro'))
  $mprobe.SetSettings(@('DeepSeek Flash', 'DeepSeek V4 Pro'), 'DeepSeek Flash', @('只读', '工作区可写', '完全访问'), '工作区可写')
  $cm = $mprobe.ContextMenuStrip
  $top = $cm.GetPreferredSize([System.Drawing.Size]::new(0, 0))
  Write-Output ("顶层 {0} 行 → 高约 {1}px（缩放 {2}%）" -f $cm.Items.Count, $top.Height, [int]($script:UiScale * 100))
  $more = $cm.Items | Where-Object { $_.Text -eq '更多' } | Select-Object -First 1
  $setm = $cm.Items | Where-Object { $_.Text -eq '设置' } | Select-Object -First 1
  if ($more) { Write-Output ("  「更多」{0} 项" -f $more.DropDownItems.Count) }
  if ($setm) { Write-Output ("  「设置」{0} 项" -f $setm.DropDownItems.Count) }
  Write-Output ("  顶层文字：" + (($cm.Items | ForEach-Object { if ($_.Text) { $_.Text } else { '—' } }) -join ' / '))
  Write-Output '=== 5q. Agent 列表（派活给谁）==='
  # 子菜单：第一条永远是「每次新建」，最后一条是「在气泡里看进度…」，中间是按状态标好的 agent。
  $mprobe.SetAgentList(@('agent-aaaa', 'agent-bbbb'), @('● agent-aaaa · 改 docx', '✓ agent-bbbb · 查余额'), 'agent-bbbb')
  $labels = $mprobe.AgentMenuLabels()
  foreach ($l in $labels) { Write-Output "  $l" }
  $okAgent = @(
    ($labels.Count -eq 6)                                   # 每次新建 + 分隔 + 两条 + 分隔 + 看进度
    ($labels[0] -eq '每次新建（默认）')
    ($labels[2] -eq '● agent-aaaa · 改 docx')
    ($labels[3] -eq '[x] ✓ agent-bbbb · 查余额')            # 当前派活目标带对勾
    ($labels[5] -eq '在气泡里看进度…')
  )
  Write-Output ("  5q {0}/5 项通过（选了 agent-bbbb → 菜单里 [x] 落在它身上）" -f @($okAgent | Where-Object { $_ }).Count)
  $mprobe.SetAgentList(@(), @(), '')
  $labels2 = $mprobe.AgentMenuLabels()
  Write-Output ("  清空后：{0} 条（{1}）；「每次新建」被勾上 = {2}" -f $labels2.Count, ($labels2 -join ' / '), ($labels2[0] -eq '[x] 每次新建（默认）'))
  $mprobe.Dispose()
  Write-Output '=== 5o. 气泡页脚（余额 / 上次调用 / 今天）==='
  $fprobe = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $fprobe.Handle
  if ($img) { $fprobe.SetImage($img) }
  Set-PetWidthForOptions @('好','不用') | Out-Null
  $fprobe.Width = [int][math]::Round(360 * $script:UiScale)
  $script:lastCallCost = 0.0312
  $fprobe.SetFooter((Get-BubbleFooter))
  $fprobe.ShowMessage('屏幕上有可证明的错误：第 42 行索引越界（列表长度 41）。', 0)
  $fprobe.SetFooter((Get-BubbleFooter))
  $outF = Join-Path $runDir 'pet-preview-footer.png'
  $fprobe.SavePreview($outF)
  Write-Output ("  页脚内容：『{0}』" -f (Get-BubbleFooter))
  Write-Output ("  预览：{0}" -f $outF)
  $fprobe.Dispose()
  Write-Output '=== 5g. 待机（黑屏/锁屏/睡眠）逻辑 ==='
  $sprobe = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $sprobe.Handle
  Write-Output ("  待机信号注册：{0}" -f $(if ($sprobe.StandbyHooked) { '成功（显示器电源 + 会话通知）' } else { '失败 —— 只能靠"连续抓屏失败"兜底' }))
  Write-Output ("  当前三个信号：display=$($sprobe.PowerDisplayOn) locked=$($sprobe.SessionLocked) suspended=$($sprobe.Suspended)")
  # 用假信号走一遍状态机（不去真的关显示器）
  $script:standbyProbePet = $sprobe
  $sprobe.PowerDisplayOn = $false
  $needsStandby = $sprobe.Suspended -or $sprobe.SessionLocked -or (-not $sprobe.PowerDisplayOn)
  Write-Output ("  显示器关掉后 → Test-StandbyNow = {0}" -f $needsStandby)
  $sprobe.PowerDisplayOn = $true
  $sprobe.SessionLocked = $true
  Write-Output ("  改成锁屏后   → Test-StandbyNow = {0}" -f ($sprobe.Suspended -or $sprobe.SessionLocked -or (-not $sprobe.PowerDisplayOn)))
  $sprobe.SessionLocked = $false
  $sprobe.Suspended = $true
  Write-Output ("  改成睡眠后   → Test-StandbyNow = {0}" -f ($sprobe.Suspended -or $sprobe.SessionLocked -or (-not $sprobe.PowerDisplayOn)))
  $sprobe.Suspended = $false
  Write-Output ("  全部恢复后   → Test-StandbyNow = {0}" -f ($sprobe.Suspended -or $sprobe.SessionLocked -or (-not $sprobe.PowerDisplayOn)))
  $sprobe.ShowSleeping('（待机中：显示器已关）屏幕亮了我再看。')
  $outSleep = Join-Path $runDir 'pet-preview-sleeping.png'
  $sprobe.SavePreview($outSleep)
  Write-Output ("  待机外观预览：{0}" -f $outSleep)
  $sprobe.Dispose()
  Write-Output '=== 5i. 任务档（采样节奏 + 该类任务该怎么帮）==='
  foreach ($case in @(
      @{ p = 'balatro'; t = 'Balatro' }
      @{ p = 'vlc'; t = '某电影 - VLC' }
      @{ p = 'explorer'; t = 'C:\Users' }
      @{ p = 'Code'; t = 'main.ps1 - Visual Studio Code' }
    )) {
    $tf = Get-TaskProfile -Process $case.p -Title $case.t
    Write-Output ("  {0,-28} → {1,-14} 每 {2}s 采一次**并截图** / 判断间隔 {3}s{4}" -f `
        "$($case.p) | $($case.t)", $tf.name, $tf.sample, $tf.judge, $(if ($tf.hint) { '  + 有提前建议' } else { '' }))
  }
  Write-Output '=== 5h. 本地闸门（值不值得起一次模型调用）==='
  # 拿假状态直接问闸门，不需要真的等一分钟
  # 注意指纹的字符范围是 '0'(48) 到 '?'(63)，不是十六进制 —— 别拿 'F' 当"最大"
  $zeroFp = '0' * 64
  $fullFp = '?' * 64
  $script:standby = $false
  $script:silentStreak = 0
  $script:lastFp = $zeroFp
  $script:lastJudgedFp = $zeroFp
  $script:currentKey = 'A|B'
  $script:lastJudgedKey = 'A|B'
  $script:lastJudgedAt = Get-Date
  Write-Output ("  画面没变 + 刚判过      → " + (Test-WorthAutoJudge))
  $script:lastFp = $fullFp          # 画面大改
  $script:lastJudgedAt = (Get-Date).AddSeconds(-10)
  Write-Output ("  画面大改但只过了 10 秒 → " + (Test-WorthAutoJudge))
  $script:lastJudgedAt = (Get-Date).AddMinutes(-2)
  Write-Output ("  画面大改 + 2 分钟前    → '" + (Test-WorthAutoJudge) + "'  （空 = 值得问）")
  $script:silentStreak = 3
  Write-Output ("  同上但连续 3 次没说    → " + (Test-WorthAutoJudge) + "   （退避：要等 240s）")
  $script:silentStreak = 0
  $script:lastFp = $zeroFp
  $script:lastJudgedFp = $zeroFp
  $script:lastJudgedKey = $script:currentKey
  $script:lastJudgedAt = (Get-Date).AddMinutes(-6)
  Write-Output ("  画面没变但已 6 分钟    → '" + (Test-WorthAutoJudge) + "'  （保险丝：不能一直不看）")
  $script:lastFp = $fullFp
  $script:standby = $true
  Write-Output ("  待机中                → " + (Test-WorthAutoJudge))
  $script:standby = $false
  Write-Output ("  指纹距离 最暗 vs 最亮  → " + (Get-FpDistance $zeroFp $fullFp) + "（最大 960）")
  # 编号说明：原来这块叫 5i，但 5i 已经被上面的「任务档」占了（两处撞号），
  # 采样表学习那块叫 5k 又和「路径解析」撞号 —— 一并重新编号：5l = 本块，5m = 采样表学习。
  Write-Output '=== 5l. 沉默判定口径（四个大脑的输出都要认得）==='
  # 回归：老代码只认 '选择不说'，于是默认的 DSH 大脑（自动模式走的那条）永远判不出沉默 ——
  # 退避不生效、角标不涨、沉默率恒偏低，而且自动模式下还会把「没说」当发言弹出来。
  # 下面四条就是四个 advisor 真实会输出的东西（外加未翻译的原始哨兵词），一个都不能漏。
  $silentTruth = @(
    '（它选择没说）'        # advisor-dsh.ps1 / advisor-minimax.ps1（改动前）
    '（它选择不说）'        # advisor-ollama.ps1 / advisor-openai.ps1
    '  （它选择不说）  '    # 前后带空白也要认
    'SILENT'                # 大脑原样吐出哨兵词
    'AMBIENT_SILENT'        # 带前缀的哨兵词（别的插件/大脑可能这么写）
    '（它选择没说）'        # 与第一条同族，前缀匹配的兜底
    '你在做：正在读 README'
  )
  $notSilent = @(
    '把定时轮询改成变化触发，只喂最新那张截图'
    '（大脑没有输出）'
    '（它把监控范围调回整屏了）'
    ''
  )
  $missed = @($silentTruth | Where-Object { -not (Test-SilentText $_) })
  $wrong  = @($notSilent  | Where-Object { Test-SilentText $_ })
  Write-Output ("  沉默串 {0}/{1} 识别{2}" -f ($silentTruth.Count - $missed.Count), $silentTruth.Count, $(if ($missed.Count -eq 0) { ' ✔' } else { ' ✘ 漏判：' + ($missed -join ' / ') }))
  Write-Output ("  非沉默串 {0}/{1} 不误判{2}" -f ($notSilent.Count - $wrong.Count), $notSilent.Count, $(if ($wrong.Count -eq 0) { ' ✔' } else { ' ✘ 误判：' + ($wrong -join ' / ') }))
  Write-Output '=== 5j. 打字派活输入条（一个圆角长框 + 一个发送按钮）==='
  # 这条路径只干一件事：敲一句话派出去。所以界面上只有两个东西 —— 长框和按钮。
  # 布局用断言核对，不靠肉眼看图（截图会受 DPI 缩放影响，坐标对不准）。
  $tif = New-TaskInputForm -Title '打字派活' -Hint '说一句，它去做，做完报结论' -OkText '发送'
  $null = $tif.Handle
  $tiBox = $tif.Controls | Where-Object { $_ -is [System.Windows.Forms.TextBox] } | Select-Object -First 1
  $tiBtn = $tif.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text } | Select-Object -First 1
  $tiHint = $tif.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Text } | Select-Object -First 1
  # 提示语必须自己画：原生 PlaceholderText 在获得焦点后就不画了，而这个框是自动聚焦的
  $tiHintText = if ($tiHint) { [string]$tiHint.Text } else { '' }
  $ch = $tif.ClientSize.Height
  $tiChecks = [ordered]@{
    # 注意：窗体没 Show 过时子控件的 Visible 一律是 False（要沿父链算），所以按"有文字"数按钮 ——
    # 挂 CancelButton 的那个 1x1 隐藏按钮没有文字，不会被算进来。
    '只有一个按钮'           = (@($tif.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text }).Count -eq 1)
    '输入框在按钮左边'       = ($tiBox.Right -lt $tiBtn.Left)
    '输入框占宽度六成以上'   = ($tiBox.Width -gt ($tif.ClientSize.Width * 0.6))
    '两者都垂直居中'         = ([math]::Abs(($tiBox.Top + $tiBox.Height / 2) - $ch / 2) -le 2) -and ([math]::Abs(($tiBtn.Top + $tiBtn.Height / 2) - $ch / 2) -le 2)
    '按钮不出右边界'         = ($tiBtn.Right -le $tif.ClientSize.Width)
    '提示语是自绘覆盖层'     = ($tiHintText -eq '说一句，它去做，做完报结论')
    '提示层与输入框对齐'     = ($null -ne $tiHint) -and ($tiHint.Left -eq $tiBox.Left) -and ($tiHint.Width -eq $tiBox.Width) -and ($tiHint.Top -eq $tiBox.Top)
    '提示语放不下会省略'     = ($tiHint.AutoEllipsis -eq $true)
    '没有用原生 PlaceholderText' = (-not $tiBox.PlaceholderText)
    '外框是真圆角（Region）' = ($null -ne $tif.Region)
    '按钮是真圆角（Region）' = ($null -ne $tiBtn.Region)
    '按钮文字是发送'         = ($tiBtn.Text -eq '发送')
  }
  $tiBad = @($tiChecks.Keys | Where-Object { -not $tiChecks[$_] }).Count
  foreach ($k in $tiChecks.Keys) { Write-Output ("  {0} {1}" -f $(if ($tiChecks[$k]) { '✔' } else { '✘' }), $k) }
  Write-Output ("  逻辑尺寸 {0}x{1}｜输入框 {2}x{3} @({4},{5})｜按钮 {6}x{7} @({8},{9})｜{10}/{11} 项通过" -f `
      [int]($tif.Width / $script:UiScale), [int]($tif.Height / $script:UiScale), `
      [int]($tiBox.Width / $script:UiScale), [int]($tiBox.Height / $script:UiScale), [int]($tiBox.Left / $script:UiScale), [int]($tiBox.Top / $script:UiScale), `
      [int]($tiBtn.Width / $script:UiScale), [int]($tiBtn.Height / $script:UiScale), [int]($tiBtn.Left / $script:UiScale), [int]($tiBtn.Top / $script:UiScale), `
      ($tiChecks.Count - $tiBad), $tiChecks.Count)
  $tbmp = New-Object System.Drawing.Bitmap ([int]$tif.Width), ([int]$tif.Height)
  try {
    $tif.DrawToBitmap($tbmp, [System.Drawing.Rectangle]::new(0, 0, $tbmp.Width, $tbmp.Height))
    $outTi = Join-Path $runDir 'pet-preview-taskinput.png'
    $tbmp.Save($outTi, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output ("  预览：{0}" -f $outTi)
  } finally { $tbmp.Dispose(); $tif.Dispose() }
  Write-Output '=== 5n. 账本（充值播报的数据源）==='
  $led = Get-LedgerSnapshot
  if ($led) {
    Write-Output ("  账本：$($led.Day) 余额 $(Format-Money $led.Balance $led.Currency)  今天 $(Format-Money $led.TodayUsage $led.Currency)  更新于 $([int]$led.StaleSeconds)s 前")
    Write-Output ("  充值判据：余额增加 >= $(if ($cfg.rechargeMinDelta) { $cfg.rechargeMinDelta } else { 0.5 }) 就播报（当前基线 $($script:ledgerLastBalance)）")
    Write-Output ("  卡片预览：`n" + ((Format-LedgerCard -Ledger $led) -split "`n" | ForEach-Object { '    ' + $_ }) -join "`n")
  } else {
        Write-Output '  读不到账本（没配 DeepSeek API key，也还没有本地观测记录）'
  }
  Write-Output '=== 5m. 采样表学习（模型建议 / 画面漏帧）==='
  # 用临时表跑，别动真正的 task-samples.json
  $realPath = $script:taskSamplesPath
  $script:taskSamplesPath = Join-Path $runDir 'task-samples.selftest.json'
  try {
    $script:taskSamples = $null; $script:wakeCounts = @{}
    $script:curProfile = [pscustomobject]@{ sample = 2.0 }
    [void](Set-TaskSample -Key 'probe-game' -Seconds 1.2 -Source 'model' -Why '自检')
    Write-Output ("  模型建议 1.2s → 表里记成 {0}s，来源={1}" -f `
        $script:taskSamples['probe-game'].sampleSeconds, $script:taskSamples['probe-game'].source)
    $prof = Get-TaskProfile -Process 'probe-game' -Title 'Probe Game'
    Write-Output ("  下次遇到 probe-game → 采样 {0}s（学习值覆盖默认 2s）" -f $prof.sample)
    # 真实运行时 curProfile 就是解析后的档；自检里也要这样，否则算出来的是假数
    $script:curProfile = $prof
    # 注意：判据不是"用户叫了几次"——好提醒可能只要看一眼、零交互。
    # 这里模拟的是**画面连续大跳变**（两次采样之间漏掉了东西 = 采样太慢）。
    1..2 | ForEach-Object { Note-SampleJump -Key 'probe-game' -Delta 400 }
    $before = $script:taskSamples['probe-game'].sampleSeconds
    Note-SampleJump -Key 'probe-game' -Delta 400
    $after = $script:taskSamples['probe-game'].sampleSeconds
    Write-Output ("  连续 3 次大跳变 → {0}s 降到 {1}s（来源={2}）" -f $before, $after, $script:taskSamples['probe-game'].source)
    Note-SampleJump -Key 'probe-game' -Delta 5
    Write-Output ("  画面几乎没动（跳变 5，阈值 {0}）→ 不触发" -f $([int]$cfg.jumpDeltaThreshold))
    Write-Output ("  夹取保护：请求 0.01s 会被夹到 {0}s" -f (Set-TaskSample -Key 'probe-fast' -Seconds 0.01 -Source 'model'))
  } finally {
    $script:taskSamplesPath = $realPath
    $script:taskSamples = $null
    Remove-Item -LiteralPath (Join-Path $runDir 'task-samples.selftest.json') -Force -ErrorAction SilentlyContinue
  }
  Write-Output '=== 5k. 路径解析（不再依赖本机绝对路径）==='
  # 这一块盯的是"换台机器还能不能跑"：DSH 装在哪、node/edge 在哪、配置里有没有写死本机路径。
  $dshPaths = Get-DgDshPaths
  $dgNode = Get-DgNodePath
  $dgEdge = Get-DgEdgePath
  Write-Output ("  DSH 根  : {0}" -f $(if ($dshPaths.Root) { $dshPaths.Root } else { '（未找到 —— 设 DG_DSH_ROOT）' }))
  Write-Output ("  exe     : {0}" -f $(if ($dshPaths.Exe) { $dshPaths.Exe } else { '（未找到）' }))
  Write-Output ("  cli.js  : {0}" -f $(if ($dshPaths.Cli) { $dshPaths.Cli } else { '（未找到）' }))
  Write-Output ("  dsh.cmd : {0}" -f $(if ($dshPaths.Cmd) { $dshPaths.Cmd } else { '（未找到）' }))
  Write-Output ("  node    : {0}" -f $(if ($dgNode) { $dgNode } else { '（未找到）' }))
  Write-Output ("  edge    : {0}" -f $(if ($dgEdge) { $dgEdge } else { '（未找到）' }))
  # 配置里不该再出现本机用户名或 DSH 安装盘符的字面量
  $hardRe = '[A-Za-z]:\\Users|DeepSeekHarness'
  $cfgHard = [regex]::Matches((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8), $hardRe).Count
  $agHard = [regex]::Matches((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'agents.json') -Raw -Encoding UTF8), $hardRe).Count
  $tkRoot = Expand-DgTokens '{root}\advisor-dsh.ps1'
  $pathChecks = [ordered]@{
    'DSH 根已解析'     = [bool]$dshPaths.Root
    'exe 已解析'       = [bool]$dshPaths.Exe
    'cli.js 已解析'    = [bool]$dshPaths.Cli
    'dsh.cmd 已解析'   = [bool]$dshPaths.Cmd
    '配置无机器字面量' = (($cfgHard + $agHard) -eq 0)
    '令牌 {root} 展开' = ($tkRoot -eq (Join-Path $PSScriptRoot 'advisor-dsh.ps1'))
  }
  $pBad = @($pathChecks.Keys | Where-Object { -not $pathChecks[$_] })
  foreach ($k in $pathChecks.Keys) { Write-Output ("  {0} {1}" -f $(if ($pathChecks[$k]) { '✔' } else { '✘' }), $k) }
  Write-Output ("  配置里的机器字面量：config.json $cfgHard 处，agents.json $agHard 处；{0}/{1} 项通过" -f ($pathChecks.Count - $pBad.Count), $pathChecks.Count)
  Write-Output '=== 5q. 采样节奏落地（"只在换档名时重设"是不够的）==='
  # 自检跑在定时器创建之前，所以这里装一个**假定时器**，看 Interval 有没有被真的写进去。
  # 用 pscustomobject 而不是真的 WinForms Timer：自检不该改真实节奏、也不该起消息循环。
  # 变量用 $script: 前缀，函数里读的就是它（PowerShell 的变量查找会走到脚本作用域）。
  $fakeTimer = [pscustomobject]@{ Interval = 0 }
  $script:sampleTimer = $fakeTimer
  $script:appliedSampleMs = 0
  [void](Sync-SampleCadence -Sample 0.6)       # 卡牌档（balatro）
  Write-Output ("  卡牌档 0.6s            → Interval={0}ms" -f $fakeTimer.Interval)
  [void](Sync-SampleCadence -Sample 0.42)      # 跳变学习把 balatro 调快 → 必须当场生效
  Write-Output ("  学习值热更新 → 0.42s   → Interval={0}ms（调了当场生效，不用等换档）" -f $fakeTimer.Interval)
  $keep = $fakeTimer.Interval
  [void](Sync-SampleCadence -Sample 0.42)      # 同值重复：不该重复写（写 Interval 会重排计时器）
  Write-Output ("  同一个值再算一遍       → Interval={0}ms（{1}）" -f $fakeTimer.Interval, $(if ($fakeTimer.Interval -eq $keep) { '没重复写' } else { '重复写了 —— 不该' }))
  [void](Sync-SampleCadence -Sample 0.6)       # 同规则、无学习值的另一个进程（hearthstone）
  Write-Output ("  换到同档另一个进程     → Interval={0}ms（老逻辑会停在 420）" -f $fakeTimer.Interval)
  [void](Sync-SampleCadence -Sample 0.05)      # 异常学习值：下限 300ms 必须兜住
  Write-Output ("  被学出 0.05s（异常）   → Interval={0}ms（下限 300）" -f $fakeTimer.Interval)
  # 判据是**窗口句柄**：同一个进程的两个窗口 pid 相同、句柄不同，所以能区分换窗口。
  $h1 = [DesktopGuide.Native]::ForegroundHwnd()
  Write-Output ("  前台窗口句柄           → {0}（0 = 拿不到）" -f $h1)
  $script:sampleTimer = $null
  $script:appliedSampleMs = 0
  Write-Output '=== 5r. 设置窗口（一个窗口改完 config.json）==='
  # 这一块盯两件事：(1) 界面自己的机械自检 + 存盘往返（见 settings-window.ps1 的 -SelfTest）；
  # (2) config.json 里的参数**一个都没漏** —— 需求原话是"能改的参数都提供给用户"，
  # 所以这里做的是集合比对，不是靠眼睛看。
  [void](Show-DgSettings -ConfigPath $Config -Root $PSScriptRoot -UiScale $script:UiScale -SelfTest)
  $swSchema = @(Get-DgSettingsSchema -Root $PSScriptRoot -ModelNames @())
  $swKeys = @()
  foreach ($swSec in $swSchema) { foreach ($swIt in $swSec.Items) { $swKeys += [string]$swIt.Key } }
  $swSpecial = @('region', 'taskRules')     # 这两项有专用页（区域选择器 / 规则表编辑器），不在 Items 里
  $swCfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
  $swCfgKeys = @($swCfg.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })
  $swMissing = @($swCfgKeys | Where-Object { $swKeys -notcontains $_ -and $swSpecial -notcontains $_ })
  Write-Output ("  分组 {0} 个｜可改参数 {1} 个｜专用页 {2} 个（{3}）" -f $swSchema.Count, $swKeys.Count, $swSpecial.Count, ($swSpecial -join '、'))
  Write-Output ("  config.json 参数 {0} 个 → 没进界面的：{1}" -f $swCfgKeys.Count, $(if ($swMissing.Count -gt 0) { $swMissing -join '、' } else { '无 ✔' }))
  # 接线检查：C# 那边的事件叫 SettingsRequested，PowerShell 这边必须能挂上 add_SettingsRequested。
  # 自检在"注册菜单事件"那一段代码**之前**就 exit 了，所以单独验一下这个方法存在 ——
  # 名字写错的话桌宠会直接起不来，而这种错只有到运行时才暴露。
  $swEvt = [DesktopGuide.PetForm].GetMethod('add_SettingsRequested')
  Write-Output ("  事件接线：add_SettingsRequested 存在 = {0}" -f ($null -ne $swEvt))
  Write-Output '=== 6. 朗读（TTS）==='
  # -Check 只列音色，不出声（自检不该在半夜突然开口）。
  [void](Initialize-Tts -Config $cfg)
  Test-Tts -Check
  exit 0
}

if ($Dump) {
  Sample-Once
  if ($Seconds -gt 0) {
    # 连续采样一段时间：这样轨迹和截图缓冲才有内容，对照实验才有意义
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds ([double]$cfg.sampleSeconds)
      Sample-Once
    }
  } else {
    Start-Sleep -Milliseconds 300
    Sample-Once
  }
  $p = Build-Payload
  ($p | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $payloadPath -Encoding UTF8
  Write-Output (([pscustomobject]@{
        askedAt   = $p.askedAt
        current   = $p.current
        timeline  = $p.timeline
        shotCount = $p.shots.Count
        shotKB    = @($p.shots | ForEach-Object { [math]::Round($_.Length * 3 / 4 / 1024, 1) })
        extras    = $p.extras
      }) | ConvertTo-Json -Depth 5)
  exit 0
}

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------

# 可见性诊断：真的把宠物显示出来，检查分层窗口推送是否成功，并截屏取证。
if ($VisibleTest) {
$f = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
  $null = $f.Handle
  $img = Resolve-PetImage -Configured ([string]$cfg.petImage)
  if ($img) { $f.SetImage($img) }
  $f.PlaceBottomRight(40)
  $f.Show()
  $f.ShowMessage('测试：我应该出现在屏幕右下角。', 20)
  $f.Render()
  Write-Output ("显示后：RenderCount={0} LastPushOk={1} Visible={2} Bounds={3}" -f $f.RenderCount, $f.LastPushOk, $f.Visible, $f.Bounds)
  $end = (Get-Date).AddSeconds(10)
  $shot = $false
  while ((Get-Date) -lt $end) {
    [System.Windows.Forms.Application]::DoEvents()
    $f.Render()   # 诊断：不依赖 OnPaint，直接主动推送
    Start-Sleep -Milliseconds 100
    if (-not $shot -and ((Get-Date) -gt $end.AddSeconds(-4))) {
      Add-Type -AssemblyName System.Drawing
      $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
      $full = New-Object System.Drawing.Bitmap $b.Width, $b.Height
      $g = [System.Drawing.Graphics]::FromImage($full)
      $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
      $g.Dispose()
      $r = $f.Bounds; $r.Inflate(40, 40)
      $r.Intersect((New-Object System.Drawing.Rectangle 0, 0, $b.Width, $b.Height))
      $crop = $full.Clone($r, $full.PixelFormat)
      $crop.Save((Join-Path $runDir 'visible-test.png'), [System.Drawing.Imaging.ImageFormat]::Png)
      $crop.Dispose(); $full.Dispose()
      $shot = $true
    }
  }
  Write-Output ("结束时：RenderCount={0} LastPushOk={1}" -f $f.RenderCount, $f.LastPushOk)
  $key = [uint32]0; $alpha = [byte]0; $flags = [uint32]0
  $got = [DesktopGuide.Native]::GetLayeredWindowAttributes($f.Handle, [ref]$key, [ref]$alpha, [ref]$flags)
  $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  Write-Output ("分层窗口属性查询: 成功={0} flags=0x{1:X} alpha={2} (若成功=处于属性模式，会顶掉 UpdateLayeredWindow 的内容；LastError={3})" -f $got, $flags, $alpha, $err)
  Write-Output ("截图：{0}" -f (Join-Path $runDir 'visible-test.png'))
  $f.Close()
  exit 0
}

$pet = New-Object DesktopGuide.PetForm -ArgumentList @([double]$script:UiScale, [string]$cfg.fontFamily, [double]$cfg.fontSize)
$null = $pet.Handle
$resolvedImage = Resolve-PetImage -Configured ([string]$cfg.petImage)
if ($resolvedImage) { $pet.SetImage($resolvedImage); Write-Host "角色图：$resolvedImage" }

# ---- 朗读（TTS）----
# 配置里的 ttsEnabled 决定初始静音与否；真正的开关状态随后由 pet.json 覆盖。
[void](Initialize-Tts -Config $cfg)
$pet.TtsEnabled = -not (Get-TtsMuted)
Write-Host (Get-TtsStatus)

# ---- 语音输入（STT）：长按宠物说话，松开就把它说的话交给 agent ----
. (Join-Path $PSScriptRoot 'stt.ps1')
$script:sttReady = [bool](Initialize-Stt -Config $cfg).Ready
if (-not $script:sttReady) { Write-Host (Get-SttStatus) }
$script:sttJob = $null
$script:sttDownload = $null
$pet.LongPressMs = [int]$(if ($cfg.sttLongPressMs) { $cfg.sttLongPressMs } else { 400 })

$saved = Load-PetState
if ($saved -and $saved.x -ne $null) {
  $pet.Location = New-Object System.Drawing.Point ([int]$saved.x), ([int]$saved.y)
  if ($saved.auto) { $pet.AutoEnabled = $true }
  if ($null -ne $saved.muted) { $pet.TtsEnabled = -not [bool]$saved.muted }
  # 上次选好的"派活给谁"也一起恢复（'' = 每次新建）
  if ($saved.PSObject.Properties.Name -contains 'dispatchAgent') { $script:dispatchAgent = [string]$saved.dispatchAgent }
} else {
  $pet.PlaceBottomRight(40)
}

Load-History
Load-Interactions
$script:silentTotal = Get-SilentTotalFromLog
$pet.SilentCount = [int]$script:silentTotal

# ---- DSH agent 引擎（外壳 + 引擎：我们出界面，DSH 出 agent 能力）----
$agentsConfig = Join-Path $PSScriptRoot 'agents.json'

# 原始观察日志轮换：只保留最近 logKeepDays 天（默认 7）。
# 一天的日志能到几 MB，不清理会一直涨。记忆只读最近 memoryHours，所以留几天足够回溯。
try {
  $keepDays = if ($cfg.logKeepDays) { [int]$cfg.logKeepDays } else { 7 }
  $cutDate = (Get-Date).Date.AddDays(-$keepDays)
  Get-ChildItem $logDir -Filter 'observe-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.LastWriteTime -lt $cutDate) {
      Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
      Write-Host "清理过期观察日志：$($_.Name)"
    }
  }
} catch { }
$script:AgentCfg = $null
try {
  . (Join-Path $PSScriptRoot 'dsh-agents.ps1')
  $script:AgentCfg = Get-AgentConfig -Path $agentsConfig
  $reaped = Clear-OrphanDsh -RunDir $runDir -OlderThanMinutes 15
  if ($reaped -gt 0) { Write-Host "清理了 $reaped 个占着会话的孤儿 dsh 进程" }
  Write-Host ("agent 引擎已就绪：模型 {0} 个，权限 {1} 档" -f @($script:AgentCfg.models).Count, @($script:AgentCfg.access).Count)
} catch {
  Write-Warning "agent 引擎未加载：$($_.Exception.Message)"
}

# ---- 常驻大脑：起一次，之后所有派出去的任务都走它（不再每轮起新进程）----
# 自己先写 pet.pid：大脑靠它判断"桌宠还在不在"，桌宠没了它会自己收摊，
# 免得那个常驻 DSH 运行时（一个完整 Electron 进程）被留在后台。
try { Set-Content -LiteralPath (Join-Path $runDir 'pet.pid') -Value $PID -Encoding UTF8 } catch { }
if ($script:AgentCfg -and $cfg.brainTransport) {
  try {
    if (Start-Brain -Root $PSScriptRoot -RunDir $runDir) {
      Write-Host '已在后台拉起常驻大脑（首次约 4 秒就绪；之后每个任务 1 秒级）'
    }
  } catch { Write-Warning "拉起常驻大脑失败：$($_.Exception.Message)" }
}

function Start-AgentFromPet {
  param($Model)
  $task = Read-AgentTask -Hint ("用「{0}」起一个后台 agent。它会自己在这个工作区里干活。" -f $Model.name)
  if ([string]::IsNullOrWhiteSpace($task)) { return }
  try {
    $access = $script:AgentCfg.access | Where-Object { $_.name -eq $script:AgentCfg.workAgent.access } | Select-Object -First 1
    if (-not $access) { $access = $script:AgentCfg.access[1] }
    $rec = Start-DshAgent -Task $task -Model $Model -Access $access `
      -RunDir $runDir -LogDir $logDir -Config $agentsConfig -MaxConcurrent ([int]$script:AgentCfg.maxConcurrent)
    Add-Interaction 'agent_start' "$($rec.id)|$($Model.name)"
    $pet.ShowMessage("已起 agent $($rec.id)`n模型 $($Model.name) · $($rec.access)`n右键 →「Agent 列表」看进度", [int]$cfg.showSeconds)
  } catch {
    $pet.ShowMessage("起 agent 失败：$($_.Exception.Message)", [int]$cfg.showSeconds)
  }
}

# ---- 语音/拖入把事派出去做（不再开那个自绘对话窗口）----
# 为什么：语音说的是"去做一件事"，不是"来聊天"。原来把它丢回对话栏，等于
# 让用户对着一个不渲染 Markdown 的气泡窗口干等（实测截图里等了 23 秒）。
# 现在直接起一个后台 DSH agent 去做，桌宠只负责"收到"和"做完了告诉你"。
$script:watchedAgents = @{}

# ---- 子 agent 观察：它在干什么 ----
function Get-AgentProgress {
  <#
    从 agent 的 --json 事件流尾部读"此刻在干什么"。
    实测事件类型：status / thinking / text / tool_call / tool_result / final。
    tool_call 信息量最大（能说出具体动作），所以从后往前找最后一条 tool_call，
    没有再退回 text/thinking —— 这和 advisor 那条进度显示是同一个思路。
  #>
  param([string]$LogFile, [int]$TailLines = 30)
  if (-not $LogFile -or -not (Test-Path -LiteralPath $LogFile)) { return '' }
  $lastTool = ''; $lastThink = ''; $lastText = ''
  foreach ($l in @(Get-Content -LiteralPath $LogFile -Tail $TailLines -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    if (-not $l.Trim()) { continue }
    try { $e = $l | ConvertFrom-Json } catch { continue }
    switch ([string]$e.type) {
      'tool_call' {
        $n = [string]$e.tool
        $arg = ''
        if ($e.input) {
          foreach ($k in @('file_path', 'path', 'command', 'pattern', 'task', 'prompt')) {
            if (($e.input.PSObject.Properties.Name -contains $k) -and $e.input.$k) { $arg = [string]$e.input.$k; break }
          }
          if (-not $arg) { $arg = ($e.input | ConvertTo-Json -Compress -Depth 3) }
        }
        $label = switch ($n) {
          'subagent' { '子 agent' }
          'subagent_fork' { '子 agent（fork）' }
          'workflow' { '工作流' }
          'read' { '读文件' }
          'read_image' { '看图片' }
          'write' { '写文件' }
          'edit' { '改文件' }
          'pwsh' { '跑命令' }
          'bash' { '跑命令' }
          'glob' { '找文件' }
          'grep' { '搜内容' }
          'present' { '交付文件' }
          default { $n }
        }
        $lastTool = "$label$(if ($arg) { '：' + (Shorten-Text $arg 46) })"
      }
      'text' { if ($e.text) { $lastText = [string]$e.text } }
      'thinking' { if ($e.text) { $lastThink = [string]$e.text } }
    }
  }
  if ($lastTool) { return $lastTool }
  if ($lastText) { return '正在整理结论…' }
  if ($lastThink) { return '正在想…' }
  return ''
}

function Get-ObservedAgents {
  <#
    后台在跑的 agent（含此刻的动作）。
    两个用途：① 显示在气泡里（用户看得到"它派出去的活在干什么"）；
             ② 塞进主 agent 的 payload（否则它会把"屏幕没动"误判成"用户卡住了"）。
    顺手就会覆盖到**子 agent**：agent 自己调 subagent/subagent_fork 时，
    事件流里会出现对应的 tool_call，进度行就会显示"子 agent：…"。
  #>
  if (-not $script:AgentCfg) { return @() }
  try {
    return @(Update-AgentStatus -RunDir $runDir |
      Where-Object { $_.status -eq 'running' } |
      Select-Object -Last 4 |
      ForEach-Object {
        [pscustomobject]@{
          id     = $_.id
          model  = $_.model
          access = $_.access
          task   = (Shorten-Text ([string]$_.task) 70)
          doing  = (Get-AgentProgress -LogFile $_.logFile)
        }
      })
  } catch { return @() }
}

# ---- 用户优先：用户一动手，正在跑的**自动**判断立刻让位；停手后再补 ----
function Stop-AdvisorProcess {
  <#
    杀**整棵**进程树。advisor 是三层：cmd.exe /c → pwsh → dsh。
    只 Kill 最外层的话，里面那个 dsh 会变成孤儿、继续占着会话写句柄，
    下一次判断立刻撞 "already owned by an active write handle"。
    （双击打断那条路原来只用 Kill()，这里统一成 taskkill /T /F。）
  #>
  if (-not $script:advisorProc) { return $false }
  try {
    if ($script:advisorProc.HasExited) { return $false }
    try { taskkill /PID $script:advisorProc.Id /T /F 2>&1 | Out-Null } catch { }
    if (-not $script:advisorProc.HasExited) { $script:advisorProc.Kill() }
    return $true
  } catch { return $false }
}

function Stop-AutoAdvisorForUser {
  param([string]$What = 'user')
  if (-not $script:thinking) { return $false }
  if (-not $script:autoAsk) { return $false }   # 手动那次是用户自己要的，不动它
  [void](Stop-AdvisorProcess)
  $script:thinking = $false
  $script:autoAsk = $false
  $script:pendingAutoResume = $true
  # 指纹要清掉：那一轮"已经判过"的记录是在它被打断时写下的，
  # 留着的话补跑时会被"状态没变，不必再判断"直接跳过（实测会这样）。
  $script:lastJudgedFp = $null
  Add-Interaction 'preempt' $What
  return $true
}

function Note-UserAction {
  <# 每个用户入口都调它：记时间戳（判断"用户是不是还在操作"），并让自动判断让位。 #>
  param([string]$What = '')
  $script:lastUserAt = Get-Date
  if (-not $What) { return }
  if (Stop-AutoAdvisorForUser -What $What) {
    try { $pet.ShowMessage('（先听你的 —— 自动判断已让位，等你停手再继续）', 5) } catch { }
  }
}

function Format-FileMention {
  <#
    按**原生 dsh-file-reference 的 mention 语法**格式化路径：@path，带空格/引号的用 @"path"。
    为什么要照抄这个语法：挂上 dsh-file-reference 之后，模型会收到那段原生提示
    （「@ 开头是用户显式引用的路径…需要内容时用 read 工具，没读之前不许声称看过」），
    两边用同一个语法才对得上。见 dsh-agents.ps1 里 -EnableFileRefs 那一段。
  #>
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  if ($Path -match '[\s"]') { return '@"' + ($Path -replace '"', '') + '"' }
  return '@' + $Path
}

function New-TaskTextFromDrop {
  <# 拖进来的东西 → 一段任务描述：文件按原生 mention 写，用户的话原样跟在后面。 #>
  param([string[]]$Files = @(), [string]$Text = '')
  $parts = New-Object System.Collections.ArrayList
  foreach ($f in @($Files)) { if ($f) { [void]$parts.Add((Format-FileMention $f)) } }
  if (-not [string]::IsNullOrWhiteSpace($Text)) {
    [void]$parts.Add($Text.Trim())
  } elseif (@($Files).Count -gt 0) {
    # 只丢文件、没留言：给一个最小任务，别让模型猜"你到底想干嘛"
    [void]$parts.Add('（用户没留说明）请先读这些文件，再简要说明它们是什么、有没有明显问题。')
  }
  return ($parts -join "`n")
}

function Start-PetTask {
  <# 把一句自然语言（或一串文件）变成一次后台 agent 任务。 #>
  param([string]$Task, $Model = $null)
  if ([string]::IsNullOrWhiteSpace($Task)) { return }
  if (-not $script:AgentCfg) { $pet.ShowMessage('agent 引擎没加载，做不了。', 8); return }
  try {
    if (-not $Model) {
      $want = [string]$cfg.petTaskModel
      if ($want) { $Model = $script:AgentCfg.models | Where-Object { $_.name -eq $want } | Select-Object -First 1 }
      if (-not $Model) { $Model = $script:AgentCfg.models[0] }
    }
    $access = $script:AgentCfg.access | Where-Object { $_.name -eq $script:AgentCfg.workAgent.access } | Select-Object -First 1
    if (-not $access) { $access = $script:AgentCfg.access[1] }

    # ---- 派活给指定的 agent？（更多 → Agent 列表 里选的那条）----
    # 选了一条就：① 更新它那条记录（列表里不再每次新增）② 沿用它的模型 / 权限
    # ③ 接着它的 sessionId 跑 —— 上下文不断，"刚才那个文件"这种指代才有意义。
    $reuseId = ''; $sid = ''; $reusing = $false
    if ($script:dispatchAgent) {
      $target = @(Update-AgentStatus -RunDir $runDir) | Where-Object { $_.id -eq $script:dispatchAgent } | Select-Object -First 1
      if (-not $target) {
        # 目标被清理掉了（只保留最近 keepFinished 条）→ 退回"每次新建"，并把指针清掉
        $script:dispatchAgent = ''
        Save-PetState
      } elseif ($target.status -eq 'running') {
        # 目标正忙：这次先照常新建一条（别把用户刚说的话丢了），并说明原因
        $pet.ShowMessage("$($target.id) 还在跑，这次先新建一个 agent 去做。`n（想让后来的也排队等它：等它做完再派）", 8)
      } else {
        $reuseId = [string]$target.id
        $reusing = $true
        if (($target.PSObject.Properties.Name -contains 'model') -and $target.model) {
          $m2 = $script:AgentCfg.models | Where-Object { $_.name -eq $target.model } | Select-Object -First 1
          if ($m2) { $Model = $m2 }
        }
        if (($target.PSObject.Properties.Name -contains 'access') -and $target.access) {
          $a2 = $script:AgentCfg.access | Where-Object { $_.name -eq $target.access } | Select-Object -First 1
          if ($a2) { $access = $a2 }
        }
        $sid = if (($target.PSObject.Properties.Name -contains 'sessionId') -and $target.sessionId) {
          [string]$target.sessionId
        } else {
          # 老记录没有会话字段：给它生成一个稳定的会话名，第一次派活时由 DSH 建出来
          'pet-task-' + ([string]$target.id -replace '^agent-', '')
        }
      }
    }

    # 语音派出去的多半是"查一下/改一下"这种短活，把推理强度压到 low 能明显快一截；
    # 想跟 agents.json 里配的一致就把 petTaskEffort 留空。
    # 指定了 agent 就不压 —— 那条 agent 的身份包括模型，替它改推理强度会让人意外。
    if ($cfg.petTaskEffort -and -not $reusing) {
      $Model = $Model.PSObject.Copy()
      $Model.effort = [string]$cfg.petTaskEffort
    }
    $rec = Start-DshAgent -Task $Task -Model $Model -Access $access `
      -RunDir $runDir -LogDir $logDir -Config $agentsConfig -MaxConcurrent ([int]$script:AgentCfg.maxConcurrent) `
      -UseBrain:$([bool]$cfg.brainTransport) -SessionId $sid -ReuseId $reuseId
    Add-Interaction 'task_start' "$($rec.id)|$($Model.name)$(if ($reusing) { '|reuse' } else { '' })"
    $script:watchedAgents[$rec.id] = (Get-Date).ToString('o')
    # 记下调用前的余额：跑完再读一次，差值就是"这次调用花了多少"
    try {
      $l0 = Get-LedgerSnapshot
      $script:callBalanceBefore = if ($l0 -and $l0.Source -ne 'none') { [double]$l0.Balance } else { $null }
    } catch { $script:callBalanceBefore = $null }
    $pet.ShowMessage("收到，交给 $($rec.id) 去做：`n$(Shorten-Text $Task 42)`n（做完我念给你听）", [int]$cfg.showSeconds)
    $agentTimer.Start()
  } catch {
    $pet.ShowMessage("派任务失败：$($_.Exception.Message)", 8)
  }
}

# 盯着派出去的 agent：跑完就把最后一行结果报出来（顺带念一遍）
$agentTimer = New-Object System.Windows.Forms.Timer
$agentTimer.Interval = 3000
$agentTimer.Add_Tick({
    try {
      if ($script:watchedAgents.Count -eq 0) { $agentTimer.Stop(); return }
      $agents = @(Update-AgentStatus -RunDir $runDir)
      # ---- 观察：跑着的 agent 把"此刻在干什么"显示出来 ----
      # 让位规则：正在说话/想事/录音/等应答/有选项待选时都不抢气泡。
      if ($cfg.observeAgents -and -not $script:standby -and -not $script:thinking -and -not $script:Stt.Recording -and -not $script:askPending -and -not $script:pendingOptions) {
        $running = @($agents | Where-Object { $_.status -eq 'running' -and $script:watchedAgents.ContainsKey($_.id) })
        if ($running.Count -gt 0) {
          $a0 = $running[0]
          $doing = Get-AgentProgress -LogFile $a0.logFile
          if (-not $doing) { $doing = '正在启动…' }
          $more = if ($running.Count -gt 1) { "（另外还有 $($running.Count - 1) 个在跑）" } else { '' }
          $pet.ShowThinking("$($a0.id) 正在：$doing$more")
        }
      }
      foreach ($id in @($script:watchedAgents.Keys)) {
        $a = $agents | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $a -or $a.status -eq 'running') { continue }
        $script:watchedAgents.Remove($id)
        $raw = ''
        try { $raw = Get-AgentResult -LogFile $a.logFile } catch { }
        $line = ''
        if ($raw) {
          $rows = @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
          if ($rows.Count -gt 0) { $line = Shorten-Text $rows[-1] 90 }
        }
        # 气泡是纯文本控件：agent 常回 `**29%**` 这种 Markdown，先压平再上屏/朗读
        if ($line) { try { $line = ConvertTo-PlainText $line } catch { } }
        Add-Interaction 'task_done' "$id|$($a.status)"
        # 这次调用花了多少 = 调用前后余额差（余额是实时查的，所以这个数是真的花的钱）。
        # 注意：如果这期间用户自己也在用 DSH，那个消耗会一起算进来 —— 所以文案写"这次≈"。
        if ($script:callBalanceBefore -ne $null) {
          try {
            $l1 = Get-LedgerSnapshot
            if ($l1 -and $l1.Source -ne 'none') {
              $d = [double]$script:callBalanceBefore - [double]$l1.Balance
              if ($d -ge 0) { $script:lastCallCost = [math]::Round($d, 4) }
            }
          } catch { }
          $script:callBalanceBefore = $null
        }
        try { Update-BubbleFooter } catch { }
        if ($a.status -eq 'done') {
          $pet.ShowMessage($(if ($line) { "$id 做完了：`n$line" } else { "$id 做完了（没看到结论，右键看 Agent 列表）" }), 20)
          if ($line) { try { Speak-Text $line } catch { } }
        } else {
          $pet.ShowMessage($(if ($line) { "$id 没成（$($a.status)）：`n$line" } else { "$id 没成（$($a.status)）" }), 20)
        }
      }
      if ($script:watchedAgents.Count -eq 0) { $agentTimer.Stop() }
    } catch { }
  })

# ---- 用户停下之后再继续：被让位的那次自动判断，在这里补上 ----
# 这是"用户操作优先级最高"的后半句：打断不是取消，是延期。
$priorityTimer = New-Object System.Windows.Forms.Timer
$priorityTimer.Interval = 1000
$priorityTimer.Add_Tick({
    try {
      if (-not $script:pendingAutoResume) { return }
      if ($script:thinking) { return }          # 已经在跑（可能是用户手动问的）就不插手
      if ($script:lastUserAt -ne [datetime]::MinValue) {
        $quiet = [double]$(if ($cfg.userQuietSeconds) { $cfg.userQuietSeconds } else { 6 })
        if (((Get-Date) - $script:lastUserAt).TotalSeconds -lt $quiet) { return }
      }
      $script:pendingAutoResume = $false
      Start-Advisor -Auto
    } catch { }
  })
$priorityTimer.Start()

# 启动时对账一次：把上一次运行残留的 running 记录收拾掉。
# 不加这一句的话，agentTimer 因为 watchedAgents 为空会立刻停，
# run\agents.json 里那条旧记录就永远挂着（实测挂了几小时，还带着一条假 running）。
try {
  $stale = Reset-StaleAgentRecords -RunDir $runDir
  if ($stale.Interrupted -gt 0) {
    Write-Host "已清理 $($stale.Interrupted) 条上次重启遗留的 running 记录"
  }
} catch { Write-Warning "对账 agent 记录失败（不影响使用）：$($_.Exception.Message)" }

# 设置改完要写回 agents.json，并刷新菜单上的勾选
function Save-PetConfig {
  try { ($cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Config -Encoding UTF8 } catch { }
}

function Select-MonitorRegion {
  $pet.Hide()                       # 别把桌宠自己也框进去
  Start-Sleep -Milliseconds 150
  $picker = New-Object DesktopGuide.RegionPicker
  [void]$picker.ShowDialog()
  $sel = $picker.Selected
  $cancelled = $picker.Cancelled
  $picker.Dispose()
  $pet.Show()
  if ($cancelled -or $sel.Width -lt 24 -or $sel.Height -lt 24) {
    $pet.ShowMessage('已取消框选，监控区域不变。', [int]$cfg.showSeconds)
    return
  }
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $x = $wa.X + $sel.X; $y = $wa.Y + $sel.Y
  $cfg.region = [pscustomobject]@{ x = $x; y = $y; w = $sel.Width; h = $sel.Height }
  Save-PetConfig
  $script:shots.Clear()
  Add-Interaction 'region_set' "$x,$y,$($sel.Width)x$($sel.Height)"
  $pet.ShowMessage("监控区域已设为 $($sel.Width)x$($sel.Height)`n以后只截图这一块（省 token，也更私密）。", [int]$cfg.showSeconds)
}

function Clear-MonitorRegion {
  $cfg.region = $null
  Save-PetConfig
  $script:shots.Clear()
  Add-Interaction 'region_clear'
  $pet.ShowMessage('监控区域已取消，恢复抓整个屏幕。', [int]$cfg.showSeconds)
}

# agent 说"盯这个窗口"，我们把它解析成真实矩形。
# 让模型做语义判断（该盯什么），我们做几何测量（它在哪）—— 比让它猜像素坐标可靠得多。
function Set-SpeakStyle {
  param([ValidateSet('guard', 'coach')][string]$Style)
  $src = Join-Path $PSScriptRoot "presets\$Style.txt"
  $dst = Join-Path $PSScriptRoot 'system-prompt.txt'
  if (Test-Path $src) {
    $text = Get-Content -LiteralPath $src -Raw -Encoding UTF8
    Set-Content -LiteralPath $dst -Value $text -Encoding UTF8
  }
  $cfg.speakStyle = $Style
  Save-PetConfig
  Add-Interaction 'speak_style' $Style
  if ($Style -eq 'coach') {
    $autoHint = if ($pet.AutoEnabled) { '自动检查已开着，它会连续陪练。' } else { '但自动检查目前是关的 —— 右键开「自动发言」才会连续陪练，否则还是只在你问的时候给建议。' }
    $pet.ShowMessage("已切到陪练模式：每次判断都会给出建议。`n$autoHint", [int]$cfg.showSeconds)
  } else {
    $pet.ShowMessage('已切回保守模式：只在明显的问题、反复失败、或与目标冲突时开口。', [int]$cfg.showSeconds)
  }
}

function Edit-PetFont {
  $fd = New-Object System.Windows.Forms.FontDialog
  $fd.ShowEffects = $false
  try { $fd.Font = New-Object System.Drawing.Font ($pet.GetFontFamily()), ([float]$pet.GetFontSize()) } catch { }
  if ($fd.ShowDialog($pet) -eq 'OK') {
    $cfg.fontFamily = $fd.Font.FontFamily.Name
    # 存"逻辑字号"（96dpi 下的），渲染时会再乘 DPI 缩放
    $cfg.fontSize = [math]::Round($fd.Font.Size / $script:UiScale, 2)
    Save-PetConfig
    $pet.SetTextFont([string]$cfg.fontFamily, [double]$cfg.fontSize)
    Add-Interaction 'font' "$($cfg.fontFamily) $($cfg.fontSize)"
    $pet.ShowMessage("字体已改为 $($cfg.fontFamily) $($cfg.fontSize)pt", [int]$cfg.showSeconds)
  }
  $fd.Dispose()
}

# 「所有设置」：一个窗口改完 config.json 的每个参数（schema 与界面都在 settings-window.ps1）。
# 为什么还留着上面那个「字体字号…」小对话框：换字体是高频操作，FontDialog 一步到位；
# 这个窗口是给「我想把整台机器从头调一遍」用的。
function Edit-AllSettings {
  $values = Show-DgSettings -ConfigPath $Config -Root $PSScriptRoot -UiScale $script:UiScale -OwnerForm $pet
  if (-not $values) { return }                       # 取消（$null）
  foreach ($k in $values.Keys) { $cfg[$k] = $values[$k] }
  $keys = @($values.Keys)
  Apply-PetConfigLive -Changed $keys
  Add-Interaction 'settings' ("{0} 项：{1}" -f $keys.Count, ($keys -join ','))
  if ($keys.Count -eq 0) { $pet.ShowMessage('设置窗口关掉了，没有改动。', [int]$cfg.showSeconds) }
  else { $pet.ShowMessage("设置已保存（$($keys.Count) 项）。", [int]$cfg.showSeconds) }
}

# 把刚保存的改动**当场落地**。多数键是每轮现读 $cfg 的，改了自然就生效；
# 这里要补的是"启动时读过一次、之后不再读"的那几个模块。
function Apply-PetConfigLive {
  param([string[]]$Changed = @())
  if ($Changed -contains 'fontFamily' -or $Changed -contains 'fontSize') {
    try { $pet.SetTextFont([string]$cfg.fontFamily, [double]$cfg.fontSize) } catch { }
  }
  # 采样节奏：不补这一步要等下次换任务档才生效（"调了但当时不生效"就是这么来的）
  if ($Changed -contains 'sampleSeconds' -or $Changed -contains 'minSampleSeconds' -or $Changed -contains 'maxSampleSeconds') {
    try { [void](Sync-SampleCadence -Sample ([double]$cfg.sampleSeconds)) } catch { }
  }
  if (@($Changed | Where-Object { $_ -like 'tts*' }).Count -gt 0) {
    try { [void](Initialize-Tts -Config $cfg) } catch { }
  }
  if (@($Changed | Where-Object { $_ -like 'stt*' }).Count -gt 0) {
    try { $script:sttReady = [bool](Initialize-Stt -Config $cfg).Ready } catch { }
  }
  if ($Changed -contains 'speakStyle') {
    try {
      $src = Join-Path $PSScriptRoot ("presets\$($cfg.speakStyle).txt")
      if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $PSScriptRoot 'system-prompt.txt') -Force }
    } catch { }
  }
  # 监控区域或任务规则表变了 → 之前攒的截图/任务档判据都过期了
  if ($Changed -contains 'region' -or $Changed -contains 'taskRules') { try { $script:shots.Clear() } catch { } }
}

# 供应商表：key 写到哪里、有什么用。参考那类"路径 + 供应商表"的做法，但只留我们真会读的三个。
$script:ApiKeyProviders = @(
  [pscustomobject]@{ Name = 'DeepSeek（余额 / 充值播报）'; File = 'deepseek.key'; Hint = '查余额：api.deepseek.com/user/balance（没填这里时，会自动用 run\openai.key）' }
  [pscustomobject]@{ Name = 'MiniMax（备用大脑，能看图）'; File = 'minimax.key'; Hint = 'advisor-minimax.ps1 用' }
  [pscustomobject]@{ Name = 'OpenAI（备用大脑，快）'; File = 'openai.key'; Hint = 'advisor-openai.ps1 用' }
)

function Read-ApiKeyDialog {
  <# 选供应商 + 输入 key（密码框遮住，别念在屏幕上）。留空 = 清掉这个供应商的 key。 #>
  param([int]$Preselect = 0)
  $f = New-Object System.Windows.Forms.Form
  $f.Text = '填 API key'
  $f.Size = New-Object System.Drawing.Size ([int](540 * $script:UiScale)), ([int](250 * $script:UiScale))
  $f.StartPosition = 'CenterScreen'
  $f.TopMost = $true
  $f.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', (9 * $script:UiScale)

  $lblP = New-Object System.Windows.Forms.Label
  $lblP.Text = '供应商（写进 run\<名字>.key，只存在本机）：'
  $lblP.Dock = 'Top'; $lblP.Height = [int](26 * $script:UiScale)
  $lblP.Padding = New-Object System.Windows.Forms.Padding ([int](10 * $script:UiScale)), ([int](6 * $script:UiScale)), 0, 0

  $cbo = New-Object System.Windows.Forms.ComboBox
  $cbo.Dock = 'Top'; $cbo.DropDownStyle = 'DropDownList'
  foreach ($p in $script:ApiKeyProviders) { [void]$cbo.Items.Add($p.Name) }
  $cbo.SelectedIndex = [math]::Max(0, [math]::Min($Preselect, $script:ApiKeyProviders.Count - 1))

  $lblH = New-Object System.Windows.Forms.Label
  $lblH.Dock = 'Top'; $lblH.Height = [int](30 * $script:UiScale)
  $lblH.ForeColor = [System.Drawing.Color]::DimGray
  $lblH.Padding = New-Object System.Windows.Forms.Padding ([int](10 * $script:UiScale)), ([int](4 * $script:UiScale)), 0, 0
  $updateHint = {
    $p = $script:ApiKeyProviders[[math]::Max(0, $cbo.SelectedIndex)]
    $exists = if (Test-Path -LiteralPath (Join-Path $runDir $p.File)) { '（已有，保存会覆盖）' } else { '（还没填过）' }
    $lblH.Text = "$($p.Hint)　$exists"
  }
  $cbo.Add_SelectedIndexChanged($updateHint)

  $box = New-Object System.Windows.Forms.TextBox
  $box.Dock = 'Top'
  $box.UseSystemPasswordChar = $true
  $box.Font = New-Object System.Drawing.Font 'Consolas', (10 * $script:UiScale)

  $panel = New-Object System.Windows.Forms.Panel
  $panel.Dock = 'Bottom'; $panel.Height = [int](44 * $script:UiScale)
  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = '保存'; $ok.DialogResult = 'OK'; $ok.Dock = 'Right'; $ok.Width = [int](90 * $script:UiScale)
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = '取消'; $cancel.DialogResult = 'Cancel'; $cancel.Dock = 'Right'; $cancel.Width = [int](90 * $script:UiScale)
  $panel.Controls.Add($cancel); $panel.Controls.Add($ok)

  $f.Controls.Add($box); $f.Controls.Add($lblH); $f.Controls.Add($cbo); $f.Controls.Add($lblP); $f.Controls.Add($panel)
  $f.AcceptButton = $ok; $f.CancelButton = $cancel
  & $updateHint
  $res = $f.ShowDialog($pet)
  $out = [pscustomobject]@{
    Provider = $script:ApiKeyProviders[[math]::Max(0, $cbo.SelectedIndex)]
    Key      = $box.Text.Trim()
    Ok       = ($res -eq 'OK')
  }
  $f.Dispose()
  return $out
}

function Edit-ApiKey {
  <# 填 key → 落盘 → 立刻让相关功能用上（DeepSeek 那条会马上刷新账本）。 #>
  $r = Read-ApiKeyDialog
  if (-not $r.Ok) { return }
  $path = Join-Path $runDir $r.Provider.File
  if ([string]::IsNullOrWhiteSpace($r.Key)) {
    try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
    Add-Interaction 'apikey' "$($r.Provider.File)|cleared"
    $pet.ShowMessage("已清掉 $($r.Provider.Name) 的 key。", 6)
    return
  }
  Set-Content -LiteralPath $path -Value $r.Key -Encoding UTF8 -NoNewline
  Add-Interaction 'apikey' "$($r.Provider.File)|set($($r.Key.Length) 字符)"
  if ($r.Provider.File -eq 'deepseek.key') {
    $script:ledgerWarned = $false      # 清掉"没有来源"的告警标记，让它重新读
    try { Update-Ledger } catch { }
    $pet.ShowMessage("已保存，重新读了账本：`n$(Format-LedgerCard -Ledger (Get-LedgerSnapshot))", 0)
  } else {
    $pet.ShowMessage("已保存 $($r.Provider.Name) 的 key（$($r.Key.Length) 个字符）。", 8)
  }
}

function Edit-SystemPrompt {
  $file = Join-Path $PSScriptRoot 'system-prompt.txt'
  if (-not (Test-Path $file)) { Set-Content -LiteralPath $file -Value '' -Encoding UTF8 }
  $f = New-Object System.Windows.Forms.Form
  $f.Text = '改 system prompt —— 你的指令优先级最高'
  $f.Size = New-Object System.Drawing.Size ([int](780 * $script:UiScale)), ([int](620 * $script:UiScale))
  $f.StartPosition = 'CenterScreen'
  $f.TopMost = $true
  $f.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', (9 * $script:UiScale)
  $hint = New-Object System.Windows.Forms.Label
  $hint.Dock = 'Top'; $hint.Height = [int](48 * $script:UiScale)
  $hint.Padding = New-Object System.Windows.Forms.Padding ([int](10 * $script:UiScale)), ([int](8 * $script:UiScale)), 0, 0
  $hint.ForeColor = [System.Drawing.Color]::FromArgb(90, 96, 110)
  $hint.Text = "这段会作为最高优先级追加在主 agent 的指令之后（冲突时以这里为准）。留空则不生效。改完下一次判断起作用。"
  $f.Controls.Add($hint)
  $panel = New-Object System.Windows.Forms.Panel
  $panel.Dock = 'Bottom'; $panel.Height = [int](48 * $script:UiScale)
  $save = New-Object System.Windows.Forms.Button
  $save.Text = '保存'; $save.DialogResult = 'OK'; $save.Dock = 'Right'; $save.Width = [int](90 * $script:UiScale)
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = '取消'; $cancel.DialogResult = 'Cancel'; $cancel.Dock = 'Right'; $cancel.Width = [int](90 * $script:UiScale)
  $panel.Controls.Add($save); $panel.Controls.Add($cancel)
  $f.Controls.Add($panel)
  $box = New-Object System.Windows.Forms.TextBox
  $box.Multiline = $true; $box.Dock = 'Fill'; $box.AcceptsReturn = $true; $box.ScrollBars = 'Vertical'
  $box.Font = New-Object System.Drawing.Font 'Consolas', (9.5 * $script:UiScale)
  $box.Text = (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
  $f.Controls.Add($box); $box.BringToFront()
  $f.AcceptButton = $save; $f.CancelButton = $cancel
  $r = $f.ShowDialog($pet)
  $text = $box.Text
  $f.Dispose()
  if ($r -eq 'OK') {
    Set-Content -LiteralPath $file -Value $text -Encoding UTF8
    Add-Interaction 'system_prompt' "$($text.Length) 字"
    if ([string]::IsNullOrWhiteSpace($text)) { $pet.ShowMessage('已清空自定义 prompt，恢复内置规则。', [int]$cfg.showSeconds) }
    else { $pet.ShowMessage("已保存（$($text.Length) 字），下一次判断生效。", [int]$cfg.showSeconds) }
  }
}

function Set-WatchFromAgent {
  param([string]$Target, [switch]$Quiet)
  if ([string]::IsNullOrWhiteSpace($Target)) { return $false }
  if ($Target -match '^(full|fullscreen|全屏|全部|整个屏幕)$') {
    $cfg.region = $null; Save-PetConfig; $script:shots.Clear()
    Add-Interaction 'watch_agent' 'full'
    if (-not $Quiet) { $pet.ShowMessage('（它把监控范围调回整屏了）', [int]$cfg.showSeconds) }
    return $true
  }
  $key = ($Target -replace '^["「『]|["」』]$', '').Trim()
  $wins = [DesktopGuide.Native]::ListWindows()
  $best = $null; $bestArea = 0
  foreach ($w in $wins) {
    $parts = $w -split "`u{0001}"
    if ($parts.Count -lt 2) { continue }
    if ($parts[0] -notlike "*$key*") { continue }
    if ($parts[0] -like '*随时指导*' -or $parts[0] -like '*DesktopGuide*') { continue }   # 别盯我们自己
    $r = $parts[1] -split ','
    if ($r.Count -ne 4) { continue }
    $area = [int]$r[2] * [int]$r[3]
    if ($area -gt $bestArea) { $bestArea = $area; $best = $r }
  }
  if (-not $best) { return $false }
  $cfg.region = [pscustomobject]@{ x = [int]$best[0]; y = [int]$best[1]; w = [int]$best[2]; h = [int]$best[3] }
  Save-PetConfig
  $script:shots.Clear()
  Add-Interaction 'watch_agent' "$key -> $($best -join ',')"
  if (-not $Quiet) { $pet.ShowMessage("它把监控范围收到「$key」这个窗口了。", [int]$cfg.showSeconds) }
  return $true
}

function Open-ChatPanel {
  param([string]$Text = '', [string[]]$Files = @(), [switch]$Send)
  # 空白内容 = 用户只是想跟它聊天 → 直接开 **DSH 自己的界面**（不再用自绘气泡栏）。
  # 有内容（拖进来的文字/文件、或把选项回传）时才走自绘栏那条 CLI 通路，
  # 因为 DSH 界面是另一个进程，我们没法替它往输入框里塞字。
  if (-not $Text -and @($Files).Count -eq 0) {
    # 丢给独立进程去做：首次要等 DSH Web 服务起来（十几秒），不能卡住桌宠的界面线程。
    try {
      $panel = Join-Path $PSScriptRoot 'chat-panel.ps1'
      Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $panel) -WindowStyle Hidden | Out-Null
      $pet.ShowMessage('对话窗口正在起来（首次要等 DSH 服务，十几秒）…', 8)
    } catch { $pet.ShowMessage("开对话窗口失败：$($_.Exception.Message)", 8) }
    return
  }
  $payloadFile = Join-Path $runDir 'drop.json'
  ([pscustomobject]@{ text = $Text; files = @($Files); send = [bool]$Send } | ConvertTo-Json -Depth 4 -Compress) |
    Set-Content -LiteralPath $payloadFile -Encoding UTF8
  $panel = Join-Path $PSScriptRoot 'chat-panel.ps1'
  Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $panel, '-PayloadFile', $payloadFile) -WindowStyle Hidden | Out-Null
}

function Save-AgentsConfig {
  try { ($script:AgentCfg | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $agentsConfig -Encoding UTF8 } catch { }
}

function Refresh-PetSettings {
  if (-not $script:AgentCfg) { return }
  try {
    $pet.SetSettings(
      @($script:AgentCfg.models | ForEach-Object { $_.name }), [string]$script:AgentCfg.mainAgent.model,
      @($script:AgentCfg.access | ForEach-Object { $_.name }), [string]$script:AgentCfg.workAgent.access)
  } catch { Write-Warning "刷新设置菜单失败：$($_.Exception.Message)" }
}

function Show-MainAgentSession {
  Set-PetWidth 430
  $stateFile = Join-Path $runDir 'main-agent.json'
  $sid = '（还没有）'
  if (Test-Path $stateFile) {
    try { $sid = (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).sessionId } catch { }
  }
  $lines = @(
    "主 agent（常驻会话）"
    "模型：$($script:AgentCfg.mainAgent.model)"
    "会话：$sid"
    "会话文件在 $env:USERPROFILE\.dsh\sessions\ 下，"
    "也可以在 DSH 应用里直接打开它接着聊。"
    "清空记忆：删掉 run\main-agent.json"
  )
  $pet.ShowMessage(($lines -join "`n"), 0)
}

# ---- 「更多 → Agent 列表」子菜单（派活给谁）----
# 以前这一项只在气泡里列个清单（只读）。现在它是**子菜单**：点其中一条，
# 之后的语音 / 打字 / 拖文件派活都交给它 —— 并且接着它的会话跑，上下文不断。
function Update-AgentMenu {
  <# 菜单每次弹出前刷新：agent 一直在变，子菜单得跟着变。
      标签里的 ●/✓/✗ 是状态，前面带对勾的那条就是当前派活目标。 #>
  try {
    $agents = @(Update-AgentStatus -RunDir $runDir)
    $recent = @($agents | Select-Object -Last 6)
    $ids = @(); $labels = @()
    foreach ($a in $recent) {
      $mark = switch ($a.status) { 'running' { '●' } 'done' { '✓' } 'failed' { '✗' } default { '○' } }
      $ids += [string]$a.id
      $labels += ("{0} {1} · {2}" -f $mark, $a.id, (Shorten-Text $a.task 14))
    }
    $pet.SetAgentList([string[]]$ids, [string[]]$labels, [string]$script:dispatchAgent)
  } catch {
    try { $pet.SetAgentList([string[]]@(), [string[]]@(), [string]$script:dispatchAgent) } catch { }
  }
}

function Show-AgentList {
  Set-PetWidth 480
  try {
    $agents = @(Update-AgentStatus -RunDir $runDir)
    if ($agents.Count -eq 0) {
      $pet.ShowMessage('还没有 agent。右键 →「新建 agent」。', [int]$cfg.showSeconds)
      return
    }
    $running = @($agents | Where-Object { $_.status -eq 'running' }).Count
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("DSH agent：$($agents.Count) 个（在跑 $running）")
    foreach ($a in ($agents | Select-Object -Last 6)) {
      $mark = switch ($a.status) { 'running' { '●' } 'done' { '✓' } 'failed' { '✗' } default { '○' } }
      $task = Shorten-Text $a.task 26
      [void]$lines.Add("$mark $($a.id) · $($a.model) · $($a.access)")
      [void]$lines.Add("      $task")
    }
    $pet.ShowMessage(($lines -join "`n"), 0)
  } catch {
    $pet.ShowMessage("读 agent 列表失败：$($_.Exception.Message)", [int]$cfg.showSeconds)
  }
}

$pet.Add_AskRequested({
    # 用户点了它 = 人一定在电脑前。如果它还停在待机里（系统通知漏了），先自愈再看，
    # 否则这一轮又会是"没有截图、只能照窗口标题猜"。
    if ($script:standby) { [void](Try-WakeFromStandby -Why '用户点了它') }
    # 它正在朗读时，这一下不是「再问一句」，而是「别说了」—— 打断优先，不再叠一次判断。
    # 为什么不做成"先停再问"：Edge 合成要 3–5 秒，用户点下去就是想让它闭嘴，
    # 这时再起一轮判断只会在几秒后冒出第二段话，等于没打断。
    if (Test-TtsSpeaking) {
      Note-UserAction 'interrupt'
      Add-Interaction 'interrupt' 'click'
      [void](Stop-Tts)
      $pet.ShowMessage('（不说了）', 3)
      return
    }
    Note-UserAction 'ask'
    Add-Interaction 'ask' $pet.LastAskSource
    try { Start-Advisor } catch { Write-Warning "触发失败：$($_.Exception.Message)" }
  })

$pet.Add_MouseUp({
    Save-PetState
  })

$pet.Add_Moved({
    Note-UserAction
    Add-Interaction 'drag' ("{0},{1}" -f $pet.Location.X, $pet.Location.Y)
  })

$pet.Add_MenuOpened({
    Note-UserAction 'menu'
    Update-AgentMenu   # agent 列表是动态的，每次弹菜单前刷一遍
  })

# 屏幕开关 / 锁屏 / 睡眠 → 进待机；恢复 → 醒过来重新看一眼
$pet.Add_StandbyChanged({
    try { Sync-Standby } catch { Write-Warning "待机切换失败：$($_.Exception.Message)" }
  })

$pet.Add_AgentListRequested({
    Add-Interaction 'agents_list'
    Show-AgentList
  })

# 「派活给谁」：在 Agent 列表里点一条（或点「每次新建」）
$pet.Add_AgentPickRequested({
    try {
      $script:dispatchAgent = [string]$pet.LastAgentPicked
      Save-PetState
      Update-AgentMenu
      if ($script:dispatchAgent) {
        Add-Interaction 'dispatch_target' $script:dispatchAgent
        $pet.ShowMessage("好，之后的派活都交给 $($script:dispatchAgent)`n（接着它的会话跑，上下文不断）", [int]$cfg.showSeconds)
      } else {
        Add-Interaction 'dispatch_target' 'new'
        $pet.ShowMessage('好，之后每次都新建一个 agent。', [int]$cfg.showSeconds)
      }
    } catch { }
  })

# 「我是醒着的」：待机卡住（系统通知漏发）时的手动出口 —— 不用重启进程
$pet.Add_WakeRequested({
    try {
      Add-Interaction 'wake' 'manual'
      if ($script:standby) {
        $pet.Suspended = $false
        $pet.SessionLocked = $false
        $pet.PowerDisplayOn = $true
        Exit-Standby -Display '用户手动唤醒'
      } else {
        try { Sample-Once -Force } catch { }
        $pet.ShowMessage('好，我再看一眼。', 4)
      }
    } catch { }
  })

$pet.Add_AgentStartRequested({
    try {
      $m = $script:AgentCfg.models | Where-Object { $_.name -eq $pet.LastAgentModel } | Select-Object -First 1
      if ($m) { Start-AgentFromPet -Model $m }
    } catch { Write-Warning "起 agent 失败：$($_.Exception.Message)" }
  })

$pet.Add_ModelSelected({
    try {
      Add-Interaction 'set_model' $pet.LastSettingValue
      $script:AgentCfg.mainAgent.model = $pet.LastSettingValue
      Save-AgentsConfig
      Refresh-PetSettings
      $pet.ShowMessage("主 agent 模型已切到「$($pet.LastSettingValue)」。`n下一次判断生效（会话保留）。", [int]$cfg.showSeconds)
    } catch { $pet.ShowMessage("切换失败：$($_.Exception.Message)", [int]$cfg.showSeconds) }
  })

$pet.Add_AccessSelected({
    try {
      Add-Interaction 'set_access' $pet.LastSettingValue
      $script:AgentCfg.workAgent.access = $pet.LastSettingValue
      Save-AgentsConfig
      Refresh-PetSettings
      $pet.ShowMessage("工作 agent 权限改为「$($pet.LastSettingValue)」。`n下次新建 agent 生效。", [int]$cfg.showSeconds)
    } catch { $pet.ShowMessage("切换失败：$($_.Exception.Message)", [int]$cfg.showSeconds) }
  })

$pet.Add_MainSessionRequested({
    Add-Interaction 'main_session'
    Show-MainAgentSession
  })

$pet.Add_ChatRequested({
    Note-UserAction 'chat'
    Add-Interaction 'chat'
    Open-ChatPanel
  })

# ---- 桌面应答器：DSH 要问人的事（权限审批 / 提问 / 计划评审）在这里弹按钮 ----
# 对端是 pet-responder 插件（见 pet-responder\index.js）：它把请求写成 run\ask\req-*.json，
# 等我们写回 ans-*.json。三条路共用同一套按钮和文件协议。
$askDir = Join-Path $runDir 'ask'
$script:askPending = $null

function Send-AskAnswer {
  param([string]$Choice)
  $ask = $script:askPending
  if (-not $ask) { return }
  $body = $ask.Body
  $ansPath = Join-Path $askDir ("ans-{0}.json" -f $body.id)
  $payload = $null
  if ($body.kind -eq 'approval') {
    # 审批的词表是 allowed-once / rejected / cancelled / unavailable（多了会被规范化成 unavailable=拒绝）
    if ($Choice -eq '允许') { $payload = @{ outcome = 'allowed-once' } }
    elseif ($Choice -eq '拒绝') { $payload = @{ outcome = 'rejected' } }
    else { $payload = @{ canceled = $true } }   # 「稍后」/超时 = 没答，交回给 agent 自己决定
  } else {
    $q = @($body.questions)[0]
    if (-not $q) { $payload = @{ canceled = $true } }
    elseif (-not $Choice -or $Choice -eq '稍后') { $payload = @{ canceled = $true } }
    elseif (@($q.options).Count -gt 0) { $payload = @{ answers = @(@{ id = $q.id; selected = @($Choice) }) } }
    else { $payload = @{ answers = @(@{ id = $q.id; selected = @(); custom = $Choice }) } }
  }
  try { ($payload | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $ansPath -Encoding UTF8 } catch { }
  $script:askPending = $null
}

$askTimer = New-Object System.Windows.Forms.Timer
$askTimer.Interval = 300
$askTimer.Add_Tick({
    try {
      if ($script:askPending) {
        # 请求文件消失 = 对面已经超时或被别处回答 → 把气泡收起来
        # 请求文件消失 = 对面已经超时或被别处回答。这里必须连选项一起清，
        # 只清文字会留下三个还能点的按钮，点了会走错分支（当成 agent 的选项发回对话栏）。
        if (-not (Test-Path -LiteralPath $script:askPending.File)) {
          $script:askPending = $null
          $pet.CancelPrompt()
          Restore-PetWidthAfterPrompt
        }
        return
      }
      if ($script:sttJob -or $script:Stt.Recording) { return }   # 正在语音输入，别抢界面
      if (-not (Test-Path -LiteralPath $askDir)) { return }
      $f = Get-ChildItem -LiteralPath $askDir -Filter 'req-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -First 1
      if (-not $f) { return }
      $body = $null
      try { $body = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
      if (-not $body.id) { return }
      $script:askPending = [pscustomobject]@{ File = $f.FullName; Body = $body }
      $secs = [int]$(if ($cfg.askSeconds) { $cfg.askSeconds } else { 45 })
      if ($body.kind -eq 'approval') {
        $what = if ($body.displayReason) { $body.displayReason } elseif ($body.reason) { $body.reason } else { '这一步需要你点头' }
        # 升权类审批的 tool 字段可能是空的（实测：reason 里才有信息），别显示成"它要执行 ：…"
        $head = if ([string]::IsNullOrWhiteSpace([string]$body.tool)) { '它要升权做一步操作' } else { "它要执行「$($body.tool)」" }
        $approvalOpts = @('允许', '拒绝', '稍后')
        Set-PetWidthForOptions $approvalOpts -Min 400
        $pet.ShowPrompt("$head：$what`n允许这一次吗？", $approvalOpts, $secs)
      } else {
        $q = @($body.questions)[0]
        $labels = @(@($q.options) | ForEach-Object { $_.label })
        if (@($labels).Count -eq 0) { $labels = @('稍后') }
        # DSH 的 ask_user_question 给的是一整句一整句的标签（"继续读完 README 并给你中文解读（推荐）"），
        # 先按"不折行"把气泡撑开，撑不下再折行 —— 总之不许再溢出窗口把字切掉。
        Set-PetWidthForOptions $labels -Min 400
        $pet.ShowPrompt([string]$q.question, $labels, $secs)
      }
      Add-Interaction 'ask' ([string]$body.kind)
    } catch { }
  })
$askTimer.Start()

# agent 提出的选项：用户点了（或 5 秒超时）→ 把选择回给主 agent
$pet.Add_OptionChosen({
    try {
      Note-UserAction 'option'
      # 答完就把提问时撑开的宽度还回去（点选和超时都会走这里）
      Restore-PetWidthAfterPrompt
      # 先看这一次点击是不是在回答 DSH 的提问/审批（那条路走文件协议，不发对话栏）
      if ($script:askPending) {
        $choice = if ($pet.LastOptionIndex -ge 0) { [string]@($script:pendingOptions)[$pet.LastOptionIndex] } else { '' }
        Add-Interaction 'ask-answer' $(if ($choice) { $choice } else { 'timeout' })
        $pet.ShowMessage($(if ($choice) { "已回复：$choice" } else { '没答 —— 交回给 agent 自己决定。' }), [int]$cfg.showSeconds)
        Send-AskAnswer -Choice $choice
        return
      }
      if ($pet.LastOptionIndex -lt 0) {
        Add-Interaction 'option' 'timeout'
      } else {
        $choice = @($script:pendingOptions)[$pet.LastOptionIndex]
        Add-Interaction 'option' "$($pet.LastOptionIndex):$choice"
        $pet.ShowMessage("已选择「$choice」，正在转交给 agent…", [int]$cfg.showSeconds)
        # 复用对话栏那条已经验证过的通路把选择送回去
        Open-ChatPanel -Text "[对上一个提问我选择了：$choice]" -Send
      }
    } catch { Write-Warning "处理选项失败：$($_.Exception.Message)" }
  })

$pet.Add_PickRegionRequested({
    try { Select-MonitorRegion } catch { $pet.ShowMessage("框选失败：$($_.Exception.Message)", [int]$cfg.showSeconds) }
  })

$pet.Add_ClearRegionRequested({
    try { Clear-MonitorRegion } catch { }
  })

$pet.Add_FontRequested({
    try { Edit-PetFont } catch { $pet.ShowMessage("改字体失败：$($_.Exception.Message)", [int]$cfg.showSeconds) }
  })

$pet.Add_SettingsRequested({
    Note-UserAction 'settings'
    try { Edit-AllSettings } catch { $pet.ShowMessage("打开设置失败：$($_.Exception.Message)", [int]$cfg.showSeconds) }
  })

$pet.Add_PromptRequested({
    try { Edit-SystemPrompt } catch { $pet.ShowMessage("打开 prompt 编辑器失败：$($_.Exception.Message)", [int]$cfg.showSeconds) }
  })

$pet.Add_StyleGuardRequested({ try { Set-SpeakStyle -Style 'guard' } catch { } })
$pet.Add_StyleCoachRequested({ try { Set-SpeakStyle -Style 'coach' } catch { } })

# 拖东西到宠物身上 = 发给 agent（打开对话栏并把内容填进去，直接发）
$pet.Add_Dropped({
    try {
      Note-UserAction 'drop'
      $files = @()
      if ($pet.DroppedFiles) { $files = @($pet.DroppedFiles -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) }
      $text = [string]$pet.DroppedText
      Add-Interaction 'drop' ("files=$($files.Count);text=$($text.Length)")
      $summary = if ($files.Count -gt 0) { $files -join "`n" } else { $text }
      $pet.ShowMessage("收到，转给 agent：`n$(Shorten-Text $summary 60)", [int]$cfg.showSeconds)
      # 和语音走同一条路：派一个后台 agent 去做，不再开那个自绘对话窗口。
      # 文件用原生 @mention 语法写进任务，模型会拿到 dsh-file-reference 的原生提示去 read。
      $task = New-TaskTextFromDrop -Files $files -Text $text
      if ($task) { Start-PetTask -Task $task }
    } catch { Write-Warning "处理拖入内容失败：$($_.Exception.Message)" }
  })

if ($script:AgentCfg) {
  $pet.SetAgentModels(@($script:AgentCfg.models | ForEach-Object { $_.name }))
  Refresh-PetSettings
}

# ---- 语音输入：长按开麦 → 松开识别 → 把识别到的句子交给 agent ----
# 为什么要长按：单击已经给了「现在说一句」（那是"你来说"）。语音是"我要说"，
# 需要一个不会误触、也不用记快捷键的入口。按住期间只要挪动超过 3px 就退化成拖动。
function Stop-VoiceAndTranscribe {
  try {
    $wav = Stop-SttRecording
    if (-not $wav) { $pet.ShowMessage('没录到声音。', 4); return }
    Add-Interaction 'voice' 'recorded'
    $script:sttJob = Start-SttTranscribe -WavPath $wav
    $pet.ShowThinking('识别中…')
    $sttTimer.Start()
  } catch { $pet.ShowMessage("录音失败：$($_.Exception.Message)", 8) }
}

$pet.Add_LongPressStarted({
    try {
      Note-UserAction 'voice'
      if (-not $cfg.sttEnabled) { return }
      if ($script:sttJob) { return }   # 上一句还在识别，别叠
      if (-not $script:sttReady) {
        $pet.ShowMessage((Get-SttStatus), [int]$cfg.showSeconds)
        return
      }
      Add-Interaction 'voice' 'start'
      # 说话即打断：它还在念上一条时就先闭嘴 —— 否则朗读声会盖住用户的话，
      # 也会被录进去干扰识别。
      if (Test-TtsSpeaking) {
        [void](Stop-Tts)
        Add-Interaction 'interrupt' 'voice'
      }
      [void](Start-SttRecording)
      $pet.ShowListening("正在听…（松开结束，最多 $([int]$script:Stt.MaxSeconds) 秒）")
      $sttTimer.Start()                # 用来在超过上限时自动停止
    } catch { $pet.ShowMessage("开麦失败：$($_.Exception.Message)", 8) }
  })

$pet.Add_LongPressEnded({
    Note-UserAction
    if (-not $script:Stt.Recording) { return }   # 已经因为超时自动结束了
    Stop-VoiceAndTranscribe
  })

# ---- 打字派活：和长按说话**完全同一条下游** ----
# 区别只有一个：字是键盘敲的，不是麦克风听来的。识别那边最后一行是 Start-PetTask，
# 这里是同一句 —— 派给常驻大脑去做，做完报结论。
$pet.Add_ApiKeyRequested({
    Note-UserAction 'apikey'
    try { Edit-ApiKey } catch { $pet.ShowMessage("填 key 失败：$($_.Exception.Message)", 8) }
  })

$pet.Add_TypeRequested({
    Note-UserAction 'type'
    try {
      $text = Read-AgentTask -Title '打字派活' -OkText '发送' `
        -Hint '说一句，它去做，做完报结论'
      if ([string]::IsNullOrWhiteSpace($text)) { return }
      Add-Interaction 'type' ("text=$($text.Length)")
      Start-PetTask -Task $text
    } catch { $pet.ShowMessage("打字派活失败：$($_.Exception.Message)", 8) }
  })

$pet.Add_VoiceRequested({
    try {
      Note-UserAction 'voice-menu'
      if ($script:sttReady) {
        # 顺手把可用输入设备列出来：默认设备不一定是真麦克风（这台机器上还有 ToDesk 虚拟声卡），
        # 想换就把 config.json 的 sttDevice 改成这里的序号。
        $devs = ([MicRec]::ListDevices()) -replace "`r?`n", ' / '
        $pet.ShowMessage("长按我说话，松开就发出去。`n输入设备：$devs`n（换设备：config.json 的 sttDevice 填序号）", [int]$cfg.showSeconds)
        return
      }
      if ($script:sttDownload -and -not $script:sttDownload.HasExited) {
        $pet.ShowMessage('语音模型还在下载…', 5)
        return
      }
      if ($script:Stt.Reason -notmatch '模型未就绪') {
        $pet.ShowMessage((Get-SttStatus), [int]$cfg.showSeconds)
        return
      }
      # 缺模型 → 起一个子进程去下（229MB，能下几分钟，绝不能在界面线程里等）
      $cmd = ". '$PSScriptRoot\stt.ps1'; [void](Initialize-Stt -Config (Get-Content '$PSScriptRoot\config.json' -Raw -Encoding UTF8 | ConvertFrom-Json)); Get-SttModel | Out-Null"
      $script:sttDownload = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd) -WindowStyle Hidden -PassThru
      $pet.ShowMessage('开始下载语音模型（约 229MB）。下载完我会说一声。', 8)
      $sttTimer.Start()
    } catch { $pet.ShowMessage("下载启动失败：$($_.Exception.Message)", 8) }
  })

# 语音输入的后台推进：识别结果 / 模型下载完成 / 录太久自动停
$sttTimer = New-Object System.Windows.Forms.Timer
$sttTimer.Interval = 150
$sttTimer.Add_Tick({
    try {
      # 1) 录音中超时 → 自动停下来去识别（用户可能一直按着忘了松手）
      if ($script:Stt.Recording -and (Get-SttRecordSeconds) -ge $script:Stt.MaxSeconds) {
        Stop-VoiceAndTranscribe
        return
      }
      # 2) 模型下载完成
      if ($script:sttDownload -and $script:sttDownload.HasExited) {
        $script:sttDownload = $null
        $script:sttReady = [bool](Initialize-Stt -Config $cfg).Ready
        $pet.ShowMessage($(if ($script:sttReady) { '语音模型下好了，长按我就行。' } else { "下载似乎没成功。$(Get-SttStatus)" }), 8)
        if (-not $script:sttJob) { $sttTimer.Stop() }
        return
      }
      # 3) 识别结果
      if ($script:sttJob) {
        $r = Get-SttTranscribeResult $script:sttJob
        if (-not $r.Done) { return }
        $script:sttJob = $null
        if ($r.Error) { $pet.ShowMessage("语音输入失败：$($r.Error)", 8); $sttTimer.Stop(); return }
        if ($r.Peak -lt 0.01) {
          $pet.ShowMessage('麦克风几乎没收到声音 —— 离麦克风近一点再说一次。', 8); $sttTimer.Stop(); return
        }
        $text = [string]$r.Text
        if ([string]::IsNullOrWhiteSpace($text)) { $pet.ShowMessage('没听清，再说一次？', 5); $sttTimer.Stop(); return }
        Add-Interaction 'voice' ("text=$($text.Length)")
        $pet.ShowMessage("听清了：$text", [int]$cfg.showSeconds)
        # 不再把它丢回自绘对话窗口（那只会让人干等）；直接派一个 agent 去做。
        Start-PetTask -Task $text
        $sttTimer.Stop()
        return
      }
      if (-not $script:sttDownload) { $sttTimer.Stop() }
    } catch { }
  })

$pet.Add_HistoryRequested({
    Note-UserAction 'history'
    Add-Interaction 'card'
    try { Show-DecisionCard } catch { Write-Warning "打开记录失败：$($_.Exception.Message)" }
  })

$pet.Add_CollapseRequested({
    Note-UserAction 'collapse'
    Add-Interaction 'collapse'
    # 有提问在等回答时不许收起：收起了气泡就没了，只剩几个孤零零的按钮。
    try { Set-PetWidth 292; if (-not $pet.PromptPending) { $pet.ClearMessage() } } catch { }
  })

# 菜单里「自动发言」的文案跟着真实周期走（周期来自 config.json 的 autoMinutes）
try { $pet.AutoItemText = "自动发言（每 $([double]$cfg.autoMinutes) 分钟问一次）" } catch { }

$autoTimer = New-Object System.Windows.Forms.Timer
$autoTimer.Interval = [int]([double]$cfg.autoMinutes * 60 * 1000)
$autoTimer.Add_Tick({ try { Start-Advisor -Auto } catch { } })

$pet.Add_AutoChanged({
    try {
      Add-Interaction 'auto' $(if ($pet.AutoEnabled) { 'on' } else { 'off' })
      if ($pet.AutoEnabled) {
        $autoTimer.Start()
        $pet.ShowMessage("好，我会每 $($cfg.autoMinutes) 分钟自己看一眼；没事就不出声。", 6)
      } else {
        $autoTimer.Stop()
        $pet.ShowMessage('自动发言已关闭。', 5)
      }
      Save-PetState
    } catch { }
  })

# ---- 朗读开关 / 打断 / 重读 ----
$pet.Add_TtsChanged({
    try {
      Add-Interaction 'tts' $(if ($pet.TtsEnabled) { 'on' } else { 'off' })
      Set-TtsMuted (-not $pet.TtsEnabled)
      Save-PetState
      if ($pet.TtsEnabled) {
        $pet.ShowMessage('好，以后有建议就说给你听。', 5)
        [void](Speak-Text '好，以后有建议就说给你听。' -Force)
      } else {
        $pet.ShowMessage('已静音。想打断也可以直接双击我。', 5)
      }
    } catch { }
  })

# 双击宠物 = 打断：先停朗读；如果它正在想，这次思考也一并取消（不再出声、不再打扰）。
$pet.Add_InterruptRequested({
    try {
      # 这里只更新时间戳，不走 Note-UserAction 的"让位并补跑"：
      # 双击的意思是**明确要停**，所以下面直接把待补的那次也取消掉。
      Note-UserAction
      $script:pendingAutoResume = $false
      Add-Interaction 'interrupt'
      $wasSpeaking = [bool](Stop-Tts)
      if ($script:thinking) {
        [void](Stop-AdvisorProcess)   # 杀整棵树，别留孤儿 dsh 占着会话
        $script:thinking = $false
        $script:autoAsk = $false
        $pet.ShowMessage('（已打断）', 4)
      } elseif ($wasSpeaking) {
        $pet.ShowMessage('（不说了）', 3)
      }
    } catch { }
  })

$pet.Add_ReplayRequested({
    try {
      Add-Interaction 'tts_replay'
      if ([string]::IsNullOrWhiteSpace([string]$script:TtsLastText)) {
        $pet.ShowMessage('还没有可以重读的话。', 3)
      } else {
        [void](Speak-Text $script:TtsLastText -Force)   # 显式要求重读 → 无视静音
      }
    } catch { }
  })

$sampleTimer = New-Object System.Windows.Forms.Timer
$sampleTimer.Interval = [int]([double]$cfg.sampleSeconds * 1000)
$sampleTimer.Add_Tick({
    try {
      if ($script:standby) {
        # 待机期间不采样，但每 standbyProbeSeconds 秒做一次**自愈探测**（见 Try-WakeFromStandby）：
        # 系统通知漏一条就会一直以为在待机，用户明明坐在电脑前却再没被看过一眼。
        $gap = [double]$(if ($cfg.standbyProbeSeconds) { $cfg.standbyProbeSeconds } else { 30 })
        if (((Get-Date) - $script:lastStandbyProbe).TotalSeconds -ge $gap) {
          $script:lastStandbyProbe = Get-Date
          [void](Try-WakeFromStandby -Why '每 30 秒自检')
        }
        return
      }
      Sample-Once
    } catch { }
  })

# ---- 焦点/前台切换 = 一次采样触发 ----
# 为什么要它：定时采样最坏要等一整个采样周期才知道"用户换程序了"，
# 而换程序恰恰是最值得立刻看一眼的时刻（新窗口可能要立刻给建议，例如牌局开始）。
# 判据用**窗口句柄**而不是进程 pid：同一个进程里换窗口（两个资源管理器窗口、两个浏览器
# 窗口、VS Code 换工作区）pid 完全一样，只看 pid 会把这类切换整个漏掉 ——
# 而它对用户就是"换了个窗口"，同样值得立刻看一眼。
# **标题不参与比较**：浏览器/播放器的标题一直在变（进度、歌名），那不是切换，
# 跟着它触发只会把采样刷成噪声，而采样每次都带一张截图。
$script:lastFocusHwnd = [long]0
$focusTimer = New-Object System.Windows.Forms.Timer
$focusTimer.Interval = [int]([double]$(if ($cfg.focusWatchMs) { $cfg.focusWatchMs } else { 400 }))
$focusTimer.Add_Tick({
    try {
      $h = [DesktopGuide.Native]::ForegroundHwnd()
      if ($h -le 0) { return }
      if ($h -eq $script:lastFocusHwnd) { return }
      $script:lastFocusHwnd = $h
      # 待机中照样盯着前台窗口：窗口一换就是"人回来了"的强信号，顺手试一次自愈
      # （比等 30 秒那一拍快得多）。锁屏/显示器关时 Try-WakeFromStandby 会自己拒绝。
      if ($script:standby) { if (-not (Try-WakeFromStandby -Why '前台窗口换了')) { return } }
      Sample-Once -Force      # 换窗口立刻采一次，并且立刻截图
    } catch { }
  })
$focusTimer.Start()

# ---- 账本轮询：余额涨了就播报（充值）----
    # 20 秒一次、一次 HTTP（或读一个本地小 JSON），开销可以忽略。
$ledgerTimer = New-Object System.Windows.Forms.Timer
$ledgerTimer.Interval = [int]([double]$(if ($cfg.ledgerWatchSeconds) { $cfg.ledgerWatchSeconds } else { 20 }) * 1000)
$ledgerTimer.Add_Tick({
    try {
      if ($script:standby) { return }   # 待机时不用播报（本来就没人看）
      Update-Ledger
      Update-BubbleFooter               # 页脚跟着余额走
      # ---- 定时播报余额 ----
      $mins = [double]$(if ($cfg.balanceBroadcastMinutes) { $cfg.balanceBroadcastMinutes } else { 30 })
      if ($mins -gt 0 -and ((Get-Date) - $script:lastBalanceAnnounceAt).TotalMinutes -ge $mins) {
        $script:lastBalanceAnnounceAt = Get-Date
        $l = Get-LedgerSnapshot
        if ($l -and $l.Source -ne 'none') {
          $msg = '余额 ' + (Format-Money $l.Balance $l.Currency)
          if ($l.TodayUsage -gt 0) { $msg += ' · 今天 ' + (Format-Money $l.TodayUsage $l.Currency) }
          $pet.ShowMessage($msg, 10)
          try { [void](Speak-Text $msg) } catch { }
        }
      }
    } catch { }
  })
# 先读一次做基线：不然启动后第一拍会把"历史上那次充值"当成刚发生
try { Update-Ledger -Quiet } catch { }
$ledgerTimer.Start()
$sampleTimer.Start()

# ---------------------------------------------------------------------------
# 托盘图标 + 暂停
#
# 为什么要有：桌宠是**无边框、不在任务栏占位**的窗口，右键菜单里的「隐藏」一旦点下去
# 就没有任何东西能把它叫回来（README 里一直把「托盘」列在待办里）。
#
# 暂停的边界和 Electron 版一致，刻意划清：
#   · 停掉的是**它自己观察**的那三个定时器：采样 / 前台看门狗 / 自动判断
#   · **不停**：应答器($askTimer)、派出去的 agent 的回报($agentTimer)、朗读、账本 ——
#     那些是"你要它做的"，不是"它自己多事"。把 agent 回报也静音会让你以为活没跑。
# ---------------------------------------------------------------------------
$script:paused = $false

function Set-PetPaused {
  param([bool]$Paused)
  $script:paused = $Paused
  foreach ($t in @($sampleTimer, $focusTimer, $autoTimer)) {
    if (-not $t) { continue }
    try {
      if ($Paused) {
        $t.Stop()
      } elseif ($t -eq $autoTimer) {
        # 自动判断要尊重「自动发言」开关与待机状态（和启动时那句一样的条件）
        if ($pet.AutoEnabled -and -not $script:standby) { $t.Start() }
      } else {
        $t.Start()
      }
    } catch { }
  }
  try { Refresh-PetTray } catch { }
  try {
    $pet.ShowMessage($(if ($Paused) { '（已暂停：不再自己观察和开口。要我说话随时点我）' } else { '（继续了）' }), 6)
  } catch { }
  Write-Host "[托盘] $(if ($Paused) { '已暂停：不采样 / 不判断 / 不自动发言' } else { '已继续' })"
}

function Refresh-PetTray {
  if (-not $script:tray -or -not $script:trayMenu) { return }
  $hidden = -not $pet.Visible
  # NotifyIcon.Text 上限 63 字符，这句很短，够用
  $script:tray.Text = "泡泡 · Bloop —— $(if ($script:paused) { '已暂停' } else { '在看着' })$(if ($hidden) { '（桌宠已隐藏）' } else { '' })"
  # 菜单项文字要跟着状态改（点一次之后"隐藏桌宠"得变成"显示桌宠"）
  $script:trayMenu.Items[0].Text = $(if ($hidden) { '显示桌宠' } else { '隐藏桌宠' })
  $script:trayMenu.Items[1].Text = $(if ($script:paused) { '继续（恢复观察）' } else { '暂停（停止观察）' })
}

function Initialize-PetTray {
  try {
    $iconPath = Resolve-PetImage -Configured ([string]$cfg.petImage)
    if (-not $iconPath) { Write-Host '[托盘] 没有可用图标（config.petImage 为空且没找到角色图），跳过'; return }

    # NotifyIcon 要的是 Icon 不是 PNG：把角色图缩到 16×16 再转。
    # ⚠️ Icon.FromHandle **不复制**像素，位图必须留着（$script:trayBmp）——
    #    只留 Icon、让 Bitmap 被回收，托盘图标会变成一块空白（WinForms 的经典坑）。
    $src = [System.Drawing.Image]::FromFile($iconPath)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($src, 0, 0, 16, 16)
    $g.Dispose(); $src.Dispose()
    $script:trayBmp = $bmp
    $script:trayHicon = $bmp.GetHicon()
    $script:trayIcon = [System.Drawing.Icon]::FromHandle($script:trayHicon)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add('隐藏桌宠', $null, {
        if ($pet.Visible) { $pet.Hide() } else { $pet.Show() }
        Refresh-PetTray
      })
    [void]$menu.Items.Add('暂停（停止观察）', $null, { Set-PetPaused (-not $script:paused) })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add('看它判过什么', $null, { try { Show-DecisionCard } catch { } })
    [void]$menu.Items.Add('退出', $null, { [System.Windows.Forms.Application]::Exit() })
    $script:trayMenu = $menu

    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    $script:tray.Icon = $script:trayIcon
    $script:tray.ContextMenuStrip = $menu
    $script:tray.Visible = $true
    # 左键 = 显示/隐藏（Windows 习惯；双击会连着触发两次，效果一样，无害）
    $script:tray.Add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
          if ($pet.Visible) { $pet.Hide() } else { $pet.Show() }
          Refresh-PetTray
        }
      })
    # 宠物自己隐藏/显示（右键菜单里那段）时，托盘文字也要跟着变
    $pet.Add_VisibleChanged({ try { Refresh-PetTray } catch { } })

    Refresh-PetTray
    Write-Host '[托盘] 图标已就位：左键显示/隐藏，右键可暂停'
  } catch {
    Write-Warning "托盘没建起来（不影响其它功能）：$($_.Exception.Message)"
  }
}

Initialize-PetTray

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 500
$pollTimer.Add_Tick({ try { Complete-AdvisorIfDone } catch { } })
$pollTimer.Start()

# 朗读是「两段式」的（Edge：先合成成 wav，再播），靠这个定时器推进状态机。
# 没有它 edge 后端就只会合成、永远不出声。
$ttsTimer = New-Object System.Windows.Forms.Timer
$ttsTimer.Interval = 120
$ttsTimer.Add_Tick({ try { Update-Tts } catch { } })
$ttsTimer.Start()

$pet.Add_FormClosing({
    try { Stop-Tts | Out-Null } catch { }
    # 托盘图标不显式收掉的话，进程没了它还会挂在通知区里，要等鼠标划过才消失
    try { if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() } } catch { }
    # 退出时把常驻大脑收掉（它自己也有 pet.pid 看门狗，双保险）
    try { if ($cfg.brainTransport) { Stop-Brain -RunDir $runDir } } catch { }
    Save-PetState
  })

Sample-Once
Write-Host "桌宠已就位。左键点它 / Ctrl+Alt+G 让它说一句；拖它换位置；右键有菜单。"
Write-Host "日志：$logPath"

if ($pet.AutoEnabled) { $autoTimer.Start() }

if ($cfg.warmupOnStart -and -not [string]::IsNullOrWhiteSpace([string]$cfg.advisor)) {
  try { $script:suppressShow = $true; Start-Advisor -Auto; Write-Host '已在后台预热大脑。' } catch { }
}

# 对话界面也预热一下：DSH Web 服务首次要十几秒才起，等用户点「对话」才起会白等。
# 同样丢到独立进程里，别占界面线程。
if ($cfg.chatUi -ne 'bubbles') {
  try {
    $cmd = ". '$PSScriptRoot\web-ui.ps1'; `$c = Get-Content '$PSScriptRoot\config.json' -Raw -Encoding UTF8 | ConvertFrom-Json; Start-WebUi -Config `$c -Wait | Out-Null"
    Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -WindowStyle Hidden | Out-Null
    Write-Host '已在后台预热 DSH 界面（对话窗口会直接开）。'
  } catch { }
}

[System.Windows.Forms.Application]::Run($pet)
// ---------------------------------------------------------------------------
// 气泡页脚 + 定时播报余额 + 每次调用花了多少
// ---------------------------------------------------------------------------

