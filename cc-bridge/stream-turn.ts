// stream 会话逐字流式：把 claude `--include-partial-messages` 的 stream-json 事件折成
// 「建节点 / 改正文 / 改思考 / 块完成 / 轮结束」动作。纯状态机，节流和广播在 hub 里做。
// 事实（09-18 探针 docs/plan-strip-thinking.md 十一-11.1）：thinking 块在 text 块之前；
// block 完成时的 `assistant` 事件 uuid == 转录行 uuid（Stop hook 的 turn_uuid 同源）。
// 本轮一旦出现 reply 工具的 tool_use（小克要发文件/引用），停止流式：已建的节点留着，
// 后面的正文不再投（同 thinking-hook.py 的 used_reply 规则）。

export type TurnAction =
  | { kind: "create"; pendingId: string }                 // 第一个字：按 reply 落库（content 可能还是空）
  | { kind: "text"; pendingId: string; content: string }  // 正文累计到目前
  | { kind: "thinking"; pendingId: string; content: string }
  | { kind: "text_done"; pendingId: string; content: string; uuid: string }   // text 块完成，uuid = 转录行
  | { kind: "thinking_done"; pendingId: string; content: string }
  | { kind: "split"; pendingId: string; text: string; thinking: string }   // AskUserQuestion 前封稿：问答泡会插在下面，答完的字另起节点
  | { kind: "end"; pendingId?: string; textUuids: string[]; text: string; thinking: string }   // result：本轮结束，带终稿

interface TurnState {
  pendingId?: string
  text: string
  thinking: string
  usedReply: boolean
  textUuids: string[]
  blockTypes: Map<number, string>
}

export class StreamTurnTracker {
  private turns = new Map<string, TurnState>()
  constructor(private newId: () => string = () => crypto.randomUUID()) {}

  private state(name: string): TurnState {
    let s = this.turns.get(name)
    if (!s) { s = { text: "", thinking: "", usedReply: false, textUuids: [], blockTypes: new Map() }; this.turns.set(name, s) }
    return s
  }

  has(name: string): boolean { return this.turns.has(name) }
  pendingIdOf(name: string): string | undefined { return this.turns.get(name)?.pendingId }

  /** 喂一条 stream-json 消息，返回该产生的动作（可能为空） */
  handle(name: string, m: any): TurnAction[] {
    const out: TurnAction[] = []
    if (m?.type === "result") {
      const s = this.turns.get(name)
      this.turns.delete(name)
      out.push({ kind: "end", pendingId: s?.pendingId, textUuids: s?.textUuids ?? [], text: s?.text ?? "", thinking: s?.thinking ?? "" })
      return out
    }
    if (m?.type === "assistant") {
      const s = this.turns.get(name)
      if (!s || !s.pendingId || s.usedReply) return out
      const uuid = typeof m.uuid === "string" ? m.uuid : ""
      for (const b of (m.message?.content ?? [])) {
        if (b?.type === "text" && uuid) {
          const t = typeof b.text === "string" ? b.text : s.text
          if (t.trim()) { s.text = t; s.textUuids.push(uuid); out.push({ kind: "text_done", pendingId: s.pendingId, content: s.text, uuid }) }
        } else if (b?.type === "thinking") {
          if (s.thinking.trim()) out.push({ kind: "thinking_done", pendingId: s.pendingId, content: s.thinking })
        }
      }
      return out
    }
    if (m?.type !== "stream_event") return out
    const e = m.event
    if (!e) return out
    const s = this.state(name)
    if (e.type === "content_block_start") {
      const cb = e.content_block ?? {}
      s.blockTypes.set(e.index, cb.type)
      if (cb.type === "tool_use" && cb.name === "mcp__cc-bridge__reply") s.usedReply = true
      // 提问前已有正文 → 封稿，之后的正文新开节点（只有 thinking 没正文的不拆，等答完的字填进去）
      if (cb.type === "tool_use" && cb.name === "AskUserQuestion" && s.pendingId && s.text.trim()) {
        out.push({ kind: "split", pendingId: s.pendingId, text: s.text, thinking: s.thinking })
        s.pendingId = undefined; s.text = ""; s.thinking = ""
      }
      return out
    }
    if (e.type !== "content_block_delta" || s.usedReply) return out
    const d = e.delta ?? {}
    if (d.type === "text_delta" && typeof d.text === "string") {
      if (!s.pendingId) { s.pendingId = `s_txt_${this.newId()}`; out.push({ kind: "create", pendingId: s.pendingId }) }
      s.text += d.text
      out.push({ kind: "text", pendingId: s.pendingId, content: s.text })
    } else if (d.type === "thinking_delta" && typeof d.thinking === "string") {
      if (!s.pendingId) { s.pendingId = `s_txt_${this.newId()}`; out.push({ kind: "create", pendingId: s.pendingId }) }
      s.thinking += d.thinking
      out.push({ kind: "thinking", pendingId: s.pendingId, content: s.thinking })
    }
    return out
  }
}

// ── 传输 reconcile（按 session 策略）──
// live：活着的会话及其当前传输 + 忙不忙；wantOf：该 session 应该是什么传输。
// 传输不符的：空闲立刻收（retireNow），忙的等本轮结束（retireLater）；之前挂着等收但现在又符合了的取消。
export interface LiveSession { name: string; transport: "tmux" | "stream"; busy: boolean }
export function planTransportReconcile(
  live: LiveSession[],
  wantOf: (name: string) => "tmux" | "stream",
  pending: Iterable<string>,
): { retireNow: string[]; retireLater: string[]; cancel: string[] } {
  const already = new Set(pending)
  const retireNow: string[] = [], retireLater: string[] = [], cancel: string[] = []
  const mismatched = new Set<string>()
  for (const s of live) {
    if (wantOf(s.name) === s.transport) continue
    mismatched.add(s.name)
    if (!s.busy) retireNow.push(s.name)
    else if (!already.has(s.name)) retireLater.push(s.name)
  }
  for (const n of already) if (!mismatched.has(n)) cancel.push(n)
  return { retireNow, retireLater, cancel }
}
