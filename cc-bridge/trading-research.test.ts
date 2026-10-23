// 交易 T0.5：纯函数（裁决截取/质量闸/产物定位）+ pending 三件套。
// 全部走临时目录，零网络零生产资产（hub 测试隔离铁律）。
import { describe, expect, test, beforeEach, afterEach } from "bun:test"
import { mkdtempSync, rmSync, writeFileSync, utimesSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  extractDigest, reportLooksValid, findFreshReport, buildFilingAttachment,
  deliverTradingReport, pendingTradingReports, ackTradingReport,
  setTradingBroadcaster,
} from "./trading-research.ts"

const FM = "---\nticker: NVDA\ndate: 2026-08-01\nrating: Underweight\nconfidence: 65\n---\n"
const VERDICT = "\n# NVDA 研究报告\n\n## 1. 裁决摘要\n\n核心逻辑。\n"
const REST = "\n---\n\n# NVDA 基本面\n\n一大坨全文。\n\n---\n\n# 附录：辩论实录\n"

let dir: string
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "trading-test-")) })
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
  setTradingBroadcaster(null)
})

describe("extractDigest", () => {
  test("frontmatter+裁决保留，分隔符后全文剪掉", () => {
    const digest = extractDigest(FM + VERDICT + REST)
    expect(digest).toContain("rating: Underweight")
    expect(digest).toContain("裁决摘要")
    expect(digest).not.toContain("NVDA 基本面")
    expect(digest).not.toContain("辩论实录")
  })
  test("无分隔符原样返回", () => {
    expect(extractDigest(FM + VERDICT)).toBe(FM + VERDICT)
  })
  test("frontmatter 自己的 --- 不当截断点", () => {
    const digest = extractDigest(FM + VERDICT + REST)
    expect(digest).toContain("# NVDA 研究报告")
  })
  test("update 短 note 全文即 digest（正文分隔线不截断）", () => {
    const updateMd = "---\nticker: AMD\ntype: update\nrating: Underweight\n---\n\n# 复核\n\n表格\n\n---\n\n后半段核对表也要保留\n"
    const digest = extractDigest(updateMd)
    expect(digest).toContain("后半段核对表也要保留")
  })
  test("earnings note 同样全文即 digest + 质量闸放行短文", () => {
    const md = "---\nticker: AMD\ntype: earnings\nrating: Underweight\n---\n\n# 收账\n\n---\n\n收账表在此\n" + "x".repeat(900)
    expect(extractDigest(md)).toContain("收账表在此")
    expect(reportLooksValid(md)).toBe(true)
  })
})

describe("buildFilingAttachment", () => {
  test("frontmatter filing_files + manifest → base64 附件；缺清单返回 null 不炸", async () => {
    const { mkdirSync, writeFileSync } = await import("node:fs")
    const axis = mkdtempSync(join(tmpdir(), "axis-test-"))
    process.env.MP_AXISMUNDI_DIR_UNUSED = axis   // buildFilingAttachment 用常量 AXISMUNDI——测试走真目录太脏，
    // 改测负例（不炸）+ 正例逻辑由 M4 E2E 覆盖
    const md = "---\nticker: ZZZZ\ntype: earnings\nfiling_files: [ZZZZ-8-K-2099-01-01.txt]\ndata_date: 2099-01-01\n---\n"
    expect(buildFilingAttachment(md, "ZZZZ", "2099-01-01")).toBeNull()
    expect(buildFilingAttachment("---\nno filings\n---\n", "ZZZZ", "2099-01-01")).toBeNull()
    rmSync(axis, { recursive: true, force: true })
  })
})

describe("reportLooksValid", () => {
  test("有 rating 且够长 = 有效", () => {
    expect(reportLooksValid(FM + VERDICT + "x".repeat(6000))).toBe(true)
  })
  test("太短 / 无 rating 拒收", () => {
    expect(reportLooksValid(FM + "短")).toBe(false)
    expect(reportLooksValid("---\ndate: x\n---\n" + "x".repeat(6000))).toBe(false)
  })
})

describe("findFreshReport", () => {
  test("只认 since 之后的 md，取最新", () => {
    const old = join(dir, "2026-07-29-initiate.md")
    const fresh = join(dir, "2026-08-01-initiate.md")
    writeFileSync(old, "old")
    utimesSync(old, new Date(Date.now() - 3600_000), new Date(Date.now() - 3600_000))
    const since = Date.now() - 60_000
    writeFileSync(fresh, "fresh")
    expect(findFreshReport(dir, since)).toBe(fresh)
    expect(findFreshReport(dir, Date.now() + 3600_000)).toBeNull()
    expect(findFreshReport(join(dir, "nope"), 0)).toBeNull()
  })
})

describe("pending 三件套", () => {
  test("ok 报告：落盘 + 广播 + ack 删", () => {
    const frames: string[] = []
    setTradingBroadcaster((f) => frames.push(f))
    const ok = deliverTradingReport({ uuid: "u-1", symbol: "NVDA", ok: true, content: "digest" }, dir)
    expect(ok).toBe(true)
    expect(pendingTradingReports(dir).length).toBe(1)
    expect(frames.length).toBe(1)
    expect(JSON.parse(frames[0]).type).toBe("trading_report_result")
    ackTradingReport("u-1", dir)
    expect(pendingTradingReports(dir).length).toBe(0)
  })
  test("失败帧：广播但不进 pending", () => {
    const frames: string[] = []
    setTradingBroadcaster((f) => frames.push(f))
    deliverTradingReport({ uuid: "u-2", symbol: "NVDA", ok: false, error: "busy" }, dir)
    expect(frames.length).toBe(1)
    expect(pendingTradingReports(dir).length).toBe(0)
  })
  test("超大 filing 降级：不 inline + filing_too_large 标记（落盘和广播帧一致）", () => {
    const frames: string[] = []
    setTradingBroadcaster((f) => frames.push(f))
    const big = "x".repeat(33 * 1024 * 1024)
    deliverTradingReport({ uuid: "u-big", symbol: "AMD", ok: true, content: "digest",
                           filing: { filename: "f.pdf", format: "pdf", data: big } }, dir)
    const list = pendingTradingReports(dir)
    expect(list.length).toBe(1)
    expect(list[0].filing).toBeNull()
    expect(list[0].filing_too_large).toBe(true)
    expect(frames.length).toBe(1)
    const frame = JSON.parse(frames[0])
    expect(frame.filing).toBeNull()
    expect(frame.filing_too_large).toBe(true)
    expect(frames[0].length).toBeLessThan(1024 * 1024)
  })
  test("超大 pending 文件不重投，改名 .oversize 留底", () => {
    const pendingDir = join(dir, "pending-reports")
    deliverTradingReport({ uuid: "u-ok", symbol: "A", ok: true, content: "d" }, dir)
    // 直接落一个超限文件模拟历史毒丸（绕过 deliver 闸门的旧数据）
    writeFileSync(join(pendingDir, "poison.json"),
                  JSON.stringify({ uuid: "poison", ok: true, filing: { data: "y".repeat(33 * 1024 * 1024) } }))
    const list = pendingTradingReports(dir)
    expect(list.length).toBe(1)
    expect(list[0].uuid).toBe("u-ok")
    expect(existsSync(join(pendingDir, "poison.json"))).toBe(false)
    expect(existsSync(join(pendingDir, "poison.json.oversize"))).toBe(true)
    // 第二次读不再碰 .oversize
    expect(pendingTradingReports(dir).length).toBe(1)
  })
  test("坏 uuid 拒收；坏 pending 文件隔离不炸补投", () => {
    expect(deliverTradingReport({ uuid: "../evil", ok: true }, dir)).toBe(false)
    const pendingDir = join(dir, "pending-reports")
    deliverTradingReport({ uuid: "u-3", symbol: "A", ok: true }, dir)
    writeFileSync(join(pendingDir, "corrupt.json"), "{not json")
    const list = pendingTradingReports(dir)
    expect(list.length).toBe(1)
    expect(list[0].uuid).toBe("u-3")
  })
})
