import XCTest
import SwiftData
@testable import 记忆花园

/// duplicateConversation 特征测试：分支树重映射 / 标题去重 / FavoriteItem 复制 / 附件 ref 重写。
/// in-memory ModelContainer，附件落盘用固定测试楼层 id，tearDown 删整个楼层目录。
final class DuplicateConversationTests: XCTestCase {

    let pid = "xctest-dup-conv"
    var container: ModelContainer!
    var context: ModelContext!
    var viewModel: ConversationViewModel!

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: config
        )
        context = ModelContext(container)
        viewModel = ConversationViewModel()
    }

    override func tearDown() {
        let floorDir = FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: floorDir)
        container = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    @discardableResult
    private func node(_ id: String, role: String, content: String,
                      parent: String?, children: [String], conv: Conversation) -> MessageNode {
        let n = MessageNode(id: id, role: role, content: content, contentType: "text",
                            createTime: Date(), parentId: parent, childrenIds: children,
                            conversationId: conv.id, profileId: pid)
        context.insert(n)
        return n
    }

    /// root ─ u1 ─ a1 ─┬─ u2
    ///                  └─ u3 ─ a3   （currentNodeId = u3）
    private func makeBranchedConversation(title: String) -> Conversation {
        let ids = (0..<6).map { _ in UUID().uuidString }
        let (root, u1, a1, u2, u3, a3) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])
        let conv = Conversation(id: UUID().uuidString, title: title, createTime: Date(),
                                updateTime: Date(), currentNodeId: u3, provider: "api", profileId: pid)
        context.insert(conv)
        node(root, role: "system", content: "c-root", parent: nil, children: [u1], conv: conv)
        node(u1, role: "user", content: "c-u1", parent: root, children: [a1], conv: conv)
        node(a1, role: "assistant", content: "c-a1", parent: u1, children: [u2, u3], conv: conv)
        node(u2, role: "user", content: "c-u2", parent: a1, children: [], conv: conv)
        node(u3, role: "user", content: "c-u3", parent: a1, children: [a3], conv: conv)
        node(a3, role: "assistant", content: "c-a3", parent: u3, children: [], conv: conv)
        try? context.save()
        return conv
    }

    private func nodes(of convId: String) -> [MessageNode] {
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.conversationId == convId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 分支树同构

    func testDuplicatePreservesBranchTree() throws {
        let original = makeBranchedConversation(title: "原始对话")
        let copy = viewModel.duplicateConversation(original, context: context)

        XCTAssertEqual(copy.title, "原始对话-copy")
        XCTAssertNotEqual(copy.id, original.id)

        let oldNodes = nodes(of: original.id)
        let newNodes = nodes(of: copy.id)
        XCTAssertEqual(oldNodes.count, 6)
        XCTAssertEqual(newNodes.count, oldNodes.count)
        XCTAssertTrue(Set(oldNodes.map(\.id)).isDisjoint(with: newNodes.map(\.id)), "副本节点必须全新 id")

        let oldByContent = Dictionary(uniqueKeysWithValues: oldNodes.map { ($0.content, $0) })
        let newByContent = Dictionary(uniqueKeysWithValues: newNodes.map { ($0.content, $0) })
        let oldById = Dictionary(uniqueKeysWithValues: oldNodes.map { ($0.id, $0) })
        let newById = Dictionary(uniqueKeysWithValues: newNodes.map { ($0.id, $0) })

        for (content, oldNode) in oldByContent {
            let newNode = try XCTUnwrap(newByContent[content], "副本缺节点 \(content)")
            XCTAssertEqual(newNode.role, oldNode.role)
            XCTAssertEqual(newNode.profileId, pid)
            XCTAssertEqual(
                newNode.parentId.flatMap { newById[$0]?.content },
                oldNode.parentId.flatMap { oldById[$0]?.content },
                "节点 \(content) 父指针不同构"
            )
            XCTAssertEqual(
                newNode.childrenIds.compactMap { newById[$0]?.content },
                oldNode.childrenIds.compactMap { oldById[$0]?.content },
                "节点 \(content) childrenIds 不同构（分支顺序必须保留）"
            )
        }

        XCTAssertEqual(newById[copy.currentNodeId]?.content, "c-u3", "currentNodeId 要重映射")
        XCTAssertEqual(newByContent["c-a1"]?.childrenIds.count, 2, "分支点要保留")
    }

    // MARK: - 标题去重

    func testTitleDedupCopy2Copy3() {
        let original = makeBranchedConversation(title: "对话A")
        XCTAssertEqual(viewModel.duplicateConversation(original, context: context).title, "对话A-copy")
        XCTAssertEqual(viewModel.duplicateConversation(original, context: context).title, "对话A-copy2")
        XCTAssertEqual(viewModel.duplicateConversation(original, context: context).title, "对话A-copy3")
    }

    func testTrashedTitleDoesNotBlockDedup() {
        let trashed = Conversation(id: UUID().uuidString, title: "对话B-copy", createTime: Date(),
                                   updateTime: Date(), currentNodeId: "", provider: "api", profileId: pid)
        trashed.isTrashed = true
        context.insert(trashed)
        let original = makeBranchedConversation(title: "对话B")
        XCTAssertEqual(viewModel.duplicateConversation(original, context: context).title, "对话B-copy")
    }

    // MARK: - Conversation 字段

    func testConversationFieldsCopiedAndUnlinked() {
        let original = makeBranchedConversation(title: "字段对话")
        original.isFavorite = true
        original.memoryEnabled = false
        original.selectedModelId = "anthropic+claude-fable-5"
        original.importBatchId = UUID()
        original.ccBridgeSessionName = "mp-cc-3"
        original.draftText = "草稿"
        original.draftQuoteReplyTo = "映射不到的id"

        let copy = viewModel.duplicateConversation(original, context: context)
        XCTAssertTrue(copy.isFavorite)
        XCTAssertFalse(copy.memoryEnabled)
        XCTAssertEqual(copy.selectedModelId, "anthropic+claude-fable-5")
        XCTAssertEqual(copy.draftText, "草稿")
        XCTAssertNil(copy.importBatchId, "批量导入撤销不应误删手动副本")
        XCTAssertNil(copy.ccBridgeSessionName, "CC session 绑定不能共享")
        XCTAssertEqual(copy.draftQuoteReplyTo, "", "映射不到的草稿引用要清空")
        XCTAssertNil(copy.lastOpenedAt)
    }

    // MARK: - replyToId 重映射

    func testReplyToIdRemapsInternalKeepsExternal() throws {
        let original = makeBranchedConversation(title: "引用对话")
        let oldNodes = nodes(of: original.id)
        let u1 = try XCTUnwrap(oldNodes.first { $0.content == "c-u1" })
        try XCTUnwrap(oldNodes.first { $0.content == "c-a3" }).replyToId = u1.id
        try XCTUnwrap(oldNodes.first { $0.content == "c-u2" }).replyToId = "s_external_cc_id"
        try context.save()

        let copy = viewModel.duplicateConversation(original, context: context)
        let newNodes = nodes(of: copy.id)
        let newU1 = try XCTUnwrap(newNodes.first { $0.content == "c-u1" })
        XCTAssertEqual(newNodes.first { $0.content == "c-a3" }?.replyToId, newU1.id, "对话内引用要重映射")
        XCTAssertEqual(newNodes.first { $0.content == "c-u2" }?.replyToId, "s_external_cc_id", "外部 ccMessageId 引用原样保留")
    }

    // MARK: - FavoriteItem 复制

    func testFavoriteItemsCopiedWithNodeRemap() throws {
        let original = makeBranchedConversation(title: "收藏对话")
        let u1 = try XCTUnwrap(nodes(of: original.id).first { $0.content == "c-u1" })
        context.insert(FavoriteItem(conversationId: original.id, tagId: "tag-1", contentPreview: "收藏对话", profileId: pid))
        context.insert(FavoriteItem(nodeId: u1.id, conversationId: original.id, tagId: "tag-1", contentPreview: "c-u1", profileId: pid))
        context.insert(FavoriteItem(nodeId: "ghost", conversationId: original.id, tagId: "tag-1", contentPreview: "悬空", profileId: pid))
        try context.save()

        let copy = viewModel.duplicateConversation(original, context: context)
        let copyId = copy.id
        let items = try context.fetch(FetchDescriptor<FavoriteItem>(
            predicate: #Predicate<FavoriteItem> { $0.conversationId == copyId }
        ))
        XCTAssertEqual(items.count, 2, "悬空气泡收藏应跳过")
        XCTAssertTrue(items.contains { $0.nodeId == nil && $0.tagId == "tag-1" }, "标签 join 要复制")
        let bubble = try XCTUnwrap(items.first { $0.nodeId != nil })
        let newU1 = nodes(of: copy.id).first { $0.content == "c-u1" }
        XCTAssertEqual(bubble.nodeId, newU1?.id, "气泡收藏 nodeId 要重映射")
    }

    // MARK: - 附件

    func testRewriteSegmentRefs() throws {
        let segs: [MessageSegment] = [
            .text("hi"),
            .imageRef(name: "a.png", type: "image/png", path: "attachments/AABBCCDD-旧标题/a.png"),
            .fileDataRef(name: "b.bin", mime: "application/octet-stream", path: "attachments/FFEE0011-别的对话/b.bin")
        ]
        let data = try JSONEncoder().encode(segs)
        let out = AttachmentStore.rewriteSegmentRefs(data, oldDir: "AABBCCDD-旧标题", newDir: "11223344-旧标题-copy")
        let decoded = try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(out))
        XCTAssertEqual(decoded[0], .text("hi"))
        XCTAssertEqual(decoded[1], .imageRef(name: "a.png", type: "image/png", path: "attachments/11223344-旧标题-copy/a.png"))
        XCTAssertEqual(decoded[2], segs[2], "别的对话目录的 ref 不该被动")
        XCTAssertNil(AttachmentStore.rewriteSegmentRefs(nil, oldDir: "x", newDir: "y"))
    }

    func testCopyConversationAttachmentsOnDisk() throws {
        MainThreadIO.allowMainThreadInThisTest()   // #033：测试体直接调 store / 工具，测试自己站主线程
        let oldConvId = "AABBCCDD-1111-2222-3333-444455556666"
        let newConvId = "EEFF0011-1111-2222-3333-444455556666"
        try FileLibraryStore.writeData("attachments/AABBCCDD-旧标题/x.txt", data: Data("hello".utf8), profileId: pid)

        let dirs = try XCTUnwrap(AttachmentStore.copyConversationAttachments(
            from: oldConvId, to: newConvId, newTitle: "旧标题-copy", profileId: pid))
        XCTAssertEqual(dirs.oldDir, "AABBCCDD-旧标题")
        XCTAssertEqual(dirs.newDir, "EEFF0011-旧标题-copy")
        let copied = AttachmentStore.read("attachments/EEFF0011-旧标题-copy/x.txt", profileId: pid)
        XCTAssertEqual(copied.map { String(decoding: $0, as: UTF8.self) }, "hello", "附件字节要复制到新目录")
        XCTAssertNotNil(AttachmentStore.read("attachments/AABBCCDD-旧标题/x.txt", profileId: pid), "源目录不能动")

        XCTAssertNil(AttachmentStore.copyConversationAttachments(
            from: "00000000-no-such", to: newConvId, newTitle: "x", profileId: pid), "无附件目录返回 nil")
    }
}
