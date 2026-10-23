import CryptoKit
import XCTest
import SwiftData
@testable import 记忆花园

/// #049 B 段：Kelivo 两代备份走导入流程写内存库——扫描（settings.json 不读不拷）→ 预览 → 导入 / 再导跳过 / 叠加补消息 / 撤回 /
/// 包里的图片落文件库。合成样本（结构依据 docs/research-import-kelivo-format.md）。
@MainActor
final class KelivoImportEndToEndTests: XCTestCase {

    private var container: ModelContainer!
    private var work: URL!
    private var library: URL!
    private let pid = "profile-kelivo-e2e"
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
    /// 两代 settings.json 都带凭证；故意带个 `assistants` 数组，看会不会被当成 RikkaHub 的设置读
    private let settings = Data(#"{"assistants":[{"id":"a1","name":"小克"}],"provider_configs_v1":"{\"openai\":{\"apiKey\":\"sk-FAKE\"}}"}"#.utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
            ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kelivo-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        library = work.appendingPathComponent("library")
        FileLibraryStore.testRootOverride = library
        MainThreadIO.allowMainThreadInThisTest()
    }

    override func tearDownWithError() throws {
        FileLibraryStore.testRootOverride = nil
        MainThreadIO.allowMainThreadInThisTest(false)
        if let work { try? FileManager.default.removeItem(at: work) }
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - 样本

    /// 旧版：一段对话，用户发图（导出设备上的绝对路径）、AI 回答重新生成过一次、选中第 2 版
    private func legacyChats(extraTurn: Bool = false, selected: Int = 1) throws -> Data {
        var ids = ["u1", "a1", "a1b"]
        var messages: [[String: Any]] = [
            ["id": "u1", "role": "user", "conversationId": "c1", "timestamp": "2025-03-01T10:00:00.000", "version": 0,
             "content": "看这只猫\n[image:/Users/x/Library/Application Support/com.psyche.kelivo/upload/cat.png]"],
            ["id": "a1", "role": "assistant", "conversationId": "c1", "timestamp": "2025-03-01T10:00:05.000",
             "groupId": "a1", "version": 0, "content": "第一版"],
            ["id": "a1b", "role": "assistant", "conversationId": "c1", "timestamp": "2025-03-01T10:01:00.000",
             "groupId": "a1", "version": 1, "content": "第二版"],
        ]
        if extraTurn {
            ids += ["u2", "a2"]
            messages += [
                ["id": "u2", "role": "user", "conversationId": "c1", "timestamp": "2025-03-02T09:00:00.000", "version": 0, "content": "再说说"],
                ["id": "a2", "role": "assistant", "conversationId": "c1", "timestamp": "2025-03-02T09:00:03.000", "version": 0, "content": "好"],
            ]
        }
        let conversation: [String: Any] = [
            "id": "c1", "title": "猫", "createdAt": "2025-03-01T10:00:00.000Z", "updatedAt": "2025-03-02T09:00:03.000Z",
            "messageIds": ids, "versionSelections": ["a1": selected]]
        return try JSONSerialization.data(withJSONObject: [
            "version": 1, "conversations": [conversation], "messages": messages, "toolEvents": [:], "geminiThoughtSigs": [:]])
    }

    private func legacyFiles(extraTurn: Bool = false, selected: Int = 1) throws -> [String: Data] {
        ["settings.json": settings, "chats.json": try legacyChats(extraTurn: extraTurn, selected: selected), "upload/cat.png": png,
         "avatars/me.png": png, "fonts/x.ttf": Data("font".utf8)]
    }

    /// 新版：最小 schema 3 库，一段对话，用户发图（kelivo-file URI）+ AI 回答
    private func modernDatabase() throws -> Data {
        let url = work.appendingPathComponent("build-\(UUID().uuidString).db")
        do {
            let db = try SQLiteDB(url: url)
            try db.exec("CREATE TABLE conversation_rows (id TEXT PRIMARY KEY, title TEXT, created_at INTEGER, updated_at INTEGER, version_selections_json TEXT)")
            try db.exec("CREATE TABLE message_rows (id TEXT PRIMARY KEY, conversation_id TEXT, role TEXT, timestamp INTEGER, group_id TEXT, version INTEGER, message_order INTEGER)")
            try db.exec("CREATE TABLE message_part_rows (part_id INTEGER PRIMARY KEY, conversation_id TEXT, revision_id TEXT, ordinal INTEGER, kind TEXT, payload TEXT)")
            try db.exec("CREATE TABLE provider_rows (id TEXT PRIMARY KEY, payload TEXT)")
            try db.exec(#"INSERT INTO provider_rows VALUES ('p1', '{"apiKey":"sk-FAKE"}')"#)
            try db.exec("PRAGMA user_version = 3")
            let t0: Int64 = 1_740_823_200_000_000
            try db.exec("INSERT INTO conversation_rows VALUES ('k1', '新对话', \(t0), \(t0 + 60_000_000), NULL)")
            try db.exec("INSERT INTO message_rows VALUES ('m1', 'k1', 'user', \(t0), NULL, 0, 0)")
            try db.exec("INSERT INTO message_rows VALUES ('m2', 'k1', 'assistant', \(t0 + 5_000_000), NULL, 0, 1)")
            try db.exec("INSERT INTO message_part_rows (conversation_id, revision_id, ordinal, kind, payload) VALUES ('k1', 'm1', 0, 'text', '看图')")
            try db.exec(#"INSERT INTO message_part_rows (conversation_id, revision_id, ordinal, kind, payload) VALUES ('k1', 'm1', 1, 'image', '{"uri":"kelivo-file:///images/my%20cat.png","mime":"image/png"}')"#)
            try db.exec("INSERT INTO message_part_rows (conversation_id, revision_id, ordinal, kind, payload) VALUES ('k1', 'm2', 0, 'text', '是猫')")
        }
        return try Data(contentsOf: url)
    }

    private func manifest(db: Data, sha: String? = nil, payloadKind: String = "sqlite") throws -> Data {
        let hash = sha ?? SHA256.hash(data: db).map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: [
            "format": "kelivo-backup", "formatVersion": 3, "minimumReadableFormatVersion": 3, "payloadKind": payloadKind,
            "appVersion": "1.3.1+80", "includeChats": payloadKind != "settings-only", "includeFiles": true, "secretsIncluded": true,
            "database": ["entry": "database/kelivo.db", "schemaVersion": 3, "conversationCount": 1],
            "entries": ["database/kelivo.db": ["bytes": db.count, "sha256": hash]],
        ] as [String: Any])
    }

    private func modernFiles(sha: String? = nil) throws -> [String: Data] {
        let db = try modernDatabase()
        return ["settings.json": settings, "database/kelivo.db": db, "images/my cat.png": png, "upload/notes.zip": Data("不是真 zip".utf8),
                "skills/s/SKILL.md": Data("x".utf8), "manifest.json": try manifest(db: db, sha: sha)]
    }

    // MARK: - 入口

    private func write(_ files: [String: Data], folder: String) throws -> URL {
        let dir = work.appendingPathComponent("src-\(UUID().uuidString)").appendingPathComponent(folder)
        for (rel, data) in files {
            let url = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return dir
    }

    private func zip(_ files: [String: Data], name: String) throws -> URL {
        let dir = work.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try GPT.zip(files, to: url)
        return url
    }

    private func scan(_ url: URL) throws -> ExportPackageScan {
        try ExportPackageScanner.scan([url], tempRoot: work)
    }

    private func run(_ scan: ExportPackageScan, merge: Bool = false) -> ImportSummary {
        ImportRunner.run(scan: scan, preview: ImportPreview.make(scan), selection: ImportSelection(),
                         options: .init(merge: merge, sourceName: "kelivo_backup.zip"), profileId: pid, container: container,
                         libraryCreate: { _ in XCTFail("Kelivo 不写文件库条目"); return false }, progress: { _, _ in })
    }

    private func runAll(_ url: URL, merge: Bool = false) throws -> ImportSummary {
        let s = try scan(url)
        defer { s.cleanup() }
        return run(s, merge: merge)
    }

    // MARK: - 查询

    private func ctx() -> ModelContext { ModelContext(container) }

    private func conversations() throws -> [Conversation] {
        let p = pid
        return try ctx().fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == p }))
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

    private func segments(_ node: MessageNode) throws -> [MessageSegment] {
        try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(node.segmentsData))
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

    private func stagedFiles(_ scan: ExportPackageScan) -> [URL] {
        let e = FileManager.default.enumerator(at: scan.stagingDir, includingPropertiesForKeys: nil)
        return ((e?.allObjects as? [URL]) ?? []).filter { !$0.hasDirectoryPath }
    }

    /// 包里的图换成文件库里的真文件
    private func assertImageStored(_ node: MessageNode, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let refs = try segments(node).compactMap { seg -> String? in
            if case .imageRef(let n, _, let path) = seg, n == name { return path }
            return nil
        }
        let all = try segments(node)
        let path = try XCTUnwrap(refs.first, "应换成文件库里的图：\(all)", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent(pid).appendingPathComponent(path)), png, file: file, line: line)
    }

    // MARK: - 用例

    func testLegacyZipImportsWithImageAndNeverReadsSettings() throws {
        let s = try scan(try zip(try legacyFiles(), name: "kelivo_backup_old.zip"))
        defer { s.cleanup() }
        XCTAssertEqual(s.kelivoPackages.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(s.kelivoPackages.first).assets.keys), ["upload/cat.png"])
        XCTAssertTrue(s.rikkaHubPackages.isEmpty && s.rikkaHubSettingsOnly.isEmpty, "settings.json 不该被当成 RikkaHub 的")
        XCTAssertTrue(s.unrecognized.isEmpty, "\(s.unrecognized)")
        XCTAssertTrue(s.ignoredLabels.contains(KelivoArchive.settingsLabel), "\(s.ignoredLabels)")
        for file in stagedFiles(s) {
            XCTAssertNotEqual(file.lastPathComponent, "settings.json")
            XCTAssertNil(try Data(contentsOf: file).range(of: Data("sk-FAKE".utf8)), file.lastPathComponent)
        }

        let preview = ImportPreview.make(s)
        XCTAssertEqual(preview.kelivo, KelivoPreview(conversations: 1, legacyPackages: 1, regenerated: 1, attachments: 1,
                                                     conversationIds: ["c1@kelivo"]))
        XCTAssertEqual(ImportSources.kelivo.conversationIds(s, preview), ["c1@kelivo"], "预览查跨楼层冲突用（#061）")
        let row = try XCTUnwrap(ImportSources.kelivo.shownRows(s, preview).first)
        XCTAssertEqual(row.detail, "1 段 · 旧版备份，含 1 处重新生成，所有版本都保留 → 本楼层；附件 1 个 → 文件库")

        let summary = run(s)
        XCTAssertNil(summary.failure)
        XCTAssertEqual(summary.conversations.added, 1)
        let conv = try XCTUnwrap(try conversations().first)
        XCTAssertEqual(conv.id, "c1@kelivo")
        XCTAssertEqual(conv.provider, "kelivo")
        XCTAssertTrue(Conversation.importedProviders.contains(conv.provider))
        XCTAssertEqual(Conversation.importedProviderName(conv.provider), "Kelivo")
        let all = try nodes(conv.id)
        XCTAssertEqual(all.count, 4, "两个版本都在（含合成根）")
        try assertImageStored(try XCTUnwrap(all.first { $0.id == "c1@kelivo/u1" }), name: "cat.png")

        let record = try XCTUnwrap(try records().first)
        XCTAssertEqual(record.provider, "kelivo")
        XCTAssertTrue(record.supportsUndo)
        XCTAssertTrue(summary.notes.contains("Kelivo：3 个时间没带时区，按本机时区算"), "\(summary.notes)")
    }

    func testReimportSkipsThenMergeAddsTurnsAndUndo() throws {
        _ = try runAll(try write(try legacyFiles(), folder: "kelivo_backup"))
        XCTAssertEqual(try nodes("c1@kelivo").count, 4, "含合成根")

        let newer = try write(try legacyFiles(extraTurn: true), folder: "kelivo_backup")
        let again = try runAll(newer)
        XCTAssertEqual(again.conversations.skipped, 1)
        XCTAssertEqual(again.conversations.added, 0)
        XCTAssertEqual(try nodes("c1@kelivo").count, 4)

        let merged = try runAll(newer, merge: true)
        XCTAssertEqual(merged.conversations.updated, 1)
        XCTAssertEqual(try nodes("c1@kelivo").count, 6)
        XCTAssertEqual(try XCTUnwrap(try conversations().first).nodeCount, 4, "只数当前分支，重新生成的旁支不算")

        let same = try runAll(newer, merge: true)
        XCTAssertEqual(same.conversations.updated, 0, "同一份再叠加不该算「更新」")

        let mergeRecord = try XCTUnwrap(try records().first { $0.mode == .merge && $0.updatedConversationCount > 0 })
        try undo(mergeRecord.id)
        XCTAssertEqual(try nodes("c1@kelivo").count, 4, "撤回叠加导入回到导入前")
        let first = try XCTUnwrap(try records().first { $0.mode == .normal && $0.addedConversationCount > 0 })
        try undo(first.id)
        XCTAssertTrue(try conversations().isEmpty)
    }

    func testModernFolderImportsAndSettingsNeverStaged() throws {
        let s = try scan(try write(try modernFiles(), folder: "kelivo_backup_new"))
        defer { s.cleanup() }
        XCTAssertEqual(s.kelivoPackages.count, 1)
        XCTAssertTrue(s.manifestFiles.isEmpty, "Kelivo 清单不当 Claude 的")
        XCTAssertTrue(s.rikkaHubSettingsOnly.isEmpty && s.unrecognized.isEmpty, "\(s.unrecognized)")
        XCTAssertFalse(stagedFiles(s).contains { $0.lastPathComponent == "settings.json" })
        XCTAssertNotNil(s.kelivoPackages.first?.assets["upload/notes.zip"], "附件目录里的 zip 原样收，不展开（sol #8）")
        XCTAssertEqual(ImportPreview.make(s).kelivo, KelivoPreview(conversations: 1, modernPackages: 1, attachments: 1,
                                                                   conversationIds: ["k1@kelivo"]))

        let summary = run(s)
        XCTAssertNil(summary.failure)
        XCTAssertEqual(summary.conversations.added, 1)
        let user = try XCTUnwrap(try nodes("k1@kelivo").first { $0.role == "user" })
        try assertImageStored(user, name: "my cat.png")
    }

    func testSettingsOnlyAndMismatchedDatabaseAreExplained() throws {
        let db = try modernDatabase()
        let settingsOnly = try scan(try zip(["settings.json": settings, "manifest.json": try manifest(db: db, payloadKind: "settings-only")],
                                            name: "only-settings.zip"))
        defer { settingsOnly.cleanup() }
        XCTAssertTrue(settingsOnly.isEmpty)
        XCTAssertEqual(settingsOnly.kelivoSettingsOnly, ["only-settings.zip"])
        XCTAssertTrue(settingsOnly.rikkaHubSettingsOnly.isEmpty && settingsOnly.unrecognized.isEmpty)

        let broken = try scan(try zip(try modernFiles(sha: String(repeating: "0", count: 64)), name: "broken.zip"))
        defer { broken.cleanup() }
        let preview = ImportPreview.make(broken)
        XCTAssertEqual(preview.kelivo.conversations, 0)
        XCTAssertEqual(preview.kelivo.failures.count, 1)
        XCTAssertTrue(preview.notes.contains { $0.hasPrefix("Kelivo 备份读不了：broken.zip：") }, "\(preview.notes)")
        XCTAssertTrue(ImportSources.kelivo.shownRows(broken, preview).isEmpty)
    }

    /// Kelivo 里换了选中的版本、后面的对话不变：叠加导入跟着换选择表（sol #6）
    func testMergeFollowsChangedSelection() throws {
        _ = try runAll(try write(try legacyFiles(extraTurn: true, selected: 1), folder: "kelivo_backup"))
        func selection() throws -> [String: String] {
            BranchSelection.decode(try XCTUnwrap(try conversations().first).branchSelectionData)
        }
        XCTAssertEqual(try selection(), ["c1@kelivo/u1": "c1@kelivo/a1b"])
        let merged = try runAll(try write(try legacyFiles(extraTurn: true, selected: 0), folder: "kelivo_backup"), merge: true)
        XCTAssertEqual(merged.conversations.updated, 1)
        XCTAssertEqual(try selection(), ["c1@kelivo/u1": "c1@kelivo/a1"])
    }

    /// 一次选了两份不同时间的备份（同一段对话都在）：按包先后导，第二份里的同一段按「已有」处理
    func testTwoBackupsPickedTogether() throws {
        let older = try write(try legacyFiles(), folder: "kelivo_backup_1")
        let newer = try zip(try legacyFiles(extraTurn: true), name: "kelivo_backup_2.zip")
        let s = try ExportPackageScanner.scan([older, newer], tempRoot: work)
        defer { s.cleanup() }
        XCTAssertEqual(s.kelivoPackages.count, 2)
        XCTAssertEqual(ImportPreview.make(s).kelivo.conversations, 2, "预览按包数，不去重")
        let summary = run(s, merge: true)
        XCTAssertNil(summary.failure)
        XCTAssertEqual(summary.conversations.added, 1)
        XCTAssertEqual(summary.conversations.updated, 0, "同一次导入里先新增再补，引擎只记一次新增")
        XCTAssertEqual(try nodes("c1@kelivo").count, 6, "叠加模式下第二份补上了新消息")
        XCTAssertEqual(try records().count, 1, "同一来源一条导入记录")
    }

    /// 同一份备份要导进另一个楼层：预览就能看到「已在其他楼层」（#061）
    func testPreviewSeesConflictOnOtherFloor() throws {
        let src = try write(try legacyFiles(), folder: "kelivo_backup")
        _ = try runAll(src)
        let s = try scan(src)
        defer { s.cleanup() }
        let reports = ImportSession.probeConflicts(s, ImportPreview.make(s), ctx(), "profile-other")
        XCTAssertEqual(reports[KelivoBackup.provider]?.total, 1)
        XCTAssertEqual(reports[KelivoBackup.provider]?.floors.first?.profileId, pid)
    }

    /// 直接选中解压出来的 chats.json：按内容认，附件都是占位
    func testDirectlyPickedLegacyChats() throws {
        let file = work.appendingPathComponent("chats.json")
        try legacyChats().write(to: file)
        let s = try scan(file)
        defer { s.cleanup() }
        XCTAssertEqual(s.kelivoPackages.count, 1)
        let summary = run(s)
        XCTAssertEqual(summary.conversations.added, 1)
        XCTAssertTrue(summary.notes.contains { $0.contains("1 个附件在备份里找不到") }, "\(summary.notes)")
    }
}
