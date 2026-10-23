import XCTest
@testable import 记忆花园

/// #049：用两代官方 Kelivo（v1.1.17 / v1.3.1，macOS）真导出的备份对数。
/// 样本是同一份合成数据：v1.1.17 导入后导出旧格式，再装 v1.3.1 让它自己迁移后导出新格式——所以两边解析出来应当一模一样。
/// 真包只在 `~/.mp-merge-queue/artifacts/kelivo-049/exports/`（不进仓库），没有就跳过。
final class KelivoRealSampleTests: XCTestCase {

    /// 测试宿主可能把 HOME 改道到临时家（#035），真家目录从账户记录取
    private let exports = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        .appendingPathComponent(".mp-merge-queue/artifacts/kelivo-049/exports")
    /// 导出那台 Mac 的时区（旧版时间不带时区，Kelivo 按本机解）
    private let exportTimeZone = TimeZone(identifier: "America/Los_Angeles")!
    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kelivo-real-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    /// 用我们自己的解包器解（两代 local header 都带 data descriptor，顺便验它）
    private func extract(_ name: String) throws -> (URL, Set<String>) {
        let zip = exports.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: zip.path) else { throw XCTSkip("没有真样本 \(name)") }
        let dir = work.appendingPathComponent(name)
        try TwitterZipExtractor.extract(zip, to: dir, budget: ZipExtractBudget(ExportPackageScanner.limits))
        var members = Set<String>()
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        for case let url as URL in e where !url.hasDirectoryPath {
            members.insert(url.pathComponents.suffix(e.level).joined(separator: "/"))
        }
        return (dir, members)
    }

    private func payloads(_ conversations: [KelivoBackup.Conversation], members: Set<String>) -> [ImportedConversationPayload] {
        var stats = KelivoPayloadBuilder.Stats()
        return conversations.compactMap { KelivoPayloadBuilder.payload($0, format: "real", members: members, stats: &stats) }
            .sorted { $0.id < $1.id }
    }

    func testBothGenerationsOfSameDataMatch() throws {
        let (oldDir, oldMembers) = try extract("kelivo_v1.1.17_export.zip")
        let (newDir, newMembers) = try extract("kelivo_v1.3.1_export.zip")

        XCTAssertTrue(KelivoBackup.isLegacyChats(try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: oldDir.appendingPathComponent("chats.json"))))))
        let legacy = try KelivoLegacyParser.parse(data: Data(contentsOf: oldDir.appendingPathComponent("chats.json")),
                                                  timeZone: exportTimeZone)
        XCTAssertEqual(legacy.counts.danglingIds + legacy.counts.duplicateReferences + legacy.counts.unreferencedMessages, 0)

        let manifest = try KelivoDatabaseReader.manifest(data: Data(contentsOf: newDir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.formatVersion, 3)
        XCTAssertEqual(manifest.appVersion, "1.3.1+80")
        let db = newDir.appendingPathComponent(manifest.databaseEntry)
        try KelivoDatabaseReader.verify(database: db, against: manifest)
        var modern: [KelivoBackup.Conversation] = []
        let summary = try KelivoDatabaseReader.read(database: db) { modern.append($0) }
        XCTAssertEqual(summary.schemaVersion, 3)
        XCTAssertEqual(summary.conversationCount, manifest.conversationCount)

        let a = payloads(legacy.conversations, members: oldMembers)
        let b = payloads(modern, members: newMembers)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.title, y.title)
            XCTAssertEqual(x.createTime, y.createTime, x.id)
            XCTAssertEqual(x.updateTime, y.updateTime, x.id)
            XCTAssertEqual(x.currentNodeId, y.currentNodeId, x.id)
            XCTAssertEqual(x.branchSelectionData, y.branchSelectionData, x.id)
            XCTAssertEqual(x.nodes.map(\.id), y.nodes.map(\.id), x.id)
            for (n, m) in zip(x.nodes, y.nodes) {
                XCTAssertEqual(n.role, m.role, n.id)
                XCTAssertEqual(n.parentId, m.parentId, n.id)
                XCTAssertEqual(n.childrenIds, m.childrenIds, n.id)
                XCTAssertEqual(n.createTime, m.createTime, n.id)
                XCTAssertEqual(try decode(n), try decode(m), n.id)
            }
        }

        // 抽查几处：图片在包里、重新生成选第 2 版、代码块里的标记不当附件、包里没有的文件是占位
        let c1 = try XCTUnwrap(b.first { $0.id == "seed-c1@kelivo" })
        XCTAssertEqual(try decode(XCTUnwrap(c1.nodes.first { $0.id.hasSuffix("/s1-u1") })).last,
                       .file(name: "seed-cat.png", uuid: "kelivo-asset:upload/seed-cat.png"))
        XCTAssertEqual(c1.nodes.first { $0.id.hasSuffix("/s1-a1b") }?.childrenIds, ["seed-c1@kelivo/s1-u2"])
        XCTAssertEqual(c1.currentNodeId, "seed-c1@kelivo/s1-a2")
        let c2 = try XCTUnwrap(b.first { $0.id == "seed-c2@kelivo" })
        XCTAssertEqual(try decode(XCTUnwrap(c2.nodes.first { $0.id.hasSuffix("/s2-u1") })).last, .file(name: "行程.pdf", uuid: ""))
    }

    /// 合成根没有分段
    private func decode(_ node: ImportedNodePayload) throws -> [MessageSegment] {
        guard let data = node.segmentsData else { return [] }
        return try JSONDecoder().decode([MessageSegment].self, from: data)
    }
}
