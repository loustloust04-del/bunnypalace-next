import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class WikiLifecycleFaultTests: XCTestCase {
    private enum Fault: String, CaseIterable { case file, marks, proposal, indexes }
    private enum Operation: String { case approve, withdraw, regroupApprove, regroupWithdraw }
    private enum Injected: Error, Equatable { case failure }
    private var f: WikiLifecycleFixture!

    override func tearDown() async throws { if let f { try await f.cleanup() } }

    private func reset() async throws {
        if let f { try await f.cleanup() }
        f = try WikiLifecycleFixture()
        try await f.seed()
    }

    private func exercise(_ operation: Operation, fault: Fault) async throws {
        try await reset()
        let regroup = operation == .regroupApprove || operation == .regroupWithdraw
        let withdrawal = operation == .withdraw || operation == .regroupWithdraw
        let p: WikiProposal
        if regroup { p = try f.regroup() }
        else {
            p = WikiProposal(origin: .scheduled, createdAt: f.now, items: [.init(change: .rewriteNow(path: f.a, old: "旧码头", new: "新码头"), fragmentIds: f.fragments.map(\.id), baseVersion: f.wiki.version(of: f.a))])
            try f.store.save(p)
        }
        if withdrawal { _ = try await f.approve(p) }
        let before = f.live()
        let beforeProposal = try XCTUnwrap(f.store.load(p.id))
        var faultyWiki = f.wiki
        if fault == .file {
            let target = regroup ? (withdrawal ? f.movedA : f.b) : f.a
            faultyWiki.beforeWrite = { if $0 == target + ".md" { throw Injected.failure } }
        }
        if fault == .indexes { faultyWiki.beforeRebuildIndexes = { throw Injected.failure } }
        var store = WikiProposalStore(wiki: faultyWiki)
        if fault == .proposal {
            store.beforeSave = { saved in
                if withdrawal {
                    if saved.items[0].state == .pending && saved.items[0].approval == nil { throw Injected.failure }
                } else if saved.items[0].approval?.phase == .applied { throw Injected.failure }
            }
        }
        var markFailures = 0
        let saveMarks: WikiProposalReview.SaveMarks = { context in
            if fault == .marks { markFailures += 1; throw Injected.failure }
            try context.save()
        }
        if withdrawal {
            let result = try await f.withdraw(p, store: store, saveMarks: saveMarks)
            if fault == .indexes {
                XCTAssertEqual(result.succeeded, 1, result.message)
                XCTAssertNotNil(result.indexFailure)
            } else {
                XCTAssertEqual(result.succeeded, 0, result.message)
                guard case .failed(_, _, let unresolved) = result.items.first?.outcome else { return XCTFail(result.message) }
                XCTAssertEqual(unresolved, [], result.message)
                XCTAssertEqual(f.store.load(p.id)?.items[0].state, .approved)
                XCTAssertEqual(f.store.load(p.id)?.items[0].approval?.phase, .committed)
            }
        } else {
            do { _ = try await f.approve(p, store: store, saveMarks: saveMarks); XCTFail("\(operation) / \(fault) must report failure") }
            catch { XCTAssertEqual(error as? Injected, .failure, "\(operation) / \(fault): \(error)") }
        }
        if fault == .marks { XCTAssertGreaterThan(markFailures, 0) }
        let expected: [String: String]
        let state: WikiProposal.Item.State
        let markPage: String
        let approvedMarks: Bool
        if fault == .indexes {
            state = withdrawal ? .pending : .approved
            if withdrawal {
                expected = f.before
                markPage = f.a
                approvedMarks = false
            } else if regroup {
                var moved = f.before
                moved[f.movedA] = moved.removeValue(forKey: f.a)
                moved[f.movedB] = moved.removeValue(forKey: f.b)
                var linked = WikiPage.parse(f.before[f.linked]!, path: f.linked)
                linked.links[0].target = f.movedA
                linked.links[1].target = f.movedB
                moved[f.linked] = linked.markdown
                expected = moved
                markPage = f.movedA
                approvedMarks = false
            } else {
                var changed = f.before
                var page = WikiPage.parse(f.before[f.a]!, path: f.a)
                page.now = "新码头"
                changed[f.a] = page.markdown
                expected = changed
                markPage = f.a
                approvedMarks = true
            }
        } else {
            expected = before
            state = withdrawal ? .approved : .pending
            markPage = regroup && withdrawal ? f.movedA : f.a
            approvedMarks = withdrawal && !regroup
            XCTAssertEqual(f.store.load(p.id)?.items[0].approval?.id, beforeProposal.items[0].approval?.id)
        }
        try await f.assertState(expected, markPage: markPage, approvedMarks: approvedMarks, proposals: [(p, [state])], indexesSettled: fault != .indexes)
        if fault == .indexes {
            let wiki = f.wiki
            try await Task.detached { try wiki.rebuildAllIndexes() }.value
            try await CatalogRecallIndexer.shared.reconcile(profileId: f.pid)
            try await f.assertState(expected, markPage: markPage, approvedMarks: approvedMarks, proposals: [(p, [state])])
        }
        print("[lifecycle-fault] \(operation.rawValue) × \(fault.rawValue): \(fault == .indexes ? "committed + index error; rebuilt" : "compensated; state unchanged")")
    }

    func testOrdinaryApprovalFaultMatrix() async throws {
        for fault in Fault.allCases { try await exercise(.approve, fault: fault) }
    }
    func testOrdinaryWithdrawalFaultMatrix() async throws {
        for fault in Fault.allCases { try await exercise(.withdraw, fault: fault) }
    }
    func testRegroupApprovalFaultMatrix() async throws {
        for fault in Fault.allCases { try await exercise(.regroupApprove, fault: fault) }
    }
    func testRegroupWithdrawalFaultMatrix() async throws {
        for fault in Fault.allCases { try await exercise(.regroupWithdraw, fault: fault) }
    }

    func testPersistedMarkFailureBlocksUnsettledTargetUntilReconcile() async throws {
        try await reset()
        let p = WikiProposal(origin: .scheduled, createdAt: f.now, items: [.init(change: .rewriteNow(path: f.a, old: "旧码头", new: "新码头"), fragmentIds: f.fragments.map(\.id), baseVersion: f.wiki.version(of: f.a))])
        try f.store.save(p)
        var saves = 0
        do {
            _ = try await f.approve(p, saveMarks: { context in
                saves += 1
                if saves == 1 { try context.save() }
                throw Injected.failure
            })
            XCTFail("persist-then-throw must not look successful")
        } catch { XCTAssertEqual(error as? Injected, .failure) }
        let receipt = try XCTUnwrap(f.store.load(p.id)?.items[0].approval)
        let persisted = try ModelContext(f.context.container).fetch(FetchDescriptor<Memory>()).filter { $0.profileId == f.pid }
        XCTAssertEqual(Set(persisted.map(\.id)), Set(f.fragments.map(\.id)))
        for fragment in persisted {
            XCTAssertEqual(fragment.organizedAt, f.now)
            XCTAssertEqual(fragment.organizedPage, f.a)
            XCTAssertEqual(fragment.organizeRejectedAt, f.now.addingTimeInterval(-120))
        }
        XCTAssertEqual(f.live(), f.before)
        XCTAssertEqual(receipt.phase, .recoveryRequired)
        XCTAssertThrowsError(try WikiProposalReview.requireSettled(f.a, store: f.store))
        let reloaded = WikiProposalStore(wiki: WikiStore(root: f.wiki.root))
        try await WikiProposalReview.reconcile(p.id, itemId: p.items[0].id, store: reloaded, profileId: f.pid, context: f.context, now: f.now)
        XCTAssertNoThrow(try WikiProposalReview.requireSettled(f.a, store: f.store))
        try await f.assertState(f.before, markPage: f.a, approvedMarks: false, proposals: [(p, [.pending])])
    }

    func testDeletionFaultMatrixCanContinueCancelOrRebuild() async throws {
        for fault in [Fault.file, .proposal, .indexes] {
            try await reset()
            var faulty = f.wiki
            if fault == .proposal { faulty.beforeWrite = { if $0.hasPrefix(".history/.deleted/") { throw Injected.failure } } }
            if fault == .indexes { faulty.beforeRebuildIndexes = { throw Injected.failure } }
            let wiki = faulty, path = f.a, before = f.before
            let outcome = try await WikiProposalReview.exclusive(wiki: wiki) {
                try await Task.detached { () -> WikiStore.DeletionOutcome? in
                    do {
                        let outcome = try wiki.delete(path, expectedVersion: wiki.version(of: path)!, beforeRemove: { _ in
                            if fault == .file { throw Injected.failure }
                        })
                        XCTAssertEqual(fault, .indexes)
                        XCTAssertNotNil(outcome.indexError)
                        XCTAssertNotNil(outcome.warning)
                        return outcome
                    } catch {
                        XCTAssertNotEqual(fault, .indexes)
                        XCTAssertEqual(wiki.readRaw(path), before[path])
                        return nil
                    }
                }.value
            }
            if fault == .file {
                let prepared = try await Task.detached { try XCTUnwrap(wiki.deletions().first) }.value
                XCTAssertEqual(prepared.phase, .prepared)
                XCTAssertTrue(prepared.incomplete)
                try await f.assertState(before, markPage: path, approvedMarks: false, proposals: [])
                try await Task.detached { try wiki.cancelDeletion(id: prepared.id) }.value
                let again = try await Task.detached { () -> WikiStore.DeletionReceipt in
                    do { try wiki.delete(path, expectedVersion: wiki.version(of: path)!, beforeRemove: { _ in throw Injected.failure }) }
                    catch { }
                    return try XCTUnwrap(wiki.deletions().first)
                }.value
                let clean = f.wiki
                _ = try await Task.detached { try clean.continueDeletion(id: again.id) }.value
                var deleted = before; deleted[path] = nil
                try await f.assertState(deleted, markPage: path, approvedMarks: false, proposals: [])
            } else if let outcome {
                XCTAssertEqual(outcome.receipt.phase, .deleted)
                var deleted = before; deleted[path] = nil
                try await f.assertState(deleted, markPage: path, approvedMarks: false, proposals: [], indexesSettled: false)
                let clean = f.wiki
                try await Task.detached { try clean.rebuildAllIndexes() }.value
                try await f.assertState(deleted, markPage: path, approvedMarks: false, proposals: [])
            } else {
                try await f.assertState(before, markPage: path, approvedMarks: false, proposals: [])
                let receipts = await Task.detached { wiki.deletions() }.value
                XCTAssertEqual(receipts, [])
            }
            print("[lifecycle-fault] delete × \(fault): truthful failure / warning; cancel, continue or rebuild settled")
        }
    }

    func testRestoreDeletedFaultMatrixNeverReportsFalseSuccess() async throws {
        for fault in [Fault.file, .proposal, .indexes] {
            try await reset()
            let clean = f.wiki, path = f.a
            let deletion = try await Task.detached { try clean.delete(path, expectedVersion: clean.version(of: path)!).receipt }.value
            var faulty = clean
            faulty.beforeWrite = { target in
                if fault == .file && target == path + ".md" { throw Injected.failure }
                if fault == .proposal && target.hasPrefix(".history/.deleted/") { throw Injected.failure }
            }
            if fault == .indexes { faulty.beforeRebuildIndexes = { throw Injected.failure } }
            let wiki = faulty
            try await Task.detached {
                XCTAssertThrowsError(try wiki.restoreDeleted(id: deletion.id))
                XCTAssertEqual(wiki.deletion(id: deletion.id).phase, fault == .indexes ? .restored : .deleted)
            }.value
            var expected = f.before
            if fault == .file { expected[path] = nil }
            try await f.assertState(expected, markPage: path, approvedMarks: false, proposals: [], indexesSettled: fault == .file)
            try await Task.detached {
                if fault == .file { try clean.restoreDeleted(id: deletion.id) }
                else if fault == .proposal {
                    XCTAssertThrowsError(try clean.restoreDeleted(id: deletion.id))
                    let retry = try clean.delete(path, expectedVersion: clean.version(of: path)!).receipt
                    try clean.restoreDeleted(id: retry.id)
                } else { try clean.rebuildAllIndexes() }
            }.value
            try await f.assertState(f.before, markPage: path, approvedMarks: false, proposals: [])
            print("[lifecycle-fault] restoreDeleted × \(fault): reported failure; exact bytes retained; retry or rebuild settled")
        }
    }
}
