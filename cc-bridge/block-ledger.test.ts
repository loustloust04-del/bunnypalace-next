import { expect, test } from "bun:test"
import { Database } from "bun:sqlite"
import { mkdtempSync, statSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { BlockLedger, describeLagVitals, execSite, fsSite, HANDLER_MS, MAX_SITES, OTHER_SITE, procSample, sqlVerb, timedExecFileSync, timedFs, timedSyncFs, timeHandler, timeSqlite, wsSite } from "./block-ledger.ts"

test("BlockLedger：累计 / 慢调用进环 / 卡顿归因 + 其余", () => {
  let clock = 10_000
  const lines: string[] = []
  const b = new BlockLedger(() => clock, (l) => lines.push(l))
  b.record("tmux send-keys", 5)            // 快：只累计
  clock = 11_000; b.record("tmux send-keys", 600)   // 慢 + 打日志
  clock = 11_500; b.record("fs.statSync a.jsonl", 300)
  expect(b.stats.get("tmux send-keys")).toEqual({ count: 2, totalMs: 605, maxMs: 600 })
  expect(lines).toEqual(["[block] tmux send-keys 600ms"])
  // 卡顿 [10_000, 12_000]：tmux 600 + stat 300，其余 1100
  expect(b.explainLag(12_000, 2_000)).toBe("其中 tmux send-keys 600ms、fs.statSync a.jsonl 300ms；其余 1100ms（GC / 换页 / JS）")
  expect(b.explainLag(20_000, 1_000)).toBe("其余 1000ms（GC / 换页 / JS）")
  expect(b.top(1)[0][0]).toBe("tmux send-keys")
})

test("time() 异常照抛也记账", () => {
  const b = new BlockLedger()
  expect(() => b.time("x", () => { throw new Error("boom") })).toThrow("boom")
  expect(b.stats.get("x")?.count).toBe(1)
})

test("调用点标签：uuid / 长数字归类", () => {
  expect(execSite("tmux", ["send-keys", "-t", "a"])).toBe("tmux send-keys")
  expect(fsSite("statSync", "/x/658e8c83-668f-4d4f-8abf-7c4741c726dc.jsonl")).toBe("fs.statSync *.jsonl")
  expect(fsSite("readFileSync", "/tmp/session-map.json")).toBe("fs.readFileSync session-map.json")
  expect(fsSite("readSync", 23)).toBe("fs.readSync fd")
})

test("站点名归一 + 累计表有上限（审查 R1-5）：原子写临时文件 / 时间戳 / hex 后缀不再每次新增键", () => {
  expect(fsSite("writeFileSync", "/s/hub-config.json.tmp-12345-a1b2c3d4e5f6")).toBe("fs.writeFileSync hub-config.json.tmp-*")
  expect(fsSite("renameSync", "/s/x.json.tmp.9f8e7d")).toBe("fs.renameSync x.json.tmp-*")
  expect(fsSite("readFileSync", "/s/1759912345678-3f2a1b4c-5d6.json")).toBe("fs.readFileSync *-*-5d6.json")
  expect(fsSite("statSync", "/c/rollout-2026-10-10T12-30-45-658e8c83-668f-4d4f-8abf-7c4741c726dc.jsonl")).toBe("fs.statSync rollout-*.jsonl")
  expect(fsSite("readFileSync", "/s/session-map.json")).toBe("fs.readFileSync session-map.json")
  // 真走 saveJsonPrivate 那种「写临时 → chmod → rename」100 次：键数不涨
  const b = new BlockLedger(() => 0, () => {})
  const dir = mkdtempSync(join(tmpdir(), "cc-bridge-bl-"))
  const fs = timedSyncFs("hub-config ", b)
  const p = join(dir, "hub-config.json")
  fs.writeFileSync(p, "{}")
  const before = b.stats.size
  for (let i = 0; i < 100; i++) {
    const tmp = `${p}.tmp-${process.pid}-${Math.random().toString(16).slice(2, 14).padEnd(12, "0")}`
    fs.writeFileSync(tmp, "{}"); fs.chmodSync(tmp, 0o600); fs.renameSync(tmp, p)
  }
  expect(b.stats.size - before).toBe(3)
  expect(b.stats.get("hub-config fs.renameSync hub-config.json.tmp-*")?.count).toBe(100)
  // 上限：新站点超出并进「其他」，已有的照常累计
  const c = new BlockLedger(() => 0, () => {})
  for (let i = 0; i < MAX_SITES + 50; i++) c.record(`site-${i}`, 1)
  c.record("site-0", 1)
  expect(c.stats.size).toBe(MAX_SITES)
  expect(c.stats.get(OTHER_SITE)?.count).toBe(51)
  expect(c.stats.get("site-0")?.count).toBe(2)
})

test("卡顿归因：重叠的记账（ws 处理里套着 fs 调用）其余按并集算，不重复扣", () => {
  let clock = 0
  const b = new BlockLedger(() => clock, () => {})
  clock = 1_000; b.record("fs.readFileSync a.json", 300)     // [700, 1000]
  clock = 1_200; b.record("ws client_info", 800)              // [400, 1200]，包住上面那个
  clock = 1_900; b.record("sqlite agora SELECT rooms", 100)   // [1800, 1900]
  expect(b.covered(0, 2_000)).toBe(900)
  expect(b.explainLag(2_000, 2_000)).toBe("其中 ws client_info 800ms、fs.readFileSync a.json 300ms、sqlite agora SELECT rooms 100ms；其余 1100ms（GC / 换页 / JS）")
})

test("timedFs / timedSyncFs：模块前缀进站点名，行为和返回值不变，异常照抛", () => {
  const b = new BlockLedger(() => 0, () => {})
  const dir = mkdtempSync(join(tmpdir(), "cc-bridge-bl-"))
  const fs = timedSyncFs("warroom ", b)
  fs.writeFileSync(join(dir, "x.json"), "hi")
  expect(fs.readFileSync(join(dir, "x.json"), "utf8")).toBe("hi")
  expect(fs.existsSync(join(dir, "nope"))).toBe(false)
  expect(() => fs.readFileSync(join(dir, "nope"))).toThrow()
  expect(b.stats.get("warroom fs.readFileSync x.json")?.count).toBe(1)
  expect(b.stats.get("warroom fs.readFileSync nope")?.count).toBe(1)
  const stat = timedFs("statSync", statSync, "", b)
  expect(stat(dir).isDirectory()).toBe(true)
  expect([...b.stats.keys()]).toContain(`fs.statSync ${dir.slice(dir.lastIndexOf("/") + 1)}`)
  const exec = timedExecFileSync("x ", b)
  expect(exec("echo", ["hi"]).toString()).toBe("hi\n")
  expect(b.stats.get("x echo hi")?.count).toBe(1)
})

test("timeSqlite：语句 / exec / run 计时，按动作 + 表归类，缓存的语句只包一次，结果不变", () => {
  const b = new BlockLedger(() => 0, () => {})
  const db = timeSqlite(new Database(":memory:"), "agora", b)
  expect(timeSqlite(db, "agora", b)).toBe(db)
  db.exec("CREATE TABLE t(a INTEGER)")
  db.run("INSERT INTO t VALUES (1)")
  const ins = db.query("INSERT INTO t VALUES (?)")
  ins.run(2); db.query("INSERT INTO t VALUES (?)").run(3)
  expect(db.query("SELECT a FROM t ORDER BY a").all()).toEqual([{ a: 1 }, { a: 2 }, { a: 3 }])
  expect(db.prepare("SELECT COUNT(*) AS n FROM t").get()).toEqual({ n: 3 })
  db.exec("BEGIN"); db.query("UPDATE t SET a = a + 1").run(); db.exec("COMMIT")
  expect(b.stats.get("sqlite agora CREATE")?.count).toBe(1)
  expect(b.stats.get("sqlite agora INSERT t")?.count).toBe(3)
  expect(b.stats.get("sqlite agora SELECT t")?.count).toBe(2)
  expect(b.stats.get("sqlite agora UPDATE t")?.count).toBe(1)
  expect(b.stats.get("sqlite agora BEGIN")?.count).toBe(1)
  expect(() => db.query("SELECT * FROM nope").all()).toThrow()
  expect(sqlVerb("  insert or replace into foo(a) values (1)")).toBe("INSERT foo")
  expect(sqlVerb("DELETE FROM \"bar\" WHERE x")).toBe("DELETE bar")
  expect(sqlVerb("WITH r AS (SELECT 1) SELECT * FROM r")).toBe("SELECT r")
  expect(sqlVerb("PRAGMA journal_mode=WAL")).toBe("PRAGMA")
})

test("timeHandler：只量同步段，≥ 阈值才记，站点名处理完再取；wsSite 收紧客户端给的名字", async () => {
  const b = new BlockLedger(() => 0, () => {})
  let type = "?"
  const busy = (ms: number) => { const t = performance.now(); while (performance.now() - t < ms) {} }
  timeHandler(() => wsSite("ws", type), () => { type = "client_info"; busy(60) }, HANDLER_MS, b)
  timeHandler(() => wsSite("ws", type), () => { type = "focus" }, HANDLER_MS, b)
  const p = timeHandler(() => wsSite("ws", "replay"), async () => { await new Promise((r) => setTimeout(r, 80)) }, HANDLER_MS, b)
  await p
  expect([...b.stats.keys()]).toEqual(["ws client_info"])
  expect(() => timeHandler(() => "x", () => { busy(55); throw new Error("boom") }, HANDLER_MS, b)).toThrow("boom")
  expect(b.stats.get("x")?.count).toBe(1)
  expect(wsSite("ws", "set_cc_config")).toBe("ws set_cc_config")
  expect(wsSite("ws connect", "/cc")).toBe("ws connect /cc")
  expect(wsSite("ws", "a b")).toBe("ws ?")
  expect(wsSite("ws", 42)).toBe("ws ?")
  expect(wsSite("ws", "x".repeat(41))).toBe("ws ?")
})

test("卡顿体征：CPU / 硬缺页 / 堆掉没掉 / 切换 / 软缺页", () => {
  const prev = { cpuMs: 1_000, majorFaults: 10, heapMB: 180.2, rssMB: 300, switches: 500, minorFaults: 20_000 }
  expect(describeLagVitals(prev, { cpuMs: 1_800, majorFaults: 3410, heapMB: 95.4, rssMB: 140.6, switches: 1_400, minorFaults: 21_200 }, 5_662))
    .toBe("CPU 800ms/5662ms、硬缺页 +3400、堆 180→95MB（回收过）、rss 141MB、切换 +900、软缺页 +1200")
  expect(describeLagVitals(prev, { cpuMs: 1_100, majorFaults: 10, heapMB: 181, rssMB: 300, switches: 503, minorFaults: 20_000 }, 1_500))
    .toBe("CPU 100ms/1500ms、硬缺页 +0、堆 180→181MB、rss 300MB、切换 +3、软缺页 +0")
  const s = procSample()
  expect(s.cpuMs).toBeGreaterThan(0)
  expect(s.rssMB).toBeGreaterThan(1)
  expect(s.switches).toBeGreaterThan(0)
  expect(s.minorFaults).toBeGreaterThan(0)
})

test("mergeStats（K2）：别的线程送回的累计并进累计表，不进近期环、不算进卡顿归因", () => {
  let clock = 10_000
  const lines: string[] = []
  const b = new BlockLedger(() => clock, (l) => lines.push(l))
  b.record("warroom-worker fs.statSync *.jsonl", 10)
  b.mergeStats([["warroom-worker fs.statSync *.jsonl", { count: 3, totalMs: 900, maxMs: 700 }], ["sqlite warroom-worker COMMIT", { count: 1, totalMs: 40, maxMs: 40 }]])
  expect(b.stats.get("warroom-worker fs.statSync *.jsonl")).toEqual({ count: 4, totalMs: 910, maxMs: 700 })
  expect(b.stats.get("sqlite warroom-worker COMMIT")).toEqual({ count: 1, totalMs: 40, maxMs: 40 })
  expect(lines).toEqual([])
  clock = 11_000
  expect(b.explainLag(11_000, 1_000)).toBe("其余 1000ms（GC / 换页 / JS）")
})
