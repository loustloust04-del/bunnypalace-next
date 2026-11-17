import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 11-15「一条 C2 原子事实只剩一张详情页、一份列表、一个 Deleted」：从哪个入口改 / 删 / 钉 / 加都走 `MemoryEntryActions`
/// （记进记忆日志、能 Undo、保存不自动钉）；记忆页和整理台同一个数；Deleted 一个口径；Source 那一句只在靠得住时标；Why 只在有理由时出。全虚构
@MainActor
final class MemoryEntryActionsTests: XCTestCase {
    private let pid = "xctest-memory-entry-actions"
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func mem(_ content: String, reviewed: Bool = false, deleted: Bool = false, pinned: Bool = false) -> Memory {
        let m = Memory(content: content, category: "fact", profileId: pid, isUserExplicit: pinned)
        m.occurredDay = "2026-11-10"
        m.reviewedAt = reviewed ? Date(timeIntervalSince1970: 1_000) : nil
        m.supersededAt = deleted ? Date(timeIntervalSince1970: 2_000) : nil
        context.insert(m)
        return m
    }

    private var log: [MemoryAuditLog.Entry] { MemoryAuditLog.load(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) }

    // MARK: - 一份列表：记忆页那排筛选和整理台三段同一个数

    func testListFilterCountsMatchAuditDesk() throws {
        mem("岚舟喜欢云桥城的雨")
        mem("星砚养了一只灰猫")
        mem("岚舟在学陶艺", reviewed: true)
        mem("钉住的那条", reviewed: true, pinned: true)
        mem("删掉的一", deleted: true)
        mem("删掉的二", reviewed: true, deleted: true)
        try context.save()
        let all = SwiftDataMemoryStore().listAll(profileId: pid, context: context)

        let page = MemoryListFilter.counts(all)
        let desk = MemoryAudit.counts(all, filter: MemoryAudit.Filter())
        XCTAssertEqual(page[.draft], desk[.unreviewed], "记忆页 Draft = 整理台 Draft")
        XCTAssertEqual(page[.archive], desk[.kept], "记忆页 Archive = 整理台 Archive（钉住的也算在里面）")
        XCTAssertEqual(page[.all], 4, "全部 = 活着的 = Draft + Archive")
        XCTAssertEqual(page[.draft], 2)
        XCTAssertEqual(page[.archive], 2)

        XCTAssertEqual(all.filter(MemoryListFilter.draft.matches).count, page[.draft], "筛出来的行数和牌子上的数一样")
        XCTAssertEqual(all.filter(MemoryListFilter.archive.matches).count, page[.archive])
        XCTAssertEqual(all.filter(MemoryListFilter.all.matches).count, page[.all], "全部里没有删掉的")
        XCTAssertTrue(all.filter(MemoryListFilter.all.matches).contains { $0.isUserExplicit }, "钉住的也在这份列表里（11-15 起列表是全的）")
    }

    /// 一个 Deleted：记忆页底那一行和整理台第三段同一个数 = 删掉的原子事实 + {助手}划掉的
    func testDeletedCountIsOneNumber() throws {
        mem("活的")
        mem("删掉的一", deleted: true)
        mem("删掉的二", reviewed: true, deleted: true)
        try context.save()
        let all = SwiftDataMemoryStore().listAll(profileId: pid, context: context)
        func selfMem(_ name: String, deleted: Bool) -> SelfMemory {
            SelfMemory(slug: SelfMemoryStore.slugify(name), name: name, description: name, type: "user", importance: 3,
                       origin: "self", created: Date(timeIntervalSince1970: 1_000), source: nil,
                       superseded: deleted ? Date(timeIntervalSince1970: 3_000) : nil, body: "正文")
        }
        let selfs = [selfMem("星砚划掉的", deleted: true), selfMem("星砚还记着的", deleted: false)]

        let deskTrashed = MemoryAudit.counts(all, filter: MemoryAudit.Filter())[.trashed] ?? 0
        XCTAssertEqual(MemoryAudit.deletedCount(all, selfMemories: selfs), deskTrashed + 1)
        XCTAssertEqual(MemoryAudit.deletedCount(all, selfMemories: selfs), 3)
        let grouped = MemoryRevival.trash(archive: all.filter { $0.supersededAt != nil }, assistant: selfs)
        XCTAssertEqual(grouped.batches.reduce(0) { $0 + $1.memories.count } + grouped.scattered.count, 3, "Deleted 里列出来的条数 = 这个数")
    }

    // MARK: - 保存不自动钉；改 / 删 / 钉都进记忆日志、能 Undo

    func testSaveDoesNotPinAndIsUndoable() throws {
        let m = mem("岚舟喜欢云桥城的雨")
        try context.save()
        var edit = MemoryAudit.Edit(m)
        edit.text = "岚舟喜欢云桥城的雪"
        let out = MemoryEntryActions.save(edit, to: m, context: context)

        XCTAssertTrue(out.ok)
        XCTAssertFalse(m.isUserExplicit, "11-15：保存不再自动钉，钉不钉只看 ⋯ 里的 Pin")
        XCTAssertNotNil(m.reviewedAt, "Draft 改完算 Approve")
        XCTAssertEqual(m.confidence, MemoryAudit.handEditedConfidence, "她改过 = 100")
        XCTAssertEqual(log.first?.action, .edit)
        XCTAssertEqual(log.first?.actor, MemoryAuditLog.you)

        let undone = MemoryEntryActions.undo(try XCTUnwrap(out.undoable), profileId: pid, context: context)
        XCTAssertNil(undone.error)
        XCTAssertEqual(undone.text, "Undone 1")
        XCTAssertEqual(m.content, "岚舟喜欢云桥城的雨")
        XCTAssertNil(m.reviewedAt, "撤回 = 回到 Draft")
    }

    func testUnchangedSaveWritesNothing() throws {
        let m = mem("星砚养了一只灰猫", reviewed: true)
        try context.save()
        let out = MemoryEntryActions.save(MemoryAudit.Edit(m), to: m, context: context)
        XCTAssertTrue(out.ok)
        XCTAssertNil(out.entry)
        XCTAssertTrue(log.isEmpty, "什么都没改不记")
    }

    /// 每一笔都记着是不是从整批的入口来的：单张、手挑的几张 = 逐条；把眼前列着的全选了再删、Delete all = 整批
    func testDeleteEntriesCarryWhetherTheyWereBulk() throws {
        let a = mem("岚舟喜欢云桥城的雨"), b = mem("星砚养了一只灰猫"), c = mem("岚舟在栎川镇住过"), d = mem("槐序巷皮影作坊周一不开门")
        try context.save()
        XCTAssertFalse(MemoryEntryActions.isBulk(picked: 1, shown: 1), "只有一条、删的就是它：逐条")
        XCTAssertFalse(MemoryEntryActions.isBulk(picked: 2, shown: 5), "手挑了其中两条：逐条")
        XCTAssertTrue(MemoryEntryActions.isBulk(picked: 5, shown: 5), "全选了再删：整批")
        XCTAssertFalse(MemoryEntryActions.isBulk(picked: 1, shown: 9))

        let one = MemoryEntryActions.trash([a], profileId: pid, context: context)
        XCTAssertEqual(one.entry?.bulk, false)
        let all = MemoryEntryActions.trash([b, c], profileId: pid, context: context, bulk: true)
        XCTAssertEqual(all.entry?.bulk, true)
        XCTAssertEqual(log.map(\.bulk), [true, false], "存进文件了")
        let undo = MemoryEntryActions.undo(try XCTUnwrap(one.undoable), profileId: pid, context: context)
        XCTAssertNil(undo.error)
        XCTAssertNil(log.first?.bulk, "Undo 那一笔不带")
        XCTAssertEqual(MemoryEntryActions.approve([d], profileId: pid, context: context).entry?.bulk, false)

        let cards = SwiftDataMemoryStore().listAll(profileId: pid, context: context).map { (id: $0.id, supersededAt: $0.supersededAt) }
        XCTAssertTrue(MemoryAuditLog.handDeleted(cards, entries: log).isEmpty, "单删的被撤了、另外两条是整批删的：一条都不算")
        _ = MemoryEntryActions.trash([a], profileId: pid, context: context)
        XCTAssertEqual(MemoryAuditLog.handDeleted(SwiftDataMemoryStore().listAll(profileId: pid, context: context).map { (id: $0.id, supersededAt: $0.supersededAt) },
                                                  entries: log), [a.id], "她又单删了一次：算")
    }

    /// 记忆页左滑 / 长按 / 多选删：进 Deleted、记一笔 Delete、能 Undo
    func testTrashFromMemoryPageIsLoggedAndUndoable() throws {
        let a = mem("岚舟喜欢云桥城的雨"), b = mem("星砚养了一只灰猫", reviewed: true)
        try context.save()
        let out = MemoryEntryActions.trash([a, b], profileId: pid, context: context)
        XCTAssertNotNil(a.supersededAt)
        XCTAssertNotNil(b.supersededAt)
        XCTAssertEqual(out.entry?.action, .delete)
        XCTAssertEqual(out.entry?.items.count, 2)
        XCTAssertEqual(MemoryEntryActions.toastText(try XCTUnwrap(out.entry)), "Deleted 2")

        _ = MemoryEntryActions.undo(try XCTUnwrap(out.undoable), profileId: pid, context: context)
        XCTAssertNil(a.supersededAt)
        XCTAssertNil(b.supersededAt)
        XCTAssertNil(a.reviewedAt, "放回原来那一段：Draft 还是 Draft")
        XCTAssertNotNil(b.reviewedAt)
    }

    func testPinIsLoggedAndUndoable() throws {
        let m = mem("岚舟在学陶艺", reviewed: true)
        try context.save()
        let out = MemoryEntryActions.togglePin([m], profileId: pid, context: context)
        XCTAssertTrue(m.isUserExplicit)
        XCTAssertEqual(out.entry?.action, .pin)
        _ = MemoryEntryActions.undo(try XCTUnwrap(out.undoable), profileId: pid, context: context)
        XCTAssertFalse(m.isUserExplicit)
    }

    /// 记忆页的 ＋：新加的不钉（除非点了 Pin）、直接是 Archive、进得了对话、记一笔 Add；Undo = 进 Deleted
    func testCreateIsArchiveNotPinnedAndUndoable() throws {
        let draft = MemoryAudit.Edit(text: "  岚舟周三去云桥城  ", subject: "岚舟", keywords: ["行程"], confidence: MemoryAudit.handEditedConfidence)
        let (made, out) = MemoryEntryActions.create(draft, pinned: false, profileId: pid, context: context)
        let m = try XCTUnwrap(made)
        XCTAssertTrue(out.ok)
        XCTAssertEqual(m.content, "岚舟周三去云桥城")
        XCTAssertFalse(m.isUserExplicit)
        XCTAssertEqual(MemoryAudit.state(of: m), .kept, "她亲手写的直接是 Archive")
        XCTAssertTrue(MemoryInjector.isInjectable(m), "不钉也进得了对话")
        XCTAssertEqual(m.subject, "岚舟")
        XCTAssertEqual(m.category, MemoryAuditTraits.plainCategory, "类别给默认，不再单独选")
        XCTAssertEqual(m.confidence, 100)
        XCTAssertEqual(log.first?.action, .add)

        _ = MemoryEntryActions.undo(try XCTUnwrap(out.undoable), profileId: pid, context: context)
        XCTAssertNotNil(m.supersededAt, "撤回一笔 Add = 这条进 Deleted")

        let (pinned, _) = MemoryEntryActions.create(MemoryAudit.Edit(text: "星砚的灯笼铺子"), pinned: true, profileId: pid, context: context)
        XCTAssertEqual(pinned?.isUserExplicit, true, "点了 Pin 才钉")
        XCTAssertNil(MemoryEntryActions.create(MemoryAudit.Edit(text: "   "), pinned: false, profileId: pid, context: context).memory, "空的不加")
    }

    /// 详情页 ⋯「这条的记录」：只列动过这一条的那几笔
    func testLogSheetFiltersToOneCard() throws {
        let a = mem("岚舟喜欢云桥城的雨"), b = mem("星砚养了一只灰猫")
        try context.save()
        MemoryEntryActions.trash([a], profileId: pid, context: context)
        MemoryEntryActions.togglePin([b], profileId: pid, context: context)
        let rows = MemoryWriteLogSheet.rows([], audit: log, filter: .all, card: b.id)
        XCTAssertEqual(rows.count, 1)
        if case .you(let e) = rows.first { XCTAssertEqual(e.action, .pin) } else { XCTFail("应是她的一笔") }
        XCTAssertEqual(MemoryWriteLogSheet.rows([], audit: log, filter: .all).count, 2, "不给 card 照旧全列")
    }

    // MARK: - Why 只在有理由时出

    func testWhyChipOnlyWithReason() {
        let live = mem("岚舟喜欢云桥城的雨"), gone = mem("删掉的", deleted: true)
        let note = FragmentDreamNotes.Note(label: "Unsure", why: "只出现过一次", problem: nil, text: nil, at: Date(), record: "r1")
        XCTAssertTrue(MemoryWhyTray.shows(note, for: live))
        XCTAssertFalse(MemoryWhyTray.shows(nil, for: live), "没理由不出")
        XCTAssertFalse(MemoryWhyTray.shows(note, for: gone), "删了的不出")
        XCTAssertFalse(MemoryWhyTray.shows(note, for: nil), "新加的不出")
        XCTAssertEqual(MemoryWhyTray.body(FragmentDreamNotes.Note(label: "Unsure", why: "拿不准", problem: "想并进另一条",
                                                                 text: "岚舟常去云桥城", at: Date(), record: "r2")),
                       "想并进另一条；拿不准\n它想写成：岚舟常去云桥城")
    }

    // MARK: - Source：那一句只在靠得住时标

    private func spot(_ content: String, _ message: String) -> String? {
        MemorySourceSpot.locate(content: content, in: message).map { String(message[$0]) }
    }

    func testSourceSpotMarksTheSentence() {
        let message = "今天去了云桥城。岚舟说星砚的灯笼铺子周末关门！我们就改去河边走了一圈。"
        XCTAssertEqual(spot("岚舟说星砚的灯笼铺子周末关门", message), "岚舟说星砚的灯笼铺子周末关门！")
        // 引号里的一句：收尾的引号一起带上
        let quoted = "她停了一下。「云桥城的雨下了三天三夜。」然后笑了。"
        XCTAssertEqual(spot("岚舟记得云桥城的雨下了三天三夜", quoted), "「云桥城的雨下了三天三夜。」")
        // 英文：一段一字不差的原文够长才标
        let english = "We walked by the river. Lanzhou said the lantern shop closes on weekends. Then it rained."
        XCTAssertEqual(spot("Lanzhou said the lantern shop closes on weekends", english), "Lanzhou said the lantern shop closes on weekends.")
    }

    func testSourceSpotRefusesWhenUnsure() {
        let message = "今天去了云桥城。岚舟说星砚的灯笼铺子周末关门！我们就改去河边走了一圈。"
        XCTAssertNil(spot("灯笼铺子", message), "太短（不到 6 个字）不标")
        XCTAssertNil(spot("岚舟喜欢下雪天的山路", message), "对不上不标")
        XCTAssertNil(spot("星砚的灯笼铺子关门了", "星砚的灯笼铺子关门了吗？我听说星砚的灯笼铺子关门了。"), "那一段出现不止一次不标")
        XCTAssertNil(spot("岚舟说星砚的灯笼铺子周末关门", "岚舟说星砚的灯笼铺子周末关门。"), "整条消息就是这一句：不用标")
        XCTAssertNil(spot("the lantern shop", "We walked. The lantern shop was shut. Rain."), "英文太短不标")
        XCTAssertNil(spot("", message))
    }
}
