#if os(macOS)
import XCTest
@testable import 记忆花园

@MainActor
final class MacPanelPresentationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var layout: IPadPanelLayout!
    private var suite: String!
    private let size = CGSize(width: 1600, height: 900)

    override func setUp() {
        super.setUp()
        suite = "xctest-mac-panel-presentation-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        layout = IPadPanelLayout(defaults: defaults)
        layout.macReturnFrame = CGRect(x: 1188, y: 0, width: 360, height: 44)
        layout.macTabFrames["a"] = CGRect(x: 1196, y: 6, width: 120, height: 34)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        layout = nil
        defaults = nil
        super.tearDown()
    }

    func testCancelledDragClearsAllTransientFeedbackWithoutWritingArchive() {
        layout.open("a")
        let archive = defaults.data(forKey: "ipad.panel.layout.v2")
        layout.beginMacTabDrag("a")
        layout.macDropTarget = "workspace"
        let generation = layout.macDragGeneration
        layout.endMacTabDrag()
        XCTAssertNil(layout.draggingTab)
        XCTAssertNil(layout.macDropTarget)
        XCTAssertGreaterThan(layout.macDragGeneration, generation)
        XCTAssertEqual(defaults.data(forKey: "ipad.panel.layout.v2"), archive)
    }

    func testOldFlightCompletionCannotClearNewFlight() throws {
        layout.open("a")
        layout.detachMacPanel("a", in: size)
        let outgoing = try XCTUnwrap(layout.macFlightTargets["a"]?.id)
        layout.attachMacPanel("a", in: size)
        let incoming = try XCTUnwrap(layout.macFlightTargets["a"]?.id)
        XCTAssertNotEqual(outgoing, incoming)
        layout.finishMacFlight("a", token: outgoing)
        XCTAssertEqual(layout.macFlightTargets["a"]?.id, incoming)
        XCTAssertEqual(layout.tabs, ["a"])
        layout.finishMacFlight("a", token: incoming)
        XCTAssertNil(layout.macFlightTargets["a"])
        XCTAssertNil(layout.flights["a"])
    }

    func testCloseDuringFlightCannotResurrectPanel() throws {
        layout.open("a")
        layout.detachMacPanel("a", in: size)
        let token = try XCTUnwrap(layout.macFlightTargets["a"]?.id)
        layout.close("a")
        layout.finishMacFlight("a", token: token)
        layout.attachMacPanel("a", in: size)
        XCTAssertFalse(layout.isOpen("a"))
        XCTAssertNil(layout.flights["a"])
        XCTAssertNil(layout.macFlightTargets["a"])
        XCTAssertTrue(layout.tabs.isEmpty)
    }

    func testReloadRestoresMembershipWithoutTransientPresentation() {
        layout.open("a")
        layout.beginMacTabDrag("a")
        layout.detachMacPanel("a", in: size)
        let restored = IPadPanelLayout(defaults: defaults)
        XCTAssertEqual(restored.detached, ["a"])
        XCTAssertNil(restored.draggingTab)
        XCTAssertTrue(restored.flights.isEmpty)
        XCTAssertTrue(restored.macFlightTargets.isEmpty)
        XCTAssertTrue(restored.macTabFrames.isEmpty)
    }

    func testCollapsedClickAndDockUseSameExpansionSemantics() {
        layout.open("a")
        layout.tabGroupCollapsed = true
        layout.clickMacTab("a", count: 1)
        layout.clickMacTab("a", count: 2)
        XCTAssertFalse(layout.tabGroupCollapsed, "Second click must not undo the first click's expansion")
        layout.clickMacTab("a", count: 1)
        layout.clickMacTab("a", count: 2)
        XCTAssertTrue(layout.tabGroupCollapsed)
        layout.dockTap("a")
        XCTAssertFalse(layout.tabGroupCollapsed)
        XCTAssertTrue(layout.isOpen("a"))
    }

    func testCancellingPresentationPreservesCommittedLayout() {
        layout.open("a")
        layout.detachMacPanel("a", at: CGPoint(x: 600, y: 240), in: size)
        let frame = layout.frames["a"]
        layout.cancelMacPresentation()
        XCTAssertEqual(layout.detached, ["a"])
        XCTAssertEqual(layout.frames["a"], frame)
        XCTAssertTrue(layout.flights.isEmpty)
        XCTAssertTrue(layout.macFlightTargets.isEmpty)
    }

    func testExistingTabDroppedOnHeaderSelectsAndExpands() {
        layout.open("a")
        layout.open("b")
        layout.tabGroupCollapsed = true
        layout.attachMacPanel("a", in: size)
        XCTAssertEqual(layout.currentTab, "a")
        XCTAssertFalse(layout.tabGroupCollapsed)
        XCTAssertEqual(layout.tabs, ["a", "b"])
        XCTAssertTrue(layout.macFlightTargets.isEmpty)
    }
}
#endif
