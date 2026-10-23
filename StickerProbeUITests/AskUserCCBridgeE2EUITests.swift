import XCTest

/// 问问题 CC 桥 E2E（plan-问问题-cc桥 M5）：真实 hub + 隔离 session（mp-cc-ask1）。
/// idb/cliclick 对 sheet 的合成触摸全部穿透（E2E 踩坑记录见 review），XCTest 注入是
/// 模拟器上唯一能点 sheet 的自动化通道——完整链路：建独立 session → 发消息 →
/// CC 调 AskUserQuestion → hook → hub 帧 → 选择卡 → 作答 → 键序落 TUI → resolved Q/A 泡。
/// ⚠️ 跑在一次性模拟器上（真实 hub 生产资源只碰 mp-cc-ask1）。
final class AskUserCCBridgeE2EUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// sheet 循环后 element.tap() 不稳定给焦点，keyboards.count 也会假阴——
    /// 坐标点 + hasKeyboardFocus（KVC）双判 + 重试
    private func focusChatInput(_ app: XCUIApplication) {
        // 输入框已 UIKit 化（UITextView 在 XCUI 树里不是 textField），用 .any 查（B2 复现器同款）
        let input = app.descendants(matching: .any)["chat-input-field"].firstMatch
        for _ in 0..<4 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.93)).tap()
            sleep(2)
            let focused = (input.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
            if focused || app.keyboards.count > 0 { return }
        }
        XCTFail("聊天输入框焦点起不来")
    }

    func testAskUserAnswerFlowOverCCBridge() throws {
        // 手动 E2E 工具（烧真实 CC 轮 + 需要 hub/隔离模拟器 + 输入焦点在 sheet 循环后有 flake）——
        // 显式开关才跑：TEST_RUNNER_ASKUSER_E2E=1 xcodebuild …
        // 2026-08-04 实录：答题主链（卡→键序→post→resolved 泡）在本测试 run4 内完整通过；
        // 剩余 flake 全在 focusChatInput（typeText 焦点），与被测功能无关。
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ASKUSER_E2E"] == "1", "手动 E2E：设 ASKUSER_E2E=1 再跑")
        let app = XCUIApplication()
        app.launch()
        sleep(6)

        // 通知权限弹窗防御（首启已拒过一般不会再弹）
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons["Don't Allow"]
        if dontAllow.waitForExistence(timeout: 3) { dontAllow.tap() }

        // 1. 模型 chip 打开 picker（默认 Claude Code）
        let chip = app.staticTexts["Claude Code"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "模型 chip 没找到")
        chip.tap()

        // 2. 独立 session：每轮唯一名（旧名会绑上轮对话显示「被占用」行 disabled，点了没反应）
        let sessionName = "mp-cc-a\(Int(Date().timeIntervalSince1970) % 1000000)"
        let field = app.textFields["mp-cc-N"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "session 字段没出现（picker 没开？）")
        sleep(3)   // session 列表加载
        field.tap()
        sleep(1)
        if let val = field.value as? String, !val.isEmpty, val != "mp-cc-N" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: val.count + 2))
        }
        field.typeText(sessionName)
        app.buttons["+ 新建"].tap()
        sleep(10)   // spawn + boot 安排 + onPick 收 picker
        XCTAssertFalse(field.exists, "picker 没收（spawn 失败？）")

        // 3. 发消息（英文避开中文键盘）
        let input = app.descendants(matching: .any)["chat-input-field"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "输入框没找到")
        focusChatInput(app)
        app.typeText("Call the AskUserQuestion tool right now: exactly 2 test questions in Chinese. Q1 single-choice with 3 short options. Q2 multiSelect with 3 short options. Automated bridge test, question content is up to you.")
        let send = app.buttons["Up"]   // 发送键 label（诊断 dump 实测；images 不可查）
        XCTAssertTrue(send.waitForExistence(timeout: 10), "发送键没出现（打字进错框？）")
        send.tap()

        // 4. 等选择卡（CC 冷 spawn + boot + 回帧，宽限 240s）——自由输入框是卡的独有元素
        let cardField = app.textFields["Type your answer…"]
        XCTAssertTrue(cardField.waitForExistence(timeout: 240), "选择卡没弹（hook→hub→帧链路断？）")
        sleep(1)

        // 5. Q1 单选：点第 3 个选项（label "3, xxx"）→ 自动翻 Q2
        let opt3 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '3,'")).firstMatch
        XCTAssertTrue(opt3.waitForExistence(timeout: 5), "Q1 选项 3 没找到")
        opt3.tap()
        sleep(1)

        // 6. Q2 多选：勾 1、2 → 确定
        let opt1 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '1,'")).firstMatch
        XCTAssertTrue(opt1.waitForExistence(timeout: 5), "Q2 选项 1 没找到")
        opt1.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '2,'")).firstMatch.tap()
        let confirm = app.buttons["确定"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "多选确定钮没找到")
        confirm.tap()

        // 7. 键序落 TUI → 用户提交 → PostToolUse → resolved 帧 → Q/A 真实 user 泡
        // Q/A 是真实 user 消息 = TextView（staticText 查不到，E2E 踩的）
        let qaBubble = app.textViews.matching(NSPredicate(format: "label CONTAINS 'Q: '")).firstMatch
        XCTAssertTrue(qaBubble.waitForExistence(timeout: 60), "resolved Q/A 泡没落（键序/hook/帧断？）")
        // 卡应已收
        XCTAssertFalse(cardField.exists, "答完卡没收")

        // 8. 第二轮：X 跳过路径 → hub 发 Esc → declined resolved → 跳过泡
        focusChatInput(app)
        app.typeText("Call AskUserQuestion again: 1 single-choice question with 2 short options in Chinese.")
        let send2 = app.buttons["Up"]
        XCTAssertTrue(send2.waitForExistence(timeout: 10), "第二轮发送键没出现")
        send2.tap()
        XCTAssertTrue(cardField.waitForExistence(timeout: 180), "第二张选择卡没弹")
        sleep(1)
        app.buttons["Close"].tap()
        let skipBubble = app.textViews.matching(NSPredicate(format: "label CONTAINS '跳过'")).firstMatch
        XCTAssertTrue(skipBubble.waitForExistence(timeout: 60), "declined 跳过泡没落")

        sleep(3)   // 尾窗（外部截图）
    }
}
