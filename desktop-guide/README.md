# desktop-guide —— 桌面「随时指导」桌宠

一只常年待在桌面上的小宠物。它在后台悄悄看你用什么程序、待了多久，并周期性抓缩小的截图；
你想问它的时候（**点它**或按 **Ctrl+Alt+G**），它把最近一段观察交给「大脑」换回**一句**建议，用气泡说出来。

> 为什么从 DSH 搬到桌面：DSH 里的操作模型本来就看得见，摘要的增量只剩时间行为，价值不足（该插件已关）。
> 桌面上模型完全看不见——那才是这个能力真正该在的地方。

## 它长什么样

- 平时安静地待在角落，会眨眼、会轻微呼吸
- **思考中**：变成琥珀色，头顶冒三个点
- **说话**：变成蓝色，张嘴 + 声波，头顶弹出白色气泡
- **决定不说**：变成灰色，嘴角放平，**右上角一个会跳的三个点**（`DrawSilentDots`）——
  这是 `SILENT` 的可见表达。以前只有"变灰 + 嘴角放平"两种**静态**表达，看着跟发呆没区别；
  加个波浪式跳动的省略号，一眼就能看出"它看过了、正在忍着不说"。
  三个点的相位依次错开（`sin(tick/3 - i*0.8)`），所以不像三个点一起上下，而是像打字光标那样流动。
  自检 5y 节钉住六条：非沉默不画 / 沉默画在右半边上半边 / 不越界 / **两帧截图的哈希不一样**
  （最后一条用来证明它真的在动，而不是"看图觉得像在动"）。

`-SelfTest` 会生成两张带 alpha 的自绘预览，可以先看长相：
`run/pet-preview.png`（说话中）、`run/pet-preview-idle.png`（空闲）。

### 角色图：仓库自带一张，随时可换

`config.json` 的 `petImage` 默认指向 **`desktop-guide\assets\pet.png`**（610×610，带透明通道），
所以**不用装任何别的插件就能跑**。换成自己的图有两条路：覆盖 `assets\pet.png`，
或把 `petImage` 指到别的 PNG（支持 `{root}` / `{dshHome}` / `{userProfile}` 等占位符）；
两条都没有才退回代码绘制的圆脸。

图片不能换色，所以四个状态改用**背后一圈光晕**表达：空闲无色 / 思考琥珀 / 说话蓝 / 沉默灰。

> ⚠️ **这张图不在本项目的许可范围内**：来源不可考（最初取自 `dsh-whale-widget`，
> 那份 `PROVENANCE.md` 自述"AI 生成、按 as-is 分发、不授予再许可"），
> 作者**不对它主张任何权利**，也没法替它授权给你。权利人提出要求就立即替换或移除 ——
> 完整声明见 [`assets/PROVENANCE.md`](assets/PROVENANCE.md) 与根目录
> [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)。

### 判断记录直接画在气泡里（不用翻日志）

右键 →「**看它判过什么**」，气泡变成一张卡片：

```
它判过 12 次：说了 3 次，没说 9 次
14:02 没说 · Codex 正在处理任务，属于正常等待
13:58 说了 · 这个循环写了三遍，上面的判断可以合并
13:55 没说 · 用户只是在阅读文档
13:51 没说 · 不确定屏幕上在发生什么
```

卡片**不会自动消失**，右上角有一个 **×**（点它收起）；右键「收起气泡」同效。
这份记录来自 `logs/utterances.jsonl`，启动时自动载入，所以重启后还在。

### 宠物身上有个沉默角标

宠物右肩上有一个灰色小角标，显示**「看过了但决定不说」的累计次数**——
这是把"沉默"变成看得见的东西的最直接做法。一句话没说的次数，和它说了什么同样重要。

## 怎么用

### 右键菜单为什么只有 8 行

之前是二十来项平铺（设置 / 更多 / 对话 / 框选 / 字体 / 风格 / 朗读 / 自动发言 / 记录 …），
200% 缩放下**比屏幕还高**，点完想关掉都费劲。现在顶层只有 8 行、约 244px：

```
现在说一句 / 对话 / 语音输入（长按宠物说话）
──────
更多 ▸   看它判过什么 · 收起气泡 · 框选监控区域 · 取消监控区域 · 我是醒着的 · 新建 agent ▸ · Agent 列表（派活给谁）…
设置 ▸   主 agent 模型 ▸ · 工作 agent 权限 ▸ · 说话风格 ▸ · 朗读 ▸ · 自动发言 · 字体字号 · system prompt · 主 agent 会话
──────
退出
```

**关掉菜单**现在有三条路，不用再去找那块空白：

| 想关的时候 | 怎么做 |
|---|---|
| 顺手 | **点宠物本体**（这一下不会触发"现在说一句"） |
| 常规 | 点菜单外面任意位置（`AutoClose`） |
| 懒 | 鼠标**跑到菜单（含已经弹出的子菜单）范围之外、停 1.2 秒**，自动关 |

### 开机启动：勾一下就行（不需要管理员）

右键 →「设置 → 开机启动（跟 Windows 一起起）」勾上就写进
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，值名 `BloopPet`，内容是：

```
"<某个 pwsh.exe>" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<仓库>\desktop-guide\DesktopGuide.ps1"
```

为什么要这么实现（而不是在「启动」文件夹放快捷方式）：不用建 `.lnk`（那要调 WScript.Shell COM）、
不用管理员权限、用户想手动检查或删掉，注册表编辑器里一眼就能看到。`-WindowStyle Hidden` 是为了
开机不要弹一个黑窗口（桌宠自己有分层窗口）。勾的状态**以注册表为准**（回读），写不进去（组策略
禁了 HKCU\Run 之类）会把勾弹回去并给出可手动粘贴的命令行 —— 不骗用户。

> ⚠️ **pwsh 路径是有讲究的**：`Get-AutoStartExe` 优先挑**系统装**的 PowerShell 7
> （`Program Files`、`LOCALAPPDATA\Programs`、`WindowsApps`），找不到才退回**当前进程用的那个**。
> 为什么挑：最早这台机器上没有系统版 PowerShell 7，唯一的 pwsh 在 Codex 运行时的缓存里
> （`.cache\codex-runtimes\...\pwsh.exe`）—— 能用，但缓存被清理/升级就失效，开机项会指向一个不存在的文件。
>
> **现在装好了**：`winget install Microsoft.PowerShell` 装了 **7.6.6**（MSIX，**用户级、不需要管理员**），
> 落到 `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`。所以开机项和快捷方式现在指的它 ——
> 不再依赖 Codex 的缓存。换成别的机器时，只要装过系统版 pwsh，`Get-AutoStartExe` 会自动挑中；
> 如果它仍然挑到了 `.cache\codex-runtimes\...`（说明那台机器还没装），自检 5w 会把这条提醒打出来。

> ⚠️ **"移开就自动关"踩过一次**：它一开始只拿主菜单的范围算（`ContextMenuStrip.Bounds` 再外扩 250px），
> 可**子菜单是独立窗口**，Bounds 里没有它们 —— 桌宠贴在屏幕右缘时，「设置 → 说话风格」
> 这种嵌套子菜单会一路往左铺开（实测：主菜单范围右边界 560，子菜单右边界已经 841），
> 鼠标刚移过去就被判成"跑远"，0.8 秒后整个菜单关掉。用户原话是"右键菜单来不及点就消失了"。
> 现在 `MenuZone()` 会把**主菜单 + 所有已弹出的子菜单**的范围并起来（递归，支持多层嵌套），
> 外扩按缩放走（`S(140)`），停留阈值放宽到 1.2 秒。自检 5f 节把这条钉住：
> 弹出菜单和「设置」子菜单后，断言子菜单范围落在判定区内、屏幕外的点不在。

另外菜单本身也窄了一截（`ShowImageMargin = false`，去掉左边那条图标留白）。

**直接命令启动**（这台机器上 `start.cmd` 会被应用控制策略按扩展名拦掉，见下）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\DesktopGuide.ps1
```

> ⚠️ 实测：在这台机器上启动 `start.cmd` 会被应用控制策略拦下来，报
> 「应用程序控制策略已阻止此文件。来自 Web 的危险文件扩展名。」（不是 Web 标记，是按扩展名拦的）。
> `.ps1` 不受影响，所以用上面的命令；`-WindowStyle Minimized` 可以让控制台不占地方。
> 想停止：右键宠物 →「退出」，或关掉那个窗口。

### 双击启动：跑一次 `make-launcher.ps1`（推荐给日常使用）

上面那行命令每次都要敲，太麻烦；而这台机器上 `.cmd` / `.bat` 又按扩展名被拦（见上一条），
`.ps1` 双击默认交给记事本。所以给你生成一个**快捷方式**：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\make-launcher.ps1
```

它做三件事：挑一个稳的 pwsh（优先系统安装的 PowerShell 7，找不到才用当前进程这个）、
用 `assets\pet.png` 现生成一个 `assets\pet.ico` 当图标、然后在**桌面**和**仓库目录**各放一个
「泡泡桌宠.lnk」。双击就启动，不用右键「使用 PowerShell 运行」。

两个细节：

- 快捷方式里带 `-WindowStyle Hidden`（不弹黑窗口）和 `-NotifyIfRunning`
  （**已经在跑的时候双击**，会弹一句「桌宠已经在跑了（PID xxxx）」而不是起第二个 ——
  两个桌宠叠一起会抢同一个会话写句柄、抢同一个托盘图标，还会互相抢点击）。
- `.lnk` 里是绝对路径，所以它**不进仓库**（`.gitignore` 里挡了，图标 `pet.ico` 也一样）。
  换机器 / 搬目录之后重跑一次 `make-launcher.ps1` 就行。

自检第 5x 节盯着这条链：`Get-RunningPetPid` 的三态（没有 pid 文件 / pid 是死进程 / pid 是活桌宠）、
`make-launcher.ps1 -SelfTest` 能跑、图标在不在。

| 操作 | 效果 |
|---|---|
| **左键点它** | 现在说一句；**它正在朗读时，这一下是让它闭嘴**（不叠加新判断） |
| **双击它** | **完全打断**：停止朗读；如果它正在想，这次思考也一并取消 |
| **长按开麦前** | 先停掉正在进行的朗读 —— 说话即打断，免得朗读声盖住用户的话、还被录进去 |
| **拖它** | 换位置（位置会记住，下次还在那） |
| **右键** | 菜单：现在说一句 / 自动发言（每 5 分钟）/ **朗读** / **看它判过什么** / 收起气泡 / 退出 |
| **Ctrl+Alt+G** | 同「左键点它」 |

透明区域点下去会**穿过**（不挡住下面的窗口）；它也不会抢焦点。

### 说话风格：保守 / 陪练 / 损友

**右键 → 设置 → 说话风格**（设置窗口里也有同一项）三选一。它不是"语气旋钮"，而是**换掉整份
system prompt**：`presets\<名字>.txt` 会被复制成 `system-prompt.txt`，由 advisor 当作
「用户自定义指令（最高优先级）」注入。

| 风格 | 什么时候开口 | 文件 |
|---|---|---|
| 保守 `guard` | 只在有可证明的错误、反复失败、或做法与用户目标冲突时 | `presets\guard.txt` |
| 陪练 `coach` | 每轮都给建议（想连续陪练还要同时开「自动发言」） | `presets\coach.txt` |
| **损友 `roast`** | **陪着你说话**：画面没变也吐槽两句，像直播解说；先拆台再给建议 | `presets\roast.txt` |

损友模式是**吐槽事、不吐槽人**：提示词里写死了「不评价用户的能力 / 性格 / 外貌、不骂人、
不带脏字」，以及「屏幕上真的什么都看不到时才沉默 —— 硬找茬是最难看的」。长度上限仍是 60 字。

它和别的风格还有一个**门控上的区别**：其它风格要「画面变了 / 窗口换了」才值得看一眼，
而损友模式的定位是陪着说话，所以在**画面没变时也放行**，间隔走 `roastMinSeconds`
（默认 30 秒，不再走任务档的 `judgeMinSeconds`）。代价是真的花钱 —— 每轮都是一次模型调用
（约 0.02–0.03 元），所以留了两个刹车：**人长时间不动键鼠就不开口**（直播间里没人了还解说很傻），
以及**连着几次被判成"没什么可说"时间隔自动放宽 2–3 倍**（别对着一个无聊画面一直付费）。
`-SelfTest` 的 5h 节把这三条都钉住了（15 秒拦住 / 40 秒放行 / 退避到 90 秒）。

> 想加自己的风格：往 `presets\` 丢一个 `xxx.txt`，`speakStyle` 填 `xxx` 就生效。
> **但一定要带上那句「回答一律用纯文本，不要用 Markdown」** —— 气泡不渲染 Markdown，
> 漏了这句，用户看到的就是一堆星号和井号。自检第 5u 节盯着三份内置风格都带着它，
> 以及「设置窗口的下拉」「右键菜单」两处入口都是三项。

## 朗读：把结论句念出来（TTS）

气泡里那句话，现在会同时**读出来**。读的是**结论句**，不是思考过程 ——
推理过程是给模型自己看的英文长文本，念出来对耳朵没有价值。

**引擎**（`ttsEngine`，默认 `auto`）：

| 引擎 | 音色 | 出声延迟 | 联网 |
|---|---|---|---|
| **`edge`**（默认，当前用这个） | 微软 Edge 神经音色：`zh-CN-XiaoyiNeural` = 卡通活泼女声 | **约 3–5 秒** | 要 |
| `speech` | 本机 System.Speech（Huihui / Yaoyao / Kangkang，十几年前的拼接音） | 瞬时 | 不要 |
| `sapi` | SAPI COM，兜底 | 瞬时 | 不要 |

`auto` = 找得到 Edge 就用 Edge，否则自动退回本机音色；Edge 合成失败（断网等）也会**当场退回本机音色**，不会让这句话没声。朗读逻辑都在 `tts.ps1` 里。

> **那 3–5 秒是怎么来的**（别以为是坏了）：`import edge_tts` 本身要 **1.7 秒**
>（包里的数据模块很大，不是环境问题），网络合成约 2 秒。所以 Edge 是「气泡先出来、
> 声音晚几秒」。想要瞬时出声就把 `ttsEngine` 改成 `speech`。
>
> Edge 只肯返回 MP3，而 PowerShell 播 MP3 要走 Media Foundation（冷启动另加 0.5–1.1 秒），
> 所以 `tts-edge-say.py` 顺手用 miniaudio 解码成 WAV，`SoundPlayer` 播放启动只要 15ms。

**挑音色**（这是耳朵的活，不是脑子的活）：

```powershell
cd <仓库根>\desktop-guide
pwsh -NoProfile -Command ". .\md-plain.ps1; . .\tts.ps1; Initialize-Tts -Config (Get-Content .\config.json -Raw | ConvertFrom-Json) | Out-Null; Invoke-TtsAudition"
```

它会依次念同一句话给你听：卡通活泼（默认）／更嗲更雀跃／温暖自然／男童声／台湾腔软糯。
选好之后把 `config.json` 的 `ttsVoice`（必要时连 `ttsEdgeRate`、`ttsEdgePitch`）改成对应值。

**只读该读的**：`（它选择不说）`、`（大脑没有输出）`、`你在做：…`、`REASON:` / `WATCH:`
这些一律不出声 —— 过滤规则在 `ConvertTo-Speakable`。太长的一句会按 `ttsMaxChars`
在标点处截断（半句话被生生掐断比少说两句更难受）。

**静音 / 播放 / 打断**：

| 入口 | 效果 |
|---|---|
| 右键 → 朗读 → **出声朗读**（勾选框） | 开/关朗读；关掉时立刻停住当前这句 |
| 右键 → 朗读 → **停止朗读（打断）** | 同「打断」 |
| 右键 → 朗读 → **重读上一句** | 复读刚才那句（静音时也读 —— 这是明确要求） |
| **单击宠物**（它正在说话时） | 停朗读 —— 最直接的一条路，不用去够右键菜单 |
| **双击宠物** | 完全打断：先停朗读；如果它正在想，这次思考也一并取消 |
| **长按宠物**（开麦） | 先停朗读再录音：说话即打断 |

静音状态是**记住的**：关掉后重启依然是静音（存在 `run/pet.json` 的 `muted` 字段）。

> **为什么单击也要看状态**：单击本来是「现在说一句」。但用户点下去的那一刻如果是"它正在念"，
> 想让它闭嘴的意图远大于再要一条建议 —— 而且 Edge 合成要 3–5 秒，若按"先停再问"处理，
> 几秒后又会冒出一段新朗读，等于没打断。所以正在朗读时，单击只负责闭嘴；
> 真想再问一句，停住之后再点一下即可（`Test-TtsSpeaking` 判断，见 `Add_AskRequested`）。

> **双击为什么要专门处理**：WinForms 的双击消息序列是 按下 → 抬起 → 双击 → 抬起，
> 第二次「抬起」必须吞掉 —— 否则刚打断完，那一下又会被当成「问一句」，
> 等于打断无效（实测踩过，已修）。同时给 `Start-Advisor` 加了「已有一轮在跑就不再起」
> 的闸门：以前连点两下会起两个 advisor，第二个去抢同一会话的写句柄，
> 报 `already owned by an active write handle` 并留下孤儿 dsh 进程。

### config.json 里的朗读项

| 键 | 默认 | 说明 |
|---|---|---|
| `ttsEnabled` | `true` | 是否朗读（运行时开关以 `run/pet.json` 为准） |
| `ttsEngine` | `auto` | `auto` / `edge` / `speech` |
| `ttsVoice` | `""` | 留空 = Edge 用 `zh-CN-XiaoyiNeural`；也可写 `zh-CN-XiaoxiaoNeural`、`Microsoft Yaoyao` |
| `ttsEdgeRate` | `+6%` | Edge 语速（`+10%` 更快） |
| `ttsEdgePitch` | `+12Hz` | Edge 音高（抬一点显可爱；`+32Hz` 就很嗲） |
| `ttsEdgeVolume` | `+0%` | Edge 音量 |
| `ttsPython` | `""` | 留空 = 自动用 `.tts\venv\Scripts\python.exe` |
| `ttsRate` | `0` | **本机引擎**的语速 -10..10 |
| `ttsVolume` | `100` | **本机引擎**的音量 0..100 |
| `ttsMaxChars` | `180` | 一句最多读多少字 |
| `ttsSkipStatus` | `true` | 「你在做：…」这类"我看见你了"的话不读 |

自检（只列音色，**不出声**）：`pwsh -NoProfile -ExecutionPolicy Bypass -File DesktopGuide.ps1 -SelfTest`。
想试听一句：dot-source `tts.ps1` 后调 `Test-Tts -Play`。

## 语音输入：**长按宠物说话**

### 打字派活：和语音**完全同一条下游**

不想说话就打字。入口三个：底部按钮条的**键盘图标**、右键菜单「打字派活（和说话同一条路）」、
或 **Ctrl+Alt+T**。弹一个输入框，敲完回车 → 走的是语音那条路的**最后一行**：

```
语音：长按 → 录音 → SenseVoice → 识别出的句子 ┐
                                              ├→ Start-PetTask → 常驻大脑 → 报结论
打字：输入框 → 键盘敲的句子 ───────────────────┘
```

也就是说「识别」是唯一被替换的环节，后面（派任务、走常驻运行时、跑完念结论、失败回报）
一模一样 —— 这也是为什么加它只动了两处：一个输入框，一个 `Start-PetTask`。

> **输入条只有两个控件：一个长圆角输入框 + 一个发送按钮。**
> 老版本是「提示标签 + 多行大框 + 整宽按钮」三层叠在一个 460×200 的窗口里，而这条路径
> 只干一件事（敲一句话派出去），三层里两层是多余的：提示改成输入框上的**自绘覆盖层**，
> 多行框换成单行长框。Enter 发送、Esc 取消、按住空白处拖动（无边框窗口没有标题栏）。
> 圆角是用 `Region` **真裁**的（不裁的话四个角是方底色），按钮是圆角药丸。
>
> 两个踩到的坑，都写进了注释：
> 1. **不能用原生 `PlaceholderText`** —— 它在控件获得焦点时就不画了，而这个框是自动聚焦的，
>    等于提示语永远看不见（截屏核对时发现的）。改成一块盖在输入框上的 Label：有字就藏。
> 2. **200% 缩放下框里只放得下约 16 个汉字**，所以提示语压到 14 字，并开了 `AutoEllipsis`，
>    放不下时给省略号而不是硬切一半。
>
> 自检里有 12 条断言盯着这一条（只有一个按钮 / 输入框在左 / 占宽六成以上 / 两者垂直居中 /
> 按钮不越界 / 提示层文字与对齐 / 开省略号 / 没用原生 placeholder / 外框与按钮都带 Region /
> 按钮文字），在 100%、125%、150%、200% 四种缩放下都跑过；预览图见 `run\pet-preview-taskinput.png`。
>
> 为什么用断言不用肉眼看图：截图会受 DPI 缩放影响（这台机器 200%，坐标对不准），
> 而且 `DrawToBitmap` 不还原 `Region` —— 看图反而会误判。断言之外仍做一次真实截屏核对观感。

顺手把按钮条从 4 个扩到 5 个时修了个隐患：`buttonRects` 原来写死 `new Rectangle[4]`，
而排布循环用的是 `BtnIcons.Length` —— 多加一个图标就会下标越界。现在是 `new Rectangle[5]`
并注明"长度跟着 BtnIcons 走"。

按住宠物不放（默认 **400ms** 判定为长按）→ 红光晕 + 气泡「正在听…」→ 松开 → 识别 → 识别到的
那句话**直接派一个后台 agent 去做**（不是拿去聊天）：气泡先说「收到，交给 agent-xxxx 去做」，
它跑完桌宠把最后一行结论报出来、顺带念一遍。

> 为什么不是丢回对话窗口：语音说的是"去做一件事"，不是"来聊天"。最早那版把它送进自绘对话栏，
> 结果是用户对着一个不渲染 Markdown 的气泡窗口干等（实测 23 秒）。现在桌宠不阻塞、不用盯着看，
> 跑完主动告诉你。同一个任务实测 **9.3 秒**出结论（"当前 CPU 占用率约为 29%"）。

任务用的模型/推理强度在 `config.json`：`petTaskModel` 留空 = `agents.json` 的第一个模型；
`petTaskEffort` 默认 **low** —— 语音派的多半是"查一下/改一下"这种短活，压到 low 明显快一截。
想聊长一点或要它自己动手，就走右键 →「对话」/「新建 agent」。

为什么是长按：单击已经给了「现在说一句」（那是"你来说"）。语音是"我要说"，需要一个不会误触、
也不用记快捷键的入口。按住期间只要**挪动超过 3px** 就退化成拖动（搬家），不会误开麦。

**引擎是 DSH 自带的那套**，全程本机、离线、不出机器：

| 环节 | 用什么 |
|---|---|
| 录音 | `winmm` 的 **waveIn** 直录 16-bit PCM 单声道（可选设备）。MCI 在这台机器上只肯给 8-bit 且选不了设备，所以没用它 |
| 识别 | **SenseVoice**（`sherpa-onnx`），和 DSH 的 `dsh-experimental-speech-to-text-sensevoice` 用同一份运行时与同一套参数 |
| 运行时来源 | DSH 发行包里已带的 `sherpa-onnx.node`；JS 包装层从 `app.asar` 抽到 `.stt\sherpa\sherpa-onnx-node\` |
| 模型 | `.stt\model\`（`model.int8.onnx` 228MB + `tokens.txt` + `silero_vad.onnx`），首次按需下载 |

> ⚠️ **必须用普通 node 跑，不能用 `ELECTRON_RUN_AS_NODE`**：Electron 的 node 禁止原生外部缓冲区，
> `sherpa.readWave()` 一返回就抛 `External buffers are not allowed`（实测踩过）。node 的查找顺序是
> `config.sttNode` → DSH 自带运行时（`~\.dsh\dsh-runtimes\...\node\bin\node.exe`）→ PATH 里的 node。
>
> ⚠️ **录音不要用 MCI 设格式**：`set ... bitspersample 16` 之后 `record` 直接报 328
> （"未安装可按当前格式记录文件的波形设备"）。所以走 waveIn，格式自己说了算。

实测（本机）：识别 **3.2–5.2 秒/句**（含模型加载；音频越长越久），纯音频 16-bit 44.1k → 自动重采样到 16k。

拿桌宠自己念过的句子做**已知答案**的回归测试最省事（不用对着麦克风说话）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File DesktopGuide.ps1 -SelfTest   # 含 STT 自检 +「录音中」预览图
```

```powershell
# 只测识别（默认拿 run\tts\say-*.wav，有原句可对照）
cd <仓库根>\desktop-guide
pwsh -NoProfile -Command ". .\stt.ps1; [void](Initialize-Stt -Config (Get-Content .\config.json -Raw | ConvertFrom-Json)); Test-Stt -Count 3"
```

### config.json 里的语音项

| 键 | 默认 | 说明 |
|---|---|---|
| `sttEnabled` | `true` | 总开关 |
| `sttLongPressMs` | `400` | 按住多久算长按；低于它仍是普通点击 |
| `sttMaxSeconds` | `20` | 单次录音上限，到点自动停止去识别（松手前也会停） |
| `sttMinSeconds` | `0.4` | 比这还短当作"没说" |
| `sttLanguage` | `auto` | SenseVoice 语言提示：`auto`/`zh`/`en`/`yue`/`ja`/`ko` |
| `sttSampleRate` | `44100` | 录音采样率（识别前统一重采样到 16k） |
| `sttDevice` | `-1` | `-1` = 系统默认输入设备；换设备填右键菜单里列出的序号 |
| `sttModelDir` / `sttNode` / `sttSherpaDir` | `""` | 留空 = 自动（`.stt\model` / 自动找 node / `.stt\sherpa\...`） |

模型没下的时候，右键 →「**语音输入（长按宠物说话）**」会起一个后台进程去下（约 229MB，
优先 `hf-mirror.com`，失败再试 `huggingface.co`），下完会在气泡里说一声。

**没听到声音时不会瞎猜**：录音峰值低于 0.01 直接报「麦克风几乎没收到声音」，
不把几个噪声幻觉字当成你说的话。

### 派活交给指定的 agent：一个窗口管「选 / 新建 / 删」

「派活」默认**每次都新建一个 agent**：说一句"把这份表格按月拆开"，它起 `agent-xxxx` 去做，
做完报结论，上下文不跨任务。想让它"记住上一次"，就打开
**右键 → 更多 → Agent 列表（派活给谁）…**（界面在 `agents-window.ps1`）：

```
派活给谁
选中的那条会接到后面所有语音 / 打字 / 拖文件的派活上，并且接着它的会话跑（上下文不断）。
当前派活目标：agent-ca901485
┌────────────┬───────────────┬──────────────┬────────┬──────────────────┬───────────┐
│ 状态       │ ID            │ 模型         │ 权限   │ 最后任务         │ 时间      │
├────────────┼───────────────┼──────────────┼────────┼──────────────────┼───────────┤
│ ✓ 完成     │ agent-8dc1c559│ DeepSeek F…  │ 工作区…│ 用一句话说明你是谁│ 10-04 16:40│
│ ○ 待派活   │ agent-1a2b3cde│ DeepSeek V4… │ 完全…  │ 给这个 agent 派活│ 10-06 20:40│
└────────────┴───────────────┴──────────────┴────────┴──────────────────┴───────────┘
[设为派活目标] [新建…] [删除] [每次新建（默认）] [关闭]
```

| 按钮 | 干什么 |
|---|---|
| **设为派活目标**（也可以双击那一行） | 之后的语音 / 打字 / 拖文件都派给它 |
| **新建…** | 挑模型 + 权限 + 备注，建一条 `○ 待派活` 的空记录，**并顺手设为派活目标** |
| **删除** | 删掉选中的那条（跑着的先 `taskkill` 停掉；日志文件保留），如果它正好是派活目标就一并清空 |
| **每次新建（默认）** | 回到原来的行为 |

选中之后：

| 变化 | 说明 |
|---|---|
| 任务落在同一条记录上 | 不再每次新增 `agent-xxxx`；`Agent 列表` 里那一行会更新成最新任务 |
| **接着它的会话跑** | 派活时带上这条 agent 的 `sessionId`，所以"刚才那个文件""再改一下"这类指代才有意义 |
| 用它自己的模型 / 权限 | 指定的 agent 是什么模型、什么权限就用那套（不再套 `petTaskEffort` 的推理强度压缩） |
| 目标正忙 | 那一次会**先新建一个**去做（不丢刚说的话），气泡里会说明原因 |

选择写在 **`run\dispatch.json`**（不是 `pet.json`）—— 因为 `pet.json` 是桌宠自己在写的
（拖动、静音都会存一次），两边同时写会互相覆盖。桌宠**每轮派活前重读这个文件**，
所以窗口里改完立刻生效，不用重启。那条 agent 被清理掉时（`keepFinished` 只留最近 20 条）
自动退回"每次新建"。

> **为什么从子菜单改成窗口**：子菜单只能点一下选中 —— 看不到状态、没法新建、没法删。
> 这张表本质是个列表（状态 / 模型 / 权限 / 最后任务 / 时间），该用窗口。
> 自检在 `-SelfTest` 的第 5s 节：逻辑自检在临时目录里跑"新建 / 设目标 / 删除"（8 项断言），
> 再把窗口挪到屏幕外 `Show()` 出来渲染一张 `run\agents-window.png` 供肉眼看版面。

> ⚠️ **一处已知限制**：会话记忆**跨大脑重启会丢**。DSH 的 SDK 用 `ctx.agents.create({sessionId})`
> 建会话，**已存在**的 id 会被拒（"session already exists"），大脑那边只能换一个带时间戳的新会话
> 重试（见 `brain-sdk.ps1` 的兜底）。所以同一个大脑进程活着时，指定 agent 的记忆是连续的；
> 桌宠（或大脑）重启之后，同一条 agent 会换到新会话继续跑 —— 功能不受影响，
> 但它不再记得重启前的那几个任务。

## 对话界面：直接用 DSH 自己的

原来那个"对话栏"是自绘气泡（`chat-panel.ps1`），它只能画纯文本 —— **Markdown、工具卡片、流式输出全画不了**，
排版还得自己维护。实测结果是：文字被裁、气泡中间一大块空白、发送按钮位置错。

所以默认改成**直接把 DSH 的界面拿过来**：

```
dsh --profile web --patch run\webui-model.patch.yml --port 4319 --no-open   ← 就是 `dsh web`，发行包里现成的
```

由 [`web-ui.ps1`](web-ui.ps1) 起服务（幂等；pid 记在 `run\webui.json`），再用 **Edge 的 `--app=` 模式**
开一个无地址栏窗口指向它 —— 看起来是个原生窗口，内容 100% 由 DSH 渲染（Markdown、工具卡片、会话侧栏全都有）。

- 点桌宠的「**对话**」= 开这个窗口。
- 想换回旧的自绘气泡栏：`config.json` 里 `chatUi` 改成 `"bubbles"`（保留作兜底）。
- **拖拽到桌宠**现在也走"派一个 agent 去做"（和语音同一条路），见下一节。

> ⚠️ **对话窗口为什么要带 `--patch`**：DSH 装完自带的 `web` profile 把 `agent-default-model`
> 指向 **`deepseek-official`**，那个 provider 要 `DEEPSEEK_API_KEY` 环境变量 —— 没设的话
> 「对话」里问什么都是 `MISSING_CREDENTIAL`（`no API key for provider route "deepseek-official"`）。
> 桌宠自己的 headless 侧一直是靠 `--patch` 改用**账号登录**的（见 `dsh-agents.ps1` 的 `Write-AgentPatch`），
> 唯独对话窗口直接开的是 `dsh web`、没走那条路，所以漏了。现在启动时补同一份 patch，
> 覆盖成 `agents.json` 里的模型（`deepseek-account`，不用 key）。
>
> 两点实测细节：`--patch` 是**启动器**参数，必须排在 `--port` / `--no-open` 这些**应用**参数前面，
> 否则会被 web 应用接管、报 `error: unknown option '--patch'` 起不来；换模型改 `config.json` 的
> `webModel`（填 `agents.json` 里 models 的 `name`，留空 = 第一个），下次点「对话」会自动重启那个服务。

## 拖进来的文件：会真的被读掉

先说一个容易误会的事实：**原生 DSH 自己也不把文件内容塞进提示词**。它的 `@file` 引用和附件
都是给模型一个**路径/handle**，由模型自己调 `read` / `read_image` 去读。所以"我拖进去只得到路径"
这件事本身不是 bug —— 差的是**模型有没有被告知该去读**。

原生 DSH 为此给模型装了一段提示，我们把它**原样迁了过来**（`dsh-file-reference-local` 自带的
`FILE_REFERENCE_PROMPT`）：

> Tokens prefixed with @ are paths the user explicitly referenced. … A trailing slash marks a directory:
> list it when its contents matter. Anything else is a file: **use the read tool when its contents are
> needed, and do not claim to have inspected it before reading.**

于是拖拽这条路现在是：文件按**原生 mention 语法**（`@path` / `@"path with spaces"`）写进任务，
模型拿到上面那段提示，自己决定调哪个工具去读。

实测（探针留在 `run\fileref-probe.ps1`，可以传 `-Target` 试任意文件）：

| 拖进的东西 | 模型实际调的工具 | 结果 |
|---|---|---|
| 一个文本记录（.txt） | `read` | 「温度 42.5 C，振动 0.31 mm/s」——内容读出来了 ✅ |
| 一张截图（.jpg） | `read_image` | 准确描述了截图里的窗口和内容 ✅ |

只丢文件、没留言时，桌宠会补一句最小任务（"请先读这些文件，再说明它们是什么"），
不让模型猜你到底想干嘛。

> ⚠️ 挂 `dsh-file-reference-local` 时**不要再挂 `dsh-file-reference`**：前者自己就 extends 并注册了
> `ctx.fileReferences`，两个一起挂会 `service 重复注册`、激活失败（实测报
> `dsh: warning: 1 entry did not activate`）。base 那个包只是 seam。

> ⚠️ **一个会话只能有一个写入者。** DSH 界面是**另一个 DSH 实例**，和桌宠 advisor 的 headless 进程互不影响；
> 但如果你在 DSH 界面里**把桌宠的主会话也打开着**，advisor 下一轮就会撞上
> `already owned by an active write handle`。这条现在会被翻译成人话显示：
> 「主会话被别处占着 —— 关掉那边的标签页，或者关掉对话窗口」。想两边同时用，就让对话窗口聊别的会话。

## 桌面应答器：DSH 要问人的事，在桌面上回答

DSH 里有三件事都要"问人"，而它们在 headless profile 里**共用同一个缺口——没有应答者**：

| 要问人的事 | 走哪个 seam | 没应答者时的行为 |
|---|---|---|
| 权限审批（沙箱升权） | `approval/request` waterfall | 一律拒绝（fail-closed） |
| 提问 `ask_user_question` | `user-questions/request` waterfall | **工具根本没挂**（只在 web 的 standard preset 里） |
| 计划评审 `exit_plan_mode` | 同一个 `userQuestions.ask()` | 调用即失败 |

web UI 里由 `dsh-client-ui-approval` / `dsh-client-ui-user-questions` 当应答者；headless 里没人当，
所以桌宠这边补一个：[`pet-responder\index.js`](pet-responder/index.js)（DSH 侧）+ DesktopGuide 里的 `AskTimer`（界面侧）。

两边靠 `run\ask\` 下的两个文件说话：

```
请求  run\ask\req-<id>.json     { kind:'approval'|'question', tool, reason, questions:[...] }
应答  run\ask\ans-<id>.json     审批 → { outcome:'allowed-once'|'rejected' }
                                提问 → { answers:[{ id, selected:[标签], custom? }] }
                                { canceled:true } = 没答（交回给系统原来的 fail-closed 行为）
```

气泡上就是可点的按钮：审批给「允许 / 拒绝 / 稍后」，提问直接用**请求里带的选项标签**——
这对计划评审很关键，`exit_plan_mode` 要求回来的标签和它给的 `Approve` 逐字相同。
按钮默认等 `askSeconds`（45 秒）；超时或点「稍后」等于没答，**不伪造一个答案糊弄模型**。

### 选项按钮不许溢出气泡（踩过一次）

老排版是"一行平铺、每个按钮取最长标签的宽度"。审批的三个短词没问题，但 `ask_user_question`
给的是一整句一整句的标签（「继续读完 README 并给你中文解读（推荐）」），四个排一行的总宽远超窗口，
按钮画到窗口外面、右边的字被直接切掉 —— 用户看到的就是半截「解释某个具体文」。

现在两层兜底：

| 层 | 做法 |
|---|---|
| 先撑开 | `Set-PetWidthForOptions` 量一遍整句宽度（`PetForm.PromptLogicalWidth`），把窗口撑到放得下（上限 620） |
| 再折行 | 撑不下就按"每行最多完整放下几个"折行（`ComputeOptionLayout`），单个标签本身超宽才用省略号 |

所以按钮**永远不会**画到气泡外面。另外，自己这套 `OPTIONS:` 的标签是提示词里明确要求短写
（2-4 个字、动词开头、最多 8 字，见交互规格 R3「≤8 字」）—— 整句标签是 DSH 那边给的，我们只负责画得下。

实测两条路（探针留在 `run\ask-probe.ps1` 与 `run\approval-probe.ps1`）：

| 场景 | 结果 |
|---|---|
| agent 用 `ask_user_question` 问"早餐吃甲还是乙" | 请求落到桌面 → 回「甲」→ agent 最终回复**「你选了甲。」** ✅ |
| 只读沙箱下 agent 写文件、申请升权 | `approval/request` 触发（reason 是 "escalate sandbox to workspace-write…"）→ 回「拒绝」→ **文件确实没写成**，agent 如实报告被拒 ✅ |

插件用 **`file://` URL** 引（patch 里 `name:` 写 `file:///C:/.../pet-responder/index.js`）——实测绝对路径和裸包名都不行，
`file://` 可以，而且**完全不用改 DSH 的 profile**（不塞 junction、不动 package.json）。
`ask_user_question` 那个工具本身也要自己插一行（`@deepseek-ai/dsh-tool-ask-user`），它不在 `dsh-base` 里。

## 插件管理：和 DSH 是同一套，不是仿的

`plugin_manager` 本来就是 **DSH 给 agent 的工具**（不是只有 UI 才有）——
`dsh-base` 的第一行就是它，只是**默认关着**。官方 README 专门写了无预设的部署怎么开：

```yaml
- id: tool-plugin-manager
  disabled: false
```

我们就是照抄这两行（见 `dsh-agents.ps1` 的 `-EnablePluginManager`）。工具名 `plugin_manager`，八个 action：

| 分类 | action |
|---|---|
| 看 | `list_plugins`、`list_bundles`、`list_version_exemptions` |
| 改 | `set_plugin`、`set_bundle`、`remove_bundle`、`set_version_exemption` |
| 装 | `install_bundle`（带 `registry` / `approvedBuilds` 参数） |

**实测**（探针 `run\plugin-probe.ps1`，可以 `-Task` 换问题）：

| 问它什么 | 结果 |
|---|---|
| `list_plugins` | 分页读完 100 个条目，正确指出 95 个 active、5 个 disabled（`hmr`/`bash-sandbox`/`tool-bash`/`skill-badge`/`tool-ralph`），还认出了我们自己的 `pet-responder` |
| `list_bundles` | 找出 4 个官方**实验性可选包**：`agent-team`、`schedule`、`auto-review`、`voice-input`；并正确说明 ACP/SDK/Web 那几项是互斥宿主形态、不该手动勾 |

**每次调用要求 `danger-full-access` 或本次审批。** 工作 agent 默认是完全访问，所以它自己就能开关插件；
想更稳就把「工作 agent 权限」改成**工作区可写** —— 那样每个插件操作都会在桌宠上弹一个允许/拒绝按钮
（上一轮接好的桌面应答器正好接住）。两条路都是现成的，不是二选一。

> ⚠️ 诚实说明一处**没有**对齐的地方：DSH 的服务里有 `inspect(spec)`（拿包名去 registry 问它是什么）
> 和 `registries()`，但它们**没有**暴露成工具 action —— 所以 agent 能"列出已装 / 可选"，
> 不能按关键词搜 npm。这不是我们漏了，是 DSH 自己也没把这层做成工具。
> 要装指定包，直接给包名（或 git 地址 / 本地路径）。

## 另外挂上的三样（同样是包里现成、之前没挂）

| 挂的是 | 给了什么 | 为什么之前没有 |
|---|---|---|
| `@deepseek-ai/dsh-tool-present` | `present` 工具：agent 声明"这是我交付的文件"（记路径+说明，不复制内容） | 官方 `standard` preset 里有，`dsh-base` 里没有 |
| `@deepseek-ai/dsh-skill-office`（+ `dsh-office-to-pdf`） | 三个 skill：**`office-docx` / `office-pptx` / `office-xlsx`** —— Word/PPT/Excel 的创建、局部编辑、结构检查、渲染与交付 | 同上；`standard` preset 之外不挂 |
| `@deepseek-ai/dsh-tool-cordis`（+ `/host` + `dsh-cordis-host-runner`） | 两个只读工具：`cordis_inspect_list` / `cordis_inspect_query` —— 写或调插件之前先问清运行时契约 | 同上 |

实测（`run\plugin-probe.ps1 -Kind extras`）：

| 问它什么 | 结果 |
|---|---|
| 列出可用 skill | 4 个：`diagnose-windows-sandbox-acl`、**`office-docx`**、**`office-pptx`**、**`office-xlsx`** ✅ |
| `cordis_inspect_list` | 返回 4 个 provider：`Service` / `Event` / `Config` / `Tool` ✅ |
| 用 `present` 声明交付物 | `Presented README.md` ✅ |

两个坑记一下：

- **`dsh-skill-office` 必须显式给 `node`**。README 原话：Electron 和独立 SDK 可执行文件必须显式提供。
  我们的 agent 正是用 `DeepSeek Harness.exe` + `ELECTRON_RUN_AS_NODE` 跑的，所以 patch 里写死了
  DSH 自带运行时那个 `node.exe`（和 `stt.ps1` 用的是同一个）。
- **`dsh-tool-cordis` 光挂工具行不够**：还要在宿主侧挂一次 `/host` 半边，否则没有 provider。
  照 README 挂三行（`cordis-host-runner` + `/host` + 工具）之后才真的能查。

工作 agent 现在一共插 9 行（`ask_user_question` / `file-reference-local` / `present` / `skill-office` /
`office-to-pdf` / cordis×3 / `pet-responder`），实跑一遍确认**没有激活警告**、6.4 秒回结果。

## 用户操作优先：能打断自动判断，停手后自己接着做

用户一动手（点它 / 长按 / 打字 / 拖 / 开菜单 / 点选项），自动判断立刻让位：
`Start-Advisor -Auto` 看到 `userQuietSeconds`（默认 6 秒）内有过用户操作就直接返回，
只记一笔"欠一次"，等用户停手后由 `$priorityTimer` 补做。**双击打断不补做** —— 那是在明确要求"停"。
被打断的那一轮还要**清掉画面指纹**，否则补跑会被"状态没变，不必再判断"直接跳过。

## 待机：黑屏 / 锁屏 / 睡眠时它不装忙

屏幕没了，"看一眼"就没有意义，所以待机期间**不抓屏、不自动判断、不打扰**。判据是**系统信号**，
不是"抓不到屏"（后者在远程会话断开时最容易误判）：

| 信号 | 来源 |
|---|---|
| 显示器开 / 关 / 变暗 | `GUID_CONSOLE_DISPLAY_STATE` 电源通知（`RegisterPowerSettingNotification`） |
| 锁屏 / 解锁 / 远程会话连断 | `WM_WTSSESSION_CHANGE`（`WTSRegisterSessionNotification`） |
| 睡眠 / 唤醒 | `WM_POWERBROADCAST` 的 `PBT_APMSUSPEND` / `PBT_APMRESUMEAUTOMATIC` |

进入待机时会**停掉正在跑的自动判断**（基于黑屏的结论没有意义）并且不欠账；醒来第一件事是
**作废全部过期观测**（清截图环、重置"停留 / 静止"计时）—— 否则"停留了 8 小时"这种数字
会直接喂给模型。

### 为什么要留一条「自愈」通道

信号是消息驱动的，**漏一条就会一直以为自己在待机**。实测踩过一次：18:09 收到"锁屏 + 显示器已关"，
之后解锁的通知没到，桌宠连着两小时没再看过一眼屏幕。这期间用户每次点它，模型手上**一张截图都没有**，
只能拿到窗口标题 —— 于是照标题"脑补"出「把采集方式改成 Windows 10 (1903 以上)」这类
看着专业、其实全是猜的建议。

所以现在每 `standbyProbeSeconds`（默认 30 秒）**自己核一遍实时状态**，不再信那三个缓存标志位：

| 检查 | 手段 |
|---|---|
| 最近有人动键鼠 | `GetLastInputInfo` 的闲置时间 `< standbyProbeIdleSeconds`（默认 60 秒） |
| 现在没锁屏 | `OpenInputDesktop` —— 锁屏时输入桌面换成 Winlogon，普通进程打不开 |
| 能抓到屏 | 真的抓一张 JPEG |

三条都成立 → 醒过来，并把 `Suspended` / `SessionLocked` / `PowerDisplayOn` **一起校准**
（不校准的话，下一个任意待机事件会立刻把它按回待机）。"连续抓不到屏"那一路（`captureFailLimit`）
继续保留：信号没来但确实抓不到屏时，抓几次失败就自己进待机。

除了那三拍一次的自检，还有两条更快的路：

- **前台窗口切换**：待机中也照样盯着前台窗口句柄 —— 窗口一换就是"人回来了"的强信号，
  会立刻试一次自愈（`focusTimer` 那 400ms 一拍）。锁屏 / 显示器关时自愈会自己拒绝，不会误醒。
- **手动出口**：右键 → 更多 → **「我是醒着的（现在就看一眼）」**，直接把三个标志位校准回
  "醒着"并立刻采一次。所以**不需要为了这个重启进程**。

### 没有截图时，不许照标题脑补

`payload.screen` 现在带 `shotCount` / `shotAgeSeconds`。截图缓冲是空的、或最新一张超过
`shotStaleSeconds`（默认 30 秒）时，提示词里会追加一条硬规则：**禁止**依据窗口标题推断画面内容，
**禁止**给出具体操作步骤（改哪个选项、点哪个按钮），只能说"现在看不到画面"或保持沉默。
自动路径本来就被本地闸门拦在"还没有画面"那一步，这条规则管的是手动点它的那一路。

## 本地闸门：该不该问模型，由本地代码决定

一次"自动判断"的成本不是一句话，而是：起一个 `pwsh` → 再起一个**完整的 DSH 进程** →
带最多 6 张截图的一次模型调用。实测 8–25 秒、真金白银。而绝大多数轮次的答案是"没事，不用说话"。

**"值不值得问"不需要模型判断** —— 屏幕变没变、窗口换没换、人还在不在，本地代码全知道。
这也是项目一贯的立场：门控是确定性代码，模型只负责"说什么"。

自动路径先过一道 `Test-WorthAutoJudge`，任一条命中就不起模型：

| 本地条件 | 判据 | 为什么合理 |
|---|---|---|
| 画面几乎没变 | 指纹差异 `< judgeMinFpDelta`（默认 12 / 上限 960）**且**前台窗口没换 | 8x8 指纹没动，就没有新东西可看 |
| 刚判过 | 距上次（真的起了调用那次）`< judgeMinSeconds`（默认 60s） | 抖一下不算变化 |
| 它连着几次都说"不用说" | 间隔按连续沉默次数放宽，最多 `silentBackoffMax`（默认 4）倍 | 越是没事越少问 |
| 人不在 | 无键鼠输入 `>= judgeIdleSkipSeconds`（默认 600s）**且**窗口没换 | 没人在看，别出声 |
| 待机中 | 见上一节 | 屏幕都没了 |
| **保险丝** | 不管画面多静，隔 `judgeMaxGapSeconds`（默认 300s）也要看一眼 | 防止闸门把桌宠"饿死" |

手动「问一句」**不走**这道闸门（那是你明确要的）。

实测（`-SelfTest` 第 5h 节，用假状态直接问闸门）：

```
画面没变 + 刚判过      → 画面几乎没变（差异 0 < 12），前台窗口也没换
画面大改但只过了 10 秒 → 距上次判断只有 10s（连续 0 次没说 → 间隔放宽到 60s）
画面大改 + 2 分钟前    → ''   （空 = 值得问）
同上但连续 3 次没说    → 距上次判断只有 120s（连续 3 次没说 → 间隔放宽到 240s）
画面没变但已 6 分钟    → ''   （保险丝：不能一直不看）
待机中                → 待机中
指纹距离 最暗 vs 最亮  → 960（最大 960）
```

省下的次数会直接写在「看它判过什么」卡片里：*本地闸门省下 N 次模型调用*。

> 两个坑记一下：指纹的字符是 `'0'(48)..'?'(63)`（生成时就是 `48 + lum/16`），**不是十六进制**——
> 我第一版测试拿 `'F'` 当最大值，算出 1408 > 理论上限 960 才发现。另外闸门必须带保险丝：
> 用户在一个窗口里连续工作时（8x8 指纹本来就看不出一行代码的变化），没保险丝就会一直跳过、
> 桌宠等于停了。

以前屏幕一黑，桌宠会每 2 秒刷一条 `截图失败：句柄无效`，还照样拿黑图去问模型——**失败只是症状，
它其实不知道发生了什么**。现在它直接读系统的三个正式信号（都在窗口消息里，不需要轮询）：

| 信号 | 来源 | 含义 |
|---|---|---|
| 显示器电源 | `RegisterPowerSettingNotification(GUID_CONSOLE_DISPLAY_STATE)` | 亮 / 灭 / 变暗 |
| 会话锁 | `WTSRegisterSessionNotification` → `WM_WTSSESSION_CHANGE` | 锁屏 / 解锁、远程会话连断 |
| 睡眠 | `WM_POWERBROADCAST` → `PBT_APMSUSPEND` / `PBT_APMRESUMEAUTOMATIC` | 系统挂起与唤醒 |

任一命中就进**待机**：

- 停止采样（不抓屏、不记窗口轨迹、不涨"停留时间"）
- 停掉自动判断定时器；正在跑的**自动**那一次直接掐掉（基于黑屏的结论没有意义）
- 关掉"用户优先"的补跑欠账——醒来会重新看一眼，比补一次基于黑屏的判断正确
- 外观变成安静的暗灰蓝 + 气泡说明原因（`run\pet-sleeping.png` 有预览）

恢复时**第一件事是把过期观测全部作废**：清截图环、清指纹、重置 `currentSince`/`stillSince`。
不清的话，「停留了 8 小时」「画面静止 8 小时」这种数字会直接喂给模型——项目里为这个坑修过一次。
然后立刻重新采一次样，并让自动判断接上。

**兜底**：有些情况信号不会来（最典型是**远程会话断开**）。所以还加了第二条路——
连续 `captureFailLimit`（默认 3）次抓屏失败就自己进待机，并且每 `standbyProbeSeconds`（默认 30 秒）
试抓一次，能抓到就自己醒。这样既不会刷警告，也不会永远待机下去。

自检里能直接看状态（`-SelfTest` 第 5g 节）：注册成功没有、三个信号当前值、以及用假信号走一遍状态机
（显示器关 / 锁屏 / 睡眠 → 都应为 `True`；全部恢复 → `False`）。本机实测：

```
待机信号注册：成功（显示器电源 + 会话通知）
显示器关掉后 → True    改成锁屏后 → True    改成睡眠后 → True    全部恢复后 → False
```

**规则**：用户对桌宠做的任何事（点它、长按说话、拖、拖入文件、开菜单、点选项、开对话…）
优先级最高。用户动手时，正在跑的**自动**判断立刻让位；用户停手 `userQuietSeconds`（默认 6 秒）后，
被让位的那次会自动补上。

| 情形 | 行为 |
|---|---|
| 自动判断正在跑，用户点了「现在说一句」 | 杀掉自动那次（**整棵进程树**）→ 立刻跑用户要的这次 |
| 自动判断正在跑，用户长按说了一句 | 同上：让位，然后派任务 |
| 自动轮询到点了，但用户 6 秒内动过 | **不起**，记一笔"欠一次"，等静默后补 |
| 用户双击（明确的"打断"） | 杀掉在跑的，**同时取消**待补的那次 —— 说要停就停 |

几个实现上的坑，都踩过并写在代码注释里：

- **必须杀整棵进程树**：advisor 是 `cmd.exe /c → pwsh → dsh` 三层，只 `Kill()` 最外层会把 dsh
  留成孤儿、继续占着会话写句柄，下一次判断立刻撞 `already owned by an active write handle`。
  现在统一走 `taskkill /PID <pid> /T /F`（`Stop-AdvisorProcess`）。
- **被打断的那次要清掉画面指纹**：指纹在那一轮开始时已经写成"判过了"，不清的话补跑会被
  "状态没变，不必再判断"直接跳过。
- 双击打断**不**触发补跑（那和用户的意图相反），所以它只更新时间戳、单独清 pending 标志。

## 托盘图标：隐藏之后能叫回来，顺手能暂停

桌宠是无边框、**不在任务栏占位**的窗口，所以右键菜单里的「隐藏」一旦点下去，
就没有任何东西能把它叫回来（只能重启一次）。托盘补的就是这个洞：

| 动作 | 效果 |
|---|---|
| 左键点托盘 | 显示 / 隐藏桌宠（Windows 习惯） |
| 右键 → 暂停/继续 | **暂停 = 停掉它自己的观察** |
| 右键 → 看它判过什么 / 退出 | 和宠物右键菜单同一份实现 |

图标用自绘的角色图（`Resolve-PetImage` 那一套，默认 `assets/pet.png`）缩到 16×16。
悬停能看到状态：`泡泡 · Bloop —— 在看着 / 已暂停（桌宠已隐藏）`。
暂停时**桌宠头顶左上角还会挂一个小暂停标**（深色胶囊 + 两道白竖杠，描白边）——
托盘图标只有鼠标悬上去才看得出状态，桌面上也得一眼看得见。画在 `DrawPauseMark`，
自检第 5t 节管它（没暂停不画、暂停画在左上、不出边界）。

暂停这件事**会留痕、也会记住**（这次专门补的）：

- 暂停 / 继续各往 `logs\interactions.jsonl` 记一条（`kind=pause` / `resume`，detail 写是谁按的：
  `tray` / `spend-cap` / `restored-from-pet.json`）。以前只改内存状态，于是"它怎么不动了"
  根本没法从日志分辨是**用户按了暂停**、**进了待机**、还是**真卡住** —— 实测为这个查过一次。
- 状态存进 `run\pet.json` 的 `paused` 字段：暂停着重启，起来**仍然是暂停**（否则会悄悄开始观察，
  顺手花钱）。启动时还会打一行 `[启动] 暂停=… 自动发言=… 派活目标=…` 到控制台
  （用 `start.cmd` 启动时会落进 `run\pet-console.log`）。
- `Sample-Once` 和 `Start-Advisor` 里各加了一道 `$script:paused` 判断 —— 暂停是靠停定时器实现的，
  而在飞的那一拍 Tick 照样会跑（实测：暂停着启动还会记一条 task + 一条 judge_skip）。

**暂停停的是什么**（刻意划清，免得两头不讨好）：

| 停 | 不停 |
|---|---|
| 采样（`sampleTimer`） | 应答器（`askTimer`）—— DSH 在等你回话，静音会让你以为 agent 卡住了 |
| 前台看门狗（`focusTimer`） | 派出去的 agent 的回报（`agentTimer`）—— 那是你要它做的活 |
| 自动判断（`autoTimer`） | 朗读 / 账本 / 打字 / 语音 / 点它说一句 |

也就是说：**暂停只关掉"它自己找话"，你要它说话随时都行。** 恢复时自动判断那一路会尊重
「自动发言」开关和待机状态（和启动时的条件一致），不会在待机里把它拉起来。

> 实现上有个 WinForms 的坑写在注释里了：`Icon.FromHandle` **不复制**像素，
> 位图必须留着（`$script:trayBmp`），只留 Icon 让 Bitmap 被回收，托盘会变成一块空白。

## 设置窗口：一个窗口改完 config.json

`config.json` 里现在有 74 个参数。想调「多久看一眼屏幕」，得先知道键名是 `sampleSeconds`、
还得记得单位是秒不是毫秒 —— 而且 JSON 少一个逗号整份配置就废了。所以有了这个：

**右键 →「设置 ▸ 所有设置…（一个窗口改完）」**

- 左边 11 个分组（外观 / 采集 / 判断闸门 / 对话窗口 / 语音 / 朗读 / 大脑与任务 / 记忆与日志 /
  待机与应答 / 任务规则表 / 监控区域），顶上还有搜索框 —— 打「采样」「token」都能直接滤到那几行。
- 每行都是「标签 + 行内速览 + 对得上的控件」：数字给数字框（范围**夹好**）、开关给勾选框、
  固定几档给下拉。**鼠标停在哪一行，底部就把那个键名和完整说明显示出来**（行内那条是省略过的）。
- 「本页恢复默认」只把这一页改回仓库里带的那份，而且仍然要点「保存」才写盘。
- 保存时**只覆盖改过的键**：`_xxxNote` 那些说明、以及以后新加的键都不会被这个窗口吃掉。
- 「任务规则表」是列表 + 字段编辑器（可以增删、上下移）；「监控区域」只能清除，
  重新框选还是走菜单里那个全屏选择器。

> ⚠️ 为什么参数表写在 `settings-window.ps1` 的 schema 里，而不是从 `config.json` 反推：
> JSON 里没有「这个键是什么类型 / 范围 / 单位」的信息，而**夹子**恰恰是最值钱的部分
> （比如采样下限 0.3 秒，防的是学出 0.05 秒把机器烧了）。schema 里还记了每项的默认值，
> 「本页恢复默认」靠的就是它。

### 排版：窗口拉大，内容要跟着长（踩过两次）

第一版把所有位置按 **920×700 的设计尺寸**算死在构建时，于是最大化了窗口，卡片还是原来那么宽、
右边空一大块（用户截图里「最大化但内容范围不变」）。更糟的是卡片左边距那行写成了

```powershell
$card.Left = [int](($24 + 208 + 16) * $s)   # ← `$24` 不是 24
```

PowerShell 把 `$24` 当成「变量 `$2` 后面跟个 4」，求值成 0 —— 卡片整体左移 16 逻辑 px，
**压到导航列表底下**，那一列的行标签左边被切掉（用户截图里的"遮挡"）。

现在位置统一由 `Update-DgLayout` / `Set-DgSectionLayout` / `Set-DgRowLayout` 三个函数算，
构建时排一次、`Resize` 时再排一次（最大化、拖边框、换显示器都走同一条路）：

| 元素 | 尺寸规则 |
|---|---|
| 导航 | 宽度固定 208，高度 = 客户区高 − 顶栏 − 底栏 |
| 卡片 | 左边 = 24 + 208 + 16，右边距 24，宽高随窗口 |
| 行内控件 | 标签列 300（最多占 45%），控件列吃掉剩余宽度并按类型**封顶**（数字 160 / 下拉 320 / 文本框 460），多出来的留成右边距 |
| 底栏 | 分隔线、提示条、三个按钮全部贴底，右对齐 |

控件宽度封顶是刻意的：数字框拉成 1500px 宽并不好看，"相对大小"要的是**内容区跟着窗口长**，
不是把每个输入框都撑到满。自检里新增了四种尺寸的回归（820×560 / 920×700 / 1180×800 / 1400×900），
每种都断言「卡片没压到导航、行没探出卡片、控件没探出行」：

```
pwsh -File settings-window.ps1 -DgsSelfTest
缩放检查 820x560：OK（内容跟着窗口长，未越界）
...
pwsh -File settings-window.ps1 -DgsRenderTo run\settings-wide -DgsSize 1400x900
```

自检（**不弹窗**，也不动真的 config.json）：

```
pwsh -File settings-window.ps1 -DgsSelfTest
```

它会核对「每行的控件真的加进了那一行、而且没越界」，再拿 `config.json` 的**副本**跑一次存盘
往返（不改任何东西 → 文件必须字节不变；改一个开关 → 只该动那一个键、`_note` 必须原样还在）。
`DesktopGuide.ps1 -SelfTest` 的第 5r 节也会跑一遍，并顺带断言「config.json 里的参数一个都没漏」。

想直接看每个分组长什么样（离屏渲染成 PNG，一样**不弹窗**）：

```
pwsh -File settings-window.ps1 -DgsRenderTo run\settings-render
```

也可以单独开：`pwsh -File settings-window.ps1`（改的是同一份 `config.json`）。

## 采样节奏：换窗口立刻看一眼，多久看一次跟着任务走

「采样」= 看一眼前台窗口 + 抓一张缩图 + 算一次画面指纹。这里其实有**两个独立的量**，别混：

| 量 | 谁决定 | 默认 |
|---|---|---|
| **多久发现一次「换窗口了」** | `focusWatchMs`（前台窗口看门狗轮询间隔） | 400ms |
| **多久看一眼屏幕** | 任务档 `sampleSeconds`（`config.taskRules`），学习表 `task-samples.json` 覆盖 | 2s；卡牌 0.6s / 视频 8s / 桌面 10s |

看门狗只做一件极便宜的事：`GetForegroundWindow()` 拿**窗口句柄**，和上次比。变了就立刻采一次
（`Sample-Once -Force`），不等定时器 —— 换程序恰恰是最值得立刻看一眼的时刻（例如牌局开始）。

- **判据是句柄，不是进程 pid**。同一个进程里换窗口时 pid 完全一样，只看 pid 会把这类切换整个
  漏掉。本机实测，同时开着 ≥2 个可见顶层窗口的进程有 4 个：两个「文件资源管理器」窗口
  （pid 53392，不同 hwnd）、三个 Edge 窗口（pid 29556）。
- **标题不参与比较**：浏览器/播放器的标题一直在变（进度、歌名），那不是切换，跟着它触发只会
  把采样刷成噪声 —— 而每次采样都带一张截图。
- **采样节奏每次采样都对账**（`Sync-SampleCadence`）。原来是「档名变了才重设定时器」，两种情况
  下节奏是错的：① 同一条规则下的两个进程（balatro → hearthstone 都命中「卡牌/回合制游戏」），
  档名一样，前一个进程的学习值会被后一个继续沿用；② 模型给了 `SAMPLE: <秒>`、或跳变学习改了
  学习表之后，当前档当场不生效，要等下次换档。下限 300ms 的兜底照旧（防「学出 0.05 秒把机器烧了」）。

自检第 5q 节把上面这几条钉住了（用假定时器看 `Interval` 有没有真的被写进去，不动真实节奏）。

## 子 agent 观察：它派出去的活也在观察范围内

桌宠现在不只看屏幕，也看**自己派出去的后台 agent**（包括 agent 再开的**子 agent**）：

| 观察面 | 怎么体现 |
|---|---|
| 用户看得见 | 后台 agent 跑的时候，气泡显示它**此刻在干什么**（`agent-xxxx 正在：改文件：xxx.docx`），3 秒刷新一次 |
| 主 agent 判断时知道 | payload 里新增 `agents` 字段，提示词里明确写「**这是用户自己派出去的活，不是异常**」 |
| 子 agent 也覆盖 | agent 调 `subagent` / `subagent_fork` 时事件流里就是一条 tool_call，进度行直接显示「子 agent：…」 |

进度是从 agent 的 `--json` 事件流尾部读的（`Get-AgentProgress`）：优先用最后一条 `tool_call`
翻译成人话（读文件 / 改文件 / 跑命令 / 子 agent / 交付文件…），没有就退回「正在整理结论…」。

**为什么这条重要**：不给这个字段，主 agent 会把"屏幕很久没动"误读成"用户卡住了"——
而真相常常是"用户派了活出去，正在等它跑完"。

实测提示词（合成 payload 跑 `advisor-dsh.ps1`，直接读回 `run\main-agent.task.txt`）：

```
后台正在跑 1 个 agent（**这是用户自己派出去的活，不是异常**）：
  - agent-abc123（DeepSeek Flash · 完全访问）正在：子 agent：检查文档结构
      它领到的任务：把 report.docx 第三段加粗
距用户上次操作桌宠：3 秒（很小 = 用户此刻正在跟桌宠互动，别插话）。
```

主 agent 的回答也印证了：`REASON: 距上次操作仅 3 秒、后台任务正常推进，规则要求此时不插话。`

> ⚠️ 验证时踩过一个小坑：`run\main-agent.task.txt` 是**共享文件**，桌宠自己的自动轮询
> （每 `autoMinutes` 分钟一次）会把它覆盖掉。做合成验证时要先停掉桌宠，或者立刻读回。

两个新配置项：`userQuietSeconds`（默认 6）、`observeAgents`（默认 true）。

## 它刻意不做什么

## 账本（充值播报）：自己查、自己记，不依赖别的插件

余额涨了（有人充值）就在气泡里说一声。**这套是桌宠自己的实现**，不需要先装任何别的插件才能用：

| 来源 | 需要什么 | 说明 |
|---|---|---|
| **实时查余额** | 一个 DeepSeek API key | `GET https://api.deepseek.com/user/balance` |
| **本地记账** | 无 | 每次查到的余额记进 `desktop-guide/ledger.json`，于是"今天花了多少"和"是不是充值了"都算得出来 |
| 都没有 | — | 明说缺什么（"配一个 DeepSeek API key 即可"），不装死 |

key 的查找顺序和项目里 `advisor-minimax` / `advisor-openai` 一致：**环境变量 `DEEPSEEK_API_KEY` → `run\deepseek.key` 文件**。

**充值判据是"余额变大"**（默认 ≥ 0.5 元才播报，`rechargeMinDelta` 可配）——比读任何记账字段都直接。
启动时先读一次做基线，所以重启不会把历史充值当成刚发生再播一遍。每 20 秒轮询一次（`ledgerWatchSeconds`）。

### 每日消费上限：到线自动暂停

`dailySpendCapYuan`（默认 **50** 元，0 = 不设上限，设置窗口里也能改）。账本轮询发现「今天花了」
到线时：**自动暂停**（停掉采样 / 自动判断 / 前台看门狗，不再花新钱）+ 气泡上说明 + 记一条
`kind=spend_cap` 日志。气泡页脚也会把上限一起显示：`今天 ¥12.3 / 上限 ¥50`，到线时多一个「（已到上限）」。

三个刻意的取舍：

- **触发一次后按「哪一天 + 哪个上限」记账**（`Get-SpendCapKey`）：跨天、或你把上限调大，都会重新武装 ——
  否则改成 100 之后它再也不管了。
- **到线后手动点「继续」不会立刻又被暂停**：那是你的明确选择，不该跟你对着干；但今天再到线还是会暂停
  （key 没变时不会重复触发）。
- **只挡自动观察，不挡你手动点它**：手动问一句是你主动要的，仍会花钱 —— 这一点在气泡说明里写明了。

判据本身抽成了纯函数 `Test-SpendCap`，自检第 5v 节直接喂数字（12.3/50 不管、50/50 停、0 不设上限、
已触发不重复、改上限/跨天重新武装 → 5/5）。

### 出问题时日志里能查到什么

`logs\interactions.jsonl` 除了交互，还专门记了这些"桌宠可能出问题"的时刻（原先很多是静默 catch，
表现成"它就是不动了"，日志里一个字都没有）：

| kind | 什么时候记 |
|---|---|
| `pause` / `resume` | 暂停 / 继续（detail 写是谁按的：tray / spend-cap / restored-from-pet.json） |
| `spend_cap` | 今天花费到上限、自动暂停 |
| `standby` / `wake` | 进待机（signal / capture） / 被唤醒（谁唤醒的） |
| `capture_fail` | 抓不到屏（记每轮第一条和最后一条，0.6 秒一档也不会刷爆日志） |
| `sample_stall` / `sample_resume` | 超过「采样间隔 ×6、至少 60 秒」没抓到新画面 → 重建抓屏线程 |
| `tick_error` | 采样 / 焦点定时器里抛异常（同类只记第一条，换错误再记） |
| `judge_error` / `judge_timeout` | 大脑没输出 / 报错；或超过 `advisorTimeoutSeconds` 被掐掉 |
| `task` / `judge_skip` | 换任务档；本地闸门为什么跳过这一次（含具体数字） |

> **如果你本机已经装了 `dsh-whale-widget`（DSH 里那个鲸鱼挂件）**：它的账本在
> `~\.dsh\.dshw-usage.json`（余额 / 今日花费 / 近 7 天 / 每轮消耗，字段比我们这套细）。
> 本项目**不读它**——那是别人的插件，读它等于"不装就用不了"。想让它当数据源的话，
> 自己写个几行的小脚本把它转成 `ledger.json` 的格式即可。
>
> 同理，本项目的**角色图也不再从那个插件的目录里取**了：现在只认
> `config.json` 的 `petImage`、环境变量 `DG_PET_IMAGE`、或本目录 `assets\pet.png`；
> 三条都没有就退回代码绘制的圆脸（`-SelfTest` 的预览图里那张）。
> 想用它的鲸鱼形象自用，把那张 PNG 的路径填进 `config.json` 的 `petImage` 就行 ——
> 但注意**它的素材授权不允许随本项目分发**（见 `THIRD_PARTY_NOTICES.md`）。

| 不做 | 原因 |
|---|---|
| 不监听键盘输入 / 不读剪贴板 / 不记录窗口里的文字 | 侵入性太强，对判断"卡没卡住"帮助也有限 |
| 不把截图落盘 | 只在内存环形缓冲；落盘只有窗口标题/进程/时间 |
| 不抢焦点 | `WS_EX_NOACTIVATE`：可点可用，但永远不激活、不打断你 |
| 不写"什么时候该说"的规则 | 判断交给模型；它返回 `SILENT` 就安静待着 |

## 环境要求

**需要 PowerShell 7（`pwsh`）**。Windows PowerShell 5.1 用的是 .NET Framework，
`Add-Type` 的引用解析完全不同，会直接报错退出——脚本开头有版本守卫，会明确告诉你。

### DSH / node / Edge 装在哪：`paths.ps1`

原先 DSH 的安装位置在 11 处硬编码成 `D:\DeepSeekHarness\...`，换台机器整个桌宠就哑了，
而且报错只会说「找不到文件」。现在所有机器相关路径都收在 `paths.ps1`，解析链统一是：

```
1. 显式配置（config.json / agents.json）—— 可以写 {root} {dshRoot} {userProfile} {dshHome} 占位符
2. 环境变量（DG_* 一族）
3. 自动探测：正在运行的 DSH 进程 → PATH 上的 dsh.cmd → 常见安装位置
```

装了非默认位置时，最省事的做法是设一个环境变量：

| 变量 | 作用 |
|---|---|
| `DG_DSH_ROOT` | DSH 安装根目录（**一般只需要设这一个**） |
| `DG_DSH_EXE` / `DG_DSH_CLI` / `DG_DSH_CMD` | 单独指定三个入口（极少用） |
| `DG_NODE` | 跑 STT 用的普通 node.exe |
| `DG_EDGE` | 对话窗口用的 msedge.exe |
| `DG_PET_IMAGE` | 桌宠角色图（带透明通道的 PNG） |

> 注意 `cli.js` 在 `app.asar` **归档里面**，`Test-Path` 看不见它（逐级测到 `app.asar\` 就是 False），
> 但 Electron 读得到 —— 所以这一项不能用"文件存在"来判断，只能校验挂载点 `app.asar` 在不在。
> 这是踩过的坑，`paths.ps1` 里有注释。

自检的 5k 块会打印解析结果，并断言两件事：四个入口都能解析出来，以及
**config.json / agents.json 里不再出现本机用户名或安装盘符的字面量**（防止以后又写回去）。

## 主 agent 的工具裁剪（省 token + 少走错路）

主 agent 的活是"看一眼，判断要不要开口"，它**只会用 `read_image`**（实测一条会话里 174 次工具调用全是它）。
但它跑在 DSH 的 `headless` profile 上，那里默认把整套工具都挂上了 —— 24 个工具的 schema ≈ **19,731 字符/轮**
（约 5k token，而且是每一轮都要重发的固定前缀）。

`agents.json` 的 `mainAgent.disableTools` 按**行 id** 把这些插件整行关掉（patch 层的 `disabled: true`，
只影响主 agent 那个进程；工作 agent 走另一份 patch，工具一个不少）：

```json
"disableTools": ["tool-pwsh", "tool-fs-search", "tool-todo", "tool-goal", "plan-mode",
                 "tool-jobs", "tool-subagent", "tool-subagent-control", "tool-subagent-list-agents",
                 "tool-subagent-fork", "tool-workflow", "workflow-ptc", "tool-web",
                 "tool-skill", "tool-ralph", "tool-bash"]
```

实测（同一个 `--profile headless`，同一句话）：

| | 改动前 | 改动后 |
|---|---|---|
| 主 agent 可见工具 | **24** 个 | **4** 个（`read_image` / `read` / `write` / `edit`） |
| 工具 schema 字符数 | 19,731 | **2,707** |

`write` / `edit` 去不掉 —— 它们和 `read_image` 同属 `dsh-tool-fs` 一行插件，那一行没有"只开读"的开关；
但主 agent 的权限是 `read-only` 沙箱，这两个调用会被直接拒，留着只是占一点 schema。

**关掉的是"工具行"，不是服务本身**：`tool-subagent` 关了不等于 subagent 服务没了。要恢复哪一项，
把对应 id 从数组里删掉即可。

## 七个踩过的坑（都很隐蔽，写下来免得重来）

### 1. DPI：必须在第一行就设置感知

这台机器是 **200% 缩放**：物理 2880×1800，逻辑 1440×900。进程如果是 DPI-unaware：

- **给的坐标会被系统乘 2 再落地**——我算的"右下角 (1080,610)"实际落到了物理 (2160,1220)，
  于是我自己截的图（只覆盖左上 1440×900）里永远看不到它，一度以为是"被别的窗口盖住了"；
- **逐像素 alpha 的分层窗口会完全不合成**——`UpdateLayeredWindow` 返回 True，但窗口退化成
  一块空白底色。桌宠的透明圆角、角色图全都不显示。

所以脚本的第一件事就是 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`，
所有尺寸再乘以 `dpi/96` 缩放。

### 2. 别依赖 `Invalidate()` → `OnPaint`

分层窗口下 `Invalidate()` **不会**再触发 `OnPaint`（实测 10 秒内 `RenderCount` 一直是 1），
所以内容只被推送过一次。改成在动画定时器里**直接调用 `Render()`** 主动推送。

### 3. `Label.AutoEllipsis` 会让这个控件在 WM_PRINT 下**整块不画**

做设置窗口时踩到的：标签开了 `AutoEllipsis = $true`，屏幕上一切正常，但 `DrawToBitmap`
（以及任何走 WM_PRINT 的截图/打印路径）里**标签列整个消失**——同一行里的 TextBox、按钮都好好的，
于是很容易误判成"布局算错了"。排查到最后是 `AutoEllipsis` 把 Label 切到了另一条绘制路径。

改法：**自己截断 + 自己加 `…`**（`settings-window.ps1` 的 `Limit-DgText`），
顺手还能收在标点处（裁成半个词看着像坏了）。自检那套离屏渲染就是靠这个才看得见内容。

### 4. 窗体 Dispose 之后，WinForms 定时器还会再跳一拍

`Timer` 是**窗口消息**驱动的：窗体 Dispose 了，消息队列里压着的那一拍照样会到，
然后在 `Render()` 里对已释放的窗体 `CreateHandle()` → `ObjectDisposedException` 直接弹
「未处理异常」对话框（实测：自检里一 `DoEvents` 就中）。

改法：`PetForm` 重写 `Dispose(bool)` 停掉并释放两个定时器，`Render()` 开头再挡一下
`IsDisposed || Disposing`。两道都要——只停定时器挡不住已经在队列里的那一拍。

### 5. 字号别再乘一遍 `uiScale`（第一次做设置窗口就踩了）

点是**物理单位**：GDI+ 会自己按设备 DPI 把 pt 换成像素。192dpi（200% 缩放）下 9.5pt 已经是
25px、行高约 32px —— 这**正是** Windows 缩放想要的效果。做设置窗口时我按仓库里其它对话框的
写法把字号也乘了 `uiScale`，于是 9.5pt 变成 19pt：文本行高从 32px 涨到 74px，两行字挤在
一行的高度里互相压住。用户的原话是「字体太大了都堆起来了」。

顺带一个更隐蔽的：**别用 `TextRenderer.MeasureText` 量行高去设 Label 高度**。同一个 19pt 字体，
它量出来 66、Label 的 `PreferredHeight` 是 74 —— 按 66 设高度会把字裁掉、还紧贴下一行。
`settings-window.ps1` 的 `Get-DgLineHeight` 用的是后者。

> 桌宠自己的气泡是**反着补偿**的：`SetTextFont` 里把字号乘了 `uiScale`，所以 `config.json` 的
> `fontSize` 才写成 6.0（乘 2 之后约等于正常的 12pt）。设置窗口不跟进这个绕法 ——
> **字号给"96dpi 视角"的值，位置和尺寸才乘 `uiScale`**。
>
> ⚠️ **气泡这一处别改**。看着像"双重缩放没除干净"，其实 `fontSize: 6.0` 就是配着它算出来的，
> 观感是定下来的；把它改成"不乘 `uiScale` + `fontSize` 写 9.5"等于换一套字号体系，
> 气泡会整体变样。设置窗口是独立窗口，字号单独给值，两者互不影响。

### 6. 桌宠自己就在画面里（"自己触发自己"）

抓屏是整屏的，**桌宠自己也在里面**。它一弹气泡，压在它身上那几格灰度就变了 —— 等于"我自己说了一句话"
被当成"画面变了"，下一轮更容易再开口。这不是推理出来的：自检里拿一块它那么大的白板（430×250 逻辑 px）
顶替气泡，量到的指纹差**随它当时在哪而变**：

| 白板放在哪 | 指纹差 | 与 `judgeMinFpDelta`（12）比 |
|---|---|---|
| 右下角、整块可见 | **26** | 过线 —— 自己弹一次气泡就够触发一次判断 |
| 贴着屏幕右边、一半在屏外 | **5** | 没过线 |

所以问题不是"有没有"，是"**它站在哪决定了自己会不会触发自己**" —— 这种"偶尔多问一次、翻日志还查不出原因"
最难受。桌宠**可以拖到任何地方**（`run\pet.json` 里存着 x/y，实测这几分钟就从 `2342,723` 变成 `2316,1163`），
所以自检不写死位置：白板放在它**当时记录的位置**上，只断言"挖洞之后差值一定更小"。

改法：`Capture.SelfRect` 在**每次**抓屏前由 UI 线程写入（就是 `$pet.Bounds`，所以拖到哪都跟着），
`FingerprintOf` 把落在它里面的格子（重叠 ≥ 30%）写成固定的 `'0'`。**为什么写固定值而不是记个掩码**：这么写之后
`Get-FpDistance`（差值之和）和 `$fp -ne $lastFp`（"静止了多久"）两条路都自动忽略这些格子，
调用方一行都不用动；掩码方案得把 mask 一路穿到每个比较点。

> 一个已知且可接受的行为：桌宠被拖走时，挖洞的格子集合会变（老位置不再挖、新位置开始挖），
> 所以**拖动本身**会造成一次指纹跳变。但拖动确实是"画面真的变了"，而且拖它的人就在现场 ——
> 这次跳变是对的，不用额外处理。

自检（第 5y 节）现场复现 + 验证：同一个变化，修前差 15、修后差 0（挖掉 6/64 格）。
⚠️ 这一段会在屏幕上闪一块白板约 1 秒，就是在测这个。

> 同一类问题的**另一半还没处理**：截图里也有它自己，模型可能把自己上一句当成屏幕上的内容。
> 这次只改了指纹（影响"什么时候开口"）；截图那条只影响"说什么"，量级小，等有现场图再定。

### 7. 参数是**建立时**固定的：改了不等于生效（监控区域）

抓屏跑在一个常驻的 runspace 里（每帧重建太贵，见 `Reset-CaptureRunspace`），而监控区域是**建它那一刻**
用 `AddArgument` 固定下来的。于是「框选监控区域」改了 `cfg.region`、也清了截图环，抓出来却还是整屏的 ——
要等到重启、或者一次"抓屏停滞自愈"把 runspace 重建掉，新区域才生效。表现就是**"框了没用，重启一下就好了"**，
日志里一个字都没有。四个入口（右键框选 / 取消框选 / agent 的 `WATCH:` / 设置窗口保存）当时都是这样。

修法：把这个动作收成一处 `Sync-CaptureRegion`（清截图环 + 重建 runspace），四个入口都走它。

> 这里坑的不是哪一行写错了 —— 那几处代码看起来完全正确：它确实改了配置，也确实清了缓存，
> 只是**没有人替"让新参数落地"负责**。清环和重建是两件事，原来只做了前一件。
>
> 自检（第 5z 节）钉的就是这个顺序：**先**在整屏状态下把 runspace 建好（这才是出 bug 的现场），
> **再**只改区域、立刻抓一张量像素宽。600 宽的假区域必须立刻抓出 600 px 宽 —— 老行为会是整屏的 1024。
> 实测输出：
>
> ```
> 建 runspace 时是整屏 → 抓出来 1024 px 宽
> 只改区域、不重启     → 抓出来 600 px 宽（新区域是 600 px）
> 判定：✔ 区域改了立刻生效（老行为：这里会是整屏宽度，得重启才变）
> ```

### 8. `TextRenderer.MeasureText` 量宽度也偏窄（单位标签只剩一个"小"）

同一类坑，换到宽度上：单位标签（`小时` / `秒` / `种`）的框原来是照 `TextRenderer` 量出来的宽度给的，
结果**只显示一个"小"**。原因和上面第 5 条一模一样 —— `MeasureText` 量得比 Label 实际绘制窄，
Label 于是把"小时"折成两行，而框高只够一行，第二行正好被裁掉。

改法（`settings-window.ps1` 的 `New-DgRow`）：量出来再加一点余量，并且给一个下限
（`max(量出来 + 24px, 70px)`）。顺带说明为什么**不**用固定的 70px 了事：别的语言 / 更长的单位
（"毫秒"、"百分点"）字变宽之后 70px 又不够，下限 + 实测才是两头都兜住。

### 9. 卡片左边距写成 `$24`（当成 24 用了）

`$card.Left = [int](($24 + 208 + 16) * $s)` —— `$24` 不是 24，PowerShell 把它当成
「变量 `$2` 后面跟个 4」，求值成 0：卡片整体左移 16 逻辑 px 压到导航列表底下，
**那一列的行标签左边被切掉**（用户截图里的"遮挡"）。这种拼写错误解析器不会报，因为语法完全合法。

自检里现在有一条专门盯它：卡片左边缘必须比导航右边缘大（`卡片压到导航底下` 就是这条断言）。

## 大脑（可插拔）

`config.json` 里的 `advisor` 是一整条命令行，运行时会**在末尾追加 payload.json 的路径**。
它把要显示的那句话打到 stdout 即可。留空则用内置的「事实播报」大脑（不调用模型）。

> ⚠️ 命令行**不要自己再包一层引号**。它通常已经带引号（`-File "路径"`），外面再包会让
> `cmd /c` 把它当成一个程序名、参数全丢。只给 payload 路径加引号。

内置实现（本机 Ollama，零 key、数据不出机器）：

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "...\desktop-guide\advisor-ollama.ps1"
```

### 三种大脑来源，都在设置窗口里选

**右键 →「设置 ▸ 所有设置…」→「大脑与任务」→ 第一行「大脑来源」**，三选一（外加自定义）：

| 选它 | 用的是什么 | 它的参数在哪 |
|---|---|---|
| **和 DSH 同一个模型** | DSH 自己的常驻 agent 会话（用的是你在 DSH 里登录的账号，模型表在 `agents.json`） | 同一页的「DSH 模型」下拉 —— 选另一个就等于把"同一个模型"换掉（写 `agents.json` 的 `mainAgent.model`） |
| **网络模型（用 API key）** | 任意 OpenAI 兼容端点，默认 DeepSeek | 「网络模型地址 / 模型名 / API key / 连通性 / 发截图 / 生成上限」六行 |
| **本地 Ollama 模型** | 本机 Ollama，零 key、数据不出机器 | 「Ollama 地址 / 模型 / 探测 / 发截图 / 温度 / 上下文 / 生成上限 / 驻留时间」 |
| 自定义 | 你自己写命令行 | 下面那两行「常驻大脑命令 / 「问一句」命令」 |

「大脑来源」是个**翻译层**：保存时把 `advisor` / `advisorFast` 两条命令改写成对应脚本，
配置文件里仍然只有那两条命令（可读、可手改，别处引用的也是它们），不引入第二套事实来源。
选「自定义」就不动你手写的命令；选「本地 Ollama」会顺手把「大脑超时」抬到 120 秒（本地模型慢，
30 秒太紧）。三种来源的参数**只有当前在用的那一种会生效**，其余几行留着不碍事、换回来时还在。

#### 网络模型：key 不进配置文件

「API key」那一行是**遮住的输入框 + 「写入」按钮**：点写入只把 key 写进 `run\openai.key`
（和右键菜单「填 API key」同一个文件、同一套语义），**不进 `config.json`、不写日志**；
输入框留空再点一次「写入」= 删掉 key。写完那行「连通性」会立刻刷新 —— 它是拿 key 问一次
`/models`：连上就列出可用模型（这些模型同时喂给上面「网络模型名」下拉），连不上会写清是
哪一步失败（没 key / 401 / 连不通）。**没填 key 就不发请求**，所以离线/没用过这一步的人
打开窗口不会卡。

#### Ollama：模型列表是当场问本机的

同一页下面那几行就是 Ollama 的全部旋钮（都存在 `config.json`，环境变量可覆盖）：

| 键 | 默认 | 说明 |
|---|---|---|
| `ollamaUrl` | `http://127.0.0.1:11434` | 服务地址；换机器/改端口只改这里 |
| `ollamaModel` | 空 | 空 = 用本机第一个。下拉里的模型是**当场问 `/api/tags` 列出来的**（带「能看图 / 会思考」标注） |
| `ollamaVision` | 空 = 按模型名判断 | 只有多模态模型（qwen3-vl / llava / gemma3 …）收得下截图 |
| `ollamaNumCtx` | 8192 | 上下文；截图很占，太小会把记忆挤掉 |
| `ollamaNumPredict` | 400 | 生成上限。一句话够用，也顺便防止思考型模型无限生成 |
| `ollamaKeepAlive` | `10m` | 模型留显存里多久；设短了每次都要重新加载，明显变慢 |
| `ollamaTemperature` | 0.3 | 温度 |

设置窗口里那行「本机探测」直接显示探测结果（连没连上、有哪些模型、哪些能看图），
所以**没装 Ollama 的人也不会莫名其妙** —— 最坏就是一行红字说"没连上"。
命令行自检：`pwsh -File advisor-ollama.ps1 -Check`：

```
OK  url=http://127.0.0.1:11434  version=0.35.1  模型 4 个
    qwen3-vl:2b, qwen3:14b, qwen3:8b, qwen2.5-coder:3b
```

**实测（这台机器，200% 缩放）**：`qwen3:8b` 冷启动 32 秒、模型热着 5 秒，输出就是标准的
「一句话 + `REASON:`」两行；`qwen3-vl:2b` 会**无视 `think=false`** 一路在思考里绕圈 ——
400 token 上限一到只剩思考、没有结论。所以脚本里有一道兜底：`content` 空而 `thinking` 非空时，
自动用 4 倍预算再问一次；还是空就直说
「（qwen3-vl:2b 只输出了思考过程、没给结论 —— 换个文本模型，或把 ollamaNumPredict 调大）」，
而不是把思考过程当结论糊到气泡里。

> 换到 Ollama 时**超时会自动抬到 120 秒**（原来 30 秒对本地模型太紧）。想改回来就在
> 「大脑超时」那行改。
>
> 范围说明：这一项管的是**判断用的那个脑子**（自动发言 / 问一句）。对话栏和「派活给 agent」
> 走的是 DSH 自己的会话与工具，不在这一项里 —— 本地小模型也扛不住那套工具调用。

### 每次沉默都带理由（用来复盘它判得对不对）

大脑可以多回一行 `REASON: ...`。**那一行不显示在气泡里，只写进 `logs/utterances.jsonl`**。
于是你翻日志时能看见它每次为什么开口、为什么沉默：

```json
{"at":"...","auto":false,"text":"（它选择不说）","reason":"Codex正在处理任务（32秒→1分2秒），属于正常等待，没有可证明的错误","window":"ChatGPT|ChatGPT"}
```

这是判断"它判得准不准"唯一的办法——只看气泡，你分不清一次沉默是判对了，还是根本没看见。

### 输出是纯文本，不渲染 Markdown（要么渲染、要么不渲染）

气泡（`DesktopGuide.ps1` 的 `DrawBubble`）和对话栏（`chat-panel.ps1` 的 `ChatBubbleView`）都是
自绘的纯文本控件（`TextRenderer.DrawText`），**不编译 Markdown**。模型只要输出 `**首选：…**`、
`# 标题`、反引号、`- 列表`，屏幕上就会原样出现这些符号 —— 既不美观，也白白吃掉气泡那点宽度。

两条路只能选一条：真渲染，或者不渲染。这里选**不渲染**，理由是气泡只有一两行的位置、字号还很小，
为它写一套 Markdown 排版引擎（多字体混排、列表缩进、表格）收益极低、出错面很大。
落地方式有两层：

| 层 | 做什么 | 在哪 |
|---|---|---|
| 进屏前压平 | 把标记转成纯文本（`**粗**`→`粗`、`# 标题`→`标题`、`` `code` ``→`code`、`-`→`·`） | `md-plain.ps1` 的 `ConvertTo-PlainText` |
| 源头不产生 | 提示词明确要求纯文本，且不再用 `**` 写提示词本身（否则模型会照着学） | `advisor-*.ps1`、`presets/*.txt` |

它在做减法时也在做保护：`**/*.js`（glob）、`2 * 3`、`foo_bar_baz`、`__init__`（代码）
都不会被当成 Markdown 吃掉。原始模型输出不丢，还在 `run/advisor.out.txt` 里；
`logs/utterances.jsonl` 记的是**气泡里实际显示的那句**。

### 提示词里的"闭嘴清单"

第一次带截图时它开口说「响应在跑，等着就行」——**那是噪音**，用户自己看得见。
收紧提示词后，同一份 payload 改为沉默。现在系统提示里明确列了两栏：

| 一律 SILENT | 才值得开口 |
|---|---|
| 播报状态（任务在跑 / 加载中 / 已处理 N 秒） | 屏幕上有**可证明的错误** |
| 复述用户正在做的事、正在看的报错 | 做法**与他自己的目标不一致** |
| 用户只是在等待、浏览、阅读、思考 | 同一件事**反复失败**、原地打转 |
| 不确定屏幕上在发生什么 | 漏掉**关键检查步骤**且后果具体 |

### 换成 MiniMax（能看图）

从本机 DSH 的 provider 目录读到的真实能力定义：

| 模型 | `input` | 看图 |
|---|---|---|
| `MiniMax-M2.7` / `-highspeed` | `["text"]` | ❌ |
| **`MiniMax-M3`** | **`["text","image"]`** | ✅（最长边 2000、单张 ≤4.5MB、JPEG 80） |

```powershell
$env:MINIMAX_API_KEY = '你的 key'
pwsh -NoProfile -ExecutionPolicy Bypass -File advisor-minimax.ps1 -Check   # 先自检
```

然后把 `config.json` 的 `advisor` 指向 `advisor-minimax.ps1`。

**更稳的做法：把 key 写进文件**（推荐）。这样不用每次设环境变量，也**不会因为漏打引号**
被 PowerShell 当成命令去执行（`$env:X = sk-abc` 不加引号就是这个下场，报 `CommandNotFoundException`）：

```powershell
$p = ".\run\minimax.key"      # 在 desktop-guide 目录下跑
New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
Set-Content -LiteralPath $p -Value (Read-Host -MaskInput '粘贴 MiniMax API Key') -NoNewline -Encoding UTF8
```

advisor 的查找顺序是：环境变量 → `run\minimax.key` 文件。

> ⚠️ **隐私差别**：Ollama 全程本机；MiniMax 会把**截图和窗口标题上传到它的服务器**。

## 实测数字（这台机器）

| 项 | 数值 |
|---|---|
| 前台窗口识别 | 正确（进程名 + 窗口标题） |
| 截图 + 缩图 + JPEG | 110–360 ms，约 40–60 KB |
| 采样间隔 / 截图间隔 | 2 秒 / 5 秒，内存里保留最近 6 张 |
| qwen3:14b 热态一句建议 | 约 3 秒 |
| qwen3:14b 冷启动 | 约 50–60 秒 → 所以启动时会自动预热一次 |

## 对照实验：看得见屏幕 vs. 看不见

`compare.ps1` 拿同一份 payload 跑两遍（`-Fresh` 会先重新采样一段时间）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File compare.ps1 -Advisor minimax -Fresh -FreshSeconds 40
```

实测结果（MiniMax-M3）：

| | 结果 |
|---|---|
| **【A】只给窗口轨迹** | 沉默，理由："没有足够信息判断" |
| **【B】轨迹 + 6 张截图** | 「ChatGPT 响应已经在跑了（已处理 1 分 2 秒），不用做任何操作」 |

**B 说出了 A 不可能知道的东西**（那个 1 分 2 秒的进度），视觉的价值坐实了。
但 B 这次**开口是错的**：用户自己看得见进度，这是噪音；而且它把 Codex 的任务误认成 ChatGPT。

> 结论：难点从来不在"看不看得见"，而在"该不该说"。视觉解决了前者，没解决后者——
> 后者只能靠提示词约束 + 用 `REASON` 日志反复校准。

### 视觉精度的旁证

用 `advisor-minimax.ps1 -PayloadPath <payload> -Probe` 让它只描述看到什么（不做判断），
它能读出浏览器标签页标题、地址栏 URL、侧边栏项目列表、聊天标题、甚至任务计时从 32 秒到 1 分 2 秒的递增。

## 已知限制

| 限制 | 说明 |
|---|---|
| **只靠窗口标题时建议质量差** | 实测：轨迹显示"在同一个报错页和编辑器之间来回切 9 次"时，模型说的是"你可能在处理列表索引超出范围的错误"——**用户当时搜的就是这个报错**。信息量近乎为零。这就是必须接视觉模型的原因 |
| 多显示器只抓主屏 | `Capture` 只取 `PrimaryScreen` |
| 全屏独占程序抓不到 | GDI 截图的固有限制 |
| ~~托盘未做~~ → 已做｜~~开机自启未做~~ → 已做 | 托盘图标：左键显示/隐藏，右键可暂停/继续；开机启动勾在「设置」里，写 HKCU 的 Run 项 |
| **语音输入只能"整句"** | 录完才识别（不是边说边出字）。SenseVoice 没流式接口，一次一句反而是它的用法 |

## 下一步（未做）

1. **接视觉模型**（MiniMax-M3 或本机拉 `gemma3:4b`），让截图真正被用上——这是当前最大短板。
2. 自动触发的策略——暂停用固定的"每 N 分钟问一次"，真正的"何时该说"要用真数据决定。
3. ~~托盘图标~~ → 已做；~~开机自启~~ → 已做（右键 →「设置 → 开机启动」）。
4. **桌面应答器**：写一个 host 插件，注册 `user-questions/request` 与 `approval/request` 两个 waterfall
   应答者，把「要问人」的请求写成 `run\` 下的 JSON、由桌宠渲染成气泡按钮。一次投入同时点亮
   权限审批、`ask_user_question`、计划评审（`exit_plan_mode`）——它们本来都缺同一个应答者，
   而 headless profile 里现在一律 fail-closed（审批直接拒、`exit_plan_mode` 调用即失败）。
5. 把 `todo` / `goal` 投影画到桌面上（DSH 侧已有，缺的只是呈现）。
6. 反馈评分（👍/👎 写回 `dsh-message-feedback`）——直接产出"什么时候该沉默"的标注数据。

## 监控区域分两层：你的意见 / agent 的临时覆盖

`config.json` 里的 `region` 原来一个键干两件事：你在右键里**框选**的区域，和主 agent 回复里那行
`WATCH: Codex` 解析出来的窗口矩形，都往它里面写、都落盘。于是 agent 一开口，你框的那块在**磁盘上**
就没了 —— 取消、重启都回不去；而且那条路是 `-Quiet` 的，连气泡都不弹（只在日志里留一行），你完全无感。

现在拆成两层：

| 层 | 存在哪 | 谁能写 | 活多久 |
|---|---|---|---|
| 用户层 `config.json:region` | 落盘 | 只有你（框选 / 取消 / 设置窗口） | 一直在，直到你改 |
| 覆盖层（内存 `$script:autoRegion`） | **不落盘** | agent 的 `WATCH:`（以后的自动跟随） | 盯的窗口关掉、超时（默认 30 分钟）、或你一动手就撤 |

生效顺序是 `覆盖层（若允许）→ 用户层 → 整屏`，而默认**用户优先**：

- 你已经框了区域 → agent 的 `WATCH` **盖不过**，会被挡下并记一条 `watch_agent_blocked`（不再静默）。
- `WATCH: full` 只撤**覆盖层**。"我不管了"不等于"把用户框的那块也删了"。
- 你重新框一次（或取消）→ 覆盖层当场作废。

分法是照抄项目里已经在用的那条原则：`config.taskRules`（部署方的意见）对
`task-samples.json`（观察到的现实）——**分开写，谁改谁不互相覆盖**。

自检第 5aa 节钉的就是这三条，而且"有没有写盘"是可断言的事实、不是推理：它把 `Save-PetConfig`
和 interactions 日志的落点临时指到自检专用文件，再回头看它们有没有被创建。

```
用户框 600 + agent 要盯 800 → 被挡下 = True；生效 600 px；这一段里写盘 = False
用户没框  + agent 要盯 800 → 覆盖生效；抓出来 800 px（期望 800）
覆盖生效时用户再框一次      → 覆盖作废 = True；生效 600 px（期望回到 600）
WATCH: full                 → 用户那份还在 = True；覆盖层 = 已撤
判定：✔ agent 的覆盖只在内存里、盖不过用户、full 也不删用户那份
```

> 还没做（第 4 步）：冲突时用气泡上的按钮问你一次（复用现成的 `OPTIONS:` 机制），以及一个
> `watchOverridesRegion` 开关（想让 agent 反过来优先时用）——这条现在写死在代码里
> （`$script:watchOverridesUserRegion = $false`）。设置窗口「监控区域」那页目前只显示**生效**的那份，
> "你手选的 / 当前生效 + 来源"两行式也在第 4 步。
