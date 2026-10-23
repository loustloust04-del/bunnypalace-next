import XCTest

/// 画板（docs/plan-page1-note-drawing.md）：+ 面板 → 画画 → 水彩 / 尖头 / 平头 / 铅笔各画一笔 → 撤销重做 → 贴上。拍图给人眼看笔触。
@MainActor
final class DrawingBoardUITests: XCTestCase {
    private let app = XCUIApplication()

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func stroke(_ canvas: XCUIElement, from: CGVector, to: CGVector, mid: CGVector) {
        canvas.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: mid), withVelocity: .slow, thenHoldForDuration: 0)
        canvas.coordinate(withNormalizedOffset: mid)
            .press(forDuration: 0.02, thenDragTo: canvas.coordinate(withNormalizedOffset: to), withVelocity: .default, thenHoldForDuration: 0)
    }

    func testDrawAndSave() {
        app.launchArguments = ["--kb-probe-seed", "-onboardingCompletedV1", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chat-input-field"].firstMatch.waitForExistence(timeout: 30))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.908)).tap()
        let draw = app.buttons["画画"].firstMatch
        XCTAssertTrue(draw.waitForExistence(timeout: 5), "+ 面板里没有画画")
        // 工具图标那排横向滚动，画画在屏外：先把那排往左推
        app.scrollViews.containing(.button, identifier: "paintbrush.pointed").firstMatch.swipeLeft()
        sleep(1)
        draw.tap()
        let canvas = app.descendants(matching: .any)["drawing-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        sleep(1)
        snap("0-empty")

        app.buttons["水彩"].firstMatch.tap()
        stroke(canvas, from: CGVector(dx: 0.12, dy: 0.18), to: CGVector(dx: 0.85, dy: 0.22), mid: CGVector(dx: 0.45, dy: 0.32))
        stroke(canvas, from: CGVector(dx: 0.15, dy: 0.32), to: CGVector(dx: 0.8, dy: 0.12), mid: CGVector(dx: 0.5, dy: 0.18))
        sleep(2)
        app.buttons["尖头钢笔"].firstMatch.tap()
        stroke(canvas, from: CGVector(dx: 0.1, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.52), mid: CGVector(dx: 0.5, dy: 0.42))
        app.buttons["平头钢笔"].firstMatch.tap()
        stroke(canvas, from: CGVector(dx: 0.1, dy: 0.68), to: CGVector(dx: 0.9, dy: 0.62), mid: CGVector(dx: 0.45, dy: 0.76))
        app.buttons["铅笔"].firstMatch.tap()
        stroke(canvas, from: CGVector(dx: 0.2, dy: 0.86), to: CGVector(dx: 0.8, dy: 0.84), mid: CGVector(dx: 0.5, dy: 0.92))
        sleep(2)
        snap("1-drawn")

        app.buttons["颜色"].firstMatch.tap()
        sleep(1)
        snap("1b-palette")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(1)

        app.buttons["撤销"].firstMatch.tap()
        sleep(1)
        snap("2-undo-pencil")
        app.buttons["重做"].firstMatch.tap()
        sleep(1)

        app.buttons["drawing-save"].firstMatch.tap()
        XCTAssertTrue(canvas.waitForNonExistence(timeout: 5), "贴上后画板没关")
        sleep(1)
        snap("3-saved")
    }
}
