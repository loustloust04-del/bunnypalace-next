import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class WikiRegroupWithdrawTests: XCTestCase {
    private let pid = "xctest-regroup-" + UUID().uuidString
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!
    private var wiki: WikiStore!
    private var store: WikiProposalStore!
    private var context: ModelContext!
    private let oldPage = "主题/纸舟"
    private let newPage = "主题/新港/纸舟"
    private let oldFolder = "主题/旧群岛"
    private let newFolder = "主题/新群岛"
    private let linked = "主题/航图"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("regroup-\(UUID().uuidString)/wiki")
        wiki = WikiStore(root: root)
        store = WikiProposalStore(wiki: wiki)
        let schema = ProfileManager.makeFullSchema()
        context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private func page(_ path: String, links: [WikiPage.Link] = []) -> WikiPage {
        WikiPage(path: path, kind: .topic, triggers: ["纸舟"], hook: "虚构航路", title: "纸舟", now: "旧码头", records: ["虚构记录"], links: links)
    }

    private func write(_ bytes: String, _ path: String) throws {
        try SafeWiki.write(Data(bytes.utf8), name: (path as NSString).lastPathComponent,
            in: path.split(separator: "/").dropLast().map(String.init), under: root)
    }

    private func bytes(_ path: String) throws -> Data? { try wiki.relativeData(path) }

    private func fixture() throws -> (WikiProposal, Memory, [String: Data]) {
        let paths = [oldPage, oldFolder + "/灯塔", oldFolder + "/内海/帆船"]
        for path in paths { try wiki.saveRaw(page(path).markdown.replacingOccurrences(of: "\n", with: "\r\n"), path: path) }
        let links = paths.map { WikiPage.Link(target: $0, relation: .citation, why: "虚构航线") }
        try wiki.saveRaw(page(linked, links: links).markdown + "\n", path: linked)
        try write("---\r\n钩子: 旧钩子\r\n附加: 不可丢\r\n---\r\n", "主题/已有/.group.md")
        try write("---\n钩子: 群岛\n---\n", oldFolder + "/.group.md")
        try FileManager.default.createDirectory(at: wiki.folderURL("主题/无说明"), withIntermediateDirectories: true)
        try write("旧历史甲", ".history/" + oldPage + "/same.md")
        try write("目标旧历史，不应挪", ".history/" + newPage + "/same.md")
        try write("旧历史乙", ".history/" + oldPage + "/move.md")
        try write("目录历史", ".history/" + oldFolder + "/内海/帆船/move.md")
        let m = Memory(content: "虚构纸舟航路", category: "fact", profileId: pid)
        m.organizedAt = now.addingTimeInterval(-30)
        m.organizedPage = paths[2]
        context.insert(m)
        try context.save()
        let proposal = WikiProposal(origin: .manual, createdAt: now, items: [.init(change: .regroup(layer: "主题", groups: [
            .init(path: "主题/新港", hook: "新建"), .init(path: "主题/已有", hook: "改说明"), .init(path: "主题/无说明", hook: "补说明")
        ], moves: [.init(from: oldPage, to: newPage), .init(from: oldFolder, to: newFolder)]))])
        try store.save(proposal)
        let expected = paths.map { $0 + ".md" } + [linked + ".md", "主题/已有/.group.md", oldFolder + "/.group.md",
            ".history/" + oldPage + "/same.md", ".history/" + newPage + "/same.md", ".history/" + oldPage + "/move.md",
            ".history/" + oldFolder + "/内海/帆船/move.md"]
        return (proposal, m, try Dictionary(uniqueKeysWithValues: expected.map { ($0, try XCTUnwrap(bytes($0))) }))
    }

    private func approve(_ p: WikiProposal) async throws -> WikiProposal {
        try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now)
    }

    private func withdraw(_ p: WikiProposal) async throws -> WikiProposalReview.WithdrawResult {
        try await WikiProposalReview.withdraw(p.id, store: store, profileId: pid, context: context, now: now.addingTimeInterval(1))
    }

    func testPersistentRegroupRestoresExactBytesHistoryHooksAndFragmentAfterReload() async throws {
        let (p, m, before) = try fixture()
        let approved = try await approve(p)
        let receipt = try XCTUnwrap(approved.items[0].approval)
        XCTAssertEqual(receipt.phase, .committed)
        let moves = try XCTUnwrap(receipt.moves)
        XCTAssertEqual(moves.map(\.isFolder), [false, true])
        XCTAssertEqual(moves[0].history.map(\.from), [".history/" + oldPage + "/move.md"])
        XCTAssertEqual(moves[1].history.map(\.to), [".history/" + newFolder + "/内海/帆船/move.md"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: receipt.pages.map { ($0.beforePath!, $0.path) }),
            [oldPage: newPage, oldFolder + "/内海/帆船": newFolder + "/内海/帆船", oldFolder + "/灯塔": newFolder + "/灯塔"])
        let images = try XCTUnwrap(receipt.groupImages)
        XCTAssertNil(images[0].beforeImage)
        XCTAssertEqual(try bytes(XCTUnwrap(images[1].beforeImage)), before["主题/已有/.group.md"])
        XCTAssertNil(images[2].beforeImage)
        let relink = try XCTUnwrap(receipt.relinked?.first)
        XCTAssertEqual(relink.path, linked)
        XCTAssertEqual(wiki.historyText(linked, entry: try XCTUnwrap(relink.beforeHistoryEntry)).map { Data($0.utf8) }, before[linked + ".md"])
        XCTAssertEqual(m.organizedPage, newFolder + "/内海/帆船")
        store = WikiProposalStore(wiki: WikiStore(root: root))
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        XCTAssertNil(result.indexFailure)
        for (path, data) in before { XCTAssertEqual(try bytes(path), data, path) }
        XCTAssertFalse(wiki.pageExists(newPage))
        XCTAssertFalse(wiki.folderExists(newFolder))
        XCTAssertFalse(wiki.folderExists("主题/新港"))
        XCTAssertNil(try bytes("主题/无说明/.group.md"))
        XCTAssertTrue(wiki.folderExists("主题/无说明"))
        XCTAssertEqual(m.organizedPage, oldFolder + "/内海/帆船")
        XCTAssertEqual(m.organizedAt, now.addingTimeInterval(-30))
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
        XCTAssertNil(store.load(p.id)?.items[0].approval)
    }

    func testAnyEditedPageGroupOrRelinkBlocksWholeRegroupWithoutMovingFiles() async throws {
        for changed in [newPage + ".md", "主题/已有/.group.md", linked + ".md", newFolder + "/后来加的页.md"] {
            let (p, _, _) = try fixture()
            _ = try await approve(p)
            try write("人工改动，必须保留", changed)
            let current = try wiki.relativeFiles("主题")
            let result = try await withdraw(p)
            XCTAssertEqual(result.succeeded, 0)
            XCTAssertEqual(try wiki.relativeFiles("主题"), current, changed)
            XCTAssertEqual(store.load(p.id)?.items[0].approval?.phase, .committed)
            try FileManager.default.removeItem(at: root)
        }
    }

    func testSecondReverseMoveFailureCompensatesFirstMoveAndRelink() async throws {
        enum Failure: Error { case secondMove }
        let (p, m, _) = try fixture()
        _ = try await approve(p)
        let live = try wiki.relativeFiles("主题", excludingIndexes: true)
        let second = newPage
        let result = try await WikiProposalReview.withdraw(p.id, store: store, profileId: pid, context: context, now: now,
            beforeMove: { from, _ in if from == second { throw Failure.secondMove } })
        guard case .failed(_, let restored, let unresolved) = result.items.first?.outcome else { return XCTFail(result.message) }
        XCTAssertTrue(unresolved.isEmpty, result.message)
        XCTAssertTrue(restored.contains { $0.contains("目录") })
        XCTAssertEqual(try wiki.relativeFiles("主题", excludingIndexes: true), live)
        XCTAssertEqual(m.organizedPage, newFolder + "/内海/帆船")
        XCTAssertEqual(store.load(p.id)?.items[0].approval?.phase, .committed)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .approved)
    }

    func testMixedRecoveryPreservesManualEditsAndReportsManualIntervention() async throws {
        let (p, _, _) = try fixture()
        var approved = try await approve(p)
        approved.items[0].approval?.phase = .recoveryRequired
        approved.items[0].approval?.progress.goal = .rollbackApproval
        try store.save(approved)
        try write("人工改动，必须保留", newPage + ".md")
        try await WikiProposalReview.reconcile(p.id, itemId: p.items[0].id, store: store, profileId: pid, context: context)
        XCTAssertEqual(try bytes(newPage + ".md"), Data("人工改动，必须保留".utf8))
        let receipt = try XCTUnwrap(store.load(p.id)?.items[0].approval)
        XCTAssertEqual(receipt.phase, .recoveryRequired)
        XCTAssertTrue(receipt.progress.unresolved.allSatisfy { $0.hasPrefix("需人工：") })
        XCTAssertTrue(receipt.progress.unresolved.contains { $0.contains(newPage) || $0.contains(oldPage) })
        for path in [oldPage, newPage, oldFolder + "/灯塔", newFolder + "/灯塔", "主题/已有/.group.md"] {
            XCTAssertThrowsError(try WikiProposalReview.requireSettled(path, store: store))
        }
    }

    func testPreparedRegroupFailureNeverMovesOrChangesGroupBytes() async throws {
        enum Failure: Error { case prepared }
        let (p, m, before) = try fixture()
        do {
            _ = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now,
                saveReceipt: { p, store in
                    if p.items[0].approval?.phase == .prepared { throw Failure.prepared }
                    try store.save(p)
                })
            XCTFail("prepared 保存失败必须阻止活页写入")
        } catch Failure.prepared { }
        for (path, data) in before { XCTAssertEqual(try bytes(path), data, path) }
        XCTAssertFalse(wiki.folderExists("主题/新港"))
        XCTAssertEqual(m.organizedPage, oldFolder + "/内海/帆船")
        XCTAssertNil(store.load(p.id)?.items[0].approval)
    }

    func testAppliedRegroupFailureRestoresExistingGroupAndMovedHistory() async throws {
        enum Failure: Error { case applied }
        let (p, m, before) = try fixture()
        do {
            _ = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now,
                saveReceipt: { p, store in
                    if p.items[0].approval?.phase == .applied { throw Failure.applied }
                    try store.save(p)
                })
            XCTFail("applied 失败必须补偿")
        } catch Failure.applied { }
        for (path, data) in before { XCTAssertEqual(try bytes(path), data, path) }
        XCTAssertEqual(m.organizedPage, oldFolder + "/内海/帆船")
        XCTAssertNil(store.load(p.id)?.items[0].approval)
    }

    func testMovedPageWithLinksRestoresBothItsBytesAndHistory() async throws {
        let (p, _, _) = try fixture()
        let original = page(oldPage, links: [.init(target: oldFolder + "/灯塔", relation: .citation, why: "旧航图")]).markdown
            .replacingOccurrences(of: "\n", with: "\r\n")
        try wiki.saveRaw(original, path: oldPage)
        let approved = try await approve(p)
        XCTAssertEqual(approved.items[0].approval?.relinked?.map(\.path).sorted(), [newPage, linked].sorted())
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        XCTAssertEqual(wiki.readRaw(oldPage), original)
    }

    private func direction(_ mode: WikiProposal.Direction.Mode = .daily, ran: Date? = nil, result: String? = nil, content: String? = nil) -> WikiProposal.Item {
        .init(state: .approved, change: .direction(.init(path: oldPage, title: "纸舟", action: .newPage, reason: "虚构", mode: mode,
            ranAt: ran, result: result, contentProposalId: content)))
    }

    func testUnclaimedDirectionsWithdrawIndependentlyFromBlockedDirectionAndPreserveRunFacts() async throws {
        let p = WikiProposal(origin: .manual, createdAt: now, items: [direction(), direction(ran: now), direction()])
        try store.save(p)
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 2, result.message)
        XCTAssertEqual(store.load(p.id)?.items.map(\.state), [.pending, .approved, .pending])
        XCTAssertEqual(store.load(p.id)?.items[1].change.direction?.ranAt, now)
        XCTAssertTrue(result.message.contains("正在查原料、写"))
        XCTAssertEqual(store.load(p.id)?.items[0].withdrawals?.first?.note, "已撤授权")
        let claimed = try await WikiProposalReview.claimDirections(p.id, store: store)
        XCTAssertTrue(claimed.1.isEmpty)
    }

    func testClaimedDirectionResultAndDownstreamBlockWithActualItemCounts() async throws {
        let content = WikiProposal(origin: .manual, createdAt: now, items: [
            .init(change: .newPage(page: page(oldPage))), .init(state: .approved, change: .newPage(page: page(linked)))
        ])
        try store.save(content)
        let p = WikiProposal(origin: .manual, createdAt: now, items: [direction(ran: now, result: "没有原料"), direction(ran: now, content: content.id)])
        try store.save(p)
        let plan = try await WikiProposalReview.withdrawPlan(p.id, store: store, profileId: pid, context: context)
        XCTAssertTrue(plan.ordered.isEmpty)
        XCTAssertEqual(plan.blocked.compactMap(\.contentProposalId), [content.id])
        XCTAssertTrue(plan.blocked.contains { $0.reason.contains("没有原料") })
        XCTAssertTrue(plan.blocked.contains { $0.reason.contains("已交正文提案 \(content.id)") && $0.reason.contains("1 条待批 / 已批 1") })
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(store.load(p.id)?.items.compactMap { $0.change.direction?.ranAt }, [now, now])
    }

    func testSeedAuthorizationUsesCurrentPageItemWithoutMutatingTaskProgress() async throws {
        let taskId = UUID().uuidString
        let items = [direction(.seed), direction(.seed), direction(.seed, content: UUID().uuidString)]
        let p = WikiProposal(id: taskId, origin: .seed, createdAt: now, items: items, seedTask: taskId)
        var task = CatalogSeedTask(id: taskId, profileId: pid, entry: .cc, modelName: "fictional", createdAt: now,
            run: .init(path: ".runs/fictional.md"), state: .writing)
        task.rounds = 7
        task.outlineSaved = true
        task.page = .init(item: items[1].id, history: [.init(role: "user", content: "虚构开场")], key: "虚构页对话 key")
        try CatalogSeedTaskStore(wiki: wiki).save(task)
        try store.save(p)
        let plan = try await WikiProposalReview.withdrawPlan(p.id, store: store, profileId: pid, context: context)
        XCTAssertEqual(plan.ordered.map(\.itemId), [items[0].id])
        XCTAssertTrue(plan.blocked.contains { $0.target.itemId == items[1].id && $0.reason.contains("先停任务") })
        XCTAssertTrue(plan.blocked.contains { $0.target.itemId == items[2].id && $0.reason.contains(items[2].change.direction!.contentProposalId!) })
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(CatalogSeedTaskStore(wiki: wiki).load(taskId), task)
        task.state = .stopped
        try CatalogSeedTaskStore(wiki: wiki).save(task)
        let stopped = try await WikiProposalReview.withdraw(p.id, itemIds: [items[1].id], store: store, profileId: pid, context: context)
        XCTAssertEqual(stopped.succeeded, 1)
        XCTAssertEqual(CatalogSeedTaskStore(wiki: wiki).load(taskId), task)
        XCTAssertEqual(task.status(outline: store.load(p.id)), .waitingOutline(pending: 2))
    }

    func testReconcileFinishesInterruptedApprovalAndWithdrawalWithoutChangingLiveBytes() async throws {
        let (p, _, _) = try fixture()
        var approved = try await approve(p)
        approved.items[0].approval?.phase = .applied
        approved.items[0].state = .pending
        approved.items[0].approval?.progress.unresolved = ["旧的未恢复目标"]
        try store.save(approved)
        let live = try wiki.relativeFiles("主题", excludingIndexes: true)
        _ = try await WikiProposalReview.finishInterrupted(store: store, before: now, profileId: pid, context: context)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .approved)
        XCTAssertEqual(store.load(p.id)?.items[0].approval?.phase, .committed)
        XCTAssertEqual(try wiki.relativeFiles("主题", excludingIndexes: true), live)
        let receipt = try XCTUnwrap(store.load(p.id)?.items[0].approval)
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        var interrupted = try XCTUnwrap(store.load(p.id))
        interrupted.items[0].state = .approved
        interrupted.items[0].approval = receipt
        interrupted.items[0].approval?.phase = .withdrawing
        interrupted.items[0].approval?.progress.goal = .withdrawal
        try store.save(interrupted)
        let reversed = try wiki.relativeFiles("主题", excludingIndexes: true)
        try await WikiProposalReview.reconcile(p.id, itemId: p.items[0].id, store: store, profileId: pid, context: context)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
        XCTAssertNil(store.load(p.id)?.items[0].approval)
        XCTAssertEqual(try wiki.relativeFiles("主题", excludingIndexes: true), reversed)
    }

    func testSeedCurrentPageBlocksReadingWaitingAndWritingButNotTerminalStates() async throws {
        let taskId = UUID().uuidString
        let item = direction(.seed)
        let p = WikiProposal(id: taskId, origin: .seed, createdAt: now, items: [item], seedTask: taskId)
        var task = CatalogSeedTask(id: taskId, profileId: pid, entry: .cc, modelName: "fictional", createdAt: now,
            run: .init(path: ".runs/fictional.md"), state: .reading)
        task.page = .init(item: item.id, history: [], key: "fictional")
        for state in [CatalogSeedTask.State.reading, .waiting, .writing, .stopped, .ended, .complete, .abandoned] {
            task.state = state
            try CatalogSeedTaskStore(wiki: wiki).save(task)
            let block = await WikiProposalReview.directionBlock(item, proposal: p, store: store)
            XCTAssertEqual(block != nil, [.reading, .waiting, .writing].contains(state), state.rawValue)
        }
    }

    func testPurgeFinishedRemovesRegroupImagesWithProposal() async throws {
        let (p, _, _) = try fixture()
        let approved = try await approve(p)
        let image = try XCTUnwrap(approved.items[0].approval?.groupImages?.compactMap(\.afterImage).first)
        XCTAssertNotNil(try bytes(image))
        XCTAssertEqual(store.purgeFinished(now: now.addingTimeInterval(31 * 86_400)), 1)
        XCTAssertNil(store.load(p.id))
        XCTAssertNil(try bytes(image))
        XCTAssertNil(SafeWiki.names(in: [WikiStore.proposalsFolder, p.id, "images"], under: root))
    }

    func testIdenticalBeforeAndAfterImagesResolveUsingEachRecoveryGoal() async throws {
        try wiki.save(page(oldPage))
        let raw = wiki.readRaw(oldPage)
        for goal in [WikiProposal.ApprovalReceipt.Progress.Goal.approval, .withdrawal, .rollbackApproval, .rollbackWithdrawal] {
            var p = WikiProposal(origin: .manual, createdAt: now, items: [
                .init(change: .confirmCovered(path: oldPage), baseVersion: wiki.version(of: oldPage))
            ])
            try store.save(p)
            p = try await approve(p)
            p.items[0].approval?.phase = .recoveryRequired
            p.items[0].approval?.progress.goal = goal
            if goal == .approval || goal == .rollbackApproval { p.items[0].state = .pending }
            try store.save(p)
            try await WikiProposalReview.reconcile(p.id, itemId: p.items[0].id, store: store, profileId: pid, context: context)
            let item = try XCTUnwrap(store.load(p.id)?.items.first)
            let after = goal == .approval || goal == .rollbackWithdrawal
            XCTAssertEqual(item.state, after ? .approved : .pending)
            XCTAssertEqual(item.approval?.phase, after ? .committed : nil)
            XCTAssertEqual(wiki.readRaw(oldPage), raw)
        }
    }

    func testPreparedReceiptWithAllBeforeImagesReturnsToPending() async throws {
        let (p, _, before) = try fixture()
        let approved = try await approve(p)
        let receipt = try XCTUnwrap(approved.items[0].approval)
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        var interrupted = try XCTUnwrap(store.load(p.id))
        interrupted.items[0].approval = receipt
        interrupted.items[0].approval?.phase = .prepared
        interrupted.items[0].approval?.progress.goal = .approval
        try store.save(interrupted)
        try await WikiProposalReview.reconcile(p.id, itemId: p.items[0].id, store: store, profileId: pid, context: context)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
        XCTAssertNil(store.load(p.id)?.items[0].approval)
        for (path, data) in before { XCTAssertEqual(try bytes(path), data, path) }
    }

    func testWithdrawingReceiptWithAllAfterImagesReturnsToCommitted() async throws {
        let (p, _, _) = try fixture()
        var interrupted = try await approve(p)
        interrupted.items[0].approval?.phase = .withdrawing
        interrupted.items[0].approval?.progress.goal = .withdrawal
        try store.save(interrupted)
        let live = try wiki.relativeFiles("主题", excludingIndexes: true)
        try await WikiProposalReview.reconcile(p.id, itemId: p.items[0].id, store: store, profileId: pid, context: context)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .approved)
        XCTAssertEqual(store.load(p.id)?.items[0].approval?.phase, .committed)
        XCTAssertEqual(try wiki.relativeFiles("主题", excludingIndexes: true), live)
    }

    func testHalfMovedApprovalRollsBackToBeforeImagesAndPending() async throws {
        let (p, m, before) = try fixture()
        let approved = try await approve(p)
        let receipt = try XCTUnwrap(approved.items[0].approval)
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        try wiki.moveRelative(from: oldPage + ".md", to: newPage + ".md")
        let history = try XCTUnwrap(receipt.moves?.first?.history.first)
        try wiki.moveRelative(from: history.from, to: history.to)
        var interrupted = try XCTUnwrap(store.load(p.id))
        interrupted.items[0].approval = receipt
        interrupted.items[0].approval?.phase = .prepared
        interrupted.items[0].approval?.progress.goal = .approval
        try store.save(interrupted)
        try await WikiProposalReview.reconcile(p.id, itemId: p.items[0].id, store: store, profileId: pid, context: context)
        XCTAssertEqual(store.load(p.id)?.items[0].state, .pending)
        XCTAssertNil(store.load(p.id)?.items[0].approval)
        XCTAssertEqual(m.organizedPage, oldFolder + "/内海/帆船")
        for (path, data) in before { XCTAssertEqual(try bytes(path), data, path) }
    }

    func testHookOnlyRegroupAndChildPageDoNotBecomeDependencies() async throws {
        try wiki.save(page(oldPage))
        let hook = WikiProposal(origin: .manual, createdAt: now, items: [
            .init(change: .regroup(layer: "主题", groups: [.init(path: "主题", hook: "新钩子")], moves: []))
        ])
        try store.save(hook)
        let approvedHook = try await approve(hook)
        let child = WikiProposal(origin: .manual, createdAt: now, items: [
            .init(change: .appendRecords(path: oldPage, lines: ["后批记录"]), baseVersion: wiki.version(of: oldPage))
        ])
        try store.save(child)
        let approvedChild = try await approve(child)
        XCTAssertEqual(approvedChild.items[0].approval?.dependencies, [])
        var interrupted = approvedHook
        interrupted.items[0].approval?.phase = .prepared
        try store.save(interrupted)
        XCTAssertNoThrow(try WikiProposalReview.requireSettled(oldPage, store: store))
        XCTAssertThrowsError(try WikiProposalReview.requireSettled("主题/.group.md", store: store))
        try store.save(approvedHook)
        let result = try await withdraw(hook)
        XCTAssertEqual(result.succeeded, 1, result.message)
        XCTAssertEqual(wiki.read(oldPage)?.records.last, "后批记录")
    }

    func testPageAndSameNamedFolderMoveIndependentlyIncludingOnlyOwnHistory() async throws {
        let source = "主题/港口", target = "主题/远港", child = source + "/灯塔"
        try wiki.save(page(source))
        try wiki.save(page(child))
        try write("页历史", ".history/" + source + "/own.md")
        try write("子页历史", ".history/" + child + "/child.md")
        let p = WikiProposal(origin: .manual, createdAt: now, items: [
            .init(change: .regroup(layer: "主题", groups: [], moves: [.init(from: source, to: target)]))
        ])
        try store.save(p)
        let approved = try await approve(p)
        XCTAssertEqual(approved.items[0].state, .approved)
        XCTAssertEqual(approved.items[0].approval?.moves?.first?.isFolder, false)
        XCTAssertEqual(approved.items[0].approval?.moves?.first?.history.map(\.from), [".history/" + source + "/own.md"])
        XCTAssertEqual(try bytes(".history/" + child + "/child.md"), Data("子页历史".utf8))
        XCTAssertTrue(wiki.pageExists(child))
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        XCTAssertTrue(wiki.pageExists(source))
        XCTAssertTrue(wiki.pageExists(child))
        XCTAssertEqual(try bytes(".history/" + source + "/own.md"), Data("页历史".utf8))
        XCTAssertEqual(try bytes(".history/" + child + "/child.md"), Data("子页历史".utf8))
    }

    func testFolderWithdrawalAllowsUnrelatedSameNamedPageAtOldLocation() async throws {
        let (p, _, _) = try fixture()
        _ = try await approve(p)
        let raw = page(oldFolder).markdown
        try wiki.saveRaw(raw, path: oldFolder)
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        XCTAssertEqual(wiki.readRaw(oldFolder), raw)
        XCTAssertTrue(wiki.pageExists(oldFolder + "/灯塔"))
    }

    func testPageCanMoveIntoSameNamedSubfolderAndWithdraw() async throws {
        let source = "主题/电影", target = "主题/电影/电影"
        try wiki.save(page(source))
        let raw = wiki.readRaw(source)
        let p = WikiProposal(origin: .manual, createdAt: now, items: [
            .init(change: .regroup(layer: "主题", groups: [], moves: [.init(from: source, to: target)]))
        ])
        try store.save(p)
        let approved = try await approve(p)
        XCTAssertEqual(approved.items[0].state, .approved)
        XCTAssertEqual(wiki.readRaw(target), raw)
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        XCTAssertEqual(wiki.readRaw(source), raw)
        XCTAssertFalse(wiki.folderExists(source))
    }

    func testA2ReceiptDecodesWithoutRegroupFieldsOrRecoveryGoal() throws {
        let json = #"{"id":"old","proposalId":"p","itemId":"i","preparedAt":0,"phase":"committed","pages":[{"path":"主题/纸舟","afterVersion":"fictional"}],"addedEntries":{},"fragmentMarks":[],"rebasedItems":[],"dependencies":[],"progress":{"completed":["proposal"],"compensated":[],"unresolved":[]}}"#
        let receipt = try JSONDecoder().decode(WikiProposal.ApprovalReceipt.self, from: Data(json.utf8))
        XCTAssertNil(receipt.moves)
        XCTAssertNil(receipt.groupImages)
        XCTAssertNil(receipt.relinked)
        XCTAssertNil(receipt.progress.goal)
        XCTAssertEqual(receipt.pages.first?.path, oldPage)
    }

    func testRegroupAndLaterPageApprovalWithdrawTogetherInDependencyOrder() async throws {
        let (p, _, before) = try fixture()
        _ = try await approve(p)
        let q = WikiProposal(origin: .manual, createdAt: now, items: [
            .init(change: .appendRecords(path: newFolder + "/灯塔", lines: ["后批记录"]),
                  baseVersion: wiki.version(of: newFolder + "/灯塔"))
        ])
        try store.save(q)
        _ = try await approve(q)
        let blocked = try await withdraw(p)
        XCTAssertEqual(blocked.succeeded, 0)
        let ids = Set([p.items[0].id, q.items[0].id])
        let plan = try await WikiProposalReview.withdrawPlan(p.id, itemIds: ids, store: store, profileId: pid, context: context)
        XCTAssertTrue(plan.blocked.isEmpty, plan.confirmation)
        XCTAssertEqual(plan.ordered.map(\.proposalId), [q.id, p.id])
        let result = try await WikiProposalReview.withdraw(p.id, itemIds: ids, store: store, profileId: pid, context: context)
        XCTAssertEqual(result.succeeded, 2, result.message)
        for (path, data) in before { XCTAssertEqual(try bytes(path), data, path) }
    }

    func testNewGroupKeepsLaterUnrelatedPageButRestoresAbsentHook() async throws {
        let (p, _, _) = try fixture()
        _ = try await approve(p)
        let unrelated = "主题/新港/后来加入"
        let raw = page(unrelated).markdown
        try wiki.saveRaw(raw, path: unrelated)
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        XCTAssertTrue(wiki.folderExists("主题/新港"))
        XCTAssertNil(try bytes("主题/新港/.group.md"))
        XCTAssertEqual(wiki.readRaw(unrelated), raw)
    }

    func testDirectionActionAvailabilityTracksClaimAndActiveSeedItem() {
        let idle = direction()
        XCTAssertEqual(WikiProposalDisplay.status(idle), .withdrawable)
        XCTAssertEqual(WikiProposalDisplay.status(direction(ran: now)), .approved)
        XCTAssertEqual(WikiProposalDisplay.status(direction(.seed)), .withdrawable)
        XCTAssertEqual(WikiProposalDisplay.status(direction(.seed), directionBlock: "正在写"), .approved)
        XCTAssertEqual(WikiProposalDisplay.status(direction(.seed, content: "downstream")), .approved)
        let legacy = WikiProposal.Item(state: .approved, change: .regroup(layer: "主题", groups: [], moves: []))
        XCTAssertEqual(WikiProposalDisplay.status(legacy), .legacyApproved)
    }

    func testHooksInsideMovedFolderAndItsAncestorRestoreAtOriginalPaths() async throws {
        let (original, _, _) = try fixture()
        let rootHook = "---\r\n钩子: 原层说明\r\n---\r\n"
        try write(rootHook, "主题/.group.md")
        var p = original
        p.items[0].change = .regroup(layer: "主题", groups: [
            .init(path: "主题", hook: "新层说明"),
            .init(path: oldFolder, hook: "新群岛说明"),
            .init(path: oldFolder + "/新增子组", hook: "子组说明")
        ], moves: [.init(from: oldFolder, to: newFolder)])
        try store.save(p)
        let oldHook = try bytes(oldFolder + "/.group.md")
        let approved = try await approve(p)
        let images = try XCTUnwrap(approved.items[0].approval?.groupImages)
        XCTAssertEqual(images[1].beforePath, oldFolder)
        XCTAssertEqual(images[1].path, newFolder)
        XCTAssertEqual(wiki.groupHook(newFolder), "新群岛说明")
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        XCTAssertEqual(try bytes("主题/.group.md"), Data(rootHook.utf8))
        XCTAssertEqual(try bytes(oldFolder + "/.group.md"), oldHook)
        XCTAssertFalse(wiki.folderExists(oldFolder + "/新增子组"))
        XCTAssertFalse(wiki.folderExists(newFolder))
    }

    func testImplicitDestinationParentsHaveAbsentHookImagesAndAreRemovedWhenEmpty() async throws {
        try wiki.save(page(oldPage))
        let target = "主题/隐式港/内湾/纸舟"
        let p = WikiProposal(origin: .manual, createdAt: now, items: [
            .init(change: .regroup(layer: "主题", groups: [], moves: [.init(from: oldPage, to: target)]))
        ])
        try store.save(p)
        let approved = try await approve(p)
        let images = try XCTUnwrap(approved.items[0].approval?.groupImages)
        XCTAssertEqual(Set(images.map(\.path)), ["主题/隐式港", "主题/隐式港/内湾"])
        XCTAssertTrue(images.allSatisfy { $0.createdByThisApproval && $0.beforeImage == nil && $0.afterImage == nil })
        let result = try await withdraw(p)
        XCTAssertEqual(result.succeeded, 1, result.message)
        XCTAssertTrue(wiki.pageExists(oldPage))
        XCTAssertFalse(wiki.folderExists("主题/隐式港"))
    }
}
