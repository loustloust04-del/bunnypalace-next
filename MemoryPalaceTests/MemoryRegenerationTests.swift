import XCTest
@testable import 记忆花园

/// 记忆备份 / 恢复（临时目录当测试楼层）——备份逐字一致、核对、恢复失败挪回来、回滚逐字一致；三代搬迁复用的 `work`
final class MemoryRegenerationTests: XCTestCase {

    private var floor: URL!
    private var root: URL { floor.appendingPathComponent("memory", isDirectory: true) }
    private let cal = Calendar.current

    override func setUpWithError() throws {
        floor = FileManager.default.temporaryDirectory.appendingPathComponent("xctest-regen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 测试里改过权限的先改回来，不然删不掉
        if let e = FileManager.default.enumerator(atPath: floor.path) {
            for case let rel as String in e {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: floor.appendingPathComponent(rel).path)
            }
        }
        try? FileManager.default.removeItem(at: floor)
    }

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    /// 一个窗口：10-09 晚上 3 条 + 10-10 上午 3 条
    private func messages() -> [SessionSegmentWriter.Message] {
        [date(10, 9, 21), date(10, 9, 22), date(10, 9, 23), date(10, 10, 9), date(10, 10, 10), date(10, 10, 11)].enumerated().map { i, d in
            .init(id: "n\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "第\(i)条", date: d)
        }
    }

    /// 写坏的老数据：sessions/ 里一段收尾段（带待续）、时间轴 9 月文件里一条 10 月的老条目（第三刀的毛病）
    private func seedBroken() throws {
        let closeout = SessionSegment(kind: .closeout, title: "这个窗口……", start: date(10, 9, 21), end: date(10, 10, 11), from: 0, to: 6,
                                      lastNodeId: "n5", story: "这个窗口聊了很多", quotes: "", pending: "仍未问到")
        try SessionSummaryStore.save(SessionSummary(conversationId: "conv-live-0001", title: "色色", compressedCount: 0,
                                                    segments: [closeout], updatedAt: date(10, 10, 12)),
                                     in: SessionSummaryStore.dir(root: root))
        let tl = TimelineStore.dir(root: root)
        try TimelineStore.write([TimelineEntry(start: date(10, 9, 21), end: date(10, 10, 11), conversationId: "conv-live-0001",
                                               title: "色色", text: "（想了很久）……想到了", pending: "仍未问到")], month: "2026-09", in: tl)
        try TimelineStore.write([TimelineEntry(start: date(10, 2, 0, 30), end: date(10, 2, 1), conversationId: "conv-gone-0001",
                                               title: "删掉的", text: "凌晨聊的", pending: "")], month: "2026-10", in: tl)
    }

    /// 这几个文件夹里的全部文件 → 内容
    private func snapshot(_ folders: [String] = MemoryRegeneration.folders, base: URL? = nil) -> [String: String] {
        let base = base ?? root
        var out: [String: String] = [:]
        for f in folders {
            let dir = base.appendingPathComponent(f)
            for rel in ((try? MemoryRegeneration.inventory(dir)) ?? [:]).keys {
                out[f + "/" + rel] = try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8)
            }
        }
        return out
    }

    private func source(_ id: String) -> MemoryRegeneration.Source? {
        id == "conv-live-0001" ? .init(title: "色色", messages: messages(), isCC: false) : nil
    }

    private func msgs(_ n: Int, from start: Date, prefix: String = "n") -> [SessionSegmentWriter.Message] {
        (0..<n).map { .init(id: "\(prefix)\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "第\($0)条",
                            date: start.addingTimeInterval(TimeInterval($0) * 60)) }
    }

    // MARK: - work（三代搬迁 a2Full 复用）

    /// #1：原覆盖 [0,300) 全在范围里 → 重建整段 [0,300)，不套首次补写的 150 条上限；CC 分支同样从头建
    func testRebuildsFullOriginalCoverage() {
        let m = msgs(400, from: date(10, 5, 9))
        let seg = SessionSegment(kind: .rolling, title: "老压缩", start: date(10, 5, 9), end: m[299].date!, from: 0, to: 300,
                                 lastNodeId: "n299", story: "", quotes: "", pending: "仍未")
        let old = SessionSummary(conversationId: "c", title: "t", compressedCount: 300, segments: [seg], updatedAt: date(10, 6, 0))
        let api = MemoryRegeneration.work(old: old, source: .init(title: "t", messages: m, isCC: false), scopeStart: date(10, 1, 5), now: date(10, 11, 12))
        XCTAssertEqual(api.contextParts.first?.lowerBound, 0)
        XCTAssertEqual(api.contextParts.last?.upperBound, 300)
        XCTAssertEqual(api.contextParts.reduce(0) { $0 + $1.count }, 300, "[0,300) 全部重建")
        let cc = MemoryRegeneration.work(old: old, source: .init(title: "t", messages: m, isCC: true), scopeStart: date(10, 1, 5), now: date(10, 11, 12))
        XCTAssertEqual(cc.contextParts.first?.lowerBound, 0, "CC 也从头建")
        XCTAssertEqual(cc.contextParts.reduce(0) { $0 + $1.count }, 400, "那天已经过去：整截都写")
    }

    /// 锚点曾因老收尾段盖住窗外只推不写：重写时按 compressedCount 补上下文摘要，不然窗外那截没人总结
    func testAnchorOnlyWindowGetsContextRewritten() throws {
        let closeout = SessionSegment(kind: .closeout, title: "老收尾", start: date(10, 9, 21), end: date(10, 10, 11), from: 0, to: 6,
                                      lastNodeId: "n5", story: "", quotes: "", pending: "")
        let old = SessionSummary(conversationId: "conv-live-0001", title: "色色", compressedCount: 4, segments: [closeout], updatedAt: date(10, 10, 12))
        let w = MemoryRegeneration.work(old: old, source: try XCTUnwrap(source("conv-live-0001")), scopeStart: date(10, 1, 5), now: date(10, 11, 12))
        XCTAssertEqual(w.contextParts, [0..<4])
        XCTAssertTrue(w.keep.segments.isEmpty, "老收尾段拿掉")
    }

    /// 三代搬迁 astra #4：跨起点的段（起点以前开始）整段留着，只拿掉整段在起点以后的
    func testWorkKeepsSegmentsCrossingStart() {
        let m = msgs(10, from: date(9, 30, 22), prefix: "o") + msgs(60, from: date(10, 5, 9))
        let cross = SessionSegment(kind: .rolling, title: "跨起点", start: m[0].date!, end: m[19].date!, from: 0, to: 20,
                                   lastNodeId: m[19].id, story: "", quotes: "", pending: "仍未")
        let crossClose = SessionSegment(kind: .closeout, title: "跨起点收尾", start: m[5].date!, end: m[25].date!, from: 5, to: 26,
                                        lastNodeId: m[25].id, story: "", quotes: "", pending: "")
        let after = SessionSegment(kind: .rolling, title: "起点以后", start: m[20].date!, end: m[49].date!, from: 20, to: 50,
                                   lastNodeId: m[49].id, story: "", quotes: "", pending: "仍未")
        let old = SessionSummary(conversationId: "c", title: "t", compressedCount: 50, segments: [cross, crossClose, after], updatedAt: date(10, 6, 0))
        let w = MemoryRegeneration.work(old: old, source: .init(title: "t", messages: m, isCC: false), scopeStart: date(10, 1, 5), now: date(10, 11, 12))
        XCTAssertEqual(w.keep.segments.map(\.title), ["跨起点", "跨起点收尾"])
        XCTAssertEqual(w.contextParts, [20..<50], "只重写整段在起点以后的那截")
    }

    // MARK: - 备份

    /// #4：恢复时拷贝失败 → 拷了一半的删掉，挪开的挪回来，「回滚前」撤掉
    func testRestoreCopyFailureMovesCurrentBack() throws {
        try seedBroken()
        let backup = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v4-1-test")
        try TimelineStore.write([], month: "2026-11", in: TimelineStore.dir(root: root))   // 现在的和备份不一样
        let current = snapshot()
        let failingCopy: MemoryRegeneration.FileOp = { from, to in
            if from.lastPathComponent == SessionSummaryStore.folder { throw InjectedFailure() }
            try FileManager.default.copyItem(at: from, to: to)
        }
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: backup, memoryRoot: root, now: date(10, 11, 13), copy: failingCopy))
        XCTAssertEqual(snapshot(), current, "现在的文件原样回来")
        XCTAssertFalse(MemoryRegeneration.backups(memoryRoot: root).contains { $0.lastPathComponent.hasPrefix("回滚前-") })
    }

    private struct InjectedFailure: Error {}

    /// #5：拷到一半的备份不列、不让恢复；清单分得清「原本没有」和「没拷完」
    func testHalfBackupIsNotListedOrRestorable() throws {
        try seedBroken()
        let failingCopy: MemoryRegeneration.FileOp = { from, to in
            if from.lastPathComponent == SessionSummaryStore.folder { throw InjectedFailure() }
            try FileManager.default.copyItem(at: from, to: to)
        }
        XCTAssertThrowsError(try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v4-1-half", copy: failingCopy))
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).isEmpty, "没拷完的不列")
        let backupRoot = MemoryRegeneration.backupRoot(memoryRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent("v4-1-half").path), "没拷完不发布正式名字")

        // 手搭一份没清单的
        let fake = backupRoot.appendingPathComponent("v4-1-fake", isDirectory: true)
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("timeline"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: fake, memoryRoot: root, now: date(10, 11, 13))) {
            XCTAssertEqual($0 as? MemoryRegeneration.RegenError, .incompleteBackup("没有完成清单，可能拷到一半"))
        }

        // 正常备份：windows/ 原本没有 → 清单里没有它，恢复后也没有
        let good = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v4-1-good")
        XCTAssertEqual(MemoryRegeneration.manifest(of: good)?.folders, [TimelineStore.folder, SessionSummaryStore.folder])
        XCTAssertEqual(MemoryRegeneration.backups(memoryRoot: root).map(\.lastPathComponent), ["v4-1-good"])
        // 清单里有、备份里却没有 → 拒绝
        try FileManager.default.removeItem(at: good.appendingPathComponent(SessionSummaryStore.folder))
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: good, memoryRoot: root, now: date(10, 11, 13)))
    }

    /// 恢复后和备份逐字一致；现在的挪进「回滚前」
    func testRestoreMatchesBackup() throws {
        try seedBroken()
        let before = snapshot()
        let backup = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v4-1-test")
        try TimelineStore.write([], month: "2026-11", in: TimelineStore.dir(root: root))
        try WindowSummaryStore.save(SessionSummary(conversationId: "conv-live-0001", title: "色色", compressedCount: 0, segments: [],
                                                   updatedAt: date(10, 11, 12)), in: root)
        XCTAssertNotEqual(snapshot(), before)
        try MemoryRegeneration.restore(backup: backup, memoryRoot: root, now: date(10, 11, 13))
        XCTAssertEqual(snapshot(), before, "回滚后和备份逐字一致")
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).contains { $0.lastPathComponent.hasPrefix("回滚前-") })
    }

    // MARK: - 三代搬迁 · 备份 / 恢复（plan-memory-migrate-3gen B1–B3）

    private let five = MemoryMigration.folders

    private func put(_ rel: String, _ text: String, in base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func text(_ rel: String, in base: URL? = nil) -> String? {
        try? String(contentsOf: (base ?? root).appendingPathComponent(rel), encoding: .utf8)
    }

    /// B1：五个都进备份、逐字一致；原本没有的 windows/ 也算这份备份管的（covered），清单 folders 只列原本有的；B3 认 v5搬迁- 前缀；
    /// 清单逐个文件记大小 + SHA256（astra #10）
    func testMigrationBackupCoversFiveFolders() throws {
        try seedBroken()
        try put("pending/待续.md", "待续本子")
        try put("summaries/conv-old-x.md", "第一代")
        let before = snapshot(five)
        let b = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v5搬迁-t1", folders: five)
        let m = try XCTUnwrap(MemoryRegeneration.manifest(of: b))
        XCTAssertEqual(m.covered, five)
        XCTAssertEqual(Set(m.folders), Set(five).subtracting([WindowSummaryStore.folder]))
        XCTAssertEqual(snapshot(five, base: b), before, "备份和原件逐字一致")
        XCTAssertEqual(Set(m.files?.keys ?? [:].keys), Set(before.keys), "清单里逐个文件都有")
        XCTAssertEqual(m.files?["pending/待续.md"]?.size, "待续本子".utf8.count)
        XCTAssertEqual(MemoryRegeneration.backups(memoryRoot: root).map(\.lastPathComponent), ["v5搬迁-t1"])
    }

    /// B1：拷完大小对不上 → 抛错、不发布正式名字、memory/ 一字不动
    func testMigrationBackupSizeMismatchPublishesNothing() throws {
        try seedBroken()
        try put("pending/待续.md", "待续本子，好几个字")
        let before = snapshot(five)
        let truncating: MemoryRegeneration.FileOp = { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            if from.lastPathComponent == PendingStore.folder {
                try Data("短".utf8).write(to: to.appendingPathComponent(PendingStore.fileName))
            }
        }
        XCTAssertThrowsError(try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v5搬迁-bad", folders: five, copy: truncating)) {
            XCTAssertEqual($0 as? MemoryRegeneration.RegenError, .backupMismatch(PendingStore.folder))
        }
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).isEmpty)
        XCTAssertEqual(snapshot(five), before)
    }

    /// astra #10：同样大小、内容不一样也核得出来
    func testBackupSameSizeDifferentContentIsMismatch() throws {
        try put("pending/待续.md", "甲乙丙")
        let swapped: MemoryRegeneration.FileOp = { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            if from.lastPathComponent == PendingStore.folder {
                try Data("丙乙甲".utf8).write(to: to.appendingPathComponent(PendingStore.fileName))
            }
        }
        XCTAssertThrowsError(try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v5搬迁-same", folders: five, copy: swapped)) {
            XCTAssertEqual($0 as? MemoryRegeneration.RegenError, .backupMismatch(PendingStore.folder))
        }
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).isEmpty)
    }

    /// astra #10：读不了的文件 → 核对直接抛错，不当成 0 字节通过
    func testUnreadableFileStopsBackup() throws {
        try put("pending/待续.md", "待续本子")
        let file = root.appendingPathComponent("pending/待续.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        XCTAssertThrowsError(try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v5搬迁-unread", folders: five))
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: MemoryRegeneration.backupRoot(memoryRoot: root).path)) ?? []
        XCTAssertEqual(leftovers, [], "什么都没建")
    }

    /// astra #5：五个文件夹里（文件夹本身或里面）有符号链接 → 停下、什么都不改、报路径
    func testSymlinkStopsBackup() throws {
        try seedBroken()
        let elsewhere = floor.appendingPathComponent("别处", isDirectory: true)
        try put("待续.md", "活的", in: elsewhere)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(PendingStore.folder), withDestinationURL: elsewhere)
        let before = snapshot(five)
        XCTAssertThrowsError(try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v5搬迁-link", folders: five)) {
            XCTAssertEqual($0 as? MemoryRegeneration.RegenError, .symlink(self.root.appendingPathComponent(PendingStore.folder).path))
        }
        XCTAssertEqual(snapshot(five), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MemoryRegeneration.backupRoot(memoryRoot: root).path), "什么都没建")

        // 里面一层的符号链接也拦
        try FileManager.default.removeItem(at: root.appendingPathComponent(PendingStore.folder))
        let inner = TimelineStore.dir(root: root).appendingPathComponent("2026-12.md")
        try FileManager.default.createSymbolicLink(at: inner, withDestinationURL: elsewhere.appendingPathComponent("待续.md"))
        XCTAssertThrowsError(try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v5搬迁-link2", folders: five)) {
            guard case .symlink(let path)? = $0 as? MemoryRegeneration.RegenError else { return XCTFail("\($0)") }
            XCTAssertTrue(path.hasSuffix("/timeline/2026-12.md"), path)
        }
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).isEmpty)
    }

    /// astra #10：恢复前按清单核备份——文件被改过 / 少了 / 多了都拒绝，现在的一字不动
    func testRestoreRefusesBackupNotMatchingManifest() throws {
        try seedBroken()
        let b = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v5搬迁-t3", folders: five)
        let current = snapshot(five)
        let file = try XCTUnwrap(try MemoryRegeneration.inventory(b.appendingPathComponent(TimelineStore.folder)).keys.sorted().first)
        let url = b.appendingPathComponent(TimelineStore.folder).appendingPathComponent(file)
        let original = try Data(contentsOf: url)
        try Data("被改过".utf8).write(to: url)
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: b, memoryRoot: root, now: date(10, 16, 1))) {
            XCTAssertEqual($0 as? MemoryRegeneration.RegenError, .incompleteBackup("备份里的文件和清单对不上"))
        }
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: b, memoryRoot: root, now: date(10, 16, 1)), "少了")
        try original.write(to: url)
        try put("timeline/多出来的.md", "x", in: b)
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: b, memoryRoot: root, now: date(10, 16, 1)), "多了")
        XCTAssertEqual(snapshot(five), current)
        XCTAssertFalse(MemoryRegeneration.backups(memoryRoot: root).contains { $0.lastPathComponent.hasPrefix("回滚前-") })
    }

    /// astra #11：现在的全部挪开以后、开始拷回以前，「回滚前」就已经发布（备份列表里看得到、清单完整）
    func testRestorePublishesAsideBeforeCopyingBack() throws {
        try seedBroken()
        let b = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v5搬迁-t4", folders: five)
        try put("sessions/新写的.md", "搬完以后写的")
        let current = snapshot(five)
        var seenAtCopy: [String: String]?
        let watching: MemoryRegeneration.FileOp = { from, to in
            if seenAtCopy == nil, let aside = MemoryRegeneration.backups(memoryRoot: self.root).first(where: { $0.lastPathComponent.hasPrefix("回滚前-") }) {
                seenAtCopy = self.snapshot(self.five, base: aside)
                XCTAssertNotNil(MemoryRegeneration.manifest(of: aside)?.files)
            }
            try FileManager.default.copyItem(at: from, to: to)
        }
        try MemoryRegeneration.restore(backup: b, memoryRoot: root, now: date(10, 16, 1), copy: watching)
        XCTAssertEqual(seenAtCopy, current, "拷回第一份以前，回滚前就已经能恢复")
    }

    /// astra #1：恢复失败、挪回也失败 → 挪开的原件一个不删，抛错报出确切路径
    func testRestoreRollbackFailureKeepsAside() throws {
        try seedBroken()
        let b = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v4-1-test")
        try put("timeline/2026-11.md", "备份以后才有的")
        let current = snapshot()
        // 拷时间轴时有人在 memory/ 里又建了 sessions/ 并且删不掉；拷 sessions/ 时失败
        let hostile: MemoryRegeneration.FileOp = { from, to in
            if from.lastPathComponent == SessionSummaryStore.folder {
                try self.put("sessions/占位.md", "别人建的")
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: to.path)
                throw InjectedFailure()
            }
            try FileManager.default.copyItem(at: from, to: to)
        }
        var reported: String?
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: b, memoryRoot: root, now: date(10, 16, 1), copy: hostile)) {
            if case .rollbackIncomplete(let path)? = $0 as? MemoryRegeneration.RegenError { reported = path }
        }
        let aside = try XCTUnwrap(reported.map { URL(fileURLWithPath: $0) }, "报出了路径")
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("回滚前-"))
        // 挪开的原件一个不少：时间轴挪回去了，sessions/ 挪不回去就整份留在回滚前
        var now = snapshot()
        for (k, v) in snapshot([SessionSummaryStore.folder], base: aside) { now[k] = v }
        now["sessions/占位.md"] = nil
        XCTAssertEqual(now, current)
        XCTAssertNotNil(MemoryRegeneration.manifest(of: aside), "回滚前还在、能恢复")
    }

    /// B2：恢复老 v4-1 备份（清单没有 covered、没有文件清单）→ 只动老三个，pending/ summaries/ 原样不动
    func testRestoringOldBackupLeavesPendingAndSummaries() throws {
        try seedBroken()
        let b = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v4-1-old")
        // 老清单：没有 covered 这个字段
        try put("manifest.json", #"{"folders":["timeline","sessions"],"createdAt":"2026-10-11T12:00:00Z"}"#, in: b)
        XCTAssertNil(MemoryRegeneration.manifest(of: b)?.covered)
        try put("pending/待续.md", "搬完以后的待续")
        try put("summaries/conv-old-x.md", "第一代")
        try MemoryRegeneration.restore(backup: b, memoryRoot: root, now: date(10, 16, 1))
        XCTAssertEqual(text("pending/待续.md"), "搬完以后的待续")
        XCTAssertEqual(text("summaries/conv-old-x.md"), "第一代")
        let aside = try XCTUnwrap(MemoryRegeneration.backups(memoryRoot: root).first { $0.lastPathComponent.hasPrefix("回滚前-") })
        XCTAssertEqual(MemoryRegeneration.manifest(of: aside)?.coveredFolders, MemoryRegeneration.folders)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.appendingPathComponent(PendingStore.folder).path), "回滚前也只挪老三个")
    }

    /// B2：恢复 v5 搬迁备份 → 五个都回到备份那刻（备份时没有的 windows/ 恢复后也没有）；待续缓存清掉，读回备份那刻
    func testRestoringMigrationBackupBringsPendingBack() throws {
        let pid = "xctest-regen-pending"
        let proot = FileLibraryStore.memoryRoot(profileId: pid)
        defer {
            PendingStore.forget(profileId: pid)
            UserDefaults.standard.removeObject(forKey: PendingStore.migratedKey(profileId: pid))
            try? FileManager.default.removeItem(at: proot.deletingLastPathComponent())
        }
        try PendingStore.add(["问结果"], conversationId: "c1", day: "2026-10-14", anchor: nil, profileId: pid)
        try put("summaries/conv-old-x.md", "第一代", in: proot)
        try put("sessions/c1.md", "老 A2", in: proot)
        let b = try MemoryRegeneration.makeBackup(memoryRoot: proot, name: "v5搬迁-t2", folders: five)
        try PendingStore.add(["搬完才有的"], conversationId: "c1", day: "2026-10-16", anchor: nil, profileId: pid)
        try put("windows/c1.md", "新 A3", in: proot)
        try put("sessions/c1.md", "新 A2", in: proot)
        XCTAssertEqual(PendingStore.load(profileId: pid)?.count, 2)
        try MemoryRegeneration.restore(backup: b, memoryRoot: proot, now: date(10, 16, 2), profileId: pid)
        XCTAssertEqual(PendingStore.load(profileId: pid)?.map(\.text), ["问结果"], "待续本子回到备份那刻")
        XCTAssertEqual(text("sessions/c1.md", in: proot), "老 A2")
        XCTAssertEqual(text("summaries/conv-old-x.md", in: proot), "第一代")
        XCTAssertFalse(FileManager.default.fileExists(atPath: proot.appendingPathComponent(WindowSummaryStore.folder).path),
                       "备份时原本没有的 windows/，恢复后也没有")
        let aside = try XCTUnwrap(MemoryRegeneration.backups(memoryRoot: proot).first { $0.lastPathComponent.hasPrefix("回滚前-") })
        XCTAssertEqual(text("windows/c1.md", in: aside), "新 A3", "搬完以后写的挪进回滚前")
        XCTAssertEqual(MemoryRegeneration.manifest(of: aside)?.covered, five)
    }

    private func pendingFloor(_ pid: String) -> URL {
        let proot = FileLibraryStore.memoryRoot(profileId: pid)
        addTeardownBlock {
            PendingStore.forget(profileId: pid)
            UserDefaults.standard.removeObject(forKey: PendingStore.migratedKey(profileId: pid))
            try? FileManager.default.removeItem(at: proot.deletingLastPathComponent())
        }
        return proot
    }

    /// astra #7：恢复失败也清待续缓存——盘上的本子和缓存不一样时，失败挪回来以后读的是盘上的
    func testRestoreFailureStillForgetsPendingCache() throws {
        let pid = "xctest-regen-pending-fail"
        let proot = pendingFloor(pid)
        try PendingStore.add(["问结果"], conversationId: "c1", day: "2026-10-14", anchor: nil, profileId: pid)
        try put("sessions/c1.md", "老 A2", in: proot)
        let b = try MemoryRegeneration.makeBackup(memoryRoot: proot, name: "v5搬迁-t5", folders: five)
        XCTAssertEqual(PendingStore.load(profileId: pid)?.count, 1, "缓存热着")
        let onDisk = [PendingItem(id: "p0001", text: "问结果", state: .done, conversationId: "c1", day: "2026-10-14", anchor: nil)]
        try Data(PendingStore.render(onDisk).utf8).write(to: PendingStore.fileURL(profileId: pid))
        let failing: MemoryRegeneration.FileOp = { from, to in
            if from.lastPathComponent == SessionSummaryStore.folder { throw InjectedFailure() }
            try FileManager.default.copyItem(at: from, to: to)
        }
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: b, memoryRoot: proot, now: date(10, 16, 2), copy: failing, profileId: pid))
        XCTAssertEqual(PendingStore.load(profileId: pid), onDisk, "缓存清了，读回挪回来的那份")
    }

    /// astra #7：恢复期间改待续（pending_notes / 设置里改）要等恢复做完，落在恢复以后的本子上，不拿旧缓存整份写回去
    func testPendingEditDuringRestoreWaitsAndLandsOnRestored() throws {
        let pid = "xctest-regen-pending-lock"
        let proot = pendingFloor(pid)
        try PendingStore.add(["问结果"], conversationId: "c1", day: "2026-10-14", anchor: nil, profileId: pid)
        let b = try MemoryRegeneration.makeBackup(memoryRoot: proot, name: "v5搬迁-t6", folders: five)
        try PendingStore.add(["现在的"], conversationId: "c1", day: "2026-10-16", anchor: nil, profileId: pid)
        let added = DispatchSemaphore(value: 0)
        var blocked = false
        let editing: MemoryRegeneration.FileOp = { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            guard from.lastPathComponent == PendingStore.folder else { return }
            Thread.detachNewThread {
                _ = try? PendingStore.add(["恢复中加的"], conversationId: "c1", day: "2026-10-16", anchor: nil, profileId: pid)
                added.signal()
            }
            blocked = added.wait(timeout: .now() + 0.3) == .timedOut
        }
        try MemoryRegeneration.restore(backup: b, memoryRoot: proot, now: date(10, 16, 2), copy: editing, profileId: pid)
        XCTAssertTrue(blocked, "恢复拿着锁，改待续进不来")
        XCTAssertEqual(added.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(PendingStore.load(profileId: pid)?.map(\.text), ["问结果", "恢复中加的"], "加在恢复以后的本子上，旧缓存没写回去")
    }

    // MARK: - astra #6 搬迁 / 恢复全局一趟

    @MainActor
    func testMaintenanceGateIsExclusiveAndReleases() async {
        let gate = MemoryMaintenance.shared
        var inner: Result<String, MemoryMaintenance.Refusal> = .success("还没试")
        let outer = await gate.exclusive("搬迁") { () async -> String in
            XCTAssertEqual(gate.holder, "搬迁")
            inner = await gate.exclusive("恢复") { () async -> String in "不该跑" }
            return "跑了"
        }
        XCTAssertEqual(outer, .success("跑了"))
        XCTAssertEqual(inner, .failure(.held), "另一趟拿不到资格，什么都不跑")
        XCTAssertNil(gate.holder, "结束放开")
        let regenerating = await SessionCloseout.shared.regenerating
        XCTAssertFalse(regenerating, "日常写手放开")
        let again = await gate.exclusive("恢复") { "又能跑了" }
        XCTAssertEqual(again, .success("又能跑了"))
    }
}
