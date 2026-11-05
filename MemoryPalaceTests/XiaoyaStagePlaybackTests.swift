import XCTest
@testable import 记忆花园

/// 小芽引导 v2 实机两个 bug（plan-onboarding-xiaoya-impl §12-C / D，粟粟 10-16 Air 试完）。
/// C：Tip 插图有时卡在示意帧不播；D：填 key / 名字时舞台头不收。
/// 能测的是两处判断逻辑；回调真实时序（LazyVStack / 键盘通知）测不了，得 Air 上看。
final class XiaoyaStagePlaybackTests: XCTestCase {

    // MARK: C · 插图看得见

    /// 根因复现：出现 → 滚动可见 → 消失 → 回来，而这次可见性回调没再报 true。
    /// 旧版单个 visible 在这里被 onDisappear 清成 false 回不来；现在两路各管各的，回来就接着播
    func testScrollGateRecoversAfterDisappearWithoutScrollCallback() {
        var v = XiaoyaTipVisibility()
        v.onScreen = true
        v.inViewport = true
        XCTAssertTrue(v.visible(.scroll))
        v.onScreen = false
        XCTAssertFalse(v.visible(.scroll), "离屏要停")
        v.onScreen = true
        XCTAssertTrue(v.visible(.scroll), "回来时不靠滚动回调也要接着播")
    }

    func testScrollGateNeedsBothSignals() {
        var v = XiaoyaTipVisibility()
        v.onScreen = true
        XCTAssertFalse(v.visible(.scroll), "LazyVStack 预建在视口外的那张不动")
        v.inViewport = true
        v.onScreen = false
        XCTAssertFalse(v.visible(.scroll))
    }

    func testAppearGateIgnoresScrollAndStillNeverPlays() {
        var v = XiaoyaTipVisibility()
        v.onScreen = true
        XCTAssertTrue(v.visible(.appear), "设置页 List 里只看出现 / 消失")
        v.inViewport = true
        XCTAssertFalse(v.visible(.still))
    }

    func testClockLoopsLikeTheOldLinearKeyframe() {
        let origin = Date(timeIntervalSinceReferenceDate: 1000)
        let d = 4.0
        XCTAssertEqual(XiaoyaTipClock.progress(at: origin, origin: origin, duration: d), 0)
        XCTAssertEqual(XiaoyaTipClock.progress(at: origin.addingTimeInterval(1), origin: origin, duration: d), 0.25, accuracy: 1e-9)
        XCTAssertEqual(XiaoyaTipClock.progress(at: origin.addingTimeInterval(9), origin: origin, duration: d), 0.25, accuracy: 1e-9, "第三圈")
        XCTAssertEqual(XiaoyaTipClock.progress(at: origin.addingTimeInterval(-3), origin: origin, duration: d), 0, "暂停时帧日期比起点早：从头画")
        XCTAssertEqual(XiaoyaTipClock.progress(at: origin.addingTimeInterval(3), origin: origin, duration: 0), 0)
        for scene in [XiaoyaTipScene.strip, .arc, .toChat, .toList, .floors] {
            let t = XiaoyaTipClock.progress(at: origin.addingTimeInterval(1000.123), origin: origin, duration: scene.duration)
            XCTAssertTrue((0..<1).contains(t))
        }
    }

    // MARK: D · 舞台收放

    /// 钥匙卡 / 起名卡的输入框弹键盘：聊天框没焦点，也要收
    func testCardFieldKeyboardCollapsesStage() {
        XCTAssertTrue(XiaoyaStageFold.collapsed(chatFocused: false, keyboardUp: true))
    }

    func testChatFocusStillCollapsesAndNoKeyboardExpands() {
        XCTAssertTrue(XiaoyaStageFold.collapsed(chatFocused: true, keyboardUp: false), "外接键盘：聊天框有焦点照旧收")
        XCTAssertTrue(XiaoyaStageFold.collapsed(chatFocused: true, keyboardUp: true))
        XCTAssertFalse(XiaoyaStageFold.collapsed(chatFocused: false, keyboardUp: false))
    }
}
