import XCTest
import SwiftData
@testable import 记忆花园

/// 全部使用虚构内容与独立临时磁盘库；旧实体刻意不含归因字段。
final class MemoryAttributionPersistenceTests: XCTestCase {
    private let pid = "xctest-attribution-persistence"
    private let time = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-attribution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func container(at url: URL, schema: Schema) throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [
            ModelConfiguration("attribution-test", schema: schema, url: url,
                               allowsSave: true, cloudKitDatabase: .none)
        ])
    }

    private func encode(_ document: FullMemoryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(document)
    }

    private func decode(_ data: Data) throws -> FullMemoryDocument {
        try JSONDecoder().decode(FullMemoryDocument.self, from: data)
    }

    @MainActor
    func testRealLegacyDiskStoreMigratesWithoutChangingOldValuesOrInferringAttribution() throws {
        let url = root.appendingPathComponent("legacy.store")
        let id = UUID(), related = UUID(), parent = UUID()
        let shortID = UUID()
        // 先用旧实体真正创建磁盘库；离开 autoreleasepool 后才由当前实体打开同一路径。
        try autoreleasepool {
            let schema = Schema(versionedSchema: PreAttributionMemorySchema.self)
            let oldContainer = try container(at: url, schema: schema)
            let context = ModelContext(oldContainer)
            context.autosaveEnabled = false
            let old = PreAttributionMemorySchema.Memory(content: "想画地图", category: "goal", profileId: pid)
            old.id = id
            old.keywords = ["虚构地图", "灯塔"]
            old.tokenCount = 17
            old.accessCount = 4
            old.lastAccessedAt = time.addingTimeInterval(1)
            old.decayWeight = 0.625
            old.validUntil = time.addingTimeInterval(2)
            old.sourceConversationId = "fictional-conversation"
            old.extractedBy = "fictional-model"
            old.isUserExplicit = true
            old.sourceQuote = "虚构人物准备画灯塔地图"
            old.sourceNodeId = "fictional-node"
            old.supersededAt = time.addingTimeInterval(3)
            old.feedbackDownCount = 1
            old.createdAt = time
            old.updatedAt = time.addingTimeInterval(4)
            old.embeddingData = Data([1, 2, 3, 4])
            old.embeddingRevision = 7
            old.relatedIds = [related]
            old.parentId = parent
            old.occurredDay = "2026-10-17"
            old.importance = 4
            old.emotion = -1
            old.resolved = false
            old.reviewedAt = time.addingTimeInterval(5)
            old.userEditedAt = time.addingTimeInterval(6)
            old.organizedAt = time.addingTimeInterval(7)
            old.organizedPage = "工程/虚构灯塔"
            old.organizeRejectedAt = time.addingTimeInterval(8)
            context.insert(old)
            let short = PreAttributionMemorySchema.Memory(content: "嗯", category: "fact", profileId: pid)
            short.id = shortID
            context.insert(short)
            try context.save()
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<PreAttributionMemorySchema.Memory>()), 2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "必须迁移刚创建的旧磁盘库，不可换成新库")

        try autoreleasepool {
            let current = try container(at: url, schema: Schema([Memory.self]))
            let context = ModelContext(current)
            let memories = try context.fetch(FetchDescriptor<Memory>())
            XCTAssertEqual(memories.count, 2)
            let migrated = try XCTUnwrap(memories.first { $0.id == id })
            XCTAssertEqual(migrated.content, "想画地图", "旧短正文不扩写")
            XCTAssertEqual(migrated.category, "goal")
            XCTAssertEqual(migrated.keywords, ["虚构地图", "灯塔"])
            XCTAssertEqual(migrated.tokenCount, 17)
            XCTAssertEqual(migrated.accessCount, 4)
            XCTAssertEqual(migrated.lastAccessedAt, time.addingTimeInterval(1))
            XCTAssertEqual(migrated.decayWeight, 0.625)
            XCTAssertEqual(migrated.validUntil, time.addingTimeInterval(2))
            XCTAssertEqual(migrated.sourceConversationId, "fictional-conversation")
            XCTAssertEqual(migrated.extractedBy, "fictional-model")
            XCTAssertTrue(migrated.isUserExplicit)
            XCTAssertEqual(migrated.sourceQuote, "虚构人物准备画灯塔地图")
            XCTAssertEqual(migrated.sourceNodeId, "fictional-node")
            XCTAssertEqual(migrated.supersededAt, time.addingTimeInterval(3))
            XCTAssertEqual(migrated.feedbackDownCount, 1)
            XCTAssertEqual(migrated.profileId, pid)
            XCTAssertEqual(migrated.createdAt, time)
            XCTAssertEqual(migrated.updatedAt, time.addingTimeInterval(4))
            XCTAssertEqual(migrated.embeddingData, Data([1, 2, 3, 4]))
            XCTAssertEqual(migrated.embeddingRevision, 7)
            XCTAssertEqual(migrated.relatedIds, [related])
            XCTAssertEqual(migrated.parentId, parent)
            XCTAssertEqual(migrated.occurredDay, "2026-10-17")
            XCTAssertEqual(migrated.importance, 4)
            XCTAssertEqual(migrated.emotion, -1)
            XCTAssertEqual(migrated.resolved, false)
            XCTAssertEqual(migrated.reviewedAt, time.addingTimeInterval(5))
            XCTAssertEqual(migrated.userEditedAt, time.addingTimeInterval(6))
            XCTAssertEqual(migrated.organizedAt, time.addingTimeInterval(7))
            XCTAssertEqual(migrated.organizedPage, "工程/虚构灯塔")
            XCTAssertEqual(migrated.organizeRejectedAt, time.addingTimeInterval(8))
            XCTAssertNil(migrated.subject)
            XCTAssertNil(migrated.speaker)
            let short = try XCTUnwrap(memories.first { $0.id == shortID })
            XCTAssertEqual(short.content, "嗯", "旧库不套新提取校验")
            XCTAssertNil(short.subject)
            XCTAssertNil(short.speaker)
            XCTAssertNil(short.occurredDay)
            XCTAssertNil(short.organizedAt)
            XCTAssertNil(short.organizedPage)
        }
    }

    @MainActor
    func testNewAttributionSurvivesBackupRoundTripAndDiskReopen() throws {
        let url = root.appendingPathComponent("new.store")
        let speakers = ["用户自述", "AI 观察", "AI 承诺"]
        var expected: [UUID: Data] = [:]
        try autoreleasepool {
            let current = try container(at: url, schema: Schema([Memory.self]))
            let context = ModelContext(current)
            context.autosaveEnabled = false
            for (index, speaker) in speakers.enumerated() {
                let memory = Memory(content: "虚构灯塔第\(index)条状态。", category: "relationship",
                                    keywords: ["灯塔", "地图"], profileId: pid,
                                    sourceConversationId: "fictional-conversation")
                memory.subject = "虚构灯塔-\(index)"
                memory.speaker = speaker
                memory.sourceQuote = "虚构出处第\(index)条"
                memory.sourceNodeId = "fictional-node-\(index)"
                memory.createdAt = time
                memory.updatedAt = time.addingTimeInterval(1)
                memory.occurredDay = "2026-10-17"
                memory.importance = 4
                memory.emotion = 1
                memory.resolved = false
                memory.reviewedAt = time
                memory.organizedAt = time
                memory.organizedPage = "工程/虚构灯塔"
                let payload = try encode(FullMemoryDocument(model: memory))
                expected[memory.id] = payload
                let decoded = try decode(payload)
                XCTAssertEqual(decoded.subject, memory.subject)
                XCTAssertEqual(decoded.speaker, speaker)
                let restored = decoded.toModel()
                XCTAssertEqual(restored.subject, memory.subject)
                XCTAssertEqual(restored.speaker, speaker)
                context.insert(restored)
            }
            try context.save()
        }
        try autoreleasepool {
            let reopened = try container(at: url, schema: Schema([Memory.self]))
            let context = ModelContext(reopened)
            let stored = try context.fetch(FetchDescriptor<Memory>())
            XCTAssertEqual(stored.count, speakers.count)
            XCTAssertEqual(Set(stored.compactMap(\.speaker)), Set(speakers))
            for memory in stored {
                let payload = try encode(FullMemoryDocument(model: memory))
                XCTAssertEqual(payload, try XCTUnwrap(expected[memory.id]), "磁盘重开及再导出不能丢归因或改变原字段")
                let again = try decode(payload).toModel()
                XCTAssertEqual(again.subject, memory.subject)
                XCTAssertEqual(again.speaker, memory.speaker)
                XCTAssertEqual(again.content, memory.content)
            }
        }
    }

    @MainActor
    func testLegacyBackupMissingKeysStaysUnknownAfterDiskImportReexportAndRestore() throws {
        let memory = Memory(content: "嗯", category: "fact", keywords: ["虚构关键词"], profileId: pid,
                            sourceConversationId: "fictional-old-conversation")
        memory.subject = "这个值必须从旧备份夹具删除"
        memory.speaker = "AI 承诺"
        memory.tokenCount = 9
        memory.sourceQuote = "虚构旧出处"
        memory.sourceNodeId = "fictional-old-node"
        memory.createdAt = time
        memory.updatedAt = time
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(FullMemoryDocument(model: memory))) as? [String: Any])
        object.removeValue(forKey: "subject")
        object.removeValue(forKey: "speaker")
        XCTAssertNil(object["subject"])
        XCTAssertNil(object["speaker"])
        let legacy = try decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.subject)
        XCTAssertNil(legacy.speaker)
        let expected = try encode(legacy)
        let firstURL = root.appendingPathComponent("old-backup-import.store")
        try autoreleasepool {
            let current = try container(at: firstURL, schema: Schema([Memory.self]))
            let context = ModelContext(current)
            context.autosaveEnabled = false
            let imported = legacy.toModel()
            XCTAssertEqual(imported.content, "嗯", "旧备份不扩写、不套新提取校验")
            XCTAssertNil(imported.subject)
            XCTAssertNil(imported.speaker)
            context.insert(imported)
            try context.save()
        }
        let reexported: Data = try autoreleasepool {
            let reopened = try container(at: firstURL, schema: Schema([Memory.self]))
            let context = ModelContext(reopened)
            let saved = try XCTUnwrap(context.fetch(FetchDescriptor<Memory>()).first)
            XCTAssertNil(saved.subject)
            XCTAssertNil(saved.speaker)
            XCTAssertEqual(saved.content, "嗯")
            return try encode(FullMemoryDocument(model: saved))
        }
        XCTAssertEqual(reexported, expected, "旧备份导入再导出的所有已有字段保持不变")
        let secondURL = root.appendingPathComponent("old-backup-restored.store")
        try autoreleasepool {
            let current = try container(at: secondURL, schema: Schema([Memory.self]))
            let context = ModelContext(current)
            context.autosaveEnabled = false
            context.insert(try decode(reexported).toModel())
            try context.save()
        }
        try autoreleasepool {
            let reopened = try container(at: secondURL, schema: Schema([Memory.self]))
            let context = ModelContext(reopened)
            let restored = try XCTUnwrap(context.fetch(FetchDescriptor<Memory>()).first)
            XCTAssertNil(restored.subject, "没有出处角色不应猜归因")
            XCTAssertNil(restored.speaker)
            XCTAssertEqual(restored.content, "嗯")
            XCTAssertEqual(try encode(FullMemoryDocument(model: restored)), expected)
        }
    }
}

/// 归因加入前的真实 Memory 存储结构：同名实体、原字段类型/默认值/唯一约束/索引完全保留。
/// 只用于制造旧磁盘库；不能用当前实体创建新库来替代迁移。
private enum PreAttributionMemorySchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Memory.self] }

    @Model
    final class Memory {
        #if os(iOS)
        #Index<Memory>(
            [\.profileId],
            [\.profileId, \.decayWeight],
            [\.profileId, \.updatedAt]
        )
        #endif

        @Attribute(.unique) var id: UUID = UUID()
        var content: String
        var category: String
        var keywords: [String]
        var tokenCount: Int
        var accessCount: Int = 0
        var lastAccessedAt: Date
        var decayWeight: Double = 1.0
        var validUntil: Date?
        var sourceConversationId: String?
        var extractedBy: String = ""
        var isUserExplicit: Bool = false
        var sourceQuote: String?
        var sourceNodeId: String?
        var supersededAt: Date?
        var feedbackDownCount: Int = 0
        var profileId: String
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var embeddingData: Data?
        var embeddingRevision: Int?
        var relatedIds: [UUID] = []
        var parentId: UUID?
        var occurredDay: String?
        var importance: Int?
        var emotion: Int?
        var resolved: Bool?
        var reviewedAt: Date?
        var userEditedAt: Date?
        var organizedAt: Date?
        var organizedPage: String?
        var organizeRejectedAt: Date?

        init(content: String, category: String, profileId: String) {
            self.content = content
            self.category = category
            self.keywords = []
            self.tokenCount = 1
            self.lastAccessedAt = Date()
            self.profileId = profileId
        }
    }
}
