# blop-net —— .NET 版（Windows-only，进行中）

把 `../desktop-guide/`（PowerShell 7 + WinForms）那套桌宠搬到 .NET 8 + WinForms。

**为什么要搬**：现在的成品要求用户自己装 PowerShell 7，做不到开箱即用。
"把 pwsh 打包进去"不算出路 —— 一份自包含的 pwsh 目录实测 **244.7 MB**，比 Electron 便携版（168 MB）还大，
等于把"装一次"换成"每次都背着"。.NET 版的目标是 **20–70 MB 的单一 exe、不需要任何运行时**。

**代价（说在前面）**：WinForms 就是 Windows-only。跨平台那条线仍然由 `../desktop-pet/`（Electron）负责。
三份实现的功能差距与"有意为之的差别"记在 `../实现差别记录.md`。

## ⚠️ 这台机器上的两个前提

> **状态更新（2026-10-12 晚）**：这台机器的 **Smart App Control 已关掉**（`VerifiedAndReputablePolicyState = 0`），
> 下面三张表的"被拦"全部消失 —— net48 exe、net8 依赖运行时、net8 单文件自包含都跑通了。
> 但这一节留着：① 那次判定不稳定是真实发生过的，别再拿"跑通过一次"当依据；
> ② **用户的机器**上仍可能开着 SAC，那时未签名的 exe 会被系统直接拒掉（连"仍要运行"都没有）。

1. **SDK 装在用户目录**（不需要管理员）：`%LOCALAPPDATA%\Microsoft\dotnet\`。
   `winget install Microsoft.DotNet.SDK.8` 只提供机器级安装（要 UAC），所以改用官方
   `dotnet-install.ps1 -Channel 8.0 -InstallDir ... -NoPath`。这条路径**没有进 PATH**。
2. **Smart App Control（SAC）会拦"新编出来的 exe"** —— 而且判定**不稳定**，这点最要命（现已关掉）。

   事件日志给出了铁证（`Microsoft-Windows-CodeIntegrity/Operational`）：

   ```
   id=3118  Smart App Control Block Deteails
   id=3077  Code Integrity determined that a process (…\pwsh.exe) attempted to load
            …\blop-net\src\Blop.Cases\bin\Release\net48\Blop.Cases.exe that did not meet
            the Enterprise signing level requirements (Policy ID:{0283ac0f-fff1-49ae-ada1-8a933130cad6})
   ```

   实测矩阵（**同一台机器、同一天**）：

   | 产物 | 结果 |
   | --- | --- |
   | 刚编出来的 net48 exe | 上午跑通 18/18；**重编之后就被拦**（复制到 TEMP 也一样） |
   | net8 的 dll / 单文件自包含 exe（67 MB 托管） | ❌ 被拦 |
   | net8 + Native AOT 单文件原生 exe（1.9 MB） | 跑通过（但这不等于"稳定能跑"，见下） |
   | .NET Framework `csc` 编的小 exe（含 WinForms GUI） | 跑通过 |
   | 打包好的 Electron 应用（**未签名**，176 MB） | ✅ **能起**（`Start-Process` 根本不被拦） |
   | `Add-Type`（内存编译） | ✅ **一直能跑**（桌宠那 2379 行内嵌 C# 就这么跑的） |

   **结论（上一版这份文档写错了，当天纠正）**：
   - "未签名能不能跑"在这台机器上**不是稳定属性** —— 别再拿"刚才跑通过一次"当依据；
     凡是刚编译出来的 exe，都要当成可能被 SAC 拦。
   - 因此本地验证走 **`verify-addtype.ps1`（内存编译，永远不受影响）**；
     exe 形态只在**没开 SAC 的机器**上才算验过。发版给用户也要把这条算进去：
     开着 SAC 的机器会**直接拦掉未签名的 exe，不给"仍要运行"的选项**。
   - Electron 打包版能起，说明它走的是另一条路（发布者声誉），但那是它的运气，不是我们的保证。

   **框架选择的现状**：双目标 `net48;net8.0-windows` 保留着（两边源码同一份、都能编过），
   但"用哪个出成品"这件事现在被 SAC 卡着：net8 + WinForms 最省事也最现代，要签名；
   net48 不需要用户装运行时（.NET Framework 4.8 是 Windows 组件），但同样过不了 SAC。

## 目录

```
src/Blop.Core/           引擎（无 UI）：指纹距离、闸门… 每搬一块都要能用行为用例表验收
src/Blop.Cases/          用例表跑分器（控制台）：读 ../behavior-cases/*.json，失败退出码非 0
src/Blop.App/            壳（WinForms）：透明置顶窗口、角色图、拖动、位置记忆、右键菜单、托盘、实例锁
verify-addtype.ps1       本机验证：Add-Type 内存编译同一份源码，跑同一张表（策略拦 exe 时的活路）
```

## 壳（Blop.App）：现在双击就能起来

```powershell
# 发布一个能双击的成品（net48：1.35 MB，用户不用装任何运行时 —— 4.8 是 Windows 组件）
$dotnet = "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe"
& $dotnet publish .\src\Blop.App\Blop.App.csproj -c Release -f net48 -o .\out\net48
# 然后双击 .\out\net48\Bloop.exe
```

**这一版只有壳**：透明置顶、逐像素 alpha 的角色图，可拖动（位置记进 `run\pet.json`），
右键有菜单，托盘图标能显示/隐藏，机器级实例锁保证"同时只有一只"。它还没有脑子 ——
抓屏 / 闸门 / DSH 会话是接下来往里接的东西。

命令行开关（都写在 `Program.cs` 顶部注释里）：

| 开关 | 用途 |
| --- | --- |
| `--shell-smoke` | 自检：建窗体 → 渲染一帧存 `run\pet-preview.png` → 把 DPI/尺寸/ExStyle 写进 `run\shell-smoke.txt` → 立刻退出。壳是常驻窗体程序，没有它就没法进自动化 |
| `--no-lock` | 跳过实例锁。**和 PowerShell 版同时跑**时必须带它（两版共用同一把机器级锁，见 `Paths.LockPath`） |
| `--notify-if-running` | 已在运行时弹个说明框；默认是**静默退出**（开机启动、连点两下快捷方式都不该弹出个框等人点） |

实测（2026-10-12，本机 200% 缩放）：

```
systemDpi=192  dpiAwareCall=True  screen=2880x1800
form=440x440 at (2360,1280)          ← 220 逻辑宽 × 200% + 40 逻辑像素边距
exstyle=0x08090008  noActivate=True  layered=True
```

两个踩过的坑写在代码注释里，这里各留一句：

- **DPI 感知要在任何窗口之前定下来**。net48 上光在 `Main` 里 `SetProcessDpiAwarenessContext` 不够 ——
  WinForms 会按 `App.config` 的 `DpiAwareness`（或清单）先定死，晚了改不动；net8 那半边走
  `Application.SetHighDpiMode`。没生效的表现是"200% 缩放下只有一半大、位置也按逻辑坐标算错"。
- **量尺寸要用 DPI 感知的进程去量**。用不感知的 pwsh 去 `GetWindowRect`，读到的坐标会被系统
  虚拟化成 1/2（220×220 @ (1180,640)）—— 我一开始就是被这个骗了，以为窗体尺寸算错了。
  所以自检把尺寸写进 `run\shell-smoke.txt`，由程序自己报数。

发布形态对比（同一份代码，`net48;net8.0-windows` 双目标）：

| 形态 | 体积 | 用户要装什么 | 实测 |
| --- | --- | --- | --- |
| **net48** | **1.35 MB**（14 个文件） | 不用装（4.8 是 Windows 组件） | ✅ 自检通过 |
| net8 依赖运行时 | 1.04 MB | .NET 8 Desktop 运行时 | ✅ 自检通过（`dpiAwareCall=False` 是正常的：net8 那边由 `SetHighDpiMode` 先设掉了） |
| net8 单文件自包含 | 146 MB | 不用装 | ⚠️ 本机在 `EnableVisualStyles` 写临时清单时报 `UnauthorizedAccessException`（待查；体积也没优势） |

> 与 PowerShell 版**不能同时跑**：两版共用 `%LOCALAPPDATA%\Bloop\pet.lock` 这把机器级锁
>（这正是它存在的意义 —— 两种形态状态根不同，各看各的 pid 文件会互相看不见）。
> 想同时开着看效果，给 .NET 那只加 `--no-lock`。

## 怎么跑

```powershell
# 用例表（闸门 / 路径 / 掩码几何）：内存编译同一份源码，跑 behavior-cases/*.json
pwsh -NoProfile -ExecutionPolicy Bypass -File .\verify-addtype.ps1

# 抓屏冒烟：这条路径没法做"假世界"用例（它真的要抓屏幕），所以单独一条命令
$dotnet = "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe"   # SDK 没进 PATH，要用全路径
& $dotnet build .\src\Blop.Cases\Blop.Cases.csproj -c Release -f net48
.\src\Blop.Cases\bin\Release\net48\Blop.Cases.exe ..\behavior-cases
.\src\Blop.Cases\bin\Release\net48\Blop.Cases.exe --capture-smoke

# 无 UI 引擎的 AOT 单文件形态（1.9 MB）。必须带 -p:TargetFrameworks=net8.0-windows：
# 不然 PublishAot 会传给 net48 那一半，报 NETSDK1207（"目标框架不支持提前编译"）。
& $dotnet publish .\src\Blop.Cases\Blop.Cases.csproj -c Release -f net8.0-windows -r win-x64 `
    -p:PublishAot=true -p:TargetFrameworks=net8.0-windows -o .\out-aot
```

> 注意：`verify-addtype.ps1` 编的是**同一份源码**（`Blop.Core` + `Blop.Cases` 一起进内存程序集），
> 跑分器里那些期望值与假世界也是真的在跑 —— 不是另写一份测试去"陪跑"。

两条路读的是**同一份 `behavior-cases/*.json`**，也是 PowerShell 版 `DesktopGuide.ps1 -SelfTest`
里跑的那几节（5h / 5l / 5q / 5y）。三份实现结论必须逐条一致 —— 差别只能是表里写明的"有意不同"，
或者还没搬完。

## 进度

| 模块 | 状态 | 验收 |
| --- | --- | --- |
| 指纹距离 `Fingerprint.Distance` | ✅ 已搬 | 与 `Get-FpDistance` 同口径（长度不等返回 999） |
| 闸门 `Gate.Decide` | ✅ 已搬 | `behavior-cases/gate.json` **18/18** |
| 路径解析 / 占位符展开 / 状态根 / 实例锁路径 | ✅ 已搬 | `behavior-cases/paths.json` **36/36**（含"装在别处""只装了 DSH 没装 node"这类以前测不到的情况） |
| 挖洞掩码的几何 `Fingerprint.MaskFor` | ✅ 已搬 | `behavior-cases/fingerprint.json` **10/10**（与 PowerShell 侧自检 5y 同一张表） |
| 抓屏 + 8×8 指纹 `ScreenCapture.Grab` | ✅ 已搬 | `--capture-smoke`：真抓 2880×1800 → 1024×640、JPEG 约 96 KB、掩码 7/64 格、非法区域退回整屏 |
| 壳 `Blop.App`（窗口/角色图/拖动/位置记忆/菜单/托盘/实例锁） | ✅ 已搬 | `--shell-smoke` 自检 + 真跑一次（窗口 ExStyle、DPI、尺寸、位置记忆都对） |
| DSH 常驻会话 `DshSession`（stdio JSON-RPC） | ⚠️ 代码已搬，**本机没验成** | 见下面「DSH 现状」 |
| 账本 / 每日消费上限 | ⬜ | 待搬 |
| 气泡 / 选项按钮 / 设置窗口 | ⬜ | 待搬（壳的骨架已在，接着往里加） |

合计：`verify-addtype.ps1` **64/64 项通过**。

## DSH 现状（2026-10-12 晚，卡住的地方）

`DshSession` 已经把协议搬完（`initialize` 必须等响应、`session/prompt` 带 contentBlocks、
`session.status=idle` 收轮、UTF-8 直写 stdin 基础流、必须持续读 stderr 否则子进程被管道堵死），
但**没能从我们的进程里跑通**。我们起的子进程死在 profile 组装那一步：

```
Error: EPERM: operation not permitted, open 'C:\Users\62487\.dsh\profiles\sdk\cordis.yml'
    at prepareProfile (…/dsh/lib/profile-boot-*.js:189)
    at composeProfile (…:206) → runProfile (…:241) → runCli (…/lib/bin.js:215)
```

**已经排除掉的**（都做过对照实验，每条都是从 PowerShell 用同一套参数跑成功、从我们的进程跑失败）：

| 猜过的原因 | 实测 |
| --- | --- |
| exe / cli.js / 参数写错 | 打印实参快照逐字对比：**完全一致** |
| 工作目录不对 | desktop-guide 与仓库根都试过，PS 侧两个都成功 |
| 环境变量不全或被小写化 | 子进程 `cmd /c set` 全量对比：**97 行一字不差** |
| 环境里少了 `ELECTRON_RUN_AS_NODE` | 有（自己在进程里设、继承给子进程） |
| 身份/令牌不同 | `JASONLAPTOP\62487`，非管理员，未带任何沙箱组 |
| 父进程层级（孙进程） | pwsh → pwsh → DSH 也成功 |
| `CreateNoWindow` | true / false 在 PS 侧都成功 |
| stdin 写法（WriteLine vs 裸字节） | 两种在 PS 侧都成功 |
| stdout/stderr 被管道/文件重定向 | 两种都试过，我们这边照样失败 |
| sdk profile 被别的实例占着 | 关掉 DSH 应用、清掉所有 sdk 实例、换独立 `DSH_HOME`，都一样 |

**仍然没找到的原因**：同一个 exe、同一份参数、同一份环境、同一个用户、同样从 pwsh 派生，
从我们的进程里起就被拒写 `~\.dsh\profiles\sdk\cordis.yml`（PS 侧同一时刻写得好好的 ——
文件时间戳能看到它刚被写成功过）。下一步要么去看 `profile-boot` 那段代码到底按什么判断"要重写"，
要么干脆**绕开它**：让 DSH 应用自己去跑（走它的 IPC/插件形态），别从我们这边直接起 sdk 会话。

**当前决定**：先不卡在这里 —— 壳里那条「观察 → 闸门 → 气泡」的链路照接，大脑放在一个接口后面，
先用假大脑把环路验通（抓屏 → 闸门放行 → 气泡 + 判断记录），等上面这个问题有结论再把真大脑插进去。

### 补记（同一晚，读源码之后）

DSH 是开源的（`deepseek-ai/deepseek-harness`），所以直接读了 `apps/cli/src/profile-boot.ts`：

```ts
// 每次启动都会重写 cordis.yml（空根配置）—— 有意为之：防止 Loader 的写回把组合结果烙进文件
writeFileSync(join(profile.dir, PROFILE_ROOT_FILENAME), PROFILE_ROOT_CONFIG)
```

所以那个 EPERM 就是**一次普通的写文件被拒**。同一时刻：

| 从哪起 | 结果 |
| --- | --- |
| PowerShell（`dsh-sdk.ps1` 的原样代码，连跑两次） | ✅ 成功 |
| 我们的进程（参数/环境/令牌/工作目录/编码逐字段对齐，net48 与 net8 都试） | ❌ EPERM |
| 我们的进程 → `cmd /c` 中转再起 | ❌ EPERM（同一条命令从 pwsh 起就没问题） |

**另一个好消息**：DSH 的 CLI 有一条**一次性模式**，实测从 PowerShell 起完全可用：

```
DeepSeek Harness.exe --expose-internals <cli.js> headless --patch <最小 patch> "只回复两个字：可用"
→ stdout 最后一行「可用」，4.6 秒，退出码 0
```

其中 `<最小 patch>` 只是把模型 provider 注入成 `deepseek-account`（用你 DSH 里已登录的账号，
不用再配 key）—— 见 `BrainPatch.cs`，它是 `dsh-agents.ps1` 里 `WriteAgentPatch` 的精简版。
代价是每轮起一个完整进程（8–25 秒），比常驻会话慢一个量级，但**这条路是通的**：
`DshOneShot.cs` + `Blop.Cases --brain-oneshot-smoke`（带一张实时截图问一句，让模型自己 `read_image`）。

**当前最大的怀疑**：**沙箱继承**。上面所有"从我们的进程起就失败"的对照，都是在 Codex 的沙箱里跑的
（我们的进程是沙箱里的 pwsh 拉起来的）；而你平时是**双击运行**，那是正常上下文。
所以仓库里放了一个一键测试：双击 `blop-net/out/试试大脑.cmd`（它跑的就是同一条命令）。
如果它出答案 → 说明沙箱是原因、真实运行时没这个问题，我们就照一次性模式把大脑接上。
