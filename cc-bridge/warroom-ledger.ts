// 军机处 M1 · 奏折账本
// 单写者 = hub。所有状态变更走这里并留 task_log 审计流水。
// 状态机：draft → dispatched → working → evidence_in → reviewing → approved | rejected | failed
// （rejected 可再派：rejected → dispatched，形成返工链，M2 用）
import { Database } from "bun:sqlite"
import { timeSqlite } from "./block-ledger"

export type TaskStatus =
  | "draft" | "dispatched" | "working" | "evidence_in"
  | "reviewing" | "approved" | "rejected" | "failed"

export const LEGAL_TRANSITIONS: Record<TaskStatus, TaskStatus[]> = {
  draft: ["dispatched", "failed"],
  dispatched: ["working", "evidence_in", "failed"],   // T2 快任务可能直接跳 evidence_in
  working: ["evidence_in", "failed"],
  evidence_in: ["reviewing", "approved", "rejected", "failed"],
  reviewing: ["approved", "rejected", "failed"],
  rejected: ["dispatched", "failed"],                 // 返工再派
  approved: [],
  failed: [],
}

export type TargetKind = "tmux" | "resume" | "repo"
export type Engine = "claude" | "codex"
export type Approval = "auto" | "ask_susu"

export interface NewTask {
  title: string
  body: string
  target_kind: TargetKind
  target_ref: string          // tmux session 名 / session_id / 目录（repo 通道 = 绝对路径）
  engine: Engine
  created_by: string          // susu | zhongshu
  approval?: Approval
  filescope?: string | null
  parent_task?: string | null
  depends_on?: string[]       // M4 DAG：全部 approved 才可派
  epic?: string | null        // M4：EPIC 分组标签
}

export interface TaskRow {
  task_id: string
  title: string; body: string
  target_kind: TargetKind; target_ref: string; engine: Engine
  status: TaskStatus
  approval: Approval
  filescope: string | null
  created_by: string
  parent_task: string | null
  depends_on: string | null   // JSON array 文本
  epic: string | null
  created_at: string; dispatched_at: string | null; done_at: string | null
  receipt: string | null      // JSON 文本
  evidence: string | null
  verdict: string | null
  cost_usd: number
}

// 危险模式 → 强制 ask_susu（M1 只标记不派发，命中即拦在 draft）
// 注意大小写不敏感；改军机处自己（cc-bridge）也算——军机处不能自己改门锁。
export const DANGER_PATTERNS: RegExp[] = [
  /rm\s+-rf?\s/i,
  /git\s+push\s+.*(--force|-f\b)/i,
  /force[- ]?push/i,
  /deploy|发布到生产|上生产/i,
  /cc-bridge\/(hub|warroom|mcp-server|agora)/i,
  /launchctl|launchd/i,
  /(删库|drop\s+table|truncate\s+table)/i,
  /sudo\s/i,
]

export function isDangerous(text: string): boolean {
  return DANGER_PATTERNS.some((re) => re.test(text))
}

export class IllegalTransition extends Error {
  constructor(from: TaskStatus, to: TaskStatus, taskId: string) {
    super(`illegal transition ${from} → ${to} (task ${taskId})`)
  }
}

export class TargetBusy extends Error {
  constructor(targetRef: string, existingTaskId: string) {
    super(`target ${targetRef} already has active task ${existingTaskId}`)
  }
}

// ── K2 审查 R1-1：主连接撞写锁（scan worker 正在提交一批）只同步等很短（MAIN_BUSY_TIMEOUT_MS，见 warroom-indexer），
// 等不到就抛 SQLITE_BUSY；调用方用 retryBusy 异步退避重试整个账本操作（每个操作是一个事务，失败即全回滚，重试安全）。
// 退避期间主循环照常转，不再卡在 sqlite 的忙等里

export function isSqliteBusy(e: unknown): boolean {
  const code = (e as { code?: unknown } | null)?.code
  if (typeof code === "string" && code.startsWith("SQLITE_BUSY")) return true
  return /database is locked/i.test(String((e as Error | null)?.message ?? ""))
}

/// 退避表：合计约 7s（worker 一批常态几 ms，swap 打满时最坏几秒）；用完还 BUSY 就把错误抛给调用方原来的错误路径
export const BUSY_RETRY_DELAYS_MS = [25, 50, 100, 200, 400, 800, 1600, 2000, 2000]

export async function retryBusy<T>(fn: () => T, delays: readonly number[] = BUSY_RETRY_DELAYS_MS, sleep: (ms: number) => Promise<unknown> = (ms) => Bun.sleep(ms)): Promise<T> {
  for (let i = 0; ; i++) {
    try { return fn() } catch (e) {
      if (!isSqliteBusy(e) || i >= delays.length) throw e
      await sleep(delays[i])
    }
  }
}

const ACTIVE_STATUSES =["dispatched", "working", "evidence_in", "reviewing"] as const

export class WarroomLedger {
  readonly db: Database

  constructor(dbPathOrDb: string | Database) {
    this.db = timeSqlite(typeof dbPathOrDb === "string"
      ? new Database(dbPathOrDb, { create: true, strict: true })
      : dbPathOrDb, "warroom")
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS tasks (
        task_id TEXT PRIMARY KEY,
        title TEXT NOT NULL, body TEXT NOT NULL,
        target_kind TEXT NOT NULL, target_ref TEXT NOT NULL, engine TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'draft',
        approval TEXT NOT NULL DEFAULT 'auto',
        filescope TEXT, created_by TEXT NOT NULL,
        parent_task TEXT,
        created_at TEXT NOT NULL, dispatched_at TEXT, done_at TEXT,
        receipt TEXT, evidence TEXT, verdict TEXT,
        cost_usd REAL NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
      CREATE INDEX IF NOT EXISTS idx_tasks_target ON tasks(target_ref);
    `)
    // M4 迁移：老库补 depends_on/epic 列（ALTER 幂等靠 try）
    for (const col of ["depends_on TEXT", "epic TEXT"]) {
      try { this.db.exec(`ALTER TABLE tasks ADD COLUMN ${col}`) } catch { /* 已存在 */ }
    }
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS task_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT NOT NULL, ts TEXT NOT NULL,
        actor TEXT NOT NULL, event TEXT NOT NULL, detail TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_task_log_task ON task_log(task_id);
      CREATE TABLE IF NOT EXISTS requests (
        request_id TEXT PRIMARY KEY,   -- zq-MMDD-NN，同时用作子奏折的 epic 标签
        text TEXT NOT NULL,            -- 粟粟的原话（终审对照原文，不对照转述）
        status TEXT NOT NULL DEFAULT 'open',   -- open | reviewing | closed
        created_at TEXT NOT NULL, closed_at TEXT
      );
    `)
  }

  // ── M5：需求（app 一句话派单）──

  createRequest(text: string, now = new Date()): { request_id: string; text: string } {
    return this.tx(() => this.createRequestTx(text, now))
  }

  private createRequestTx(text: string, now: Date): { request_id: string; text: string } {
    const mmdd = `${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}`
    const prefix = `zq-${mmdd}-`
    const row = this.db.query("SELECT COUNT(*) as n FROM requests WHERE request_id LIKE ?").get(`${prefix}%`) as { n: number }
    const id = `${prefix}${String(row.n + 1).padStart(2, "0")}`
    this.db.query("INSERT INTO requests(request_id, text, created_at) VALUES (?,?,?)").run(id, text, now.toISOString())
    return { request_id: id, text }
  }

  getRequest(id: string): { request_id: string; text: string; status: string } | null {
    return this.db.query("SELECT * FROM requests WHERE request_id = ?").get(id) as any
  }

  setRequestStatus(id: string, status: "open" | "reviewing" | "closed"): void {
    this.db.query("UPDATE requests SET status = ?, closed_at = CASE WHEN ?='closed' THEN ? ELSE closed_at END WHERE request_id = ?")
      .run(status, status, new Date().toISOString(), id)
  }

  /** EPIC 聚合：该 epic 下有任务、且全部到终态（approved/rejected/failed）→ 可终审。
   *  reviewing 状态的 request 不重复触发。 */
  epicsReadyForFinalReview(): Array<{ request_id: string; text: string; total: number; approved: number }> {
    const open = this.db.query("SELECT request_id, text FROM requests WHERE status = 'open'").all() as any[]
    const out: Array<{ request_id: string; text: string; total: number; approved: number }> = []
    for (const r of open) {
      const stats = this.db.query(
        `SELECT COUNT(*) as total,
                SUM(CASE WHEN status = 'approved' THEN 1 ELSE 0 END) as approved,
                SUM(CASE WHEN status IN ('approved','rejected','failed') THEN 1 ELSE 0 END) as terminal
         FROM tasks WHERE epic = ?`).get(r.request_id) as any
      if (stats && stats.total > 0 && stats.terminal === stats.total) {
        out.push({ request_id: r.request_id, text: r.text, total: stats.total, approved: stats.approved ?? 0 })
      }
    }
    return out
  }

  /// K2 审查 R1-2：每个账本操作一个 IMMEDIATE 事务——状态 / 收据 / 证据和审计日志一起提交或一起不提交。
  /// 主连接和 scan worker 抢写锁，撞锁失败时整个操作回滚，调用方（retryBusy）重试整件事不会半成功。
  /// 嵌套调用（acceptReceipt 里的 transition）bun 自动降成 SAVEPOINT
  private tx<T>(fn: () => T): T {
    return this.db.transaction(fn).immediate()
  }

  private log(taskId: string, actor: string, event: string, detail?: string): void {
    this.db.query("INSERT INTO task_log(task_id, ts, actor, event, detail) VALUES (?,?,?,?,?)")
      .run(taskId, new Date().toISOString(), actor, event, detail ?? null)
  }

  /** 生成 zz-MMDD-NN 形式的 task id */
  private nextTaskId(now = new Date()): string {
    const mmdd = `${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}`
    const prefix = `zz-${mmdd}-`
    const row = this.db.query("SELECT COUNT(*) as n FROM tasks WHERE task_id LIKE ?").get(`${prefix}%`) as { n: number }
    return `${prefix}${String(row.n + 1).padStart(2, "0")}`
  }

  getTask(taskId: string): TaskRow | null {
    return this.db.query("SELECT * FROM tasks WHERE task_id = ?").get(taskId) as TaskRow | null
  }

  activeTaskFor(targetRef: string): TaskRow | null {
    return this.db.query(
      `SELECT * FROM tasks WHERE target_ref = ? AND status IN (${ACTIVE_STATUSES.map(() => "?").join(",")}) LIMIT 1`
    ).get(targetRef, ...ACTIVE_STATUSES) as TaskRow | null
  }

  /** 开工单。危险内容强制 ask_susu；同 target 有活工单 → TargetBusy；依赖必须存在且无环。
   *  例外：带 depends_on 的单允许在目标忙时立案（它本来就要排队等 DAG 放行，
   *  放行时 dispatch 的 target/repo 锁会再把关）——不然"B 等 A"永远没法立案（实弹②教训）。 */
  createTask(t: NewTask): TaskRow {
    return this.tx(() => this.createTaskTx(t))
  }

  private createTaskTx(t: NewTask): TaskRow {
    const deps0 = (t.depends_on ?? []).filter(Boolean)
    const busy = this.activeTaskFor(t.target_ref)
    if (busy && deps0.length === 0) throw new TargetBusy(t.target_ref, busy.task_id)
    const deps = deps0
    for (const d of deps) {
      if (!this.getTask(d)) throw new Error(`depends_on 引用不存在的工单: ${d}`)
    }
    const dangerous = isDangerous(`${t.title}\n${t.body}`)
    const approval: Approval = dangerous ? "ask_susu" : (t.approval ?? "auto")
    const taskId = this.nextTaskId()
    this.db.query(`INSERT INTO tasks(task_id, title, body, target_kind, target_ref, engine,
        status, approval, filescope, created_by, parent_task, depends_on, epic, created_at)
      VALUES (?,?,?,?,?,?,'draft',?,?,?,?,?,?,?)`)
      .run(taskId, t.title, t.body, t.target_kind, t.target_ref, t.engine,
        approval, t.filescope ?? null, t.created_by, t.parent_task ?? null,
        deps.length ? JSON.stringify(deps) : null, t.epic ?? null, new Date().toISOString())
    // 环检测：新单入库后沿依赖走，能走回自己 = 有环 → 删掉拒收
    if (deps.length && this.hasDependencyCycle(taskId)) {
      this.db.query("DELETE FROM tasks WHERE task_id = ?").run(taskId)
      throw new Error(`depends_on 成环，拒收（${taskId} → ${deps.join(",")}）`)
    }
    this.log(taskId, t.created_by, "created", dangerous ? "danger-pattern → forced ask_susu" : undefined)
    return this.getTask(taskId)!
  }

  private hasDependencyCycle(startId: string): boolean {
    const visit = (id: string, seen: Set<string>): boolean => {
      if (seen.has(id)) return true
      seen.add(id)
      const task = this.getTask(id)
      if (!task?.depends_on) return false
      let deps: string[] = []
      try { deps = JSON.parse(task.depends_on) } catch { return false }
      return deps.some((d) => visit(d, new Set(seen)))
    }
    return visit(startId, new Set())
  }

  /** DAG：全部依赖 approved 才可派 */
  depsSatisfied(task: TaskRow): boolean {
    if (!task.depends_on) return true
    let deps: string[] = []
    try { deps = JSON.parse(task.depends_on) } catch { return true }
    return deps.every((d) => this.getTask(d)?.status === "approved")
  }

  /** DAG 自动放行候选：draft + auto + 有依赖 + 依赖全 approved（hub 定时器扫） */
  readyQueuedTasks(): TaskRow[] {
    return (this.db.query(
      "SELECT * FROM tasks WHERE status = 'draft' AND approval = 'auto' AND depends_on IS NOT NULL"
    ).all() as TaskRow[]).filter((t) => this.depsSatisfied(t))
  }

  /** 状态迁移（带守卫 + 审计） */
  transition(taskId: string, to: TaskStatus, actor: string, detail?: string): TaskRow {
    return this.tx(() => this.transitionTx(taskId, to, actor, detail))
  }

  private transitionTx(taskId: string, to: TaskStatus, actor: string, detail?: string): TaskRow {
    const task = this.getTask(taskId)
    if (!task) throw new Error(`task not found: ${taskId}`)
    const legal = LEGAL_TRANSITIONS[task.status as TaskStatus] ?? []
    if (!legal.includes(to)) throw new IllegalTransition(task.status as TaskStatus, to, taskId)
    const stamps: string[] = []
    const params: unknown[] = []
    if (to === "dispatched") { stamps.push("dispatched_at = ?"); params.push(new Date().toISOString()) }
    if (to === "approved" || to === "rejected" || to === "failed") { stamps.push("done_at = ?"); params.push(new Date().toISOString()) }
    this.db.query(`UPDATE tasks SET status = ?${stamps.length ? ", " + stamps.join(", ") : ""} WHERE task_id = ?`)
      .run(to, ...(params as any[]), taskId)
    this.log(taskId, actor, `→ ${to}`, detail)
    return this.getTask(taskId)!
  }

  /** 挂收据（T2 stdout JSON / T1 收据文件），顺带记账 cost。同一份收据再挂一次不重复记 cost（幂等） */
  attachReceipt(taskId: string, receipt: object, actor: string): void {
    this.tx(() => this.attachReceiptTx(taskId, receipt, actor))
  }

  private attachReceiptTx(taskId: string, receipt: object, actor: string): void {
    const json = JSON.stringify(receipt)
    const cur = this.db.query("SELECT receipt FROM tasks WHERE task_id = ?").get(taskId) as { receipt: string | null } | null
    if (cur?.receipt === json) return
    const cost = (receipt as any)?.total_cost_usd
    this.db.query("UPDATE tasks SET receipt = ?, cost_usd = cost_usd + ? WHERE task_id = ?")
      .run(json, typeof cost === "number" ? cost : 0, taskId)
    this.log(taskId, actor, "receipt", json.slice(0, 200))
  }

  /** 收下收据 + 状态迁移（evidence_in / failed）一个事务：要么都成，要么都没发生（可整个重试） */
  acceptReceipt(taskId: string, receipt: object, receiptActor: string, to: TaskStatus, actor: string, detail?: string): TaskRow {
    return this.tx(() => {
      this.attachReceiptTx(taskId, receipt, receiptActor)
      return this.transitionTx(taskId, to, actor, detail)
    })
  }

  /** 挂证据（git base / 验收官产出）——merge 进 evidence 列，不碰执行者的收据。验收官 cost 也计入。 */
  attachEvidence(taskId: string, patch: object, actor: string): void {
    this.tx(() => this.attachEvidenceTx(taskId, patch, actor))
  }

  private attachEvidenceTx(taskId: string, patch: object, actor: string): void {
    const task = this.getTask(taskId)
    if (!task) return
    let ev: Record<string, unknown> = {}
    try { ev = task.evidence ? JSON.parse(task.evidence) : {} } catch {}
    Object.assign(ev, patch)
    const cost = (patch as any)?.inspector_cost_usd
    this.db.query("UPDATE tasks SET evidence = ?, cost_usd = cost_usd + ? WHERE task_id = ?")
      .run(JSON.stringify(ev), typeof cost === "number" ? cost : 0, taskId)
    this.log(taskId, actor, "evidence", JSON.stringify(patch).slice(0, 200))
  }

  /** 挂朱批 */
  attachVerdict(taskId: string, verdict: object, actor: string): void {
    this.tx(() => {
      this.db.query("UPDATE tasks SET verdict = ? WHERE task_id = ?").run(JSON.stringify(verdict), taskId)
      this.log(taskId, actor, "verdict", JSON.stringify(verdict).slice(0, 200))
    })
  }

  queryTasks(q: { status?: string; target?: string; limit?: number }): TaskRow[] {
    const conds: string[] = []
    const params: unknown[] = []
    if (q.status) { conds.push("status = ?"); params.push(q.status) }
    if (q.target) { conds.push("target_ref LIKE ?"); params.push(`%${q.target}%`) }
    const where = conds.length ? `WHERE ${conds.join(" AND ")}` : ""
    const limit = Math.min(Math.max(q.limit ?? 50, 1), 500)
    return this.db.query(`SELECT * FROM tasks ${where} ORDER BY created_at DESC LIMIT ${limit}`).all(...(params as any[])) as TaskRow[]
  }

  taskLog(taskId: string): unknown[] {
    return this.db.query("SELECT ts, actor, event, detail FROM task_log WHERE task_id = ? ORDER BY id").all(taskId)
  }

  close(): void { this.db.close() }
}
