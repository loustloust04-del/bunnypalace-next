import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class WikiLifecycleFixture {
    let pid = "xctest-lifecycle-" + UUID().uuidString
    let floor = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-lifecycle-" + UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let context: ModelContext
    var wiki: WikiStore
    var store: WikiProposalStore { WikiProposalStore(wiki: wiki) }
    let a = "主题/纸舟城", b = "主题/灯塔", linked = "主题/航图", added = "主题/夜港"
    let movedA = "主题/群岛/纸舟城", movedB = "主题/群岛/灯塔"
    let sources = ["memory/cc/虚构旧航线.md", "memory/cc/虚构新航线.md"]
    var fragments: [Memory] = []
    var before: [String: String] = [:]
    var cards: [String: MemoryRegeneration.FileInfo] = [:]

    init() throws {
        wiki = WikiStore(root: floor.appendingPathComponent("memory/wiki"))
        let schema = ProfileManager.makeFullSchema()
        context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    func seed() async throws {
        for i in 0..<2 {
            let m = Memory(content: "虚构纸舟航线 \(i)", category: "fact", profileId: pid)
            m.organizedAt = now.addingTimeInterval(-60)
            m.organizedPage = a
            m.organizeRejectedAt = now.addingTimeInterval(-120)
            context.insert(m)
            fragments.append(m)
        }
        try context.save()
        let wiki = wiki, sources = sources, now = now, a = a, b = b, linked = linked
        before = try await Task.detached {
            let texts = [
                a: WikiPage(path: a, kind: .topic, triggers: ["lifecycle"], hook: "虚构港城", title: "纸舟城", now: "旧码头", records: ["旧记录"], entries: [sources[0] + "|v0"], factDomain: .inWorld).markdown.replacingOccurrences(of: "\n", with: "\r\n"),
                b: WikiPage(path: b, kind: .topic, triggers: ["lifecycle"], title: "灯塔", now: "旧灯火", factDomain: .inWorld).markdown,
                linked: WikiPage(path: linked, kind: .topic, triggers: ["lifecycle"], title: "航图", now: "虚构航图", links: [.init(target: a, relation: .citation, why: "航路"), .init(target: b, relation: .supplement, why: "灯火")], factDomain: .inWorld).markdown
            ]
            for (path, text) in texts { try wiki.saveRaw(text, path: path, now: now) }
            for (i, source) in sources.enumerated() {
                try SeedNoteStore(wiki: wiki).save(.init(path: source, version: "v\(i)", name: "虚构原料", layer: "CC", title: "虚构航线", gist: "虚构港城的航线", mentions: [], aboutUser: false, group: "主题", when: [], model: "fictional", madeAt: now, run: .init(path: ".runs/fictional.md"), factDomain: .inWorld))
            }
            try wiki.rebuildAllIndexes()
            return texts
        }.value
        cards = try await Task.detached { try MemoryRegeneration.inventory(wiki.root.appendingPathComponent(".cards")) }.value
        CatalogRecallIndexer.shared.ensure(profileId: pid, wiki: wiki)
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
    }

    func daily() throws -> WikiProposal {
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc, modelName: "fictional", createdAt: now, run: .init(path: ".runs/fictional.md"))
        task.read = [sources[0]: "v0", sources[1]: "v1"]
        task.carded = task.read
        try CatalogSeedTaskStore(wiki: wiki).save(task)
        let ids = fragments.map(\.id)
        let p = WikiProposal(origin: .scheduled, createdAt: now, items: [
            .init(change: .newPage(page: WikiPage(path: added, kind: .topic, triggers: ["lifecycle"], title: "夜港", now: "虚构夜港", factDomain: .inWorld)), fragmentIds: ids),
            .init(change: .appendRecords(path: a, lines: ["新航线（出处：\(sources[1])）"]), fragmentIds: ids, baseVersion: wiki.version(of: a)),
            .init(change: .rewriteNow(path: a, old: "旧码头", new: "新码头"), fragmentIds: ids, baseVersion: wiki.version(of: a))
        ], seedTask: task.id)
        try store.save(p)
        return p
    }

    func regroup() throws -> WikiProposal {
        let p = WikiProposal(origin: .manual, createdAt: now.addingTimeInterval(2), items: [.init(change: .regroup(layer: "主题", groups: [.init(path: "主题/群岛", hook: "虚构新分组")], moves: [.init(from: a, to: movedA), .init(from: b, to: movedB)]))])
        try store.save(p)
        return p
    }

    func approve(_ p: WikiProposal, store: WikiProposalStore? = nil, saveMarks: WikiProposalReview.SaveMarks = { try $0.save() }) async throws -> WikiProposal {
        try await WikiProposalReview.approve(p.id, store: store ?? self.store, profileId: pid, context: context, now: now, saveMarks: saveMarks)
    }

    func withdraw(_ p: WikiProposal, store: WikiProposalStore? = nil, saveMarks: WikiProposalReview.SaveMarks = { try $0.save() }) async throws -> WikiProposalReview.WithdrawResult {
        try await WikiProposalReview.withdraw(p.id, store: store ?? self.store, profileId: pid, context: context, now: now.addingTimeInterval(1), saveMarks: saveMarks)
    }

    func live() -> [String: String] {
        Dictionary(uniqueKeysWithValues: wiki.pagePaths().map { ($0, wiki.readRaw($0)!) })
    }

    func assertState(_ expected: [String: String], markPage: String, approvedMarks: Bool,
                     proposals: [(WikiProposal, [WikiProposal.Item.State])], indexesSettled: Bool = true,
                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let wiki = wiki, cards = cards, pid = pid
        for (proposal, states) in proposals {
            let saved = try XCTUnwrap(store.load(proposal.id), file: file, line: line)
            XCTAssertEqual(saved.items.map(\.state), states, file: file, line: line)
            for item in saved.items {
                XCTAssertEqual(item.approval?.phase, item.state == .approved ? .committed : nil, file: file, line: line)
            }
        }
        let persisted = try ModelContext(context.container).fetch(FetchDescriptor<Memory>()).filter { $0.profileId == self.pid }
        XCTAssertEqual(Set(persisted.map(\.id)), Set(fragments.map(\.id)), file: file, line: line)
        for m in persisted {
            XCTAssertEqual(m.organizedPage, markPage, file: file, line: line)
            XCTAssertEqual(m.organizedAt, approvedMarks ? now : now.addingTimeInterval(-60), file: file, line: line)
            XCTAssertEqual(m.organizeRejectedAt, now.addingTimeInterval(-120), file: file, line: line)
        }
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
        let index = try XCTUnwrap(CatalogRecallIndexer.shared.store(profileId: pid))
        try await Task.detached {
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: wiki.pagePaths().map { ($0, wiki.readRaw($0)!) }), expected, file: file, line: line)
            XCTAssertEqual(try MemoryRegeneration.inventory(wiki.root.appendingPathComponent(".cards")), cards, file: file, line: line)
            let snapshot = WikiInjection.load(wiki)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: snapshot.pages.map { ($0.path, $0.version) }), expected.mapValues { WikiStore.version(of: Data($0.utf8)) }, file: file, line: line)
            for page in snapshot.pages {
                XCTAssertEqual(page.now, WikiPage.parse(expected[page.path]!, path: page.path).now, file: file, line: line)
            }
            let hits = try index.search(terms: ["lifecycle"], profileId: pid, kinds: [.page])
            let verified = index.verified(hits, snapshot: snapshot, maximumCount: 20)
            let expectedVersions = expected.mapValues { WikiStore.version(of: Data($0.utf8)) }
            for hit in verified {
                XCTAssertEqual(hit.version, expectedVersions[hit.path], "旧代召回不得作为新鲜结果出站", file: file, line: line)
            }
            if indexesSettled {
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: verified.map { ($0.path, $0.version) }), expectedVersions, file: file, line: line)
                for folder in [""] + wiki.allFolders() {
                    XCTAssertEqual(try String(contentsOf: wiki.folderURL(folder).appendingPathComponent("INDEX.md"), encoding: .utf8), wiki.layerMarkdown(folder), file: file, line: line)
                }
            }
        }.value
    }

    func cleanup() async throws {
        MemoryWriteLog.flush()
        CatalogRecallIndexer.shared.deleteProfile(pid, wiki: wiki)
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
        try FileManager.default.removeItem(at: floor)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }
}

@MainActor
final class WikiLifecycleSmokeTests: XCTestCase {
    private var f: WikiLifecycleFixture!
    override func setUp() async throws { f = try WikiLifecycleFixture(); try await f.seed() }
    override func tearDown() async throws { try await f.cleanup() }

    func testApproveReloadWithdrawReapproveRegroupDeleteAndRestore() async throws {
        let p1 = try f.daily()
        try await f.assertState(f.before, markPage: f.a, approvedMarks: false, proposals: [(p1, [.pending, .pending, .pending])])
        let first = try await f.approve(p1)
        let receipts = first.items.compactMap { $0.approval?.id }
        var daily = f.before
        var changed = WikiPage.parse(f.before[f.a]!, path: f.a)
        changed.records.append("新航线（出处：\(f.sources[1])）")
        changed.entries = f.sources.enumerated().map { "\($0.element)|v\($0.offset)" }
        changed.now = "新码头"
        daily[f.a] = changed.markdown
        daily[f.added] = WikiPage(path: f.added, kind: .topic, triggers: ["lifecycle"], title: "夜港", now: "虚构夜港", factDomain: .inWorld).markdown
        try await f.assertState(daily, markPage: f.a, approvedMarks: true, proposals: [(p1, [.approved, .approved, .approved])])
        f.wiki = WikiStore(root: f.wiki.root)
        XCTAssertEqual(f.store.load(p1.id), first)
        let plan = try await WikiProposalReview.withdrawPlan(p1.id, store: f.store, profileId: f.pid, context: f.context)
        XCTAssertEqual(plan.ordered.map(\.itemId), p1.items.reversed().map(\.id))
        let dailyAfter = daily
        for (offset, item) in p1.items.reversed().enumerated() {
            let result = try await WikiProposalReview.withdraw(p1.id, itemIds: [item.id], store: f.store, profileId: f.pid, context: f.context, now: f.now.addingTimeInterval(1))
            XCTAssertEqual(result.succeeded, 1, result.message)
            XCTAssertNil(result.indexFailure)
            if offset == 0 { changed.now = "旧码头"; daily[f.a] = changed.markdown }
            if offset == 1 { daily[f.a] = f.before[f.a] }
            if offset == 2 { daily[f.added] = nil }
            let states: [WikiProposal.Item.State] = (0..<3).map { $0 < 2 - offset ? .approved : .pending }
            try await f.assertState(daily, markPage: offset == 1 ? f.added : f.a, approvedMarks: offset != 2, proposals: [(p1, states)])
        }
        let second = try await f.approve(p1)
        XCTAssertTrue(Set(receipts).isDisjoint(with: second.items.compactMap { $0.approval?.id }))
        let approved = f.live()
        XCTAssertEqual(approved, dailyAfter)
        try await f.assertState(approved, markPage: f.a, approvedMarks: true, proposals: [(p1, [.approved, .approved, .approved])])
        let p2 = try f.regroup()
        let grouped = try await f.approve(p2)
        var moved = approved
        moved[f.movedA] = moved.removeValue(forKey: f.a)
        moved[f.movedB] = moved.removeValue(forKey: f.b)
        var links = WikiPage.parse(approved[f.linked]!, path: f.linked)
        links.links[0].target = f.movedA
        links.links[1].target = f.movedB
        moved[f.linked] = links.markdown
        let both: [(WikiProposal, [WikiProposal.Item.State])] = [(p1, [.approved, .approved, .approved]), (p2, [.approved])]
        try await f.assertState(moved, markPage: f.movedA, approvedMarks: true, proposals: both)
        XCTAssertEqual(f.wiki.groupHook("主题/群岛"), "虚构新分组")
        let withdrawn = try await f.withdraw(p2)
        XCTAssertEqual(withdrawn.succeeded, 1, withdrawn.message)
        try await f.assertState(approved, markPage: f.a, approvedMarks: true, proposals: [(p1, [.approved, .approved, .approved]), (p2, [.pending])])
        XCTAssertFalse(f.wiki.folderExists("主题/群岛"))
        let regrouped = try await f.approve(p2)
        XCTAssertNotEqual(grouped.items[0].approval?.id, regrouped.items[0].approval?.id)
        try await f.assertState(moved, markPage: f.movedA, approvedMarks: true, proposals: both)
        let wiki = f.wiki, target = f.movedA, now = f.now
        let deletion = try await WikiProposalReview.exclusive(wiki: wiki) {
            try await Task.detached { try wiki.delete(target, expectedVersion: wiki.version(of: target)!, now: now).receipt }.value
        }
        var deleted = moved
        deleted[target] = nil
        try await f.assertState(deleted, markPage: target, approvedMarks: true, proposals: both)
        XCTAssertFalse(f.wiki.browse("主题/群岛").contains { $0.path == target })
        XCTAssertEqual(f.wiki.read(f.linked)?.links[0].target, target)
        try await WikiProposalReview.exclusive(wiki: wiki) {
            try await Task.detached { try wiki.restoreDeleted(id: deletion.id, now: now) }.value
        }
        try await f.assertState(moved, markPage: target, approvedMarks: true, proposals: both)
        XCTAssertTrue(f.wiki.pageExists(try XCTUnwrap(f.wiki.read(f.linked)?.links[0].target)))
        let next = try await WikiProposalReview.exclusive(wiki: wiki) {
            try await Task.detached { try wiki.delete(target, expectedVersion: wiki.version(of: target)!, now: now).receipt }.value
        }
        try await Task.detached {
            try wiki.saveRaw(moved[target]!, path: target)
            XCTAssertThrowsError(try wiki.restoreDeleted(id: next.id)) {
                XCTAssertEqual($0 as? WikiStore.WikiError, .conflict(target, "已有同名页"))
            }
            XCTAssertEqual(wiki.deletion(id: next.id).phase, .deleted)
            try wiki.rebuildIndexes(affecting: [target])
        }.value
        try await f.assertState(moved, markPage: target, approvedMarks: true, proposals: both)
    }

    private enum RaceOrder { case firstThenSecond, secondThenFirst }

    private func waitForWaiters(_ count: Int, key: String) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while CatalogLock.waiterCount(key) != count && ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(CatalogLock.waiterCount(key), count)
    }

    private func race(order: RaceOrder, _ first: @escaping () async throws -> Bool,
                      _ second: @escaping () async throws -> Bool) async throws -> (Bool, Bool) {
        let wiki = f.wiki
        let key = await Task.detached { WikiProposalReview.lockKey(wiki) }.value
        let before = f.live()
        let gate = CatalogLock()
        await gate.acquire("hold")
        let entered = expectation(description: "holder owns floor")
        let crossed = expectation(description: "neither operation crosses holder")
        crossed.isInverted = true
        var holding = false
        let holder = Task {
            try await WikiProposalReview.exclusive(wiki: wiki) {
                holding = true
                entered.fulfill()
                await gate.acquire("hold")
                holding = false
                await gate.release("hold")
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        let leading = order == .firstThenSecond ? first : second
        let trailing = order == .firstThenSecond ? second : first
        let one = Task {
            defer { if holding { crossed.fulfill() } }
            return try await leading()
        }
        await waitForWaiters(1, key: key)
        let two = Task {
            defer { if holding { crossed.fulfill() } }
            return try await trailing()
        }
        await waitForWaiters(2, key: key)
        await fulfillment(of: [crossed], timeout: 0.2)
        XCTAssertEqual(f.live(), before, "持锁时活页不能先被改动")
        await gate.release("hold")
        try await holder.value
        let results = (try await one.value, try await two.value)
        return order == .firstThenSecond ? results : (results.1, results.0)
    }

    private func rewriteProposal() throws -> WikiProposal {
        let p = WikiProposal(origin: .scheduled, createdAt: f.now, items: [.init(change: .rewriteNow(path: f.a, old: "旧码头", new: "批准的新码头"), fragmentIds: f.fragments.map(\.id), baseVersion: f.wiki.version(of: f.a))])
        try f.store.save(p)
        return p
    }

    func testApprovalRacesManualSaveWithoutLosingEitherUpdate() async throws {
        try await approvalRacesManualSave(order: .firstThenSecond)
    }

    func testManualSaveRacesApprovalWithoutLosingEitherUpdate() async throws {
        try await approvalRacesManualSave(order: .secondThenFirst)
    }

    private func approvalRacesManualSave(order: RaceOrder) async throws {
        let p = try rewriteProposal()
        let wiki = f.wiki, path = f.a, baseline = f.before[f.a]!
        var manual = WikiPage.parse(baseline, path: path)
        manual.now = "人工稿"
        let edited = manual.markdown
        let (approved, saved) = try await race(order: order, {
            try await self.f.approve(p).items[0].state == .approved
        }, {
            do { try await WikiEditing.save(edited, baseline: baseline, store: wiki, path: path); return true }
            catch { return false }
        })
        let approvalFirst = order == .firstThenSecond
        XCTAssertEqual(approved, approvalFirst)
        XCTAssertEqual(saved, !approvalFirst)
        var expected = f.before
        manual.now = approvalFirst ? "批准的新码头" : "人工稿"
        expected[path] = manual.markdown
        try await f.assertState(expected, markPage: path, approvedMarks: approvalFirst, proposals: [(p, [approvalFirst ? .approved : .stale])])
    }

    func testWithdrawalRacesDeletionUsingVersionAndExistenceChecks() async throws {
        try await withdrawalRacesDeletion(order: .firstThenSecond)
    }

    func testDeletionRacesWithdrawalUsingVersionAndExistenceChecks() async throws {
        try await withdrawalRacesDeletion(order: .secondThenFirst)
    }

    private func withdrawalRacesDeletion(order: RaceOrder) async throws {
        let p = try rewriteProposal()
        _ = try await f.approve(p)
        let wiki = f.wiki, path = f.a, version = f.wiki.version(of: f.a)!
        let (withdrawn, deleted) = try await race(order: order, {
            try await self.f.withdraw(p).succeeded == 1
        }, {
            do {
                _ = try await WikiProposalReview.exclusive(wiki: wiki) {
                    try await Task.detached { try wiki.delete(path, expectedVersion: version) }.value
                }
                return true
            } catch { return false }
        })
        let withdrawalFirst = order == .firstThenSecond
        XCTAssertEqual(withdrawn, withdrawalFirst)
        XCTAssertEqual(deleted, !withdrawalFirst)
        var expected = f.before
        expected[path] = withdrawalFirst ? f.before[path] : nil
        try await f.assertState(expected, markPage: path, approvedMarks: !withdrawalFirst, proposals: [(p, [withdrawalFirst ? .pending : .approved])])
    }

    func testDeletionRacesHistoryRestoreWithoutResurrectingStaleWindow() async throws {
        try await deletionRacesHistoryRestore(order: .firstThenSecond)
    }

    func testHistoryRestoreRacesDeletionWithoutDeletingRestoredPage() async throws {
        try await deletionRacesHistoryRestore(order: .secondThenFirst)
    }

    private func deletionRacesHistoryRestore(order: RaceOrder) async throws {
        let wiki = f.wiki, path = f.a
        var page = WikiPage.parse(f.before[path]!, path: path)
        page.now = "历史之后的版本"
        let (version, entry) = try await Task.detached {
            let version = try wiki.saveRaw(page.markdown, path: path)
            return (version, try XCTUnwrap(wiki.history(path).first).name)
        }.value
        let (deleted, restored) = try await race(order: order, {
            do {
                _ = try await WikiProposalReview.exclusive(wiki: wiki) {
                    try await Task.detached { try wiki.delete(path, expectedVersion: version) }.value
                }
                return true
            } catch { return false }
        }, {
            do {
                try await WikiProposalReview.exclusive(wiki: wiki) {
                    try await Task.detached {
                        try wiki.restore(path, entry: entry, expectedVersion: version)
                        try wiki.rebuildIndexes(affecting: [path])
                    }.value
                }
                return true
            } catch { return false }
        })
        let deletionFirst = order == .firstThenSecond
        XCTAssertEqual(deleted, deletionFirst)
        XCTAssertEqual(restored, !deletionFirst)
        var expected = f.before
        expected[path] = deletionFirst ? nil : f.before[path]
        try await f.assertState(expected, markPage: path, approvedMarks: false, proposals: [])
    }

    func testRegroupRacesManualSaveAndMovesLatestAcceptedBytes() async throws {
        try await regroupRacesManualSave(order: .firstThenSecond)
    }

    func testManualSaveRacesRegroupAndMovesLatestAcceptedBytes() async throws {
        try await regroupRacesManualSave(order: .secondThenFirst)
    }

    private func regroupRacesManualSave(order: RaceOrder) async throws {
        let p = try f.regroup()
        let wiki = f.wiki, path = f.a, baseline = f.before[f.a]!
        var manual = WikiPage.parse(baseline, path: path)
        manual.now = "人工确认的航线"
        let edited = manual.markdown
        let (approved, saved) = try await race(order: order, {
            try await self.f.approve(p).items[0].state == .approved
        }, {
            do { try await WikiEditing.save(edited, baseline: baseline, store: wiki, path: path); return true }
            catch { return false }
        })
        XCTAssertTrue(approved)
        XCTAssertEqual(saved, order == .secondThenFirst)
        var expected = f.before
        expected[f.movedA] = order == .secondThenFirst ? edited : baseline
        expected[path] = nil
        expected[f.movedB] = expected.removeValue(forKey: f.b)
        var linked = WikiPage.parse(f.before[f.linked]!, path: f.linked)
        linked.links[0].target = f.movedA
        linked.links[1].target = f.movedB
        expected[f.linked] = linked.markdown
        try await f.assertState(expected, markPage: f.movedA, approvedMarks: false, proposals: [(p, [.approved])])
    }

    func testDifferentFloorApprovalDoesNotWaitForHeldFloor() async throws {
        let other = try WikiLifecycleFixture()
        try await other.seed()
        let proposal = try other.daily()
        let wiki = f.wiki
        let gate = CatalogLock()
        await gate.acquire("hold")
        let entered = expectation(description: "first floor held")
        let completed = expectation(description: "other floor commits while first held")
        let holder = Task {
            try await WikiProposalReview.exclusive(wiki: wiki) {
                entered.fulfill()
                await gate.acquire("hold")
                await gate.release("hold")
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        let approval = Task {
            let approved = try await other.approve(proposal)
            XCTAssertEqual(approved.items.map(\.state), [.approved, .approved, .approved])
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        await gate.release("hold")
        try await holder.value
        do { try await approval.value }
        catch { try await other.cleanup(); throw error }
        try await other.cleanup()
        try await f.assertState(f.before, markPage: f.a, approvedMarks: false, proposals: [])
    }

    func testDirectoryRestoreWaitsForWikiLockAndRejectsOldEditor() async throws {
        let wiki = f.wiki, memoryRoot = f.wiki.root.deletingLastPathComponent(), pid = f.pid, now = f.now, path = f.a
        let key = await Task.detached { WikiProposalReview.lockKey(wiki) }.value
        let backup = try await Task.detached { try MemoryRegeneration.makeBackup(memoryRoot: memoryRoot, name: "种子清理前-fictional", folders: ["wiki"]) }.value
        var edited = WikiPage.parse(f.before[path]!, path: path)
        edited.now = "备份之后的人工稿"
        let baseline = edited.markdown
        try await Task.detached { try wiki.saveRaw(baseline, path: path) }.value
        let gate = CatalogLock()
        await gate.acquire("hold")
        let entered = expectation(description: "wiki holder entered")
        let crossed = expectation(description: "restore cannot cross wiki holder")
        crossed.isInverted = true
        var holding = false
        let holder = Task {
            try await WikiProposalReview.exclusive(wiki: wiki) {
                holding = true
                entered.fulfill()
                await gate.acquire("hold")
                holding = false
                await gate.release("hold")
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        var restoreCompleted = false
        let restore = Task {
            defer { restoreCompleted = true }
            try await MemoryRegeneration.restoreExclusively(backup: backup, memoryRoot: memoryRoot, now: now, profileId: pid)
            if holding { crossed.fulfill() }
        }
        await waitForWaiters(1, key: key)
        await fulfillment(of: [crossed], timeout: 0.2)
        XCTAssertEqual(f.wiki.readRaw(path), baseline)
        XCTAssertFalse(restoreCompleted)
        await gate.release("hold")
        try await holder.value
        try await restore.value
        XCTAssertEqual(f.wiki.readRaw(path), f.before[path])
        do {
            try await WikiEditing.save("旧窗口试图覆盖", baseline: baseline, store: wiki, path: path)
            XCTFail("目录恢复后旧编辑器必须冲突")
        } catch { XCTAssertNotEqual(wiki.readRaw(path), "旧窗口试图覆盖") }
    }
}
