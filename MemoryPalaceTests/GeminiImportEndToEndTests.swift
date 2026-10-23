import XCTest
import SwiftData
@testable import 记忆花园

/// #047：Gemini / AI Studio 走 #043 导入流程写内存库——普通 / 再导 / 叠加补轮次 / 撤回 / 图片先外置。合成样本，不是真包。
@MainActor
final class GeminiImportEndToEndTests: XCTestCase {

    private var container: ModelContainer!
    private var work: URL!
    private let pid = "profile-gemini-e2e"

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
            ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gemini-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - 入口

    /// 整条导入流程：扫描 → 预览 → ImportRunner.run（不含图片，不会碰真文件库）
    private func runAll(_ files: [String: Data], merge: Bool = false) throws -> ImportSummary {
        let dir = work.appendingPathComponent(UUID().uuidString)
        for (rel, data) in files {
            let url = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let scan = try ExportPackageScanner.scan([dir], tempRoot: work)
        defer { scan.cleanup() }
        return ImportRunner.run(scan: scan, preview: ImportPreview.make(scan), selection: ImportSelection(),
                                options: .init(merge: merge, sourceName: "takeout.zip"), profileId: pid, container: container,
                                libraryCreate: { _ in XCTFail("Gemini 不写文件库"); return false }, progress: { _, _ in })
    }

    private let activityPath = "Takeout/My Activity/Gemini Apps/MyActivity.json"

    private func takeout(_ records: [[String: Any]]) throws -> Data {
        try GeminiImportScanTests.takeoutJSON(records)
    }

    // MARK: - 查询

    private func ctx() -> ModelContext { ModelContext(container) }

    private func conversations() throws -> [Conversation] {
        let p = pid
        return try ctx().fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == p })).sorted { $0.id < $1.id }
    }

    private func nodes(_ conversationId: String) throws -> [MessageNode] {
        let p = pid
        return try ctx().fetch(FetchDescriptor<MessageNode>(predicate: #Predicate {
            $0.conversationId == conversationId && $0.profileId == p
        }))
    }

    private func records() throws -> [ImportRecord] {
        let p = pid
        return try ctx().fetch(FetchDescriptor<ImportRecord>(predicate: #Predicate { $0.profileId == p }))
    }

    /// 照 ImportHistoryView.undoImport 的做法撤回一次导入
    private func undo(_ recordId: UUID) throws {
        let c = ctx()
        let p = pid
        let changes = try c.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate {
            $0.recordId == recordId && $0.profileId == p
        }))
        for change in changes { try restoreConversationChange(change, in: c) }
        for change in changes { c.delete(change) }
        if let r = try c.fetch(FetchDescriptor<ImportRecord>(predicate: #Predicate { $0.id == recordId })).first { c.delete(r) }
        try c.save()
    }

    // MARK: - 用例

    func testImportsBothSourcesWithOwnRecords() throws {
        let s = try runAll([
            activityPath: try takeout(GeminiImportScanTests.geminiRecords),
            "Takeout/Drive/Google AI Studio/Trip plan": try GeminiImportScanTests.aiStudioFile(),
        ])
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.conversations.added, 3)
        let convs = try conversations()
        XCTAssertEqual(convs.filter { $0.provider == "gemini" }.count, 2)
        XCTAssertEqual(convs.filter { $0.provider == "aistudio" }.map(\.title), ["Trip plan"])
        XCTAssertTrue(convs.allSatisfy { Conversation.importedProviders.contains($0.provider) })
        let linked = try XCTUnwrap(convs.first { $0.id == "c1@gemini" })
        XCTAssertEqual(try nodes(linked.id).count, 4)
        XCTAssertEqual(linked.nodeCount, 4)

        let recs = try records()
        XCTAssertEqual(Set(recs.map(\.provider)), ["gemini", "aistudio"])
        XCTAssertTrue(recs.allSatisfy(\.supportsUndo))
        XCTAssertEqual(recs.first { $0.provider == "gemini" }?.addedConversationCount, 2)
        XCTAssertTrue(s.notes.contains("1 段对话是按时间间隔推测切分的，不是 Gemini 原来的会话"), "\(s.notes)")
    }

    func testReimportSkipsThenMergeAddsTurns() throws {
        _ = try runAll([activityPath: try takeout(GeminiImportScanTests.geminiRecords)])
        let newer = GeminiImportScanTests.geminiRecords
            + [GeminiImportScanTests.activity("第三句", time: "2026-01-04T08:00:00Z", answer: "三三", chat: "c1")]

        let again = try runAll([activityPath: try takeout(newer)])
        XCTAssertEqual(again.conversations.skipped, 2, "普通导入：本地已有的整段跳过，新问答进不来")
        XCTAssertEqual(again.conversations.added, 0)
        XCTAssertEqual(try nodes("c1@gemini").count, 4)

        let merged = try runAll([activityPath: try takeout(newer)], merge: true)
        XCTAssertEqual(merged.conversations.updated, 1)
        XCTAssertEqual(merged.conversations.skipped, 1)
        XCTAssertEqual(try nodes("c1@gemini").count, 6)
        let c1 = try XCTUnwrap(try conversations().first { $0.id == "c1@gemini" })
        XCTAssertEqual(c1.nodeCount, 6)

        let mergeRecord = try XCTUnwrap(try records().first { $0.mode == .merge })
        try undo(mergeRecord.id)
        XCTAssertEqual(try nodes("c1@gemini").count, 4, "撤回叠加导入回到导入前")
    }

    func testUndoRemovesImportedConversations() throws {
        _ = try runAll([activityPath: try takeout(GeminiImportScanTests.geminiRecords)])
        let record = try XCTUnwrap(try records().first)
        try undo(record.id)
        XCTAssertTrue(try conversations().isEmpty)
        XCTAssertTrue(try nodes("c1@gemini").isEmpty)
    }

    /// #050：内嵌图交给引擎转存（externalizeOnWrite），只对真写入的对话落盘；文件库根换到临时目录验真文件
    func testInlineImagesExternalizedByEngine() throws {
        let library = work.appendingPathComponent("library")
        FileLibraryStore.testRootOverride = library
        defer { FileLibraryStore.testRootOverride = nil }
        MainThreadIO.allowMainThreadInThisTest()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        let file = try JSONSerialization.data(withJSONObject: ["chunkedPrompt": ["chunks": [
            ["role": "user", "text": "画只猫", "createTime": "2025-06-15T10:30:00Z"],
            ["role": "model", "inlineImage": ["mimeType": "image/png", "data": png.base64EncodedString()]],
        ]]])
        let parsed = try AIStudioParser.parse(data: file, fileName: "猫")
        func importOnce() throws -> ImportCounts {
            let c = ctx()
            c.autosaveEnabled = false
            let record = ImportRecord(fileName: "猫", provider: "aistudio", mode: .normal, profileId: pid)
            c.insert(record)
            let engine = try PayloadImportEngine(context: c, profileId: pid, record: record, merge: false, copyConflicts: false)
            try ImportRunner.importGeminiPayloads(parsed.payloads, engine: engine)
            return engine.counts
        }
        XCTAssertEqual(try importOnce().added, 1)

        let stored = try XCTUnwrap(try nodes(parsed.payloads[0].id).first { $0.role == "assistant" })
        let segments = try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(stored.segmentsData))
        guard case .imageRef(let name, let type, let path) = segments.first, segments.count == 1 else {
            return XCTFail("应换成文件库里的图：\(segments)")
        }
        XCTAssertEqual(name, "image-1.png")
        XCTAssertEqual(type, "image/png")
        let root = library.appendingPathComponent(pid)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), png)

        let attachments = root.appendingPathComponent(AttachmentStore.folderName)
        try FileManager.default.removeItem(at: attachments)
        XCTAssertEqual(try importOnce().skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.path), "跳过的对话不再落盘")
    }
}
