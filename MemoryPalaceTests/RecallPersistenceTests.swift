import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// All stores and archive bytes are temporary; recall never becomes chat content.
final class RecallPersistenceTests: XCTestCase {
    private let pid = "xctest-recall-persistence"
    private let time = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    /// 每列使用不同于出厂的值，防止解码漏列后回填默认值仍碰巧通过。
    private var historicalTuning: RecallTuning {
        RecallTuning(
            schemaVersion: 1,
            minimumEffectiveLength: 7, minimumSharedTerms: 3, activeOverlapThreshold: 0.7,
            cooldownTurns: 8, identityLookbackMessages: 9, maximumPages: 4,
            maximumQueryTerms: 11, minimumHanTermLength: 3, minimumLatinTermLength: 5,
            minimumFullTextTerms: 4, fullTextCoverageThreshold: 0.8,
            previousWindowMessages: 13, maximumRecallCalls: 12,
            maximumBodyCharacters: 5100, maximumResponseCharacters: 6200,
            datePageDays: 2, datePageEvents: 17, windowPageSegments: 19,
            searchPageResults: 7, wikiIndexPageLines: 41, wikiPageRecords: 23,
            originalPageMessages: 14
        )
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func container(at url: URL, schema: Schema? = nil) throws -> ModelContainer {
        let schema = schema ?? Schema([Conversation.self, MessageNode.self])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration("recall-test", schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        ])
    }

    private func conversation() -> Conversation {
        let conversation = Conversation(id: "conversation", title: "岚舟与星砚", createTime: time,
                                        updateTime: time, currentNodeId: "u1", provider: "api", profileId: pid)
        conversation.nodeCount = 1
        return conversation
    }

    private func user() -> MessageNode {
        MessageNode(id: "u1", role: "user", content: "林栖在云桥城的计划怎样了？", contentType: "text",
                    createTime: time, parentId: nil, childrenIds: [], conversationId: "conversation", profileId: pid)
    }

    private func facts() -> (RecallConversationState, RecallTurnReceipt) {
        let item = RecallItem(source: RecallSourceRef(profileId: pid, conversationId: "conversation", kind: .page,
                                                      path: "人物/林栖", version: "fictional-v1"),
                              text: "林栖在云桥城整理地图。", identities: ["林栖"], tokenCost: 15)
        var state = RecallConversationState()
        state.effectiveTurn = 4
        state.branchAnchor = "u1"
        state.topicAnchor = "林栖 云桥城 地图"
        state.active = [item]
        state.pending = [item]
        state.cooldowns = [RecallCooldown(source: RecallSourceRef(profileId: pid, conversationId: "conversation",
                                                                 kind: .fragment, path: "fictional-fragment", version: "v2"), untilTurn: 6)]
        state.lastAppliedTurnId = "u1"
        let decision = RecallTurnDecision(turnId: "u1", branchAnchor: "u1", origin: .user, gateReason: .search,
                                          tuning: historicalTuning, topicAnchor: state.topicAnchor,
                                          selected: [item], candidates: [item],
                                          suppressions: [], ignored: [], thawed: [], stateAfterResponse: state)
        var receipt = RecallTurnReceipt(decision: decision)
        let attempt = receipt.beginAttempt(id: "fictional-attempt")
        receipt.markAttempt(attempt, status: .submitted)
        var empty = RecallConversationState()
        XCTAssertTrue(receipt.recordResponse(attemptId: attempt, state: &empty, currentTurnId: "u1", currentBranchAnchor: "u1"))
        receipt.reads = [RecallReadReceipt(toolCallId: "fictional-tool", turnId: "u1", layer: "page", target: "人物/林栖")]
        return (state, receipt)
    }

    private func encode(_ document: FullConversationDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(document)
    }

    @MainActor
    func testLegacyDiskSchemaAddsNilColumnsWithoutChangingChat() throws {
        let url = root.appendingPathComponent("legacy.store")
        try autoreleasepool {
            let old = try container(at: url, schema: Schema(versionedSchema: PreRecallSchema.self))
            let context = ModelContext(old)
            context.autosaveEnabled = false
            context.insert(PreRecallSchema.Conversation(id: "conversation", title: "岚舟与星砚", time: time))
            context.insert(PreRecallSchema.MessageNode(id: "u1", content: "林栖在云桥城的计划怎样了？", time: time))
            try context.save()
        }
        try autoreleasepool {
            let current = try container(at: url)
            let context = ModelContext(current)
            let conversations = try context.fetch(FetchDescriptor<Conversation>())
            let nodes = try context.fetch(FetchDescriptor<MessageNode>())
            XCTAssertEqual(conversations.count, 1)
            XCTAssertEqual(nodes.count, 1)
            let conversation = try XCTUnwrap(conversations.first)
            let node = try XCTUnwrap(nodes.first)
            XCTAssertNil(conversation.recallStateData)
            XCTAssertEqual(conversation.recallState, RecallConversationState())
            XCTAssertNil(node.recallReceiptData)
            XCTAssertNil(node.recallReceipt)
            XCTAssertEqual(node.content, "林栖在云桥城的计划怎样了？")
            XCTAssertEqual(conversation.currentNodeId, "u1")
            XCTAssertEqual(node.role, "user")
        }
    }

    @MainActor
    func testCacheAndReceiptsSurviveDiskReopenAndFullBackupRoundTripByteForByte() throws {
        let sourceURL = root.appendingPathComponent("source.store")
        let destinationURL = root.appendingPathComponent("restored.store")
        let (state, receipt) = facts()
        var stateBytes: Data!
        var receiptBytes: Data!
        try autoreleasepool {
            let source = try container(at: sourceURL)
            let context = ModelContext(source)
            context.autosaveEnabled = false
            let conversation = conversation(), node = user()
            conversation.recallState = state
            node.recallReceipt = receipt
            node.agentOrigin = "fictional-agent"
            node.recallHitsData = Data("fictional-hit-bytes".utf8)
            stateBytes = conversation.recallStateData
            receiptBytes = node.recallReceiptData
            context.insert(conversation)
            context.insert(node)
            try context.save()
        }
        let archive: Data = try autoreleasepool {
            let reopened = try container(at: sourceURL)
            let context = ModelContext(reopened)
            let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
            let nodes = try context.fetch(FetchDescriptor<MessageNode>())
            XCTAssertEqual(conversation.recallState, state)
            XCTAssertEqual(conversation.recallStateData, stateBytes)
            XCTAssertEqual(nodes.first?.recallReceipt, receipt)
            XCTAssertEqual(nodes.first?.recallReceiptData, receiptBytes)
            XCTAssertEqual(nodes.first?.recallReceipt?.decision.tuning, historicalTuning)
            XCTAssertEqual(nodes.first?.agentOrigin, "fictional-agent")
            XCTAssertEqual(nodes.first?.recallHitsData, Data("fictional-hit-bytes".utf8))
            return try encode(FullConversationDocument(model: conversation, nodes: nodes))
        }
        try autoreleasepool {
            let decoded = try JSONDecoder().decode(FullConversationDocument.self, from: archive)
            XCTAssertEqual(decoded.recallStateData, stateBytes)
            XCTAssertEqual(decoded.nodes.first?.recallReceiptData, receiptBytes)
            let destination = try container(at: destinationURL)
            let context = ModelContext(destination)
            context.autosaveEnabled = false
            context.insert(decoded.toConversationModel())
            for node in decoded.nodes { context.insert(node.toNodeModel()) }
            try context.save()
        }
        try autoreleasepool {
            let restored = try container(at: destinationURL)
            let context = ModelContext(restored)
            let conversations = try context.fetch(FetchDescriptor<Conversation>())
            let nodes = try context.fetch(FetchDescriptor<MessageNode>())
            XCTAssertEqual(conversations.count, 1)
            XCTAssertEqual(nodes.count, 1, "Receipts must not create synthetic chat nodes")
            let conversation = try XCTUnwrap(conversations.first)
            let node = try XCTUnwrap(nodes.first)
            XCTAssertEqual(conversation.recallStateData, stateBytes)
            XCTAssertEqual(node.recallReceiptData, receiptBytes)
            XCTAssertEqual(node.recallReceipt?.decision.tuning, historicalTuning)
            XCTAssertEqual(node.agentOrigin, "fictional-agent")
            XCTAssertEqual(node.recallHitsData, Data("fictional-hit-bytes".utf8))
            XCTAssertEqual(node.content, user().content)
            XCTAssertEqual(node.role, "user")
            XCTAssertEqual(node.conversationId, conversation.id)
            XCTAssertEqual(try encode(FullConversationDocument(model: conversation, nodes: nodes)), archive)
        }
    }

    @MainActor
    func testWindowChoicesAndFrozenSnapshotSurviveFullBackupAndLegacyKeysStayNil() throws {
        let source = conversation()
        source.memoryWindowChoices = .init(timeline: false, pending: true, selfMemory: false, archive: true, previousWindow: true, pinned: false)
        source.previousWindowId = "fictional-earlier-window"
        source.previousWindowSnapshot = PreviousWindowSnapshot(sourceId: "fictional-earlier-window", sourceTitle: "云桥城航图",
            leafId: "earlier-a", capturedAt: time,
            messages: [.init(nodeId: "earlier-a", role: "assistant", createTime: time, text: "星砚的航图已经画好")])
        source.lastRealChatAt = time
        let doc = FullConversationDocument(model: source, nodes: [user()])
        XCTAssertNoThrow(try SchemaCoverageCheck.compareFields(modelName: "Conversation",
            modelFields: SchemaCoverageCheck.modelFieldNames(source), docFields: SchemaCoverageCheck.documentFieldNames(sample: doc),
            allowedExtraInDoc: ["schemaVersion", "nodes"]))
        let archive = try encode(doc)
        let restored = try JSONDecoder().decode(FullConversationDocument.self, from: archive).toConversationModel()
        XCTAssertEqual(restored.memoryWindowChoices, source.memoryWindowChoices)
        XCTAssertEqual(restored.previousWindowSnapshot, source.previousWindowSnapshot)
        XCTAssertEqual(restored.previousWindowId, source.previousWindowId)
        XCTAssertEqual(restored.lastRealChatAt, time)
        XCTAssertEqual(try encode(FullConversationDocument(model: restored, nodes: [user()])), archive)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        for key in ["memoryWindowChoicesData", "previousWindowId", "previousWindowSnapshotData", "lastRealChatAt"] {
            legacy.removeValue(forKey: key)
        }
        let old = try JSONDecoder().decode(FullConversationDocument.self, from: JSONSerialization.data(withJSONObject: legacy)).toConversationModel()
        XCTAssertNil(old.memoryWindowChoicesData)
        XCTAssertNil(old.previousWindowId)
        XCTAssertNil(old.previousWindowSnapshotData)
        XCTAssertNil(old.lastRealChatAt)
    }

    @MainActor
    func testLegacyFullBackupMissingRecallKeysRemainsNilAfterDiskImport() throws {
        let conversation = conversation(), node = user()
        let (state, receipt) = facts()
        conversation.recallState = state
        node.recallReceipt = receipt
        node.agentOrigin = "fictional-agent"
        node.recallHitsData = Data("fictional-hit-bytes".utf8)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(FullConversationDocument(model: conversation, nodes: [node]))) as? [String: Any])
        object.removeValue(forKey: "recallStateData")
        var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        nodes[0].removeValue(forKey: "recallReceiptData")
        nodes[0].removeValue(forKey: "agentOrigin")
        nodes[0].removeValue(forKey: "recallHitsData")
        object["nodes"] = nodes
        let legacy = try JSONDecoder().decode(FullConversationDocument.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.recallStateData)
        XCTAssertNil(legacy.nodes.first?.recallReceiptData)
        XCTAssertNil(legacy.nodes.first?.agentOrigin)
        XCTAssertNil(legacy.nodes.first?.recallHitsData)
        let url = root.appendingPathComponent("legacy-backup.store")
        try autoreleasepool {
            let store = try container(at: url)
            let context = ModelContext(store)
            context.autosaveEnabled = false
            context.insert(legacy.toConversationModel())
            for node in legacy.nodes { context.insert(node.toNodeModel()) }
            try context.save()
        }
        try autoreleasepool {
            let reopened = try container(at: url)
            let context = ModelContext(reopened)
            let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
            let nodes = try context.fetch(FetchDescriptor<MessageNode>())
            XCTAssertEqual(conversation.recallState, RecallConversationState())
            XCTAssertNil(conversation.recallStateData)
            XCTAssertEqual(nodes.count, 1)
            XCTAssertNil(nodes.first?.recallReceipt)
            XCTAssertNil(nodes.first?.agentOrigin)
            XCTAssertNil(nodes.first?.recallHitsData)
            XCTAssertEqual(nodes.first?.content, user().content)
            XCTAssertEqual(try encode(FullConversationDocument(model: conversation, nodes: nodes)), try encode(legacy))
        }
    }

    @MainActor
    func testOptionalAccessorsAndImportUndoSnapshotsKeepReceiptOutOfChat() throws {
        let conversation = conversation(), node = user()
        XCTAssertEqual(conversation.recallState, RecallConversationState())
        XCTAssertNil(node.recallReceipt)
        conversation.recallStateData = Data("invalid".utf8)
        node.recallReceiptData = Data("invalid".utf8)
        XCTAssertEqual(conversation.recallState, RecallConversationState())
        XCTAssertNil(node.recallReceipt)
        let (state, receipt) = facts()
        conversation.recallState = state
        node.recallReceipt = receipt
        let snapshots = try encodeSnapshots(conversation: conversation, nodes: [node])
        let restoredConversation = try XCTUnwrap(decodeConversationSnapshot(from: snapshots.conversationData)).makeConversation(profileId: pid)
        let restoredNode = try XCTUnwrap(decodeNodeSnapshots(from: snapshots.nodesData).first).makeNode(profileId: pid)
        XCTAssertEqual(restoredConversation.recallStateData, conversation.recallStateData)
        XCTAssertEqual(restoredNode.recallReceiptData, node.recallReceiptData)
        XCTAssertEqual(restoredNode.recallReceipt?.decision.tuning, historicalTuning)
        XCTAssertEqual(restoredNode.content, node.content)
        node.recallReceipt = nil
        XCTAssertNil(node.recallReceiptData)
        XCTAssertEqual(node.content, restoredNode.content)
    }

    @MainActor
    func testDailyBackupAndSyncDocumentsPreserveRawBytesAndDecodeOldMissingKeys() throws {
        let (state, receipt) = facts()
        let conversation = conversation(), node = user()
        conversation.recallState = state
        node.recallReceipt = receipt
        let nodeDocument = SyncStore.NodeDocument(
            id: node.id, role: node.role, content: node.content, contentType: node.contentType,
            createTime: node.createTime, parentId: node.parentId, childrenIds: node.childrenIds,
            isFavorite: false, isPinned: false, pinnedAt: nil, segmentsData: nil,
            ccMessageId: nil, replyToId: nil, replyQuote: nil, ccEdited: false,
            ccThinking: nil, imageDescsData: nil, recallReceiptData: node.recallReceiptData
        )
        let document = SyncStore.ConversationDocument(
            schemaVersion: SyncStore.schemaVersion, conversationId: conversation.id, profileId: pid,
            title: conversation.title, createTime: time, updateTime: time, currentNodeId: node.id,
            provider: "api", isFavorite: false, folderId: nil, pinnedAt: nil, memoryEnabled: true,
            selectedModelId: "", nodes: [nodeDocument], isDeleted: false, deletedAt: nil,
            recallStateData: conversation.recallStateData
        )
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let decoded = try decoder.decode(SyncStore.ConversationDocument.self, from: encoder.encode(document))
        XCTAssertEqual(decoded.recallStateData, conversation.recallStateData)
        XCTAssertEqual(decoded.nodes.first?.recallReceiptData, node.recallReceiptData)
        let restoredReceipt = try decoder.decode(RecallTurnReceipt.self, from: XCTUnwrap(decoded.nodes.first?.recallReceiptData))
        XCTAssertEqual(restoredReceipt.decision.tuning, historicalTuning)
        XCTAssertEqual(decoded.nodes.count, 1)
        XCTAssertEqual(decoded.nodes.first?.content, node.content)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        legacy.removeValue(forKey: "recallStateData")
        var nodes = try XCTUnwrap(legacy["nodes"] as? [[String: Any]])
        nodes[0].removeValue(forKey: "recallReceiptData")
        legacy["nodes"] = nodes
        let old = try decoder.decode(SyncStore.ConversationDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.recallStateData)
        XCTAssertNil(old.nodes.first?.recallReceiptData)
        XCTAssertEqual(old.nodes.count, 1)
        XCTAssertEqual(old.nodes.first?.content, node.content)
    }

}

/// Real pre-slice entities: every persisted field except the two new optional columns.
private enum PreRecallSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Conversation.self, MessageNode.self] }

    @Model
    final class Conversation {
        #Index<Conversation>([\.profileId], [\.profileId, \.lastOpenedAt], [\.profileId, \.isTrashed, \.lastOpenedAt])
        @Attribute(.unique) var id: String
        var profileId: String = ""
        var title: String
        var createTime: Date
        var updateTime: Date
        var currentNodeId: String
        var isFavorite: Bool = false
        var folderId: String?
        var pinnedAt: Date? = nil
        var unreadCount: Int = 0
        var nodeCount: Int = 0
        var lastOpenedAt: Date?
        var isDeleted: Bool = false
        var deletedAt: Date?
        var isTrashed: Bool = false
        var trashedAt: Date?
        var provider: String = "chatgpt"
        var importBatchId: UUID?
        var memoryEnabled: Bool = true
        var ccBridgeSessionName: String? = nil
        var selectedModelId: String = ""
        var currentStyleId: String = ""
        var mcpServerIds: [String] = []
        var permGrantsRaw: String = ""
        var draftText: String = ""
        @Attribute(.externalStorage) var draftAttachmentsData: Data? = nil
        var draftQuotePreview: String = ""
        var draftQuoteReplyTo: String = ""
        var branchSelectionData: Data? = nil
        var personaId: String? = nil
        var archiveKind: String? = nil
        @Attribute(.externalStorage) var sourceMetadata: Data? = nil
        @Attribute(.externalStorage) var cardVariablesData: Data? = nil

        init(id: String, title: String, time: Date) {
            self.id = id
            self.title = title
            createTime = time
            updateTime = time
            currentNodeId = "u1"
            profileId = "xctest-recall-persistence"
            nodeCount = 1
            provider = "api"
        }
    }

    @Model
    final class MessageNode {
        #Index<MessageNode>([\.profileId], [\.profileId, \.conversationId], [\.profileId, \.conversationId, \.isTrashed])
        @Attribute(.unique) var id: String
        var profileId: String = ""
        var isSyntheticRoot: Bool = false
        var role: String
        var content: String
        var contentType: String
        var createTime: Date?
        var parentId: String?
        var childrenIds: [String] = []
        var conversationId: String
        var isFavorite: Bool = false
        var isPinned: Bool = false
        var pinnedAt: Date? = nil
        var isDeleted: Bool = false
        var deletedAt: Date?
        var isTrashed: Bool = false
        var trashedAt: Date?
        @Attribute(.externalStorage) var segmentsData: Data?
        var ccMessageId: String? = nil
        var replyToId: String? = nil
        var replyQuote: String? = nil
        var ccEdited: Bool = false
        var styleIdSnapshot: String? = nil
        var ccThinking: String? = nil
        var usagePromptTokens: Int? = nil
        var usageCompletionTokens: Int? = nil
        var usageCacheReadTokens: Int? = nil
        var usageCacheWriteTokens: Int? = nil
        var usageCostUSD: Double? = nil
        var usageSavedUSD: Double? = nil
        var imageDescsData: Data? = nil
        var thinkingSummary: String? = nil
        var toolSummariesData: Data? = nil
        var bookRef: String? = nil
        var webSourcesData: Data? = nil
        var agentOrigin: String? = nil
        var recallHitsData: Data? = nil
        @Attribute(.externalStorage) var sourceMetadata: Data? = nil
        var sourceVisibility: String? = nil
        @Attribute(.externalStorage) var cardVariablesData: Data? = nil
        var cardEditedAt: Date? = nil
        var cardEventsData: Data? = nil

        init(id: String, content: String, time: Date) {
            self.id = id
            self.content = content
            createTime = time
            role = "user"
            contentType = "text"
            conversationId = "conversation"
            profileId = "xctest-recall-persistence"
        }
    }
}
