# desktop-pet —— Electron 重写版

把 `../desktop-guide/`（PowerShell + WinForms）那套桌宠搬到 Electron。
**当前是骨架，不是成品** —— 见下面的"搬了多少"。

## 怎么跑

```bash
cd desktop-pet
npm install          # 会下载 Electron（约 100–200MB，只此一次）
npm start
```

> **国内网络**下从 GitHub 下 Electron 二进制会卡住（实测十几分钟不动）。用镜像：
> ```powershell
> $env:ELECTRON_MIRROR = 'https://npmmirror.com/mirrors/electron/'
> npm install
> ```

不想装 Electron 也能验路径逻辑（纯 node，7 项测试）：

```bash
npm test
```

### ⚠️ 这台机器上 Electron GUI 起不来（已定位为环境问题）

2026-10-05 在本机实测：`npm start` 立刻崩溃，**不是代码问题** —— 最小探针
`tools/probe.cjs`（只有 `app.whenReady()` 后打印一行再退出）同样崩溃：

```
[probe] module loaded, electron = 33.4.11     ← 主进程跑起来了
exit = -1073741819  (0xC0000005 访问冲突)      ← 崩在 app 就绪那一刻
```

已经排除的：`--disable-gpu` / `--disable-gpu-compositing` / `--disable-features=Vulkan` /
`--use-angle=swiftshader` —— 全都一样崩；也不是我们的 main.mjs（探针也不打印 `app ready`）。

最可能的原因：**Smart App Control 处于强制开启状态**。证据：

```
HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState = 1   （1 = 强制）
Microsoft-Windows-CodeIntegrity/Operational 里有 "Smart App Control Block Deteails" 事件
```

而且 `electron --version` **必须加 `--no-sandbox` 才返回**（不加就 0x80000003 直接退出）——
沙箱正是 SAC 这类完整性策略最先拦的地方。npm 下下来的 Electron 二进制没有签名，
这台机器上装的 DSH 能跑是因为它是走安装包装的、在系统眼里可信。

**没有抓到直接针对 `electron.exe` 的拦截记录**，所以只能说是"极可能"，不是 100% 断定。

可选出路（都要你拍板，我不擅自改系统设置）：

| 出路 | 代价 |
|---|---|
| 关掉智能应用控制 | **单向操作**：关了以后要重装 Windows 才能再开。不建议为了开发就关 |
| 换台机器 / 虚拟机 / WSL2 里开发 | 最省事，代码不用改 |
| 本机继续用 PowerShell 版，Electron 版先只写代码 | 功能不丢，只是本机看不了效果 |
| 给开发版签名 | 需要代码签名证书（花钱） |

代码本身是好的：7 项路径测试全过，主进程能加载、能解析 DSH 路径。**换台机器 `npm start` 就能看。**

## 交互

| 操作 | 效果 |
|---|---|
| 左键点宠物 | 说一句（走 DSH 主 agent） |
| 双击宠物 | 打开/收起打字派活输入条 |
| 按住拖动 | 挪位置（位置记进 config.json） |
| 右键宠物 | 菜单：显示/隐藏、打开配置目录、退出 |
| 输入条里回车 / 点发送 | 派活给 agent，跑完结论显示在气泡里 |

鼠标**只在**宠物、气泡、输入条上被拦截，其余区域穿透到下面的窗口 ——
这是靠渲染进程实时报"指针在不在我身上"，主进程切 `setIgnoreMouseEvents`。

## 状态与沉默

光晕颜色就是状态：`idle` 灰蓝 / `thinking` 琥珀 / `speaking` 蓝 / `silent` 灰。
角色图本身不变色 —— 图片改不了色，这是 PowerShell 版踩过的坑。

**沉默是一等输出**：模型回 `SILENT` 时不弹气泡，只把状态切成 silent。

## 搬了多少

| 能力 | 状态 | 说明 |
|---|---|---|
| 透明置顶窗口、鼠标穿透 | ✅ 已搬 | WinForms 分层窗口 → Electron 透明窗口 |
| 气泡、右键菜单、拖动、位置记忆 | ✅ 已搬 | |
| 打字派活（一句话 → agent → 结论） | ✅ 已搬 | 过渡期仍复用 `dsh --profile headless --json`，见 `src/brain.mjs` |
| 路径解析（DSH/node/Edge/角色图） | ✅ 已搬 | `src/paths.mjs` 与 `../desktop-guide/paths.ps1` **同一套规则** |
| 屏幕采样 + 本地闸门 | ⬜ 未搬 | 逻辑在 `DesktopGuide.ps1` 的 `Sample-Once` / `Test-WorthAutoJudge` |
| 语音输入（STT） | ⬜ 未搬 | `stt.ps1` + `stt-sensevoice.cjs` 可以直接复用，只是调用方换成 Electron |
| 朗读（TTS） | ⬜ 未搬 | `tts.ps1` |
| 选项问答 / 审批应答 | ⬜ 未搬 | 气泡按钮 + `pet-responder` |
| 子 agent 观察 | ⬜ 未搬 | |

没搬的那些在 `../desktop-guide/` 里仍然可用；两套可以并存，只是别同时跑（会抢同一个会话）。

## 为什么重建而不是"把 PowerShell 包成 exe"

见根目录的迁移计划 `MIGRATION.md`。一句话：打包成 exe 解决不了真正的问题
（外部依赖 + 绝对路径 + 只跑 Windows），而这个仓库的目标是能对外分发。

## 开源

- 本项目代码：MIT，见根目录 [LICENSE](../LICENSE)
- 运行时借用的第三方组件与**不可分发的素材**：见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)
- 参考过 Coopanion（AGPL-3.0）的设计思路，但**没有复制它的代码**

## 目录

```
src/
  main.mjs            Electron 主进程：窗口、菜单、IPC
  preload.cjs         contextBridge 暴露给渲染进程的几个方法
  paths.mjs           机器相关路径的唯一解析点（与 paths.ps1 同规则）
  config.mjs          配置读写（缺键补默认值）
  brain.mjs           派活：调 dsh headless，取最后一行结论
  renderer/           窗口里画的东西（HTML/CSS/JS，无框架）
test/paths.test.mjs   纯 node 可跑的路径测试
```
