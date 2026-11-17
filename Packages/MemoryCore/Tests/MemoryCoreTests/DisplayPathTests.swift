import XCTest
@testable import MemoryCore

final class DisplayPathTests: XCTestCase {
    private func project(_ path: [String], hidden: Set<String> = [], forks: Set<String> = []) -> DisplayPath.Result {
        DisplayPath.project(pathIds: path, isDisplayable: { !hidden.contains($0) }, childCount: { forks.contains($0) ? 2 : 1 })
    }

    func testAllVisibleKeepsOrderAndBubblesNothing() {
        XCTAssertEqual(project(["a", "b", "c"], forks: ["b"]), .init(visibleIds: ["a", "b", "c"]),
                       "分叉点自己显示时不用往前记")
    }

    func testHiddenNodesAreSkippedWithoutCuttingThePath() {
        XCTAssertEqual(project(["a", "x", "b"], hidden: ["x"]).visibleIds, ["a", "b"])
    }

    func testHiddenForkIsRecordedOnThePreviousVisibleNode() {
        let result = project(["a", "tool", "b"], hidden: ["tool"], forks: ["tool"])
        XCTAssertEqual(result, .init(visibleIds: ["a", "b"], bubbledBranches: ["a": "tool"]))
    }

    func testHiddenForkBeforeAnyVisibleNodeHasNowhereToGo() {
        XCTAssertEqual(project(["root", "a"], hidden: ["root"], forks: ["root"]), .init(visibleIds: ["a"]))
    }

    func testTwoHiddenForksAfterTheSameNodeKeepTheLaterOne() {
        let result = project(["a", "f1", "f2", "b"], hidden: ["f1", "f2"], forks: ["f1", "f2"])
        XCTAssertEqual(result.bubbledBranches, ["a": "f2"])
    }

    func testDisplayableRule() {
        XCTAssertTrue(DisplayPath.isDisplayable(role: "user", hasDisplayableContent: true, isTrashed: false))
        XCTAssertTrue(DisplayPath.isDisplayable(role: "assistant", hasDisplayableContent: true, isTrashed: false))
        XCTAssertFalse(DisplayPath.isDisplayable(role: "system", hasDisplayableContent: true, isTrashed: false))
        XCTAssertFalse(DisplayPath.isDisplayable(role: "tool", hasDisplayableContent: true, isTrashed: false))
        XCTAssertFalse(DisplayPath.isDisplayable(role: "user", hasDisplayableContent: false, isTrashed: false))
        XCTAssertFalse(DisplayPath.isDisplayable(role: "user", hasDisplayableContent: true, isTrashed: true))
    }
}
