import { test, expect } from "bun:test"
import { Database } from "bun:sqlite"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { WarroomLedger, IllegalTransition, TargetBusy, isDangerous, isSqliteBusy, retryBusy } from "./warroom-ledger.ts"
import { MAIN_BUSY_TIMEOUT_MS, WarroomIndexer } from "./warroom-indexer"

function mkLedger(): WarroomLedger {
  return new WarroomLedger(join(mkdtempSync(join(tmpdir(), "wl-")), "l.db"))
}

const BASE = { title: "补测试", body: "把 reader-daemon 的测试补完", target_kind: "resume" as const, target_ref: "sess-1", engine: "claude" as const, created_by: "zhongshu" }

test("账本：创建 → id 格式 zz-MMDD-NN，状态 draft，审计留痕", () => {
  const l = mkLedger()
  const t = l.createTask(BASE)
  expect(t.task_id).toMatch(/^zz-\d{4}-\d{2}$/)
  expect(t.status).toBe("draft")
  expect((l.taskLog(t.task_id) as any[])[0].event).toBe("created")
  l.close()
})

test("状态机：合法链 draft→dispatched→working→evidence_in→approved", () => {
  const l = mkLedger()
  const t = l.createTask(BASE)
  l.transition(t.task_id, "dispatched", "hub")
  l.transition(t.task_id, "working", "hub")
  l.transition(t.task_id, "evidence_in", "hub")
  const done = l.transition(t.task_id, "approved", "zhongshu", "验收通过")
  expect(done.status).toBe("approved")
  expect(done.dispatched_at).not.toBeNull()
  expect(done.done_at).not.toBeNull()
  l.close()
})

test("状态机：非法迁移抛 IllegalTransition（draft→approved / approved→任何）", () => {
  const l = mkLedger()
  const t = l.createTask(BASE)
  expect(() => l.transition(t.task_id, "approved", "x")).toThrow(IllegalTransition)
  l.transition(t.task_id, "dispatched", "hub")
  l.transition(t.task_id, "evidence_in", "hub")   // T2 快任务直跳合法
  l.transition(t.task_id, "approved", "x")
  expect(() => l.transition(t.task_id, "dispatched", "x")).toThrow(IllegalTransition)
  l.close()
})

test("状态机：rejected → dispatched 返工链合法", () => {
  const l = mkLedger()
  const t = l.createTask(BASE)
  l.transition(t.task_id, "dispatched", "hub")
  l.transition(t.task_id, "evidence_in", "hub")
  l.transition(t.task_id, "rejected", "inspector", "测试没真跑")
  const re = l.transition(t.task_id, "dispatched", "hub", "返工第1轮")
  expect(re.status).toBe("dispatched")
  l.close()
})

test("单 active 锁：同 target 活工单存在时 createTask 抛 TargetBusy；完结后可再开", () => {
  const l = mkLedger()
  const t1 = l.createTask(BASE)
  l.transition(t1.task_id, "dispatched", "hub")
  expect(() => l.createTask({ ...BASE, title: "另一张" })).toThrow(TargetBusy)
  l.transition(t1.task_id, "evidence_in", "hub")
  expect(() => l.createTask({ ...BASE, title: "还是不行" })).toThrow(TargetBusy)   // evidence_in 也算活
  l.transition(t1.task_id, "approved", "x")
  const t2 = l.createTask({ ...BASE, title: "现在可以了" })
  expect(t2.status).toBe("draft")
  l.close()
})

test("危险模式：rm -rf / force push / 改军机处自己 / sudo → 强制 ask_susu", () => {
  expect(isDangerous("清理一下：rm -rf node_modules")).toBe(true)
  expect(isDangerous("git push --force origin main")).toBe(true)
  expect(isDangerous("改一下 cc-bridge/hub.ts 的端口")).toBe(true)
  expect(isDangerous("sudo launchctl load")).toBe(true)
  expect(isDangerous("把 reader-daemon 的测试补完")).toBe(false)
  const l = mkLedger()
  const t = l.createTask({ ...BASE, body: "rm -rf dist && rebuild", approval: "auto" })
  expect(t.approval).toBe("ask_susu")   // 声明 auto 也拗不过危险模式
  l.close()
})

test("收据：attachReceipt 记 cost 并留审计", () => {
  const l = mkLedger()
  const t = l.createTask(BASE)
  // 实验 ① 拿到的真实 T2 收据形状（裁剪）
  l.attachReceipt(t.task_id, {
    is_error: false, num_turns: 1, result: "naked",
    total_cost_usd: 0.503598, session_id: "f3e659aa", permission_denials: [],
  }, "hub")
  const after = l.getTask(t.task_id)!
  expect(after.cost_usd).toBeCloseTo(0.503598)
  expect(JSON.parse(after.receipt!).result).toBe("naked")
  const events = (l.taskLog(t.task_id) as any[]).map(e => e.event)
  expect(events).toContain("receipt")
  l.close()
})

test("查询：按 status/target 过滤", () => {
  const l = mkLedger()
  const t1 = l.createTask(BASE)
  l.createTask({ ...BASE, target_ref: "sess-2" })
  l.transition(t1.task_id, "dispatched", "hub")
  expect(l.queryTasks({ status: "draft" }).length).toBe(1)
  expect(l.queryTasks({ status: "dispatched" }).length).toBe(1)
  expect(l.queryTasks({ target: "sess-" }).length).toBe(2)
  l.close()
})

// ── M4：依赖 DAG ──

test("DAG：依赖不存在拒收；depsSatisfied 全 approved 才 true；readyQueuedTasks 只出满足的", () => {
  const l = mkLedger()
  expect(() => l.createTask({ ...BASE, depends_on: ["zz-9999-99"] })).toThrow(/不存在/)
  const a = l.createTask({ ...BASE, target_ref: "sA" })
  const b = l.createTask({ ...BASE, target_ref: "sB", depends_on: [a.task_id], epic: "试验EPIC" })
  expect(b.epic).toBe("试验EPIC")
  expect(l.depsSatisfied(l.getTask(b.task_id)!)).toBe(false)
  expect(l.readyQueuedTasks().length).toBe(0)
  // A 走完到 approved
  l.transition(a.task_id, "dispatched", "hub")
  l.transition(a.task_id, "evidence_in", "hub")
  l.transition(a.task_id, "approved", "x")
  expect(l.depsSatisfied(l.getTask(b.task_id)!)).toBe(true)
  const ready = l.readyQueuedTasks()
  expect(ready.length).toBe(1)
  expect(ready[0].task_id).toBe(b.task_id)
  l.close()
})

test("DAG：带依赖的单允许在目标忙时立案排队（实弹②修复）", () => {
  const l = mkLedger()
  const a = l.createTask({ ...BASE, target_ref: "sX" })
  l.transition(a.task_id, "dispatched", "hub")   // A 在飞，目标忙
  expect(() => l.createTask({ ...BASE, target_ref: "sX", title: "无依赖" })).toThrow(TargetBusy)
  const b = l.createTask({ ...BASE, target_ref: "sX", title: "带依赖", depends_on: [a.task_id] })
  expect(b.status).toBe("draft")   // 排队立案成功
  l.close()
})

// ── M5：需求与 EPIC 终审聚合 ──

test("M5：createRequest 编号 zq-MMDD-NN；epic 全终态才进终审队列；reviewing 不重复触发", () => {
  const l = mkLedger()
  const r = l.createRequest("给读书页加夜间模式")
  expect(r.request_id).toMatch(/^zq-\d{4}-\d{2}$/)
  // epic 下还没有任务 → 不触发（total=0）
  expect(l.epicsReadyForFinalReview().length).toBe(0)
  const t1 = l.createTask({ ...BASE, target_ref: "e1", epic: r.request_id })
  const t2 = l.createTask({ ...BASE, target_ref: "e2", epic: r.request_id })
  l.transition(t1.task_id, "dispatched", "hub"); l.transition(t1.task_id, "evidence_in", "hub"); l.transition(t1.task_id, "approved", "x")
  expect(l.epicsReadyForFinalReview().length).toBe(0)   // t2 还是 draft
  l.transition(t2.task_id, "dispatched", "hub"); l.transition(t2.task_id, "failed", "hub")
  const ready = l.epicsReadyForFinalReview()
  expect(ready.length).toBe(1)
  expect(ready[0].total).toBe(2)
  expect(ready[0].approved).toBe(1)
  l.setRequestStatus(r.request_id, "reviewing")
  expect(l.epicsReadyForFinalReview().length).toBe(0)   // 不重复触发
  l.close()
})

test("K2 审查 R1-2：收据 + 迁移一个事务——撞锁整个回滚、重试只记一次 cost；同一份收据再挂不重复记账", () => {
  const dir = mkdtempSync(join(tmpdir(), "warroom-ledger-tx-"))
  const l = new WarroomLedger(join(dir, "w.db"))
  l.db.exec("PRAGMA journal_mode = WAL")
  const t = l.createTask(BASE)
  l.transition(t.task_id, "dispatched", "hub")
  const receipt = { is_error: false, result: "ok", total_cost_usd: 2 }

  // 另一条连接（scan worker）占着写锁：账本操作撞锁失败，什么都没留下
  const other = new Database(join(dir, "w.db"))
  other.exec("BEGIN IMMEDIATE")
  expect(() => l.acceptReceipt(t.task_id, receipt, "t1-receipt", "evidence_in", "hub")).toThrow(/locked|busy/i)
  let row = l.getTask(t.task_id)!
  expect(row.receipt).toBeNull()
  expect(row.cost_usd).toBe(0)
  expect(row.status).toBe("dispatched")
  other.exec("COMMIT")
  other.close()

  // 迁移那一步失败（日志写不进）→ 收据和 cost 也回滚
  const ledger = l as unknown as { log: (id: string, actor: string, event: string, detail?: string) => void }
  const realLog = ledger.log.bind(l)
  let failOnce = true
  ledger.log = (id, actor, event, detail) => {
    if (event === "→ evidence_in" && failOnce) { failOnce = false; throw new Error("注入：日志写失败") }
    realLog(id, actor, event, detail)
  }
  expect(() => l.acceptReceipt(t.task_id, receipt, "t1-receipt", "evidence_in", "hub")).toThrow("注入")
  row = l.getTask(t.task_id)!
  expect(row.cost_usd).toBe(0)
  expect(row.receipt).toBeNull()

  // 重试成功：cost 只记一次；同一份收据再挂一次（重复投递）不翻倍
  l.acceptReceipt(t.task_id, receipt, "t1-receipt", "evidence_in", "hub")
  l.attachReceipt(t.task_id, receipt, "t1-receipt")
  row = l.getTask(t.task_id)!
  expect(row.cost_usd).toBe(2)
  expect(row.status).toBe("evidence_in")
  expect((l.taskLog(t.task_id) as Array<{ event: string }>).map((e) => e.event)).toEqual(["created", "→ dispatched", "receipt", "→ evidence_in"])
  l.close()
})

test("K2 审查 R1-1：retryBusy 只重试 SQLITE_BUSY，次数用完把原错误抛回", async () => {
  const busy = Object.assign(new Error("database is locked"), { code: "SQLITE_BUSY" })
  let n = 0
  expect(await retryBusy(() => { if (++n < 3) throw busy; return "ok" }, [1, 1, 1])).toBe("ok")
  expect(n).toBe(3)
  n = 0
  await expect(retryBusy(() => { n++; throw new Error("别的错") }, [1, 1])).rejects.toThrow("别的错")
  expect(n).toBe(1)
  n = 0
  await expect(retryBusy(() => { n++; throw busy }, [1, 1])).rejects.toThrow("database is locked")
  expect(n).toBe(3)
  expect(isSqliteBusy(busy)).toBe(true)
  expect(isSqliteBusy(new Error("x"))).toBe(false)
})

test("K2 审查 R1-1：主连接撞上 worker 的长事务——每次同步只等 ~20ms，主循环照转，锁放开后整个账本操作成功", async () => {
  const dir = mkdtempSync(join(tmpdir(), "warroom-ledger-busy-"))
  const opts = { dbPath: join(dir, "w.db"), ccProjectsRoot: join(dir, "p"), codexSessionsRoot: join(dir, "c") }
  const idx = new WarroomIndexer(opts)                          // 主连接：MAIN_BUSY_TIMEOUT_MS
  const l = new WarroomLedger(idx.db)
  const worker = new Database(opts.dbPath)                     // 「worker」连接占着写锁 400ms
  worker.exec("BEGIN IMMEDIATE")
  worker.exec("INSERT INTO scan_state(path, size, mtime_ms, offset) VALUES ('x', 1, 1, 1)")
  setTimeout(() => worker.exec("COMMIT"), 400)

  let ticks = 0
  const tick = setInterval(() => { ticks++ }, 10)
  let maxSync = 0
  const t0 = performance.now()
  const req = await retryBusy(() => {
    const s = performance.now()
    try { return l.createRequest("撞锁也要存档") } finally { maxSync = Math.max(maxSync, performance.now() - s) }
  })
  clearInterval(tick)
  expect(req.request_id).toMatch(/^zq-\d{4}-01$/)
  expect(performance.now() - t0).toBeGreaterThanOrEqual(380)
  expect(maxSync).toBeLessThan(MAIN_BUSY_TIMEOUT_MS + 80)       // 原来 busy_timeout=5000：一次同步卡满 400ms
  expect(ticks).toBeGreaterThan(10)                            // 等锁期间定时器照常跑
  expect(l.getRequest(req.request_id)?.text).toBe("撞锁也要存档")

  // 一直拿不到锁：重试用完 reject（调用方 .catch 回 WS 错误），不留半截
  worker.exec("BEGIN IMMEDIATE")
  await expect(retryBusy(() => l.createRequest("拿不到锁"), [5, 5])).rejects.toThrow(/locked/)
  worker.exec("ROLLBACK")
  expect((l.db.query("SELECT COUNT(*) AS n FROM requests").get() as { n: number }).n).toBe(1)
  worker.close(); idx.close()
})
