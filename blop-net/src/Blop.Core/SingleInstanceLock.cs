#nullable enable
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace Blop.Core;

/// <summary>
/// 机器级实例锁：**同时只会有一只桌宠**。
/// </summary>
/// <remarks>
/// 为什么锁文件不放在状态根里：桌宠有两种形态（独立运行 / DSH 插件外壳拉起），
/// 两种形态的状态根不同，各自的 <c>run\pet.pid</c> 互相看不见 —— 同时起就是两只桌宠、
/// 双份抓屏、双份模型开销。所以锁放在和形态无关的位置（见 <see cref="Paths.LockPath"/>）。
///
/// 判据是**进程还活着**而不是"文件在不在"：被硬杀（任务管理器、断电）时没人来删锁，
/// 文件会一直留着；只看文件的话桌宠就再也起不来了。
/// </remarks>
public sealed class SingleInstanceLock
{
    private readonly string _path;
    private readonly Func<int, bool> _isAlive;

    /// <param name="path">锁文件路径（空串 = 没有可用位置，那就退化成"不互斥"）</param>
    /// <param name="isProcessAlive">判活函数；默认走真实进程查询（测试可以注入）</param>
    public SingleInstanceLock(string path, Func<int, bool>? isProcessAlive = null)
    {
        _path = path ?? "";
        _isAlive = isProcessAlive ?? DefaultIsAlive;
    }

    /// <summary>占用者的 pid；没人占、文件坏了、或者占用者已经死了 → null。</summary>
    public int? Holder()
    {
        var pid = ReadPid();
        if (pid is null) return null;
        if (pid.Value == CurrentPid) return null;   // 自己写的锁不算"别人占着"
        return _isAlive(pid.Value) ? pid : null;
    }

    /// <summary>尝试占用。已被别人占 → false（<paramref name="heldBy"/> 给出占用者 pid）。</summary>
    public bool TryAcquire(out int? heldBy)
    {
        heldBy = Holder();
        if (heldBy is not null) return false;
        if (string.IsNullOrEmpty(_path)) return true;   // 没地方写锁：不互斥，但也不拦着自己跑
        try
        {
            var dir = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(_path, WriteBody(CurrentPid), new UTF8Encoding(false));
            return true;
        }
        catch
        {
            // 写不进去（权限/路径异常）就当没有锁：宁可多一只桌宠，也不要起不来
            return true;
        }
    }

    /// <summary>释放（只清自己的那把 —— 别人的锁不能被我删掉）。</summary>
    public void Release()
    {
        if (string.IsNullOrEmpty(_path)) return;
        try
        {
            if (ReadPid() != CurrentPid) return;
            File.Delete(_path);
        }
        catch
        {
        }
    }

    /// <summary>锁文件里记的 pid（形如 <c>{"pid":1234,…}</c>）。用正则而不是 JSON 解析：
    /// 别的实现（PowerShell 版）写进去的字段更多，格式偶尔变一下也不该让这里读不出来。</summary>
    private int? ReadPid()
    {
        if (string.IsNullOrEmpty(_path) || !File.Exists(_path)) return null;
        try
        {
            var m = Regex.Match(File.ReadAllText(_path), "\"pid\"\\s*:\\s*(\\d+)");
            return m.Success && int.TryParse(m.Groups[1].Value, out var pid) ? pid : (int?)null;
        }
        catch
        {
            return null;
        }
    }

    private static string WriteBody(int pid)
    {
        var at = DateTime.Now.ToString("o");
        var home = AppDomain.CurrentDomain.BaseDirectory.Replace("\\", "\\\\");
        return "{\"pid\":" + pid + ",\"at\":\"" + at + "\",\"form\":\"blop-net\",\"home\":\"" + home + "\"}";
    }

    private static int CurrentPid
    {
        get
        {
            try { return Process.GetCurrentProcess().Id; }
            catch { return 0; }
        }
    }

    private static bool DefaultIsAlive(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return !p.HasExited;
        }
        catch
        {
            return false;
        }
    }
}
