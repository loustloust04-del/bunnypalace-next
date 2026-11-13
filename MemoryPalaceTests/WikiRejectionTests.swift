import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class WikiRejectionTests: XCTestCase {
    private var pid = ""
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!
    private var wiki: WikiStore!
    private var store: WikiProposalStore!
    private var context: ModelContext!

    override func setUp() async throws {
        pid = "xctest-wiki-rejection-\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(pid)
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

    private func fragment(profileId: String? = nil) throws -> Memory {
        let row = Memory(content: "虚构云桥城的纸舟夜航", category: "fact", profileId: profileId ?? pid)
        row.organizedAt = now.addingTimeInterval(-100)
        row.organizedPage = "主题/旧港"
        row.organizeRejectedAt = now.addingTimeInterval(-200)
        context.insert(row)
        try context.save()
        return row
    }

    private func fresh(_ id: UUID) throws -> Memory {
        let other = ModelContext(context.container)
        return try XCTUnwrap(other.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.id == id })).first)
    }

    private func proposal(_ items: [WikiProposal.Item], task: String? = nil, id: String = UUID().uuidString) throws -> WikiProposal {
        let proposal = WikiProposal(id: id, origin: task == nil ? .manual : .seed, createdAt: now, items: items, seedTask: task)
        try store.save(proposal)
        return proposal
    }

    private func item(_ ids: [UUID] = []) -> WikiProposal.Item {
        .init(change: .appendRecords(path: "主题/云桥城", lines: ["虚构夜航草稿"]), fragmentIds: ids)
    }

    private func reject(_ proposal: WikiProposal, reasons: [String: String]? = nil) async throws -> WikiProposal {
        try await WikiProposalReview.reject(proposal.id, reasons: reasons, store: store, profileId: pid, context: context, now: now)
    }

    func testEmptyAndTwoHundredCharactersAreStoredWithoutTrimmingOrTruncation() async throws {
        let combined = "👩🏽‍🚀"
        XCTAssertEqual(combined.count, 1)
        let reasons = ["", String(repeating: "字", count: 200), String(repeating: combined, count: 200), "  保留原话\n"]
        for reason in reasons {
            let p = try proposal([item()])
            let before = Set(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).map(\.id))
            let rejected = try await reject(p, reasons: [p.items[0].id: reason])
            let saved = try XCTUnwrap(store.load(p.id))
            XCTAssertEqual(saved.items[0].state, .rejected)
            XCTAssertEqual(saved.items[0].rejection?.reason, reason)
            XCTAssertEqual(saved.items[0].rejection?.at, now)
            XCTAssertEqual(saved.items[0].reviewHistory?.first?.rejection, saved.items[0].rejection)
            XCTAssertEqual(saved, rejected)
            MemoryWriteLog.flush()
            let logs = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter { !before.contains($0.id) }
            XCTAssertEqual(logs.map(\.note), ["驳回 1 条（原因 \(reason.isEmpty ? 0 : 1) 条非空）"])
            XCTAssertEqual(logs.map(\.ok), [true])
        }
    }

    func testTwoHundredAndOneCharactersRejectsTheEntireBatchBeforeSaving() async throws {
        for reason in [String(repeating: "字", count: 201), String(repeating: "👩🏽‍🚀", count: 201)] {
            let first = try fragment(), second = try fragment()
            let p = try proposal([item([first.id]), item([second.id])])
            do {
                _ = try await reject(p, reasons: [p.items[0].id: "有效原因", p.items[1].id: reason])
                XCTFail("超限时整批不能驳回")
            } catch {
                XCTAssertEqual(error as? CatalogSeedDrafts.EditError, .invalid("驳回原因最多 200 字"))
            }
            XCTAssertEqual(store.load(p.id), p)
            for row in [first, second] {
                XCTAssertEqual(row.organizeRejectedAt, now.addingTimeInterval(-200))
                XCTAssertEqual(try fresh(row.id).organizeRejectedAt, now.addingTimeInterval(-200))
            }
        }
    }

    func testOrdinarySignatureCanonicalizesFormalIdentityAndIgnoresPresentation() async throws {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let original = WikiProposal.Cite(layer: "原文", day: "2026-10-09", windowId: "fictional-window", segment: 3,
            messageFrom: 4, messageTo: 8, profileId: pid, nodeId: "fictional-node", role: "user", created: now, onMain: true)
        let file = WikiProposal.Cite(layer: "CC", filePath: "memory/cc/纸舟.md", name: "旧名字")
        var first = item([high, low, high])
        first.change = .appendRecords(path: " /主题/云桥城.md/ \n", lines: ["旧稿"])
        first.cites = [original, file, original]
        first.covered = [UUID()]
        var other = original
        other.role = "assistant"
        other.created = now.addingTimeInterval(99)
        other.onMain = false
        var second = item([low, high])
        second.cites = [.init(layer: "CC", filePath: "memory/cc/纸舟.md", name: "新名字"), other]
        let p = try proposal([first, second])
        let rejected = try await reject(p)
        let signature = try XCTUnwrap(rejected.items[0].rejection?.sourceSignature)
        XCTAssertEqual(signature, rejected.items[1].rejection?.sourceSignature)
        XCTAssertEqual(signature.changeKind, .appendRecords)
        XCTAssertEqual(signature.targetPath, "主题/云桥城")
        XCTAssertFalse(signature.targetIsGroup)
        XCTAssertEqual(signature.fragmentIds, [low, high])
        XCTAssertEqual(signature.cites, [
            .init(layer: "CC", filePath: "memory/cc/纸舟.md"),
            .init(layer: "原文", day: "2026-10-09", profileId: pid, windowId: "fictional-window", segment: 3,
                  nodeId: "fictional-node", messageFrom: 4, messageTo: 8),
        ])
        XCTAssertTrue(signature.sources.isEmpty)
    }

    func testSeedSignatureUsesFrozenVersionsAndNeverPromotesCandidates() async throws {
        let source = "memory/cc/纸舟.md", missing = "prompt/fictional#02", candidate = "memory/cc/回扫.md"
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc, modelName: "fictional",
            createdAt: now, run: .init(path: ".runs/fictional.md"))
        task.read = [source: "frozen-v1", missing: "", candidate: "candidate-v1"]
        task.materials = [.init(path: source, name: "当前卡不同版本", layer: "CC", version: "new-v2")]
        task.carded = [source: "new-v2", missing: "latest-but-not-frozen"]
        try CatalogSeedTaskStore(wiki: wiki).save(task)
        let direction = WikiProposal.Direction(path: " /主题/云桥城.md/ ", title: "虚构云桥城", action: .newPage,
            reason: "虚构目录", mode: .seed, sources: [source, missing, source],
            candidates: [.init(path: candidate, hits: ["纸舟"])], group: true)
        let outline = try proposal([.init(change: .direction(direction))], task: task.id, id: task.id)
        let outlineResult = try await reject(outline)
        let signature = try XCTUnwrap(outlineResult.items[0].rejection?.sourceSignature)
        XCTAssertEqual(signature.changeKind, .direction)
        XCTAssertEqual(signature.targetPath, "主题/云桥城")
        XCTAssertTrue(signature.targetIsGroup)
        XCTAssertEqual(signature.sources, [.init(path: source, version: "frozen-v1"), .init(path: missing, version: nil)])

        var body = item()
        body.cites = [.init(layer: "CC", filePath: source)]
        let content = try proposal([body], task: task.id)
        let bodyResult = try await reject(content)
        XCTAssertEqual(bodyResult.items[0].rejection?.sourceSignature.sources, [.init(path: source, version: "frozen-v1")])

        let absentTask = UUID().uuidString
        let legacy = try proposal([.init(change: .direction(direction))], task: absentTask)
        let legacyResult = try await reject(legacy)
        XCTAssertEqual(legacyResult.items[0].rejection?.sourceSignature.sources,
                       [.init(path: source, version: nil), .init(path: missing, version: nil)])
        XCTAssertEqual(CatalogSeedTaskStore(wiki: wiki).load(task.id)?.read[source], "frozen-v1")
    }

    func testSurveyAnswerSignaturesStayDistinctAndUseFrozenAnswerVersions() async throws {
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .survey, modelName: "fictional",
            createdAt: now, run: .init(path: ".runs/fictional.md"))
        let keys = ["称呼", "在做什么"]
        task.read = [CatalogSurvey.prefix + keys[0]: "answer-v1", CatalogSurvey.prefix + keys[1]: "answer-v2"]
        try CatalogSeedTaskStore(wiki: wiki).save(task)
        var first = item(), second = item()
        first.cites = [CatalogSurvey.cite(key: keys[0], taskId: task.id, day: "2026-10-09")]
        second.cites = [CatalogSurvey.cite(key: keys[1], taskId: task.id, day: "2026-10-09")]
        let p = try proposal([first, second], task: task.id)
        let rejected = try await reject(p)
        let a = try XCTUnwrap(rejected.items[0].rejection?.sourceSignature)
        let b = try XCTUnwrap(rejected.items[1].rejection?.sourceSignature)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.cites.map(\.name), [keys[0]])
        XCTAssertEqual(b.cites.map(\.name), [keys[1]])
        XCTAssertEqual(a.sources, [.init(path: CatalogSurvey.prefix + keys[0], version: "answer-v1")])
        XCTAssertEqual(b.sources, [.init(path: CatalogSurvey.prefix + keys[1], version: "answer-v2")])
    }

    func testRegroupSignatureUsesItsLayerAndDistinguishesGroupTargets() async throws {
        let regroup = WikiProposal.Item(change: .regroup(layer: " /主题/ ", groups: [], moves: []))
        let direction = WikiProposal.Direction(path: "主题/云桥城", title: "虚构页", action: .update, reason: "虚构", mode: .daily)
        let p = try proposal([regroup, .init(change: .direction(direction))])
        let rejected = try await reject(p)
        XCTAssertEqual(rejected.items[0].rejection?.sourceSignature.targetPath, "主题")
        XCTAssertEqual(rejected.items[0].rejection?.sourceSignature.changeKind, .regroup)
        XCTAssertEqual(rejected.items[0].rejection?.sourceSignature.targetIsGroup, true)
        XCTAssertEqual(rejected.items[1].rejection?.sourceSignature.targetIsGroup, false)
    }

    func testReloadPreservesReviewSnapshotAndExactFragmentOwnership() async throws {
        let row = try fragment()
        let p = try proposal([item([row.id])])
        let rejected = try await reject(p, reasons: [p.items[0].id: "这是设定，不是现实经历"])
        let reloaded = try XCTUnwrap(WikiProposalStore(wiki: WikiStore(root: root)).load(p.id))
        XCTAssertEqual(reloaded, rejected)
        let record = try XCTUnwrap(reloaded.items[0].reviewHistory?.first)
        XCTAssertNotNil(UUID(uuidString: record.id))
        XCTAssertEqual(record.kind, .rejected)
        XCTAssertEqual(record.origin, .user)
        XCTAssertEqual(record.at, now)
        XCTAssertEqual(record.rejection, reloaded.items[0].rejection)
        XCTAssertEqual(record.fragmentMarks, [.init(fragmentId: row.id, organizedAt: now.addingTimeInterval(-100),
            organizedPage: "主题/旧港", organizeRejectedAt: now.addingTimeInterval(-200),
            afterOrganizedAt: now.addingTimeInterval(-100), afterOrganizedPage: "主题/旧港", afterOrganizeRejectedAt: now)])
        XCTAssertEqual(try fresh(row.id).organizedPage, "主题/旧港")
        XCTAssertEqual(try fresh(row.id).organizedAt, now.addingTimeInterval(-100))
        XCTAssertEqual(try fresh(row.id).organizeRejectedAt, now)

        var reopened = reloaded
        reopened.items[0].state = .pending
        reopened.items[0].rejection = nil
        reopened.finishedAt = nil
        try store.save(reopened)
        let again = try await reject(reopened, reasons: [p.items[0].id: "第二次仍是设定"])
        XCTAssertEqual(again.items[0].reviewHistory?.first, record)
        XCTAssertEqual(again.items[0].reviewHistory?.map(\.rejection?.reason), ["这是设定，不是现实经历", "第二次仍是设定"])
        XCTAssertNotEqual(again.items[0].reviewHistory?.last?.id, record.id)
    }

    func testLegacyRejectedJSONWithoutRejectionOrHistoryStillLoads() throws {
        let json = #"{"id":"fictional-legacy","state":"rejected","change":{"confirmCovered":{"path":"主题/云桥城"}},"fragmentIds":[],"cites":[]}"#
        let legacy = try JSONDecoder().decode(WikiProposal.Item.self, from: Data(json.utf8))
        XCTAssertEqual(legacy.state, .rejected)
        XCTAssertNil(legacy.rejection)
        XCTAssertNil(legacy.reviewHistory)
        let saved = try proposal([legacy])
        XCTAssertEqual(store.load(saved.id)?.items[0], legacy)
    }

    func testLegacyReviewJSONWithoutOriginDefaultsToUser() throws {
        let json = #"{"id":"fictional-review","at":0,"kind":"rejected","fragmentMarks":[]}"#
        let record = try JSONDecoder().decode(WikiProposal.ReviewRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.origin, .user)
        XCTAssertEqual(try JSONDecoder().decode(WikiProposal.ReviewRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testSaveMarksFailureRestoresProposalAndPersistedPreimageEvenAfterPartialSave() async throws {
        enum Failure: Error { case marks }
        for savesBeforeThrowing in [false, true] {
            let row = try fragment()
            let p = try proposal([item([row.id])])
            do {
                try await WikiProposalReview.reject(p.id, reasons: [p.items[0].id: "虚构拒稿"], store: store,
                    profileId: pid, context: context, now: now, saveMarks: { context in
                        if savesBeforeThrowing { try context.save() }
                        throw Failure.marks
                    })
                XCTFail("碎片保存失败必须抛错")
            } catch Failure.marks { }
            XCTAssertEqual(store.load(p.id), p)
            XCTAssertNil(store.load(p.id)?.items[0].rejection)
            XCTAssertNil(store.load(p.id)?.items[0].reviewHistory)
            XCTAssertEqual(row.organizeRejectedAt, now.addingTimeInterval(-200))
            let persisted = try fresh(row.id)
            XCTAssertEqual(persisted.organizedAt, now.addingTimeInterval(-100))
            XCTAssertEqual(persisted.organizedPage, "主题/旧港")
            XCTAssertEqual(persisted.organizeRejectedAt, now.addingTimeInterval(-200))
            MemoryWriteLog.flush()
            let log = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).first)
            XCTAssertFalse(log.ok)
            XCTAssertTrue(log.note.contains("保存碎片标记"), log.note)
        }
    }

    func testFinalProposalSaveFailureAlsoCompensatesMarksAndReviewHistory() async throws {
        enum Failure: Error { case afterImage }
        let row = try fragment()
        let p = try proposal([item([row.id])])
        let now = now
        var failing = store!
        failing.beforeSave = { proposal in
            if proposal.items.contains(where: { $0.reviewHistory?.last?.fragmentMarks.first?.afterOrganizeRejectedAt == now }) {
                throw Failure.afterImage
            }
        }
        do {
            try await WikiProposalReview.reject(p.id, store: failing, profileId: pid, context: context, now: now)
            XCTFail("审核后像没存成时也不能报告成功")
        } catch Failure.afterImage { }
        XCTAssertEqual(store.load(p.id), p)
        XCTAssertEqual(row.organizeRejectedAt, now.addingTimeInterval(-200))
        XCTAssertEqual(try fresh(row.id).organizeRejectedAt, now.addingTimeInterval(-200))
        MemoryWriteLog.flush()
        let log = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).first)
        XCTAssertFalse(log.ok)
        XCTAssertTrue(log.note.contains("保存审核后像"), log.note)
    }

    func testFinalSaveAndProposalRestoreFailureKeepsRejectedProposalAndMarksTogether() async throws {
        enum Failure: Error { case afterImage, restore }
        let row = try fragment()
        let p = try proposal([item([row.id])])
        let now = now
        var failing = store!
        failing.beforeSave = { proposal in
            if proposal.items.contains(where: { $0.reviewHistory?.last?.fragmentMarks.first?.afterOrganizeRejectedAt == now }) {
                throw Failure.afterImage
            }
            if proposal.items.contains(where: { $0.state == .pending }) { throw Failure.restore }
        }
        do {
            try await WikiProposalReview.reject(p.id, store: failing, profileId: pid, context: context, now: now)
            XCTFail("提案补偿失败必须抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("补偿失败：提案："), error.localizedDescription)
        }
        let saved = try XCTUnwrap(store.load(p.id))
        XCTAssertEqual(saved.items[0].state, .rejected)
        XCTAssertEqual(saved.items[0].rejection?.at, now)
        XCTAssertNotEqual(saved.items[0].reviewHistory?.last?.fragmentMarks.first?.afterOrganizeRejectedAt, now)
        XCTAssertEqual(row.organizeRejectedAt, now)
        let persisted = try fresh(row.id)
        XCTAssertEqual(persisted.organizeRejectedAt, now)
        XCTAssertEqual(persisted.organizedAt, now.addingTimeInterval(-100))
        XCTAssertEqual(persisted.organizedPage, "主题/旧港")
        MemoryWriteLog.flush()
        let log = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).first)
        XCTAssertFalse(log.ok)
        XCTAssertTrue(log.note.contains("保存审核后像"), log.note)
        XCTAssertTrue(log.note.contains("补偿失败：提案："), log.note)
    }

    func testCoveredCluesAndOtherFloorFragmentsAreNeverMarked() async throws {
        let used = try fragment(), covered = try fragment(), clue = try fragment(), elsewhere = try fragment(profileId: "fictional-other-floor")
        var content = item([used.id, elsewhere.id])
        content.covered = [covered.id]
        let direction = WikiProposal.Direction(path: "主题/另一个虚构方向", title: "虚构", action: .newPage,
            reason: "虚构线索", clues: [clue.id], mode: .daily)
        let p = try proposal([content, .init(change: .direction(direction))])
        let rejected = try await reject(p)
        XCTAssertEqual(try fresh(used.id).organizeRejectedAt, now)
        for row in [covered, clue, elsewhere] {
            XCTAssertEqual(try fresh(row.id).organizeRejectedAt, now.addingTimeInterval(-200))
        }
        XCTAssertEqual(rejected.items[0].reviewHistory?.last?.fragmentMarks.map(\.fragmentId), [used.id])
        XCTAssertEqual(rejected.items[1].reviewHistory?.last?.fragmentMarks, [])
    }

    func testBatchCommonReasonAndPerItemOverridesReachTheCorrectItems() async throws {
        let p = try proposal([item(), item(), item()])
        var draft = WikiRejectionDraft(commonReason: "都是剧场设定")
        draft.overrides[p.items[1].id] = "这一条还混入了推测"
        draft.overrides[p.items[2].id] = ""
        let rejected = try await reject(p, reasons: draft.reasons(for: p.items.map(\.id)))
        XCTAssertEqual(rejected.items.map(\.rejection?.reason), ["都是剧场设定", "这一条还混入了推测", "都是剧场设定"])
        MemoryWriteLog.flush()
        let log = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).first)
        XCTAssertTrue(log.ok)
        XCTAssertEqual(log.note, "驳回 3 条（原因 3 条非空）")
        draft.overrides[p.items[1].id] = String(repeating: "👩🏽‍🚀", count: 200)
        XCTAssertFalse(draft.isOverLimit)
        draft.overrides[p.items[1].id]?.append("字")
        XCTAssertTrue(draft.isOverLimit)
        draft.overrides[p.items[1].id] = "短原因"
        draft.commonReason = String(repeating: "字", count: 201)
        XCTAssertTrue(draft.isOverLimit)
    }

    func testRepeatedRejectionSkipsAlreadyHandledItemsAndPreservesTheirReasonAndMarks() async throws {
        let row = try fragment()
        let p = try proposal([item([row.id]), item()])
        let first = try await WikiProposalReview.reject(p.id, itemIds: [p.items[0].id], reasons: [p.items[0].id: "最初的原因"],
            store: store, profileId: pid, context: context, now: now)
        let next = try await WikiProposalReview.reject(p.id,
            reasons: [p.items[0].id: String(repeating: "字", count: 201), p.items[1].id: "剩余项的原因"],
            store: store, profileId: pid, context: context, now: now.addingTimeInterval(1))
        XCTAssertEqual(next.items[0], first.items[0])
        XCTAssertEqual(next.items[1].rejection?.reason, "剩余项的原因")
        XCTAssertEqual(try fresh(row.id).organizeRejectedAt, now)
        let duplicate = try await reject(next, reasons: [p.items[0].id: "不能覆盖旧因"])
        XCTAssertEqual(duplicate, next)
    }
}
