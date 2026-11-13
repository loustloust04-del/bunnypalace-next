import { expect, test } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  badKey, badText, decide, DEFAULT_QUIET, expandScriptPath, ingestStatusReport, isQuietAt, isValidStatusId, listStatusReports,
  loadAlertState, loadQuiet, normalizeReport, parseQuiet, parseStatusBody, recoveredText, releaseDeferred, saveQuiet,
  statusResultFrame, StatusRunner, takeDuePushes, type AlertState, type StatusAlert, type StatusItem,
} from "./status-reports.ts"
import { deliverStatusAlert, pendingStatusAlerts } from "./status-alerts.ts"

// hub 跑在太平洋时区也必须按 quiet.tz 算
process.env.TZ = "America/Los_Angeles"

const SH = DEFAULT_QUIET
const at = (iso: string) => new Date(iso)
const empty = (): AlertState => ({ sources: {}, deferredPushes: [] })
let seq = 0
const newId = () => `id-${++seq}`
const yes = () => true
const items = (bad: string[], good: string[] = ["服务器B"]): StatusItem[] => [
  ...good.map((name) => ({ name, ok: true, detail: "" })),
  ...bad.map((name) => ({ name, ok: false, detail: "连不上" })),
]
// 北京 12:00 = 04:00Z（非静音）；北京 02:00 = 18:00Z 前一天（静音）
const DAY = at("2026-10-31T04:00:00Z")
const NIGHT = at("2026-10-30T18:00:00Z")

test("id 校验", () => {
  for (const ok of ["ladder", "a", "x_y-1", "a".repeat(32)]) expect(isValidStatusId(ok)).toBe(true)
  for (const bad of ["", "Ladder", "a b", "a/b", "..", "a".repeat(33), "梯子"]) expect(isValidStatusId(bad)).toBe(false)
})

test("body 校验：缺字段 / 坏类型都给理由", () => {
  const good = { checkedAt: "2026-10-31T19:17:42-07:00", items: [{ name: "线路A", ok: true }] }
  expect(parseStatusBody(JSON.stringify(good)).ok).toBe(true)
  const cases: unknown[] = [
    "不是 json",
    [],
    { items: good.items },
    { ...good, checkedAt: "昨天" },
    { ...good, checkedAt: "2026-13-45T99:99:99Z" },
    { ...good, items: [] },
    { ...good, items: Array.from({ length: 101 }, (_, i) => ({ name: `n${i}`, ok: true })) },
    { ...good, items: [{ ok: true }] },
    { ...good, items: [{ name: "  ", ok: true }] },
    { ...good, items: [{ name: "x", ok: "yes" }] },
    { ...good, items: [{ name: "x", ok: true, detail: 3 }] },
    { ...good, title: 5 },
    { ...good, staleAfterHours: -1 },
    { ...good, staleAfterHours: "36" },
  ]
  for (const c of cases) {
    const r = parseStatusBody(typeof c === "string" ? c : JSON.stringify(c))
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason.length).toBeGreaterThan(0)
  }
})

test("body 规范化：allOk 忽略、长度截断、detail 缺省空串、100 项正好可以", () => {
  const r = parseStatusBody(JSON.stringify({
    checkedAt: "2026-10-31T19:17:42-07:00", allOk: true,
    items: [{ name: "名".repeat(90), ok: false, detail: "细".repeat(400) }, { name: "服务器B", ok: true }],
  }))
  expect(r.ok).toBe(true)
  if (!r.ok) return
  expect(Array.from(r.body.items[0].name).length).toBe(80)
  expect(Array.from(r.body.items[0].detail).length).toBe(300)
  expect(r.body.items[1].detail).toBe("")
  expect(badKey(r.body.items)).toBe("名".repeat(80))
  const hundred = parseStatusBody(JSON.stringify({ checkedAt: "2026-10-31T00:00:00Z", items: Array.from({ length: 100 }, (_, i) => ({ name: `n${i}`, ok: true })) }))
  expect(hundred.ok).toBe(true)
})

test("标题优先级：配置 title > body title > id；staleAfterHours 配置 > body > 36；时间统一成 UTC 秒", () => {
  const body = { title: "报上来的", checkedAt: "2026-10-31T19:17:42.123-07:00", items: items([]) }
  const now = at("2026-11-01T02:20:00.456Z")
  expect(normalizeReport("ladder", body, { title: "梯子", staleAfterHours: 12 }, now)).toEqual({
    id: "ladder", title: "梯子", checkedAt: "2026-11-01T02:17:42Z", staleAfterHours: 12, items: body.items, receivedAt: "2026-11-01T02:20:00Z",
  })
  expect(normalizeReport("ladder", { ...body, staleAfterHours: 48 }, {}, now)).toMatchObject({ title: "报上来的", staleAfterHours: 48 })
  expect(normalizeReport("ladder", { checkedAt: body.checkedAt, items: body.items }, undefined, now)).toMatchObject({ title: "ladder", staleAfterHours: 36 })
})

test("坏项 key：只看名字、排序后 \\n 拼；全绿是空串", () => {
  expect(badKey(items(["线路B", "线路A"]))).toBe("线路A\n线路B")
  expect(badKey([{ name: "线路A", ok: false, detail: "证书剩 63 天" }])).toBe(badKey([{ name: "线路A", ok: false, detail: "证书剩 62 天" }]))
  expect(badKey(items([]))).toBe("")
})

test("文案：前 3 个名字用、连，超过 3 个加「等」", () => {
  expect(badText("梯子", ["线路A", "服务器B"])).toBe("梯子掉了 2 颗：线路A、服务器B。点我看原因。")
  expect(badText("梯子", ["a", "b", "c"])).toBe("梯子掉了 3 颗：a、b、c。点我看原因。")
  expect(badText("梯子", ["a", "b", "c", "d"])).toBe("梯子掉了 4 颗：a、b、c等。点我看原因。")
  expect(recoveredText("梯子", 2)).toBe("梯子又串满了，刚才那 2 条都通了。")
})

test("静音边界（tz=Asia/Shanghai，跨午夜 23:30–08:30）：23:29 否 / 23:30 是 / 08:29 是 / 08:30 否", () => {
  expect(isQuietAt(at("2026-10-31T15:29:00Z"), SH)).toBe(false)
  expect(isQuietAt(at("2026-10-31T15:30:00Z"), SH)).toBe(true)
  expect(isQuietAt(at("2026-10-31T00:29:59Z"), SH)).toBe(true)
  expect(isQuietAt(at("2026-10-31T00:30:00Z"), SH)).toBe(false)
  expect(isQuietAt(at("2026-10-31T19:00:00Z"), SH)).toBe(true)    // 北京 03:00
  expect(isQuietAt(DAY, SH)).toBe(false)
  // 同一瞬间换个 tz 结论就变：不是按 hub 本机时区
  expect(isQuietAt(at("2026-10-31T15:30:00Z"), { ...SH, tz: "UTC" })).toBe(false)
  // 不跨午夜的区间；start == end = 没有静音
  const day = { start: "12:00", end: "13:00", tz: "Asia/Shanghai" }
  expect(isQuietAt(at("2026-10-31T03:59:00Z"), day)).toBe(false)
  expect(isQuietAt(at("2026-10-31T04:00:00Z"), day)).toBe(true)
  expect(isQuietAt(at("2026-10-31T05:00:00Z"), day)).toBe(false)
  expect(isQuietAt(DAY, { start: "08:00", end: "08:00", tz: "UTC" })).toBe(false)
})

test("静音配置解析：坏时间 / 坏时区不认", () => {
  expect(parseQuiet({ start: "23:30", end: "08:30", tz: "Asia/Shanghai" })).toEqual(SH)
  expect(parseQuiet({ start: "24:00", end: "08:30", tz: "Asia/Shanghai" })).toBeNull()
  expect(parseQuiet({ start: "23:30", end: "8:30", tz: "Asia/Shanghai" })).toBeNull()
  expect(parseQuiet({ start: "23:30", end: "08:30", tz: "Mars/Olympus" })).toBeNull()
  expect(parseQuiet(null)).toBeNull()
})

test("decide：首次坏 → bad + 立刻推；同组 24h 内不再喊；24h 后再喊；坏项变了再喊", () => {
  const first = decide({ state: empty(), source: "ladder", title: "梯子", items: items(["线路A"]), now: DAY, quiet: SH, newId })
  expect(first.alert).toMatchObject({ source: "ladder", title: "梯子", kind: "bad", names: ["线路A"], text: "梯子掉了 1 颗：线路A。点我看原因。", createdAt: "2026-10-31T04:00:00Z" })
  expect(first.push).toEqual({ alertId: first.alert!.id, source: "ladder", kind: "bad", text: first.alert!.text })
  expect(first.state.sources.ladder).toEqual({ notifiedKey: "线路A", notifiedAt: "2026-10-31T04:00:00Z", notifiedBad: true, lastAlertId: first.alert!.id })

  const again = decide({ state: first.state, source: "ladder", title: "梯子", items: items(["线路A"]), now: at("2026-11-01T03:59:59Z"), quiet: SH, newId })
  expect(again).toEqual({ state: first.state, alert: null, push: null })

  const later = decide({ state: first.state, source: "ladder", title: "梯子", items: items(["线路A"]), now: at("2026-11-01T04:00:00Z"), quiet: SH, newId })
  expect(later.alert?.kind).toBe("bad")
  expect(later.state.sources.ladder.notifiedAt).toBe("2026-11-01T04:00:00Z")

  const changed = decide({ state: first.state, source: "ladder", title: "梯子", items: items(["线路A", "服务器C"]), now: at("2026-10-31T05:00:00Z"), quiet: SH, newId })
  expect(changed.alert).toMatchObject({ kind: "bad", names: ["线路A", "服务器C"] })
  expect(changed.state.sources.ladder.notifiedKey).toBe("服务器C\n线路A")
})

test("decide：全绿且喊过坏 → recovered；没喊过坏的全绿什么都不发；入参 state 不被改", () => {
  const bad = decide({ state: empty(), source: "ladder", title: "梯子", items: items(["线路A", "服务器C"]), now: DAY, quiet: SH, newId })
  const snapshot = JSON.stringify(bad.state)
  const ok = decide({ state: bad.state, source: "ladder", title: "梯子", items: items([]), now: at("2026-10-31T05:00:00Z"), quiet: SH, newId })
  expect(ok.alert).toMatchObject({ kind: "recovered", names: ["服务器C", "线路A"], text: "梯子又串满了，刚才那 2 条都通了。" })
  expect(ok.push?.kind).toBe("recovered")
  expect(ok.state.sources.ladder).toMatchObject({ notifiedKey: "", notifiedBad: false, lastAlertId: ok.alert!.id })
  expect(JSON.stringify(bad.state)).toBe(snapshot)

  const quietGreen = decide({ state: ok.state, source: "ladder", title: "梯子", items: items([]), now: at("2026-10-31T06:00:00Z"), quiet: SH, newId })
  expect(quietGreen.alert).toBeNull()
  expect(decide({ state: empty(), source: "ladder", title: "梯子", items: items([]), now: DAY, quiet: SH, newId }).alert).toBeNull()

  // 恢复后再坏（同一组）→ key 变了（"" → 线路A），照喊
  const reBad = decide({ state: ok.state, source: "ladder", title: "梯子", items: items(["线路A"]), now: at("2026-10-31T07:00:00Z"), quiet: SH, newId })
  expect(reBad.alert?.kind).toBe("bad")
})

test("decide：静音中坏了 → 横幅照出、推送进 deferredPushes；出静音补推", () => {
  const r = decide({ state: empty(), source: "ladder", title: "梯子", items: items(["线路A"]), now: NIGHT, quiet: SH, newId })
  expect(r.alert?.kind).toBe("bad")
  expect(r.push).toBeNull()
  expect(r.state.deferredPushes).toEqual([{ alertId: r.alert!.id, source: "ladder", kind: "bad", text: r.alert!.text }])

  expect(releaseDeferred(r.state, at("2026-10-31T00:29:00Z"), SH).pushes).toEqual([])   // 北京 08:29 还在静音
  const out = releaseDeferred(r.state, at("2026-10-31T00:30:00Z"), SH)
  expect(out.pushes.map((p) => p.alertId)).toEqual([r.alert!.id])
  expect(out.state.deferredPushes).toEqual([])
})

test("decide：静音中坏了又好了 → recovered 只挂横幅，同源未推的 bad 推送撤掉；别的源的延后推送不动", () => {
  const other = decide({ state: empty(), source: "nas", title: "NAS", items: items(["硬盘1"]), now: NIGHT, quiet: SH, newId })
  const bad = decide({ state: other.state, source: "ladder", title: "梯子", items: items(["线路A"]), now: NIGHT, quiet: SH, newId })
  expect(bad.state.deferredPushes.map((p) => p.source)).toEqual(["nas", "ladder"])
  const ok = decide({ state: bad.state, source: "ladder", title: "梯子", items: items([]), now: at("2026-10-30T19:00:00Z"), quiet: SH, newId })
  expect(ok.alert?.kind).toBe("recovered")
  expect(ok.push).toBeNull()
  expect(ok.state.deferredPushes.map((p) => p.source)).toEqual(["nas"])
  // 白天恢复（bad 早推出去了）→ recovered 照推
  const dayBad = decide({ state: empty(), source: "ladder", title: "梯子", items: items(["线路A"]), now: DAY, quiet: SH, newId })
  const dayOk = decide({ state: dayBad.state, source: "ladder", title: "梯子", items: items([]), now: at("2026-10-31T05:00:00Z"), quiet: SH, newId })
  expect(dayOk.push?.kind).toBe("recovered")
})

test("decide：静音中同源坏项又变了 → 延后队列里只留最新那条", () => {
  const a = decide({ state: empty(), source: "ladder", title: "梯子", items: items(["线路A"]), now: NIGHT, quiet: SH, newId })
  const b = decide({ state: a.state, source: "ladder", title: "梯子", items: items(["线路A", "服务器C"]), now: at("2026-10-30T19:00:00Z"), quiet: SH, newId })
  expect(b.state.deferredPushes.map((p) => p.alertId)).toEqual([b.alert!.id])
})

test("ingestStatusReport：落盘 + 判定 + 重报不重复；takeDuePushes 出静音才放", () => {
  const dir = mkdtempSync(join(tmpdir(), "status-reports-test-"))
  writeFileSync(join(dir, "status-sources.json"), JSON.stringify({ ladder: { title: "梯子", run: "~/x.sh" }, "Bad Id": { title: "x" } }))
  const body = JSON.stringify({ title: "body 标题", checkedAt: "2026-10-31T02:00:00Z", items: items(["线路A"]) })
  expect(ingestStatusReport("../evil", body, yes, NIGHT, dir)).toMatchObject({ ok: false })
  expect(ingestStatusReport("ladder", "{}", yes, NIGHT, dir)).toMatchObject({ ok: false })
  expect(existsSync(join(dir, "status", "ladder.json"))).toBe(false)

  const r = ingestStatusReport("ladder", body, yes, NIGHT, dir)
  expect(r).toMatchObject({ ok: true, alert: { kind: "bad", title: "梯子" }, push: null })
  expect(JSON.parse(readFileSync(join(dir, "status", "ladder.json"), "utf8"))).toMatchObject({ id: "ladder", title: "梯子", staleAfterHours: 36 })
  expect(loadAlertState(dir).deferredPushes.length).toBe(1)
  expect(ingestStatusReport("ladder", body, yes, NIGHT, dir)).toEqual({ ok: true, alert: null, push: null })

  expect(takeDuePushes(NIGHT, dir)).toEqual([])
  expect(takeDuePushes(DAY, dir).length).toBe(1)
  expect(takeDuePushes(DAY, dir)).toEqual([])

  const frame = statusResultFrame((id) => id === "ladder", dir)
  expect(frame.type).toBe("status_result")
  expect(frame.quiet).toEqual(DEFAULT_QUIET)
  expect(frame.sources).toEqual([{ ...listStatusReports(dir)[0], canRun: true, running: true }])
  saveQuiet({ start: "22:00", end: "07:00", tz: "Europe/London" }, dir)
  expect(loadQuiet(dir)).toEqual({ start: "22:00", end: "07:00", tz: "Europe/London" })
})

test("脚本路径展开：~ 展开、相对路径不收", () => {
  expect(expandScriptPath("~/a/b.sh", "/Users/x")).toBe("/Users/x/a/b.sh")
  expect(expandScriptPath("/opt/a.sh", "/Users/x")).toBe("/opt/a.sh")
  expect(expandScriptPath("a.sh", "/Users/x")).toBeNull()
  expect(expandScriptPath("~user/a.sh", "/Users/x")).toBeNull()
})

async function until(cond: () => boolean, ms = 5_000): Promise<void> {
  const deadline = Date.now() + ms
  while (!cond()) {
    if (Date.now() > deadline) throw new Error("等超时")
    await new Promise((r) => setTimeout(r, 20))
  }
}

test("StatusRunner：只跑配了 run 的；正在跑忽略；跑完 running 翻回；超时 kill", async () => {
  const dir = mkdtempSync(join(tmpdir(), "status-runner-test-"))
  const quick = join(dir, "quick.sh")
  const slow = join(dir, "slow.sh")
  const mark = join(dir, "ran")
  writeFileSync(quick, `sleep 0.2\necho ok > "${mark}"\n`)
  writeFileSync(slow, "sleep 30\n")
  writeFileSync(join(dir, "status-sources.json"), JSON.stringify({ quick: { run: quick }, slow: { run: slow }, norun: { title: "x" } }))
  const changes: string[] = []
  const runner = new StatusRunner(() => changes.push(`${runner.isRunning("quick")}/${runner.isRunning("slow")}`), 300, () => dir)

  expect(runner.run("norun")).toBe(false)
  expect(runner.run("missing")).toBe(false)
  expect(runner.run("quick")).toBe(true)
  expect(runner.isRunning("quick")).toBe(true)
  expect(runner.run("quick")).toBe(false)
  await until(() => !runner.isRunning("quick"))
  expect(existsSync(mark)).toBe(true)
  expect(changes).toEqual(["true/false", "false/false"])

  const t0 = Date.now()
  expect(runner.run("slow")).toBe(true)
  await until(() => !runner.isRunning("slow"))
  expect(Date.now() - t0).toBeLessThan(5_000)
})

test("body 规范化：name 里的 \\r \\n 换成空格，key 不会和多项拼接撞车", () => {
  const r = parseStatusBody(JSON.stringify({ checkedAt: "2026-10-31T00:00:00Z", items: [{ name: "线路A\n服务器B\r", ok: false }] }))
  expect(r.ok).toBe(true)
  if (!r.ok) return
  expect(r.body.items[0].name).toBe("线路A 服务器B")
  expect(badKey(r.body.items)).not.toBe(badKey(items(["线路A", "服务器B"], [])))
})

test("decide：非静音立刻推时，撤掉同源旧的延后推送（别的源不动）", () => {
  const other = decide({ state: empty(), source: "nas", title: "NAS", items: items(["硬盘1"]), now: NIGHT, quiet: SH, newId })
  const night = decide({ state: other.state, source: "ladder", title: "梯子", items: items(["线路A"]), now: NIGHT, quiet: SH, newId })
  expect(night.state.deferredPushes.map((p) => p.source)).toEqual(["nas", "ladder"])
  const day = decide({ state: night.state, source: "ladder", title: "梯子", items: items(["线路A", "服务器C"]), now: DAY, quiet: SH, newId })
  expect(day.push?.alertId).toBe(day.alert!.id)
  expect(day.state.deferredPushes.map((p) => p.source)).toEqual(["nas"])
  // 延后的是 recovered，白天又坏了 → 推 bad，撤掉那条 recovered
  const b = decide({ state: empty(), source: "ladder", title: "梯子", items: items(["线路A"]), now: DAY, quiet: SH, newId })
  const rec = decide({ state: b.state, source: "ladder", title: "梯子", items: items([]), now: NIGHT, quiet: SH, newId })
  expect(rec.state.deferredPushes.map((p) => p.kind)).toEqual(["recovered"])
  const again = decide({ state: rec.state, source: "ladder", title: "梯子", items: items(["线路A"]), now: at("2026-10-31T05:00:00Z"), quiet: SH, newId })
  expect(again.push?.kind).toBe("bad")
  expect(again.state.deferredPushes).toEqual([])
})

test("ingestStatusReport：投递失败（返回 false / 抛错）→ alert null、不推、不落已通知；下次报告照样喊", () => {
  const dir = mkdtempSync(join(tmpdir(), "status-ingest-fail-"))
  const body = JSON.stringify({ checkedAt: "2026-10-31T02:00:00Z", items: items(["线路A"]) })
  const tried: string[] = []
  expect(ingestStatusReport("ladder", body, (a) => { tried.push(a.kind); return false }, DAY, dir)).toEqual({ ok: true, alert: null, push: null })
  expect(ingestStatusReport("ladder", body, () => { throw new Error("磁盘满") }, DAY, dir)).toEqual({ ok: true, alert: null, push: null })
  expect(tried).toEqual(["bad"])
  expect(existsSync(join(dir, "status", "ladder.json"))).toBe(true)
  expect(loadAlertState(dir)).toEqual({ sources: {}, deferredPushes: [] })
  const ok = ingestStatusReport("ladder", body, yes, DAY, dir)
  expect(ok).toMatchObject({ ok: true, alert: { kind: "bad" }, push: { kind: "bad" } })
  expect(loadAlertState(dir).sources.ladder.notifiedBad).toBe(true)
})

const alertOf = (id: string, source: string, createdAt = "2026-10-31T04:00:00Z"): StatusAlert =>
  ({ id, source, title: source, kind: "bad", text: "x", names: ["线路A"], createdAt })

test("deliverStatusAlert：原子写 pending；同源只留最新，别的源不动；写不进去返回 false", () => {
  const dir = mkdtempSync(join(tmpdir(), "status-deliver-"))
  expect(deliverStatusAlert(alertOf("a1", "ladder", "2026-10-31T04:00:00Z"), dir)).toBe(true)
  expect(deliverStatusAlert(alertOf("n1", "nas", "2026-10-31T04:00:01Z"), dir)).toBe(true)
  expect(deliverStatusAlert(alertOf("a2", "ladder", "2026-10-31T04:00:02Z"), dir)).toBe(true)
  expect(pendingStatusAlerts(dir).map((a) => a.id)).toEqual(["n1", "a2"])
  expect(readdirSync(join(dir, "pending-status-alerts")).sort()).toEqual(["a2.json", "n1.json"])

  const blocked = mkdtempSync(join(tmpdir(), "status-deliver-blocked-"))
  writeFileSync(join(blocked, "pending-status-alerts"), "我是个文件")
  expect(deliverStatusAlert(alertOf("b1", "ladder"), blocked)).toBe(false)
  expect(deliverStatusAlert(alertOf("../x", "ladder"), dir)).toBe(false)
})

test("pendingStatusAlerts：null / 坏 JSON / 结构不对 / 文件名对不上一律删掉跳过，不抛", () => {
  const dir = mkdtempSync(join(tmpdir(), "status-pending-bad-"))
  expect(pendingStatusAlerts(dir)).toEqual([])
  const p = join(dir, "pending-status-alerts")
  mkdirSync(p)
  const good = alertOf("ok1", "ladder")
  writeFileSync(join(p, "ok1.json"), JSON.stringify(good))
  writeFileSync(join(p, "null.json"), "null")
  writeFileSync(join(p, "broken.json"), "{坏")
  writeFileSync(join(p, "nokind.json"), JSON.stringify({ ...good, id: "nokind", kind: undefined }))
  writeFileSync(join(p, "weird.json"), JSON.stringify({ ...good, id: "weird", kind: "meh" }))
  writeFileSync(join(p, "notext.json"), JSON.stringify({ ...good, id: "notext", text: 3 }))
  writeFileSync(join(p, "badnames.json"), JSON.stringify({ ...good, id: "badnames", names: [1] }))
  writeFileSync(join(p, "mismatch.json"), JSON.stringify({ ...good, id: "other" }))
  writeFileSync(join(p, "readme.txt"), "不是 json 后缀，不管")
  expect(pendingStatusAlerts(dir)).toEqual([good])
  expect(readdirSync(p).sort()).toEqual(["ok1.json", "readme.txt"])
})
