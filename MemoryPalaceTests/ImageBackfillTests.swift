import JavaScriptCore
import XCTest
import SwiftData
@testable import 记忆花园

/// #057 补原图：扫描占位 → 读下好的文件夹 → 预览 → 填回 → 精确撤回。合成样本，不碰真库、真文件库。
@MainActor
final class ImageBackfillTests: XCTestCase {

    private var container: ModelContainer!
    private var work: URL!
    private var library: URL!
    private let pid = "profile-backfill"
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x02])

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
            ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("backfill-\(UUID().uuidString)")
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

    private func encode(_ segments: [MessageSegment]) throws -> Data {
        try JSONEncoder().encode(segments)
    }

    @discardableResult
    private func addConversation(_ id: String, provider: String, profileId: String? = nil, trashed: Bool = false,
                                 nodes: [(id: String, segments: [MessageSegment])], in context: ModelContext) throws -> Conversation {
        let floor = profileId ?? pid
        let conversation = Conversation(id: id, title: "标题 \(id)", createTime: Date(), updateTime: Date(),
                                        currentNodeId: nodes.last?.id ?? "", provider: provider, profileId: floor)
        conversation.isTrashed = trashed
        context.insert(conversation)
        for node in nodes {
            let content = node.segments.compactMap { segment -> String? in
                switch segment {
                case .text(let s): return s
                case .file(let name, _), .imageRef(let name, _, _): return "🖼 \(name)"
                default: return nil
                }
            }.joined(separator: "\n")
            let message = MessageNode(id: node.id, role: "user", content: content, contentType: "segmented",
                                      createTime: Date(), parentId: nil, childrenIds: [], conversationId: id, profileId: floor)
            message.segmentsData = try encode(node.segments)
            context.insert(message)
        }
        try context.save()
        return conversation
    }

    private func segments(_ nodeId: String, in context: ModelContext) throws -> [MessageSegment] {
        let node = try XCTUnwrap(try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })).first)
        return try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(node.segmentsData))
    }

    private func folder(_ files: [String: Data], manifest: String? = nil) throws -> URL {
        let dir = work.appendingPathComponent("downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }
        if let manifest { try Data(manifest.utf8).write(to: dir.appendingPathComponent(ImageBackfill.manifestFileName)) }
        return dir
    }

    /// Claude 一段：两个节点引用同一张图 + 一张别的图 + 一个 pdf；ChatGPT 一段没占位（旧版导入）
    private func seedStandard(_ context: ModelContext) throws {
        try addConversation("claude-1", provider: "claude", nodes: [
            ("c1-u1", [.text("看这张"), .file(name: "Screenshot 2026-02-15 at 10.53 am", uuid: "uuid-a")]),
            ("c1-u2", [.file(name: "photo.png", uuid: "uuid-a"), .file(name: "notes.pdf", uuid: "uuid-doc")]),
            ("c1-u3", [.file(name: "IMG_0001.jpeg", uuid: "uuid-b")]),
        ], in: context)
        try addConversation("gpt-1", provider: "chatgpt", nodes: [("g1-u1", [.text("旧版导入，图没留位置")])], in: context)
    }

    // MARK: - 扫描

    func testScanFindsImagePlaceholdersOnly() throws {
        let context = container.mainContext
        try seedStandard(context)
        // 别的楼层、回收站里的对话、已经是真图的节点都不算
        try addConversation("claude-other", provider: "claude", profileId: "another-floor",
                            nodes: [("o1", [.file(name: "x.png", uuid: "uuid-x")])], in: context)
        try addConversation("claude-trash", provider: "claude", trashed: true,
                            nodes: [("t1", [.file(name: "y.png", uuid: "uuid-y")])], in: context)
        try addConversation("claude-done", provider: "claude",
                            nodes: [("d1", [.imageRef(name: "z.png", type: "image/png", path: "attachments/z.png")])], in: context)
        // 别的来源（API 对话）不算
        try addConversation("api-1", provider: "api", nodes: [("p1", [.file(name: "q.png", uuid: "uuid-q")])], in: context)

        let inventory = try ImageBackfill.scan(profileId: pid, context: context, pageSize: 2)
        XCTAssertEqual(Set(inventory.byId.keys), ["uuid-a", "uuid-b"])
        XCTAssertEqual(inventory.byId["uuid-a"]?.count, 2)
        XCTAssertEqual(inventory.missingIds(.claude), ["uuid-a", "uuid-b"])
        XCTAssertEqual(inventory.missingIds(.chatgpt), [])
        XCTAssertEqual(inventory.conversationCount[.chatgpt], 1, "ChatGPT 有对话却没占位 → 页面提示先叠加再导")
        XCTAssertEqual(inventory.conversationCount[.claude], 2)
        XCTAssertEqual(inventory.conversationsWithPlaceholders(.claude), 1)
    }

    // MARK: - 脚本

    func testScriptEmbedsListAsJSONAndCompiles() throws {
        let context = container.mainContext
        try addConversation("gpt-2", provider: "chatgpt", nodes: [
            ("g2-u1", [.file(name: #"带"引号"和</script>的名字.png"#, uuid: #"file_00"abc"#)]),
            ("g2-u2", [.file(name: "b.png", uuid: "file-b")]),
        ], in: context)
        try addConversation("claude-2", provider: "claude", nodes: [("c2-u1", [.file(name: "c.png", uuid: "uuid-c")])], in: context)
        let inventory = try ImageBackfill.scan(profileId: pid, context: context)

        let script = try ImageBackfill.script(for: .chatgpt, inventory: inventory)
        XCTAssertFalse(script.contains("__BACKFILL_CONFIG__"))
        XCTAssertTrue(script.contains(#""conversationId":"gpt-2""#))
        XCTAssertFalse(script.contains("uuid-c"), "只带这个来源的编号")

        // 模板语法：只编译不运行（运行要 window / location）
        let js = try XCTUnwrap(JSContext())
        var exception: String?
        js.exceptionHandler = { _, value in exception = value?.toString() }
        let source = String(decoding: try JSONEncoder().encode(script), as: UTF8.self)
        js.evaluateScript("new Function(\(source));")
        XCTAssertNil(exception, "脚本编不过：\(exception ?? "")")

        // 清单原样还原（引号、</script> 都不破坏）
        let start = try XCTUnwrap(script.range(of: "const CONFIG = "))
        let end = try XCTUnwrap(script.range(of: ";\n", range: start.upperBound..<script.endIndex))
        let config = try JSONSerialization.jsonObject(with: Data(script[start.upperBound..<end.lowerBound].utf8)) as? [String: Any]
        let items = try XCTUnwrap(config?["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, ["file-b", #"file_00"abc"#])

        let trial = try ImageBackfill.script(for: .claude, inventory: inventory, limit: 3)
        XCTAssertTrue(trial.contains("uuid-c"))
        XCTAssertFalse(trial.contains("conversationId\":\"claude-2"), "Claude 不带对话 id")
    }

    // MARK: - 文件夹 + 预览

    func testPreviewMatchesByIdOnly() throws {
        let context = container.mainContext
        try seedStandard(context)
        let inventory = try ImageBackfill.scan(profileId: pid, context: context)
        let dir = try folder([
            "uuid-a.png": png,
            "uuid-b.jpg": Data("<html>Not found</html>".utf8),
            "uuid-elsewhere.png": png,
            "IMG_0001.jpeg": jpeg,   // 名字对得上也不认：只按编号
        ], manifest: #"{"source":"claude","items":[{"id":"uuid-a","status":"ok"},{"id":"uuid-b","status":"error"}]}"#)
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))

        let preview = ImageBackfill.preview(inventory: inventory, folder: try ImageBackfill.readFolder(dir))
        XCTAssertEqual(Set(preview.fillable.keys), ["uuid-a"])
        XCTAssertEqual(preview.placeholderCount[.claude], 2)
        XCTAssertEqual(preview.conversationCount[.claude], 1)
        XCTAssertEqual(preview.notImage, ["uuid-b"])
        XCTAssertEqual(preview.notInFloor, 2)
        XCTAssertEqual(preview.fillableBytes, UInt64(png.count))
        XCTAssertEqual(preview.stillMissing[.claude], nil, "uuid-b 文件夹里有（只是不是图），不算还缺")
    }

    func testPreviewCountsReportedNotFound() throws {
        let context = container.mainContext
        try seedStandard(context)
        let inventory = try ImageBackfill.scan(profileId: pid, context: context)
        let dir = try folder(["uuid-a.png": png],
                             manifest: #"{"source":"claude","items":[{"id":"uuid-b","status":"notFound"}]}"#)
        let preview = ImageBackfill.preview(inventory: inventory, folder: try ImageBackfill.readFolder(dir))
        XCTAssertEqual(preview.stillMissing[.claude], 1)
        XCTAssertEqual(preview.reportedNotFound, 1)
    }

    func testBrokenManifestIsIgnored() throws {
        let dir = try folder(["uuid-a.png": png], manifest: "{坏的")
        let folder = try ImageBackfill.readFolder(dir)
        XCTAssertEqual(Set(folder.items.keys), ["uuid-a"])
        XCTAssertTrue(folder.manifestStatus.isEmpty)
    }

    // MARK: - 写库

    private func applyAll(_ files: [String: Data]) throws -> ImageBackfill.Result {
        let context = container.mainContext
        let inventory = try ImageBackfill.scan(profileId: pid, context: context)
        let preview = ImageBackfill.preview(inventory: inventory, folder: try ImageBackfill.readFolder(try folder(files)))
        return try ImageBackfill.apply(preview: preview, inventory: inventory, folderName: "claude-images",
                                       profileId: pid, container: container)
    }

    func testApplyReplacesPlaceholdersAndStoresOneFilePerConversation() throws {
        let context = container.mainContext
        try seedStandard(context)
        let result = try applyAll(["uuid-a.png": png, "uuid-b.jpeg": jpeg])
        XCTAssertEqual(result.filled[.claude], 3)
        XCTAssertEqual(result.conversations[.claude], 1)
        XCTAssertTrue(result.failed.isEmpty)

        let fresh = ModelContext(container)
        let first = try segments("c1-u1", in: fresh)
        XCTAssertEqual(first.first, .text("看这张"))
        guard case .imageRef(_, let type, let pathA) = first[1] else { return XCTFail("没换成真图：\(first)") }
        XCTAssertEqual(type, "image/png")
        let second = try segments("c1-u2", in: fresh)
        guard case .imageRef(_, _, let pathA2) = second[0] else { return XCTFail("同编号第二处没补") }
        XCTAssertEqual(pathA, pathA2, "同一段对话里同一张图只存一份")
        XCTAssertEqual(second[1], .file(name: "notes.pdf", uuid: "uuid-doc"), "文档占位不动")
        XCTAssertEqual(try FileLibraryStore.readData(pathA, profileId: pid), png)

        // 正文不动（搜索不用重建）
        let node = try XCTUnwrap(try fresh.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "c1-u1" })).first)
        XCTAssertEqual(node.content, "看这张\n🖼 Screenshot 2026-02-15 at 10.53 am")

        let record = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ImportRecord>()).first)
        XCTAssertEqual(record.mode, .backfill)
        XCTAssertEqual(record.provider, "claude")
        XCTAssertEqual(record.nodeCount, 3)
        XCTAssertEqual(record.updatedConversationCount, 1)
        XCTAssertTrue(record.supportsUndo)
        XCTAssertEqual(record.summaryText, "补原图 · 3 张，在 1 段对话里")
        XCTAssertEqual(ImportManifest.decode(record.detailData)?.sources.first?.updated, ["claude-1"])
    }

    // MARK: - 撤回

    private func undoAll() throws {
        let context = ModelContext(container)
        for change in try context.fetch(FetchDescriptor<ImportConversationChange>()) {
            try restoreConversationChange(change, in: context)
        }
        try context.save()
    }

    func testUndoRestoresOnlyBackfilledImages() throws {
        let context = container.mainContext
        try seedStandard(context)
        _ = try applyAll(["uuid-a.png": png, "uuid-b.jpeg": jpeg])

        // 补完之后接着聊：新消息、改过的节点都得留着
        let later = ModelContext(container)
        let newNode = MessageNode(id: "c1-new", role: "assistant", content: "后来的回复", contentType: "text",
                                  createTime: Date(), parentId: "c1-u3", childrenIds: [], conversationId: "claude-1", profileId: pid)
        later.insert(newNode)
        let u2 = try XCTUnwrap(try later.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "c1-u2" })).first)
        var u2Segments = try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(u2.segmentsData))
        u2Segments.append(.text("我后来补了一句"))
        u2.segmentsData = try encode(u2Segments)
        try later.save()
        let storedPaths = ImageBackfill.attachmentFiles(conversationId: "claude-1", profileId: pid)
        XCTAssertEqual(storedPaths.count, 2)

        try undoAll()

        let fresh = ModelContext(container)
        XCTAssertEqual(try segments("c1-u1", in: fresh), [.text("看这张"), .file(name: "Screenshot 2026-02-15 at 10.53 am", uuid: "uuid-a")])
        XCTAssertEqual(try segments("c1-u2", in: fresh),
                       [.file(name: "photo.png", uuid: "uuid-a"), .file(name: "notes.pdf", uuid: "uuid-doc"), .text("我后来补了一句")])
        XCTAssertEqual(try segments("c1-u3", in: fresh), [.file(name: "IMG_0001.jpeg", uuid: "uuid-b")])
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "c1-new" })), 1)
        XCTAssertTrue(ImageBackfill.attachmentFiles(conversationId: "claude-1", profileId: pid).isEmpty, "这次存的图删掉")
    }

    func testUndoKeepsFilesThatExistedBefore() throws {
        let context = container.mainContext
        try seedStandard(context)
        // 文件库里早就有同名同内容的图（AttachmentStore 会复用它）→ 撤回不能删
        let existing = try AttachmentStore.save(fileName: "IMG_0001.jpeg", data: jpeg, conversationId: "claude-1",
                                                conversationTitle: "标题 claude-1", profileId: pid)
        _ = try applyAll(["uuid-b.jpeg": jpeg])
        guard case .imageRef(_, _, let path) = try segments("c1-u3", in: ModelContext(container))[0] else {
            return XCTFail("没补上")
        }
        XCTAssertEqual(path, existing)

        try undoAll()
        XCTAssertNotNil(FileLibraryStore.absoluteURL(existing, profileId: pid), "补之前就有的文件留着")
        XCTAssertEqual(try segments("c1-u3", in: ModelContext(container)), [.file(name: "IMG_0001.jpeg", uuid: "uuid-b")])
    }

    func testUndoSkipsDeletedNodesAndSwappedImages() throws {
        let context = container.mainContext
        try seedStandard(context)
        _ = try applyAll(["uuid-a.png": png, "uuid-b.jpeg": jpeg])

        let later = ModelContext(container)
        // c1-u3 被删了；c1-u1 的图被换成别的
        let u3 = try XCTUnwrap(try later.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "c1-u3" })).first)
        later.delete(u3)
        let u1 = try XCTUnwrap(try later.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "c1-u1" })).first)
        u1.segmentsData = try encode([.text("看这张"), .imageRef(name: "other.png", type: "image/png", path: "attachments/other.png")])
        try later.save()

        try undoAll()
        let fresh = ModelContext(container)
        XCTAssertEqual(try segments("c1-u1", in: fresh),
                       [.text("看这张"), .imageRef(name: "other.png", type: "image/png", path: "attachments/other.png")])
        XCTAssertEqual(try segments("c1-u2", in: fresh),
                       [.file(name: "photo.png", uuid: "uuid-a"), .file(name: "notes.pdf", uuid: "uuid-doc")])
    }

    func testUnknownChangeKindDoesNothing() throws {
        let context = container.mainContext
        try seedStandard(context)
        let change = ImportConversationChange(recordId: UUID(), conversationId: "claude-1", changeKind: .created, profileId: pid)
        change.changeKindRaw = "somethingFromANewerVersion"
        context.insert(change)
        try context.save()

        try restoreConversationChange(change, in: context)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == "claude-1" })), 1,
                       "不认识的撤回种类不能当成「新建」把对话删掉")
    }
}
