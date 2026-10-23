import XCTest

/// page1 时间分割线 = 居中一个时间、上下等距（粟粟 10-11 去波浪线）：滚到顶拍一张给人眼看
@MainActor
final class ChatTimeDividerUITests: XCTestCase {
    private let app = XCUIApplication()

    func testDividerSnapshot() {
        app.launchArguments = ["--kb-probe-seed", "-onboardingCompletedV1", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chat-input-field"].firstMatch.waitForExistence(timeout: 30))
        for _ in 0..<8 { app.swipeDown(velocity: .fast) }
        sleep(2)
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "divider-top"
        a.lifetime = .keepAlways
        add(a)
    }
}
