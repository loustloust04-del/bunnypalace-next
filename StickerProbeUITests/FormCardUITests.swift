import XCTest

/// 表单卡（粟粟 10-03）：种子「[RG] 表单」对话里的表单卡，看各种字段控件的样子，再点提交看是否直接发出
@MainActor
final class FormCardUITests: RegressionTestCase {

    private var formRow: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "[RG] 表单")).firstMatch
    }

    func testFormCardControlsAndSubmit() {
        launch(["--ui-regression-seed"])
        waitFor(field, "输入框")
        expectPage(1, "启动落在聊天页")
        swipeToPrev()
        expectPage(0, "翻到列表")
        waitFor(formRow, "列表里的「[RG] 表单」")
        formRow.tap()
        expectPage(1, "点对话自动翻到聊天页")
        let submit = app.buttons["提交"].firstMatch
        waitFor(submit, "表单卡的提交按钮", timeout: 15)
        Thread.sleep(forTimeInterval: 1)
        snap("form-0-card")
        app.buttons["海边"].firstMatch.tap()
        app.buttons["猫"].firstMatch.tap()
        snap("form-1-picked")
        submit.tap()
        Thread.sleep(forTimeInterval: 2)
        snap("form-2-sent")
    }
}
