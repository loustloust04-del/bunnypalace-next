import XCTest

/// Page2「聊天（css自定义）」的实机自验壳。
///
/// 存在的理由：实机上没有 idb，我点不进这个 app，每次验证都得麻烦粟粟。
/// 这个壳让 CI/本地能自己点进去、截图、把 webview 里的文字读出来。
final class Page2CssChatUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// 只为把包装进设备：`devicectl device install` 会静默不生效（报 App installed 却没替换），
    /// xcodebuild 的安装通道才可靠。这个用例**只启动、不点任何东西**——粟粟在用这台手机。
    @MainActor
    func testInstallOnly() throws {
        XCUIApplication().launch()
    }

    @MainActor
    func testOpenCssChatAndCapture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["page2-ui-test", "-onboardingCompletedV1", "YES", "-settings.proMode", "YES"]
        app.launch()

        // selectedToolId 是持久化的：上次进过 cssChat 的话，这次启动就直接停在里面，
        // 桌面上自然找不到图标。两种状态都要能处理。
        let placeholder = app.staticTexts["说点什么…"].firstMatch
        let alreadyInside = placeholder.waitForExistence(timeout: 6)

        if !alreadyInside {
            let cssChat = app.buttons["page2.app.cssChat"].firstMatch
            if !cssChat.waitForExistence(timeout: 4) {
                let forward = app.buttons["chevron.right"].firstMatch
                if forward.isHittable { forward.tap() } else { app.swipeLeft() }
            }
            if !cssChat.waitForExistence(timeout: 8) {
                app.swipeLeft()
                let library = app.textFields["App 资源库"].firstMatch
                if library.waitForExistence(timeout: 5) {
                    library.tap(); library.typeText("聊天")
                }
            }
            XCTAssertTrue(cssChat.waitForExistence(timeout: 20), "Page2 上找不到 page2.app.cssChat")
            save(app.screenshot(), name: "01-page2-找到入口")
            cssChat.tap()
        } else {
            save(app.screenshot(), name: "01-启动即在-cssChat")
        }

        // webview 里的内容会暴露成 accessibility 元素，等第一条文字出现
        let anyText = app.staticTexts.firstMatch
        _ = anyText.waitForExistence(timeout: 12)
        save(app.screenshot(), name: "02-cssChat-打开后")

        // 把 webview 里读到的文字打出来——这是判断「渲染了什么」最直接的证据
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(25).map { $0.label }
        print("=== CSSCHAT WEBVIEW 文本 (\(texts.count)) ===")
        for t in texts { print("  · \(t)") }

        // 假数据的 id 是 demo-*，真数据不会有「第 N 条：」这种文案
        let looksLikeDemo = texts.contains { $0.contains("第 ") && $0.contains(" 条：") }
        print("=== 是否假数据: \(looksLikeDemo) ===")

        // 输入框在不在（web 起来了的最低证据）
        XCTAssertTrue(app.textViews.count > 0 || app.staticTexts.count > 0, "webview 里什么都没有")
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
