import XCTest

/// 网页卡宿主能力桥（research-chat-cards §13）：种子对话里的网页卡点「运行」→ 卡里点按钮 →
/// 原生确认弹窗 → 卡片拿到成功回复把 #out 改成 RGOK；「问」把一句话放进输入框
@MainActor
final class HTMLCardBridgeUITests: RegressionTestCase {

    private var htmlRow: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "[RG] 网页卡")).firstMatch
    }

    private func web(_ text: String) -> XCUIElement {
        app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    func testCardAddsTodoAfterConfirmAndAsksIntoComposer() {
        launch(["--ui-regression-seed"])
        waitFor(field, "输入框")
        expectPage(1, "启动落在聊天页")
        swipeToPrev()
        expectPage(0, "翻到列表")
        waitFor(htmlRow, "列表里的「[RG] 网页卡」")
        htmlRow.tap()
        expectPage(1, "点对话自动翻到聊天页")

        let run = app.buttons["运行"].firstMatch
        waitFor(run, "网页卡的运行按钮", timeout: 15)
        run.tap()
        let add = app.webViews.buttons["加待办"].firstMatch
        waitFor(add, "卡里的加待办按钮", timeout: 15)
        snap("bridge-0-running")
        add.tap()

        let confirm = app.alerts["这张卡想加一条待办"]
        waitFor(confirm, "原生确认弹窗", timeout: 10)
        snap("bridge-1-confirm")
        confirm.buttons["加入"].tap()
        Thread.sleep(forTimeInterval: 2)
        snap("bridge-1b-after-allow")
        XCTAssertTrue(until(10) { [self] in web("RGOK").exists }, "[product] 卡片没收到成功回复")
        snap("bridge-2-ok")

        app.webViews.buttons["问"].firstMatch.tap()
        XCTAssertTrue(until(10) { [self] in (field.value as? String)?.contains("RG 再出一组") == true },
                      "[product] mp.ask 没放进输入框（\(String(describing: field.value))）")
        snap("bridge-3-asked")
    }
}
