import XCTest
import SwiftData
@testable import 记忆花园

/// 记忆条目「去原对话 / 跳到这条」：出处还在就跳到那条；消息没了只开窗口、不误报切分支；窗口没了不动
@MainActor
final class MemorySourceJumpTests: XCTestCase {
    private let pid = "memory-source-jump-floor"

    private struct Fixture {
        let context: ModelContext
        let conversation: Conversation
        let node: MessageNode
        let memory: Memory
    }

    private func fixture() throws -> Fixture {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let conversation = Conversation(id: "source-window", title: "虚构窗口", createTime: Date(), updateTime: Date(),
                                        currentNodeId: "n2", profileId: pid)
        context.insert(conversation)
        let first = MessageNode(id: "n1", role: "user", content: "虚构的第一句", contentType: "text", createTime: Date(),
                                parentId: nil, childrenIds: ["n2"], conversationId: conversation.id, profileId: pid)
        let second = MessageNode(id: "n2", role: "assistant", content: "虚构的回答", contentType: "text", createTime: Date(),
                                 parentId: "n1", childrenIds: [], conversationId: conversation.id, profileId: pid)
        context.insert(first)
        context.insert(second)
        try context.save()
        let memory = Memory(content: "虚构的记忆", category: "fact", profileId: pid, sourceConversationId: conversation.id)
        memory.sourceNodeId = first.id
        return Fixture(context: context, conversation: conversation, node: first, memory: memory)
    }

    private func waitLoaded(_ vm: ConversationViewModel) async throws {
        for _ in 0..<200 where vm.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(vm.isLoading)
        try await Task.sleep(for: .milliseconds(50))
    }

    private func open(_ f: Fixture, _ vm: ConversationViewModel) -> (MemoryConversationLink.MessageResult, Int) {
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .conversationNavigationRequested, object: nil, queue: nil) { _ in
            posted += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let result = MemoryConversationLink.openSource(of: f.memory, profileId: pid, context: f.context, viewModel: vm)
        return (result, posted)
    }

    func testLiveSourceJumpsToThatMessage() async throws {
        let f = try fixture()
        let vm = ConversationViewModel()
        let (result, posted) = open(f, vm)
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(posted, 1)
        try await waitLoaded(vm)
        XCTAssertEqual(vm.selectedConversation?.id, f.conversation.id)
        XCTAssertEqual(vm.currentPath.map(\.id), ["n1", "n2"])
        XCTAssertEqual(vm.scrollToNodeId, "n1")
        XCTAssertEqual(vm.highlightedNodeId, "n1")
        XCTAssertNil(vm.transientNotice)
    }

    func testSourceWithoutNodeOpensWindowAndFlipsToChat() async throws {
        let f = try fixture()
        f.memory.sourceNodeId = nil
        let vm = ConversationViewModel()
        let (result, posted) = open(f, vm)
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(posted, 1)
        try await waitLoaded(vm)
        XCTAssertEqual(vm.selectedConversation?.id, f.conversation.id)
        XCTAssertNil(vm.scrollToNodeId)
    }

    func testGoneMessageOpensWindowWithoutBranchNotice() async throws {
        let invalidations: [(String, (Fixture) -> Void)] = [
            ("trashed", { $0.node.isTrashed = true }),
            ("hidden", { $0.node.sourceVisibility = "hidden" }),
            ("stale id", { $0.memory.sourceNodeId = "no-such-node" }),
            ("other window", { $0.node.conversationId = "another-window" }),
        ]
        for (kind, invalidate) in invalidations {
            let f = try fixture()
            invalidate(f)
            try f.context.save()
            let vm = ConversationViewModel()
            let (result, posted) = open(f, vm)
            XCTAssertEqual(result, .messageGone, kind)
            XCTAssertEqual(posted, 1, kind)
            XCTAssertNil(vm.pendingScrollNodeId, kind)
            XCTAssertNil(vm.transientNotice, "不得误报已切换到分支：\(kind)")
            try await waitLoaded(vm)
            XCTAssertEqual(vm.selectedConversation?.id, f.conversation.id, kind)
            XCTAssertNil(vm.scrollToNodeId, kind)
            XCTAssertNil(vm.highlightedNodeId, kind)
        }
    }

    func testGoneWindowDoesNotNavigate() throws {
        let invalidations: [(String, (Fixture) -> Void)] = [
            ("trashed", { $0.conversation.isTrashed = true }),
            ("deleted", { $0.context.delete($0.conversation) }),
            ("other floor", { $0.conversation.profileId = "another-floor" }),
        ]
        for (kind, invalidate) in invalidations {
            let f = try fixture()
            invalidate(f)
            try f.context.save()
            let vm = ConversationViewModel()
            let (result, posted) = open(f, vm)
            XCTAssertEqual(result, .windowGone, kind)
            XCTAssertEqual(posted, 0, kind)
            XCTAssertNil(vm.selectedConversation, kind)
            XCTAssertFalse(vm.isLoading, kind)
        }
    }
}
