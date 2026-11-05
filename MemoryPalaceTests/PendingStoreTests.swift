import XCTest
@testable import 记忆花园

/// v5 §八：待续单独存 memory/pending/待续.md，一条一行三态；迁移只拆每个窗口最新一条条目、条目文件不动、只跑一次
final class PendingStoreTests: XCTestCase {

    let pid = "xctest-pending-store"

    override func tearDown() {
        PendingStore.forget(profileId: pid)
        UserDefaults.standard.removeObject(forKey: PendingStore.migratedKey(profileId: pid))
        UserDefaults.standard.removeObject(forKey: TimelineDaily.backupKey(pid))
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func entry(_ conv: String, day: String, hour: Int, pending: String) -> TimelineEntry {
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: Int(day.suffix(2))!, hour: hour))!
        return TimelineEntry(start: start, end: start.addingTimeInterval(600), conversationId: conv, title: "T",
                             text: "- 话题", pending: pending, day: day, lastNodeId: "last-\(conv)-\(day)")
    }

    func testRenderParseRoundTrip() {
        let items = [
            PendingItem(id: "p0001", text: "周三复诊结果要问", state: .open, conversationId: "conv-aaaa1111", day: "2026-10-14", anchor: "n9"),
            PendingItem(id: "p0002", text: "把搬家清单列完", state: .faded, conversationId: "conv-bbbb2222", day: "2026-10-13", anchor: nil),
        ]
        XCTAssertEqual(PendingStore.parse(PendingStore.render(items)), items)
    }

    func testAddingDedupesOpenInSameWindow() {
        var items: [PendingItem] = []
        let a = PendingStore.adding(["问结果", "无", " ", "问结果"], conversationId: "c1", day: "2026-10-14", anchor: "n1", to: &items)
        XCTAssertEqual(a.map(\.text), ["问结果"], "「无」和空的不加；一字不差的不加")
        XCTAssertEqual(a.first?.id, "p0001")
        items[0].state = .done
        let b = PendingStore.adding(["问结果"], conversationId: "c1", day: "2026-10-15", anchor: "n2", to: &items)
        XCTAssertEqual(b.first?.id, "p0002", "做完了的不挡新的")
        let c = PendingStore.adding(["问结果"], conversationId: "c2", day: "2026-10-15", anchor: nil, to: &items)
        XCTAssertEqual(c.count, 1, "别的窗口照加")
    }

    func testMigrationOnlyLatestEntryPerWindowAndOnce() throws {
        let dir = TimelineStore.dir(profileId: pid)
        try TimelineStore.seedLegacy(entry("conv-1", day: "2026-10-12", hour: 10, pending: "旧的"), in: dir)
        try TimelineStore.seedLegacy(entry("conv-1", day: "2026-10-14", hour: 10, pending: "问结果\n买药"), in: dir)
        try TimelineStore.seedLegacy(entry("conv-2", day: "2026-10-13", hour: 10, pending: "无"), in: dir)
        let before = try String(contentsOf: dir.appendingPathComponent("2026-10.md"), encoding: .utf8)
        XCTAssertNil(PendingStore.load(profileId: pid), "没迁移 = nil")

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pending-store-\(UUID().uuidString)"))
        let backup = try TimelineDaily.ensurePendingMigrated(profileId: pid, defaults: defaults)
        XCTAssertNotNil(backup, "迁之前先备份")
        XCTAssertTrue(PendingStore.isLegacyDone(profileId: pid))
        let items = try XCTUnwrap(PendingStore.load(profileId: pid))
        XCTAssertEqual(items.map(\.text), ["问结果", "买药"], "每个窗口只拆最新一条")
        XCTAssertTrue(items.allSatisfy { $0.state == .open && $0.conversationId == "conv-1" && $0.day == "2026-10-14" })
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("2026-10.md"), encoding: .utf8), before, "条目文件不动")

        try PendingStore.setState(items[0].id, .done, profileId: pid)
        XCTAssertNil(try TimelineDaily.ensurePendingMigrated(profileId: pid, defaults: defaults))
        XCTAssertEqual(PendingStore.load(profileId: pid)?.first?.state, .done, "迁完了不再跑，不覆盖")
    }

    /// astra 二轮 #2：以前宽松入口先建了本子、漏了一个月（那时读不了）——本子在不算迁完；严格迁移补上漏的，已有的三态 / 改过的字不动、不重复
    func testStrictMigrationFillsGapsLeftByLenientPath() throws {
        let dir = TimelineStore.dir(profileId: pid)
        let sept = entry("conv-9", day: "2026-10-01", hour: 10, pending: "九月那条")
        try TimelineStore.seedLegacy(entry("conv-1", day: "2026-10-14", hour: 10, pending: "问结果\n买药"), in: dir)
        try TimelineStore.seedLegacy(sept, in: dir)
        // 宽松入口当年迁的：只有 conv-1（没来源身份），她把「买药」改成「买感冒药」、标了做完
        try PendingStore.mutate(profileId: pid) { items in
            items = [PendingItem(id: "p0001", text: "问结果", state: .open, conversationId: "conv-1", day: "2026-10-14", anchor: "last-conv-1-2026-10-14"),
                     PendingItem(id: "p0002", text: "买感冒药", state: .done, conversationId: "conv-1", day: "2026-10-14", anchor: "last-conv-1-2026-10-14")]
        }
        XCTAssertFalse(PendingStore.isLegacyDone(profileId: pid), "本子在 ≠ 迁完")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pending-store-\(UUID().uuidString)"))
        try TimelineDaily.ensurePendingMigrated(profileId: pid, defaults: defaults)
        let items = try XCTUnwrap(PendingStore.load(profileId: pid))
        XCTAssertEqual(items.map(\.text), ["问结果", "买感冒药", "九月那条"], "漏的补上，以前迁过的整条不重复")
        XCTAssertEqual(items[1].state, .done)
        XCTAssertEqual(items[2].source.map { $0.hasPrefix("o") }, true)
        XCTAssertTrue(PendingStore.isLegacyDone(profileId: pid))
        try PendingStore.setText(items[2].id, "九月那条改过了", profileId: pid)
        XCTAssertTrue(PendingStore.isLegacyDone(profileId: pid), "日常改字不碰迁完标记")
    }

    /// 有一个月读不了：严格迁移抛，本子原样、不标迁完
    func testStrictMigrationStopsOnUnreadableMonth() throws {
        let dir = TimelineStore.dir(profileId: pid)
        try TimelineStore.seedLegacy(entry("conv-1", day: "2026-10-14", hour: 10, pending: "问结果"), in: dir)
        try Data("<!-- entry 坏的 -->\n".utf8).write(to: dir.appendingPathComponent("2026-09.md"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pending-store-\(UUID().uuidString)"))
        XCTAssertThrowsError(try TimelineDaily.ensurePendingMigrated(profileId: pid, defaults: defaults))
        XCTAssertNil(PendingStore.load(profileId: pid))
        XCTAssertFalse(PendingStore.isLegacyDone(profileId: pid))
    }

    /// astra 三轮 #1：老待续迁不好（本子有一行认不出）→ 看 / 改之前就停：改三态、改字都被拒，那一行和别的行一个字节不丢
    func testEditRefusedWhileBookUnreadableOrNotMigrated() throws {
        let dir = TimelineStore.dir(profileId: pid)
        try TimelineStore.seedLegacy(entry("conv-1", day: "2026-10-14", hour: 10, pending: "问结果"), in: dir)
        let url = PendingStore.fileURL(profileId: pid)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = PendingStore.render([PendingItem(id: "p0001", text: "认得的", state: .open, conversationId: "c1", day: "2026-10-14", anchor: nil)])
            + "\n- 机读注释坏了的一行 <!-- id=p0002 -->"
        try Data(raw.utf8).write(to: url)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pending-store-\(UUID().uuidString)"))
        XCTAssertThrowsError(try TimelineDaily.preparePendingForEdit(profileId: pid, defaults: defaults))
        XCTAssertThrowsError(try PendingStore.setState("p0001", .done, profileId: pid), "迁不好不许改")
        XCTAssertThrowsError(try PendingStore.setText("p0001", "改字", profileId: pid))
        XCTAssertThrowsError(try PendingStore.mutate(profileId: pid) { $0[0].state = .done }, "底层也严格读实际文件，认不出就拒写")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), raw, "坏行和好行都原样")
        let tool = PendingNotesTool.execute(inputJSON: #"{"action":"done","id":"p0001"}"#, profileId: pid, conversationId: nil)
        XCTAssertTrue(tool.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), raw)
    }

    /// astra 三轮 #4：升级前本子里的老条目（没有原文哈希）：严格迁移按来源对上、补记身份——字没改的、改过字并标了做完的都算搬过；
    /// 之后 A2 里同一句再来不会新加一条 open
    func testOldBookEntriesGetOriginAndAreNotReharvested() throws {
        let dir = TimelineStore.dir(profileId: pid)
        try TimelineStore.seedLegacy(entry("conv-1", day: "2026-10-14", hour: 10, pending: "问结果\n买药"), in: dir)
        try PendingStore.mutate(profileId: pid) { items in
            items = [PendingItem(id: "p0001", text: "问结果", state: .open, conversationId: "conv-1", day: "2026-10-14", anchor: "last-conv-1-2026-10-14"),
                     PendingItem(id: "p0002", text: "买感冒药", state: .done, conversationId: "conv-1", day: "2026-10-14", anchor: "last-conv-1-2026-10-14"),
                     PendingItem(id: "p0003", text: "列清单", state: .open, conversationId: "conv-2", day: "2026-10-13", anchor: nil)]
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pending-store-\(UUID().uuidString)"))
        try TimelineDaily.ensurePendingMigrated(profileId: pid, defaults: defaults)
        var items = try XCTUnwrap(PendingStore.load(profileId: pid))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].origin, PendingStore.hash("问结果"))
        XCTAssertEqual(items[1].origin, PendingStore.hash("买药"), "改过字的按来源对上剩下的原文")
        let a2 = PendingStore.Candidate(conversationId: "conv-1", day: "2026-10-15", anchor: "n9", texts: ["买药", "问结果"], source: "seg")
        XCTAssertEqual(try PendingStore.addCandidates([a2], profileId: pid), [], "A2 里同一句不再新加 open")
        // 一字不差对上的也补记身份：之后她改字，同一句照样不再搬
        let c2 = PendingStore.Candidate(conversationId: "conv-2", day: "2026-10-15", anchor: nil, texts: ["列清单"], source: "seg2")
        XCTAssertEqual(try PendingStore.addCandidates([c2], profileId: pid), [])
        items = try XCTUnwrap(PendingStore.load(profileId: pid))
        XCTAssertEqual(items[2].origin, PendingStore.hash("列清单"))
        try PendingStore.setText("p0003", "列搬家清单", profileId: pid)
        XCTAssertEqual(try PendingStore.addCandidates([c2], profileId: pid), [])
        XCTAssertEqual(PendingStore.load(profileId: pid)?.count, 3)
    }

    /// astra 四轮 #2：待补读不了 → 不当空的、不覆盖（入队抛）；搬的时候只搬这一批，坏的那份原样留着
    func testCorruptRetryQueueNotOverwritten() throws {
        let url = PendingStore.retryURL(profileId: pid, memoryRoot: nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("坏了的待补".utf8).write(to: url)
        let c = PendingStore.Candidate(conversationId: "c1", day: "2026-10-14", anchor: nil, texts: ["问结果"], source: "s")
        XCTAssertThrowsError(try PendingStore.retryQueueStrict(profileId: pid))
        XCTAssertThrowsError(try PendingStore.enqueueRetry([c], profileId: pid))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "坏了的待补")
        XCTAssertEqual(try PendingStore.addCandidatesFlushingRetry([c], profileId: pid).map(\.text), ["问结果"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "坏了的待补", "坏的那份不动")
    }

    /// astra 二轮 #7：搬进来的按原文哈希去重——她改了字、标了做完，同一句再来不重搬
    func testImportDedupesByOriginAfterEdit() {
        var items: [PendingItem] = []
        let c = PendingStore.Candidate(conversationId: "c1", day: "2026-10-14", anchor: "n1", texts: ["买药", "无"], source: "s1")
        XCTAssertEqual(PendingStore.importing([c], into: &items).map(\.text), ["买药"])
        items[0].text = "买感冒药"
        items[0].state = .done
        XCTAssertEqual(PendingStore.importing([c], into: &items), [], "改了字、做完了都不重搬")
        let other = PendingStore.Candidate(conversationId: "c1", day: "2026-10-15", anchor: "n9", texts: ["买药"], source: "s2")
        XCTAssertEqual(PendingStore.importing([other], into: &items), [], "同一窗口同一句（别的段）也不重复")
        let elsewhere = PendingStore.Candidate(conversationId: "c2", day: "2026-10-15", anchor: nil, texts: ["买药"], source: "s3")
        XCTAssertEqual(PendingStore.importing([elsewhere], into: &items).count, 1, "别的窗口照加")
        XCTAssertEqual(PendingStore.parse(PendingStore.render(items)), items, "来源身份 / 原文哈希存读一样")
    }

    func testStateTextAndOpenByConversation() throws {
        try PendingStore.add(["问结果", "讲完故事"], conversationId: "c1", day: "2026-10-14", anchor: "n1", profileId: pid)
        try PendingStore.add(["列清单"], conversationId: "c2", day: "2026-10-14", anchor: nil, profileId: pid)
        try PendingStore.setState("p0002", .faded, profileId: pid)
        try PendingStore.setText("p0001", "问复诊结果\n（周三）", profileId: pid)
        XCTAssertEqual(PendingStore.openByConversation(profileId: pid)?["c1"], ["问复诊结果 （周三）"], "淡了的不带；改字压成一行")
        XCTAssertEqual(PendingStore.openByConversation(profileId: pid)?["c2"], ["列清单"])
        PendingStore.forget(profileId: pid)
        XCTAssertEqual(PendingStore.load(profileId: pid)?.count, 3, "落盘了，换缓存照样读回来")
    }

    /// astra #5：组 prompt 读快照——没迁移的楼层 nil（照读老字段）；迁移过但还没热 → 空的（这一轮不带，别把做完的老字段翻出来）
    func testCachedDistinguishesNotMigratedFromCold() throws {
        XCTAssertNil(PendingStore.openByConversationCached(profileId: pid), "没迁移 = nil")
        XCTAssertFalse(PendingStore.isMigrated(profileId: pid))

        try PendingStore.add(["做完的", "问结果"], conversationId: "c1", day: "2026-10-14", anchor: nil, profileId: pid)
        XCTAssertTrue(PendingStore.isMigrated(profileId: pid), "写过一次 = 迁移过")
        try PendingStore.setState("p0001", .done, profileId: pid)
        XCTAssertEqual(PendingStore.openByConversationCached(profileId: pid), ["c1": ["问结果"]], "做完了的不带")

        PendingStore.forget(profileId: pid)   // 冷启动 / 切楼层：缓存没热
        XCTAssertEqual(PendingStore.openByConversationCached(profileId: pid), [:], "迁移过但没热：这一轮不带，不是 nil")
        _ = PendingStore.load(profileId: pid)   // 后台预热读完
        XCTAssertEqual(PendingStore.openByConversationCached(profileId: pid), ["c1": ["问结果"]], "热好了下一轮就对")
    }

    /// astra #5：有人正拿着锁写盘时，组 prompt 沿用上一份快照（不回退、不读盘）
    func testCachedKeepsSnapshotWhileWriting() throws {
        try PendingStore.add(["问结果"], conversationId: "c1", day: "2026-10-14", anchor: nil, profileId: pid)
        let inside = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = expectation(description: "写完")
        DispatchQueue.global().async {
            _ = try? PendingStore.mutate(profileId: self.pid) { items in
                inside.signal()
                release.wait()
                items[0].state = .done
            }
            done.fulfill()
        }
        inside.wait()
        XCTAssertEqual(PendingStore.openByConversationCached(profileId: pid), ["c1": ["问结果"]], "锁被占着：沿用上一份")
        release.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(PendingStore.openByConversationCached(profileId: pid), [:], "写完换新")
    }
}
