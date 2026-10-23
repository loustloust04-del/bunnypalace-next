// K2：warroom 普查扫描进 Worker 线程。全在临时目录：假 projects / codex 树 + 临时 db，不碰真 secrets / ~/.claude / ~/.codex，
// liveness 一律 "none"（不跑 tmux / ps）
import { afterEach, beforeEach, expect, test } from "bun:test"
import { Database } from "bun:sqlite"
import { appendFileSync, mkdirSync, mkdtempSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { BlockLedger } from "./block-ledger"
import { WarroomLedger } from "./warroom-ledger"
import { WarroomIndexer, WRITE_BATCH, type IndexerOptions } from "./warroom-indexer"
import { k2Enabled, WarroomScanWorker, warroomScanRunner, WorkerUnavailable, type ScanSummary } from "./warroom-scan-client"

const cc = (sid: string, i: number, extra: object = {}) => JSON.stringify({
  type: "user", sessionId: sid, cwd: `/Users/x/项目-${sid}`, timestamp: `2026-10-11T0${i % 10}:00:00Z`, message: { content: `任务 ${sid} #${i}` }, ...extra,
}) + "\n"
const asst = (rid: string) => JSON.stringify({
  type: "assistant", requestId: rid, timestamp: "2026-10-11T09:00:00Z",
  message: { usage: { output_tokens: 7, cache_read_input_tokens: 3 }, content: [{ type: "tool_use", name: "Bash", input: { command: `echo ${rid}` } }] },
}) + "\n"

/// 造一棵假树：3 个 CC 项目 × 4 个会话（> WRITE_BATCH，跨批次）+ 一个 2.5MB 大文件（跨多轮 partial）+
/// 一个带半行尾巴的 + codex 两层目录 3 个 rollout
function makeTree(): { root: string; opts: (db: string) => IndexerOptions; ccRoot: string } {
  const root = mkdtempSync(join(tmpdir(), "warroom-k2-"))
  const ccRoot = join(root, "projects"), cxRoot = join(root, "codex")
  for (let p = 0; p < 3; p++) {
    mkdirSync(join(ccRoot, `-Users-x-p${p}`), { recursive: true })
    for (let s = 0; s < 4; s++) {
      const sid = `cc-${p}-${s}`
      writeFileSync(join(ccRoot, `-Users-x-p${p}`, `${sid}.jsonl`), cc(sid, 1) + asst(`r-${sid}`) + cc(sid, 2))
    }
  }
  const big = [cc("cc-big", 0)]
  for (let i = 0; big.join("").length < 2.5 * 1024 * 1024; i++) big.push(asst(`big-${i}`) + JSON.stringify({ type: "user", sessionId: "cc-big", message: { content: "x".repeat(4000) } }) + "\n")
  writeFileSync(join(ccRoot, "-Users-x-p0", "cc-big.jsonl"), big.join(""))
  writeFileSync(join(ccRoot, "-Users-x-p1", "cc-half.jsonl"), cc("cc-half", 1) + '{"type":"assistant","message":"' + "y".repeat(2048))
  for (let d = 0; d < 3; d++) {
    const dir = join(cxRoot, "2026", "10", `1${d}`)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, `rollout-2026-10-1${d}T00-00-00-cx${d}.jsonl`),
      JSON.stringify({ timestamp: "2026-10-11T01:00:00Z", type: "session_meta", payload: { id: `cx-${d}`, cwd: `/Users/x/codex${d}`, originator: "codex_cli" } }) + "\n" +
      JSON.stringify({ timestamp: "2026-10-11T01:01:00Z", type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: `codex 任务 ${d}` }] } }) + "\n")
  }
  return { root, ccRoot, opts: (db) => ({ dbPath: join(root, db), ccProjectsRoot: ccRoot, codexSessionsRoot: cxRoot }) }
}

/// 三张表的内容（indexed_at 是写入时刻，不比）
function dump(db: Database): unknown {
  return {
    sessions: db.query("SELECT * FROM sessions ORDER BY session_id").all().map((r) => { const { indexed_at: _, ...rest } = r as Record<string, unknown>; return rest }),
    scan_state: db.query("SELECT * FROM scan_state ORDER BY path").all(),
    acc_cache: db.query("SELECT * FROM acc_cache ORDER BY path").all(),
  }
}

const sumSites = (b: BlockLedger, prefix: string) => [...b.stats].filter(([k]) => k.startsWith(prefix)).reduce((n, [, s]) => n + s.count, 0)

let workers: WarroomScanWorker[] = []
let unhandled: unknown[] = []
const onUnhandled = (e: unknown) => { unhandled.push(e) }
beforeEach(() => { workers = []; unhandled = []; process.on("unhandledRejection", onUnhandled) })
afterEach(() => { for (const w of workers) w.terminate(); process.off("unhandledRejection", onUnhandled) })
const mk = (o: ConstructorParameters<typeof WarroomScanWorker>[0]) => { const w = new WarroomScanWorker({ liveness: "none", log: () => {}, ...o }); workers.push(w); return w }

test("K2：worker 扫描结果与主线程 scanAllAsync 逐行一致；库是 WAL；阻塞账带 warroom-worker 前缀并回主账", async () => {
  const t = makeTree()
  const main = new WarroomIndexer(t.opts("main.db"))
  const rMain = await main.scanAllAsync(async () => [])

  const reader = new WarroomIndexer(t.opts("worker.db"))      // hub 里主线程先开库（读查询 + 账本），worker 再开第二条连接
  const ledger = new BlockLedger(Date.now, () => {})
  const w = mk({ indexer: t.opts("worker.db"), ledger })
  const rWorker = await w.scan()

  expect(rWorker).toEqual(rMain)
  expect(rMain.scanned).toBe(3 * 4 + 2 + 3)
  expect(rMain.changed).toBeGreaterThan(rMain.scanned)        // 大文件跨了好几轮
  expect(dump(reader.db)).toEqual(dump(main.db))
  expect((reader.querySessions({}) as unknown[]).length).toBe(3 * 4 + 2 + 3)
  expect((reader.db.query("PRAGMA journal_mode").get() as { journal_mode: string }).journal_mode).toBe("wal")

  const sites = [...ledger.stats.keys()]
  expect(sites.length).toBeGreaterThan(0)
  expect(sites.every((k) => k.startsWith("warroom-worker ") || k.startsWith("sqlite warroom-worker "))).toBe(true)
  expect(sumSites(ledger, "warroom-worker fs.statSync")).toBeGreaterThan(0)
  // 写进了批事务：COMMIT 次数远少于写的条数（每个文件 3 条）
  const commits = ledger.stats.get("sqlite warroom-worker COMMIT")?.count ?? 0
  expect(commits).toBeGreaterThan(0)
  expect(commits).toBeLessThan(rMain.changed)
  expect(rMain.scanned).toBeGreaterThan(WRITE_BATCH)
  expect(unhandled).toEqual([])
  main.close(); reader.close()
})

test("K2：增量只读变化的文件；没变化 changed=0；worker 跨轮复用", async () => {
  const t = makeTree()
  const reader = new WarroomIndexer(t.opts("w.db"))
  const ledger = new BlockLedger(Date.now, () => {})
  const w = mk({ indexer: t.opts("w.db"), ledger })
  const r1 = await w.scan()
  expect(r1.changed).toBeGreaterThan(0)

  ledger.stats.clear()
  const r2 = await w.scan()
  expect(r2).toEqual({ scanned: r1.scanned, changed: 0 })
  // 只有尾巴是半行的那个文件会被重新打开（offset < size，本来的语义，判 stuck 不写库），其余 stat 完就跳
  expect(sumSites(ledger, "warroom-worker fs.openSync")).toBe(1)

  appendFileSync(join(t.ccRoot, "-Users-x-p2", "cc-2-3.jsonl"), cc("cc-2-3", 3))
  ledger.stats.clear()
  const r3 = await w.scan()
  expect(r3.changed).toBe(1)
  expect(sumSites(ledger, "warroom-worker fs.openSync")).toBe(2)
  const row = reader.db.query("SELECT turns FROM sessions WHERE session_id = 'cc-2-3'").get() as { turns: number }
  expect(row.turns).toBe(3)
  expect(w.alive).toBe(true)
  reader.close()
})

test("K2：worker 里扫描失败（库开不了）→ 本轮 reject，worker 不死，主线程无未处理 rejection", async () => {
  const t = makeTree()
  const dirAsDb = join(t.root, "not-a-db")
  mkdirSync(dirAsDb)
  const w = mk({ indexer: { ...t.opts("x"), dbPath: dirAsDb } })
  await expect(w.scan()).rejects.toThrow()
  expect(w.alive).toBe(true)
  await expect(w.scan()).rejects.toThrow()
  expect(unhandled).toEqual([])
})

/// 假 worker：第一次起来收到请求就崩（marker 文件记一笔），重建后的第二个正常回包。ready=false：永远不发 ready（启动卡住）
function fixture(root: string, body: string, ready = true): string {
  const f = join(root, `fixture-${Math.random().toString(36).slice(2)}.ts`)
  writeFileSync(f, `declare var self: Worker\nimport { existsSync, writeFileSync } from "node:fs"\nself.onmessage = (ev: MessageEvent) => {\n  const req = ev.data\n  const marker = req.opts.dbPath + ".boom"\n${body}\n}\n${ready ? `postMessage({ type: "ready" })\n` : ""}`)
  return f
}
const okReply = `  postMessage({ type: "done", id: req.id, scanned: 7, changed: 0, ms: 0, block: [["warroom-worker fs.statSync x", { count: 2, totalMs: 5, maxMs: 4 }]] })`

test("K2：worker 抛未捕获异常 → 本轮失败、扔掉 worker；下一轮重建后正常；主线程不炸", async () => {
  const t = makeTree()
  const ledger = new BlockLedger(Date.now, () => {})
  const w = mk({ indexer: t.opts("w.db"), ledger, workerUrl: fixture(t.root, `  if (!existsSync(marker)) { writeFileSync(marker, "1"); throw new Error("boom") }\n${okReply}`) })
  await expect(w.scan()).rejects.toThrow(/^scan worker 出错：error: boom$/)
  expect(w.alive).toBe(false)
  expect(await w.scan()).toEqual({ scanned: 7, changed: 0 })
  expect(ledger.stats.get("warroom-worker fs.statSync x")).toEqual({ count: 2, totalMs: 5, maxMs: 4 })
  expect(unhandled).toEqual([])
})

test("K2：worker 自己退出 / 卡死超时 → 本轮失败、下一轮重建", async () => {
  const t = makeTree()
  const exiting = mk({ indexer: t.opts("a.db"), workerUrl: fixture(t.root, `  if (!existsSync(marker)) { writeFileSync(marker, "1"); process.exit(3); return }\n${okReply}`) })
  await expect(exiting.scan()).rejects.toThrow(/退出/)
  expect(await exiting.scan()).toEqual({ scanned: 7, changed: 0 })

  const hanging = mk({ indexer: t.opts("b.db"), timeoutMs: 300, workerUrl: fixture(t.root, `  if (!existsSync(marker)) { writeFileSync(marker, "1"); return }\n${okReply}`) })
  await expect(hanging.scan()).rejects.toThrow(/没回/)
  expect(hanging.alive).toBe(false)
  expect(await hanging.scan()).toEqual({ scanned: 7, changed: 0 })
  expect(unhandled).toEqual([])
})

test("K2：同一时刻只跑一轮；terminate 让在跑的一轮 reject（启动中 / 已发请求都算）", async () => {
  const t = makeTree()
  const w = mk({ indexer: t.opts("w.db"), workerUrl: fixture(t.root, "  return") })
  const first = w.scan()                                   // 还在等 ready
  await expect(w.scan()).rejects.toThrow(/上一轮/)
  w.terminate()
  await expect(first).rejects.toThrow(/终止/)
  expect(w.unavailable).toBe(false)

  const w2 = mk({ indexer: t.opts("w2.db"), workerUrl: fixture(t.root, "  return") })
  const second = w2.scan()
  await Bun.sleep(300)                                     // 已 ready、请求已发、假 worker 不回
  w2.terminate()
  await expect(second).rejects.toThrow(/终止/)
  await expect(w2.scan()).rejects.toThrow(/终止/)
  expect(unhandled).toEqual([])
})

test("K2 审查 R1-4：worker 起不来（入口不存在 / 不发 ready）连试 3 次后判不可用，之后直接 WorkerUnavailable", async () => {
  const t = makeTree()
  const logs: string[] = []
  let ready = 0
  const missing = mk({ indexer: t.opts("a.db"), workerUrl: join(t.root, "没有这个入口.ts"), startBackoffMs: 1, log: (l) => logs.push(l), onReady: () => ready++ })
  await expect(missing.scan()).rejects.toBeInstanceOf(WorkerUnavailable)
  expect(missing.unavailable).toBe(true)
  expect(logs.filter((l) => l.includes("起不来（第")).length).toBe(3)
  await expect(missing.scan()).rejects.toBeInstanceOf(WorkerUnavailable)
  expect(ready).toBe(0)

  const silent = mk({ indexer: t.opts("b.db"), workerUrl: fixture(t.root, "  return", false), readyTimeoutMs: 100, startBackoffMs: 1 })
  await expect(silent.scan()).rejects.toThrow(/连续 3 次起不来.*没就绪/)
  expect(silent.unavailable).toBe(true)
  expect(unhandled).toEqual([])
})

test("K2 审查 R1-4：普查轮遇到不可用 → 同一轮退回主线程扫描 + onFallback 一次；单轮崩溃不算不可用、onReady 只报第一次", async () => {
  const t = makeTree()
  const main = new WarroomIndexer(t.opts("main.db"))
  let mainCalls = 0, fallbacks = 0
  const scans: ScanSummary[] = []
  const warns: string[] = []
  const missing = mk({ indexer: t.opts("x.db"), workerUrl: join(t.root, "没有这个入口.ts"), startBackoffMs: 1 })
  const run = warroomScanRunner({
    scanMain: () => { mainCalls++; return main.scanAllAsync(async () => []) },
    worker: missing, load5: () => 1, onScan: (s) => scans.push(s), onFallback: () => fallbacks++, log: () => {}, warn: (l) => warns.push(l),
  })
  await run("initial")
  expect(mainCalls).toBe(1)
  expect(fallbacks).toBe(1)
  expect(scans[0].scanned).toBe(17)
  expect(warns[0]).toMatch(/退回主线程/)
  await run("incremental")
  expect(mainCalls).toBe(2)
  expect(fallbacks).toBe(1)

  let ready = 0
  const crashy = mk({ indexer: t.opts("y.db"), onReady: () => ready++, workerUrl: fixture(t.root, `  if (!existsSync(marker)) { writeFileSync(marker, "1"); throw new Error("boom") }\n${okReply}`) })
  await expect(crashy.scan()).rejects.toThrow(/boom/)
  expect(crashy.unavailable).toBe(false)
  expect(await crashy.scan()).toEqual({ scanned: 7, changed: 0 })
  expect(ready).toBe(1)
  main.close()
})

test("K2 审查 R1-4：空闲 worker 不拖住进程——扫完不 terminate，进程照样自然退出", async () => {
  const t = makeTree()
  const script = join(t.root, "natural-exit.ts")
  writeFileSync(script, `import { WarroomScanWorker } from ${JSON.stringify(join(import.meta.dir, "warroom-scan-client.ts"))}
const w = new WarroomScanWorker({ indexer: ${JSON.stringify(t.opts("n.db"))}, liveness: "none", log: () => {} })
const r = await w.scan()
console.log("scanned", r.scanned)
`)
  const p = Bun.spawn([process.execPath, script], { stdout: "pipe", stderr: "pipe" })
  const timer = setTimeout(() => p.kill(9), 15_000)
  const out = await new Response(p.stdout).text()
  const code = await p.exited
  clearTimeout(timer)
  expect(out.trim()).toBe("scanned 17")
  expect(code).toBe(0)
}, 20_000)

test("K2 开关：MP_HUB_PERF_K2=0 才关；普查轮 worker=null 走主线程扫描，有 worker 就不碰主线程", async () => {
  const saved = process.env.MP_HUB_PERF_K2
  try {
    delete process.env.MP_HUB_PERF_K2
    expect(k2Enabled()).toBe(true)
    process.env.MP_HUB_PERF_K2 = "1"
    expect(k2Enabled()).toBe(true)
    process.env.MP_HUB_PERF_K2 = "0"
    expect(k2Enabled()).toBe(false)
  } finally { if (saved === undefined) delete process.env.MP_HUB_PERF_K2; else process.env.MP_HUB_PERF_K2 = saved }

  const t = makeTree()
  const main = new WarroomIndexer(t.opts("main.db"))
  const scans: ScanSummary[] = []
  const logs: string[] = []
  let mainCalls = 0
  const off = warroomScanRunner({
    scanMain: () => { mainCalls++; return main.scanAllAsync(async () => []) },
    worker: null, load5: () => 1, onScan: (s) => scans.push(s), log: (l) => logs.push(l), warn: (l) => logs.push(l),
  })
  await off("initial")
  expect(mainCalls).toBe(1)
  expect(scans[0].scanned).toBe(3 * 4 + 2 + 3)
  expect(logs[0]).toMatch(/^\[warroom\] initial scan: 17 files, \d+ changed, \d+ms$/)

  const w = mk({ indexer: t.opts("worker.db") })
  const on = warroomScanRunner({
    scanMain: () => { mainCalls++; return main.scanAllAsync(async () => []) },
    worker: w, load5: () => 1, onScan: (s) => scans.push(s), log: (l) => logs.push(l), warn: (l) => logs.push(l),
  })
  const a = on("initial"), b = on("incremental")          // 第二个撞上 scanRunning 直接返回
  await Promise.all([a, b])
  expect(mainCalls).toBe(1)
  expect(scans.length).toBe(2)
  expect(scans[1].scanned).toBe(17)
  main.close()
})

test("普查轮：过载跳过增量（最多 30 分钟），首扫不跳；失败只记一行", async () => {
  let clock = 1_000_000
  const logs: string[] = []
  let calls = 0, failNext = false
  const run = warroomScanRunner({
    scanMain: async () => { calls++; if (failNext) throw new Error("盘坏了"); return { scanned: 1, changed: 0 } },
    worker: null, load5: () => 99, onScan: () => {}, log: (l) => logs.push(l), warn: (l) => logs.push(l), now: () => clock,
  })
  await run("initial"); expect(calls).toBe(1)
  clock += 5 * 60_000; await run("incremental"); expect(calls).toBe(1)
  clock += 26 * 60_000; failNext = true; await run("incremental"); expect(calls).toBe(2)
  expect(logs.at(-1)).toBe("[warroom] incremental scan fail: 盘坏了")
})

test("K2 审查 R1-3：主连接关了自动检查点，worker 扫描 changed=0 也回写 WAL——账本写不让 WAL 无界涨", async () => {
  const t = makeTree()
  const opts = t.opts("w.db")
  const main = new WarroomIndexer(opts)
  const ledger = new WarroomLedger(main.db)
  const w = mk({ indexer: opts, onReady: () => main.db.exec("PRAGMA wal_autocheckpoint = 0") })   // 和 hub 一样：ready 后关主连接检查点
  await w.scan()
  const walPath = `${opts.dbPath}-wal`
  const burst = () => { for (let i = 0; i < 300; i++) ledger.createRequest("x".repeat(4000)) }
  burst()
  const before = statSync(walPath).size

  const r = await w.scan()                                  // transcript 没变：changed=0，扫描本身不写库
  expect(r.changed).toBe(0)
  const cp = await w.checkpoint()
  expect(cp).not.toBeNull()
  expect(cp!.checkpointed).toBe(cp!.log)                    // 全部回写

  burst()                                                   // 同样多的账本写：复用 WAL，不再翻倍
  expect(statSync(walPath).size).toBeLessThanOrEqual(before * 1.1)
  main.close()
})

test("K2 审查 R1-3：普查轮过载跳过时只让 worker 做检查点；worker 不可用 / K2 关时不发", async () => {
  let clock = 1_000_000
  let scans = 0, checkpoints = 0
  const fake = {
    unavailable: false,
    scan: async () => { scans++; return { scanned: 1, changed: 0 } },
    checkpoint: async () => { checkpoints++; return { busy: 0, log: 0, checkpointed: 0 } },
  }
  const run = warroomScanRunner({ scanMain: async () => ({ scanned: 0, changed: 0 }), worker: fake, load5: () => 99, onScan: () => {}, log: () => {}, warn: () => {}, now: () => clock })
  await run("initial")
  expect([scans, checkpoints]).toEqual([1, 0])
  clock += 5 * 60_000; await run("incremental")
  expect([scans, checkpoints]).toEqual([1, 1])
  fake.unavailable = true
  clock += 5 * 60_000; await run("incremental")
  expect([scans, checkpoints]).toEqual([1, 1])
})
