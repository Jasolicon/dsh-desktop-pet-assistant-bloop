# 迁移计划：PowerShell 桌宠 → Electron

**日期**：2026-10-05
**起点**：`desktop-guide/`（PowerShell 7 + WinForms，约 4100 行主脚本 + 9 个模块）
**目标**：`desktop-pet/`（Electron，跨平台、可分发的 exe/安装包，PolyForm Noncommercial 1.0.0）

---

## 0. 为什么要重写（而不是打包成 exe）

上一轮查过：把 `.ps1` 包成 exe 只能解决"需要装 pwsh"，换来"未签名 exe 被 SmartScreen/WDAC 拦"
（这台机器**已经**有按扩展名拦 `.cmd` 的应用控制策略）。真正的问题是另外三条，打包一条都解决不了：

1. **外部依赖**：`pwsh` / `node` / `python` / `msedge` / `dsh` 六个外部程序的 17 处 `Start-Process`
2. **绝对路径**：11 处写死的 DSH 安装位置（**已在 `e460229` 修掉**，见下）
3. **只跑 Windows**：WinForms 分层窗口 + `AttachThreadInput` + GDI 截屏，一个都跨不了平台

---

## 1. 已经完成的地基

### 1.1 路径解析（这一步先做，因为它两边都要用）

`desktop-guide/paths.ps1`（提交 `e460229`）与 `desktop-pet/src/paths.mjs` 是**同一套规则**：

```
显式配置（{root}/{dshRoot}/{userProfile}/{dshHome} 占位符）
  → 环境变量 DG_DSH_ROOT / DG_DSH_EXE / DG_DSH_CLI / DG_DSH_CMD / DG_NODE / DG_EDGE / DG_PET_IMAGE
    → 自动探测：正在运行的 DSH 进程 → PATH 上的 dsh.cmd → 常见安装位置
```

两个坑都写进了注释，两边一致：

- **`cli.js` 在 `app.asar` 归档里**，`Test-Path` / `existsSync` 看不见它（逐级测到 `app.asar\` 就是 False），
  但 Electron 读得到 —— 所以不能按"文件存在"判断，只校验挂载点。
- **不要把某台机器的盘符写进代码**。原来写死的 `D:\DeepSeekHarness` 改成从**正在运行的 DSH 进程**反推。

自检/单测盯住回归：PowerShell 侧 5k 块 + Electron 侧 `test/paths.test.mjs` 都会断言
"配置与源码里不出现本机用户名或安装盘符"。

### 1.2 窗口与交互（Electron 骨架）

已搬：透明置顶窗口、鼠标穿透（`setIgnoreMouseEvents` + 渲染进程实时上报）、气泡、
右键菜单、按住拖动、位置记忆、打字派活（一句话 → agent → 结论 → 气泡）。

---

## 2. 剩下的搬家清单

按"依赖越少越先搬"排序。每一条都标了源文件与验收方式。

| # | 能力 | 源 | 目标 | 验收 |
|---|---|---|---|---|
| ~~1~~ | ~~账号 / 模型注入~~ | `Write-AgentPatch` | ✅ `src/agents.mjs` | 已完成 |
| ~~1~~ | ~~配置迁移~~ | `config.json` | ✅ `tools/migrate-config.mjs` | 已搬 15 个用得上的键 |
| ~~2~~ | ~~屏幕采样~~ | `Sample-Once` | ✅ `src/capture.mjs` + `src/fingerprint.mjs` | 已完成 |
| ~~3~~ | ~~本地闸门~~ | `Test-WorthAutoJudge` | ✅ `src/gate.mjs` | 已完成 |
| ~~4~~ | ~~主 agent 常驻~~ | `dsh-sdk.ps1` | ✅ `src/dsh-session.mjs` | 已完成，单轮 **0.9–1.3 秒**（见下） |
| ~~5~~ | ~~语音输入~~ | `stt.ps1` | ✅ `src/stt.mjs` + 渲染进程录音 | 已实现；识别链路实测过，**麦克风那段没端到端验过**（见下） |
| ~~6~~ | ~~朗读~~ | `tts.ps1` | ✅ 渲染进程的 Web Speech API | 已完成，且**不再依赖 pwsh** |
| 7 | 选项问答 / 审批应答 | `AskTimer` + `pet-responder/index.js` | 渲染进程按钮 + IPC | 审批能在气泡上点 |
| 8 | 子 agent 观察 | `Get-ObservedAgents` | `src/agents.mjs` | 后台任务进度显示在当前气泡上 |
| ~~9~~ | ~~判断记录 / 沉默角标~~ | `Format-DecisionCard` | ✅ `logs/decisions.jsonl` + 右键「看它判过什么」 | 已完成（含沉默率） |
| ~~10~~ | ~~打包~~ | — | ✅ electron-builder 已配好 | 便携版已产出；安装器在本机被应用控制策略拦下，见 `DISTRIBUTION.md` §6 |

**顺序上的理由**：2、3 是核心能力（"什么时候该说"），必须在 UI 打磨之前搬完并且
用真实日志验证一致 —— 否则重写会悄悄改变产品行为，而这是最难发现的一类回归。

---

## 3. 不搬的东西（有意丢掉）

| 丢掉 | 原因 |
|---|---|
| WinForms 自绘分层窗口 | Electron 透明窗口是等价物，且跨平台 |
| `AttachThreadInput` 抢前台键盘 | 那是 Windows 特有；气泡按钮在 Electron 里直接可点 |
| `stt-sapi.ps1`（系统识别兜底） | Windows-only，收益低；保留 FunASR 一条路 |
| `chat-panel.ps1` 的自绘气泡栏 | 已经决定用 DSH 自己的 Web 界面（`web-ui.ps1`），Electron 里换成 `BrowserView` |

## 4. 开源要件

| 项 | 状态 |
|---|---|
| LICENSE（PolyForm Noncommercial 1.0.0） | ✅ 根目录 |
| THIRD_PARTY_NOTICES（含"鲸鱼素材不可分发"） | ✅ 根目录 |
| 不复制 AGPL 代码（Coopanion） | ✅ 只借思路 |
| `.gitignore`（node_modules / .stt / .tts / run / logs） | ✅ |
| 自绘角色素材 `assets/pet.png` | ⬜ **待补** —— 目前自用兜底仍指向鲸鱼；对外分发前必须换成自绘的 |
| 远端仓库（GitHub） | ⬜ 仓库现在没有 remote |
| CI（跑 `npm test` + `node --test`） | ⬜ |

> 分发前的检查清单：仓库里 `git ls-files | grep -i dsn` 必须为空（即没有任何鲸鱼素材），
> 且 README 里说明"首次运行需要一个已安装的 DSH 实例"。

## 5. 本机跑 Electron 的两个坑（已解决）

2026-10-05 实测，两条都记在 `README.md` 里，这里只留结论：

1. **Electron 33 在这台机器上会崩**（`0xC0000005`，出错模块就是 electron.exe 自己），
   **28.3.3 正常**。所以版本钉在 `^28`。排查过程中试过 `--disable-gpu` 等一串开关，
   以及"未签名被 Smart App Control 拦"这个假设 —— **后者被否掉了**：
   本地用 `csc` 编译的、完全没签名的 WinForms exe 跑得好好的（探针见
   `../packaging-probe/`）。SAC 确实是强制开启状态，但它不是这里的原因。
2. **`--no-sandbox` 必需**（不加连 `--version` 都不返回）。

### 那签名还要不要做？**先不做。**

代码签名不是可用的前提，只是"首次打开时会不会被拦一下"。**不签名直接发是开源工具的常态**，
用户点一次「更多信息 → 仍要运行」就能用。完整的分发方案（含免费/廉价的 OSS 签名渠道、
以及"什么时候才值得花钱"）写在 [DISTRIBUTION.md](DISTRIBUTION.md)。

顺带说明：这条也说明"把 `.ps1` 包成 exe"那条路并不占便宜 —— 它同样要面对拦截提示，
却换不来跨平台。

## 6. 已完成的搬家（截至 2026-10-05）

| 能力 | 落点 | 验证 |
|---|---|---|
| 路径解析（DSH/node/Edge/角色图） | `src/paths.mjs` | 13 项单测；四个入口全部解出 |
| 窗口 / 鼠标穿透 / 气泡 / 拖动 / 菜单 | `src/main.mjs` + `renderer/` | 起得来，`capturePage` 有图 |
| 账号 + 模型注入 | `src/agents.mjs`（等价 `Write-AgentPatch`） | patch 格式与 PowerShell 版逐字对齐，有单测锁字段名 |
| 派活（一句话 → DSH → 结论） | `src/brain.mjs` | 实测 `{"ok":true,"text":"可用","seconds":4.663}` |
| 前台窗口（免 pwsh） | `src/win.mjs`（koffi → user32） | 实测 `{"process":"chatgpt","title":"ChatGPT"}` |
| **屏幕采样 + 8×8 指纹** | `src/capture.mjs` + `fingerprint.mjs` | 算法与 C# 版逐字一致；6 项单测（含 960 上限、整幅降采样） |
| **本地闸门** | `src/gate.mjs` | 12 项单测，用例照着 PowerShell 自检 5h 块抄，阈值逐条对齐 |
| 观察循环（采样→闸门→叫模型→沉默/说话） | `src/monitor.mjs` | **端到端实跑**：放行一次并说出"Codex 窗口被挡住了大半"，随后每轮都被闸门拦下 |
| 判断日志 / 沉默角标 | `logs/decisions.jsonl` + 渲染进程角标 | 日志按 kind=skip/silent/spoke 记录；角标显示累计"没说"次数 |
| 打包（electron-builder） | `package.json` 的 `build` 段 + `npm run pack` / `dist` | 便携版产出成功（168 MB）；安装器在本机被策略拦下，见 `DISTRIBUTION.md` §6 |
| 朗读（TTS） | 渲染进程 `speechSynthesis` | 用 Chromium 自带音色，离线零依赖；系统句 / SILENT / 「你在做：」不出声 |
| 判断记录卡片 | 右键「看它判过什么」 | 从 `logs/decisions.jsonl` 读回，卡片里给沉默率 |
| 配置迁移 | `tools/migrate-config.mjs` | 从 desktop-guide/config.json 搬了 15 个用得上的键 |
| **主 agent 常驻** | `src/dsh-session.mjs`（stdio JSON-RPC） | initialize 4.5s 一次性；之后每轮 **0.897s**（对比一次性起的 4.66s） |
| 语音输入（STT） | `src/stt.mjs` + 渲染进程 `getUserMedia` | 识别链路实测：1 秒静音 → `{ok:true,text:""}`（3.1s，含模型加载）。**长按录音 → 派活这一段没端到端验过**（得真人按住说话），代码路径与打字派活共用 `dispatchTask` |
| 语音意图分流 | `src/router.mjs` | 识别完先判 TASK/CHAT，**聊天不起 agent**。真实模型实测 4 例全对（0.7–1.6s/次） |

**常驻会话带来的一个额外好处**：`session/prompt` 的 `contentBlocks` **支持内联图片**
（TypeScript 版那边 headless CLI 没有附件入口，只能让模型用 `read_image` 读路径、多花一轮）。
所以自动判断现在是**截图直接随消息给模型**，省掉那一轮往返。

### 还没搬的（2 项）

| # | 能力 | 现状 | 说明 |
|---|---|---|---|
| 7 | 选项问答 / 审批应答 | ⬜ | `run/ask/` 那套协议在（见 DesktopGuide 的 AskTimer），但 **`pet-responder` 目前没装、`run/ask` 目录也不存在**，所以还没有对话方 |
| 8 | 子 agent 观察 | ⬜ | 后台 agent 的进度显示 + 把 agents 字段塞进判断 payload |

### 两处**有意**与 PowerShell 版不同，别当成 bug

1. **截图时机**：PowerShell 版是"采样即截图"（每次采样都编码一张 JPEG）；这里采样只算指纹
   （160×90 缩略图），**只有闸门放行时才抓高质量截图**。理由：截图是给模型看的，而模型
   只在放行时被叫到 —— 这样采样率可以调密而不烧 CPU。
2. **空闲时间**用 Electron 的 `powerMonitor.getSystemIdleTime()`（= Win32 `GetLastInputInfo`），
   不是 `process.uptime()`（那是本进程跑了多久，与用户有没有动键鼠无关）。
