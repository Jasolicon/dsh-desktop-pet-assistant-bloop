# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# chat-panel.ps1 —— 桌宠左边的对话栏（自绘气泡版）
#
# 跟谁说话：**主 agent 的常驻会话**（run\main-agent.json）——它记得桌宠这一天看到过什么。
#
# UI 是自绘的：圆角气泡 / 左侧 agent、右侧你 / 时间戳 / 自动滚到底。
# 视觉与桌宠同一套语言：白底蓝调、柔和边框、圆角。
#
# 用法：
#   pwsh -File chat-panel.ps1
#   pwsh -File chat-panel.ps1 -PayloadFile run\drop.json     （桌宠拖拽时用）

param(
  [string]$InitialText = '',
  [string[]]$Files = @(),
  [switch]$Send,
  [string]$PayloadFile = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

# ---- 默认：对话直接交给 DSH 自己的界面，下面这套自绘气泡只在 chatUi="bubbles" 时才用 ----
# 理由见 web-ui.ps1 头部：自绘只能画纯文本，Markdown / 工具卡片 / 流式都画不了，
# 排版还得自己维护，结果又丑又容易坏（实测截图：文字被裁、中间一大块空白、发送按钮错位）。
# 唯一例外：拖拽（-PayloadFile）要"把这段文字发进主会话"，DSH 界面是另一个进程、
# 没法替它往输入框里塞字，所以那条路继续走自绘版。
if (-not $PayloadFile) {
  $chatCfg = $null
  # 状态根（DG_HOME）：配置从状态根读；不设时 == 脚本目录
  if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'paths.ps1') }
  try { $chatCfg = Get-Content -LiteralPath (Join-Path (Get-DgHome) 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  $chatUi = 'dsh'
  if ($chatCfg -and ($chatCfg.PSObject.Properties.Name -contains 'chatUi') -and $chatCfg.chatUi) { $chatUi = [string]$chatCfg.chatUi }
  if ($chatUi -ne 'bubbles') {
    . (Join-Path $PSScriptRoot 'web-ui.ps1')
    $url = Show-WebUi -Config $chatCfg -Wait
    Write-Host "已打开 DSH 界面：$url"
    exit 0
  }
}

# DPI 感知必须在任何 WinForms 之前（否则坐标会被系统缩放，窗口跑到别处）
if (-not ('DesktopGuide.Dpi' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace DesktopGuide {
  public static class Dpi {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    public static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);
    public static uint Scale() { try { SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2); } catch { } try { return GetDpiForSystem(); } catch { return 96; } }
  }
}
'@
}
$dpiScale = [Math]::Max(1.0, [double][DesktopGuide.Dpi]::Scale() / 96.0)
function S([int]$v) { return [int][Math]::Round($v * $dpiScale) }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# 自绘控件：圆角气泡对话流
# ---------------------------------------------------------------------------
if (-not ('DesktopGuide.ChatBubbleView' -as [type])) {
  $runtimeDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
  $refs = @(Get-ChildItem -LiteralPath $runtimeDir -Filter 'System.*.dll' |
      Where-Object { $_.Name -notlike 'System.Private.CoreLib*' -and $_.Name -notlike '*.Native.dll' } |
      Select-Object -ExpandProperty FullName)
  $refs += [System.Windows.Forms.Form].Assembly.Location
  $refs = $refs | Select-Object -Unique

  Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DesktopGuide {
  public class ChatLine {
    public string Role;      // "me" | "it" | "sys"
    public string Text;
    public string Time;
  }

  public class ChatBubbleView : Panel {
    public readonly ArrayList Lines = new ArrayList();
    public Color Accent = Color.FromArgb(47, 127, 208);
    public Color AgentBg = Color.White;
    public Color PageBg = Color.FromArgb(244, 247, 251);
    public Font BodyFont = new Font("Microsoft YaHei UI", 10f);
    int contentH;

    public ChatBubbleView() {
      DoubleBuffered = true;
      BackColor = PageBg;
      AutoScroll = true;
      Padding = new Padding(0);
    }

    public void Add(string role, string text) {
      Lines.Add(new ChatLine { Role = role, Text = text ?? "", Time = DateTime.Now.ToString("HH:mm") });
      Relayout();
      ScrollToEnd();
    }
    public void RemoveLastIf(string role) {
      if (Lines.Count > 0 && ((ChatLine)Lines[Lines.Count - 1]).Role == role) { Lines.RemoveAt(Lines.Count - 1); Relayout(); Invalidate(); }
    }
    /** 就地更新最后一条（用来把"正在想…"变成"正在想… 6s"） */
    public void UpdateLast(string role, string text) {
      if (Lines.Count == 0) return;
      var last = (ChatLine)Lines[Lines.Count - 1];
      if (last.Role != role) return;
      last.Text = text; Relayout(); Invalidate();
    }
    public void ScrollToEnd() {
      Relayout();
      AutoScrollPosition = new Point(0, Math.Max(0, contentH - ClientSize.Height));
      Invalidate();
    }

    int WrapWidth() { return Math.Max(S2(160), ClientSize.Width - S2(150)); }
    // 这里的缩放由外层传入的字体决定，控件内部只需要一个安全下限
    static int S2(int v) { return v; }

    void Relayout() {
      int y = S2(12);
      int w = WrapWidth();
      foreach (ChatLine l in Lines) {
        var sz = TextRenderer.MeasureText(l.Text, BodyFont, new Size(w, 20000), TextFormatFlags.WordBreak);
        y += S2(18) + sz.Height + S2(14) + S2(10);
      }
      contentH = y + S2(10);
      AutoScrollMinSize = new Size(0, contentH + S2(10));
    }

    static GraphicsPath Round(Rectangle r, int radius) {
      var p = new GraphicsPath();
      int d = radius * 2;
      p.AddArc(r.X, r.Y, d, d, 180, 90);
      p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
      p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
      p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
      p.CloseFigure();
      return p;
    }

    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.Clear(PageBg);
      g.TranslateTransform(0, AutoScrollPosition.Y);

      int w = WrapWidth();
      int y = S2(12);
      using (var timeFont = new Font(BodyFont.FontFamily, (float)(BodyFont.Size * 0.78)))
      using (var timeBrush = new SolidBrush(Color.FromArgb(150, 158, 172))) {
        foreach (ChatLine l in Lines) {
          bool me = l.Role == "me";
          bool sys = l.Role == "sys";
          var sz = TextRenderer.MeasureText(l.Text, BodyFont, new Size(w, 20000), TextFormatFlags.WordBreak);

          // 时间戳
          var tsz = TextRenderer.MeasureText(l.Time, timeFont);
          if (sys) {
            TextRenderer.DrawText(g, l.Text, timeFont, new Rectangle(0, y, ClientSize.Width, tsz.Height + S2(4)),
              Color.FromArgb(140, 150, 165), TextFormatFlags.HorizontalCenter);
            y += tsz.Height + S2(12);
            continue;
          }
          int bubbleW = sz.Width + S2(26);
          int bubbleH = sz.Height + S2(18);
          int bx = me ? ClientSize.Width - bubbleW - S2(16) : S2(16);
          if (bx < S2(16)) bx = S2(16);
          var rect = new Rectangle(bx, y + S2(16), bubbleW, bubbleH);

          TextRenderer.DrawText(g, l.Time, timeFont,
            new Rectangle(me ? rect.Right - tsz.Width - S2(6) : rect.X + S2(6), y, tsz.Width + S2(8), tsz.Height + S2(2)),
            Color.FromArgb(150, 158, 172), TextFormatFlags.NoPrefix);

          using (var path = Round(rect, S2(10))) {
            if (me) {
              using (var b = new LinearGradientBrush(rect, Accent, Color.FromArgb(36, 108, 186), 90f)) g.FillPath(b, path);
            } else {
              using (var b = new SolidBrush(AgentBg)) g.FillPath(b, path);
              using (var p = new Pen(Color.FromArgb(223, 229, 238), 1.2f)) g.DrawPath(p, path);
            }
          }
          TextRenderer.DrawText(g, l.Text, BodyFont,
            new Rectangle(rect.X + S2(13), rect.Y + S2(9), rect.Width - S2(26), rect.Height - S2(18)),
            me ? Color.White : Color.FromArgb(32, 36, 44), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);

          y = rect.Bottom + S2(12);
        }
      }
      g.ResetTransform();
    }
  }

  // 一个圆角高亮的输入容器：把 TextBox 放在里面，视觉上像现代输入框
  public class RoundPanel : Panel {
    public Color Fill = Color.White;
    public Color Edge = Color.FromArgb(219, 226, 236);
    public int Radius = 10;
    public RoundPanel() { DoubleBuffered = true; BackColor = Color.Transparent; }
    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
      var r = new Rectangle(0, 0, Width - 1, Height - 1);
      int d = Radius * 2;
      using (var p = new GraphicsPath()) {
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        using (var b = new SolidBrush(Fill)) g.FillPath(b, p);
        using (var pen = new Pen(Edge, 1.2f)) g.DrawPath(pen, p);
      }
    }
  }

  public class UIWin {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  }
}
'@ -ReferencedAssemblies $refs
}

# ---------------------------------------------------------------------------
# 配置 / 会话
# ---------------------------------------------------------------------------
$root = $PSScriptRoot
# 状态根（DG_HOME）：run / logs / agents.json / config.json 都从这走；不设时 == $root
if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $root 'paths.ps1') }
$dgHome = Get-DgHome
$runDir = Join-Path $dgHome 'run'
$logDir = Join-Path $dgHome 'logs'
. (Join-Path $root 'dsh-agents.ps1')
# 会话绑定的工作目录：必须和当初建这个 session 时一致，否则 dsh 会拒绝续跑。
$workspace = Get-AgentWorkspace -RunDir $runDir
# 对话气泡同样是自绘纯文本，不编译 Markdown —— 进气泡前先压成纯文本（和桌宠共用一套规则）。
. (Join-Path $root 'md-plain.ps1')
$cfg = Get-AgentConfig -Path (Join-Path $dgHome 'agents.json')
$petCfgPath = Join-Path $dgHome 'config.json'
$petCfg = Get-Content -LiteralPath $petCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$uiFamily = if ($petCfg.fontFamily) { [string]$petCfg.fontFamily } else { 'Microsoft YaHei UI' }
$uiSize = if ($petCfg.fontSize) { [double]$petCfg.fontSize } else { 9.5 }

if ($PayloadFile -and (Test-Path $PayloadFile)) {
  try {
    $pl = Get-Content -LiteralPath $PayloadFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($pl.text) { $InitialText = [string]$pl.text }
    if ($pl.files) { $Files = @($pl.files) }
    if ($pl.send) { $Send = $true }
  } catch { }
}

$stateFile = Join-Path $runDir 'main-agent.json'
$sessionId = $null
if (Test-Path $stateFile) {
  try { $sessionId = (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).sessionId } catch { }
}
$model = $cfg.models | Where-Object { $_.name -eq $cfg.mainAgent.model } | Select-Object -First 1
if (-not $model) { $model = $cfg.models[0] }
$access = $cfg.access | Where-Object { $_.name -eq $cfg.mainAgent.access } | Select-Object -First 1
$patchPath = Write-AgentPatch -Model $model -Access $access -AccessList $cfg.access -RunDir $runDir -Id 'main'

# ---------------------------------------------------------------------------
# 窗口
# ---------------------------------------------------------------------------
$ACCENT = [System.Drawing.Color]::FromArgb(47, 127, 208)
$PAGE = [System.Drawing.Color]::FromArgb(244, 247, 251)

$form = New-Object System.Windows.Forms.Form
$form.Text = '随时指导 · 对话'
$form.Size = New-Object System.Drawing.Size (S(600)), (S(700))
$form.MinimumSize = New-Object System.Drawing.Size (S(420)), (S(420))
$form.StartPosition = 'Manual'
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.BackColor = $PAGE
$form.Font = New-Object System.Drawing.Font $uiFamily, ($uiSize * $dpiScale)
$form.KeyPreview = $true

# 停在桌宠左边
$placed = $false
$petState = Join-Path $runDir 'pet.json'
if (Test-Path $petState) {
  try {
    $p = Get-Content -LiteralPath $petState -Raw -Encoding UTF8 | ConvertFrom-Json
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = [int]$p.x - $form.Width - (S(14))
    $y = [int]$p.y + (S(146)) - $form.Height
    if ($x -lt $wa.Left + (S(8))) { $x = $wa.Left + (S(8)) }
    if ($y -lt $wa.Top + (S(8))) { $y = $wa.Top + (S(8)) }
    $form.Location = New-Object System.Drawing.Point $x, $y
    $placed = $true
  } catch { }
}
if (-not $placed) {
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $form.Location = New-Object System.Drawing.Point ($wa.Right - $form.Width - (S(560))), ($wa.Bottom - $form.Height - (S(90)))
}

# ---- 顶栏 ----
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = S(58); $header.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($header)
$header.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::White)
    # 左边一个小圆点当"在线"指示
    $dot = New-Object System.Drawing.Rectangle (S(16)), (S(24)), (S(10)), (S(10))
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ($ACCENT)), $dot)
    $f1 = New-Object System.Drawing.Font $uiFamily, (($uiSize + 1.5) * $dpiScale), ([System.Drawing.FontStyle]::Bold)
    $f2 = New-Object System.Drawing.Font $uiFamily, (($uiSize - 0.8) * $dpiScale)
    $g.DrawString('随时指导', $f1, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(28,32,40))), (S(34)), (S(12)))
    $g.DrawString(("主 agent · $($model.name) · $($access.name)"), $f2, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(140,148,162))), (S(34)), (S(33)))
    # 底边一条细分割线
    $g.DrawLine((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(228,233,241))), 0, $header.Height - 1, $header.Width, $header.Height - 1)
    $f1.Dispose(); $f2.Dispose()
  })

# ---- 底部输入区 ----
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = 'Bottom'; $bottom.Height = S(112); $bottom.BackColor = [System.Drawing.Color]::White
$bottom.Padding = New-Object System.Windows.Forms.Padding (S(14)), (S(10)), (S(14)), (S(10))
$form.Controls.Add($bottom)
$bottom.Add_Paint({
    param($s, $e)
    $e.Graphics.DrawLine((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(228,233,241))), 0, 0, $bottom.Width, 0)
  })

$guideBox = New-Object System.Windows.Forms.CheckBox
$guideBox.Text = '一步一步来'
$guideBox.Dock = 'Bottom'; $guideBox.Height = S(26)
$guideBox.ForeColor = [System.Drawing.Color]::FromArgb(120, 128, 142)
$bottom.Controls.Add($guideBox)

$sendBtn = New-Object System.Windows.Forms.Button
$sendBtn.Text = '发送'
$sendBtn.Dock = 'Right'; $sendBtn.Width = S(88)
$sendBtn.FlatStyle = 'Flat'
$sendBtn.FlatAppearance.BorderSize = 0
$sendBtn.BackColor = $ACCENT
$sendBtn.ForeColor = [System.Drawing.Color]::White
$sendBtn.Font = New-Object System.Drawing.Font $uiFamily, ($uiSize * $dpiScale), ([System.Drawing.FontStyle]::Bold)
$sendBtn.Cursor = 'Hand'
$bottom.Controls.Add($sendBtn)

$inputWrap = New-Object DesktopGuide.RoundPanel
$inputWrap.Dock = 'Fill'
$inputWrap.Fill = $PAGE
$inputWrap.Edge = [System.Drawing.Color]::FromArgb(219, 226, 236)
$inputWrap.Padding = New-Object System.Windows.Forms.Padding (S(10)), (S(8)), (S(10)), (S(8))
$bottom.Controls.Add($inputWrap)

$inputBox = New-Object System.Windows.Forms.TextBox
$inputBox.Multiline = $true
$inputBox.BorderStyle = 'None'
$inputBox.BackColor = $PAGE
$inputBox.Dock = 'Fill'
$inputBox.AcceptsReturn = $true
$inputBox.AllowDrop = $true
$inputBox.Font = New-Object System.Drawing.Font $uiFamily, ($uiSize * $dpiScale)
$inputWrap.Controls.Add($inputBox)

# ---- 对话流 ----
$chat = New-Object DesktopGuide.ChatBubbleView
$chat.Dock = 'Fill'
$chat.BodyFont = New-Object System.Drawing.Font $uiFamily, ($uiSize * $dpiScale)
$chat.Accent = $ACCENT
$chat.PageBg = $PAGE
$form.Controls.Add($chat)
$chat.BringToFront()

# ---- 拖拽：文件 / 文字 / 网址 ----
$dragEnter = [System.Windows.Forms.DragEventHandler]{
  param($sender, $e)
  if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop) -or $e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText)) {
    $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
  }
}
$dragDrop = [System.Windows.Forms.DragEventHandler]{
  param($sender, $e)
  $add = @()
  if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $add += [string[]]$e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop) }
  if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText)) {
    $t = [string]$e.Data.GetData([System.Windows.Forms.DataFormats]::UnicodeText); if ($t) { $add += $t }
  }
  if ($add.Count -gt 0) { $inputBox.Text = (($inputBox.Text, ($add -join "`n")) -join "`n").Trim() }
}
foreach ($c in @($inputBox, $chat, $form)) { $c.AllowDrop = $true; $c.Add_DragEnter($dragEnter); $c.Add_DragDrop($dragDrop) }

# ---------------------------------------------------------------------------
# 发送
# ---------------------------------------------------------------------------
$script:busy = $false
$script:proc = $null
$script:outFile = Join-Path $runDir 'chat.out.jsonl'
$script:errFile = Join-Path $runDir 'chat.err.txt'
$script:taskFile = Join-Path $runDir 'chat.task.txt'
$script:lockPath = $null
$trace = Join-Path $runDir 'panel-trace.txt'
function Trace-Line { param([string]$m) try { Add-Content -LiteralPath $trace -Encoding UTF8 -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) } catch { } }
Trace-Line "启动 panel（自绘版）Payload='$PayloadFile' Send=$Send"

function Send-Message {
  if ($script:busy) { return }
  $text = $inputBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  $inputBox.Text = ''

  $chat.Add('me', $text)
  $prompt = $text
  if ($guideBox.Checked) {
    # 给模型的指令本身也不要用 Markdown 写法，否则它会照着学、把 `**` 回显到气泡里。
    $prompt = "用户要求一步一步来。这一轮只给一步：说清这一步做什么、做完应该看到什么，然后停下来等他确认。不要一次给全部步骤。回答用纯文本，不要用 Markdown 标记。`n`n$text"
  }
  $paths = @($text -split "`n" | Where-Object { $_ -match '^[A-Za-z]:\\' -or $_ -match '^\\\\' })
  if ($paths.Count -gt 0) {
    $prompt += "`n`n附件（用工具读取，图片用 read_image）：`n" + (($paths | ForEach-Object { "  - $_" }) -join "`n")
  }

  try { $script:lockPath = Enter-AgentLock -RunDir $runDir -Name 'main' -TimeoutSeconds 0 }
  catch {
    $chat.RemoveLastIf('me')
    $inputBox.Text = $text
    $chat.Add('sys', '它正忙（上一轮判断还没跑完），等几秒再发。')
    return
  }

  Set-Content -LiteralPath $script:taskFile -Value $prompt -Encoding UTF8
  $args = @('--expose-internals', $cfg.dshCli, '--profile', $cfg.profile, '--patch', $patchPath)
  if ($sessionId) { $args += @('--session-id', $sessionId) }
  $args += @('--json', '-')

  $old = $env:ELECTRON_RUN_AS_NODE; $oldMode = $env:DSH_PERMISSION_MODE
  $env:ELECTRON_RUN_AS_NODE = '1'
  if ($access -and $access.sandbox) { $env:DSH_PERMISSION_MODE = $access.sandbox }
  try {
    $script:proc = Start-Process -FilePath $cfg.dshExe -ArgumentList $args `
      -RedirectStandardInput $script:taskFile -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile `
      -WorkingDirectory $workspace -NoNewWindow -PassThru
  } finally {
    if ($null -eq $old) { Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue } else { $env:ELECTRON_RUN_AS_NODE = $old }
    if ($null -eq $oldMode) { Remove-Item Env:DSH_PERMISSION_MODE -ErrorAction SilentlyContinue } else { $env:DSH_PERMISSION_MODE = $oldMode }
  }
  $script:busy = $true
  $script:t0 = Get-Date
  $sendBtn.Enabled = $false
  $sendBtn.BackColor = [System.Drawing.Color]::FromArgb(160, 185, 214)
  $chat.Add('sys', '正在想…')
}

function Finish-Message {
  if (-not $script:busy) { return }
  if (-not $script:proc.HasExited) { return }
  $script:busy = $false
  $sendBtn.Enabled = $true
  $sendBtn.BackColor = $ACCENT
  Exit-AgentLock -LockPath $script:lockPath
  $script:lockPath = $null
  $chat.RemoveLastIf('sys')

  $final = ''; $newSid = $null
  if (Test-Path $script:outFile) {
    foreach ($line in (Get-Content -LiteralPath $script:outFile -Encoding UTF8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $e = $line | ConvertFrom-Json } catch { continue }
      if ($e.type -eq 'session' -and $e.sessionId) { $newSid = $e.sessionId }
      if ($e.type -eq 'final' -and $e.text) { $final = [string]$e.text }
    }
  }
  if ($newSid -and $newSid -ne $sessionId) {
    $script:sessionId = $newSid
    ([pscustomobject]@{ sessionId = $newSid; model = $model.name; updatedAt = (Get-Date).ToString('o') } | ConvertTo-Json -Compress) |
      Set-Content -LiteralPath $stateFile -Encoding UTF8
  }
  if ([string]::IsNullOrWhiteSpace($final)) {
    $err = ''
    if (Test-Path $script:errFile) { $err = [string](Get-Content -LiteralPath $script:errFile -Raw -Encoding UTF8) }
    $final = if ($err.Trim()) { "（出错）$(($err.Trim() -split "`n")[0])" } else { '（没有输出）' }
  }
  # 主 agent 的回复也走同一套：气泡不编译 Markdown，就别把 `**`、`#`、反引号原样糊到屏幕上。
  $chat.Add('it', (ConvertTo-PlainText $final))
}

$sendBtn.Add_Click({ Send-Message })
$inputBox.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and $e.Control) { $e.SuppressKeyPress = $true; Send-Message }
  })

$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 600
$poll.Add_Tick({
    try {
      Finish-Message
      if ($script:busy -and $script:t0) {
        $sec = [int]((Get-Date) - $script:t0).TotalSeconds
        $chat.UpdateLast('sys', "正在想… ${sec}s")
      }
    } catch { }
  })
$poll.Start()

$form.Add_Shown({
    # -WindowStyle Hidden 启动这个进程时，Windows 会把 SW_HIDE 应用到进程第一个显示的窗口 ——
    # 也就是面板自己（WS_VISIBLE 没置上，窗口隐形）。必须显式 ShowWindow 覆盖。
    try {
      [DesktopGuide.UIWin]::ShowWindow($form.Handle, 5) | Out-Null
      $form.Activate(); $form.BringToFront()
      [DesktopGuide.UIWin]::SetForegroundWindow($form.Handle) | Out-Null
    } catch { }
    Trace-Line "Shown 触发"
    try {
      $chat.Add('it', "我在。可以聊，也可以把文字、图片、网址直接拖进来。`n我记着这一整天看到过什么，不用你重新交代背景。")
      if ($InitialText) { $inputBox.Text = $InitialText }
      if ($Files.Count -gt 0) { $inputBox.Text = (($inputBox.Text, ($Files -join "`n")) -join "`n").Trim() }
      if ($Send -and $inputBox.Text.Trim()) { Send-Message }
      $inputBox.Focus()
    } catch { Trace-Line "Shown 出错：$($_.Exception.Message)" }
  })

[System.Windows.Forms.Application]::Run($form)
