import XCTest
import SwiftData
@testable import 记忆花园

/// #043：Claude 导出包导入（解析 / 合并 / 文件库 / 记忆 / 文件夹 / 撤回）。
/// 全部用内存库 + 临时目录 + 合成夹具，不碰真库、真文件库。
private func fixtures() throws -> URL { try ExportPackageScannerTests.fixtures() }

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
        ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private let pid = "profile-cccccccc"

private func decodeSegments(_ node: ImportedNodePayload) throws -> [MessageSegment] {
    try JSONDecoder().decode([MessageSegment].self, from: try XCTUnwrap(node.segmentsData))
}

// MARK: - 解析

final class ClaudeImporterSegmentsTests: XCTestCase {

    func testNewBlocksInlineAndFilesDedup() throws {
        let raws = try ClaudeImporter.load(file: try fixtures().appendingPathComponent("gen-c/conversations-000/conversations.json"))
        let payload = try XCTUnwrap(ClaudeImporter.payload(from: raws[0], folderIdByProject: ["p-c1": "folder-x"]))
        XCTAssertEqual(payload.folderId, "folder-x", "对话自带 project_uuid 时归进项目文件夹")
        let user = try XCTUnwrap(payload.nodes.first { $0.id == "c1-u" })
        XCTAssertEqual(try decodeSegments(user), [
            .text("看这张图"),
            .file(name: "截图.png", uuid: "f-img"),
            .file(name: "季度报告", uuid: "f-doc"),
            .text("这是语音转写"),
            .attachment(name: "附件.txt", type: "txt", extractedContent: "附件正文"),
            .file(name: "只在末尾.png", uuid: "f-tail"),
        ])
        XCTAssertFalse(user.content.contains("系统注入"), "注入块不导、不进搜索")
    }

    func testEmptyUUIDFilesNotDeduped() throws {
        let json = """
        [{"uuid":"x","name":"t","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
          "chat_messages":[{"uuid":"m","text":"","sender":"human","created_at":"2026-01-01T00:00:00Z",
            "content":[{"type":"text","text":"hi"},{"type":"image","file_uuid":""}],
            "files":[{"file_name":"a.png","file_uuid":""}],"attachments":[]}]}]
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = try XCTUnwrap(ClaudeImporter.payload(from: try ClaudeImporter.load(file: url)[0], folderIdByProject: [:]))
        XCTAssertEqual(try decodeSegments(payload.nodes[0]), [
            .text("hi"), .file(name: "图片", uuid: ""), .file(name: "a.png", uuid: ""),
        ])
    }

    func testCurrentLeafUsedWhenPresent() throws {
        let json = """
        [{"uuid":"x","name":"t","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
          "current_leaf_message_uuid":"a1",
          "chat_messages":[
            {"uuid":"u","text":"","sender":"human","content":[{"type":"text","text":"q"}],"parent_message_uuid":"root"},
            {"uuid":"a1","text":"","sender":"assistant","content":[{"type":"text","text":"一"}],"parent_message_uuid":"u"},
            {"uuid":"a2","text":"","sender":"assistant","content":[{"type":"text","text":"二"}],"parent_message_uuid":"u"}]}]
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let raws = try ClaudeImporter.load(file: url)
        XCTAssertEqual(ClaudeImporter.payload(from: raws[0], folderIdByProject: [:])?.currentNodeId, "a1")
    }
}

final class ClaudeDesignChatTests: XCTestCase {

    func testDesignChatPayload() throws {
        let url = try fixtures().appendingPathComponent("gen-b/design_chats/d-b1.json")
        let chat = try XCTUnwrap(ClaudeImporter.loadDesignChat(url))
        let payload = try XCTUnwrap(ClaudeImporter.makeDesignChatPayload(chat, folderIdByProject: ["dp-1": "f1"]))
        XCTAssertEqual(payload.title, "设计一个按钮")
        XCTAssertEqual(payload.folderId, "f1")
        XCTAssertEqual(payload.provider, "claude")
        XCTAssertEqual(payload.nodes.map(\.role), ["user", "assistant"])
        XCTAssertEqual(payload.nodes[0].childrenIds, ["d-b1-m1"])
        XCTAssertEqual(payload.nodes[1].parentId, "d-b1-m0")
        XCTAssertEqual(payload.currentNodeId, "d-b1-m1")
        XCTAssertEqual(try decodeSegments(payload.nodes[0]), [.text("做个按钮"), .file(name: "草图.png", uuid: "att-1")])
        XCTAssertEqual(try decodeSegments(payload.nodes[1]),
                       [.text("好的，按钮做好了"), .attachment(name: "button.html", type: "file", extractedContent: "<button>按钮</button>")])
        XCTAssertEqual(ClaudeImporter.designProjects([url]).map(\.uuid), ["dp-1"])
    }
}

// MARK: - 同一次导入多文件同 id

@MainActor
final class ImportDedupTests: XCTestCase {

    private func engine(_ container: ModelContainer, merge: Bool = false) throws -> (PayloadImportEngine, ImportRecord, ModelContext) {
        let ctx = ModelContext(container)
        let record = ImportRecord(fileName: "t", provider: "claude", mode: merge ? .merge : .normal, profileId: pid)
        ctx.insert(record)
        return (try PayloadImportEngine(context: ctx, profileId: pid, record: record, merge: merge, copyConflicts: false), record, ctx)
    }

    private func nodes(_ ctx: ModelContext, _ convId: String) throws -> [MessageNode] {
        try ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == convId && $0.profileId == pid }))
    }

    private func undo(_ ctx: ModelContext, _ recordId: UUID) throws {
        let changes = try ctx.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate { $0.recordId == recordId }))
        for c in changes { try restoreConversationChange(c, in: ctx) }
        try ctx.save()
    }

    func testOldThenNewMergesWithoutLosingAndUndoesClean() throws {
        let container = try makeContainer()
        let (e, record, ctx) = try engine(container)
        let f = try fixtures()
        try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-a/conversations.json"), folderIds: [:], engine: e)
        try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-b/conversations.json"), folderIds: [:], engine: e)

        XCTAssertEqual(e.counts.added, 3)        // a1 a2 b1
        XCTAssertEqual(e.counts.ignored, 1)      // a-empty
        XCTAssertEqual(e.counts.mergedDuplicates, 1)
        XCTAssertEqual(e.counts.updated, 0)
        XCTAssertEqual(Set(try nodes(ctx, "a1").map(\.id)), ["a1-u", "a1-a0", "a1-a1"], "新包多的消息补上，旧的不丢")
        let a1 = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == "a1" })).first)
        XCTAssertEqual(a1.title, "旧包对话一（改过）")
        let kinds = try ctx.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate { $0.conversationId == "a1" })).map(\.changeKind)
        XCTAssertEqual(kinds, [.created], "同次导入新建的不再存 updated 快照")
        XCTAssertTrue(record.supportsUndo)

        try undo(ctx, record.id)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Conversation>()).isEmpty)
        XCTAssertTrue(try nodes(ctx, "a1").isEmpty)
    }

    /// astra #1：同一条在第一个文件里没变、第二个文件才变 → 算「更新」，撤回入口要在
    func testMergeModeLaterOccurrenceCountsAsUpdatedAndIsUndoable() throws {
        let container = try makeContainer()
        let f = try fixtures()
        do {
            let (e, _, _) = try engine(container)
            try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-a/conversations.json"), folderIds: [:], engine: e)
        }
        let all = try JSONSerialization.jsonObject(with: Data(contentsOf: f.appendingPathComponent("gen-b/conversations.json"))) as! [[String: Any]]
        let onlyA1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: all.filter { $0["uuid"] as? String == "a1" }).write(to: onlyA1)
        defer { try? FileManager.default.removeItem(at: onlyA1) }

        let (e, record, ctx) = try engine(container, merge: true)
        try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-a/conversations.json"), folderIds: [:], engine: e)
        try ImportRunner.importClaudeFile(onlyA1, folderIds: [:], engine: e)
        XCTAssertEqual(e.counts.updated, 1)
        XCTAssertEqual(e.counts.skipped, 1)   // a2
        XCTAssertEqual(e.counts.mergedDuplicates, 1)
        XCTAssertTrue(record.supportsUndo)
        try undo(ctx, record.id)
        XCTAssertEqual(try nodes(ctx, "a1").count, 2)
    }

    /// astra #3：同次导入里后处理的那份更旧 → 只补消息，标题和共同消息不被旧的盖掉
    func testOlderDuplicateDoesNotOverwriteNewer() throws {
        let container = try makeContainer()
        let (e, _, ctx) = try engine(container)
        let f = try fixtures()
        try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-b/conversations.json"), folderIds: [:], engine: e)
        try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-a/conversations.json"), folderIds: [:], engine: e)
        let a1 = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == "a1" })).first)
        XCTAssertEqual(a1.title, "旧包对话一（改过）")
        XCTAssertEqual(try nodes(ctx, "a1").count, 3)
    }

    func testExistingLocalStaysUntouchedInNormalMode() throws {
        let container = try makeContainer()
        let f = try fixtures()
        do {
            let (e, _, _) = try engine(container)
            try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-a/conversations.json"), folderIds: [:], engine: e)
        }
        let (e, _, ctx) = try engine(container)
        try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-a/conversations.json"), folderIds: [:], engine: e)
        try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-b/conversations.json"), folderIds: [:], engine: e)
        XCTAssertEqual(e.counts.skipped, 2)
        XCTAssertEqual(e.counts.mergedDuplicates, 1)
        XCTAssertEqual(e.counts.added, 1)   // b1
        XCTAssertEqual(try nodes(ctx, "a1").count, 2, "普通模式不动本地已有的")
    }

    func testMergeModeSnapshotsOnceSoUndoRestoresOriginal() throws {
        let container = try makeContainer()
        let f = try fixtures()
        do {
            let (e, _, _) = try engine(container)
            try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-a/conversations.json"), folderIds: [:], engine: e)
        }
        let (e, record, ctx) = try engine(container, merge: true)
        try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-b/conversations.json"), folderIds: [:], engine: e)
        try ImportRunner.importClaudeFile(f.appendingPathComponent("gen-b/conversations.json"), folderIds: [:], engine: e)
        let rid = record.id
        let snapshots = try ctx.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate {
            $0.conversationId == "a1" && $0.recordId == rid
        }))
        XCTAssertEqual(snapshots.map(\.changeKind), [.updated], "一条对话一次导入只存一份导入前快照")
        XCTAssertEqual(try nodes(ctx, "a1").count, 3)

        try undo(ctx, record.id)
        XCTAssertEqual(try nodes(ctx, "a1").count, 2)
        let a1 = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == "a1" })).first)
        XCTAssertEqual(a1.title, "旧包对话一")
    }
}

// MARK: - 文件库

final class ClaudeLibraryImporterTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    private func genCPlan() throws -> ClaudeLibraryImporter.Plan {
        let c = try fixtures().appendingPathComponent("gen-c")
        let projects = try XCTUnwrap(ClaudeProject.load(c.appendingPathComponent("projects-000/projects/p-c1.json")))
        let (memory, _) = ClaudeMemoryImporter.parse([c.appendingPathComponent("memories-000/memories/acct-1.json")])
        return ClaudeLibraryImporter.plan(
            projects: projects,
            memoryFiles: memory.memoryFiles.map { ($0.path, $0.content) },
            artifactDirs: [c.appendingPathComponent("frames-000/artifacts/art1"), c.appendingPathComponent("frames-000/artifacts/art2")])
    }

    func testPlanPaths() throws {
        let plan = try genCPlan()
        let paths = Set(plan.writes.map(\.relPath))
        XCTAssertEqual(paths, [
            "Claude 项目/新项目/说明.md",
            "Claude 项目/新项目/spec.pdf.md",
            "Claude 项目/新项目/_..／逃逸.md",
            "Claude 记忆/notes/偏好.md",
            "Claude Artifacts/小页面/小页面.html",
            "Claude Artifacts/多文件应用/index.html",
            "Claude Artifacts/多文件应用/assets/app.js",
            "Claude Artifacts/多文件应用/conversations.json",
        ])
        XCTAssertFalse(plan.writes.contains { $0.relPath.split(separator: "/").contains("..") })
        XCTAssertEqual(plan.writes.first { $0.relPath.hasSuffix("小页面.html") }?.content, "<p>当前版</p>", "只取 active_version")
        let readme = try XCTUnwrap(plan.writes.first { $0.relPath.hasSuffix("说明.md") }?.content)
        XCTAssertTrue(readme.contains("编的项目") && readme.contains("项目指令：回答简短。"), "描述和指令都留")
        XCTAssertTrue(plan.skipped.contains("../../逃逸.md"))
        XCTAssertTrue(plan.skipped.contains { $0.contains("logo.png") })
    }

    func testCleanComponent() {
        XCTAssertEqual(ClaudeLibraryImporter.cleanComponent("a/b"), "a／b")
        XCTAssertNil(ClaudeLibraryImporter.cleanComponent(".."))
        XCTAssertNil(ClaudeLibraryImporter.cleanComponent("  "))
        XCTAssertEqual(ClaudeLibraryImporter.cleanComponent("\u{0}x\n"), "x")
        XCTAssertEqual(ClaudeLibraryImporter.cleanComponent(".hidden"), "_.hidden")
        let long = String(repeating: "长", count: 200)
        XCTAssertLessThanOrEqual(ClaudeLibraryImporter.cleanComponent(long)!.utf8.count, 255)
        XCTAssertNil(ClaudeLibraryImporter.cleanRelativePath("a/../b"))
        XCTAssertEqual(ClaudeLibraryImporter.cleanRelativePath("/a//./b/"), "a/b")
    }

    func testUniqueNamerStableAndCaseInsensitive() {
        var namer = ClaudeLibraryImporter.UniqueNamer()
        XCTAssertEqual(namer.name("Note.md", in: "d", source: "s1"), "Note.md")
        XCTAssertEqual(namer.name("note.md", in: "d", source: "s2abc"), "note · s2ab.md")
        XCTAssertEqual(namer.name("Note.md", in: "d", source: "s1"), "Note.md", "同一来源拿同一个名字")
        XCTAssertEqual(namer.name("Note.md", in: "other", source: "s9"), "Note.md")
    }

    func testApplyNeverOverwrites() throws {
        let plan = try genCPlan()
        let create: (LibraryWrite) throws -> Bool = { w in
            let url = self.work.appendingPathComponent(w.relPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try FileLibraryStore.createFileExclusively(at: url, data: Data(w.content.utf8))
        }
        let mine = work.appendingPathComponent("Claude 项目/新项目/说明.md")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("我自己改过".utf8).write(to: mine)

        let first = ClaudeLibraryImporter.apply(plan.writes, create: create)
        XCTAssertEqual(first.written, plan.writes.count - 1)
        XCTAssertEqual(first.existing, 1)
        XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "我自己改过")

        let again = ClaudeLibraryImporter.apply(plan.writes, create: create)
        XCTAssertEqual(again.written, 0)
        XCTAssertEqual(again.existing, plan.writes.count)
    }
}

// MARK: - 记忆

@MainActor
final class ClaudeMemoryImporterTests: XCTestCase {

    func testShapes() throws {
        let f = try fixtures()
        let (a, badA) = ClaudeMemoryImporter.parse([f.appendingPathComponent("gen-a/memories.json")])
        XCTAssertTrue(badA.isEmpty)
        XCTAssertEqual(ClaudeMemoryImporter.drafts(a, projectNames: ["p-a1": "旧项目"]).map(\.content), [
            "用户喜欢简短回答。", "用户在做一个 iOS app。", "（Claude 项目「旧项目」）这个项目是写小说的。",
        ])
        let (c, _) = ClaudeMemoryImporter.parse([f.appendingPathComponent("gen-c/memories-000/memories/acct-1.json")])
        XCTAssertEqual(c.memoryFiles.count, 2)
        XCTAssertEqual(ClaudeMemoryImporter.drafts(c, projectNames: [:]).last?.content, "（Claude 项目「p-c1」）新项目在做导入功能。")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows = dir.appendingPathComponent("rows.json")
        try Data(#"[{"uuid":"m1","content":"喜欢猫"},{"uuid":"m2","memory":"住在海边"}]"#.utf8).write(to: rows)
        let junk = dir.appendingPathComponent("junk.json")
        try Data(#"{"foo":1}"#.utf8).write(to: junk)
        let (r, bad) = ClaudeMemoryImporter.parse([rows, junk])
        XCTAssertEqual(ClaudeMemoryImporter.drafts(r, projectNames: [:]).map(\.content), ["喜欢猫", "住在海边"])
        XCTAssertEqual(bad, ["junk.json"])
    }

    func testSplitKeepsEveryCharacter() {
        let sentence = String(repeating: "字", count: 99) + "。"
        let long = String(repeating: sentence, count: 15)
        let chunks = ClaudeMemoryImporter.split(long)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= ClaudeMemoryImporter.maxChunk })
        XCTAssertEqual(chunks.joined(), long)

        let unbroken = String(repeating: "无", count: 1300)
        XCTAssertEqual(ClaudeMemoryImporter.split(unbroken).map(\.count), [600, 600, 100])
    }

    /// astra #7：导入后内容被改过的记忆，撤回时留着
    func testUndoKeepsRewrittenMemory() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let rid = UUID()
        _ = try ClaudeMemoryImporter.apply([.init(content: "一", category: "context"), .init(content: "二", category: "context")],
                                           profileId: pid, recordId: rid, context: ctx)
        let rewritten = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Memory>()).first { $0.content == "一" })
        rewritten.content = "一（园丁改写过）"
        try ctx.save()
        for change in try ctx.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate { $0.recordId == rid })) {
            try restoreConversationChange(change, in: ctx)
        }
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Memory>()).map(\.content), ["一（园丁改写过）"])
    }

    func testApplyDedupsAndRecordsChanges() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let drafts = [ClaudeMemoryImporter.Draft(content: "一", category: "context"),
                      ClaudeMemoryImporter.Draft(content: "二", category: "context")]
        let rid = UUID()
        XCTAssertEqual(try ClaudeMemoryImporter.apply(drafts, profileId: pid, recordId: rid, context: ctx).added, 2)
        let again = try ClaudeMemoryImporter.apply(drafts, profileId: pid, recordId: UUID(), context: ctx)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.existing, 2)
        let memories = try ctx.fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(memories.count, 2)
        XCTAssertTrue(memories.allSatisfy { !$0.isUserExplicit && $0.extractedBy == ClaudeMemoryImporter.source })
        let changes = try ctx.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate { $0.recordId == rid }))
        XCTAssertEqual(changes.map(\.changeKind), [.createdMemory, .createdMemory])
    }
}

// MARK: - 文件夹

@MainActor
final class ClaudeProjectFolderTests: XCTestCase {

    func testFoldersCreatedOnceAndUserEditsKept() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let projects = try XCTUnwrap(ClaudeProject.load(try fixtures().appendingPathComponent("gen-a/projects.json")))
        let first = try ClaudeProjectFolders.apply(projects: projects, designProjects: [("dp-1", "设计项目甲")],
                                                   profileId: pid, recordId: UUID(), context: ctx)
        XCTAssertEqual(first.created, 2)
        let tag = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ConversationTag>()).first { $0.name == "旧项目" })
        XCTAssertEqual(tag.instructions, "项目指令：回答简短。")
        XCTAssertEqual(tag.id, ClaudeProjectFolders.folderId(source: "p-a1", kind: "project", profileId: pid))

        tag.name = "我改的名字"
        tag.instructions = "我改的说明"
        try ctx.save()
        let again = try ClaudeProjectFolders.apply(projects: projects, designProjects: [("dp-1", "设计项目甲")],
                                                   profileId: pid, recordId: UUID(), context: ctx)
        XCTAssertEqual(again.created, 0)
        XCTAssertEqual(again.existing, 2)
        XCTAssertEqual(tag.name, "我改的名字")
        XCTAssertEqual(tag.instructions, "我改的说明")
    }

    func testSameNameFolderReused() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let mine = ConversationTag(name: "旧项目", profileId: pid)
        ctx.insert(mine)
        try ctx.save()
        let projects = try XCTUnwrap(ClaudeProject.load(try fixtures().appendingPathComponent("gen-a/projects.json")))
        let rid = UUID()
        let r = try ClaudeProjectFolders.apply(projects: projects, designProjects: [], profileId: pid, recordId: rid, context: ctx)
        XCTAssertEqual(r.existing, 1)
        XCTAssertEqual(r.folderIdBySource["p-a1"], mine.id)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate { $0.recordId == rid })).isEmpty,
                      "你原来的文件夹不记撤回")
    }
}

// MARK: - 整条流程

@MainActor
final class ImportEndToEndTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("import-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    private func libraryCreate(_ w: LibraryWrite) throws -> Bool {
        let url = work.appendingPathComponent("library").appendingPathComponent(w.relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try FileLibraryStore.createFileExclusively(at: url, data: Data(w.content.utf8))
    }

    private func run(_ scan: ExportPackageScan, _ container: ModelContainer, options: ImportRunner.Options = .init()) -> ImportSummary {
        ImportRunner.run(scan: scan, preview: ImportPreview.make(scan), selection: ImportSelection(), options: options,
                         profileId: pid, container: container, libraryCreate: libraryCreate, progress: { _, _ in })
    }

    func testGenCFullRunUndoAndRerun() throws {
        let container = try makeContainer()
        let scan = try ExportPackageScanner.scan([try fixtures().appendingPathComponent("gen-c")], tempRoot: work)
        let s = run(scan, container)
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.conversations.added, 2)           // c1 + 设计对话
        XCTAssertEqual(s.foldersCreated, 2)                // 项目 + 设计项目
        XCTAssertEqual(s.memoriesAdded, 3)
        XCTAssertEqual(s.library.written, 8)
        XCTAssertFalse(s.librarySkipped.isEmpty)

        let ctx = ModelContext(container)
        let convs = try ctx.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(convs.first { $0.id == "c1" }?.folderId,
                       ClaudeProjectFolders.folderId(source: "p-c1", kind: "project", profileId: pid))
        XCTAssertEqual(convs.first { $0.id == "d-c1" }?.folderId,
                       ClaudeProjectFolders.folderId(source: "dp-2", kind: "design", profileId: pid))
        let record = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ImportRecord>()).first { $0.provider == "claude" })
        XCTAssertTrue(record.supportsUndo)

        let rid = record.id
        for change in try ctx.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate { $0.recordId == rid })) {
            try restoreConversationChange(change, in: ctx)
        }
        try ctx.save()
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Conversation>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ConversationTag>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Memory>()).isEmpty)

        let again = run(scan, container)
        XCTAssertEqual(again.conversations.added, 2)
        XCTAssertEqual(again.library.existing, 8, "文件库不随撤回删，再导一次全跳过不覆盖")
        let third = run(scan, container)
        XCTAssertEqual(third.conversations.skipped, 2)
        XCTAssertEqual(third.foldersExisting, 2)
        XCTAssertEqual(third.memoriesExisting, 3)
        scan.cleanup()
    }

    /// astra #8：清空 Claude 导入数据连带清掉导入时建的记忆 / 文件夹，不留撤不了的孤儿
    func testWiperClearsExtras() throws {
        let container = try makeContainer()
        let scan = try ExportPackageScanner.scan([try fixtures().appendingPathComponent("gen-c")], tempRoot: work)
        defer { scan.cleanup() }
        _ = run(scan, container)
        let ctx = ModelContext(container)
        let mine = Memory(content: "我自己的记忆", category: "fact", profileId: pid, isUserExplicit: true, extractedBy: "manual")
        ctx.insert(mine)
        try ctx.save()
        try ClaudeDataWiper.wipe(profileId: pid, context: ctx)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Conversation>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ConversationTag>()).isEmpty)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Memory>()).map(\.content), ["我自己的记忆"])
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ImportConversationChange>()).isEmpty)
    }

    func testFailureMidwayKeepsUndoableProgress() throws {
        let container = try makeContainer()
        let broken = work.appendingPathComponent("broken.json")
        try Data("[{\"uuid\": ".utf8).write(to: broken)
        var scan = ExportPackageScan(stagingDir: work.appendingPathComponent("staging"))
        let good = try fixtures().appendingPathComponent("gen-a/conversations.json")
        scan.claudeFiles = [
            .init(url: good, source: .claude, entries: [], latest: nil, order: 0),
            .init(url: broken, source: .claude, entries: [], latest: nil, order: 1),
        ]
        let s = run(scan, container)
        XCTAssertEqual(s.failedStep, ImportStage.claude.rawValue)
        XCTAssertEqual(s.conversations.added, 2)

        let ctx = ModelContext(container)
        let record = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ImportRecord>()).first)
        XCTAssertTrue(record.supportsUndo, "前一个文件已落库，必须能撤回")
        XCTAssertEqual(record.addedConversationCount, 2)
    }
}
