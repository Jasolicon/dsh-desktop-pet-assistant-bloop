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
  [double]$DgsUiScale = 0
)

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# schema：分组 → 参数
#
# Kind：bool | int | number | text | choice | path | multiline | info（info = 只显示不可改，原值保留）
# 其它字段：Min/Max/Step/Decimals（数字）、Choices（选择）、Pattern/PatternTip（文本校验）、
#           Def（仓库里带的那份 config.json 的值，也就是「恢复默认」的目标）、
#           Late（需要重启 / 下次才生效的提示，会贴在说明后面）
# ---------------------------------------------------------------------------
function Get-DgSettingsSchema {
  param([string]$Root = '', [string[]]$ModelNames = @())

  $modelChoices = @([pscustomobject]@{ Value = ''; Text = '（跟 agents.json 的第一个一致）' })
  foreach ($m in $ModelNames) { $modelChoices += [pscustomobject]@{ Value = $m; Text = $m } }

  $effortChoices = @(
    [pscustomobject]@{ Value = ''; Text = '（跟 agents.json 一致）' }
    [pscustomobject]@{ Value = 'low'; Text = 'low —— 最快，够用' }
    [pscustomobject]@{ Value = 'high'; Text = 'high —— 默认' }
    [pscustomobject]@{ Value = 'max'; Text = 'max —— 最慢最贵' }
  )

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
         )
         Help='决定 presets\ 下哪份 system prompt 生效。保守 = 只在明显的问题、反复失败、或与目标冲突时开口。' }
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
    )
  })

  [void]$sections.Add([pscustomobject]@{
    Name = '大脑与任务'
    Note = '自动判断、手动问一句、语音派活分别用哪条命令 / 哪个模型。'
    Items = @(
      @{ Key='advisor'; Label='常驻大脑命令'; Kind='text'; Def='pwsh -NoProfile -ExecutionPolicy Bypass -File "{root}\advisor-dsh.ps1"'
         Help='自动判断用的大脑（有记忆、但慢）。命令末尾会自动追加 payload.json 的路径，它把要说的话打到 stdout。可用占位符：{root} {dshRoot} {userProfile} {dshHome}。' }
      @{ Key='advisorFast'; Label='「问一句」命令'; Kind='text'; Def='pwsh -NoProfile -ExecutionPolicy Bypass -File "{root}\advisor-openai.ps1"'
         Help='手动「现在说一句」走的快通路（一次性调用，3-4 秒）。换大脑只改这两行。' }
      @{ Key='advisorTimeoutSeconds'; Label='大脑超时'; Kind='number'; Min=5; Max=600; Step=5; Decimals=0; Def=30; Unit='秒'
         Help='一次调用最多等多久，超了就当作这轮没结果。' }
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
function New-DgSettingsContext {
  param([string]$ConfigPath, [string]$Root = '', [double]$UiScale = 0, [string]$RenderTo = '')

  if (-not $Root) { $Root = $PSScriptRoot }
  if ($UiScale -le 0) {
    try {
      $g = [System.Drawing.Graphics]::FromHwnd([intptr]::Zero)
      $UiScale = [Math]::Max(1.0, [double]$g.DpiX / 96.0)
      $g.Dispose()
    } catch { $UiScale = 1.0 }
  }

  $origin = [ordered]@{}
  if (Test-Path -LiteralPath $ConfigPath) {
    try {
      $loaded = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $loaded.PSObject.Properties) { $origin[$p.Name] = $p.Value }
    } catch { }
  }

  $modelNames = @()
  $agentsFile = Join-Path $Root 'agents.json'
  if (Test-Path -LiteralPath $agentsFile) {
    try { $modelNames = @((Get-Content -LiteralPath $agentsFile -Raw -Encoding UTF8 | ConvertFrom-Json).models | ForEach-Object { [string]$_.name }) } catch { }
  }

  return @{
    S              = $UiScale
    ConfigPath     = $ConfigPath
    Root           = $Root
    RenderTo       = $RenderTo
    Origin         = $origin
    Sections       = (Get-DgSettingsSchema -Root $Root -ModelNames $modelNames)
    Rows           = (New-Object System.Collections.ArrayList)   # 每行：Key/Kind/Ctl/Get/Section/Row/Panel/Item
    Form           = $null
    Nav            = $null
    Card           = $null
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
  $labelW = [int](300 * $s)
  $ctlX = $Indent + $labelW
  $ctlW = [int]($Width - $ctlX - 18 * $s)
  $multiline = ($Item.Kind -eq 'multiline')
  # 行高由**实测行高**算出来，不写死数字：19pt 字体在高 DPI 下比 "18*s" 高得多，写死会把字裁掉。
  $rowH = if ($multiline) { [int](92 * $s) } else { [int](8 * $s) + [int]$Ctx.HMain + [int]$Ctx.HSmall }

  $row = New-Object System.Windows.Forms.Panel
  $row.Left = $Indent; $row.Top = $Top; $row.Width = $Width; $row.Height = $rowH
  # 用不透明底色，**不要** Transparent：透明控件的绘制要靠父级先画背景，在
  # DrawToBitmap / WM_PRINT 那条路径下会变成"子控件被擦掉"（实测标签整列不见）。
  $row.BackColor = $c.Card

  $lbl = New-Object System.Windows.Forms.Label
  $lblTextW = $labelW - [int](14 * $s)
  $lbl.Text = Limit-DgText -Text ([string]$Item.Label) -Font $Ctx.FontItemBold -MaxWidth $lblTextW
  $lbl.AutoSize = $false
  $lbl.Font = $Ctx.FontItemBold
  $lbl.ForeColor = $c.Text
  $lbl.BackColor = $c.Card
  $lbl.Left = 0; $lbl.Top = [int](4 * $s); $lbl.Width = $labelW - [int](14 * $s); $lbl.Height = [int]$Ctx.HMain
  # ⚠️ 别开 AutoEllipsis：它会把 Label 切到另一条绘制路径，WM_PRINT / DrawToBitmap 下
  # **整块都不画**（实测标签列整个消失）。行内说明本来就只是提示，过长就让它硬裁，
  # 完整说明在底部那条（鼠标停上去就有）。
  $lbl.AutoEllipsis = $false

  $help = New-Object System.Windows.Forms.Label
  $help.Text = Limit-DgText -Text ([string]$Item.Help) -Font $Ctx.FontSmall -MaxWidth $lblTextW
  $help.AutoSize = $false
  $help.Font = $Ctx.FontSmall
  $help.ForeColor = $c.Muted
  $help.BackColor = $c.Card
  $help.Left = 0; $help.Top = [int](4 * $s) + [int]$Ctx.HMain; $help.Width = $labelW - [int](14 * $s); $help.Height = [int]$Ctx.HSmall
  $help.AutoEllipsis = $false

  $row.Controls.Add($lbl)
  $row.Controls.Add($help)

  $entry = @{
    Key = [string]$Item.Key; Kind = [string]$Item.Kind; Item = $Item
    Section = $Section; Row = $row; Label = $lbl; Help = $help; Ctl = $null; Get = $null; Choices = $null
  }

  $cur = Get-DgItemValue -Ctx $Ctx -Item $Item
  $ctlTop = [int](9 * $s)

  switch ([string]$Item.Kind) {
    'bool' {
      $chk = New-Object System.Windows.Forms.CheckBox
      $chk.Text = ''
      $chk.Checked = [bool]$cur
      $chk.Left = $ctlX; $chk.Top = $ctlTop; $chk.Width = [int](24 * $s); $chk.Height = [int](22 * $s)
      $chk.FlatStyle = 'Standard'
      $entry.Ctl = $chk
      $entry.Get = { param($ctl, $ent) return [bool]$ctl.Checked }
      $row.Controls.Add($chk)
    }
    'int' {
      $n = New-DgNumeric -Ctx $Ctx -Item $Item -Value $cur -CtlX $ctlX -CtlTop $ctlTop -Width $ctlW
      $n.DecimalPlaces = 0
      $entry.Ctl = $n
      $entry.Get = { param($ctl, $ent) return [int]$ctl.Value }
      $row.Controls.Add($n)
    }
    'number' {
      $n = New-DgNumeric -Ctx $Ctx -Item $Item -Value $cur -CtlX $ctlX -CtlTop $ctlTop -Width $ctlW
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
      $cb.Left = $ctlX; $cb.Top = $ctlTop
      $cb.Width = [int]([Math]::Max(180 * $s, [Math]::Min($ctlW, 320 * $s)))
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
      $box.Left = $ctlX; $box.Top = $ctlTop; $box.Width = $ctlW - $btnW - [int](8 * $s)
      $b = New-Object System.Windows.Forms.Button
      $b.Text = '浏览…'
      $b.FlatStyle = 'Flat'
      $b.Font = $Ctx.FontSmall
      $b.Left = $ctlX + $ctlW - $btnW; $b.Top = $ctlTop - [int](1 * $s); $b.Width = $btnW; $b.Height = [int](24 * $s)
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
      $entry.Get = { param($ctl, $ent) return [string]$ctl.Text }
    }
    'multiline' {
      $box = New-Object System.Windows.Forms.TextBox
      $box.Font = $Ctx.FontItem
      $box.BorderStyle = 'FixedSingle'
      $box.Multiline = $true
      $box.ScrollBars = 'Vertical'
      $box.Text = [string]$cur
      $box.Left = $ctlX; $box.Top = [int](6 * $s); $box.Width = $ctlW; $box.Height = [int](70 * $s)
      $row.Controls.Add($box)
      $entry.Ctl = $box
      $entry.Get = { param($ctl, $ent) return [string]$ctl.Text }
    }
    'info' {
      $lbl2 = New-Object System.Windows.Forms.Label
      $lbl2.Text = [string]$cur
      $lbl2.Font = $Ctx.FontItem
      $lbl2.ForeColor = $c.Muted
      $lbl2.Left = $ctlX; $lbl2.Top = $ctlTop; $lbl2.Width = $ctlW; $lbl2.Height = [int](22 * $s)
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
      $box.Left = $ctlX; $box.Top = $ctlTop; $box.Width = $ctlW
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
    $u.Left = [int]($entry.Ctl.Left + $entry.Ctl.Width + 8 * $s); $u.Top = $ctlTop + [int](4 * $s)
    $u.Width = [int](70 * $s); $u.Height = [int](18 * $s)
    $row.Controls.Add($u)
  }

  # 行底 1px 分隔线做进**行里面**，搜索过滤重排时它会跟着行一起走
  $line = New-Object System.Windows.Forms.Panel
  $line.BackColor = $c.Line
  $line.Left = 0; $line.Width = $Width; $line.Height = 1
  $line.Top = $rowH - 1
  $row.Controls.Add($line)

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
  return @{ Entry = $entry; Height = $rowH }
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
  $note.Height = [Math]::Max([int]$Ctx.HSmall, [int]$noteSize.Height)
  $panel.Controls.Add($note)

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

  $listW = [int](230 * $s)
  # 编辑区高度要装得下**全部**字段：6 个字段（其中一个是多行）加起来约 470 逻辑 px。
  # 之前给 300 —— 后两个字段被面板裁掉、还看不到（面板不滚动，裁剪是静默的）。
  $boxH = [int](472 * $s)
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
    $bx += [int](70 * $s)
  }

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

  $txt = if ($null -eq $reg) { '整个屏幕（默认）' } else { "x=$($reg.x), y=$($reg.y), $($reg.w)×$($reg.h)" }
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
}

# ---------------------------------------------------------------------------
# 导航 / 搜索 / 底部说明
# ---------------------------------------------------------------------------
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
  $f = [string]$Ctx.Filter
  # 过滤后必须**重排**：只把行藏掉不算数，中间会留一片空白（看着像坏了）。
  $y = @{}
  foreach ($k in $Ctx.PanelBySection.Keys) {
    $sec = $Ctx.Sections[$k]
    if ($sec.Items.Count -gt 0) {
      $y[$k] = if ($Ctx.RowStart.ContainsKey($k)) { [int]$Ctx.RowStart[$k] } else { [int]$Ctx.RowTop0 }
    } else {
      $y[$k] = 0
    }
  }
  foreach ($ent in $Ctx.Rows) {
    $hit = Test-DgMatch -Text ("$($ent.Item.Label) $($ent.Key) $($ent.Item.Help)") -Filter $f
    $ent.Row.Visible = $hit
    if ($hit -and $y.ContainsKey($ent.Section)) {
      $ent.Row.Top = [int]$y[$ent.Section]
      $y[$ent.Section] = [int]([int]$y[$ent.Section] + [int]$ent.RowH + [int](2 * [double]$Ctx.S))
    }
  }
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
  $bad = $null

  foreach ($ent in $Ctx.Rows) {
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

  if ($bad) {
    [void][System.Windows.Forms.MessageBox]::Show($bad.Why, '这个值填得不对', 'OK', 'Warning')
    $navIdx = [array]::IndexOf($Ctx.NavMap, $bad.Entry.Section)
    if ($navIdx -ge 0) { $Ctx.Nav.SelectedIndex = $navIdx }
    try { $bad.Entry.Ctl.Focus() } catch { }
    return $null
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
    [switch]$SelfTest
  )

  try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }

  $Ctx = New-DgSettingsContext -ConfigPath $ConfigPath -Root $Root -UiScale $UiScale -RenderTo $RenderTo
  $s = [double]$Ctx.S
  $c = $Ctx.Colors
  $site = 'Microsoft YaHei UI'
  $Ctx.FontItem = New-Object System.Drawing.Font $site, ([float](9.5 * $s))
  $Ctx.FontItemBold = New-Object System.Drawing.Font $site, ([float](9.5 * $s)), ([System.Drawing.FontStyle]::Bold)
  $Ctx.FontSmall = New-Object System.Drawing.Font $site, ([float](8.75 * $s))
  $Ctx.FontH1 = New-Object System.Drawing.Font $site, ([float](12.5 * $s)), ([System.Drawing.FontStyle]::Bold)
  # 行高一律用 GDI 实测（Label 内部也是这条路径量的），别用「字号 × 系数」猜：
  # 200% 缩放下 19pt 的行高比 18*2 大，猜小了就会把标签裁掉。
  $Ctx.HMain = [System.Windows.Forms.TextRenderer]::MeasureText('汉字Ag', $Ctx.FontItemBold).Height
  $Ctx.HSmall = [System.Windows.Forms.TextRenderer]::MeasureText('汉字Ag', $Ctx.FontSmall).Height
  $Ctx.HH1 = [System.Windows.Forms.TextRenderer]::MeasureText('汉字Ag', $Ctx.FontH1).Height
  $Ctx.RowTop0 = [int](14 * $s) + [int]$Ctx.HH1 + [int](6 * $s) + (2 * [int]$Ctx.HSmall) + [int](10 * $s)

  $W = [int](980 * $s); $H = [int](728 * $s)
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
  $title.Font = New-Object System.Drawing.Font $site, ([float](15 * $s)), ([System.Drawing.FontStyle]::Bold)
  $title.ForeColor = $c.Text
  $title.Left = [int](24 * $s); $title.Top = [int](16 * $s); $title.Width = [int](200 * $s); $title.Height = [int](30 * $s)
  $f.Controls.Add($title)

  $sub = New-Object System.Windows.Forms.Label
  $sub.Text = '左边选一类，右边改值；鼠标停在某一行，底下会显示这个键叫什么、干嘛用的。改完点「保存」——立刻能生效的会当场生效，需要重启的会标出来。'
  $sub.Font = $Ctx.FontSmall
  $sub.ForeColor = $c.Muted
  $sub.Left = [int](24 * $s); $sub.Top = [int](46 * $s); $sub.Width = [int](600 * $s); $sub.Height = [int](20 * $s)
  $f.Controls.Add($sub)

  $navW = [int](208 * $s)
  $nav = New-Object System.Windows.Forms.ListBox
  $nav.Left = [int](24 * $s); $nav.Top = [int](84 * $s)
  $nav.Width = $navW; $nav.Height = [int](496 * $s)
  $nav.BorderStyle = 'None'
  $nav.BackColor = $c.Nav
  $nav.ForeColor = $c.Text
  $nav.Font = $Ctx.FontItem
  $nav.ItemHeight = [int](32 * $s)
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
  $card.Left = [int](($24 + 208 + 16) * $s); $card.Top = [int](84 * $s)
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

  Show-DgHelp -Ctx $Ctx -Entry $null -Note '提示：改完点「保存」。不确定某一项是干嘛的，把鼠标停在那一行上。'

  $openBtn = New-Object System.Windows.Forms.Button
  $openBtn.Text = '打开配置文件'
  $openBtn.FlatStyle = 'Flat'
  $openBtn.Font = $Ctx.FontItem
  $openBtn.Width = [int](120 * $s); $openBtn.Height = [int](34 * $s)
  $openBtn.Left = [int](($W - 24 * $s) - (120 + 100 + 100 + 20 + 16) * $s); $openBtn.Top = [int](662 * $s)
  $openBtn.Add_Click({ param($sender, $e) Start-Process 'notepad.exe' -ArgumentList ('"' + $sender.Tag + '"') })
  $openBtn.Tag = $ConfigPath
  $f.Controls.Add($openBtn)

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = '取消'
  $cancel.FlatStyle = 'Flat'
  $cancel.Font = $Ctx.FontItem
  $cancel.Width = [int](100 * $s); $cancel.Height = [int](34 * $s)
  $cancel.Left = [int](($W - 24 * $s) - (100 + 100 + 10) * $s); $cancel.Top = [int](662 * $s)
  $cancel.DialogResult = 'Cancel'
  $f.Controls.Add($cancel)

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
  $save.Left = [int](($W - 24 * $s) - 100 * $s); $save.Top = [int](662 * $s)
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
  $f.AcceptButton = $save
  $f.CancelButton = $cancel

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
      if ($ent.Ctl.Right -gt $ent.Row.Width -or $ent.Ctl.Bottom -gt $ent.Row.Height) { $bad += "$($ent.Key)：控件超出行的范围" }
      if ($ent.Label.Bottom -gt $ent.Row.Height) { $bad += "$($ent.Key)：标签超出行的范围" }
    }
    if ($bad.Count -gt 0) { Write-Host ('自检发现问题：' + ($bad -join '；')) }
    else { Write-Host ("自检：{0} 行全部就位（控件已加入行内、未越界）" -f $Ctx.Rows.Count) }

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
  $out = Show-DgSettings -ConfigPath $cfgPath -Root $PSScriptRoot -UiScale $DgsUiScale -RenderTo $DgsRenderTo -SelfTest:$DgsSelfTest
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
