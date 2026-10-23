import XCTest
@testable import 记忆花园

/// #067 第 3 步：主列表删除只碰活着的、多选钉住 / 取消钉住、「已删除」分组、{{char}}自己记下的彻底删除。
final class MemoryTrashTests: XCTestCase {

    let pid = "xctest-memory-trash"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func mem(_ content: String, deletedAt: Date? = nil, pinned: Bool = false, category: String = "fact") -> Memory {
        let m = Memory(content: content, category: category, profileId: pid, isUserExplicit: pinned)
        m.supersededAt = deletedAt
        return m
    }

    private func selfMem(_ name: String, deletedAt: Date? = nil, origin: String = "self", type: String = "user") -> SelfMemory {
        SelfMemory(slug: SelfMemoryStore.slugify(name), name: name, description: "关于\(name)", type: type, importance: 4,
                   origin: origin, created: Date(timeIntervalSince1970: 1_000), source: nil, superseded: deletedAt, body: "正文")
    }

    // MARK: - 删除只碰活着的

    func testMoveToTrashNeverTouchesAlreadyDeleted() {
        let old = Date(timeIntervalSince1970: 100)
        let live1 = mem("活1"), live2 = mem("活2"), dead = mem("早删了", deletedAt: old)
        let now = Date(timeIntervalSince1970: 5_000)
        let moved = MemoryDeletePlan.moveToTrash([live1, dead, live2], now: now)
        XCTAssertEqual(moved, [live1.id, live2.id])
        XCTAssertEqual(live1.supersededAt, now)
        XCTAssertEqual(live2.supersededAt, now)
        XCTAssertEqual(dead.supersededAt, old)
        XCTAssertNotEqual(dead.updatedAt, now)
    }

    func testMoveToTrashOnlyDeletedIsNoop() {
        let old = Date(timeIntervalSince1970: 100)
        let dead = mem("早删了", deletedAt: old)
        XCTAssertTrue(MemoryDeletePlan.moveToTrash([dead]).isEmpty)
        XCTAssertEqual(dead.supersededAt, old)
    }

    func testPurgeTitle() {
        XCTAssertEqual(MemoryDeletePlan.purgeTitle(1), "彻底删除这条记忆？")
        XCTAssertEqual(MemoryDeletePlan.purgeTitle(3), "彻底删除 3 条记忆？")
    }

    // MARK: - 多选钉住

    func testPinWhenAnyUnpinned() {
        let a = mem("a", pinned: true), b = mem("b")
        XCTAssertFalse(MemoryPinPlan.unpins([a, b]))
        MemoryPinPlan.apply([a, b])
        XCTAssertTrue(a.isUserExplicit)
        XCTAssertTrue(b.isUserExplicit)
    }

    func testUnpinWhenAllPinned() {
        let a = mem("a", pinned: true), b = mem("b", pinned: true)
        XCTAssertTrue(MemoryPinPlan.unpins([a, b]))
        MemoryPinPlan.apply([a, b])
        XCTAssertFalse(a.isUserExplicit)
        XCTAssertFalse(b.isUserExplicit)
        XCTAssertFalse(MemoryPinPlan.unpins([]))
    }

    // MARK: - 「已删除」分组

    func testTrashGroupsBatchAndScattered() {
        let t = Date(timeIntervalSince1970: 10_000)
        let batch = [mem("合1", deletedAt: t), mem("合2", deletedAt: t.addingTimeInterval(5)), mem("合3", deletedAt: t.addingTimeInterval(20))]
        let loneOld = mem("单删旧", deletedAt: t.addingTimeInterval(-3_600))
        let live = mem("活着的")
        let selfDead = selfMem("划掉的", deletedAt: t.addingTimeInterval(3_600))
        let selfLive = selfMem("还在")

        let g = MemoryRevival.trash(archive: batch + [loneOld, live], assistant: [selfDead, selfLive])
        XCTAssertEqual(g.batches.count, 1)
        XCTAssertEqual(Set(g.batches[0].memories.map(\.id)), Set(batch.map(\.id)))
        XCTAssertEqual(g.scattered.map(\.id), [.assistant(selfDead.slug), .archive(loneOld.id)])
        XCTAssertFalse(g.scattered.contains { $0.id == .archive(live.id) || $0.id == .assistant(selfLive.slug) })
    }

    func testTrashTwoDeletionsAreScatteredNotBatch() {
        let t = Date(timeIntervalSince1970: 10_000)
        let g = MemoryRevival.trash(archive: [mem("a", deletedAt: t), mem("b", deletedAt: t.addingTimeInterval(1))], assistant: [])
        XCTAssertTrue(g.batches.isEmpty)
        XCTAssertEqual(g.scattered.count, 2)
    }

    // MARK: - 行数据

    func testRowItemInfoLines() {
        let cal = Calendar.current
        let thisYear = cal.date(from: DateComponents(year: cal.component(.year, from: Date()), month: 3, day: 2))!
        let pinned = MemoryRowItem(mem("猫", pinned: true, category: "preference"))
        XCTAssertTrue(pinned.pinned)
        XCTAssertNil(pinned.importance)

        let deleted = MemoryRowItem(mem("旧", deletedAt: thisYear, category: "context"))
        XCTAssertEqual(deleted.infoLine, "近况 · 删于 3月2日")
        XCTAssertTrue(deleted.isDeleted)

        let asked = MemoryRowItem(selfMem("配色", origin: "asked", type: "feedback"))
        XCTAssertEqual(asked.id, .assistant("配色"))
        XCTAssertEqual(asked.text, "关于配色")
        XCTAssertTrue(asked.infoLine.hasPrefix("你的要求 · 你让记的 · "), asked.infoLine)
        XCTAssertEqual(asked.importance, 4)
    }

    // MARK: - {{char}}自己记下的彻底删除

    func testSelfMemoryDeleteRemovesFileAndIndexEntry() throws {
        let keep = selfMem("留着"), gone = selfMem("要删")
        try SelfMemoryStore.save(keep, profileId: pid)
        try SelfMemoryStore.save(gone, profileId: pid)
        let dir = SelfMemoryStore.directory(profileId: pid)
        let index = dir.appendingPathComponent(SelfMemoryStore.indexFileName)
        XCTAssertTrue(try String(contentsOf: index, encoding: .utf8).contains(gone.fileName))

        try SelfMemoryStore.delete(slug: gone.slug, profileId: pid)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(gone.fileName).path))
        XCTAssertEqual(SelfMemoryStore.list(profileId: pid).map(\.slug), [keep.slug])
        let indexText = try String(contentsOf: index, encoding: .utf8)
        XCTAssertFalse(indexText.contains(gone.fileName))
        XCTAssertTrue(indexText.contains(keep.fileName))
    }

    func testSelfMemoryDeleteMissingThrows() {
        XCTAssertThrowsError(try SelfMemoryStore.delete(slug: "没有这条", profileId: pid))
    }
}
