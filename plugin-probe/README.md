# plugin-probe —— 「桌宠能不能做成 DSH 插件」的极薄探针

它不干正事，只回答四个问题。**每个答案都落成 `<stateDir>` 下的 json**，可以事后复核，不用信我说。

> 为什么要有它：`PC2005-cloud/dsh-pet`（1122★）证明了"桌宠可以做成一行装好的 DSH 插件"，
> 但它是**纯看板娘**（整个仓库零截屏调用）。我们要知道的是：**我们这种"主动抓屏做辅助"的桌宠，
> 能不能也走插件的分发方式** —— 而不是把抓屏塞进 DSH 进程里（那样会顶到 DSH 的 UI 线程）。

## 探针验的四件事

| # | 问题 | 判据（落盘文件） |
|---|---|---|
| ① | 插件宿主半边能不能 **spawn 子进程**，子进程能不能**真的抓屏** | `apply.json`（宿主跑起来了）+ `spawn.json`（子进程 pid/命令行）+ `capture.json`（每拍屏幕上真抓到的指纹） |
| ② | 能不能在 DSH 的 WebServer 上**挂本机路由**（对外接口） | `GET /dsh-petprobe/state` 返回 JSON；`POST /dsh-petprobe/say` 落 `say.log` |
| ③ | **收摊**：宿主 dispose 时子进程收不收得掉；宿主被**硬杀**时会不会留孤儿 | `stopped.json`；硬杀 DSH 后看子进程是不是自己退出（`child-exit.json`） |
| ④ | 浏览器半边（`client.js`）能不能被 DSH 正常加载 | `/plugins/dsh-petprobe/client.js` 能取到；页面控制台有 `[dsh-petprobe] client 半边加载成功` |

## 目录

```
plugin-probe/
├─ index.js           宿主半边：spawn 子进程 + 定时器 + 路由 + 收摊（cordis 插件）
├─ client.js          浏览器半边：最小骨架，只打一行日志
├─ cordis.patch.yml   把插件挂进 profile 的那一条 insert
├─ package.json       dsh.bundle.patch / dsh.client 声明
├─ probe/capture.ps1  被 spawn 的那个子进程：真抓屏 + 8x8 指纹 + 宿主探活
└─ run-probe.ps1      编排：建独立 profile → 装插件 → 起 DSH → 验四件事 → 硬杀 → 看孤儿
```

## 怎么跑

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File plugin-probe\run-probe.ps1
```

- **只用独立 profile `probe-pet`**（从 DSH 自带的 `web` 模板建），绝不碰你的 `desktop` / `web` / `headless`。
- 状态写在 `%USERPROFILE%\.dsh\petprobe\`，报告写在 `run\probe-report.json`。
- 跑完会把 DSH（探针那个实例）停掉；profile 保留，想删：`Remove-Item -Recurse ~\.dsh\profiles\probe-pet`。

## 实测结果（2026-10-08，本机 DSH + pwsh 7.6.5）

`pwsh -NoProfile -ExecutionPolicy Bypass -File plugin-probe\run-probe.ps1` → **四件事全过**，
全流程 **9.8 秒**（含把 DSH 起起来）。逐条证据：

| # | 结论 | 证据 |
|---|---|---|
| ① spawn + 真抓屏 | **能** | `apply.json.hostPid` 与 DSH 进程号**相同**（117360）；子进程 48732 每 2 秒抓一次屏，8×8 指纹 64 字符，单次抓屏 **43 ms** |
| ② 本机路由 | **能** | `GET /dsh-petprobe/state` → 200 JSON，**不需要 token**、只监听 127.0.0.1；`POST /say` → 200 且落盘 `say.log` |
| ③ 收摊 | **能，但必须自己做** | 硬杀 DSH 后子进程**自己退了**（子进程每拍 `Get-Process -Id <hostPid>` 探活）；`childStillAlive=False` |
| ④ 浏览器半边 | **能** | client.js HTTP 200、527 字节、内容确认是我们的 |

**插件现场能拿到的服务**（不是猜的，查出来记进 `apply.json`）：`timer`、`webServer`、`agents`、`llm`、`commands`。
（用 `credentials` / `homePaths` 这两个名字**取不到** —— 以后要读凭证得先找对服务名。）

### 三条要记住的

1. **别把抓屏塞进插件宿主半边。** `hostPid` 和 DSH 进程号相同 = 宿主代码跑在 **DSH 自己的 Node 进程**里。
   我们那条"0.6 秒抓一次 + 编码"的循环塞进去就是顶 DSH 的 UI；放在子进程里跑，单次 43 ms 且与 DSH 无关。
2. **客户端半边的 URL 不能手拼。** DSH 把它编进页面的 `__DSH_BOOT__`，形状是
   `plugins/??<id>/client.js&rev=<hash>` —— 少了 `rev` 就是 404（第一版手拼 `/plugins/dsh-petprobe/client.js`，实测 404）；
   而且那个首页要一次性 token（服务自己打在 stdout 里）。
3. **子进程必须自己探活宿主。** 宿主被硬杀时 dispose 根本不会跑，不自己收就留孤儿。
   （`dsh-pet` 的 Electron helper 也是这么做的 —— 它注释里写着 issue #56。）

### 探针自己踩的坑（顺手记下）

编排脚本第一版**没清上一轮的状态文件**：`apply.json` 一存在，`Wait-Until` 立刻返回，
读到的却是上一次的 `hostPid` —— `hostPidMatches` 直接假阴性。现在开跑前先清 7 个现场文件。
「拿上一轮的结果当本轮结论」是这类端到端探针最容易犯的错，别的探针（比如 `packaging-probe`）也该照着做。

### 所以：我们的桌宠能不能做成 DSH 插件？

**能，而且不用重写引擎** —— 形态就是"薄插件壳 + 现在的独立抓屏进程"：

```
插件壳（跑在 DSH 进程里，只做轻活）        我们的引擎（现在这套，不变）
 ├─ 安装/开机/DSH 设置页                ─spawn─▶  DesktopGuide.ps1 或 Electron 版
 ├─ 生命周期（DSH 退了就收摊，含探活）              （runspace 抓屏、指纹、闸门、派活）
 ├─ GET /state + 动作路由  ◀──HTTP───            对外接口（别的插件/脚本据此驱动它）
 └─ dsh.compatibility 兼容性声明
```

代价（都还成立）：绑 DSH 版本、要维护那份兼容性声明、以及"装桌宠的人不预期被截屏"这个信任问题。
好处是**一行装 + 插件商店分发**，而且**绕开 Smart App Control**：这条路跑的是 DSH 自己 + 官方签名的
Electron + 我们的脚本，不需要再发一个自己的 exe。

复跑 / 清理：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File plugin-probe\run-probe.ps1   # 复跑
Remove-Item -Recurse "$env:USERPROFILE\.dsh\profiles\probe-pet"            # 拆掉探针 profile
Remove-Item -Recurse "$env:USERPROFILE\.dsh\petprobe"                      # 清掉探针状态
```
