import XCTest
@testable import 记忆花园

/// 对话行条数只数当前分支路径：每条都重新生成过一次（2 / 2）时，全树 16 条、眼前这支 8 条，应显示 8
final class NodeCountPathTests: XCTestCase {
    private func node(_ id: String, _ role: String, parent: String?, content: String = "x") -> ImportedNodePayload {
        ImportedNodePayload(id: id, role: role, content: content, contentType: "text", createTime: nil,
                            parentId: parent, childrenIds: [])
    }

    /// 4 轮对话，每条消息都有一个重新生成的旁支 → 全树 16 条可显示，路径 8 条
    private func branchyTree() -> (nodes: [ImportedNodePayload], leaf: String) {
        var nodes = [node("root", "system", parent: nil, content: "")]
        var parent = "root"
        for turn in 0..<4 {
            for role in ["user", "assistant"] {
                let id = "\(role)\(turn)"
                nodes.append(node(id, role, parent: parent))
                nodes.append(node(id + "-alt", role, parent: parent))
                parent = id
            }
        }
        return (nodes, parent)
    }

    func testCountsOnlyCurrentBranchPath() {
        let (nodes, leaf) = branchyTree()
        XCTAssertEqual(countDisplayableNodes(nodes), 16)
        XCTAssertEqual(countDisplayableOnPath(nodes, leafId: leaf), 8)
    }

    func testMissingLeafFallsBackToAllDisplayable() {
        let (nodes, _) = branchyTree()
        XCTAssertEqual(countDisplayableOnPath(nodes, leafId: "gone"), 16)
        XCTAssertEqual(countDisplayableOnPath(nodes, leafId: nil), 16)
    }

    func testParentCycleTerminates() {
        let nodes = [node("a", "user", parent: "b"), node("b", "assistant", parent: "a")]
        XCTAssertEqual(countDisplayableOnPath(nodes, leafId: "a"), 2)
    }
}
