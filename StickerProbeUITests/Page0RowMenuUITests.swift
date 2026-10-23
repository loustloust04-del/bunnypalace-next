import XCTest

/// page0 对话行长按菜单 = page1 同款自绘浮层（docs/plan-page0-row-menu.md，粟粟 10-11）：
/// 顶排图标 Rename / Copy / Pin / Star / Delete，下面文字行，不再出系统大菜单；点 Rename 进行内改名。
@MainActor
final class Page0RowMenuUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--kb-probe-seed", "-onboardingCompletedV1", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chat-input-field"].firstMatch.waitForExistence(timeout: 30))
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func el(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testLongPressShowsCompactMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.40))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.40)),
                   withVelocity: .default, thenHoldForDuration: 0)
        sleep(2)
        snap("0-list")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.8)
        sleep(1)
        snap("1-menu")

        // 顶排图标格 accessibilityLabel = 中文 title；文字行照旧
        for label in ["重命名", "复制对话", "置顶对话", "收藏整个对话", "删除", "重新生成标题", "导出为 Markdown"] {
            XCTAssertTrue(el(label).exists, "菜单里缺「\(label)」")
        }
        XCTAssertFalse(el("终端").exists)
        el("重命名").tap()
        sleep(1)
        snap("2-rename")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3), "点重命名没出改名框")
    }
}
