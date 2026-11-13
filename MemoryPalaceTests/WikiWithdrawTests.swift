import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class WikiWithdrawTests: XCTestCase {
    private let pid = "xctest-wiki-withdraw"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!
    private var wiki: WikiStore!
    private var store: WikiProposalStore!
    private var context: ModelContext!
    private var recallProfile: String?
    private let path = "主题/纸舟城"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-withdraw-\(UUID().uuidString)")
        wiki = WikiStore(root: root)
        store = WikiProposalStore(wiki: wiki)
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        if let recallProfile {
            CatalogRecallIndexer.shared.deleteProfile(recallProfile, wiki: WikiStore(root: root.appendingPathComponent("recall-floor/wiki")))
            try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: recallProfile)
            try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: recallProfile).deletingLastPathComponent())
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private func page(_ path: String? = nil) -> WikiPage {
        WikiPage(path: path ?? self.path, kind: .topic, triggers: ["纸舟"], hook: "虚构城市",
            title: "纸舟城", now: "旧码头", records: ["旧记录"], entries: ["memory/cc/旧航线.md|old"],
            links: [.init(target: "主题/远港", relation: .citation, why: "旧航线")],
            extra: .init(meta: ["自定义: 保留"], sections: [.init(heading: "附录", body: "不可丢失\n")]), factDomain: .inWorld)
    }

    private func fragment() throws -> Memory {
        let m = Memory(content: "虚构纸舟城有夜航", category: "fact", profileId: pid)
        m.organizedAt = now.addingTimeInterval(-100)
        m.organizedPage = "主题/旧港"
        m.organizeRejectedAt = now.addingTimeInterval(-200)
        context.insert(m)
        try context.save()
        return m
    }

    private func proposal(_ items: [WikiProposal.Item], task: String? = nil) throws -> WikiProposal {
        let p = WikiProposal(origin: .manual, createdAt: now, items: items, seedTask: task)
        try store.save(p)
        return p
    }

    private func approve(_ p: WikiProposal, ids: Set<String>? = nil) async throws -> WikiProposal {
        try await WikiProposalReview.approve(p.id, itemIds: ids, store: store, profileId: pid, context: context, now: now)
    }

    private func withdraw(_ p: WikiProposal, ids: Set<String>? = nil) async throws -> WikiProposalReview.WithdrawResult {
        try await WikiProposalReview.withdraw(p.id, itemIds: ids, store: store, profileId: pid, context: context, now: now.addingTimeInterval(1))
    }

    func testReceiptRoundTripAndLegacyProposalWithoutReceipt() async throws {
        let legacy = #"{"id":"legacy","state":"approved","change":{"confirmCovered":{"path":"主题/纸舟城"}},"fragmentIds":[],"cites":[]}"#
        let old = try JSONDecoder().decode(WikiProposal.Item.self, from: Data(legacy.utf8))
        XCTAssertNil(old.approval)
        XCTAssertNil(old.withdrawals)
        let p = try proposal([.init(change: .newPage(page: page()))])
        let approved = try await approve(p)
        let reloaded = try XCTUnwrap(WikiProposalStore(wiki: WikiStore(root: root)).load(p.id))
        XCTAssertEqual(reloaded, approved)
        let receipt = try XCTUnwrap(reloaded.items[0].approval)
        XCTAssertEqual(receipt.proposalId, p.id)
        XCTAssertEqual(receipt.itemId, p.items[0].id)
        XCTAssertEqual(receipt.phase, .committed)
        XCTAssertEqual(receipt.approvedAt, now)
        XCTAssertEqual(receipt.pages[0].afterVersion, wiki.version(of: path))
        XCTAssertNil(receipt.pages[0].beforeVersion)
        XCTAssertNil(receipt.pages[0].beforeHistoryEntry)
    }

    func testFractionalDatesSurviveReloadAndAllowWithdrawal() async throws {
        let approvedAt = Date(timeIntervalSinceReferenceDate: 815_000_000.1234567)
        let rejectedAt = approvedAt.addingTimeInterval(-200.234567)
        let m = try fragment()
        m.organizeRejectedAt = rejectedAt
        try context.save()
        let p = try proposal([.init(change: .newPage(page: page()), fragmentIds: [m.id])])
        _ = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: approvedAt)
        store = WikiProposalStore(wiki: WikiStore(root: root))
        let reloaded = try XCTUnwrap(store.load(p.id))
        XCTAssertEqual(reloaded.items[0].approval?.phase, .committed)
        let plan = try await WikiProposalReview.withdrawPlan(p.id, store: store, profileId: pid, context: context)
        XCTAssertTrue(plan.blocked.isEmpty)
        XCTAssertEqual(plan.ordered.map(\.itemId), [p.items[0].id])
        let result = try await withdraw(reloaded)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertFalse(wiki.pageExists(path))
        XCTAssertEqual(m.organizedPage, "主题/旧港")
        XCTAssertEqual(try XCTUnwrap(m.organizeRejectedAt).timeIntervalSince(rejectedAt), 0, accuracy: 0.001)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
    }

    func testDeletedFragmentIsRecordedAndRemainingMarksAreRestored() async throws {
        let deleted = try fragment(), remaining = try fragment()
        let deletedId = deleted.id
        let p = try proposal([.init(change: .newPage(page: page()), fragmentIds: [deletedId, remaining.id])])
        _ = try await approve(p)
        context.delete(deleted)
        try context.save()
        let plan = try await WikiProposalReview.withdrawPlan(p.id, store: store, profileId: pid, context: context)
        XCTAssertTrue(plan.blocked.isEmpty)
        XCTAssertEqual(plan.ordered.map(\.itemId), [p.items[0].id])
        var compensated: [String] = []
        let store = store!
        let result = try await WikiProposalReview.withdraw(p.id, store: store, profileId: pid, context: context, now: now,
            saveMarks: { context in
                compensated = store.load(p.id)?.items[0].approval?.progress.compensated ?? []
                try context.save()
            })
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(compensated, ["碎片 \(deletedId) 已删，无需还原"])
        XCTAssertFalse(result.message.contains(deletedId.uuidString))
        XCTAssertEqual(remaining.organizedAt, now.addingTimeInterval(-100))
        XCTAssertEqual(remaining.organizedPage, "主题/旧港")
        XCTAssertEqual(remaining.organizeRejectedAt, now.addingTimeInterval(-200))
        XCTAssertFalse(wiki.pageExists(path))
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
    }

    func testUnchangedLinkDoesNotCreateHistoryOnApprovalOrWithdrawal() async throws {
        let original = WikiPage.parse(page().markdown, path: path)
        let base = try wiki.save(original)
        let p = try proposal([.init(change: .link(from: path, link: try XCTUnwrap(original.links.first)), baseVersion: base)])
        let approved = try await approve(p)
        let receipt = try XCTUnwrap(approved.items[0].approval)
        XCTAssertEqual(receipt.pages[0].beforeVersion, base)
        XCTAssertEqual(receipt.pages[0].afterVersion, base)
        XCTAssertNil(receipt.pages[0].beforeHistoryEntry)
        XCTAssertTrue(wiki.history(path).isEmpty)
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(wiki.readRaw(path), original.markdown)
        XCTAssertTrue(wiki.history(path).isEmpty)
    }

    func testSixKindsRestoreExactBytesMarksAndReviewStateAfterReload() async throws {
        for kind in 0..<6 {
            let target = path + String(kind)
            let original = page(target).markdown.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
            let version = kind == 0 ? nil : try wiki.saveRaw(original, path: target, now: now)
            let m = try fragment()
            let change: WikiProposal.Change
            switch kind {
            case 0: change = .newPage(page: page(target))
            case 1: change = .rewriteNow(path: target, old: "旧码头", new: "新夜航")
            case 2: change = .retag(path: target, oldHook: "虚构城市", newHook: "夜航", oldTriggers: ["纸舟"], newTriggers: ["夜航"])
            case 3: change = .link(from: target, link: .init(target: "主题/新港", relation: .supplement, why: "新线"))
            case 4: change = .appendRecords(path: target, lines: ["追加夜航记录"])
            default: change = .confirmCovered(path: target)
            }
            let p = try proposal([.init(change: change, fragmentIds: [m.id], baseVersion: version)])
            let approved = try await approve(p)
            let receipt = try XCTUnwrap(approved.items[0].approval)
            XCTAssertEqual(receipt.pages[0].beforeVersion, version)
            XCTAssertEqual(receipt.pages[0].afterVersion, wiki.version(of: target))
            let mark = try XCTUnwrap(receipt.fragmentMarks.first)
            XCTAssertEqual(mark.organizedAt, now.addingTimeInterval(-100))
            XCTAssertEqual(mark.organizedPage, "主题/旧港")
            XCTAssertEqual(mark.organizeRejectedAt, now.addingTimeInterval(-200))
            if kind > 0 && kind != 5 {
                let entry = try XCTUnwrap(receipt.pages[0].beforeHistoryEntry)
                XCTAssertEqual(wiki.historyText(target, entry: entry), original)
                XCTAssertEqual(wiki.history(target).count, 1)
            }
            if kind == 5 {
                XCTAssertEqual(wiki.readRaw(target), original)
                XCTAssertTrue(wiki.history(target).isEmpty)
            }
            store = WikiProposalStore(wiki: WikiStore(root: root))
            let result = try await withdraw(p)
            XCTAssertEqual(result.items.first?.outcome, .withdrawn)
            XCTAssertEqual(wiki.readRaw(target), kind == 0 ? nil : original)
            let saved = try XCTUnwrap(store.load(p.id))
            XCTAssertEqual(saved.items[0].state, .pending)
            XCTAssertEqual(saved.items[0].baseVersion, version)
            XCTAssertNil(saved.items[0].approval)
            XCTAssertEqual(saved.items[0].withdrawals?.map(\.receiptId), [receipt.id])
            XCTAssertNil(saved.finishedAt)
            let other = ModelContext(context.container)
            let fid = m.id
            let restored = try XCTUnwrap(other.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.id == fid })).first)
            XCTAssertEqual(restored.organizedAt, mark.organizedAt)
            XCTAssertEqual(restored.organizedPage, mark.organizedPage)
            XCTAssertEqual(restored.organizeRejectedAt, mark.organizeRejectedAt)
            if kind == 0 {
                let copies = wiki.history(target).compactMap { wiki.historyText(target, entry: $0.name) }
                XCTAssertEqual(copies, [page(target).markdown], "删新页只保存一份撤回前像")
                let savedDeletion = await Task.detached { [wiki = wiki!] in wiki.deletions().first { $0.path == target } }.value
                let deletion = try XCTUnwrap(savedDeletion)
                XCTAssertEqual(deletion.phase, .deleted)
                XCTAssertEqual(deletion.reason, "撤回新页")
                XCTAssertEqual(deletion.historyEntry, wiki.history(target).first?.name)
            } else if kind != 5 {
                XCTAssertEqual(wiki.history(target).count, 2, "批准前像和撤回前像各一份")
            }
        }
    }

    func testAppendEntriesRecordsOnlyNewReferencesAndPreservesOldOnWithdrawal() async throws {
        let source = "memory/cc/新航线.md", existing = "memory/cc/旧航线.md"
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc, modelName: "fictional",
            createdAt: now, run: .init(path: ".runs/fictional.md"))
        task.read = [source: "new", existing: "old"]
        task.carded = task.read
        try CatalogSeedTaskStore(wiki: wiki).save(task)
        let before = page().markdown
        let base = try wiki.saveRaw(before, path: path)
        let lines = ["夜航（出处：\(source)）", "旧航线补记（出处：\(existing)）", "再记夜航（出处：\(source)）"]
        let p = try proposal([.init(change: .appendRecords(path: path, lines: lines), baseVersion: base)], task: task.id)
        let approved = try await approve(p)
        let receipt = try XCTUnwrap(approved.items[0].approval)
        XCTAssertEqual(receipt.addedEntries[path], [source + "|new"])
        XCTAssertEqual(wiki.read(path)?.entries, [existing + "|old", source + "|new"])
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(wiki.readRaw(path), before)
    }

    func testPreparedPersistenceFailureNeverWritesLivePageOrMarks() async throws {
        enum Failure: Error { case prepared }
        let m = try fragment()
        let target = "主题/未建分组/更深/纸舟城"
        let p = try proposal([.init(change: .newPage(page: page(target)), fragmentIds: [m.id])])
        do {
            try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now,
                saveReceipt: { p, store in
                    if p.items.contains(where: { $0.approval?.phase == .prepared }) { throw Failure.prepared }
                    try store.save(p)
                })
            XCTFail("prepared 必须先持久化")
        } catch Failure.prepared { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("主题/未建分组").path))
        XCTAssertFalse(wiki.pageExists(target))
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
        XCTAssertNil(store.load(p.id)?.items[0].approval)
        XCTAssertEqual(m.organizedPage, "主题/旧港")
    }

    func testHumanEditAndDeletionBlockWithoutOverwriting() async throws {
        let p = try proposal([.init(change: .newPage(page: page()))])
        _ = try await approve(p)
        let edited = "人工编辑，不可覆盖\n"
        let version = try wiki.saveRaw(edited, path: path)
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(wiki.readRaw(path), edited)
        XCTAssertEqual(store.load(p.id)?.items[0].approval?.phase, .committed)
        try await Task.detached { [wiki = wiki!, path, now] in try wiki.delete(path, expectedVersion: version, now: now) }.value
        let missing = try await withdraw(p)
        XCTAssertEqual(missing.succeeded, 0)
        XCTAssertFalse(wiki.pageExists(path))
    }

    func testCrossProposalPageDependenciesWithdrawInReverseWithoutTimeOrdering() async throws {
        let first = try proposal([.init(change: .newPage(page: page()))])
        let a = try await approve(first)
        var second = try proposal([.init(change: .appendRecords(path: path, lines: ["后批准"]), baseVersion: wiki.version(of: path))])
        second.title = "夜航整理"
        try store.save(second)
        let b = try await approve(second)
        XCTAssertEqual(b.items[0].approval?.dependencies, [try XCTUnwrap(a.items[0].approval?.id)])
        let blocked = try await withdraw(first)
        guard case .blocked(let blockers, let reason) = blocked.items.first?.outcome else { return XCTFail("早批应被阻挡") }
        XCTAssertEqual(reason, "先撤回依赖此项的后批条目")
        XCTAssertEqual(blockers.first?.label, "主题/纸舟城 · 追加记录 · 提案「夜航整理」")
        let blockedPlan = try await WikiProposalReview.withdrawPlan(first.id, store: store, profileId: pid, context: context)
        XCTAssertTrue(blockedPlan.paths.isEmpty, "被阻挡项不算影响页")
        XCTAssertFalse(blockedPlan.confirmation.contains(first.id))
        XCTAssertFalse(blockedPlan.confirmation.contains(second.id))
        XCTAssertFalse(blocked.message.contains(second.items[0].id))
        XCTAssertEqual(blockers.map(\.proposalId), [second.id])
        XCTAssertEqual(blockers.map(\.itemId), [second.items[0].id])
        let ids = Set([first.items[0].id, second.items[0].id])
        let plan = try await WikiProposalReview.withdrawPlan(first.id, itemIds: ids, store: store, profileId: pid, context: context)
        XCTAssertEqual(plan.ordered.map(\.proposalId), [second.id, first.id])
        let result = try await withdraw(first, ids: ids)
        XCTAssertEqual(result.items.map(\.target.proposalId), [second.id, first.id])
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertFalse(wiki.pageExists(path))
    }

    func testUnsettledSharedFragmentRequiresRecoveryRatherThanWithdrawal() async throws {
        let m = try fragment()
        let path2 = "主题/另港"
        let v1 = try wiki.save(page()), v2 = try wiki.save(page(path2))
        let first = try proposal([.init(change: .confirmCovered(path: path), fragmentIds: [m.id], baseVersion: v1)])
        _ = try await approve(first)
        var second = try proposal([.init(change: .confirmCovered(path: path2), fragmentIds: [m.id], baseVersion: v2)])
        second.title = "未收口夜航"
        try store.save(second)
        second = try await approve(second)
        second.items[0].state = .pending
        for phase in [WikiProposal.ApprovalReceipt.Phase.prepared, .applied, .withdrawing, .recoveryRequired] {
            second.items[0].approval?.phase = phase
            try store.save(second)
            let plan = try await WikiProposalReview.withdrawPlan(first.id, store: store, profileId: pid, context: context)
            XCTAssertTrue(plan.ordered.isEmpty)
            let block = try XCTUnwrap(plan.blocked.first)
            XCTAssertEqual(block.reason, "同页 / 同碎片有未收口的批准或撤回（主题/另港 · 确认已覆盖 · 提案「未收口夜航」），先处理恢复")
            XCTAssertEqual(block.blockers.map(\.proposalId), [second.id])
            XCTAssertFalse(plan.confirmation.contains(second.id))
        }
    }

    func testSharedFragmentCreatesCrossProposalDependencyWithoutPageChanges() async throws {
        let m = try fragment()
        let path2 = "主题/另港"
        let v1 = try wiki.save(page()), v2 = try wiki.save(page(path2))
        let first = try proposal([.init(change: .confirmCovered(path: path), fragmentIds: [m.id], baseVersion: v1)])
        _ = try await approve(first)
        let second = try proposal([.init(change: .confirmCovered(path: path2), fragmentIds: [m.id], baseVersion: v2)])
        _ = try await approve(second)
        let blocked = try await withdraw(first)
        XCTAssertEqual(blocked.succeeded, 0)
        let result = try await withdraw(first, ids: [first.items[0].id, second.items[0].id])
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(m.organizedPage, "主题/旧港")
        XCTAssertEqual(wiki.version(of: path), v1)
        XCTAssertEqual(wiki.version(of: path2), v2)
        XCTAssertTrue(wiki.history(path).isEmpty)
    }

    func testRebasedPendingItemsOnlyRevertUnchangedFingerprint() async throws {
        let base = try wiki.save(page())
        let a = WikiProposal.Item(change: .appendRecords(path: path, lines: ["批准记录"]), baseVersion: base)
        let b = WikiProposal.Item(change: .rewriteNow(path: path, old: "旧码头", new: "未改草稿"), baseVersion: base)
        let c = WikiProposal.Item(change: .rewriteNow(path: path, old: "旧码头", new: "后来会改"), baseVersion: base)
        let p = try proposal([a, b, c])
        let approved = try await approve(p, ids: [a.id])
        let receipt = try XCTUnwrap(approved.items[0].approval)
        XCTAssertEqual(receipt.rebasedItems.map(\.itemId), [b.id, c.id])
        XCTAssertEqual(receipt.rebasedItems.first?.changeFingerprint, try WikiProposalReview.fingerprint(b.change))
        let followed = try XCTUnwrap(approved.items[2].baseVersion)
        _ = try store.edit(p.id, itemId: c.id, change: .rewriteNow(path: path, old: "旧码头", new: "人工另改"), judgment: nil)
        let result = try await withdraw(p, ids: [a.id])
        XCTAssertEqual(result.succeeded, 1)
        let saved = try XCTUnwrap(store.load(p.id))
        XCTAssertEqual(saved.items[1].baseVersion, base)
        XCTAssertEqual(saved.items[2].baseVersion, followed)
        XCTAssertNotNil(saved.items[2].staleReason)
        XCTAssertEqual(saved.items.map(\.state), [.pending, .pending, .pending])
    }

    func testMarkFailureCompensatesPageAndKeepsCommittedAfterReload() async throws {
        enum Failure: Error { case marks }
        let m = try fragment()
        let p = try proposal([.init(change: .newPage(page: page()), fragmentIds: [m.id])])
        _ = try await approve(p)
        let before = try XCTUnwrap(wiki.readRaw(path))
        let result = try await WikiProposalReview.withdraw(p.id, store: store, profileId: pid, context: context, now: now,
            saveMarks: { _ in throw Failure.marks })
        guard case .failed(_, _, let unresolved) = result.items.first?.outcome else { return XCTFail("标记失败应如实报告") }
        XCTAssertTrue(unresolved.isEmpty)
        XCTAssertEqual(wiki.readRaw(path), before)
        let reloaded = try XCTUnwrap(WikiProposalStore(wiki: WikiStore(root: root)).load(p.id))
        XCTAssertEqual(reloaded.items[0].state, .approved)
        XCTAssertEqual(reloaded.items[0].approval?.phase, .committed)
        XCTAssertEqual(m.organizedPage, path)
        XCTAssertNil(reloaded.items[0].withdrawals)
        XCTAssertNotNil(reloaded.items[0].approval?.pages[0].afterHistoryEntry)
    }

    func testRemovalFailureCompensatesWithoutLeavingResumableDeletionReceipt() async throws {
        let p = try proposal([.init(change: .newPage(page: page()))])
        _ = try await approve(p)
        let before = try XCTUnwrap(wiki.readRaw(path))
        let url = try wiki.pageURL(path)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        let result = try await withdraw(p)
        guard case .failed(_, _, let unresolved) = result.items.first?.outcome else { return XCTFail("移除失败不能提交撤回") }
        XCTAssertTrue(unresolved.isEmpty)
        XCTAssertEqual(wiki.readRaw(path), before)
        XCTAssertEqual(store.load(p.id)?.items[0].approval?.phase, .committed)
        let receipts = await Task.detached { [wiki = wiki!] in wiki.deletions() }.value
        XCTAssertEqual(receipts, [])
        let history = try XCTUnwrap(wiki.history(path).first)
        XCTAssertEqual(wiki.historyText(path, entry: history.name), before)
    }

    func testApprovalCompensationRemovalFailureDiscardsItsPreparedDeletionReceipt() async throws {
        enum Failure: Error { case applied }
        let p = try proposal([.init(change: .newPage(page: page()))])
        let wiki = wiki!, path = path
        let url = try wiki.pageURL(path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        do {
            _ = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now,
                saveReceipt: { p, store in
                    if p.items.contains(where: { $0.approval?.phase == .applied }) {
                        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
                        throw Failure.applied
                    }
                    try store.save(p)
                })
            XCTFail("批准中断必须报告")
        } catch Failure.applied { }
        XCTAssertTrue(wiki.pageExists(path))
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
        XCTAssertEqual(store.load(p.id)?.items[0].approval?.phase, .recoveryRequired)
        let receipts = await Task.detached { wiki.deletions() }.value
        XCTAssertEqual(receipts, [])
        let history = try XCTUnwrap(wiki.history(path).first)
        XCTAssertEqual(wiki.historyText(path, entry: history.name), wiki.readRaw(path))
    }

    func testCompensationFailurePersistsRecoveryAndBlocksApprovalAndSeedOverwrite() async throws {
        enum Failure: Error { case marks }
        let m = try fragment()
        let p = try proposal([.init(change: .newPage(page: page()), fragmentIds: [m.id])])
        _ = try await approve(p)
        let wiki = wiki!, path = path
        let result = try await WikiProposalReview.withdraw(p.id, store: store, profileId: pid, context: context, now: now,
            saveMarks: { _ in
                try wiki.saveRaw("故障注入：补偿目标版本已变", path: path)
                throw Failure.marks
            })
        guard case .failed(_, _, let unresolved) = result.items.first?.outcome else { return XCTFail("补偿失败必须报未恢复") }
        XCTAssertFalse(unresolved.isEmpty)
        store = WikiProposalStore(wiki: WikiStore(root: root))
        let saved = try XCTUnwrap(store.load(p.id))
        XCTAssertEqual(saved.items[0].approval?.phase, .recoveryRequired)
        XCTAssertEqual(saved.items[0].state, .approved)
        XCTAssertNil(saved.finishedAt)
        let item = WikiProposal.Item(change: .appendRecords(path: path, lines: ["不准再写"]), baseVersion: wiki.version(of: path))
        let next = try proposal([item])
        do { _ = try await approve(next); XCTFail("未收口页不准继续批准") } catch { }
        XCTAssertThrowsError(try CatalogSeedDrafts.validate(item.change, original: item, task: nil, wiki: wiki))
        XCTAssertEqual(wiki.readRaw(path), "故障注入：补偿目标版本已变")
        _ = store.purgeFinished(now: now.addingTimeInterval(90 * 86_400))
        XCTAssertNotNil(store.load(p.id))
    }

    func testLegacyApprovedItemCannotWithdraw() async throws {
        let base = try wiki.save(page())
        let p = try proposal([.init(state: .approved, change: .confirmCovered(path: path), baseVersion: base)])
        let result = try await withdraw(p)
        guard case .blocked(_, _) = result.items.first?.outcome else { return XCTFail("旧提案不能猜测逆操作") }
        XCTAssertEqual(wiki.version(of: path), base)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .approved)
    }

    func testSnapshotAndRemovalRejectSymlinkAndHistoryTraversal() async throws {
        let base = try wiki.save(page())
        XCTAssertNil(wiki.historyText(path, entry: "../纸舟城.md"))
        let outside = root.appendingPathComponent("outside.md")
        try Data("根外内容".utf8).write(to: outside)
        let target = try wiki.pageURL(path)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        do {
            try await Task.detached { [wiki = wiki!, path, now] in
                _ = try wiki.snapshotCurrent(path, now: now)
                try wiki.delete(path, expectedVersion: base, now: now)
            }.value
            XCTFail("链接不能被读写")
        } catch { }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "根外内容")
    }
}

extension WikiWithdrawTests {
    func testReapprovalCreatesNewReceiptAndUnfinishedPhaseSurvivesReload() async throws {
        let p = try proposal([.init(change: .newPage(page: page()))])
        let first = try await approve(p)
        let firstId = try XCTUnwrap(first.items[0].approval?.id)
        _ = try await withdraw(p)
        var second = try await approve(p)
        XCTAssertNotEqual(second.items[0].approval?.id, firstId)
        XCTAssertEqual(second.items[0].withdrawals?.count, 1)
        for phase in [WikiProposal.ApprovalReceipt.Phase.prepared, .applied, .withdrawing, .recoveryRequired] {
            second.items[0].approval?.phase = phase
            second.finishedAt = now
            try store.save(second)
            let restarted = WikiProposalStore(wiki: WikiStore(root: root))
            XCTAssertEqual(restarted.load(p.id)?.items[0].approval?.phase, phase)
            let result = try await WikiProposalReview.withdraw(p.id, store: restarted, profileId: pid, context: context)
            XCTAssertEqual(result.succeeded, 0)
            XCTAssertEqual(wiki.readRaw(path), page().markdown)
            _ = restarted.purgeFinished(now: now.addingTimeInterval(90 * 86_400))
            XCTAssertNotNil(restarted.load(p.id))
        }
    }

    func testSharedFragmentManualMarkChangeBlocksConfirmationAndExecution() async throws {
        let m = try fragment()
        let p = try proposal([.init(change: .newPage(page: page()), fragmentIds: [m.id])])
        _ = try await approve(p)
        m.organizedPage = "主题/人工归页"
        try context.save()
        let plan = try await WikiProposalReview.withdrawPlan(p.id, store: store, profileId: pid, context: context)
        XCTAssertTrue(plan.ordered.isEmpty)
        XCTAssertEqual(plan.blocked.map(\.target.itemId), [p.items[0].id])
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(wiki.readRaw(path), page().markdown)
        XCTAssertEqual(m.organizedPage, "主题/人工归页")
    }

    func testBatchReportsCompletedFailedAndSkippedItemsSeparately() async throws {
        enum Failure: Error { case marks }
        let m = try fragment()
        let paths = ["主题/甲港", "主题/乙港", "主题/丙港"]
        let p = try proposal([
            .init(id: "a", change: .newPage(page: page(paths[0]))),
            .init(id: "b", change: .newPage(page: page(paths[1])), fragmentIds: [m.id]),
            .init(id: "c", change: .newPage(page: page(paths[2])))
        ])
        _ = try await approve(p)
        let result = try await WikiProposalReview.withdraw(p.id, store: store, profileId: pid, context: context, now: now,
            saveMarks: { _ in throw Failure.marks })
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.items.map(\.target.itemId), ["a", "b", "c"])
        XCTAssertFalse(wiki.pageExists(paths[0]))
        XCTAssertEqual(wiki.readRaw(paths[1]), page(paths[1]).markdown)
        XCTAssertEqual(wiki.readRaw(paths[2]), page(paths[2]).markdown)
        XCTAssertEqual(store.load(p.id)?.items.map(\.state), [.pending, .approved, .approved])
    }

    func testBeforeImageFailureLeavesExistingPagePendingAndUntouched() async throws {
        let before = page().markdown
        let base = try wiki.saveRaw(before, path: path)
        try Data("不是历史文件夹".utf8).write(to: root.appendingPathComponent(WikiStore.historyFolder))
        let p = try proposal([.init(change: .appendRecords(path: path, lines: ["不应写入"]), baseVersion: base)])
        do { _ = try await approve(p); XCTFail("前像必须先落盘") } catch { }
        XCTAssertEqual(wiki.readRaw(path), before)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
        XCTAssertNil(store.load(p.id)?.items[0].approval)
    }

    func testAppliedReceiptFailureCompensatesBeforeAnyFragmentMark() async throws {
        enum Failure: Error { case applied }
        let before = page().markdown
        let base = try wiki.saveRaw(before, path: path)
        let m = try fragment()
        let p = try proposal([.init(change: .appendRecords(path: path, lines: ["不应留在页上"]), fragmentIds: [m.id], baseVersion: base)])
        do {
            _ = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now,
                saveReceipt: { p, store in
                    if p.items.contains(where: { $0.approval?.phase == .applied }) { throw Failure.applied }
                    try store.save(p)
                })
            XCTFail("applied 未持久化不能提交批准")
        } catch Failure.applied { }
        XCTAssertEqual(wiki.readRaw(path), before)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
        XCTAssertNil(store.load(p.id)?.items[0].approval)
        XCTAssertEqual(m.organizedPage, "主题/旧港")
    }

    func testUnrecoverableApprovalStaysPendingAndBlocksFurtherWrites() async throws {
        enum Failure: Error { case applied }
        let base = try wiki.save(page())
        let p = try proposal([.init(change: .appendRecords(path: path, lines: ["未完成的批准"]), baseVersion: base)])
        let wiki = wiki!, path = path
        do {
            _ = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now,
                saveReceipt: { p, store in
                    if p.items.contains(where: { $0.approval?.phase == .applied }) {
                        try wiki.saveRaw("故障注入：批准补偿版本不符", path: path)
                        throw Failure.applied
                    }
                    try store.save(p)
                })
            XCTFail("批准未完成必须抛错")
        } catch Failure.applied { }
        let saved = try XCTUnwrap(store.load(p.id))
        XCTAssertEqual(saved.items[0].state, .pending)
        XCTAssertEqual(saved.items[0].approval?.phase, .recoveryRequired)
        XCTAssertNil(saved.finishedAt)
        let next = try proposal([.init(change: .appendRecords(path: path, lines: ["不可继续写"]), baseVersion: wiki.version(of: path))])
        do { _ = try await approve(next); XCTFail("未收口批准必须继续拦同页") }
        catch {
            guard case .conflict = error as? WikiStore.WikiError else { return XCTFail("应被未收口凭据阻挡") }
        }
        XCTAssertEqual(store.load(next.id)?.items[0].state, .pending)
        XCTAssertEqual(wiki.readRaw(path), "故障注入：批准补偿版本不符")
    }

    func testInterruptedPendingApprovalCannotAdvertiseApprovalActions() async throws {
        let p = try proposal([.init(change: .newPage(page: page()))])
        let approved = try await approve(p)
        var interrupted = approved.items[0]
        interrupted.state = .pending
        interrupted.approval?.phase = .prepared
        interrupted.staleReason = "旧的页域提醒"
        let status = WikiProposalDisplay.status(interrupted)
        XCTAssertFalse(status.canAct)
        XCTAssertEqual(status, .interruptedApproval([path]))
        XCTAssertEqual(WikiProposalDetailPage(proposalId: p.id, viewModel: nil).statusLabel(interrupted, status),
                       "批准未完成（未核清：\(path)）")
        interrupted.approval = nil
        XCTAssertEqual(WikiProposalDetailPage(proposalId: p.id, viewModel: nil).statusLabel(interrupted, .actionable),
                       "旧的页域提醒")
        XCTAssertEqual(WikiProposalDisplay.status(approved.items[0]), .withdrawable)
    }

    func testWithdrawnNewPageDisappearsFromRecallIndexAndWikiIndex() async throws {
        let indexedWiki = WikiStore(root: root.appendingPathComponent("recall-floor/wiki"))
        let indexedStore = WikiProposalStore(wiki: indexedWiki)
        let p = WikiProposal(origin: .manual, createdAt: now, items: [.init(change: .newPage(page: page()))])
        let profile = pid + "-recall"
        recallProfile = profile
        try await Task.detached { try indexedStore.save(p) }.value
        _ = try await WikiProposalReview.approve(p.id, store: indexedStore, profileId: profile, context: context, now: now)
        CatalogRecallIndexer.shared.ensure(profileId: profile, wiki: indexedWiki)
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: profile)
        let index = try XCTUnwrap(CatalogRecallIndexer.shared.store(profileId: profile))
        let before = try await Task.detached { try index.search(terms: ["纸舟城"], profileId: profile) }.value
        XCTAssertEqual(before.filter { $0.kind == .page }.map(\.path), [path])
        let result = try await WikiProposalReview.withdraw(p.id, store: indexedStore, profileId: profile, context: context, now: now)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertNil(result.indexFailure)
        let after = try await Task.detached { try index.search(terms: ["纸舟城"], profileId: profile) }.value
        XCTAssertTrue(after.isEmpty)
        let rootIndex = try String(contentsOf: indexedWiki.root.appendingPathComponent(WikiStore.indexFileName), encoding: .utf8)
        XCTAssertFalse(rootIndex.contains(path))
    }
}
