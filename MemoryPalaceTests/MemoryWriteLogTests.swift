import MemoryCore
import XCTest
@testable import 记忆花园

/// v5 §十一：记忆日志——成败都记（时间 / 编号 / 原因 / 模型 / 花了多少）；保留 30 天或 1000 条；状态卡每行跳到这一项最近一条
final class MemoryWriteLogTests: XCTestCase {

    let pid = "xctest-write-log"

    override func tearDown() {
        MemoryWriteLog.flush()
        let d = UserDefaults.standard
        for kind in ["extract", "dream", "summary", "context", "timeline"] {
            for field in ["ok", "err", "errmsg", "streak", "model"] { d.removeObject(forKey: "mem_health_\(kind)_\(field)_\(pid)") }
        }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func entry(_ writer: String, _ time: Date, ok: Bool = true, rejected: Int? = nil) -> MemoryWriteLog.Entry {
        .init(time: time, writer: writer, ok: ok, note: "n", model: "m", costUSD: nil, rejected: rejected)
    }

    func testOKAndErrorBothLoggedWithCost() async {
        await MemoryWriteLog.metered {
            MemoryWriteLog.addCost(0.03)
            MemoryWriteLog.addCost(0.01)
            MemoryHealthStore.recordOK(.summary, profileId: pid, modelName: "sonnet", note: "《搬家》286 字")
        }
        MemoryHealthStore.recordError(.timeline, profileId: pid, message: "请求超时", modelName: "sonnet")
        MemoryHealthStore.recordOK(.dream, profileId: pid, modelName: "x")
        MemoryWriteLog.flush()
        let list = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        XCTAssertEqual(list.map(\.writer), ["A4", "A3"], "新的在前；画像（下线）不记")
        XCTAssertEqual(list[0].ok, false)
        XCTAssertEqual(list[0].note, "请求超时")
        XCTAssertNil(list[0].costUSD, "没记账的那次不写钱")
        XCTAssertEqual(list[1].costUSD ?? 0, 0.04, accuracy: 1e-9, "钱从这次调用记账的那几笔取")
        XCTAssertEqual(list[1].note, "《搬家》286 字")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MemoryWriteLog.fileURL(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).path), "存楼层 memory/log/，不放 UserDefaults")
    }

    func testPrune() {
        let now = Date()
        var list = (0..<1005).map { entry("A2", now.addingTimeInterval(-Double($0))) }
        list.append(entry("A3", now.addingTimeInterval(-31 * 86400)))
        let kept = MemoryWriteLog.pruned(list, now: now)
        XCTAssertEqual(kept.count, 1000, "最多 1000 条")
        XCTAssertFalse(kept.contains { $0.writer == "A3" }, "30 天以前的删")
        XCTAssertEqual(kept.last?.time, now, "留最新的")
    }

    func testLatestAndRejectedThisWeek() {
        let now = Date()
        let list = [entry("C2", now.addingTimeInterval(-100), rejected: 2), entry("C2", now.addingTimeInterval(-50), ok: false, rejected: 1),
                    entry("A4", now.addingTimeInterval(-10)), entry("C2", now.addingTimeInterval(-30 * 86400), rejected: 9)]
        XCTAssertEqual(MemoryWriteLog.latest(.c2, in: list)?.time, now.addingTimeInterval(-50), "状态卡点 C2 跳到最近那条")
        XCTAssertNil(MemoryWriteLog.latest(.a2, in: list))
        XCTAssertEqual(MemoryWriteLog.rejectedThisWeek(list, now: now), 3)
    }

    /// 试写台的记录：老行没有 trial 照读；状态行「最近那条」跳过试写
    func testTrialEntriesSkippedByLatestAndOldLinesStillDecode() throws {
        let old = #"{"id":"7C0E1A9B-3B3A-4E5D-9B1C-2F0D3E4A5B6C","time":1800000000,"writer":"C2","ok":true,"note":"写了 3 张","model":"m"}"#
        let decoded = MemoryWriteLog.decode(Data((old + "\n").utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].trial)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var trial = entry("C2", t.addingTimeInterval(60))
        trial.trial = true
        let list = [entry("C2", t), trial]
        XCTAssertEqual(MemoryWriteLog.latest(.c2, in: list)?.time, t, "试写更新也不顶掉真写的那条")

        MemoryWriteLog.record(writer: .c2, profileId: pid, ok: true, note: "试写 · 探针", model: "Haiku", trial: true, cost: 0.02, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        MemoryWriteLog.flush()
        let saved = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).first)
        XCTAssertEqual(saved.trial, true)
        XCTAssertEqual(saved.costUSD ?? 0, 0.02, accuracy: 1e-9, "给了 cost 就用它")
    }

    func testDaysGrouping() {
        let now = Date()
        let list = [entry("A2", now), entry("A3", now.addingTimeInterval(-86400)), entry("A4", now.addingTimeInterval(-3 * 86400))]
        let days = MemoryWriteLogSheet.days(list, now: now)
        XCTAssertEqual(days.first?.0, "今天")
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[1].0, "昨天")
    }

    func testRunReaderOpensExistingContentBeforeRequestedAnchorAppears() async throws {
        let content = "# 整理记录\n\n已经落盘的第一轮原文\n"
        let fixture = try runFixture(content: content, anchor: "round-not-written-yet")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await MemoryWriteLogRunReader.load(fixture.entry, wiki: fixture.wiki) { url in
            XCTAssertFalse(Thread.isMainThread, "文件读取留在后台")
            return try String(contentsOf: url, encoding: .utf8)
        }
        guard case .loaded(let document) = result else { return XCTFail("锚点尚未落盘也应打开已有全文") }
        XCTAssertEqual(document.url, fixture.url)
        XCTAssertEqual(document.link, fixture.entry.run)
        XCTAssertEqual(document.content, content)
        XCTAssertNil(result.message)
        let location = FileEditorPreviewLocation(content: document.content, anchor: document.link.anchor)
        XCTAssertNil(location.targetIndex)
        XCTAssertEqual(location.parts.joined(), content, "缺少锚点不能丢掉现有内容")
    }

    func testRunReaderReportsUnreadableExistingFileWithoutClaimingCleanup() async throws {
        let fixture = try runFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for error in [
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        ] {
            let result = await MemoryWriteLogRunReader.load(fixture.entry, wiki: fixture.wiki) { _ in
                XCTAssertFalse(Thread.isMainThread)
                throw error
            }
            guard case .unavailable = result else { return XCTFail("读取失败不能冒充文件已清理") }
            XCTAssertFalse(try XCTUnwrap(result.message).isEmpty)
            XCTAssertNotEqual(result.message, CatalogRunRecord.expiredMessage)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.path))
        }
    }

    func testRunReaderReportsExpiredOnlyAfterFileDeletion() async throws {
        let fixture = try runFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let existing = await MemoryWriteLogRunReader.load(fixture.entry, wiki: fixture.wiki)
        guard case .loaded = existing else { return XCTFail("删除前应正常打开") }
        let duringRead = await MemoryWriteLogRunReader.load(fixture.entry, wiki: fixture.wiki) { url in
            try FileManager.default.removeItem(at: url)
            return try String(contentsOf: url, encoding: .utf8)
        }
        guard case .expired = duringRead else { return XCTFail("读取时实际删除的文件应报告已清理") }
        XCTAssertEqual(duringRead.message, CatalogRunRecord.expiredMessage)

        let deleted = await MemoryWriteLogRunReader.load(fixture.entry, wiki: fixture.wiki) { _ in
            XCTFail("已删除的文件不应继续读取")
            return ""
        }
        guard case .expired = deleted else { return XCTFail("实际不存在的文件应报告已清理") }
        XCTAssertEqual(deleted.message, CatalogRunRecord.expiredMessage)
    }

    func testRunReaderRejectsInvalidPathsWithoutClaimingCleanup() async throws {
        let fixture = try runFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = fixture.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("directory.md"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("alias.md"), withDestinationURL: fixture.url)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("dangling.md"),
                                                  withDestinationURL: folder.appendingPathComponent("missing.md"))
        let outside = fixture.root.appendingPathComponent("outside.md")
        try "不能读取的库外内容".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.md"), withDestinationURL: outside)

        for path in [
            "../secret.md", ".runs/../secret.md", ".proposals/a.json", ".runs/record.txt",
            ".runs/directory.md", ".runs/alias.md", ".runs/dangling.md", ".runs/escape.md"
        ] {
            var entry = fixture.entry
            entry.run = CatalogRunLink(path: path)
            let result = await MemoryWriteLogRunReader.load(entry, wiki: fixture.wiki) { _ in
                XCTFail("非法路径、目录或符号链接不得进入内容读取")
                return ""
            }
            guard case .unavailable = result else { return XCTFail("无效链接不是记录已清理：\(path)") }
            XCTAssertFalse(try XCTUnwrap(result.message).isEmpty)
            XCTAssertNotEqual(result.message, CatalogRunRecord.expiredMessage)
        }
    }

    private func runFixture(
        content: String = "# 整理记录\n\n已有原文\n",
        anchor: String? = nil
    ) throws -> (root: URL, wiki: WikiStore, url: URL, entry: MemoryWriteLog.Entry) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let folder = wiki.root.appendingPathComponent(CatalogRunRecord.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("record.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let entry = MemoryWriteLog.Entry(time: Date(), writer: "C3", ok: true, note: "", model: "",
                                         run: CatalogRunLink(path: CatalogRunRecord.folderName + "/" + url.lastPathComponent, anchor: anchor))
        return (root, wiki, url, entry)
    }
}
