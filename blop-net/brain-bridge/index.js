// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * blop-brain-bridge —— 大脑桥：桌宠问、DSH 答
 *
 * 为什么要有它（而不是让桌宠自己去起一个 dsh 进程）：
 *   dsh 的四个接口（acp / sdk / headless / web）里，前三个都是 stdio —— 必须由调用方起进程。
 *   而"由我们的 .NET 进程当父进程"这件事在本机会让 dsh 起动阶段写 profile 被拒
 *（EPERM: ~\.dsh\profiles\<name>\cordis.yml），从 pwsh 里起同样的命令却没问题。
 *   与其继续啃那个差异，不如换个姿态：**让已经在运行的 DSH 应用自己跑**，我们只当壳。
 *
 * 所以本插件的职责只有两件：读桌宠写的请求文件 → 用本进程内的 agent 问一句 → 把答案写回去。
 * 用的都是官方插件 API：ctx.agents.create / agent.followup / agent.whenIdle（见 packages/core/agent）。
 *
 * 文件协议（桌宠侧实现在 Blop.Core/FileBridgeBrain.cs）：
 *   请求  <dir>\req-<id>.json   { id, prompt, imagePath?, timeoutMs? }
 *   应答  <dir>\ans-<id>.json   { id, ok:true, text, seconds } | { id, ok:false, error }
 * 应答先写 .tmp 再 rename —— 免得对面读到写了一半的文件。
 */

import { mkdirSync, readdirSync, readFileSync, writeFileSync, renameSync, unlinkSync, appendFileSync } from 'node:fs'
import { join } from 'node:path'

export const name = 'blop-brain-bridge'
export const inject = ['agents']

export function apply(ctx, config) {
  const dir = config && config.dir
  if (!dir) throw new Error('blop-brain-bridge 需要 config.dir（放请求/应答文件的目录）')
  const provider = (config && config.provider) || 'deepseek-account'
  const model = (config && config.model) || 'deepseek-flash'
  const pollMs = Number((config && config.pollMs) || 300)
  mkdirSync(dir, { recursive: true })

  const log = (msg) => {
    try { appendFileSync(join(dir, 'bridge.log'), new Date().toISOString() + ' ' + msg + '\n') } catch { }
  }
  log(`bridge 起：dir=${dir} provider=${provider} model=${model}`)

  /** 常驻一个 agent（和"常驻会话"同一个意思，只不过它活在 DSH 应用自己的进程里）。 */
  let handle = null
  let lastText = ''

  async function ensureAgent() {
    if (handle) return handle
    handle = await ctx.agents.create({
      sessionId: 'blop-brain',
      agentOptions: { provider, model },
    })
    // 收它这一轮的回复：assistant/message 的 data.message.content 里挑 text 块
    //（reasoning 块不算 —— 和桌宠侧 SDK 那条路的口径一致）
    handle.agent.ctx.on('assistant/message', (ev) => {
      try {
        const parts = []
        for (const c of (ev && ev.data && ev.data.message && ev.data.message.content) || []) {
          if (c && c.type === 'text' && c.text) parts.push(c.text)
        }
        const text = parts.join('\n').trim()
        if (text) lastText = text
      } catch (e) {
        log('事件解析失败：' + (e && e.message))
      }
    })
    log('agent 已创建')
    return handle
  }

  function blocks(req) {
    const out = []
    if (req.prompt) out.push({ type: 'text', text: String(req.prompt) })
    if (req.imagePath) {
      try {
        out.push({
          type: 'image',
          data: readFileSync(req.imagePath).toString('base64'),
          mimeType: /\.png$/i.test(req.imagePath) ? 'image/png' : 'image/jpeg',
        })
      } catch (e) {
        log('读图失败（就当没有图）：' + (e && e.message))
      }
    }
    return out
  }

  async function answerOne(file) {
    const path = join(dir, file)
    let req = null
    try {
      req = JSON.parse(readFileSync(path, 'utf8'))
    } catch {
      return   // 对面可能正写到一半，下一轮再读
    }
    const id = req && req.id
    if (!id) { try { unlinkSync(path) } catch { } ; return }
    const started = Date.now()
    log(`收到请求 ${id}`)
    try {
      const h = await ensureAgent()
      lastText = ''
      h.agent.followup({
        content: blocks(req),
        source: { kind: 'plugin', plugin: name },
      })
      await h.agent.whenIdle()
      const text = lastText
      writeAnswer(id, { id, ok: true, text, seconds: Math.round((Date.now() - started) / 100) / 10 })
      log(`答完 ${id}：${text.slice(0, 40)}`)
    } catch (e) {
      const err = (e && (e.stack || e.message)) || String(e)
      writeAnswer(id, { id, ok: false, error: err })
      log(`答失败 ${id}：${err}`)
    } finally {
      try { unlinkSync(path) } catch { }
    }
  }

  function writeAnswer(id, obj) {
    const tmp = join(dir, `ans-${id}.json.tmp`)
    const dst = join(dir, `ans-${id}.json`)
    writeFileSync(tmp, JSON.stringify(obj, null, 2), 'utf8')
    renameSync(tmp, dst)
  }

  // 串行处理：一个 agent 同时只跑一轮，收到多个请求就排队
  let queue = Promise.resolve()
  const timer = setInterval(() => {
    let files = []
    try { files = readdirSync(dir).filter((f) => f.startsWith('req-') && f.endsWith('.json')) } catch { return }
    for (const f of files) {
      queue = queue.then(() => answerOne(f)).catch((e) => log('队列里出错：' + (e && e.message)))
    }
  }, pollMs)

  // 插件卸载时收摊：停轮询、拆 agent（agent 一拆，它那个会话也就没了）
  ctx.effect(() => () => {
    clearInterval(timer)
    const h = handle
    handle = null
    if (h) { try { h.dispose() } catch { } }
    log('bridge 停')
  })
}
