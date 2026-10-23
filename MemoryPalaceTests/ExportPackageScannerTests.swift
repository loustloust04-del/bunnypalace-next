import XCTest
import ZIPFoundation
@testable import 记忆花园

/// #043：导出包扫描。夹具 fixtures/claude-export（scripts/make-claude-export-fixtures.py 生成，内容全是编的）。
final class ExportPackageScannerTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("export-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    static func fixtures() throws -> URL {
        try XCTUnwrap(Bundle(for: ExportPackageScannerTests.self).url(forResource: "claude-export", withExtension: nil))
    }

    /// 把一个目录打成 zip（条目路径相对目录）
    static func zip(_ dir: URL, to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        let base = dir.standardized.path + "/"
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in e where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let rel = String(file.standardized.path.dropFirst(base.count))
            let data = try Data(contentsOf: file)
            try archive.addEntry(with: rel, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
    }

    static let categories = ["conversations", "projects", "memories", "frames", "design_chats", "feedback", "light_metadata"]

    /// 新版 7 个分类包（照真包命名 `<类别>-000.zip`）
    private func genCZips(_ only: [String] = categories) throws -> [URL] {
        let root = try Self.fixtures().appendingPathComponent("gen-c")
        return try only.map { cat in
            let url = work.appendingPathComponent("\(cat)-000.zip")
            if !FileManager.default.fileExists(atPath: url.path) {
                try Self.zip(root.appendingPathComponent("\(cat)-000"), to: url)
            }
            return url
        }
    }

    private func scan(_ urls: [URL]) throws -> ExportPackageScan {
        try ExportPackageScanner.scan(urls, tempRoot: work)
    }

    // MARK: - 三代 Claude

    func testGenAFolder() throws {
        let s = try scan([try Self.fixtures().appendingPathComponent("gen-a")])
        XCTAssertEqual(s.claudeFiles.count, 1)
        XCTAssertEqual(s.claudeFiles[0].entries.map(\.id), ["a1", "a2", "a-empty"])
        XCTAssertEqual(s.projectFiles.count, 1)
        XCTAssertEqual(s.memoryFiles.count, 1)
        XCTAssertEqual(s.ignoredLabels, ["账号信息"])
        XCTAssertTrue(s.unrecognized.isEmpty)
    }

    func testGenAZip() throws {
        let zip = work.appendingPathComponent("data-2026-02-17-batch-0000.zip")
        try Self.zip(try Self.fixtures().appendingPathComponent("gen-a"), to: zip)
        let s = try scan([zip])
        XCTAssertEqual(s.claudeConversationCount, 3)
        XCTAssertEqual(s.projectFiles.count, 1)
        XCTAssertEqual(s.memoryFiles.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.stagingDir.appendingPathComponent("000/users.json").path),
                       "账号信息不落盘")
    }

    func testGenBFolder() throws {
        let s = try scan([try Self.fixtures().appendingPathComponent("gen-b")])
        XCTAssertEqual(s.claudeFiles.count, 1)
        XCTAssertEqual(s.projectFiles.count, 1)
        XCTAssertEqual(s.designChatFiles.count, 1)
        XCTAssertEqual(s.memoryFiles.count, 1)
    }

    func testGenCSevenZipsWithManifest() throws {
        let manifest = try Self.fixtures().appendingPathComponent("gen-c/manifest-test.json")
        let s = try scan(try genCZips() + [manifest])
        XCTAssertEqual(s.claudeFiles.count, 1, "artifact 子树里的 conversations.json 不能当对话")
        XCTAssertEqual(s.claudeFiles[0].entries.map(\.id), ["c1"])
        XCTAssertEqual(s.designChatFiles.count, 1)
        XCTAssertEqual(s.projectFiles.count, 1)
        XCTAssertEqual(s.memoryFiles.count, 1)
        XCTAssertEqual(s.artifactDirs.map(\.lastPathComponent), ["art1", "art2"])
        XCTAssertEqual(s.manifestFiles.count, 1)
        XCTAssertEqual(Set(s.ignoredLabels), ["月度回顾", "账号信息", "登录记录"])
        XCTAssertTrue(s.missingFromManifest.isEmpty)
        XCTAssertTrue(s.unrecognized.isEmpty, "\(s.unrecognized)")
    }

    func testManifestReportsMissingPackages() throws {
        let manifest = try Self.fixtures().appendingPathComponent("gen-c/manifest-test.json")
        let s = try scan(try genCZips(["conversations"]) + [manifest])
        XCTAssertEqual(Set(s.missingFromManifest),
                       ["projects-000.zip", "memories-000.zip", "frames-000.zip", "design_chats-000.zip"],
                       "回顾 / 账号信息本来就不导，缺了不提示")
    }

    func testGenCExtractedFolder() throws {
        let s = try scan([try Self.fixtures().appendingPathComponent("gen-c")])
        XCTAssertEqual(s.claudeFiles.count, 1)
        XCTAssertEqual(s.artifactDirs.count, 2)
        XCTAssertEqual(s.designChatFiles.count, 1)
        XCTAssertEqual(s.manifestFiles.count, 1)
    }

    func testFolderHoldingZips() throws {
        let dir = work.appendingPathComponent("下载目录")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for zip in try genCZips() {
            try FileManager.default.copyItem(at: zip, to: dir.appendingPathComponent(zip.lastPathComponent))
        }
        let s = try scan([dir])
        XCTAssertEqual(s.claudeFiles.count, 1)
        XCTAssertEqual(s.artifactDirs.count, 2)
        XCTAssertEqual(s.projectFiles.count, 1)
        for artifact in s.artifactDirs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("artifact.json").path),
                          "artifact 目录要指到真解出来的位置：\(artifact.path)")
        }
        let plan = ClaudeLibraryImporter.plan(projects: [], memoryFiles: [], artifactDirs: s.artifactDirs)
        XCTAssertEqual(plan.writes.first { $0.relPath.hasSuffix("小页面.html") }?.content, "<p>当前版</p>")
    }

    func testChatGPTWithoutIdStillCounted() throws {
        let url = work.appendingPathComponent("conversations.json")
        try Data(#"[{"conversation_id":"x","title":"t","mapping":{}}]"#.utf8).write(to: url)
        let s = try scan([url])
        XCTAssertEqual(s.chatGPTConversationCount, 1)
        XCTAssertTrue(s.emptyFiles.isEmpty)
    }

    func testDirectOldMemoryRows() throws {
        let url = work.appendingPathComponent("memories.json")
        try Data(#"[{"uuid":"m1","content":"喜欢猫"}]"#.utf8).write(to: url)
        XCTAssertEqual(try scan([url]).memoryFiles.count, 1)
    }

    func testZip64OffsetZero() throws {
        let s = try scan([try Self.fixtures().appendingPathComponent("zip64/conversations-000.zip")])
        XCTAssertEqual(s.claudeFiles.first?.entries.map(\.id), ["z1"])
    }

    // MARK: - ChatGPT / 直接选 json

    func testChatGPTZip() throws {
        let zip = work.appendingPathComponent("chatgpt-export.zip")
        try Self.zip(try Self.fixtures().appendingPathComponent("chatgpt"), to: zip)
        let s = try scan([zip])
        XCTAssertEqual(s.chatGPTFiles.count, 1)
        XCTAssertEqual(s.chatGPTFiles[0].entries.map(\.id), ["g1"])
        XCTAssertTrue(s.claudeFiles.isEmpty)
        XCTAssertEqual(s.ignoredLabels, ["账号信息"])
        XCTAssertTrue(s.unrecognized.isEmpty, "chat.html 不提示")
    }

    func testRenamedJSONRecognizedByContent() throws {
        let renamed = work.appendingPathComponent("我的导出")
        try FileManager.default.copyItem(at: try Self.fixtures().appendingPathComponent("gen-a/conversations.json"), to: renamed)
        XCTAssertEqual(try scan([renamed]).claudeConversationCount, 3)
    }

    func testBOMStripped() throws {
        let url = work.appendingPathComponent("conversations.json")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(try Data(contentsOf: try Self.fixtures().appendingPathComponent("chatgpt/conversations.json")))
        try data.write(to: url)
        XCTAssertEqual(try scan([url]).chatGPTConversationCount, 1)
    }

    func testUnrecognizedAndEmpty() throws {
        let junk = work.appendingPathComponent("random.json")
        try Data(#"{"foo": 1}"#.utf8).write(to: junk)
        let dir = work.appendingPathComponent("空包")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: dir.appendingPathComponent("conversations.json"))
        let s = try scan([junk, dir])
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.unrecognized, ["random.json"])
        XCTAssertEqual(s.emptyFiles, ["conversations.json"])
    }

    func testMixedOldAndNewOrdersOldFirst() throws {
        let f = try Self.fixtures()
        let s = try scan([f.appendingPathComponent("gen-b"), f.appendingPathComponent("gen-a")])
        XCTAssertEqual(s.claudeFiles.count, 2)
        XCTAssertEqual(s.claudeFiles.first?.entries.first?.id, "a1", "gen-a 更旧，排前面")
        XCTAssertEqual(s.duplicateConversationCount, 1)
        XCTAssertEqual(s.claudeConversationCount, 4)
    }

    // MARK: - 安全

    func testZipSlipRejected() throws {
        let zip = work.appendingPathComponent("evil.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        let data = Data("[]".utf8)
        try archive.addEntry(with: "../x/conversations.json", type: .file, uncompressedSize: Int64(data.count)) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }
        XCTAssertThrowsError(try scan([zip]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: work.path)
            .filter { $0.hasPrefix(ExportPackageScanner.stagingPrefix) }
        XCTAssertTrue(leftovers.isEmpty, "失败要清掉 staging")
    }

    func testCleanupRemovesStaging() throws {
        let s = try scan([try Self.fixtures().appendingPathComponent("gen-a")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.stagingDir.path))
        s.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.stagingDir.path))
    }

    func testPackageOrder() {
        XCTAssertEqual(ExportPackageScanner.packageOrder("conversations-003.zip"), 3)
        XCTAssertEqual(ExportPackageScanner.packageOrder("data-x-batch-0001.zip"), 1)
        XCTAssertEqual(ExportPackageScanner.packageOrder("conversations.json"), 0)
    }
}

/// #043 plan §2.5：解包预算 + 畸形包不崩
final class ZipExtractLimitsTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zip-limits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    private func makeZip(_ files: [String: Data]) throws -> URL {
        let url = work.appendingPathComponent("\(UUID().uuidString).zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        return url
    }

    private func extract(_ zip: URL, _ limits: ZipExtractLimits) throws {
        try TwitterZipExtractor.extract(zip, to: work.appendingPathComponent("out-\(UUID().uuidString)"),
                                        budget: ZipExtractBudget(limits))
    }

    private let roomy = ZipExtractLimits(maxEntries: 100, maxEntryBytes: 1 << 20, maxTotalBytes: 1 << 20, maxRatio: 1000)

    func testWithinBudgetExtracts() throws {
        XCTAssertNoThrow(try extract(try makeZip(["a.json": Data("[1]".utf8)]), roomy))
    }

    func testTooManyEntries() throws {
        var l = roomy
        l.maxEntries = 1
        let zip = try makeZip(["a.json": Data("1".utf8), "b.json": Data("2".utf8)])
        XCTAssertThrowsError(try extract(zip, l)) { XCTAssertEqual($0 as? ZipLimitError, .tooManyEntries(1)) }
    }

    func testTotalBudgetSharedAcrossZips() throws {
        var l = roomy
        l.maxTotalBytes = 12
        let budget = ZipExtractBudget(l)
        let one = try makeZip(["a.json": Data("1234567890".utf8)])
        try TwitterZipExtractor.extract(one, to: work.appendingPathComponent("o1"), budget: budget)
        XCTAssertThrowsError(try TwitterZipExtractor.extract(one, to: work.appendingPathComponent("o2"), budget: budget)) {
            XCTAssertEqual($0 as? ZipLimitError, .totalTooLarge)
        }
    }

    func testCompressionRatio() throws {
        var l = roomy
        l.maxRatio = 10
        let zip = try makeZip(["zeros.json": Data(repeating: 0x30, count: 200_000)])
        XCTAssertThrowsError(try extract(zip, l)) { XCTAssertEqual($0 as? ZipLimitError, .ratio("zeros.json")) }
    }

    /// 中央目录偏移改成超过文件长度：要抛错，不能 trap
    func testMalformedOffsetThrows() throws {
        var data = try Data(contentsOf: try makeZip(["a.json": Data("1".utf8)]))
        let eocd = try XCTUnwrap(data.lastRange(of: Data([0x50, 0x4B, 0x05, 0x06]))?.lowerBound)
        data.replaceSubrange((eocd + 16)..<(eocd + 20), with: [0xFF, 0xFF, 0xFF, 0xFF])
        let bad = work.appendingPathComponent("bad.zip")
        try data.write(to: bad)
        XCTAssertThrowsError(try extract(bad, roomy))
    }

    /// 压缩大小改成比整个包还大：解析目录时就拦下（原来求和会溢出崩溃），有没有预算都一样
    func testHugeCompressedSizeThrowsNotTraps() throws {
        var data = try Data(contentsOf: try makeZip(["a.json": Data("1".utf8), "b.json": Data("2".utf8)]))
        var from = data.startIndex
        while let cd = data.range(of: Data([0x50, 0x4B, 0x01, 0x02]), in: from..<data.endIndex)?.lowerBound {
            data.replaceSubrange((cd + 20)..<(cd + 24), with: [0xFE, 0xFF, 0xFF, 0xFF])
            data.replaceSubrange((cd + 24)..<(cd + 28), with: [0, 0, 0, 0])
            from = cd + 4
        }
        let bad = work.appendingPathComponent("bad-size.zip")
        try data.write(to: bad)
        XCTAssertThrowsError(try extract(bad, roomy))
        XCTAssertThrowsError(try TwitterZipExtractor.extract(bad, to: work.appendingPathComponent("o-nobudget")))
    }

    /// 中央目录里声明的解压大小改成 4 GB：在分配内存前就被预算拦下
    func testDeclaredHugeEntryRejectedBeforeAllocation() throws {
        var data = try Data(contentsOf: try makeZip(["a.json": Data("1".utf8)]))
        let cd = try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))?.lowerBound)
        data.replaceSubrange((cd + 24)..<(cd + 28), with: [0xFE, 0xFF, 0xFF, 0xFF])
        let bad = work.appendingPathComponent("huge.zip")
        try data.write(to: bad)
        XCTAssertThrowsError(try extract(bad, roomy)) { XCTAssertEqual($0 as? ZipLimitError, .entryTooLarge("a.json")) }
    }
}
