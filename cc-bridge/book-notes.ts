// CR-4 P1 下行：agent 读书产物（批注+消息）投递。独立模块避免 hub ↔ agent-runner 循环 import。
// 三层可靠性：先写 pending 文件 → WS 广播（hub 注册的 broadcaster）→ app 处理成功回 ack 才删；
// app 重连时 hub 补投全部 pending；app 端 uuid 去重兜底（重复投递无害）。
import { timedSyncFs } from "./block-ledger"
const { writeFileSync, readFileSync, unlinkSync, mkdirSync, existsSync, readdirSync } = timedSyncFs("book-notes ")
import { join } from "node:path"
import { agentDir } from "./agent-runner.ts"

/** hub 启动时注册（frame → 广播给全部 mp clients）；未注册（测试/hub 未起）只写 pending。 */
let broadcaster: ((frame: string) => void) | null = null
export function setBookNoteBroadcaster(fn: ((frame: string) => void) | null): void {
  broadcaster = fn
}

export function deliverBookNote(payload: Record<string, unknown>, dir: string = agentDir()): boolean {
  const uuid = typeof payload.uuid === "string" ? payload.uuid : ""
  if (!uuid || !/^[\w-]+$/.test(uuid)) return false
  try {
    const pendingDir = join(dir, "pending-notes")
    mkdirSync(pendingDir, { recursive: true })
    writeFileSync(join(pendingDir, `${uuid}.json`), JSON.stringify(payload))
  } catch (e) {
    console.warn(`[hub] book_note pending 写入失败: ${e}`)
    return false
  }
  broadcaster?.(JSON.stringify({ type: "agent_book_note", ...payload }))
  return true
}

export function pendingBookNotes(dir: string = agentDir()): Record<string, unknown>[] {
  const pendingDir = join(dir, "pending-notes")
  if (!existsSync(pendingDir)) return []
  const out: Record<string, unknown>[] = []
  for (const f of readdirSync(pendingDir)) {
    if (!f.endsWith(".json")) continue
    try {
      out.push(JSON.parse(readFileSync(join(pendingDir, f), "utf8")))
    } catch {
      // 坏文件隔离，别卡住补投
      try { unlinkSync(join(pendingDir, f)) } catch {}
    }
  }
  return out
}

export function ackBookNote(uuid: string, dir: string = agentDir()): void {
  if (!/^[\w-]+$/.test(uuid)) return
  try { unlinkSync(join(dir, "pending-notes", `${uuid}.json`)) } catch {}
}
