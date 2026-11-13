import CoreGraphics
import XCTest
@testable import TranscriptCore

/// 场景回放：把真机上踩过的滚动 / 键盘 / 流式的坑写成事务序列。
/// 每个场景断言的都是同一件事——不许动的那一行，在屏幕上的位置没动。
final class TranscriptEngineTests: XCTestCase {
    private typealias Row = TranscriptLayout.Row

    /// 20 行、每行 100 高、无间距；可见高度 600。行 id 从最新到最旧 r0…r19
    private func makeEngine(rows count: Int = 20, insetStart: CGFloat = 0, insetEnd: CGFloat = 0) -> TranscriptEngine {
        var engine = TranscriptEngine(width: 300, viewport: .init(height: 600, insetStart: insetStart, insetEnd: insetEnd))
        _ = engine.apply(.setRows((0..<count).map { Row(id: "r\($0)", estimatedHeight: 100) }))
        return engine
    }

    /// 一行的上沿在屏幕上的位置（离可见区起点一侧多远）
    private func screenTop(_ engine: TranscriptEngine, _ id: String) -> CGFloat {
        engine.layout.frame(of: id)!.maxY - engine.offset
    }

    private func grow(_ id: String, to height: CGFloat) -> TranscriptEngine.Transaction {
        .setHeights([.init(id: id, version: 0, height: height, tier: .measured)])
    }

    // MARK: 贴着最新消息

    func testOpensAtStartAndFollows() {
        let engine = makeEngine(insetStart: 80)
        XCTAssertEqual(engine.offset, -80)
        XCTAssertTrue(engine.isFollowing)
        XCTAssertEqual(engine.maxOffset, 2000 - 600)
    }

    func testStreamingGrowthWhileFollowingStaysPinned() {
        var engine = makeEngine()
        let effects = engine.apply(grow("r0", to: 260))
        XCTAssertEqual(effects, [.layoutChanged(offsetAdjustment: 0)])
        XCTAssertEqual(engine.offset, 0, "最新一行长高：位置不动，旧内容被往上推")
        XCTAssertEqual(engine.layout.frame(of: "r1")?.minY, 260)
    }

    func testNewMessageWhileFollowingAppearsAtStart() {
        var engine = makeEngine()
        var rows = engine.layout.rows
        rows.insert(Row(id: "new", estimatedHeight: 60), at: 0)
        XCTAssertEqual(engine.apply(.setRows(rows)), [.rowsChanged(reconfigure: [], offsetAdjustment: 0)])
        XCTAssertEqual(engine.offset, 0)
        XCTAssertEqual(engine.layout.frame(of: "new"), .init(minY: 0, height: 60))
    }

    func testPadWhileFollowingLiftsNewestWithoutMovingOffset() {
        var engine = makeEngine()
        XCTAssertEqual(engine.apply(.setLeadingPad(300, reason: .layout)), [.layoutChanged(offsetAdjustment: 0)])
        XCTAssertEqual(engine.offset, 0)
        XCTAssertEqual(engine.layout.frame(of: "r0")?.minY, 300, "最新一行被垫块顶上去")
        XCTAssertEqual(engine.apply(.setLeadingPad(300, reason: .layout)), [], "同一个值再来一次不产生指令")
    }

    // MARK: 在看历史

    /// 滚到 r5–r10 一带再停下
    private func scrolledUp() -> TranscriptEngine {
        var engine = makeEngine()
        _ = engine.apply(.scrolled(to: 450, phase: .tracking))
        _ = engine.apply(.scrolled(to: 450, phase: .idle))
        XCTAssertFalse(engine.isFollowing)
        return engine
    }

    func testStreamingBelowTheScreenDoesNotMoveWhatIsBeingRead() {
        var engine = scrolledUp()                      // 可见 450–1050：r4 的上半 … r10 的下半
        let before = screenTop(engine, "r7")
        let effects = engine.apply(grow("r0", to: 340)) // 屏幕下方看不见的最新一行在流式长高
        XCTAssertEqual(effects, [.layoutChanged(offsetAdjustment: 240)])
        XCTAssertEqual(screenTop(engine, "r7"), before)
    }

    func testNewMessageBelowTheScreenDoesNotMoveWhatIsBeingRead() {
        var engine = scrolledUp()
        let before = screenTop(engine, "r7")
        var rows = engine.layout.rows
        rows.insert(Row(id: "new", gapBefore: 0, estimatedHeight: 70), at: 0)
        XCTAssertEqual(engine.apply(.setRows(rows)), [.rowsChanged(reconfigure: [], offsetAdjustment: 70)])
        XCTAssertEqual(screenTop(engine, "r7"), before)
        XCTAssertFalse(engine.isFollowing, "看历史时来了新消息：不抢走位置")
    }

    func testExpandingARowOnScreenGrowsDownwardKeepingItsTop() {
        var engine = scrolledUp()
        let top = screenTop(engine, "r7")
        let above = screenTop(engine, "r9")
        _ = engine.apply(grow("r7", to: 300))           // 点了「展开全文」
        XCTAssertEqual(screenTop(engine, "r7"), top, "被展开的那一行上沿不动")
        XCTAssertEqual(screenTop(engine, "r9"), above, "它上面的内容不动")
    }

    func testGrowthAboveTheScreenNeedsNoAdjustment() {
        var engine = scrolledUp()
        XCTAssertEqual(engine.apply(grow("r15", to: 500)), [.layoutChanged(offsetAdjustment: 0)],
                       "屏幕上方更旧的行晚到的测量：它们排在后面，不影响看着的内容")
    }

    func testPadChangeWhileReadingHistoryStaysInPlace() {
        var engine = scrolledUp()
        let before = screenTop(engine, "r7")
        XCTAssertEqual(engine.apply(.setLeadingPad(300, reason: .layout)), [.layoutChanged(offsetAdjustment: 300)])
        XCTAssertEqual(screenTop(engine, "r7"), before, "输入条长高：看着的内容不动")
        XCTAssertEqual(engine.apply(.setLeadingPad(0, reason: .layout)), [.layoutChanged(offsetAdjustment: -300)])
        XCTAssertEqual(screenTop(engine, "r7"), before)
    }

    func testBranchSwitchBelowTheForkKeepsTheForkInPlace() {
        var engine = scrolledUp()                      // 屏幕最上面是 r10（更旧）
        let before = screenTop(engine, "r10")
        // 分叉点是 r8：比它新的 r0…r7 整段换成另一条分支的 3 行
        let other = (0..<3).map { Row(id: "alt\($0)", estimatedHeight: 150) }
        let kept = Array(engine.layout.rows[8...])
        _ = engine.apply(.setRows(other + kept))
        XCTAssertEqual(screenTop(engine, "r10"), before)
    }

    func testAnchorRowDeletedFallsBackToClampedOffset() {
        var engine = makeEngine(rows: 8)               // 内容 800，最远能滚到 200
        _ = engine.apply(.scrolled(to: 200, phase: .tracking))
        _ = engine.apply(.scrolled(to: 200, phase: .idle))
        XCTAssertFalse(engine.isFollowing)
        let effects = engine.apply(.setRows(Array(engine.layout.rows.prefix(3))))   // 屏幕上的行全删了
        XCTAssertEqual(effects, [.rowsChanged(reconfigure: [], offsetAdjustment: -200)])
        XCTAssertEqual(engine.offset, 0, "内容不满一屏：夹回起点")
    }

    func testWidthChangeKeepsTheTopRow() {
        var engine = scrolledUp()
        _ = engine.apply(.setHeights((0..<20).map { .init(id: "r\($0)", version: 0, height: 100, tier: .measured) }))
        let before = screenTop(engine, "r10")
        _ = engine.apply(.setViewport(.init(height: 600), width: 420))
        // 转屏后每行重新量：变矮
        _ = engine.apply(.setHeights((0..<20).map { .init(id: "r\($0)", version: 0, height: 80, tier: .measured) }))
        XCTAssertEqual(screenTop(engine, "r10"), before)
    }

    // MARK: 跟随的进出

    func testSmallDragDoesNotLeaveFollowButLargeOneDoes() {
        var engine = makeEngine()
        _ = engine.apply(.scrolled(to: 15, phase: .tracking))
        XCTAssertTrue(engine.isFollowing, "拖了 15：还没过 20 的线")
        _ = engine.apply(.scrolled(to: 25, phase: .tracking))
        XCTAssertFalse(engine.isFollowing)
        _ = engine.apply(.scrolled(to: 10, phase: .decelerating))
        XCTAssertFalse(engine.isFollowing, "回到 10：还没进 4 的线，不来回翻")
        _ = engine.apply(.scrolled(to: 3, phase: .decelerating))
        XCTAssertTrue(engine.isFollowing)
    }

    func testProgrammaticAnimationDoesNotChangeFollow() {
        var engine = scrolledUp()
        _ = engine.apply(.scrolled(to: 2, phase: .animating))
        XCTAssertFalse(engine.isFollowing)
        _ = engine.apply(.scrolled(to: 2, phase: .idle))
        XCTAssertTrue(engine.isFollowing)
    }

    func testScrollToStart() {
        var engine = scrolledUp()
        XCTAssertEqual(engine.apply(.scrollToStart(animated: true)), [.scroll(to: 0, animation: .standard)])
        XCTAssertTrue(engine.isFollowing)
        XCTAssertEqual(engine.apply(.scrollToStart(animated: true)), [], "已经在起点")
    }

    func testScrollToRowAlignmentsAndClamp() {
        var engine = makeEngine(insetStart: 50, insetEnd: 30)   // 可见区 520 高
        XCTAssertEqual(engine.apply(.scrollToRow(id: "r10", alignment: .start, animated: false)),
                       [.scroll(to: 950, animation: .none)])
        XCTAssertFalse(engine.isFollowing)
        XCTAssertEqual(engine.apply(.scrollToRow(id: "r10", alignment: .end, animated: false)),
                       [.scroll(to: 1100 - 570, animation: .none)])
        XCTAssertEqual(engine.apply(.scrollToRow(id: "r10", alignment: .center, animated: false)),
                       [.scroll(to: 1050 - 50 - 260, animation: .none)])
        XCTAssertEqual(engine.apply(.scrollToRow(id: "r0", alignment: .center, animated: true)),
                       [.scroll(to: -50, animation: .standard)], "夹在起点")
        XCTAssertTrue(engine.isFollowing)
        XCTAssertEqual(engine.apply(.scrollToRow(id: "missing", alignment: .center, animated: true)), [])
    }

    // MARK: 其它

    func testVersionBumpReportsReconfigure() {
        var engine = makeEngine(rows: 3)
        var rows = engine.layout.rows
        rows[1].version = 1
        XCTAssertEqual(engine.apply(.setRows(rows)), [.rowsChanged(reconfigure: ["r1"], offsetAdjustment: 0)])
        XCTAssertEqual(engine.apply(.setRows(rows)), [], "同一份行再来一次不产生指令")
    }

    func testUnchangedHeightReportProducesNoEffect() {
        var engine = makeEngine(rows: 3)
        _ = engine.apply(grow("r1", to: 140))
        XCTAssertEqual(engine.apply(grow("r1", to: 140)), [])
    }

    /// 随机事务流：不跟随且锚点行还在时，它在屏幕上的位置只会因为「夹到两头」而变
    func testAnchorInvariantUnderRandomTransactions() {
        var generator = SeededGenerator(seed: 2026)
        var engine = makeEngine(rows: 60)
        var nextID = 0

        for step in 0..<3000 {
            let visible = engine.visibleRange
            let anchorIndex = engine.isFollowing ? nil : engine.layout.indices(intersecting: visible.minY, visible.maxY).last
            let anchorID = anchorIndex.map { engine.layout.rows[$0].id }
            let before = anchorID.map { screenTop(engine, $0) }

            let rows = engine.layout.rows
            switch Int.random(in: 0..<12, using: &generator) {
            case 0:
                var next = rows
                nextID += 1
                next.insert(Row(id: "n\(nextID)", gapBefore: 8, estimatedHeight: 90), at: 0)
                _ = engine.apply(.setRows(next))
            case 1 where rows.count > 20:
                var next = rows
                next.remove(at: Int.random(in: 0..<next.count, using: &generator))
                _ = engine.apply(.setRows(next))
            case 2:
                _ = engine.apply(.setLeadingPad(CGFloat(Int.random(in: 0...350, using: &generator)), reason: .layout))
            case 3:
                let target = CGFloat(Int.random(in: -10...Int(engine.maxOffset) + 10, using: &generator))
                _ = engine.apply(.scrolled(to: target, phase: .tracking))
                _ = engine.apply(.scrolled(to: min(max(target, engine.minOffset), engine.maxOffset), phase: .idle))
                continue
            default:
                let row = rows[Int.random(in: 0..<rows.count, using: &generator)]
                _ = engine.apply(.setHeights([.init(id: row.id, version: row.version,
                                                    height: CGFloat(Int.random(in: 30...500, using: &generator)), tier: .measured)]))
            }

            XCTAssertGreaterThanOrEqual(engine.offset, engine.minOffset, "第 \(step) 步")
            XCTAssertLessThanOrEqual(engine.offset, engine.maxOffset, "第 \(step) 步")
            if engine.isFollowing {
                XCTAssertEqual(engine.offset, engine.minOffset, "第 \(step) 步：跟随时钉在起点")
            } else if let anchorID, let before, engine.layout.index(of: anchorID) != nil,
                      engine.offset > engine.minOffset, engine.offset < engine.maxOffset {
                XCTAssertEqual(screenTop(engine, anchorID), before, accuracy: 0.001, "第 \(step) 步：锚点行挪了")
            }
        }
    }
}
