#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Blop.Core;

/// <summary>
/// 路径解析要问"外部世界"的那些事。全部走这个接口，<see cref="Paths"/> 里就没有一处直接读环境或磁盘 ——
/// 这样"解析顺序"本身才能被 <c>behavior-cases/paths.json</c> 钉住（假世界 = 一组给定的事实）。
/// </summary>
/// <remarks>
/// 为什么要这么做：路径解析是"换台机器就哑"那类 bug 的老巢（原来 11 处硬编码 D:\DeepSeekHarness）。
/// 规则是确定的（显式配置 → 环境变量 → 自动探测），但它以前只被测过"在这台机器上能解出来"，
/// 测不到"装在别处、或者只装了 DSH 没装 node 时会怎样"。
/// </remarks>
public interface IPathWorld
{
    /// <summary>读环境变量（去空白）。没设返回空串。</summary>
    string Env(string name);

    /// <summary>文件或目录存在吗（等价 Test-Path）。</summary>
    bool Exists(string path);

    /// <summary>PATH 上找命令（等价 Get-Command），拿不到返回空串。</summary>
    string PathOf(string command);

    /// <summary>从**正在运行的** DSH 进程反推安装根目录；拿不到返回空串。</summary>
    string RunningHarnessRoot();

    /// <summary>列目录里匹配的文件（等价 Get-ChildItem -Filter），拿不到就返回空。</summary>
    IEnumerable<string> ListFiles(string dir, string pattern);
}

/// <summary>真实世界：环境变量 + 文件系统 + PATH + 正在运行的 DSH 进程。</summary>
public sealed class SystemPathWorld : IPathWorld
{
    public string Env(string name)
    {
        if (string.IsNullOrEmpty(name)) return "";
        try
        {
            return (Environment.GetEnvironmentVariable(name) ?? "").Trim();
        }
        catch
        {
            return "";
        }
    }

    public bool Exists(string path)
    {
        if (string.IsNullOrEmpty(path)) return false;
        try
        {
            return File.Exists(path) || Directory.Exists(path);
        }
        catch
        {
            return false;
        }
    }

    public string PathOf(string command)
    {
        if (string.IsNullOrEmpty(command)) return "";
        try
        {
            // 等价 PowerShell 的 Get-Command：走 PATH（带 PATHEXT）
            var dirs = (Env("PATH") ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
            var exts = (Env("PATHEXT") ?? ".COM;.EXE;.BAT;.CMD")
                .Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (var raw in dirs)
            {
                var dir = raw.Trim();
                if (dir.Length == 0) continue;
                foreach (var ext in exts)
                {
                    var candidate = JoinSafe(dir, command + ext.ToLowerInvariant());
                    if (Exists(candidate)) return candidate;
                    candidate = JoinSafe(dir, command + ext);
                    if (Exists(candidate)) return candidate;
                }

                var bare = JoinSafe(dir, command);
                if (Exists(bare)) return bare;
            }
        }
        catch
        {
            // 找不到就是找不到，从不抛
        }

        return "";
    }

    public string RunningHarnessRoot()
    {
        foreach (var name in new[] { "DeepSeek Harness", "DeepSeekHarness" })
        {
            try
            {
                foreach (var p in System.Diagnostics.Process.GetProcessesByName(name))
                {
                    try
                    {
                        var file = p.MainModule?.FileName;
                        if (!string.IsNullOrEmpty(file)) return Path.GetDirectoryName(file) ?? "";
                    }
                    catch
                    {
                        // 权限不足的进程跳过
                    }
                    finally
                    {
                        p.Dispose();
                    }
                }
            }
            catch
            {
            }
        }

        return "";
    }

    public IEnumerable<string> ListFiles(string dir, string pattern)
    {
        try
        {
            return Directory.Exists(dir) ? Directory.GetFiles(dir, pattern) : Array.Empty<string>();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    private static string JoinSafe(string dir, string name)
    {
        try
        {
            return Path.Combine(dir, name);
        }
        catch
        {
            return "";
        }
    }
}
