import XCTest
@testable import 记忆花园

/// page2 应用栈（plan-page2-app-shell §2.1）：最近用的在前、最多 4 个、返回路径按打开顺序走。
final class Page2AppStackTests: XCTestCase {

    func testOpenPutsMostRecentFirst() {
        var stack = Page2AppStack()
        stack.open("reading")
        stack.open("browser")
        stack.open("reading")
        XCTAssertEqual(stack.openApps, ["reading", "browser"])
    }

    func testOpeningPastCapacityEvictsLeastRecentlyUsed() {
        var stack = Page2AppStack()
        let ids = (0..<Page2AppStack.capacity).map { "app\($0)" }
        for id in ids { XCTAssertNil(stack.open(id)) }
        stack.open("app0")
        XCTAssertEqual(stack.open("new"), "app1")
        XCTAssertEqual(stack.openApps, ["new", "app0"] + ids.dropFirst(2).reversed())
    }

    func testReopeningAliveAppNeverEvicts() {
        var stack = Page2AppStack()
        for id in (0..<Page2AppStack.capacity).map({ "app\($0)" }) { stack.open(id) }
        XCTAssertNil(stack.open("app1"))
        XCTAssertEqual(stack.openApps.count, Page2AppStack.capacity)
    }

    func testBackWalksTheOpeningOrder() {
        var stack = Page2AppStack()
        for id in ["a", "b", "c"] { stack.open(id) }
        XCTAssertEqual(stack.back(), "b")
        XCTAssertEqual(stack.back(), "a")
        XCTAssertNil(stack.back())
        XCTAssertFalse(stack.canGoBack)
    }

    /// 按「最近用过」退会在两个应用间来回跳（小样试出来的），返回路径不能这样
    func testBackDoesNotPingPong() {
        var stack = Page2AppStack()
        for id in ["a", "b", "c"] { stack.open(id) }
        XCTAssertEqual(stack.back(), "b")
        XCTAssertNotEqual(stack.back(), "c")
    }

    func testBackBringsPreviousAppToFront() {
        var stack = Page2AppStack()
        for id in ["a", "b", "c"] { stack.open(id) }
        stack.back()
        XCTAssertEqual(stack.openApps.first, "b")
    }

    func testReopeningCurrentAppDoesNotGrowHistory() {
        var stack = Page2AppStack()
        stack.open("a")
        stack.open("a")
        XCTAssertEqual(stack.history, ["a"])
    }

    func testCloseRemovesAppFromHistoryAndCollapsesRepeats() {
        var stack = Page2AppStack()
        for id in ["a", "b", "a"] { stack.open(id) }
        stack.close("b")
        XCTAssertEqual(stack.openApps, ["a"])
        XCTAssertEqual(stack.history, ["a"])
        XCTAssertFalse(stack.canGoBack)
    }

    func testHistoryIsCapped() {
        var stack = Page2AppStack()
        for i in 0..<(Page2AppStack.historyLimit + 10) { stack.open(i.isMultiple(of: 2) ? "a" : "b") }
        XCTAssertEqual(stack.history.count, Page2AppStack.historyLimit)
    }

    func testEncodingRoundTrips() {
        var stack = Page2AppStack()
        for id in ["reading", "browser", "calendar"] { stack.open(id) }
        stack.back()
        XCTAssertEqual(Page2AppStack(encoded: stack.encoded), stack)
    }

    func testDecodingDropsBlanksAndClampsCapacity() {
        let ids = (0...Page2AppStack.capacity).map { "app\($0)" }
        let stack = Page2AppStack(encoded: "app0,," + ids.dropFirst().joined(separator: ",") + ",app0|a,,b")
        XCTAssertEqual(stack.openApps, Array(ids.prefix(Page2AppStack.capacity)))
        XCTAssertEqual(stack.history, ["a", "b"])
    }

    func testDecodingGarbageGivesEmptyStack() {
        XCTAssertEqual(Page2AppStack(encoded: ""), Page2AppStack())
        XCTAssertEqual(Page2AppStack(encoded: "|||"), Page2AppStack())
    }

    func testRetainDropsUnavailableApps() {
        var stack = Page2AppStack()
        for id in ["a", "gone", "b"] { stack.open(id) }
        stack.retain { $0 != "gone" }
        XCTAssertEqual(stack.openApps, ["b", "a"])
        XCTAssertEqual(stack.history, ["a", "b"])
    }
}
