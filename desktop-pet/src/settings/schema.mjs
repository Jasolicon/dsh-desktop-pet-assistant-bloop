// 泡泡 · Bloop —— 桌宠设置窗口的数据源（唯一）：分组 + 每个可调项。
//
// 为什么单独一份 schema 而不是从 config.json 反推：
//   配置里还有一堆 `_xxxNote` 说明键、以及 PowerShell 版专属的键（那边 97 个），
//   从文件反推会把它们一起画到界面上，看着像"都能改"，其实改了没用。
//   这里只列**这边真正读**的键 —— 与 src/config.mjs 的 DEFAULTS 一一对应。
//
// 字段含义：
//   key       config.json 里的键名
//   label     界面上显示的名字
//   type      bool / int / number / string / choice
//   choices   type=choice 时的候选项 [{ value, text }]
//   min/max   数值范围（会夹取）
//   live      true = 改完立刻生效；false = 需要重启桌宠
//   help      一句话说明（写"为什么有这个开关"，不是复述名字）

export const STYLES = [
  { value: 'guard', text: '保守 —— 只在明显问题时说' },
  { value: 'coach', text: '陪练 —— 每次判断都给建议' },
  { value: 'roast', text: '损友 —— 先吐槽屏幕上的事再给建议（不骂人、不带脏字）' },
  { value: 'scout', text: '找事 —— 主动提一件它真能替你做的事（你不点它不动手）' },
];

export const SCHEMA = [
  {
    title: '外观',
    items: [
      { key: 'petImage', label: '角色图', type: 'string', live: false, help: '带透明通道的 PNG；留空 = 用仓库自带的 assets/pet.png。' },
      { key: 'petWidth', label: '窗口宽度', type: 'int', min: 240, max: 900, live: false, help: '气泡有多宽、角色图有多大地方站。默认 320（和 PowerShell 版同比例）；比按钮条窄时按按钮条算。' },
      { key: 'fontFamily', label: '气泡字体', type: 'string', live: false },
      { key: 'fontSize', label: '气泡字号', type: 'number', min: 6, max: 40, live: false },
      { key: 'showSeconds', label: '气泡停留（秒）', type: 'int', min: 2, max: 120, live: true, help: '自动消失的气泡也能点 × 提前收起。' },
      { key: 'showHalo', label: '状态光晕', type: 'bool', live: true, help: '角色图背后那圈柔光（思考/说话/聆听时才亮，空闲不显示）。关掉就完全不要它。' },
    ],
  },
  {
    title: '说话风格',
    items: [
      { key: 'speakStyle', label: '风格', type: 'choice', choices: STYLES, live: true, help: '换的不是语气，而是整段提示词。保守/陪练/损友/找事，四种定位见选项里的说明。' },
    ],
  },
  {
    title: '模型与权限',
    items: [
      // 这两项的候选项来自 agents.json（由主进程在 settings:get 里注入，见 main.mjs）——
      // 写死在这里的话，agents.json 一改就和界面不一致了。
      { key: 'mainAgentModel', label: '用哪个模型', type: 'string', live: true, help: '留空 = 用 agents.json 的 mainAgent.model。改完常驻会话会按新模型重建。' },
      { key: 'workAgentAccess', label: '干活时的权限', type: 'string', live: true, help: '留空 = 用 agents.json 的 workAgent.access。「完全访问」意味着它派出去的活不再问你。' },
    ],
  },
  {
    title: '采集与节奏',
    items: [
      // region 是"专用控件"（type: region）：它不是一个能打字的框，而是"框选 / 取消"两个动作，
      // 值由主进程框选后写回（见 src/region-picker.mjs）。别把它改成 string —— 手写坐标没人对得上。
      { key: 'region', label: '监控区域', type: 'region', live: true, help: '只截图这一块：省 token，也更私密。区域外的变化不会叫醒模型。' },
      { key: 'sampleSeconds', label: '采样间隔（秒）', type: 'int', min: 1, max: 60, live: true, help: '采样只算 160px 缩略图的指纹，闸门放行时才抓高质量截图。' },
      { key: 'fastSampleSeconds', label: '活跃时采样间隔（秒）', type: 'number', min: 0.3, max: 10, live: true, help: '用户刚有键鼠输入时使用这个更快的节奏；空闲后自动回到常规采样间隔。' },
      { key: 'minSampleSeconds', label: '采样率下限（秒）', type: 'number', min: 0.2, max: 10, live: true, help: '学习出来的采样率会被夹在 [下限, 上限] 里 —— 免得学出 0.05 秒把机器烧了。' },
      { key: 'maxSampleSeconds', label: '采样率上限（秒）', type: 'number', min: 1, max: 600, live: true },
      { key: 'autoMinutes', label: '自动看一眼（分钟）', type: 'int', min: 1, max: 60, live: true, help: '非损友模式下"多久自动判断一次"。' },
      // 规则表：type: rules 是专用控件（一个 JSON 文本框 + 校验），见 settings.js
      { key: 'taskRules', label: '任务规则表', type: 'rules', live: true, help: '不同应用不同的"多久看一眼、怎么看"：顺序即优先级，进程名或窗口标题**子串**命中即算。hint 会提前写进提示词。' },
      { key: 'screenshotMaxWidth', label: '截图最大宽度', type: 'int', min: 320, max: 3840, live: true, help: '给模型看的那张图的宽度上限；框选区域比它还窄时按原生分辨率给，不放大。' },
      { key: 'jpegQuality', label: '截图 JPEG 质量', type: 'int', min: 10, max: 100, live: true, help: '越低越省 token，越高越清楚。' },
      { key: 'shotStaleSeconds', label: '截图太旧就当没有（秒）', type: 'int', min: 5, max: 600, live: true, help: '模型看不见图有多旧，太旧的图会让它照着窗口标题脑补。超龄的一张都不发，并明说看不到画面。' },
      { key: 'standbyProbeSeconds', label: '待机自愈探测（秒）', type: 'int', min: 5, max: 600, live: true, help: '待机期间每隔这么久试一次"人是不是回来了"——防的是系统通知漏发后它一直以为在待机。' },
      { key: 'standbyProbeIdleSeconds', label: '探测时"人在动"的判据（秒）', type: 'int', min: 5, max: 3600, live: true, help: '距上次键鼠输入小于这么多秒才算人在动；不到这条不唤醒（免得在待机里被误唤醒）。' },
    ],
  },
  {
    title: '对话窗口',
    items: [
      // 对话用的是 DSH 自带的 Web 界面（Markdown / 工具卡片 / 流式都是现成的），
      // 所以这一组只有"起在哪个端口、窗口多大"。
      { key: 'webPort', label: 'DSH Web 端口', type: 'int', min: 1024, max: 65535, live: false, help: '「对话」按钮起的本地服务端口；被占用就换一个。' },
      { key: 'chatWidth', label: '窗口宽', type: 'int', min: 360, max: 2000, live: false },
      { key: 'chatHeight', label: '窗口高', type: 'int', min: 300, max: 2000, live: false },
    ],
  },
  {
    title: '账本（余额 / 消费上限）',
    items: [
      // 余额靠一个 DeepSeek API key（公开余额接口）。type: secret 是**专用控件**：
      // 它写的是 run\deepseek.key 文件，不是 config.json —— key 不该混在配置里到处跟着走。
      { key: 'deepseekKey', label: 'DeepSeek API key', type: 'secret', live: true, help: '填了才能在气泡页脚看到余额。也可以设环境变量 DEEPSEEK_API_KEY（那个优先级更高）。' },
      { key: 'ledgerEnabled', label: '启用账本', type: 'bool', live: true, help: '关掉就不查余额、不播报充值、页脚也不显示（省一次 HTTP）。' },
      { key: 'ledgerWatchSeconds', label: '轮询间隔（秒）', type: 'int', min: 5, max: 3600, live: true, help: '每这么久查一次余额；一次 HTTP，开销可忽略。' },
      { key: 'rechargeMinDelta', label: '充值播报阈值（元）', type: 'number', min: 0, max: 1000, live: true, help: '余额**变大**超过这个数才算"充值到账"——避开观测抖动和几分钱的修正。' },
      { key: 'balanceBroadcastMinutes', label: '定时播报余额（分钟）', type: 'int', min: 0, max: 1440, live: true, help: '0 = 不主动播报（页脚仍然一直显示）。' },
      { key: 'dailySpendCapYuan', label: '每日消费上限（元）', type: 'number', min: 0, max: 10000, live: true, help: '今天花到这就**自动暂停**（不再自己观察花钱）。0 = 不设上限；调大上限会重新武装。' },
    ],
  },
  {
    title: '判断与闸门',
    items: [
      { key: 'judgeMinSeconds', label: '两次判断最小间隔（秒）', type: 'int', min: 5, max: 3600, live: true, help: '本地闸门：值不值得起一次模型调用，由它决定。' },
      { key: 'judgeMinFpDelta', label: '画面差异阈值', type: 'int', min: 0, max: 960, live: true, help: '0..960（8×8 指纹，每格 0..15）。越大越不容易被打扰。' },
      { key: 'fastJudgeSeconds', label: '快速通道最小间隔（秒）', type: 'int', min: 1, max: 60, live: true, help: '窗口切换或画面明显突变时，最多这么快就可以重新判断一次。' },
      { key: 'fastFpDelta', label: '快速通道差异阈值', type: 'int', min: 8, max: 960, live: true, help: '超过这个差异视为明显变化；它只影响快速通道，不替代常规判断阈值。' },
      { key: 'silentBackoffMax', label: '沉默退避倍数上限', type: 'int', min: 1, max: 10, live: true, help: '连续"没什么可说"时，间隔最多放宽到这个倍数。' },
      { key: 'memoryEnabled', label: '长期记忆', type: 'bool', live: true, help: '把观察日志压成一段活动汇总喂给判断——否则它只看得到最近 30 秒。' },
      { key: 'memoryHours', label: '记忆回看（小时）', type: 'int', min: 1, max: 48, live: true, help: '压缩的时候往回看多久。' },
      { key: 'memoryTop', label: '记几个窗口', type: 'int', min: 1, max: 20, live: true, help: '按累计停留排前几名写进记忆。' },
      { key: 'memoryMaxChars', label: '记忆长度上限（字符）', type: 'int', min: 100, max: 4000, live: true, help: '记忆是提示词的一部分，太长会挤掉正文。' },
      {
        key: 'agentEventsEnabled', label: '写脱敏 Agent 事件', type: 'bool', live: true,
        help: '把 DSH 的状态/工具名/错误码写成 logs\\agent-events\\dsh.jsonl；不含消息正文、命令参数或截图路径。',
      },
    ],
  },
  {
    title: '行为',
    items: [
      { key: 'showToolbar', label: '显示功能按钮条', type: 'bool', live: true, help: '宠物脚下那排小按钮（问一句 / 对话 / 打字派活 / 框选 / 记录）。' },
      { key: 'userQuietSeconds', label: '用户操作后安静（秒）', type: 'int', min: 1, max: 60, live: true, help: '你刚动过（点它/打字/拖东西）时，自动判断先让位，停手这么久再补做。' },
      { key: 'askSeconds', label: '等回答（秒）', type: 'int', min: 5, max: 600, live: true, help: 'DSH 问过来的审批/提问等多久算放弃；放弃 = 不写应答文件，交回给 agent 自己决定。' },
      { key: 'routeTyped', label: '打字也先判意图', type: 'bool', live: true, help: '默认关：输入框本来就写着"派活"，敲进去就是明确要做事。开了之后打字也先判 TASK/CHAT。' },
      { key: 'profile', label: 'DSH profile', type: 'string', live: false, help: '派活/判断用哪个 profile（默认 headless）。' },
    ],
  },
  {
    title: '生活节奏与动作',
    items: [
      {
        key: 'rhythmEnabled', label: '生活节奏', type: 'bool', live: true,
        help: '按时段、饭点、节日挑动作和写日志。它只读本地钟表，不叫模型、不截屏。',
      },
      {
        key: 'rhythmTimeZone', label: '节奏时区', type: 'string', live: true,
        help: 'IANA 时区，默认 Asia/Shanghai。节日按这个时区的本地日期算。',
      },
      {
        key: 'rhythmGraceMinutes', label: '错过提醒补发（分钟）', type: 'int', min: 0, max: 120, live: true,
        help: '桌宠晚启动时只补最近一次到点的提醒；超过这个窗口就记一条 missed，不再打扰。',
      },
      {
        key: 'reminderLeadMinutes', label: '默认提前提醒（分钟）', type: 'int', min: 0, max: 120, live: true,
        help: '到点前先提醒一次（0 = 不提前）。单条提醒可在表格里覆盖这个值。',
      },
      {
        key: 'reminderSystemNotification', label: '隐藏时用系统通知', type: 'bool', live: true,
        help: '桌宠隐藏或最小化时，提醒走 Windows 通知中心；关掉就只写日志，不弹任何东西。',
      },
      {
        key: 'actionEnabled', label: '启用动作库', type: 'bool', live: true,
        help: '关掉就回到静态角色图。动作素材默认在 assets\\actions；也可把自定义 WebM/GIF/PNG 放进 actionDir。',
      },
      {
        key: 'actionDir', label: '动作素材目录', type: 'string', live: true,
        help: '留空 = assets\\actions。支持 idle/click/drag/thinking/speaking/greeting/event/meal/holiday 子目录，也支持角色目录。相对路径按桌宠根目录算。',
      },
      {
        key: 'actionScale', label: '动作缩放', type: 'number', min: 0.5, max: 2.5, live: true,
        help: '1 = 按 150×146 的宠物框 contain；默认 1.6（动作原图四周留白较多）。觉得太大就调到 1.2–1.4。',
      },
      {
        key: 'actionIntervalSeconds', label: '自动动作间隔（秒）', type: 'int', min: 15, max: 600, live: true,
        help: '自动事件动作的节拍；会加约 ±15% 抖动，避免整点像闹钟。',
      },
      {
        key: 'actionRules', label: '动作规则', type: 'table', live: true,
        optionsFrom: 'actionFiles',
        help: '触发方式、素材、权重、冷却都可以改。素材按目录分类；新增文件后点表格上方「刷新素材」，不用重启桌宠。',
        columns: [
          { key: 'enabled', label: '启用', type: 'bool' },
          { key: 'label', label: '名称', type: 'text' },
          {
            key: 'trigger', label: '触发', type: 'select', options: [
              { value: 'idle', text: '待机' },
              { value: 'event', text: '自动事件' },
              { value: 'click', text: '点击' },
              { value: 'drag', text: '拖拽' },
              { value: 'thinking', text: '思考' },
              { value: 'speaking', text: '说话' },
              { value: 'greeting', text: '开场' },
            ],
          },
          { key: 'file', label: '素材', type: 'select', optionsFrom: 'actionFiles' },
          { key: 'weight', label: '权重', type: 'number', min: 0, max: 9999 },
          { key: 'cooldownSeconds', label: '冷却秒', type: 'number', min: 0, max: 86400 },
        ],
        newRow: { id: 'custom-action', label: '新动作', file: '', trigger: 'event', weight: 100, cooldownSeconds: 60, enabled: true },
      },
      {
        key: 'rhythmPeriods', label: '时间段', type: 'table', live: true,
        optionsFrom: 'actionOptions',
        help: '支持跨午夜（例如 23:00–05:00）。进入时段时记日志；如果填了动作，会优先播这个动作。',
        columns: [
          { key: 'enabled', label: '启用', type: 'bool' },
          { key: 'label', label: '名称', type: 'text' },
          { key: 'start', label: '开始', type: 'time' },
          { key: 'end', label: '结束', type: 'time' },
          { key: 'action', label: '动作', type: 'select', optionsFrom: 'actionOptions' },
        ],
        newRow: { id: 'custom-period', label: '新时段', start: '09:00', end: '12:00', action: '', enabled: true },
      },
      {
        key: 'mealTimes', label: '饭点', type: 'table', live: true,
        optionsFrom: 'actionOptions',
        help: '进入饭点时会记日志，并优先挑填写的动作（比如吃早餐/午餐/晚餐）。',
        columns: [
          { key: 'enabled', label: '启用', type: 'bool' },
          { key: 'label', label: '名称', type: 'text' },
          { key: 'start', label: '开始', type: 'time' },
          { key: 'end', label: '结束', type: 'time' },
          { key: 'action', label: '动作', type: 'select', optionsFrom: 'actionOptions' },
        ],
        newRow: { id: 'custom-meal', label: '加餐', start: '15:00', end: '16:00', action: '', enabled: true },
      },
      {
        key: 'holidays', label: '节日', type: 'table', live: true,
        optionsFrom: 'actionOptions',
        help: 'solar = 公历固定日期；lunar = 农历（Intl 中文历法，不写死年份）。radiusDays 是节日前后的气氛窗口。',
        columns: [
          { key: 'enabled', label: '启用', type: 'bool' },
          { key: 'label', label: '名称', type: 'text' },
          { key: 'kind', label: '历法', type: 'select', options: [{ value: 'solar', text: '公历' }, { value: 'lunar', text: '农历' }] },
          { key: 'month', label: '月', type: 'number', min: 1, max: 12 },
          { key: 'day', label: '日', type: 'number', min: 1, max: 31 },
          { key: 'radiusDays', label: '前后天数', type: 'number', min: 0, max: 14 },
          { key: 'action', label: '动作', type: 'select', optionsFrom: 'actionOptions' },
        ],
        newRow: { id: 'custom-holiday', label: '新节日', kind: 'solar', month: 1, day: 1, radiusDays: 1, action: '', enabled: true },
      },
      {
        key: 'reminders', label: '时间提醒', type: 'table', live: true,
        optionsFrom: 'actionOptions',
        help: '到点显示气泡、朗读并写日志。days 填 daily / weekdays / weekends 或 1,3,5（周一=1）。错过只补最近一次。',
        columns: [
          { key: 'enabled', label: '启用', type: 'bool' },
          { key: 'title', label: '名称', type: 'text' },
          { key: 'time', label: '时间', type: 'time' },
          { key: 'days', label: '星期', type: 'text' },
          { key: 'leadMinutes', label: '提前分', type: 'number', min: 0, max: 120 },
          { key: 'text', label: '提醒内容', type: 'text' },
          { key: 'action', label: '动作', type: 'select', optionsFrom: 'actionOptions' },
        ],
        newRow: { id: 'custom-reminder', title: '喝水', time: '10:00', days: 'weekdays', leadMinutes: 5, text: '主人，该喝水啦～', action: '', enabled: true },
      },
      { key: '__rhythmLog', label: '节奏日志', type: 'rhythmLog', live: true, help: '时段/饭点/节日/提醒/动作都会写到 logs\\rhythm.jsonl。' },
    ],
  },
  {
    title: '语音输入（可选）',
    items: [
      { key: 'sttEnabled', label: '启用', type: 'bool', live: false },
      { key: 'sttLongPressMs', label: '长按判定（毫秒）', type: 'int', min: 150, max: 2000, live: true, help: '按住这么久才开始录音；松手就识别。' },
      { key: 'sttMaxSeconds', label: '单次最长录音（秒）', type: 'int', min: 3, max: 120, live: true },
      { key: 'sttModelDir', label: '模型目录', type: 'string', live: false, help: '留空 = 用 DSH 自带的 SenseVoice 模型（首次会下载约 229MB）。' },
      // 麦克风：录音是渲染进程用 getUserMedia 做的，所以设备只能由页面自己枚举（type: mic）
      { key: 'sttDeviceId', label: '麦克风', type: 'mic', live: true, help: '留空 = 系统默认。设备名要授权过一次麦克风才看得到（点「刷新」会先要一次权限）。' },
    ],
  },
  {
    title: '朗读（可选）',
    items: [
      { key: 'ttsEnabled', label: '启用', type: 'bool', live: true },
      { key: 'ttsEngine', label: '引擎', type: 'choice', live: true, choices: [
        { value: 'auto', text: '自动 —— 系统音色优先，失败再退回浏览器自带的' },
        { value: 'speech', text: 'speech —— 只用系统音色（离线、瞬时）' },
        { value: 'web', text: 'web —— 只用浏览器自带那条（Mac/Linux 上只有它）' },
      ] },
      { key: 'ttsVoice', label: '音色', type: 'string', live: true, help: '留空 = 自动挑中文音色。写系统里的音色名（可用音色每次启动都写进 start.log）。' },
      { key: 'ttsRate', label: '语速', type: 'int', min: -10, max: 10, live: true, help: '-10..10，0 正常（和 PowerShell 版同一口径）。' },
      { key: 'ttsVolume', label: '音量', type: 'int', min: 0, max: 100, live: true, help: '0..100。' },
      { key: 'ttsMaxChars', label: '最多念多少字', type: 'int', min: 20, max: 600, live: true, help: '超了在标点处截断（别让一句话念三分钟）。' },
      { key: 'ttsQueueMax', label: '待念队列上限', type: 'int', min: 1, max: 10, live: true, help: '自动判断可能连着产出、嘴跟不上：满了丢最旧的。' },
    ],
  },
  {
    title: '路径（装在不常见位置时才要改）',
    items: [
      { key: 'dshRoot', label: 'DSH 安装根', type: 'string', live: false, help: '留空 = 自动探测（配置 → 环境变量 → PATH → 正在运行的 DSH 进程 → 常见位置）。' },
      { key: 'dshExe', label: 'DeepSeek Harness.exe', type: 'string', live: false, help: '留空 = 从安装根推。' },
      { key: 'dshCli', label: 'cli.js', type: 'string', live: false, help: '留空 = 从安装根推（它在 app.asar 归档里，不需要真实存在）。' },
      { key: 'sttNode', label: 'node.exe', type: 'string', live: false, help: '跑语音识别那个 .cjs 用的普通 node。' },
    ],
  },
];
