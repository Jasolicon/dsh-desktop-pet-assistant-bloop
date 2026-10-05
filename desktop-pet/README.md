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

### ⚠️ Electron 版本：**33 在这台机器上会崩，用 28**

2026-10-05 本机实测。先说结论：**Electron 33.4.11 起不来，28.3.3 正常**，所以
`package.json` 钉在 `^28`。这不是"这台机器跑不了 Electron"，只是版本问题。

排查过程（都留了可复现的探针）：

```
最小探针 tools/probe.cjs（只有 app.whenReady() 后打印一行再退出）

  electron 33.4.11 : [probe] module loaded … 然后 exit=-1073741819 (0xC0000005)
                     事件日志的"出错模块"就是 electron.exe 自己，偏移固定 0x1f1e1bb
                     --disable-gpu / --disable-gpu-compositing / --disable-features=Vulkan /
                     --use-angle=swiftshader 全试过，一样崩
  electron 28.3.3  : [probe] module loaded → [probe] app ready, quitting   exit=0  ✔
```

另外两条排查中被否掉的假设，记下来省得重走：

- **不是"未签名 exe 一律被拦"**。这台机器 Smart App Control 确实是强制开着
  （`HKLM\...\CI\Policy\VerifiedAndReputablePolicyState = 1`），但**本地用 csc 编译的、
  完全没签名的 WinForms exe 跑得好好的**（探针见仓库根的 `packaging-probe/`）。
  SAC 的证据不成立。
- **不是下载标记**：npm 解出来的 `dist/` 里一个 `Zone.Identifier` 都没有。

已知的坑还有一个：`--no-sandbox` 是必需的（不加，连 `--version` 都不返回）。

#### 想看渲染结果，别用桌面截图

桌面的 `CopyFromScreen`（BitBlt）**拍不到透明的置顶窗口** —— 实测窗口明明在 z=02、
Win32 枚举也报 `vis`，截图里却什么都没有，白白怀疑了一轮渲染。

要看渲染结果用这个（从渲染进程内部抓，最可信）：

```powershell
$env:PET_DEBUG_CAPTURE = "$PWD\debug-render.png"
npm run start:no-sandbox     # 窗口打开 1.5 秒后自动存图并退出
```

#### 派活链路：已通

```
node -e "import('./src/brain.mjs').then(m => m.askDsh('只回复两个字：可用', {}).then(r => console.log(JSON.stringify(r))))"
→ {"ok":true,"text":"可用","seconds":4.663}
```

用的是**你在 DSH 里已登录的账号**，不是环境变量里的 key —— 靠 `src/agents.mjs`
生成一份 `--patch` 把 `provider: deepseek-account` 注入进去，等价于 `dsh-agents.ps1` 的
`Write-AgentPatch`。

patch 的字段名是 desktop-guide 那侧踩出来的、写错不会报错只会静默不生效，
所以 `test/agents.test.mjs` 把它们锁住了：模型那条 id 必须是 `agent-default-model`；
权限那条必须是 `permission`（写成 `permission-presets` 会新增一条而不是覆盖，
权限就从来没生效过）。

## 交互

| 操作 | 效果 |
|---|---|
| 左键点宠物 | 说一句（走 DSH 主 agent） |
| 双击宠物 | 打开/收起打字派活输入条 |
| 按住拖动 | 挪位置（位置记进 config.json） |
| 右键宠物 | 菜单：显示/隐藏、打开配置目录、退出 |
| 输入条里回车 / 点发送 | 派活给 agent，跑完结论显示在气泡里 |

### 它自己什么时候开口

后台每 `sampleSeconds`（默认 2 秒）采样一次，但**每次采样不等于每次叫模型**：

```
每 2s：读前台窗口 + 算 8×8 画面指纹      （很便宜）
   ↓
本地闸门 src/gate.mjs（纯函数）
   画面变了吗？窗口换了吗？距上次多久？人还在不在？连着几次没说了？
   ↓ 值了才往下走
抓一张高质量截图 → 交给 DSH 主 agent 看一眼 → 说一句，或者回 SILENT
```

角标显示**累计"看过了但决定不说"的次数** —— 沉默是一等输出，不是"什么都没发生"。
判断过程都记在 `logs/decisions.jsonl`（`skip` / `silent` / `spoke` 三种）。

想只开窗口不开观察循环（调试用）：`$env:PET_NO_AUTO='1'`。

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
- **分发方案（不花钱也能发）**：见 [DISTRIBUTION.md](DISTRIBUTION.md)

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
