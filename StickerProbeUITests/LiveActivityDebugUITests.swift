import XCTest

/// M1 收尾验收的起岛驱动。
///
/// 设置页是 SwiftUI sheet，idb / cliclick 的合成触摸对 sheet 内部全部穿透
/// （同 `AskUserCCBridgeE2EUITests` 的踩坑），XCTest 注入是模拟器上唯一能点到
/// CC 设置页底部 DEBUG 小节的通道。本用例只负责**把假数据 Live Activity 起起来**；
/// 截图（锁屏卡 / 紧凑态 / 长按展开）在 SpringBoard 上做，idb + simctl 就够。
///
/// 默认 skip，显式指定状态才跑：
/// `TEST_RUNNER_LA_DEBUG_STATE=working xcodebuild test -only-testing:StickerProbeUITests/LiveActivityDebugUITests`
final class LiveActivityDebugUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let buttonLabels = [
        "idle": "idle",
        "working": "working (ctx 22)",
        "waiting": "waiting (ctx 47)",
        "done": "done (ctx 75)",
        "end": "end",
    ]

    /// 在给定的归一化纵向位置往上拖一段——外层设置表和内嵌的 CC List 都靠这个滚。
    private func dragUp(_ app: XCUIApplication, at y: CGFloat, by delta: CGFloat = 0.22) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y - delta))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @discardableResult
    private func reveal(
        _ app: XCUIApplication,
        _ element: XCUIElement,
        scrollAt y: CGFloat,
        tries: Int = 14
    ) -> Bool {
        for _ in 0..<tries {
            if element.exists && element.isHittable { return true }
            dragUp(app, at: y)
            usleep(400_000)
        }
        return element.exists && element.isHittable
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testStartDebugLiveActivity() throws {
        let key = ProcessInfo.processInfo.environment["LA_DEBUG_STATE"] ?? ""
        guard let label = Self.buttonLabels[key] else {
            throw XCTSkip("设 LA_DEBUG_STATE=idle|working|waiting|done|end 再跑")
        }

        let app = XCUIApplication()
        app.launch()
        sleep(6)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons["Don't Allow"]
        if dontAllow.waitForExistence(timeout: 3) { dontAllow.tap() }

        // 会话页 → 列表页（齿轮只在列表页底部）
        let gear = app.buttons["gearshape"]
        if !gear.waitForExistence(timeout: 3) {
            let back = app.buttons["Back"]
            if back.exists { back.tap() }
            sleep(2)
        }
        XCTAssertTrue(gear.waitForExistence(timeout: 8), "找不到设置齿轮")
        gear.tap()
        sleep(3)

        // 设置表会恢复上次停留的页签和折叠组状态，所以先直接找按钮；
        // 找不到才走「编程工具」→「Claude Code」这条冷启动路径（折叠组已展开时点它反而收起来）。
        // CC 设置页是定高 430 的内嵌 List，DEBUG 小节在它自己的底部。
        let target = app.buttons[label]
        if !reveal(app, target, scrollAt: 0.62, tries: 8) {
            let devTools = app.buttons["编程工具"]
            if reveal(app, devTools, scrollAt: 0.75, tries: 10) {
                devTools.tap()
                sleep(1)
            }
            let claudeCode = app.buttons["Claude Code"]
            XCTAssertTrue(reveal(app, claudeCode, scrollAt: 0.75, tries: 10), "滚不到「Claude Code」")
            claudeCode.tap()
            sleep(3)
            XCTAssertTrue(reveal(app, target, scrollAt: 0.62, tries: 16), "滚不到 DEBUG 按钮「\(label)」")
        }
        snap("before-\(key)")
        target.tap()
        sleep(3)
        snap("after-\(key)")

        // 退到后台，Live Activity 才会以灵动岛形态出现在 SpringBoard 上
        XCUIDevice.shared.press(.home)
        sleep(3)
    }
}
