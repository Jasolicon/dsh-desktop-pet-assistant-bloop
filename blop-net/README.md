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
verify-addtype.ps1       本机验证：Add-Type 内存编译同一份源码，跑同一张表（策略拦 exe 时的活路）
```

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
| 账本 / 每日消费上限 | ⬜ | 待搬 |
| DSH 常驻会话（stdio JSON-RPC） | ⬜ | 待搬 |
| WinForms 壳（分层窗口 / 气泡 / 菜单 / 设置窗口） | ⬜ | 待搬 |

合计：`verify-addtype.ps1` **64/64 项通过**。
