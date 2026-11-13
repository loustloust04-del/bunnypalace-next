import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class WikiRecordEditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let path = "主题/虚构纸舟夜航"
    private let sources = ["memory/cc/虚构纸舟.md", "memory/cc/虚构星港.md"]
    private var pid = ""
    private var seedId = ""
    private var root: URL!
    private var wiki: WikiStore!
    private var store: WikiProposalStore!
    private var context: ModelContext!

    override func setUp() async throws {
        pid = "xctest-record-edit-" + UUID().uuidString
        seedId = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(pid)
        wiki = WikiStore(root: root)
        store = WikiProposalStore(wiki: wiki)
        let schema = ProfileManager.makeFullSchema()
        context = ModelContext(try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private func fragment(_ text: String) throws -> Memory {
        let row = Memory(content: text, category: "fact", profileId: pid)
        context.insert(row)
        try context.save()
        return row
    }

    private func proposal(_ item: WikiProposal.Item, seed: Bool = false) throws -> WikiProposal {
        let p = WikiProposal(origin: seed ? .seed : .manual, createdAt: now, items: [item], seedTask: seed ? seedId : nil)
        try store.save(p)
        return p
    }

    private func newItem(_ records: [String], ids: [UUID] = [], covered: [UUID]? = nil) -> WikiProposal.Item {
        .init(change: .newPage(page: WikiPage(path: path, kind: .topic, title: "虚构纸舟", now: "剧场设定",
            records: records, entries: sources.map { $0 + "|frozen-v1" }, factDomain: .inWorld)),
            fragmentIds: ids, cites: sources.map { .init(layer: "CC", filePath: $0) }, covered: covered,
            checks: ["虚构旧检查"])
    }

    func testImplicitConversionIsRejectedForTextAndStructuredEdits() throws {
        for line in ["虚构纸舟（出处：碎片 11111111）", "虚构纸舟（memory/cc/虚构纸舟.md）"] {
            let item = newItem([line])
            for manual in ["虚构纸舟", "虚构纸舟（出处：用户编辑）"] {
                var draft = WikiProposalDraft(item.change)
                draft.records[0].deleted = true
                draft.records.append(.init(line: manual))
                XCTAssertThrowsError(try WikiProposalStore.edited(item, change: draft.apply(to: item.change), judgment: nil)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("改为手写事实"))
                }
                guard case .newPage(var page) = item.change else { return XCTFail() }
                page.records = [manual]
                XCTAssertThrowsError(try CatalogSeedDrafts.parsePage(page.markdown, item: item, task: nil, wiki: wiki))
            }
        }
    }

    func testBodyEditPreservesTheOriginalSourceSuffixVerbatim() throws {
        let suffix = "（出处：memory/cc/虚构纸舟.md）"
        let item = newItem(["虚构旧正文" + suffix])
        var draft = WikiProposalDraft(item.change)
        draft.records[0].body = "虚构修订正文"
        let saved = try WikiProposalStore.edited(item, change: draft.apply(to: item.change), judgment: nil)
        guard case .newPage(let page) = saved.change else { return XCTFail() }
        XCTAssertEqual(page.records, ["虚构修订正文" + suffix])
        XCTAssertEqual(page.entries, [sources[0] + "|frozen-v1"])
    }

    func testStructuredRecordWithEmbeddedNewlineIsRejected() throws {
        let item = newItem(["虚构原稿（出处：用户编辑）"])
        guard case .newPage(var page) = item.change else { return XCTFail() }
        page.records = ["虚构第一条（出处：用户编辑）", "虚构第二条\n夹入的第三条（出处：用户编辑）"]
        XCTAssertThrowsError(try WikiProposalStore.edited(item, change: .newPage(page: page), judgment: nil)) { error in
            XCTAssertEqual(error.localizedDescription, "第 2 条记录里有换行；一条记录一行，要两条用「加一行」")
        }
    }

    func testModelToolSchemasCannotAuthorizeHandConversion() throws {
        let direction = WikiProposal.Direction(path: path, title: "虚构纸舟", kind: .topic, action: .newPage,
            reason: "虚构目录", mode: .seed, sources: sources)
        let tools = CatalogAgentTools.definitions(submitOnly: false)
            + CatalogSeedTools.pageDefinitions(item: "fictional-item", direction: direction)
        let schema = String(decoding: try JSONSerialization.data(withJSONObject: tools), as: UTF8.self).lowercased()
        XCTAssertFalse(schema.contains("conversion"))
        XCTAssertFalse(schema.contains("trusted"))
    }

    func testSeedDirectionRejectsTargetDeletedAfterSnapshot() throws {
        let version = try wiki.save(WikiPage(path: path, kind: .topic, title: "虚构纸舟", factDomain: .inWorld))
        var task = CatalogSeedTask(id: seedId, profileId: pid, entry: .cc, modelName: "fictional-no-model",
            createdAt: now, run: .init(path: ".runs/fictional.md"))
        task.read = [sources[0]: "frozen-v1", CatalogSeedMaterials.wikiPath(path): version]
        let direction = WikiProposal.Direction(path: path, title: "虚构纸舟", kind: .topic, action: .update,
            reason: "虚构目录", mode: .seed, sources: [sources[0]], factDomain: .inWorld)
        let item = WikiProposal.Item(change: .direction(direction))
        try FileManager.default.removeItem(at: wiki.pageURL(path))
        XCTAssertThrowsError(try CatalogSeedDrafts.validate(item.change, original: item, task: task, wiki: wiki)) { error in
            XCTAssertEqual(error.localizedDescription, "「\(path)」在提案之后被删了（页已变），不能再改这条")
        }
    }

    func testExistingManualRecordDoesNotAuthorizeAnImplicitCopyOfACodeRecord() throws {
        let code = "虚构同文事实（出处：碎片 11111111）"
        let manual = "虚构同文事实（出处：用户编辑）"
        let original = [code, manual]
        XCTAssertEqual(try CatalogSources.checkEdited(original, original: original, allowed: []), original)
        XCTAssertEqual(try CatalogSources.checkEdited([manual], original: original, allowed: []), [manual])
        XCTAssertThrowsError(try CatalogSources.checkEdited([manual, manual], original: original, allowed: []))
        let conversion = CatalogSources.Conversion(index: 0, fingerprint: CatalogSources.fingerprint(code), newLine: manual)
        XCTAssertEqual(try CatalogSources.checkEdited([manual, manual], original: original, allowed: [], conversions: [conversion]), [manual, manual])
    }

    func testExplicitConversionPersistsLineAuditWithoutFactOrCitationPromotion() async throws {
        let row = try fragment("虚构纸舟记录")
        let original = "虚构纸舟（出处：\(CatalogSources.label(row.id))；CC \(sources[0])）"
        var item = newItem([original], ids: [row.id])
        item.cites = [item.cites[0]]
        let p = try proposal(item, seed: true)
        var draft = WikiProposalDraft(item.change)
        draft.records[0].body = "本人手写的虚构纸舟说明"
        draft.records[0].converted = true
        let saved = try await CatalogSeedDrafts.saveChange(p.id, itemId: item.id, change: draft.apply(to: item.change),
            baseline: item.change, wiki: wiki, conversions: draft.conversions)
        let reloaded = try XCTUnwrap(store.load(p.id))
        let edited = reloaded.items[0]
        guard case .newPage(let page) = edited.change else { return XCTFail() }
        XCTAssertEqual(page.records, ["本人手写的虚构纸舟说明（出处：用户编辑）"])
        XCTAssertEqual(page.factDomain, .inWorld)
        XCTAssertEqual(edited.fragmentIds, [])
        XCTAssertEqual(edited.cites, [])
        XCTAssertEqual(page.entries, [])
        XCTAssertEqual(edited.checks, item.checks)
        XCTAssertEqual(edited.checksEdited, true)
        let record = try XCTUnwrap(edited.reviewHistory?.last)
        XCTAssertEqual(record.at.timeIntervalSince1970, saved.items[0].reviewHistory?.last?.at.timeIntervalSince1970)
        XCTAssertEqual(record.kind, .handConverted)
        XCTAssertEqual(record.origin, .user)
        XCTAssertNil(record.rejection)
        XCTAssertEqual(record.fragmentMarks, [])
        XCTAssertEqual(record.conversions, [.init(index: 0, originalLine: original,
            originalLabels: [CatalogSources.label(row.id), "CC " + sources[0]], newLine: page.records[0])])
        XCTAssertNil(wiki.read(path), "保存仍待批，不写活页")
        let approved = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now)
        XCTAssertEqual(approved.items[0].approval?.fragmentMarks, [])
        XCTAssertEqual(approved.items[0].approval?.addedEntries[path], [])
        XCTAssertEqual(wiki.read(path)?.factDomain, .inWorld)
        XCTAssertEqual(wiki.read(path)?.entries, [])
    }

    func testConversionAfterDeletionRetainsOriginalIndexAndDoesNotAuthorizeOtherRows() throws {
        let lines = ["删除的虚构行（memory/cc/虚构纸舟.md）", "转换的虚构行（memory/cc/虚构星港.md）",
                     "仍需出处的虚构行（出处：碎片 33333333）"]
        let item = newItem(lines)
        var draft = WikiProposalDraft(item.change)
        draft.records[0].deleted = true
        draft.records[1].body = "手写的虚构星港"
        draft.records[1].converted = true
        draft.records.append(.init(line: "全新虚构茶馆"))
        let saved = try WikiProposalStore.edited(item, change: draft.apply(to: item.change), judgment: nil, conversions: draft.conversions, now: now)
        XCTAssertEqual(saved.reviewHistory?.last?.conversions?.first?.index, 1)
        XCTAssertEqual(saved.reviewHistory?.last?.conversions?.first?.originalLine, lines[1])
        guard case .newPage(let page) = saved.change else { return XCTFail() }
        XCTAssertEqual(page.records, ["手写的虚构星港（出处：用户编辑）", lines[2], "全新虚构茶馆（出处：用户编辑）"])
        var bad = page
        bad.records[1] = "仍需出处的虚构行（出处：用户编辑）"
        XCTAssertThrowsError(try WikiProposalStore.edited(item, change: .newPage(page: bad), judgment: nil, conversions: draft.conversions))
    }

    func testConversionRejectsStaleFingerprintUnneededAndMismatchedOutput() throws {
        let original = "虚构纸舟（memory/cc/虚构纸舟.md）"
        let manual = "虚构纸舟（出处：用户编辑）"
        let valid = CatalogSources.Conversion(index: 0, fingerprint: CatalogSources.fingerprint(original), newLine: manual)
        for conversion in [CatalogSources.Conversion(index: 0, fingerprint: "wrong", newLine: manual),
                           .init(index: 5, fingerprint: valid.fingerprint, newLine: manual)] {
            XCTAssertThrowsError(try CatalogSources.checkEdited([manual], original: [original], allowed: [], conversions: [conversion])) { error in
                XCTAssertTrue(error.localizedDescription.contains("重新打开再转"))
            }
        }
        for line in ["无出处虚构行", manual] {
            let conversion = CatalogSources.Conversion(index: 0, fingerprint: CatalogSources.fingerprint(line), newLine: manual)
            XCTAssertThrowsError(try CatalogSources.checkEdited([manual], original: [line], allowed: [], conversions: [conversion])) { error in
                XCTAssertEqual(error.localizedDescription, "这行不需要转换")
            }
        }
        XCTAssertThrowsError(try CatalogSources.checkEdited(["另一条手写（出处：用户编辑）"], original: [original], allowed: [], conversions: [valid]))
        XCTAssertThrowsError(try CatalogSources.checkEdited([manual], original: [original], allowed: [], conversions: [valid, valid]))
    }

    func testDeletingLastSourcePrunesOwnershipBeforeApprovalForOrdinaryAndSeed() async throws {
        for seed in [false, true] {
            let removed = try fragment("虚构被删来源"), kept = try fragment("虚构保留来源"), covered = try fragment("虚构独立覆盖")
            let lines = ["被删的虚构纸舟（出处：\(CatalogSources.label(removed.id))；\(sources[0])）",
                         "保留的虚构星港（出处：\(CatalogSources.label(kept.id))；\(sources[1])）"]
            let item = newItem(lines, ids: [removed.id, kept.id], covered: [covered.id])
            let p = try proposal(item, seed: seed)
            var draft = WikiProposalDraft(item.change)
            draft.records[0].deleted = true
            let edited: WikiProposal
            if seed {
                edited = try await CatalogSeedDrafts.saveChange(p.id, itemId: item.id, change: draft.apply(to: item.change), baseline: item.change, wiki: wiki)
            } else {
                edited = try await WikiProposalReview.edit(p.id, itemId: item.id, change: draft.apply(to: item.change), judgment: nil, store: store)
            }
            XCTAssertEqual(edited.items[0].fragmentIds, [kept.id])
            XCTAssertEqual(edited.items[0].cites, [item.cites[1]])
            XCTAssertEqual(edited.items[0].covered, [covered.id])
            let approved = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now)
            let receipt = try XCTUnwrap(approved.items[0].approval)
            XCTAssertEqual(approved.items[0].state, .approved)
            XCTAssertEqual(Set(receipt.fragmentMarks.map(\.fragmentId)), Set([kept.id, covered.id]))
            XCTAssertEqual(receipt.addedEntries[path], [sources[1] + "|frozen-v1"])
            XCTAssertEqual(wiki.read(path)?.entries, [sources[1] + "|frozen-v1"])
            XCTAssertEqual(wiki.read(path)?.records, [lines[1]])
            let fresh = ModelContext(context.container)
            let removedId = removed.id
            let row = try XCTUnwrap(fresh.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.id == removedId })).first)
            XCTAssertNil(row.organizedAt)
            XCTAssertNil(row.organizedPage)
            try FileManager.default.removeItem(at: wiki.pageURL(path))
        }
    }

    func testSameSourceRemainsUntilItsLastRecordIsConverted() throws {
        let id = UUID()
        let label = CatalogSources.label(id)
        let lines = ["第一段虚构（出处：\(label)；CC \(sources[0])）", "第二段虚构（出处：\(label)；CC \(sources[0])）"]
        let item = newItem(lines, ids: [id])
        var draft = WikiProposalDraft(item.change)
        draft.records[0].converted = true
        let saved = try WikiProposalStore.edited(item, change: draft.apply(to: item.change), judgment: nil, conversions: draft.conversions)
        XCTAssertEqual(saved.fragmentIds, [id])
        XCTAssertEqual(saved.cites, item.cites)
        guard case .newPage(let page) = saved.change else { return XCTFail() }
        XCTAssertEqual(page.entries, [sources[0] + "|frozen-v1"])
        var last = WikiProposalDraft(saved.change)
        last.records[1].converted = true
        let converted = try WikiProposalStore.edited(saved, change: last.apply(to: saved.change), judgment: nil, conversions: last.conversions)
        XCTAssertEqual(converted.fragmentIds, [])
        XCTAssertEqual(converted.cites, [item.cites[1]])
    }

    func testCoveredOwnershipSurvivesRemovalOfOverlappingRecordSource() async throws {
        let row = try fragment("虚构重复归属")
        let id = row.id
        let item = newItem(["虚构重复归属（出处：\(CatalogSources.label(id))）"], ids: [id], covered: [id])
        var draft = WikiProposalDraft(item.change)
        draft.records[0].deleted = true
        draft.records.append(.init(line: "全新手写虚构行"))
        let saved = try WikiProposalStore.edited(item, change: draft.apply(to: item.change), judgment: nil)
        XCTAssertEqual(saved.covered, item.covered)
        XCTAssertFalse(saved.fragmentIds.contains(id))
        let p = try proposal(saved)
        let approved = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now)
        XCTAssertTrue(try XCTUnwrap(approved.items[0].approval).fragmentMarks.contains { $0.fragmentId == id })
    }

    func testTitleEditKeepsIdentityDomainAndBaselineAndRecomputesUntil() throws {
        var item = newItem(["虚构记录（出处：用户编辑）"])
        item.baseVersion = "frozen-baseline"
        var draft = WikiProposalDraft(item.change)
        draft.title = "虚构纸舟的新显示名"
        draft.now = "剧场夜航（到 2027-02-03）"
        let saved = try WikiProposalStore.edited(item, change: draft.apply(to: item.change), judgment: nil)
        guard case .newPage(let page) = saved.change else { return XCTFail() }
        XCTAssertEqual(page.title, "虚构纸舟的新显示名")
        XCTAssertEqual(page.path, path)
        XCTAssertEqual(page.kind, .topic)
        XCTAssertEqual(page.factDomain, .inWorld)
        XCTAssertEqual(page.validUntil, "2027-02-03")
        XCTAssertEqual(saved.baseVersion, "frozen-baseline")
    }

    func testReopenedConversionKeepsRejectionAndConversionHistory() async throws {
        let row = try fragment("虚构纸舟原料")
        let item = newItem(["虚构纸舟（出处：\(CatalogSources.label(row.id))）"], ids: [row.id])
        let p = try proposal(item)
        let rejected = try await WikiProposalReview.reject(p.id, reasons: [item.id: "这是虚构设定"], store: store, profileId: pid, context: context, now: now)
        var draft = WikiProposalDraft(rejected.items[0].change)
        draft.records[0].converted = true
        let result = try await WikiProposalReview.reopen(p.id, itemId: item.id, change: draft.apply(to: item.change),
            baseline: item.change, judgment: nil, store: store, profileId: pid, context: context, now: now.addingTimeInterval(60), conversions: draft.conversions)
        let saved = try XCTUnwrap(store.load(p.id))
        XCTAssertEqual(saved, result.proposal)
        XCTAssertEqual(saved.items[0].reviewHistory?.map(\.kind), [.rejected, .handConverted, .reopened])
        XCTAssertEqual(saved.items[0].reviewHistory?[1].conversions?.first?.originalLine, draft.records[0].body + "（出处：\(CatalogSources.label(row.id))）")
        XCTAssertEqual(saved.items[0].state, .pending)
        XCTAssertEqual(saved.items[0].fragmentIds, [])
        XCTAssertNil(saved.items[0].rejection)
        XCTAssertNil(saved.finishedAt)
    }

    func testAppendOnlyAddsRetainedFrozenEntriesAndNeverRemovesExistingOnes() async throws {
        let oldEntry = "memory/cc/虚构旧港.md|old-v0"
        let oldLine = "旧虚构港口（memory/cc/虚构旧港.md）"
        let version = try wiki.save(WikiPage(path: path, kind: .topic, title: "虚构旧页", records: [oldLine], entries: [oldEntry], factDomain: .inWorld))
        var task = CatalogSeedTask(id: seedId, profileId: pid, entry: .cc, modelName: "fictional", createdAt: now, run: .init(path: ".runs/fictional.md"))
        task.read = Dictionary(uniqueKeysWithValues: sources.map { ($0, "frozen-v1") })
        task.carded = task.read
        try CatalogSeedTaskStore(wiki: wiki).save(task)
        let lines = ["新虚构纸舟（\(sources[0])）", "新虚构星港（\(sources[1])）"]
        let item = WikiProposal.Item(change: .appendRecords(path: path, lines: lines), cites: sources.map { .init(layer: "CC", filePath: $0) }, baseVersion: version)
        let p = try proposal(item, seed: true)
        var draft = WikiProposalDraft(item.change)
        XCTAssertEqual(draft.records.map(\.body), ["新虚构纸舟", "新虚构星港"], "不载入原页已有记录")
        draft.records[0].converted = true
        _ = try await CatalogSeedDrafts.saveChange(p.id, itemId: item.id, change: draft.apply(to: item.change), baseline: item.change, wiki: wiki, conversions: draft.conversions)
        let approved = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: context, now: now)
        XCTAssertEqual(wiki.read(path)?.entries, [oldEntry, sources[1] + "|frozen-v1"])
        XCTAssertEqual(wiki.read(path)?.records, [oldLine, "新虚构纸舟（出处：用户编辑）", lines[1]])
        XCTAssertEqual(approved.items[0].approval?.addedEntries[path], [sources[1] + "|frozen-v1"])
    }
}
