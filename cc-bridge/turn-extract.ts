// 从 CC 转录尾部取「最后一轮 memorypalace 对话」：chat_id / message_id / 正文 / thinking / 是否用了 reply 工具。
// 规则与 thinking-hook.py 一致：只有「最后一条真人输入就是这条 channel」才算本轮（保暖 ping 等排在后面就不是）；
// 用了 reply 工具的轮正文不投（混合期防双发）。hub 的轮末兜底用它核对 hook 有没有漏投（09-19 hook 读早了 0.2s）。
import { timedSyncFs } from "./block-ledger"
const { openSync, readSync, closeSync, fstatSync } = timedSyncFs("turn-extract ")
import { open } from "node:fs/promises"

export interface ChannelTurn {
  chatId: string
  messageId?: string
  text: string
  thinking: string
  turnUuid?: string
  usedReply: boolean
  isLatest: boolean
  /// 本轮每段正文（转录里一行一段，按序）。投递按段去重：见 undeliveredRows
  rows: TextRow[]
}

export interface TextRow { uuid: string; text: string }

/// 本轮还没投过的正文段。投递永远是按序的前缀（hook / 轮末兜底 / 重复 Stop 读到的都是同一轮的前若干段），
/// 所以「最后一个投过的段」之前的全算投过，只投它后面的。
/// 10-11：以前整轮拼成一条、按最后一段的 uuid 去重——读早了只拿到前两段（吞了最后一段），
/// 后来补读到全轮又换了 uuid，前两段再发一遍（重复）。
export function undeliveredRows(rows: TextRow[], delivered: (uuid: string) => boolean): TextRow[] {
  let last = -1
  rows.forEach((r, i) => { if (delivered(r.uuid)) last = i })
  return rows.slice(last + 1)
}

/// hook 投来的 rows 字段：数组且每项 uuid / text 都是非空字符串才认，否则 undefined（走老的整轮 reply_text）
export function parseRows(raw: unknown): TextRow[] | undefined {
  if (!Array.isArray(raw) || raw.length === 0) return undefined
  const rows: TextRow[] = []
  for (const r of raw) {
    if (typeof r?.uuid !== "string" || !r.uuid || typeof r?.text !== "string" || !r.text.trim()) return undefined
    rows.push({ uuid: r.uuid, text: r.text.trim() })
  }
  return rows
}

const CHANNEL_RE = /<channel source="memorypalace"[^>]*?\schat_id="([^"]+)"/
const MID_RE = /<channel source="memorypalace"[^>]*?\smessage_id="([^"]+)"/

function textOf(c: any): string {
  if (typeof c === "string") return c
  if (Array.isArray(c)) return c.filter((b) => b?.type === "text").map((b) => b.text ?? "").join("")
  return ""
}

/// 本单测 / hook 规则里的「真人输入」：user 行、非 sidechain / isMeta、不是纯 tool_result
function isHumanRow(o: any): boolean {
  if (o.type !== "user" || o.isSidechain || o.isMeta) return false
  const c = o.message?.content
  return !(Array.isArray(c) && !c.some((b: any) => b?.type === "text"))
}

export function extractLastChannelTurn(lines: string[]): ChannelTurn | null {
  return extractChannelTurnAt(lines, lines.map((_, i) => i), Infinity)
}

/// 取「pin 之前开始的那一轮」：起点 = pin 之前最后一条 channel，读到它之后下一条真人输入（下一轮）为止。
/// offsets[i] 是 lines[i] 在文件里的起始字节；pin = 排兜底时（Stop 那一刻）转录的长度。
/// 10-11 审：兜底 20s 后才读，期间她又发了一条就会挑成新的一轮，上一轮漏的段永远补不上——所以排的时候就钉住。
export function extractChannelTurnAt(lines: string[], offsets: number[], pin: number): ChannelTurn | null {
  const rows: any[] = [], rowOffsets: number[] = []
  lines.forEach((l, i) => { if (!l.trim()) return; try { rows.push(JSON.parse(l)); rowOffsets.push(offsets[i]) } catch {} })
  let chanIdx = -1, humanIdx = -1
  for (let i = 0; i < rows.length && rowOffsets[i] < pin; i++) {
    if (!isHumanRow(rows[i])) continue
    humanIdx = i
    if (CHANNEL_RE.test(textOf(rows[i].message?.content))) chanIdx = i
  }
  if (chanIdx < 0) return null
  let end = rows.length
  for (let i = chanIdx + 1; i < rows.length; i++) if (rowOffsets[i] >= pin && isHumanRow(rows[i])) { end = i; break }
  const head = textOf(rows[chanIdx].message.content)
  const turn: ChannelTurn = {
    chatId: CHANNEL_RE.exec(head)![1], messageId: MID_RE.exec(head)?.[1],
    text: "", thinking: "", usedReply: false, isLatest: chanIdx === humanIdx, rows: [],
  }
  const texts: string[] = [], thinks: string[] = []
  for (const o of rows.slice(chanIdx + 1, end)) {
    if (o.type !== "assistant" || o.isSidechain) continue
    for (const b of o.message?.content ?? []) {
      if (b?.type === "tool_use" && b.name === "mcp__cc-bridge__reply") turn.usedReply = true
      if (b?.type === "text" && (b.text ?? "").trim()) {
        texts.push(b.text.trim()); turn.turnUuid = o.uuid
        if (typeof o.uuid === "string" && o.uuid) turn.rows.push({ uuid: o.uuid, text: b.text.trim() })
      }
      if (b?.type === "thinking" && (b.thinking ?? "").trim()) thinks.push(b.thinking.trim())
    }
  }
  turn.text = texts.join("\n\n")
  turn.thinking = thinks.join("\n\n")
  return turn
}

/// 轮末兜底用：先读尾巴 4MB，找不到本轮起点（带图的轮一轮就能有好几 MB）就放大再读，最多 64MB。
/// 10-11：一轮 7.7MB（三张截图），4MB 尾巴里没有 channel 行 → 返回 null → 兜底静默放弃，最后一段正文永远没投。
/// pin：钉住的那一轮（见 extractChannelTurnAt）；不给 = 最后一轮。
/// 放大读（第二档起）全 hub 同一时刻只跑一个，其余排队：解析是同步的，64MB 一次卡主线程约 63ms（技术债，见 research）
export const TURN_TAIL_STEPS = [4 << 20, 16 << 20, 64 << 20]
export interface TailChunk { lines: string[]; offsets: number[] }
let bigReadChain: Promise<unknown> = Promise.resolve()
function serialBigRead<T>(job: () => Promise<T>): Promise<T> {
  const p = bigReadChain.then(job, job)
  bigReadChain = p.catch(() => {})
  return p
}
export async function extractLastChannelTurnFromFile(
  path: string, steps = TURN_TAIL_STEPS, pin = Infinity,
  read: (path: string, maxBytes: number) => Promise<TailChunk> = readTailWithOffsets,
): Promise<ChannelTurn | null> {
  for (let i = 0; i < steps.length; i++) {
    const once = async () => { const c = await read(path, steps[i]); return extractChannelTurnAt(c.lines, c.offsets, pin) }
    const t = i === 0 ? await once() : await serialBigRead(once)
    if (t) return t
  }
  return null
}

/// readTailAsync + 每行在文件里的起始字节（钉轮用）
export async function readTailWithOffsets(path: string, maxBytes: number): Promise<TailChunk> {
  const fh = await open(path, "r")
  try {
    const size = (await fh.stat()).size
    const start = Math.max(0, size - maxBytes)
    const buf = Buffer.alloc(size - start)
    await fh.read(buf, 0, buf.length, start)
    const lines: string[] = [], offsets: number[] = []
    let pos = 0
    if (start > 0) { const nl = buf.indexOf(10); pos = nl < 0 ? buf.length : nl + 1 }   // 丢掉第一段半行
    while (pos < buf.length) {
      let nl = buf.indexOf(10, pos)
      if (nl < 0) nl = buf.length
      lines.push(buf.toString("utf8", pos, nl)); offsets.push(start + pos)
      pos = nl + 1
    }
    return { lines, offsets }
  } finally { await fh.close() }
}

/// 本次能完整发出去的段：拼起来不超 max（10-11 审：以前整轮拼完再截，截掉的尾段也被记成投过，永远补不上）。
/// 剩下的段不记投过，留给下一次补投（轮末兜底）。
/// 例外：第一段自己就超 max → 照样只发它（截断后由调用方标投过）；不然这一段永远发不出去，后面的段也被它堵死。
export function fitRows(rows: TextRow[], max: number): TextRow[] {
  let used = 0
  const out: TextRow[] = []
  for (const r of rows) {
    const add = r.text.length + (out.length ? 2 : 0)
    if (out.length && used + add > max) break
    out.push(r); used += add
    if (used > max) break
  }
  return out
}

/** 读文件末尾 maxBytes，按行切（丢掉第一段半行） */
export function readTail(path: string, maxBytes = 4 << 20): string[] {
  const fd = openSync(path, "r")
  try {
    const size = fstatSync(fd).size
    const start = Math.max(0, size - maxBytes)
    const buf = Buffer.alloc(size - start)
    readSync(fd, buf, 0, buf.length, start)
    return tailLines(buf, start)
  } finally { closeSync(fd) }
}

/** readTail 的异步版（K3：定时器路径不在主线程同步读盘） */
export async function readTailAsync(path: string, maxBytes = 4 << 20): Promise<string[]> {
  const fh = await open(path, "r")
  try {
    const size = (await fh.stat()).size
    const start = Math.max(0, size - maxBytes)
    const buf = Buffer.alloc(size - start)
    await fh.read(buf, 0, buf.length, start)
    return tailLines(buf, start)
  } finally { await fh.close() }
}

function tailLines(buf: Buffer, start: number): string[] {
  const lines = buf.toString("utf8").split("\n")
  if (start > 0) lines.shift()
  return lines
}
