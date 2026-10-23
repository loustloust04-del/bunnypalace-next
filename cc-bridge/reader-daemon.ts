// CR-4 P2：ReaderDaemon 的纯逻辑件——gate 判定 / 阅读材料注入 / LLM 产出解析。
// 执行体复用 runTrigger 的 LLM 路径（contextLoader="currentBook" + sink="bookNote"），
// 不造新 loop。全部纯函数/文件读，方便测试。
import { timedSyncFs } from "./block-ledger"
const { readFileSync, writeFileSync, existsSync } = timedSyncFs("reader ")
import { join } from "node:path"
import { randomUUID } from "node:crypto"

function readJSON(path: string): Record<string, unknown> | null {
  if (!existsSync(path)) return null
  try {
    return JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>
  } catch {
    return null
  }
}

// MARK: - Gate（她在读让路 / 没材料不跑）

export type GateResult = { ok: true } | { ok: false; reason: string }

export function readerGate(dir: string, now: Date = new Date()): GateResult {
  const ctx = readJSON(join(dir, "reading-context.json"))
  if (!ctx || typeof ctx.text !== "string" || !ctx.text) {
    return { ok: false, reason: "skipped-no-material" }
  }
  const status = readJSON(join(dir, "reading-status.json"))
  if (status && typeof status.updatedAt === "string") {
    const age = now.getTime() - Date.parse(status.updatedAt)
    if (Number.isFinite(age) && age >= 0 && age < 2 * 60_000) {
      return { ok: false, reason: "skipped-reading" }   // 她在读，让路
    }
  }
  return { ok: true }
}

// MARK: - 阅读材料注入（contextLoader "currentBook"）

/** 章文本截断上限（字符）。gemini flash lite 200K ctx 富余，8K 字 ≈ 一次阅读量。 */
const MATERIAL_TEXT_LIMIT = 8_000

/** 上行快照里的用户称呼（通用 app：禁止硬编码人称，app 侧传 Profile.userName）。 */
export function readerUserName(dir: string): string {
  const ctx = readJSON(join(dir, "reading-context.json"))
  const name = ctx && typeof ctx.userName === "string" ? ctx.userName.trim() : ""
  return name || "用户"
}

export function loadReaderMaterial(dir: string): string | null {
  const ctx = readJSON(join(dir, "reading-context.json"))
  if (!ctx || typeof ctx.text !== "string" || !ctx.text) return null

  const user = readerUserName(dir)
  const bookName = typeof ctx.bookName === "string" ? ctx.bookName : "这本书"
  const chapter = ctx.chapter
  const title = typeof ctx.chapterTitle === "string" ? ctx.chapterTitle : ""
  const text = (ctx.text as string).slice(0, MATERIAL_TEXT_LIMIT)

  let notesBlock = ""
  if (Array.isArray(ctx.userNotes) && ctx.userNotes.length > 0) {
    const lines = (ctx.userNotes as Record<string, unknown>[])
      .slice(0, 20)
      .map((n) => {
        const anchor = typeof n.anchorText === "string" ? n.anchorText : ""
        const content = typeof n.content === "string" ? n.content : ""
        return content ? `- 「${anchor}」→ ${user}写：${content}` : `- ${user}划了「${anchor}」`
      })
    notesBlock = `\n\n【${user}在这一章的批注】\n${lines.join("\n")}`
  }

  return `【${user}正在读的书】《${bookName}》第 ${chapter} 章 · ${title}\n\n【章节内容（节选）】\n${text}${notesBlock}${readerHistoryBlock(dir)}`
}

// MARK: - 共读足迹（R3：daemon 记得自己读过什么、说过什么）

export interface ReaderHistoryEntry {
  ts: string
  bookName: string
  safeName: string
  chapter: number
  comments: string[]
  message: string
}

const HISTORY_KEEP = 20

/** bookNote 投递成功后记一笔（滚动保留 20 条）。 */
export function appendReaderHistory(entry: ReaderHistoryEntry, dir: string): void {
  const path = join(dir, "reader-history.json")
  let arr: ReaderHistoryEntry[] = []
  const prev = readJSON(path)
  if (Array.isArray(prev)) arr = prev as unknown as ReaderHistoryEntry[]
  arr.push(entry)
  if (arr.length > HISTORY_KEEP) arr = arr.slice(-HISTORY_KEEP)
  try {
    writeFileSync(path, JSON.stringify(arr))
  } catch (e) {
    console.warn(`[hub] reader-history 写入失败: ${e}`)
  }
}

/** 最近几轮共读足迹 → 材料注入段（"你上次读到…你当时说…"）。无足迹 = 空串。 */
export function readerHistoryBlock(dir: string, latest = 4): string {
  const prev = readJSON(join(dir, "reader-history.json"))
  if (!Array.isArray(prev) || prev.length === 0) return ""
  const lines = (prev as unknown as ReaderHistoryEntry[])
    .slice(-latest)
    .map((e) => {
      const date = typeof e.ts === "string" ? e.ts.slice(5, 10) : ""
      const comment = e.comments?.[0] ? `你批注过「${e.comments[0].slice(0, 60)}」` : ""
      const msg = e.message ? `你说过「${e.message.slice(0, 60)}」` : ""
      const said = [comment, msg].filter(Boolean).join("；")
      return `- ${date} 《${e.bookName}》第 ${e.chapter} 章${said ? `：${said}` : ""}`
    })
  return `\n\n【你最近的共读足迹】\n${lines.join("\n")}\n（接着这些足迹往下读——不要重复之前写过的批注。）`
}

/** reading-context 里的楼层人格包；无 → null（runner 用通用兜底）。 */
export function loadReaderPersona(dir: string): string | null {
  const ctx = readJSON(join(dir, "reading-context.json"))
  const persona = ctx && typeof ctx.persona === "string" ? ctx.persona.trim() : ""
  if (!persona) return null
  const user = readerUserName(dir)
  return `${persona}\n\n（现在${user}不在，你在独自读${user}正在读的书——这是你们的共读。直接输出要求的 JSON，不要寒暄。）`
}

// MARK: - LLM 产出解析

export interface ReaderNote {
  anchorText: string
  comment: string
  replyToAnchor?: string
}

export interface ReaderOutput {
  notes: ReaderNote[]
  message: string
}

const MAX_NOTES = 3
const ANCHOR_MIN = 6
const ANCHOR_MAX = 200
const COMMENT_MAX = 600

/** 从 LLM 文本提取 JSON（容忍 ```json 围栏/前后废话），校验形状。全废返回 null。 */
export function parseReaderOutput(text: string): ReaderOutput | null {
  const jsonStr = extractJSON(text)
  if (!jsonStr) return null
  let obj: unknown
  try {
    obj = JSON.parse(jsonStr)
  } catch {
    return null
  }
  if (!obj || typeof obj !== "object") return null
  const o = obj as Record<string, unknown>

  const notes: ReaderNote[] = []
  if (Array.isArray(o.annotations)) {
    for (const raw of o.annotations.slice(0, MAX_NOTES)) {
      if (!raw || typeof raw !== "object") continue
      const n = raw as Record<string, unknown>
      const anchor = typeof n.anchorText === "string" ? n.anchorText.trim() : ""
      const comment = typeof n.comment === "string" ? n.comment.trim() : ""
      if (anchor.length < ANCHOR_MIN || anchor.length > ANCHOR_MAX || !comment) continue
      const note: ReaderNote = { anchorText: anchor, comment: comment.slice(0, COMMENT_MAX) }
      if (typeof n.replyToAnchor === "string" && n.replyToAnchor.trim()) {
        note.replyToAnchor = n.replyToAnchor.trim()
      }
      notes.push(note)
    }
  }
  const message = typeof o.message === "string" ? o.message.trim().slice(0, 1_000) : ""
  if (notes.length === 0 && !message) return null
  return { notes, message }
}

function extractJSON(text: string): string | null {
  const fenced = /```(?:json)?\s*([\s\S]*?)```/.exec(text)
  const candidate = fenced ? fenced[1] : text
  const start = candidate.indexOf("{")
  const end = candidate.lastIndexOf("}")
  if (start < 0 || end <= start) return null
  return candidate.slice(start, end + 1)
}

// MARK: - 组下行 payload

export function buildBookNotePayload(output: ReaderOutput, dir: string): Record<string, unknown> | null {
  const ctx = readJSON(join(dir, "reading-context.json"))
  if (!ctx) return null
  return {
    uuid: randomUUID(),
    floorId: typeof ctx.floorId === "string" ? ctx.floorId : "",
    safeName: typeof ctx.safeName === "string" ? ctx.safeName : "",
    bookName: typeof ctx.bookName === "string" ? ctx.bookName : "",
    chapter: ctx.chapter,
    notes: output.notes,
    message: output.message,
    createdAt: new Date().toISOString(),
  }
}
