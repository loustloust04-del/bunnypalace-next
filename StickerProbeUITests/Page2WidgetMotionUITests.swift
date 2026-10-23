import XCTest

final class Page2WidgetMotionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(_ pair: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchEnvironment["PAGE2_UI_WIDGET_PAIR"] = pair
        app.launchEnvironment["PAGE2_UI_RENDERING"] = "standard"
        app.launchEnvironment["PAGE2_UI_TOUCH_TRACE"] = "1"
        app.launchPage2()
        XCTAssertTrue(app.otherElements["page2.widget.todo"].firstMatch.waitForExistence(timeout: 8))
        return app
    }
    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func cross(_ pair: String) {
        let app = launch(pair)
        let source = app.otherElements["page2.widget.todo"].firstMatch
        let target = app.otherElements["page2.widget.calendar"].firstMatch
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 3.4)
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        let before = target.frame
        let oldSource = source.frame
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: oldSource.midX, dy: before.minY + oldSource.height * 0.35))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: 180, thenHoldForDuration: 0.2)
        let moved = NSPredicate { _, _ in source.exists && target.exists && source.frame.minY < before.minY + 20 && target.frame.minY > before.minY + 150 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5), .completed)
        XCTAssertFalse(app.alerts["主屏"].exists)
        save(app, "widget-cross-" + pair)
        app.buttons["完成"].firstMatch.tap()
        app.launchPage2()
        XCTAssertTrue(source.waitForExistence(timeout: 8)); XCTAssertTrue(target.exists)
        XCTAssertLessThan(source.frame.minY, target.frame.minY)
        save(app, "widget-cross-restarted-" + pair)
    }
    @MainActor func testSmallCrossesLargeAndPersists() { cross("small-large") }
    @MainActor func testMediumCrossesLargeAndPersists() { cross("medium-large") }
    @MainActor func testLargeCrossesSmallAndPersists() { cross("large-small") }
}
