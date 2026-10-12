#nullable enable
using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace Blop.Core;

/// <summary>
/// 通过文件协议问 DSH 那一侧的大脑（配对插件：<c>blop-net/brain-bridge</c>）。
/// </summary>
/// <remarks>
/// 为什么是这个形状：dsh 的 stdio 接口（acp / sdk / headless）都要由调用方起进程，
/// 而从我们的进程里起 dsh 在本机会在写 profile 时被拒（见 blop-net/README「DSH 现状」）。
/// 于是反过来：**让已经在运行的 DSH 应用去问模型**，我们只写一个请求文件、等一个应答文件。
///
/// 协议（对面在 brain-bridge/index.js）：
///   req-&lt;id&gt;.json  { id, prompt, imagePath?, timeoutMs? }
///   ans-&lt;id&gt;.json  { id, ok, text?, error? }
/// 双方都不读"写了一半"的文件：写方先写 .tmp 再 rename。
/// </remarks>
public sealed class FileBridgeBrain : IBrain
{
    private readonly string _dir;
    private readonly int _timeoutMs;
    private readonly Action<string>? _log;

    public FileBridgeBrain(string dir, int timeoutMs = 180000, Action<string>? log = null)
    {
        _dir = dir ?? "";
        _timeoutMs = timeoutMs;
        _log = log;
    }

    /// <summary>
    /// 桥的目录：默认机器级（和实例锁一样，与桌宠形态无关）。
    /// </summary>
    /// <remarks>
    /// 环境变量 <c>BLOOP_BRAIN_DIR</c> 可以覆盖 —— 测试时把它指到工作区里（沙箱只允许写工作区），
    /// 前提是插件那侧的 <c>config.dir</c> 指向同一个地方（两边必须约定同一个目录）。
    /// </remarks>
    public static string DefaultDir()
    {
        var over = Environment.GetEnvironmentVariable("BLOOP_BRAIN_DIR");
        if (!string.IsNullOrWhiteSpace(over)) return over!;
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Bloop", "brain");
    }

    public string Dir => _dir;

    /// <summary>桥装过没有（有没有它的日志/目录）—— 没有就别假装能问。</summary>
    public bool Available => !string.IsNullOrEmpty(_dir) && Directory.Exists(_dir) && File.Exists(Path.Combine(_dir, "bridge.log"));

    public string? Judge(JudgmentRequest request)
    {
        if (string.IsNullOrEmpty(_dir)) return null;
        var id = Guid.NewGuid().ToString("N").Substring(0, 8);
        var reqFile = Path.Combine(_dir, "req-" + id + ".json");
        var ansFile = Path.Combine(_dir, "ans-" + id + ".json");
        try
        {
            Directory.CreateDirectory(_dir);
            var payload = new StringBuilder();
            payload.Append("{\"id\":\"").Append(id).Append("\",\"prompt\":")
                .Append(JsonSerializer.Serialize(BrainPrompt.Compose(request)))
                .Append(",\"imagePath\":").Append(JsonSerializer.Serialize(request.ShotPath ?? ""))
                .Append(",\"timeoutMs\":").Append(_timeoutMs).Append('}');
            var tmp = reqFile + ".tmp";
            File.WriteAllText(tmp, payload.ToString(), new UTF8Encoding(false));
            File.Move(tmp, reqFile);   // 先写 tmp 再改名：对面永远不会读到半个文件

            var deadline = DateTime.UtcNow.AddMilliseconds(_timeoutMs);
            while (DateTime.UtcNow < deadline)
            {
                if (File.Exists(ansFile))
                {
                    var text = ReadAnswer(ansFile, id);
                    try { File.Delete(ansFile); } catch { }
                    return text;
                }

                Thread.Sleep(200);
            }

            _log?.Invoke("桥超时（" + _timeoutMs + "ms）：" + id);
            try { File.Delete(reqFile); } catch { }
            return null;
        }
        catch (Exception ex)
        {
            _log?.Invoke("桥出错：" + ex.Message);
            return null;
        }
    }

    private string? ReadAnswer(string path, string id)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var r = doc.RootElement;
            var ok = r.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.True;
            if (!ok)
            {
                var err = r.TryGetProperty("error", out var e) ? e.GetString() : "（没有错误信息）";
                _log?.Invoke("桥答失败：" + err);
                return null;
            }

            return r.TryGetProperty("text", out var t) ? t.GetString() ?? "" : "";
        }
        catch (Exception ex)
        {
            _log?.Invoke("读应答失败（" + id + "）：" + ex.Message);
            return null;
        }
    }
}
