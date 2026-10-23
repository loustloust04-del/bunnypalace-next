#if os(macOS)
import CoreServices
import XCTest
@testable import 记忆花园

/// N1-d 实时增量：监听器合批 / 节流 / 丢事件兜底 / Kimi 边车映射 / 真 FSEvents；扫描器 scanFiles。全在 tmp。
final class CodingSessionWatcherTests: XCTestCase {
    private var dir: URL!
    private var projects: URL { dir.appendingPathComponent("claude/projects") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: CodingSessionAdapterTests.fixtures.appendingPathComponent("claude"),
                                         to: dir.appendingPathComponent("claude"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var claudeFile: URL {
        projects.appendingPathComponent("-Users-tester-Github-wakefx/11111111-aaaa-bbbb-cccc-000000000001.jsonl")
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CodingSessionWatcher.Batch] = []
        func add(_ b: CodingSessionWatcher.Batch) { lock.lock(); items.append(b); lock.unlock() }
        var batches: [CodingSessionWatcher.Batch] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testRecordBatchesAndThrottlesSameFile() {
        let collector = Collector()
        let watcher = CodingSessionWatcher(adapters: [ClaudeCodeAdapter(root: projects)]) { collector.add($0) }
        watcher.record([claudeFile.path, claudeFile.path], [0, 0])
        waitFor({ collector.batches.count >= 1 }, timeout: 3)
        XCTAssertEqual(collector.batches.first?.refs.map(\.nativeId), ["11111111-aaaa-bbbb-cccc-000000000001"], "同批去重")

        watcher.record([claudeFile.path], [0])
        waitFor({ collector.batches.count >= 2 }, timeout: 1.5)
        XCTAssertEqual(collector.batches.count, 1, "3 s 内同文件不重解析")
        waitFor({ collector.batches.count >= 2 }, timeout: 5)
        XCTAssertEqual(collector.batches.count, 2, "节流到期后补上")
    }

    func testDroppedEventsRequestRescanAndMissingFileIsRemoval() {
        let collector = Collector()
        let watcher = CodingSessionWatcher(adapters: [ClaudeCodeAdapter(root: projects)]) { collector.add($0) }
        let gone = projects.appendingPathComponent("-Users-tester-Github-wakefx/deleted.jsonl").path
        watcher.record([projects.path, gone], [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), 0])
        waitFor({ !collector.batches.isEmpty }, timeout: 3)
        XCTAssertEqual(collector.batches.first?.needsRescan, true)
        XCTAssertEqual(collector.batches.first?.removedPaths, [gone])
    }

    func testKimiStateSidecarMapsToWire() {
        XCTAssertEqual(CodingSessionWatcher.sessionFilePath(for: "/k/sessions/wd/session_1/state.json"),
                       "/k/sessions/wd/session_1/agents/main/wire.jsonl")
        XCTAssertEqual(CodingSessionWatcher.sessionFilePath(for: "/k/other/state.json"), "/k/other/state.json")
    }

    func testRealFSEventsDeliverNewFile() throws {
        let collector = Collector()
        let watcher = CodingSessionWatcher(adapters: [ClaudeCodeAdapter(root: projects)]) { collector.add($0) }
        watcher.start()
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.5)
        let fresh = projects.appendingPathComponent("-Users-tester-Github-wakefx/22222222-aaaa-bbbb-cccc-000000000099.jsonl")
        try FileManager.default.copyItem(at: claudeFile, to: fresh)
        waitFor({ collector.batches.contains { $0.refs.contains { $0.nativeId == "22222222-aaaa-bbbb-cccc-000000000099" } } }, timeout: 10)
        XCTAssertTrue(collector.batches.contains { $0.refs.contains { $0.nativeId == "22222222-aaaa-bbbb-cccc-000000000099" } })
    }

    // MARK: - scanFiles

    func testScanFilesWritesPrunesAndHonoursTombstones() throws {
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        let adapter = ClaudeCodeAdapter(root: projects)
        let scanner = CodingSessionScanner(index: index, adapters: [adapter])
        let ref = try XCTUnwrap(adapter.fileRef(claudeFile))

        XCTAssertEqual(try scanner.scanFiles([ref]).parsed, 1)
        XCTAssertEqual(try index.session(key: "claude-code:11111111-aaaa-bbbb-cccc-000000000001")?.title, "QR login revamp")

        XCTAssertEqual(try scanner.scanFiles([], removedPaths: [claudeFile.path]).pruned, 1)
        XCTAssertNil(try index.session(key: "claude-code:11111111-aaaa-bbbb-cccc-000000000001"))

        let report = try scanner.scanFiles([ref], isTombstoned: { path, _ in path == self.claudeFile.path })
        XCTAssertEqual(report.parsed, 0)
        XCTAssertEqual(try index.sessionCount(), 0, "墓碑挡住，不复活")
    }

    func testFullScanSkipsWhileIncrementalHoldsGate() throws {
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        let scanner = CodingSessionScanner(index: index, adapters: [ClaudeCodeAdapter(root: projects)])
        let first = try scanner.run()
        XCTAssertFalse(first.skipped)
        XCTAssertEqual(first.parsed, 3)
    }
}
#endif
