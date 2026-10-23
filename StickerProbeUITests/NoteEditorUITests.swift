import XCTest

/// 便利贴原地编辑（docs/plan-page1-note-drawing.md §E）：+ 面板 → 便利贴 → 纸上直接打字 → 切几种纸 / 字体 → 点空白贴到对话里。拍图给人眼看纸样。
@MainActor
final class NoteEditorUITests: XCTestCase {
    private let app = XCUIApplication()

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testWriteAndPlaceNote() {
        app.launchArguments = ["--kb-probe-seed", "-onboardingCompletedV1", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chat-input-field"].firstMatch.waitForExistence(timeout: 30))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.908)).tap()
        let note = app.buttons["便利贴"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "+ 面板里没有便利贴")
        if !note.isHittable {
            app.scrollViews.containing(.button, identifier: "note.text.badge.plus").firstMatch.swipeLeft()
            sleep(1)
        }
        note.tap()
        let paper = app.descendants(matching: .any)["note-editor-paper"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 5), "便利贴编辑没出来")
        sleep(1)
        app.typeText("周六去买花\n洋桔梗和尤加利")
        sleep(1)
        snap("0-sticky")

        for kind in ["牛皮纸", "拍立得", "和纸胶带", "撕边纸条", "线圈本"] {
            let chip = app.buttons[kind].firstMatch
            if !chip.isHittable { app.scrollViews.containing(.button, identifier: "便利贴").firstMatch.swipeLeft() }
            chip.tap()
            sleep(1)
            snap("1-\(kind)")
        }
        app.buttons["手写"].firstMatch.tap()
        sleep(1)
        snap("2-hand-font")

        // 点压暗的空白处：保存并贴到对话里
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap()
        XCTAssertTrue(paper.waitForNonExistence(timeout: 5), "点空白没收起")
        sleep(2)
        snap("3-placed")
    }
}
