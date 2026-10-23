import XCTest

/// 加密提问卡验收（plan-secure-ask 验证 2）：配 scratchpad 的 secure-mock.py（127.0.0.1:9876）。
/// 发「secure」→ mock 回 secure 卡 → 点「填写」弹单填密码 → 保存 → 发送 → mock 回 run_command 带占位 → 加密值确认卡 → 允许 → 结果复述。
/// idb 点不进 sheet，确认卡只能走 XCUITest。默认跳过：`MP_SECURE_ASK_UIT=1` 才跑（依赖本机 mock）。
final class SecureAskUITests: XCTestCase {
    static let password = "Hunter2-Garden!9"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MP_SECURE_ASK_UIT"] == "1", "需要本机 secure-mock.py")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func el(_ app: XCUIApplication, _ contains: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
    }

    /// 保存后不该弹系统「存储密码」（app 内或 springboard）
    private func assertNoSavePasswordPrompt(_ app: XCUIApplication) {
        let pred = NSPredicate(format: "label CONTAINS[c] 'Save Password' OR label CONTAINS '存储密码' OR label CONTAINS '储存密码' OR label CONTAINS[c] 'Not Now'")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for host in [app, springboard] {
            if host.descendants(matching: .any).matching(pred).firstMatch.exists {
                XCTFail("弹了系统存储密码")
            }
        }
    }

    private func send(_ app: XCUIApplication) {
        let up = app.buttons["Up"]
        XCTAssertTrue(up.waitForExistence(timeout: 5), "找不到发送键")
        up.tap()
    }

    /// 审批卡在对话底部（10-03 起不弹窗）：新装机运行命令默认要问 → 先一张普通权限卡，再一张加密值卡（带「会用到加密值」）。
    /// 逐张点「允许这一次」直到出结果；文字按钮 isHittable 判不准，按坐标点。
    private func approveUntil(_ app: XCUIApplication, _ done: XCUIElement, tag: String) {
        var sawSecretCard = false
        for i in 0..<3 {
            if done.exists { break }
            let allow = app.buttons.matching(NSPredicate(format: "label == %@", "允许这一次"))
            guard allow.firstMatch.waitForExistence(timeout: 20) else { break }
            if el(app, "会用到加密值").exists { sawSecretCard = true }
            snap(app, "\(tag)-confirm\(i)")
            allow.element(boundBy: allow.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = done.waitForExistence(timeout: 6)
        }
        XCTAssertTrue(sawSecretCard, "没见到加密值审批卡")
    }

    /// 加密卡走「小卡 + 弹单」（plan-secure-ask-sheet）：等新出的「填写」→ 点开弹单
    private func openSheet(_ app: XCUIApplication, after send: () -> Void) {
        let fill = app.buttons.matching(NSPredicate(format: "label == %@", "填写"))
        let before = fill.count
        send()
        let deadline = Date().addingTimeInterval(20)
        while fill.count <= before && Date() < deadline { sleep(1) }
        XCTAssertGreaterThan(fill.count, before, "没出新的加密小卡")
        sleep(1)
        snap(app, "1-card")
        fill.element(boundBy: fill.count - 1).tap()
        XCTAssertTrue(app.buttons["保存"].waitForExistence(timeout: 5), "弹单没出来")
        sleep(1)
        XCTAssertGreaterThan(sheetTop(app), app.frame.height * 0.3, "弹单该先停在半屏")
        snap(app, "1b-sheet-half")
    }

    /// 弹单顶上那行说明的 y：半屏时在屏幕下半，全屏时贴顶
    private func sheetTop(_ app: XCUIApplication) -> CGFloat {
        el(app, "加密保存在这台设备").frame.minY
    }

    /// 表单卡：小卡 → 填写 → 弹单填账号（普通）+ 密码（加密）→ 保存即发 → 确认卡 → 允许 → 结果带账号原文 + 密码占位
    func testFormCardAllowOnce() {
        let app = openSmoke()
        openSheet(app) { typeAndSend(app, "form") }
        XCTAssertTrue(el(app, "account.proton.me").exists, "弹单没显示网站行")

        let acct = app.textFields["账号"]
        acct.tap()
        sleep(1)
        XCTAssertLessThan(sheetTop(app), app.frame.height * 0.3, "点输入框后弹单该升全屏")
        acct.typeText("root")
        let pw = app.secureTextFields["密码"]
        pw.tap()
        pw.typeText(Self.password)
        snap(app, "F2-sheet")
        // 表单保存即发（粟粟 10-03 表单提交直接发）
        app.buttons["保存"].tap()
        sleep(2)
        assertNoSavePasswordPrompt(app)
        XCTAssertFalse(app.buttons["保存"].exists, "保存后弹单没关")
        snap(app, "F3-sent")

        // 完成信号用 LEN=16（结果才有）；USER=root 在审批卡的命令预览里就有，不能当信号
        let result = el(app, "LEN=16")
        approveUntil(app, result, tag: "F4")
        XCTAssertTrue(result.waitForExistence(timeout: 30), "没收到工具结果")
        XCTAssertTrue(el(app, "USER=root PW={{secret:").exists, "结果里没有账号原文 + 密码占位")
        sleep(2)
        snap(app, "F5-result")
        XCTAssertTrue(el(app, "已保存").exists, "小卡没变成已保存")
        XCTAssertFalse(el(app, Self.password).exists, "界面上出现了真值")
    }

    private func typeAndSend(_ app: XCUIApplication, _ text: String) {
        let input = app.descendants(matching: .any)["chat-input-field"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "找不到输入框")
        input.tap()
        input.typeText(text)
        send(app)
    }

    private func openSmoke() -> XCUIApplication {
        let app = XCUIApplication()
        // 回归模拟器是新装机：跳过引导页（同 Page2 系列 UI 测试）
        app.launchArguments = ["--stream-smoke", "-onboardingCompletedV1", "YES"]
        // 新装首启选中的是 Claude Code（种子还没落），第二次启动才是 Mock——必须重启一次，
        // 否则「secure」会打到生产 hub（10-02 真出过：spawn 了 mp-cc-218f1851）
        app.launch()
        sleep(6)
        app.terminate()
        app.launch()
        sleep(10)
        // 启动落在新空对话（Claude Code）：点左上返回到列表，再进 [SMOKE]
        let smoke = el(app, "[SMOKE]")
        for _ in 0..<3 where !smoke.exists {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 38, dy: 91)).tap()
            sleep(2)
        }
        if smoke.exists { smoke.tap(); sleep(3) }
        XCTAssertTrue(el(app, "Mock").waitForExistence(timeout: 5), "当前模型不是 Mock，停下，别往 hub 发")
        XCTAssertFalse(el(app, "Claude Code").exists, "当前模型是 Claude Code，停下，别往 hub 发")
        return app
    }

    func testSecureCardAllowOnce() {
        let app = openSmoke()
        openSheet(app) { typeAndSend(app, "secure") }

        let field = app.secureTextFields["密码"]
        field.tap()
        field.typeText(Self.password)
        snap(app, "A2-sheet")
        // 单个加密卡保存 = 进输入框，按发送才发
        app.buttons["保存"].tap()
        sleep(2)
        assertNoSavePasswordPrompt(app)
        XCTAssertFalse(app.buttons["保存"].exists, "保存后弹单没关")
        snap(app, "A3-staged")
        send(app)

        let result = el(app, "工具结果是")
        approveUntil(app, result, tag: "A4")
        XCTAssertTrue(result.waitForExistence(timeout: 30), "没收到工具结果复述")
        sleep(2)
        snap(app, "A5-result")
        XCTAssertFalse(el(app, Self.password).exists, "界面上出现了真值")
    }
}
