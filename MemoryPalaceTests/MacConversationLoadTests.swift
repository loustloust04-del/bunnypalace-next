import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class MacConversationLoadTests: XCTestCase {
    func testIndexedLoadingPreservesCompleteHistoryAndContent() async throws {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let writer = ModelContext(container)
        let conv = Conversation(id: "metadata-load", title: "fixture", createTime: Date(), updateTime: Date(),
                                currentNodeId: "node-199", profileId: "test-metadata-floor")
        writer.insert(conv)
        for i in 0..<200 {
            let node = MessageNode(id: "node-\(i)", role: i % 2 == 0 ? "user" : "assistant",
                content: "message \(i): " + String(repeating: "payload ", count: 512), contentType: "text",
                createTime: Date(), parentId: i == 0 ? nil : "node-\(i - 1)",
                childrenIds: i == 199 ? [] : ["node-\(i + 1)"],
                conversationId: conv.id, profileId: conv.profileId)
            node.isPinned = i == 13
            node.isTrashed = i == 17
            writer.insert(node)
        }
        try writer.save()
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        let selected = try XCTUnwrap(reader.fetch(FetchDescriptor<Conversation>()).first)
        let vm = ConversationViewModel()
        vm.loadConversation(selected, context: reader)
        for _ in 0..<200 {
            if !vm.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.currentPath.count, 199)
        XCTAssertEqual(vm.currentPath.first?.id, "node-0")
        XCTAssertEqual(vm.currentPath.last?.id, "node-199")
        XCTAssertTrue(vm.currentPath.first?.content.hasPrefix("message 0: ") == true)
        XCTAssertTrue(vm.currentPath.last?.content.hasPrefix("message 199: ") == true)
        XCTAssertEqual(vm.pinnedNodes.map(\.id), ["node-13"])
        XCTAssertEqual(vm.currentPath.last?.parentId, "node-198")
    }
}
