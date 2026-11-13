import XCTest
import SwiftData
import SQLite3
@testable import 记忆花园

/// 活库一致快照（research-backup-while-open A1）。全部临时目录 + 合成库（真 makeFullSchema），不碰真库。
final class StoreSnapshotterTests: XCTestCase {
    private var dir: URL!
    private var store: URL { dir.appendingPathComponent("live/unified.store") }
    private var external: URL { dir.appendingPathComponent("live/.unified_SUPPORT", isDirectory: true) }
    private var root: URL { dir.appendingPathComponent("air-snapshot", isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("store-snap-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("live"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    // MARK: - 合成库

    private func makeContainer(_ url: URL) throws -> ModelContainer {
        let schema = ProfileManager.makeFullSchema()
        return try ModelContainer(for: schema, configurations: [ModelConfiguration("unified", schema: schema, url: url, cloudKitDatabase: .none)])
    }

    private func node(_ i: Int, big: Bool) -> MessageNode {
        let n = MessageNode(id: "n\(i)-\(UUID().uuidString)", role: "user", content: "m\(i)", contentType: "text",
                            createTime: Date(), parentId: nil, childrenIds: [], conversationId: "c1", profileId: "p")
        if big { n.segmentsData = Data(repeating: UInt8(i % 251), count: 300_000) }
        else if i % 10 == 0 { n.segmentsData = Data(repeating: 7, count: 400) }
        return n
    }

    /// N 条消息，每 100 条一个 300 KB 外置 blob；返回 (container, 外置的那几条)
    private func seed(_ n: Int) throws -> (ModelContainer, [MessageNode]) {
        let c = try makeContainer(store)
        let ctx = ModelContext(c)
        var bigs: [MessageNode] = []
        for i in 0..<n {
            let m = node(i, big: i % 100 == 0)
            ctx.insert(m)
            if i % 100 == 0 { bigs.append(m) }
        }
        try ctx.save()
        return (c, bigs)
    }

    private func count(_ c: ModelContainer) -> Int {
        (try? ModelContext(c).fetchCount(FetchDescriptor<MessageNode>())) ?? -1
    }

    private func pragma(_ url: URL, _ sql: String) -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return "open failed" }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "prepare failed" }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return "no row" }
        return String(cString: c)
    }

    private func snap(_ id: String, free: Int64? = nil, afterPin: (() -> Void)? = nil) throws -> StoreSnapshotter.Manifest {
        try StoreSnapshotter.snapshot(store: store, external: external, root: root, id: id, appBuild: "test-build",
                                      fingerprint: "fp", freeBytes: { _ in free }, afterPin: afterPin)
    }

    // MARK: - 正常 / 并发写

    func testSnapshotIsConsistentWhileAnotherContextKeepsWriting() throws {
        let (c, _) = try seed(3000)
        let lock = NSLock()
        var stop = false
        var wrote = 0
        let done = expectation(description: "writer stopped")
        let writer = Thread {
            let ctx = ModelContext(c)
            var i = 100_000
            while true {
                lock.lock(); let s = stop; lock.unlock()
                if s { break }
                for _ in 0..<10 { ctx.insert(self.node(i, big: i % 30 == 0)); i += 1 }
                try? ctx.save()
                lock.lock(); wrote += 10; lock.unlock()
            }
            done.fulfill()
        }
        writer.start()
        Thread.sleep(forTimeInterval: 0.2)
        let before = count(c)
        let m = try snap("s1")
        let after = count(c)
        lock.lock(); stop = true; lock.unlock()
        wait(for: [done], timeout: 10)
        XCTAssertGreaterThan(wrote, 0, "写线程得真的在写")

        let out = root.appendingPathComponent("s1")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path).sorted(), [".unified_SUPPORT", "snapshot.json", "unified.store"],
                       "单文件库：没有 -wal / -shm")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["s1"], ".tmp- 已 rename 掉")
        XCTAssertEqual(pragma(out.appendingPathComponent("unified.store"), "PRAGMA journal_mode"), "delete")
        XCTAssertEqual(pragma(out.appendingPathComponent("unified.store"), "PRAGMA integrity_check"), "ok")
        XCTAssertGreaterThanOrEqual(m.messageCount, before)
        XCTAssertLessThanOrEqual(m.messageCount, after)
        XCTAssertGreaterThanOrEqual(m.externalRefs, 30)
        XCTAssertGreaterThanOrEqual(m.externalFiles, m.externalRefs, "快照之后新建的外置文件可以多（孤儿），不能少")
        XCTAssertEqual(m.attempts, 1)
        XCTAssertEqual(try StoreSnapshotter.missingExternal(in: out), [])

        let saved = try JSONDecoder().decode(StoreSnapshotter.Manifest.self, from: Data(contentsOf: out.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(saved, m)
        XCTAssertEqual(saved.storeBytes, StoreSnapshotter.fileSize(out.appendingPathComponent("unified.store")))
        XCTAssertEqual(saved.appBuild, "test-build")
        XCTAssertEqual(try out.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        // 产物能被新 ModelContainer 打开（会自己切回 WAL），条数和清单一致，外置字段能读回
        let reopened = try makeContainer(out.appendingPathComponent("unified.store"))
        XCTAssertEqual(count(reopened), m.messageCount)
        let ctx = ModelContext(reopened)
        let bigs = try ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.content == "m100" }))
        XCTAssertEqual(bigs.first?.segmentsData?.count, 300_000)
    }

    // MARK: - 外置文件在 T0 之后被删

    func testExternalDeletedBetweenPinAndCloneIsRedoneOnce() throws {
        let (c, bigs) = try seed(500)
        let victim = bigs[1].id
        let m = try snap("s2", afterPin: {
            let ctx = ModelContext(c)
            let doomed = try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == victim }))
            doomed?.forEach { ctx.delete($0) }
            try? ctx.save()
        })
        XCTAssertEqual(m.attempts, 2, "第一遍缺了刚删的外置文件，整份重做一次")
        XCTAssertEqual(m.messageCount, 499)
        XCTAssertEqual(try StoreSnapshotter.missingExternal(in: root.appendingPathComponent("s2")), [])
    }

    func testStillMissingAfterRedoFailsAndLeavesNothing() throws {
        _ = try seed(500)
        let data = external.appendingPathComponent("_EXTERNAL_DATA")
        let gone = try XCTUnwrap(fm.contentsOfDirectory(atPath: data.path).first)
        XCTAssertThrowsError(try snap("s3", afterPin: { try? self.fm.removeItem(at: data.appendingPathComponent(gone)) })) { error in
            XCTAssertEqual(error as? StoreSnapshotter.SnapshotError, .missingExternal([gone]))
        }
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: root.path)) ?? [], [], "失败不留 .tmp- 也不留成品")
    }

    func testInterimFilesAreSkipped() throws {
        _ = try seed(200)
        let data = external.appendingPathComponent("_EXTERNAL_DATA")
        try Data("half".utf8).write(to: data.appendingPathComponent("\(UUID().uuidString).interim"))
        _ = try snap("s4")
        let copied = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("s4/.unified_SUPPORT/_EXTERNAL_DATA").path)
        XCTAssertFalse(copied.contains { $0.hasSuffix(".interim") })
    }

    // MARK: - 拒绝

    func testInsufficientSpaceRefusesBeforeTouchingAnything() throws {
        _ = try seed(200)
        XCTAssertThrowsError(try snap("s5", free: 1)) { error in
            guard case .insufficientSpace(let need, let free)? = error as? StoreSnapshotter.SnapshotError else {
                return XCTFail("应是空间不足：\(error)")
            }
            XCTAssertEqual(free, 1)
            XCTAssertGreaterThan(need, StoreSnapshotter.fileSize(self.store))
        }
        XCTAssertFalse(fm.fileExists(atPath: root.path))
    }

    func testNoStore() {
        XCTAssertThrowsError(try snap("s6")) { error in
            XCTAssertEqual(error as? StoreSnapshotter.SnapshotError, .noStore(store.path))
        }
    }
}
