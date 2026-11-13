import XCTest
import SwiftData
@testable import 记忆花园

enum PreUpgradeV1 {
    @Model final class PUItem {
        var name: String
        init(name: String) { self.name = name }
    }
}

enum PreUpgradeV2 {
    @Model final class PUItem {
        var name: String
        var extra: String?
        init(name: String) { self.name = name }
    }
}

/// 新包首启克隆（research-backup-while-open 段 B）。临时目录 + 合成库，不碰真库。
final class PreUpgradeSnapshotTests: XCTestCase {
    private var dir: URL!
    private var paths: PreUpgradeSnapshot.Paths!
    private let fm = FileManager.default
    private let b1 = PreUpgradeSnapshot.BuildStamp(bundleVersion: "260924", binaryUUID: "AAAAAAAA-0000-0000-0000-000000000001")
    private let b2 = PreUpgradeSnapshot.BuildStamp(bundleVersion: "260924", binaryUUID: "BBBBBBBB-0000-0000-0000-000000000002")
    private let b3 = PreUpgradeSnapshot.BuildStamp(bundleVersion: "260924", binaryUUID: "CCCCCCCC-0000-0000-0000-000000000003")
    private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("pre-upgrade-\(UUID().uuidString)", isDirectory: true)
        let ms = dir.appendingPathComponent("MemoryPalace", isDirectory: true)
        try fm.createDirectory(at: ms, withIntermediateDirectories: true)
        paths = PreUpgradeSnapshot.Paths(store: ms.appendingPathComponent("unified.store"),
                                         external: ms.appendingPathComponent(".unified_SUPPORT", isDirectory: true),
                                         root: ms.appendingPathComponent("pre-upgrade", isDirectory: true),
                                         stamp: ms.appendingPathComponent("last-launched.json"))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    /// 合成「上一个包关掉后的库」：store + -wal + -shm + _EXTERNAL_DATA 一个文件
    private func makeStore(rows: Int = 20) throws {
        let schema = Schema([PreUpgradeV1.PUItem.self])
        do {
            let c = try ModelContainer(for: schema, configurations: [ModelConfiguration("unified", schema: schema, url: paths.store, cloudKitDatabase: .none)])
            let ctx = ModelContext(c)
            for i in 0..<rows { ctx.insert(PreUpgradeV1.PUItem(name: "i\(i)")) }
            try ctx.save()
        }
        for suffix in ["-wal", "-shm"] where !fm.fileExists(atPath: paths.store.path + suffix) {
            fm.createFile(atPath: paths.store.path + suffix, contents: Data())
        }
        let data = paths.external.appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 4096).write(to: data.appendingPathComponent(UUID().uuidString))
    }

    private func run(_ build: PreUpgradeSnapshot.BuildStamp, policy: PreUpgradeSnapshot.Policy = .everyNewBuild(keep: 2),
                     at: Date? = nil, changed: Bool? = false, free: Int64? = nil) -> PreUpgradeSnapshot.Outcome {
        PreUpgradeSnapshot.run(paths, current: build, policy: policy, now: at ?? t0, schemaChanged: { changed }, freeBytes: { _ in free })
    }

    private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    // MARK: - 判定

    func testFreshInstallWithoutStoreJustRecordsBuild() {
        XCTAssertEqual(run(b1), .noStore)
        XCTAssertEqual(PreUpgradeSnapshot.readStamp(paths.stamp)?.build, b1)
        XCTAssertEqual(run(b1), .sameBuild)
        XCTAssertFalse(fm.fileExists(atPath: paths.root.appendingPathComponent("x").path))
        XCTAssertEqual(PreUpgradeSnapshot.clones(root: paths.root), [])
    }

    func testNewBuildClonesAllFourPiecesBeforeOpen() throws {
        try makeStore()
        // 第一次带这个功能的包：没有 last-launched.json，但库在 → 也算新 build
        guard case .cloned(let name) = run(b1) else { return XCTFail("应克隆") }
        XCTAssertTrue(name.hasSuffix("-unknown"), name)
        let clone = paths.root.appendingPathComponent(name)
        for piece in paths.pieces where piece.name != ".unified_SUPPORT" {
            XCTAssertEqual(bytes(clone.appendingPathComponent(piece.name)), bytes(piece.url), piece.name)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: clone.appendingPathComponent(".unified_SUPPORT/_EXTERNAL_DATA").path),
                       try fm.contentsOfDirectory(atPath: paths.external.appendingPathComponent("_EXTERNAL_DATA").path))
        let mf = try XCTUnwrap(PreUpgradeSnapshot.manifest(of: name, root: paths.root))
        XCTAssertNil(mf.fromBuild)
        XCTAssertEqual(mf.toBuild, b1)
        XCTAssertEqual(mf.schemaChanged, false)
        XCTAssertEqual(mf.files["unified.store"], StoreSnapshotter.fileSize(paths.store))
        XCTAssertEqual(mf.files[".unified_SUPPORT"], 4096)
        XCTAssertEqual(try clone.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        XCTAssertEqual(run(b1), .sameBuild, "同一个包再启动不克隆")
        guard case .cloned(let second) = run(b2, at: t0.addingTimeInterval(60)) else { return XCTFail("新 build 应克隆") }
        XCTAssertTrue(second.hasSuffix("-" + b1.description), "名字带上一个包")
        XCTAssertEqual(PreUpgradeSnapshot.manifest(of: second, root: paths.root)?.fromBuild, b1)
    }

    func testDebugKeepsTwoNewestAndDropsOlderOnlyAfterNewSucceeds() throws {
        try makeStore()
        _ = run(b1, at: t0)
        _ = run(b2, at: t0.addingTimeInterval(60))
        XCTAssertEqual(PreUpgradeSnapshot.clones(root: paths.root).count, 2)
        guard case .cloned(let newest) = run(b3, at: t0.addingTimeInterval(120)) else { return XCTFail("应克隆") }
        let left = PreUpgradeSnapshot.clones(root: paths.root)
        XCTAssertEqual(left.count, 2)
        XCTAssertEqual(left.first, newest)
        XCTAssertTrue(left.last!.hasSuffix("-" + b1.description), "最旧那份删掉")

        // 新克隆没做成（空间不够）不删旧的
        let b4 = PreUpgradeSnapshot.BuildStamp(bundleVersion: "260924", binaryUUID: "DDDDDDDD")
        XCTAssertEqual(run(b4, at: t0.addingTimeInterval(180), free: 1), .insufficientSpace(need: PreUpgradeSnapshot.Paths.sizeForTest(paths) * 2, free: 1))
        XCTAssertEqual(PreUpgradeSnapshot.clones(root: paths.root), left)
        XCTAssertEqual(run(b4, at: t0.addingTimeInterval(240)), .sameBuild, "没做成也记下这个 build：库已被新包动过，不再补克隆")
    }

    func testClonesAndReplacedOlderThan14DaysArePruned() throws {
        try makeStore()
        guard case .cloned(let old) = run(b1, at: t0) else { return XCTFail("应克隆") }
        let replaced = paths.root.appendingPathComponent("replaced-20200101T000000Z", isDirectory: true)
        try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.root.appendingPathComponent(".tmp-crashed"), withIntermediateDirectories: true)
        let fifteenDays = Date().addingTimeInterval(-15 * 24 * 3600)
        for p in [paths.root.appendingPathComponent(old).path, replaced.path] {
            try fm.setAttributes([.modificationDate: fifteenDays], ofItemAtPath: p)
        }
        XCTAssertEqual(run(b1, at: Date()), .sameBuild)
        XCTAssertEqual(((try? fm.contentsOfDirectory(atPath: paths.root.path)) ?? []).sorted(), [], "过期克隆、replaced-、残留 .tmp- 都清了")
    }

    func testReleaseOnlyClonesWhenMigrating() throws {
        try makeStore()
        let release = PreUpgradeSnapshot.Policy.onlyWhenMigrating(keep: 1)
        XCTAssertEqual(run(b1, policy: release, changed: false), .notMigrating)
        XCTAssertEqual(PreUpgradeSnapshot.clones(root: paths.root), [])
        guard case .cloned = run(b2, policy: release, at: t0.addingTimeInterval(60), changed: true) else { return XCTFail("会迁移应克隆") }
        guard case .cloned = run(b3, policy: release, at: t0.addingTimeInterval(120), changed: nil) else { return XCTFail("判不了按会迁移处理") }
        XCTAssertEqual(PreUpgradeSnapshot.clones(root: paths.root).count, 1, "Release 只留 1 份")
    }

    func testSchemaChangedDetection() throws {
        XCTAssertNil(PreUpgradeSnapshot.schemaChanged(store: paths.store, types: [PreUpgradeV1.PUItem.self]), "没库判不了")
        try makeStore()
        XCTAssertEqual(PreUpgradeSnapshot.schemaChanged(store: paths.store, types: [PreUpgradeV1.PUItem.self]), false)
        XCTAssertEqual(PreUpgradeSnapshot.schemaChanged(store: paths.store, types: [PreUpgradeV2.PUItem.self]), true, "加一个可选字段 = 会迁移")
    }

    func testCurrentBuildStampReadsBinaryUUID() {
        let s = PreUpgradeSnapshot.BuildStamp.current
        XCTAssertNotNil(UUID(uuidString: s.binaryUUID), s.binaryUUID)
        XCTAssertNotEqual(s.bundleVersion, "unknown")
    }

    func testCloneTimeForOneGigabyteStore() throws {
        try makeStore()
        // 把主库撑到 1 GB（APFS 克隆按元数据走，和大小几乎无关）+ 500 个外置文件
        let handle = try FileHandle(forWritingTo: paths.store)
        try handle.seekToEnd()
        let chunk = Data(repeating: 0x5A, count: 8 << 20)
        for _ in 0..<128 { try handle.write(contentsOf: chunk) }
        try handle.close()
        let data = paths.external.appendingPathComponent("_EXTERNAL_DATA")
        for _ in 0..<500 { try Data(repeating: 1, count: 200_000).write(to: data.appendingPathComponent(UUID().uuidString)) }
        guard case .cloned(let name) = run(b1) else { return XCTFail("应克隆") }
        let ms = try XCTUnwrap(PreUpgradeSnapshot.manifest(of: name, root: paths.root)).durationMs
        print("[pre-upgrade] 1 GB 库 + 500 外置文件克隆 \(ms) ms")
        XCTAssertLessThan(ms, 500, "预算 50 ms；机器忙时放宽到 500 ms 只防退化成真拷贝")
    }

    // MARK: - 恢复

    func testRestoreSwapsCloneInAndKeepsReplaced() throws {
        try makeStore()
        guard case .cloned(let name) = run(b1) else { return XCTFail("应克隆") }
        let cloneStore = bytes(paths.root.appendingPathComponent(name).appendingPathComponent("unified.store"))
        // 新包把主库改了
        try Data(repeating: 0xEE, count: 1234).write(to: paths.store)
        let changedStore = bytes(paths.store)
        try PreUpgradeSnapshot.requestRestore(name, root: paths.root)
        XCTAssertEqual(PreUpgradeSnapshot.pendingRestore(root: paths.root), name)

        guard case .restored(let from, let replacedName)? = PreUpgradeSnapshot.restoreIfRequested(paths, now: t0.addingTimeInterval(300)) else {
            return XCTFail("应换回")
        }
        XCTAssertEqual(from, name)
        XCTAssertEqual(bytes(paths.store), cloneStore)
        XCTAssertEqual(bytes(paths.root.appendingPathComponent(replacedName).appendingPathComponent("unified.store")), changedStore, "旧主位挪走不删")
        XCTAssertTrue(fm.fileExists(atPath: paths.external.appendingPathComponent("_EXTERNAL_DATA").path))
        XCTAssertNil(PreUpgradeSnapshot.pendingRestore(root: paths.root), "flag 用完即删")
        XCTAssertEqual(PreUpgradeSnapshot.clones(root: paths.root), [name], "克隆本身还在，replaced- 不算克隆")
        XCTAssertNil(PreUpgradeSnapshot.restoreIfRequested(paths), "没 flag 不动")
    }

    func testRestoreOfMissingCloneLeavesPrimaryAlone() throws {
        try makeStore()
        let before = bytes(paths.store)
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try PreUpgradeSnapshot.requestRestore("nope", root: paths.root)
        XCTAssertEqual(PreUpgradeSnapshot.restoreIfRequested(paths), .failed("没有这份克隆：nope"))
        XCTAssertEqual(bytes(paths.store), before)
        XCTAssertNil(PreUpgradeSnapshot.pendingRestore(root: paths.root))
    }
}

private extension PreUpgradeSnapshot.Paths {
    static func sizeForTest(_ p: PreUpgradeSnapshot.Paths) -> Int64 {
        p.pieces.reduce(0) { $0 + PreUpgradeSnapshot.treeSize($1.url) }
    }
}
