#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace Blop.Core;

/// <summary>一次性提问的参数。</summary>
public sealed record OneShotOptions
{
    public string Exe { get; init; } = "";
    public string Cli { get; init; } = "";
    public string Patch { get; init; } = "";
    public string Profile { get; init; } = "headless";
    public string Prompt { get; init; } = "";
    public string Cwd { get; init; } = "";
    public int TimeoutSeconds { get; init; } = 180;

    /// <summary>
    /// 经 <c>cmd.exe /c</c> 中转一次再起 DSH。
    /// </summary>
    /// <remarks>
    /// 为什么需要这个开关（不是洁癖）：从**我们的进程**直接 CreateProcess 起 DSH 时，
    /// 子进程会在准备 profile 那一步被拒写 <c>~\.dsh\profiles\&lt;name&gt;\cordis.yml</c>
    /// （EPERM）；而同一条命令从 pwsh / cmd 里起就是好的。中转一层能绕开这个差异。
    /// </remarks>
    public bool CmdHop { get; init; }

    /// <summary>
    /// 脱离我们的句柄表启动（默认开）。
    /// </summary>
    /// <remarks>
    /// 为什么需要：<c>ProcessStartInfo</c> 走重定向时是 <c>CreateProcess(bInheritHandles=TRUE)</c>，
    /// 父进程表里**所有可继承句柄**都会漏进子进程；实测 DSH 在这种子进程里准备 profile 会被拒写
    /// <c>~\.dsh\profiles\&lt;name&gt;\cordis.yml</c>（EPERM），而同一份参数从 pwsh 起就没事。
    /// 换成 ShellExecute 起一个批处理（不继承句柄），提示词/路径一律走环境变量、
    /// 输出重定向到文件再读回来，就绕开了这个问题。
    /// </remarks>
    public bool Detached { get; init; } = true;
}

public sealed record OneShotResult(string Text, string Stdout, string Stderr, double Seconds, bool TimedOut, int ExitCode)
{
    public bool Ok => !TimedOut && ExitCode == 0 && !string.IsNullOrWhiteSpace(Text);
}

/// <summary>
/// 一次性问 DSH（<c>dsh headless "任务"</c>）：答一次、打印、退出。
/// </summary>
/// <remarks>
/// 为什么先走这条而不是常驻会话：常驻的 <c>--profile sdk</c> 那条路在本机从我们的进程里起不来
///（子进程准备 profile 时被拒写 <c>~\.dsh\profiles\sdk\cordis.yml</c>，而同样的启动从 PowerShell
/// 里跑就正常 —— 见 README 的「DSH 现状」）。一次性这条路**实测能通**：
///
///     DeepSeek Harness.exe --expose-internals &lt;cli.js&gt; headless --patch &lt;patch&gt; "只回复两个字：可用"
///     → 「可用」，4.6 秒，退出码 0
///
/// 代价是每轮都要起一个完整进程（8–25 秒，PS 版文档里的数字），比常驻会话慢一个量级。
/// 好处是它是 DSH 官方支持的一次性入口，不依赖常驻会话那套握手。
/// </remarks>
public static class DshOneShot
{
    public static OneShotResult Ask(OneShotOptions opt)
    {
        if (string.IsNullOrEmpty(opt.Exe) || string.IsNullOrEmpty(opt.Cli))
            throw new InvalidOperationException("没解出 DSH 的 exe / cli.js");

        if (opt.Detached) return AskDetached(opt);

        var inner = Quote(opt.Exe) + " --expose-internals " + Quote(opt.Cli) + " " + opt.Profile;
        if (!string.IsNullOrEmpty(opt.Patch)) inner += " --patch " + Quote(opt.Patch);
        if (!string.IsNullOrEmpty(opt.Prompt)) inner += " " + Quote(opt.Prompt);

        var args = "--expose-internals " + Quote(opt.Cli) + " " + opt.Profile;
        if (!string.IsNullOrEmpty(opt.Patch)) args += " --patch " + Quote(opt.Patch);
        if (!string.IsNullOrEmpty(opt.Prompt)) args += " " + Quote(opt.Prompt);

        var psi = new ProcessStartInfo
        {
            FileName = opt.CmdHop ? "cmd.exe" : opt.Exe,
            // cmd 的规矩：命令以引号开头时，/c 后面要用一对引号把整条命令包起来
            //（cmd 会剥掉最外那一对）；少一层会把 "D:\…\DeepSeek 当成命令名。
            Arguments = opt.CmdHop ? "/c \"" + inner + "\"" : args,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = string.IsNullOrEmpty(opt.Cwd) ? AppDomain.CurrentDomain.BaseDirectory : opt.Cwd,
        };
        psi.StandardOutputEncoding = new UTF8Encoding(false);
        psi.EnvironmentVariables["ELECTRON_RUN_AS_NODE"] = "1";

        var sw = Stopwatch.StartNew();
        using var proc = new Process { StartInfo = psi };
        proc.Start();
        // 两个流都要**同时**读：只读一个的话另一个写满管道就把子进程堵死（实测踩过）
        var outTask = proc.StandardOutput.ReadToEndAsync();
        var errTask = proc.StandardError.ReadToEndAsync();
        var exited = proc.WaitForExit(Math.Max(1000, opt.TimeoutSeconds * 1000));
        if (!exited)
        {
            try { proc.Kill(); } catch { }
            try { proc.WaitForExit(3000); } catch { }
        }

        var stdout = SafeResult(outTask);
        var stderr = SafeResult(errTask);
        sw.Stop();
        return new OneShotResult(
            LastMeaningfulLine(stdout),
            stdout,
            stderr,
            Math.Round(sw.Elapsed.TotalSeconds, 1),
            !exited,
            exited ? proc.ExitCode : -1);
    }

    /// <summary>
    /// 脱离句柄表启动：写一个只含 ASCII 的小批处理（值全部走环境变量，避免命令行引号地狱），
    /// 用 ShellExecute 起它，等它跑完再读输出文件。
    /// </summary>
    private static OneShotResult AskDetached(OneShotOptions opt)
    {
        var stamp = Guid.NewGuid().ToString("N").Substring(0, 8);
        var dir = string.IsNullOrEmpty(opt.Cwd) ? Path.GetTempPath() : opt.Cwd;
        var outFile = Path.Combine(dir, "dsh-out-" + stamp + ".txt");
        var errFile = Path.Combine(dir, "dsh-err-" + stamp + ".txt");
        var batFile = Path.Combine(dir, "dsh-run-" + stamp + ".cmd");

        // 批处理只含 ASCII（cmd 按系统码页读 .cmd，中文会变乱码并把行拆坏 —— 踩过）
        File.WriteAllText(batFile,
            "@echo off\r\n" +
            "chcp 65001 >nul\r\n" +
            "\"%BLOOP_EXE%\" --expose-internals \"%BLOOP_CLI%\" %BLOOP_PROFILE% --patch \"%BLOOP_PATCH%\" \"%BLOOP_PROMPT%\" " +
            "> \"%BLOOP_OUT%\" 2> \"%BLOOP_ERR%\"\r\n",
            new UTF8Encoding(false));

        // 值走环境变量：这条子进程不该继承我们的句柄表，但环境照常继承
        Environment.SetEnvironmentVariable("BLOOP_EXE", opt.Exe);
        Environment.SetEnvironmentVariable("BLOOP_CLI", opt.Cli);
        Environment.SetEnvironmentVariable("BLOOP_PROFILE", opt.Profile);
        Environment.SetEnvironmentVariable("BLOOP_PATCH", opt.Patch);
        Environment.SetEnvironmentVariable("BLOOP_PROMPT", (opt.Prompt ?? "").Replace("\r\n", " ").Replace('\n', ' '));
        Environment.SetEnvironmentVariable("BLOOP_OUT", outFile);
        Environment.SetEnvironmentVariable("BLOOP_ERR", errFile);
        Environment.SetEnvironmentVariable("ELECTRON_RUN_AS_NODE", "1");

        var sw = Stopwatch.StartNew();
        var psi = new ProcessStartInfo
        {
            FileName = batFile,
            UseShellExecute = true,            // 关键：走 ShellExecute，不继承父进程句柄
            WindowStyle = ProcessWindowStyle.Hidden,
            WorkingDirectory = dir,
        };
        var exited = false;
        var exitCode = -1;
        try
        {
            using var proc = Process.Start(psi);
            exited = proc is not null && proc.WaitForExit(Math.Max(1000, opt.TimeoutSeconds * 1000));
            if (proc is not null)
            {
                if (!exited)
                {
                    try { proc.Kill(); } catch { }
                }
                else
                {
                    exitCode = proc.ExitCode;
                }
            }
        }
        catch (Exception ex)
        {
            sw.Stop();
            return new OneShotResult("", "", "启动失败：" + ex.Message, Math.Round(sw.Elapsed.TotalSeconds, 1), false, -1);
        }

        sw.Stop();
        var stdout = ReadIfExists(outFile);
        var stderr = ReadIfExists(errFile);
        try { File.Delete(batFile); File.Delete(outFile); File.Delete(errFile); } catch { }
        return new OneShotResult(LastMeaningfulLine(stdout), stdout, stderr,
            Math.Round(sw.Elapsed.TotalSeconds, 1), !exited, exitCode);
    }

    private static string ReadIfExists(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path, new UTF8Encoding(false)) : "";
        }
        catch
        {
            return "";
        }
    }

    /// <summary>取最后一行非空文本 —— headless 会把结论打在最后一行。</summary>
    private static string LastMeaningfulLine(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "";
        var lines = text.Replace("\r\n", "\n").Split('\n');
        for (var i = lines.Length - 1; i >= 0; i--)
        {
            var line = lines[i].Trim();
            if (line.Length > 0) return line;
        }

        return "";
    }

    private static string SafeResult(Task<string> task)
    {
        try
        {
            return task.Wait(5000) ? task.Result : "";
        }
        catch
        {
            return "";
        }
    }

    /// <summary>
    /// 给命令行参数加引号。提示词里可能有中文引号、也可能有半角双引号 ——
    /// 半角引号直接换成单引号，免得在 Windows 命令行那层被拆开（这不是洁癖：拆开之后
    /// DSH 收到的是半截提示词，模型会一本正经地回答另一件事）。
    /// </summary>
    private static string Quote(string value)
    {
        var clean = (value ?? "").Replace('"', '\'').Replace("\r\n", " ").Replace('\n', ' ');
        return "\"" + clean + "\"";
    }
}
