// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * pet-responder —— 把 DSH「要问人」的两件事接到桌面桌宠上
 *
 * 为什么需要这个插件（这是整个迁移的枢纽）：
 *   在 headless profile 里，DSH 有三个能力**缺同一个东西**——应答者（answerer）：
 *     · 权限审批   dsh-user-approval  走 `approval/request` waterfall
 *     · 提问       dsh-user-questions 走 `user-questions/request` waterfall（agent 的 ask_user_question）
 *     · 计划评审   dsh-plan-mode 的 exit_plan_mode 也是 `ctx.userQuestions.ask(...)`
 *   web UI 里由 dsh-client-ui-approval / dsh-client-ui-user-questions 充当应答者；
 *   headless 里没有 → 一律 fail-closed（审批直接拒、exit_plan_mode 调用即失败）。
 *   本插件注册这两个 waterfall 的监听器，把请求写成 run\ask\req-*.json，
 *   等桌宠写回 ans-*.json，再把结果按各自的词汇表返回。
 *
 * 文件协议（桌宠一侧实现在 DesktopGuide.ps1 的 AskTimer 里）：
 *   请求  run\ask\req-<id>.json   { id, kind:'approval'|'question', at, deadline, ... }
 *   应答  run\ask\ans-<id>.json   approval → { outcome:'allowed-once'|'rejected' }
 *                                 question → { answers:[{id, selected:[label], custom?}] }
 *                                 { canceled:true } = 用户没答（本插件就当没接到，交给下一个应答者）
 *
 * 拿不到应答就**绝不假装**：超时 / 取消 / 用户点"稍后" → 一律走 next()，
 * 让系统保持原来的 fail-closed 行为（审批失败即拒绝）。这条是刻意的。
 */

import { mkdirSync, writeFileSync, readFileSync, existsSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

export const name = 'pet-responder'

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const APPROVAL_OUTCOMES = ['allowed-once', 'rejected', 'cancelled', 'unavailable']

export function apply(ctx, config) {
  const dir = config && config.dir
  if (!dir) throw new Error('pet-responder 需要 config.dir（放请求/应答文件的目录）')
  const timeoutMs = Number((config && config.timeoutMs) || 120000)
  const pollMs = Number((config && config.pollMs) || 200)
  mkdirSync(dir, { recursive: true })

  /**
   * 把一次请求交给桌面，等它的答复。
   * @returns {{answered:boolean, answer?:object, reason?:string}}
   */
  async function askDesktop(kind, payload, signal) {
    const id = `${kind}-${randomUUID().slice(0, 8)}`
    const reqFile = join(dir, `req-${id}.json`)
    const ansFile = join(dir, `ans-${id}.json`)
    const deadline = Date.now() + timeoutMs
    writeFileSync(
      reqFile,
      JSON.stringify({ id, kind, at: new Date().toISOString(), deadline, ...payload }, null, 2),
      'utf8'
    )
    try {
      while (Date.now() < deadline) {
        if (signal && signal.aborted) return { answered: false, reason: 'aborted' }
        if (existsSync(ansFile)) {
          let parsed
          try {
            parsed = JSON.parse(readFileSync(ansFile, 'utf8'))
          } catch {
            await sleep(pollMs)   // 桌宠可能正写到一半，下一轮再读
            continue
          }
          if (parsed && parsed.canceled === true) return { answered: false, reason: 'canceled' }
          return { answered: true, answer: parsed }
        }
        await sleep(pollMs)
      }
      return { answered: false, reason: 'timeout' }
    } finally {
      try { unlinkSync(reqFile) } catch { }
      try { unlinkSync(ansFile) } catch { }
    }
  }

  // ---- 权限审批：返回 outcome 词表里的一个词，或 next() 交给下一个应答者 ----
  ctx.on('approval/request', async (request, next) => {
    const r = await askDesktop('approval', {
      tool: request.tool ?? '',
      callId: request.callId ?? null,
      reason: request.reason ?? '',
      displayReason: request.displayReason ?? '',
    }, request.signal)
    if (!r.answered) return next()
    const outcome = r.answer && r.answer.outcome
    if (!APPROVAL_OUTCOMES.includes(outcome) || outcome === 'unavailable') return next()
    return outcome
  })

  // ---- 提问（ask_user_question / 计划评审）：返回 { answers:[{id,selected,custom?}] } ----
  ctx.on('user-questions/request', async (request, next) => {
    const questions = (request.questions || []).map((q) => ({
      id: q.id,
      question: q.question,
      header: q.header ?? null,
      options: (q.options || []).map((o) => ({ label: o.label, description: o.description ?? '' })),
      multiSelect: q.multiSelect === true,
      detail: q.detail ?? null,
      intent: q.intent ?? null,
    }))
    const r = await askDesktop('question', { questions }, request.signal)
    if (!r.answered) return next()
    const given = Array.isArray(r.answer && r.answer.answers) ? r.answer.answers : []
    const answers = questions.map((q) => {
      const a = given.find((x) => x && x.id === q.id)
      const selected = Array.isArray(a && a.selected) ? a.selected.map(String) : []
      return typeof (a && a.custom) === 'string' && a.custom !== ''
        ? { id: q.id, selected, custom: a.custom }
        : { id: q.id, selected }
    })
    // 一条都没选到 = 用户其实没回答，别伪造一个空答案糊弄模型
    if (!answers.some((a) => a.selected.length > 0 || a.custom)) return next()
    return { answers }
  })
}
