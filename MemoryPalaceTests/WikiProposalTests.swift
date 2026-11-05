import XCTest
import SwiftData
@testable import 记忆花园

/// C3 整理提案（plan-memory-c3-catalog 2.3 / 第五节）：存取、逐条 / 整批批、驳回、页已变、同页连续条目、分组调整、碎片标记、清理
@MainActor
final class WikiProposalTests: XCTestCase {

    private let pid = "xctest-wiki-proposal"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!
    private var wiki: WikiStore!
    private var store: WikiProposalStore!
    private var context: ModelContext!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-proposal-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root)
        store = WikiProposalStore(wiki: wiki)
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private func fragment(_ content: String) -> Memory {
        let m = Memory(content: content, category: "fact", profileId: pid)
        m.occurredDay = "2026-10-12"
        m.importance = 3
        context.insert(m)
        return m
    }

    private func fresh(_ id: UUID) throws -> Memory? {
        let other = ModelContext(context.container)
        return try other.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.id == id })).first
    }

    private func proposal(_ items: [WikiProposal.Item], created: Date? = nil) throws -> WikiProposal {
        let p = WikiProposal(origin: .scheduled, createdAt: created ?? t0, items: items)
        try store.save(p)
        return p
    }

    private let xiaohui = WikiPage(path: "楼层/人/小慧", kind: .person, triggers: ["小慧"], hook: "她提到小慧时",
                                   title: "小慧", now: "室友（自 2026-09 起）", records: ["2026-10-01 认识"])

    // MARK: - 存取

    func testCodableRoundTripAndList() throws {
        let item = WikiProposal.Item(change: .rewriteNow(path: "楼层/人/小慧", old: "旧", new: "新"), judgment: .conflict,
                                     fragmentIds: [UUID()], cites: [.init(layer: "A2", day: "2026-10-12", windowId: "w1", segment: 3, messageFrom: 4, messageTo: 9)],
                                     baseVersion: "abc")
        var p = try proposal([item, .init(change: .regroup(layer: "楼层", groups: [.init(path: "楼层/人", hook: "h")],
                                                            moves: [.init(from: "楼层/a", to: "楼层/人/a")]), baseVersion: nil)])
        p.title = "电影"
        p.incomplete = true
        p.origin = .topic
        try store.save(p)
        XCTAssertEqual(store.load(p.id), p)

        let newer = try proposal([.init(change: .appendRecords(path: "楼层/x", lines: ["y"]), baseVersion: nil)], created: t0.addingTimeInterval(60))
        XCTAssertEqual(store.list().map(\.id), [newer.id, p.id], "新→旧")
        XCTAssertEqual(store.pendingItemCount(), 3)
        XCTAssertNil(store.load("../x"))
    }

    func testStatusFromItems() {
        var p = WikiProposal(origin: .manual, createdAt: t0, items: [
            .init(change: .appendRecords(path: "楼层/a", lines: []), baseVersion: nil),
            .init(change: .appendRecords(path: "楼层/b", lines: []), baseVersion: nil),
        ])
        XCTAssertEqual(p.status, .pending)
        p.items[0].state = .stale
        XCTAssertEqual(p.status, .partial)
        p.items[1].state = .rejected
        XCTAssertEqual(p.status, .done)
    }

    func testEdit() async throws {
        let v0 = try wiki.save(xiaohui)
        let item = WikiProposal.Item(change: .appendRecords(path: xiaohui.path, lines: ["草稿"]), baseVersion: v0)
        let p = try proposal([item])
        let edited = try store.edit(p.id, itemId: item.id, change: .appendRecords(path: xiaohui.path, lines: ["改过的一行"]), judgment: .coexist)
        XCTAssertEqual(edited.items[0].judgment, .coexist)
        XCTAssertEqual(store.load(p.id)?.items[0].change, .appendRecords(path: xiaohui.path, lines: ["改过的一行（出处：用户编辑）"]), "她自己写的标「用户编辑」")
        try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(wiki.read(xiaohui.path)?.records, ["2026-10-01 认识", "改过的一行（出处：用户编辑）"])
        XCTAssertThrowsError(try store.edit(p.id, itemId: item.id, change: item.change, judgment: nil)) {
            XCTAssertEqual($0 as? WikiProposalStore.ProposalError, .notPending(item.id))
        }
    }

    // MARK: - 批

    func testApproveAllNewPageThenFollowUps() async throws {
        let f1 = fragment("小慧是室友"), f2 = fragment("小慧会做饭"), f3 = fragment("小慧喜欢猫"), untouched = fragment("无关")
        try context.save()
        let link = WikiPage.Link(target: "楼层/地点/五楼", relation: .supplement, why: "一起住")
        let p = try proposal([
            .init(change: .newPage(page: xiaohui), fragmentIds: [f1.id, f2.id], baseVersion: nil),
            .init(change: .appendRecords(path: xiaohui.path, lines: ["2026-10-12 喜欢猫（到 2026-10-22）"]), judgment: .coexist, fragmentIds: [f3.id], baseVersion: nil),
            .init(change: .link(from: xiaohui.path, link: link), baseVersion: nil),
            .init(change: .retag(path: xiaohui.path, oldHook: "她提到小慧时", newHook: "她提到小慧、室友时", oldTriggers: ["小慧"], newTriggers: ["小慧", "慧慧"]), baseVersion: nil),
        ])
        XCTAssertEqual(store.pendingItemCount(), 4)

        let done = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(done.items.map(\.state), [.approved, .approved, .approved, .approved])
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.finishedAt, t0)
        XCTAssertEqual(store.pendingItemCount(), 0)

        let page = try XCTUnwrap(wiki.read(xiaohui.path))
        XCTAssertEqual(page.records, ["2026-10-01 认识", "2026-10-12 喜欢猫（到 2026-10-22）"])
        XCTAssertEqual(page.links, [link])
        XCTAssertEqual(page.hook, "她提到小慧、室友时")
        XCTAssertEqual(page.triggers, ["小慧", "慧慧"])
        XCTAssertEqual(page.now, "室友（自 2026-09 起）")

        for f in [f1, f2, f3] {
            let m = try XCTUnwrap(fresh(f.id), "显式 save 过，别的 context 读得到")
            XCTAssertEqual(m.organizedAt, t0)
            XCTAssertEqual(m.organizedPage, xiaohui.path)
            XCTAssertNil(m.organizeRejectedAt)
        }
        XCTAssertNil(try fresh(untouched.id)?.organizedAt)

        let layer = try String(contentsOf: wiki.folderURL("楼层/人").appendingPathComponent(WikiStore.indexFileName), encoding: .utf8)
        XCTAssertTrue(layer.contains("- [[楼层/人/小慧]] 小慧 — 她提到小慧、室友时"))
        XCTAssertNotNil(try? String(contentsOf: root.appendingPathComponent(WikiStore.indexFileName), encoding: .utf8))

        MemoryWriteLog.flush()
        let log = try XCTUnwrap(MemoryWriteLog.entries(profileId: pid).first)
        XCTAssertEqual(log.writer, "C3")
        XCTAssertEqual(log.note, "整理提案批了 4 条 · 写了 1 页")
    }

    func testPartialApproveCarriesBaseVersion() async throws {
        let v0 = try wiki.save(xiaohui)
        let a = WikiProposal.Item(change: .appendRecords(path: xiaohui.path, lines: ["甲"]), baseVersion: v0)
        let b = WikiProposal.Item(change: .rewriteNow(path: xiaohui.path, old: xiaohui.now, new: "新的现在"), judgment: .conflict, baseVersion: v0)
        let p = try proposal([a, b])

        let after1 = try await WikiProposalReview.approve(p.id, itemIds: [a.id], store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(after1.status, .partial)
        XCTAssertNil(after1.finishedAt)
        XCTAssertEqual(after1.items[1].baseVersion, wiki.version(of: xiaohui.path), "同页后面的待批条目跟上新版本")

        let after2 = try await WikiProposalReview.approve(p.id, itemIds: [b.id], store: store, profileId: pid, context: context, now: t0.addingTimeInterval(1))
        XCTAssertEqual(after2.items.map(\.state), [.approved, .approved])
        XCTAssertEqual(wiki.read(xiaohui.path)?.records, ["2026-10-01 认识", "甲"])
        XCTAssertEqual(wiki.read(xiaohui.path)?.now, "新的现在")
        XCTAssertEqual(wiki.history(xiaohui.path).count, 2, "每次覆盖都存一版")
    }

    func testStaleWhenPageChanged() async throws {
        let f = fragment("x")
        try context.save()
        let v0 = try wiki.save(xiaohui)
        var hand = xiaohui
        hand.now = "她手改了"
        try wiki.saveRaw(hand.markdown, path: xiaohui.path)

        let p = try proposal([
            .init(change: .appendRecords(path: xiaohui.path, lines: ["不该写"]), fragmentIds: [f.id], baseVersion: v0),
            .init(change: .newPage(page: xiaohui), baseVersion: nil),
            .init(change: .appendRecords(path: "楼层/人/不存在", lines: ["x"]), baseVersion: "v"),
            .init(change: .appendRecords(path: "别处/x", lines: ["x"]), baseVersion: nil),
        ])
        let out = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(out.items.map(\.state), [.stale, .stale, .stale, .stale])
        XCTAssertEqual(out.status, .done)
        XCTAssertEqual(wiki.read(xiaohui.path), hand, "不硬盖")
        XCTAssertNil(try fresh(f.id)?.organizedAt)
        XCTAssertNil(try fresh(f.id)?.organizeRejectedAt)
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(profileId: pid).isEmpty, "一条没批成不记日志")
    }

    func testTwoProposalsSamePage() async throws {
        let v0 = try wiki.save(xiaohui)
        let first = try proposal([.init(change: .appendRecords(path: xiaohui.path, lines: ["一"]), baseVersion: v0)])
        let second = try proposal([.init(change: .appendRecords(path: xiaohui.path, lines: ["二"]), baseVersion: v0)])
        try await WikiProposalReview.approve(first.id, store: store, profileId: pid, context: context, now: t0)
        let out = try await WikiProposalReview.approve(second.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(out.items[0].state, .stale, "后一份对不上的置灰")
        XCTAssertEqual(wiki.read(xiaohui.path)?.records, ["2026-10-01 认识", "一"])
    }

    // MARK: - 批的顺序（astra 10-16 #2）

    func testMarkSaveFailureLeavesItemPending() async throws {
        struct Boom: Error {}
        let f = fragment("小慧是室友")
        try context.save()
        let p = try proposal([.init(change: .newPage(page: xiaohui), fragmentIds: [f.id], baseVersion: nil)])

        do {
            try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0, saveMarks: { _ in throw Boom() })
            XCTFail("打标存不成应该抛")
        } catch is Boom {}

        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending, "碎片没标成，条目不变成已批")
        XCTAssertNil(store.load(p.id)?.finishedAt)
        XCTAssertNil(try fresh(f.id)?.organizedAt)
        XCTAssertNil(f.organizedAt, "context 里改的字段也改回去")
        XCTAssertNil(f.organizedPage)
    }

    func testRegroupFailureMidwayRollsBack() async throws {
        try wiki.save(WikiPage(path: "楼层/电影/甲", title: "甲", records: ["1"]), now: t0)
        try wiki.save(WikiPage(path: "楼层/电影/甲", title: "甲", records: ["1", "2"]), now: t0.addingTimeInterval(1))
        try wiki.save(WikiPage(path: "楼层/身体", title: "身体", links: [.init(target: "楼层/电影/甲", relation: .citation, why: "")]))
        // 挪历史那一步会撞上：新位置历史的上一层是个文件
        let blocker = wiki.historyURL("楼层/电影/国产")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker)
        let p = try proposal([.init(change: .regroup(layer: "楼层/电影", groups: [.init(path: "楼层/电影/国产", hook: "她聊国产片时")],
                                                       moves: [.init(from: "楼层/电影/甲", to: "楼层/电影/国产/甲")]), baseVersion: nil)])
        let cacheVersion = WikiInjectionCache.shared.version

        do {
            try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
            XCTFail("挪历史失败应该抛")
        } catch {}

        XCTAssertGreaterThan(WikiInjectionCache.shared.version, cacheVersion, "页移动和回滚都要作废注入缓存")
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending, "条目保持待批")
        XCTAssertEqual(wiki.read("楼层/电影/甲")?.records, ["1", "2"], "页挪回原处")
        XCTAssertFalse(wiki.pageExists("楼层/电影/国产/甲"))
        XCTAssertEqual(wiki.history("楼层/电影/甲").count, 1, "历史还在原处")
        XCTAssertFalse(wiki.folderExists("楼层/电影/国产"), "新建的分组删掉")
        XCTAssertEqual(wiki.read("楼层/身体")?.links.first?.target, "楼层/电影/甲")
    }

    // MARK: - covered（astra 10-16 #7）

    func testCoveredMarkedOnApproveButNotRejectedOnReject() async throws {
        let used = fragment("用了的"), covered = fragment("页上写过的"), other = fragment("没用上的")
        try context.save()
        let v0 = try wiki.save(xiaohui)
        var a = WikiProposal.Item(change: .appendRecords(path: xiaohui.path, lines: ["甲"]), fragmentIds: [used.id], baseVersion: v0)
        a.covered = [covered.id]
        let p = try proposal([a])
        XCTAssertEqual(CatalogMaterial.pendingFragmentIds(store), [used.id, covered.id], "covered 的待批时也不再送分拣")

        try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(try fresh(used.id)?.organizedPage, xiaohui.path)
        XCTAssertEqual(try fresh(covered.id)?.organizedPage, xiaohui.path, "covered 的批了一起标")
        XCTAssertNil(try fresh(other.id)?.organizedAt)

        let u2 = fragment("u2"), c2 = fragment("c2")
        try context.save()
        var b = WikiProposal.Item(change: .appendRecords(path: xiaohui.path, lines: ["乙"]), fragmentIds: [u2.id], baseVersion: wiki.version(of: xiaohui.path))
        b.covered = [c2.id]
        let q = try proposal([b])
        try await WikiProposalReview.reject(q.id, store: store, context: context, now: t0)
        XCTAssertEqual(try fresh(u2.id)?.organizeRejectedAt, t0)
        XCTAssertNil(try fresh(c2.id)?.organizeRejectedAt, "驳回只连带明确引用的")
    }

    // MARK: - 驳回

    func testReject() async throws {
        let f1 = fragment("a"), f2 = fragment("b")
        try context.save()
        let a = WikiProposal.Item(change: .newPage(page: xiaohui), fragmentIds: [f1.id], baseVersion: nil)
        let b = WikiProposal.Item(change: .newPage(page: WikiPage(path: "楼层/人/阿明", title: "阿明")), fragmentIds: [f2.id], baseVersion: nil)
        let p = try proposal([a, b])

        let r1 = try await WikiProposalReview.reject(p.id, itemIds: [a.id], store: store, context: context, now: t0)
        XCTAssertEqual(r1.items.map(\.state), [.rejected, .pending])
        XCTAssertEqual(try fresh(f1.id)?.organizeRejectedAt, t0)
        XCTAssertNil(try fresh(f1.id)?.organizedAt)
        XCTAssertNil(try fresh(f2.id)?.organizeRejectedAt)
        XCTAssertFalse(wiki.pageExists(xiaohui.path))

        let r2 = try await WikiProposalReview.reject(p.id, store: store, context: context, now: t0.addingTimeInterval(9))
        XCTAssertEqual(r2.status, .done)
        XCTAssertEqual(r2.finishedAt, t0.addingTimeInterval(9))
        XCTAssertEqual(try fresh(f2.id)?.organizeRejectedAt, t0.addingTimeInterval(9))
        XCTAssertTrue(wiki.pagePaths().isEmpty)
    }

    // MARK: - 分组调整

    func testRegroupMovesPagesHistoryLinksAndFragments() async throws {
        try wiki.save(WikiPage(path: "楼层/电影/甲", title: "甲", records: ["1"]), now: t0)
        try wiki.save(WikiPage(path: "楼层/电影/甲", title: "甲", records: ["1", "2"]), now: t0.addingTimeInterval(1))
        try wiki.save(WikiPage(path: "楼层/电影/乙", title: "乙"))
        try wiki.save(WikiPage(path: "楼层/身体", title: "身体",
                               links: [.init(target: "楼层/电影/甲", relation: .citation, why: "看过"),
                                       .init(target: "楼层/电影/乙", relation: .resonance, why: "")]))
        let f = fragment("甲好看")
        f.organizedAt = t0
        f.organizedPage = "楼层/电影/甲"
        let other = fragment("别的")
        other.organizedAt = t0
        other.organizedPage = "楼层/身体"
        try context.save()

        let p = try proposal([.init(change: .regroup(layer: "楼层/电影", groups: [.init(path: "楼层/电影/国产", hook: "她聊国产片时")],
                                                       moves: [.init(from: "楼层/电影/甲", to: "楼层/电影/国产/甲")]), baseVersion: nil)])
        let cacheVersion = WikiInjectionCache.shared.version
        let out = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0.addingTimeInterval(10))
        XCTAssertEqual(out.items[0].state, .approved)

        XCTAssertGreaterThan(WikiInjectionCache.shared.version, cacheVersion)
        XCTAssertFalse(wiki.pageExists("楼层/电影/甲"))
        XCTAssertEqual(wiki.read("楼层/电影/国产/甲")?.records, ["1", "2"])
        XCTAssertEqual(wiki.history("楼层/电影/国产/甲").count, 1, "历史跟着挪")
        XCTAssertTrue(wiki.history("楼层/电影/甲").isEmpty)
        XCTAssertEqual(wiki.read("楼层/身体")?.links.map(\.target), ["楼层/电影/国产/甲", "楼层/电影/乙"])
        XCTAssertEqual(wiki.groupHook("楼层/电影/国产"), "她聊国产片时")
        XCTAssertEqual(try fresh(f.id)?.organizedPage, "楼层/电影/国产/甲")
        XCTAssertEqual(try fresh(other.id)?.organizedPage, "楼层/身体")
        let layer = try String(contentsOf: wiki.folderURL("楼层/电影").appendingPathComponent(WikiStore.indexFileName), encoding: .utf8)
        XCTAssertTrue(layer.contains("- [[楼层/电影/国产/]] 国产 — 她聊国产片时（1 页）"))
        XCTAssertTrue(layer.contains("- [[楼层/电影/乙]] 乙"))
        XCTAssertNotNil(try? String(contentsOf: wiki.folderURL("工程").appendingPathComponent(WikiStore.indexFileName), encoding: .utf8), "全量重建")
    }

    func testRegroupMovesFolder() async throws {
        try wiki.save(WikiPage(path: "楼层/电影/甲", title: "甲"), now: t0)
        try wiki.save(WikiPage(path: "楼层/电影/甲", title: "甲", now: "改"), now: t0.addingTimeInterval(1))
        try wiki.save(WikiPage(path: "楼层/身体", title: "身体", links: [.init(target: "楼层/电影/甲", relation: .citation, why: "")]))
        let p = try proposal([.init(change: .regroup(layer: "楼层", groups: [.init(path: "楼层/爱好", hook: "她聊爱好时")],
                                                       moves: [.init(from: "楼层/电影", to: "楼层/爱好/电影")]), baseVersion: nil)])
        try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(wiki.pagePaths(), ["楼层/爱好/电影/甲", "楼层/身体"])
        XCTAssertEqual(wiki.history("楼层/爱好/电影/甲").count, 1)
        XCTAssertEqual(wiki.read("楼层/身体")?.links.first?.target, "楼层/爱好/电影/甲")
    }

    func testRegroupStaleWhenSourceMissingOrTargetTaken() async throws {
        try wiki.save(WikiPage(path: "楼层/a", title: "a"))
        try wiki.save(WikiPage(path: "楼层/组/a", title: "a"))
        let p = try proposal([
            .init(change: .regroup(layer: "楼层", groups: [], moves: [.init(from: "楼层/没有", to: "楼层/组/没有")]), baseVersion: nil),
            .init(change: .regroup(layer: "楼层", groups: [], moves: [.init(from: "楼层/a", to: "楼层/组/a")]), baseVersion: nil),
            .init(change: .regroup(layer: "楼层", groups: [], moves: [.init(from: "楼层", to: "工程/楼层")]), baseVersion: nil),
        ])
        let out = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: t0)
        XCTAssertEqual(out.items.map(\.state), [.stale, .stale, .stale])
        XCTAssertEqual(wiki.pagePaths(), ["楼层/a", "楼层/组/a"])
    }

    // MARK: - 清理

    func testPurgeFinished() throws {
        var old = WikiProposal(origin: .manual, createdAt: t0, items: [.init(state: .approved, change: .appendRecords(path: "楼层/a", lines: []), baseVersion: nil)])
        old.finishedAt = t0
        var recent = WikiProposal(origin: .manual, createdAt: t0, items: [.init(state: .rejected, change: .appendRecords(path: "楼层/a", lines: []), baseVersion: nil)])
        recent.finishedAt = t0.addingTimeInterval(20 * 86_400)
        let pending = WikiProposal(origin: .manual, createdAt: t0, items: [.init(change: .appendRecords(path: "楼层/a", lines: []), baseVersion: nil)])
        for p in [old, recent, pending] { try store.save(p) }

        XCTAssertEqual(store.purgeFinished(now: t0.addingTimeInterval(31 * 86_400)), 1)
        XCTAssertEqual(Set(store.list().map(\.id)), [recent.id, pending.id])
    }
}
