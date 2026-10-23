import XCTest
@testable import 记忆花园

/// CC 入场弹泡特征测试：场景 B 标记规则 + 泡长自适应节奏（plan-cc-bubble-entrance）。
final class CCEntranceTests: XCTestCase {

    // MARK: - entranceNodeIds（场景 B 标记）

    private func p(_ items: [(String, String)]) -> [(role: String, id: String)] {
        items.map { (role: $0.0, id: $0.1) }
    }

    func testTailAssistantsWithinUnread() {
        let path = p([("user", "u1"), ("assistant", "a1"), ("assistant", "a2"), ("assistant", "a3")])
        XCTAssertEqual(ConversationViewModel.entranceNodeIds(path: path, unread: 2, cap: 3),
                       ["a3", "a2"], "unread=2 只取尾部最后 2 条")
    }

    func testUnreadExceedsCapClampsToThree() {
        let path = p([("assistant", "a1"), ("assistant", "a2"), ("assistant", "a3"),
                      ("assistant", "a4"), ("assistant", "a5")])
        XCTAssertEqual(ConversationViewModel.entranceNodeIds(path: path, unread: 5, cap: 3),
                       ["a5", "a4", "a3"], "未读积压只弹最近 cap 条")
    }

    func testTailIsUserYieldsEmpty() {
        let path = p([("assistant", "a1"), ("user", "u1")])
        XCTAssertTrue(ConversationViewModel.entranceNodeIds(path: path, unread: 2, cap: 3).isEmpty,
                      "尾部不是 assistant（用户已回过/怪态）不弹")
    }

    func testZeroUnreadYieldsEmpty() {
        let path = p([("assistant", "a1")])
        XCTAssertTrue(ConversationViewModel.entranceNodeIds(path: path, unread: 0, cap: 3).isEmpty)
    }

    func testUnreadLargerThanTailRunStopsAtRunBoundary() {
        let path = p([("user", "u1"), ("assistant", "a1"), ("assistant", "a2")])
        XCTAssertEqual(ConversationViewModel.entranceNodeIds(path: path, unread: 3, cap: 3),
                       ["a2", "a1"], "连续段只有 2 条时到段界即止，不越过 user")
    }

    // MARK: - entranceDelay（泡长自适应节奏）

    func testShortBlockFastPop() {
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 20, isFirst: false), 0.23, accuracy: 0.001)
    }

    func testLongBlockSlowerPop() {
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 100, isFirst: false), 0.55, accuracy: 0.001)
    }

    func testVeryLongBlockClampedAtCeiling() {
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 300, isFirst: false), 0.7, accuracy: 0.001)
    }

    func testFirstPopHasDotsBeat() {
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 10, isFirst: true), 0.4, accuracy: 0.001,
                       "首泡前至少 0.4s dots 前奏")
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 200, isFirst: true), 0.7, accuracy: 0.001,
                       "首块很长时取自适应值（>0.4）")
    }
}
