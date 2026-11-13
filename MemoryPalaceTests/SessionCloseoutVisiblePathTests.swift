import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 写侧主线口径（摘包刀 2 E2-3）：`SessionCloseout.mainPathNodesStrict` 走包里的 `visiblePath`。
/// L-B5 = 中间单条软删不再切断主线；L-B6 = 源隐藏 / 合成根不进记忆；只有 segments 的附件消息保留。
final class SessionCloseoutVisiblePathTests: XCTestCase {
    private let pid = "floor-visible-path"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Conversation.self, MessageNode.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @discardableResult
    private func node(_ id: String, role: String, parent: String?, children: [String], in context: ModelContext,
                      content: String = "正文", trashed: Bool = false, hidden: Bool = false,
                      synthetic: Bool = false, segments: [MessageSegment]? = nil, at: Int) -> MessageNode {
        let node = MessageNode(id: id, role: role, content: content, contentType: "text",
                               createTime: Date(timeIntervalSince1970: TimeInterval(at)),
                               parentId: parent, childrenIds: children, conversationId: convId, profileId: pid)
        node.isTrashed = trashed
        node.isSyntheticRoot = synthetic
        if hidden { node.sourceVisibility = "hidden" }
        if let segments { node.segmentsData = try? JSONEncoder().encode(segments) }
        context.insert(node)
        return node
    }

    private var convId: String { "conv-visible-path" }

    private func window(_ context: ModelContext, currentNodeId: String, selection: [String: String] = [:]) -> Conversation {
        let conv = Conversation(id: convId, title: "主线", createTime: Date(timeIntervalSince1970: 0),
                                updateTime: Date(timeIntervalSince1970: 100), currentNodeId: currentNodeId, profileId: pid)
        conv.branchSelectionData = BranchSelection.encode(selection)
        context.insert(conv)
        return conv
    }

    private func path(_ context: ModelContext) throws -> [String] {
        let container = context.container
        let source = SwiftDataConversationSource(container: container)
        let conv = try XCTUnwrap(try source.window(profileId: pid, idOrPrefix: convId))
        return try SessionCloseout.mainPathNodesStrict(conv, source: source).map(\.id)
    }

    /// L-B5：u1-a1-u2(软删)-a2-u3-a3，软删那条不切断主线
    func testMiddleTrashedMessageDoesNotCutMainPath() throws {
        let context = ModelContext(try container())
        window(context, currentNodeId: "a3")
        node("u1", role: "user", parent: nil, children: ["a1"], in: context, at: 1)
        node("a1", role: "assistant", parent: "u1", children: ["u2"], in: context, at: 2)
        node("u2", role: "user", parent: "a1", children: ["a2"], in: context, trashed: true, at: 3)
        node("a2", role: "assistant", parent: "u2", children: ["u3"], in: context, at: 4)
        node("u3", role: "user", parent: "a2", children: ["a3"], in: context, at: 5)
        node("a3", role: "assistant", parent: "u3", children: [], in: context, at: 6)
        try context.save()

        XCTAssertEqual(try path(context), ["u1", "a1", "a2", "u3", "a3"], "中间软删一条只少这一条，不切断后面的主线")
    }

    /// L-B6：源隐藏消息与合成根都不进主线（拆包前 `mainPathNodesStrict` 只滤 role / 空正文）
    func testHiddenAndSyntheticNodesStayOutOfMainPath() throws {
        let context = ModelContext(try container())
        window(context, currentNodeId: "a3")
        node("root", role: "user", parent: nil, children: ["u1"], in: context, content: "结构锚点", synthetic: true, at: 0)
        node("u1", role: "user", parent: "root", children: ["a1"], in: context, at: 1)
        node("a1", role: "assistant", parent: "u1", children: ["h2"], in: context, at: 2)
        node("h2", role: "assistant", parent: "a1", children: ["u3"], in: context, hidden: true, at: 3)
        node("u3", role: "user", parent: "h2", children: ["a3"], in: context, at: 4)
        node("a3", role: "assistant", parent: "u3", children: [], in: context, at: 5)
        try context.save()

        XCTAssertEqual(try path(context), ["u1", "a1", "u3", "a3"], "合成根 / 源隐藏消息不写进记忆")
    }

    /// 口径变化 ③：只有 segments 的附件消息保留（原 `!content.isEmpty` 会丢）
    func testSegmentsOnlyAttachmentStays() throws {
        let context = ModelContext(try container())
        window(context, currentNodeId: "a2")
        node("u1", role: "user", parent: nil, children: ["a1"], in: context, at: 1)
        node("a1", role: "assistant", parent: "u1", children: ["a2"], in: context, content: "", segments: [.image(name: "图", type: "image/png", data: Data())], at: 2)
        node("a2", role: "assistant", parent: "a1", children: [], in: context, content: "", segments: [.text("附件说明")], at: 3)
        try context.save()

        XCTAssertEqual(try path(context), ["u1", "a1", "a2"], "只有 segments 的消息不丢")

        let source = SwiftDataConversationSource(container: context.container)
        let conv = try XCTUnwrap(try source.window(profileId: pid, idOrPrefix: convId))
        XCTAssertEqual(SessionCloseout.mainPath(conv, source: source).map(\.content), ["正文", "", "附件说明"],
                       "正文走 body(of:cacheKey:)：图片段为空，text 段照写")
    }

    /// 多分叉按 `branchSelection` 走；没有选择表时退回旧 `currentNodeId` 所在那条
    func testBranchSelectionPicksTheBranch() throws {
        let context = ModelContext(try container())
        window(context, currentNodeId: "a3", selection: ["a1": "a2"])
        node("u1", role: "user", parent: nil, children: ["a1"], in: context, at: 1)
        node("a1", role: "assistant", parent: "u1", children: ["a2", "a2b"], in: context, at: 2)
        node("a2", role: "assistant", parent: "a1", children: ["u3"], in: context, at: 3)
        node("a2b", role: "assistant", parent: "a1", children: ["u3b"], in: context, at: 3)
        node("u3", role: "user", parent: "a2", children: ["a3"], in: context, at: 4)
        node("a3", role: "assistant", parent: "u3", children: [], in: context, at: 5)
        node("u3b", role: "user", parent: "a2b", children: [], in: context, at: 4)
        try context.save()

        XCTAssertEqual(try path(context), ["u1", "a1", "a2", "u3", "a3"])
    }

    func testLegacyCurrentNodeIdPicksTheBranchWithoutSelection() throws {
        let context = ModelContext(try container())
        window(context, currentNodeId: "u3b")
        node("u1", role: "user", parent: nil, children: ["a1"], in: context, at: 1)
        node("a1", role: "assistant", parent: "u1", children: ["a2", "a2b"], in: context, at: 2)
        node("a2", role: "assistant", parent: "a1", children: ["u3"], in: context, at: 3)
        node("a2b", role: "assistant", parent: "a1", children: ["u3b"], in: context, at: 3)
        node("u3", role: "user", parent: "a2", children: [], in: context, at: 4)
        node("u3b", role: "user", parent: "a2b", children: [], in: context, at: 4)
        try context.save()

        XCTAssertEqual(try path(context), ["u1", "a1", "a2b", "u3b"])
    }
}
