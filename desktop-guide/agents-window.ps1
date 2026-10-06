# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# agents-window.ps1 —— 「派活给谁」窗口：**选一条 / 新建一条 / 删一条**
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

function Show-DgAgents {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [double]$UiScale = 0,
    $OwnerForm = $null,
    [string]$RenderTo = '',
    [switch]$SelfTest
  )
  try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

  $runDir = Join-Path $Root 'run'
  $logDir = Join-Path $Root 'logs'
  if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Force -Path $runDir | Out-Null }
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

  $agentCfg = $null
  try { $agentCfg = Get-Content -LiteralPath (Join-Path $Root 'agents.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
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
  $f.Text = '泡泡 · 派活给谁'
  $f.Font = $fontItem
  $f.BackColor = $c.Bg
  $f.ForeColor = $c.Text
  $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $f.Size = New-Object System.Drawing.Size ($W, $H)
  $f.MinimumSize = New-Object System.Drawing.Size ($W, $H)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = '派活给谁'
  $title.Font = $fontH1
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](16 * $s))
  $f.Controls.Add($title)

  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = '选中的那条会接到后面所有语音 / 打字 / 拖文件的派活上，并且接着它的会话跑（上下文不断）。'
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
  $list.Size = New-Object System.Drawing.Size ([int](715 * $s)), ([int](300 * $s))
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
  $status.Location = New-Object System.Drawing.Point ([int](20 * $s)), ([int](414 * $s))
  $status.Size = New-Object System.Drawing.Size ([int](715 * $s)), ([int](22 * $s))
  $status.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
  $f.Controls.Add($status)

  function New-AgentButton([string]$text, [double]$x, [double]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Font = $fontItem
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $b.Location = New-Object System.Drawing.Point ([int]($x * $s)), ([int](448 * $s))
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
    $status.Text = "共 $($list.Items.Count) 条。加粗浅蓝底那条就是当前派活目标。"
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

    Write-Host ("  1) 读列表 {0} 条（agent-1111）              {1}" -f $rows.Count, $(if ($ok[0] -and $ok[1]) { '✔' } else { '✘' }))
    Write-Host ("  2) 新建一条 → 共 {0} 条、状态是待派活       {1}" -f $rows2.Count, $(if ($ok[2] -and $ok[3] -and $ok[4]) { '✔' } else { '✘' }))
    Write-Host ("  3) 设为派活目标 → dispatch.json 记下来了    {0}" -f $(if ($ok[5]) { '✔' } else { '✘' }))
    Write-Host ("  4) 删除 → 记录没了、派活目标被清空          {0}" -f $(if ($ok[6] -and $ok[7]) { '✔' } else { '✘' }))
    Write-Host ("  agents 窗口逻辑：{0}/{1} 项通过" -f @($ok | Where-Object { $_ }).Count, $ok.Count)
    return (@($ok | Where-Object { -not $_ }).Count -eq 0)
  } finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
}
