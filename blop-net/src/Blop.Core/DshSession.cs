#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace Blop.Core;

/// <summary>常驻会话的启动参数。</summary>
public sealed record DshSessionOptions
{
    /// <summary>DSH 的 exe（<c>Paths.Dsh()</c> 里的 Exe）。</summary>
    public string Exe { get; init; } = "";

    /// <summary><c>app.asar</c> 里的 cli.js（<c>Paths.Dsh()</c> 的 Cli）。</summary>
    public string Cli { get; init; } = "";

    /// <summary>可选：给运行时的 <c>--patch</c>（注入模型 / 权限用）。</summary>
    public string Patch { get; init; } = "";

    /// <summary>用哪个账号（默认 <c>deepseek-account</c>，也就是 DSH 里已登录的那个，不用另配 key）。</summary>
    public string Provider { get; init; } = "deepseek-account";

    public string Model { get; init; } = "deepseek-flash";

    /// <summary>思考档（留空 = 不传）。</summary>
    public string Effort { get; init; } = "";

    /// <summary>工作目录。</summary>
    public string Cwd { get; init; } = "";

    public string SessionId { get; init; } = "pet-main";
}

/// <summary>一轮提示词的结果。</summary>
public sealed record PromptResult(string Text, double Seconds, bool TimedOut, string MessageId)
{
    /// <summary>这一轮没拿到任何文本（超时、或者模型只回了工具调用）。</summary>
    public bool Empty => string.IsNullOrWhiteSpace(Text);
}

/// <summary>
/// 常驻 DSH 运行时客户端（stdio JSON-RPC）。
/// </summary>
/// <remarks>
/// 为什么要常驻：早先每一轮判断都是「起 pwsh → 起一个完整的 DSH 进程 → 跑一轮 → 退出」，
/// 单轮 8–25 秒，其中大半是**每轮重建**的开销而不是模型在算。常驻之后 initialize 一次性
/// 约 3.4 秒，之后每轮 0.8–1.3 秒。
///
/// 协议（<c>dsh --profile sdk</c> 自带）：
///   客户端→服务端：initialize{cwd,provider,model,reasoningEffort?} / session/prompt{sessionId,contentBlocks} / shutdown
///   服务端→客户端：session.event / session.status …
///
/// ⚠️ 两个实测踩过的坑，这里都保留了处理：
///   ① **必须等 initialize 的响应回来**才能发提示词（请求是并发分派的，早发会被拒
///      "SDK server is not initialized"）。
///   ② stdin/stdout 必须显式 UTF-8，否则中文进去是乱码（"可用" 变成 "ֻ�ظ������֣�����"）。
/// </remarks>
public sealed class DshSession : IDisposable
{
    private readonly DshSessionOptions _opt;
    private readonly StringBuilder _stderr = new StringBuilder();
    private Process? _proc;
    private Task? _stderrDrain;
    private Task<string?>? _pendingRead;
    private int _nextId = 1;

    public DshSession(DshSessionOptions options) => _opt = options;

    public bool Initialized { get; private set; }

    public string SessionId => _opt.SessionId;

    public string Status =>
        _proc is null ? "未启动"
        : _proc.HasExited ? "已退出"
        : Initialized ? "就绪" : "启动中";

    /// <summary>起进程 + 握手（约 3.4 秒，一个进程只付一次）。</summary>
    public void Start(int timeoutSeconds = 60)
    {
        if (_proc is not null && !_proc.HasExited && Initialized) return;
        if (string.IsNullOrEmpty(_opt.Exe) || string.IsNullOrEmpty(_opt.Cli))
        {
            throw new InvalidOperationException(
                "没解出 DSH 的 exe / cli.js —— 先看 blop-net 的路径解析用例表在你这台机器上过不过");
        }

        var psi = new ProcessStartInfo
        {
            FileName = _opt.Exe,
            Arguments = "--expose-internals \"" + _opt.Cli + "\" --profile sdk" +
                        (!string.IsNullOrEmpty(_opt.Patch) && File.Exists(_opt.Patch)
                            ? " --patch \"" + _opt.Patch + "\""
                            : ""),
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = string.IsNullOrEmpty(_opt.Cwd) ? AppDomain.CurrentDomain.BaseDirectory : _opt.Cwd,
        };
        // 输出这边可以设编码（net48 也有这个属性）；**输入那边没有** ——
        // ProcessStartInfo.StandardInputEncoding 是 .NET Core 才加的，所以 Send() 里直接
        // 往 StandardInput.BaseStream 写 UTF-8 字节。中文进去必须是 UTF-8，否则是乱码（实测）。
        psi.StandardOutputEncoding = new UTF8Encoding(false);
        // 把 Electron 的可执行文件当 node 用（这正是 DSH 自己那套启动方式）。
        // ⚠️ 这条**不能**写成 psi.EnvironmentVariables["ELECTRON_RUN_AS_NODE"] = "1"：
        // .NET Framework 那个集合会把**所有键的键名小写化**再交给子进程，于是 DSH（Node）
        // 在 profile 启动阶段报 "EPERM: open …\.dsh\profiles\sdk\cordis.yml" ——
        // 一个看起来像权限问题、实际是环境变量名大小写问题的怪错（实测踩了很久）。
        // 在自己进程里设一次，子进程自然继承（net48 / net8 都支持，也不动那份继承的环境）。
        Environment.SetEnvironmentVariable("ELECTRON_RUN_AS_NODE", "1");

        var proc = new Process { StartInfo = psi };
        proc.Start();
        _proc = proc;
        _pendingRead = null;
        _nextId = 1;
        Initialized = false;
        // ⚠️ 重定向了 stderr 就**必须持续读**它：Electron 往 stderr 写得不少（启动日志、警告），
        // 管道缓冲区（几 KB）一满，子进程就卡在写 stderr 上 —— 表现是 initialize 永远不回来。
        _stderr.Clear();
        _stderrDrain = Task.Run(() => DrainStderr(proc));

        var cwd = string.IsNullOrEmpty(_opt.Cwd) ? AppDomain.CurrentDomain.BaseDirectory : _opt.Cwd;
        var id = _nextId++;
        var ps = new JsonObject
        {
            ["cwd"] = cwd.Replace('\\', '/'),
            ["provider"] = _opt.Provider,
            ["model"] = _opt.Model,
        };
        if (!string.IsNullOrEmpty(_opt.Effort)) ps["reasoningEffort"] = _opt.Effort;
        Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = "initialize", ["params"] = ps });

        var res = ReceiveResponse(id, timeoutSeconds * 1000);
        if (res is null)
            throw new TimeoutException(
                "initialize 没在 " + timeoutSeconds + " 秒内回来。子进程 stderr 末尾：" +
                Environment.NewLine + Tail(_stderr));
        if (!res.Value.TryGetProperty("serverInfo", out _)) throw new InvalidOperationException("initialize 没返回 serverInfo");
        Initialized = true;
    }

    /// <summary>发一轮提示词，等它跑完（<c>session.status=idle</c>）。</summary>
    public PromptResult Prompt(string text, IReadOnlyList<string>? imagePaths = null, int timeoutSeconds = 120)
    {
        if (_proc is null || !Initialized) throw new InvalidOperationException("常驻运行时还没初始化");

        var blocks = new JsonArray();
        if (!string.IsNullOrEmpty(text)) blocks.Add(new JsonObject { ["type"] = "text", ["text"] = text });
        foreach (var path in imagePaths ?? Array.Empty<string>())
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) continue;
            blocks.Add(new JsonObject
            {
                ["type"] = "image",
                ["data"] = Convert.ToBase64String(File.ReadAllBytes(path)),
                ["mimeType"] = MimeOf(path),
            });
        }

        var sw = Stopwatch.StartNew();
        var id = _nextId++;
        Send(new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id,
            ["method"] = "session/prompt",
            ["params"] = new JsonObject { ["sessionId"] = _opt.SessionId, ["contentBlocks"] = blocks },
        });

        var answer = "";
        var messageId = "";
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        var timedOut = false;
        while (true)
        {
            if (DateTime.UtcNow >= deadline)
            {
                timedOut = true;
                break;
            }

            var line = ReadLine(2000);
            if (line is null) throw new IOException("常驻运行时挂了（stdout 关闭）");
            if (line.Length == 0) continue;

            JsonDocument doc;
            try
            {
                doc = JsonDocument.Parse(line);
            }
            catch
            {
                continue;
            }

            using (doc)
            {
                var root = doc.RootElement;
                if (root.TryGetProperty("id", out var rid) && rid.ValueKind == JsonValueKind.Number &&
                    rid.GetInt32() == id)
                {
                    if (root.TryGetProperty("error", out var err))
                        throw new InvalidOperationException("session/prompt 被拒：" + err.GetRawText());
                    if (root.TryGetProperty("result", out var result) &&
                        result.TryGetProperty("messageId", out var mid))
                    {
                        messageId = mid.GetString() ?? "";
                    }

                    continue;
                }

                if (!root.TryGetProperty("method", out var method)) continue;
                var name = method.GetString();
                if (name == "session.event" && root.TryGetProperty("params", out var pars) &&
                    pars.TryGetProperty("event", out var ev))
                {
                    if (EventType(ev) == "assistant/message")
                    {
                        var t = EventText(ev);
                        if (!string.IsNullOrEmpty(t)) answer = t;
                    }

                    continue;
                }

                if (name == "session.status" && root.TryGetProperty("params", out var sp) &&
                    sp.TryGetProperty("status", out var st) && st.GetString() == "idle")
                {
                    break;   // 这一轮跑完了
                }
            }
        }

        sw.Stop();
        return new PromptResult(answer, Math.Round(sw.Elapsed.TotalSeconds, 1), timedOut, messageId);
    }

    /// <summary>shutdown；不听话就连整棵树一起收掉（里面有 node 子进程）。</summary>
    public void Shutdown(int graceSeconds = 3)
    {
        var proc = _proc;
        if (proc is null) return;
        try
        {
            if (!proc.HasExited)
            {
                Send(new JsonObject
                {
                    ["jsonrpc"] = "2.0",
                    ["id"] = _nextId++,
                    ["method"] = "shutdown",
                    ["params"] = new JsonObject(),
                });
                if (!proc.WaitForExit(graceSeconds * 1000)) KillTree(proc.Id);
            }
        }
        catch
        {
            // 收摊失败不该影响退出
        }
        finally
        {
            _proc = null;
            _pendingRead = null;
            Initialized = false;
        }
    }

    public void Dispose() => Shutdown();

    /// <summary>子进程 stderr 的末尾（诊断用）。</summary>
    public string StderrTail => Tail(_stderr);

    /// <summary>持续把 stderr 读空（不读会把子进程堵死，见 Start 里的注释）。</summary>
    private void DrainStderr(Process proc)
    {
        try
        {
            string? line;
            while ((line = proc.StandardError.ReadLine()) is not null)
            {
                lock (_stderr)
                {
                    _stderr.AppendLine(line);
                    if (_stderr.Length > 8000) _stderr.Remove(0, _stderr.Length - 8000);
                }
            }
        }
        catch
        {
            // 进程结束/管道关闭都算正常收场
        }
    }

    private static string Tail(StringBuilder sb)
    {
        lock (sb)
        {
            var s = sb.ToString().Trim();
            return s.Length == 0 ? "（空）" : s;
        }
    }

    private void Send(JsonObject message)
    {
        var proc = _proc ?? throw new InvalidOperationException("进程还没起来");
        // 一行 JSON + '\n'，按 UTF-8 写字节（不经过 StreamWriter，免得踩到 net48 的默认码页）
        var bytes = Encoding.UTF8.GetBytes(
            message.ToJsonString(new JsonSerializerOptions { WriteIndented = false }) + "\n");
        var stream = proc.StandardInput.BaseStream;
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    /// <summary>读一行，带超时。返回 null = 流关了；空串 = 这次超时；否则是那一行。</summary>
    /// <remarks>
    /// **超时不能让读任务作废** —— 丢了它下一次读会报 "The stream is currently in use by a previous
    /// operation"（PS 版实测踩过）。所以半途的任务留着，下一轮接着等它。
    /// </remarks>
    private string? ReadLine(int timeoutMs)
    {
        var proc = _proc ?? throw new InvalidOperationException("进程还没起来");
        if (_pendingRead is null) _pendingRead = proc.StandardOutput.ReadLineAsync();
        if (!_pendingRead.Wait(timeoutMs)) return "";
        var line = _pendingRead.Result;
        _pendingRead = null;
        return line;
    }

    private JsonElement? ReceiveResponse(int id, int timeoutMs)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            var line = ReadLine(2000);
            if (line is null) throw new IOException("常驻运行时的 stdout 关掉了（进程没了？）");
            if (line.Length == 0) continue;
            JsonDocument doc;
            try
            {
                doc = JsonDocument.Parse(line);
            }
            catch
            {
                continue;
            }

            if (doc.RootElement.TryGetProperty("id", out var rid) && rid.ValueKind == JsonValueKind.Number &&
                rid.GetInt32() == id)
            {
                if (doc.RootElement.TryGetProperty("error", out var err))
                    throw new InvalidOperationException("initialize 被拒：" + err.GetRawText());
                if (doc.RootElement.TryGetProperty("result", out var r))
                    return JsonDocument.Parse(r.GetRawText()).RootElement;
                return null;
            }
        }

        return null;
    }

    private static string EventType(JsonElement ev)
        => ev.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() ?? "" : "";

    /// <summary>从 <c>assistant/message</c> 事件里抠文本块（reasoning 块不算）。</summary>
    private static string EventText(JsonElement ev)
    {
        if (!ev.TryGetProperty("data", out var data) || !data.TryGetProperty("message", out var msg)) return "";
        if (!msg.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) return "";
        var parts = new List<string>();
        foreach (var c in content.EnumerateArray())
        {
            if (c.TryGetProperty("type", out var type) && type.GetString() == "text" &&
                c.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String)
            {
                parts.Add(text.GetString() ?? "");
            }
        }

        return string.Join("\n", parts).Trim();
    }

    private static string MimeOf(string path)
    {
        switch (Path.GetExtension(path).ToLowerInvariant())
        {
            case ".png": return "image/png";
            case ".jpg":
            case ".jpeg": return "image/jpeg";
            case ".webp": return "image/webp";
            case ".gif": return "image/gif";
            default: return "image/jpeg";
        }
    }

    private static void KillTree(int pid)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "taskkill",
                Arguments = "/PID " + pid + " /T /F",
                UseShellExecute = false,
                CreateNoWindow = true,
            })?.WaitForExit(5000);
        }
        catch
        {
        }
    }
}
