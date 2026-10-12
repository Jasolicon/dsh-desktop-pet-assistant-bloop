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
