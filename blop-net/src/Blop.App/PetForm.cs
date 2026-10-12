#nullable enable
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;
using Blop.Core;

namespace Blop.App;

/// <summary>
/// 桌宠窗口：透明、置顶、不抢焦点、可拖动、右键有菜单。
/// 第一版只有"壳" —— 还没有脑子（抓屏 / 闸门 / DSH 会话接下来往里接）。
/// </summary>
internal sealed class PetForm : Form
{
    /// <summary>角色图按这个**逻辑宽度**显示（DPI 越高物理像素越多，看着一样大）。</summary>
    private const int LogicalPetWidth = 220;

    private readonly Bitmap _pet;
    private readonly float _scale;
    private readonly PetState _state;
    private readonly NotifyIcon _tray;

    private Bitmap? _surface;
    private bool _dragging;
    private Point _grabOffset;

    public PetForm(Bitmap pet, PetState state)
    {
        _pet = pet;
        _state = state;
        _scale = DpiScale();

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Text = "泡泡 · Bloop";
        DoubleBuffered = true;
        SetStyle(
            ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer,
            true);

        var width = (int)Math.Round(LogicalPetWidth * _scale);
        var height = Math.Max(1, (int)Math.Round(width * (_pet.Height / (double)_pet.Width)));
        Size = new Size(width, height);
        Location = StartLocation(width, height);

        ContextMenuStrip = BuildMenu();
        _tray = BuildTray();
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            // 不抢焦点（点它不会把焦点/输入法从当前窗口抢走）+ 逐像素 alpha
            cp.ExStyle |= LayeredNative.WsExNoActivate | LayeredNative.WsExLayered;
            return cp;
        }
    }

    protected override void OnPaint(PaintEventArgs e) => Render();

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        // 整窗由 UpdateLayeredWindow 推上去；这里再刷一层底色只会闪
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left)
        {
            _dragging = true;
            _grabOffset = e.Location;
        }

        base.OnMouseDown(e);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (_dragging)
        {
            var screen = PointToScreen(e.Location);
            Location = new Point(screen.X - _grabOffset.X, screen.Y - _grabOffset.Y);
        }

        base.OnMouseMove(e);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (_dragging)
        {
            _dragging = false;
            _state.Save(Location.X, Location.Y);   // 位置记下来，下次起来还在原处
        }

        base.OnMouseUp(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tray.Visible = false;
            _tray.Dispose();
            _surface?.Dispose();
            _pet.Dispose();
        }

        base.Dispose(disposing);
    }

    /// <summary>
    /// 画到 32bpp ARGB 位图上，再整块推给窗口。
    /// </summary>
    /// <remarks>
    /// 已释放就直接返回：WinForms 定时器是**窗口消息**驱动的，Dispose 之后消息队列里可能还压着一拍，
    /// 谁在这时候泵消息就会对已释放的窗体 CreateHandle → 直接弹未处理异常（PS 版在自检里踩过）。
    /// </remarks>
    private void Render()
    {
        if (IsDisposed || Disposing) return;
        if (_surface is null || _surface.Width != Width || _surface.Height != Height)
        {
            _surface?.Dispose();
            _surface = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
        }

        using (var g = Graphics.FromImage(_surface))
        {
            DrawAll(g);
        }

        Push();
    }

    /// <summary>画一帧（透明底 + 角色图）。</summary>
    private void DrawAll(Graphics g)
    {
        g.Clear(Color.Transparent);
        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
        g.DrawImage(_pet, new Rectangle(0, 0, Width, Height));
    }

    /// <summary>把当前这一帧存成带 alpha 的 PNG（自检/排查用：所见即分层窗口所得）。</summary>
    public void SavePreview(string path)
    {
        using var bmp = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            DrawAll(g);
        }

        bmp.Save(path, ImageFormat.Png);
    }

    /// <summary>窗口扩展样式（自检用：确认 NOACTIVATE / LAYERED 真的挂上了）。</summary>
    public int ExStyle => LayeredNative.GetWindowLong(Handle, LayeredNative.GwlExStyle);

    private void Push()
    {
        if (_surface is null) return;
        var screenDc = LayeredNative.GetDC(IntPtr.Zero);
        var memDc = LayeredNative.CreateCompatibleDC(screenDc);
        var hBitmap = IntPtr.Zero;
        var oldBitmap = IntPtr.Zero;
        try
        {
            hBitmap = _surface.GetHbitmap(Color.FromArgb(0));
            oldBitmap = LayeredNative.SelectObject(memDc, hBitmap);
            var size = new LayeredNative.Size { cx = _surface.Width, cy = _surface.Height };
            var src = new LayeredNative.Point();
            var blend = new LayeredNative.BlendFunction
            {
                BlendOp = LayeredNative.AcSrcOver,
                BlendFlags = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = LayeredNative.AcSrcAlpha,
            };
            LayeredNative.UpdateLayeredWindow(
                Handle, screenDc, IntPtr.Zero, ref size, memDc, ref src, 0, ref blend, LayeredNative.UlwAlpha);
        }
        finally
        {
            if (hBitmap != IntPtr.Zero)
            {
                LayeredNative.SelectObject(memDc, oldBitmap);
                LayeredNative.DeleteObject(hBitmap);
            }

            LayeredNative.DeleteDC(memDc);
            LayeredNative.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip
        {
            ShowImageMargin = false,   // 去掉左边那条图标留白，菜单窄一截
            AutoClose = true,
        };
        var ask = menu.Items.Add("现在说一句（还没接上）");
        ask.Enabled = false;
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("隐藏（托盘里能叫回来）", null, (_, _) => Hide());
        menu.Items.Add("退出", null, (_, _) => Close());
        return menu;
    }

    private NotifyIcon BuildTray()
    {
        var trayMenu = new ContextMenuStrip { ShowImageMargin = false };
        trayMenu.Items.Add("显示 / 隐藏", null, (_, _) => ToggleVisible());
        trayMenu.Items.Add("退出", null, (_, _) => Close());

        var tray = new NotifyIcon
        {
            Icon = MakeIcon(),
            Text = "泡泡 · Bloop",
            Visible = true,
            ContextMenuStrip = trayMenu,
        };
        tray.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ToggleVisible();
        };
        return tray;
    }

    private void ToggleVisible()
    {
        if (Visible)
        {
            Hide();
        }
        else
        {
            Show();
            Render();
        }
    }

    private Icon MakeIcon()
    {
        // ⚠️ Icon.FromHandle **不复制**像素（句柄一销毁图标就废），所以立刻 Clone 一份再销毁句柄
        var h = _pet.GetHicon();
        try
        {
            using var raw = Icon.FromHandle(h);
            return (Icon)raw.Clone();
        }
        finally
        {
            LayeredNative.DestroyIcon(h);
        }
    }

    private Point StartLocation(int width, int height)
    {
        var screen = Screen.PrimaryScreen?.Bounds ?? new Rectangle(0, 0, 1920, 1080);
        if (_state.X is { } x && _state.Y is { } y)
        {
            // 记录的位置可能已经不在屏幕里了（拔了外接屏 / 改了分辨率）—— 夹回主屏内
            var cx = Math.Max(screen.Left, Math.Min(x, screen.Right - 40));
            var cy = Math.Max(screen.Top, Math.Min(y, screen.Bottom - 40));
            return new Point(cx, cy);
        }

        var wa = Screen.PrimaryScreen?.WorkingArea ?? screen;
        var margin = (int)Math.Round(40 * _scale);
        return new Point(wa.Right - width - margin, wa.Bottom - height - margin);
    }

    private static float DpiScale()
    {
        try
        {
            using var g = Graphics.FromHwnd(IntPtr.Zero);
            return Math.Max(1f, g.DpiX / 96f);
        }
        catch
        {
            return 1f;
        }
    }
}
