# DSH 架构事实速查(交互设计约束来源)

**用途**:为"随时指导"交互设计提供实现约束。只登记与交互形态直接相关的事实,并标注出处(DSH 发行包内 README / 类型声明)。

**来源**:`D:\DeepSeekHarness\resources\app.asar`(asar 包,12967 个文件),重点是 `@deepseek-ai/dsh-agent`、`dsh-agent-loop`、`dsh-api-session-controller`。

---

## 1. 整体结构

- **插件系统**:基于 `@deepseek-ai/cordis`(Context/Service/Fiber 模型)。37 个 `@deepseek-ai/dsh-*` 包,绝大多数是插件,通过 YAML 配置声明挂载。
- **多端**:web GUI(`dsh web`,注入 `window.__DSH_BOOT__`)、desktop host(`dsh-desktop-host`)、ACP(`dsh-acp` / `dsh-acp-app`)。
- **会话模型**:`dsh-api-session-controller` 维护 session 生命周期,通过 `dsh-api-gateway` 对外暴露,客户端持有投影(projection)。

---

## 2. 核心:轮次 / 步骤 / 收件箱

```
会话(Session) = 事件日志(append-only)
   └─ 轮次(Turn)   ← 在轮次边界领取「下一条消息」+ 一条排队提示词
        └─ 步骤(Step) ← 在步骤之间只领取「next-step 输入」
             └─ 模型请求 → 流式响应 → 工具执行
```

**关键事实**

| 事实 | 出处 | 对交互设计的含义 |
|---|---|---|
| 每个步骤发送「派生历史」+「可见工具 schema」 | agent-loop README §一个步骤做什么 | 状态是**派生**的,不是另存的——状态机必须从会话日志推导 |
| 模型工具调用经「受守卫的工具流水线」 | 同上 | 工具执行处已有拦截点 |
| 取消是**协作式**的;被取消的流会**终结已送达用户的文本** | 同上 | 打断不会丢失用户已看到的内容 |
| **没有内置轮次预算**;工具调用或 steering 会让当前轮次继续 | agent-loop README §已知限制 | 轮次可以被"续命"——这就是主动介入的机制基础 |

---

## 3. 三种注入语义(这是主动指导的挂载点)

来自 `dsh-agent` 的 `AgentHandle` API:

| 方法 | 语义 | 是否唤醒驱动器 | 落点 |
|---|---|---|---|
| `followup()` | 排队一条**下一轮次**提示词 | **唤醒** | 下一轮次 |
| `steer()` | 提交**下一步**输入 | **唤醒** | 下一个步骤 |
| `inject()` | 添加面向模型的上下文 | **不唤醒** | 下一个**被接纳的**步骤 |

**这三条恰好覆盖了「静默 / 轻提示 / 打断」三种介入强度**,不需要自己造机制:

| 介入强度 | 对应方法 | 何时用 |
|---|---|---|
| 只记入上下文,不打扰 | `inject()` | 常规状态更新、静默结转 |
| 立刻影响下一步 | `steer()` | 红线、必须马上纠正的偏差 |
| 留到下一轮再说 | `followup()` | 轻度建议、事后补充 |

**注意**:`inject()` 不唤醒驱动器,因此**如果 agent 此刻空闲,注入的内容会一直等到下一次被接纳的步骤**。这既是优点(天然批量)也是约束(空闲时无法主动发起)。

---

## 4. 生命周期钩子(可拦截 / 可观察)

| 事件 | 能力 | 这里能做什么 |
|---|---|---|
| `agent/pre-step` | **可以拒绝拟进入的步骤,或替换进入它的消息** | 最后一道闸门:决定这一步要不要带上引导内容 |
| `agent/turn-stopping` | 在本可完成的轮次关闭前运行,**可通过 steer 让它保持打开** | 天然检查点:轮次要结束了,是否该做一次汇总/提醒 |
| `agent/request-error` | 让监听器**重试**失败的模型请求 | 容错 |
| `agent/assistant-stream` | 有序 start / 分片 / end frame;进程本地 | **实时呈现数据**(非回放来源) |
| `agent/status` / `agent/created` / `agent/disposed` | 驱动 UI 与协调状态 | 状态指示器的数据源 |
| `agent/inbox/*` | 逐消息通知:`inserted` / `claimed` / `discarded` | 收件箱投影同步 |

**`agent/turn-stopping` 是最被低估的一个**:它是唯一一个"系统主动决定要不要继续说"的时点,而且**不打断用户**,因为轮次本来就要结束了。这正好是"决策点"的天然位置。

---

## 5. 收件箱(Inbox)与消息身份

- 每次 inbox 变更都提交规范化的 `agent/inbox/spliced` 事件;`Session.append()` 返回时**实时投影已反映该 splice**。
- 插入 / 编辑 / 移除 / 领取 / 取消**都通过同一组 splice 坐标回放**。
- 领取 = 纯删除(无 outcome)+ `agent/inbox/claimed`;取消 = 带 `outcome:'canceled'` + `agent/inbox/discarded`。
- `MessageId` 在两个待处理列表之间保持唯一。

**含义**:收件箱是一个**可回放的结构化队列**,不是一个简单的消息数组。任何"系统替用户说话"的机制,只要走 inbox,就是可审计、可撤销、可回放的。

---

## 6. 客户端投影与分栏

`dsh-api-session-controller` 客户端:

- `SessionSnapshot.pendingSubmissions` — 本地提交回显,**在调用方序列化与发送提示词之前同步插入**,使 UI 能在点击当帧显示消息。
- 分栏推导:`placement = running ? (mode==='steer' ? 'steering' : 'queued') : 'transcript'`
- 投递模式:`mode: 'queue' | 'steer'`
- 错误:`session/steer-unavailable`("current turn no longer accepts steering")、`promptError` 落在快照上。
- **`steer` 只在 `agent.status === 'running'` 时可用。**

**含义**:UI 侧已经区分「transcript / queued / steering」三种消息位置。**主动注入如果要在界面上可见,必须选择进哪一栏**——这是交互设计里一个具体的决策点。

---

## 7. 与交互形态直接相关的结论

1. **状态是派生的,不是另存的。** DSH 的会话日志是 append-only 事件流,任何"任务状态机"都应从日志推导,而不是维护一份平行状态(否则必然不一致)。
2. **三种注入强度已经现成。** 不需要造轮子;需要的是**决定什么时候用哪一种**——这恰恰就是门控。
3. **`inject()` 是"沉默"的技术对应物。** 它把内容送进上下文却不打扰用户。这正好实现前面交互设计里"在场的沉默"。
4. **`turn-stopping` 是天然的检查点。** 它不打断任何东西(轮次本来就要结束),是放"决策点选项"的最佳位置。
5. **`agent/pre-step` 是最后一道闸门。** 如果门控要"撤回"一次不该发出的提示,这是唯一的位置。
6. **空闲时无法主动发起。** 这是这套架构最硬的一条约束:**没有在途轮次时,系统不能"自己开口"**。所以"随时"必须建立在"一个持续在跑的会话"之上,或者由外部事件(文件变化、定时器)去唤醒。

---

## 8. 未确认项

以下事项目前**没有证据**,不应在设计里当成已知:

- web GUI 是否已经把 `steer` / `inject` 暴露到界面上(只确认了服务端与客户端库支持,未确认 GUI 是否使用)。
- `inject()` 的内容在 UI 上是否可见(文档只说明它"面向模型")。
- 是否存在面向"屏幕观察"的现成插件(未在包列表中见到;`dsh-attachment` 是附件相关,不是屏幕感知)。
- desktop host 与 web GUI 在会话呈现上的差异(未展开)。
