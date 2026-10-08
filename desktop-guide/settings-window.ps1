# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# settings-window.ps1 —— 一个窗口改完 config.json 里的所有参数
#
# 为什么要有它：config.json 里现在有 60 多个键，一半带 `_xxxNote` 说明。想调「多久看一眼屏幕」
# 得先知道键名是 sampleSeconds、还得记得单位是秒不是毫秒 —— 对用户不友好，而且很容易改坏
# （JSON 少个逗号整份配置就废了）。所以做一个 **schema 驱动**的设置窗口：每个键都有一行，
# 类型对得上（数字就是数字框、开关就是勾选框）、范围夹好、说明就在旁边。
#
# 三个设计取舍：
#   1. schema 写在本文件里，不从 config.json 反推 —— JSON 里没有「这个键是什么类型 / 范围 / 单位」
#      的信息，而**夹子**恰恰是最值钱的部分（比如采样下限 0.3 秒，防的是学出 0.05 秒把机器烧了）。
#   2. 保存时**不重写整份文件**：先把 config.json 读成有序字典，只覆盖**改过**的键。这样
#      `_xxxNote` 那些说明、以及以后新加的键，都不会被这个窗口吃掉。
#   3. 只把「改过的键」交回调用方，由调用方决定怎么当场生效（字体 / 朗读 / 语音 / 采样节奏…）。
#
# 对外：
#   Show-DgSettings -ConfigPath <path> [-Root <dir>] [-UiScale <n>] [-OwnerForm <form>] [-RenderTo <dir>]
#     保存 → 返回 [ordered]@{ 改过的键 = 新值 }；取消 → $null
#   `pwsh -File settings-window.ps1` 也能单独开（改的是同一份 config.json）
#   -RenderTo <dir> = 不弹窗，把每个分组离屏渲染成 PNG（排版自检用，见 run\settings-*.png）

param(
  [string]$DgsConfig = '',
  [string]$DgsRenderTo = '',
  [switch]$DgsSelfTest,
  [double]$DgsUiScale = 0,
  [string]$DgsSize = ''
)

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# 状态根（DG_HOME）统一走 paths.ps1：被桌宠 Dot-Source 时它已经加载过了，这里兜住"单独开这个窗口"的情况
# （写 run\openai.key 和 agents.json 都从它推路径）
if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'paths.ps1') }

# ---------------------------------------------------------------------------
# schema：分组 → 参数
#
# Kind：bool | int | number | text | choice | path | multiline | info（info = 只显示不可改，原值保留）
# 其它字段：Min/Max/Step/Decimals（数字）、Choices（选择）、Pattern/PatternTip（文本校验）、
#           Def（仓库里带的那份 config.json 的值，也就是「恢复默认」的目标）、
#           Late（需要重启 / 下次才生效的提示，会贴在说明后面）
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 大脑来源：dsh / openai / ollama / custom
#
# 为什么要这一项：换大脑原来得手改 advisor / advisorFast 两整条命令行 —— 对"知道自己在干嘛"
# 的人没问题，但"我就想拿本机 Ollama 试试"会被卡在门外（还得先知道有 advisor-ollama.ps1）。
# 现在选择会**翻译成那两条命令**写进 config.json：配置里仍然只有两条命令（可读、可手改、
# 别处引用的也是它们），不引入第二套事实来源。
# ---------------------------------------------------------------------------
function Get-DgBrainKindFromCommands {
  param([string]$Advisor = '', [string]$Fast = '')
  if ($Advisor -match 'advisor-ollama\.ps1' -or $Fast -match 'advisor-ollama\.ps1') { return 'ollama' }
  if ($Advisor -match 'advisor-dsh\.ps1') { return 'dsh' }
  if ($Advisor -match 'advisor-(openai|minimax)\.ps1') { return 'openai' }
  return 'custom'
}

function Resolve-DgBrainCommands {
  <# 「大脑来源」→ advisor / advisorFast 两条命令。custom → $null（用户自己写的，别碰）。 #>
  param([string]$Kind)
  $ps = 'pwsh -NoProfile -ExecutionPolicy Bypass -File'
  switch ($Kind) {
    'dsh' {
      return [ordered]@{
        advisor     = "$ps `"{root}\advisor-dsh.ps1`""
        advisorFast = "$ps `"{root}\advisor-openai.ps1`""
      }
    }
    'openai' {
      return [ordered]@{
        advisor     = "$ps `"{root}\advisor-openai.ps1`""
        advisorFast = "$ps `"{root}\advisor-openai.ps1`""
      }
    }
    'ollama' {
      return [ordered]@{
        advisor     = "$ps `"{root}\advisor-ollama.ps1`""
        advisorFast = "$ps `"{root}\advisor-ollama.ps1`""
      }
    }
    default { return $null }
  }
}

function Set-DgAgentsField {
  <# 把 'mainAgent.model' 这样的点号路径写进 agents.json（整份读-改-写，保留其它键）。
     和桌宠自己的 Save-AgentsConfig 一个路子；注释用的 _xxx 键也是普通键，会原样留着。 #>
  param([string]$Path, [string]$DottedKey, $Value)
  if (-not $Path -or -not $DottedKey) { return $false }
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $parts = @($DottedKey -split '\.')
    $cur = $obj
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
      $next = $cur.($parts[$i])
      if ($null -eq $next) { return $false }
      $cur = $next
    }
    $leaf = $parts[-1]
    if (-not ($cur.PSObject.Properties.Name -contains $leaf)) { return $false }
    $cur.$leaf = $Value
    (($obj | ConvertTo-Json -Depth 12) + "`n") | Set-Content -LiteralPath $Path -Encoding UTF8
    return $true
  } catch { return $false }
}

# ---------------------------------------------------------------------------
# 问一下本机 Ollama：在不在、有哪些模型、哪些能看图
#
# 探测是**只读、有超时、失败不抛**：没装 Ollama 的人打开设置窗口不该卡住，也不该报错。
# 结果缓存一次（同一进程里 schema 会被建好几次：自检 + 渲染 + 真开窗）。
# ---------------------------------------------------------------------------
$script:DgOllamaProbe = $null

function Get-DgOllamaProbe {
  param([string]$Url = 'http://127.0.0.1:11434', [switch]$NoCache)
  if (-not $Url) { $Url = 'http://127.0.0.1:11434' }
  $Url = $Url.TrimEnd('/')
  if (-not $NoCache -and $script:DgOllamaProbe -and $script:DgOllamaProbe.Url -eq $Url) { return $script:DgOllamaProbe }

  $res = [pscustomobject]@{
    Url     = $Url
    Ok      = $false
    Version = ''
    Models  = @()          # 模型名数组
    Vision  = @()          # 其中有 vision 能力的
    Thinking = @()         # 其中会思考的（qwen3 系）
    Error   = ''
  }
  try {
    $tags = Invoke-RestMethod -Uri "$Url/api/tags" -Method Get -TimeoutSec 3 -ErrorAction Stop
    $res.Ok = $true
    $names = @($tags.models | ForEach-Object { [string]$_.name })
    $res.Models = $names
    try { $res.Version = [string]((Invoke-RestMethod -Uri "$Url/api/version" -Method Get -TimeoutSec 3).version) } catch { }
    # 能力：/api/show 每个模型问一次（本机调用，很快；模型多就跳过，别拖慢开窗）
    if ($names.Count -le 12) {
      foreach ($n in $names) {
        try {
          $s = Invoke-RestMethod -Uri "$Url/api/show" -Method Post -TimeoutSec 3 `
            -Body (@{ model = $n } | ConvertTo-Json -Compress) -ContentType 'application/json'
          $caps = @($s.capabilities)
          if ($caps -contains 'vision') { $res.Vision += $n }
          if ($caps -contains 'thinking') { $res.Thinking += $n }
        } catch { }
      }
    }
  } catch {
    $res.Error = $_.Exception.Message
  }
  $script:DgOllamaProbe = $res
  return $res
}

# ---------------------------------------------------------------------------
# 网络模型（OpenAI 兼容端点）
#
# key 是唯一**不进 config.json** 的东西：它写 run\openai.key（和右键菜单「填 API key」同一个文件、
# 同一套语义）。所以那一行是"输完点写入"，不走保存。
# 端点 / 模型名 / 发不发图 / 生成上限才进 config.json（advisor-openai.ps1 会读，环境变量仍优先）。
# ---------------------------------------------------------------------------
function Get-DgOpenAiKeyPath {
  param([string]$StateRoot)
  if (-not $StateRoot) { return '' }
  return (Join-Path (Join-Path $StateRoot 'run') 'openai.key')
}

function Get-DgOpenAiProbe {
  <# 拿 key 问一次 /models：既验证 key 能不能用，也顺便得到可用模型列表。
     失败不抛；没 key 就不发请求（离线用户不会因此卡开窗）。 #>
  param([string]$BaseUrl = 'https://api.deepseek.com/v1', [string]$KeyPath = '')
  $res = [pscustomobject]@{ BaseUrl = $BaseUrl; HasKey = $false; KeyChars = 0; Ok = $false; Models = @(); Error = '' }
  $key = ''
  if ($KeyPath -and (Test-Path -LiteralPath $KeyPath)) {
    try { $key = (Get-Content -LiteralPath $KeyPath -Raw -Encoding UTF8).Trim() } catch { }
  }
  $res.HasKey = -not [string]::IsNullOrWhiteSpace($key)
  $res.KeyChars = $key.Length
  if (-not $res.HasKey) {
    $res.Error = '还没填 key'
    return $res
  }
  if (-not $BaseUrl) { $BaseUrl = 'https://api.deepseek.com/v1' }
  try {
    $r = Invoke-RestMethod -Uri ("{0}/models" -f $BaseUrl.TrimEnd('/')) -Method Get `
      -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 6 -ErrorAction Stop
    $res.Ok = $true
    $res.Models = @($r.data | ForEach-Object { [string]$_.id })
  } catch {
    $d = ''
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $d = ' ' + ($_.ErrorDetails.Message -replace '\s+', ' ') }
    $res.Error = "$($_.Exception.Message)$d"
  }
  return $res
}

function Update-DgOpenAiProbe {
  <# key 刚写完 → 立刻重问一次 /models，把那行「连通性」刷新掉（省得为了看结果重开窗口）。 #>
  param($Ctx)
  $info = $Ctx.Rows | Where-Object { $_.Key -eq '_openaiProbe' } | Select-Object -First 1
  if (-not $info -or -not $info.Ctl) { return }
  $base = $Ctx.Rows | Where-Object { $_.Key -eq 'openaiBaseUrl' } | Select-Object -First 1
  $url = if ($base -and $base.Ctl) { ([string]$base.Ctl.Text).Trim() } else { '' }
  if (-not $url) { $url = 'https://api.deepseek.com/v1' }
  try {
    $p = Get-DgOpenAiProbe -BaseUrl $url -KeyPath (Get-DgOpenAiKeyPath -StateRoot $Ctx.StateRoot)
    $info.Ctl.Text =
      if ($p.Ok) { "已连上 $url：key 可用（$($p.KeyChars) 字符），可用模型 $(@($p.Models).Count) 个：$(@($p.Models) -join '、')" }
      elseif (-not $p.HasKey) { '还没填 key：在下面那行输入后点「写入」（只写进 run\openai.key，不进 config.json）。' }
      else { "key 已填（$($p.KeyChars) 字符），但调用 $url/models 失败：$($p.Error)" }
  } catch { }
}

function Get-DgSettingsSchema {
  param([string]$Root = '', [string[]]$ModelNames = @(), $Origin = $null, [string]$DshModel = '')

  $modelChoices = @([pscustomobject]@{ Value = ''; Text = '（跟 agents.json 的第一个一致）' })
  foreach ($m in $ModelNames) { $modelChoices += [pscustomobject]@{ Value = $m; Text = $m } }

  $effortChoices = @(
    [pscustomobject]@{ Value = ''; Text = '（跟 agents.json 一致）' }
    [pscustomobject]@{ Value = 'low'; Text = 'low —— 最快，够用' }
    [pscustomobject]@{ Value = 'high'; Text = 'high —— 默认' }
    [pscustomobject]@{ Value = 'max'; Text = 'max —— 最慢最贵' }
  )

  # ---- 大脑来源 / 本地 Ollama ----
  # 当前用的是哪条路：从 config 里那两条命令反推（老配置没这个键也不会显示错）
  $curAdvisor = if ($Origin -and $Origin.Contains('advisor')) { [string]$Origin['advisor'] } else { '' }
  $curFast = if ($Origin -and $Origin.Contains('advisorFast')) { [string]$Origin['advisorFast'] } else { '' }
  $brainKindDefault =
    if ($Origin -and $Origin.Contains('brainKind') -and [string]$Origin['brainKind']) { [string]$Origin['brainKind'] }
    else { Get-DgBrainKindFromCommands -Advisor $curAdvisor -Fast $curFast }

  $ollamaUrlCfg = if ($Origin -and $Origin.Contains('ollamaUrl')) { [string]$Origin['ollamaUrl'] } else { '' }
  if (-not $ollamaUrlCfg) { $ollamaUrlCfg = 'http://127.0.0.1:11434' }
  $probe = Get-DgOllamaProbe -Url $ollamaUrlCfg

  $ollamaChoices = @([pscustomobject]@{ Value = ''; Text = '（自动：用本机第一个可用模型）' })
  foreach ($m in @($probe.Models)) {
    $tag = @()
    if ($probe.Vision -contains $m) { $tag += '能看图' }
    if ($probe.Thinking -contains $m) { $tag += '会思考' }
    $suffix = if ($tag.Count -gt 0) { ' —— ' + ($tag -join ' · ') } else { '' }
    $ollamaChoices += [pscustomobject]@{ Value = $m; Text = ("{0}{1}" -f $m, $suffix) }
  }
  # 配置里指定的模型如果本机没有（比如刚换机器），也要出现在下拉里，否则保存一次就把它丢了
  $curModel = if ($Origin -and $Origin.Contains('ollamaModel')) { [string]$Origin['ollamaModel'] } else { '' }
  if ($curModel -and (@($probe.Models) -notcontains $curModel)) {
    $ollamaChoices += [pscustomobject]@{ Value = $curModel; Text = "$curModel —— 本机没找到（先 ollama pull）" }
  }

  if ($probe.Ok) {
    $visionText = if (@($probe.Vision).Count -gt 0) { ' 能看图的有：' + (@($probe.Vision) -join '、') } else { ' 没有能看图的模型（不会发截图）' }
    $vText = if ($probe.Version) { " v$($probe.Version)" } else { '' }
    $ollamaInfo = "已连上 $($probe.Url)$vText，$(@($probe.Models).Count) 个模型：$(@($probe.Models) -join '、')。$visionText"
    $ollamaLine = "（本机 Ollama 已连上，$(@($probe.Models).Count) 个模型）"
  } else {
    $ollamaInfo = "没连上 $($probe.Url)：$($probe.Error)。要用本地模型先在命令行敲 ollama serve，或先把 ollamaUrl 改对。"
    $ollamaLine = '（本机现在没连上 Ollama —— 选它之前先 ollama serve）'
  }
  $ollamaModelHelp = '留空 = 用本机第一个模型。想加模型：ollama pull <名字>，回这个窗口重新打开一次就会出现在下拉里。' +
    $(if ($probe.Ok -and @($probe.Thinking).Count -gt 0) { ' 注意：带「会思考」的模型（qwen3 系）在 Ollama 上偶尔会一路思考不给结论，遇到就把下面「生成上限」调大。' } else { '' })

  # ---- 网络模型（OpenAI 兼容端点）----
  $homeForKeys = ''
  try { $homeForKeys = Get-DgHome } catch { $homeForKeys = $Root }
  $openaiBaseCfg = if ($Origin -and $Origin.Contains('openaiBaseUrl')) { [string]$Origin['openaiBaseUrl'] } else { '' }
  if (-not $openaiBaseCfg) { $openaiBaseCfg = 'https://api.deepseek.com/v1' }
  $oaProbe = Get-DgOpenAiProbe -BaseUrl $openaiBaseCfg -KeyPath (Get-DgOpenAiKeyPath -StateRoot $homeForKeys)

  $openaiModelChoices = @()
  foreach ($m in @($oaProbe.Models)) { $openaiModelChoices += [pscustomobject]@{ Value = $m; Text = $m } }
  $curOaModel = if ($Origin -and $Origin.Contains('openaiModel')) { [string]$Origin['openaiModel'] } else { 'deepseek-flash' }
  if (-not $curOaModel) { $curOaModel = 'deepseek-flash' }
  if (@($openaiModelChoices | ForEach-Object { $_.Value }) -notcontains $curOaModel) {
    $openaiModelChoices += [pscustomobject]@{ Value = $curOaModel; Text = "$curOaModel —— 现在用的" }
  }

  if (-not $oaProbe.HasKey) {
    $openaiInfo = "还没填 key：右边那行输入后点「写入」（只写进 run\openai.key，不进 config.json）。填完连通性会自动刷新。"
    $openaiLine = '（网络模型这条路还没填 key）'
  } elseif ($oaProbe.Ok) {
    $openaiInfo = "已连上 $($oaProbe.BaseUrl)：key 可用（$($oaProbe.KeyChars) 字符），可用模型 $(@($oaProbe.Models).Count) 个：$(@($oaProbe.Models) -join '、')"
    $openaiLine = "（网络模型 key 可用，$( @($oaProbe.Models).Count ) 个模型）"
  } else {
    $openaiInfo = "key 已填（$($oaProbe.KeyChars) 字符），但调用 $($oaProbe.BaseUrl)/models 失败：$($oaProbe.Error)"
    $openaiLine = '（网络模型的 key 填了，但连不通）'
  }

  # ---- 和 DSH 同一个模型 ----
  $dshModelNow = if ($DshModel) { $DshModel } else { '' }
  $dshModelChoices = @()
  foreach ($m in @($ModelNames)) { $dshModelChoices += [pscustomobject]@{ Value = $m; Text = $m } }
  if ($dshModelNow -and (@($dshModelChoices | ForEach-Object { $_.Value }) -notcontains $dshModelNow)) {
    $dshModelChoices += [pscustomobject]@{ Value = $dshModelNow; Text = "$dshModelNow —— 现在用的" }
  }
  if ($dshModelChoices.Count -eq 0) {
    $dshModelChoices = @([pscustomobject]@{ Value = ''; Text = '（读不到 agents.json 的模型表）' })
  }
  $dshInfo = if ($dshModelNow) {
    "现在 DSH 用的是「$dshModelNow」（agents.json → mainAgent.model）。改上面那一行 = 换掉这个「同一个模型」。"
  } else {
    '读不到 agents.json 的 mainAgent.model —— 确认 agents.json 在当前状态根下。'
  }

  $sections = New-Object System.Collections.ArrayList

  [void]$sections.Add([pscustomobject]@{
    Name = '外观与气泡'
    Note = '桌宠长什么样、气泡说多久。这一页改完基本立刻能看到效果。'
    Items = @(
      @{ Key='petImage'; Label='角色图（透明 PNG）'; Kind='path'; Def='{root}\assets\pet.png'; Late='重启桌宠后换图'
         Help='换成自己的图就把这里指到一个带透明通道的 PNG。支持占位符：{root} 本目录、{dshHome} DSH 家目录、{userProfile}。留空 = 用自带的 assets\pet.png。' }
      @{ Key='fontFamily'; Label='气泡字体'; Kind='text'; Def='黑体'
         Help='系统里装了的字体名（例如「微软雅黑」「黑体」「Microsoft YaHei UI」）。' }
      @{ Key='fontSize'; Label='气泡字号'; Kind='number'; Min=6; Max=36; Step=0.5; Decimals=1; Def=6.0; Unit='pt'
         Help='96dpi 下的逻辑字号；实际显示会按你的屏幕缩放再乘一次，所以换显示器不用重调。基准字号是 6pt（这台机器 200% 缩放下约等于 12pt）。' }
      @{ Key='showSeconds'; Label='气泡停留'; Kind='number'; Min=0; Max=120; Step=1; Decimals=0; Def=12; Unit='秒'
         Help='一句话说完后气泡留多久。0 = 不自动消失（要自己点掉）。' }
      @{ Key='optionSeconds'; Label='选项倒计时'; Kind='number'; Min=1; Max=60; Step=1; Decimals=0; Def=5; Unit='秒'
         Help='agent 提出选项时，气泡上的按钮多久后自动取消（当作没选）。' }
      @{ Key='speakStyle'; Label='说话风格'; Kind='choice'; Def='coach'; Late='立刻换 system prompt'
         Choices=@(
           [pscustomobject]@{ Value='coach'; Text='陪练 —— 每次判断都给建议' }
           [pscustomobject]@{ Value='guard'; Text='保守 —— 只在明显问题时说' }
           [pscustomobject]@{ Value='roast'; Text='损友 —— 先吐槽一句再给建议' }
         )
         Help='决定 presets\ 下哪份 system prompt 生效。保守 = 只在明显的问题、反复失败、或与目标冲突时开口；陪练 = 每轮都给建议；损友 = 先吐槽屏幕上的事再给建议（不骂人、不带脏字）。' }
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '采集与节奏'
    Note = '多久看一眼屏幕、一次带几张图。这几项直接决定 token 花得多快 —— 调快更及时，也更贵。'
    Items = @(
      @{ Key='sampleSeconds'; Label='采样间隔'; Kind='number'; Min=0.3; Max=60; Step=0.1; Decimals=1; Def=2; Unit='秒'
         Help='**采样即截图**：每次采样都带一张图。0.6 秒是游戏档的节奏，10 秒是桌面空闲档。想省资源就调大。' }
      @{ Key='maxScreenshots'; Label='一次最多带几张图'; Kind='int'; Min=1; Max=24; Step=1; Def=6; Unit='张'
         Help='交给模型的截图张数上限。越少越快越便宜，但看不到时间上的变化。' }
      @{ Key='fastImageCount'; Label='「现在说一句」带几张'; Kind='int'; Min=1; Max=8; Step=1; Def=2; Unit='张'
         Help='手动问一句走的是快通路，只发最近这几张。默认 2 张（3-4 秒能回）。' }
      @{ Key='screenshotMaxWidth'; Label='截图最大宽度'; Kind='int'; Min=320; Max=4096; Step=64; Def=1024; Unit='px'
         Help='超过就等比缩小。这一项对 token 的影响比什么都大 —— 1024 宽约等于 1.1k token/张。' }
      @{ Key='jpegQuality'; Label='JPEG 质量'; Kind='int'; Min=10; Max=100; Step=5; Def=60
         Help='60 左右够看 UI 文字；界面字很小、或截图里要读数字时才需要调高。' }
      @{ Key='focusWatchMs'; Label='换窗口检测间隔'; Kind='int'; Min=50; Max=5000; Step=50; Def=400; Unit='毫秒'
         Help='前台窗口变没变，多久查一次。**这不是采样率本身** —— 它只决定「切过去的一瞬间多早被发现」，开销是一次 GetForegroundWindow。' }
      @{ Key='minSampleSeconds'; Label='采样下限'; Kind='number'; Min=0.1; Max=10; Step=0.05; Decimals=2; Def=0.3; Unit='秒'
         Help='学习出来的采样率被夹在这个下限之上，防的是「学出 0.05 秒把机器烧了」。' }
      @{ Key='maxSampleSeconds'; Label='采样上限'; Kind='number'; Min=1; Max=600; Step=1; Decimals=1; Def=60; Unit='秒'
         Help='上限。防止某个档学出几十分钟，等于把桌宠饿死。' }
      @{ Key='jumpDeltaThreshold'; Label='画面跳变阈值'; Kind='int'; Min=20; Max=960; Step=10; Def=200
         Help='两次采样之间画面指纹差超过它，就算「漏掉了东西」（会把间隔收窄）。指纹总差上限是 960。' }
      @{ Key='timelineSize'; Label='内存里留多少条观察'; Kind='int'; Min=10; Max=500; Step=10; Def=40; Unit='条'
         Help='拼提示词时最多回看多少条观察记录。调大更连贯，也更费 token。' }
      @{ Key='screenshotSeconds'; Label='截图间隔（遗留键）'; Kind='number'; Min=0.5; Max=300; Step=0.5; Decimals=1; Def=5; Unit='秒'
         Help='旧版本用的键。现在「采样即截图」，节奏只看上面的采样间隔 —— 这一项留着只是为了兼容老配置。' }
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '判断与闸门'
    Note = '本地闸门决定「值不值得为这一轮起一次模型调用」。它省下的是「起进程 + 带截图的一次模型调用」，所以这里是最划算的一页。'
    Items = @(
      @{ Key='judgeMinSeconds'; Label='两次判断最小间隔'; Kind='number'; Min=5; Max=3600; Step=5; Decimals=0; Def=60; Unit='秒'
         Help='不管画面怎么变，两次真的起模型调用之间至少隔这么久。' }
      @{ Key='judgeMinFpDelta'; Label='画面没变阈值'; Kind='int'; Min=0; Max=960; Step=1; Def=12
         Help='画面指纹差异小于它就当作「没变」，不进模型。调大 = 更沉默。' }
      @{ Key='silentBackoffMax'; Label='沉默退避上限'; Kind='number'; Min=1; Max=20; Step=1; Decimals=1; Def=4; Unit='倍'
         Help='连续「它决定不说」时，间隔最多放宽到几倍（说了一次就归 1）。' }
      @{ Key='judgeIdleSkipSeconds'; Label='人不在就跳过'; Kind='number'; Min=0; Max=7200; Step=30; Decimals=0; Def=600; Unit='秒'
         Help='这么久没有键鼠输入、窗口也没换 → 直接不进模型。0 = 关掉这条判据。' }
      @{ Key='judgeMaxGapSeconds'; Label='最长沉默'; Kind='number'; Min=30; Max=7200; Step=30; Decimals=0; Def=300; Unit='秒'
         Help='保险丝：不管画面多静，隔这么久也要看一眼 —— 防的是闸门把桌宠饿死。' }
      @{ Key='roastMinSeconds'; Label='损友模式最短间隔'; Kind='number'; Min=5; Max=600; Step=5; Decimals=0; Def=15; Unit='秒'
         Late='只在说话风格 = 损友时生效'
         Help='损友模式是「陪着说话」：画面没变也允许吐槽，所以间隔不走上面那条，而用这个 —— 它同时也是损友模式的检查节拍（默认 15 秒，比其它风格密得多）。每轮都是一次真的模型调用（约 0.02–0.03 元/轮），调小 = 更话痨，也更花钱。' }
      @{ Key='roastBackoffMax'; Label='损友模式沉默退避'; Kind='number'; Min=0; Max=8; Step=1; Decimals=0; Def=2; Unit='倍'
         Late='只在说话风格 = 损友时生效'
         Help='连续被它判成「没什么可说」时，间隔最多放宽到 (1+这个值) 倍。0 = 不退避，永远按最短间隔来 —— 最话痨，也最贵。' }
      @{ Key='dailySpendCapYuan'; Label='每日消费上限'; Kind='number'; Min=0; Max=10000; Step=5; Decimals=0; Def=50; Unit='元'
         Help='今天的花费到线就自动暂停（停掉采样和自动判断，不再花新钱），气泡上会说明。0 = 不设上限。跨天或把上限调大会重新武装；暂停只挡自动观察，手动点它问一句仍会花钱。' }
      @{ Key='userQuietSeconds'; Label='用户优先，停手后补一次'; Kind='number'; Min=0; Max=600; Step=1; Decimals=0; Def=6; Unit='秒'
         Help='你一动桌宠，正在跑的**自动**判断立刻让位；停手这么久之后再把欠下的那次补上。' }
      @{ Key='logMinSeconds'; Label='观察日志最短间隔'; Kind='number'; Min=0; Max=600; Step=1; Decimals=0; Def=2; Unit='秒'
         Help='多快往 logs\observe-*.jsonl 写一条观察记录（只是日志，不影响模型）。' }
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '对话窗口'
    Note = '点右键「对话」开出来的那个窗口 —— 直接把 DSH 自己的 Web 界面拿来用（无地址栏的 Edge 窗口）。'
    Items = @(
      @{ Key='chatUi'; Label='对话界面'; Kind='choice'; Def='dsh'; Late='下次开对话生效'
         Choices=@(
           [pscustomobject]@{ Value='dsh'; Text='DSH 自己的界面（推荐）' }
           [pscustomobject]@{ Value='bubbles'; Text='桌宠自绘的气泡栏（兜底）' }
         )
         Help='dsh = 完整的 DSH 界面，有 Markdown、工具卡片、会话侧栏；bubbles = 老的自绘气泡栏，只能画纯文本。' }
      @{ Key='webPort'; Label='本地端口'; Kind='int'; Min=1024; Max=65535; Step=1; Def=4319; Late='下次开对话生效'
         Help='DSH 界面只监听 127.0.0.1 的这个端口，带一次性 token。被别的程序占了就换一个。' }
      @{ Key='webWindowWidth'; Label='窗口宽'; Kind='int'; Min=320; Max=2400; Step=20; Def=560; Unit='px'; Late='下次开对话生效'
         Help='对话窗口的初始大小。' }
      @{ Key='webWindowHeight'; Label='窗口高'; Kind='int'; Min=320; Max=2400; Step=20; Def=780; Unit='px'; Late='下次开对话生效'
         Help='对话窗口的初始大小。' }
      @{ Key='webEdge'; Label='Edge 路径'; Kind='path'; Def=''; Late='下次开对话生效'
         Help='留空 = 自动探测 msedge.exe。找不到 Edge 时才会用到（换成 Chrome/Edge 的绝对路径也行）。' }
      @{ Key='webModel'; Label='对话用哪个模型'; Kind='choice'; Def=''; Choices=$modelChoices; Late='下次开对话生效'
         Help='必须指向用 DSH 已登录账号的 provider（deepseek-account）。DSH 自带的 web profile 默认是 deepseek-official，那要 DEEPSEEK_API_KEY —— 没设就是一问就报 MISSING_CREDENTIAL，所以这里启动时会用 --patch 覆盖掉它。' }
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '语音输入'
    Note = '长按桌宠说话，松开就把识别到的句子派给后台 agent（不是拿去聊天）。引擎是 DSH 自带的 sherpa-onnx + SenseVoice，本机离线。'
    Items = @(
      @{ Key='sttEnabled'; Label='启用语音输入'; Kind='bool'; Def=$true
         Help='关掉之后长按桌宠就只是长按，不会开麦。' }
      @{ Key='sttLongPressMs'; Label='长按判定'; Kind='int'; Min=100; Max=3000; Step=50; Def=400; Unit='毫秒'
         Help='按住超过这么久算「长按」；低于它仍然是普通点击。移动超过 3px 会退化成拖动。' }
      @{ Key='sttMaxSeconds'; Label='单次最长'; Kind='number'; Min=3; Max=120; Step=1; Decimals=0; Def=20; Unit='秒'
         Help='一次最多录多久，到点自动停止去识别。' }
      @{ Key='sttMinSeconds'; Label='最短有效'; Kind='number'; Min=0.1; Max=10; Step=0.1; Decimals=1; Def=0.4; Unit='秒'
         Help='比这还短就当作没说话（防误触）。' }
      @{ Key='sttLanguage'; Label='语言提示'; Kind='choice'; Def='auto'
         Choices=@(
           [pscustomobject]@{ Value='auto'; Text='auto —— 自动判断' }
           [pscustomobject]@{ Value='zh'; Text='zh —— 中文' }
           [pscustomobject]@{ Value='en'; Text='en —— 英文' }
           [pscustomobject]@{ Value='yue'; Text='yue —— 粤语' }
           [pscustomobject]@{ Value='ja'; Text='ja —— 日语' }
           [pscustomobject]@{ Value='ko'; Text='ko —— 韩语' }
         )
         Help='给 SenseVoice 的语言提示。固定说一种语言时指定它，准确率会高一点。' }
      @{ Key='sttSampleRate'; Label='录音采样率'; Kind='int'; Min=8000; Max=48000; Step=1000; Def=44100; Unit='Hz'
         Help='录音时的采样率（识别前会统一重采样到 16k）。声卡不支持 44100 时改成 48000。' }
      @{ Key='sttDevice'; Label='输入设备序号'; Kind='int'; Min=-1; Max=32; Step=1; Def=-1
         Help='-1 = 系统默认设备。想换设备：右键「语音输入」会把可用设备列出来，把它前面的序号填到这里。' }
      @{ Key='sttModelDir'; Label='识别模型目录'; Kind='path'; Def=''
         Help='留空 = 用 .stt\model（首次使用会自动下载约 229MB）。' }
      @{ Key='sttNode'; Label='Node 运行时'; Kind='path'; Def=''
         Help='留空 = 自动找（DSH 自带运行时 → PATH）。' }
      @{ Key='sttSherpaDir'; Label='sherpa-onnx 目录'; Kind='path'; Def=''
         Help='留空 = 用 .stt\sherpa\sherpa-onnx-node。' }
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '朗读'
    Note = '把结论句读出来。运行时「静音/出声」在右键菜单里，这一页是默认值和音色。'
    Items = @(
      @{ Key='ttsEnabled'; Label='默认出声'; Kind='bool'; Def=$true; Late='运行中的开关只看菜单'
         Help='启动时的默认值。运行中想立刻静音，用右键「设置 ▸ 朗读 ▸ 出声朗读」（状态记在 run\pet.json，不会改这里）。' }
      @{ Key='ttsEngine'; Label='引擎'; Kind='choice'; Def='auto'
         Choices=@(
           [pscustomobject]@{ Value='auto'; Text='auto —— 有 Edge 就用 Edge，否则退回本机' }
           [pscustomobject]@{ Value='edge'; Text='edge —— 微软神经音色（音质好，要联网）' }
           [pscustomobject]@{ Value='speech'; Text='speech —— 本机老音色（瞬时、离线）' }
         )
         Help='edge 好听但要联网、约 3 秒才出声；speech 是本机 SAPI，瞬时但没有感情。' }
      @{ Key='ttsVoice'; Label='音色'; Kind='text'; Def=''
         Help='留空 = Edge 用默认可爱女声（Xiaoyi）、本机自动挑中文音色。想挑音色跑：pwsh -File tts.ps1 -Audition' }
      @{ Key='ttsEdgeRate'; Label='Edge 语速'; Kind='text'; Def='+6%'; Pattern='^[+-]?\d+(\.\d+)?%$'; PatternTip='形如 +6% 或 -10%'
         Help='Edge 专用。默认 +6%（稍快显活泼）。' }
      @{ Key='ttsEdgePitch'; Label='Edge 音高'; Kind='text'; Def='+12Hz'; Pattern='^[+-]?\d+(\.\d+)?Hz$'; PatternTip='形如 +12Hz 或 -20Hz'
         Help='Edge 专用。默认 +12Hz（略抬高显可爱）。' }
      @{ Key='ttsEdgeVolume'; Label='Edge 音量'; Kind='text'; Def='+0%'; Pattern='^[+-]?\d+(\.\d+)?%$'; PatternTip='形如 +0% 或 -50%'
         Help='Edge 专用，相对音量。要绝对音量就调下面的「本机音量」。' }
      @{ Key='ttsPython'; Label='Python（edge-tts 用）'; Kind='path'; Def=''
         Help='留空 = 自动用 .tts\venv\Scripts\python.exe（首次用 Edge 引擎时自动装）。' }
      @{ Key='ttsRate'; Label='本机语速'; Kind='int'; Min=-10; Max=10; Step=1; Def=0
         Help='只对 speech 引擎有效：-10 最慢、0 正常、10 最快。' }
      @{ Key='ttsVolume'; Label='本机音量'; Kind='int'; Min=0; Max=100; Step=5; Def=100
         Help='只对 speech 引擎有效。' }
      @{ Key='ttsMaxChars'; Label='一句话最多读几个字'; Kind='int'; Min=20; Max=1000; Step=10; Def=180; Unit='字'
         Help='超了就在标点处截断 —— 朗读只读「结论句」，不该把整篇念出来。' }
      @{ Key='ttsSkipStatus'; Label='不读状态句'; Kind='bool'; Def=$true
         Help='「你在做：…」这类「我看见你了」的话不朗读，只显示。' }
      @{ Key='ttsQueueMax'; Label='待播队列上限'; Kind='int'; Min=1; Max=20; Step=1; Def=3; Unit='句'
         Help='来不及念的先排队（播音员按顺序念）。排满后再来的丢掉最旧的那句 —— 越新的消息越值钱。调大 = 一句不漏但可能落后你半分钟。' }
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '大脑与任务'
    Note = '自动判断、手动问一句、语音派活分别用哪条命令 / 哪个模型。'
    Items = @(
      @{ Key='brainKind'; Label='大脑来源'; Kind='choice'; Def=$brainKindDefault; Late='立刻生效（会改写下面两条命令）'
         Choices=@(
           [pscustomobject]@{ Value='dsh'; Text='和 DSH 同一个模型 —— 有常驻记忆，慢（8-25 秒）' }
           [pscustomobject]@{ Value='openai'; Text='网络模型（用 API key）—— 快（3-5 秒），按量付费' }
           [pscustomobject]@{ Value='ollama'; Text='本地 Ollama 模型 —— 零 key、不出机器，速度看显卡' }
           [pscustomobject]@{ Value='custom'; Text='自定义 —— 下面两条命令自己写' }
         )
         Help=('三条路都是现成的，换大脑只要改这一项：保存时自动把下面两条命令改写成对应的脚本。三种来源各自的参数在下面分三块。' + $ollamaLine + $openaiLine) }

      # ---- ① 和 DSH 同一个模型（走 DSH 自己的 agent 与登录账号，模型表在 agents.json）----
      @{ Key='_dshModel'; Label='DSH 模型（这行就是"同一个模型"）'; Kind='choice'; AgentPath='mainAgent.model'; AgentDef=$dshModelNow; Choices=$dshModelChoices
         Help='选这一项时，判断用的大脑 = 和 DSH 自己的 agent 同一个模型（存在 agents.json 的 mainAgent.model）。有常驻会话记忆，但一轮 8-25 秒。' }
      @{ Key='_dshInfo'; Label='DSH 现状'; Kind='info'; Def=$dshInfo
         Help='DSH 的模型表和权限档在 agents.json；这里的模型就是"和 DSH 同一个"里的那个"同一个"。' }

      # ---- ② 网络模型（用 API key 调 OpenAI 兼容端点）----
      @{ Key='openaiBaseUrl'; Label='网络模型地址'; Kind='text'; Def='https://api.deepseek.com/v1'
         Help='OpenAI 兼容端点的 base url（带 /v1）。默认 DeepSeek；换成 OpenAI、硅基流动、本地 LM Studio 都填这里。' }
      @{ Key='openaiModel'; Label='网络模型名'; Kind='choice'; Def='deepseek-flash'; Choices=$openaiModelChoices
         Help='要调的模型名。列表是拿 key 问一次 /models 得到的；连不上就只列已知的那几个 + 你现在填的值。' }
      @{ Key='openaiKey'; Label='API key'; Kind='secret'; KeyFile='openai.key'
         Help='key 只写进 run\openai.key（不进 config.json、不会写进日志）—— 和右键菜单「填 API key」用的是同一个文件。输完点右边「写入」。' }
      @{ Key='_openaiProbe'; Label='连通性'; Kind='info'; Def=$openaiInfo
         Help='拿 key 问一次 /models 的结果：连上就列出可用模型，连不上会写清是哪一步失败（没 key / 401 / 连不通）。' }
      @{ Key='openaiVision'; Label='网络模型发截图'; Kind='choice'; Def=''
         Choices=@(
           [pscustomobject]@{ Value=''; Text='按模型名自动判断（推荐）' }
           [pscustomobject]@{ Value='1'; Text='发（模型必须能看图）' }
           [pscustomobject]@{ Value='0'; Text='不发（只用窗口标题 + 记忆）' }
         )
         Help='deepseek-flash 这类是收图的；纯文本模型会被拒或忽略。' }
      @{ Key='openaiMaxTokens'; Label='网络模型生成上限'; Kind='number'; Min=64; Max=8192; Step=64; Decimals=0; Def=1500; Unit='token'
         Help='推理型模型（deepseek-flash）思考也吃 token：给太少会"只有思考、没有结论"（实测 300 时就是空输出）。' }

      # ---- ③ 本地 Ollama 模型 ----
      @{ Key='ollamaUrl'; Label='Ollama 地址'; Kind='text'; Def='http://127.0.0.1:11434'
         Help='Ollama 服务地址（默认本机 11434 端口）。改完点「保存」，再回到这一项看下面那行探测结果。' }
      @{ Key='ollamaModel'; Label='Ollama 模型'; Kind='choice'; Def=''; Choices=$ollamaChoices
         Help=$ollamaModelHelp }
      @{ Key='_ollamaProbe'; Label='本机探测'; Kind='info'; Def=$ollamaInfo
         Help='这一行只是把探测结果摊开给你看：连没连上、有哪些模型、哪些能看图（能看图的才会把截图发给它）。' }
      @{ Key='ollamaVision'; Label='Ollama 发截图'; Kind='choice'; Def=''
         Choices=@(
           [pscustomobject]@{ Value=''; Text='按模型名自动判断（推荐）' }
           [pscustomobject]@{ Value='1'; Text='发（模型必须能看图）' }
           [pscustomobject]@{ Value='0'; Text='不发（只用窗口标题 + 记忆）' }
         )
         Help='只有多模态模型（qwen3-vl / llava / gemma3 / minicpm-v …）收得下图片；发给纯文本模型会被拒或直接忽略。' }
      @{ Key='ollamaTemperature'; Label='Ollama 温度'; Kind='number'; Min=0; Max=2; Step=0.1; Decimals=1; Def=0.3
         Help='0 = 每次都说同一句；0.3 左右比较稳。' }
      @{ Key='ollamaNumCtx'; Label='Ollama 上下文'; Kind='number'; Min=0; Max=131072; Step=1024; Decimals=0; Def=8192; Unit='token'
         Help='能"记住"多少内容（含截图，图很占）。0 = 让 Ollama 自己定。调大更占显存。' }
      @{ Key='ollamaNumPredict'; Label='Ollama 生成上限'; Kind='number'; Min=32; Max=8192; Step=64; Decimals=0; Def=400; Unit='token'
         Help='一句话回复 400 足够，也顺便防止模型卡住时无限生成。思考型模型（qwen3 系）如果只输出思考、没有结论，把这个调到 1600 以上 —— 程序里也有一次自动放大重问的兜底。' }
      @{ Key='ollamaKeepAlive'; Label='Ollama 驻留时间'; Kind='text'; Def='10m'
         Help='模型留在显存里多久（10m / 30s / -1 = 常驻）。设短了每次调用都要重新加载模型，会明显变慢。' }

      # ---- 通用：两条命令（高级逃生口）+ 节奏 ----
      @{ Key='advisor'; Label='常驻大脑命令'; Kind='text'; Def='pwsh -NoProfile -ExecutionPolicy Bypass -File "{root}\advisor-dsh.ps1"'
         Help='自动判断用的大脑（有记忆、但慢）。命令末尾会自动追加 payload.json 的路径，它把要说的话打到 stdout。可用占位符：{root} {dshRoot} {userProfile} {dshHome}。' }
      @{ Key='advisorFast'; Label='「问一句」命令'; Kind='text'; Def='pwsh -NoProfile -ExecutionPolicy Bypass -File "{root}\advisor-openai.ps1"'
         Help='手动「现在说一句」走的快通路（一次性调用，3-4 秒）。换大脑只改这两行。' }
      @{ Key='advisorTimeoutSeconds'; Label='大脑超时'; Kind='number'; Min=5; Max=600; Step=5; Decimals=0; Def=30; Unit='秒'
         Help='一次调用最多等多久，超了就当作这轮没结果。选 Ollama（尤其 CPU 上跑）时建议 60-180 秒。' }
      @{ Key='warmupOnStart'; Label='开机预热'; Kind='bool'; Def=$true
         Help='启动时先跑一次空转，把模型和截图通路热起来（否则第一次会明显慢）。' }
      @{ Key='autoMinutes'; Label='自动发言间隔'; Kind='number'; Min=1; Max=180; Step=1; Decimals=0; Def=1; Unit='分钟'
         Help='菜单里「自动发言」打开时，多久问一次。' }
      @{ Key='brainTransport'; Label='常驻大脑进程'; Kind='bool'; Def=$true; Late='重启桌宠后生效'
         Help='一个进程一直持有 DSH 运行时，派任务时不再每轮起新进程（见 brain-sdk.ps1）。关掉就回到「每任务一个进程」。' }
      @{ Key='brainEffort'; Label='大脑推理强度'; Kind='choice'; Def='low'; Choices=$effortChoices; Late='重启桌宠后生效'
         Help='常驻大脑的推理档位。它负责派活和汇总，low 通常够。' }
      @{ Key='brainSessionId'; Label='大脑会话名'; Kind='text'; Def='pet-brain'; Late='重启桌宠后生效'
         Help='常驻大脑续跑用的会话 id（会话文件在 %USERPROFILE%\.dsh\sessions\ 下）。换个名字 = 换一份记忆。' }
      @{ Key='petTaskModel'; Label='派活用哪个模型'; Kind='choice'; Def=''; Choices=$modelChoices
         Help='语音 / 打字派出去的后台任务用哪个模型。留空 = 用 agents.json 的第一个。' }
      @{ Key='petTaskEffort'; Label='派活推理强度'; Kind='choice'; Def='low'; Choices=$effortChoices
         Help='语音派的多半是短活，压到 low 能明显快一截。留空 = 跟 agents.json 一致。' }
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '记忆与日志'
    Note = '记忆 = 把当天的观察日志压成一段活动汇总，写进提示词。下面这页决定它看多远、留多久。'
    Items = @(
      @{ Key='memoryEnabled'; Label='启用记忆'; Kind='bool'; Def=$true
         Help='关掉之后每次判断都是「只看眼前」，不回顾前面几小时。' }
      @{ Key='memoryHours'; Label='回看窗口'; Kind='number'; Min=0; Max=72; Step=1; Decimals=1; Def=4; Unit='小时'
         Help='把最近这么久内的观察压成一段汇总（0 = 关闭记忆）。' }
      @{ Key='memoryTop'; Label='汇总里留几种活动'; Kind='int'; Min=1; Max=20; Step=1; Def=5; Unit='种'
         Help='按停留时长排序，最多保留前几种。' }
      @{ Key='memoryMaxChars'; Label='汇总最多多少字'; Kind='int'; Min=100; Max=4000; Step=50; Def=700; Unit='字'
         Help='这段汇总每轮都会进提示词，所以是一个长期成本。' }
      @{ Key='memorySince'; Label='清空记忆的时间点'; Kind='text'; Def=''; Pattern='^$|^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$'; PatternTip='留空 = 不清空；或者 2026-10-06 或 2026-10-06 15:30'
         Help='设成某个时间点 = 从那时起重新算记忆（旧的观察不再进汇总）。清空记忆用这个，别去删日志。' }
      @{ Key='logKeepDays'; Label='原始日志保留'; Kind='int'; Min=1; Max=90; Step=1; Def=7; Unit='天'
         Help='logs\observe-*.jsonl 按天轮换，只留最近这么多天。一天能到几 MB，所以别设太大。' }
      @{ Key='micKeepFiles'; Label='录音留几个'; Kind='int'; Min=0; Max=500; Step=5; Def=20; Unit='个'
         Help='run\mic\mic-*.wav 只保留最近几个（每句 200–300KB，不删会一直涨）。' }
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '待机与应答'
    Note = '它什么时候该闭嘴、什么时候该问人、待机时怎么收着力。'
    Items = @(
      @{ Key='askSeconds'; Label='问人时等多久'; Kind='number'; Min=5; Max=600; Step=5; Decimals=0; Def=45; Unit='秒'
         Help='DSH 要问你事时（权限审批 / ask_user_question / 计划评审），气泡上的按钮等多久算放弃。放弃 = 交回给它自己决定，审批则等价于拒绝。' }
      @{ Key='observeAgents'; Label='显示子 agent 在干什么'; Kind='bool'; Def=$true
         Help='后台 agent 跑的时候，在气泡里显示它此刻在干什么，并把 agents 状态塞进主 agent 的 payload（否则它会把「屏幕没动」误判成「用户卡住了」）。' }
      @{ Key='balanceBroadcastMinutes'; Label='余额播报间隔'; Kind='number'; Min=0; Max=1440; Step=5; Decimals=0; Def=30; Unit='分钟'
         Help='定时念一次余额 / 今日花费。0 = 不播（那几个数字仍然一直显示在气泡最下方那行小字里）。' }
      @{ Key='captureFailLimit'; Label='抓不到屏几次进待机'; Kind='int'; Min=1; Max=20; Step=1; Def=3; Unit='次'
         Help='信号没来但连续抓不到屏这么多次 → 自动进待机。防的是远程会话断开时一直刷警告。' }
      @{ Key='standbyProbeSeconds'; Label='待机时多久试一次'; Kind='number'; Min=5; Max=600; Step=5; Decimals=0; Def=30; Unit='秒'
         Help='待机中每隔这么久试探一次能不能恢复（黑屏 / 锁屏 / 睡眠本身走系统信号，不用试探）。' }
      @{ Key='standbyProbeIdleSeconds'; Label='自愈探测的「有人在用」'; Kind='number'; Min=0; Max=3600; Step=10; Decimals=0; Def=60; Unit='秒'
         Help='待机自愈：距上次键鼠输入小于这么多秒、且没锁屏、且抓得到屏 —— 三条都成立就当信号漏发了，自己醒过来。防的是系统通知漏发后桌宠一直以为在待机、手里一张截图都没有。0 = 关掉这条。' }
      @{ Key='shotStaleSeconds'; Label='截图多久算过期'; Kind='number'; Min=1; Max=600; Step=5; Decimals=0; Def=30; Unit='秒'
         Help='最近一张截图超过这么久就当作「没有截图」：这时提示词会**禁止**模型照窗口标题脑补操作步骤，只能说"我还没看清"。' }
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '任务规则表'
    Note = '决定「这类任务多久看一眼」和「这类任务该怎么帮」。判据是完全确定的（进程名 / 窗口标题），所以写成表比问模型可靠、便宜，还能离线单测。hint 会提前写进提示词 —— 这就是「对这类任务提前给出工作建议」。'
    Items = @()
    Custom = 'taskRules'
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '监控区域'
    Note = '默认抓整个屏幕。限定成一块区域更省 token，也更私密。'
    Items = @()
    Custom = 'region'
  })

  # 直接返回 ArrayList：PowerShell 会把它拆成「一组分组对象」，调用方拿到的就是分组数组。
  # （早先写成 `return , $sections`，调用方拿到的是"装着 ArrayList 的数组"，.Count 恒等于 1 ——
  #   自检里报"分组 1 个"才发现。)
  return $sections
}

# ---------------------------------------------------------------------------
# 上下文：所有控件、值、以及事件处理器要共享的东西都挂在这一个 hashtable 上。
# 为什么不靠闭包抓局部变量：WinForms 的事件处理器里取外层局部变量不可靠（这个仓库踩过，
# 见 DesktopGuide.ps1 里 TaskInput 的注释），所以统一走 Tag。
# ---------------------------------------------------------------------------
function Get-DgUiScale {
  <#
    DPI 缩放（1.0 = 96dpi）。

    为什么不直接问 Graphics.FromHwnd(0).DpiX：那个值取决于**进程此刻的 DPI 感知状态**，
    而那是 WinForms 初始化时顺带设的 —— 同一台机器、同一份代码实测有时给 96、有时给 192，
    窗口大小直接差一倍。桌宠自己是在最开头显式调 SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)
    再 GetDpiForSystem，这里照做（桌宠进程里已经设过，重复调用无副作用）。
  #>
  if ('DesktopGuide.Dpi' -as [type]) {
    # 被桌宠 Dot-Source 时直接用它的，免得两处实现漂移
    return [Math]::Max(1.0, [double]([DesktopGuide.Dpi]::Scale()) / 96.0)
  }
  if (-not ('DgSettings.Dpi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DgSettings {
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
  return [Math]::Max(1.0, [double]([DgSettings.Dpi]::Scale()) / 96.0)
}

function New-DgSettingsContext {
  param([string]$ConfigPath, [string]$Root = '', [double]$UiScale = 0, [string]$RenderTo = '')

  if (-not $Root) { $Root = $PSScriptRoot }
  if ($UiScale -le 0) { $UiScale = Get-DgUiScale }

  $origin = [ordered]@{}
  if (Test-Path -LiteralPath $ConfigPath) {
    try {
      $loaded = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $loaded.PSObject.Properties) { $origin[$p.Name] = $p.Value }
    } catch { }
  }

  $modelNames = @()
  $dshModel = ''
  $dshAccess = ''
  $agentsFile = Join-Path $Root 'agents.json'
  if (Test-Path -LiteralPath $agentsFile) {
    try {
      $ac = Get-Content -LiteralPath $agentsFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $modelNames = @($ac.models | ForEach-Object { [string]$_.name })
      if ($ac.mainAgent) { $dshModel = [string]$ac.mainAgent.model }
      if ($ac.workAgent) { $dshAccess = [string]$ac.workAgent.access }
    } catch { }
  }

  # 状态根：config.json 在哪不重要，**run\openai.key 和 agents.json 一定在状态根下**（DG_HOME）
  $stateRoot = ''
  try { $stateRoot = Get-DgHome } catch { $stateRoot = $Root }
  if ($stateRoot -and -not (Test-Path -LiteralPath $agentsFile)) {
    # 单独开窗（没被桌宠 Dot-Source）时 Root 可能不是状态根，用状态根再找一次 agents.json
    $alt = Join-Path $stateRoot 'agents.json'
    if (Test-Path -LiteralPath $alt) {
      try {
        $ac = Get-Content -LiteralPath $alt -Raw -Encoding UTF8 | ConvertFrom-Json
        $modelNames = @($ac.models | ForEach-Object { [string]$_.name })
        if ($ac.mainAgent) { $dshModel = [string]$ac.mainAgent.model }
      } catch { }
    }
  }

  return @{
    S              = $UiScale
    ConfigPath     = $ConfigPath
    Root           = $Root
    StateRoot      = $stateRoot          # 状态根（run\openai.key、agents.json 都在这）
    AgentModels    = $modelNames
    AgentModel     = $dshModel
    AgentAccess    = $dshAccess
    RenderTo       = $RenderTo
    Origin         = $origin
    Sections       = (Get-DgSettingsSchema -Root $Root -ModelNames $modelNames -Origin $origin -DshModel $dshModel)
    Rows           = (New-Object System.Collections.ArrayList)   # 每行：Key/Kind/Ctl/Get/Section/Row/Panel/Item
    Form           = $null
    Nav            = $null
    Card           = $null
    Title          = $null        # 下面的引用都为了「窗口变大时重排」用
    Search         = $null
    SearchHint     = $null
    HelpBar        = $null
    Sep            = $null
    SaveBtn        = $null
    CancelBtn      = $null
    OpenBtn        = $null
    SectionTitle   = @{}
    SectionNote    = @{}
    SectionReset   = @{}
    RuleButtons    = @()
    RuleBoxH       = 0
    RuleListW      = 0
    RuleEditorW    = -1           # 规则编辑区上次排版的宽度（只在宽度真变了才重建，免得打字被打断）
    RegionNodes    = $null
    LayoutReady    = $false       # 构建完才允许重排（Resize 在构建期间也会触发）
    LayoutBusy     = $false
    PanelBySection = @{}
    RowStart       = @{}
    NavMap         = @()          # 导航列表里第 i 项 → 分组下标
    Active         = 0
    Hover          = -1
    Filter         = ''
    Changed        = [ordered]@{}
    RegionCleared  = $false
    RuleSets       = $null
    FontItem       = $null
    FontItemBold   = $null
    FontSmall      = $null
    FontH1         = $null
    Colors         = @{
      Bg      = [System.Drawing.Color]::FromArgb(255, 246, 247, 249)
      Card    = [System.Drawing.Color]::White
      Nav     = [System.Drawing.Color]::FromArgb(255, 240, 242, 246)
      NavSel  = [System.Drawing.Color]::White
      NavHot  = [System.Drawing.Color]::FromArgb(255, 231, 235, 241)
      Accent  = [System.Drawing.Color]::FromArgb(255, 47, 111, 235)
      Text    = [System.Drawing.Color]::FromArgb(255, 31, 41, 55)
      Muted   = [System.Drawing.Color]::FromArgb(255, 138, 148, 166)
      Line    = [System.Drawing.Color]::FromArgb(255, 236, 239, 243)
      Hot     = [System.Drawing.Color]::FromArgb(255, 253, 246, 224)
    }
  }
}

function Get-DgItemValue {
  param($Ctx, $Item)
  if ($Ctx.Origin.Contains($Item.Key)) {
    $v = $Ctx.Origin[$Item.Key]
    if ($null -ne $v) { return $v }
  }
  if ($Item.ContainsKey('Def')) { return $Item.Def }
  return $null
}

# schema 里的说明写成 `**强调**` 是为了读源码时清楚，显示到界面上要摘掉标记
function Clear-DgMarkdown {
  param([string]$Text)
  if (-not $Text) { return '' }
  return ($Text -replace '\*\*', '')
}

# 一个字体在「Label 里实际占多高」（像素）。
# 用它而不是 TextRenderer.MeasureText：后者量出来偏小（实测 19pt：66 vs 74），
# 按它设高度会把字裁掉、并且和下一行贴在一起 —— 用户看到的就是"字堆起来了"。
function Get-DgLineHeight {
  param($Font)
  $probe = New-Object System.Windows.Forms.Label
  $probe.AutoSize = $true
  $probe.Font = $Font
  $probe.Text = '汉字Ag'
  $h = [int]$probe.PreferredHeight
  $probe.Dispose()
  if ($h -le 0) { $h = [int][math]::Ceiling($Font.GetHeight()) + 4 }
  return $h
}

# 自己截断 + 加省略号。
# 为什么不用 Label.AutoEllipsis：它会把控件切到另一条绘制路径，WM_PRINT / DrawToBitmap
# 下**整块都不画**（实测标签列全消失，排查了半天）。自己截断则两条路径都正常。
function Limit-DgText {
  param([string]$Text, $Font, [int]$MaxWidth)
  $t = Clear-DgMarkdown $Text
  if (-not $t) { return '' }
  if ($MaxWidth -le 0) { return $t }
  if ([System.Windows.Forms.TextRenderer]::MeasureText($t, $Font).Width -le $MaxWidth) { return $t }
  while ($t.Length -gt 1 -and [System.Windows.Forms.TextRenderer]::MeasureText(($t + '…'), $Font).Width -gt $MaxWidth) {
    $t = $t.Substring(0, $t.Length - 1)
  }
  # 尽量收在标点上：裁成半个词看着像坏了，收在「，、；」上才像"本来就写到这儿"
  $idx = $t.LastIndexOfAny([char[]]@('，', '、', '；', '：', '。', '（', ' ', ',', ';', '('))
  if ($idx -ge [int]($t.Length * 0.55)) { $t = $t.Substring(0, $idx) }
  return ($t + '…')
}

# 把任意值压成可比较的字符串（用来判断"到底改没改"）
function Get-DgValueKey {
  param($Value)
  if ($null -eq $Value) { return 'null' }
  # 数字要归一化：JSON 读进来的 2 是整数、界面上读出来的是 2.0 —— 不归一化的话
  # 每个数字框都会被判成"改过"，保存一次整个文件就被写成 2.0（值一样，但很难看）。
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or
      $Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
    $d = [double]$Value
    if ($d -eq [math]::Floor($d) -and [math]::Abs($d) -lt 1e15) { return [string]([long]$d) }
    return $d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
  }
  if ($Value -is [bool]) { return ([string]$Value).ToLowerInvariant() }
  try { return [string]($Value | ConvertTo-Json -Compress -Depth 8) } catch { return [string]$Value }
}

# ---------------------------------------------------------------------------
# 造一行：左边标签 + 说明，右边控件
# ---------------------------------------------------------------------------
function New-DgRow {
  param($Ctx, $Item, [int]$Section, [int]$Top, [int]$Width, [int]$Indent = 0)

  $s = [double]$Ctx.S
  $c = $Ctx.Colors
  # 右边那列"单位"标签（秒 / 毫秒 / 张 / px / 元…）也是内容的一部分 —— 以前没把它算进宽度，
  # 于是行内容比面板宽几个像素，面板长出**横向滚动条**；一旦某个控件拿到焦点，
  # WinForms 会横向滚动去把它露出来 → 整列标签左边被切掉（用户截图里"采样间隔"缺了半边）。
  # 所以：先把单位标签量出来，再从控件宽度里扣掉。
  $unitW = 0
  if ($Item.ContainsKey('Unit') -and $Item.Unit) {
    # 70*s 是下限：TextRenderer 量出来偏窄（Label 自己画的时候更宽），
    # 量窄了"小时"会被折成两行、第二行正好被高度裁掉（实测就剩一个"小"）。
    $unitW = [int]([System.Windows.Forms.TextRenderer]::MeasureText([string]$Item.Unit, $Ctx.FontSmall).Width + 24 * $s)
    if ($unitW -lt [int](70 * $s)) { $unitW = [int](70 * $s) }
  }
  $multiline = ($Item.Kind -eq 'multiline')
  # 行高由**实测行高**算出来，不写死数字：19pt 字体在高 DPI 下比 "18*s" 高得多，写死会把字裁掉。
  $rowH = if ($multiline) { [int](92 * $s) } else { [int](8 * $s) + [int]$Ctx.HMain + [int]$Ctx.HSmall }

  $row = New-Object System.Windows.Forms.Panel
  $row.Top = $Top; $row.Height = $rowH
  # 用不透明底色，**不要** Transparent：透明控件的绘制要靠父级先画背景，在
  # DrawToBitmap / WM_PRINT 那条路径下会变成"子控件被擦掉"（实测标签整列不见）。
  $row.BackColor = $c.Card

  $lbl = New-Object System.Windows.Forms.Label
  $lbl.AutoSize = $false
  $lbl.Font = $Ctx.FontItemBold
  $lbl.ForeColor = $c.Text
  $lbl.BackColor = $c.Card
  $lbl.Left = 0; $lbl.Top = [int](4 * $s); $lbl.Height = [int]$Ctx.HMain
  # ⚠️ 别开 AutoEllipsis：它会把 Label 切到另一条绘制路径，WM_PRINT / DrawToBitmap 下
  # **整块都不画**（实测标签列整个消失）。行内说明本来就只是提示，过长就让它硬裁，
  # 完整说明在底部那条（鼠标停上去就有）。
  $lbl.AutoEllipsis = $false

  $help = New-Object System.Windows.Forms.Label
  $help.AutoSize = $false
  $help.Font = $Ctx.FontSmall
  $help.ForeColor = $c.Muted
  $help.BackColor = $c.Card
  $help.Left = 0; $help.Top = [int](4 * $s) + [int]$Ctx.HMain; $help.Height = [int]$Ctx.HSmall
  $help.AutoEllipsis = $false

  $row.Controls.Add($lbl)
  $row.Controls.Add($help)

  $entry = @{
    Key = [string]$Item.Key; Kind = [string]$Item.Kind; Item = $Item
    Section = $Section; Row = $row; Label = $lbl; Help = $help; Ctl = $null; Get = $null; Choices = $null
    Indent = $Indent; UnitW = $unitW; CtlTop = 0; UnitCtl = $null; Btn = $null; Line = $null
  }

  $cur = Get-DgItemValue -Ctx $Ctx -Item $Item
  $ctlTop = [int](9 * $s)
  $entry.CtlTop = $ctlTop

  switch ([string]$Item.Kind) {
    'bool' {
      $chk = New-Object System.Windows.Forms.CheckBox
      $chk.Text = ''
      $chk.Checked = [bool]$cur
      $chk.FlatStyle = 'Standard'
      $chk.Height = [int](22 * $s)
      $entry.Ctl = $chk
      $entry.Get = { param($ctl, $ent) return [bool]$ctl.Checked }
      $row.Controls.Add($chk)
    }
    'int' {
      $n = New-DgNumeric -Ctx $Ctx -Item $Item -Value $cur -CtlX 0 -CtlTop $ctlTop -Width 1
      $n.DecimalPlaces = 0
      $entry.Ctl = $n
      $entry.Get = { param($ctl, $ent) return [int]$ctl.Value }
      $row.Controls.Add($n)
    }
    'number' {
      $n = New-DgNumeric -Ctx $Ctx -Item $Item -Value $cur -CtlX 0 -CtlTop $ctlTop -Width 1
      $entry.Ctl = $n
      $dp = if ($Item.ContainsKey('Decimals')) { [int]$Item.Decimals } else { 1 }
      $entry.Dp = $dp
      $entry.Get = { param($ctl, $ent) return [math]::Round([double]$ctl.Value, [int]$ent.Dp) }
      $row.Controls.Add($n)
    }
    'choice' {
      $cb = New-Object System.Windows.Forms.ComboBox
      $cb.DropDownStyle = 'DropDownList'
      $cb.FlatStyle = 'Flat'
      $cb.Font = $Ctx.FontItem
      $entry.Choices = @($Item.Choices)
      $idx = 0
      for ($i = 0; $i -lt $entry.Choices.Count; $i++) {
        [void]$cb.Items.Add([string]$entry.Choices[$i].Text)
        if ([string]$entry.Choices[$i].Value -eq [string]$cur) { $idx = $i }
      }
      $cb.SelectedIndex = $idx
      $entry.Ctl = $cb
      $entry.Get = { param($ctl, $ent) return [string]$ent.Choices[$ctl.SelectedIndex].Value }
      $row.Controls.Add($cb)
    }
    'path' {
      $box = New-Object System.Windows.Forms.TextBox
      $box.Font = $Ctx.FontItem
      $box.BorderStyle = 'FixedSingle'
      $box.Text = [string]$cur
      $btnW = [int](64 * $s)
      $b = New-Object System.Windows.Forms.Button
      $b.Text = '浏览…'
      $b.FlatStyle = 'Flat'
      $b.Font = $Ctx.FontSmall
      $b.Height = [int](24 * $s)
      $b.Add_Click({
          param($sender, $e)
          $ctx = $sender.Tag
          $dlg = New-Object System.Windows.Forms.OpenFileDialog
          $dlg.Filter = '可执行 / 图片 / 目录里的一切|*.*'
          $dlg.CheckFileExists = $false
          if ($dlg.ShowDialog() -eq 'OK') { $ctx.Box.Text = $dlg.FileName }
          $dlg.Dispose()
        })
      $b.Tag = @{ Box = $box }
      $row.Controls.Add($box)
      $row.Controls.Add($b)
      $entry.Ctl = $box
      $entry.Btn = $b
      $entry.Get = { param($ctl, $ent) return [string]$ctl.Text }
    }
    'multiline' {
      $box = New-Object System.Windows.Forms.TextBox
      $box.Font = $Ctx.FontItem
      $box.BorderStyle = 'FixedSingle'
      $box.Multiline = $true
      $box.ScrollBars = 'Vertical'
      $box.Text = [string]$cur
      $box.Height = [int](70 * $s)
      $row.Controls.Add($box)
      $entry.Ctl = $box
      $entry.Get = { param($ctl, $ent) return [string]$ctl.Text }
    }
    'secret' {
      # 秘密不进 config.json：输入框 + 「写入」按钮 + 状态，写的是 run\<KeyFile>。
      # 状态标签借用"单位"那个槽位（这一行没有单位），Set-DgRowLayout 会自动排好。
      $box = New-Object System.Windows.Forms.TextBox
      $box.Font = $Ctx.FontItem
      $box.BorderStyle = 'FixedSingle'
      $box.UseSystemPasswordChar = $true

      $keyPath = ''
      if ($Ctx.StateRoot -and $Item.ContainsKey('KeyFile') -and $Item.KeyFile) {
        $keyPath = Join-Path (Join-Path $Ctx.StateRoot 'run') ([string]$Item.KeyFile)
      }

      $status = New-Object System.Windows.Forms.Label
      $status.Font = $Ctx.FontSmall
      $status.AutoSize = $false
      $status.BackColor = $c.Card
      $status.ForeColor = $c.Muted
      $status.Text = '未配置'
      if ($keyPath -and (Test-Path -LiteralPath $keyPath)) {
        try {
          $n = (Get-Content -LiteralPath $keyPath -Raw -Encoding UTF8).Trim().Length
          $status.Text = "已配置（$n 字符）"
        } catch { }
      }
      $entry.UnitCtl = $status
      $entry.UnitW = [int](150 * $s)

      $writeBtn = New-Object System.Windows.Forms.Button
      $writeBtn.Text = '写入'
      $writeBtn.FlatStyle = 'Flat'
      $writeBtn.Font = $Ctx.FontSmall
      $writeBtn.Height = [int](24 * $s)
      $writeBtn.Tag = @{ Ctx = $Ctx; Box = $box; Status = $status; Path = $keyPath }
      $writeBtn.Add_Click({
          param($sender, $e)
          $t = $sender.Tag
          if (-not $t.Path) { $t.Status.Text = '找不到状态根'; $t.Status.ForeColor = $t.Ctx.Colors.Muted; return }
          $key = ([string]$t.Box.Text).Trim()
          try {
            $dir = Split-Path -Parent $t.Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            if ([string]::IsNullOrWhiteSpace($key)) {
              if (Test-Path -LiteralPath $t.Path) { Remove-Item -LiteralPath $t.Path -Force }
              $t.Status.Text = '已清空'
              $t.Status.ForeColor = $t.Ctx.Colors.Muted
            } else {
              # -NoNewline：key 里混进换行的话，Authorization 头会被拆坏（实测这个坑很隐蔽）
              Set-Content -LiteralPath $t.Path -Value $key -NoNewline -Encoding UTF8
              $t.Status.Text = "已写入（$($key.Length) 字符）"
              $t.Status.ForeColor = $t.Ctx.Colors.Accent
            }
            Update-DgOpenAiProbe -Ctx $t.Ctx
          } catch {
            $t.Status.Text = "写入失败：$($_.Exception.Message)"
            $t.Status.ForeColor = $t.Ctx.Colors.Muted
          }
        })
      $row.Controls.Add($box)
      $row.Controls.Add($writeBtn)
      $row.Controls.Add($status)
      $entry.Ctl = $box
      $entry.Btn = $writeBtn
      # 这一行的值不进 config.json（Save-DgSettings 会跳过 secret），所以 Get 只是占位
      $entry.Get = { param($ctl, $ent) return '' }
    }
    'info' {
      $lbl2 = New-Object System.Windows.Forms.Label
      $lbl2.Text = [string]$cur
      $lbl2.Font = $Ctx.FontItem
      $lbl2.ForeColor = $c.Muted
      $lbl2.Height = [int](22 * $s)
      $lbl2.AutoEllipsis = $true
      $row.Controls.Add($lbl2)
      $entry.Ctl = $lbl2
      $entry.Get = { param($ctl, $ent) return [string]$ctl.Text }
    }
    default {
      $box = New-Object System.Windows.Forms.TextBox
      $box.Font = $Ctx.FontItem
      $box.BorderStyle = 'FixedSingle'
      $box.Text = [string]$cur
      $row.Controls.Add($box)
      $entry.Ctl = $box
      $entry.Get = { param($ctl, $ent) return [string]$ctl.Text }
    }
  }
  # 单位跟在控件后面（数字框右边），一眼能看出秒 / 毫秒 / px
  if ($Item.ContainsKey('Unit') -and $Item.Unit) {
    $u = New-Object System.Windows.Forms.Label
    $u.Text = [string]$Item.Unit
    $u.Font = $Ctx.FontSmall
    $u.ForeColor = $c.Muted
    $u.AutoSize = $false
    $u.Height = [int](18 * $s)
    $row.Controls.Add($u)
    $entry.UnitCtl = $u
  }

  # 行底 1px 分隔线做进**行里面**，搜索过滤重排时它会跟着行一起走
  $line = New-Object System.Windows.Forms.Panel
  $line.BackColor = $c.Line
  $line.Left = 0; $line.Height = 1
  $line.Top = $rowH - 1
  $row.Controls.Add($line)
  $entry.Line = $line

  # 鼠标停在哪一行，底部就把那一行的键名 + 完整说明显示出来（行内的说明是省略过的）。
  # 上下文走 Tag —— 事件处理器里抓外层局部变量不可靠（这个仓库踩过，见 TaskInput 的注释）。
  $hoverTag = @{ Ctx = $Ctx; Entry = $entry }
  foreach ($cc in @($row, $lbl, $help, $line)) {
    $cc.Tag = $hoverTag
    $cc.Add_MouseEnter({
        param($sender, $e)
        $t = $sender.Tag
        Show-DgHelp -Ctx $t.Ctx -Entry $t.Entry
      })
  }

  $entry.RowH = $rowH
  # 位置统一交给 Set-DgRowLayout —— 窗口拉伸时同一个函数会被再调一次，两处不会漂移
  Set-DgRowLayout -Ctx $Ctx -Entry $entry -Width $Width
  return @{ Entry = $entry; Height = $rowH }
}

# ---------------------------------------------------------------------------
# 一行里各控件的实际位置 / 宽度（构建时和窗口改大小时都走这里）
#
# 为什么单独抽一个函数：老写法把位置算死在 New-DgRow 里，窗口拉大之后行宽还是设计宽度，
# 内容不跟着长大（用户截图里"最大化但内容范围不变"）。抽出来之后 resize 只要重算即可。
# ---------------------------------------------------------------------------
function Set-DgRowLayout {
  param($Ctx, $Entry, [int]$Width, [int]$Indent = -1)
  $s = [double]$Ctx.S
  if ($Indent -lt 0) { $Indent = [int]$Entry.Indent }
  $row = $Entry.Row
  $row.Left = $Indent
  $row.Width = [Math]::Max([int](160 * $s), $Width)

  # 标签列：默认 300 逻辑 px，但不许吃掉超过 45% 的行宽（窄窗口下控制区先保底）
  $labelW = [int](300 * $s)
  $cap = [int]($row.Width * 0.45)
  if ($labelW -gt $cap) { $labelW = $cap }
  if ($labelW -lt [int](120 * $s)) { $labelW = [Math]::Min([int](120 * $s), $row.Width) }

  $ctlX = $Indent + $labelW
  $rightPad = [int](18 * $s)
  $unitW = [int]$Entry.UnitW
  $ctlW = $row.Width - $ctlX - $rightPad - $unitW
  if ($ctlW -lt [int](90 * $s)) { $ctlW = [int](90 * $s) }

  # 标签 / 说明跟着列宽重新截断：宽度变了，省略号的位置也得跟着变
  $txtW = [Math]::Max(1, $labelW - [int](14 * $s))
  $Entry.Label.Text = Limit-DgText -Text ([string]$Entry.Item.Label) -Font $Ctx.FontItemBold -MaxWidth $txtW
  $Entry.Label.Width = $txtW
  $Entry.Help.Text = Limit-DgText -Text ([string]$Entry.Item.Help) -Font $Ctx.FontSmall -MaxWidth $txtW
  $Entry.Help.Width = $txtW
  if ($Entry.Line) { $Entry.Line.Left = 0; $Entry.Line.Width = $row.Width }

  # 控件宽度按类型封顶：数字框、下拉框拉满整个窗口会很难看，多出来的就留成右边距
  $ctlTop = [int]$Entry.CtlTop
  $boxTop = $ctlTop
  $w = $ctlW
  switch ([string]$Entry.Kind) {
    'bool' { $w = [int](24 * $s) }
    'int' { $w = [Math]::Min($ctlW, [int](160 * $s)) }
    'number' { $w = [Math]::Min($ctlW, [int](160 * $s)) }
    'choice' { $w = [Math]::Max([int](180 * $s), [Math]::Min($ctlW, [int](320 * $s))) }
    'multiline' { $w = [Math]::Min($ctlW, [int](460 * $s)); $boxTop = [int](6 * $s) }
    default { $w = [Math]::Min($ctlW, [int](460 * $s)) }
  }
  if ($w -lt [int](90 * $s)) { $w = [int](90 * $s) }

  if ($Entry.Ctl) {
    $Entry.Ctl.Left = $ctlX
    $Entry.Ctl.Top = $boxTop
    $Entry.Ctl.Width = $w
  }
  if (($Entry.Kind -eq 'path' -or $Entry.Kind -eq 'secret') -and $Entry.Btn) {
    $bw = [int](64 * $s)
    $Entry.Ctl.Width = [Math]::Max([int](80 * $s), $w - $bw - [int](8 * $s))
    $Entry.Btn.Left = $ctlX + $w - $bw
    $Entry.Btn.Top = $ctlTop - [int](1 * $s)
    $Entry.Btn.Width = $bw
  }
  if ($Entry.UnitCtl) {
    $Entry.UnitCtl.Left = $Entry.Ctl.Left + $Entry.Ctl.Width + [int](8 * $s)
    $Entry.UnitCtl.Top = $ctlTop + [int](4 * $s)
    $Entry.UnitCtl.Width = [Math]::Max([int](24 * $s), $unitW)
    $Entry.UnitCtl.Height = [int](18 * $s)
  }
}

function New-DgNumeric {
  param($Ctx, $Item, $Value, [int]$CtlX, [int]$CtlTop, [int]$Width)
  $s = [double]$Ctx.S
  $n = New-Object System.Windows.Forms.NumericUpDown
  $n.Font = $Ctx.FontItem
  $n.BorderStyle = 'FixedSingle'
  $n.TextAlign = 'Left'
  $n.ThousandsSeparator = $false
  $dp = if ($Item.ContainsKey('Decimals')) { [int]$Item.Decimals } else { 1 }
  $n.DecimalPlaces = $dp
  $min = if ($Item.ContainsKey('Min')) { [decimal]$Item.Min } else { [decimal]0 }
  $max = if ($Item.ContainsKey('Max')) { [decimal]$Item.Max } else { [decimal]1000000 }
  $n.Minimum = $min
  $n.Maximum = $max
  $step = if ($Item.ContainsKey('Step')) { [decimal]$Item.Step } else { [decimal]1 }
  if ($step -le 0) { $step = [decimal]1 }
  $n.Increment = $step
  $v = [decimal]0
  try { $v = [decimal]$Value } catch { $v = $min }
  if ($v -lt $min) { $v = $min }
  if ($v -gt $max) { $v = $max }
  $n.Value = [math]::Round($v, $dp)
  $n.Left = $CtlX; $n.Top = $CtlTop
  $n.Width = [int]([Math]::Max(120 * $s, [Math]::Min($Width, 160 * $s)))
  return $n
}

# ---------------------------------------------------------------------------
# 分组面板
# ---------------------------------------------------------------------------
function New-DgSectionPanel {
  param($Ctx, [int]$Index)
  $s = [double]$Ctx.S
  $c = $Ctx.Colors
  $sec = $Ctx.Sections[$Index]
  $card = $Ctx.Card

  $panel = New-Object System.Windows.Forms.Panel
  $panel.Dock = 'Fill'
  $panel.BackColor = $c.Card
  $panel.AutoScroll = $true
  $panel.Visible = $false

  $title = New-Object System.Windows.Forms.Label
  $title.Text = [string]$sec.Name
  $title.Font = $Ctx.FontH1
  $title.ForeColor = $c.Text
  $title.Left = [int](18 * $s); $title.Top = [int](14 * $s)
  $title.Width = [int](360 * $s); $title.Height = [int]$Ctx.HH1
  $title.AutoSize = $false
  $panel.Controls.Add($title)
  $Ctx.SectionTitle[$Index] = $title

  $note = New-Object System.Windows.Forms.Label
  $noteText = Clear-DgMarkdown ([string]$sec.Note)
  $note.Text = $noteText
  $note.Font = $Ctx.FontSmall
  $note.ForeColor = $c.Muted
  $note.AutoSize = $false
  # 右边多留出竖直滚动条的位置（约 24 逻辑 px）。不留的话内容一超屏、竖条一出现，
  # 可用宽度变窄 → 立刻又长出横向滚动条，两条一起挂在那很难看。
  $noteW = [int]($card.ClientSize.Width - (24 + 40) * $s)
  $note.Left = [int](18 * $s); $note.Top = [int](14 * $s) + [int]$Ctx.HH1 + [int](6 * $s)
  $note.Width = $noteW
  # 说明要整段显示（有几段话比较长），所以按实际折行数算高度，别写死两行
  $noteSize = [System.Windows.Forms.TextRenderer]::MeasureText($noteText, $Ctx.FontSmall,
    ([System.Drawing.Size]::new($noteW, 1000)), ([System.Windows.Forms.TextFormatFlags]::WordBreak))
  # 多给几像素：TextRenderer 量折行高度也偏紧，这里宁可多留一点也别把说明裁掉
  $note.Height = [Math]::Max([int]$Ctx.HSmall, [int]$noteSize.Height + 6)
  $panel.Controls.Add($note)
  $Ctx.SectionNote[$Index] = $note

  # 「本页恢复默认」：只把这一页的值改回仓库里带的那份，仍然要点「保存」才写盘
  $reset = New-Object System.Windows.Forms.Button
  $reset.Text = '本页恢复默认'
  $reset.FlatStyle = 'Flat'
  $reset.Font = $Ctx.FontSmall
  $reset.ForeColor = $c.Accent
  $reset.BackColor = $c.Card
  $reset.FlatAppearance.BorderSize = 0
  $reset.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 240, 244, 253)
  $reset.Width = [int](120 * $s); $reset.Height = [int](24 * $s)
  $reset.Left = [int]($card.ClientSize.Width - (24 + 132) * $s); $reset.Top = [int](14 * $s)
  $reset.Tag = @{ Ctx = $Ctx; Section = $Index }
  $reset.Add_Click({
      param($sender, $e)
      Reset-DgSection -Ctx $sender.Tag.Ctx -Section $sender.Tag.Section
    })
  $panel.Controls.Add($reset)
  $Ctx.SectionReset[$Index] = $reset

  $width = [int]($card.ClientSize.Width - 36 * $s)
  $top = [int](14 * $s) + [int]$Ctx.HH1 + [int](6 * $s) + [int]$note.Height + [int](12 * $s)
  $Ctx.RowStart[$Index] = $top

  if ($sec.Custom -eq 'taskRules') {
    Build-DgTaskRules -Ctx $Ctx -Panel $panel -Top $top -Width $width -Section $Index
  } elseif ($sec.Custom -eq 'region') {
    Build-DgRegion -Ctx $Ctx -Panel $panel -Top $top -Width $width -Section $Index
  } else {
    foreach ($item in $sec.Items) {
      $r = New-DgRow -Ctx $Ctx -Item $item -Section $Index -Top $top -Width $width
      $panel.Controls.Add($r.Entry.Row)
      [void]$Ctx.Rows.Add($r.Entry)
      $top += $r.Height
      $top += [int](2 * $s)
    }
  }

  $Ctx.PanelBySection[$Index] = $panel
  $card.Controls.Add($panel)
  return $panel
}

function Reset-DgSection {
  param($Ctx, [int]$Section)
  foreach ($ent in $Ctx.Rows) {
    if ($ent.Section -ne $Section) { continue }
    if (-not $ent.Item.ContainsKey('Def')) { continue }
    $d = $ent.Item.Def
    switch ($ent.Kind) {
      'bool' { $ent.Ctl.Checked = [bool]$d }
      'int' {
        $v = [decimal]$d
        if ($v -lt $ent.Ctl.Minimum) { $v = $ent.Ctl.Minimum }
        if ($v -gt $ent.Ctl.Maximum) { $v = $ent.Ctl.Maximum }
        $ent.Ctl.Value = $v
      }
      'number' {
        $v = [decimal]$d
        if ($v -lt $ent.Ctl.Minimum) { $v = $ent.Ctl.Minimum }
        if ($v -gt $ent.Ctl.Maximum) { $v = $ent.Ctl.Maximum }
        $ent.Ctl.Value = $v
      }
      'choice' {
        for ($i = 0; $i -lt $ent.Choices.Count; $i++) {
          if ([string]$ent.Choices[$i].Value -eq [string]$d) { $ent.Ctl.SelectedIndex = $i; break }
        }
      }
      default { $ent.Ctl.Text = [string]$d }
    }
  }
  Show-DgHelp -Ctx $Ctx -Entry $null -Note '这一页已改回仓库里带的默认值（点「保存」才写进 config.json）。'
}

# ---------------------------------------------------------------------------
# 任务规则表：左列规则，右边编辑选中那条
# ---------------------------------------------------------------------------
function Build-DgTaskRules {
  param($Ctx, $Panel, [int]$Top, [int]$Width, [int]$Section)
  $s = [double]$Ctx.S
  $c = $Ctx.Colors

  $rules = New-Object System.Collections.ArrayList
  $cur = $Ctx.Origin['taskRules']
  if ($null -ne $cur) {
    foreach ($r in @($cur)) {
      # 统一换成有序 hashtable：JSON 读进来的是 PSCustomObject，属性只读、界面改不动。
      # 换的时候保留原有键顺序和未知键（以后加的字段），保存回去才不会丢东西。
      $h = [ordered]@{}
      foreach ($p in $r.PSObject.Properties) { $h[$p.Name] = $p.Value }
      [void]$rules.Add($h)
    }
  }
  $Ctx.RuleSets = $rules

  $listW = [int](190 * $s)
  # 编辑区高度要装得下**全部**字段（6 个，其中一个是多行）：字变小之后约 650 物理 px。
  # 也不能太高 —— 下面的「新增/删除/上移/下移」得留在卡片可视区内，不然要滚动才点得到。
  $boxH = [int](350 * $s)
  $list = New-Object System.Windows.Forms.ListBox
  $list.Left = [int](18 * $s); $list.Top = $Top
  $list.Width = $listW; $list.Height = $boxH
  $list.Font = $Ctx.FontItem
  $list.BorderStyle = 'FixedSingle'
  $list.IntegralHeight = $false

  $editor = New-Object System.Windows.Forms.Panel
  $editor.Left = [int](18 * $s) + $listW + [int](16 * $s); $editor.Top = $Top
  $editor.Width = $Width - $listW - [int](50 * $s); $editor.Height = $boxH
  $editor.BackColor = $c.Card

  $btns = @(
    @{ Text = '新增'; Act = 'add' }
    @{ Text = '删除'; Act = 'del' }
    @{ Text = '上移'; Act = 'up' }
    @{ Text = '下移'; Act = 'down' }
  )
  $ruleBtns = New-Object System.Collections.ArrayList
  $bx = [int](18 * $s)
  foreach ($b in $btns) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = [string]$b.Text
    $btn.FlatStyle = 'Flat'
    $btn.Font = $Ctx.FontSmall
    $btn.Width = [int](64 * $s); $btn.Height = [int](26 * $s)
    $btn.Left = $bx; $btn.Top = $Top + $boxH + [int](12 * $s)
    $btn.Tag = @{ Ctx = $Ctx; Act = [string]$b.Act }
    $btn.Add_Click({
        param($sender, $e)
        $ctx = $sender.Tag.Ctx
        $act = $sender.Tag.Act
        $sets = $ctx.RuleSets
        $sel = [int]$ctx.RuleList.SelectedIndex
        switch ($act) {
          'add' {
            [void]$sets.Add([pscustomobject]@{ name = '新规则'; process = @(); sampleSeconds = 2; judgeMinSeconds = 60; hint = '' })
            $ctx.RuleList.SelectedIndex = $sets.Count - 1
          }
          'del' {
            if ($sel -ge 0 -and $sets.Count -gt 0) {
              $sets.RemoveAt($sel)
              if ($sets.Count -gt 0) { $ctx.RuleList.SelectedIndex = [Math]::Min($sel, $sets.Count - 1) }
            }
          }
          'up' {
            if ($sel -gt 0) {
              $tmp = $sets[$sel - 1]; $sets[$sel - 1] = $sets[$sel]; $sets[$sel] = $tmp
              $ctx.RuleList.SelectedIndex = $sel - 1
            }
          }
          'down' {
            if ($sel -ge 0 -and $sel -lt $sets.Count - 1) {
              $tmp = $sets[$sel + 1]; $sets[$sel + 1] = $sets[$sel]; $sets[$sel] = $tmp
              $ctx.RuleList.SelectedIndex = $sel + 1
            }
          }
        }
      })
    $Panel.Controls.Add($btn)
    [void]$ruleBtns.Add($btn)
    $bx += [int](70 * $s)
  }
  $Ctx.RuleButtons = @($ruleBtns)
  $Ctx.RuleBoxH = $boxH
  $Ctx.RuleListW = $listW

  $list.Tag = @{ Ctx = $Ctx }
  $list.Add_SelectedIndexChanged({
      param($sender, $e)
      Update-DgRuleEditor -Ctx $sender.Tag.Ctx
    })

  $Panel.Controls.Add($list)
  $Panel.Controls.Add($editor)
  $Ctx.RuleList = $list
  $Ctx.RuleEditor = $editor
  $list.BeginUpdate()
  foreach ($r in $Ctx.RuleSets) { [void]$list.Items.Add((Get-DgRuleTitle -Rule $r)) }
  $list.EndUpdate()
  if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
  Update-DgRuleEditor -Ctx $Ctx
}

function Get-DgRuleTitle {
  param($Rule)
  $n = ''
  if ($Rule.Contains('name')) { $n = [string]$Rule['name'] }
  if (-not $n -and $Rule.Contains('process')) { $n = (@($Rule['process']) -join '/') }
  if (-not $n) { $n = '(未命名)' }
  return $n
}

function Update-DgRuleEditor {
  param($Ctx)
  $s = [double]$Ctx.S
  $c = $Ctx.Colors
  $ed = $Ctx.RuleEditor
  $ed.Controls.Clear()
  $idx = [int]$Ctx.RuleList.SelectedIndex
  if ($idx -lt 0 -or $idx -ge $Ctx.RuleSets.Count) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = '左边选一条规则来编辑；「新增」加一条。'
    $lbl.Font = $Ctx.FontSmall; $lbl.ForeColor = $c.Muted
    $lbl.Left = 0; $lbl.Top = [int](10 * $s); $lbl.Width = $ed.Width; $lbl.Height = [int](20 * $s)
    $ed.Controls.Add($lbl)
    return
  }
  $rule = $Ctx.RuleSets[$idx]
  $ed.Tag = @{ Ctx = $Ctx; Rule = $rule }
  $y = 0
  foreach ($f in @(
      @{ Key = 'name'; Label = '规则名'; Hint = '只给你自己看，例如「卡牌/回合制游戏」'; Kind = 'text' }
      @{ Key = 'process'; Label = '进程名（逗号分隔）'; Hint = '命中即算，例如 balatro, slay, sts'; Kind = 'list' }
      @{ Key = 'title'; Label = '窗口标题（逗号分隔）'; Hint = '进程名认不出时用它，子串匹配'; Kind = 'list' }
      @{ Key = 'sampleSeconds'; Label = '采样间隔（秒）'; Hint = '这类任务多久看一眼'; Kind = 'number' }
      @{ Key = 'judgeMinSeconds'; Label = '判断最小间隔（秒）'; Hint = '两次起模型之间至少隔多久'; Kind = 'number' }
      @{ Key = 'hint'; Label = '给模型的提示'; Hint = '会提前写进提示词：这类任务优先看什么'; Kind = 'multiline' }
    )) {
    $lbl = New-Object System.Windows.Forms.Label
    $lblW = [int](170 * $s)
    $lbl.Text = Limit-DgText -Text ([string]$f.Label) -Font $Ctx.FontItemBold -MaxWidth $lblW
    $lbl.AutoSize = $false
    $lbl.Font = $Ctx.FontItemBold; $lbl.ForeColor = $c.Text
    $lbl.Left = 0; $lbl.Top = $y + [int](4 * $s); $lbl.Width = $lblW; $lbl.Height = [int]$Ctx.HMain
    $ed.Controls.Add($lbl)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = Limit-DgText -Text ([string]$f.Hint) -Font $Ctx.FontSmall -MaxWidth $lblW
    $hint.AutoSize = $false
    $hint.Font = $Ctx.FontSmall; $hint.ForeColor = $c.Muted
    $hint.Left = 0; $hint.Top = $y + [int](4 * $s) + [int]$Ctx.HMain; $hint.Width = $lblW; $hint.Height = [int]$Ctx.HSmall
    $hint.AutoEllipsis = $false
    $ed.Controls.Add($hint)
    $rowStep = [int](4 * $s) + [int]$Ctx.HMain + [int](2 * $s) + [int]$Ctx.HSmall + [int](10 * $s)

    $val = $null
    if ($rule.Contains([string]$f.Key)) { $val = $rule[[string]$f.Key] }
    $cx = [int](180 * $s)
    $cw = $ed.Width - $cx
    if ($f.Kind -eq 'multiline') {
      $box = New-Object System.Windows.Forms.TextBox
      $box.Multiline = $true; $box.ScrollBars = 'Vertical'; $box.BorderStyle = 'FixedSingle'
      $box.Font = $Ctx.FontSmall
      $box.Text = [string]$val
      $box.Left = $cx; $box.Top = $y; $box.Width = $cw; $box.Height = [int](58 * $s)
      $box.Tag = @{ Ctx = $Ctx; Index = $idx; Rule = $rule; Key = [string]$f.Key; Kind = 'text' }
      $box.Add_TextChanged({ param($sender, $e) $t = $sender.Tag; Set-DgRuleField -Ctx $t.Ctx -Index $t.Index -Key $t.Key -Value $sender.Text -Kind $t.Kind })
      $ed.Controls.Add($box)
      $y += [int](66 * $s)
    } else {
      $box = New-Object System.Windows.Forms.TextBox
      $box.BorderStyle = 'FixedSingle'
      $box.Font = $Ctx.FontItem
      if ($f.Kind -eq 'list') { $box.Text = (@($val) -join ', ') } else { $box.Text = [string]$val }
      $box.Left = $cx; $box.Top = $y; $box.Width = $cw
      $box.Tag = @{ Ctx = $Ctx; Index = $idx; Rule = $rule; Key = [string]$f.Key; Kind = [string]$f.Kind }
      $box.Add_TextChanged({ param($sender, $e) $t = $sender.Tag; Set-DgRuleField -Ctx $t.Ctx -Index $t.Index -Key $t.Key -Value $sender.Text -Kind $t.Kind })
      $ed.Controls.Add($box)
      $y += $rowStep
    }
  }
}

function Set-DgRuleField {
  param($Ctx, [int]$Index, [string]$Key, $Value, [string]$Kind)
  if ($Index -lt 0 -or $Index -ge $Ctx.RuleSets.Count) { return }
  $Rule = $Ctx.RuleSets[$Index]
  if ($Kind -eq 'list') {
    $Rule[$Key] = @(($Value -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  } elseif ($Kind -eq 'number') {
    $d = 0.0
    try { $d = [double]$Value } catch { $d = 0.0 }
    $Rule[$Key] = $d
  } else {
    $Rule[$Key] = [string]$Value
  }
  # 改名要立刻反映到左边的列表上，否则用户以为没改上
  try {
    if ($Ctx.RuleList -and $Index -lt $Ctx.RuleList.Items.Count) {
      $Ctx.RuleList.Items[$Index] = (Get-DgRuleTitle -Rule $Rule)
    }
  } catch { }
}

# ---------------------------------------------------------------------------
# 监控区域
# ---------------------------------------------------------------------------
function Build-DgRegion {
  param($Ctx, $Panel, [int]$Top, [int]$Width, [int]$Section)
  $s = [double]$Ctx.S
  $c = $Ctx.Colors
  $reg = $Ctx.Origin['region']

  # 这一行必须说清"现在真正在抓的是谁"：区域分成两层之后，用户层为空时在抓的可能是
  # agent 的临时覆盖层（内存里那份，本页改不到）。不说的话这行会跟实际抓的东西不一致。
  $auto = $null; try { $auto = $script:autoRegion } catch { }
  $byAgent = $false
  if ($null -ne $auto) {
    $overrides = $true
    try { $overrides = [bool]$script:watchOverridesUserRegion } catch { }
    if ($null -eq $reg -or $overrides) { $reg = $auto; $byAgent = $true }
  }
  $txt = if ($null -eq $reg) { '整个屏幕（默认）' }
         elseif ($byAgent) { "x=$($reg.x), y=$($reg.y), $($reg.w)×$($reg.h)（agent 临时盯的）" }
         else { "x=$($reg.x), y=$($reg.y), $($reg.w)×$($reg.h)" }
  $row = New-Object System.Windows.Forms.Panel
  $row.Left = 0; $row.Top = $Top; $row.Width = $Width
  $row.BackColor = $c.Card
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text = '当前监控区域'
  $lbl.AutoSize = $false
  $lbl.BackColor = $c.Card
  $lbl.Font = $Ctx.FontItemBold; $lbl.ForeColor = $c.Text
  $lbl.Left = [int](18 * $s); $lbl.Top = [int](6 * $s); $lbl.Width = [int](300 * $s); $lbl.Height = [int]$Ctx.HMain
  $val = New-Object System.Windows.Forms.Label
  $val.Text = Limit-DgText -Text $txt -Font $Ctx.FontItem -MaxWidth ([int](300 * $s))
  $val.AutoSize = $false
  $val.BackColor = $c.Card
  $val.Font = $Ctx.FontItem; $val.ForeColor = $c.Text
  $val.Left = [int](336 * $s); $val.Top = [int](6 * $s); $val.Width = [int](300 * $s); $val.Height = [int]$Ctx.HMain
  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = Limit-DgText -Text '框选新区域用右键「更多 ▸ 框选监控区域…」（那是个全屏的选择器，没法塞进这个窗口）。' -Font $Ctx.FontSmall -MaxWidth ([int]($Width - 36 * $s))
  $hint.AutoSize = $false
  $hint.BackColor = $c.Card
  $hint.Font = $Ctx.FontSmall; $hint.ForeColor = $c.Muted
  $hint.Left = [int](18 * $s); $hint.Top = [int](6 * $s) + [int]$Ctx.HMain + [int](4 * $s); $hint.Width = $Width - [int](36 * $s); $hint.Height = [int]$Ctx.HSmall
  $row.Height = [int](6 * $s) + [int]$Ctx.HMain + [int](4 * $s) + [int]$Ctx.HSmall + [int](6 * $s)
  $row.Controls.Add($lbl); $row.Controls.Add($val); $row.Controls.Add($hint)
  $Panel.Controls.Add($row)
  # Text 存原文：窗口变宽/变窄时按新宽度重新截断
  $Ctx.RegionNodes = @{ Row = $row; Label = $lbl; Val = $val; Hint = $hint; Text = $txt }

  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = '清除（改回整屏）'
  $btn.FlatStyle = 'Flat'
  $btn.Font = $Ctx.FontItem
  $btn.Width = [int](220 * $s); $btn.Height = [int](34 * $s)
  $btn.Left = [int](18 * $s); $btn.Top = $Top + $row.Height + [int](12 * $s)
  $btn.Tag = @{ Ctx = $Ctx; Label = $val }
  $btn.Add_Click({
      param($sender, $e)
      $t = $sender.Tag
      $t.Ctx.RegionCleared = $true
      $t.Label.Text = '整个屏幕（保存后生效）'
    })
  $Panel.Controls.Add($btn)
  $Ctx.RegionNodes.Btn = $btn
}

# ---------------------------------------------------------------------------
# 导航 / 搜索 / 底部说明
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 分组内部排版：构建时排一次，窗口改大小、搜索过滤时再排
#
# 宽度一律从**卡片**（不随滚动条变化）取，而不是从面板的 ClientSize 取 ——
# 面板一长出竖向滚动条，ClientSize 就变窄，算出来的行宽会跟着抖。
# ---------------------------------------------------------------------------
function Set-DgSectionLayout {
  param($Ctx, [int]$Index)
  if (-not $Ctx.PanelBySection.ContainsKey($Index)) { return }
  if (-not $Ctx.Card) { return }
  $s = [double]$Ctx.S
  $panel = $Ctx.PanelBySection[$Index]
  $sec = $Ctx.Sections[$Index]

  # 横滚一点点都不许有：面板一旦横向滚动，整列标签左边就被切掉（用户报的"遮挡"）。
  # 竖向位置保留，只把横向偏移归零。
  try {
    $sp = $panel.AutoScrollPosition
    if ([Math]::Abs([int]$sp.X) -gt 0) { $panel.AutoScrollPosition = New-Object System.Drawing.Point 0, (-[int]$sp.Y) }
  } catch { }

  $pw = [int]$Ctx.Card.ClientSize.Width
  $ph = [int]$Ctx.Card.ClientSize.Height
  if ($pw -le 0) { return }
  $padL = [int](18 * $s)
  $padR = [int](24 * $s)      # 比滚动条宽一点：竖条冒出来也不会把行挤窄

  $title = $Ctx.SectionTitle[$Index]
  if ($title) { $title.Left = $padL; $title.Top = [int](14 * $s); $title.Height = [int]$Ctx.HH1 }

  $noteTop = [int](14 * $s) + [int]$Ctx.HH1 + [int](6 * $s)
  $noteH = [int]$Ctx.HSmall
  $note = $Ctx.SectionNote[$Index]
  if ($note) {
    $note.Left = $padL
    $note.Top = $noteTop
    $note.Width = [Math]::Max([int](160 * $s), $pw - $padL - $padR - [int](16 * $s))
    # 说明要整段显示（有几段比较长），按实际折行数算高度 —— 窗口一变窄，行数就变多
    $noteSize = [System.Windows.Forms.TextRenderer]::MeasureText([string]$note.Text, $Ctx.FontSmall,
      ([System.Drawing.Size]::new($note.Width, 4000)), ([System.Windows.Forms.TextFormatFlags]::WordBreak))
    $note.Height = [Math]::Max([int]$Ctx.HSmall, [int]$noteSize.Height + 6)
    $noteH = [int]$note.Height
  }

  $reset = $Ctx.SectionReset[$Index]
  if ($reset) {
    $reset.Width = [int](120 * $s); $reset.Height = [int](24 * $s)
    # 「本页恢复默认」右对齐，跟着窗口走（老写法按设计宽度算死，最大化之后它会飘到中间）
    $reset.Left = [Math]::Max($padL, $pw - $padR - $reset.Width - [int](8 * $s))
    $reset.Top = [int](14 * $s)
  }

  $top = $noteTop + $noteH + [int](12 * $s)
  $Ctx.RowStart[$Index] = $top

  if ($sec.Custom -eq 'taskRules') {
    $listW = [int](190 * $s)
    $boxH = [int](350 * $s)
    # 编辑区**不跟着窗口变矮**：它里面 6 个字段是固定内容，压矮了下面两个字段就点不到了。
    # 窗口矮的时候由外面那层走竖向滚动（面板本来就是 AutoScroll）。
    if ($Ctx.RuleList) {
      $Ctx.RuleList.Left = $padL; $Ctx.RuleList.Top = $top
      $Ctx.RuleList.Width = $listW; $Ctx.RuleList.Height = $boxH
    }
    if ($Ctx.RuleEditor) {
      $edLeft = $padL + $listW + [int](16 * $s)
      $Ctx.RuleEditor.Left = $edLeft; $Ctx.RuleEditor.Top = $top; $Ctx.RuleEditor.Height = $boxH
      $Ctx.RuleEditor.Width = [Math]::Max([int](240 * $s), $pw - $edLeft - $padR)
      if ($Ctx.RuleEditorW -ne $Ctx.RuleEditor.Width) {
        $Ctx.RuleEditorW = [int]$Ctx.RuleEditor.Width
        Update-DgRuleEditor -Ctx $Ctx      # 字段宽度是算出来的，宽度变了就重建一次
      }
    }
    $bx = $padL
    foreach ($b in @($Ctx.RuleButtons)) {
      if (-not $b) { continue }
      $b.Left = $bx; $b.Top = $top + $boxH + [int](12 * $s)
      $bx += [int](70 * $s)
    }
    return
  }

  if ($sec.Custom -eq 'region') {
    $n = $Ctx.RegionNodes
    if ($n) {
      $rowW = [Math]::Max([int](240 * $s), $pw - $padL - $padR)
      $n.Row.Left = 0; $n.Row.Top = $top; $n.Row.Width = $rowW
      $lblW = [int](300 * $s)
      if ($lblW -gt [int]($rowW * 0.5)) { $lblW = [int]($rowW * 0.5) }
      $n.Label.Left = $padL; $n.Label.Top = [int](6 * $s); $n.Label.Width = $lblW
      $n.Val.Left = $padL + $lblW + [int](18 * $s); $n.Val.Top = [int](6 * $s)
      $n.Val.Width = [Math]::Max([int](120 * $s), $rowW - $n.Val.Left - [int](18 * $s))
      if ($n.Text) { $n.Val.Text = Limit-DgText -Text ([string]$n.Text) -Font $Ctx.FontItem -MaxWidth ([int]$n.Val.Width) }
      $n.Hint.Left = $padL; $n.Hint.Top = [int](6 * $s) + [int]$Ctx.HMain + [int](4 * $s)
      $n.Hint.Width = [Math]::Max([int](160 * $s), $rowW - $padL - $padR)
      if ($n.Btn) { $n.Btn.Left = $padL; $n.Btn.Top = $top + $n.Row.Height + [int](12 * $s) }
    }
    return
  }

  # 普通分组：逐行重排（被搜索藏掉的行不占位置）
  $rowW = [Math]::Max([int](240 * $s), $pw - $padL - $padR)
  $y = $top
  foreach ($ent in $Ctx.Rows) {
    if ($ent.Section -ne $Index) { continue }
    Set-DgRowLayout -Ctx $Ctx -Entry $ent -Width $rowW
    $hit = $true
    if ($Ctx.Filter) { $hit = Test-DgMatch -Text ("$($ent.Item.Label) $($ent.Key) $($ent.Item.Help)") -Filter $Ctx.Filter }
    $ent.Row.Visible = $hit
    if ($hit) {
      $ent.Row.Top = $y
      $y += [int]$ent.RowH + [int](2 * $s)
    }
  }
}

# ---------------------------------------------------------------------------
# 整窗排版：最大化 / 拖动边框都走这里
#
# 老写法把所有位置按 920×700 的设计尺寸算死在构建时 —— 窗口一最大化，卡片还是那么宽，
# 内容范围不变、右边空一大块，导航和卡片之间那条 16px 的间距还会算丢（`$24` 写成了变量，
# 求值成 0），卡片被塞到导航底下。现在所有位置都在这里按**实际客户区**算。
# ---------------------------------------------------------------------------
function Update-DgLayout {
  param($Ctx)
  if (-not $Ctx.LayoutReady) { return }
  if ($Ctx.LayoutBusy) { return }
  $Ctx.LayoutBusy = $true
  try {
    $f = $Ctx.Form
    if (-not $f -or -not $Ctx.Card -or -not $Ctx.Nav) { return }
    $s = [double]$Ctx.S
    $cw = [int]$f.ClientSize.Width
    $ch = [int]$f.ClientSize.Height
    $pad = [int](24 * $s)
    $headerH = [int](84 * $s)     # 顶部标题 + 搜索框那一带
    $footerH = [int](120 * $s)    # 底部：分隔线 + 提示 + 三个按钮
    $gap = [int](16 * $s)
    $navW = [int](208 * $s)

    if ($Ctx.Title) { $Ctx.Title.Left = $pad; $Ctx.Title.Top = [int](14 * $s) }
    if ($Ctx.Search) {
      $sw = [int](264 * $s)
      $Ctx.Search.Width = $sw
      $Ctx.Search.Left = [Math]::Max($pad, $cw - $pad - $sw)
      $Ctx.Search.Top = [int](22 * $s)
      if ($Ctx.SearchHint) {
        $Ctx.SearchHint.Left = $Ctx.Search.Left + 3
        $Ctx.SearchHint.Top = $Ctx.Search.Top + 3
        $Ctx.SearchHint.Width = [Math]::Max(1, $Ctx.Search.Width - 6)
        $Ctx.SearchHint.Height = [Math]::Max(1, $Ctx.Search.Height - 6)
      }
    }

    # 中间这一带（导航 + 卡片）跟着窗口长高长宽
    $bandH = [Math]::Max([int](160 * $s), $ch - $headerH - $footerH)
    $Ctx.Nav.Left = $pad; $Ctx.Nav.Top = $headerH
    $Ctx.Nav.Width = $navW; $Ctx.Nav.Height = $bandH

    $cardLeft = $pad + $navW + $gap
    $Ctx.Card.Left = $cardLeft; $Ctx.Card.Top = $headerH
    $Ctx.Card.Width = [Math]::Max([int](360 * $s), $cw - $cardLeft - $pad)
    $Ctx.Card.Height = $bandH

    if ($Ctx.Sep) {
      $Ctx.Sep.Left = $pad; $Ctx.Sep.Width = [Math]::Max(1, $cw - 2 * $pad)
      $Ctx.Sep.Top = $ch - $footerH
    }
    if ($Ctx.HelpBar) {
      $Ctx.HelpBar.Left = $pad; $Ctx.HelpBar.Width = [Math]::Max(1, $cw - 2 * $pad)
      $Ctx.HelpBar.Top = $ch - $footerH + [int](6 * $s)
      $Ctx.HelpBar.Height = 2 * [int]$Ctx.HSmall
    }

    $btnTop = [Math]::Max($headerH, $ch - [int](60 * $s))
    if ($Ctx.SaveBtn) {
      $Ctx.SaveBtn.Top = $btnTop
      $Ctx.SaveBtn.Left = [Math]::Max($pad, $cw - $pad - $Ctx.SaveBtn.Width)
    }
    if ($Ctx.CancelBtn) {
      $Ctx.CancelBtn.Top = $btnTop
      $Ctx.CancelBtn.Left = [Math]::Max($pad, $Ctx.SaveBtn.Left - [int](10 * $s) - $Ctx.CancelBtn.Width)
    }
    if ($Ctx.OpenBtn) {
      $Ctx.OpenBtn.Top = $btnTop
      $Ctx.OpenBtn.Left = [Math]::Max($pad, $Ctx.CancelBtn.Left - [int](16 * $s) - $Ctx.OpenBtn.Width)
    }

    for ($i = 0; $i -lt $Ctx.Sections.Count; $i++) { Set-DgSectionLayout -Ctx $Ctx -Index $i }
  } finally { $Ctx.LayoutBusy = $false }
}

function Show-DgHelp {
  param($Ctx, $Entry, [string]$Note = '')
  if (-not $Ctx.HelpBar) { return }
  if ($Note) { $Ctx.HelpBar.Text = $Note; return }
  if (-not $Entry) { $Ctx.HelpBar.Text = ''; return }
  $late = ''
  if ($Entry.Item.ContainsKey('Late') -and $Entry.Item.Late) { $late = "　⚠ $($Entry.Item.Late)" }
  $Ctx.HelpBar.Text = Clear-DgMarkdown "$($Entry.Key)（$($Entry.Item.Label)）　$($Entry.Item.Help)$late"
}

function Update-DgNav {
  param($Ctx)
  $nav = $Ctx.Nav
  $keep = $Ctx.Active
  $nav.BeginUpdate()
  $nav.Items.Clear()
  $Ctx.NavMap = @()
  $f = [string]$Ctx.Filter
  for ($i = 0; $i -lt $Ctx.Sections.Count; $i++) {
    $sec = $Ctx.Sections[$i]
    $n = 0
    foreach ($ent in $Ctx.Rows) {
      if ($ent.Section -ne $i) { continue }
      if (Test-DgMatch -Text ("$($ent.Item.Label) $($ent.Key) $($ent.Item.Help)") -Filter $f) { $n++ }
    }
    if ($sec.Custom) { $n = if ($f) { 0 } else { 1 } }
    if ($n -le 0 -and -not $f) { $n = 1 }
    if ($n -le 0) { continue }
    if ($f) { [void]$nav.Items.Add("$($sec.Name)  ($n)") } else { [void]$nav.Items.Add([string]$sec.Name) }
    $Ctx.NavMap += $i
  }
  $nav.EndUpdate()
  $old = [Math]::Max(0, [array]::IndexOf($Ctx.NavMap, $keep))
  if ($old -ge $nav.Items.Count) { $old = [Math]::Max(0, $nav.Items.Count - 1) }
  if ($nav.Items.Count -gt 0) { $nav.SelectedIndex = $old }
}

function Test-DgMatch {
  param([string]$Text, [string]$Filter)
  if (-not $Filter) { return $true }
  # 不用 -like：用户搜 "[" 之类的字符时通配符会误伤；这里就是要朴素的子串匹配。
  return ($Text.IndexOf($Filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Apply-DgFilter {
  param($Ctx)
  # 过滤后必须**重排**：只把行藏掉不算数，中间会留一片空白（看着像坏了）。
  # 重排逻辑统一在 Set-DgSectionLayout 里（它同时负责窗口大小变化后的重排）。
  for ($i = 0; $i -lt $Ctx.Sections.Count; $i++) { Set-DgSectionLayout -Ctx $Ctx -Index $i }
  Update-DgNav -Ctx $Ctx
}

function Set-DgSection {
  param($Ctx, [int]$Index)
  $Ctx.Active = $Index
  foreach ($k in $Ctx.PanelBySection.Keys) {
    $Ctx.PanelBySection[$k].Visible = ($k -eq $Index)
  }
  if ($Ctx.PanelBySection.ContainsKey($Index)) {
    $Ctx.PanelBySection[$Index].AutoScrollPosition = New-Object System.Drawing.Point 0, 0
  }
  $sec = $Ctx.Sections[$Index]
  Show-DgHelp -Ctx $Ctx -Entry $null -Note (Clear-DgMarkdown "$($sec.Name)　—　$($sec.Note)")
}

# ---------------------------------------------------------------------------
# 保存
# ---------------------------------------------------------------------------
function Save-DgSettings {
  param($Ctx)
  $changed = [ordered]@{}
  $agentChanged = [ordered]@{}      # 要写进 agents.json 的（不是 config.json）
  $bad = $null

  foreach ($ent in $Ctx.Rows) {
    # info 行是"只显示、不可改"（探测结果）；secret 行自己写文件（key 不进 config.json）
    if ($ent.Kind -eq 'info' -or $ent.Kind -eq 'secret') { continue }
    # AgentPath 行是 agents.json 的字段（比如「和 DSH 同一个模型」）
    if ($ent.Item.ContainsKey('AgentPath')) {
      $newA = $null
      try { $newA = [string](& $ent.Get $ent.Ctl $ent) } catch { continue }
      $curA = if ($ent.Item.ContainsKey('AgentDef')) { [string]$ent.Item.AgentDef } else { '' }
      if ($newA -ne $curA -and $newA) { $agentChanged[[string]$ent.Item.AgentPath] = $newA }
      continue
    }
    $new = $null
    try { $new = & $ent.Get $ent.Ctl $ent } catch { continue }
    if ($ent.Item.ContainsKey('Pattern') -and $ent.Item.Pattern) {
      $txt = [string]$new
      if ($txt -and ($txt -notmatch [string]$ent.Item.Pattern)) {
        $bad = [pscustomobject]@{ Entry = $ent; Why = "格式不对：$($ent.Item.PatternTip)" }
        break
      }
    }
    $old = Get-DgItemValue -Ctx $Ctx -Item $ent.Item
    if ((Get-DgValueKey $old) -ne (Get-DgValueKey $new)) { $changed[[string]$ent.Key] = $new }
  }

  # 「大脑来源」是一层翻译：选完之后要落到 advisor / advisorFast 两条命令上。
  # 只在这一项**被改过**时才改写它们 —— 手改过命令的高级用户不会被悄悄覆盖。
  if ($changed.Keys -contains 'brainKind') {
    $derived = Resolve-DgBrainCommands -Kind ([string]$changed['brainKind'])
    if ($derived) {
      foreach ($k in $derived.Keys) {
        $old = if ($Ctx.Origin.Contains($k)) { $Ctx.Origin[$k] } else { $null }
        if ((Get-DgValueKey $old) -ne (Get-DgValueKey $derived[$k])) { $changed[$k] = $derived[$k] }
      }
      # 本地模型慢（尤其 CPU 上跑）：超时还停在 30 秒的话，第一次问它就会"超时当作没说"。
      # 换到 Ollama 时顺手把超时抬到 120（用户之后想改小随时可以在上面那行改）。
      if ([string]$changed['brainKind'] -eq 'ollama') {
        $curTimeout = if ($Ctx.Origin.Contains('advisorTimeoutSeconds')) { [int]$Ctx.Origin['advisorTimeoutSeconds'] } else { 30 }
        if ($curTimeout -lt 60) { $changed['advisorTimeoutSeconds'] = 120 }
      }
    }
  }

  if ($bad) {
    [void][System.Windows.Forms.MessageBox]::Show($bad.Why, '这个值填得不对', 'OK', 'Warning')
    $navIdx = [array]::IndexOf($Ctx.NavMap, $bad.Entry.Section)
    if ($navIdx -ge 0) { $Ctx.Nav.SelectedIndex = $navIdx }
    try { $bad.Entry.Ctl.Focus() } catch { }
    return $null
  }

  # agents.json 的改动（「和 DSH 同一个模型」那一行）：写它自己的文件，不进 config.json
  if ($agentChanged.Count -gt 0) {
    $agentsPath = if ($Ctx.StateRoot) { Join-Path $Ctx.StateRoot 'agents.json' } else { '' }
    foreach ($k in $agentChanged.Keys) {
      $okA = Set-DgAgentsField -Path $agentsPath -DottedKey $k -Value $agentChanged[$k]
      Write-Host ("agents.json: $k = $($agentChanged[$k])  →  $(if ($okA) { '已写入' } else { '**写入失败**' })（$agentsPath）")
    }
  }

  if ($Ctx.RegionCleared -and $null -ne $Ctx.Origin['region']) { $changed['region'] = $null }

  if ($Ctx.RuleSets -and $Ctx.RuleSets.Count -gt 0) {
    $rules = @()
    foreach ($r in $Ctx.RuleSets) { $rules += $r }
    if ((Get-DgValueKey $Ctx.Origin['taskRules']) -ne (Get-DgValueKey $rules)) { $changed['taskRules'] = $rules }
  }

  if ($changed.Count -eq 0) { return $changed }

  # 只覆盖改过的键：`_xxxNote` 那些说明和以后新加的键都不会被吃掉
  $all = [ordered]@{}
  foreach ($k in $Ctx.Origin.Keys) { $all[$k] = $Ctx.Origin[$k] }
  foreach ($k in $changed.Keys) { $all[$k] = $changed[$k] }
  $json = $all | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($Ctx.ConfigPath, ($json + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  return $changed
}

# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------
function Show-DgSettings {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [string]$Root = '',
    [double]$UiScale = 0,
    $OwnerForm = $null,
    [string]$RenderTo = '',
    [string]$Size = '',          # 逻辑尺寸 "宽x高"（自检 / 离屏渲染用；空 = 默认 920x700）
    [switch]$SelfTest
  )

  try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

  $Ctx = New-DgSettingsContext -ConfigPath $ConfigPath -Root $Root -UiScale $UiScale -RenderTo $RenderTo
  # 自检会把「副作用文件」写到状态根（run\openai.key、agents.json）。为了不碰用户真身，
  # 自检模式下把状态根换成一个临时目录，并把 agents.json 复制一份进去 —— 写入路径照样被走一遍。
  if ($SelfTest) {
    $sideHome = Join-Path ([System.IO.Path]::GetTempPath()) ('dgs-side-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $sideHome 'run'))
    foreach ($sideFile in @('agents.json', 'config.json')) {
      $src = Join-Path $Ctx.StateRoot $sideFile
      if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $sideHome $sideFile) -Force }
    }
    $Ctx.StateRoot = $sideHome
    Write-Host "自检用的临时状态根：$sideHome"
  }
  $s = [double]$Ctx.S
  $c = $Ctx.Colors
  $site = 'Microsoft YaHei UI'
  # ⚠️ 字号**不要**乘 $UiScale —— 这是踩过的坑，也是用户说的「字体太大、都堆起来了」的根。
  #
  # 点是物理单位：GDI+ 会自己按设备 DPI 把 pt 换成像素。192dpi（200% 缩放）下 9.5pt 已经是
  # 25px，行高约 32px —— 这**正是** Windows 缩放想要的效果（和 96dpi 下 12.7px 一样大）。
  # 再乘一次 uiScale 就变成 19pt / 50px / 行高 74px：字比正常大一倍，行高从 32 涨到 74，
  # 于是两行字挤在一行的高度里互相压住。
  #
  # （桌宠自己的气泡是反着补偿的：config 里 fontSize 写 6.0，乘 2 之后才约等于正常的 12pt。
  #   这里不跟进那个绕法 —— 窗口直接用"96dpi 视角"的字号，位置尺寸才乘 uiScale。）
  $Ctx.FontItem = New-Object System.Drawing.Font $site, ([float]9.5)
  $Ctx.FontItemBold = New-Object System.Drawing.Font $site, ([float]9.5), ([System.Drawing.FontStyle]::Bold)
  $Ctx.FontSmall = New-Object System.Drawing.Font $site, ([float]9.0)
  $Ctx.FontH1 = New-Object System.Drawing.Font $site, ([float]12.0), ([System.Drawing.FontStyle]::Bold)
  # 行高用 **Label 自己的 PreferredHeight**，不用 TextRenderer.MeasureText：
  # 实测 19pt 下后者给 66、Label 实到 74 —— 按 66 设高度会把字裁掉、并且和下一行贴在一起。
  # 行高本来就是像素值，所以也不乘 $s。
  $Ctx.HMain = Get-DgLineHeight -Font $Ctx.FontItemBold
  $Ctx.HSmall = Get-DgLineHeight -Font $Ctx.FontSmall
  $Ctx.HH1 = Get-DgLineHeight -Font $Ctx.FontH1
  $Ctx.RowTop0 = [int](14 * $s) + [int]$Ctx.HH1 + [int](6 * $s) + (2 * [int]$Ctx.HSmall) + [int](10 * $s)

  $W = [int](920 * $s); $H = [int](700 * $s)
  if ($Size -match '^\s*(\d+)\s*[x×X]\s*(\d+)\s*$') {
    $W = [int]([int]$Matches[1] * $s); $H = [int]([int]$Matches[2] * $s)
  }
  $f = New-Object System.Windows.Forms.Form
  $f.Text = '泡泡 · 设置'
  $f.Font = $Ctx.FontItem
  $f.BackColor = $c.Bg
  $f.ForeColor = $c.Text
  # ⚠️ 必须关掉自动缩放。Form.AutoScaleMode 默认是 Font，而这里所有尺寸/字体**已经**乘过
  # $UiScale 了 —— 不关的话 WinForms 会按"设计字体 vs 当前字体"再放大一次（本文 9.5pt→19pt
  # 差不多又是一倍），控件被挤出各自行面板的裁剪区：实测标签整列消失、数字框看不见。
  $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $f.ClientSize = New-Object System.Drawing.Size $W, $H
  $f.MinimumSize = New-Object System.Drawing.Size ([int](820 * $s)), ([int](560 * $s))
  $f.StartPosition = 'CenterScreen'
  $f.ShowInTaskbar = $true
  $f.MaximizeBox = $true
  $Ctx.Form = $f

  $title = New-Object System.Windows.Forms.Label
  $title.Text = '设置'
  # ⚠️ 字号**不要**乘 $s：pt 是物理单位，GDI+ 会自己按设备 DPI 换算。乘了之后 200% 缩放下
  # 变成 30pt（一行近 40px），而高度还写死 30px —— 结果是标题被**拦腰裁掉**（用户截图里那个"设置"）。
  # 标题比正文大一档：正文 9.5pt，这里 15pt（和分组标题 12pt 拉开层次）。
  $title.Font = New-Object System.Drawing.Font $site, ([float]15.0), ([System.Drawing.FontStyle]::Bold)
  $title.ForeColor = $c.Text
  $title.AutoSize = $false
  # 高度按**字体实际行高**算，不写死数字（行高是像素量，不乘 $s）
  $title.Height = Get-DgLineHeight -Font $title.Font
  $title.Left = [int](24 * $s); $title.Top = [int](14 * $s); $title.Width = [int](260 * $s)
  $f.Controls.Add($title)
  $Ctx.Title = $title

  $navW = [int](208 * $s)
  $nav = New-Object System.Windows.Forms.ListBox
  $nav.Left = [int](24 * $s); $nav.Top = [int](84 * $s)
  $nav.Width = $navW; $nav.Height = [int](496 * $s)
  $nav.BorderStyle = 'None'
  $nav.BackColor = $c.Nav
  $nav.ForeColor = $c.Text
  $nav.Font = $Ctx.FontItem
  # 导航项高跟着字体走：字变小了还留 32 逻辑 px 会空得发虚，字变大又会裁
  $nav.ItemHeight = [int]$Ctx.HMain + [int](10 * $s)
  $nav.DrawMode = 'OwnerDrawFixed'
  $nav.IntegralHeight = $false
  $nav.Tag = $Ctx
  $Ctx.Nav = $nav
  $f.Controls.Add($nav)

  # 注意用 Add_DrawItem 而不是 `$nav.DrawItem += {…}` —— 后者在 PowerShell 里挂不上
  # （赋值给事件属性会被当普通属性写入，报 "property 'DrawItem' cannot be found"），
  # 结果是自绘静默失效、导航退回系统默认样式。这个仓库其它地方也都是 Add_ 形式。
  $nav.Add_DrawItem({
    param($sender, $e)
    if ($e.Index -lt 0) { return }
    $ctx = $sender.Tag
    $col = $ctx.Colors
    $sel = ($sender.SelectedIndex -eq $e.Index)
    $hot = ($ctx.Hover -eq $e.Index)
    $back = if ($sel) { $col.NavSel } elseif ($hot) { $col.NavHot } else { $col.Nav }
    $br = New-Object System.Drawing.SolidBrush $back
    try { $e.Graphics.FillRectangle($br, $e.Bounds) } finally { $br.Dispose() }
    if ($sel) {
      $ab = New-Object System.Drawing.SolidBrush $col.Accent
      try {
        $barRect = [System.Drawing.Rectangle]::new($e.Bounds.Left, ($e.Bounds.Top + 4), 3, ($e.Bounds.Height - 8))
        $e.Graphics.FillRectangle($ab, $barRect)
      } finally { $ab.Dispose() }
    }
    $txt = [string]$sender.Items[$e.Index]
    $flags = [System.Windows.Forms.TextFormatFlags]([System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis)
    $rect = [System.Drawing.Rectangle]::new(($e.Bounds.Left + 16), $e.Bounds.Top, ($e.Bounds.Width - 24), $e.Bounds.Height)
    $fg = if ($sel) { $col.Accent } else { $col.Text }
      [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $txt, $ctx.FontItem, $rect, $fg, $flags)
    })
  $nav.Add_MouseMove({
      param($sender, $e)
      $idx = $sender.IndexFromPoint($e.Location)
      if ($idx -ne $sender.Tag.Hover) { $sender.Tag.Hover = $idx; $sender.Invalidate() }
    })
  $nav.Add_MouseLeave({ param($sender, $e) $sender.Tag.Hover = -1; $sender.Invalidate() })
  $nav.Add_SelectedIndexChanged({
      param($sender, $e)
      $ctx = $sender.Tag
      $i = [int]$sender.SelectedIndex
      if ($i -lt 0 -or $i -ge $ctx.NavMap.Count) { return }
      Set-DgSection -Ctx $ctx -Index ([int]$ctx.NavMap[$i])
    })

  # 搜索框：拿 label 当占位提示（原生 PlaceholderText 一获得焦点就不画了，这个仓库踩过）
  $search = New-Object System.Windows.Forms.TextBox
  $search.Font = $Ctx.FontItem
  $search.BorderStyle = 'FixedSingle'
  $search.Left = [int](($W - 24 * $s) - (264 * $s)); $search.Top = [int](22 * $s)
  $search.Width = [int](264 * $s)
  $f.Controls.Add($search)
  $Ctx.Search = $search
  $shint = New-Object System.Windows.Forms.Label
  $shint.Text = '搜参数（例如 采样、token、秒）'
  $shint.Font = $Ctx.FontItem
  $shint.ForeColor = $c.Muted
  $shint.BackColor = [System.Drawing.Color]::White
  $shint.TextAlign = 'MiddleLeft'
  $shint.AutoEllipsis = $true
  $shint.Cursor = 'IBeam'
  $shint.Left = $search.Left + 3; $shint.Top = $search.Top + 3
  $shint.Width = $search.Width - 6; $shint.Height = $search.Height - 6
  $f.Controls.Add($shint)
  $Ctx.SearchHint = $shint
  $shint.BringToFront()
  $shint.Tag = $search
  $shint.Add_Click({ param($sender, $e) try { $sender.Tag.Focus() } catch { } })
  $search.Add_TextChanged({
      param($sender, $e)
      $ctx = $sender.Parent.Tag
      $ctx.Filter = [string]$sender.Text
      if ($ctx.SearchHint) { $ctx.SearchHint.Visible = [string]::IsNullOrEmpty($sender.Text) }
      Apply-DgFilter -Ctx $ctx
    })
  $f.Tag = $Ctx

  $card = New-Object System.Windows.Forms.Panel
  # ⚠ 这里是 `24`，不是 `$24` —— `$24` 会被 PowerShell 当成"变量 $2 后面跟个 4"，
  # 求值成 0，于是卡片整体左移 16 逻辑 px，被压在导航列表底下（用户截图里的遮挡就是这么来的）。
  $card.Left = [int]((24 + 208 + 16) * $s); $card.Top = [int](84 * $s)
  $card.Width = $W - $card.Left - [int](24 * $s)
  $card.Height = [int](496 * $s)
  $card.BackColor = $c.Card
  $card.BorderStyle = 'FixedSingle'
  $Ctx.Card = $card
  $f.Controls.Add($card)

  for ($i = 0; $i -lt $Ctx.Sections.Count; $i++) { [void](New-DgSectionPanel -Ctx $Ctx -Index $i) }
  Update-DgNav -Ctx $Ctx
  if ($nav.Items.Count -gt 0) { $nav.SelectedIndex = 0 }

  $helpBar = New-Object System.Windows.Forms.Label
  $helpBar.Text = ''
  $helpBar.Font = $Ctx.FontSmall
  $helpBar.ForeColor = $c.Muted
  $helpBar.AutoSize = $false
  $helpBar.Left = [int](24 * $s); $helpBar.Top = [int](594 * $s)
  $helpBar.Width = [int](($W - 48 * $s)); $helpBar.Height = 2 * [int]$Ctx.HSmall
  $f.Controls.Add($helpBar)
  $Ctx.HelpBar = $helpBar

  # 底栏和卡片之间拉一条分隔线：不然说明文字紧贴卡片下沿，看着像溢出来的
  $sep = New-Object System.Windows.Forms.Panel
  $sep.BackColor = $c.Line
  $sep.Left = [int](24 * $s); $sep.Top = [int](588 * $s)
  $sep.Width = [int](($W - 48 * $s)); $sep.Height = 1
  $f.Controls.Add($sep)
  $Ctx.Sep = $sep

  Show-DgHelp -Ctx $Ctx -Entry $null -Note '提示：改完点「保存」。不确定某一项是干嘛的，把鼠标停在那一行上。'

  $openBtn = New-Object System.Windows.Forms.Button
  $openBtn.Text = '打开配置文件'
  $openBtn.FlatStyle = 'Flat'
  $openBtn.Font = $Ctx.FontItem
  $openBtn.Width = [int](120 * $s); $openBtn.Height = [int](34 * $s)
  $openBtn.Left = [int](($W - 24 * $s) - (120 + 100 + 100 + 20 + 16) * $s); $openBtn.Top = [int](640 * $s)
  $openBtn.Add_Click({ param($sender, $e) Start-Process 'notepad.exe' -ArgumentList ('"' + $sender.Tag + '"') })
  $openBtn.Tag = $ConfigPath
  $f.Controls.Add($openBtn)
  $Ctx.OpenBtn = $openBtn

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = '取消'
  $cancel.FlatStyle = 'Flat'
  $cancel.Font = $Ctx.FontItem
  $cancel.Width = [int](100 * $s); $cancel.Height = [int](34 * $s)
  $cancel.Left = [int](($W - 24 * $s) - (100 + 100 + 10) * $s); $cancel.Top = [int](640 * $s)
  $cancel.DialogResult = 'Cancel'
  $f.Controls.Add($cancel)
  $Ctx.CancelBtn = $cancel

  $save = New-Object System.Windows.Forms.Button
  $save.Text = '保存'
  $save.FlatStyle = 'Flat'
  $save.UseVisualStyleBackColor = $false
  $save.BackColor = $c.Accent
  $save.ForeColor = [System.Drawing.Color]::White
  $save.FlatAppearance.BorderSize = 0
  $save.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 66, 130, 246)
  $save.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(255, 33, 92, 205)
  $save.Font = $Ctx.FontItem
  $save.Width = [int](100 * $s); $save.Height = [int](34 * $s)
  $save.Left = [int](($W - 24 * $s) - 100 * $s); $save.Top = [int](640 * $s)
  $save.Add_Click({
      param($sender, $e)
      $ctx = $sender.Parent.Tag
      $res = Save-DgSettings -Ctx $ctx
      if ($null -eq $res) { return }    # 校验没过，停在这个窗口里
      $ctx.Result = $res
      $ctx.Form.DialogResult = 'OK'
      $ctx.Form.Close()
    })
  $f.Controls.Add($save)
  $Ctx.SaveBtn = $save
  $f.AcceptButton = $save
  $f.CancelButton = $cancel

  # 构建完了：按**实际客户区**排一遍版，并挂上 resize —— 最大化/拖边框时内容跟着长大，
  # 而不是停在 920×700 的设计尺寸上（用户截图里的"最大化但内容范围不变"）。
  $Ctx.LayoutReady = $true
  Update-DgLayout -Ctx $Ctx
  $f.Add_Resize({ param($sender, $e) try { Update-DgLayout -Ctx $sender.Tag } catch { } })

  # ---- 自检 / 渲染：都不弹窗 ----
  if ($RenderTo -or $SelfTest) {
    if ($RenderTo -and -not (Test-Path -LiteralPath $RenderTo)) { New-Item -ItemType Directory -Force -Path $RenderTo | Out-Null }
    $f.ShowInTaskbar = $false
    $f.StartPosition = 'Manual'
    $f.Location = New-Object System.Drawing.Point -4000, -4000
    $f.Show()
    [System.Windows.Forms.Application]::DoEvents()
    # 机械自检：每个控件必须**真的**被加进了行里，而且落在行的范围内。
    # 为什么要有这一步：忘了 Controls.Add 时，控件照样有正确的 Bounds 和 Visible，
    # 代码读起来完全正常，但界面上那一列根本不存在（数字框整列消失，实测踩过）。
    $bad = @()
    foreach ($ent in $Ctx.Rows) {
      if (-not $ent.Row.Controls.Contains($ent.Ctl)) { $bad += "$($ent.Key)：控件没加进行里"; continue }
      if (-not $ent.Row.Controls.Contains($ent.Label)) { $bad += "$($ent.Key)：标签没加进行里" }
      # 单位 / 状态那类附加标签也必须在行里 —— 只赋值不 Controls.Add 的话，
      # 代码读起来完全正常、界面上却整块不画（key 行的"已配置"状态就这么漏过一次）
      if ($ent.UnitCtl -and -not $ent.Row.Controls.Contains($ent.UnitCtl)) { $bad += "$($ent.Key)：附加标签没加进行里" }
      if ($ent.Ctl.Right -gt $ent.Row.Width -or $ent.Ctl.Bottom -gt $ent.Row.Height) { $bad += "$($ent.Key)：控件超出行的范围" }
      if ($ent.Label.Bottom -gt $ent.Row.Height) { $bad += "$($ent.Key)：标签超出行的范围" }
      # 行里**每一个**控件（含单位标签、浏览按钮）都不能探出行的右边界 ——
      # 探出去就会让整个面板长出横向滚动条，一滚动左边标签就被切（用户报的排版遮挡就是这么来的）。
      foreach ($ch in $ent.Row.Controls) {
        if ($ch.Right -gt $ent.Row.Width + 1) { $bad += "$($ent.Key)：$($ch.GetType().Name) 探出行右边界（$($ch.Right) > $($ent.Row.Width)）" }
      }
    }
    if ($bad.Count -gt 0) { Write-Host ('自检发现问题：' + ($bad -join '；')) }
    else { Write-Host ("自检：{0} 行全部就位（控件已加入行内、未越界）" -f $Ctx.Rows.Count) }

    # ---- 缩放检查：把窗口按几种尺寸摆一遍，每种都做一次边界检查 ----
    # 这一段防的是"设计尺寸下没问题、最大化/缩到最小就散架"——用户报的遮挡正是这一类。
    $sizeCases = @(@(820, 560), @(920, 700), @(1180, 800), @(1400, 900))
    foreach ($sc in $sizeCases) {
      $f.ClientSize = New-Object System.Drawing.Size ([int]($sc[0] * $s)), ([int]($sc[1] * $s))
      [System.Windows.Forms.Application]::DoEvents()
      Update-DgLayout -Ctx $Ctx
      [System.Windows.Forms.Application]::DoEvents()
      $probs = @()
      # 内容不许压到导航下面、不许探出卡片、行内控件不许探出行右边界
      $navRight = $Ctx.Nav.Left + $Ctx.Nav.Width
      if ($Ctx.Card.Left -lt ($navRight + 4)) { $probs += "卡片压到导航底下（card.Left=$($Ctx.Card.Left) ≤ nav.Right=$navRight）" }
      foreach ($ent in $Ctx.Rows) {
        if ($ent.Row.Left + $ent.Row.Width -gt $Ctx.Card.ClientSize.Width) { $probs += "$($ent.Key)：行探出卡片" }
        foreach ($ch in $ent.Row.Controls) {
          if ($ch.Right -gt $ent.Row.Width + 1) { $probs += "$($ent.Key)：$($ch.GetType().Name) 探出行右边界（$($ch.Right) > $($ent.Row.Width)）" }
        }
      }
      if ($probs.Count -gt 0) { Write-Host ("缩放检查 {0}x{1}：问题 —— {2}" -f $sc[0], $sc[1], ($probs -join '；')) }
      else { Write-Host ("缩放检查 {0}x{1}：OK（内容跟着窗口长，未越界）" -f $sc[0], $sc[1]) }
    }
    # 还原成进来的尺寸，后面还要按这个尺寸渲染出图
    $f.ClientSize = New-Object System.Drawing.Size $W, $H
    [System.Windows.Forms.Application]::DoEvents()
    Update-DgLayout -Ctx $Ctx
    [System.Windows.Forms.Application]::DoEvents()

    # ---- 搜索过滤：过滤后要重排（不能留空洞），也不能把行排出卡片 ----
    try {
      $Ctx.Filter = '秒'
      Apply-DgFilter -Ctx $Ctx
      [System.Windows.Forms.Application]::DoEvents()
      $vis = @($Ctx.Rows | Where-Object { $_.Row.Visible }).Count
      $fprobs = @()
      foreach ($ent in $Ctx.Rows) {
        if (-not $ent.Row.Visible) { continue }
        if ($ent.Row.Left + $ent.Row.Width -gt $Ctx.Card.ClientSize.Width) { $fprobs += "$($ent.Key)：行探出卡片" }
        foreach ($ch in $ent.Row.Controls) {
          if ($ch.Right -gt $ent.Row.Width + 1) { $fprobs += "$($ent.Key)：控件探出行右边界" }
        }
      }
      if ($fprobs.Count -gt 0) { Write-Host ("搜索过滤：问题 —— " + ($fprobs -join '；')) }
      else { Write-Host ("搜索过滤：'秒' 命中 {0} / {1} 行，重排后未越界 ✅" -f $vis, $Ctx.Rows.Count) }
      $Ctx.Filter = ''
      Apply-DgFilter -Ctx $Ctx
      [System.Windows.Forms.Application]::DoEvents()
    } catch { Write-Host ("搜索过滤自检异常：" + $_.Exception.Message) }

    # 存盘往返测试。这一段测的是**最危险**的部分：它会重写用户的 config.json。
    # 两条断言：(1) 没改任何东西 → 文件必须一个字节都不动；(2) 改一个开关 → 只该动那一个键，
    # `_xxxNote` 那些说明和别的键必须原样还在。
    if ($SelfTest) {
      $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dgs-selftest-' + [guid]::NewGuid().ToString('N') + '.json')
      $origPath = $Ctx.ConfigPath
      try {
        Copy-Item -LiteralPath $origPath -Destination $tmp -Force
        $Ctx.ConfigPath = $tmp

        $before = [System.IO.File]::ReadAllText($tmp)
        $noop = Save-DgSettings -Ctx $Ctx
        $after = [System.IO.File]::ReadAllText($tmp)
        if ($noop.Count -eq 0 -and $before -eq $after) { Write-Host '存盘自检：没改动时文件字节不变 ✅' }
        else { Write-Host ("存盘自检：**没改动却动了文件**（返回 {0} 项）❌" -f $noop.Count) }

        $flip = $Ctx.Rows | Where-Object { $_.Kind -eq 'bool' } | Select-Object -First 1
        if ($flip) {
          $flip.Ctl.Checked = -not $flip.Ctl.Checked
          $expect = [bool]$flip.Ctl.Checked      # 刚翻过，期望值就是翻转后的这个
          $res = Save-DgSettings -Ctx $Ctx
          $parsed = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
          $ok = ($res.Keys -contains $flip.Key)
          $round = [bool]$parsed.($flip.Key)
          $keepNotes = @($parsed.PSObject.Properties.Name | Where-Object { $_ -like '_*Note' }).Count
          $origNotes = @($Ctx.Origin.Keys | Where-Object { $_ -like '_*Note' }).Count
          Write-Host ("存盘自检：改 {0} → 返回 {1} 项、落盘值 {2}、_note 保留 {3}/{4}" -f $flip.Key, $res.Count, $round, $keepNotes, $origNotes)
          if ($ok -and ($round -eq $expect) -and $res.Count -eq 1 -and $keepNotes -eq $origNotes) { Write-Host '存盘自检：通过 ✅' }
          else { Write-Host '存盘自检：**不通过** ❌' }
        }

        # 换大脑：选「本地 Ollama」应当把 advisor / advisorFast 两条命令一起改写
        # （这是"一个下拉换大脑"的核心一步，写错就等于选了不生效）
        $bk = $Ctx.Rows | Where-Object { $_.Key -eq 'brainKind' } | Select-Object -First 1
        if ($bk -and $bk.Ctl) {
          $bkIdx = -1
          for ($bi = 0; $bi -lt $bk.Choices.Count; $bi++) {
            if ([string]$bk.Choices[$bi].Value -eq 'ollama') { $bkIdx = $bi; break }
          }
          if ($bkIdx -ge 0) {
            $bk.Ctl.SelectedIndex = $bkIdx
            [void](Save-DgSettings -Ctx $Ctx)
            $p2 = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
            $advName = if ([string]$p2.advisor -match 'advisor-([a-z]+)\.ps1') { $Matches[1] } else { '?' }
            $fastName = if ([string]$p2.advisorFast -match 'advisor-([a-z]+)\.ps1') { $Matches[1] } else { '?' }
            $brainOk = ([string]$p2.brainKind -eq 'ollama') -and $advName -eq 'ollama' -and $fastName -eq 'ollama'
            Write-Host ("换大脑自检：选 ollama → brainKind={0}、advisor={1}、advisorFast={2}  {3}" -f $p2.brainKind, $advName, $fastName, $(if ($brainOk) { '通过 ✅' } else { '**不通过** ❌' }))
            # 还原成 dsh，免得后面渲染 / 别的断言看到"半截状态"
            for ($bi = 0; $bi -lt $bk.Choices.Count; $bi++) {
              if ([string]$bk.Choices[$bi].Value -eq 'dsh') { $bk.Ctl.SelectedIndex = $bi; break }
            }
            [void](Save-DgSettings -Ctx $Ctx)
          }
        }

        # 网络模型的 key：不进 config.json，只写 run\openai.key（这里写的是临时状态根）
        $keyEnt = $Ctx.Rows | Where-Object { $_.Key -eq 'openaiKey' } | Select-Object -First 1
        if ($keyEnt -and $keyEnt.Ctl -and $keyEnt.Btn) {
          # PerformClick 只对**可见**的控件生效（Button.PerformClick → CanSelect）。
          # 这行在「大脑与任务」页里，先切到那一页再点，否则点了等于没点（自检会误报失败）。
          $brainSecIdx = -1
          for ($bi2 = 0; $bi2 -lt $Ctx.Sections.Count; $bi2++) {
            if ($Ctx.Sections[$bi2].Name -eq '大脑与任务') { $brainSecIdx = $bi2; break }
          }
          $navWant = [array]::IndexOf($Ctx.NavMap, $brainSecIdx)
          if ($navWant -ge 0) { $Ctx.Nav.SelectedIndex = $navWant; [System.Windows.Forms.Application]::DoEvents() }
          $keyFile = Join-Path (Join-Path $Ctx.StateRoot 'run') 'openai.key'
          $keyEnt.Ctl.Text = 'sk-selftest-1234567890'
          $keyEnt.Btn.PerformClick()
          $wrote = (Test-Path -LiteralPath $keyFile) -and ((Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8) -eq 'sk-selftest-1234567890')
          $cfgHasKey = @((Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name) -contains 'openaiKey'
          # 再清一次：留空点写入 = 删掉 key 文件
          $keyEnt.Ctl.Text = ''
          $keyEnt.Btn.PerformClick()
          $cleared = -not (Test-Path -LiteralPath $keyFile)
          Write-Host ("key 自检：写入 run\openai.key = {0}｜没进 config.json = {1}｜留空再点写入会删掉 = {2}  {3}" -f `
              $wrote, (-not $cfgHasKey), $cleared, $(if ($wrote -and -not $cfgHasKey -and $cleared) { '通过 ✅' } else { '**不通过** ❌' }))
        }

        # 「和 DSH 同一个模型」那一行写的是 agents.json（不是 config.json）
        $dshEnt = $Ctx.Rows | Where-Object { $_.Key -eq '_dshModel' } | Select-Object -First 1
        if ($dshEnt -and $dshEnt.Ctl -and $dshEnt.Choices.Count -gt 1) {
          $agentsTmp = Join-Path $Ctx.StateRoot 'agents.json'
          $beforeModel = [string]$dshEnt.Item.AgentDef
          $pick = @($dshEnt.Choices | Where-Object { [string]$_.Value -ne $beforeModel } | Select-Object -First 1)
          if ($pick.Count -gt 0) {
            for ($di = 0; $di -lt $dshEnt.Choices.Count; $di++) {
              if ([string]$dshEnt.Choices[$di].Value -eq [string]$pick[0].Value) { $dshEnt.Ctl.SelectedIndex = $di; break }
            }
            [void](Save-DgSettings -Ctx $Ctx)
            $dshNow = [string]((Get-Content -LiteralPath $agentsTmp -Raw -Encoding UTF8 | ConvertFrom-Json).mainAgent.model)
            $okDsh = ($dshNow -eq [string]$pick[0].Value)
            Write-Host ("DSH 模型自检：agents.json mainAgent.model = {0}（期望 {1}）  {2}" -f $dshNow, $pick[0].Value, $(if ($okDsh) { '通过 ✅' } else { '**不通过** ❌' }))
            # 还原
            for ($di = 0; $di -lt $dshEnt.Choices.Count; $di++) {
              if ([string]$dshEnt.Choices[$di].Value -eq $beforeModel) { $dshEnt.Ctl.SelectedIndex = $di; break }
            }
            [void](Save-DgSettings -Ctx $Ctx)
          }
        }
      } catch {
        Write-Host ("存盘自检：异常 —— " + $_.Exception.Message)
      } finally {
        $Ctx.ConfigPath = $origPath
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      }
    }

    $shots = @()
    for ($i = 0; $RenderTo -and $i -lt $Ctx.Sections.Count; $i++) {
      $want = [array]::IndexOf($Ctx.NavMap, $i)
      if ($want -lt 0) { continue }
      $nav.SelectedIndex = $want
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 60
      [System.Windows.Forms.Application]::DoEvents()
      $bmp = New-Object System.Drawing.Bitmap $f.Width, $f.Height
      $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $f.Width, $f.Height))
      $file = Join-Path $RenderTo ("settings-{0:00}-{1}.png" -f $i, ($Ctx.Sections[$i].Name -replace '[\\/:*?"<>|]', '_'))
      $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
      $shots += $file
    }
    $f.Close()
    $f.Dispose()
    return [pscustomobject]@{ Rendered = $shots; Rows = $Ctx.Rows.Count; Values = ([ordered]@{}) }
  }

  if ($OwnerForm) {
    $f.TopMost = $false
    $r = $f.ShowDialog($OwnerForm)
  } else {
    $r = $f.ShowDialog()
  }
  $result = $null
  if ($r -eq [System.Windows.Forms.DialogResult]::OK -and $Ctx.Result) { $result = $Ctx.Result }
  $f.Dispose()
  return $result
}

# 直接运行本文件（pwsh -File settings-window.ps1）时自动开窗；被 Dot-Source 时不自作主张。
if ($MyInvocation.InvocationName -ne '.') {
  $cfgPath = if ($DgsConfig) { $DgsConfig } else { Join-Path $PSScriptRoot 'config.json' }
  $out = Show-DgSettings -ConfigPath $cfgPath -Root $PSScriptRoot -UiScale $DgsUiScale -RenderTo $DgsRenderTo -Size $DgsSize -SelfTest:$DgsSelfTest
  if ($DgsSelfTest) {
    # 自检报告上面已经逐条打过了（而且它没碰真正的 config.json）
    exit 0
  } elseif ($DgsRenderTo) {
    if ($out) { Write-Output ("已渲染 {0} 张：{1}" -f $out.Rendered.Count, ($out.Rendered -join '; ')) }
  } elseif ($out) {
    Write-Output ("已保存 {0} 项：{1}" -f $out.Count, (($out.Keys) -join ', '))
  } else {
    Write-Output '已取消（config.json 没动）'
  }
}
