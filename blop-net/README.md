# blop-net —— .NET 版（Windows-only，进行中）

把 `../desktop-guide/`（PowerShell 7 + WinForms）那套桌宠搬到 .NET 8 + WinForms。

**为什么要搬**：现在的成品要求用户自己装 PowerShell 7，做不到开箱即用。
"把 pwsh 打包进去"不算出路 —— 一份自包含的 pwsh 目录实测 **244.7 MB**，比 Electron 便携版（168 MB）还大，
等于把"装一次"换成"每次都背着"。.NET 版的目标是 **20–70 MB 的单一 exe、不需要任何运行时**。

**代价（说在前面）**：WinForms 就是 Windows-only。跨平台那条线仍然由 `../desktop-pet/`（Electron）负责。
三份实现的功能差距与"有意为之的差别"记在 `../实现差别记录.md`。

## ⚠️ 这台机器上的两个前提

1. **SDK 装在用户目录**（不需要管理员）：`%LOCALAPPDATA%\Microsoft\dotnet\`。
   `winget install Microsoft.DotNet.SDK.8` 只提供机器级安装（要 UAC），所以改用官方
   `dotnet-install.ps1 -Channel 8.0 -InstallDir ... -NoPath`。这条路径**没有进 PATH**。
2. **应用控制策略会拦掉 SDK 产出的文件**（实测，2026-10-12）：

   | 产物 | 结果 |
   | --- | --- |
   | `dotnet build` 出来的 `.dll` | ❌ `0x800711C7 应用程序控制策略已阻止此文件` |
   | `dotnet publish` 单文件自包含 exe（67 MB） | ❌ 进程都起不来 |
   | .NET Framework `csc` 编的 IL-only **exe** | ✅ 能跑 |
   | .NET Framework `csc` 编的 **dll** | ❌ 被拦 |
   | `Add-Type`（内存编译） | ✅ 能跑（桌宠那 2379 行内嵌 C# 一直这么跑） |

   所以：**编译能过、跑不起来**。这不只是本机麻烦 —— 它说明**未签名的 .NET exe 在开着
   Smart App Control / WDAC 的机器上会被直接拦掉**（不是弹个"仍要运行"就能过）。分发给用户前
   代码签名是前置条件，这一点和 Electron 版一样（见 `../desktop-pet/DISTRIBUTION.md`），
   不是"以后再补"的收尾工作。

## 目录

```
src/Blop.Core/           引擎（无 UI）：指纹距离、闸门… 每搬一块都要能用行为用例表验收
src/Blop.Cases/          用例表跑分器（控制台）：读 ../behavior-cases/*.json，失败退出码非 0
verify-addtype.ps1       本机验证：Add-Type 内存编译同一份源码，跑同一张表（策略拦 exe 时的活路）
```

## 怎么跑

```powershell
# 本机（策略拦 exe，走内存编译）—— 现在就能验：
pwsh -NoProfile -ExecutionPolicy Bypass -File .\verify-addtype.ps1

# 没开策略的机器上（真正的 .NET 路径）：
$dotnet = "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe"
& $dotnet run --project .\src\Blop.Cases\Blop.Cases.csproj
```

两条路读的是**同一份 `behavior-cases/*.json`**，也是 PowerShell 版 `DesktopGuide.ps1 -SelfTest`
里跑的那几节（5h / 5l / 5q / 5y）。三份实现结论必须逐条一致 —— 差别只能是表里写明的"有意不同"，
或者还没搬完。

## 进度

| 模块 | 状态 | 验收 |
| --- | --- | --- |
| 指纹距离 `Fingerprint.Distance` | ✅ 已搬 | 与 `Get-FpDistance` 同口径（长度不等返回 999） |
| 闸门 `Gate.Decide` | ✅ 已搬 | `behavior-cases/gate.json` **18/18**（C# 侧实测） |
| 路径解析 / 占位符展开 | ⬜ | 待搬（PowerShell 侧自检 5k） |
| 抓屏 + 8×8 指纹 | ⬜ | 待搬（几何规则已有 `behavior-cases/fingerprint.json`） |
| 账本 / 每日消费上限 | ⬜ | 待搬 |
| DSH 常驻会话（stdio JSON-RPC） | ⬜ | 待搬 |
| WinForms 壳（分层窗口 / 气泡 / 菜单 / 设置窗口） | ⬜ | 待搬 |
