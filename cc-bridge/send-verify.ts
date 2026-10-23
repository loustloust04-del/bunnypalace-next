/// K1 第 4b 步（docs/plan-hub-perf.md）：结果不明的消息由 hub 自己核对送达——这里是纯工具和状态账，流程在 send-track.ts。
/// 协议：hub→app `{type:"send_status", chat_id, message_id, session_name, status:"uncertain"|"delivered"|"failed", retryable, reason?}`；
/// app→hub 重发 = 原 send 帧 + `retry:true`，只接受这里记为 failed 且 retryable 的 message_id
import { open, readdir, stat } from "node:fs/promises"
import { join } from "node:path"

export type SendStatus = "uncertain" | "delivered" | "failed"

export interface SendStatusFrame {
  type: "send_status"
  chat_id: string
  message_id: string
  session_name: string
  status: SendStatus
  retryable: boolean
  reason?: string
}

const CHAT_RE = /^<channel source="memorypalace"[^>]*?\schat_id="([^"]*)"/
const TS_RE = /^<channel source="memorypalace"[^>]*?\sts="([^"]*)"/
const MID_RE = /^<channel source="memorypalace"[^>]*?\smessage_id="([^"]*)"/
const CLAIM_RE = /"claim_token":"([^"\\]+)"/
const OPEN_TAG_RE = /^<channel\b[^>]*>/

/// 从 buildChannelTag 产出的文本里取 chat_id / message_id（只认开头那个 memorypalace channel 标签的属性）
/// ts：hub 收到这次 send 帧的时刻，同一个 message_id 每次发送（含重新生成、重发）都不同，用来区分「第几次」
export function channelIds(tag: string): { chatId?: string; messageId?: string; ts?: string } {
  return { chatId: CHAT_RE.exec(tag)?.[1], messageId: MID_RE.exec(tag)?.[1], ts: TS_RE.exec(tag)?.[1] }
}

/// 这次注入的身份记号：text = 在 transcript / 输入框里要找的原文，id = 裸值（transcript 原始行里先按它粗筛，JSON 转义不影响）
export interface SendMarker { text: string; id: string }

/// 审查 R1-4：身份只认唯一 ID，不用正文指纹。app 消息用 message_id；agora 用 claim_token（每次认领唯一）；
/// 其余 channel 标签（warroom / 保暖 / 提醒…）没有每次唯一的业务 ID → hub 生成注入 ID，写进开头标签的属性末尾（不动 source 等前面的属性，下游正则照认）。
/// 既不是 channel 标签也没有 claim_token 的裸文本（生产路径上没有，只有测试）：不改字节，记号永远认不出 = 只能「确定没执行才重发」，其余一律不确定
export function withMarker(text: string, newId: () => string = () => `inj-${crypto.randomUUID().slice(0, 13)}`): { text: string; marker: SendMarker } {
  const mid = MID_RE.exec(text)?.[1]
  if (mid) return { text, marker: { text: `message_id="${mid}"`, id: mid } }
  const claim = CLAIM_RE.exec(text)?.[1]
  if (claim) return { text, marker: { text: `"claim_token":"${claim}"`, id: claim } }
  const id = newId()
  const attr = `inject_id="${id}"`
  const head = OPEN_TAG_RE.exec(text)?.[0]
  return { text: head ? `${head.slice(0, -1)} ${attr}>${text.slice(head.length)}` : text, marker: { text: attr, id } }
}

const stripWs = (s: string) => s.replace(/[\s\u2500-\u257f]+/g, "")

export function hasMarker(text: string, marker: SendMarker): boolean {
  return stripWs(text).includes(stripWs(marker.text))
}

/// 粘贴占位：claude `[Pasted text #N …]`，codex `[Pasted Content N chars]`。只能当线索（审查 R1-5），不能确认是哪一条
export const PASTE_PLACEHOLDER_RE = /\[Pasted (?:text #\d+|Content \d+)/

function textOf(c: unknown): string {
  if (typeof c === "string") return c
  if (Array.isArray(c)) return c.map((b) => (typeof b?.text === "string" ? b.text : "")).join("")
  return ""
}

/// transcript 一行是不是用户输入、正文是什么。claude：`{type:"user", message:{content}}`（跳过 sidechain）；
/// codex rollout：`response_item` 的 user message 或 `event_msg` 的 user_message。不是 → undefined
export function userTextOfLine(line: string): string | undefined {
  let o: any
  try { o = JSON.parse(line) } catch { return undefined }
  if (o?.type === "user" && !o.isSidechain) return textOf(o.message?.content)
  if (o?.type === "response_item" && o.payload?.type === "message" && o.payload.role === "user") return textOf(o.payload.content)
  if (o?.type === "event_msg" && o.payload?.type === "user_message") return textOf(o.payload.message)
  return undefined
}

// ── transcript 游标（审查 R1-6）：发送前记下文件长度，核对时只从这里往后读。读不全 = unknown，绝不当「没提交」──

export interface TranscriptCursor { path: string; offset: number }
export type TranscriptSeen = "seen" | "not-seen" | "unknown"

/// 发送前记位置：stat 最多等 timeoutMs（盘卡住不拖正常发送）；文件还没有 = 从 0 开始；等不到 / 读不了 = undefined（之后核对一律 unknown）
export async function transcriptCursor(path: string, timeoutMs = 200): Promise<TranscriptCursor | undefined> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const size = stat(path).then((s) => s.size, (e) => (e?.code === "ENOENT" ? 0 : undefined))
  const r = await Promise.race([size, new Promise<undefined>((res) => { timer = setTimeout(() => res(undefined), timeoutMs) })])
  clearTimeout(timer)
  return r === undefined ? undefined : { path, offset: r }
}

export const TRANSCRIPT_SCAN_MAX_BYTES = 64 << 20

/// 从游标往后增量扫：每次 poll 只读新增部分。超过 maxBytes、文件变短（被换掉）、读出错 → unknown
export class TranscriptScanner {
  private pos: number
  private carry = ""
  private found = false
  private broken = false
  constructor(private readonly cursor: TranscriptCursor | undefined, private readonly marker: SendMarker, private readonly maxBytes = TRANSCRIPT_SCAN_MAX_BYTES) {
    this.pos = cursor?.offset ?? 0
  }

  async poll(): Promise<TranscriptSeen> {
    if (this.found) return "seen"
    if (!this.cursor || this.broken) return "unknown"
    let fh
    try { fh = await open(this.cursor.path, "r") } catch (e: any) {
      if (e?.code === "ENOENT" && this.cursor.offset === 0 && this.pos === 0) return "not-seen"   // 发送前就没有，现在还没有：什么都没写
      this.broken = true
      return "unknown"
    }
    try {
      const size = (await fh.stat()).size
      if (size < this.pos || size - this.cursor.offset > this.maxBytes) { this.broken = true; return "unknown" }
      const dec = new TextDecoder()
      const buf = Buffer.alloc(1 << 20)
      while (this.pos < size) {
        const { bytesRead } = await fh.read(buf, 0, Math.min(buf.length, size - this.pos), this.pos)
        if (bytesRead <= 0) break
        this.pos += bytesRead
        const lines = (this.carry + dec.decode(buf.subarray(0, bytesRead), { stream: true })).split("\n")
        this.carry = lines.pop() ?? ""
        for (const l of lines) {
          if (!l.includes(this.marker.id)) continue
          const t = userTextOfLine(l)
          if (t !== undefined && hasMarker(t, this.marker)) { this.found = true; return "seen" }
        }
      }
      return "not-seen"
    } catch { this.broken = true; return "unknown" } finally { await fh.close().catch(() => {}) }
  }
}

// ── 当前编辑区（审查 R1-5）──

export type EditArea =
  | { kind: "found"; text: string }
  | { kind: "unlocated" }                 // 屏读到了，认不出输入框
  | { kind: "unreadable"; detail: string } // 读屏暂时失败（卡住 / 超时）
  | { kind: "gone"; detail: string }       // 会话已经不在了

const RULE_RE = /^\s*[╭╰]?[─━]{8,}[╮╯]?\s*$/
const CLAUDE_PROMPT_RE = /^\s*[❯>!](?:\s|$)/
const CODEX_PROMPT_RE = /^\s*›(?:\s|$)/

/// 认出当前输入框里的文字（只看可见屏）。
/// claude（2.1.x，二进制里 PromptInput 是 borderStyle round + 去掉左右边：上下两条整行 ─，中间第一行以 ❯ / > / ! 开头）：
/// 取屏上最后两条整行横线，中间那段第一行是提示符才算；codex：最后一个以 › 开头的行到下一个空行（未查证，现场再核）。认不出 = undefined
export function locateEditArea(pane: string, engine: string): string | undefined {
  const lines = pane.replace(/\n+$/, "").split("\n")
  if (engine === "codex") {
    for (let i = lines.length - 1; i >= Math.max(0, lines.length - 20); i--) {
      if (!CODEX_PROMPT_RE.test(lines[i])) continue
      const body: string[] = []
      for (let j = i; j < lines.length && lines[j].trim() !== ""; j++) body.push(j === i ? lines[j].replace(CODEX_PROMPT_RE, "") : lines[j])
      return body.map((l) => l.trim()).join("\n")
    }
    return undefined
  }
  let bottom = -1
  for (let i = lines.length - 1; i >= 0; i--) if (RULE_RE.test(lines[i])) { bottom = i; break }
  if (bottom < 1) return undefined
  let top = -1
  for (let i = bottom - 1; i >= 0; i--) if (RULE_RE.test(lines[i])) { top = i; break }
  if (top < 0 || top + 1 >= bottom || !CLAUDE_PROMPT_RE.test(lines[top + 1])) return undefined
  return lines.slice(top + 1, bottom).map((l, k) => (k === 0 ? l.replace(CLAUDE_PROMPT_RE, "") : l).trim()).join("\n")
}

/// codex rollout 在 ~/.codex/sessions/YYYY/MM/DD/rollout-<时间>-<uuid>.jsonl，日期是会话创建那天（resume 的老会话可能很早）。从新往旧找；找不到 undefined
export async function findCodexRollout(root: string, uuid: string): Promise<string | undefined> {
  const desc = async (dir: string) => { try { return (await readdir(dir)).sort().reverse() } catch { return [] } }
  for (const y of await desc(root)) {
    for (const m of await desc(join(root, y))) {
      for (const d of await desc(join(root, y, m))) {
        const f = (await desc(join(root, y, m, d))).find((n) => n.startsWith("rollout-") && n.endsWith(`-${uuid}.jsonl`))
        if (f) return join(root, y, m, d, f)
      }
    }
  }
  return undefined
}

// ── 状态账（审查 R1-7）：进行中的操作和可淘汰的历史分开放 ──
// active：核对中 / 接受了的重发，不淘汰；满了在接纳 retry 前就拒（限流）。history：终态，1 小时过期、最多 1000 条

export interface ActiveOp {
  messageId: string
  chatId: string
  session: string
  /// app 重发：这次发送就是她要的那次，发之前先看现场
  retry: boolean
  /// 已经被某次 sendTracked 接手（防同一个重发被并发处理两次）
  started: boolean
  /// 重发途中会话没了、已经重新排过一次队
  requeued: boolean
  /// 原来那次发送前记下的 transcript 位置（重发前查「其实进过」用）
  cursor?: TranscriptCursor
  /// 这是哪一次发送（channel 标签的 ts）。同一个 message_id 有更新的发送开始后，这一次的结果一律不再发给 app
  attempt?: string
  since: number
}

export interface SendRecord {
  status: "delivered" | "failed"
  chatId: string
  session: string
  reason?: string
  retryable: boolean
  cursor?: TranscriptCursor
  at: number
}

export interface Outcome { status: "delivered" | "failed"; reason: string; retryable: boolean }

export interface SnapshotItem { chat_id: string; message_id: string; session_name: string; status: SendStatus; retryable: boolean; reason?: string }

export type RetryAdmission = { accepted: true; op: ActiveOp } | { accepted: false; frame: Omit<SendStatusFrame, "type" | "chat_id" | "message_id" | "session_name"> }

export class SendStatusBook {
  readonly active = new Map<string, ActiveOp>()
  private readonly history = new Map<string, SendRecord>()
  /// message_id → 最新一次发送的 ts（hub 收到 send 帧时记）
  private readonly latest = new Map<string, string>()
  private readonly watchers = new Set<(f: SendStatusFrame) => void>()

  constructor(private readonly ttlMs = 3_600_000, private readonly maxHistory = 1_000, readonly maxActive = 200, private readonly now: () => number = Date.now) {}

  watch(cb: (f: SendStatusFrame) => void): () => void {
    this.watchers.add(cb)
    return () => { this.watchers.delete(cb) }
  }

  private emit(f: SendStatusFrame): void {
    for (const w of this.watchers) { try { w(f) } catch {} }
  }

  record(messageId: string): SendRecord | undefined {
    this.prune()
    return this.history.get(messageId)
  }

  /// hub 收到一次 send 帧（app 那边这次发送开始了）。不是重发 = 新的一次（重新生成）：旧的那次还在核对的从账上摘掉、旧终态清掉，
  /// 它之后的结果一律不发（app 分不清是哪一次的）
  attemptStarted(messageId: string, attempt: string, retry: boolean): void {
    if (!retry) {
      this.active.delete(messageId)
      this.history.delete(messageId)
    } else {
      const op = this.active.get(messageId)
      if (op?.retry && op.attempt === undefined) op.attempt = attempt
    }
    this.latest.delete(messageId)
    this.latest.set(messageId, attempt)
    for (const id of this.latest.keys()) {
      if (this.latest.size <= this.maxHistory * 2) break
      if (!this.active.has(id)) this.latest.delete(id)
    }
  }

  /// 这一次还是这个 message_id 的最新一次吗（没经 WS 登记过的一律算是）
  isCurrent(messageId: string, attempt: string | undefined): boolean {
    const l = this.latest.get(messageId)
    return l === undefined || attempt === undefined || l === attempt
  }

  /// 普通发送进入核对：登记进行中、广播 uncertain。已经有更新的一次开始了 → undefined（不进账、不广播）
  begin(messageId: string, chatId: string, session: string, cursor: TranscriptCursor | undefined, attempt: string | undefined): ActiveOp | undefined {
    if (!this.isCurrent(messageId, attempt)) return undefined
    const op: ActiveOp = { messageId, chatId, session, retry: false, started: true, requeued: false, cursor, attempt, since: this.now() }
    this.active.set(messageId, op)
    this.emit(frameOf(op, "uncertain", false))
    return op
  }

  /// 终态：只有还登记着的这个 op 能写（看门狗 / 正常结束谁先谁算，后到的、被新一次顶掉的都是空操作）；广播
  finish(op: ActiveOp, o: Outcome, cursor?: TranscriptCursor): boolean {
    if (this.active.get(op.messageId) !== op || !this.isCurrent(op.messageId, op.attempt)) return false
    this.active.delete(op.messageId)
    this.history.delete(op.messageId)
    this.history.set(op.messageId, { status: o.status, chatId: op.chatId, session: op.session, reason: o.reason, retryable: o.retryable, cursor: cursor ?? op.cursor, at: this.now() })
    this.prune()
    this.emit({ type: "send_status", chat_id: op.chatId, message_id: op.messageId, session_name: op.session, status: o.status, retryable: o.retryable, reason: o.reason })
    return true
  }

  /// 已是终态的记录改原因再广播一次（会话放行超时补一句）
  amend(messageId: string, reason: string): void {
    const r = this.history.get(messageId)
    if (!r) return
    r.reason = reason
    this.emit({ type: "send_status", chat_id: r.chatId, message_id: messageId, session_name: r.session, status: r.status, retryable: r.retryable, reason })
  }

  /// app 的 retry：只接受记为 failed 且 retryable 的（转进行中，不广播）；其余不接受，回当前状态
  acceptRetry(messageId: string, chatId: string, session: string, crossTransport: boolean): RetryAdmission {
    if (this.active.has(messageId)) return { accepted: false, frame: { status: "uncertain", retryable: false, reason: "这条还在核对 / 重发中" } }
    const r = this.record(messageId)
    if (r?.status === "delivered") return { accepted: false, frame: { status: "delivered", retryable: false, reason: r.reason } }
    if (!r) return { accepted: false, frame: { status: "failed", retryable: false, reason: "电脑那边没有这条的记录（可能已经送达，也可能 hub 重启过），看一眼再决定要不要当新消息发" } }
    if (!r.retryable) return { accepted: false, frame: { status: "failed", retryable: false, reason: r.reason } }
    if (crossTransport) return { accepted: false, frame: { status: "failed", retryable: false, reason: "这个会话现在不走终端了，电脑那边没法核对这条，看一眼再决定要不要当新消息发" } }
    if (this.active.size >= this.maxActive) return { accepted: false, frame: { status: "failed", retryable: true, reason: "电脑那边正忙，稍后再点重发" } }
    const op: ActiveOp = { messageId, chatId: chatId || r.chatId, session, retry: true, started: false, requeued: false, cursor: r.cursor, since: this.now() }
    this.history.delete(messageId)
    this.active.set(messageId, op)
    return { accepted: true, op }
  }

  busy(session: string): boolean {
    for (const op of this.active.values()) if (op.session === session) return true
    return false
  }

  /// 重连补发（审查 R1-10，app 定的 send_status_snapshot）：进行中的（核对中 / 重发中）一个不漏报 uncertain——
  /// app 把快照里没有的「确认中」当成没送达；failed 带 retryable；delivered 不带
  snapshot(): SnapshotItem[] {
    this.prune()
    const out: SnapshotItem[] = []
    for (const op of this.active.values()) out.push({ chat_id: op.chatId, message_id: op.messageId, session_name: op.session, status: "uncertain", retryable: false })
    for (const [id, r] of this.history) {
      if (r.status === "failed" && !this.active.has(id)) out.push({ chat_id: r.chatId, message_id: id, session_name: r.session, status: "failed", retryable: r.retryable, ...(r.reason ? { reason: r.reason } : {}) })
    }
    return out
  }

  private prune(): void {
    const cutoff = this.now() - this.ttlMs
    for (const [id, r] of this.history) {
      if (this.history.size > this.maxHistory || r.at < cutoff) this.history.delete(id)
      else break   // 按 at 递增排着（写入总是挪到最后），前面没过期后面也不会
    }
  }
}

function frameOf(op: ActiveOp, status: SendStatus, retryable: boolean): SendStatusFrame {
  return { type: "send_status", chat_id: op.chatId, message_id: op.messageId, session_name: op.session, status, retryable }
}
