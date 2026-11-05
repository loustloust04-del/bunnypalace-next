import XCTest
import SwiftData
import Observation
import os
@testable import 记忆花园

@MainActor
final class MacComposerDraftTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, ModelContext, ConversationViewModel) {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (container, ModelContext(container), ConversationViewModel())
    }
    private func conversation(_ id: String, profile: String = "test-mac-drafts") -> Conversation {
        Conversation(id: id, title: id, createTime: Date(), updateTime: Date(), currentNodeId: "", profileId: profile)
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
        let queued = attachment("排队附件.txt"), nextAttachment = attachment("另一附件.txt")
        old.draftText = "排队正文"
        old.draftAttachmentsData = try JSONEncoder().encode([queued])
        next.draftText = "另一对话草稿"
        next.draftAttachmentsData = try JSONEncoder().encode([nextAttachment])
        context.insert(old); context.insert(next); try context.save()
        vm.selectedConversation = old
        let draft = MacComposerDraft()
        draft.switchConversation(to: old, temporary: false, viewModel: vm, context: context)

        // 真发送只进入排队；模拟 mac 输入条成功发送后清空两个 binding。
        vm.assistantTurnInFlight = true
        vm.activeConversationId = old.id
        let model = ProviderModel(credentialId: "test-mac-unused", modelId: "test", name: "Test")
        let profile = Profile(id: old.profileId, name: "Test", emoji: "", description: "",
                              userName: "User", assistantName: "Assistant")
        XCTAssertTrue(vm.sendMessage("排队正文", model: model, profile: profile, preset: .balanced,
                                     providerManager: ProviderManager(), context: context, attachments: [queued]))
        XCTAssertEqual(vm.pendingSends.count, 1)
        draft.editAttachments([], session: draft.sessionID, viewModel: vm, context: context)
        old.draftText = ""
        old.draftAttachmentsData = nil
        draft.edit("", session: draft.sessionID, context: context)

        vm.selectedConversation = next
        XCTAssertFalse(vm.isDraftConversation)
        XCTAssertTrue(vm.pendingSends.isEmpty)
        XCTAssertEqual(old.draftText, "排队正文", "didSet 必须先同步恢复")
        XCTAssertEqual(try storedAttachments(old).map(\.id), [queued.id])
        // SwiftUI onChange 才切换 composer，此时还握着旧的空快照。
        draft.switchConversation(to: next, temporary: false, viewModel: vm, context: context)
        XCTAssertEqual(old.draftText, "排队正文")
        XCTAssertEqual(try storedAttachments(old).map(\.id), [queued.id])
        XCTAssertEqual(draft.text, "另一对话草稿")
        XCTAssertEqual(vm.selectedAttachments.map(\.id), [nextAttachment.id])
        draft.edit("另一对话继续输入", session: draft.sessionID, context: context)
        draft.flush(viewModel: vm, context: context)

        let verify = ModelContext(container)
        let saved = try verify.fetch(FetchDescriptor<Conversation>())
        let savedOld = try XCTUnwrap(saved.first { $0.id == old.id })
        let savedNext = try XCTUnwrap(saved.first { $0.id == next.id })
        XCTAssertEqual(savedOld.draftText, "排队正文")
        XCTAssertEqual(try storedAttachments(savedOld).map(\.id), [queued.id])
        XCTAssertEqual(savedNext.draftText, "另一对话继续输入")
        XCTAssertEqual(try storedAttachments(savedNext).map(\.id), [nextAttachment.id])

        vm.selectedConversation = old
        draft.switchConversation(to: old, temporary: false, viewModel: vm, context: context)
        XCTAssertEqual(draft.text, "排队正文")
        XCTAssertEqual(vm.selectedAttachments.map(\.id), [queued.id])
    }

    func testRealtimeEditsAndFlushKeepRecoveredTextAndAttachments() throws {
        let (_, context, vm) = try fixture()
        let a = conversation("realtime")
        let removed = attachment("移除.txt"), added = attachment("新增.txt"), recovered = attachment("恢复.txt")
        a.draftText = "原草稿"
        a.draftAttachmentsData = try JSONEncoder().encode([removed])
        context.insert(a)
        let draft = MacComposerDraft()
        draft.switchConversation(to: a, temporary: false, viewModel: vm, context: context)
        a.draftText += "\n恢复正文"
        a.draftAttachmentsData = try JSONEncoder().encode([removed, recovered])

        draft.edit("继续输入", session: draft.sessionID, context: context)
        draft.editAttachments([added], session: draft.sessionID, viewModel: vm, context: context)
        draft.flush(viewModel: vm, context: context)
        draft.edit("再次修改", session: draft.sessionID, context: context)
        draft.flush(viewModel: vm, context: context)
        XCTAssertEqual(a.draftText, "再次修改\n恢复正文")
        XCTAssertEqual(try storedAttachments(a).map(\.id), [recovered.id, added.id])
    }

    func testSwitchWhileEditingPersistsStashInsteadOfEditedMessage() throws {
        let (container, context, vm) = try fixture()
        let a = conversation("editing"), b = conversation("after-editing")
        let stashed = attachment("草稿附件.txt"), edited = attachment("编辑附件.txt")
        context.insert(a); context.insert(b)
        let draft = MacComposerDraft()
        draft.switchConversation(to: a, temporary: false, viewModel: vm, context: context)
        draft.edit("收起的草稿", session: draft.sessionID, context: context)
        draft.editAttachments([stashed], session: draft.sessionID, viewModel: vm, context: context)
        vm.editingMessage = .init(
            nodeId: "edited-node",
            restored: .init(text: "原消息", attachments: [edited], quotePreview: nil, quoteReplyTo: nil, missingCount: 0),
            stash: .init(text: draft.text, attachments: [stashed], quotePreview: "草稿引用", quoteReplyTo: "quoted-node")
        )
        draft.edit("编辑中的消息", session: draft.sessionID, context: context, persist: false)
        draft.editAttachments([edited], session: draft.sessionID, viewModel: vm, context: context)
        vm.quotingPreview = "编辑中的引用"
        vm.quotingReplyTo = "edited-quote"
        draft.switchConversation(to: b, temporary: false, viewModel: vm, context: context)

        XCTAssertNil(vm.editingMessage)
        XCTAssertEqual(draft.text, "")
        XCTAssertTrue(vm.selectedAttachments.isEmpty)
        let verify = ModelContext(container)
        let saved = try XCTUnwrap(verify.fetch(FetchDescriptor<Conversation>()).first { $0.id == a.id })
        XCTAssertEqual(saved.draftText, "收起的草稿")
        XCTAssertEqual(try storedAttachments(saved).map(\.id), [stashed.id])
        XCTAssertEqual(saved.draftQuotePreview, "草稿引用")
        XCTAssertEqual(saved.draftQuoteReplyTo, "quoted-node")
    }

    func testSwitchPreservesOldDraftAndLoadsNewDraftAndQuote() throws {
        let (container, context, vm) = try fixture()
        let a = conversation("a"), b = conversation("b")
        b.draftText = "second draft"; b.draftQuotePreview = "second quote"
        context.insert(a); context.insert(b); try context.save()
        let draft = MacComposerDraft()
        draft.switchConversation(to: a, temporary: false, viewModel: vm, context: context)
        draft.edit("first edited", session: draft.sessionID, context: context)
        vm.quotingPreview = "first quote"
        draft.switchConversation(to: b, temporary: false, viewModel: vm, context: context)
        XCTAssertEqual(a.draftText, "first edited")
        XCTAssertEqual(a.draftQuotePreview, "first quote")
        XCTAssertEqual(draft.text, "second draft")
        XCTAssertEqual(vm.quotingPreview, "second quote")
        let verify = ModelContext(container)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<Conversation>()).first { $0.id == "a" }?.draftText, "first edited")
    }

    func testTemporaryAndDeletedConversationsAreNotWritten() throws {
        let (_, context, vm) = try fixture()
        let a = conversation("temporary")
        context.insert(a); try context.save()
        let draft = MacComposerDraft()
        draft.switchConversation(to: a, temporary: true, viewModel: vm, context: context)
        draft.edit("unsent", session: draft.sessionID, context: context); draft.flush(viewModel: vm, context: context)
        let unsent = attachment("临时附件.txt")
        draft.editAttachments([unsent], session: draft.sessionID, viewModel: vm, context: context)
        draft.flush(viewModel: vm, context: context)
        XCTAssertNil(a.draftAttachmentsData)
        XCTAssertEqual(a.draftText, "")
        draft.updateTemporary(false, conversationId: a.id)
        draft.edit("committed", session: draft.sessionID, context: context)
        XCTAssertEqual(a.draftText, "committed")
        draft.flush(viewModel: vm, context: context)
        XCTAssertEqual(try storedAttachments(a).map(\.id), [unsent.id])
        a.isTrashed = true
        draft.edit("deleted edit", session: draft.sessionID, context: context)
        draft.editAttachments([], session: draft.sessionID, viewModel: vm, context: context)
        draft.flush(viewModel: vm, context: context)
        XCTAssertEqual(try storedAttachments(a).map(\.id), [unsent.id])
        XCTAssertEqual(a.draftText, "committed")
    }

    func testProfileResetReleasesPreviousDraftOwner() throws {
        let (_, context, vm) = try fixture()
        let a = conversation("floor-a-conversation", profile: "floor-a"), b = conversation("floor-b-conversation", profile: "floor-b")
        context.insert(a); context.insert(b)
        let draft = MacComposerDraft()
        draft.switchConversation(to: a, temporary: false, viewModel: vm, context: context)
        draft.edit("floor a", session: draft.sessionID, context: context)
        draft.reset()
        draft.edit("late edit", session: draft.sessionID, context: context)
        XCTAssertEqual(a.draftText, "floor a")
        draft.switchConversation(to: b, temporary: false, viewModel: vm, context: context)
        XCTAssertEqual(draft.text, "")
    }

    func testOldEditorCallbackCannotOverwriteNewConversation() throws {
        let (_, context, vm) = try fixture()
        let a = conversation("old-editor"), b = conversation("new-editor")
        b.draftText = "keep new draft"
        let nextAttachment = attachment("新对话附件.txt")
        b.draftAttachmentsData = try JSONEncoder().encode([nextAttachment])
        context.insert(a); context.insert(b)
        let draft = MacComposerDraft()
        draft.switchConversation(to: a, temporary: false, viewModel: vm, context: context)
        let oldSession = draft.sessionID
        draft.edit("old text", session: oldSession, context: context)
        draft.switchConversation(to: b, temporary: false, viewModel: vm, context: context)
        draft.edit("late old composition", session: oldSession, context: context)
        draft.editAttachments([attachment("旧回调附件.txt")], session: oldSession, viewModel: vm, context: context)
        draft.flush(viewModel: vm, context: context)
        XCTAssertEqual(vm.selectedAttachments.map(\.id), [nextAttachment.id])
        XCTAssertEqual(try storedAttachments(b).map(\.id), [nextAttachment.id])
        XCTAssertEqual(draft.text, "keep new draft")
        XCTAssertEqual(b.draftText, "keep new draft")
        XCTAssertEqual(a.draftText, "old text")
    }

    func testKeystrokesDoNotInvalidateTranscriptObservation() throws {
        let (_, context, vm) = try fixture()
        let a = conversation("isolated")
        context.insert(a)
        let draft = MacComposerDraft()
        draft.switchConversation(to: a, temporary: false, viewModel: vm, context: context)
        let transcriptChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = vm.currentPath } onChange: { transcriptChanged.withLock { $0 = true } }
        for value in ["a", "ab", "abc"] { draft.edit(value, session: draft.sessionID, context: context) }
        XCTAssertFalse(transcriptChanged.withLock { $0 })
        XCTAssertEqual(a.draftText, "abc")
    }
}
