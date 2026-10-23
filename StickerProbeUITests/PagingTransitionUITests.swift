import XCTest

@MainActor
final class PagingTransitionUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--kb-probe-seed", "-onboardingCompletedV1", "YES"]
        app.launch()
        XCTAssertTrue(app.scrollViews["paging-scroll"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["chat-input-field"].firstMatch.waitForExistence(timeout: 30))
        expectPage(1)
    }

    private func expectPage(_ page: Int) {
        let pager = app.scrollViews["paging-scroll"]
        let predicate = NSPredicate(format: "value BEGINSWITH %@", "page=\(page);settled=1")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: pager)], timeout: 10)
        XCTAssertEqual(result, .completed, "Actual pager: \(String(describing: pager.value))")
    }

    private func swipe(left: Bool) {
        app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.82 : 0.18, dy: 0.40))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.18 : 0.82, dy: 0.40)),
                   withVelocity: .default, thenHoldForDuration: 0)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testProductionPagingAndCancellation() {
        snapshot("production-chat")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.40))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.40)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        expectPage(1)
        swipe(left: false); expectPage(0); snapshot("production-list")
        swipe(left: true); expectPage(1)
        swipe(left: true); expectPage(2); snapshot("production-desktop")
        swipe(left: false); expectPage(1)
    }

    func testProductionKeyboardAndOrientationRequest() {
        let input = app.descendants(matching: .any)["chat-input-field"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let originalDraft = input.value as? String
        input.tap()
        NSLog("[PagingTest] waiting for visible software keyboard")
        let visibleKeyboard = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleKeyboard], timeout: 20), .completed)
        let keyboardFrame = app.keyboards.firstMatch.frame
        NSLog("[PagingTest] input=%@ keyboard=%@", String(describing: input.frame), String(describing: keyboardFrame))
        XCTAssertGreaterThan(keyboardFrame.height, 100, "Software keyboard must actually be visible")
        XCTAssertLessThan(keyboardFrame.minY, app.windows.firstMatch.frame.maxY - 100)
        XCTAssertLessThanOrEqual(keyboardFrame.maxY, app.windows.firstMatch.frame.maxY + 1)
        XCTAssertLessThanOrEqual(input.frame.maxY, keyboardFrame.minY + 1)
        snapshot("production-keyboard")
        swipe(left: true); expectPage(2)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        swipe(left: false); expectPage(1)
        XCTAssertTrue(input.isHittable)
        XCTAssertEqual(input.value as? String, originalDraft)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectPage(1)
        NSLog("[PagingTest] requested landscape, window=%@", String(describing: app.windows.firstMatch.frame))
        snapshot("production-orientation-request")
        XCUIDevice.shared.orientation = .portrait
        expectPage(1)
    }
}
