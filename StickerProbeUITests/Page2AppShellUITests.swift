import XCTest

final class Page2AppShellUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_ARC_TRACE"] = "1"
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        // Establish an empty switcher through UI: the shared simulator may have
        // a user's previously opened tool restored by SceneStorage.
        let corner = app.buttons["page2.cornerGesture"]
        // A hidden UIKit gesture surface can still exist in the accessibility
        // hierarchy. Establish the foreground app from a hittable home icon.
        let icons = app.buttons.matching(identifier: "page2.app.memory").allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.width >= 40 && app.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        if let icon = icons.min(by: { $0.frame.minY < $1.frame.minY }) {
            icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(corner.waitForExistence(timeout: 5))
        XCTAssertTrue(app.statusBars.firstMatch.waitForNonExistence(timeout: 5))
        drag(app, to: CGPoint(x: 102, y: 102))
        let closes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "page2.close."))
        XCTAssertTrue(closes.firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            guard let close = closes.allElementsBoundByIndex.first else { break }
            let id = close.identifier
            close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons[id].waitForNonExistence(timeout: 5))
        }
        return app
    }
    @MainActor private func drag(_ app: XCUIApplication, from: CGPoint = CGPoint(x: 32, y: 32), to: CGPoint) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: from.x, dy: from.y)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)), withVelocity: 150, thenHoldForDuration: 0.15)
    }
    @MainActor private func openMemory(_ app: XCUIApplication) {
        let icon = app.buttons["page2.app.memory"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        icon.tap()
        XCTAssertTrue(app.buttons["page2.cornerGesture"].waitForExistence(timeout: 5))
    }
    @MainActor private func assertDesktop(_ app: XCUIApplication) {
        let icon = app.buttons["page2.app.memory"].firstMatch
        let usable = NSPredicate { _, _ in icon.exists && icon.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: usable, object: nil)], timeout: 5), .completed)
    }
    @MainActor func testCardRoundTripAndCloseReturnsToDesktop() {
        let app = launch()
        openMemory(app)
        drag(app, to: CGPoint(x: 102, y: 102))
        let close = app.buttons["page2.close.memory"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let card = app.buttons["page2.card.memory"]
        XCTAssertTrue(card.exists)
        // XCTest's automatic hit-point lookup returns (-1, -1) in this nested
        // pager despite a visible, correctly bounded card and a completed motion.
        // Send the real touch to the observed center; subsequent state assertions
        // still fail if the control does not receive it or opens the wrong state.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        drag(app, to: CGPoint(x: 102, y: 102))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        assertDesktop(app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testLibraryChromeSlidesAwayAndReturns() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        let pager = app.scrollViews["page2.native-pager"].firstMatch
        let dock = app.scrollViews["page2.dock"].firstMatch
        let indicator = app.buttons["page2.page-control"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        XCTAssertTrue(dock.waitForExistence(timeout: 5))
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        let dockFrame = dock.frame
        let indicatorFrame = indicator.frame
        XCTAssertGreaterThan(dockFrame.minY, app.frame.height * 0.7)
        let origin = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55))
        origin.press(forDuration: 0.05,
                     thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.74, dy: 0.55)),
                     withVelocity: 120, thenHoldForDuration: 0.2)
        XCTAssertEqual(dock.frame.minX, dockFrame.minX, accuracy: 2)
        XCTAssertEqual(dock.frame.minY, dockFrame.minY, accuracy: 2)
        origin.press(forDuration: 0.05,
                     thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.55)),
                     withVelocity: 120, thenHoldForDuration: 0.4)
        let libraryReady = NSPredicate { _, _ in (pager.value as? String) == "第2页，共2页" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: libraryReady, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(!dock.exists || dock.frame.maxX <= app.frame.minX + 1)
        XCTAssertTrue(!indicator.exists || indicator.frame.maxX <= app.frame.minX + 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "library-without-dock-and-indicator"; shot.lifetime = .keepAlways; add(shot)
        pager.swipeRight()
        let returned = NSPredicate { _, _ in (pager.value as? String) == "第1页，共2页" && dock.exists && abs(dock.frame.minX - dockFrame.minX) < 2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 5), .completed)
        XCTAssertEqual(dock.frame.minY, dockFrame.minY, accuracy: 2)
        XCTAssertEqual(indicator.frame.midX, indicatorFrame.midX, accuracy: 2)
        for _ in 0..<2 { pager.swipeLeft(velocity: .fast); pager.swipeRight(velocity: .fast) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 5), .completed)
        let calendar = dock.buttons["page2.app.calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        calendar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["日记"].firstMatch.waitForExistence(timeout: 5))
        drag(app, to: CGPoint(x: 102, y: 102))
        let close = app.buttons["page2.close.calendar"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }
    @MainActor func testSingleAndMultipleCardLayoutKeepsCloseInside() {
        let app = launch()
        openMemory(app)
        drag(app, to: CGPoint(x: 102, y: 102))
        let memory = app.buttons["page2.card.memory"]
        XCTAssertTrue(memory.waitForExistence(timeout: 5))
        let large = memory.frame
        XCTAssertGreaterThan(large.width, app.frame.width * 0.6)
        XCTAssertEqual(large.midX, app.frame.midX, accuracy: 2)
        XCTAssertTrue(large.contains(app.buttons["page2.close.memory"].frame))
        memory.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(memory.waitForNonExistence(timeout: 5))
        drag(app, to: CGPoint(x: 190, y: 190))
        let calendarIcon = app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex.filter {
            app.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) && $0.frame.width >= 40
        }.min { $0.frame.minY < $1.frame.minY }
        guard let calendarIcon else { XCTFail("缺少日历入口"); return }
        calendarIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["日记"].firstMatch.waitForExistence(timeout: 5))
        drag(app, to: CGPoint(x: 102, y: 102))
        let calendar = app.buttons["page2.card.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        XCTAssertLessThan(memory.frame.width, large.width * 0.8)
        XCTAssertEqual(memory.frame.width, calendar.frame.width, accuracy: 1)
        XCTAssertTrue(calendar.frame.contains(app.buttons["page2.close.calendar"].frame))
        app.buttons["page2.close.calendar"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(calendar.waitForNonExistence(timeout: 5))
        let expanded = NSPredicate { _, _ in abs(memory.frame.width - large.width) < 2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expanded, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(memory.frame.contains(app.buttons["page2.close.memory"].frame))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "single-large-card-close-inside"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["page2.close.memory"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(memory.waitForNonExistence(timeout: 5))
    }
    @MainActor func testSwipeUpClosesLastCard() {
        let app = launch()
        openMemory(app)
        drag(app, to: CGPoint(x: 102, y: 102))
        let card = app.buttons["page2.card.memory"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let frame = card.frame
        drag(app, from: CGPoint(x: frame.midX, y: frame.midY),
             to: CGPoint(x: frame.midX, y: frame.midY - 130))
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        assertDesktop(app)
        XCTAssertFalse(app.buttons["page2.cornerGesture"].isHittable)
    }
    @MainActor func testShortDragCancelsAndHomeDragReleasesPaging() {
        let app = launch()
        openMemory(app)
        drag(app, to: CGPoint(x: 44, y: 44))
        XCTAssertTrue(app.buttons["page2.cornerGesture"].exists)
        XCTAssertFalse(app.buttons["page2.close.memory"].exists)
        drag(app, to: CGPoint(x: 190, y: 190))
        // Home and App Library duplicate icon identifiers. Prove the desktop is
        // usable by opening a different app at its observed on-screen position,
        // rather than asking isHittable of an arbitrary first cached icon.
        let calendars = app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex.filter {
            let frame = $0.frame
            return frame.width >= 40 && app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        guard let calendar = calendars.min(by: { $0.frame.minY < $1.frame.minY }) else {
            XCTFail("回主屏后没有可定位的日历图标"); return
        }
        calendar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let diary = app.buttons["日记"].firstMatch
        XCTAssertTrue(diary.waitForExistence(timeout: 5))
        diary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let diaryList = app.navigationBars["楼层日记"]
        XCTAssertTrue(diaryList.waitForExistence(timeout: 5))
        app.buttons["关闭"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(diaryList.waitForNonExistence(timeout: 5))
        // Prove paging by interacting with the real chat UITextView after the swipe.
        // No message is typed or sent.
        drag(app, from: CGPoint(x: 60, y: 480), to: CGPoint(x: 360, y: 480))
        let input = app.textViews["chat-input-field"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }
}
