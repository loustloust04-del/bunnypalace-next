import XCTest
import SwiftData
@testable import 记忆花园

/// #061 A 期：导入详情按撤回记录反查（内存库 + 合成数据）
@MainActor
final class ImportRecordDetailTests: XCTestCase {
    private let pid = "profile-dddddddd"

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
            ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func payload(_ id: String, title: String, folder: String? = nil, updated: Date = Date(),
                         extra: [ImportedNodePayload] = []) -> ImportedConversationPayload {
        var p = ImportedConversationPayload(
            id: id, title: title, createTime: updated, updateTime: updated, currentNodeId: extra.last?.id ?? "\(id)-a",
            provider: "claude",
            nodes: [
                ImportedNodePayload(id: "\(id)-u", role: "user", content: "问", contentType: "text", createTime: updated,
                                    parentId: nil, childrenIds: ["\(id)-a"]),
                ImportedNodePayload(id: "\(id)-a", role: "assistant", content: "答", contentType: "text", createTime: updated,
                                    parentId: "\(id)-u", childrenIds: extra.map(\.id)),
            ] + extra)
        p.folderId = folder
        return p
    }

    func testCreatedUpdatedFoldersMemories() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        // 本楼层原有一段，叠加导入会更新它
        let first = ImportRecord(fileName: "old", provider: "claude", profileId: pid)
        ctx.insert(first)
        let e0 = try PayloadImportEngine(context: ctx, profileId: pid, record: first, merge: false, copyConflicts: false)
        try e0.importBatch([payload("keep", title: "原有", updated: Date(timeIntervalSince1970: 100))])

        let tag = ConversationTag(name: "小说", profileId: pid)
        tag.instructions = "第一行说明\n第二行"
        ctx.insert(tag)
        let record = ImportRecord(fileName: "data.zip", provider: "claude", mode: .merge, profileId: pid)
        ctx.insert(record)
        ctx.insert(ImportConversationChange(recordId: record.id, conversationId: tag.id, changeKind: .createdFolder, profileId: pid))
        ctx.insert(ImportConversationChange(recordId: record.id, conversationId: "gone-folder", changeKind: .createdFolder, profileId: pid))

        let e = try PayloadImportEngine(context: ctx, profileId: pid, record: record, merge: true, copyConflicts: false)
        try e.importBatch([
            payload("n1", title: "新一", folder: tag.id, updated: Date(timeIntervalSince1970: 200)),
            payload("n2", title: "新二", folder: tag.id, updated: Date(timeIntervalSince1970: 300)),
            payload("n3", title: "新三"),
            payload("del", title: "会被删"),
        ])
        try e.importBatch([payload("keep", title: "原有（改）", updated: Date(timeIntervalSince1970: 400), extra: [
            ImportedNodePayload(id: "keep-x", role: "user", content: "补", contentType: "text",
                                createTime: Date(timeIntervalSince1970: 400), parentId: "keep-a", childrenIds: []),
        ])])

        // 记忆：一条没动、一条改过、一条删了
        let kept = Memory(content: "喜欢暖奶白", category: "偏好", profileId: pid)
        let edited = Memory(content: "改过的", category: "偏好", profileId: pid)
        ctx.insert(kept)
        ctx.insert(edited)
        for (id, text) in [(kept.id.uuidString, "喜欢暖奶白"), (edited.id.uuidString, "原文"), (UUID().uuidString, "删掉的")] {
            ctx.insert(ImportConversationChange(recordId: record.id, conversationId: id, changeKind: .createdMemory,
                                                beforeConversationData: Data(text.utf8), profileId: pid))
        }
        let del = try XCTUnwrap(ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == "del" })).first)
        ctx.delete(del)
        try ctx.save()

        let detail = try ImportRecordDetail.load(recordId: record.id, profileId: pid, context: ModelContext(container))
        XCTAssertEqual(detail.createdCount, 4)
        XCTAssertEqual(detail.updatedCount, 1)
        XCTAssertEqual(detail.missingConversations, 1, "导入后删掉的单独计数")
        XCTAssertEqual(detail.created.map(\.name), ["小说", "没在文件夹里"], "有名字的文件夹在前，没在文件夹里的最后")
        XCTAssertEqual(detail.created[0].items.map(\.title), ["新二", "新一"], "组内新的在前")
        XCTAssertEqual(detail.created[1].items.map(\.title), ["新三"])
        XCTAssertEqual(detail.updated.flatMap { $0.items.map(\.title) }, ["原有（改）"])
        XCTAssertEqual(detail.updated[0].items[0].messageCount, 3)
        XCTAssertEqual(detail.folders.map(\.name), ["小说", "（已删除）"])
        XCTAssertEqual(detail.folders[0].note, "第一行说明")
        XCTAssertEqual(detail.memories.map(\.state), [.unchanged, .edited, .deleted])
        XCTAssertEqual(detail.memories[2].content, "删掉的", "删了的显示导入时的原文")
    }

    func testOtherRecordAndFloorNotMixedIn() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let a = ImportRecord(fileName: "a", provider: "chatgpt", profileId: pid)
        let b = ImportRecord(fileName: "b", provider: "chatgpt", profileId: pid)
        ctx.insert(a)
        ctx.insert(b)
        try PayloadImportEngine(context: ctx, profileId: pid, record: a, merge: false, copyConflicts: false)
            .importBatch([payload("a1", title: "甲")])
        try PayloadImportEngine(context: ctx, profileId: pid, record: b, merge: false, copyConflicts: false)
            .importBatch([payload("b1", title: "乙")])

        let detail = try ImportRecordDetail.load(recordId: a.id, profileId: pid, context: ModelContext(container))
        XCTAssertEqual(detail.created.flatMap { $0.items.map(\.id) }, ["a1"])
        let other = try ImportRecordDetail.load(recordId: a.id, profileId: "profile-other", context: ModelContext(container))
        XCTAssertEqual(other.createdCount, 0, "别的楼层查不到这条记录的东西")
    }
}

/// #061 冲突：预览先查（按楼层 / 回收站 / 本楼层已有副本）+ 写库按楼层计数
@MainActor
final class ImportConflictTests: XCTestCase {
    private let here = "profile-hhhhhhhh"

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
            ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func payload(_ id: String, nodePrefix: String? = nil) -> ImportedConversationPayload {
        let n = nodePrefix ?? id
        let t = Date(timeIntervalSince1970: 1_000)   // 固定时间：同一段再导一次不会因为时间变新被当成改过
        return ImportedConversationPayload(
            id: id, title: id, createTime: t, updateTime: t, currentNodeId: "\(n)-a", provider: "claude",
            nodes: [
                ImportedNodePayload(id: "\(n)-u", role: "user", content: "问", contentType: "text", createTime: t,
                                    parentId: nil, childrenIds: ["\(n)-a"]),
                ImportedNodePayload(id: "\(n)-a", role: "assistant", content: "答", contentType: "text", createTime: t,
                                    parentId: "\(n)-u", childrenIds: []),
            ])
    }

    /// 往某楼层直接导几段（造「已在别的楼层」）
    private func seed(_ ctx: ModelContext, _ profileId: String, _ payloads: [ImportedConversationPayload],
                      copy: Bool = false) throws {
        let record = ImportRecord(fileName: "seed", provider: "claude", profileId: profileId)
        ctx.insert(record)
        try PayloadImportEngine(context: ctx, profileId: profileId, record: record, merge: false, copyConflicts: copy)
            .importBatch(payloads)
    }

    func testProbeGroupsByFloorTrashAndCopies() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        try seed(ctx, "profile-ko", [payload("a"), payload("b"), payload("c")])
        try seed(ctx, "profile-mic", [payload("d")])
        try seed(ctx, "profile-gone", [payload("e"), payload("f")])
        let b = try XCTUnwrap(ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == "b" })).first)
        b.isTrashed = true
        try seed(ctx, here, [payload("a")], copy: true)   // 本楼层已有 a 的副本
        try ctx.save()

        let report = try ImportConflictProbe.probe(ids: ["a", "b", "c", "d", "e", "f", "new", "a"], currentProfileId: here,
                                                   context: ModelContext(container))
        XCTAssertEqual(report.total, 6)
        XCTAssertEqual(report.floors.map(\.profileId), ["profile-ko", "profile-gone", "profile-mic"])
        XCTAssertEqual(report.floors[0].count, 3)
        XCTAssertEqual(report.floors[0].trashed, 1)
        XCTAssertEqual(report.copiedHere, 1)

        let merged = ImportConflictReport.merged([report, ImportConflictReport(floors: [.init(profileId: "profile-mic", count: 2)])])
        XCTAssertEqual(merged.floors.first { $0.profileId == "profile-mic" }?.count, 3)
        XCTAssertEqual(merged.total, 8)
    }

    func testEngineCountsConflictsByFloorIncludingNodeHits() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        try seed(ctx, "profile-ko", [payload("a"), payload("b")])
        let b = try XCTUnwrap(ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == "b" })).first)
        b.isTrashed = true
        try ctx.save()

        let record = ImportRecord(fileName: "t", provider: "claude", profileId: here)
        ctx.insert(record)
        let e = try PayloadImportEngine(context: ctx, profileId: here, record: record, merge: false, copyConflicts: false)
        // x 的对话 id 不撞，但节点 id 跟 a 的撞：预览算不到，写库照样挡，算在 a 所在的楼层
        try e.importBatch([payload("a"), payload("b"), payload("x", nodePrefix: "a"), payload("fresh"), nil])
        XCTAssertEqual(e.counts.conflicts, 3)
        XCTAssertEqual(e.counts.conflictsByProfile, ["profile-ko": 3])
        XCTAssertEqual(e.counts.conflictsTrashed, 1)
        XCTAssertEqual(e.counts.added, 1)
        XCTAssertEqual(e.counts.ignored, 1, "冲突不再算在未导入里")
        XCTAssertEqual(record.conflictConversationCount, 3)
        XCTAssertEqual(record.ignoredConversationCount, 1)

        let probe = try ImportConflictProbe.probe(ids: ["a", "b", "x", "fresh"], currentProfileId: here, context: ctx)
        XCTAssertEqual(probe.total, 2, "预览只按对话 id 查")
    }

    func testSourceIdsMatchWrittenIds() throws {
        var preview = ImportPreview()
        preview.gemini.addCounts(of: GeminiImportResult(payloads: [payload("g1@gemini")]))
        preview.rikkaHub.conversationIds = [RikkaHubPayloadBuilder.conversationId("r1")]
        let scan = ExportPackageScan(stagingDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertEqual(ImportSources.gemini.conversationIds(scan, preview), ["g1@gemini"])
        XCTAssertEqual(ImportSources.rikkaHub.conversationIds(scan, preview), ["r1@\(RikkaHubPayloadBuilder.provider)"])
        XCTAssertEqual(ImportSources.aiStudio.conversationIds(scan, preview), [])
    }

    /// 叠加模式同一文件里重复出现、没变化的只记一次跳过；后面那份有新消息改判更新，从跳过里撤掉（sol #2）
    func testManifestSkipDedupAndSkipThenUpdate() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        try seed(ctx, here, [payload("k"), payload("j")])
        let record = ImportRecord(fileName: "t", provider: "claude", mode: .merge, profileId: here)
        ctx.insert(record)
        let e = try PayloadImportEngine(context: ctx, profileId: here, record: record, merge: true, copyConflicts: false)
        e.beginSource("f")
        var grown = payload("k")
        grown = ImportedConversationPayload(
            id: "k", title: "k", createTime: grown.createTime, updateTime: grown.updateTime.addingTimeInterval(60),
            currentNodeId: "k-x", provider: "claude",
            nodes: grown.nodes + [ImportedNodePayload(id: "k-x", role: "user", content: "新", contentType: "text",
                                                       createTime: Date(), parentId: "k-a", childrenIds: [])])
        try e.importBatch([payload("j"), payload("j"), payload("k"), payload("k"), grown])
        let s = try XCTUnwrap(e.sources.first)
        XCTAssertEqual(s.skipped.map(\.id), ["j"])
        XCTAssertEqual(s.skippedCount, 1)
        XCTAssertEqual(s.updated, ["k"])
        XCTAssertEqual(e.counts.skipped, 1)
        XCTAssertEqual(e.counts.updated, 1)
    }

    func testManifestConflictCarriesFloorName() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        try seed(ctx, "profile-ko", [payload("a")])
        try seed(ctx, "profile-gone", [payload("b")])
        let record = ImportRecord(fileName: "t", provider: "claude", profileId: here)
        ctx.insert(record)
        let e = try PayloadImportEngine(context: ctx, profileId: here, record: record, merge: false, copyConflicts: false)
        e.floorNames = ["profile-ko": "ko"]
        e.beginSource("包 › conversations.json")
        try e.importBatch([payload("a"), payload("b"), payload("c"), nil])
        let s = try XCTUnwrap(e.sources.first)
        XCTAssertEqual(s.label, "包 › conversations.json")
        XCTAssertEqual(s.created, ["c"])
        XCTAssertEqual(s.emptyCount, 1)
        XCTAssertEqual(s.empty, ["第 4 段"], "空白段记在文件里的位置")
        XCTAssertEqual(s.conflictCount, 2)
        XCTAssertEqual(s.conflicts.map(\.floorName), ["ko", nil], "楼层已删的没有名字")
    }
}

/// #061 B 期：导入清单（按来源文件记去向）+ 全量备份带上新字段
@MainActor
final class ImportManifestTests: XCTestCase {
    private let pid = "profile-mmmmmmmm"
    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("import-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
            ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func libraryCreate(_ w: LibraryWrite) throws -> Bool {
        let url = work.appendingPathComponent("library").appendingPathComponent(w.relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try FileLibraryStore.createFileExclusively(at: url, data: Data(w.content.utf8))
    }

    private func run(_ scan: ExportPackageScan, _ container: ModelContainer,
                     selection: ImportSelection = ImportSelection()) -> ImportSummary {
        ImportRunner.run(scan: scan, preview: ImportPreview.make(scan), selection: selection, options: .init(),
                         profileId: pid, container: container, libraryCreate: libraryCreate, progress: { _, _ in })
    }

    private func manifests(_ container: ModelContainer) throws -> [ImportManifest] {
        try ModelContext(container).fetch(FetchDescriptor<ImportRecord>(sortBy: [SortDescriptor(\.importDate)]))
            .compactMap { ImportManifest.decode($0.detailData) }
    }

    func testClaudePackageManifestBySourceFile() throws {
        let container = try makeContainer()
        let scan = try ExportPackageScanner.scan([try ExportPackageScannerTests.fixtures().appendingPathComponent("gen-c")],
                                                 tempRoot: work)
        XCTAssertNil(run(scan, container).failure)
        let m = try XCTUnwrap(try manifests(container).first)
        XCTAssertEqual(m.packages, ["gen-c"])
        XCTAssertEqual(m.sources.map(\.kind), [.projects, .conversations, .designChats, .memories, .library])
        XCTAssertEqual(m.sources[0].label, "gen-c › projects-000/projects/p-c1.json")
        XCTAssertEqual(m.sources[0].foldersCreated.count, 2, "项目 + 设计项目")
        XCTAssertEqual(m.sources[1].label, "gen-c › conversations-000/conversations.json")
        XCTAssertEqual(m.sources[1].created, ["c1"])
        XCTAssertEqual(m.sources[2].label, "gen-c › design_chats-000/design_chats（1 个文件）")
        XCTAssertEqual(m.sources[2].created, ["d-c1"])
        XCTAssertEqual(m.sources[3].memoriesAdded, 3)
        let library = m.sources[4].library
        XCTAssertEqual(library.filter { $0.reason == nil }.count, 8)
        XCTAssertTrue(library.contains { $0.reason == "跳过" })
        XCTAssertTrue(m.notIncluded.contains { $0.hasPrefix("按设计不导：") })
        XCTAssertTrue(m.failures.isEmpty)

        _ = run(scan, container)
        let again = try XCTUnwrap(try manifests(container).last)
        XCTAssertEqual(again.sources[1].skipped.map(\.id), ["c1"], "再导一次：跳过的是哪段记下来")
        XCTAssertEqual(again.sources[0].foldersExisting.count, 2)
        XCTAssertTrue(again.sources[4].library.allSatisfy { $0.reason != nil }, "同名已有 / 跳过")
    }

    func testLibraryOnlyImportLeavesRecord() throws {
        let container = try makeContainer()
        let scan = try ExportPackageScanner.scan([try ExportPackageScannerTests.fixtures().appendingPathComponent("gen-c")],
                                                 tempRoot: work)
        var selection = ImportSelection()
        selection.claudeConversations = false
        selection.designChats = false
        selection.projects = false
        selection.memories = false
        _ = run(scan, container, selection: selection)
        let records = try ModelContext(container).fetch(FetchDescriptor<ImportRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].supportsUndo)
        let m = try XCTUnwrap(ImportManifest.decode(records[0].detailData))
        XCTAssertEqual(m.sources.map(\.kind), [.library])
        XCTAssertFalse(m.sources[0].library.isEmpty)
        let unchecked = try XCTUnwrap(m.notIncluded.first { $0.hasPrefix("这次没勾：") })
        for label in ["Claude 对话", "Claude 设计对话", "Claude 项目", "Claude 记忆"] {
            XCTAssertTrue(unchecked.contains(label), label)
        }
        XCTAssertFalse(unchecked.contains("Artifacts"), "勾了的不算")
    }

    func testFullBackupRoundTripKeepsNewFields() throws {
        let record = ImportRecord(fileName: "a.zip", provider: "claude", profileId: pid)
        record.conflictConversationCount = 7
        record.detailData = ImportManifest(packages: ["a.zip"]).encoded()
        // 覆盖检查：模型的每个字段备份文档里都有（整体检查会被别的模型的可选字段卡住，这里只查导入记录）
        XCTAssertEqual(Set(SchemaCoverageCheck.modelFieldNames(record)),
                       Set(SchemaCoverageCheck.documentFieldNames(sample: FullImportRecordDocument(model: record)))
                        .subtracting(["schemaVersion"]))
        let data = try JSONEncoder().encode(FullImportRecordDocument(model: record))
        let back = try JSONDecoder().decode(FullImportRecordDocument.self, from: data).toModel()
        XCTAssertEqual(back.conflictConversationCount, 7)
        XCTAssertEqual(ImportManifest.decode(back.detailData)?.packages, ["a.zip"])

        // 旧备份没有这两个键
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "conflictConversationCount")
        json.removeValue(forKey: "detailData")
        let old = try JSONDecoder().decode(FullImportRecordDocument.self,
                                           from: try JSONSerialization.data(withJSONObject: json)).toModel()
        XCTAssertEqual(old.conflictConversationCount, 0)
        XCTAssertNil(old.detailData)
    }
}
