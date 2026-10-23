import XCTest

final class Page2StackUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor private func launch(stack: Bool = true, rendering: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "-page2RecentTool_v1", "", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchEnvironment["PAGE2_UI_TOUCH_TRACE"] = "1"
        if let rendering { app.launchEnvironment["PAGE2_UI_RENDERING"] = rendering }
        if stack { app.launchEnvironment["PAGE2_UI_STACK"] = "1" }
        app.launchPage2()
        XCTAssertTrue(app.otherElements["page2.free-home"].waitForExistence(timeout: 8))
        return app
    }
    @MainActor private func stack(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "page2.stack.")).firstMatch
    }
    @MainActor private func editor(_ app: XCUIApplication) -> XCUIElement {
        let root = stack(app)
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.7)
        let edit = app.buttons["编辑叠放"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let editor = app.collectionViews["page2.stack-editor-cards"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        return editor
    }
    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testStackBodyDragsWithCompleteWidgetEdges() throws {
        let app = launch(rendering: "clear")
        let root = stack(app)
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 3.4)
        let handle = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "page2.resize.")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let inset = root.frame.width / 2 - 9
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: handle.frame.midX - inset, dy: handle.frame.midY - inset))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.75, dy: 650))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: 140, thenHoldForDuration: 1)
        let moved = NSPredicate { _, _ in root.exists && root.frame.minY > 400 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5), .completed)
        XCTAssertFalse(app.collectionViews["page2.stack-editor-cards"].exists)
        save(app, "stack-body-dragged-clear-edges")
        let position = root.frame.minY
        app.buttons["完成"].firstMatch.tap(); app.launchPage2()
        XCTAssertTrue(root.waitForExistence(timeout: 8)); XCTAssertEqual(root.frame.minY, position, accuracy: 5)
    }
    @MainActor func testStackSwipesContinuouslyWithoutOpeningSearch() throws {
        let app = launch()
        let root = stack(app)
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let before = root.value as? String
        root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.01,
            thenDragTo: root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)), withVelocity: 220, thenHoldForDuration: 0.05)
        let changed = NSPredicate { _, _ in (root.value as? String) != before }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5), .completed)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "page2.spotlight-field").firstMatch.exists)
        save(app, "stack-after-continuous-swipe")
        let selected = root.value as? String
        app.launchPage2()
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        XCTAssertEqual(root.value as? String, selected)
    }
    @MainActor func testStackEditorAddsReordersRemovesAndPersistsOptions() throws {
        let app = launch()
        let editor = self.editor(app)
        let rotate = app.buttons["page2.stack-smart-rotate"].firstMatch
        let suggestions = app.buttons["page2.stack-suggestions"].firstMatch
        XCTAssertTrue(rotate.waitForExistence(timeout: 5)); rotate.tap(); suggestions.tap()
        XCTAssertEqual(rotate.value as? String, "开启")
        XCTAssertEqual(suggestions.value as? String, "开启")
        app.buttons["page2.stack-add"].tap()
        let addVocab = app.descendants(matching: .any).matching(identifier: "page2.widget-add.vocab").firstMatch
        XCTAssertTrue(addVocab.waitForExistence(timeout: 5)); addVocab.tap()
        let card = app.descendants(matching: .any).matching(identifier: "page2.stack-card.vocab").firstMatch
        let ready = NSPredicate { _, _ in card.exists && card.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
        let before = editor.value as? String
        XCTAssertTrue(before?.contains("单词") == true)
        save(app, "stack-editor-added-widget")
        let cards = app.collectionViews["page2.stack-editor-cards"].firstMatch
        let target = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: cards.frame.midX, dy: cards.frame.minY + 12))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5, thenDragTo: target, withVelocity: 140, thenHoldForDuration: 1.4)
        let reordered = NSPredicate { _, _ in (editor.value as? String) != before }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reordered, object: nil)], timeout: 5), .completed)
        save(app, "stack-editor-reordered")
        let remove = app.buttons["从叠放移除单词"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        let removed = NSPredicate { _, _ in (editor.value as? String)?.contains("单词") == false }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: removed, object: nil)], timeout: 5), .completed)
        app.buttons["page2.stack-done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        app.launchPage2()
        _ = self.editor(app)
        XCTAssertEqual(app.buttons["page2.stack-smart-rotate"].value as? String, "开启")
        XCTAssertEqual(app.buttons["page2.stack-suggestions"].value as? String, "开启")
        save(app, "stack-options-persisted")
    }
    @MainActor func testWidgetCanLeaveStackEditorAndLandOnHome() throws {
        let app = launch()
        let editor = self.editor(app)
        let card = app.descendants(matching: .any).matching(identifier: "page2.stack-card.todo").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 320, dy: 685)), withVelocity: 180, thenHoldForDuration: 0.5)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        let widget = app.otherElements["page2.widget.todo"].firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(widget.frame.minY, 500)
        XCTAssertFalse(stack(app).exists)
        save(app, "widget-left-stack-editor")
    }
    @MainActor func testWidgetsCombineIntoStack() throws {
        let app = launch(stack: false)
        let calendarApp = app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex.first { $0.frame.minY < 700 }
        try XCTUnwrap(calendarApp).press(forDuration: 3.4)
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 84 / 440, dy: 33)).tap()
        XCTAssertTrue(app.buttons["添加小组件"].waitForExistence(timeout: 5)); app.buttons["添加小组件"].tap()
        let add = app.descendants(matching: .any).matching(identifier: "page2.widget-add.calendar").firstMatch
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "widget-gallery-tree"; tree.lifetime = .keepAlways; self.add(tree)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        if add.frame.midY > app.frame.height - 170 { app.scrollViews["page2.widget-gallery"].firstMatch.swipeUp() }
        add.tap()
        XCTAssertTrue(app.scrollViews["page2.widget-gallery"].firstMatch.waitForNonExistence(timeout: 5))
        let source = app.descendants(matching: .any).matching(identifier: "page2.widget.calendar").firstMatch
        let target = app.descendants(matching: .any).matching(identifier: "page2.widget.todo").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.3,
            thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)), withVelocity: 180, thenHoldForDuration: 0.8)
        XCTAssertTrue(stack(app).waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        save(app, "widgets-combined-into-stack")
    }
}
