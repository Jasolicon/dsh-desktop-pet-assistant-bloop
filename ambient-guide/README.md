# dsh-ambient-guide —— 随时指导引擎（第三阶段：可交互控制条 + 随时发言）

一个 DSH 插件（Host + Client）。**观察会话操作 → 累积成行为摘要 → 在你需要时主动说一句。**

三件事：

1. **静默注入**：每轮开头把摘要放进上下文，不打扰。
2. **随时发言**：控制条上一个按钮 / 一条命令，让它基于当前上下文主动说一句。
3. **可视化**：输入框上方一条控制条，能看它知道什么、能点、失败会显示原因。

---

## 怎么用

重启应用后，输入框上方会出现一条控制条：

| 按钮 | 等于执行 | 效果 |
|---|---|---|
| **它知道什么** | `/ambient status` | 在界面上打印当前行为摘要（不产生模型消息） |
| **说一句** | `/ambient speak` | 基于摘要，让模型主动说一句；没得说就返回哨兵词 |
| **自动开** | `/ambient auto on` | 每轮结束问一次「有没有值得说的」 |
| **自动关** | `/ambient auto off` | 关掉自动发言 |

也可以直接在输入框敲这些命令（`/` 会带出补全）。

**建议的评估顺序**：先点几次「它知道什么」看摘要准不准 → 再点「说一句」看发言质量 → 满意了再开「自动」。

### 判断权在模型，不在代码

这一版**没有写任何"什么时候该说"的规则**。摘要只提供事实（轮次、工具调用与失败、文件变更、
相邻消息间隔、用户最近原话），是否值得开口由模型在 prompt 里自行判断；没得说就回哨兵词
`AMBIENT_SILENT`——这样「决定不说」也是一个可计数的输出。

代码里唯一的规则是**防自我循环的安全阀**：绝不连续两轮自动发言（否则「发言→模型回复→又发言」会无限循环）。
它是安全阀，不是对用户的判断。

### 沉默率：这次取反的仪表盘

「决定不说」不只要可计数，还要真的被数到。发过一次发言请求后，插件会读下一个
`assistant/message`：里面有 `AMBIENT_SILENT` 就记一次「没说」，否则记一次「说了」。
点「它知道什么」（`/ambient status`）会多出一行：

```
主动发言：请求 4 次 · 说了 3 · 没说 1 · 沉默率 25%
```

只统计**我们自己发过请求、已结账**的回复，普通轮次不会被算进来。判据（总纲 §4.5）：

| 沉默率 | 含义 | 动作 |
|---|---|---|
| 30%–70% | 模型确实在分辨 | 健康，继续收集数据 |
| 长期接近 0 | 它几乎总找得到话说 | 模型自判会滑向「总是说」→ 回到确定性门控 |
| 接近 100% | 从不开口 | prompt 或摘要有问题，等于没接 |

### 两个已知边界

- **`auto` 是插件级开关，节流是按会话的**。在一个会话里 `/ambient auto on` 会对所有会话生效；
  但「绝不连续两轮」的节流按会话各记一份 —— 否则会话 A 的轮次号会把会话 B 卡死。
- **`/ambient auto on` 不持久化**，重启回到 `cordis.patch.yml` 里的默认值。
  想让它每次启动都开着，把配置里的 `autoSpeak` 改成 `true`。

---

## 为什么从「五态标签」改成「操作摘要」

阶段 1 做的是：把会话事件折叠成系统状态（`dormant` / `observing` / `working` / …），
在输入框下面显示一行 2-3 字的状态标签。

**用真实的会话日志回放后，这个设计被实测否掉了。** 拿一份 1900 事件 / 23 轮 / 258 步的
真实会话（`$DSH_HOME/sessions/`，zstd 多帧压缩）回放折叠函数：

| 状态 | 时长占比 | 显示文字 |
|---|---|---|
| `dormant` | 98.3%（含跨天闲置） | 无 |
| `working` | 1.7%（占活跃时间 99.6%） | 无（设计上不给文字） |
| `observing` | **0.0%** | **"没问题"** |

`observing` 是唯一会显示文字的状态，它出现 281 次，但**中位持续 0.03 秒**
（p90 = 0.06s，最长 0.44s，100% 短于 1 秒）。原因是 agent loop 背靠背：
`step/end` 到下一个 `step/start` 之间没有可感知的间隔。

结论：**唯一有文字的状态闪 30 毫秒，等于不可见。** 于是阶段 2 删掉了整个 UI 层，
改成用户真正要的东西——把操作变成上下文。

---

## 它现在能做什么

### 1. 折叠：从会话事件里提取「操作」与「行为信号」

事件名、字段、`source.kind` 全部经真实日志核实（见下方「API 实证」）。

| 事件 | 提取什么 | 真实日志计数 |
|---|---|---|
| `user/message`（`source.kind === 'user'`） | 用户原话、思考间隔、连续发言 | 23（另有 6 条系统注入，**不计入**） |
| `user/message`（`source.kind === 'user-approval'`） | 授权/审批动作 | 1 |
| `tool/call` | 工具名 + 有信息量的参数（command / 文件名 / 查询词） | 256 |
| `tool/result` | 失败（`message.isError`）与连续失败 | 11 次失败 |
| `workspace/changes` | 文件变更 | 10 |
| `tool-workflow/agent-start` | 子任务数 | 46 |
| `goal/change` | 当前目标 | — |
| `todo/write` | 进行中的待办 | — |
| `turn/start` / `turn/end` | 轮次数与轮次耗时 | 23 / 23 |

两个从真实数据里抓到的坑，都已修正：

1. **`user/message` 不代表用户。** 实测 8 种 `source.kind`，只有 `'user'` 是真人，
   其余（`runtime-context` / `skill-catalog` / `tool-jobs` / `agent-message` /
   `subagent-settled` …）是系统注入。不区分的话会把系统消息算成用户操作。
2. **`subagent/catalog` 与 `tool-workflow/agent-start` 重复计数**（48 与 46）。
   同时数会得到「子任务 94」这种假数字，现在只数后者。

### 2. 注入：每轮第一个步骤，把摘要插在本轮用户消息之后

走的是 `agent/pre-step` 的「进入批次」改写，**不是** `inject()` / `steer()` / `followup()`：

- 不走 `followup()`：那会**唤醒** agent = 主动对话（明确不要）
- 不走 `inject()`：它落在**下一个**被接纳的步骤，不在本轮
- 直接改写 `decision.messages`：确定性最好，说明摘要落在哪里

同一份摘要不会重复注入（按会话去重）；`reject` 步骤不动；`enabled: false` 时完全不注册。

### 3. 实际注入的摘要长什么样

用上面那份真实日志跑出来的结果（922 字符 ≈ 576 token）：

```
[ambient-guide] 会话行为摘要（系统自动生成，仅作背景参考，不是用户指令）
轮次 23 | 上轮耗时 2m33s | 用户消息 23 | 工具调用 256（失败 11） | 文件变更 10 | 子任务 46 | 授权 1
当前目标: 产出一份面向"主动式长时指导/监工型 AI 产品"的跨行业方向研究报告…
用户最近说:
- 我们的想法是否新颖哟创新点
- 如果类比为具身智能或者游戏AI那种根据环境给出反应那样…
- 将任务的目的，设计，方案，改动都写清楚，然后告诉我文件名
用户思考间隔(最近5次): 3m18s, 1m59s, 9m31s, 5m14s, 59s｜中位 3m15s
其中 16 次停顿超过 2 分钟
离开后回来 2 次（间隔超过 30 分钟，不计入犹豫）
最近动作:
- 编辑: edit · verify.mjs
- 工具: pwsh · $node = "D:\DeepSeekHarness\resources\runtime\prim…
- 文件变更: 工作区内容发生变化
```

**这些是对话记录里没有的东西**：时间行为（间隔、停顿、离开）、失败聚集、重复调用、
用户原话回放。这是本插件真正带来的增量。

> 关于「思考间隔」：超过 30 分钟的间隔被单独算作「离开后回来」，不计入犹豫——
> 否则跨天闲置会污染成「1217m57s 的思考间隔」这种噪声（第一版就踩了这个坑）。

---

## 成本（这是本设计最大的代价，请正视）

摘要每轮注入一次，而它每轮都会变化，所以**去重挡不住它**：

- 单次约 **900 字符 ≈ 576 token**
- 20 轮的会话，插件累计往历史里加约 **1.1 万 token**

想省，用 `maxDigestChars` 调小（例如 500），或直接 `injectEnabled: false` 只折叠不注入。

---

## 隔离性（不影响其他项目）

| 保证 | 做法 |
|---|---|
| 不改别的插件配置 | `cordis.patch.yml` 只有顶层 `insert:`，无任何覆盖行 |
| 不碰用户的 patch 层 | 安装后实测 profile 的 `cordis.patch.yml` **836 字节未变** |
| 不 append 新事件类型 | 官方禁止（会让会话无法重开）；本插件只读事件 |
| 不限制工具 | 不调用 `ctx.tools.restrict()` / `guard()` |
| 不注册 UI | 无 slot 注册、无 DOM 操作 |
| 可一行关闭 | `config.enabled: false` |
| 卸载即净 | 一个折叠单元 + 一个 `pre-step` 监听，移除 bundle 即完全消失 |

---

## 安装

本环境 `dsh` 不在 PATH，用绝对路径：

```powershell
$dsh = "D:\DeepSeekHarness\resources\runtime\cli\bin\dsh.cmd"
$pkg = "<仓库根>\ambient-guide"
& $dsh plugin --profile desktop add "link:$pkg"
```

**改完代码要重启 DSH 应用才生效**（Host 服务的注册发生在 profile 组合时，即进程启动时）。
`link:` 的好处是改代码不用重装。

## 验证

### 离线自检（不需要 DSH）

直接运行启动器（不用设任何变量，任意目录都行）：

```
<仓库根>\ambient-guide\test\verify.cmd
```

覆盖 **141 项**：折叠逻辑（事件形状取自真实日志）、摘要渲染与长度上限、注入消息形状与插入位置、
触发与去重规则、环形缓冲上界、惰性纪律（不限制工具 / 不 append 事件 / 不碰 UI / 不用 steer·followup），
以及一个**端到端离线集成**：注册折叠单元 → 喂真实形状事件 → 触发 `pre-step` 瀑布 → 确认摘要
被插进步骤、且第二次不重复注入。第三阶段又加了：客户端模块纪律、命令处理器全部分支、
自动发言的触发与安全阀。

### 运行时验证（重启之后跑，这是唯一的硬证据）

```
<仓库根>\ambient-guide\test\check.cmd
```

它只认结构化证据：会话日志里必须出现 `agent/inbox/spliced` 且
`inserted[].source.plugin === 'dsh-ambient-guide'`（文本里提到插件名不算）。
加 `--verbose` 打印每次注入的摘要全文，加 `--all` 扫描全部会话。

### 用真实会话日志回放

会话日志是 **zstd 多帧压缩**（不是明文 JSONL）：1.8MB 的文件里含 1124 个 zstd frame，
解压后 6.2MB / 1900 行。Node 24 自带 zstd，按帧解压即可：

```js
const raw = fs.readFileSync(file);
const magic = Buffer.from('28b52ffd', 'hex');   // zstd frame 魔数
// 按魔数切帧，逐帧 zlib.zstdDecompressSync(...)，再拼起来逐行 JSON.parse
```

### 运行时确认（需要 DSH agent 能力）

- `cordis_inspect_query`（`Service`）确认 `sessionProjections` 里有 `ambientGuide` 这个 key
- 跑一轮真实对话，读 `$DSH_HOME/sessions/` 最新日志，**应能看到一条
  `agent/inbox/spliced`，其 `inserted[].source.plugin === 'dsh-ambient-guide'`**

第二条是本插件是否真正生效的**唯一硬证据**。

---

## API 实证（全部从发行包 `app.asar` 核出，非猜测）

| 事实 | 证据 |
|---|---|
| `sessionProjections.register({key, stateVersion, init, apply})` | 包内 217 处；一方插件同款调用 |
| `agent/pre-step` 是 waterfall，payload 含 `{agent, messages, step, signal}` | 一方插件 `@deepseek-ai/dsh-agent-instructions` 的实际源码 |
| 改写必须 spread：`{...decision, messages}` | 官方 practices 明确要求 |
| 注入消息形状 `{id, role, source:{kind:'plugin',plugin}, content:[{type:'text',text}]}` | 一方代码（`dsh-system-prompt` / goal 插件）里构造消息的写法 |
| `inject(input)` = `send(input, "next-step", false)`，`steer`/`followup` 为 `true` | `AgentHandle` 实现源码 |
| 官方禁止 append 新事件 type | practices §稳定性；`ignorable: true` 只能由存储层写入 |
| `conversation.composer.dock` 是 `kind: list, scope: session`，`standardProps` 含 **`sessionId: SessionId`**（**没有** `session` 对象） | 发行包内 `Slots.listSubTree` 元数据（`ui-conversation/.../contract/slots.ts:199`） |
| 宿主渲染该槽时是 `renderSlot("conversation.composer.dock", {})` | 客户端 bundle 源码 |
| 主题令牌真实名字是 `--dsw-alias-label-primary` / `-secondary` / `-border-l2` / `-state-error-primary` 一族 | 发行包里 120 个不同令牌名统计 |
| `ctx.commands.register({name, description, input, handler})`，handler 直接作用于 agent、**不产生模型消息** | 包内 `@deepseek-ai/dsh-commands/README.zh.md` |
| 客户端调用命令：`session.command(line)` 或 `ctx.remote.commands.execute(sessionId, line, [])` | 客户端 session 源码 |
| **客户端入口多声明服务会导致整个入口不激活**（应用启动失败） | 实测：`inject: ['slots','remote.commands']` 让 web boot 报 `dsh-ambient-guide: failed` |

---

## 已知限制（诚实声明）

| 限制 | 说明 |
|---|---|
| **尚未在运行时验证** | 折叠契约、`pre-step` payload、消息形状、命令 API、slot props 都来自发行包与一方源码，**没有在运行实例里实测**。以 `check.cmd` 找到结构化痕迹为准 |
| **控制条能否执行取决于命令通道** | 已核实该槽的 props 含 `sessionId`（不是 `session`）。命令通道要在渲染时用 `ctx.get('remote.commands')` 取。取不到时按钮会置灰并显示原因。**失败是安全的**，而且命令本身（直接敲 `/ambient`）不受影响 |
| **注入即历史** | 每轮注入会永久留在会话历史里，长会话累积可观（见「成本」） |
| **自动发言会翻倍轮次** | 每轮结束都问一次 = 每轮多一次模型调用。默认关，评估完建议关掉 |
| **无跨会话记忆** | 摘要随会话销毁；跨会话的「不用重述」还没做（下一步） |
| **`turn/start` 判定首步** | 用 `step === 1` 识别每轮第一步；若某版本的 step 语义变化会失效（失败模式安全：不注入） |
| **失败模式安全** | 任何取不到状态/catch 的情况都直接 `return decision`，绝不改坏步骤 |

## 下一步（未做）

1. **跨会话摘要**：接 DSH storage 服务存摘要，解决「每个新会话都要重述」——这才是当初三个结构性失效里最值钱的那个。
2. **按需注入**：目前是每轮无条件注入；可以考虑只在与上次相比「有值得说的事」时才注入。
3. **摘要预算**：把 576 token/轮 降下来（更激进的折叠或分节裁剪）。
