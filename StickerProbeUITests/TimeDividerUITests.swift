import XCTest

/// 时间分割线 + 长按菜单底部时间行（TASK page1-消息-20）：种子「[RG] 网页卡」对话第一条顶上有分割线；长按出菜单底部时间
@MainActor
final class TimeDividerUITests: RegressionTestCase {

    private var htmlRow: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "[RG] 网页卡")).firstMatch
    }

    func testDividerAndLongPressInfo() {
        launch(["--ui-regression-seed"])
        waitFor(field, "输入框")
        expectPage(1, "启动落在聊天页")
        swipeToPrev()
        expectPage(0, "翻到列表")
        waitFor(htmlRow, "列表里的「[RG] 网页卡」")
        htmlRow.tap()
        expectPage(1, "点对话自动翻到聊天页")
        guard until(10, { [self] in anchor("RGHTML") != nil }), let first = anchor("RGHTML") else {
            snap("divider-setup"); return XCTFail("[setup] 种子对话没打开")
        }
        Thread.sleep(forTimeInterval: 1)
        snap("divider-0-list")
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: first.frame.midX, dy: first.frame.midY))
        point.press(forDuration: 0.9)
        waitFor(app.buttons["删除"].firstMatch, "长按菜单", timeout: 5)
        Thread.sleep(forTimeInterval: 0.6)
        snap("divider-1-menu")
    }
}
