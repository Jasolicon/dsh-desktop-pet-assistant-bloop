#nullable enable
using System;
using System.Diagnostics;

namespace Blop.Core;

/// <summary>前台窗口的标识：进程名 + 标题（闸门用它判断"换了窗口没有"）。</summary>
public sealed record ForegroundInfo(string Process, string Title)
{
    public static readonly ForegroundInfo None = new("", "");

    /// <summary>闸门用的 key。进程名 + 标题，空的话给个占位，别让两个"不知道"互相相等。</summary>
    public string Key => string.IsNullOrEmpty(Process) && string.IsNullOrEmpty(Title)
        ? "(unknown)"
        : Process + "|" + Title;
}

/// <summary>读当前前台窗口 / 空闲时间。全部吞异常：这些信号拿不到也不该让桌宠停摆。</summary>
public static class Foreground
{
    public static ForegroundInfo Current()
    {
        try
        {
            var hwnd = NativeMethods.GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return ForegroundInfo.None;
            var title = NativeMethods.ForegroundTitle(hwnd);
            var pid = NativeMethods.ForegroundPid(hwnd);
            var name = "";
            if (pid != 0)
            {
                try
                {
                    using var p = Process.GetProcessById((int)pid);
                    name = p.ProcessName;
                }
                catch
                {
                    // 权限不足/进程已退出：只有标题也能用
                }
            }

            return new ForegroundInfo(name, title);
        }
        catch
        {
            return ForegroundInfo.None;
        }
    }

    /// <summary>用户已经多少秒没动键鼠。</summary>
    public static double IdleSeconds() => NativeMethods.IdleSeconds();
}
