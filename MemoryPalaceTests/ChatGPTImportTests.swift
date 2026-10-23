import XCTest
import SwiftData
import ZIPFoundation
@testable import 记忆花园

/// #050：ChatGPT 导出包导入。样本全在代码里合成，不碰真库、真文件库。
private let pid = "profile-dddddddd"

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Conversation.self, MessageNode.self, FavoriteItem.self, UserCard.self,
        ImportRecord.self, ImportConversationChange.self, Memory.self, ConversationTag.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

/// 合成 ChatGPT 对话：一个根 + 按顺序一条接一条的消息
enum GPT {
    struct Msg {
        var id: String
        var role: String = "assistant"
        var content: [String: Any] = ["content_type": "text", "parts": ["你好"]]
        var recipient: String? = nil
        var channel: String? = nil
        var metadata: [String: Any] = [:]
        var authorName: String? = nil
        var time: Double? = 1_700_000_010
    }

    static func text(_ id: String, _ role: String, _ text: String) -> Msg {
        Msg(id: id, role: role, content: ["content_type": "text", "parts": [text]])
    }

    static func conversation(_ id: String?, title: String = "标题", messages: [Msg],
                             create: Double? = 1_700_000_000, update: Double? = 1_700_000_100) -> [String: Any] {
        let cid = id ?? "anon"
        var mapping: [String: Any] = [:]
        var prev = "\(cid)-root"
        mapping[prev] = ["id": prev, "message": NSNull(), "parent": NSNull(), "children": [] as [String]]
        for m in messages {
            var p = mapping[prev] as! [String: Any]
            p["children"] = (p["children"] as! [String]) + [m.id]
            mapping[prev] = p
            var author: [String: Any] = ["role": m.role]
            if let n = m.authorName { author["name"] = n }
            var message: [String: Any] = ["id": m.id, "author": author, "content": m.content, "metadata": m.metadata]
            message["create_time"] = m.time ?? NSNull()
            if let r = m.recipient { message["recipient"] = r }
            if let c = m.channel { message["channel"] = c }
            mapping[m.id] = ["id": m.id, "message": message, "parent": prev, "children": [] as [String]]
            prev = m.id
        }
        var conv: [String: Any] = ["title": title, "current_node": prev, "mapping": mapping]
        if let id { conv["id"] = id }
        conv["create_time"] = create ?? NSNull()
        conv["update_time"] = update ?? NSNull()
        return conv
    }

    static func simple(_ id: String, title: String = "标题", reply: String = "你好") -> [String: Any] {
        conversation(id, title: title, messages: [text("\(id)-u", "user", "问题"), text("\(id)-a", "assistant", reply)])
    }

    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    /// 打 zip：条目名 → 内容
    static func zip(_ files: [String: Data], to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
    }
}

final class ChatGPTImportFlowTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gpt-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    private func run(_ scan: ExportPackageScan, _ container: ModelContainer, merge: Bool = false) -> ImportSummary {
        ImportRunner.run(scan: scan, preview: ImportPreview.make(scan), selection: ImportSelection(),
                         options: .init(merge: merge), profileId: pid, container: container,
                         libraryCreate: { _ in true }, progress: { _, _ in })
    }

    private func undo(_ provider: String, _ container: ModelContainer) throws {
        let ctx = ModelContext(container)
        let record = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ImportRecord>()).last { $0.provider == provider })
        let rid = record.id
        for change in try ctx.fetch(FetchDescriptor<ImportConversationChange>(predicate: #Predicate { $0.recordId == rid })) {
            try restoreConversationChange(change, in: ctx)
            ctx.delete(change)
        }
        ctx.delete(record)
        try ctx.save()
    }

    /// 0a：ChatGPT zip 走完整流程（扫描 → 导入 → 撤回 → 重导 → 再导跳过）
    func testZipFullRunUndoAndRerun() throws {
        let container = try makeContainer()
        let zip = work.appendingPathComponent("chatgpt-export.zip")
        try GPT.zip(["conversations.json": try GPT.json([GPT.simple("g1"), GPT.simple("g2")]),
                     "user.json": try GPT.json(["id": "u"])], to: zip)
        let scan = try ExportPackageScanner.scan([zip], tempRoot: work)
        defer { scan.cleanup() }
        XCTAssertEqual(scan.chatGPTConversationCount, 2)

        let s = run(scan, container)
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.conversations.added, 2)
        let ctx = ModelContext(container)
        XCTAssertEqual(Set(try ctx.fetch(FetchDescriptor<Conversation>()).map(\.id)), ["g1", "g2"])
        let record = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ImportRecord>()).first)
        XCTAssertEqual(record.provider, "chatgpt")
        XCTAssertTrue(record.supportsUndo)

        try undo("chatgpt", container)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<MessageNode>()).isEmpty)

        XCTAssertEqual(run(scan, container).conversations.added, 2)
        let third = run(scan, container)
        XCTAssertEqual(third.conversations.skipped, 2)
        XCTAssertTrue(third.notes.contains { $0.hasPrefix("有 2 段 ChatGPT 对话本地已有") }, "提示开叠加再导能升级")
        XCTAssertFalse(run(scan, container, merge: true).notes.contains { $0.contains("本地已有") })
    }

    // MARK: - 认包（E3）

    /// 隐私门户包：外层 zip 套三个分卷；对话分卷解开，附件分卷只建索引，图片按「名字 + 大小」导进文件库
    func testPrivacyPortalNestedVolumes() throws {
        let library = work.appendingPathComponent("library")
        FileLibraryStore.testRootOverride = library
        defer { FileLibraryStore.testRootOverride = nil }
        MainThreadIO.allowMainThreadInThisTest()

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 1, 2, 3])
        let user = GPT.Msg(id: "p1-u", role: "user",
                           content: ["content_type": "multimodal_text",
                                     "parts": [["content_type": "image_asset_pointer", "asset_pointer": "sediment://file_00aa"],
                                               "看这张图"]],
                           metadata: ["attachments": [["id": "file_00aa", "name": "IMG_0001.png", "size": png.count],
                                                      ["id": "file-zz", "name": "报告.pdf", "size": 3]]])
        let conv = GPT.conversation("p1", messages: [user, GPT.text("p1-a", "assistant", "好看")])

        let convZip = work.appendingPathComponent("Conversations__user-x-chatgpt-0001.zip")
        try GPT.zip(["conversations.json": try GPT.json([conv]), "chat.html": Data("<html>".utf8),
                     "user.json": try GPT.json(["id": "u"])], to: convZip)
        let filesZip = work.appendingPathComponent("Files__user-x-files-0001.zip")
        try GPT.zip(["personal/files/IMG_0001.png": png, "personal/files/IMG_0002.png": png], to: filesZip)
        let dalleZip = work.appendingPathComponent("Dall-E__user-x-dalle-0001.zip")
        try GPT.zip(["personal/dallelabs/u/chatgptgenerations/u/conversations/p1/abc.webp": Data([1, 2])], to: dalleZip)
        let outer = work.appendingPathComponent("OpenAI-export.zip")
        try GPT.zip(["User Online Activity/\(convZip.lastPathComponent)": try Data(contentsOf: convZip),
                     "User Online Activity/\(filesZip.lastPathComponent)": try Data(contentsOf: filesZip),
                     "User Online Activity/\(dalleZip.lastPathComponent)": try Data(contentsOf: dalleZip),
                     "User Profile/Support Profile.csv": Data("a,b".utf8)], to: outer)

        let scan = try ExportPackageScanner.scan([outer], tempRoot: work)
        defer { scan.cleanup() }
        XCTAssertEqual(scan.chatGPTConversationCount, 1)
        XCTAssertEqual(scan.chatGPTAssets.count, 3)

        let container = try makeContainer()
        let s = run(scan, container)
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.conversations.added, 1)
        XCTAssertEqual(s.warnings.map(\.title), ["上传的图片 / 文件包里没有，放了占位"], "pdf 包里没有")

        let node = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<MessageNode>()).first { $0.id == "p1-u" })
        let segs = try JSONDecoder().decode([MessageSegment].self, from: try XCTUnwrap(node.segmentsData))
        guard case .imageRef(_, let type, let path) = segs[0] else { return XCTFail("第一段应是存进文件库的图：\(segs)") }
        XCTAssertEqual(type, "image/png")
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent(pid).appendingPathComponent(path)), png)
        XCTAssertEqual(segs[1], .text("看这张图"))
        XCTAssertEqual(segs[2], .file(name: "报告.pdf", uuid: "file-zz"))
        XCTAssertTrue(node.content.contains("看这张图"))
    }

    /// 普通模式下已有的对话（跳过）不读附件、不往文件库写
    func testSkippedConversationWritesNoAssets() throws {
        let library = work.appendingPathComponent("library")
        FileLibraryStore.testRootOverride = library
        defer { FileLibraryStore.testRootOverride = nil }
        MainThreadIO.allowMainThreadInThisTest()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
        let user = GPT.Msg(id: "s1-u", role: "user",
                           content: ["content_type": "multimodal_text",
                                     "parts": [["content_type": "image_asset_pointer", "asset_pointer": "file-service://file-abc"]]])
        let zip = work.appendingPathComponent("export.zip")
        try GPT.zip(["conversations.json": try GPT.json([GPT.conversation("s1", messages: [user])]),
                     "file-abc-photo.png": png], to: zip)
        let scan = try ExportPackageScanner.scan([zip], tempRoot: work)
        defer { scan.cleanup() }
        let container = try makeContainer()
        XCTAssertEqual(run(scan, container).conversations.added, 1, "按 id 对上")
        let attachments = library.appendingPathComponent(pid).appendingPathComponent(AttachmentStore.folderName)
        let firstWrite = try FileManager.default.contentsOfDirectory(atPath: attachments.path)
        try FileManager.default.removeItem(at: attachments)
        XCTAssertEqual(run(scan, container).conversations.skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.path), "跳过的对话不写文件库")
        XCTAssertEqual(firstWrite.count, 1)
    }

    /// 新版分片 + manifest：缺的分片进注意事项，其余照导
    func testShardsAndManifestMissingShard() throws {
        let zip = work.appendingPathComponent("chatgpt-new.zip")
        let manifest: [String: Any] = ["version": 1, "logical_files": ["conversations.json": [
            "files": ["conversations-000.json", "conversations-001.json", "conversations-002.json"]]]]
        try GPT.zip(["export_manifest.json": try GPT.json(manifest),
                     "conversations-000.json": try GPT.json([GPT.simple("n1")]),
                     "conversations-001.json": try GPT.json([GPT.simple("n2"), GPT.simple("n3")])], to: zip)
        let scan = try ExportPackageScanner.scan([zip], tempRoot: work)
        defer { scan.cleanup() }
        XCTAssertEqual(scan.chatGPTConversationCount, 3)
        XCTAssertEqual(scan.missingFromManifest, ["conversations-002.json"])
        XCTAssertTrue(scan.unrecognized.isEmpty)
        let s = run(scan, try makeContainer())
        XCTAssertEqual(s.conversations.added, 3)
        XCTAssertEqual(s.warnings.first?.title, "清单里有、包里没有的分片（部分导入）")
    }

    /// `{"conversations": [...]}` 包一层的也认
    func testWrapperObject() throws {
        let url = work.appendingPathComponent("wrapped.json")
        try GPT.json(["conversations": [GPT.simple("w1")], "version": 2]).write(to: url)
        let scan = try ExportPackageScanner.scan([url], tempRoot: work)
        defer { scan.cleanup() }
        XCTAssertEqual(scan.chatGPTConversationCount, 1)
        XCTAssertEqual(run(scan, try makeContainer()).conversations.added, 1)
    }

    // MARK: - 读文件（E2 / E8）

    /// 坏一条只丢那一条；ChatGPT 文件整份坏了也不连累 Claude
    func testBadConversationSkippedAndNoCascade() throws {
        let good = try GPT.json([GPT.simple("b1"), GPT.simple("b2")])
        var text = String(data: good, encoding: .utf8)!
        text = text.replacingOccurrences(of: "\"mapping\"", with: "\"mapping\": 5, \"x\"", options: [], range: text.range(of: "\"mapping\""))
        let url = work.appendingPathComponent("conversations.json")
        try Data(text.utf8).write(to: url)
        let container = try makeContainer()
        var scan = ExportPackageScan(stagingDir: work.appendingPathComponent("staging"))
        scan.chatGPTFiles = [.init(url: url, source: .chatgpt, entries: [], latest: nil, order: 0)]
        let s = run(scan, container)
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.conversations.added, 1)
        XCTAssertEqual(s.conversations.ignored, 1)
        XCTAssertEqual(s.warnings.first?.title, "有对话格式读不出来，跳过了")

        let broken = work.appendingPathComponent("broken.json")
        try Data("{\"oops\": 1}".utf8).write(to: broken)
        let claude = try ExportPackageScannerTests.fixtures().appendingPathComponent("gen-a/conversations.json")
        var scan2 = ExportPackageScan(stagingDir: work.appendingPathComponent("staging2"))
        scan2.chatGPTFiles = [.init(url: broken, source: .chatgpt, entries: [], latest: nil, order: 0)]
        scan2.claudeFiles = [.init(url: claude, source: .claude, entries: [], latest: nil, order: 0)]
        let s2 = run(scan2, try makeContainer())
        XCTAssertEqual(s2.failedStep, ImportStage.chatGPT.rawValue)
        XCTAssertEqual(s2.conversations.added, 2, "Claude 照导")
    }

    /// sol #1：扫描也逐条认，坏的一条不让整份变「没认出来」
    func testScanKeepsGoodRowsWhenOneIsBad() throws {
        let zip = work.appendingPathComponent("export.zip")
        try GPT.zip(["conversations.json": try GPT.json([GPT.simple("k1"), ["id": "bad", "mapping": 5]])], to: zip)
        let scan = try ExportPackageScanner.scan([zip], tempRoot: work)
        defer { scan.cleanup() }
        XCTAssertEqual(scan.chatGPTConversationCount, 1)
        XCTAssertTrue(scan.unrecognized.isEmpty)
        let s = run(scan, try makeContainer())
        XCTAssertEqual(s.conversations.added, 1)
        XCTAssertEqual(s.conversations.ignored, 1)
    }

    /// sol #7 #10：附件目录里的 zip 是附件；沙盒输出的 json 也是附件
    func testClassifyVolumesAndSandboxJSON() {
        XCTAssertEqual(ExportPackageScanner.classify("User Online Activity/Conversations__user-x-chatgpt-0001.zip"), .exportVolume)
        XCTAssertEqual(ExportPackageScanner.classify("personal/files/Backup__2026.zip"), .asset)
        XCTAssertNil(ExportPackageScanner.classify("下载/Backup__2026.zip"))
        XCTAssertEqual(ExportPackageScanner.classify("personal/files/a/b/mnt/data/result.json"), .asset)
        XCTAssertEqual(ExportPackageScanner.classify("conversations-003.json"), .conversation)
    }

    /// sol #6：叠加模式下最后没合（包里的比本地旧）的对话不往文件库写
    func testMergeSkippedConversationWritesNoAssets() throws {
        let library = work.appendingPathComponent("library")
        FileLibraryStore.testRootOverride = library
        defer { FileLibraryStore.testRootOverride = nil }
        MainThreadIO.allowMainThreadInThisTest()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
        let user = GPT.Msg(id: "m1-u", role: "user",
                           content: ["content_type": "multimodal_text",
                                     "parts": [["content_type": "image_asset_pointer", "asset_pointer": "file-service://file-abc"]]])
        func scanWith(update: Double) throws -> ExportPackageScan {
            let zip = work.appendingPathComponent("e\(Int(update)).zip")
            try GPT.zip(["conversations.json": try GPT.json([GPT.conversation("m1", messages: [user], update: update)]),
                         "file-abc-photo.png": png], to: zip)
            return try ExportPackageScanner.scan([zip], tempRoot: work)
        }
        let container = try makeContainer()
        let newer = try scanWith(update: 200)
        defer { newer.cleanup() }
        XCTAssertEqual(run(newer, container).conversations.added, 1)
        let attachments = library.appendingPathComponent(pid).appendingPathComponent(AttachmentStore.folderName)
        try FileManager.default.removeItem(at: attachments)

        let older = try scanWith(update: 100)
        defer { older.cleanup() }
        XCTAssertEqual(run(older, container, merge: true).conversations.skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.path), "没合的对话不写文件库")
    }

    /// sol #12：两个来源都失败，完成页两处都列出来
    func testEveryFailureListed() throws {
        let broken = work.appendingPathComponent("broken.json")
        try Data("{\"oops\": 1}".utf8).write(to: broken)
        var scan = ExportPackageScan(stagingDir: work.appendingPathComponent("staging"))
        scan.chatGPTFiles = [.init(url: broken, source: .chatgpt, entries: [], latest: nil, order: 0)]
        scan.claudeFiles = [.init(url: broken, source: .claude, entries: [], latest: nil, order: 0)]
        let s = run(scan, try makeContainer())
        XCTAssertEqual(s.failures.map(\.step), [ImportStage.chatGPT.rawValue, ImportStage.claude.rawValue])
        XCTAssertEqual(s.failedStep, ImportStage.chatGPT.rawValue)
    }

    // MARK: - 升级旧对话（E5）

    /// 旧代码导进来的（思考 / 工具节点正文为空）开叠加再导一次：节点 id 不变，回复带上思考，撤回回到旧样子
    func testMergeUpgradesOldImportAndUndoes() throws {
        let messages = [
            GPT.text("u1", "user", "算一下"),
            GPT.Msg(id: "t1", content: ["content_type": "thoughts", "thoughts": [["summary": "想", "content": "先算"]]]),
            GPT.Msg(id: "c1", content: ["content_type": "code", "language": "python", "text": "1+1"], recipient: "python"),
            GPT.Msg(id: "o1", role: "tool", content: ["content_type": "execution_output", "text": "2"], authorName: "python"),
            GPT.Msg(id: "r1", content: ["content_type": "reasoning_recap", "content": "已思考 3 秒"]),
            GPT.text("a1", "assistant", "等于 2"),
        ]
        let conv = GPT.conversation("m1", messages: messages)
        let url = work.appendingPathComponent("conversations.json")
        try GPT.json([conv]).write(to: url)
        let container = try makeContainer()

        // 模拟旧代码导入：节点、正文都是旧样子（只有 parts 字符串）
        let ctx = ModelContext(container)
        let old = try XCTUnwrap(ChatGPTPayloadBuilder().payload(from: try JSONDecoder().decode(RawConversation.self, from: try GPT.json(conv))))
        ctx.insert(makeImportedConversation(old, profileId: pid))
        for n in old.nodes {
            let legacy = ImportedNodePayload(id: n.id, role: n.role, content: ["u1": "算一下", "a1": "等于 2"][n.id] ?? "",
                                             contentType: n.contentType, createTime: n.createTime,
                                             parentId: n.parentId, childrenIds: n.childrenIds)
            ctx.insert(makeImportedNode(legacy, conversationId: "m1", profileId: pid))
        }
        try ctx.save()
        let idsBefore = Set(try ctx.fetch(FetchDescriptor<MessageNode>()).map(\.id))

        var scan = ExportPackageScan(stagingDir: work.appendingPathComponent("staging"))
        scan.chatGPTFiles = [.init(url: url, source: .chatgpt, entries: [], latest: nil, order: 0)]
        let s = run(scan, container, merge: true)
        XCTAssertEqual(s.conversations.updated, 1)

        let nodes = try ModelContext(container).fetch(FetchDescriptor<MessageNode>())
        XCTAssertEqual(Set(nodes.map(\.id)), idsBefore, "节点一个不多一个不少")
        let a1 = try XCTUnwrap(nodes.first { $0.id == "a1" })
        let segs = try JSONDecoder().decode([MessageSegment].self, from: try XCTUnwrap(a1.segmentsData))
        XCTAssertEqual(segs.count, 4)
        XCTAssertEqual(segs[0], .thinking(text: "想\n\n先算", signature: nil))
        guard case .toolUse(_, "python", let input, _, _) = segs[1] else { return XCTFail("\(segs)") }
        XCTAssertTrue(input.contains("1+1"))
        XCTAssertEqual(segs[2], .toolResult(toolUseId: "", text: "2", isError: false, integrationName: "python"))
        XCTAssertEqual(segs[3], .text("等于 2"))
        XCTAssertEqual(nodes.first { $0.id == "t1" }?.sourceVisibility, "hidden")
        XCTAssertEqual(nodes.first { $0.id == "u1" }?.content, "算一下", "纯文本节点不动")
        XCTAssertNil(nodes.first { $0.id == "u1" }?.segmentsData)

        try undo("chatgpt", container)
        let restored = try ModelContext(container).fetch(FetchDescriptor<MessageNode>())
        XCTAssertNil(restored.first { $0.id == "a1" }?.segmentsData)
        XCTAssertEqual(restored.first { $0.id == "a1" }?.content, "等于 2")
    }
}

// MARK: - 切片

final class JSONArraySlicerTests: XCTestCase {

    private func pieces(_ json: String) -> (parts: [String], error: String?) {
        let data = Data(json.utf8)
        let r = JSONArraySlicer.slice(data)
        return (r.elements.map { String(data: data[$0], encoding: .utf8)! }, r.error)
    }

    func testNestedStringsAndEscapes() {
        let r = pieces(#" [ {"a": "x]}\"y", "b": [1, {"c": "{"}]} , {"d": 2}, 3, "s,]" ] "#)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.parts, [#"{"a": "x]}\"y", "b": [1, {"c": "{"}]}"#, #"{"d": 2}"#, "3", #""s,]""#])
    }

    /// sol #13：包装体没收尾也要报不完整
    func testWrapperTruncatedReportsError() {
        let r = pieces(#"{"conversations": [{"id": 1}]"#)
        XCTAssertEqual(r.parts, [#"{"id": 1}"#])
        XCTAssertNotNil(r.error)
        XCTAssertNil(pieces(#"{"conversations": [{"id": 1}], "tail": {"a": [1]}}"#).error)
    }

    func testWrapperAndEmpty() {
        XCTAssertEqual(pieces(#"{"version": {"x": [1]}, "conversations": [{"id": 1}]}"#).parts, [#"{"id": 1}"#])
        XCTAssertEqual(pieces("[]").parts, [])
        XCTAssertNil(pieces("[]").error)
        XCTAssertNotNil(pieces(#"{"other": []}"#).error)
        XCTAssertNotNil(pieces("").error)
    }

    func testTruncatedKeepsCompleteOnes() {
        let r = pieces(#"[{"id": 1}, {"id": 2}, {"id": "#)
        XCTAssertEqual(r.parts, [#"{"id": 1}"#, #"{"id": 2}"#])
        XCTAssertNotNil(r.error)
    }

    func testBOMSliceIndicesPointIntoData() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bom-\(UUID().uuidString).json")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(#"[{"id": "x"}]"#.utf8)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try JSONArrayFile(url: url)
        XCTAssertEqual(try file.decode([String: String].self, at: 0), ["id": "x"])
    }
}

// MARK: - 转 payload

final class ChatGPTPayloadBuilderTests: XCTestCase {

    private func payload(_ conv: [String: Any], warnings: ImportWarnings? = nil) throws -> ImportedConversationPayload {
        let raw = try JSONDecoder().decode(RawConversation.self, from: try GPT.json(conv))
        return try XCTUnwrap(ChatGPTPayloadBuilder(warnings: warnings).payload(from: raw))
    }

    func testPlainTextUnchangedFromOldCode() throws {
        let p = try payload(GPT.conversation("x", messages: [
            GPT.Msg(id: "u", role: "user", content: ["content_type": "text", "parts": ["一", "二"]]),
            GPT.text("a", "assistant", "好")]))
        let u = try XCTUnwrap(p.nodes.first { $0.id == "u" })
        XCTAssertEqual(u.content, "一\n二")
        XCTAssertNil(u.segmentsData)
        XCTAssertNil(u.sourceVisibility)
        let root = try XCTUnwrap(p.nodes.first { $0.id == "x-root" })
        XCTAssertEqual(root.role, "unknown")
        XCTAssertEqual(root.content, "")
        XCTAssertTrue(p.pendingAssets.isEmpty)
    }

    func testImageOnlyUserMessageStillShows() throws {
        let p = try payload(GPT.conversation("x", messages: [
            GPT.Msg(id: "u", role: "user", content: ["content_type": "multimodal_text", "parts": [
                ["content_type": "image_asset_pointer", "asset_pointer": "file-service://file-q"]]])]))
        let u = try XCTUnwrap(p.nodes.first { $0.id == "u" })
        XCTAssertFalse(u.content.isEmpty)
        XCTAssertTrue(isDisplayableNode(role: u.role, content: u.content))
    }

    func testHiddenAndToolCallNodes() throws {
        let p = try payload(GPT.conversation("x", messages: [
            GPT.Msg(id: "s", role: "system", content: ["content_type": "text", "parts": [""]]),
            GPT.Msg(id: "ctx", role: "user", content: ["content_type": "user_editable_context", "user_profile": "我是禾禾"],
                    metadata: ["is_visually_hidden_from_conversation": true]),
            GPT.text("u", "user", "记住这个"),
            GPT.Msg(id: "bio", content: ["content_type": "text", "parts": ["用户叫禾禾"]], recipient: "bio"),
            GPT.Msg(id: "bio-r", role: "tool", content: ["content_type": "text", "parts": ["Model set context updated."]], authorName: "bio"),
            GPT.text("a", "assistant", "记住了")]))
        let byId = Dictionary(uniqueKeysWithValues: p.nodes.map { ($0.id, $0) })
        XCTAssertEqual(byId["ctx"]?.sourceVisibility, "hidden")
        XCTAssertEqual(byId["bio"]?.sourceVisibility, "hidden")
        XCTAssertEqual(byId["bio"]?.content, "")
        let segs = try JSONDecoder().decode([MessageSegment].self, from: try XCTUnwrap(byId["a"]?.segmentsData))
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs.last, .text("记住了"))
    }

    func testMissingIdAndTimesFallBack() throws {
        let w = ImportWarnings()
        var conv = GPT.conversation(nil, messages: [GPT.text("u", "user", "hi")], create: nil, update: nil)
        let a = try payload(conv, warnings: w)
        XCTAssertEqual(a.id, try payload(conv).id, "同样内容同样 id，再导不重复")
        XCTAssertTrue(a.id.hasSuffix("@chatgpt"))
        XCTAssertEqual(a.createTime, Date(timeIntervalSince1970: 1_700_000_010), "用消息时间")
        conv["conversation_id"] = "cid"
        XCTAssertEqual(try payload(conv).id, "cid")
        XCTAssertEqual(w.groups.map(\.title), ["对话缺 id，按内容算了一个"])
    }

    // MARK: - sol 审查补的

    private func segs(_ p: ImportedConversationPayload, _ id: String) throws -> [MessageSegment] {
        try JSONDecoder().decode([MessageSegment].self, from: try XCTUnwrap(p.nodes.first { $0.id == id }?.segmentsData))
    }

    /// sol #2：content 本身就是图片指针
    func testTopLevelImagePointer() throws {
        let p = try payload(GPT.conversation("x", messages: [
            GPT.text("u", "user", "画只猫"),
            GPT.Msg(id: "g", role: "tool", content: ["content_type": "image_asset_pointer", "asset_pointer": "sediment://file_gen1"],
                    authorName: "dalle.text2im"),
            GPT.text("a", "assistant", "画好了")]))
        let a = try segs(p, "a")
        XCTAssertEqual(a.first, .file(name: "生成的图片", uuid: "file_gen1"))
        XCTAssertEqual(a.last, .text("画好了"))
    }

    /// sol #3：用户插话不吃前一轮的思考 / 工具；那一轮落在自己的助手节点上
    func testUserInterruptionDoesNotAbsorb() throws {
        let p = try payload(GPT.conversation("x", messages: [
            GPT.text("u1", "user", "查一下"),
            GPT.Msg(id: "t", content: ["content_type": "thoughts", "thoughts": [["summary": "想", "content": "先搜"]]]),
            GPT.Msg(id: "c", content: ["content_type": "text", "parts": ["q"]], recipient: "web.run"),
            GPT.Msg(id: "r", role: "tool", content: ["content_type": "text", "parts": ["结果"]], authorName: "web.run"),
            GPT.text("u2", "user", "停，换个问题")]))
        let byId = Dictionary(uniqueKeysWithValues: p.nodes.map { ($0.id, $0) })
        XCTAssertNil(byId["u2"]?.segmentsData)
        XCTAssertEqual(byId["u2"]?.content, "停，换个问题")
        XCTAssertNil(byId["c"]?.sourceVisibility, "落点：链里最下面的助手节点")
        XCTAssertEqual(try segs(p, "c").count, 3)
        XCTAssertTrue(isDisplayableNode(role: "assistant", content: byId["c"]?.content ?? ""))
        XCTAssertEqual(byId["t"]?.sourceVisibility, "hidden")
        XCTAssertEqual(byId["r"]?.sourceVisibility, "hidden")
    }

    /// sol #4：停在工具结果（current_node 是 tool）也看得见
    func testChainEndingAtToolResultHasLanding() throws {
        let p = try payload(GPT.conversation("x", messages: [
            GPT.text("u", "user", "算"),
            GPT.Msg(id: "c", content: ["content_type": "code", "text": "1+1"], recipient: "python"),
            GPT.Msg(id: "o", role: "tool", content: ["content_type": "execution_output", "text": "2"], authorName: "python")]))
        XCTAssertEqual(p.currentNodeId, "o")
        let c = try XCTUnwrap(p.nodes.first { $0.id == "c" })
        XCTAssertNil(c.sourceVisibility)
        XCTAssertEqual(try segs(p, "c").count, 2)
    }

    /// sol #5：两张生成图、分卷里只有一个文件 → 都放占位，不配错
    func testTwoGenerationsOneFileStaysPlaceholder() throws {
        var assets = ChatGPTAssetIndex()
        assets.add(ImportAssetRef(location: .file(URL(fileURLWithPath: "/tmp/a.webp")), fileName: "a.webp", size: 1),
                   path: "personal/dallelabs/u/chatgptgenerations/u/conversations/x/a.webp")
        let raw = try JSONDecoder().decode(RawConversation.self, from: try GPT.json(GPT.conversation("x", messages: [
            GPT.Msg(id: "g1", role: "tool", content: ["content_type": "image_asset_pointer", "asset_pointer": "sediment://file_1"]),
            GPT.Msg(id: "g2", role: "tool", content: ["content_type": "image_asset_pointer", "asset_pointer": "sediment://file_2"]),
            GPT.text("a", "assistant", "两张")])))
        XCTAssertTrue(try XCTUnwrap(ChatGPTPayloadBuilder(assets: assets).payload(from: raw)).pendingAssets.isEmpty)
        let one = try JSONDecoder().decode(RawConversation.self, from: try GPT.json(GPT.conversation("x", messages: [
            GPT.Msg(id: "g1", role: "tool", content: ["content_type": "image_asset_pointer", "asset_pointer": "sediment://file_1"]),
            GPT.text("a", "assistant", "一张")])))
        XCTAssertEqual(try XCTUnwrap(ChatGPTPayloadBuilder(assets: assets).payload(from: one)).pendingAssets.keys.sorted(), ["file_1"])
    }

    /// Dex3：同样的分段、键序不同的字节，不算改过
    func testSegmentsCompareByContent() throws {
        let segs: [MessageSegment] = [.thinking(text: "想", signature: nil), .toolUse(id: "1", name: "python", inputJSON: "{}",
                                                                                      integrationName: nil, iconName: nil)]
        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys
        let a = try sorted.encode(segs)
        let b = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: a), options: [])
        XCTAssertFalse(segmentsDiffer(a, b))
        XCTAssertTrue(segmentsDiffer(a, try sorted.encode([MessageSegment.text("别的")])))
        XCTAssertTrue(segmentsDiffer(a, nil))
        XCTAssertFalse(segmentsDiffer(nil, nil))
    }

    /// sol #11：缺 id 时内容不同 → id 不同
    func testMissingIdHashCoversContent() throws {
        let a = try payload(GPT.conversation(nil, messages: [GPT.text("u", "user", "甲")]))
        let b = try payload(GPT.conversation(nil, messages: [GPT.text("u", "user", "乙")]))
        XCTAssertNotEqual(a.id, b.id)
    }

    func testCycleAndOrphanRepaired() throws {
        let w = ImportWarnings()
        let mapping: [String: Any] = [
            "r": ["id": "r", "message": NSNull(), "parent": NSNull(), "children": ["a", "ghost"]],
            "a": ["id": "a", "message": ["id": "a", "author": ["role": "user"], "content": ["content_type": "text", "parts": ["a"]], "create_time": 1],
                  "parent": "r", "children": ["b"]],
            "b": ["id": "b", "message": ["id": "b", "author": ["role": "assistant"], "content": ["content_type": "text", "parts": ["b"]], "create_time": 2],
                  "parent": "a", "children": []],
            "o": ["id": "o", "message": ["id": "o", "author": ["role": "user"], "content": ["content_type": "text", "parts": ["孤儿"]]],
                  "parent": "missing", "children": []],
            "c1": ["id": "c1", "message": NSNull(), "parent": "c2", "children": ["c2"]],
            "c2": ["id": "c2", "message": NSNull(), "parent": "c1", "children": ["c1"]],
        ]
        let p = try payload(["id": "t", "title": "环", "current_node": "nope", "create_time": 1, "update_time": 2,
                             "mapping": mapping], warnings: w)
        let roots = p.nodes.filter { $0.parentId == nil }
        XCTAssertEqual(roots.map(\.id), ["t#root"])
        XCTAssertTrue(roots[0].isSyntheticRoot)
        XCTAssertFalse(p.nodes.first { $0.id == "r" }!.childrenIds.contains("ghost"))
        XCTAssertEqual(p.currentNodeId, "b")
        XCTAssertEqual(Set(w.groups.map(\.title)), ["对话树断了或成环，已接回根下", "对话缺当前分支，取了最新的一支"])
    }
}
