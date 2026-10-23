// 问问题打通 CC 桥（plan-问问题-cc桥）：AskUserQuestion 题面/答案的 pending 记账、
// 帧广播、TUI 键序驱动。hub.ts 只做接线（端点/WS/清理钩子），逻辑都在这——book-notes 模式。
//
// TUI 键位（2026-08-04 隔离探针实测，见 research-问问题-cc桥.md §一）：
//   单选=数字键（多题自动翻下一题，单题直接提交）；多选=数字 toggle + Tab 走 Submit 页按 "1"；
//   自由输入=数字选 "Type something" 行 + 直打 + Enter；整卡跳过=Esc（CC 收 declined）。
import { timedSyncFs } from "./block-ledger"
const { existsSync, readFileSync, writeFileSync } = timedSyncFs("askuser ")
import { join } from "node:path"

export interface AskUserOption { label: string; description?: string }
export interface AskUserQuestionSpec {
  question: string
  header?: string
  options: AskUserOption[]
  multiSelect?: boolean
}
/// app 发来的单题答案：选项下标（多选多个）或自由文本。CC 路径没有单题跳过（X=整卡 Esc）。
export interface AskAnswer { indices?: number[]; text?: string }

export interface PendingAskUser {
  toolUseId: string
  chatId: string
  sessionId: string
  sessionName?: string
  questions: AskUserQuestionSpec[]
  ts: number
  /// app 答案驱动成功后暂存（PostToolUse 才是权威；hook 断了时 reply 兜底用它而不是误报 declined）
  drivenAnswers?: Record<string, string>
}

/// 与 hub 的 realPasteIO 结构同形（自定义接口避免 import 环）
export interface AskUserIO {
  sendLiteral: (text: string, session: string) => void | Promise<void>
  sendKey: (key: string, session: string) => void | Promise<void>
  capturePane: (session: string) => string | Promise<string>
  sleep: (seconds: number) => void | Promise<void>
}

// ── 状态 ──

const pending = new Map<string, PendingAskUser>()   // key = tool_use_id
let storePath = ""
let broadcaster: ((json: string) => void) | null = null

export function initAskUser(secretsDir: string, bc: (json: string) => void): void {
  storePath = join(secretsDir, "askuser-pending.json")
  broadcaster = bc
  try {
    if (existsSync(storePath)) {
      const raw = JSON.parse(readFileSync(storePath, "utf8")) as PendingAskUser[]
      for (const p of raw) { if (p?.toolUseId) pending.set(p.toolUseId, p) }
      if (pending.size > 0) console.log(`[hub] askuser pending loaded (${pending.size})`)
    }
  } catch (e: any) { console.warn(`[hub] askuser pending load fail: ${e.message}`) }
}

function save(): void {
  try { writeFileSync(storePath, JSON.stringify([...pending.values()])) }
  catch (e: any) { console.warn(`[hub] askuser pending save fail: ${e.message}`) }
}

export function questionFramePayload(p: PendingAskUser): string {
  return JSON.stringify({ type: "ask_user_question", chat_id: p.chatId, tool_use_id: p.toolUseId, questions: p.questions })
}

// 最近 resolved 帧（重连补发——app 收帧瞬间可能离线，Q/A 泡不能丢；app 按
// ccMessageId=askuser:<toolUseId> 三层去重，重复无害）。内存态即可（丢失场景=帧漏+hub 重启双重合，接受）。
const resolvedLog: string[] = []
const MAX_RESOLVED_LOG = 50
export function resolvedFrames(): string[] { return [...resolvedLog] }

function broadcastResolved(p: PendingAskUser, answers?: Record<string, string>): void {
  // questions 一并带上：app 端不持 pending（重启/别的设备）也能按题序拼 Q/A 气泡
  const frame: any = { type: "ask_user_resolved", chat_id: p.chatId, tool_use_id: p.toolUseId, questions: p.questions }
  if (answers && Object.keys(answers).length > 0) frame.answers = answers
  else frame.declined = true
  const json = JSON.stringify(frame)
  resolvedLog.push(json)
  while (resolvedLog.length > MAX_RESOLVED_LOG) resolvedLog.shift()
  broadcaster?.(json)
}

export function getPending(toolUseId: string): PendingAskUser | undefined { return pending.get(toolUseId) }
/// stream 传输的权限卡：不是 hook 发的，hub 自己合成一张塞进同一条 pending → app 帧路径
export function registerExternalQuestion(p: PendingAskUser): void {
  pending.set(p.toolUseId, p); save(); broadcaster?.(questionFramePayload(p))
}
export function resolveExternal(toolUseId: string, answers: Record<string, string>): void {
  const p = pending.get(toolUseId); if (!p) return
  pending.delete(toolUseId); save(); broadcastResolved(p, answers)
}
export function pendingList(): PendingAskUser[] { return [...pending.values()] }
export function markDriven(toolUseId: string, answers: Record<string, string>): void {
  const p = pending.get(toolUseId)
  if (p) { p.drivenAnswers = answers; save() }
}

// ── hook 事件（POST /agent/ask-user）──

/// pre：记账 + 广播题面帧；post：answers 权威收账。返回给 hook 的响应体。
export function handleHookEvent(body: any, sessionNameOf: (sessionId: string) => string | undefined): { ok: boolean; reason?: string } {
  const toolUseId = typeof body.tool_use_id === "string" ? body.tool_use_id : ""
  const chatId = typeof body.chat_id === "string" ? body.chat_id : ""
  if (!toolUseId || !chatId) return { ok: false, reason: "invalid_body" }
  if (body.event === "pre") {
    const questions = Array.isArray(body.questions) ? body.questions : []
    if (questions.length === 0) return { ok: false, reason: "no_questions" }
    const p: PendingAskUser = {
      toolUseId, chatId,
      sessionId: typeof body.session_id === "string" ? body.session_id : "",
      sessionName: sessionNameOf(body.session_id),
      questions, ts: Date.now(),
    }
    pending.set(toolUseId, p)
    save()
    broadcaster?.(questionFramePayload(p))
    console.log(`[hub] askuser pre chat=${chatId.slice(0, 8)} tool_use=${toolUseId.slice(0, 12)} q=${questions.length} session=${p.sessionName ?? "?"}`)
    return { ok: true }
  }
  if (body.event === "post") {
    const p = pending.get(toolUseId)
    if (!p) return { ok: true, reason: "not_pending" }   // 已被 reply 兜底清过等，幂等
    const answers = (body.answers && typeof body.answers === "object") ? body.answers as Record<string, string> : {}
    pending.delete(toolUseId)
    save()
    broadcastResolved(p, answers)
    console.log(`[hub] askuser post chat=${p.chatId.slice(0, 8)} tool_use=${toolUseId.slice(0, 12)} answered=${Object.keys(answers).length}`)
    return { ok: true }
  }
  return { ok: false, reason: "invalid_event" }
}

// ── 清理钩子 ──

/// 该 chat 来了 reply = turn 结束。还挂着的 pending：驱动过→用暂存答案收账（hook 断了的兜底）；
/// 没驱动过→Esc/超时 declined 收账。（实测 Esc 不触发 PostToolUse，这是 declined 的唯一信号源。）
export function resolveOnReply(chatId: string): void {
  for (const p of [...pending.values()]) {
    if (p.chatId !== chatId) continue
    pending.delete(p.toolUseId)
    broadcastResolved(p, p.drivenAnswers)
    console.log(`[hub] askuser resolved-on-reply chat=${chatId.slice(0, 8)} tool_use=${p.toolUseId.slice(0, 12)} ${p.drivenAnswers ? "driven" : "declined"}`)
  }
  save()
}

/// 单条按 declined 收账（skip 驱动成功 / 连接重验发现 TUI 死了）。
/// 实测 Esc 不触发 PostToolUse，declined 必须由 hub 主动收账。
export function resolveDeclined(toolUseId: string, reason: string): void {
  const p = pending.get(toolUseId)
  if (!p) return
  pending.delete(toolUseId)
  save()
  broadcastResolved(p)
  console.log(`[hub] askuser declined (${reason}) tool_use=${toolUseId.slice(0, 12)}`)
}

/// session 重 spawn/kill：TUI 没了，挂着的问题按 declined 收账。
export function clearForSession(sessionName: string, reason: string): void {
  for (const p of [...pending.values()]) {
    if (p.sessionName === sessionName) resolveDeclined(p.toolUseId, reason)
  }
}

// ── TUI 存活校验 + 键序驱动 ──

/// pane 里问题卡还挂着吗。⚠️ 不锚页脚——粟粟手机终端 attach 会把 pane 压到 52 列，
/// 多题的长页脚（…Tab/Arrow keys…）被省略号整段截掉，锚 "Esc to cancel" 在窄 pane 必假阴
///（2026-08-06 实案：q=1 短页脚放得下全成功、q=2 全 ui_gone）。
/// 结构锚：任一题面前缀（去空白容折行）+ 左缘编号选项行（行号贴左缘，多窄都活着）。
export function askUiAlive(snapshot: string, questions: AskUserQuestionSpec[]): boolean {
  const flat = snapshot.replace(/\s+/g, "")
  const questionVisible = questions.some(q => flat.includes(q.question.replace(/\s+/g, "").slice(0, 8)))
  const optionRowVisible = /(?:^|\n)\s*(?:❯\s*)?1\./.test(snapshot)
  return questionVisible && optionRowVisible
}

export type KeyStep =
  | { kind: "digit"; text: string }
  | { kind: "key"; key: string }        // tmux 键名："Tab" / "Enter" / "Escape"
  | { kind: "text"; text: string }      // send-keys -l 直打
  | { kind: "sleep"; s: number }

/// 答案 → TUI 键序（纯函数可测）。answers 与 questions 按下标对齐。
/// 校验失败（长度不匹配/下标越界/空答案）返回 null。
export function buildKeySequence(questions: AskUserQuestionSpec[], answers: AskAnswer[]): KeyStep[] | null {
  if (answers.length !== questions.length) return null
  const steps: KeyStep[] = []
  for (let i = 0; i < questions.length; i++) {
    const q = questions[i]
    const a = answers[i]
    if (!a) return null
    const freeTextRow = q.options.length + 1   // "Type something." 行号
    if (typeof a.text === "string" && a.text.length > 0) {
      steps.push({ kind: "digit", text: String(freeTextRow) })
      steps.push({ kind: "sleep", s: 0.4 })
      steps.push({ kind: "text", text: a.text })
      steps.push({ kind: "sleep", s: 0.3 })
      steps.push({ kind: "key", key: "Enter" })
    } else if (Array.isArray(a.indices) && a.indices.length > 0) {
      if (a.indices.some(x => !Number.isInteger(x) || x < 0 || x >= q.options.length)) return null
      if (!q.multiSelect && a.indices.length !== 1) return null
      for (const idx of a.indices) {
        steps.push({ kind: "digit", text: String(idx + 1) })
        steps.push({ kind: "sleep", s: 0.25 })
      }
      // 多选不自动翻题：Tab 去下一题/Submit 页（单选数字后自动翻，无需导航键）
      if (q.multiSelect) steps.push({ kind: "key", key: "Tab" })
    } else {
      return null
    }
    steps.push({ kind: "sleep", s: 0.4 })
  }
  return steps
}

/// app 答案 → {题面: 答案串}（drivenAnswers 兜底用；多选 join 与 CC 一致逗号+空格）
export function formatAnswers(questions: AskUserQuestionSpec[], answers: AskAnswer[]): Record<string, string> {
  const out: Record<string, string> = {}
  for (let i = 0; i < questions.length; i++) {
    const a = answers[i]
    if (!a) continue
    out[questions[i].question] = typeof a.text === "string" && a.text.length > 0
      ? a.text
      : (a.indices ?? []).map(x => questions[i].options[x]?.label ?? "").join(", ")
  }
  return out
}

export const DRIVE_SETTLE_S = 0.6
export const SUBMIT_RETRY_MAX = 2

/// 驱动一次作答（调用方包 chainSessionSend 串行）。skip=true 发 Esc。
/// 每步前后快照校验：卡不在=stale（不盲发键——键会漏进输入框）。
export async function driveAnswer(
  p: PendingAskUser, answers: AskAnswer[] | null, skip: boolean, io: AskUserIO,
): Promise<{ ok: boolean; reason?: string }> {
  const session = p.sessionName
  if (!session) return { ok: false, reason: "no_session" }
  if (!askUiAlive(await io.capturePane(session), p.questions)) return { ok: false, reason: "ui_gone" }

  if (skip) {
    await io.sendKey("Escape", session)
    return { ok: true }
  }
  const steps = answers ? buildKeySequence(p.questions, answers) : null
  if (!steps) return { ok: false, reason: "invalid_answers" }
  for (const s of steps) {
    if (s.kind === "sleep") { await io.sleep(s.s); continue }
    if (s.kind === "key") { await io.sendKey(s.key, session); continue }
    await io.sendLiteral(s.text, session)   // digit / text 都走 -l
  }
  // 收尾：多题/多选会停在 Review 页 → 按 "1"（Submit answers）；单题单选已自动提交。
  // ⚠️ Review 页没有页脚（E2E 踩的）——先查 Review 再判"已收"；"还开着"用结构锚 askUiAlive
  //（页脚在窄 pane 会被截断，不可依赖，同上）。
  await io.sleep(DRIVE_SETTLE_S)
  for (let i = 0; i < SUBMIT_RETRY_MAX; i++) {
    const snap = await io.capturePane(session)
    if (/Review your answers|Submit answers/.test(snap)) {
      await io.sendLiteral("1", session)
      await io.sleep(DRIVE_SETTLE_S)
      continue
    }
    if (!askUiAlive(snap, p.questions)) return { ok: true }           // 非 Review 且题卡结构不在 = 已收
    await io.sleep(DRIVE_SETTLE_S)
  }
  const last = await io.capturePane(session)
  const closed = !/Review your answers/.test(last) && !askUiAlive(last, p.questions)
  return closed ? { ok: true } : { ok: false, reason: "submit_unconfirmed" }
}

/// 测试/换库用：清空内存态（不碰盘）
export function _resetForTest(): void { pending.clear() }
