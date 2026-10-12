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
      { key: 'petWidth', label: '角色宽度', type: 'int', min: 80, max: 600, live: false, help: '逻辑像素；DPI 缩放会自己乘上去。' },
      { key: 'fontFamily', label: '气泡字体', type: 'string', live: false },
      { key: 'fontSize', label: '气泡字号', type: 'number', min: 6, max: 40, live: false },
      { key: 'showSeconds', label: '气泡停留（秒）', type: 'int', min: 2, max: 120, live: true, help: '自动消失的气泡也能点 × 提前收起。' },
    ],
  },
  {
    title: '说话风格',
    items: [
      { key: 'speakStyle', label: '风格', type: 'choice', choices: STYLES, live: true, help: '换的不是语气，而是整段提示词。保守/陪练/损友/找事，四种定位见选项里的说明。' },
    ],
  },
  {
    title: '采集与节奏',
    items: [
      { key: 'sampleSeconds', label: '采样间隔（秒）', type: 'int', min: 1, max: 60, live: true, help: '采样只算 160px 缩略图的指纹，闸门放行时才抓高质量截图。' },
      { key: 'autoMinutes', label: '自动看一眼（分钟）', type: 'int', min: 1, max: 60, live: true, help: '非损友模式下"多久自动判断一次"。' },
    ],
  },
  {
    title: '判断与闸门',
    items: [
      { key: 'judgeMinSeconds', label: '两次判断最小间隔（秒）', type: 'int', min: 5, max: 3600, live: true, help: '本地闸门：值不值得起一次模型调用，由它决定。' },
      { key: 'judgeMinFpDelta', label: '画面差异阈值', type: 'int', min: 0, max: 960, live: true, help: '0..960（8×8 指纹，每格 0..15）。越大越不容易被打扰。' },
      { key: 'silentBackoffMax', label: '沉默退避倍数上限', type: 'int', min: 1, max: 10, live: true, help: '连续"没什么可说"时，间隔最多放宽到这个倍数。' },
    ],
  },
  {
    title: '行为',
    items: [
      { key: 'userQuietSeconds', label: '用户操作后安静（秒）', type: 'int', min: 1, max: 60, live: true, help: '你刚动过（点它/打字/拖东西）时，自动判断先让位，停手这么久再补做。' },
      { key: 'askSeconds', label: '等回答（秒）', type: 'int', min: 5, max: 600, live: true, help: 'DSH 问过来的审批/提问等多久算放弃；放弃 = 不写应答文件，交回给 agent 自己决定。' },
      { key: 'routeTyped', label: '打字也先判意图', type: 'bool', live: true, help: '默认关：输入框本来就写着"派活"，敲进去就是明确要做事。开了之后打字也先判 TASK/CHAT。' },
      { key: 'profile', label: 'DSH profile', type: 'string', live: false, help: '派活/判断用哪个 profile（默认 headless）。' },
    ],
  },
  {
    title: '语音输入（可选）',
    items: [
      { key: 'sttEnabled', label: '启用', type: 'bool', live: false },
      { key: 'sttLongPressMs', label: '长按判定（毫秒）', type: 'int', min: 150, max: 2000, live: true, help: '按住这么久才开始录音；松手就识别。' },
      { key: 'sttMaxSeconds', label: '单次最长录音（秒）', type: 'int', min: 3, max: 120, live: true },
      { key: 'sttModelDir', label: '模型目录', type: 'string', live: false, help: '留空 = 用 DSH 自带的 SenseVoice 模型（首次会下载约 229MB）。' },
    ],
  },
  {
    title: '朗读（可选）',
    items: [
      { key: 'ttsEnabled', label: '启用', type: 'bool', live: true },
      { key: 'ttsEngine', label: '引擎', type: 'choice', live: true, choices: [
        { value: 'auto', text: '自动' },
        { value: 'edge', text: 'edge —— 微软神经音色（音质好，要联网）' },
        { value: 'speech', text: 'speech —— 本机音色（离线）' },
      ] },
      { key: 'ttsVoice', label: '音色', type: 'string', live: true, help: '留空 = 用引擎默认音色。' },
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
