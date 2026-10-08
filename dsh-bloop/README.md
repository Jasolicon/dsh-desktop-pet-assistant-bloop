# dsh-bloop —— 泡泡 · Bloop 的 DSH 插件外壳

**它只是个壳。** 桌宠本体还是 `desktop-guide/` 那套（PowerShell 引擎，一行没重写）；
这个包的活儿是：**一行装好**、把引擎拉起来、接上对外接口、退出时收干净。

```
插件壳（跑在 DSH 进程里，只做轻活）            引擎（现在这套，原样搬进 engine/）
 ├─ 装 / 开 / 生命周期（DSH 退了就收摊）  ─spawn─▶  engine/DesktopGuide.ps1
 ├─ 备运行时（本机 pwsh → 自带便携版 → 5.1 兜底）      （抓屏 / 指纹 / 闸门 / 派活 / 语音）
 ├─ 看门（崩了重启，退避 + 次数上限）        ◀──HTTP──  GET /dsh-bloop/state
 └─ 对外接口 /dsh-bloop/{state,say,pause,resume}       POST /say → run\ext-cmd\<id>.json
```

## 装（一行）

```sh
dsh plugin --profile desktop add dsh-bloop     # 发布到 npm 之后
# 从源码装（本机开发）：
node scripts/build-engine.mjs                  # 先把引擎组装进 engine/
dsh plugin --profile desktop add file:<仓库>\dsh-bloop
# 然后重启 DSH
```

装完用户拿到的东西：**右键「对话」照旧、桌宠照旧**，只是它现在住在 DSH 的插件体系里，
而且状态都在 `%USERPROFILE%\.dsh\bloop\`（不在 `node_modules` 里）。

## 状态与运行时

| 东西 | 放哪 | 为什么 |
|---|---|---|
| 配置 / 记忆 / 录音 / 日志 / 语音模型 | `%USERPROFILE%\.dsh\bloop\`（`DG_HOME`） | 引擎住在 `node_modules` 里，插件一升级 pnpm 会换掉整个目录 |
| 引擎源码 | 包里的 `engine/`（由 `scripts/build-engine.mjs` 组装，**不进 git**） | 唯一源码在 `desktop-guide/`，仓库里不放第二份 |
| PowerShell | 本机 `pwsh`（PATH）→ 自带便携版 `bloop\runtime\pwsh\` → `powershell.exe` 兜底 | 还没做自动下载（见「下一步」） |

首次启动时，引擎会把包里的 `config.json` / `agents.json` / `presets\<风格>.txt` **种**到状态根，
之后一切以状态根为准（包里那份只是出厂默认）。**本地自己跑（`start.cmd`）不设 `DG_HOME`，
状态就还在脚本旁边 —— 行为完全和以前一样，不会偷偷搬家。**

### 两种形态是互斥的

插件形态和"双击快捷方式"那份的状态根是两个目录，所以引擎里原来看 `run\pet.pid` 的单实例检查
**互相看不见**。现在多了一把**机器级锁** `%LOCALAPPDATA%\Bloop\pet.lock`（和形态、状态根都无关）：
谁先跑谁占锁，后起来的那个会被拦下并说明"是谁在跑、怎么让位"。锁上记的 pid 死了就当没锁
（不会出现"锁着但没人跑"把用户永久挡住）。

外壳侧配套改了一处：**引擎退出码 0 视为"正常退出"，不重启** —— 被锁拦下、或用户右键退出，
都属于这种情况；只有非 0（真崩）才按崩溃重启。

## 对外接口

只监听本机、不走 `/api` 那套浏览器信任闸门：

| 接口 | 作用 |
|---|---|
| `GET /dsh-bloop/state` | 引擎 pid / 存活 / 重启次数 / 运行时 / 状态根 / 路由表 |
| `POST /dsh-bloop/say` | `{"text":"..."}` → 让桌宠说一句（气泡 + 朗读），同步等回执 |
| `POST /dsh-bloop/pause` / `resume` | 暂停 / 继续观察（等价于托盘那两项） |

```sh
curl -s http://127.0.0.1:4319/dsh-bloop/state
curl -s -X POST http://127.0.0.1:4319/dsh-bloop/say -d '{"text":"该起来走两步了"}'
```

> 引擎那边不自己开端口：它每 500ms 扫 `run\ext-cmd\*.json`，处理完写 `done-<id>.json` 当回执。
> 少开一个监听就少一个被扫的面，而且这套和现有的 `run\ask`（DSH 问人、桌宠回答）是同一个思路。

## 端到端测试

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File dsh-bloop\scripts\e2e-test.ps1
```

它会：建独立 profile `bloop-test`（**不碰 desktop / web / headless**）→ 一行装 → 起 DSH →
验 12 项 → 硬杀 DSH 看孤儿 → 收摊。**会短暂弹出桌宠窗口**（引擎是桌面程序），
但测试前会把状态种成 `{paused:true, muted:true, auto:false}`，所以不花模型钱、也不出声。

## 实测结果（2026-10-08，本机 DSH + pwsh 7.6.5）

12/12 全过：

| 项 | 结果 |
|---|---|
| `dsh plugin add file:` 一行装 | ✅ 786 ms，自动写进 `dsh.profile.bundles` |
| 外壳跑在 DSH 进程里 | ✅ `shell-apply.json.hostPid` == DSH 进程号 |
| 引擎被拉起且活着 | ✅ pid 54048，运行时 `pwsh 7.6.5` |
| 状态写在 `~/.dsh\bloop` | ✅ `config.json` / `agents.json` / `system-prompt.txt` / `run\` 都在 |
| **包目录零状态** | ✅ `node_modules\dsh-bloop\engine` 跑完还是 35 个文件、一个不多 |
| `GET /state` | ✅ 200 |
| `POST /say` | ✅ `{ok:true, chars:23}`（引擎日志里也有 `ext_say`，不是外壳自演） |
| `POST /pause` | ✅ 200 |
| 硬杀宿主 | ✅ 引擎靠 `-HostPid` 看门狗自己退（≤20 s，实测 2 s 级） |
| **不留 DSH 孤儿** | ✅ 引擎退出时把它自己起的对话窗口服务也收了 |

## 这一轮踩到的坑（都写进代码注释了）

1. **参数不能叫 `-Home`**：`$HOME` 是 PowerShell 的只读自动变量，绑定参数会直接打断脚本
   （引擎静默退出码 1）。现在是 `-DgHome`。
2. **`DG_HOME` 的解析必须放在最前面**：`Get-RunningPetPid`（"已经在跑就别起第二个"）在第 113 行
   就被调用，它要用 `Get-DgHome` —— 解析段排在 129 行时，插件形态下引擎一启动就崩，
   外壳连着重启 6 次才停下来。**自检绕过启动路径（`-SelfTest` 不查"已经在跑"），所以它全绿也
   不代表能起来** —— 这才是端到端测试存在的意义。
3. **`dsh plugin add file:<dir>` 是"快照"**：改了包内容，`install --force` 也只会说
   "Already up to date"，必须 `remove` + `add`。（发布走版本号，不受影响。）
4. **硬杀宿主会漏掉引擎的子进程**：`taskkill /T` 杀不掉"引擎用 `Start-Process` 拉起的 DSH 对话服务"
   （实测漏了一个，还锁住状态根里的文件）。所以外壳收摊改成**先请引擎优雅退出**（`ext-cmd quit`
   → `FormClosing` → 收对话服务/大脑），超时才 `taskkill`。
5. **顺手修了一个既有 bug**：引擎原来的 `FormClosing` **从来没停过对话服务** ——
   也就是说本地自己跑桌宠时，每退一次都在漏一个 DSH 进程（Electron，几百 MB）。
   现在退的时候会起个短命子进程去 `Stop-WebUi`（引擎进程里没有这个函数，
   对话服务是另一个 pwsh 起的）。
6. **`$home` 不能当变量名**（同 1，测试脚本里也踩了一次）。

## 下一步（还没做）

- **便携版 pwsh 自动下载**（`bloop\runtime\pwsh`）：照 dsh-pet 的 `ensure-electron.mjs` 那套，
  从 PowerShell 官方 Release 取 win-x64 zip 解压。做完用户就只剩"一行装插件"。
- **发布**：`npm publish` 前跑 `npm run build:engine`（`prepack` 已挂）；
  商店上架还要按 DSH 版本逐个标 `dsh.compatibility.dshReleases`。
- **设置页**：现在动配置走引擎自己的设置窗口（右键 →「所有设置…」）；要挂进 DSH 设置页得写 `lib/client.js`。
