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
        XCTAssertEqual(a.draftText, "")
        draft.updateTemporary(false, conversationId: a.id)
        draft.edit("committed", session: draft.sessionID, context: context)
        XCTAssertEqual(a.draftText, "committed")
        a.isTrashed = true
        draft.edit("deleted edit", session: draft.sessionID, context: context)
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
        context.insert(a); context.insert(b)
        let draft = MacComposerDraft()
        draft.switchConversation(to: a, temporary: false, viewModel: vm, context: context)
        let oldSession = draft.sessionID
        draft.edit("old text", session: oldSession, context: context)
        draft.switchConversation(to: b, temporary: false, viewModel: vm, context: context)
        draft.edit("late old composition", session: oldSession, context: context)
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
