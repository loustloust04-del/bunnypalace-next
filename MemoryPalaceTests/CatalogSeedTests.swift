import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class CatalogSeedTests: XCTestCase {
    private let pid = "xctest-catalog-seed"
    private var root: URL!
    private var container: ModelContainer!
    private var wiki: WikiStore { WikiStore(root: root.appendingPathComponent("wiki")) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-seed-\(UUID().uuidString)")
        container = try ModelContainer(for: Memory.self, Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        container = nil
    }

    private func raw(_ header: String = "type: user", body: String = "喜欢科幻电影") -> String {
        "---\n\(header)\n---\n\(body)"
    }

    private func put(_ name: String, _ text: String) throws {
        let dir = root.appendingPathComponent("cc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testEveryTypeIsReadAndTypeIsOnlyDisplayed() throws {
        for (header, expected) in [
            ("type: user", "user"), ("type: 'project' # 来源", "project"), ("type: feedback", "feedback"),
            ("type: reference", "reference"), ("metadata:\n  type: Feedback", "feedback"), ("metadata.type: project", "project"),
            ("name: 未分类", "未标注"), ("type: [user]", "未标注"), ("type: user\ntype: feedback", "user")
        ] {
            let source = try CatalogSeed.read(name: "test.md", text: CCMemorySync.wrap(raw(header), at: Date()))
            XCTAssertEqual(source.type, expected, header)
            XCTAssertEqual(source.body, "喜欢科幻电影", header)
        }
        XCTAssertThrowsError(try CatalogSeed.read(name: "test.md", text: raw(body: " \n"))) {
            XCTAssertEqual($0 as? CatalogSeed.Skip, .empty)
        }
        XCTAssertThrowsError(try CatalogSeed.read(name: "test.md", text: "---\ntype: user\n---\n")) {
            XCTAssertEqual($0 as? CatalogSeed.Skip, .empty)
        }
    }

    func testFilesWithoutFrontmatterAreReadWhole() throws {
        let plain = try CatalogSeed.read(name: "岚舟.md", text: "# 岚舟\n岚舟喜欢在雨天写信。")
        XCTAssertEqual(plain.type, "未标注")
        XCTAssertEqual(plain.title, "岚舟")
        XCTAssertEqual(plain.body, "# 岚舟\n岚舟喜欢在雨天写信。")
        let untitled = try CatalogSeed.read(name: "星砚笔记.md", text: "星砚每周三去旧书市。")
        XCTAssertEqual(untitled.title, "星砚笔记", "标题取不到用文件名")
        XCTAssertEqual(untitled.body, "星砚每周三去旧书市。")
        for text in ["type: user\n正文", "---\ntype: user\n  ---\n正文", "---\ntype: user\ndescription: |\n  ---\n  正文"] {
            let source = try CatalogSeed.read(name: "note.md", text: text)
            XCTAssertEqual(source.body, text, "frontmatter 没闭合 = 没有 frontmatter，整份是正文")
            XCTAssertEqual(source.type, "未标注")
        }
        let indented = try CatalogSeed.read(name: "note.md", text: raw("description: |\n  ---\ntype: user", body: "实际正文"))
        XCTAssertEqual(indented.body, "实际正文", "缩进的 --- 不结束 frontmatter")
        XCTAssertEqual(indented.type, "user")
        XCTAssertEqual(try CatalogSeed.read(name: "note.md", text: "---  \ntype: user\n--- \t\n正文").body, "正文")
    }

    func testDashLinesThatAreNotMetadataKeepTheBody() throws {
        for text in [
            "---\n# 阿青\n阿青住在云桥城。\n---\n",
            "---\n# 阿青\n阿青住在云桥城。\n---\n后半段也在",
            "---\n- 买纸\n- 写信\n---\n正文",
            "---\n星砚说：明天见\n---\n正文",
            "---\nhttps://example.invalid/a\n---\n正文",
            "---\n阿青: 明天见。\n- 记得带书\n---",
            "---\n阿青: 明天见。\n  记得带书\n---\n正文",
            "---\n# 只有注释\n---\n正文",
        ] {
            let source = try CatalogSeed.read(name: "note.md", text: text)
            XCTAssertEqual(source.body, text.trimmingCharacters(in: .whitespacesAndNewlines), "认不出是元数据：整份保留")
            XCTAssertEqual(source.type, "未标注")
        }
        for text in [
            "---\nname: 岚舟\ntags:\n- 信\nmetadata:\n  type: user\n\n---\n正文",
            "---\n# 来源说明\nname: 岚舟\ntype: user\n---\n正文",
            "---\nname: 岚舟 # 行尾注释\ndescription: |\n  - 不是列表\n  # 也不是注释\n# 独立注释\nmetadata:\n  # 注释\n  type: user\n---\n正文",
        ] {
            let meta = try CatalogSeed.read(name: "note.md", text: text)
            XCTAssertEqual(meta.body, "正文", text)
            XCTAssertEqual(meta.title, "岚舟", text)
            XCTAssertEqual(meta.type, "user", text)
        }
    }

    func testFileSwappedToLinkJustBeforeReadIsNotFollowed() throws {
        try put("a.md", raw(body: "岚舟的正文"))
        try put("private_x.md", raw(body: "PRIVATE_BODY_MARKER"))
        let cc = root.appendingPathComponent("cc")
        let scan = try CatalogSeed.load(memoryRoot: root) { url in
            if url.lastPathComponent == "a.md" {   // 列名字、查属性时还是普通文件，读之前一刻换成指向私人文件的链接
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: cc.appendingPathComponent("private_x.md"))
            }
            return try CCMemorySync.readNoFollow(url)
        }
        XCTAssertEqual(scan.sources, [])
        XCTAssertEqual(scan.skipped, ["a.md · 不是可读的普通 Markdown 文件", "跳过 1 份私人文件（private_）"])
        XCTAssertFalse((scan.notes + scan.skipped).joined().contains("PRIVATE_BODY_MARKER"))
    }

    func testPrivateIsSkippedButDiaryWordingIsRead() throws {
        for name in ["private_x.md", "PRIVATE_y.md", "Private_z.md"] {
            XCTAssertThrowsError(try CatalogSeed.read(name: name, text: raw())) {
                XCTAssertEqual($0 as? CatalogSeed.Skip, .privateFile)
            }
        }
        for name in ["project_private_x.md", "note_private_y.md", "note_PRIVATE_z.md"] {
            XCTAssertEqual(try CatalogSeed.read(name: name, text: raw()).body, "喜欢科幻电影", "中间带 private_ 的是普通文件：\(name)")
        }
        for (name, text) in [
            ("日记.md", raw()), ("DIARY.md", raw()),
            ("note.md", raw("type: user\nname: 日记片段")),
            ("note.md", raw("type: project\ndescription: |\n  Personal DIARY")),
            ("note.md", raw(body: "# 岚舟钥匙存日记本\n普通正文")),
            ("note.md", raw("type: feedback", body: "# 星砚的日记习惯\n星砚每晚睡前写日记"))
        ] {
            XCTAssertFalse(try CatalogSeed.read(name: name, text: text).body.isEmpty, "\(name) \(text)")
        }
    }

    func testTokenBudgetAndAPIKeyConfigurationAreReadableAndLoadable() throws {
        let body = "token 预算与 API key 配置\npassword / secret / 密钥 / 密码 / 令牌 / 口令是术语说明"
        let source = try CatalogSeed.read(name: "note_KEY.md", text: raw(body: body))
        XCTAssertEqual(source.type, "user")
        XCTAssertEqual(source.body, body)
        try put("note_KEY.md", raw(body: body))
        let scan = try CatalogSeed.load(memoryRoot: root)
        XCTAssertEqual(scan.sources, [source])
        XCTAssertEqual(scan.skipped, [])
    }

    func testATXHeadingSyntaxPreservesCodeIndentation() throws {
        for body in ["    # 日记", "\n    # DIARY\n", "#日记", "## 日记", "\t# 日记"] {
            let source = try CatalogSeed.read(name: "note.md", text: raw(body: body))
            XCTAssertEqual(source.title, "note", body)
        }
        XCTAssertEqual(try CatalogSeed.read(name: "note.md", text: raw(body: "   # 电影 ###  \n正文")).title, "电影")
        XCTAssertEqual(try CatalogSeed.read(name: "note.md", text: raw(body: "# 电影###")).title, "电影###")
        XCTAssertEqual(try CatalogSeed.read(name: "note.md", text: raw(body: "#\n正文")).title, "")
    }

    func testInvalidCCDirectoriesAreNotEnumerated() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let cc = root.appendingPathComponent("cc")
        try raw().write(to: cc, atomically: true, encoding: .utf8)
        var scan = try CatalogSeed.load(memoryRoot: root)
        XCTAssertEqual(scan.sources, [])
        XCTAssertEqual(scan.skipped, ["cc · 不是可读的普通 Markdown 文件"])
        try fm.removeItem(at: cc)
        let inside = root.appendingPathComponent("inside")
        let outside = fm.temporaryDirectory.appendingPathComponent("catalog-seed-outside-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: outside) }
        for destination in [inside, outside] {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try raw().write(to: destination.appendingPathComponent("source.md"), atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(at: cc, withDestinationURL: destination)
            scan = try CatalogSeed.load(memoryRoot: root)
            XCTAssertEqual(scan.sources, [])
            XCTAssertEqual(scan.skipped, ["cc · 不是可读的普通 Markdown 文件"])
            try fm.removeItem(at: cc)
        }
        try fm.createSymbolicLink(at: cc, withDestinationURL: root.appendingPathComponent("missing"))
        scan = try CatalogSeed.load(memoryRoot: root)
        XCTAssertEqual(scan.sources, [])
        XCTAssertEqual(scan.skipped, ["cc · 不是可读的普通 Markdown 文件"])
    }

    func testUnreadablePrivateFilesAreCountedBeforeOpening() throws {
        let names = ["private_x.md", "PRIVATE_y.MD", "Private_z.md"]
        for (index, name) in names.enumerated() {
            try put(name, raw(body: "PRIVATE_BODY_MARKER"))
            let file = root.appendingPathComponent("cc").appendingPathComponent(name)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            XCTAssertThrowsError(try String(contentsOf: file, encoding: .utf8))

            let scan = try CatalogSeed.load(memoryRoot: root)
            let summary = "跳过 \(index + 1) 份私人文件（private_）"
            XCTAssertEqual(scan.sources, [])
            XCTAssertEqual(scan.skipped, [summary])
            XCTAssertEqual(scan.notes, [summary])
        }
    }

    func testPrivateFilesAreNeverOpened() throws {
        try put("feedback_岚舟.md", raw("type: feedback", body: "岚舟说回答先给结论，因为她赶时间"))
        try put("private_星砚.md", raw(body: "PRIVATE_BODY_MARKER"))
        try put("Private_y.md", raw(body: "PRIVATE_BODY_MARKER"))
        try put("project_private_repo.md", raw("type: project", body: "岚舟的项目放在私有仓库里"))
        var opened: [String] = []
        let scan = try CatalogSeed.load(memoryRoot: root) { url in
            opened.append(url.lastPathComponent)
            if url.lastPathComponent.lowercased().hasPrefix("private_") { throw CocoaError(.fileReadNoPermission) }
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(opened, ["feedback_岚舟.md", "project_private_repo.md"], "private_ 开头的根本不打开，中间带 private_ 的照读")
        XCTAssertEqual(scan.sources.map(\.name), ["feedback_岚舟.md", "project_private_repo.md"])
        XCTAssertEqual(scan.skipped, ["跳过 2 份私人文件（private_）"])
    }

    func testMarkdownEntriesAndSkippedReasonsAreSafe() throws {
        try put("okay.md", raw())
        try put("private_x.md", raw(body: "PRIVATE_BODY_MARKER"))
        try put("diary.md", raw(body: "岚舟的钥匙存在日记本里"))
        try put("feedback.md", raw("type: feedback", body: "星砚不喝咖啡"))
        try put("reference.md", raw("type: reference", body: "星砚的书单"))
        try put("plain.md", "岚舟住在七楼")
        try put("empty.md", raw(body: " \n"))
        try put("unclosed.md", "---\ntype: user\n  ---\n岚舟养了一只猫")
        let cc = root.appendingPathComponent("cc")
        let target = root.appendingPathComponent("target.md")
        try raw(body: "LINK_BODY_MARKER").write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: cc.appendingPathComponent("link.md"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: cc.appendingPathComponent("missing.md"), withDestinationURL: root.appendingPathComponent("missing"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-seed-source-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try raw(body: "OUTSIDE_BODY_MARKER").write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: cc.appendingPathComponent("outside.md"), withDestinationURL: outside)
        try put("private_line\nbreak.md", raw(body: "PRIVATE_BODY_MARKER"))
        try FileManager.default.createDirectory(at: cc.appendingPathComponent("directory.md"), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0xFF]).write(to: cc.appendingPathComponent("invalid.md"))
        let scan = try CatalogSeed.load(memoryRoot: root)
        XCTAssertEqual(scan.sources.map(\.name), ["diary.md", "feedback.md", "okay.md", "plain.md", "reference.md", "unclosed.md"])
        XCTAssertEqual(scan.sources.map(\.type), ["user", "feedback", "user", "未标注", "reference", "未标注"])
        XCTAssertEqual(scan.skipped, [
            "directory.md · 不是可读的普通 Markdown 文件",
            "empty.md · 正文为空",
            "invalid.md · 不是可读的普通 Markdown 文件",
            "link.md · 不是可读的普通 Markdown 文件",
            "missing.md · 不是可读的普通 Markdown 文件",
            "outside.md · 不是可读的普通 Markdown 文件",
            "跳过 2 份私人文件（private_）"
        ])
        let report = (scan.notes + scan.skipped).joined(separator: "\n")
        XCTAssertFalse(report.contains("_BODY_MARKER"))
        XCTAssertFalse(report.contains(root.path))
        XCTAssertFalse(report.contains("private_x.md"))
        XCTAssertFalse(report.contains("private_line"))
    }

}
