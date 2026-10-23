// 军机处 M1 · 派发器
// 通道选路：
//   T1 tmux 注入   —— target 活着且在 tmux（hub ensureSessionAndSend，打扰式）
//   T2 headless    —— target 已死但 transcript 在（claude --resume -p / codex exec resume，可控式，默认优先）
//   拒绝           —— target 活着但不在 tmux（T3 够不着），或命中保护名单
// 保险丝：陪伴会话永拒；ask_susu 工单不自动派；T2 并发上限（烧钱闸）；子进程超时必杀。
import { retryBusy, WarroomLedger, type TaskRow } from "./warroom-ledger.ts"
import { timedSyncFs } from "./block-ledger"
const { statSync, existsSync } = timedSyncFs("warroom-dispatch ")

function statSyncBytes(p: string): number { return statSync(p).size }

export interface TargetInfo {
  sessionId: string
  engine: "claude" | "codex"
  alive: boolean
  tmuxSession: string | null
  cwd: string | null
  transcriptPath: string | null
}

export type Route =
  | { channel: "t1"; tmuxSession: string }
  | { channel: "t2" }
  | { channel: "reject"; reason: string }

// 陪伴会话保护名单：tmux 名 + env 扩展。中枢不可指挥中枢，狗不咬自己的尾巴。
export function protectedSessions(): Set<string> {
  const base = ["mp-cc", "mp-cc-6", "mp-cc-2521523d"]
  const extra = (process.env.MP_WARROOM_PROTECTED ?? "").split(",").map(s => s.trim()).filter(Boolean)
  return new Set([...base, ...extra])
}

/** 纯函数选路（可测）。protectedSet 里的 tmux 会话 / session id 一律拒。 */
export function pickRoute(target: TargetInfo, protectedSet: Set<string>): Route {
  if (protectedSet.has(target.sessionId) || (target.tmuxSession && protectedSet.has(target.tmuxSession))) {
    return { channel: "reject", reason: `target is protected (陪伴会话不受理奏折): ${target.tmuxSession ?? target.sessionId}` }
  }
  if (target.alive && target.tmuxSession) return { channel: "t1", tmuxSession: target.tmuxSession }
  if (target.alive && !target.tmuxSession) {
    return { channel: "reject", reason: "target alive but not in tmux (T3 够不着——关掉它变历史会话，或用 tmux 重开)" }
  }
  if (!target.transcriptPath) return { channel: "reject", reason: "no transcript on disk — cannot resume" }
  return { channel: "t2" }
}

/** T1 工单文本（注入进对方 TUI 的内容） */
export function buildWorkOrderTag(task: TaskRow, receiptDir: string): string {
  const body = task.body.replace(/\n/g, " ")
  return `<channel source="warroom" task_id="${task.task_id}">【军机处奏折 ${task.task_id}】${body} —— 完成后把结果写到 ${receiptDir}/${task.task_id}.json（格式：{"status":"done|blocked","summary":"…","files":[…],"tests":"…"}），然后继续待命。</channel>`
}

// T2 执行者的 Bash 白名单：只读 + 测试类。acceptEdits 只管文件编辑不管 Bash——
// 没有这个白名单，跑测试类工单在 headless 下必被权限弹窗拦死（zz-0726-04 实弹发现）。
// 危险命令（rm/push/sudo…）不在名单 → headless 直接 deny，正是想要的。
export const T2_ALLOWED_TOOLS =
  "Bash(bun test:*) Bash(bun run:*) Bash(npm test:*) Bash(npm run:*) Bash(npx vitest:*) " +
  "Bash(swift test:*) Bash(xcodebuild test:*) Bash(python3 -m pytest:*) Bash(cargo test:*) " +
  "Bash(git diff:*) Bash(git status:*) Bash(git log:*) Bash(git show:*) Bash(git add:*) Bash(git commit:*) " +
  "Bash(ls:*) Bash(cat:*) Bash(head:*) Bash(tail:*) Bash(wc:*) Bash(grep:*) Bash(rg:*)"

/** T2 命令行构造（纯函数，可测） */
export function buildT2Command(task: TaskRow, sessionId: string): string[] {
  if (task.engine === "codex") {
    return ["codex", "exec", "resume", sessionId, task.body, "--json", "-s", "workspace-write", "--color", "never"]
  }
  return [
    "claude", "--resume", sessionId, "-p", task.body,
    "--output-format", "json", "--permission-mode", "acceptEdits",
    "--allowedTools", T2_ALLOWED_TOOLS,
  ]
}

/** T4 命令行：目标目录里**新开**会话（无 --resume）。$21.73 学费的正解——
 *  大多数新活不需要老兵的记忆，新会话干净且便宜一个数量级。 */
export function buildT4Command(task: TaskRow): string[] {
  if (task.engine === "codex") {
    return ["codex", "exec", task.body, "--json", "-s", "workspace-write", "--color", "never"]
  }
  return [
    "claude", "-p", task.body,
    "--output-format", "json", "--permission-mode", "acceptEdits",
    "--allowedTools", T2_ALLOWED_TOOLS,
  ]
}

export interface T2Result {
  ok: boolean
  receipt: object | null      // claude: stdout 整个 JSON；codex: 最后一个 JSONL 事件集合
  raw: string
  exitCode: number
  timedOut: boolean
}

/** codex --json 输出是 JSONL 事件流——收据取尾部聚合（最后 message + token 统计行） */
export function parseCodexJsonl(raw: string): object | null {
  const lines = raw.trim().split("\n").filter(Boolean)
  const events: any[] = []
  for (const l of lines) { try { events.push(JSON.parse(l)) } catch { /* 忽略非 JSON 行 */ } }
  if (!events.length) return null
  const lastMsg = [...events].reverse().find(e => e?.msg?.type === "agent_message" || e?.type === "item.completed")
  const usage = [...events].reverse().find(e => e?.msg?.type === "token_count" || e?.type === "turn.completed")
  return { engine: "codex", last_message: lastMsg ?? null, usage: usage ?? null, event_count: events.length }
}

export function parseT2Output(engine: "claude" | "codex", raw: string): object | null {
  if (engine === "codex") return parseCodexJsonl(raw)
  try {
    const j = JSON.parse(raw.trim())
    return typeof j === "object" && j !== null ? j : null
  } catch {
    // claude 偶发在 JSON 前打日志行——从第一个 { 起再试
    const i = raw.indexOf("{")
    if (i > 0) { try { return JSON.parse(raw.slice(i)) } catch { /* fallthrough */ } }
    return null
  }
}

export const T2_TIMEOUT_MS = Number(process.env.MP_WARROOM_T2_TIMEOUT_MIN ?? 10) * 60_000
export const T2_MAX_CONCURRENT = Number(process.env.MP_WARROOM_T2_MAX ?? 2)

// 预算防线（zz-0726-07 学费 $21.73 换来的）：T2 唤醒 = 全量重烤目标上下文。
// 派单前按 transcript 字节数粗估唤醒成本（~8 字节/token，opus $15/M × 1.25 cache write），
// 超过阈值拒绝——除非派单人明示 budget_ok（知道贵还要派 = 有理由）。
export const T2_COST_GUARD_USD = Number(process.env.MP_WARROOM_COST_GUARD ?? 2)
export function estimateResumeCostUsd(transcriptBytes: number): number {
  const tokens = transcriptBytes / 8
  return Math.round(tokens / 1e6 * 15 * 1.25 * 100) / 100
}

export interface DispatcherDeps {
  ledger: WarroomLedger
  lookupTarget: (ref: string) => TargetInfo | null      // 普查表查询（session_id 或 tmux 名）
  sendTmux: (tag: string, session: string) => Promise<void>
  spawnT2: (cmd: string[], cwd: string | null, timeoutMs: number) => Promise<{ stdout: string; exitCode: number; timedOut: boolean }>
  receiptDir: string
  onT2Settled?: (taskId: string) => void
  transcriptSize?: (path: string) => number             // 预算防线用；缺省 statSync
  repoExists?: (dir: string) => boolean                 // T4 目录校验；缺省 existsSync（测试注入用）
}

const ACTIVE_FOR_REPO = ["dispatched", "working", "evidence_in", "reviewing"]

export class WarroomDispatcher {
  private running = 0
  constructor(private deps: DispatcherDeps) {}

  get t2Running(): number { return this.running }

  /** repo 锁：同一 cwd 同时只飞一张奏折（学 CAS 的 worktree 隔离补的缺口——
   *  军机处复活的是带记忆的老兵，必须在原目录干活，隔离不可行，只能不并发）。
   *  无状态查询实现：hub 重启不丢锁。repo 单的 cwd 就是 target_ref 本身。 */
  private repoConflict(taskId: string, cwd: string): string | null {
    for (const status of ACTIVE_FOR_REPO) {
      for (const t of this.deps.ledger.queryTasks({ status, limit: 50 })) {
        if (t.task_id === taskId) continue
        const otherCwd = t.target_kind === "repo" ? t.target_ref : this.deps.lookupTarget(t.target_ref)?.cwd
        if (otherCwd && otherCwd === cwd) return t.task_id
      }
    }
    return null
  }

  /** T4：在目录里新开 headless 会话跑工单（无 --resume），收据闭环 T2 同款 */
  private async startT4(task: TaskRow, actor: string): Promise<{ channel: string; note: string }> {
    const { ledger } = this.deps
    if (this.running >= T2_MAX_CONCURRENT) throw new Error(`T2/T4 concurrency limit reached (${T2_MAX_CONCURRENT}) — try later`)
    const cmd = buildT4Command(task)
    await retryBusy(() => ledger.transition(task.task_id, "dispatched", actor, `t4 → fresh session @ ${task.target_ref}`))
    this.running++
    void this.deps.spawnT2(cmd, task.target_ref, T2_TIMEOUT_MS)
      .then(async ({ stdout, exitCode, timedOut }) => {
        const receipt = parseT2Output(task.engine, stdout)
        // K2 审查 R1-1：账本写撞上 scan worker 的批事务 → 异步退避重试（每个账本操作是一个事务，重试不会半成功）
        if (timedOut) {
          await retryBusy(() => ledger.transition(task.task_id, "failed", "hub", `t4 timeout after ${T2_TIMEOUT_MS}ms`))
        } else if (receipt) {
          const isErr = (receipt as any).is_error === true || exitCode !== 0
          await retryBusy(() => ledger.acceptReceipt(task.task_id, receipt, "hub", isErr ? "failed" : "evidence_in", "hub", `t4 exit=${exitCode}`))
        } else {
          await retryBusy(() => ledger.transition(task.task_id, "failed", "hub", `t4 unparseable output (exit=${exitCode}): ${stdout.slice(0, 150)}`))
        }
      })
      .catch(async (e: any) => {
        try { await retryBusy(() => ledger.transition(task.task_id, "failed", "hub", `t4 spawn error: ${e?.message}`)) } catch { /* 已终态 / 一直撞锁 */ }
      })
      .finally(() => { this.running--; try { this.deps.onT2Settled?.(task.task_id) } catch { /* 回调只记日志，别让链 reject */ } })
    return { channel: "t4", note: `fresh headless session @ ${task.target_ref} started (timeout ${T2_TIMEOUT_MS / 60000}min)` }
  }

  /** 派发一张 draft 工单。返回启动信息；T2 的完成是异步的（收据落账本后 evidence_in）。
   *  budgetOk = 派单人明示接受高唤醒成本（预算防线 override）。 */
  async dispatch(taskId: string, actor: string, budgetOk = false): Promise<{ channel: string; note: string }> {
    const { ledger, lookupTarget } = this.deps
    const task = ledger.getTask(taskId)
    if (!task) throw new Error(`task not found: ${taskId}`)
    if (task.status !== "draft" && task.status !== "rejected") throw new Error(`task ${taskId} not dispatchable (status=${task.status})`)
    if (task.approval === "ask_susu") throw new Error(`task ${taskId} requires susu's approval (危险工单不自动派)`)
    if (!ledger.depsSatisfied(task)) throw new Error(`task ${taskId} 依赖未满足——排队中，等前置工单全部朱批（DAG 定时器会自动放行）`)

    // T4 repo 通道：target_ref = 目录，不查普查表
    if (task.target_kind === "repo") {
      const dirOk = this.deps.repoExists ? this.deps.repoExists(task.target_ref) : existsSync(task.target_ref)
      if (!dirOk) throw new Error(`repo dir not found: ${task.target_ref}`)
      const holder = this.repoConflict(taskId, task.target_ref)
      if (holder) throw new Error(`repo busy: ${task.target_ref} 已有在飞奏折 ${holder}（同仓库不并发，防打架）`)
      return this.startT4(task, actor)
    }

    const target = lookupTarget(task.target_ref)
    if (!target) throw new Error(`target not found in census: ${task.target_ref}`)
    if (target.cwd) {
      const holder = this.repoConflict(taskId, target.cwd)
      if (holder) throw new Error(`repo busy: ${target.cwd} 已有在飞奏折 ${holder}（同仓库不并发，防打架）`)
    }
    // 预算防线：T2 唤醒前估算重烤成本（zz-0726-07 的 $21.73 学费）
    if (!target.alive && target.transcriptPath && !budgetOk) {
      const sizeOf = this.deps.transcriptSize ?? ((p: string) => { try { return statSyncBytes(p) } catch { return 0 } })
      const est = estimateResumeCostUsd(sizeOf(target.transcriptPath))
      if (est > T2_COST_GUARD_USD) {
        throw new Error(`budget guard: 复活 ${target.sessionId.slice(0, 8)} 预估重烤 ~$${est}（阈值 $${T2_COST_GUARD_USD}）。` +
          `真要派：budget_ok=true。更省的做法：新开 headless 会话干这活（repo 目录当 target_kind=repo，M4）`)
      }
    }
    const route = pickRoute(target, protectedSessions())

    if (route.channel === "reject") throw new Error(`dispatch rejected: ${route.reason}`)

    if (route.channel === "t1") {
      const tag = buildWorkOrderTag(task, this.deps.receiptDir)
      await this.deps.sendTmux(tag, route.tmuxSession)
      await retryBusy(() => ledger.transition(taskId, "dispatched", actor, `t1 → tmux:${route.tmuxSession}`))
      return { channel: "t1", note: `injected into tmux:${route.tmuxSession}` }
    }

    // T2：并发闸
    if (this.running >= T2_MAX_CONCURRENT) throw new Error(`T2 concurrency limit reached (${T2_MAX_CONCURRENT}) — try later`)
    const cmd = buildT2Command(task, target.sessionId)
    await retryBusy(() => ledger.transition(taskId, "dispatched", actor, `t2 → resume ${target.sessionId.slice(0, 8)}`))
    this.running++
    // 异步跑完自动收账（调用方不等）
    void this.deps.spawnT2(cmd, target.cwd, T2_TIMEOUT_MS)
      .then(async ({ stdout, exitCode, timedOut }) => {
        const receipt = parseT2Output(task.engine, stdout)
        // K2 审查 R1-1：账本写撞上 scan worker 的批事务 → 异步退避重试（每个账本操作是一个事务，重试不会半成功）
        if (timedOut) {
          await retryBusy(() => ledger.transition(taskId, "failed", "hub", `t2 timeout after ${T2_TIMEOUT_MS}ms`))
        } else if (receipt) {
          const isErr = (receipt as any).is_error === true || exitCode !== 0
          await retryBusy(() => ledger.acceptReceipt(taskId, receipt, "hub", isErr ? "failed" : "evidence_in", "hub", `t2 exit=${exitCode}`))
        } else {
          await retryBusy(() => ledger.transition(taskId, "failed", "hub", `t2 unparseable output (exit=${exitCode}): ${stdout.slice(0, 150)}`))
        }
      })
      .catch(async (e: any) => {
        try { await retryBusy(() => ledger.transition(taskId, "failed", "hub", `t2 spawn error: ${e?.message}`)) } catch { /* 已终态 / 一直撞锁 */ }
      })
      .finally(() => { this.running--; try { this.deps.onT2Settled?.(taskId) } catch { /* 回调只记日志，别让链 reject */ } })
    return { channel: "t2", note: `headless resume ${target.sessionId.slice(0, 8)} started (timeout ${T2_TIMEOUT_MS / 60000}min)` }
  }
}

/** 生产 spawnT2：Bun.spawn + 超时必杀 */
export async function realSpawnT2(cmd: string[], cwd: string | null, timeoutMs: number): Promise<{ stdout: string; exitCode: number; timedOut: boolean }> {
  const proc = Bun.spawn(cmd, { cwd: cwd ?? undefined, stdout: "pipe", stderr: "pipe", env: { ...process.env } })
  let timedOut = false
  const timer = setTimeout(() => { timedOut = true; proc.kill(9) }, timeoutMs)
  const stdout = await new Response(proc.stdout).text()
  const exitCode = await proc.exited
  clearTimeout(timer)
  return { stdout, exitCode, timedOut }
}
