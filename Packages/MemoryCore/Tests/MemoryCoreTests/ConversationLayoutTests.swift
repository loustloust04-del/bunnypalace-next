import XCTest
@testable import MemoryCore

final class ConversationLayoutTests: XCTestCase {
    private typealias Node = ConversationLayout.Node

    /// root(合成根，不显示) → u1 → a1 ─┬ u2 → a2
    ///                               └ u3 → tool(不显示，分叉) ─┬ a3
    ///                                                        └ a4
    private func tree() -> [String: Node] {
        func node(_ parent: String?, _ children: [String], _ role: String, shown: Bool = true) -> Node {
            Node(parentId: parent, childrenIds: children, role: role, hasDisplayableContent: shown, isTrashed: false)
        }
        return [
            "root": node(nil, ["u1"], "system", shown: false),
            "u1": node("root", ["a1"], "user"),
            "a1": node("u1", ["u2", "u3"], "assistant"),
            "u2": node("a1", ["a2"], "user"),
            "a2": node("u2", [], "assistant"),
            "u3": node("a1", ["tool"], "user"),
            "tool": node("u3", ["a3", "a4"], "tool"),
            "a3": node("tool", [], "assistant"),
            "a4": node("tool", [], "assistant"),
        ]
    }

    private func load(_ nodes: [String: Node]? = nil, selection: [String: String] = [:], legacy: String = "a2",
                      target: String? = nil) -> ConversationLayout.Result {
        ConversationLayout.load(nodes: nodes ?? tree(), selection: selection, legacyCurrentNodeId: legacy, browseTargetId: target)
    }

    func testOldConversationFollowsCurrentNodeAndAsksToSaveTheSelection() {
        let result = load(legacy: "a2")
        XCTAssertEqual(result.visibleIds, ["u1", "a1", "u2", "a2"])
        XCTAssertEqual(result.rootId, "root")
        XCTAssertEqual(result.displayLeafId, "a2")
        XCTAssertEqual(result.persistedSelection["a1"], "u2")
        XCTAssertTrue(result.selectionChanged, "老对话第一次打开要把走的分支写回")
        XCTAssertEqual(result.mainPathIds, ["root", "u1", "a1", "u2", "a2"])
        XCTAssertEqual(result.displaySelection, result.persistedSelection)
    }

    func testSavedSelectionWinsAndIsNotRewritten() {
        let saved = load(legacy: "a4").persistedSelection
        let result = load(selection: saved, legacy: "a2")
        XCTAssertEqual(result.visibleIds, ["u1", "a1", "u3", "a4"])
        XCTAssertFalse(result.selectionChanged)
    }

    func testHiddenForkHangsOnThePreviousVisibleNode() {
        let result = load(legacy: "a3")
        XCTAssertEqual(result.visibleIds, ["u1", "a1", "u3", "a3"])
        XCTAssertEqual(result.bubbledBranches, ["u3": "tool"])
        XCTAssertEqual(result.effectiveChildren["tool"], ["a3", "a4"])
    }

    func testBrowseTargetChangesWhatIsShownButNotWhatIsSaved() {
        let plain = load(legacy: "a2")
        let result = load(legacy: "a2", target: "a4")
        XCTAssertEqual(result.visibleIds, ["u1", "a1", "u3", "a4"])
        XCTAssertEqual(result.displayLeafId, "a4")
        XCTAssertEqual(result.displaySelection["a1"], "u3")
        XCTAssertEqual(result.displaySelection["tool"], "a4")
        XCTAssertEqual(result.persistedSelection, plain.persistedSelection, "搜索跳转不改存下来的选择")
        XCTAssertEqual(result.mainPathIds, plain.mainPathIds, "主线还是存下来的那条")
    }

    func testUnknownBrowseTargetIsIgnored() {
        XCTAssertEqual(load(legacy: "a2", target: "gone"), load(legacy: "a2"))
    }

    func testTrashedAndEmptyNodesAreNotShown() {
        var nodes = tree()
        nodes["u2"]?.isTrashed = true
        nodes["a2"]?.hasDisplayableContent = false
        XCTAssertEqual(load(nodes, legacy: "a2").visibleIds, ["u1", "a1"])
    }

    func testEmptyConversation() {
        let result = load([:], legacy: "")
        XCTAssertEqual(result.visibleIds, [])
        XCTAssertNil(result.rootId)
        XCTAssertNil(result.displayLeafId)
    }
}
