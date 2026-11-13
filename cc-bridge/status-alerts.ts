// 小芽提醒投递（plan-status-panel §2.3 / §7.5）：照 book-notes.ts——先写 pending 文件 → WS 广播 → App 回 ack 才删；
// App 重连时 hub 补投全部 pending；App 端按 alert id 去重。
import { timedSyncFs } from "./block-ledger"
const { readFileSync, unlinkSync, existsSync, readdirSync } = timedSyncFs("status-alerts ")
import { join } from "node:path"
import { agentDir } from "./agent-runner.ts"
import { saveJsonPrivate } from "./hub-config.ts"
import type { StatusAlert } from "./status-reports.ts"

const PENDING = "pending-status-alerts"
const ID_RE = /^[\w-]+$/

let broadcaster: ((frame: string) => void) | null = null
export function setStatusAlertBroadcaster(fn: ((frame: string) => void) | null): void {
  broadcaster = fn
}

export function statusAlertFrame(alert: StatusAlert): string {
  return JSON.stringify({ type: "status_alert", alert })
}

export function isStatusAlert(v: unknown): v is StatusAlert {
  if (!v || typeof v !== "object") return false
  const a = v as Record<string, unknown>
  return typeof a.id === "string" && ID_RE.test(a.id) && typeof a.source === "string" && typeof a.title === "string"
    && (a.kind === "bad" || a.kind === "recovered") && typeof a.text === "string"
    && Array.isArray(a.names) && a.names.every((n) => typeof n === "string") && typeof a.createdAt === "string"
}

/** 原子写 pending → 删同源旧 pending（同源只留最新）→ 广播。写不进去返回 false，不广播 */
export function deliverStatusAlert(alert: StatusAlert, dir: string = agentDir()): boolean {
  if (!ID_RE.test(alert.id)) return false
  try {
    saveJsonPrivate(join(dir, PENDING, `${alert.id}.json`), alert)
  } catch (e) {
    console.warn(`[hub] status_alert pending 写入失败: ${e}`)
    return false
  }
  for (const old of pendingStatusAlerts(dir)) {
    if (old.source === alert.source && old.id !== alert.id) ackStatusAlert(old.id, dir)
  }
  broadcaster?.(statusAlertFrame(alert))
  return true
}

/** 永不抛：读不了的目录当空；坏文件（坏 JSON / 结构不对 / 文件名和 id 对不上）直接删 */
export function pendingStatusAlerts(dir: string = agentDir()): StatusAlert[] {
  const pendingDir = join(dir, PENDING)
  let files: string[]
  try {
    if (!existsSync(pendingDir)) return []
    files = readdirSync(pendingDir)
  } catch {
    return []
  }
  const out: StatusAlert[] = []
  for (const f of files) {
    if (!f.endsWith(".json")) continue
    let v: unknown
    try { v = JSON.parse(readFileSync(join(pendingDir, f), "utf8")) } catch { v = undefined }
    if (isStatusAlert(v) && `${v.id}.json` === f) out.push(v)
    else { try { unlinkSync(join(pendingDir, f)) } catch {} }
  }
  return out.sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0))
}

export function ackStatusAlert(id: string, dir: string = agentDir()): void {
  if (!ID_RE.test(id)) return
  try { unlinkSync(join(dir, PENDING, `${id}.json`)) } catch {}
}
