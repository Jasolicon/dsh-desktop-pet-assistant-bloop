# 迁移计划：PowerShell 桌宠 → Electron

**日期**：2026-10-05
**起点**：`desktop-guide/`（PowerShell 7 + WinForms，约 4100 行主脚本 + 9 个模块）
**目标**：`desktop-pet/`（Electron，跨平台、可分发的 exe/安装包，MIT 开源）

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
| 1 | 配置迁移 | `config.json` | `config.mjs` + `tools/migrate-config.mjs` | 旧配置能原样读进来，缺键补默认 |
| 2 | **屏幕采样** | `Sample-Once`（DesktopGuide.ps1） | `src/capture.mjs`（`desktopCapturer` 或原生截屏） | 采样率与 `taskRules` 一致；能出 8×8 指纹 |
| 3 | **本地闸门** | `Test-WorthAutoJudge` | `src/gate.mjs`（纯函数） | 用真实日志回放，判定结果与 PowerShell 版逐条一致 |
| 4 | **主 agent 常驻** | `dsh-sdk.ps1`（stdio JSON-RPC） | `src/brain.mjs` 换成常驻会话 | 单轮从 8–25 秒降到 1 秒级 |
| 5 | 语音输入 | `stt.ps1` + `stt-sensevoice.cjs` | `src/stt.mjs`（child_process 复用 `.cjs`） | 长按说话 → 识别 → 派活 |
| 6 | 朗读 | `tts.ps1` | `src/tts.mjs` | 结论句出声；系统句/SILENT 不出声 |
| 7 | 选项问答 / 审批应答 | `AskTimer` + `pet-responder/index.js` | 渲染进程按钮 + IPC | 审批能在气泡上点 |
| 8 | 子 agent 观察 | `Get-ObservedAgents` | `src/agents.mjs` | 后台任务进度显示在当前气泡上 |
| 9 | 判断记录 / 沉默角标 | `Format-DecisionCard` | 渲染进程卡片 + `logs/utterances.jsonl` | 沉默率与角标跨重启仍准 |
| 10 | 打包 | — | electron-builder | Windows 出 `.exe`；顺带验证 macOS/Linux |

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
| LICENSE（MIT） | ✅ 根目录 |
| THIRD_PARTY_NOTICES（含"鲸鱼素材不可分发"） | ✅ 根目录 |
| 不复制 AGPL 代码（Coopanion） | ✅ 只借思路 |
| `.gitignore`（node_modules / .stt / .tts / run / logs） | ✅ |
| 自绘角色素材 `assets/pet.png` | ⬜ **待补** —— 目前自用兜底仍指向鲸鱼；对外分发前必须换成自绘的 |
| 远端仓库（GitHub） | ⬜ 仓库现在没有 remote |
| CI（跑 `npm test` + `node --test`） | ⬜ |

> 分发前的检查清单：仓库里 `git ls-files | grep -i dsn` 必须为空（即没有任何鲸鱼素材），
> 且 README 里说明"首次运行需要一个已安装的 DSH 实例"。

## 5. 一个绕不开的工程约束：签名

本机实测（2026-10-05）：**Smart App Control 强制开启时，未签名的 Electron 二进制起不来**
（最小探针都崩在 `app.whenReady()`，详见 `README.md` 的实测记录）。

这件事对"用 Electron 重写成可分发的 exe"有直接影响：

- **开发阶段**：可以用 `npm run start:no-sandbox` 绕过一部分，但本机连最小 app 都起不来，
  说明这不是 sandbox 一个开关能解决的 —— 要么换机器/WSL 开发，要么关掉 SAC（单向操作，不建议）。
- **分发阶段**：终端用户的机器同样可能开着 SAC/其他完整性策略。**打包出来的安装包必须签名**，
  否则用户双击就是"已被阻止"，连报错都看不懂。这是真金白银的证书成本，要提前算进计划。

顺带一提：这条约束正好说明当初"把 .ps1 包成 exe"那条路为什么也不行 ——
它同样要面对签名问题，却换不来跨平台。
