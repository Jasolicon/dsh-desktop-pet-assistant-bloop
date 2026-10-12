# blop-net —— .NET 版（Windows-only，进行中）

把 `../desktop-guide/`（PowerShell 7 + WinForms）那套桌宠搬到 .NET 8 + WinForms。

**为什么要搬**：现在的成品要求用户自己装 PowerShell 7，做不到开箱即用。
"把 pwsh 打包进去"不算出路 —— 一份自包含的 pwsh 目录实测 **244.7 MB**，比 Electron 便携版（168 MB）还大，
等于把"装一次"换成"每次都背着"。.NET 版的目标是 **20–70 MB 的单一 exe、不需要任何运行时**。

**代价（说在前面）**：WinForms 就是 Windows-only。跨平台那条线仍然由 `../desktop-pet/`（Electron）负责。
三份实现的功能差距与"有意为之的差别"记在 `../实现差别记录.md`。

## ⚠️ 这台机器上的两个前提（2026-10-12 实测）

1. **SDK 装在用户目录**（不需要管理员）：`%LOCALAPPDATA%\Microsoft\dotnet\`。
   `winget install Microsoft.DotNet.SDK.8` 只提供机器级安装（要 UAC），所以改用官方
   `dotnet-install.ps1 -Channel 8.0 -InstallDir ... -NoPath`。这条路径**没有进 PATH**。
2. **应用控制策略会拦掉一部分产物 —— 但不是"未签名一律拦"**。实测矩阵：

   | 产物 | 能不能跑 |
   | --- | --- |
   | `net8.0-windows` 的 `dotnet build` 产物（dll、依赖运行时的 exe） | ❌ `0x800711C7 应用程序控制策略已阻止此文件` |
   | `net8` 单文件自包含（67 MB，托管） | ❌ 进程都起不来（换目录、复制到 TEMP 一样） |
   | **`net48` 的 `dotnet build` 产物（exe + 独立 dll）** | ✅ |
   | **`net8` + Native AOT 单文件原生 exe（1.9 MB）** | ✅（**带 MOTW 也能跑**） |
   | .NET Framework `csc` 编的 IL exe（连 WinForms GUI 一起） | ✅ |
   | `Add-Type`（内存编译） | ✅（桌宠那 2379 行内嵌 C# 一直这么跑） |

   带 `Zone.Identifier`（MOTW，模拟"从 GitHub 下载下来"）之后 net48 exe 与 AOT exe 仍然能跑 ——
   说明这两条路不是靠"本机文件免检"混过去的。

   **由此得出两条发版形态，都不需要签名**：
   - **net48 + WinForms**（现在就能跑）：.NET Framework 4.8 是 Windows 组件（Win10 1903+ / Win11 自带），
     **用户不用装任何运行时**，产物几 MB、带独立 dll 也行；
   - **net8 + Native AOT**（1.9 MB、无运行时）：但 **WinForms/WPF 官方不支持 AOT**，
     只适合无 UI 的引擎，或者将来配原生自绘壳。

   而 **net8 + WinForms**（本来最省事的写法）在这台机器上跑不起来 —— 除非代码签名到位。
   这就是我们**双目标**（`net48;net8.0-windows`）的原因：今天用 net48 出成品，
   以后能签名了把开关拨到 net8。

## 目录

```
src/Blop.Core/           引擎（无 UI）：指纹距离、闸门… 每搬一块都要能用行为用例表验收
src/Blop.Cases/          用例表跑分器（控制台）：读 ../behavior-cases/*.json，失败退出码非 0
verify-addtype.ps1       本机验证：Add-Type 内存编译同一份源码，跑同一张表（策略拦 exe 时的活路）
```

## 怎么跑

```powershell
$dotnet = "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe"   # SDK 没进 PATH，要用全路径

# ① 本机验证（net48，能跑）
& $dotnet build .\src\Blop.Cases\Blop.Cases.csproj -c Release -f net48
.\src\Blop.Cases\bin\Release\net48\Blop.Cases.exe ..\behavior-cases

# ② 无 UI 引擎的 AOT 形态（1.9 MB 单文件，也能跑）
#    必须带上 -p:TargetFrameworks=net8.0-windows：不然 PublishAot 会传给 net48 那一半，
#    直接报 NETSDK1207（"目标框架不支持提前编译"）。
& $dotnet publish .\src\Blop.Cases\Blop.Cases.csproj -c Release -f net8.0-windows -r win-x64 `
    -p:PublishAot=true -p:TargetFrameworks=net8.0-windows -o .\out-aot

# ③ 兜底：万一哪天策略把 SDK 产物也拦了，用内存编译跑同一份源码
pwsh -NoProfile -ExecutionPolicy Bypass -File .\verify-addtype.ps1
```

两条路读的是**同一份 `behavior-cases/*.json`**，也是 PowerShell 版 `DesktopGuide.ps1 -SelfTest`
里跑的那几节（5h / 5l / 5q / 5y）。三份实现结论必须逐条一致 —— 差别只能是表里写明的"有意不同"，
或者还没搬完。

## 进度

| 模块 | 状态 | 验收 |
| --- | --- | --- |
| 指纹距离 `Fingerprint.Distance` | ✅ 已搬 | 与 `Get-FpDistance` 同口径（长度不等返回 999） |
| 闸门 `Gate.Decide` | ✅ 已搬 | `behavior-cases/gate.json` **18/18**（net48 真 .NET 跑分，另 AOT 形态也 18/18） |
| 路径解析 / 占位符展开 | ⬜ | 待搬（PowerShell 侧自检 5k） |
| 抓屏 + 8×8 指纹 | ⬜ | 待搬（几何规则已有 `behavior-cases/fingerprint.json`） |
| 账本 / 每日消费上限 | ⬜ | 待搬 |
| DSH 常驻会话（stdio JSON-RPC） | ⬜ | 待搬 |
| WinForms 壳（分层窗口 / 气泡 / 菜单 / 设置窗口） | ⬜ | 待搬 |
