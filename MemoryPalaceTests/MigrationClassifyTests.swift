import XCTest
@testable import 记忆花园

/// plan-memory-migrate-3gen M1 / M2：三代各长什么样 → 分哪类；A2 要补哪几截（纯函数，不读盘）
final class MigrationClassifyTests: XCTestCase {

    private let cal = Calendar.current
    private var scope: Date { date(10, 1, 5) }

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    private func msgs(_ n: Int, from start: Date, prefix: String = "n") -> [SessionSegmentWriter.Message] {
        (0..<n).map { .init(id: "\(prefix)\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "第\($0)条",
                            date: start.addingTimeInterval(TimeInterval($0) * 60)) }
    }

    private func seg(_ kind: SessionSegment.Kind, _ m: [SessionSegmentWriter.Message], _ r: Range<Int>, pending: String = "",
                     tail: Bool = false) -> SessionSegment {
        SessionSegment(kind: kind, title: "\(kind)", start: m[r.lowerBound].date!, end: m[r.upperBound - 1].date!, from: r.lowerBound,
                       to: r.upperBound, lastNodeId: m[r.upperBound - 1].id, story: "经过", quotes: "", pending: pending, isTail: tail)
    }

    private func summary(_ segs: [SessionSegment], compressed: Int = 0, closed: String? = nil) -> SessionSummary {
        SessionSummary(conversationId: "c", title: "t", compressedCount: compressed, segments: segs, updatedAt: date(10, 9, 0), closedThrough: closed)
    }

    private func legacy(to n: Int) -> SessionSegment {
        SessionSegment(kind: .legacy, title: "改造前的累计摘要", start: date(9, 20, 0), end: date(9, 20, 0), from: 0, to: n,
                       lastNodeId: nil, story: "老摘要", quotes: "", pending: "")
    }

    private func classify(_ a2: [SessionSegment], onDisk: Bool = true, a3: SessionSummary? = nil,
                          _ m: [SessionSegmentWriter.Message]) -> MemoryMigration.Plan? {
        MemoryMigration.classify(.init(a2: summary(a2), a2OnDisk: onDisk, a3: a3), messages: m, scope: scope)
    }

    /// 第一代：起点以前、只有 summaries/ → 只落第 0 段；起点以前已经有 sessions/ 的 → 不在范围
    func testBeforeStartOnlySeed() {
        let old = msgs(10, from: date(9, 20, 9))
        XCTAssertEqual(classify([legacy(to: 10)], onDisk: false, old), .init(kind: .seedOnly))
        XCTAssertNil(classify([legacy(to: 10)], onDisk: true, old), "起点以前一个字不改")
        XCTAssertNil(classify([], onDisk: false, old))
    }

    /// 第一代、起点以后还在聊：第 0 段 + 尾段 + A3（时间轴不在搬迁里补）
    func testSeedWindowAfterStartIsTailA3() {
        let m = msgs(10, from: date(9, 20, 9)) + msgs(20, from: date(10, 5, 9), prefix: "p")
        XCTAssertEqual(classify([legacy(to: 10)], onDisk: false, m), .init(kind: .tailA3))
    }

    /// 第二代上半：第三刀压缩段带【待续】→ 整段重写；老收尾段在起点以后 → 增量补
    func testThirdCutRollingIsFullAndOldCloseoutIsIncremental() {
        let m = msgs(100, from: date(10, 3, 9))
        XCTAssertEqual(classify([seg(.rolling, m, 0..<60, pending: "仍未问到"), seg(.closeout, m, 60..<80)], m)?.kind, .a2Full)
        XCTAssertEqual(classify([seg(.rolling, m, 0..<60), seg(.closeout, m, 60..<80)], m)?.kind, .a2Incremental)
    }

    /// c2c3-v2 第 7 段（车头 B）：新写的 A2 段也带待续（A4 搬），带新格式标记 → 不算老式、不整段重写；没标的老式段照旧重写
    func testNewFormatRollingWithPendingIsNotOldStyle() {
        let m = msgs(100, from: date(10, 3, 9))
        var fresh = seg(.rolling, m, 0..<60, pending: "周三问结果")
        fresh.format = SessionSegment.currentFormat
        XCTAssertEqual(classify([fresh, seg(.closeout, m, 60..<80)], m)?.kind, .a2Incremental, "新段带待续不当老式")
        XCTAssertEqual(classify([seg(.rolling, m, 0..<60, pending: "周三问结果"), seg(.closeout, m, 60..<80)], m)?.kind, .a2Full, "没标的老式段照旧")
        let tail = seg(.closeout, m, 60..<100, tail: true)
        XCTAssertNotEqual(classify([fresh, tail], m)?.kind, .a2Full, "新写的 A2 + 尾段不重写 A2")
    }

    /// Q4：起点以前的老收尾段不算「要补」（起点以前的消息不给写手）
    func testOldCloseoutBeforeStartDoesNotTriggerA2() {
        let m = msgs(10, from: date(9, 25, 9), prefix: "o") + msgs(20, from: date(10, 5, 9))
        let plan = classify([seg(.closeout, m, 0..<10)], m)
        XCTAssertEqual(plan, .init(kind: .tailA3))
    }

    /// 第二代下半：v4-1 抄本（多段）→ 尾段 + A3；v4-1 短窗口一段 from=0、A2 没有尾段 → 也是尾段 + A3
    func testV41WindowsAreTailA3() {
        let m = msgs(80, from: date(10, 4, 9))
        let copy = summary([seg(.rolling, m, 0..<60), seg(.closeout, m, 60..<80)], closed: "n79")
        XCTAssertEqual(classify([seg(.rolling, m, 0..<60)], a3: copy, m), .init(kind: .tailA3))
        let short = msgs(30, from: date(10, 4, 9))
        let one = summary([seg(.closeout, short, 0..<30)], closed: "n29")
        XCTAssertEqual(classify([], onDisk: false, a3: one, short), .init(kind: .tailA3), "形状和 v5 一样，但 A2 里没有尾段")
    }

    /// 第三代：A3 一段 from=0 写到最后一条 + 尾段写到同一条 → 跳过；后来又有新消息 → 补尾段 + A3
    func testV5IsSkippedUntilNewMessages() {
        let m = msgs(80, from: date(10, 6, 9))
        let a2 = [seg(.rolling, m, 0..<60), seg(.closeout, m, 60..<80, tail: true)]
        let a3 = summary([seg(.closeout, m, 0..<80)], closed: "n79")
        XCTAssertEqual(classify(a2, a3: a3, m), .init(kind: .skip))
        XCTAssertFalse(MemoryMigration.Plan(kind: .skip).needsWork)
        let more = m + msgs(4, from: date(10, 7, 9), prefix: "q")
        XCTAssertEqual(classify(a2, a3: a3, more)?.kind, .tailA3)
        // 正式段已经盖到最后（不用尾段）也算写好了
        XCTAssertEqual(classify([seg(.rolling, m, 0..<80)], a3: a3, m)?.kind, .skip)
    }

    // MARK: - M2

    /// rolling[10,30) + 老收尾段[30,50) + 起点以前老收尾段[0,10) → 只补 [30,50)，起点以前那段留着
    func testIncrementalWritesOnlyOldCloseoutSpanAndKeepsPreStart() throws {
        let m = msgs(10, from: date(9, 25, 9), prefix: "o") + msgs(50, from: date(10, 5, 9))
        let pre = seg(.closeout, m, 0..<10)
        let roll = seg(.rolling, m, 10..<30)
        let old = summary([pre, roll, seg(.closeout, m, 30..<50)], compressed: 50)
        let plan = try XCTUnwrap(MemoryMigration.classify(.init(a2: old, a2OnDisk: true, a3: nil), messages: m, scope: scope))
        XCTAssertEqual(plan.kind, .a2Incremental)
        let src = MemoryRegeneration.Source(title: "t", messages: m, isCC: false)
        let w = MemoryMigration.a2Work(plan, a2: old, source: src, scope: scope, now: date(10, 16, 12))
        XCTAssertEqual(w.parts, [30..<50])
        XCTAssertEqual(w.keep.segments, [pre, roll], "起点以前的老收尾段留着（Q4），起点以后的拿掉")
        // CC 窗口：那天已经过去，整截都写
        let cc = MemoryMigration.a2Work(plan, a2: old, source: .init(title: "t", messages: m, isCC: true), scope: scope, now: date(10, 16, 12))
        XCTAssertEqual(cc.parts, [30..<60])
    }

    /// astra #3：rolling[0,20) + 老收尾段[20,40) + rolling[40,60)、锚点 60 → 拿掉老收尾段以后中间那截补上；
    /// 老收尾段在主线上找不到（切过分支）→ 补不上
    func testIncrementalFillsMiddleGapOrRefuses() throws {
        let m = msgs(60, from: date(10, 5, 9))
        let old = summary([seg(.rolling, m, 0..<20), seg(.closeout, m, 20..<40), seg(.rolling, m, 40..<60)], compressed: 60)
        let plan = try XCTUnwrap(MemoryMigration.classify(.init(a2: old, a2OnDisk: true, a3: nil), messages: m, scope: scope))
        XCTAssertEqual(plan.kind, .a2Incremental)
        let src = MemoryRegeneration.Source(title: "t", messages: m, isCC: false)
        let w = MemoryMigration.a2Work(plan, a2: old, source: src, scope: scope, now: date(10, 16, 12))
        XCTAssertNil(w.problem)
        XCTAssertEqual(w.parts, [20..<40])
        XCTAssertEqual(MemoryMigration.a2Work(plan, a2: old, source: .init(title: "t", messages: m, isCC: true), scope: scope,
                                              now: date(10, 16, 12)).parts, [20..<40], "CC 一样")
        var lost = seg(.closeout, m, 20..<40)
        lost.lastNodeId = "别的分支"
        let w2 = MemoryMigration.a2Work(plan, a2: summary([seg(.rolling, m, 0..<20), lost, seg(.rolling, m, 40..<60)], compressed: 60),
                                        source: src, scope: scope, now: date(10, 16, 12))
        XCTAssertNotNil(w2.problem)
        XCTAssertEqual(w2.parts, [])
    }

    /// astra #4：跨起点的老段（起点以前开始）算老内容留着——不触发增量 / 整段重写；增量时只拿掉整段在起点以后的
    func testSegmentsCrossingStartAreKept() throws {
        let m = msgs(10, from: date(9, 30, 22), prefix: "o") + msgs(50, from: date(10, 5, 9))
        let crossClose = seg(.closeout, m, 5..<20)
        XCTAssertEqual(classify([seg(.rolling, m, 0..<5), crossClose], m)?.kind, .tailA3)
        XCTAssertEqual(classify([seg(.rolling, m, 0..<20, pending: "仍未问到")], m)?.kind, .tailA3)
        let old = summary([seg(.rolling, m, 0..<5), crossClose, seg(.closeout, m, 20..<40)], compressed: 5)
        let plan = try XCTUnwrap(MemoryMigration.classify(.init(a2: old, a2OnDisk: true, a3: nil), messages: m, scope: scope))
        XCTAssertEqual(plan.kind, .a2Incremental)
        let w = MemoryMigration.a2Work(plan, a2: old, source: .init(title: "t", messages: m, isCC: false), scope: scope, now: date(10, 16, 12))
        XCTAssertEqual(w.keep.segments, Array(old.segments.prefix(2)))
    }

    /// a2Full 走 work，但起点以前的老收尾段也留着
    func testFullRewriteKeepsPreStartCloseout() throws {
        let m = msgs(10, from: date(9, 25, 9), prefix: "o") + msgs(70, from: date(10, 5, 9))
        let pre = seg(.closeout, m, 0..<10)
        let old = summary([pre, seg(.rolling, m, 10..<70, pending: "仍未问到")], compressed: 70)
        let plan = MemoryMigration.Plan(kind: .a2Full)
        let w = MemoryMigration.a2Work(plan, a2: old, source: .init(title: "t", messages: m, isCC: false), scope: scope, now: date(10, 16, 12))
        XCTAssertEqual(w.keep.segments, [pre])
        XCTAssertEqual(w.parts, [10..<70])
    }

    /// 10-16（粟粟）：主线两边加起来不超过 5 条 → 太短，跳过不搬；6 条照常
    func testShortWindowIsSkipped() {
        let five = msgs(5, from: date(10, 5, 9))
        XCTAssertEqual(classify([], onDisk: false, five), .init(kind: .short))
        XCTAssertEqual(classify([], onDisk: false, five)?.needsWork, false, "不花钱")
        XCTAssertEqual(classify([seg(.rolling, five, 0..<5, pending: "仍未问到")], five)?.kind, .short, "老式段也不重写")
        XCTAssertEqual(classify([], onDisk: false, msgs(6, from: date(10, 5, 9))), .init(kind: .tailA3))
    }

    /// astra #3：太短的判断在起点判断前面——起点以前 / 没有起点 / 缺第 0 段，一律不碰（不落第 0 段）；本来就不在范围的照旧不算
    func testShortWindowBeatsSeedEverywhere() {
        let oldShort = msgs(5, from: date(9, 20, 9)), oldLong = msgs(10, from: date(9, 20, 9)), newShort = msgs(5, from: date(10, 5, 9))
        func plan(_ m: [SessionSegmentWriter.Message], seed: Bool, scope: Date) -> MemoryMigration.Plan? {
            MemoryMigration.classify(.init(a2: summary(seed ? [legacy(to: m.count)] : []), a2OnDisk: !seed, a3: nil),
                                     messages: m, scope: scope)
        }
        XCTAssertEqual(plan(oldShort, seed: true, scope: scope), .init(kind: .short), "起点以前、缺第 0 段")
        XCTAssertEqual(plan(oldLong, seed: true, scope: scope), .init(kind: .seedOnly), "够长照落第 0 段")
        XCTAssertNil(plan(oldShort, seed: false, scope: scope), "起点以前、不缺第 0 段：本来就不在范围")
        XCTAssertEqual(plan(oldShort, seed: true, scope: .distantFuture), .init(kind: .short), "没有起点")
        XCTAssertEqual(plan(oldLong, seed: true, scope: .distantFuture), .init(kind: .seedOnly))
        XCTAssertNil(plan(newShort, seed: false, scope: .distantFuture))
        XCTAssertEqual(plan(newShort, seed: true, scope: scope), .init(kind: .short), "起点以后、缺第 0 段")
        XCTAssertEqual(plan(newShort, seed: false, scope: scope), .init(kind: .short), "起点以后")
    }
}
