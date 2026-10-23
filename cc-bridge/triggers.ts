// AUTONOMY Phase 1：TriggerSpec + 到点判定（plan-autonomy-network P1.2）。
// trigger 不是独立 loop——scheduler 到点后把任务塞进 pi agent 的 followUp 队列消化。
import { Cron } from "croner"
import { timedSyncFs } from "./block-ledger"
const { readFileSync, existsSync } = timedSyncFs("triggers ")

export interface TriggerSpec {
  id: string
  type: "cron" | "event"           // v1 只实现 cron；conversation-hook/regex 下窗口
  schedule?: string                 // cron 表达式（croner 语法）
  promptTemplate: string            // {{floor}} {{date}} 变量替换
  contextLoader: "none" | "floorMemory" | "currentBook"   // currentBook = CR-4 ReaderDaemon
  sink: "log" | "outbox" | "bookNote"                      // bookNote = 解析产出 → deliverBookNote
  enabled: boolean
  floorId?: string
  budgetUSD?: number                // 单 trigger 日预算，缺省走全局
  // CR-3 P3：spawn 型 = 跑配置里写死的固定命令（模型永远碰不到 argv），
  // 不走 LLM/预算。缺省 "llm" 向后兼容。
  action: "llm" | "spawn"
  spawnCommand?: string[]
}

/** triggers.json 加载：坏条目跳过并警告，不炸整个调度 */
export function loadTriggers(file: string): TriggerSpec[] {
  if (!existsSync(file)) return []
  let raw: unknown
  try {
    raw = JSON.parse(readFileSync(file, "utf8"))
  } catch (e) {
    console.warn(`[agent] triggers.json 解析失败: ${e}`)
    return []
  }
  if (!Array.isArray(raw)) return []
  const out: TriggerSpec[] = []
  for (const t of raw) {
    if (!t || typeof t !== "object") continue
    const s = t as Record<string, unknown>
    if (typeof s.id !== "string" || typeof s.promptTemplate !== "string") {
      console.warn(`[agent] trigger 缺 id/promptTemplate，跳过: ${JSON.stringify(t).slice(0, 80)}`)
      continue
    }
    if (s.type === "cron" && typeof s.schedule !== "string") {
      console.warn(`[agent] cron trigger ${s.id} 缺 schedule，跳过`)
      continue
    }
    out.push({
      id: s.id,
      type: (s.type as "cron" | "event") ?? "cron",
      schedule: s.schedule as string | undefined,
      promptTemplate: s.promptTemplate,
      contextLoader: (s.contextLoader as TriggerSpec["contextLoader"]) ?? "none",
      sink: (s.sink as TriggerSpec["sink"]) ?? "log",
      enabled: s.enabled !== false,
      floorId: s.floorId as string | undefined,
      budgetUSD: typeof s.budgetUSD === "number" ? s.budgetUSD : undefined,
      action: s.action === "spawn" ? "spawn" : "llm",
      spawnCommand: Array.isArray(s.spawnCommand)
        ? (s.spawnCommand as unknown[]).filter((x): x is string => typeof x === "string")
        : undefined,
    })
  }
  return out
}

/** 到点判定：上次检查时刻 → 现在之间有没有 cron 命中。无状态纯函数，方便测试。 */
export function isDue(spec: TriggerSpec, since: Date, now: Date): boolean {
  if (!spec.enabled || spec.type !== "cron" || !spec.schedule) return false
  let cron: Cron
  try {
    cron = new Cron(spec.schedule)
  } catch {
    console.warn(`[agent] trigger ${spec.id} schedule 非法: ${spec.schedule}`)
    return false
  }
  const next = cron.nextRun(since)
  return next !== null && next <= now
}

/** prompt 模板变量替换 */
export function renderPrompt(spec: TriggerSpec, now: Date): string {
  return spec.promptTemplate
    .replaceAll("{{floor}}", spec.floorId ?? "")
    .replaceAll("{{date}}", now.toISOString().slice(0, 10))
}
