# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# agents-window.ps1 —— 子 agent 管理窗口：**选一条 / 新建 / 删 / 看记录 / 中断**
#
# 为什么从右键子菜单改成窗口：子菜单只能点一下选中，看不到状态、没法新建、没法删。
# 这个列表本质是一张表（状态 / 模型 / 权限 / 最后任务 / 时间），该用窗口。
#
# 对外：
#   Show-DgAgents -Root <desktop-guide> [-UiScale <n>] [-OwnerForm <form>] [-RenderTo <dir>]
#   Test-DgAgents -Root <desktop-guide>     ← 纯逻辑自检（临时目录里跑，不碰真数据）
#
# 状态存在两个文件里，桌宠和这个窗口共读共写：
#   run\agents.json    agent 记录（谁在跑、跑的什么）
#   run\dispatch.json  派活目标（{"agent":"agent-xxxx"}，空串 = 每次新建）

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

function Get-DgAgentColors {
  return @{
    Bg     = [System.Drawing.Color]::FromArgb(250, 251, 253)
    Text   = [System.Drawing.Color]::FromArgb(31, 35, 42)
    Dim    = [System.Drawing.Color]::FromArgb(140, 148, 162)
    Accent = [System.Drawing.Color]::FromArgb(47, 127, 208)
  }
}

function Get-DgAgentRows {
  <# 读出列表要显示的行。状态用 Update-AgentStatus 现场对一次账（跑完的会翻成 done/failed）。 #>
  param([string]$RunDir)
  $rows = @()
  try { $agents = @(Update-AgentStatus -RunDir $RunDir) }
  catch { $agents = @(Get-Agents -RunDir $RunDir) }
  foreach ($a in $agents) {
    $mark = switch ([string]$a.status) {
      'running' { '● 在跑' }
      'done'    { '✓ 完成' }
      'failed'  { '✗ 失败' }
      'stopped' { '■ 已中断' }
      'ready'   { '○ 待派活' }
      default   { '· ' + [string]$a.status }
    }
    $when = ''
    try { if ($a.startedAt) { $when = ([datetime]$a.startedAt).ToString('MM-dd HH:mm') } } catch { }
    $rows += [pscustomobject]@{
      Id     = [string]$a.id
      Status = $mark
      Task   = [string]$a.task
      Model  = [string]$a.model
      Access = [string]$a.access
      When   = $when
    }
  }
  return $rows
}

function Show-DgAgentLog {
  <#
    记录查看器：把一条 agent 记录的日志读成人话。
    为什么单独开个窗口：日志是 JSONL，直接摊给用户看是一屏机器话；
    这里只留他真正想知道的三样 —— 派了什么活、结论是什么、调用了哪些工具。
    想看原文有「打开原始日志」。
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Id,
    [double]$UiScale = 0,
    $OwnerForm = $null,
    [string]$RenderTo = '',
    [switch]$SelfTest
  )
  if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $Root 'paths.ps1') }
  $dgHome = Get-DgHome
  $runDir = Join-Path $dgHome 'run'

  $agents = @(Get-Agents -RunDir $runDir)
  $rec = $agents | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  $logFile = if ($rec -and $rec.logFile) { [string]$rec.logFile } else { '' }
  # 老记录里存过相对路径（.\logs\agent-x.jsonl），补成绝对路径
  if ($logFile -and -not [System.IO.Path]::IsPathRooted($logFile)) { $logFile = Join-Path $dgHome $logFile }
  $digest = Get-AgentLogDigest -Agent $rec -LogFile $logFile
  $finalText = if ($logFile -and (Test-Path -LiteralPath $logFile)) { Get-AgentResult -LogFile $logFile } else { '' }

  $s = if ($UiScale -gt 0) { $UiScale } else { 1.0 }
  $c = Get-DgAgentColors
  $site = 'Microsoft YaHei UI'

  $f = New-Object System.Windows.Forms.Form
  $f.Text = "泡泡 · 子 agent 记录 · $Id"
  $f.Font = New-Object System.Drawing.Font $site, ([float]9.5)
  $f.BackColor = $c.Bg
  $f.ForeColor = $c.Text
  $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $W = [int](760 * $s); $H = [int](560 * $s)
  $f.Size = New-Object System.Drawing.Size ($W, $H)
  $f.MinimumSize = New-Object System.Drawing.Size ($W, $H)

  $box = New-Object System.Windows.Forms.TextBox
  $box.Multiline = $true
  $box.ReadOnly = $true
  $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
  $box.WordWrap = $false
  $box.BackColor = [System.Drawing.Color]::White
  $box.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](18 * $s))
  $box.Size = New-Object System.Drawing.Size ([int](715 * $s)), ([int](450 * $s))
  $box.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
  $box.Text = $digest
  $box.TabStop = $false          # 别让只读框抢焦点（抢了会把整段反白）
  $f.Controls.Add($box)

  function New-LogButton([string]$text, [double]$x, [double]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $b.Location = New-Object System.Drawing.Point ([int]($x * $s)), ([int](484 * $s))
    $b.Size = New-Object System.Drawing.Size ([int]($w * $s)), ([int](32 * $s))
    $b.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    return $b
  }
  $btnOpen = New-LogButton '打开原始日志' 20 130
  $btnCopy = New-LogButton '复制结论' 160 100
  $btnClose2 = New-LogButton '关闭' 618 118
  $f.Controls.Add($btnOpen); $f.Controls.Add($btnCopy); $f.Controls.Add($btnClose2)

  $btnOpen.Add_Click({
      if ($logFile -and (Test-Path -LiteralPath $logFile)) { try { Start-Process -FilePath $logFile | Out-Null } catch { } }
    })
  $btnCopy.Add_Click({
      if ($finalText) { try { [System.Windows.Forms.Clipboard]::SetText([string]$finalText) } catch { } }
    })
  $btnClose2.Add_Click({ $f.Close() })

  if ($SelfTest -or $RenderTo) {
    # 同 agents 主窗口：必须真的 Show 出来（挪到屏幕外）再 DrawToBitmap，否则子控件不渲染
    $f.ShowInTaskbar = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.Location = New-Object System.Drawing.Point -4000, -4000
    $f.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 120
    [System.Windows.Forms.Application]::DoEvents()
    if ($RenderTo) {
      if (-not (Test-Path -LiteralPath $RenderTo)) { New-Item -ItemType Directory -Force -Path $RenderTo | Out-Null }
      $bmp = New-Object System.Drawing.Bitmap $f.Width, $f.Height
      $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $f.Width, $f.Height))
      $out = Join-Path $RenderTo 'agents-log-window.png'
      $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
      Write-Host "记录窗口预览：$out"
    }
    if ($SelfTest) { $f.Dispose(); return }
  }

  [void]$f.ShowDialog($OwnerForm)
  $f.Dispose()
}

function Show-DgAgents {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [double]$UiScale = 0,
    $OwnerForm = $null,
    [string]$RenderTo = '',
    [switch]$SelfTest
  )
  try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

  # 状态根（DG_HOME）：run / logs / agents.json 都从这走。
  # ⚠️ `-Root` 仍然指**包目录**（要读包里的出厂默认、presets 等）；状态一律看 DG_HOME。
  if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $Root 'paths.ps1') }
  $dgHome = Get-DgHome
  $runDir = Join-Path $dgHome 'run'
  $logDir = Join-Path $dgHome 'logs'
  if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

  $agentCfg = $null
  try { $agentCfg = Get-Content -LiteralPath (Join-Path $dgHome 'agents.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  $modelNames = @(); $accessNames = @()
  if ($agentCfg) {
    $modelNames = @($agentCfg.models | ForEach-Object { [string]$_.name })
    $accessNames = @($agentCfg.access | ForEach-Object { [string]$_.name })
  }

  $s = if ($UiScale -gt 0) { $UiScale } else { 1.0 }
  $c = Get-DgAgentColors
  $site = 'Microsoft YaHei UI'
  # 字号**不乘** $s —— 点是物理单位，GDI+ 会自己按 DPI 换算（理由见 settings-window.ps1 里那段长注释）
  $fontItem = New-Object System.Drawing.Font $site, ([float]9.5)
  $fontBold = New-Object System.Drawing.Font $site, ([float]9.5), ([System.Drawing.FontStyle]::Bold)
  $fontH1 = New-Object System.Drawing.Font $site, ([float]12.0), ([System.Drawing.FontStyle]::Bold)
  $fontSmall = New-Object System.Drawing.Font $site, ([float]9.0)

  $W = [int](760 * $s); $H = [int](520 * $s)
  $f = New-Object System.Windows.Forms.Form
  $f.Text = '泡泡 · 子 agent 管理'
  $f.Font = $fontItem
  $f.BackColor = $c.Bg
  $f.ForeColor = $c.Text
  $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $f.Size = New-Object System.Drawing.Size ($W, $H)
  $f.MinimumSize = New-Object System.Drawing.Size ($W, $H)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = '子 agent 管理'
  $title.Font = $fontH1
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](16 * $s))
  $f.Controls.Add($title)

  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = '选中的那条会接到后面所有派活上，并且接着它的会话跑。双击一行 = 看这条的记录；「中断」停掉正在跑的。'
  $hint.Font = $fontSmall
  $hint.ForeColor = $c.Dim
  $hint.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](46 * $s))
  $hint.Size = New-Object System.Drawing.Size ([int](715 * $s)), ([int](22 * $s))
  $f.Controls.Add($hint)

  $targetLabel = New-Object System.Windows.Forms.Label
  $targetLabel.Font = $fontBold
  $targetLabel.ForeColor = $c.Accent
  $targetLabel.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](74 * $s))
  $targetLabel.Size = New-Object System.Drawing.Size ([int](715 * $s)), ([int](24 * $s))
  $f.Controls.Add($targetLabel)

  $list = New-Object System.Windows.Forms.ListView
  $list.View = [System.Windows.Forms.View]::Details
  $list.FullRowSelect = $true
  $list.MultiSelect = $false
  $list.HideSelection = $false
  $list.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](104 * $s))
  # 高度收一点，给下面第二排按钮（看记录 / 中断）腾位置
  $list.Size = New-Object System.Drawing.Size ([int](715 * $s)), ([int](262 * $s))
  $list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
  [void]$list.Columns.Add('状态', [int](76 * $s))
  [void]$list.Columns.Add('ID', [int](132 * $s))
  [void]$list.Columns.Add('模型', [int](120 * $s))
  [void]$list.Columns.Add('权限', [int](84 * $s))
  [void]$list.Columns.Add('最后任务', [int](207 * $s))
  [void]$list.Columns.Add('时间', [int](96 * $s))
  $f.Controls.Add($list)

  $status = New-Object System.Windows.Forms.Label
  $status.Font = $fontSmall
  $status.ForeColor = $c.Dim
  $status.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](378 * $s))
  $status.Size = New-Object System.Drawing.Size ([int](715 * $s)), ([int](22 * $s))
  $status.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
  $f.Controls.Add($status)

  function New-AgentButton([string]$text, [double]$x, [double]$w, [double]$y = 410) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Font = $fontItem
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $b.Location = New-Object System.Drawing.Point ([int]($x * $s)), ([int]($y * $s))
    $b.Size = New-Object System.Drawing.Size ([int]($w * $s)), ([int](32 * $s))
    $b.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    return $b
  }
  $btnPick = New-AgentButton '设为派活目标' 20 132
  $btnNew = New-AgentButton '新建…' 160 92
  $btnDel = New-AgentButton '删除' 260 92
  $btnFresh = New-AgentButton '每次新建（默认）' 360 148
  $btnClose = New-AgentButton '关闭' 618 118
  $f.Controls.Add($btnPick); $f.Controls.Add($btnNew); $f.Controls.Add($btnDel)
  $f.Controls.Add($btnFresh); $f.Controls.Add($btnClose)

  # 第二排：管理正在跑的东西 —— 看记录 / 中断
  $btnLog = New-AgentButton '查看记录…' 20 118 452
  $btnStop = New-AgentButton '中断' 146 76 452
  $btnStopAll = New-AgentButton '全部中断' 230 100 452
  $f.Controls.Add($btnLog); $f.Controls.Add($btnStop); $f.Controls.Add($btnStopAll)

  $state = @{ Target = [string](Get-DispatchTarget -RunDir $runDir) }

  function Refresh-AgentList {
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($r in (Get-DgAgentRows -RunDir $runDir)) {
      $it = New-Object System.Windows.Forms.ListViewItem($r.Status)
      [void]$it.SubItems.Add($r.Id)
      [void]$it.SubItems.Add($r.Model)
      [void]$it.SubItems.Add($r.Access)
      [void]$it.SubItems.Add($r.Task)
      [void]$it.SubItems.Add($r.When)
      $it.Tag = $r.Id
      if ($state.Target -and $state.Target -eq $r.Id) {
        $it.Font = $fontBold
        $it.BackColor = [System.Drawing.Color]::FromArgb(235, 244, 255)
      }
      [void]$list.Items.Add($it)
    }
    $list.EndUpdate()
    if ($state.Target) { $targetLabel.Text = "当前派活目标：$($state.Target)" }
    else { $targetLabel.Text = '当前派活目标：每次新建（默认）' }
    $running = 0
    foreach ($it in $list.Items) { if ($it.Text -like '*在跑*') { $running++ } }
    $status.Text = "共 $($list.Items.Count) 条，其中 $running 个在跑。加粗浅蓝底那条是当前派活目标；双击一行看记录。"
  }

  function Get-SelectedAgentId {
    if ($list.SelectedItems.Count -eq 0) { return '' }
    return [string]$list.SelectedItems[0].Tag
  }

  $btnPick.Add_Click({
      $id = Get-SelectedAgentId
      if (-not $id) { $status.Text = '先在列表里选一条。'; return }
      $state.Target = $id
      Set-DispatchTarget -RunDir $runDir -AgentId $id
      Refresh-AgentList
      $status.Text = "之后的派活都交给 $id（接着它的会话跑）。"
    })

  $btnFresh.Add_Click({
      $state.Target = ''
      Set-DispatchTarget -RunDir $runDir -AgentId ''
      Refresh-AgentList
      $status.Text = '好，之后的派活每次都新建一个 agent。'
    })

  $btnDel.Add_Click({
      $id = Get-SelectedAgentId
      if (-not $id) { $status.Text = '先在列表里选一条。'; return }
      $r = [System.Windows.Forms.MessageBox]::Show($f, "删掉 $id 这条记录？`n（正在跑的会先停掉；它的日志文件保留）", '删除 agent',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
      if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
      [void](Remove-DshAgentRecord -RunDir $runDir -Id $id)
      if ($state.Target -eq $id) { $state.Target = '' }
      Refresh-AgentList
      $status.Text = "删掉了 $id。"
    })

  # ---- 查看记录 ----
  $btnLog.Add_Click({
      $id = Get-SelectedAgentId
      if (-not $id) { $status.Text = '先在列表里选一条。'; return }
      Show-DgAgentLog -Root $Root -Id $id -UiScale $s -OwnerForm $f
      $status.Text = "看完 $id 的记录了。"
    })

  $list.Add_DoubleClick({
      $id = Get-SelectedAgentId
      if (-not $id) { return }
      Show-DgAgentLog -Root $Root -Id $id -UiScale $s -OwnerForm $f
      $status.Text = "看完 $id 的记录了。"
    })

  # ---- 中断 ----
  $btnStop.Add_Click({
      $id = Get-SelectedAgentId
      if (-not $id) { $status.Text = '先在列表里选一条。'; return }
      $r = Stop-DshAgent -RunDir $runDir -Id $id
      Refresh-AgentList
      $status.Text = "$id → $($r.Message)"
    })

  $btnStopAll.Add_Click({
      $running = @(Update-AgentStatus -RunDir $runDir | Where-Object { $_.status -eq 'running' })
      if ($running.Count -eq 0) { $status.Text = '现在没有在跑的子 agent。'; return }
      $r = [System.Windows.Forms.MessageBox]::Show($f, "中断正在跑的全部 $($running.Count) 个子 agent？", '全部中断',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
      if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
      $msgs = @()
      foreach ($a in $running) { $msgs += "$($a.id)：$((Stop-DshAgent -RunDir $runDir -Id $a.id).Message)" }
      Refresh-AgentList
      $status.Text = '全部中断完成 —— ' + ($msgs -join '；')
    })

  $btnNew.Add_Click({
      if ($modelNames.Count -eq 0) { $status.Text = '读不到 agents.json 的模型表，新建不了。'; return }
      $dlg = New-Object System.Windows.Forms.Form
      $dlg.Text = '新建 agent'
      $dlg.Font = $fontItem
      $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
      $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
      $dlg.Size = New-Object System.Drawing.Size ([int](380 * $s)), ([int](236 * $s))
      $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
      $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false

      $lblM = New-Object System.Windows.Forms.Label
      $lblM.Text = '模型'; $lblM.AutoSize = $true
      $lblM.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](24 * $s))
      $cmbM = New-Object System.Windows.Forms.ComboBox
      $cmbM.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
      $cmbM.Location = New-Object System.Drawing.Point ([int](90 * $s)), ([int](20 * $s))
      $cmbM.Size = New-Object System.Drawing.Size ([int](250 * $s)), ([int](26 * $s))
      [void]$cmbM.Items.AddRange([object[]]$modelNames)
      $cmbM.SelectedIndex = 0

      $lblA = New-Object System.Windows.Forms.Label
      $lblA.Text = '权限'; $lblA.AutoSize = $true
      $lblA.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](62 * $s))
      $cmbA = New-Object System.Windows.Forms.ComboBox
      $cmbA.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
      $cmbA.Location = New-Object System.Drawing.Point ([int](90 * $s)), ([int](58 * $s))
      $cmbA.Size = New-Object System.Drawing.Size ([int](250 * $s)), ([int](26 * $s))
      [void]$cmbA.Items.AddRange([object[]]$accessNames)
      if ($cmbA.Items.Count -gt 0) { $cmbA.SelectedIndex = 0 }

      $lblN = New-Object System.Windows.Forms.Label
      $lblN.Text = '备注'; $lblN.AutoSize = $true
      $lblN.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](100 * $s))
      $txtN = New-Object System.Windows.Forms.TextBox
      $txtN.Location = New-Object System.Drawing.Point ([int](90 * $s)), ([int](96 * $s))
      $txtN.Size = New-Object System.Drawing.Size ([int](250 * $s)), ([int](26 * $s))
      $txtN.Text = '给这个 agent 派活'

      $ok = New-Object System.Windows.Forms.Button
      $ok.Text = '新建'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
      $ok.Location = New-Object System.Drawing.Point ([int](190 * $s)), ([int](152 * $s))
      $ok.Size = New-Object System.Drawing.Size ([int](70 * $s)), ([int](30 * $s))
      $cancel = New-Object System.Windows.Forms.Button
      $cancel.Text = '取消'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
      $cancel.Location = New-Object System.Drawing.Point ([int](270 * $s)), ([int](152 * $s))
      $cancel.Size = New-Object System.Drawing.Size ([int](70 * $s)), ([int](30 * $s))
      $dlg.Controls.Add($lblM); $dlg.Controls.Add($cmbM); $dlg.Controls.Add($lblA)
      $dlg.Controls.Add($cmbA); $dlg.Controls.Add($lblN); $dlg.Controls.Add($txtN)
      $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel)
      $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

      if ($dlg.ShowDialog($f) -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return }
      $rec = New-DshAgentSlot -RunDir $runDir -LogDir $logDir -ModelName ([string]$cmbM.SelectedItem) `
        -AccessName ([string]$cmbA.SelectedItem) -Note ([string]$txtN.Text)
      $dlg.Dispose()
      # 新建完顺手设为派活目标 —— 新建它的目的通常就是"以后派给它"
      $state.Target = [string]$rec.id
      Set-DispatchTarget -RunDir $runDir -AgentId $state.Target
      Refresh-AgentList
      $status.Text = "建好了 $($rec.id)（$($rec.model) · $($rec.access)），并已设为派活目标。"
    })

  $btnClose.Add_Click({ $f.Close() })
  $list.Add_DoubleClick({
      $id = Get-SelectedAgentId
      if ($id) {
        $state.Target = $id
        Set-DispatchTarget -RunDir $runDir -AgentId $id
        Refresh-AgentList
        $status.Text = "之后的派活都交给 $id。"
      }
    })

  Refresh-AgentList
  $f.Add_Shown({ try { Refresh-AgentList } catch { } })

  if ($SelfTest -or $RenderTo) {
    # ⚠️ 必须**真的 Show 出来**（挪到屏幕外）再 DrawToBitmap —— 只 CreateControl + PerformLayout
    # 的话子控件不渲染，存出来是一张只有标题栏的空图（实测踩过）。settings-window.ps1 同款做法。
    $f.ShowInTaskbar = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.Location = New-Object System.Drawing.Point -4000, -4000
    $f.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 120
    [System.Windows.Forms.Application]::DoEvents()
    if ($RenderTo) {
      if (-not (Test-Path -LiteralPath $RenderTo)) { New-Item -ItemType Directory -Force -Path $RenderTo | Out-Null }
      $bmp = New-Object System.Drawing.Bitmap $f.Width, $f.Height
      $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $f.Width, $f.Height))
      $out = Join-Path $RenderTo 'agents-window.png'
      $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
      Write-Host "窗口预览：$out"
    }
    if ($SelfTest) { $f.Dispose(); return $null }
  }

  [void]$f.ShowDialog($OwnerForm)
  $f.Dispose()
  return $state.Target
}

function Test-DgAgents {
  <# 纯逻辑自检：在**临时目录**里建一套假数据跑「读列表 / 新建 / 设目标 / 删除」，不碰真 run\。 #>
  param([string]$Root, [double]$UiScale = 0)
  $ok = @()
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dg-agents-test-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'run'), (Join-Path $tmp 'logs') | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'agents.json') -Destination (Join-Path $tmp 'agents.json') -Force
  try {
    @(
      [pscustomobject]@{
        id = 'agent-1111'; task = '改 docx 第三段'; model = 'DeepSeek Flash'; access = '工作区可写'
        pid = $null; startedAt = (Get-Date).ToString('o'); endedAt = $null; status = 'done'; exitCode = 0
        logFile = (Join-Path $tmp 'logs\agent-1111.jsonl'); patch = ''; sessionId = 'pet-task-1111'
      }
    ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $tmp 'run\agents.json') -Encoding UTF8

    $rows = Get-DgAgentRows -RunDir (Join-Path $tmp 'run')
    $ok += ($rows.Count -eq 1)
    $ok += ($rows[0].Id -eq 'agent-1111')

    $rec = New-DshAgentSlot -RunDir (Join-Path $tmp 'run') -LogDir (Join-Path $tmp 'logs') `
      -ModelName 'DeepSeek V4 Pro' -AccessName '完全访问' -Note '测试用'
    $rows2 = Get-DgAgentRows -RunDir (Join-Path $tmp 'run')
    $ok += ($rows2.Count -eq 2)
    $ok += (($rows2 | Where-Object { $_.Id -eq $rec.id }).Status -like '*待派活*')
    $ok += ($rec.sessionId -eq ('pet-task-' + ($rec.id -replace '^agent-', '')))

    Set-DispatchTarget -RunDir (Join-Path $tmp 'run') -AgentId $rec.id
    $ok += ((Get-DispatchTarget -RunDir (Join-Path $tmp 'run')) -eq $rec.id)

    [void](Remove-DshAgentRecord -RunDir (Join-Path $tmp 'run') -Id $rec.id)
    $rows3 = Get-DgAgentRows -RunDir (Join-Path $tmp 'run')
    $ok += ($rows3.Count -eq 1)
    # 删掉的正好是派活目标 → 指针要被自动清空，不能留一个指向空气的目标
    $ok += ((Get-DispatchTarget -RunDir (Join-Path $tmp 'run')) -eq '')

    # ---- 下面这组是「查看记录 / 中断」----
    $base = $ok.Count
    $fakeLog = Join-Path $tmp 'logs\agent-1111.jsonl'
    @(
      '{"type":"thinking","text":"先想一下"}',
      '{"type":"tool_call","tool":"read_image"}',
      '{"type":"tool_call","tool":"pwsh"}',
      '{"type":"final","text":"改完了第三段。"}'
    ) | Set-Content -LiteralPath $fakeLog -Encoding UTF8
    $rec1111 = @(Get-Agents -RunDir (Join-Path $tmp 'run')) | Where-Object { $_.id -eq 'agent-1111' } | Select-Object -First 1
    $digest = Get-AgentLogDigest -Agent $rec1111 -LogFile $fakeLog
    $ok += ($digest -match '改完了第三段')     # 结论要能看到
    $ok += ($digest -match 'read_image')       # 工具调用要能看到
    $ok += ($digest -match '工具调用 2 次')     # 统计要对

    # 已结束的记录：中断应当是"什么都不做"，而不是把 done 改成 stopped
    $r1 = Stop-DshAgent -RunDir (Join-Path $tmp 'run') -Id 'agent-1111'
    $ok += ($r1.Ok -eq $false)
    $ok += ((@(Get-Agents -RunDir (Join-Path $tmp 'run')) | Where-Object { $_.id -eq 'agent-1111' }).status -eq 'done')

    # 走常驻大脑、还在排队的任务：撤掉它的请求文件就算取消
    $tdRun = Join-Path $tmp 'run'
    $brainDir = Join-Path $tdRun 'brain'
    New-Item -ItemType Directory -Force -Path $brainDir | Out-Null
    Set-Content -LiteralPath (Join-Path $tdRun 'stage.txt') -Value '空闲' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $brainDir 'req-2222bbbb.json') -Value '{"id":"2222bbbb","kind":"task","text":"排队中"}' -Encoding UTF8
    $more = @(Get-Agents -RunDir $tdRun) + [pscustomobject]@{
      id = 'agent-2222'; task = '排队中'; model = 'DeepSeek Flash'; access = '完全访问'
      pid = $null; brainId = '2222bbbb'; via = 'brain'; startedAt = (Get-Date).ToString('o')
      status = 'running'; exitCode = $null; logFile = ''; patch = ''
    }
    Save-Agents -RunDir $tdRun -Agents $more
    $r2 = Stop-DshAgent -RunDir $tdRun -Id 'agent-2222'
    $ok += ($r2.Ok -eq $true -and $r2.Mode -eq 'brain-queued')
    $ok += (-not (Test-Path -LiteralPath (Join-Path $brainDir 'req-2222bbbb.json')))
    $ok += ((@(Get-Agents -RunDir $tdRun) | Where-Object { $_.id -eq 'agent-2222' }).status -eq 'stopped')

    Write-Host ("  1) 读列表 {0} 条（agent-1111）              {1}" -f $rows.Count, $(if ($ok[0] -and $ok[1]) { '✔' } else { '✘' }))
    Write-Host ("  2) 新建一条 → 共 {0} 条、状态是待派活       {1}" -f $rows2.Count, $(if ($ok[2] -and $ok[3] -and $ok[4]) { '✔' } else { '✘' }))
    Write-Host ("  3) 设为派活目标 → dispatch.json 记下来了    {0}" -f $(if ($ok[5]) { '✔' } else { '✘' }))
    Write-Host ("  4) 删除 → 记录没了、派活目标被清空          {0}" -f $(if ($ok[6] -and $ok[7]) { '✔' } else { '✘' }))
    Write-Host ("  5) 记录摘要 → 结论 / 工具调用 / 计数都对     {0}" -f $(if (@($ok[$base..($base+2)]) -notcontains $false) { '✔' } else { '✘' }))
    Write-Host ("  6) 中断已结束 → 不动它、也不报错             {0}" -f $(if (@($ok[($base+3)..($base+4)]) -notcontains $false) { '✔' } else { '✘' }))
    Write-Host ("  7) 中断排队中 → 请求撤回 + 记录翻成 stopped  {0}" -f $(if (@($ok[($base+5)..($ok.Count-1)]) -notcontains $false) { '✔' } else { '✘' }))
    Write-Host ("  agents 窗口逻辑：{0}/{1} 项通过" -f @($ok | Where-Object { $_ }).Count, $ok.Count)
    return (@($ok | Where-Object { -not $_ }).Count -eq 0)
  } finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
}

# ---------------------------------------------------------------------------
# 独立运行入口（不是被 dot-source 时）：
#   pwsh -NoProfile -ExecutionPolicy Bypass -File agents-window.ps1
#
# 为什么要它：这个窗口平时由桌宠菜单打开，而桌宠只在**启动时** dot-source 本文件 ——
# 改了代码就得重启桌宠，可桌宠手里可能正跑着任务，重启会把它们全掐掉。
# 有了独立入口，改完窗口代码直接开一个看效果，不碰桌宠。
#
# ⚠️ 独立进程必须自己设 DPI 感知：这台机器是 200%，不设的话窗口会被系统位图拉伸（糊）。
#    桌宠那条路是在 DesktopGuide.ps1 开头统一设的，这里补一份等效的。
if ($MyInvocation.InvocationName -ne '.') {
  if (-not ('DesktopGuide.Dpi' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace DesktopGuide {
  public static class Dpi {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    public static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);
    public static uint Scale() {
      try { SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2); } catch { }
      try { return GetDpiForSystem(); } catch { return 96; }
    }
  }
}
'@
  }
  $dpi = [Math]::Max(1.0, [double][DesktopGuide.Dpi]::Scale() / 96.0)
  . (Join-Path $PSScriptRoot 'paths.ps1')
  . (Join-Path $PSScriptRoot 'dsh-agents.ps1')
  [void](Show-DgAgents -Root $PSScriptRoot -UiScale $dpi)
}
