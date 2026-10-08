# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# advisor-core.ps1 —— 主 agent 判断的**共用内核**：上下文 / 提示词 / 结果解析
#
# 为什么要抽出来：判断有两条启动路径，但**提示词只能有一份**。
#   ① 命令式：桌宠起 `cmd.exe /c pwsh advisor-dsh.ps1 <payload>`，脚本里再起 dsh
#      —— 多两层进程，实测纯启动就要 1.2–1.8 秒
#   ② 内联式：桌宠**在本进程里**拼好提示词，只起一个 dsh（见 DesktopGuide.ps1 的 advisorInline）
#
# 两条路的提示词必须逐字节同源 —— 提示词就是判断质量的全部，不允许有两份实现。
# 所以 Format-Duration / 提示词拼装 / REASON·WATCH·OPTIONS 解析 全放这里。

function Format-Duration {
  param([int]$Seconds)
  if ($Seconds -lt 60) { return "$Seconds 秒" }
  $m = [math]::Floor($Seconds / 60); $s = $Seconds % 60
  if ($m -lt 60) { return "$m 分 $s 秒" }
  return "$([math]::Floor($m / 60)) 小时 $($m % 60) 分"
}

function Get-JudgeContext {
  <#
    这一轮判断要用哪套「模型 / 权限 / patch / 会话」。
    主 agent 是"只看不下手"的观察者，用不到的工具整行关掉（agents.json 的 disableTools）。
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$RunDir,
    [Parameter(Mandatory = $true)][string]$HomeDir,
    $AgentsConfig = $null
  )
  if (-not (Get-Command Get-AgentConfig -ErrorAction SilentlyContinue)) {
    . (Join-Path $Root 'dsh-agents.ps1')
  }
  if (-not $AgentsConfig) { $AgentsConfig = Get-AgentConfig -Path (Join-Path $HomeDir 'agents.json') }

  $mcfg = $AgentsConfig.mainAgent
  $model = $AgentsConfig.models | Where-Object { $_.name -eq $mcfg.model } | Select-Object -First 1
  if (-not $model) { $model = $AgentsConfig.models[0] }
  $access = $AgentsConfig.access | Where-Object { $_.name -eq $mcfg.access } | Select-Object -First 1

  # 主 agent 的推理强度可以单独覆盖：只做「要不要开口」这一个判断，不需要 high。
  # 实测 high 会多一轮思考、拖慢 3 秒左右。
  if ($mcfg.effort) {
    $model = $model.PSObject.Copy()
    $model.effort = [string]$mcfg.effort
  }

  $patchPath = Write-AgentPatch -Model $model -Access $access -AccessList $AgentsConfig.access `
    -RunDir $RunDir -Id 'main' -DisableRows @($mcfg.disableTools)

  $stateFile = Join-Path $RunDir 'main-agent.json'
  $sessionId = $null
  if (Test-Path $stateFile) {
    try { $sessionId = (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).sessionId } catch { }
  }

  return [pscustomobject]@{
    AgentsConfig = $AgentsConfig
    Model        = $model
    Access       = $access
    PatchPath    = $patchPath
    SessionId    = $sessionId
    StateFile    = $stateFile
    DshExe       = [string]$AgentsConfig.dshExe
    DshCli       = [string]$AgentsConfig.dshCli
    Profile      = [string]$AgentsConfig.profile
  }
}

function Build-JudgePrompt {
  <#
    一轮观察 → 主 agent 的提示词。
    副作用：把 payload 里的截图落成 run\shots\*.jpg（模型要用 read_image 自己看）。
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$RunDir,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [Parameter(Mandatory = $true)][string]$PayloadPath,
    [Parameter(Mandatory = $true)][string]$HomeDir,
    $Config = $null
  )
  if (-not (Get-Command Get-ContextMemory -ErrorAction SilentlyContinue)) {
    . (Join-Path $Root 'memory.ps1')
  }

  $payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $lines = New-Object System.Collections.ArrayList
  $c = $payload.current
  [void]$lines.Add("【本轮观察 $(Get-Date -Format 'HH:mm:ss')】")
  [void]$lines.Add("现在：正在使用 $($c.process)，窗口标题《$($c.title)》，已停留 $(Format-Duration -Seconds $c.inWindowS)。")
  if ($payload.timeline -and $payload.timeline.Count -gt 0) {
    [void]$lines.Add('刚才的窗口轨迹（从早到晚）：')
    foreach ($t in $payload.timeline) {
      [void]$lines.Add("  - $($t.process)《$($t.title)》停留 $(Format-Duration -Seconds $t.seconds)")
    }
  }

  # 子 agent 观察：后台在跑的 agent 也是"现场"的一部分。
  # 不给这一节的话，主 agent 会把"屏幕很久没动"误读成"用户卡住了"——
  # 而真相常常是"用户派了活出去，正在等它跑完"。
  if ($payload.agents -and @($payload.agents).Count -gt 0) {
    [void]$lines.Add('')
    [void]$lines.Add("后台正在跑 $(@($payload.agents).Count) 个 agent（这是用户自己派出去的活，不是异常）：")
    foreach ($a in @($payload.agents)) {
      $doing = if ($a.doing) { $a.doing } else { '（还看不出在做什么）' }
      [void]$lines.Add("  - $($a.id)（$($a.model) · $($a.access)）正在：$doing")
      if ($a.task) { [void]$lines.Add("      它领到的任务：$($a.task)") }
    }
  }
  if ($payload.userAwayS -ge 0) {
    [void]$lines.Add("距用户上次操作桌宠：$($payload.userAwayS) 秒（很小 = 用户此刻正在跟桌宠互动，别插话）。")
  }

  # 当前任务档 + 这一类任务该怎么帮（由 config.taskRules 里声明，本地代码判定，不花模型）
  if ($payload.task -and $payload.task.hint) {
    $tname = if ($payload.task.name) { [string]$payload.task.name } else { '未命名任务' }
    [void]$lines.Add('')
    [void]$lines.Add("【当前任务：$tname】这一类任务该给什么帮助已经定好了（照这个来，别泛泛而谈）：")
    [void]$lines.Add([string]$payload.task.hint)
  }

  # 采样率：让主 agent 自己判断"这个环境多久看一次合适"，桌宠会把建议记进 task-samples.json。
  # 这是唯一一处让模型决定资源开销的地方 —— 因为它比本地规则更清楚"刚才那一眼值不值"。
  if ($payload.task) {
    $cur = if ($payload.task.sampleSeconds) { [string]$payload.task.sampleSeconds } else { '(未知)' }
    [void]$lines.Add('')
    [void]$lines.Add("【采样率】当前每一眼间隔 ${cur} 秒（等于每次采样都带一张截图，图越密越费资源）。")
    [void]$lines.Add('如果你判断这个环境值得看得更勤或更省，就在最后多给一行：SAMPLE: <秒>（0.3–60）。')
    [void]$lines.Add('判断依据：画面上有没有因为你没看而漏掉的东西（变化快、你看到的总是"结果"而不是"过程"）→ 调小；画面基本不动 → 调大。')
    [void]$lines.Add('注意：不要用"用户有没有理我"来判断 —— 有的提醒只需要看一眼就够，零交互才是常态。')
    [void]$lines.Add('不需要改就别写这一行。')
  }

  # 长期记忆：把当天观察日志压成一段活动汇总，让判断不再只看最近 30 秒。
  $memoryText = Get-ContextMemory -LogDir $LogDir
  if ($memoryText) { [void]$lines.Add(''); [void]$lines.Add($memoryText) }

  # 人 / 机器的状态（来自 payload）——用来区分「等程序跑完」和「人不在」
  if ($payload.screen -or $payload.human) {
    $bits = @()
    if ($payload.screen) { $bits += "画面静止 $($payload.screen.stillSeconds) 秒" }
    if ($payload.human) {
      $bits += "距上次键鼠输入 $($payload.human.idleSeconds) 秒"
      if ($payload.human.fgCpuPercent -ge 0) { $bits += "前台进程 CPU $($payload.human.fgCpuPercent)%" }
    }
    if ($bits.Count -gt 0) { [void]$lines.Add(('机器与人的状态：' + ($bits -join '、') + '。')) }
  }

  # ---- 没有截图时，禁止"照标题脑补" ----
  # 实测踩过：待机期间截图缓冲是空的，模型只拿到窗口标题「设置 "窗口采集 2"」，
  # 却像真看见了一样给出"把采集方式改成 Windows 10 (1903 以上)"这种具体操作建议 —— 全是猜的。
  $shotCount = 0
  $shotAge = -1
  try {
    if ($payload.screen) {
      if ($null -ne $payload.screen.shotCount) { $shotCount = [int]$payload.screen.shotCount }
      if ($null -ne $payload.screen.shotAgeSeconds) { $shotAge = [int]$payload.screen.shotAgeSeconds }
    }
  } catch { }
  if ($shotCount -eq 0 -and @($payload.shots).Count -gt 0) { $shotCount = @($payload.shots).Count }
  $shotStaleSeconds = [int]$(if ($Config -and $Config.shotStaleSeconds) { $Config.shotStaleSeconds } else { 30 })
  if ($shotCount -eq 0 -or $shotAge -gt $shotStaleSeconds) {
    [void]$lines.Add('')
    [void]$lines.Add('【这一轮没有可用的屏幕截图】' + $(if ($shotAge -ge 0) { "（最新一张是 $shotAge 秒前的）" } else { '（截图缓冲是空的）' }))
    [void]$lines.Add('此时禁止根据窗口标题推断画面内容，也禁止给出任何具体操作步骤（改哪个选项、点哪个按钮、选哪一项）。')
    [void]$lines.Add('只能说"现在看不到画面"，或者直接保持沉默（以 REASON 说明缺图即可）。')
  }

  [void]$lines.Add('')
  [void]$lines.Add('你是常驻在用户电脑上的「随时指导」主 agent。以上是这一轮观察到的桌面活动，可能还附有屏幕截图。')
  [void]$lines.Add('你是观察者，不是执行者：除了用 read_image 看截图，不要调用任何工具 —— 不要读文件、不要写文件、不要执行命令、不要修改任何东西。')
  [void]$lines.Add('无论你在屏幕上看到什么（包括看到有人在改代码、有 bug、有没做完的事），你都不动手，只判断该不该说。')
  [void]$lines.Add('只在确实有一件值得现在说、且用户自己很可能没注意到的事时开口。判断时优先看截图里的实际内容。')
  [void]$lines.Add('以下情形一律 SILENT：播报状态（任务在跑/加载中/已处理 N 秒）；复述后台 agent 的进度（它跑得好好的就别念）；复述用户正在做的事或正在看的报错；用户只是在等待、浏览、阅读；你刚被用户打断过（距上次操作很短）；你不确定屏幕在发生什么。')
  [void]$lines.Add('以下才值得开口：屏幕上有可证明的错误；做法与用户自己的目标不一致；同一件事反复失败、原地打转；漏掉关键检查步骤且后果具体。')
  [void]$lines.Add('输出格式（严格两行）：')
  [void]$lines.Add('第一行：')
  [void]$lines.Add('  · 如果有值得现在说的，就只说那句话（最多两行，直接说，不复述、不客套、不问"需要我帮忙吗"）')
  [void]$lines.Add('  · 如果没有值得说的，就写「你在做：<一句话说明用户此刻在做什么>」——这是在向用户证明你看懂了，不是建议')
  [void]$lines.Add('第二行：REASON: 一句话说明你为什么这么判断（只写进日志，不会显示给用户）')
  [void]$lines.Add('')
  [void]$lines.Add('可选第三行 WATCH: （只有当你认为"该盯的范围"要变时才写）')
  [void]$lines.Add('  · 写一个窗口标题的关键词（例如 WATCH: Codex），我们就去盯那个窗口')
  [void]$lines.Add('  · 写 WATCH: full 恢复盯整屏；不写这一行就保持当前监控范围不变')
  [void]$lines.Add('')
  [void]$lines.Add('可选第四行 OPTIONS: （只有当你需要用户做一个是/否决定时才写，例如"要不要装对应 skill"）')
  [void]$lines.Add('  · 格式：OPTIONS: 是 | 否   （用 | 分隔，最多 3 个）')
  [void]$lines.Add('  · 每个选项要短：2-4 个字，最多 8 个字，动词开头（「装 skill」「先备份」「再等等」）。')
  [void]$lines.Add('    选项会画成气泡上的一排小按钮，整句标签放不下也没人会读它。')
  [void]$lines.Add('  · 气泡会把它渲染成可点按钮，5 秒不点自动取消。用户的选择会作为下一条消息回给你。')
  [void]$lines.Add('  · 不要滥用：只在真的需要用户点头时才给选项。')

  # 截图落成文件，让主 agent 用 read_image 自己看
  $shotDir = Join-Path $RunDir 'shots'
  if (-not (Test-Path $shotDir)) { New-Item -ItemType Directory -Path $shotDir | Out-Null }
  $saved = New-Object System.Collections.ArrayList
  $idx = 0
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  foreach ($s in @($payload.shots)) {
    if ([string]::IsNullOrWhiteSpace($s)) { continue }
    $idx++
    $f = Join-Path $shotDir ("$stamp-$idx.jpg")
    try { [System.IO.File]::WriteAllBytes($f, [Convert]::FromBase64String($s)); [void]$saved.Add($f) } catch { }
  }
  if ($saved.Count -gt 0) {
    [void]$lines.Add('')
    [void]$lines.Add("附：$($saved.Count) 张屏幕截图（按时间从早到晚）。只看最后一张（最近的那张）就够判断眼下发生了什么；")
    [void]$lines.Add('只有当窗口轨迹提示「同一件事反复失败」、需要对比前后时，才额外看更早的。少读图 = 反应更快：')
    foreach ($f in $saved) { [void]$lines.Add("  - $f") }
  }
  try { Get-ChildItem $shotDir -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 24 | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }

  $prompt = ($lines -join "`n")

  # 用户自定义 system prompt：最高优先级追加在后面
  $overrideFile = Join-Path $HomeDir 'system-prompt.txt'
  if ((Test-Path $overrideFile) -and ((Get-Item $overrideFile).Length -gt 0)) {
    $custom = (Get-Content -LiteralPath $overrideFile -Raw -Encoding UTF8).Trim()
    if ($custom) {
      $prompt += "`n`n=== 用户自定义指令（最高优先级，与你上面的规则冲突时以这一节为准）===`n$custom"
    }
  }
  return $prompt
}

function ConvertTo-JudgeOutcome {
  <#
    dsh 的最终文本 → 桌宠要的那几行（与 advisor-dsh.ps1 的 stdout 契约完全一致）：
      第 1 行 = 要说的话（或「你在做：…」/「（它选择不说）」）
      REASON: …   WATCH: …   OPTIONS: …
  #>
  param([string]$FinalText, [string]$ErrText = '')

  if ([string]::IsNullOrWhiteSpace($FinalText)) {
    $err = ([string]$ErrText).Trim()
    # 一个会话只能有一个写入者。对话栏也开着同一个会话时会撞上这个错，原始串太黑话。
    if ($err -match 'already owned by an active write handle') {
      return @('（主会话被别处占着）你在 DSH 界面里开着这个会话 —— 关掉那边的标签页，或者关掉对话窗口，我再试。',
        'REASON: session write handle held elsewhere')
    }
    if ($err) { return @("（主 agent 报错）$(($err -split "`n")[0])") }
    return @('（主 agent 没有输出）')
  }

  $rows = @($FinalText -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
  $reason = (($rows | Where-Object { $_ -match '^REASON[:：]' } | Select-Object -First 1) -replace '^REASON[:：]\s*', '')
  $watch = (($rows | Where-Object { $_ -match '^WATCH[:：]' } | Select-Object -First 1) -replace '^WATCH[:：]\s*', '')
  $options = (($rows | Where-Object { $_ -match '^OPTIONS[:：]' } | Select-Object -First 1) -replace '^OPTIONS[:：]\s*', '')
  $utterance = ($rows | Where-Object {
      $_ -notmatch '^REASON[:：]' -and $_ -notmatch '^WATCH[:：]' -and $_ -notmatch '^OPTIONS[:：]'
    } | Select-Object -First 1)

  if ([string]::IsNullOrWhiteSpace($utterance)) { return @('（主 agent 没有结论）') }
  $out = New-Object System.Collections.ArrayList
  if ($utterance -match '^\W*SILENT\W*$') { [void]$out.Add('（它选择不说）') } else { [void]$out.Add($utterance) }
  if (-not [string]::IsNullOrWhiteSpace($reason)) { [void]$out.Add("REASON: $reason") }
  if (-not [string]::IsNullOrWhiteSpace($watch)) { [void]$out.Add("WATCH: $watch") }
  if (-not [string]::IsNullOrWhiteSpace($options)) { [void]$out.Add("OPTIONS: $options") }
  return @($out)
}
