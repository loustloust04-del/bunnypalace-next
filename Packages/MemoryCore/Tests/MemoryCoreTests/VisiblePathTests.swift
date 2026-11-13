import XCTest
@testable import MemoryCore

final class VisiblePathTests: XCTestCase {
    private func window(_ currentNodeId: String, selection: [String: String] = [:]) -> ConversationWindow {
        ConversationWindow(id: "w", profileId: "p", title: "窗", createTime: .distantPast,
                           updateTime: .distantPast, currentNodeId: currentNodeId,
                           branchSelection: BranchSelection.encode(selection))
    }

    private func message(_ id: String, _ role: String, _ content: String = "正文", parent: String? = nil,
                         children: [String] = [], deleted: Bool = false, hidden: Bool = false,
                         synthetic: Bool = false, segments: [ConversationSegment]? = nil) -> ConversationMessage {
        ConversationMessage(id: id, conversationId: "w", role: role, content: content, segments: segments,
                            createTime: .distantPast, parentId: parent, childrenIds: children,
                            isTrashed: deleted, isSyntheticRoot: synthetic,
                            sourceVisibility: hidden ? "hidden" : nil)
    }

    /// 中间单条软删不切断主线（体检 L-B5）
    func testSoftDeletedMiddleNodeDoesNotCutPath() {
        let nodes = [
            message("r0", "user", "一", children: ["r1"]),
            message("r1", "assistant", "二", parent: "r0", children: ["r2"]),
            message("r2", "user", "三", parent: "r1", children: ["r3"], deleted: true),
            message("r3", "assistant", "四", parent: "r2"),
        ]
        XCTAssertEqual(visiblePath(window: window("r3"), nodes: nodes).map(\.id), ["r0", "r1", "r3"])
    }

    /// 源隐藏 / 合成根 / 非 user-assistant 都不进主线（体检 L-B6）
    func testHiddenSyntheticAndNonChatRolesAreFiltered() {
        let nodes = [
            message("root", "user", "合成根", children: ["u"], synthetic: true),
            message("u", "user", "问", parent: "root", children: ["h"]),
            message("h", "user", "隐藏问", parent: "u", children: ["sys"], hidden: true),
            message("sys", "system", "系统", parent: "h", children: ["tool"]),
            message("tool", "tool", "工具", parent: "sys", children: ["a"]),
            message("a", "assistant", "答", parent: "tool"),
        ]
        XCTAssertEqual(visiblePath(window: window("a"), nodes: nodes).map(\.id), ["u", "a"])
    }

    /// 只有 segments 的附件消息保留（原 `!content.isEmpty` 口径会丢）
    func testSegmentsOnlyAttachmentIsKept() {
        let nodes = [
            message("u", "user", "问", children: ["a", "h"]),
            message("a", "assistant", "", parent: "u", segments: [.audioRef]),
            message("h", "assistant", "", parent: "u", hidden: true, segments: [.audioRef]),
        ]
        XCTAssertEqual(visiblePath(window: window("a"), nodes: nodes).map(\.id), ["u", "a"])
    }

    /// 多分叉按 branchSelection 走
    func testBranchSelectionWins() {
        let nodes = [
            message("root", "user", "问", children: ["c1", "c2"]),
            message("c1", "assistant", "一", parent: "root"),
            message("c2", "assistant", "二", parent: "root"),
        ]
        let path = visiblePath(window: window("c1", selection: ["root": "c2"]), nodes: nodes)
        XCTAssertEqual(path.map(\.id), ["root", "c2"])
    }

    /// 无 selection 时按 legacyCurrentNodeId 所在的旧路径选支
    func testLegacyCurrentNodeIdFallback() {
        let nodes = [
            message("root", "user", "问", children: ["c1", "c2"]),
            message("c1", "assistant", "一", parent: "root"),
            message("c2", "assistant", "二", parent: "root"),
        ]
        XCTAssertEqual(visiblePath(window: window("c2"), nodes: nodes).map(\.id), ["root", "c2"])
    }

    /// childrenIds 缺省时按 parentId 补挂（BranchSelection.effectiveChildren）
    func testMissingChildrenIdsAreDerivedFromParent() {
        let nodes = [
            message("root", "user", "问"),
            message("c1", "assistant", "一", parent: "root"),
            message("c2", "assistant", "二", parent: "root"),
        ]
        XCTAssertEqual(visiblePath(window: window("c2"), nodes: nodes).map(\.id), ["root", "c2"])
    }
}
