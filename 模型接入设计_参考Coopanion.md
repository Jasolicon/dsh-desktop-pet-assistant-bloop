# 模型接入设计 —— 参考 Coopanion / Cortico

**日期**：2026-10-05
**源码**：`D:\Code\Coopanion-main\Coopanion-main`
**读的文件**：`packages/cortico-provider-coo/src/{index,vendors,connect,pricing}.ts`、
`core/companion.ts`、`packages/cortico-world-desktop-pet/web/rig/rig.js`
**注**：`vendor/cortico` 是空子模块（下载时没初始化），所以 Cortico 框架内部的
`ProviderModule` 基类看不到；但 Coopanion 自己那份 `COO` 导出把**契约的完整形状**暴露了出来，够用了。

---

## 0. TL;DR

它把「接 9 家大模型」压缩成了 **一张数据表 + 一个模块 + 一套控制台路由**，而且这张表同时喂给了
别的四五个地方（引导卡片、图标、定价、桌宠配色）。真正值得抄的不是框架，是这三件事：

1. **供应商是数据，不是代码**（`vendors.ts` 一个文件声明 9 家）
2. **能力是声明出来的**（`vision[]` / `contextWindows{}` / `effort{}`），不是在调用处 if-else
3. **连接是一条固定的四步流水线**（存 → 测 → 激活 → 恢复运行）

顺带挖到一个对「桌宠 Live2D」直接有用的东西：它的鲸鱼**没有用 Live2D Cubism**，
而是自研了一个 300 行的 Live2D 式渲染器（`web/rig/rig.js`）——见 §4。

---

## 1. 它长什么样

```
Vendor 表 (vendors.ts)                  ← 唯一的真相：9 家的 baseUrl / key / 默认模型 / 能力
      │
      ├──→ ProviderModule 「coo」(index.ts)   ← 一个模块，注册给框架
      │        · accepts()  这张图该不该发给这个端点
      │        · prices()   这套模型的价格
      │        · create()   造出 client（带思考档重写 + 图片裁剪）
      │
      ├──→ 端点 (endpoint)                    ← 一家一个，配置文件里是普通 Cortico config
      │        { kind:'coo', baseUrl, secret, spec:{model,thinking,...}, multimodal }
      │        · 身份（哪一家）**不存**，用 baseUrl 反查（vendorOf）
      │        · 一个端点一个 Key → 来回切换不丢 Key
      │
      ├──→ 控制台路由 /api/providers/*        ← 添加 / 保存 / 测试 / 激活
      │
      └──→ 桌宠配色 schemes/<id>/             ← 同一批 id 又变成 8 套鲸鱼皮肤
```

---

## 2. 可迁移的 8 条

### 2.1 供应商是数据表，不是代码

`vendors.ts` 里每家就是一个对象：

```ts
{ id:'deepseek', name:'DeepSeek', baseUrl:'https://api.deepseek.com',
  keyUrl:'https://platform.deepseek.com/api_keys', keyHint:'sk-…',
  secret:'DEEPSEEK_API_KEY', model:'deepseek-flash', models:['deepseek-v4-pro'],
  vision:['deepseek-flash'], contextWindows:{...} }
```

**加一家 = 加一条记录**，不碰任何逻辑。引导页的厂商卡片、图标、申请链接、默认模型、
Key 输入框的 placeholder，全部从这条记录派生。

### 2.2 能力用声明表达，不用 if-else

```ts
accepts: (entry, spec, mime) =>
  entry.multimodal === true && mime.startsWith('image/') && readsImages(entry, spec.model)
```

「这个模型能不能看图」= `vendor.vision.includes(model)`。
**一处声明，调用处永远不用问「是哪一家」**。

### 2.3 身份从 baseUrl 反查，配置里不存冗余状态

```ts
export function vendorOf(baseUrl) {
  const url = trimSlash(baseUrl.trim());
  return VENDORS.find(v => url === v.baseUrl || url.startsWith(`${v.baseUrl}/`)) ?? null;
}
```

端点里只存 `baseUrl`，**不存 `vendor: 'deepseek'`**。少一个字段，就少一处能不一致的地方
（也意味着用户把 baseUrl 改到别家时，行为自动跟着变对）。

### 2.4 思考档：界面四档，每家一套映射

界面统一 `off / low / high / max`；每家在自己的记录里给出 `effort` 映射，取不到就删掉整个
`reasoning` 字段：

| 厂商 | 映射 |
|---|---|
| 千问 | `high→medium`、`max→xhigh` |
| Kimi | `none→low`（它没有 off） |
| 百度千帆 | 四档全 `null` → 不发 `reasoning` |
| MiniMax | `max→high` |

实现只有一段：`buildResponseBody` 里把 `reasoning.effort` 换成对方认的值；映射到 `null` 就 `delete body.reasoning`。
**界面不感知差异，厂商差异被压进数据。**

### 2.5 图片只发「最新一批」（最省钱的一条）

```ts
function sinceLastDelivery(context) {
  // 从最后一条 user 消息 / 外部事件帧往前找，之前的条目里的 image blob 全部摘掉
}
```

历史里的图片如果不摘，**每一轮请求都会重发**，直到交接（handoff）。摘掉之后文字行还在，
模型仍知道"当时有张图"，但不复付图片 token。

**对我们的价值**：desktop-guide 每次判断带最多 6 张截图，这是同一类浪费。

### 2.6 价格按需内置

`prices(entry)` 只对 DeepSeek 返回价格表，其他家返回 `[]`（用户自己填）。
价格表还区分**高峰/尖峰**（工作日 UTC 01–04、06–10 双倍），并且注释里老实写明
「中国法定假日也按非高峰计费，但这里没列，所以节假日会按高峰算」。

### 2.7 连接是四步流水线

`connectVendor()`：

```
① 已经存在同名端点？  有 → GET 详情（拿 revision）→ 带 expectedRevision 保存
                       无 → POST 新建
② POST /test            测试连接，失败就返回原因（不再往下走）
③ POST /activate        切换为当前端点
④ POST /run/resume      恢复运行
```

两个细节值得抄：
- **`expectedRevision`**：保存带乐观锁，避免并发覆盖。
- **没有 Key 时运行是 `paused`**：所以④是「恢复」而不是「启动」。这样"没配好模型"不会变成
  一个静默失败的后台任务。

### 2.8 一个 Key 一个端点，切换不丢

每家一个独立端点，命名就是厂商 id。用户从 DeepSeek 换到 Kimi 再换回来，**Key 还在**。
引导里的 `keyAlready()` 也是从这套结构直接读出来的。

---

## 3. 映射到我们

### 3.1 最直接的复用点：desktop-guide 的「大脑」

现状：`config.json` 里 `advisor` / `advisorFast` 是**两条命令行字符串**
（`pwsh -File advisor-dsh.ps1`），切换大脑要手改字符串，没有测试、没有"当前用哪家"、
没有能力声明（哪个大脑能看图）。

| Coopanion | 我们的等价物（建议） |
|---|---|
| `VENDORS[]` 数据表 | `brains.json`：`{id, name, cmd, vision:bool, needsKey, defaultModel, note}` |
| `accepts()` | `Test-BrainVision($brain)` —— 自动判断要不要附截图 |
| `POST /test` | 一条 `/test` 命令：跑一次空调用，量延迟、报错原因 |
| `POST /activate` | `设置 → 主 agent 模型` 已有雏形，改成读表 |
| `effort` 映射 | 我们的 `thinking` 档 → 各家参数名 |
| 定价表 | 现在没有；可只在 `brain.pricing` 里给一家填 |

**收益**：加一个大脑从"写一个脚本 + 改两处 config"变成"加一条记录"；
而且「这个大脑能不能看图」从人脑记忆变成代码可查——这正好是 D1 类问题的预防。

### 3.2 ambient-guide 需不需要？

**暂时不需要**。它不选模型：注入的摘要进的是宿主 agent 的上下文，模型由 DSH 的
`agentOptions: { provider, model }` 决定，我们不该越权。

**但有一个将来会需要**：如果按 M3 把门控做成确定性代码、再单独用一个小模型做「值不值得说」的
二分类，那就该用这套（一张小模型表 + 一次 `/test`），而不是把模型名硬编码进插件。

### 3.3 我们该抄什么、不抄什么

| 抄 | 不抄 |
|---|---|
| 供应商/大脑 = 数据表 | Cortico 的 World/Provider 框架（我们的宿主是 DSH） |
| 能力声明（vision / contextWindow / effort） | 控制台路由的具体形状（我们有 profile patch + commands） |
| 四步连接流水线 + 乐观锁 | `kind:'coo'` 这类框架内部字段 |
| 图片只发最新一批 | 它的 9 家具体参数（版本会过时，抄结构就行） |

---

## 4. 意外收获：它自研了一个 Live2D 式渲染器

这条直接回应我们「也做桌宠 Live2D」那件事。

它的鲸鱼**没有用 Live2D Cubism**，而是 `web/rig/rig.js` —— **10 KB、约 300 行**：

```
一个部件 = 一张贴图铺在一个网格上
每帧网格点穿过部件的变形器链（由内向外）：
  rot  ：绕枢轴转/缩放/平移   p' = pivot + t + R(a)·S·(p − pivot)
  warp ：矩形上的位移场        p' = p + fn(u,v)
WebGL2 绘制
```

配套两个很实用的机制：

- **换肤即换贴图**：同一套几何，`schemes/<id>/` 只是不同贴图；
  `figure.setScheme(id, { fade: 秒 })` 在两张贴图之间交叉淡入（fragment shader 里 `mix(tex, tex2, uMix)`）。
- **八套配色就是八家厂商**：`schemes/` 下是 `deepseek(默认) / chatgpt / claude / gemini / harness / kimi / minimax / qwen`。
  也就是说**同一张 vendor 表又变成了皮肤 id**。

**对我们的意义**：如果目标是 2.5 头身的 Q 版桌宠，自研网格变形器比走 Cubism 建模-绑骨-导出的
链路轻得多，而且能和我们的"状态=光晕/配色"直接合流（`accent` 色随状态变）。
我们已有 `desktop-guide` 的 GDI+ 分层窗口和 `ambient-guide` 的 client 渲染面，接一条 WebGL2
渲染路径的成本是可控的。

---

## 5. 落地建议（按成本从低到高）

| # | 动作 | 成本 | 收益 |
|---|---|---|---|
| 1 | 把 `effort`/`vision` 这类"能力声明"的思路用在 desktop-guide：`brains.json` 记 `vision: true/false`，附截图前先查 | 低 | 消灭"给不能看图的模型发图"这类错 |
| 2 | desktop-guide 加一条 `/test` 命令：跑一次空调用，报延迟与错误 | 低 | 换大脑时不用猜 |
| 3 | 截图负载做 `sinceLastDelivery` 式裁剪：只保留最新一批 | 低 | 直接省 token |
| 4 | 把 `advisor` / `advisorFast` 两条命令行升级成 `brains.json` 表 | 中 | 加一家 = 加一条记录 |
| 5 | 评估自研 rig 路线（照 `rig.js` 的结构）替代 Live2D Cubism | 中高 | 与状态配色天然合流 |

---

## 附：关键文件索引（对方仓库内）

| 内容 | 文件 |
|---|---|
| ProviderModule 契约的完整形状 | `packages/cortico-provider-coo/src/index.ts` |
| 9 家供应商数据表 | `packages/cortico-provider-coo/src/vendors.ts` |
| 连通性测试与四步激活 | `packages/cortico-provider-coo/src/connect.ts` |
| 价格表（含高峰/非高峰） | `packages/cortico-provider-coo/src/pricing.ts` |
| 厂商图标 | `packages/cortico-provider-coo/src/icons.ts` |
| 引导里的厂商卡片 / Key 框 | `core/guide.ts` |
| 供应商 id ↔ 桌宠配色 | `packages/cortico-world-desktop-pet/web/whale/schemes/<id>/` |
| 自研 Live2D 式渲染器 | `packages/cortico-world-desktop-pet/web/rig/rig.js` |

