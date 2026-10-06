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
  petWidth: 220,
  showSeconds: 12,
  // 位置（null = 屏幕底部居中）
  x: null,
  y: null,
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
