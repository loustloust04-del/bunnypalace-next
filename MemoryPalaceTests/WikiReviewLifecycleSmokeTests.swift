import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
private final class WikiReviewLifecycleFixture {
    let pid = "xctest-review-lifecycle-" + UUID().uuidString
    let floor = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-review-lifecycle-" + UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let path = "主题/虚构云桥夜航", existing = "主题/虚构灯塔"
    let sources = ["memory/cc/虚构旧航线.md", "memory/cc/虚构手写航线.md", "memory/cc/虚构星图.md", "memory/cc/虚构共用码头.md"]
    let context: ModelContext
    let seed: Bool
    var wiki: WikiStore
    var store: WikiProposalStore { WikiProposalStore(wiki: wiki) }
    var fragments: [Memory] = []
    var proposal: WikiProposal!
    var task: CatalogSeedTask!
    var outline: WikiProposal!
    var cards: [String: MemoryRegeneration.FileInfo] = [:]
    var originalPage = ""
    private var checkedLogs = Set<UUID>()
    var ids: [UUID] { fragments.map(\.id) }

    init(seed: Bool) throws {
        self.seed = seed
        wiki = WikiStore(root: floor.appendingPathComponent("memory/wiki"))
        let schema = ProfileManager.makeFullSchema()
        context = ModelContext(try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
    }

    func prepare() async throws {
        for text in ["虚构删除来源", "虚构转换来源", "虚构保留来源", "虚构共享来源", "虚构独立覆盖"] {
            let row = Memory(content: text, category: "fact", profileId: pid)
            context.insert(row)
            fragments.append(row)
        }
        try context.save()
        let wiki = wiki, now = now, sources = sources, pid = pid, existing = existing, path = path, ids = ids, seed = seed
        let prepared = try await Task.detached {
            let old = WikiPage(path: existing, kind: .topic, triggers: ["reviewlifecycle"], title: "虚构灯塔",
                now: "设定中的旧灯塔", records: ["虚构旧灯火（出处：用户编辑）"], entries: ["memory/cc/虚构历史.md|old-v0"], factDomain: .inWorld)
            try wiki.save(old, now: now)
            let materials = CatalogSeedMaterials(items: sources.enumerated().map { index, source in
                let text = "全虚构原料 \(index)：云桥城的夜航设定。"
                return .init(path: source, name: "虚构航线 \(index)", layer: "CC", text: text,
                    version: WikiStore.version(of: Data(text.utf8)))
            })
            var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc, modelName: "fictional-no-model",
                createdAt: now, run: .init(path: ".runs/fictional.md"))
            let tasks = CatalogSeedTaskStore(wiki: wiki)
            _ = try tasks.writeSnapshot(materials, id: task.id)
            task.materials = materials.items.map { .init(path: $0.path, name: $0.name, layer: $0.layer, version: $0.version) }
            task.read = Dictionary(uniqueKeysWithValues: materials.items.map { ($0.path, $0.version) })
            task.carded = task.read
            for material in materials.items {
                try SeedNoteStore(wiki: wiki).save(.init(path: material.path, version: material.version, name: material.name,
                    layer: "CC", title: material.name, gist: "虚构夜航设定", mentions: [], aboutUser: false, group: "主题",
                    when: [], model: task.modelName, madeAt: now, run: task.run, factDomain: .inWorld))
            }
            try tasks.save(task)
            let direction = WikiProposal.Direction(path: path, title: "虚构云桥夜航", kind: .topic, action: .newPage,
                reason: "全虚构目录", mode: .seed, sources: sources, factDomain: .inWorld)
            let outline = WikiProposal(id: task.id, origin: .seed, createdAt: now,
                items: [.init(change: .direction(direction))], seedTask: task.id)
            if seed { try WikiProposalStore(wiki: wiki).save(outline) }
            let records = sources.enumerated().map { index, source in
                "虚构代码记录 \(index)（出处：\(source)；\(CatalogSources.label(ids[index]))）"
            }
            let page = WikiPage(path: path, kind: .topic, triggers: ["reviewlifecycle"], hook: "虚构旧钩子", title: "虚构云桥夜航",
                now: "设定中等灯（到 2027-01-01）", validUntil: "2027-01-01", records: records,
                entries: sources.map { $0 + "|" + task.read[$0]! }, factDomain: .inWorld)
            let p = WikiProposal(origin: seed ? .seed : .manual, createdAt: now, items: [
                .init(change: .newPage(page: page), fragmentIds: Array(ids.prefix(4)),
                    cites: sources.map { .init(layer: "CC", filePath: $0) }, covered: [ids[4]], checks: ["虚构旧检查"]),
                .init(change: .appendRecords(path: existing, lines: [records[3]]), fragmentIds: [ids[3]],
                    cites: [.init(layer: "CC", filePath: sources[3])], baseVersion: wiki.version(of: existing))
            ], directionRef: seed ? .init(proposalId: outline.id, itemId: outline.items[0].id) : nil, seedTask: seed ? task.id : nil)
            try WikiProposalStore(wiki: wiki).save(p)
            try wiki.rebuildAllIndexes()
            return (task, outline, p, old.markdown, try MemoryRegeneration.inventory(wiki.root.appendingPathComponent(".cards")))
        }.value
        task = prepared.0
        outline = prepared.1
        proposal = prepared.2
        originalPage = prepared.3
        cards = prepared.4
        CatalogRecallIndexer.shared.ensure(profileId: pid, wiki: wiki)
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
    }

    func reload(_ expected: WikiProposal? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> WikiProposal {
        let wiki = WikiStore(root: wiki.root), id = proposal.id
        let loaded = await Task.detached { WikiProposalStore(wiki: wiki).load(id) }.value
        let p = try XCTUnwrap(loaded, file: file, line: line)
        if let expected { XCTAssertEqual(p, expected, file: file, line: line) }
        return p
    }

    func assertMarks(_ rejected: [UUID: Date], organized: Set<UUID> = [], at: Date? = nil,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = try ModelContext(context.container).fetch(FetchDescriptor<Memory>()).filter { $0.profileId == pid }
        XCTAssertEqual(Set(rows.map(\.id)), Set(ids), file: file, line: line)
        for row in rows {
            XCTAssertEqual(row.organizeRejectedAt, rejected[row.id], file: file, line: line)
            XCTAssertEqual(row.organizedAt, organized.contains(row.id) ? at : nil, file: file, line: line)
            XCTAssertEqual(row.organizedPage, organized.contains(row.id) ? path : nil, file: file, line: line)
        }
    }

    func reject(_ p: WikiProposal, onlyFirst: Bool = false, at: Date? = nil, store: WikiProposalStore? = nil,
                saveMarks: WikiProposalReview.SaveMarks = { try $0.save() }) async throws -> WikiProposal {
        let common = "这是剧场设定，不是现实经历"
        var reasons = Dictionary(uniqueKeysWithValues: p.items.map { ($0.id, common) })
        reasons[p.items[1].id] = "灯塔同样只在设定中"
        return try await WikiProposalReview.reject(p.id, itemIds: onlyFirst ? [p.items[0].id] : nil, reasons: reasons,
            store: store ?? self.store, profileId: pid, context: context, now: at ?? now, saveMarks: saveMarks)
    }

    func reopen(_ p: WikiProposal, change: WikiProposal.Change? = nil, baseline: WikiProposal.Change? = nil,
                conversions: [CatalogSources.Conversion] = [], store: WikiProposalStore? = nil,
                saveMarks: WikiProposalReview.SaveMarks = { try $0.save() }) async throws -> WikiProposalReview.ReopenResult {
        let item = p.items[0]
        var draft = WikiProposalDraft(item.change)
        draft.hook = "只谈虚构夜航设定"
        return try await WikiProposalReview.reopen(p.id, itemId: item.id, change: change ?? draft.apply(to: item.change),
            baseline: baseline ?? item.change, judgment: .coexist, store: store ?? self.store, profileId: pid, context: context,
            now: now.addingTimeInterval(60), conversions: conversions, saveMarks: saveMarks)
    }

    func assertFailureLog(_ stage: String, compensation: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        MemoryWriteLog.flush()
        let entries = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        let failures = entries.filter { !$0.ok && !checkedLogs.contains($0.id) }
        checkedLogs.formUnion(entries.map(\.id))
        XCTAssertEqual(failures.count, 1, "只核对本次注入产生的失败行", file: file, line: line)
        let entry = try XCTUnwrap(failures.first, file: file, line: line)
        XCTAssertFalse(entry.ok, file: file, line: line)
        XCTAssertTrue(entry.note.contains(stage), entry.note, file: file, line: line)
        XCTAssertEqual(entry.note.contains("补偿失败"), compensation, entry.note, file: file, line: line)
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
final class WikiReviewLifecycleSmokeTests: XCTestCase {
    private var f: WikiReviewLifecycleFixture!

    override func tearDown() async throws { if let f { try await f.cleanup() } }

    private func prepare(seed: Bool) async throws {
        f = try WikiReviewLifecycleFixture(seed: seed)
        try await f.prepare()
    }

    private func ordered(_ text: String, _ sections: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        var start = text.startIndex
        for section in sections {
            let range = try XCTUnwrap(text.range(of: section, range: start..<text.endIndex), section, file: file, line: line)
            start = range.upperBound
        }
    }

    private func feedback(_ p: WikiProposal, at: Date? = nil) async -> [WikiFeedback.Entry] {
        let path = f.path, sources = f.sources, versions = f.task.read, ids = f.ids, now = at ?? f.now
        let selected = WikiFeedback.select(.init(targetPath: path,
            sources: sources.map { .init(path: $0, version: versions[$0]) }, fragmentIds: Set(ids.prefix(4))),
            proposals: [p], receipts: [], now: now)
        return selected
    }

    func testOrdinaryReviewThroughApprovalAndFreshRecall() async throws { try await lifecycle(seed: false) }
    func testSeedReviewThroughApprovalAndFreshRecall() async throws { try await lifecycle(seed: true) }

    private func lifecycle(seed: Bool) async throws {
        try await prepare(seed: seed)
        XCTAssertEqual(f.cards.count, 4)
        if seed {
            let original = f.outline.items[0], wiki = f.wiki, missing = f.sources[0]
            var unread = try XCTUnwrap(f.task)
            unread.read.removeValue(forKey: missing)
            let task = unread
            XCTAssertFalse(task.readable.contains(missing))
            do {
                _ = try await Task.detached {
                    try CatalogSeedDrafts.validate(original.change, original: original, task: task, wiki: wiki)
                }.value
                XCTFail("种子改稿不能加入未入快照的原料")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(missing), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("原料不是这次读过的"), error.localizedDescription)
            }
        }
        let initial = try await f.reload(f.proposal)
        let rejected = try await f.reject(initial)
        var saved = try await f.reload(rejected)
        XCTAssertEqual(saved.items.map(\.state), [.rejected, .rejected])
        XCTAssertEqual(saved.items.compactMap { $0.rejection?.reason }, ["这是剧场设定，不是现实经历", "灯塔同样只在设定中"])
        for item in saved.items {
            XCTAssertEqual(item.reviewHistory?.map(\.kind), [.rejected])
            XCTAssertEqual(item.reviewHistory?.map(\.origin), [.user])
            XCTAssertEqual(item.reviewHistory?.first?.rejection, item.rejection)
            XCTAssertEqual(item.rejection?.sourceSignature.fragmentIds, item.fragmentIds.sorted { $0.uuidString < $1.uuidString })
        }
        try f.assertMarks(Dictionary(uniqueKeysWithValues: f.ids.prefix(4).map { ($0, f.now) }))
        let entries = await feedback(saved)
        let rejectionIds = Set(saved.items.compactMap { $0.reviewHistory?.first?.id })
        XCTAssertEqual(Set(entries.map(\.operationId)), rejectionIds)
        let bySource = WikiFeedback.select(.init(targetPath: "主题/虚构另页", fragmentIds: [f.ids[3]]), proposals: [saved], receipts: [], now: f.now)
        XCTAssertEqual(Set(bySource.map(\.operationId)), rejectionIds)
        if seed {
            let query = WikiFeedback.Query(sources: [.init(path: f.sources[3], version: f.task.read[f.sources[3]])])
            XCTAssertEqual(Set(WikiFeedback.select(query, proposals: [saved], receipts: [], now: f.now).map(\.operationId)), rejectionIds)
        }
        XCTAssertTrue(WikiFeedback.select(.init(targetPath: "主题/虚构无关", sources: [.init(path: "memory/cc/虚构无关.md", version: "unrelated")],
            fragmentIds: [UUID()]), proposals: [saved], receipts: [], now: f.now).isEmpty)
        try await assertPromptConsumers(entries)
        let reopened = try await f.reopen(saved)
        saved = try await f.reload(reopened.proposal)
        XCTAssertEqual(saved.items.map(\.state), [.pending, .rejected])
        XCTAssertNil(saved.items[0].rejection)
        XCTAssertEqual(saved.items[0].reviewHistory?.map(\.kind), [.rejected, .reopened])
        XCTAssertEqual(reopened.kept, [f.ids[3]])
        XCTAssertFalse(reopened.unrecorded)
        XCTAssertTrue(reopened.notice?.contains("拒绝标记保留") == true)
        try f.assertMarks([f.ids[3]: f.now])
        let againAt = f.now.addingTimeInterval(120)
        let again = try await f.reject(saved, onlyFirst: true, at: againAt)
        saved = try await f.reload(again)
        XCTAssertEqual(saved.items[0].reviewHistory?.map(\.kind), [.rejected, .reopened, .rejected])
        XCTAssertEqual(saved.items[1], rejected.items[1])
        let repeated = await feedback(saved, at: againAt)
        XCTAssertEqual(Set(repeated.map(\.operationId)), Set(saved.items.flatMap { $0.reviewHistory ?? [] }.filter { $0.kind == .rejected }.map(\.id)))
        XCTAssertEqual(Set(repeated.map(\.targetPath)), Set([f.path, f.existing]))
        try f.assertMarks(Dictionary(uniqueKeysWithValues: f.ids.prefix(4).map { ($0, againAt) }))
        let item = saved.items[0]
        var draft = WikiProposalDraft(item.change)
        let originalConverted = try XCTUnwrap(draft.records[1].line)
        draft.title = "虚构云桥修订夜航"
        draft.now = "设定中等新灯（到 2027-02-03）"
        draft.hook = "提到虚构新灯时看这页"
        draft.triggers = "reviewlifecycle、虚构新灯"
        draft.records[0].deleted = true
        draft.records[1].body = "本人手写的虚构航路说明"
        draft.records[1].converted = true
        draft.records.append(.init(line: "新增的虚构手写事实"))
        let change = draft.apply(to: item.change)
        guard case .newPage(var invalid) = change else { return XCTFail() }
        invalid.records[0] += "\n夹入一条虚构记录"
        do {
            _ = try await f.reopen(saved, change: .newPage(page: invalid), conversions: draft.conversions)
            XCTFail("夹换行必须拒存")
        } catch { XCTAssertTrue(error.localizedDescription.contains("记录里有换行")) }
        var conversions = draft.conversions
        conversions[0].fingerprint = "stale-fingerprint"
        do {
            _ = try await f.reopen(saved, change: change, conversions: conversions)
            XCTFail("旧指纹必须拒存")
        } catch { XCTAssertTrue(error.localizedDescription.contains("重新打开再转")) }
        guard case .newPage(var stripped) = item.change else { return XCTFail() }
        stripped.records[1] = CatalogSources.split(stripped.records[1]).body
        do {
            _ = try await f.reopen(saved, change: .newPage(page: stripped))
            XCTFail("纯文本去出处必须拒存")
        } catch { XCTAssertTrue(error.localizedDescription.contains("改为手写事实")) }
        _ = try await f.reload(saved)
        try f.assertMarks(Dictionary(uniqueKeysWithValues: f.ids.prefix(4).map { ($0, againAt) }))
        let edited = try await f.reopen(saved, change: change, conversions: draft.conversions)
        saved = try await f.reload(edited.proposal)
        let updated = saved.items[0]
        XCTAssertEqual(updated.state, .pending)
        XCTAssertNil(updated.rejection)
        XCTAssertNil(saved.finishedAt)
        XCTAssertEqual(updated.fragmentIds, [f.ids[2], f.ids[3]])
        XCTAssertEqual(updated.cites, Array(item.cites.suffix(2)))
        XCTAssertEqual(updated.covered, item.covered)
        XCTAssertEqual(updated.checks, item.checks)
        XCTAssertEqual(updated.checksEdited, true)
        XCTAssertEqual(updated.reviewHistory?.map(\.kind), [.rejected, .reopened, .rejected, .handConverted, .reopened])
        let converted = try XCTUnwrap(updated.reviewHistory?.last(where: { $0.kind == .handConverted }))
        XCTAssertEqual(converted.origin, .user)
        XCTAssertEqual(converted.conversions, [.init(index: 1, originalLine: originalConverted,
            originalLabels: [f.sources[1], CatalogSources.label(f.ids[1])], newLine: "本人手写的虚构航路说明（出处：用户编辑）")])
        guard case .newPage(let pendingPage) = updated.change else { return XCTFail() }
        let expectedRecords = ["本人手写的虚构航路说明（出处：用户编辑）"] + Array(stripped.records.suffix(2)) + ["新增的虚构手写事实（出处：用户编辑）"]
        let expectedEntries = f.sources.suffix(2).map { $0 + "|" + f.task.read[$0]! }
        XCTAssertEqual(pendingPage.records, expectedRecords)
        XCTAssertEqual(pendingPage.entries, expectedEntries)
        XCTAssertEqual(edited.kept, [f.ids[3]])
        try f.assertMarks([f.ids[3]: againAt])
        XCTAssertNil(f.wiki.read(f.path), "改稿不能提前落成活页")
        XCTAssertEqual(f.wiki.readRaw(f.existing), f.originalPage)
        if seed {
            let source = f.sources[2], floor = f.floor
            let liveVersion = try await Task.detached {
                let url = floor.appendingPathComponent(source)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("全虚构活原料：快照后已改成白昼航线。".utf8).write(to: url, options: .atomic)
                return WikiStore.version(of: try Data(contentsOf: url))
            }.value
            XCTAssertNotEqual(liveVersion, f.task.read[source])
        }
        let approvedAt = f.now.addingTimeInterval(180)
        let approved = try await WikiProposalReview.approve(saved.id, itemIds: [updated.id], store: f.store,
            profileId: f.pid, context: f.context, now: approvedAt)
        saved = try await f.reload(approved)
        XCTAssertEqual(saved.items.map(\.state), [.approved, .rejected])
        let receipt = try XCTUnwrap(saved.items[0].approval)
        XCTAssertEqual(receipt.phase, .committed)
        XCTAssertEqual(Set(receipt.fragmentMarks.map(\.fragmentId)), Set([f.ids[2], f.ids[3], f.ids[4]]))
        XCTAssertEqual(receipt.addedEntries[f.path], expectedEntries)
        try f.assertMarks([f.ids[3]: againAt], organized: Set([f.ids[2], f.ids[3], f.ids[4]]), at: approvedAt)
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: f.pid)
        XCTAssertEqual(f.cards.count, 4)
        let index = try XCTUnwrap(CatalogRecallIndexer.shared.store(profileId: f.pid))
        let wiki = f.wiki, path = f.path, pid = f.pid, cards = f.cards
        try await Task.detached {
            let raw = try XCTUnwrap(WikiStore(root: wiki.root).readRaw(path))
            let page = WikiPage.parse(raw, path: path)
            XCTAssertEqual(page.title, "虚构云桥修订夜航")
            XCTAssertEqual(page.now, "设定中等新灯（到 2027-02-03）")
            XCTAssertEqual(page.validUntil, "2027-02-03")
            XCTAssertEqual(page.hook, "提到虚构新灯时看这页")
            XCTAssertEqual(page.triggers, ["reviewlifecycle", "虚构新灯"])
            XCTAssertEqual(page.factDomain, .inWorld)
            XCTAssertEqual(page.records, expectedRecords)
            XCTAssertEqual(page.entries, expectedEntries)
            let snapshot = WikiInjection.load(wiki)
            let injected = try XCTUnwrap(snapshot.pages.first { $0.path == path })
            XCTAssertEqual(injected.now, page.now)
            XCTAssertEqual(injected.version, wiki.version(of: path))
            let hits = try index.search(terms: ["reviewlifecycle"], profileId: pid, kinds: [.page])
            let verified = index.verified(hits, snapshot: snapshot, maximumCount: 20)
            XCTAssertEqual(verified.first { $0.path == path }?.version, wiki.version(of: path))
            XCTAssertEqual(try MemoryRegeneration.inventory(wiki.root.appendingPathComponent(".cards")), cards)
        }.value
    }

    private func assertPromptConsumers(_ entries: [WikiFeedback.Entry]) async throws {
        let rendered = try XCTUnwrap(WikiFeedback.render(entries))
        let direction = try XCTUnwrap(f.outline.items[0].change.direction)
        let source = CatalogSeedPrompts.PageSource(path: f.sources[0], layer: "CC", name: "虚构原料", text: nil,
            title: "虚构航线", gist: "全虚构要点")
        let candidate = CatalogSeedPrompts.PageCandidate(path: "memory/cc/虚构候选.md", layer: "CC", name: "虚构候选", hits: ["云桥"])
        let opening = CatalogSeedPrompts.pageOpening(f.outline.items[0], outline: f.outline, sources: [source], existing: nil,
            candidates: [candidate], feedback: rendered)
        try ordered(opening, ["【这一项的原料】", rendered, "【回扫候选】", "写好调用 submit_proposal"])
        let selected = CatalogAgent.pageFeedback(direction, task: f.task, wiki: f.wiki, now: f.now)
        let expected = f.seed ? Set(entries.map(\.operationId)) : Set(entries.filter { $0.targetPath == f.path }.map(\.operationId))
        XCTAssertEqual(Set(selected.map(\.operationId)), expected)
        let seedRendered = try XCTUnwrap(WikiFeedback.render(selected))
        let key = CatalogAgent.pageKey(direction, task: f.task, feedback: selected)
        XCTAssertNotEqual(key, CatalogAgent.pageKey(direction, task: f.task))
        for entry in selected {
            XCTAssertTrue(key.contains(entry.operationId + "@" + WikiStore.version(of: Data(entry.reason.utf8)).prefix(12)))
        }
        let actual = try CatalogAgent.pageOpening(f.outline.items[0], outline: f.outline, task: f.task, wiki: f.wiki, feedback: selected).get()
        try ordered(actual.text, ["【这一项的原料】", seedRendered, "写好调用 submit_proposal"])
        let fragments = f.fragments.prefix(4).map { CatalogFragment(id: $0.id, content: $0.content, category: "fact", day: MemoryDay.key(f.now)) }
        let topic = CatalogSorter.Topic(path: f.path, title: "虚构云桥夜航", kind: .topic, existing: false,
            hook: "虚构钩子", reason: "虚构方向")
        let material = await CatalogWriter.material(topic, fragments: fragments, floorPrompt: "全虚构楼层", wiki: f.wiki,
            memoryRoot: f.floor.appendingPathComponent("memory"), now: f.now, embedder: CatalogFakeEmbedder.unavailable())
        let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
        let current = try await f.reload()
        let writerEntries = WikiFeedback.select(.init(targetPath: f.path, fragmentIds: Set(fragments.map(\.id))),
            proposals: [current], receipts: [], now: f.now)
        XCTAssertEqual(Set(writerEntries.map(\.operationId)), Set(entries.map(\.operationId)))
        let writerFeedback = try XCTUnwrap(WikiFeedback.render(writerEntries))
        XCTAssertEqual(material.feedback, writerFeedback)
        try ordered(CatalogWriter.userContent(material, names: names), ["【新主题】", "【定好的钩子】", "【为什么提这个方向】", writerFeedback, "【搜回来的原料】"])
        let job = CatalogAgent.Job(topic: "虚构云桥夜航", path: f.path, fragmentIds: fragments.map(\.id), profileId: f.pid,
            memoryRoot: f.floor.appendingPathComponent("memory"), names: names, floorPrompt: "全虚构楼层", snapshot: fragments,
            modelName: "fictional-no-model", feedback: rendered)
        try ordered(CatalogAgent.opening(job, rootIndex: "虚构索引", labels: material.labels), ["【主题】", rendered, "【楼层提示词】", "【wiki 根索引】"])
    }

    func testSeedFileLibraryAndAuditWindowsRejectStaleBaselines() async throws {
        try await prepare(seed: true)
        var saved = try await f.reject(f.proposal)
        let baseline = saved.items[0].change
        let entry = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: f.wiki).first { $0.kind == .page(proposalId: saved.id, itemId: saved.items[0].id) })
        let text = entry.content.replacingOccurrences(of: "虚构旧钩子", with: "文件库先存的虚构钩子")
        try await CatalogSeedDrafts.save(entry, text: text, baseline: entry.content, wiki: f.wiki, profileId: f.pid, context: f.context)
        saved = try await f.reload()
        XCTAssertEqual(saved.items[0].state, .pending)
        guard case .newPage(let reopenedPage) = saved.items[0].change else { return XCTFail() }
        XCTAssertEqual(reopenedPage.hook, "文件库先存的虚构钩子")
        do {
            _ = try await f.reopen(saved, baseline: baseline)
            XCTFail("审计台旧窗口必须拒存")
        } catch { XCTAssertTrue(error.localizedDescription.contains("这条已在别处回待批，关闭后重新打开"), error.localizedDescription) }
        _ = try await f.reload(saved)
        // 再驳回让状态仍合法，只由旧正文基线触发冲突。
        saved = try await f.reject(saved, onlyFirst: true)
        do {
            _ = try await f.reopen(saved, baseline: baseline)
            XCTFail("同为 rejected 的审计台旧基线必须拒存")
        } catch { XCTAssertTrue(error.localizedDescription.contains("这条在别处改过，重新打开再改"), error.localizedDescription) }
        _ = try await f.reload(saved)
        let staleEntry = try XCTUnwrap(CatalogSeedDrafts.entries(wiki: f.wiki).first { $0.kind == entry.kind })
        let result = try await f.reopen(saved)
        saved = try await f.reload(result.proposal)
        do {
            try await CatalogSeedDrafts.save(staleEntry, text: text, baseline: staleEntry.content, wiki: f.wiki, profileId: f.pid, context: f.context)
            XCTFail("文件库旧窗口必须拒存")
        } catch {
            XCTAssertEqual(error as? CatalogSeedDrafts.EditError, .conflict)
            XCTAssertTrue(error.localizedDescription.contains("这份草稿在别处改过了"))
        }
        _ = try await f.reload(saved)
        try f.assertMarks([f.ids[3]: f.now])
        let append = saved.items[1]
        let wiki = f.wiki, existing = f.existing, original = f.originalPage
        var page = WikiPage.parse(original, path: existing)
        page.now = "人工改过的虚构灯塔"
        try await WikiEditing.save(page.markdown, baseline: original, store: wiki, path: existing)
        do {
            _ = try await WikiProposalReview.reopen(saved.id, itemId: append.id, change: append.change, baseline: append.change,
                judgment: nil, store: f.store, profileId: f.pid, context: f.context)
            XCTFail("目标页已变不能重开")
        } catch { XCTAssertTrue(error.localizedDescription.contains("页面 / 原料在驳回后变过")) }
        _ = try await f.reload(saved)
        XCTAssertEqual(f.wiki.read(existing)?.now, page.now)
        try f.assertMarks([f.ids[3]: f.now])
    }

    private enum Failure: Error, Equatable { case marks, afterImage, restore, pageWrite }

    func testRejectMarkFailuresCompensateDiskAndFreshContextForBothOrigins() async throws {
        for seed in [false, true] {
            try await prepare(seed: seed)
            let initial = try await f.reload(f.proposal)
            for partialSave in [false, true] {
                do {
                    _ = try await f.reject(initial, onlyFirst: true, saveMarks: { context in
                        if partialSave { try context.save() }
                        throw Failure.marks
                    })
                    XCTFail("标记失败不能假报驳回成功")
                } catch Failure.marks { }
                _ = try await f.reload(initial)
                try f.assertMarks([:])
                try f.assertFailureLog("保存碎片标记")
            }
            try await f.cleanup()
            f = nil
        }
    }

    func testReopenMarkAndAfterImageFailuresRestoreRejectedPreimageForBothOrigins() async throws {
        for seed in [false, true] {
            try await prepare(seed: seed)
            let rejected = try await f.reject(f.proposal, onlyFirst: true)
            for partialSave in [false, true] {
                do {
                    _ = try await f.reopen(rejected, saveMarks: { context in
                        if partialSave { try context.save() }
                        throw Failure.marks
                    })
                    XCTFail("标记失败不能假报重开成功")
                } catch Failure.marks { }
                _ = try await f.reload(rejected)
                try f.assertMarks(Dictionary(uniqueKeysWithValues: f.ids.prefix(4).map { ($0, f.now) }))
                try f.assertFailureLog("保存碎片标记")
            }
            var failing = f.store
            failing.beforeSave = { p in
                if let record = p.items[0].reviewHistory?.last, record.kind == .reopened,
                   record.fragmentMarks.contains(where: { $0.afterOrganizeRejectedAt == nil }) { throw Failure.afterImage }
            }
            do {
                _ = try await f.reopen(rejected, store: failing)
                XCTFail("后像失败不能留下 pending")
            } catch Failure.afterImage { }
            _ = try await f.reload(rejected)
            try f.assertMarks(Dictionary(uniqueKeysWithValues: f.ids.prefix(4).map { ($0, f.now) }))
            try f.assertFailureLog("保存审核后像")
            try await f.cleanup()
            f = nil
        }
    }

    func testRejectAfterImageAndFailedProposalCompensationRemainVisibleForBothOrigins() async throws {
        for seed in [false, true] {
            try await prepare(seed: seed)
            let initial = try await f.reload(f.proposal), now = f.now
            for failRestore in [false, true] {
                var failing = f.store
                failing.beforeSave = { p in
                    if p.items[0].reviewHistory?.last?.fragmentMarks.contains(where: { $0.afterOrganizeRejectedAt == now }) == true {
                        throw Failure.afterImage
                    }
                    if failRestore && p.items[0].state == .pending { throw Failure.restore }
                }
                do {
                    _ = try await f.reject(initial, onlyFirst: true, store: failing)
                    XCTFail("审核后像保存失败必须可见")
                } catch {
                    if failRestore { XCTAssertTrue(error.localizedDescription.contains("补偿失败：提案：")) }
                    else { XCTAssertEqual(error as? Failure, .afterImage) }
                }
                let saved = try await f.reload()
                if failRestore {
                    XCTAssertEqual(saved.items.map(\.state), [.rejected, .pending])
                    XCTAssertEqual(saved.items[0].rejection?.at, now)
                    XCTAssertEqual(saved.items[0].reviewHistory?.map(\.kind), [.rejected])
                    XCTAssertEqual(saved.items[1], initial.items[1])
                    try f.assertMarks(Dictionary(uniqueKeysWithValues: f.ids.prefix(4).map { ($0, now) }))
                } else {
                    XCTAssertEqual(saved, initial)
                    try f.assertMarks([:])
                }
                try f.assertFailureLog("保存审核后像", compensation: failRestore)
            }
            try await f.cleanup()
            f = nil
        }
    }

    func testReopenedApprovalWriteFailurePreservesEditedPreimageForBothOrigins() async throws {
        for seed in [false, true] {
            try await prepare(seed: seed)
            let rejected = try await f.reject(f.proposal)
            let reopened = try await f.reopen(rejected)
            let againAt = f.now.addingTimeInterval(120)
            let again = try await f.reject(reopened.proposal, onlyFirst: true, at: againAt)
            var draft = WikiProposalDraft(again.items[0].change)
            draft.records[0].deleted = true
            draft.records[1].body = "本人手写的虚构航路说明"
            draft.records[1].converted = true
            let edited = try await f.reopen(again, change: draft.apply(to: again.items[0].change), conversions: draft.conversions)
            let pending = try await f.reload(edited.proposal)
            XCTAssertEqual(pending.items[0].reviewHistory?.map(\.kind), [.rejected, .reopened, .rejected, .handConverted, .reopened])
            XCTAssertEqual(edited.kept, [f.ids[3]])
            try f.assertMarks([f.ids[3]: againAt])
            let path = f.path
            for failCompensation in [false, true] {
                var faultyWiki = f.wiki
                faultyWiki.beforeWrite = { if $0 == path + ".md" { throw Failure.pageWrite } }
                var failing = WikiProposalStore(wiki: faultyWiki)
                if failCompensation {
                    failing.beforeSave = { p in
                        if p.items[0].approval == nil { throw Failure.restore }
                    }
                }
                do {
                    _ = try await WikiProposalReview.approve(pending.id, itemIds: [pending.items[0].id], store: failing,
                        profileId: f.pid, context: f.context, now: f.now.addingTimeInterval(180))
                    XCTFail("重开改稿后写页失败不能假报批准成功")
                } catch Failure.pageWrite { }
                let saved = try await f.reload()
                XCTAssertFalse(f.wiki.pageExists(path))
                XCTAssertEqual(saved.items.map(\.state), [.pending, .rejected])
                XCTAssertEqual(saved.items[0].change, pending.items[0].change)
                XCTAssertEqual(saved.items[0].reviewHistory, pending.items[0].reviewHistory)
                XCTAssertEqual(saved.items[1], pending.items[1])
                try f.assertMarks([f.ids[3]: againAt])
                if failCompensation {
                    let receipt = try XCTUnwrap(saved.items[0].approval)
                    // 写页前失败且清收据也失败：磁盘留 prepared，全前像由 reconcile 收口。
                    XCTAssertEqual(receipt.phase, .prepared)
                    XCTAssertNil(receipt.pages.first?.beforeVersion)
                    let mark = try XCTUnwrap(receipt.fragmentMarks.first { $0.fragmentId == f.ids[3] })
                    XCTAssertEqual(mark.organizeRejectedAt, againAt)
                    XCTAssertNil(mark.organizedAt)
                    XCTAssertNil(mark.organizedPage)
                    XCTAssertThrowsError(try WikiProposalReview.requireSettled(path, store: f.store)) { error in
                        XCTAssertTrue(error.localizedDescription.contains("未收口批准"), error.localizedDescription)
                    }
                    try await WikiProposalReview.reconcile(pending.id, itemId: pending.items[0].id, store: f.store,
                        profileId: f.pid, context: f.context, now: f.now.addingTimeInterval(240))
                }
                _ = try await f.reload(pending)
                XCTAssertFalse(f.wiki.pageExists(path))
                try f.assertMarks([f.ids[3]: againAt])
                XCTAssertNoThrow(try WikiProposalReview.requireSettled(path, store: f.store))
            }
            try await f.cleanup()
            f = nil
        }
    }

    private enum RaceOrder { case firstThenSecond, secondThenFirst }

    private func race(order: RaceOrder, _ first: @escaping () async throws -> Void,
                      _ second: @escaping () async throws -> Void) async throws {
        let wiki = f.wiki
        let key = await Task.detached { WikiProposalReview.lockKey(wiki) }.value
        let before = try await f.reload(), page = wiki.readRaw(f.existing)
        let markDates = Dictionary(uniqueKeysWithValues: f.fragments.compactMap { row in row.organizeRejectedAt.map { (row.id, $0) } })
        let gate = CatalogLock()
        await gate.acquire("hold")
        let entered = expectation(description: "holder owns review floor")
        let crossed = expectation(description: "neither review operation crosses holder")
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
            try await leading()
        }
        await waitForWaiters(1, key: key)
        let two = Task {
            defer { if holding { crossed.fulfill() } }
            try await trailing()
        }
        await waitForWaiters(2, key: key)
        await fulfillment(of: [crossed], timeout: 0.2)
        _ = try await f.reload(before)
        XCTAssertEqual(wiki.readRaw(f.existing), page)
        try f.assertMarks(markDates)
        await gate.release("hold")
        try await holder.value
        try await one.value
        try await two.value
    }

    private func waitForWaiters(_ count: Int, key: String) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while CatalogLock.waiterCount(key) != count && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(CatalogLock.waiterCount(key), count)
    }

    func testRejectThenManualSaveSerializeWithoutLosingPage() async throws { try await rejectRacesManual(order: .firstThenSecond) }
    func testManualSaveThenRejectSerializeWithoutLosingPage() async throws { try await rejectRacesManual(order: .secondThenFirst) }

    private func rejectRacesManual(order: RaceOrder) async throws {
        try await prepare(seed: false)
        let p = f.proposal!, wiki = f.wiki, path = f.existing, baseline = f.originalPage
        var page = WikiPage.parse(baseline, path: path)
        page.now = "人工保存的虚构灯火"
        let text = page.markdown
        try await race(order: order, {
            _ = try await WikiProposalReview.reject(p.id, itemIds: [p.items[1].id], reasons: [p.items[1].id: "虚构灯火不是现实"],
                store: self.f.store, profileId: self.f.pid, context: self.f.context, now: self.f.now)
        }, {
            try await WikiEditing.save(text, baseline: baseline, store: wiki, path: path)
        })
        let saved = try await f.reload()
        XCTAssertEqual(saved.items.map(\.state), [.pending, .rejected])
        XCTAssertEqual(saved.items[0], p.items[0])
        XCTAssertEqual(saved.items[1].rejection?.reason, "虚构灯火不是现实")
        XCTAssertEqual(wiki.readRaw(path), text)
        try f.assertMarks([f.ids[3]: f.now])
        do {
            let item = saved.items[1]
            _ = try await WikiProposalReview.reopen(saved.id, itemId: item.id, change: item.change, baseline: item.change,
                judgment: nil, store: f.store, profileId: f.pid, context: f.context)
            XCTFail("人工保存后旧页基线必须拒重开")
        } catch { XCTAssertTrue(error.localizedDescription.contains("页面 / 原料在驳回后变过")) }
        _ = try await f.reload(saved)
        try f.assertMarks([f.ids[3]: f.now])
    }

    func testReopenThenRejectSerializesSameItemTransitions() async throws { try await reopenRacesReject(order: .firstThenSecond) }
    func testRejectThenReopenSerializesSameItemTransitions() async throws { try await reopenRacesReject(order: .secondThenFirst) }

    private func reopenRacesReject(order: RaceOrder) async throws {
        try await prepare(seed: true)
        let rejected = try await f.reject(f.proposal, onlyFirst: true)
        let later = f.now.addingTimeInterval(120)
        try await race(order: order, {
            _ = try await self.f.reopen(rejected)
        }, {
            MemoryWriteLog.flush()
            let before = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: self.f.pid))
            let result = try await self.f.reject(rejected, onlyFirst: true, at: later)
            if order == .secondThenFirst {
                // 驳回无操作，然后重开成功。
                XCTAssertEqual(result, rejected)
                MemoryWriteLog.flush()
                XCTAssertEqual(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: self.f.pid)), before)
            }
        })
        let saved = try await f.reload()
        let reopenedFirst = order == .firstThenSecond
        XCTAssertEqual(saved.items[0].state, reopenedFirst ? .rejected : .pending)
        XCTAssertEqual(saved.items[0].reviewHistory?.map(\.kind), reopenedFirst ? [.rejected, .reopened, .rejected] : [.rejected, .reopened])
        XCTAssertEqual(saved.items[0].rejection?.at, reopenedFirst ? later : nil)
        XCTAssertEqual(saved.items[1], rejected.items[1])
        var marks = reopenedFirst ? Dictionary(uniqueKeysWithValues: f.ids.prefix(4).map { ($0, later) }) : [:]
        if !reopenedFirst { marks[f.ids[3]] = f.now }
        try f.assertMarks(marks)
    }
}
