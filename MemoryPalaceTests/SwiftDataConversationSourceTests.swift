import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 合同用例第二条腿：同一份 `ConversationSourceContract.floor()` 落进内存 SwiftData，
/// `SwiftDataConversationSource` 必须逐条等于 `SnapshotConversationSource`（研究 §9.8 的对照）。
final class SwiftDataConversationSourceTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        for window in ConversationSourceContract.floor(crossFloorDuplicate: false).windows {
            let conversation = Conversation(id: window.id, title: window.title,
                                            createTime: window.nodes.compactMap(\.at).min() ?? ConversationSourceContract.anchor,
                                            updateTime: window.updateTime ?? window.nodes.compactMap(\.at).max() ?? ConversationSourceContract.anchor,
                                            currentNodeId: window.current, profileId: window.profileId ?? ConversationSourceContract.profileId)
            conversation.memoryEnabled = window.memoryEnabled
            conversation.isTrashed = window.trashed
            conversation.branchSelectionData = window.branchSelection.flatMap(BranchSelection.encode)
            context.insert(conversation)
            for node in window.nodes {
                let message = MessageNode(id: node.id, role: node.role, content: node.text,
                                          contentType: node.contentType ?? "text", createTime: node.at,
                                          parentId: node.parent, childrenIds: node.childrenIds ?? [],
                                          conversationId: window.id,
                                          profileId: window.profileId ?? ConversationSourceContract.profileId)
                message.isTrashed = node.deleted
                message.isSyntheticRoot = node.isSyntheticRoot ?? false
                message.sourceVisibility = node.sourceVisibility ?? (node.hidden ? "hidden" : nil)
                message.ccMessageId = node.ccMessageId
                context.insert(message)
            }
        }
        try context.save()
        return container
    }

    func testSwiftDataSourceSatisfiesContract() throws {
        try ConversationSourceContract.check(SwiftDataConversationSource(container: try container()), crossFloorDuplicate: false)
    }

    func testSwiftDataSourceMatchesSnapshotOnContractFloor() throws {
        let swiftData = SwiftDataConversationSource(container: try container())
        let snapshot = SnapshotConversationSource(floor: ConversationSourceContract.floor(crossFloorDuplicate: false))
        let p = ConversationSourceContract.profileId

        func ids(_ windows: [ConversationWindow]) -> [String] { windows.map(\.id).sorted() }
        XCTAssertEqual(ids(try swiftData.windows(profileId: p, updatedSince: nil, includeTrashed: true)),
                       ids(try snapshot.windows(profileId: p, updatedSince: nil, includeTrashed: true)))
        for cid in [ConversationSourceContract.alpha, ConversationSourceContract.beta, ConversationSourceContract.delta] {
            let profile = cid == ConversationSourceContract.delta ? ConversationSourceContract.otherProfileId : p
            XCTAssertEqual(try swiftData.nodes(profileId: profile, conversationId: cid).map(\.id).sorted(),
                           try snapshot.nodes(profileId: profile, conversationId: cid).map(\.id).sorted())
        }
        XCTAssertEqual(try swiftData.search(profileId: p, text: "星砂", conversationId: nil).map(\.id),
                       try snapshot.search(profileId: p, text: "星砂", conversationId: nil).map(\.id))
        XCTAssertEqual(try swiftData.titles(profileId: p, ids: [ConversationSourceContract.alpha, ConversationSourceContract.gamma]),
                       try snapshot.titles(profileId: p, ids: [ConversationSourceContract.alpha, ConversationSourceContract.gamma]))
    }
}
