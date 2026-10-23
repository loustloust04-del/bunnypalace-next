import XCTest
@testable import 记忆花园

/// 顶栏状态岛（粟粟 09-28 稿 topbar-island.html；真机反馈后改为只看手指拖动）
final class ChatTopIslandTests: XCTestCase {
    /// fingerUp = 这次拖动里手指往上走了多少（屏幕坐标；往上 = 往下读新消息）
    func testPanCollapsesWhenReadingDownAndExpandsWhenScrollingBack() {
        var pan = TopBarCollapse.Pan()
        pan.began()
        pan.changed(fingerUp: 10)
        XCTAssertFalse(pan.collapsed)                      // 小动作不变
        pan.changed(fingerUp: 25)
        XCTAssertTrue(pan.collapsed)                       // 往下读满 24 → 收
        pan.changed(fingerUp: 60)                          // 继续往下读：拐点跟着走
        pan.changed(fingerUp: 40)
        XCTAssertTrue(pan.collapsed)                       // 回拉 20 不够
        pan.changed(fingerUp: 35)
        XCTAssertFalse(pan.collapsed)                      // 从拐点回拉满 24 → 展
    }

    func testNewGestureStartsFromZero() {
        var pan = TopBarCollapse.Pan(collapsed: true)
        pan.began()
        pan.changed(fingerUp: -20)
        XCTAssertTrue(pan.collapsed)
        pan.changed(fingerUp: -30)
        XCTAssertFalse(pan.collapsed)                      // 往上翻满 24 → 展（不管列表在哪，没有「靠近最新就强制展开」）
        pan.began()
        pan.changed(fingerUp: -100)
        XCTAssertFalse(pan.collapsed)
        pan.changed(fingerUp: -76)
        XCTAssertTrue(pan.collapsed)                       // 同一手势里从最低点往下读满 24 → 收
    }

    func testIslandContent() {
        XCTAssertEqual(ChatTopIsland.Content(hasPin: true, hasMusic: true), .both)
        XCTAssertEqual(ChatTopIsland.Content(hasPin: true, hasMusic: false), .pin)
        XCTAssertEqual(ChatTopIsland.Content(hasPin: false, hasMusic: true), .music)
        XCTAssertNil(ChatTopIsland.Content(hasPin: false, hasMusic: false))
    }

    func testSingleContentLayout() {
        XCTAssertFalse(ChatTopIsland.Content.music.fillsExpandedWidth)
        XCTAssertTrue(ChatTopIsland.Content.pin.fillsExpandedWidth)
        XCTAssertTrue(ChatTopIsland.Content.both.fillsExpandedWidth)
    }

    /// 岛按屏幕真居中：左右两侧占同样宽（取较宽的一侧）
    func testSidesAreEqualWidthForTrueCentering() {
        XCTAssertEqual(ChatTopBarLayout.sideWidth(left: 44, right: 88), 88)
        XCTAssertEqual(ChatTopBarLayout.sideWidth(left: 100, right: 88), 100)
    }

    // MARK: 置顶条照 Telegram（ChatPinnedMessageTitlePanelNode / AnimatedNavigationStripeNode）

    /// 置顶按聊天里的先后排（0 = 最旧）；默认显示最新；点一下跳到这条、换成更旧的一条；最旧再点回到最新
    func testPinCycleGoesOlderThenWraps() {
        XCTAssertEqual(PinCycle.defaultIndex(count: 3), 2)
        XCTAssertEqual(PinCycle.afterTap(index: 2, count: 3), 1)
        XCTAssertEqual(PinCycle.afterTap(index: 1, count: 3), 0)
        XCTAssertEqual(PinCycle.afterTap(index: 0, count: 3), 2)
        XCTAssertEqual(PinCycle.afterTap(index: 0, count: 1), 0)
        XCTAssertEqual(PinCycle.clamp(index: 9, count: 3), 2)     // 取消置顶后越界 → 最新
    }

    func testPinTitles() {
        XCTAssertEqual(PinCycle.title(index: 0, count: 1), "置顶消息")
        XCTAssertEqual(PinCycle.title(index: 0, count: 2), "上一条置顶")
        XCTAssertEqual(PinCycle.title(index: 1, count: 2), "置顶消息")
        XCTAssertEqual(PinCycle.title(index: 0, count: 4), "置顶消息 #1")
        XCTAssertEqual(PinCycle.title(index: 3, count: 4), "置顶消息")
    }

    /// 左侧竖条：每段高 max((36 − 2·(n−1))/n, 8)，段间 2；超过 4 段整列滚动让当前段居中（两端贴边）
    func testStripeGeometry() {
        XCTAssertEqual(PinCycle.segmentHeight(count: 1), 36, accuracy: 1e-9)
        XCTAssertEqual(PinCycle.segmentHeight(count: 2), 17, accuracy: 1e-9)
        XCTAssertEqual(PinCycle.segmentHeight(count: 6), 8, accuracy: 1e-9)
        XCTAssertEqual(PinCycle.stripeOffset(index: 1, count: 3), 0, accuracy: 1e-9)      // 放得下：不滚
        XCTAssertEqual(PinCycle.stripeOffset(index: 0, count: 8), 0, accuracy: 1e-9)      // 顶端贴边
        let total = 8 * 8.0 + 7 * 2.0
        XCTAssertEqual(PinCycle.stripeOffset(index: 7, count: 8), -(total - 36), accuracy: 1e-9)   // 底端贴边
        XCTAssertEqual(PinCycle.stripeOffset(index: 4, count: 8), -(4 * 10.0 + 4 - 18), accuracy: 1e-9)  // 当前段居中
    }
}
