import CoreGraphics
import XCTest
@testable import TranscriptCore

/// 键盘起落的场景。策略照旧页（`PagingViewController.handleChatKeyboardRise` / `keyboardWillHide`）：
/// 在底弹起 = 画面先不动、再跟键盘滑上去；在底收起 = 先跟键盘滑下去、滑完再塌垫块；
/// 候选栏小步 = 一步到位；深翻 = 原地；发送收键盘 = 不滑，按距离分档。
final class TranscriptKeyboardTests: XCTestCase {
    private typealias Row = TranscriptLayout.Row
    private let motion = TranscriptEngine.KeyboardMotion(duration: 0.25, curve: 7)

    /// 20 行 × 100，可见 600
    private func makeEngine() -> TranscriptEngine {
        var engine = TranscriptEngine(width: 300, viewport: .init(height: 600))
        _ = engine.apply(.setRows((0..<20).map { Row(id: "r\($0)", estimatedHeight: 100) }))
        return engine
    }

    private func drag(_ engine: inout TranscriptEngine, to offset: CGFloat) {
        _ = engine.apply(.scrolled(to: offset, phase: .tracking))
        _ = engine.apply(.scrolled(to: offset, phase: .idle))
    }

    private func screenTop(_ engine: TranscriptEngine, _ id: String) -> CGFloat {
        engine.layout.frame(of: id)!.maxY - engine.offset
    }

    // MARK: 弹起

    func testRiseAtStartPinsPictureThenSlidesWithKeyboard() {
        var engine = makeEngine()
        let effects = engine.apply(.setLeadingPad(300, reason: .keyboard(motion)))
        XCTAssertEqual(effects, [
            .layoutChanged(offsetAdjustment: 300),                            // 垫块长出来的同一帧位置 +300：画面没动
            .scroll(to: 0, animation: .keyboard(motion, id: 1))               // 再跟键盘同曲线滑回最新消息
        ])
        XCTAssertEqual(engine.offset, 0)
        XCTAssertTrue(engine.isFollowing)
        XCTAssertEqual(engine.layout.frame(of: "r0")?.minY, 300)
    }

    func testSmallStepAtStartIsInstant() {
        var engine = makeEngine()
        _ = engine.apply(.setLeadingPad(300, reason: .keyboard(motion)))
        XCTAssertEqual(engine.apply(.setLeadingPad(340, reason: .keyboard(motion))),
                       [.layoutChanged(offsetAdjustment: 0)], "候选栏冒出来 40：不滑")
        XCTAssertEqual(engine.apply(.setLeadingPad(300, reason: .keyboard(motion))),
                       [.layoutChanged(offsetAdjustment: 0)], "候选栏收回去也不滑")
        XCTAssertEqual(engine.offset, 0)
    }

    func testRiseWithinOneScreenReturnsToStart() {
        var engine = makeEngine()
        drag(&engine, to: 450)                                                // 离底 450，不到一屏
        let effects = engine.apply(.setLeadingPad(300, reason: .keyboard(motion)))
        XCTAssertEqual(effects, [.layoutChanged(offsetAdjustment: 300),
                                 .scroll(to: 0, animation: .keyboard(motion, id: 1))])
        XCTAssertTrue(engine.isFollowing)
    }

    func testRiseDeepInHistoryStaysInPlace() {
        var engine = makeEngine()
        drag(&engine, to: 900)                                                // 离底 1.5 屏
        let before = screenTop(engine, "r12")
        XCTAssertEqual(engine.apply(.setLeadingPad(300, reason: .keyboard(motion))),
                       [.layoutChanged(offsetAdjustment: 300)])
        XCTAssertEqual(screenTop(engine, "r12"), before)
        XCTAssertFalse(engine.isFollowing)
    }

    // MARK: 收起

    private func withKeyboardUpAtStart() -> TranscriptEngine {
        var engine = makeEngine()
        _ = engine.apply(.setLeadingPad(300, reason: .keyboard(motion)))
        _ = engine.apply(.animationFinished(id: 1))
        _ = engine.apply(.scrolled(to: 0, phase: .idle))
        return engine
    }

    func testHideAtStartSlidesFirstThenCollapsesPad() {
        var engine = withKeyboardUpAtStart()
        XCTAssertEqual(engine.apply(.setLeadingPad(0, reason: .keyboard(motion))),
                       [.scroll(to: 300, animation: .keyboard(motion, id: 2))])
        XCTAssertEqual(engine.layout.leadingPad, 300, "滑的过程中垫块还留着")
        XCTAssertEqual(engine.pendingPadRelease?.pad, 0)

        XCTAssertEqual(engine.apply(.animationFinished(id: 2)), [.layoutChanged(offsetAdjustment: -300)],
                       "滑完：塌垫块和归位在同一帧")
        XCTAssertEqual(engine.layout.leadingPad, 0)
        XCTAssertEqual(engine.offset, 0)
        XCTAssertNil(engine.pendingPadRelease)
    }

    func testStreamingDuringHideSlideKeepsNewestPinned() {
        var engine = withKeyboardUpAtStart()
        _ = engine.apply(.setLeadingPad(0, reason: .keyboard(motion)))
        _ = engine.apply(.scrolled(to: 150, phase: .animating))               // 滑到一半
        let effects = engine.apply(.setHeights([.init(id: "r0", version: 0, height: 180, tier: .measured)]))
        XCTAssertEqual(effects, [.layoutChanged(offsetAdjustment: 150)], "回到这次滑动的终点，不是跳回 0")
        XCTAssertEqual(engine.offset, 300)
        _ = engine.apply(.animationFinished(id: 2))
        XCTAssertEqual(engine.offset, 0)
        XCTAssertEqual(engine.layout.frame(of: "r0"), .init(minY: 0, height: 180))
    }

    func testRiseInterruptingHideSlidesBackWithoutCollapsing() {
        var engine = withKeyboardUpAtStart()
        _ = engine.apply(.setLeadingPad(0, reason: .keyboard(motion)))
        _ = engine.apply(.scrolled(to: 120, phase: .animating))

        XCTAssertEqual(engine.apply(.setLeadingPad(300, reason: .keyboard(motion))),
                       [.scroll(to: 0, animation: .keyboard(motion, id: 3))], "收到一半又弹起：从半路接着滑回去")
        XCTAssertNil(engine.pendingPadRelease)
        XCTAssertEqual(engine.apply(.animationFinished(id: 2)), [], "被顶掉的那次滑动晚到的回报：不塌垫块")
        XCTAssertEqual(engine.layout.leadingPad, 300)
    }

    func testHideDeepInHistoryCollapsesInPlace() {
        var engine = makeEngine()
        drag(&engine, to: 900)
        _ = engine.apply(.setLeadingPad(300, reason: .keyboard(motion)))
        let before = screenTop(engine, "r12")
        XCTAssertEqual(engine.apply(.setLeadingPad(0, reason: .keyboard(motion))),
                       [.layoutChanged(offsetAdjustment: -300)])
        XCTAssertEqual(screenTop(engine, "r12"), before)
        XCTAssertNil(engine.pendingPadRelease)
    }

    // MARK: 发送时收键盘

    func testSendDismissNearStartCollapsesAndPinsInOneStep() {
        var engine = withKeyboardUpAtStart()
        drag(&engine, to: 500)                                                // 离底 500，1.5 屏以内
        XCTAssertEqual(engine.apply(.setLeadingPad(0, reason: .sendDismiss)),
                       [.layoutChanged(offsetAdjustment: -500)])
        XCTAssertEqual(engine.offset, 0)
        XCTAssertTrue(engine.isFollowing)
    }

    func testSendDismissFarAwayKeepsPlace() {
        var engine = withKeyboardUpAtStart()
        drag(&engine, to: 1200)                                               // 离底 2 屏
        let before = screenTop(engine, "r14")
        XCTAssertEqual(engine.apply(.setLeadingPad(0, reason: .sendDismiss)),
                       [.layoutChanged(offsetAdjustment: -300)])
        XCTAssertEqual(screenTop(engine, "r14"), before)
        XCTAssertFalse(engine.isFollowing)
    }

    func testUnknownAnimationIDIsIgnored() {
        var engine = withKeyboardUpAtStart()
        XCTAssertEqual(engine.apply(.animationFinished(id: 99)), [])
    }
}
