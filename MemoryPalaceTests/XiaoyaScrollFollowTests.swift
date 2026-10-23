import XCTest
@testable import 记忆花园

/// 小芽窗口「跟不跟底 / 舞台收不收」（09-26 粟粟：输出乱抖、收键盘时舞台缩放诡异）。
/// 根因：原来拿「离底距离 > 80」当「在看旧消息」，内容长高、键盘压矮可视区都会误判。
/// 现在只有用户亲手滚动停在远处才算。
final class XiaoyaScrollFollowTests: XCTestCase {

    func testContentGrowthWhileFollowingPinsAndDoesNotCollapse() {
        var f = XiaoyaScrollFollow()
        // 流式一块到三行，离底跳到 51（没人在滚）
        XCTAssertEqual(f.geometryChanged(distance: 51), .pinToBottom)
        XCTAssertFalse(f.readingHistory)
        // 一块很大（表格）也一样
        XCTAssertEqual(f.geometryChanged(distance: 240), .pinToBottom)
        XCTAssertFalse(f.readingHistory)
    }

    func testKeyboardShrinkingViewportPinsAndDoesNotCollapse() {
        var f = XiaoyaScrollFollow()
        XCTAssertEqual(f.geometryChanged(distance: 330), .pinToBottom)
        XCTAssertFalse(f.readingHistory)
    }

    func testUserScrollingUpCollapsesAndStopsFollowing() {
        var f = XiaoyaScrollFollow()
        f.userScrolling(true)
        XCTAssertEqual(f.geometryChanged(distance: 300), .none)
        XCTAssertTrue(f.readingHistory)
        f.userScrolling(false)
        // 看旧消息时内容继续长：不拽她
        XCTAssertEqual(f.geometryChanged(distance: 360), .none)
        XCTAssertTrue(f.readingHistory)
    }

    func testUserScrollingBackToBottomResumesFollowing() {
        var f = XiaoyaScrollFollow()
        f.userScrolling(true)
        _ = f.geometryChanged(distance: 300)
        _ = f.geometryChanged(distance: 10)
        f.userScrolling(false)
        XCTAssertFalse(f.readingHistory)
        XCTAssertEqual(f.geometryChanged(distance: 40), .pinToBottom)
    }

    /// 滞回：在 24~80 之间来回拖不翻状态
    func testHysteresisWhileDragging() {
        var f = XiaoyaScrollFollow()
        f.userScrolling(true)
        _ = f.geometryChanged(distance: 60)
        XCTAssertFalse(f.readingHistory)
        _ = f.geometryChanged(distance: 90)
        XCTAssertTrue(f.readingHistory)
        _ = f.geometryChanged(distance: 50)
        XCTAssertTrue(f.readingHistory)
    }

    func testSendingJumpsBackToBottom() {
        var f = XiaoyaScrollFollow()
        f.userScrolling(true)
        _ = f.geometryChanged(distance: 300)
        f.userScrolling(false)
        f.userSent()
        XCTAssertFalse(f.readingHistory)
        XCTAssertEqual(f.geometryChanged(distance: 120), .pinToBottom)
    }

    func testAlreadyAtBottomNeedsNoPin() {
        var f = XiaoyaScrollFollow()
        XCTAssertEqual(f.geometryChanged(distance: 0.5), .none)
    }
}
