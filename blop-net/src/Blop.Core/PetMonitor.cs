#nullable enable
using System;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;

namespace Blop.Core;

/// <summary>一次采样的结果：这一轮是"闸门拦下"、"它决定不说"、还是"说了"。</summary>
public sealed record TickResult(string Kind, string Reason, string Text)
{
    public const string Skipped = "skip";     // 闸门拦下（本地决定，没花模型钱）
    public const string Silent = "silent";    // 放行了，但大脑决定不说
    public const string Spoke = "spoke";      // 说了

    public bool SaidSomething => Kind == Spoke;
}

/// <summary>
/// 观察循环：采样 → 本地闸门 →（放行时）问大脑 → 给出这一轮的结果。
/// </summary>
/// <remarks>
/// 与 <c>desktop-guide/DesktopGuide.ps1</c> 的分工一致：**值不值得开口**由本地确定性代码决定
/// （画面变没变、窗口换没换、人还在不在），模型只负责"说什么"。这样绝大多数轮次根本不花钱。
///
/// 每一条判断都落进 <c>decisions.jsonl</c>（含"没说"的理由）—— "什么时候该沉默"是要攒的标注数据，
/// 不是运行日志，所以沉默也要记档。
/// </remarks>
public sealed class PetMonitor
{
    private readonly BotConfig _cfg;
    private readonly IBrain _brain;
    private readonly string _decisionsPath;
    private readonly Func<Rectangle>? _selfRect;
    private readonly string _shotDir;

    private string _lastJudgedFp = "";
    private string _lastJudgedKey = "";
    private DateTime _lastJudgedAt = DateTime.MinValue;
    private int _silentStreak;
    private bool _standby;

    public PetMonitor(BotConfig cfg, IBrain brain, string decisionsPath, string shotDir, Func<Rectangle>? selfRect = null)
    {
        _cfg = cfg;
        _brain = brain;
        _decisionsPath = decisionsPath;
        _shotDir = shotDir;
        _selfRect = selfRect;
    }

    public int SpokeCount { get; private set; }
    public int SilentCount { get; private set; }
    public int SkipCount { get; private set; }

    /// <summary>待机（黑屏/锁屏/睡眠）：不抓屏、不判断、不打扰。</summary>
    public void SetStandby(bool standby) => _standby = standby;

    /// <summary>跑一轮。返回这一轮发生了什么（调用方据此决定要不要弹气泡）。</summary>
    /// <param name="force">true = 跳过本地闸门（用户主动"现在说一句"—— 那是他要的，不是它多事）。</param>
    public TickResult Tick(bool force = false)
    {
        var now = DateTime.Now;
        var self = _selfRect?.Invoke() ?? Rectangle.Empty;
        var fg = Foreground.Current();
        var idle = Foreground.IdleSeconds();
        var fp = _standby ? "" : ScreenCapture.FingerprintOnly(null, self);
        var fpDist = _standby ? 0 : Fingerprint.Distance(fp, _lastJudgedFp);
        var windowChanged = fg.Key != _lastJudgedKey;
        var since = _lastJudgedAt == DateTime.MinValue ? double.MaxValue : (now - _lastJudgedAt).TotalSeconds;

        var reason = force ? "" : Gate.Decide(new GateInput
        {
            HasShot = true,
            Standby = _standby,
            Style = _cfg.SpeakStyle,
            SinceSeconds = since,
            SilentStreak = _silentStreak,
            WindowChanged = windowChanged,
            FingerprintDistance = fpDist,
            IdleSeconds = idle,
            Config = _cfg.ToGateConfig(),
        });

        if (!string.IsNullOrEmpty(reason))
        {
            SkipCount++;
            Log(TickResult.Skipped, reason, "", fg);
            return new TickResult(TickResult.Skipped, reason, "");
        }

        // 放行了：这时候才抓高质量截图（给模型看），并问大脑
        var shot = ScreenCapture.Grab(1024, 60, null, self);
        var shotPath = SaveShot(shot);
        _lastJudgedAt = now;
        _lastJudgedFp = fp.Length == 0 ? _lastJudgedFp : fp;
        _lastJudgedKey = fg.Key;

        var text = "";
        try
        {
            text = _brain.Judge(new JudgmentRequest(
                fg.Process, fg.Title, idle, since, _cfg.SpeakStyle, shotPath)) ?? "";
        }
        catch (Exception ex)
        {
            // 大脑出错不该让桌宠挂掉：当这一轮"没判成"记档（和抢不到会话锁同一类），
            // 不能混进沉默率里 —— 那会污染要攒的标注数据。
            SkipCount++;
            var why = "大脑出错：" + ex.Message;
            Log(TickResult.Skipped, why, "", fg);
            return new TickResult(TickResult.Skipped, why, "");
        }

        if (SilentText.IsSilent(text))
        {
            _silentStreak++;
            SilentCount++;
            Log(TickResult.Silent, "它决定不说", text, fg);
            return new TickResult(TickResult.Silent, "它决定不说", text);
        }

        _silentStreak = 0;
        SpokeCount++;
        Log(TickResult.Spoke, "", text, fg);
        return new TickResult(TickResult.Spoke, "", text);
    }

    /// <summary>截图落盘（给模型读的那个文件）。只留最近 6 张，免得堆成山。</summary>
    private string SaveShot(GrabResult shot)
    {
        try
        {
            Directory.CreateDirectory(_shotDir);
            var path = Path.Combine(_shotDir, "shot-" + DateTime.Now.ToString("HHmmss", CultureInfo.InvariantCulture) + ".jpg");
            File.WriteAllBytes(path, Convert.FromBase64String(shot.JpegBase64));
            var old = Directory.GetFiles(_shotDir, "shot-*.jpg");
            if (old.Length > 6)
            {
                Array.Sort(old);
                for (var i = 0; i < old.Length - 6; i++)
                {
                    try { File.Delete(old[i]); } catch { }
                }
            }

            return path;
        }
        catch
        {
            return "";
        }
    }

    private void Log(string kind, string reason, string text, ForegroundInfo fg)
    {
        try
        {
            var dir = Path.GetDirectoryName(_decisionsPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var row = "{\"at\":\"" + DateTime.Now.ToString("o") + "\",\"kind\":\"" + kind + "\",\"reason\":\"" +
                      Esc(reason) + "\",\"text\":\"" + Esc(text) + "\",\"window\":\"" + Esc(fg.Key) + "\"}";
            File.AppendAllText(_decisionsPath, row + Environment.NewLine, new UTF8Encoding(false));
        }
        catch
        {
            // 记不下来不该影响桌宠
        }
    }

    private static string Esc(string s) => (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", " ").Replace("\n", " ");
}
