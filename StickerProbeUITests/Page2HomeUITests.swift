import XCTest

final class Page2HomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func homeApp(_ app: XCUIApplication, id: String) throws -> XCUIElement {
        let screen = app.frame
        func visible() -> [XCUIElement] {
            app.buttons.matching(identifier: id).allElementsBoundByIndex.filter {
                let frame = $0.frame
                return frame.width >= 40 && frame.height >= 40 && screen.contains(CGPoint(x: frame.midX, y: frame.midY))
            }
        }
        let ready = NSPredicate { _, _ in !visible().isEmpty }
        if !ready.evaluate(with: nil) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
        }
        return try XCTUnwrap(visible().min { $0.frame.minY < $1.frame.minY })
    }

    @MainActor
    func testSearchFieldTracksKeyboardAndClosesBackToPill() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        let pill = app.buttons["搜索应用"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 8))
        let original = pill.frame
        for _ in 0..<2 {
            pill.tap()
            let field = app.descendants(matching: .any).matching(identifier: "page2.spotlight-field").firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let geometry = NSPredicate { _, _ in
                abs(field.frame.width - app.frame.width + 16) < 2 && abs(field.frame.height - 48) < 2 &&
                field.frame.maxY <= app.keyboards.firstMatch.frame.minY && app.keyboards.firstMatch.frame.minY - field.frame.maxY < 36
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: geometry, object: nil)], timeout: 5), .completed)
            XCTAssertEqual(field.frame.minX, 8, accuracy: 2)
            field.typeText("rili")
            let calendar = app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY < field.frame.minY }
            XCTAssertNotNil(calendar)
            save(app.screenshot(), name: "native-field-keyboard-geometry")
            app.buttons["page2.search-cancel"].firstMatch.tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
            XCTAssertTrue(pill.waitForExistence(timeout: 5))
            XCTAssertEqual(pill.frame.midY, original.midY, accuracy: 3)
        }
        save(app.screenshot(), name: "search-returned-to-pill")
    }

    @MainActor
    func testDockCreatesFolderAndExtractsChildWithoutCopyDrag() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchEnvironment["PAGE2_UI_TOUCH_TRACE"] = "1"
        app.launchPage2()
        try homeApp(app, id: "page2.app.calendar").press(forDuration: 3.4)
        let dock = app.scrollViews["page2.dock"].firstMatch
        let source = dock.buttons["page2.app.memory"].firstMatch
        let target = dock.buttons["page2.app.calendar"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5)); XCTAssertTrue(target.exists)
        let centeredTarget = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: (source.frame.midX - target.frame.midX) / 2, dy: 0))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2,
            thenDragTo: centeredTarget, withVelocity: 180, thenHoldForDuration: 0.5)
        let folder = dock.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "page2.folder.")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        save(app.screenshot(), name: "dock-created-folder")
        folder.tap()
        let title = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "文件夹")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        save(app.screenshot(), name: "dock-folder-open")
        let child = try XCTUnwrap(app.buttons.matching(identifier: "page2.app.memory").allElementsBoundByIndex.first {
            $0.frame.minY > 250 && $0.frame.maxY < 720 && $0.isHittable
        })
        child.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.2,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 370, dy: 735)), withVelocity: 180, thenHoldForDuration: 0.5)
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        let landed = NSPredicate { _, _ in
            app.buttons.matching(identifier: "page2.app.memory").allElementsBoundByIndex.contains { $0.frame.minY > 600 && $0.frame.minY < 800 && $0.frame.midX > 300 }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 5), .completed)
        save(app.screenshot(), name: "dock-folder-child-extracted")
        app.buttons["完成"].firstMatch.tap()
        app.launchPage2()
        XCTAssertTrue(folder.waitForExistence(timeout: 8)); folder.tap()
        let remaining = NSPredicate { _, _ in app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex.contains {
            $0.frame.minY > 250 && $0.frame.maxY < 720 && $0.isHittable
        } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: remaining, object: nil)], timeout: 5), .completed)
        save(app.screenshot(), name: "dock-folder-survives-relaunch")
    }

    @MainActor
    func testDockAppDragsDirectlyOntoHome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchEnvironment["PAGE2_UI_TOUCH_TRACE"] = "1"
        app.launchPage2()
        try homeApp(app, id: "page2.app.calendar").press(forDuration: 3.4)
        let dock = app.scrollViews["page2.dock"].firstMatch
        let reading = dock.buttons["page2.app.reading"].firstMatch
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        let indicator = app.buttons["page2.page-control"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        // y=700 lies below the current safe-area-adjusted grid. Use the empty
        // row above the indicator, and avoid the page-turn zone at the right edge.
        let destination = CGPoint(x: reading.frame.midX, y: indicator.frame.minY - 60)
        reading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: destination.x, dy: destination.y)), withVelocity: 180, thenHoldForDuration: 0.3)
        XCTAssertTrue(reading.waitForNonExistence(timeout: 5))
        let landed = NSPredicate { _, _ in
            app.buttons.matching(identifier: "page2.app.reading").allElementsBoundByIndex.contains { abs($0.frame.midX - destination.x) < 40 && abs($0.frame.midY - destination.y) < 70 && $0.frame.maxY < indicator.frame.minY }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 5), .completed)
        save(app.screenshot(), name: "dock-app-direct-home-drag")
    }

    @MainActor
    func testAppCrossesLargeWidgetWithoutLosingIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchEnvironment["PAGE2_UI_LARGE_WIDGET"] = "1"
        app.launchPage2()
        try homeApp(app, id: "page2.app.calendar").press(forDuration: 3.4)
        let handle = app.otherElements["page2.resize.todo"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let initial = handle.frame
        let source = try homeApp(app, id: "page2.app.calendar")
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let top = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: source.frame.midX, dy: source.frame.minY - 3 * 108.667 + 34))
        start.press(forDuration: 0.2, thenDragTo: top, withVelocity: 180, thenHoldForDuration: 0.5)
        let down = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in handle.exists && handle.frame.midY > initial.midY + 180 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [down], timeout: 5), .completed)
        save(app.screenshot(), name: "large-widget-yields-down")
        let moved = try homeApp(app, id: "page2.app.calendar")
        XCTAssertLessThan(moved.frame.minY, 300)
        let next = moved.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        next.press(forDuration: 0.2, thenDragTo: next.withOffset(CGVector(dx: 0, dy: 3 * 108.667)), withVelocity: 180, thenHoldForDuration: 0.5)
        let up = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in handle.exists && abs(handle.frame.midY - initial.midY) < 4 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [up], timeout: 5), .completed)
        save(app.screenshot(), name: "large-widget-yields-up")
        app.buttons["完成"].firstMatch.tap()
        app.launchPage2()
        try homeApp(app, id: "page2.app.calendar").press(forDuration: 3.4)
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        XCTAssertEqual(handle.frame.midY, initial.midY, accuracy: 4)
        XCTAssertTrue(app.otherElements["page2.widget.todo"].firstMatch.exists)
        save(app.screenshot(), name: "large-widget-survives-relaunch")
    }

    @MainActor
    func testWidgetHandleResizesAndPersists() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "NO", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchEnvironment["PAGE2_UI_TOUCH_TRACE"] = "1"
        app.launchPage2()
        let calendar = try homeApp(app, id: "page2.app.calendar")
        calendar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 3.4)
        let handle = app.otherElements["page2.resize.todo"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let widget = app.otherElements["page2.widget.todo"].firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5))
        let originalHandle = handle.frame
        func resizeBy(_ delta: CGVector) {
            let source = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            source.press(forDuration: 0.05, thenDragTo: source.withOffset(delta), withVelocity: 160, thenHoldForDuration: 0.3)
        }
        resizeBy(CGVector(dx: 201, dy: 0))
        let wide = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in handle.frame.midX > app.frame.width - 60 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wide], timeout: 4), .completed)
        XCTAssertEqual(handle.frame.midY, originalHandle.midY, accuracy: 4)
        XCTAssertFalse(app.alerts["主屏"].exists)
        save(app.screenshot(), name: "page2-widget-medium")
        resizeBy(CGVector(dx: 0, dy: 217))
        let tall = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in handle.frame.midY > originalHandle.midY + 200 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [tall], timeout: 4), .completed)
        save(app.screenshot(), name: "page2-widget-large")
        app.buttons["完成"].firstMatch.tap()
        app.launchPage2()
        XCTAssertTrue(widget.waitForExistence(timeout: 10))
        try homeApp(app, id: "page2.app.calendar").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 3.4)
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(handle.frame.midX, app.frame.width - 60)
        XCTAssertGreaterThan(handle.frame.midY, originalHandle.midY + 200)
        resizeBy(CGVector(dx: -201, dy: -217))
        let small = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(handle.frame.midX - originalHandle.midX) < 4 && abs(handle.frame.midY - originalHandle.midY) < 4 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [small], timeout: 4), .completed)
        save(app.screenshot(), name: "page2-widget-small")
    }

    @MainActor
    func testWidgetBodyDragsWithoutResizing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        try homeApp(app, id: "page2.app.calendar").press(forDuration: 3.4)
        let widget = app.otherElements["page2.widget.todo"].firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5))
        let original = widget.frame
        let source = widget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        source.press(forDuration: 0.2, thenDragTo: source.withOffset(CGVector(dx: 0, dy: 320)), withVelocity: 220, thenHoldForDuration: 0.3)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in widget.frame.minY > original.minY + 150 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        XCTAssertEqual(widget.frame.width, original.width, accuracy: 3)
        XCTAssertEqual(widget.frame.height, original.height, accuracy: 3)
        save(app.screenshot(), name: "page2-widget-moved")
    }

    @MainActor
    private func openLibrary(_ app: XCUIApplication) {
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        let pager = app.scrollViews["page2.native-pager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        pager.swipeLeft()
        XCTAssertTrue(app.textFields["App 资源库"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLibraryCategoriesExpandInFourColumns() throws {
        let app = XCUIApplication()
        openLibrary(app)
        let life = app.buttons["打开生活"].firstMatch
        XCTAssertTrue(life.waitForExistence(timeout: 5)); life.tap()
        let expanded = app.scrollViews["page2.library-expanded-grid"].firstMatch
        XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        let ids = ["topicBox", "health", "calendar", "sticker"]
        let cells = ids.map { expanded.buttons["page2.app.\($0)"].firstMatch }
        for cell in cells { XCTAssertTrue(cell.waitForExistence(timeout: 5)) }
        let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cells.allSatisfy { abs($0.frame.midY - cells[0].frame.midY) < 3 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 4), .completed)
        for index in 1..<cells.count {
            XCTAssertEqual(cells[index].frame.midX - cells[index-1].frame.midX, 100.667, accuracy: 3)
        }
        save(app.screenshot(), name: "page2-library-four-column-category")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        XCTAssertTrue(expanded.waitForNonExistence(timeout: 4))
        app.buttons["打开工具"].firstMatch.tap()
        XCTAssertTrue(app.buttons["page2.app.cssChat"].firstMatch.waitForExistence(timeout: 5))
        save(app.screenshot(), name: "page2-library-tools-include-css-chat")
        expanded.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.8)).tap()
        XCTAssertTrue(expanded.waitForNonExistence(timeout: 4))
    }

    @MainActor
    func testLibraryPinyinOrderSystemIndexAndSearchOpen() throws {
        let app = XCUIApplication()
        openLibrary(app)
        let search = app.textFields["App 资源库"].firstMatch
        search.tap()
        let table = app.tables["page2.library-results"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        func row(_ id: String) -> XCUIElement { table.descendants(matching: .any).matching(identifier: "page2.app.\(id)").firstMatch }
        let ids = ["ccTerminal", "vocab", "reading", "topicBox", "health"]
        for id in ids { XCTAssertTrue(row(id).waitForExistence(timeout: 5)) }
        let spaced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (1..<ids.count).allSatisfy { abs(row(ids[$0]).frame.minY - row(ids[$0-1]).frame.minY - 72) < 2 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [spaced], timeout: 4), .completed)
        let index = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'index' OR label CONTAINS '索引'")).firstMatch
        XCTAssertTrue(index.waitForExistence(timeout: 5))
        index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        let last = row("audiobook")
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in last.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(last.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        }
        save(app.screenshot(), name: "page2-library-native-index-keyboard")
        search.tap(); search.typeText("rili")
        XCTAssertTrue(row("calendar").waitForExistence(timeout: 5))
        XCTAssertFalse(row("health").exists)
        save(app.screenshot(), name: "page2-library-pinyin-query")
        row("calendar").coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.5)).press(forDuration: 0.8)
        let menu = app.buttons["添加到主屏"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 4))
        save(app.screenshot(), name: "page2-library-system-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.6)).tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 4))
        row("calendar").tap()
        XCTAssertTrue(app.otherElements["page2.free-home"].waitForNonExistence(timeout: 8))
    }

    @MainActor
    func testLibrarySearchAppCanDragBackToHome() throws {
        let app = XCUIApplication()
        openLibrary(app)
        let search = app.textFields["App 资源库"].firstMatch
        search.tap(); search.typeText("rili")
        let row = app.tables["page2.library-results"].descendants(matching: .any).matching(identifier: "page2.app.calendar").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.5)).press(forDuration: 1.2,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)), withVelocity: 200, thenHoldForDuration: 0.6)
        let home = app.scrollViews["page2.native-pager"].firstMatch
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "第1页"), object: home)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 6), .completed)
        let calendar = try homeApp(app, id: "page2.app.calendar")
        XCTAssertGreaterThan(calendar.frame.minY, 400)
        save(app.screenshot(), name: "page2-library-app-dragged-home")
    }

    @MainActor
    func testNativeHomePagingCancellationAndReversal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchEnvironment["PAGE2_UI_TOUCH_TRACE"] = "1"
        app.launchPage2()
        let pager = app.scrollViews["page2.native-pager"].firstMatch
        if !pager.waitForExistence(timeout: 8) {
            let forward = app.buttons["chevron.right"].firstMatch
            if forward.isHittable { forward.tap() } else { app.swipeLeft() }
        }
        XCTAssertTrue(pager.waitForExistence(timeout: 30))
        let calendar = try homeApp(app, id: "page2.app.calendar")
        let original = calendar.frame
        let start = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.62))
        let short = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.74, dy: 0.62))
        start.press(forDuration: 0.01, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.25)
        XCTAssertEqual(try homeApp(app, id: "page2.app.calendar").frame.minX, original.minX, accuracy: 2)
        let library = app.textFields["App 资源库"].firstMatch
        pager.swipeLeft()
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in library.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed)
        save(app.screenshot(), name: "page2-native-paging-library")
        pager.swipeRight()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex.contains {
                $0.isHittable && abs($0.frame.minX - original.minX) < 2 && abs($0.frame.minY - original.minY) < 2
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        XCTAssertEqual(try homeApp(app, id: "page2.app.calendar").frame.minX, original.minX, accuracy: 2)
        for _ in 0..<2 { pager.swipeLeft(velocity: .fast); pager.swipeRight(velocity: .fast) }
        let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex.contains {
                $0.isHittable && abs($0.frame.minX - original.minX) < 2 && abs($0.frame.minY - original.minY) < 2
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 5), .completed)
        save(app.screenshot(), name: "page2-native-paging-return")
    }

    @MainActor
    func testHomeSearchLibraryAndEditingGeometry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        let candidate = app.buttons["page2.app.calendar"].firstMatch
        if !candidate.waitForExistence(timeout: 8) {
            let forward = app.buttons["chevron.right"].firstMatch
            if forward.isHittable { forward.tap() } else { app.swipeLeft() }
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 30))
        app.buttons["搜索应用"].tap()
        let search = app.descendants(matching: .any).matching(identifier: "page2.spotlight-field").firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("日历")
        XCTAssertTrue(app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex.contains { $0.isHittable })
        save(app.screenshot(), name: "page2-spotlight-fourth")
        app.buttons["page2.search-cancel"].firstMatch.tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        app.scrollViews["page2.native-pager"].firstMatch.swipeLeft()
        let library = app.textFields["App 资源库"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        let libraryReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in library.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [libraryReady], timeout: 5), .completed)
        save(app.screenshot(), name: "page2-library-fourth")
        library.tap()
        library.typeText("日历")
        let result = app.tables["page2.library-results"].descendants(matching: .any).matching(identifier: "page2.app.calendar").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.isHittable)
        save(app.screenshot(), name: "page2-library-search-fourth")
        app.scrollViews["page2.native-pager"].firstMatch.swipeRight()
        let homeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (app.scrollViews["page2.native-pager"].firstMatch.value as? String)?.hasPrefix("第1页") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [homeReady], timeout: 5), .completed)
        let resumedCalendar = try homeApp(app, id: "page2.app.calendar")
        XCTAssertLessThan(resumedCalendar.frame.minY, 500)
        resumedCalendar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 3.0)
        let edit = app.buttons["编辑"].firstMatch
        let done = app.buttons["完成"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(edit.frame.minX, 40)
        XCTAssertGreaterThan(edit.frame.midY, 27)
        XCTAssertLessThan(edit.frame.midY, 42)
        XCTAssertEqual(edit.frame.midY, done.frame.midY, accuracy: 2)
        save(app.screenshot(), name: "page2-edit-position-fourth")
        done.tap()
        try homeApp(app, id: "page2.app.calendar").tap()
        XCTAssertTrue(app.otherElements["page2.free-home"].waitForNonExistence(timeout: 8))
    }

    @MainActor
    func testAppleIOS26HomeReference() throws {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            springboard.icons.allElementsBoundByIndex.contains { $0.isHittable && $0.frame.width > 20 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed)
        save(XCUIScreen.main.screenshot(), name: "apple-ios26-home")
        let candidates = springboard.icons.matching(NSPredicate(format: "label IN %@", ["Calendar", "日历"])).allElementsBoundByIndex
        if let calendar = candidates.first(where: { $0.isHittable && $0.frame.width > 20 }) {
            calendar.press(forDuration: 1.2)
            save(XCUIScreen.main.screenshot(), name: "apple-ios26-native-menu")
            let editHome = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Edit Home Screen", "编辑主屏幕"])).firstMatch
            if editHome.exists {
                editHome.tap()
                let edit = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Edit", "编辑"])).firstMatch
                if edit.waitForExistence(timeout: 3) {
                    edit.tap()
                    let customize = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Customize", "自定", "自定义"])).firstMatch
                    if customize.waitForExistence(timeout: 3) {
                        customize.tap()
                        let clear = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Clear", "透明"])).firstMatch
                        if clear.waitForExistence(timeout: 3) { clear.tap(); save(XCUIScreen.main.screenshot(), name: "apple-ios26-clear-customize") }
                    }
                }
            }
            XCUIDevice.shared.press(.home)
        }
    }

    @MainActor
    func testFreeHomeAndEditing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchPage2()
        let home = app.otherElements["page2.free-home"]
        if !home.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(home.waitForExistence(timeout: 30))
        save(app.screenshot(), name: "page2-home")
        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.4))
        point.press(forDuration: 1.2)
        save(app.screenshot(), name: "page2-edit")
        let done = app.buttons["完成"].firstMatch
        if done.exists { done.tap() }
        save(app.screenshot(), name: "page2-home-after-edit")
    }

    @MainActor
    func testNativeMenuAndToolNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchPage2()
        let home = app.otherElements["page2.free-home"]
        if !home.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(home.waitForExistence(timeout: 30))
        let calendar = try homeApp(app, id: "page2.app.calendar")
        XCTAssertTrue(calendar.waitForExistence(timeout: 8))
        calendar.press(forDuration: 0.65)
        XCTAssertTrue(app.buttons["编辑主屏幕"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["完成"].firstMatch.exists)
        app.buttons["编辑主屏幕"].firstMatch.tap()
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        save(app.screenshot(), name: "page2-direct-long-press")
        let done = app.buttons["完成"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        calendar.tap()
        XCTAssertTrue(home.waitForNonExistence(timeout: 8))
        save(app.screenshot(), name: "page2-calendar-tool")
    }

    /// 开过子应用（挂后台、竖条有东西）再回桌面：长按图标照样出菜单（粟粟 10-14 报：长按不弹也拖不动）
    @MainActor
    func testLongPressMenuAfterReturningFromApp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_TOUCH_TRACE"] = "1"
        app.launchPage2()
        let home = app.otherElements["page2.free-home"]
        if !home.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(home.waitForExistence(timeout: 30))
        try homeApp(app, id: "page2.app.memory").tap()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let width = app.frame.width
        origin.withOffset(CGVector(dx: width - 8, dy: 400)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: width - 160, dy: 400)), withVelocity: 600, thenHoldForDuration: 0.1)
        sleep(1)
        save(app.screenshot(), name: "page2-strip-open")
        // 无障碍树里 ⌂ 的框是整条竖条（点中心会落到别的格子）；一个后台应用时 ⌂ 在竖条 y≈376
        let frames = app.buttons.matching(NSPredicate(format: "label == %@", "回桌面")).allElementsBoundByIndex.map(\.frame)
        print("[PROBE] home frames=\(frames)")
        origin.withOffset(CGVector(dx: width - 46, dy: 376)).tap()
        save(app.screenshot(), name: "page2-after-home-tap")
        let calendar = try homeApp(app, id: "page2.app.calendar")
        sleep(2)
        save(app.screenshot(), name: "page2-back-home")
        calendar.press(forDuration: 0.65)
        let menu = app.buttons["编辑主屏幕"].firstMatch.waitForExistence(timeout: 3)
        save(app.screenshot(), name: "page2-after-long-press")
        XCTAssertTrue(menu, "回桌面后长按图标没出菜单")
    }

    @MainActor
    func testDragToBlankCellPersistsAcrossLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        let home = app.otherElements["page2.free-home"]
        if !home.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(home.waitForExistence(timeout: 30))
        let calendar = app.buttons["page2.app.calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 8))
        let original = calendar.frame
        calendar.press(forDuration: 3.0)
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.705))
        calendar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2, thenDragTo: destination)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in calendar.frame.minY > original.minY + 300 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 8), .completed)
        save(app.screenshot(), name: "page2-drag-blank-cell")
        let done = app.buttons["完成"].firstMatch
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        let placement = calendar.frame
        app.terminate()
        app.launchPage2()
        if !home.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(home.waitForExistence(timeout: 30))
        XCTAssertTrue(calendar.waitForExistence(timeout: 8))
        XCTAssertEqual(calendar.frame.minX, placement.minX, accuracy: 2)
        XCTAssertEqual(calendar.frame.minY, placement.minY, accuracy: 2)
        save(app.screenshot(), name: "page2-restored-layout")
    }

    @MainActor
    func testReturnToChatAndOpenLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchPage2()
        let candidate = app.buttons["page2.app.calendar"].firstMatch
        if !candidate.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(candidate.waitForExistence(timeout: 30))
        let calendar = try homeApp(app, id: "page2.app.calendar")
        save(app.screenshot(), name: "page2-final-home")
        app.swipeRight()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.textViews["chat-input-field"].isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 8), .completed)
        app.swipeLeft()
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in calendar.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed)
        app.scrollViews["page2.native-pager"].firstMatch.swipeLeft()
        XCTAssertTrue(app.textFields["App 资源库"].firstMatch.waitForExistence(timeout: 5))
        save(app.screenshot(), name: "page2-app-library")
    }

    @MainActor
    func testEditingCanRemoveAndAddAppsAndWidgets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchPage2()
        let calendar = app.buttons["page2.app.calendar"].firstMatch
        if !calendar.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(calendar.waitForExistence(timeout: 30))
        save(app.screenshot(), name: "page2-clear-home")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55)).press(forDuration: 1)
        let edit = app.buttons["编辑"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        save(app.screenshot(), name: "page2-jiggle-a")
        Thread.sleep(forTimeInterval: 0.15)
        save(app.screenshot(), name: "page2-jiggle-b")
        let remove = app.buttons["从主屏移除日历"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        edit.tap()
        app.buttons["添加应用"].tap()
        let library = app.textFields["App 资源库"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        let selected = try XCTUnwrap(app.buttons.matching(identifier: "page2.app.calendar").allElementsBoundByIndex.first(where: \.isHittable))
        selected.tap()
        XCTAssertTrue(library.waitForNonExistence(timeout: 5))
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        edit.tap()
        app.buttons["添加小组件"].tap()
        let pet = app.buttons["添加宠物小组件"]
        XCTAssertTrue(pet.waitForExistence(timeout: 5))
        pet.tap()
        XCTAssertTrue(app.buttons["从主屏移除宠物"].waitForExistence(timeout: 5))
        let removeDock = app.buttons["从 Dock 移除日历"]
        XCTAssertTrue(removeDock.waitForExistence(timeout: 5))
        removeDock.tap()
        XCTAssertTrue(removeDock.waitForNonExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
        save(app.screenshot(), name: "page2-dock-glass-after-edit")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.65)).press(forDuration: 1)
        edit.tap()
        app.buttons["更换壁纸"].tap()
        let background = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "背景")).firstMatch
        XCTAssertTrue(background.waitForExistence(timeout: 5))
        background.tap()
        app.buttons["暮色玻璃"].tap()
        app.buttons["保存"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        save(app.screenshot(), name: "page2-dock-glass-dusk")
    }

    @MainActor
    func testVideoReferenceIconDragAndLanding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        let ready = NSPredicate { _, _ in
            app.buttons.matching(identifier: "page2.app.vocab").allElementsBoundByIndex.contains { $0.isHittable && $0.frame.minY < 700 }
        }
        for _ in 0..<3 {
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 4) == .completed { break }
            let forward = app.buttons["chevron.right"].firstMatch
            if forward.isHittable { forward.tap() } else { app.swipeLeft() }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
        let ids = ["vocab", "reading", "topicBox", "health"]
        let original = try ids.map { try homeApp(app, id: "page2.app.\($0)").frame }
        let source = try homeApp(app, id: "page2.app.vocab")
        let target = try homeApp(app, id: "page2.app.health").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.35))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.5, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.05)
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(identifier: "page2.app.vocab").allElementsBoundByIndex.contains {
                $0.isHittable && abs($0.frame.minX - original[3].minX) < 2 && abs($0.frame.minY - original[3].minY) < 2
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 5), .completed)
        for index in 1..<ids.count {
            let moved = try homeApp(app, id: "page2.app.\(ids[index])").frame
            XCTAssertEqual(moved.minX, original[index - 1].minX, accuracy: 2)
            XCTAssertEqual(moved.minY, original[index - 1].minY, accuracy: 2)
        }
        save(app.screenshot(), name: "page2-video-order-and-landing")
        app.buttons["完成"].firstMatch.tap()
    }

    @MainActor
    func testDraggingAcrossOccupiedCellsKeepsTheMovingGap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchPage2()
        let source = app.buttons["page2.app.vocab"].firstMatch
        if !source.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(source.waitForExistence(timeout: 30))
        let reading = app.buttons["page2.app.reading"].firstMatch
        let originalReadingX = reading.frame.minX
        source.press(forDuration: 3.0)
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        let target = app.buttons["page2.app.health"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15, thenDragTo: target)
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.buttons["编辑"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertLessThan(reading.frame.minX, originalReadingX - 50)
        XCTAssertGreaterThan(source.frame.minX, originalReadingX + 100)
        save(app.screenshot(), name: "page2-tungsten-moving-gap")
    }

    @MainActor
    func testFolderShortReleaseStaysClosed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        let ready = NSPredicate { _, _ in
            app.buttons.matching(identifier: "page2.app.vocab").allElementsBoundByIndex.contains { $0.isHittable && $0.frame.minY < 700 }
        }
        for _ in 0..<3 {
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 4) == .completed { break }
            let next = app.buttons["chevron.right"].firstMatch
            if next.exists && next.isHittable { next.tap() } else { app.swipeLeft() }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
        let sourceFrame = try homeApp(app, id: "page2.app.vocab").frame
        let targetFrame = try homeApp(app, id: "page2.app.reading").frame
        let canvas = app.coordinate(withNormalizedOffset: .zero)
        let from = canvas.withOffset(CGVector(dx: sourceFrame.midX, dy: sourceFrame.minY + sourceFrame.width / 2))
        let to = canvas.withOffset(CGVector(dx: targetFrame.midX, dy: targetFrame.minY + targetFrame.width / 2))
        from.press(forDuration: 0.5, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.25)
        let title = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "文件夹")).firstMatch
        XCTAssertFalse(title.exists)
        let folder = app.buttons["文件夹"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        for id in ["page2.app.vocab", "page2.app.reading"] {
            let matches = app.buttons.matching(identifier: id).allElementsBoundByIndex
            for element in matches { print("CLOSED_FOLDER_NODE \(id) \(element.frame) hittable=\(element.isHittable)") }
            XCTAssertFalse(matches.contains { $0.isHittable && $0.frame.minY < 700 })
        }
        save(app.screenshot(), name: "folder-short-release-closed")
        folder.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(try homeApp(app, id: "page2.app.vocab").frame.minY, 250)
        XCTAssertGreaterThan(try homeApp(app, id: "page2.app.reading").frame.minY, 250)
        save(app.screenshot(), name: "folder-short-release-members")
    }

    @MainActor
    func testFolderHoverOpenAndRename() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        let ready = NSPredicate { _, _ in
            app.buttons.matching(identifier: "page2.app.vocab").allElementsBoundByIndex.contains { $0.isHittable && $0.frame.minY < 700 }
        }
        for _ in 0..<3 {
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 4) == .completed { break }
            let next = app.buttons["chevron.right"].firstMatch
            if next.exists && next.isHittable { next.tap() } else { app.swipeLeft() }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed)
        let sourceFrame = try homeApp(app, id: "page2.app.vocab").frame
        let targetFrame = try homeApp(app, id: "page2.app.reading").frame
        let canvas = app.coordinate(withNormalizedOffset: .zero)
        let from = canvas.withOffset(CGVector(dx: sourceFrame.midX, dy: sourceFrame.minY + sourceFrame.width / 2))
        let to = canvas.withOffset(CGVector(dx: targetFrame.midX, dy: targetFrame.minY + targetFrame.width / 2))
        print("FOLDER_RECORD_READY")
        save(app.screenshot(), name: "folder-before-hover")
        from.press(forDuration: 0.5, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1.8)
        let title = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "文件夹")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(identifier: "page2.app.vocab").allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertTrue(app.buttons.matching(identifier: "page2.app.reading").allElementsBoundByIndex.contains { $0.isHittable })
        save(app.screenshot(), name: "folder-open-after-hover")
        app.buttons["清除文件夹名称"].firstMatch.tap()
        title.typeText("资料\n")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.87)).tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        let folder = app.buttons["资料"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertTrue(folder.isHittable)
        print("FOLDER_REOPEN_FRAME \(folder.frame)")
        folder.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "资料")
        save(app.screenshot(), name: "folder-renamed-and-reopened")
        print("FOLDER_RECORD_FINISHED")
        Thread.sleep(forTimeInterval: 0.5)
        app.terminate()
        app.launchPage2()
        for _ in 0..<3 {
            if folder.waitForExistence(timeout: 3), folder.isHittable { break }
            let next = app.buttons["chevron.right"].firstMatch
            if next.exists && next.isHittable { next.tap() } else { app.swipeLeft() }
        }
        XCTAssertTrue(folder.isHittable)
        folder.tap()
        XCTAssertTrue(app.staticTexts["资料"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["资料"].firstMatch.press(forDuration: 0.6)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "资料")
    }

    @MainActor
    func testEditingMotionRecording() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchEnvironment["PAGE2_UI_RENDERING"] = "standard"
        app.launchPage2()
        for _ in 0..<3 {
            if app.buttons.matching(identifier: "page2.app.health").allElementsBoundByIndex.contains(where: { $0.isHittable && $0.frame.minY < 700 }) { break }
            let forward = app.buttons["chevron.right"].firstMatch
            if forward.waitForExistence(timeout: 3), forward.isHittable { forward.tap() } else { app.swipeLeft() }
        }
        try homeApp(app, id: "page2.app.health").press(forDuration: 3.0)
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        print("WIGGLE_RECORD_READY")
        Thread.sleep(forTimeInterval: 4)
        print("WIGGLE_RECORD_FINISHED")
        save(app.screenshot(), name: "coherent-editing-motion")
        app.buttons["从主屏移除健康"].firstMatch.tap()
        XCTAssertFalse(app.buttons.matching(identifier: "page2.app.health").allElementsBoundByIndex.contains(where: { $0.isHittable }))
        print("BADGE_EXIT_RECORD_READY"); fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
        let doneFrame = app.buttons["完成"].firstMatch.frame
        XCTAssertEqual(doneFrame.midY, 33, accuracy: 5)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: doneFrame.midX, dy: doneFrame.midY)).tap()
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        print("BADGE_EXIT_RECORD_FINISHED"); fflush(stdout)
        save(app.screenshot(), name: "after-done-badges")
        let remaining = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "从主屏移除")).allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertTrue(remaining.isEmpty, remaining.map { "\($0.identifier) \($0.label) \($0.frame) value=\(String(describing: $0.value))" }.joined(separator: "\n"))
        try homeApp(app, id: "page2.app.calendar").tap()
        XCTAssertTrue(app.otherElements["page2.free-home"].waitForNonExistence(timeout: 8))
    }

    @MainActor
    func testFolderInternalReorderThenDragOutside() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        for _ in 0..<3 {
            if app.buttons.matching(identifier: "page2.app.vocab").allElementsBoundByIndex.contains(where: { $0.isHittable && $0.frame.minY < 700 }) { break }
            let forward = app.buttons["chevron.right"].firstMatch
            if forward.waitForExistence(timeout: 3), forward.isHittable { forward.tap() } else { app.swipeLeft() }
        }
        let canvas = app.coordinate(withNormalizedOffset: .zero)
        let source = try homeApp(app, id: "page2.app.vocab").frame
        let target = try homeApp(app, id: "page2.app.reading").frame
        canvas.withOffset(CGVector(dx: source.midX, dy: source.minY + source.width / 2))
            .press(forDuration: 0.5, thenDragTo: canvas.withOffset(CGVector(dx: target.midX, dy: target.minY + target.width / 2)), withVelocity: .slow, thenHoldForDuration: 1.8)
        let title = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "文件夹")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        print("FOLDER_RECORD_READY")
        let reading = try homeApp(app, id: "page2.app.reading").frame
        let vocab = try homeApp(app, id: "page2.app.vocab").frame
        XCTAssertLessThan(reading.minX, vocab.minX)
        canvas.withOffset(CGVector(dx: vocab.midX, dy: vocab.minY + vocab.width / 2))
            .press(forDuration: 0.15, thenDragTo: canvas.withOffset(CGVector(dx: reading.midX, dy: reading.minY + reading.width / 2)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(title.exists, "Internal dragging must keep the folder open")
        XCTAssertLessThan(try homeApp(app, id: "page2.app.vocab").frame.minX, try homeApp(app, id: "page2.app.reading").frame.minX)
        save(app.screenshot(), name: "folder-internal-reordered")
        let inside = try homeApp(app, id: "page2.app.vocab").frame
        canvas.withOffset(CGVector(dx: inside.midX, dy: inside.minY + inside.width / 2))
            .press(forDuration: 0.15, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.77)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        let extracted = try homeApp(app, id: "page2.app.vocab").frame
        XCTAssertGreaterThan(extracted.minY, 600)
        XCTAssertGreaterThan(extracted.minX, 280)
        XCTAssertTrue(app.buttons["完成"].firstMatch.exists)
        save(app.screenshot(), name: "folder-extracted-to-home")
        let remaining = app.buttons["文件夹"].firstMatch
        XCTAssertTrue(remaining.exists)
        remaining.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertNotNil(try homeApp(app, id: "page2.app.reading"))
        print("FOLDER_RECORD_FINISHED")
    }

    @MainActor
    func testHoldingAtEdgeMovesAppToNextPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        for _ in 0..<3 {
            if app.buttons.matching(identifier: "page2.app.health").allElementsBoundByIndex.contains(where: { $0.isHittable && $0.frame.minY < 700 }) { break }
            let forward = app.buttons["chevron.right"].firstMatch
            if forward.waitForExistence(timeout: 3), forward.isHittable { forward.tap() } else { app.swipeLeft() }
        }
        let source = try homeApp(app, id: "page2.app.health").frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: source.midX, dy: source.minY + source.width / 2))
            .press(forDuration: 0.5, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.975, dy: 0.65)), withVelocity: .slow, thenHoldForDuration: 0.95)
        let moved = try homeApp(app, id: "page2.app.health")
        XCTAssertTrue(moved.isHittable)
        XCTAssertFalse(app.buttons.matching(identifier: "page2.app.worldBook").allElementsBoundByIndex.contains(where: { $0.isHittable }))
        save(app.screenshot(), name: "app-dragged-to-next-page")
        app.swipeRight()
        XCTAssertTrue(app.buttons.matching(identifier: "page2.app.worldBook").allElementsBoundByIndex.contains(where: { $0.isHittable }))
        XCTAssertFalse(app.buttons.matching(identifier: "page2.app.health").allElementsBoundByIndex.contains(where: { $0.isHittable }))
    }

    @MainActor
    func testHoldingOverAnAppCreatesFolderAfterReordering() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchPage2()
        let candidate = app.buttons["page2.app.vocab"].firstMatch
        if !candidate.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(candidate.waitForExistence(timeout: 30))
        try homeApp(app, id: "page2.app.vocab").press(forDuration: 3.0)
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        let target = try homeApp(app, id: "page2.app.reading").coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        try homeApp(app, id: "page2.app.vocab").coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).press(forDuration: 0.15, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1.8)
        XCTAssertTrue(app.textFields["文件夹"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["page2.app.vocab"].firstMatch.exists)
        XCTAssertTrue(app.buttons["page2.app.reading"].firstMatch.exists)
        save(app.screenshot(), name: "page2-tungsten-folder")
    }

    @MainActor
    func testDraggingFromHomeToDock() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchEnvironment["PAGE2_UI_LAYOUT_CASE"] = UUID().uuidString
        app.launchPage2()
        for _ in 0..<3 {
            if app.buttons.matching(identifier: "page2.app.health").allElementsBoundByIndex.contains(where: { $0.isHittable && $0.frame.minY < 700 }) { break }
            let forward = app.buttons["chevron.right"].firstMatch
            if forward.waitForExistence(timeout: 3), forward.isHittable { forward.tap() } else { app.swipeLeft() }
        }
        let health = try homeApp(app, id: "page2.app.health")
        health.press(forDuration: 3.0)
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["从 Dock 移除日历"].tap()
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.915))
        try homeApp(app, id: "page2.app.health").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15, thenDragTo: target)
        XCTAssertTrue(app.buttons["从 Dock 移除健康"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        let dockHealth = try XCTUnwrap(app.buttons.matching(identifier: "page2.app.health").allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.minY > 800 }))
        dockHealth.tap()
        XCTAssertTrue(app.otherElements["page2.free-home"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testDirectLongPressDragAndTopEditingControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchPage2()
        let candidate = app.buttons["page2.app.calendar"].firstMatch
        if !candidate.waitForExistence(timeout: 5) {
            let forward = app.buttons["chevron.right"].firstMatch
            if forward.waitForExistence(timeout: 5), forward.isHittable { forward.tap() }
            else { app.swipeLeft() }
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 30))
        let source = try homeApp(app, id: "page2.app.calendar")
        let start = source.frame
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.705))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5, thenDragTo: destination)
        let edit = app.buttons["编辑"].firstMatch
        let done = app.buttons["完成"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertLessThan(edit.frame.midY, 45)
        XCTAssertLessThan(done.frame.midY, 45)
        XCTAssertGreaterThan(try homeApp(app, id: "page2.app.calendar").frame.minY, start.minY + 300)
        save(app.screenshot(), name: "page2-direct-drag-top-controls")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        try homeApp(app, id: "page2.app.calendar").tap()
        XCTAssertTrue(app.otherElements["page2.free-home"].waitForNonExistence(timeout: 8))
    }

    @MainActor
    func testEditingTapKeepsItemConfigurationAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingCompletedV1", "YES", "-page2HomePresentation_v1", "free", "-settings.proMode", "YES", "page2-ui-test"]
        app.launchPage2()
        let source = app.buttons["page2.app.calendar"].firstMatch
        if !source.waitForExistence(timeout: 5) { app.swipeLeft() }
        XCTAssertTrue(source.waitForExistence(timeout: 30))
        let homeSource = try homeApp(app, id: "page2.app.calendar")
        homeSource.press(forDuration: 3.0)
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        homeSource.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65)).tap()
        XCTAssertTrue(app.buttons["更换图标"].waitForExistence(timeout: 5))
        app.buttons["更换图标"].tap()
        XCTAssertTrue(app.textFields["SF Symbol 名称"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["取消"].tap()
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
extension XCUIApplication {
    func launchPage2() {
        if responds(to: NSSelectorFromString("setIdleAnimationWaitEnabled:")) { setValue(false, forKey: "idleAnimationWaitEnabled") }
        terminate()
        launch()
        let ready = NSPredicate { _, _ in
            self.buttons["随便看看"].exists || self.otherElements["page2.free-home"].exists
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5)
        if buttons["随便看看"].exists {
            terminate()
            launch()
        }
    }
}
