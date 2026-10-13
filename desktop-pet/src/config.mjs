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
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { ROOT } from './paths.mjs';
import { configPath } from './dirs.mjs';

/** 打包后用 userData 目录（源码目录在 asar 里只读），见 dirs.mjs。 */
export const CONFIG_PATH = configPath();

/** 只保留重写后真正会用到的键。别的先放着不动，迁移完再删。 */
export const DEFAULTS = {
  // 外观
  petImage: '',
  fontFamily: 'Microsoft YaHei UI',
  fontSize: 12,
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
  screenshotMaxWidth: 1024,
  jpegQuality: 60,
  captureFailLimit: 3,
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
  // 语音
  sttEnabled: true,
  sttLongPressMs: 400,
  sttMaxSeconds: 20,
  sttNode: '',
  sttSherpaDir: '',
  sttModelDir: '',
  // 朗读
  ttsEnabled: true,
  ttsEngine: 'auto',
  ttsVoice: '',
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
  silentBackoffMax: 4,
};

export function loadConfig(path = CONFIG_PATH) {
  if (!existsSync(path)) return { ...DEFAULTS };
  let raw;
  try {
    raw = JSON.parse(readFileSync(path, 'utf8'));
  } catch (err) {
    throw new Error(`配置文件不是合法 JSON：${path}\n${err.message}`);
  }
  // 缺键补默认值；多的键原样保留（不静默丢用户的设置）
  return { ...DEFAULTS, ...raw };
}

export function saveConfig(cfg, path = CONFIG_PATH) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(cfg, null, 2)}\n`, 'utf8');
}
