import XCTest

/// B2 两回归复现器（plan-keyboard-b2-regressions v2 验证面）：
/// 回归1 回底按钮锚点：断言**不用桥值自证**（sol 终审点名 v1 会假绿）——直接比较按钮 frame
/// 与输入字段 frame 的相对位置（按钮底应贴字段顶上方 8pt 带内，且整体在屏内）。
/// 回归2 多行输入留白：打多行文本撑高输入条后，尾条消息（KBMARKER123）不被输入区盖住。
/// ⚠️ 不真发消息（生产 hub 隔离铁律）；英文输入（模拟器中文键盘打不出教训）。
final class KeyboardB2RegressionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 输入字段：按 accessibilityIdentifier 精确抓（气泡正文同为 TextView，firstMatch 会误配——
    /// 首轮两 fail 的根因，KBMARKER123 气泡被当成了输入字段）
    private func inputField(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat-input-field"].firstMatch
    }

    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed"]
        app.launch()
        sleep(8)
        return app
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        sleep(2)
    }

    /// 回归1：离底时回底按钮可见，且锚在输入字段顶上方带内（不飞天、不压字段）。
    /// v1 病根（barTop≈0 → bottomInset≈屏高 → 按钮飞出可视区）在这两条断言下必红。
    func testBackToBottomButtonAnchorsToField() {
        let app = launchSeeded()
        // 离底：翻历史两次
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
            sleep(1)
        }
        let button = app.descendants(matching: .any).matching(identifier: "scroll-to-bottom").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), "离底后回底按钮没出现")
        let field = inputField(app)
        XCTAssertTrue(field.exists, "输入字段找不到（textView/textField 都没有）")
        let bf = button.frame
        let ff = field.frame
        let window = app.windows.firstMatch.frame
        NSLog("[KB-B2R] button=\(bf) field=\(ff) window=\(window)")
        snap(app, "r1-button-vs-field")
        XCTAssertTrue(window.contains(bf), "回归1：按钮飞出屏幕（v1 barTop 坐标系病根的表征）")
        // 按钮底 ∈ [字段顶-60, 字段顶-2]：8pt 设计间距 + 容差；锚错到容器顶/飞天都会出带
        XCTAssertLessThanOrEqual(bf.maxY, ff.minY - 2, "回归1：按钮压到输入字段上")
        XCTAssertGreaterThanOrEqual(bf.maxY, ff.minY - 60, "回归1：按钮离字段过远（锚点偏高）")
    }

    /// 回归2：多行输入撑高输入条后，尾条消息不被输入区盖住；删回单行恢复。
    func testMultilineInputPushesListUp() {
        let app = launchSeeded()
        let marker = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'KBMARKER123'")).firstMatch
        XCTAssertTrue(marker.exists, "seed 尾条没渲染")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        sleep(3)
        let field = inputField(app)
        XCTAssertTrue(field.exists, "聚焦后输入字段找不到")
        let singleLineTop = field.frame.minY

        // 长文本自动折行撑多行（XCUI 硬件键盘 \n 对 SwiftUI 多行 TextField 是 submit 不是换行，
        // 首轮实证 5 段全排一行）；app.typeText 打进当前焦点元素。40×"wrap " ≈ 200 字符 ≈ 5 行
        app.typeText(String(repeating: "wrap ", count: 40))
        sleep(2)
        let grown = inputField(app)
        let grownTop = grown.frame.minY
        let markerFrame = marker.exists ? marker.frame : .zero
        NSLog("[KB-B2R] singleTop=\(singleLineTop) grownTop=\(grownTop) marker=\(markerFrame)")
        NSLog("[KB-B2R] field h=\(grown.frame.height) value=\(String(describing: grown.value).prefix(80))")
        snap(app, "r2-multiline")
        XCTAssertLessThan(grownTop, singleLineTop - 30, "回归2前提：多行没把字段顶推上去（键盘布局异常？）")
        XCTAssertTrue(marker.exists && markerFrame.maxY <= grownTop + 1,
                      "回归2：多行输入把尾条消息盖住了（垫块没吃 barGrowth）")

        // 删回单行 → 字段顶回落 ≈ 原位（±20 容差），尾条仍可见
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 205))
        sleep(2)
        let restoredTop = inputField(app).frame.minY
        NSLog("[KB-B2R] restoredTop=\(restoredTop)")
        snap(app, "r2-restored")
        XCTAssertEqual(restoredTop, singleLineTop, accuracy: 20, "回归2：删回单行后字段顶没恢复")
        XCTAssertTrue(marker.exists && marker.frame.maxY <= restoredTop + 1, "回归2：恢复单行后尾条被盖")
    }
}
