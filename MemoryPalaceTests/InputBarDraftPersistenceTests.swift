import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class InputBarDraftPersistenceTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, ModelContext, ConversationViewModel) {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (container, ModelContext(container), ConversationViewModel())
    }

    private func conversation(_ id: String) -> Conversation {
        Conversation(id: id, title: id, createTime: Date(), updateTime: Date(), currentNodeId: "",
                     profileId: "test-inputbar-drafts")
    }

    private func attachment(_ name: String) -> PendingChatAttachment {
        .text(name: name, typeDescription: "文本", extractedText: name, byteCount: name.utf8.count)
    }

    private func storedAttachments(_ conversation: Conversation) throws -> [PendingChatAttachment] {
        guard let data = conversation.draftAttachmentsData else { return [] }
        return try JSONDecoder().decode([PendingChatAttachment].self, from: data)
    }

    func testExistingConversationSwitchFlushDoesNotOverwriteRestoredQueuedDraft() throws {
        let (container, context, vm) = try fixture()
        let old = conversation("old"), next = conversation("existing")
        let queued = attachment("排队附件.txt")
        old.draftText = "排队正文"
        old.draftAttachmentsData = try JSONEncoder().encode([queued])
        next.draftText = "另一对话草稿"
        context.insert(old)
        context.insert(next)
        try context.save()
        vm.selectedConversation = old
        vm.selectedAttachments = [queued]
        var draft = InputBarDraftPersistence()
        draft.load(text: old.draftText, attachments: [queued], quotePreview: nil, quoteReplyTo: nil)

        // 真 sendMessage 排队，但不发请求；和 InputBarStack 的 binding setter 一样同步记下清空。
        vm.assistantTurnInFlight = true
        vm.activeConversationId = old.id
        let model = ProviderModel(credentialId: "test-inputbar-unused", modelId: "test", name: "Test")
        let profile = Profile(id: old.profileId, name: "Test", emoji: "", description: "",
                              userName: "User", assistantName: "Assistant")
        XCTAssertTrue(vm.sendMessage("排队正文", model: model, profile: profile, preset: .balanced,
                                     providerManager: ProviderManager(), context: context, attachments: [queued]))
        XCTAssertEqual(vm.pendingSends.count, 1)
        vm.selectedAttachments = []
        draft.persistAttachments([], to: old, context: context)
        old.draftText = ""
        old.draftAttachmentsData = nil
        draft.persistText("", to: old, context: context)

        vm.selectedConversation = next
        XCTAssertFalse(vm.isDraftConversation)
        XCTAssertTrue(vm.pendingSends.isEmpty)
        XCTAssertEqual(old.draftText, "排队正文", "didSet 必须先同步恢复")
        XCTAssertEqual(try storedAttachments(old).map(\.id), [queued.id])

        // iOS 切对话 onChange 实际共用的 flush；此时仍然拿着旧输入框的清空快照。
        draft.flush(to: old, text: "", attachments: vm.selectedAttachments,
                    quotePreview: vm.quotingPreview, quoteReplyTo: vm.quotingReplyTo, context: context)
        XCTAssertEqual(old.draftText, "排队正文")
        XCTAssertEqual(try storedAttachments(old).map(\.id), [queued.id])
        XCTAssertEqual(next.draftText, "另一对话草稿")
        let verify = ModelContext(container)
        let saved = try XCTUnwrap(verify.fetch(FetchDescriptor<Conversation>()).first { $0.id == old.id })
        XCTAssertEqual(saved.draftText, "排队正文")
        XCTAssertEqual(try storedAttachments(saved).map(\.id), [queued.id])
    }

    func testFirstDraftSendQueuedDuringAnotherConversationTurnPersistsBeforeSwitchAndRestoresDraft() throws {
        let (container, context, vm) = try fixture()
        let active = conversation("active"), next = conversation("next")
        context.insert(active)
        context.insert(next)
        try context.save()
        vm.selectedConversation = active
        vm.assistantTurnInFlight = true
        vm.activeConversationId = active.id

        vm.startDraftConversation(profileId: active.profileId, fresh: true)
        let draft = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(draft.id, active.id)
        XCTAssertTrue(vm.isDraftConversation)
        let beforeSend = ModelContext(container)
        XCTAssertFalse(try beforeSend.fetch(FetchDescriptor<Conversation>()).contains { $0.id == draft.id })

        let queued = attachment("首条排队附件.txt")
        let text = "新对话首条排队正文"
        let model = ProviderModel(credentialId: "test-inputbar-unused", modelId: "test", name: "Test")
        let profile = Profile(id: active.profileId, name: "Test", emoji: "", description: "",
                              userName: "User", assistantName: "Assistant")
        XCTAssertTrue(vm.sendMessage(text, model: model, profile: profile, preset: .balanced,
                                     providerManager: ProviderManager(), context: context, attachments: [queued]))
        XCTAssertFalse(vm.isDraftConversation)
        XCTAssertEqual(vm.pendingSends.count, 1)
        let pending = try XCTUnwrap(vm.pendingSends.first)
        XCTAssertEqual(pending.conversationId, draft.id)
        XCTAssertEqual(pending.text, text)
        XCTAssertEqual(pending.attachments.map(\.id), [queued.id])
        XCTAssertTrue(vm.assistantTurnInFlight)
        XCTAssertEqual(vm.activeConversationId, active.id)
        XCTAssertTrue(vm.currentPath.isEmpty)

        // 入队受理就必须真正落库，不能靠切走后的 save 补救。
        let queuedContext = ModelContext(container)
        let savedDraft = try XCTUnwrap(queuedContext.fetch(FetchDescriptor<Conversation>()).first { $0.id == draft.id })
        XCTAssertEqual(savedDraft.draftText, "")
        XCTAssertTrue(try storedAttachments(savedDraft).isEmpty)
        let queuedNodes = try queuedContext.fetch(FetchDescriptor<MessageNode>()).filter { $0.conversationId == draft.id }
        XCTAssertEqual(queuedNodes.count, 1, "排队时只提交隐形根，不创建 user 或 assistant 消息")
        let root = try XCTUnwrap(queuedNodes.first)
        XCTAssertEqual(root.id, savedDraft.currentNodeId)
        XCTAssertEqual(root.role, "system")
        XCTAssertEqual(root.content, "")
        XCTAssertNil(root.parentId)
        XCTAssertTrue(root.childrenIds.isEmpty)

        vm.selectedConversation = next
        XCTAssertTrue(vm.pendingSends.isEmpty)
        XCTAssertEqual(draft.draftText, text)
        XCTAssertEqual(try storedAttachments(draft).map(\.id), [queued.id])
        XCTAssertEqual(next.draftText, "")
        XCTAssertTrue(vm.assistantTurnInFlight)
        XCTAssertEqual(vm.activeConversationId, active.id)

        let restoredContext = ModelContext(container)
        let restored = try XCTUnwrap(restoredContext.fetch(FetchDescriptor<Conversation>()).first { $0.id == draft.id })
        XCTAssertEqual(restored.draftText, text)
        XCTAssertEqual(try storedAttachments(restored).map(\.id), [queued.id])
        let restoredNodes = try restoredContext.fetch(FetchDescriptor<MessageNode>()).filter { $0.conversationId == draft.id }
        XCTAssertEqual(restoredNodes.map(\.id), [root.id])
    }

    func testRealtimeEditsKeepRecoveredSuffixWithoutDuplicatingIt() throws {
        let (_, context, _) = try fixture()
        let conv = conversation("realtime")
        context.insert(conv)
        var draft = InputBarDraftPersistence()
        draft.load(text: "", attachments: [], quotePreview: nil, quoteReplyTo: nil)
        draft.persistText("正在输入", to: conv, context: context)
        XCTAssertEqual(conv.draftText, "正在输入")
        conv.draftText += "\n恢复的排队正文"
        draft.persistText("正在输入更多", to: conv, context: context)
        XCTAssertEqual(conv.draftText, "正在输入更多\n恢复的排队正文")
        draft.persistText("再次修改", to: conv, context: context)
        XCTAssertEqual(conv.draftText, "再次修改\n恢复的排队正文")
        draft.flush(to: conv, text: "再次修改", attachments: [], quotePreview: nil, quoteReplyTo: nil,
                    context: context)
        XCTAssertEqual(conv.draftText, "再次修改\n恢复的排队正文")
        draft.persistText("", to: conv, context: context)
        XCTAssertEqual(conv.draftText, "恢复的排队正文")
    }

    func testBackgroundFlushPersistsLiveTailAndAttachmentsAlongsideRecovery() throws {
        let (_, context, _) = try fixture()
        let conv = conversation("background")
        let removed = attachment("移除.txt"), added = attachment("新增.txt"), recovered = attachment("恢复.txt")
        conv.draftText = "已提交"
        conv.draftAttachmentsData = try JSONEncoder().encode([removed])
        context.insert(conv)
        var draft = InputBarDraftPersistence()
        draft.load(text: "已提交", attachments: [removed], quotePreview: nil, quoteReplyTo: nil)
        conv.draftText += "\n恢复正文"
        conv.draftAttachmentsData = try JSONEncoder().encode([removed, recovered])
        draft.flush(to: conv, text: "已提交和尾巴", attachments: [added], quotePreview: "新引用",
                    quoteReplyTo: "node", context: context)
        XCTAssertEqual(conv.draftText, "已提交和尾巴\n恢复正文")
        XCTAssertEqual(try storedAttachments(conv).map(\.id), [recovered.id, added.id])
        XCTAssertEqual(conv.draftQuotePreview, "新引用")
        XCTAssertEqual(conv.draftQuoteReplyTo, "node")
        draft.flush(to: conv, text: "已提交和尾巴", attachments: [added], quotePreview: "新引用",
                    quoteReplyTo: "node", context: context)
        XCTAssertEqual(conv.draftText, "已提交和尾巴\n恢复正文")
        XCTAssertEqual(try storedAttachments(conv).map(\.id), [recovered.id, added.id])
    }

    func testUnchangedEmptySnapshotPreservesRecoveryOnBackgroundFlushAndOnChange() throws {
        let (_, context, _) = try fixture()
        let conv = conversation("empty")
        let recovered = attachment("恢复.txt")
        context.insert(conv)
        var draft = InputBarDraftPersistence()
        draft.load(text: "", attachments: [], quotePreview: nil, quoteReplyTo: nil)
        conv.draftText = "恢复正文"
        conv.draftAttachmentsData = try JSONEncoder().encode([recovered])
        conv.draftQuotePreview = "恢复引用"
        conv.draftQuoteReplyTo = "recovered-node"
        draft.persistText("", to: conv, context: context)
        draft.flush(to: conv, text: "", attachments: [], quotePreview: nil, quoteReplyTo: nil, context: context)
        XCTAssertEqual(conv.draftText, "恢复正文")
        XCTAssertEqual(try storedAttachments(conv).map(\.id), [recovered.id])
        XCTAssertEqual(conv.draftQuotePreview, "恢复引用")
        XCTAssertEqual(conv.draftQuoteReplyTo, "recovered-node")
    }

    func testTrashedDraftIsNotWritten() throws {
        let (_, context, _) = try fixture()
        let conv = conversation("trashed")
        conv.draftText = "保留"
        conv.isTrashed = true
        context.insert(conv)
        var draft = InputBarDraftPersistence()
        draft.load(text: "保留", attachments: [], quotePreview: nil, quoteReplyTo: nil)
        draft.persistText("改写", to: conv, context: context)
        draft.persistAttachments([attachment("新增.txt")], to: conv, context: context)
        draft.flush(to: conv, text: "改写", attachments: [attachment("新增.txt")], quotePreview: "改写",
                    quoteReplyTo: "node", context: context)
        XCTAssertEqual(conv.draftText, "保留")
        XCTAssertNil(conv.draftAttachmentsData)
        XCTAssertEqual(conv.draftQuotePreview, "")
    }
}
