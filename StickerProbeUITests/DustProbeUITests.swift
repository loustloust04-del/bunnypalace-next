import XCTest

/// 删除散成灰复现（research-chat-cards §12；粟粟 Air 上「删除没看见」）：种子对话里长按尾条 → 删除，删的过程中连拍。
/// AUT 侧日志：`log show --predicate 'subsystem == "MemoryPalace" AND category == "dust"'`
@MainActor
final class DustProbeUITests: RegressionTestCase {

    func testDeleteShowsDust() {
        launch(["--ui-regression-seed"])
        waitFor(field, "输入框")
        guard until(15, { [self] in anchor("RGTAIL") != nil }), let tail = anchor("RGTAIL") else {
            snap("setup-no-tail"); return XCTFail("[setup] 回归种子对话没打开")
        }
        let point = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: tail.frame.midX, dy: tail.frame.midY))
        point.press(forDuration: 0.9)
        let delete = app.buttons["删除"].firstMatch
        waitFor(delete, "长按菜单里的删除", timeout: 5)
        snap("dust-0-menu")
        delete.tap()
        for i in 1...5 {
            Thread.sleep(forTimeInterval: 0.12)
            snap("dust-\(i)")
        }
        XCTAssertTrue(until(5) { [self] in anchor("RGTAIL") == nil }, "[product] 删完尾条还在")
    }
}
