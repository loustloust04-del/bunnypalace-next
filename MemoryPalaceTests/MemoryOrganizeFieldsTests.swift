import XCTest
import SwiftData
@testable import 记忆花园

/// C3 整理编目（plan-memory-c3-catalog 2.2）：Memory 三个可选字段 + 便利 + 全局备份镜像
final class MemoryOrganizeFieldsTests: XCTestCase {

    private let pid = "xctest-organize-fields"

    func testDefaultsAndConvenience() {
        let m = Memory(content: "x", category: "fact", profileId: pid)
        XCTAssertNil(m.organizedAt)
        XCTAssertNil(m.organizedPage)
        XCTAssertNil(m.organizeRejectedAt)
        XCTAssertFalse(m.isOrganized)
        XCTAssertFalse(m.isSingleEnough)

        m.organizedAt = Date()
        XCTAssertTrue(m.isOrganized)
        XCTAssertTrue(m.isSingleEnough, "整理过、没页 = 单条就够")
        m.organizedPage = "人/小慧"
        XCTAssertTrue(m.isOrganized)
        XCTAssertFalse(m.isSingleEnough)
        XCTAssertEqual(MemoryAudit.state(of: m), .unreviewed, "不新增审计三态")
    }

    @MainActor
    func testPersists() throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let ctx = ModelContext(container)
        let m = Memory(content: "x", category: "fact", profileId: pid)
        m.organizedAt = t
        m.organizedPage = "工程/项目/记忆宫殿"
        m.organizeRejectedAt = t.addingTimeInterval(5)
        ctx.insert(m)
        try ctx.save()

        let other = ModelContext(container)
        let back = try XCTUnwrap(SwiftDataMemoryStore().listAll(profileId: pid, context: other).first)
        XCTAssertEqual(back.organizedAt, t)
        XCTAssertEqual(back.organizedPage, "工程/项目/记忆宫殿")
        XCTAssertEqual(back.organizeRejectedAt, t.addingTimeInterval(5))
    }

    func testBackupRoundTrip() throws {
        let full = Memory(content: "x", category: "fact", profileId: pid, sourceConversationId: "c")
        let d = Date()
        full.validUntil = d; full.sourceQuote = "q"; full.sourceNodeId = "n"; full.supersededAt = d
        full.embeddingData = Data([1]); full.embeddingRevision = 1; full.parentId = UUID()
        full.occurredDay = "2026-10-12"; full.importance = 3; full.emotion = 0; full.resolved = false
        full.reviewedAt = d; full.userEditedAt = d
        full.organizedAt = d; full.organizedPage = "主题/x"; full.organizeRejectedAt = d
        full.subject = "虚构工程"; full.speaker = "用户自述"
        XCTAssertNoThrow(try SchemaCoverageCheck.compareFields(modelName: "Memory",
                                                               // feedbackDownCount 备份文档本来就没带（不是这一刀的）
                                                               modelFields: SchemaCoverageCheck.modelFieldNames(full).filter { $0 != "feedbackDownCount" },
                                                               docFields: SchemaCoverageCheck.documentFieldNames(sample: FullMemoryDocument(model: full))),
                         "Memory 每个字段备份文档都有")
        let m = Memory(content: "x", category: "fact", profileId: pid)
        let fields: Set<String> = ["organizedAt", "organizedPage", "organizeRejectedAt"]

        let t1 = Date(timeIntervalSince1970: 1_800_000_000), t2 = Date(timeIntervalSince1970: 1_800_000_100)
        m.organizedAt = t1
        m.organizedPage = "主题/身体"
        m.organizeRejectedAt = t2
        let doc = FullMemoryDocument(model: m)
        let back = try JSONDecoder().decode(FullMemoryDocument.self, from: JSONEncoder().encode(doc)).toModel()
        XCTAssertEqual(back.organizedAt, t1)
        XCTAssertEqual(back.organizedPage, "主题/身体")
        XCTAssertEqual(back.organizeRejectedAt, t2)

        let data = try JSONEncoder().encode(FullMemoryDocument(model: Memory(content: "y", category: "fact", profileId: pid)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for f in fields { json[f] = nil }
        let old = try JSONDecoder().decode(FullMemoryDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.organizedAt, "老备份没这个键 = nil")
        XCTAssertNil(old.organizedPage)
        XCTAssertNil(old.organizeRejectedAt)
    }
}
