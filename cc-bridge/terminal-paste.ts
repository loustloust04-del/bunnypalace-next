import { randomUUID } from "node:crypto"
import { tmuxLoadBuffer, tmuxRun } from "./tmux-control"

/// 粘贴上限。走 load-buffer 的 stdin（>64KB 不走控制连接），没有 argv 长度问题；这只是防误贴整本书。
export const MAX_PASTE_BYTES = 1 << 20

/// tmux 卡住时最多等这么久（K1 第 4 步起是异步的，不再卡事件循环）
const TMUX_TIMEOUT_MS = 5000

export type PasteResult = { ok: true } | { ok: false; reason: string }

/// 把一段文本当「粘贴」送进 tmux pane（T27）。
///
/// 为什么不在客户端包 ESC[200~：客户端 SwiftTerm 只知道它在流里见过的 DECSET 2004，attach 时
/// 收的是 capture-pane 快照（不带模式），Claude Code 启动时开一次就不再发 → 客户端永远以为没开。
/// pane 自己记着应用开没开，`paste-buffer -p` 按它决定包不包，这是唯一可靠的判据。
/// LF 按 tmux 默认换成 CR（跟 Terminal.app / iTerm2 粘贴一致）。
///
/// K1 第 4 步：走 tmuxLoadBuffer（控制连接 set-buffer / fork load-buffer）+ tmuxRun；socket 跟 MP_CC_TMUX_SOCKET。
/// 调用方负责按会话串行（hub 包在 chainTmuxWrite 里），这里的写不带 session，带了会排在自己后面死锁
export async function pasteToTmux(sessionName: string, text: string): Promise<PasteResult> {
  if (!text) return { ok: false, reason: "空内容" }
  const size = Buffer.byteLength(text, "utf8")
  if (size > MAX_PASTE_BYTES) return { ok: false, reason: `内容太长（${size} 字节，上限 ${MAX_PASTE_BYTES}）` }
  const buffer = `mp-paste-${randomUUID()}`
  try {
    await tmuxLoadBuffer(buffer, text, TMUX_TIMEOUT_MS)
    await tmuxRun(["paste-buffer", "-p", "-d", "-b", buffer, "-t", sessionName], { timeoutMs: TMUX_TIMEOUT_MS, write: true })
    return { ok: true }
  } catch (err: any) {
    try { await tmuxRun(["delete-buffer", "-b", buffer], { timeoutMs: TMUX_TIMEOUT_MS, write: true }) } catch {}
    return { ok: false, reason: `paste: ${String(err?.stderr || err?.message || err).trim()}` }
  }
}

export function buildPasteResultPayload(sessionName: string, requestId: string | undefined, result: PasteResult): string {
  return JSON.stringify({
    type: "terminal_paste_result",
    session_name: sessionName,
    request_id: requestId,
    ok: result.ok,
    reason: result.ok ? undefined : result.reason,
  })
}
