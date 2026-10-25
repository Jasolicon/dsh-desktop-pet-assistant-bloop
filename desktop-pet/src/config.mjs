// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * config.mjs —— 配置读写
 *
 * 从 desktop-guide/config.json 迁移过来的键（用 tools/migrate-config.mjs 生成），
 * 这里只保留重写后还用得到的那些；`_xxxNote` 说明键原样带过来，方便对照。
 *
 * 设计上的取舍：不做 schema 校验库，只做"缺键补默认值"。校验交给 useConfig 的调用方，
 * 出问题时给一条能看懂的错误，而不是抛一个 zod 的堆栈。
 */
import { ROOT } from './paths.mjs';
import { configPath } from './dirs.mjs';
import { readJson, writeJson } from './jsonfile.mjs';
import {
  DEFAULT_ACTION_RULES, DEFAULT_HOLIDAYS, DEFAULT_MEALS, DEFAULT_PERIODS,
} from './rhythm.mjs';

/** 打包后用 userData 目录（源码目录在 asar 里只读），见 dirs.mjs。 */
export const CONFIG_PATH = configPath();

/** 只保留重写后真正会用到的键。别的先放着不动，迁移完再删。 */
export const DEFAULTS = {
  // 外观
  petImage: '',
  fontFamily: 'Microsoft YaHei UI',
  fontSize: 12,
  /**
   * 状态光晕（角色图背后那圈柔光）。
   * 默认开：思考/说话/聆听/暂停时亮一下，空闲时**不显示**（一直挂着只会像个白球）。
   * 关掉 = 任何状态都不显示，只看角色图 + 气泡。
   */
  showHalo: true,
  /**
   * 桌宠窗口宽度（也就是气泡的可用宽度、宠物图片槽位的宽度）。
   * 默认 320 是照 PowerShell 版来的：那边窗口 320 逻辑 px，150 宽的角色居中、按钮条 220 居中 —— 
   * 摆在一起才是同一个比例（之前按 220 算，宠物看着比 PS 版小一圈、气泡也窄）。
   */
  petWidth: 320,
  /** 说话风格：guard 保守 / coach 陪练 / roast 损友 / scout 找事（换的是整段定位，见 settings/schema.mjs）。 */
  speakStyle: 'coach',
  showSeconds: 12,
  /** 底部功能按钮条（问一句/对话/打字派活/框选/记录）。关掉就只剩宠物本体。 */
  showToolbar: true,
  // 位置（null = 屏幕底部居中）
  x: null,
  y: null,
  /**
   * 桌宠**底边**的屏幕坐标（和 y 一起记）。
   * 为什么要它：窗口高度是跟着内容变的（长气泡 → 窗口往上长，见 main.mjs 的 pet:fit）。
   * 只记窗口左上角的 y，退出时若正好开着一条长消息，下次起来桌宠就会往上飘一截 ——
   * 用户摆好的位置得放回原处，所以锚的是"脚踩在哪条线上"。
   */
  bottom: null,
  /**
   * 监控区域（框选出来的那块屏）：{ displayId, x, y, w, h }，坐标是**相对那块屏左上角的 DIP**；
   * null = 整屏。见 src/region.mjs（为什么不是绝对物理像素）。
   */
  region: null,
  // 采集
  sampleSeconds: 2,
  /** 用户刚有键鼠输入时的采样间隔；空闲后回到 sampleSeconds。 */
  fastSampleSeconds: 1,
  /** 学习出来的采样率允许范围（夹住，免得学出 0.05 秒把机器烧了）。 */
  minSampleSeconds: 0.3,
  maxSampleSeconds: 60,
  /**
   * 任务规则表：不同的应用不同的"多久看一眼、怎么看"。顺序即优先级，
   * 进程名或窗口标题**子串**命中即算（见 src/profile.mjs）。
   * 这几条是从 desktop-guide/config.json 原样搬过来的（那是用户自己调过的）。
   */
  taskRules: [
    {
      name: '卡牌/回合制游戏',
      process: ['balatro', 'slay', 'sts', 'hearthstone', 'legends of runeterra', 'mtga', 'yugioh'],
      sampleSeconds: 0.6,
      judgeMinSeconds: 20,
      hint: '这是卡牌/回合制游戏。优先判断：当前手牌能凑出的牌型/连招、这一回合的最优出牌顺序、以及资源（费用、血量、手牌数）的风险；其次才是泛泛的『要不要小心』。不要复述界面上已有的数字。',
    },
    {
      name: '视频/播放',
      process: ['vlc', 'potplayer', 'mpv', 'mpc-hc', 'bilibili', 'youtube', 'iqiyi', 'netflix'],
      title: [' - VLC', 'YouTube', '哔哩哔哩'],
      sampleSeconds: 8,
      judgeMinSeconds: 180,
      hint: '这是视频/音频播放场景。除非画面里出现可证明的问题（报错、卡住、下错片源），否则保持沉默 —— 看片时被打断的代价很高。',
    },
    {
      name: '桌面/空闲',
      process: ['explorer', 'progman', 'workerw', 'searchhost'],
      sampleSeconds: 10,
      judgeMinSeconds: 300,
      hint: '',
    },
  ],
  screenshotMaxWidth: 1024,
  jpegQuality: 60,
  captureFailLimit: 3,
  /**
   * 截图太旧就当没有（秒）：模型看不见图有多旧，会照着窗口标题脑补操作步骤。
   * 超过这个岁数的一张都不发，而且提示词里明说"看不到画面"。
   */
  shotStaleSeconds: 30,
  /** 待机自愈探测：每隔这么多秒试一次"人是不是回来了"（系统通知漏发时的兜底）。 */
  standbyProbeSeconds: 30,
  /** 探测时"人在动"的判据：距上次键鼠输入小于这么多秒。 */
  standbyProbeIdleSeconds: 60,
  // 对话窗口：用 DSH 自己的 Web 界面（见 src/webui.mjs）
  webPort: 4319,
  chatWidth: 560,
  chatHeight: 800,
  // 账本（见 src/ledger.mjs）：查余额、记充值、算今天花了多少、到上限自动停
  ledgerEnabled: true,
  ledgerWatchSeconds: 20,
  /** 余额变大多少才算"充值到账"：避开观测抖动，也免得几分钱的修正被当成充值。 */
  rechargeMinDelta: 0.5,
  /** 定时播报余额（分钟；0 = 不播）。余额/上次调用/今天另外**一直**显示在气泡页脚那行小字里。 */
  balanceBroadcastMinutes: 30,
  /** 每日消费上限（元；0 = 不设）；到线自动暂停 = 不再自己观察花钱。 */
  dailySpendCapYuan: 50,
  // 长期记忆（见 src/memory.mjs）：把观察日志压成一段活动汇总，接进判断提示词
  memoryEnabled: true,
  memoryHours: 4,
  memoryTop: 5,
  memoryMaxChars: 700,
  /** 「清空记忆」= 从现在重新算（存的是时间点，不是删日志）。 */
  memorySince: null,
  /** 观察日志的心跳间隔（秒）：窗口一直不换也要每这么久补一笔，否则最后一段没法定长。 */
  observeHeartbeatSeconds: 120,
  /** 观察日志目录（记忆的原料）。留空 = 本机默认（logs\）；只有诊断/测试才需要改。 */
  memoryLogDir: '',
  // 大脑
  advisor: 'pwsh -NoProfile -ExecutionPolicy Bypass -File "{root}\\advisor-dsh.ps1"',
  advisorFast: 'pwsh -NoProfile -ExecutionPolicy Bypass -File "{root}\\advisor-openai.ps1"',
  autoMinutes: 1,
  showSecondsAfterTask: 20,
  // 路径（留空 = 自动探测，见 paths.mjs）
  dshRoot: '',
  dsh: '',
  dshExe: '',
  dshCli: '',
  profile: 'headless',
  /**
   * 用哪个模型 / 干活时给多大权限 —— 留空 = 用 agents.json 里的 mainAgent.model / workAgent.access。
   * 值写的是 agents.json 里的**名字**（例如 "DeepSeek V4 Pro" / "只读"），不是 provider/model 那些字段：
   * 名字是给人看的，改 agents.json 里的实际配置时这两项不用跟着动。
   */
  mainAgentModel: '',
  workAgentAccess: '',
  // 语音
  sttEnabled: true,
  sttLongPressMs: 400,
  sttMaxSeconds: 20,
  /**
   * 用哪个麦克风（deviceId）。留空 = 系统默认。
   * 注意录音是**渲染进程**用 getUserMedia 做的（Chromium 选设备），所以这一项影响的是那边；
   * 识别本身（stt.mjs）拿到的只是 PCM，与设备无关。
   */
  sttDeviceId: '',
  sttNode: '',
  sttSherpaDir: '',
  sttModelDir: '',
  // 朗读
  ttsEnabled: true,
  /**
   * auto   = 系统引擎优先（src/tts.ps1），失败再退回 Chromium 自带的 Web Speech
   * speech = 只用系统引擎；web = 只用 Web Speech（macOS/Linux 上只有这条）
   * ⚠️ 这台机器上 Web Speech 是坏的（`synthesis-failed`，实测），所以默认 auto 走系统那条。
   */
  ttsEngine: 'auto',
  /** 音色名（系统里的，例如 "Microsoft Huihui Desktop"）；留空 = 自动挑中文音色。 */
  ttsVoice: '',
  ttsRate: 0,          // -10..10（System.Speech 的口径，照 PS 版）
  ttsVolume: 100,      // 0..100
  ttsMaxChars: 180,    // 一句话最多念多少字，超了在标点处截断
  ttsQueueMax: 3,      // 待念队列最多几句，满了丢最旧的（越新的消息越值钱）
  // 行为
  userQuietSeconds: 6,
  /**
   * 选项问答 / 审批应答。
   * askDir 留空 = 用 desktop-guide/run/ask（pet-responder 的 dir 就配在那儿）；
   * 两边必须指向同一个目录才接得上。askSeconds 是等多久算放弃 ——
   * 放弃 = **不写应答文件**，让 responder 自己超时后交给下一个应答者（不伪造答案）。
   */
  askSeconds: 45,
  askDir: '',
  /**
   * 打字派活要不要也先判一次意图。
   * 默认 false：那个输入框本来就写着"派活"，用户敲进去就是明确要做事 —— 不判更省一轮。
   * 打开后打字也走 router.mjs：只是说话就地回一句、不动手（代价是"要做的事"多一轮判定）。
   * 语音那条路**总是**判（见 main.mjs 的 pet:voice），不受这个开关影响。
   */
  routeTyped: false,
  judgeMinSeconds: 60,
  judgeMinFpDelta: 12,
  /** 窗口切换/明显突变的快速通道：不用等满 judgeMinSeconds。 */
  fastJudgeSeconds: 5,
  fastFpDelta: 24,
  silentBackoffMax: 4,

  // ---- 生活节奏与动作（见 rhythm.mjs / rhythm-runtime.mjs）----
  /**
   * 这些是"桌宠像不像活物"的那一层，和判断闸门是两回事：
   * 闸门决定"要不要开口"，节奏决定"现在是什么时辰、该做什么小动作"。
   * 全部走本地钟表，不叫模型。
   */
  rhythmEnabled: true,
  /** 空 = 跟系统时区；固定成 Asia/Shanghai 时，换机器也不会因为时区不同把节日过错。 */
  rhythmTimeZone: 'Asia/Shanghai',
  /** 错过提醒的补发窗口（分钟）：只补最近一次，不会把一整天的提醒倒出来。 */
  rhythmGraceMinutes: 10,
  /** 到点前的提前提醒（分钟，0 = 不提前）；单条提醒可用 leadMinutes 覆盖。 */
  reminderLeadMinutes: 5,
  /** 桌宠隐藏/最小化时，提醒是否走系统通知（否则只在日志里记一条）。 */
  reminderSystemNotification: true,
  rhythmPeriods: DEFAULT_PERIODS,
  mealTimes: DEFAULT_MEALS,
  holidays: DEFAULT_HOLIDAYS,
  /** 用户自己的提醒：{ id,title,time,days,text,action,enabled }。 */
  reminders: [],

  // 动作库：素材默认在 assets\actions，用户可以把自定义 WebM/GIF/PNG 放进 actionDir。
  actionEnabled: true,
  actionDir: '',
  /** 动作视频相对宠物框的缩放；1 = 按 object-fit: contain 装进 150×146。 */
  actionScale: 1.6,
  /** 自动事件动作的间隔（秒）；加 15% 抖动，避免整点闹钟感。 */
  actionIntervalSeconds: 45,
  actionRules: DEFAULT_ACTION_RULES,

  /** 把 DSH 的 agent 生命周期写成脱敏 JSONL（只有事件名/状态/工具名/错误码，不含正文）。 */
  agentEventsEnabled: true,
};

/**
 * 读配置。
 * ⚠️ 以前是"解析不了就 throw"，而 loadConfig 在**模块顶层**就被调用 —— 于是一份坏掉的
 * config.json 让桌宠**根本起不来**（双击闪退，只剩 start.log 里一行栈）。用户丢的不是一次运行，
 * 是"96 项设置 + 一个能用的桌宠"。现在：坏文件留一份 `.bad-<时间>` 备份 + 报出来（见 jsonfile.mjs），
 * 照样返回默认值把桌宠起起来 —— 起得来才有机会把设置改回去。
 */
export function loadConfig(path = CONFIG_PATH) {
  const raw = readJson(path, { ...DEFAULTS }, { missing: { ...DEFAULTS } });
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ...DEFAULTS };
  // 缺键补默认值；多的键原样保留（不静默丢用户的设置）
  const merged = { ...DEFAULTS, ...raw };
  // 这几项是表格编辑器，必须是数组；旧配置或手改坏的标量不能把设置页弄成空表。
  for (const key of ['rhythmPeriods', 'mealTimes', 'holidays', 'actionRules', 'reminders']) {
    if (!Array.isArray(merged[key])) merged[key] = DEFAULTS[key];
  }
  return merged;
}

export function saveConfig(cfg, path = CONFIG_PATH) {
  // 原子替换：拖一下桌宠就会存一次位置，直接覆盖写有"半截文件"的风险（见 jsonfile.mjs 的头注释）
  writeJson(path, cfg);
}
