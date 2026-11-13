import MemoryCore
import Darwin
import ObjectiveC
import SwiftData
import XCTest
@testable import 记忆花园

@MainActor
final class SeedLabTests: XCTestCase {
    private var scratchRoot: URL?

    override func tearDown() async throws {
        if let scratchRoot {
            try await Task.detached { try FileManager.default.removeItem(at: scratchRoot) }.value
        }
        scratchRoot = nil
    }

    func testSnapshotThroughRealSeedPipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["MP_SEEDLAB_SNAPSHOT"], !source.isEmpty else {
            throw XCTSkip("未设置 MP_SEEDLAB_SNAPSHOT，seedlab 不访问网络")
        }
        guard TestHostIsolation.active else { throw LabError.invalid("需要隔离的 mac XCTest 宿主") }
        guard let output = env["MP_SEEDLAB_OUT"], !output.isEmpty else { throw LabError.invalid("缺少 MP_SEEDLAB_OUT") }
        let stage = env["MP_SEEDLAB_STAGE"] ?? "outline"
        guard ["outline", "pages"].contains(stage) else { throw LabError.invalid("MP_SEEDLAB_STAGE 只能是 outline / pages") }
        let entryName = env["MP_SEEDLAB_ENTRY"] ?? "cc"
        guard ["cc", "persona"].contains(entryName), let entry = CatalogSeedEntry(rawValue: entryName) else {
            throw LabError.invalid("MP_SEEDLAB_ENTRY 只能是 cc / persona")
        }
        executionTimeAllowance = 600
        let started = Date()
        let clock = StageClock()
        let names = MemoryExtractor.Names(userName: env["MP_SEEDLAB_USER"] ?? "岚舟", assistantName: env["MP_SEEDLAB_CHAR"] ?? "星砚")
        let modelName = env["MP_SEEDLAB_MODEL"] ?? "claude-haiku-5-5"
        let taskId = UUID().uuidString
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("seedlab-\(UUID().uuidString)", isDirectory: true)
        scratchRoot = scratch
        let outRoot = URL(fileURLWithPath: output, isDirectory: true)
        let cardsPath = env["MP_SEEDLAB_CARDS"].flatMap { $0.isEmpty ? nil : $0 }
        let wikiPath = env["MP_SEEDLAB_WIKI"].flatMap { $0.isEmpty ? nil : $0 }
        let prepared = try await Task.detached {
            try Self.prepare(source: URL(fileURLWithPath: source, isDirectory: true), cards: cardsPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
                             baseline: wikiPath.map { URL(fileURLWithPath: $0, isDirectory: true) }, entry: entry, scratch: scratch, output: outRoot, taskId: taskId)
        }.value
        let relay = try await Task.detached { try Self.officialRelay() }.value
        SeedLabAuthProtocol.key = relay.key
        SeedLabAuthProtocol.host = URL(string: relay.url)?.host
        defer { SeedLabAuthProtocol.uninstall(); SeedLabAuthProtocol.key = nil; SeedLabAuthProtocol.host = nil }
        try SeedLabAuthProtocol.install()
        let id = "xctest-seedlab-\(UUID().uuidString)"
        let manager = ProviderManager()
        let model = ProviderModel(credentialId: id, modelId: modelName, name: modelName)
        manager.addCredential(APICredential(id: id, name: "Seedlab", emoji: "", type: .anthropic, baseURL: relay.url,
                                           extraHeaders: ["anthropic-version": "2023-06-01"], models: [model], toolsSupported: true))
        manager.setApiKey(SeedLabAuthProtocol.placeholder, for: id)
        defer { manager.removeCredential(id: id) }
        var cost = 0.0
        var costSamples = 0
        let deps = CatalogAgent.Deps(makeBackend: {
            AssistantCloudBackend(model: model, providerManager: manager, usage: UsageContext(kind: .catalogSeed, profileId: id))
        }, gate: { text in
            await CatalogBudget.globalGate(model: model, providerManager: manager, text: text)
        }, roundCost: { backend in
            let value = (backend as? AssistantCloudBackend)?.lastCostUSD
            if let value { cost += value; costSamples += 1 }
            return value
        })
        let wiki = prepared.wiki
        let run = CatalogRunRecord(wiki: wiki, topic: "seedlab", kind: "种子 · mac 原料快照实验", now: started)
        var task = CatalogSeedTask(id: taskId, profileId: id, entry: entry, modelName: modelName, modelKey: "remote:\(id)/\(modelName)", createdAt: started, run: run.link())
        task.materials = prepared.snapshot.materials
        task.read = prepared.snapshot.read
        task.carded = prepared.carded
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        let snapshot = prepared.snapshot
        try await Task.detached { [task] in try tasks.save(task) }.value
        let agent = CatalogAgent(deps: deps)
        let outcome = await agent.runSeed(.init(task: task, snapshot: snapshot, wiki: wiki, names: names, run: run, now: started, onStage: { clock.begin($0) }))
        let store = WikiProposalStore(wiki: wiki)
        let outline = await Task.detached { store.load(taskId) }.value
        var normal = stage == "outline" && outcome.stop == .outlineSubmitted
        if stage == "pages", outcome.stop == .outlineSubmitted, let outline {
            clock.begin("pages")
            let container = try ModelContainer(for: Memory.self, Conversation.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            try await WikiProposalReview.approve(outline.id, store: store, profileId: id, context: context)
            var job = CatalogJob(profileId: id, memoryRoot: wiki.root.deletingLastPathComponent(), container: container, names: names,
                                 floorPrompt: "", modelName: modelName, caller: { _, _ in nil }, agentDeps: deps)
            job.seedModel = task.modelKey ?? ""
            let report = await CatalogSession(job: job).resumeSeed(taskId)
            normal = report.failures.isEmpty && report.blocked == nil && !report.cancelled && report.skipped == nil
        }
        clock.finish()
        await run.flush()
        let finalTask = await Task.detached { tasks.load(taskId) }.value ?? outcome.task
        if stage == "pages" { normal = normal && finalTask.state == .complete }
        let costs: Double? = costSamples == 0 ? nil : cost
        let timings = clock.seconds
        let target = try await Task.detached {
            try Self.export(wiki: wiki, task: finalTask, outline: outline, names: names, prepared: prepared, output: outRoot,
                            started: started, model: modelName, stage: stage, cost: costs, timings: timings, normal: normal)
        }.value
        print("[seedlab] output=\(target.path)")
        print("[seedlab] requests=\(finalTask.rounds) outline=\(outline?.items.count ?? 0) cards=\(finalTask.carded?.count ?? 0)")
        XCTAssertTrue(normal, "seedlab 未到达指定阶段；诊断见输出的 task.json / .runs")
        XCTAssertTrue(outcome.persisted, "checkpoint 没存成")
    }

    func testPersonaSummaryMetricsUseDisjointThresholdsAndLiteralAliases() throws {
        let groups = [
            SeedNoteGroup(key: "星砚", display: "星砚", group: "人", paths: ["prompt/助手#01"],
                          aliases: ["阿砚", " 阿砚 ", "星砚", "ＡＹ", "ay"], sourceLayers: ["Prompt"]),
            SeedNoteGroup(key: "林栖", display: "林栖", group: "人", paths: ["CC/a", "CC/b", "CC/c"], aliases: ["林师傅"], sourceLayers: ["CC"]),
            SeedNoteGroup(key: "石芽", display: "石芽", group: "人", paths: ["CC/d"], sourceLayers: ["CC"]),
            SeedNoteGroup(key: "云桥", display: "云桥", group: "地点", paths: ["CC/e"], existingPage: "地点/云桥", sourceLayers: ["CC"]),
            SeedNoteGroup(key: "纸鸢", display: "纸鸢", group: "物", paths: ["prompt/场景#01"], sourceLayers: ["Prompt"]),
            SeedNoteGroup(key: "画笔", display: "画笔", group: "物", paths: ["prompt/场景#02", "CC/f", "CC/g"], sourceLayers: ["Prompt", "CC"]),
        ]
        let metrics = Self.entityMetrics(groups)
        XCTAssertEqual(metrics.qualified, 3)
        XCTAssertEqual(metrics.persona, 1)
        XCTAssertEqual(groups.filter { !CatalogSeedNotes.opensEntityPage($0) }.map(\.key), ["石芽", "纸鸢"])
        XCTAssertEqual(metrics.aliases.filter { $0.aliasCount > 0 }.count, 2)
        XCTAssertEqual(metrics.aliases.first { $0.id == "星砚" }?.aliases, ["ay", "阿砚"])
        XCTAssertEqual(metrics.aliases.first { $0.id == "石芽" }?.aliasCount, 0)
    }

    func testExistingWikiImportIsReadOnlySafeAndIncludedInSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seedlab-import-\(UUID().uuidString)", isDirectory: true)
        scratchRoot = root
        let fm = FileManager.default
        let source = root.appendingPathComponent("source", isDirectory: true)
        let text = "阿砚今天在旧码头修纸灯。"
        try CatalogSeedMaterials(items: [.init(path: "CC/a", name: "虚构", layer: "CC", text: text, version: WikiStore.version(of: Data(text.utf8)))]).snapshot(to: source)
        let baseline = WikiStore(root: root.appendingPathComponent("baseline", isDirectory: true))
        try fm.createDirectory(at: baseline.root.appendingPathComponent("人"), withIntermediateDirectories: true)
        let page = WikiPage(path: "人/星砚", triggers: ["阿砚"], title: "星砚", now: "岚舟的同行伙伴，详见人设。")
        let bytes = Data(page.markdown.utf8)
        let original = baseline.root.appendingPathComponent("人/星砚.md")
        try bytes.write(to: original)
        try Data("虚构隔离哨兵".utf8).write(to: baseline.root.appendingPathComponent("人/private_sentinel.md"))
        try fm.createSymbolicLink(at: baseline.root.appendingPathComponent("人/链接.md"), withDestinationURL: original)
        let prepared = try Self.prepare(source: source, cards: nil, baseline: baseline.root, entry: .cc,
                                        scratch: root.appendingPathComponent("scratch"), output: root.appendingPathComponent("out"), taskId: UUID().uuidString)
        let items = try prepared.snapshot.items()
        XCTAssertEqual(prepared.wiki.read("人/星砚")?.triggers, ["阿砚"])
        XCTAssertEqual(items.first { $0.path == CatalogSeedMaterials.wikiPath("人/星砚") }?.text, page.markdown)
        XCTAssertFalse(items.contains { $0.path.contains("private_") || $0.path.contains("链接") })
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: baseline.root.path), ["人"])
        let manifest = try Data(contentsOf: prepared.snapshot.folder.appendingPathComponent(CatalogSeedMaterials.manifestFileName))
        XCTAssertEqual(prepared.manifestSHA256, WikiStore.version(of: manifest))
        XCTAssertNotEqual(prepared.manifestSHA256, WikiStore.version(of: try Data(contentsOf: source.appendingPathComponent(CatalogSeedMaterials.manifestFileName))))
    }


    func testCoverageUsesFormalSourcesAndDeduplicatesCards() {
        let pages = [
            Page(path: "主题/雨天写生", title: "雨天写生", group: "主题", sourceCount: 1, sources: ["CC/a"]),
            Page(path: "主题/云桥地图", title: "云桥地图", group: "主题", sourceCount: 1, sources: ["CC/a"]),
        ]
        let result = Self.coverage(cardPaths: ["CC/a", "CC/a", "CC/candidate"], pages: pages, records: nil)
        XCTAssertEqual(result.basis, "outline.sources")
        XCTAssertEqual(result.cardCount, 2)
        XCTAssertEqual(result.coveredCardCount, 1)
        XCTAssertEqual(result.ratio, 0.5)
        XCTAssertEqual(result.cards.first?.pages, ["主题/云桥地图", "主题/雨天写生"])
        XCTAssertEqual(result.uncoveredPaths, ["CC/candidate"])
        XCTAssertEqual(Self.coverage(cardPaths: [], pages: [], records: nil).ratio, 1)
    }

    func testPagesCoverageReadsRecordsNotOutlineOrTextMentions() {
        let pages = [Page(path: "主题/雨天写生", title: "雨天写生", group: "主题", sourceCount: 3, sources: ["CC/a", "CC/ab", "CC/c"])]
        let result = Self.coverage(cardPaths: ["CC/a", "CC/ab", "CC/c"], pages: pages,
                                   records: ["主题/雨天写生": ["2026-10-25 · 岚舟写生（CC/ab）", "正文提到 CC/a", "2026-10-25 · 不完整（CC/c）尾注"]])
        XCTAssertEqual(result.basis, "pages.proposal.records+baseline")
        XCTAssertEqual(result.coveredCardCount, 1)
        XCTAssertEqual(result.uncoveredPaths, ["CC/a", "CC/c"])
        XCTAssertEqual(Self.coverage(cardPaths: ["CC/a"], pages: pages, records: [:]).coveredCardCount, 0)
        XCTAssertEqual(Self.coverage(cardPaths: ["CC/岚舟（修订）"], pages: pages,
                                     records: ["主题/雨天写生": ["未注明 · 修订稿（CC/岚舟（修订））"]]).coveredCardCount, 1)
    }

    func testProposalRenderingMergesBaselineWithoutApproving() {
        let path = "主题/雨天写生"
        let oldLine = "2026-10-24 · 岚舟的画纸（CC/a）"
        let newLine = "2026-10-25 · 星砚的遮雨棚（CC/b）"
        let newPage = WikiPage(path: "地点/云桥城", title: "云桥城", records: ["未注明 · 旧码头（CC/c）"])
        let proposal = WikiProposal(origin: .seed, createdAt: Date(timeIntervalSince1970: 0), items: [
            .init(change: .appendRecords(path: path, lines: [newLine])),
            .init(change: .newPage(page: newPage)),
            .init(state: .rejected, change: .appendRecords(path: path, lines: ["未注明 · 不收（CC/d）"])),
        ])
        let baseline = [path: WikiPage(path: path, title: "雨天写生", records: [oldLine])]
        let rendered = Self.proposalPages(baseline: baseline, proposals: [proposal])
        XCTAssertEqual(rendered[path]?.records, [oldLine, newLine])
        XCTAssertEqual(rendered[newPage.path]?.records, newPage.records)
        XCTAssertEqual(baseline[path]?.records, [oldLine])
        XCTAssertEqual(proposal.items.map(\.state), [.pending, .pending, .rejected])
        let pages = rendered.values.map { Page(path: $0.path, title: $0.title, group: "", sourceCount: 0, sources: []) }
        XCTAssertEqual(Self.coverage(cardPaths: ["CC/a", "CC/b", "CC/c"], pages: pages, records: rendered.mapValues(\.records)).ratio, 1)
    }

    func testShapeReportsBoundariesMedianAndNamingSignalsWithoutRejecting() {
        let pages = zip([4, 5, 15, 16], ["雨", "Cloud城", "沟通", "云桥城的旧码头"]).enumerated().map { index, pair in
            Page(path: "主题/页\(index)", title: pair.1, group: "主题", sourceCount: pair.0, sources: ["CC/\(index)"])
        } + [Page(path: "主题/待归类", title: "还没归类的", group: "主题", sourceCount: 1, sources: ["CC/loose"])]
        let result = Self.shape(pages: pages, cardPaths: ["CC/0", "CC/loose", "CC/missing"])
        XCTAssertEqual(result.pageCount, 5)
        XCTAssertEqual(result.cardDistribution, ["<=4": 2, "5-15": 2, ">15": 1])
        XCTAssertEqual(result.medianCardCount, 5)
        XCTAssertEqual(result.maximumCardCount, 16)
        XCTAssertEqual(result.oversizedPages.map(\.path), ["主题/页3"])
        XCTAssertEqual(result.largestPages.map(\.path), ["主题/页3"])
        XCTAssertEqual(result.unclassifiedCardCount, 1)
        XCTAssertEqual(result.pageNames.english, 1)
        XCTAssertEqual(result.pageNames.singleCharacter, 1)
        XCTAssertEqual(result.pageNames.abstractWord, 1)
        XCTAssertEqual(Self.shape(pages: Array(pages.prefix(2)), cardPaths: []).medianCardCount, 4.5)
        XCTAssertEqual(Self.shape(pages: [], cardPaths: []).medianCardCount, 0)
    }

    func testUnclassifiedCountIncludesCardsAlsoOnEntityPagesAndDeduplicatesPools() {
        let pages = [
            Page(path: "人/星砚", title: "星砚", group: "人", sourceCount: 1, sources: ["CC/shared"]),
            Page(path: "{{user}}/待归类", title: "还没归类的", group: "{{user}}", sourceCount: 2, sources: ["CC/shared", "CC/loose"]),
            Page(path: "主题/待归类", title: "还没归类的", group: "主题", sourceCount: 2, sources: ["CC/loose", "CC/not-a-card"]),
        ]
        let result = Self.shape(pages: pages, cardPaths: ["CC/shared", "CC/loose", "CC/loose", "CC/missing"])
        XCTAssertEqual(result.unclassifiedCardCount, 2, "同时落实体页的卡仍在待归类池；跨池重复只计一次，未覆盖卡和非卡来源不计")
    }

    func testDomainExportUsesFrozenContextsDistinctCardsAndActualPendingRecords() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("seedlab-domains-\(UUID().uuidString)")
        scratchRoot = scratch
        let wiki = WikiStore(root: scratch.appendingPathComponent("wiki"))
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        let context = SeedSourceContext(slotPath: "prompt/剧场", slotName: "云桥城设定", headingPath: ["城邦背景"])
        let declared: [SeedFactDomain?] = [.realWorld, .inWorld, .mixed, .unspecified, nil, .realWorld, .realWorld]
        let materials = CatalogSeedMaterials(items: declared.indices.map { index in
            let text = "虚构原料 \(index)"
            return .init(path: "prompt/剧场#\(index)", name: "云桥片段 \(index)", layer: "Prompt",
                         text: text, version: WikiStore.version(of: Data(text.utf8)), sourceContext: context)
        })
        let taskId = UUID().uuidString
        let snapshot = try tasks.writeSnapshot(materials, id: taskId)
        var task = CatalogSeedTask(id: taskId, profileId: "fictional", entry: .persona, modelName: "offline",
                                   createdAt: Date(timeIntervalSince1970: 1_798_000_000), run: .init(path: "fixture"))
        task.materials = snapshot.materials + [snapshot.materials[0]]
        task.read = snapshot.read
        task.carded = snapshot.read
        try tasks.save(task)
        let cards = zip(materials.items, declared).enumerated().map { index, pair in
            SeedNoteCard(path: pair.0.path, version: pair.0.version, name: pair.0.name, layer: pair.0.layer,
                         title: "云桥卡 \(index)", gist: "虚构事实 \(index)", mentions: [.init(name: "纸舟", group: "物")],
                         aboutUser: false, group: "主题", when: [], model: "offline", madeAt: task.createdAt, run: task.run,
                         sourceContext: index == 6 ? nil : index == 5 ? .init(slotPath: "prompt/别槽", slotName: "别槽", headingPath: []) : context,
                         factDomain: pair.1)
        }
        for card in cards { try SeedNoteStore(wiki: wiki).save(card) }
        let pageSpecs: [(String, SeedFactDomain?, [Int])] = [
            ("主题/现实", .realWorld, [0, 1, 2]), ("主题/设定", .inWorld, [1]),
            ("主题/混合", .mixed, [2]), ("主题/待判", .unspecified, [3, 4, 5, 6]), ("主题/旧页", nil, [])
        ]
        let directions = pageSpecs.map { path, domain, indices in
            WikiProposal.Direction(path: path, title: String(path.split(separator: "/").last!), kind: .topic, action: .newPage,
                                   reason: "虚构目录", mode: .seed, sources: indices.map { cards[$0].path },
                                   candidates: [.init(path: cards[3].path, hits: ["纸舟"])], factDomain: domain)
        }
        let outline = WikiProposal(id: task.id, origin: .seed, createdAt: task.createdAt,
                                   items: directions.map { .init(change: .direction($0)) })
        try WikiProposalStore(wiki: wiki).save(outline)
        let pageItems = directions.enumerated().map { index, direction in
            let indices = index == 0 ? [0, 1, 3] : pageSpecs[index].2
            return WikiProposal.Item(change: .newPage(page: WikiPage(path: direction.path, title: direction.title,
                records: indices.map { "未注明 · 虚构记录（\(cards[$0].path)）" }, factDomain: direction.factDomain)))
        }
        var proposal = WikiProposal(origin: .seed, createdAt: task.createdAt, items: pageItems)
        proposal.seedTask = task.id
        try WikiProposalStore(wiki: wiki).save(proposal)
        let output = scratch.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let prepared = Prepared(wiki: wiki, snapshot: snapshot, carded: [:], manifestSHA256: "fictional")
        for stage in ["outline", "pages"] {
            let target = try Self.export(wiki: wiki, task: task, outline: outline, names: CatalogTestKit.names, prepared: prepared,
                                         output: output, started: task.createdAt, model: "offline", stage: stage, cost: nil, timings: [:], normal: true)
            let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target.appendingPathComponent("summary.json"))) as? [String: Any])
            let domains = try XCTUnwrap(summary["factDomains"] as? [String: Any])
            XCTAssertEqual(summary["cardCount"] as? Int, 7)
            XCTAssertEqual(summary["success"] as? Bool, true, "域统计不新增成功门槛")
            XCTAssertEqual(domains["cards"] as? [String: Int], ["realWorld": 1, "inWorld": 1, "mixed": 1, "unspecified": 4])
            XCTAssertEqual(domains["pages"] as? [String: Int], ["realWorld": 1, "inWorld": 1, "mixed": 1, "unspecified": 1, "nil": 1])
            for (key, count) in [("legacyNilCount", 1), ("contextIssueCount", 2), ("contextMissingCount", 1),
                                 ("contextConflictCount", 1), ("pendingPool", 5), ("theatrePool", 1), ("uncoveredCardCount", 0)] {
                XCTAssertEqual(domains[key] as? Int, count, key)
            }
            let relations = try XCTUnwrap(domains["incompatibleRelations"] as? [[String: String]])
            XCTAssertEqual(domains["incompatibleRelationCount"] as? Int, 2)
            XCTAssertEqual(relations, [1, stage == "outline" ? 2 : 3].map { ["path": cards[$0].path, "page": "主题/现实"] })
            let thresholds = try XCTUnwrap(summary["thresholds"] as? [String: Any])
            XCTAssertEqual(thresholds["loosePool"] as? Int, 1)
            XCTAssertEqual(thresholds["movedToLoose"] as? Int, 1)
            XCTAssertEqual(thresholds["theatrePool"] as? Int, 1)
            XCTAssertEqual(thresholds["pendingPool"] as? Int, 5)
        }
    }

    func testOfflineExportEncodesSplitRecoveryClusterCorrectionsAndPageCoverage() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("harden-seedlab-\(UUID().uuidString)", isDirectory: true)
        scratchRoot = scratch
        let wiki = WikiStore(root: scratch.appendingPathComponent("wiki"))
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        let started = Date(timeIntervalSince1970: 1_798_000_000)
        let run = CatalogRunRecord(wiki: wiki, topic: "offline", kind: "虚构聚类导出", now: started)
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: "xctest-offline-seedlab", entry: .cc,
                                   modelName: "fake", modelKey: "remote:fake/fake", createdAt: started, run: run.link())
        let own = (1...6).map { "memory/cc/own_\($0).md" }
        let loose = (1...3).map { "memory/cc/kite_\($0).md" }
        let materials = CatalogSeedMaterials(items: (own + loose).enumerated().map { index, path in
            let text = "虚构原料\(index)：云桥的纸风筝与写生本。"
            return .init(path: path, name: "虚构片段\(index)", layer: "CC", text: text, version: WikiStore.version(of: Data(text.utf8)))
        })
        let snapshot = try tasks.writeSnapshot(materials, id: task.id)
        task.materials = snapshot.materials
        task.read = snapshot.read
        try tasks.save(task)
        let model = SeedModel()
        model.wiki = wiki
        model.notesReply = { n, kind, _ in kind == "cards" && n <= 2 ? .finished("不是 JSON") : nil }
        for (index, path) in (own + loose).enumerated() {
            model.cards[path] = ["title": "卡片标题\(index)", "gist": "云桥第\(index)份虚构见闻",
                                 "about_user": own.contains(path), "mentions": [], "group": "主题"]
        }
        model.userPages = [("卡片标题0", "主题/写生", Array(own.prefix(3)))]
        // 跨数组但前缀已经正确：必须仍计归位，不能混进同数组改前缀。
        model.topics = [("画具整理", "{{user}}/画具", Array(own.suffix(3))),
                        ("卡片标题6", "主题/风筝", loose)]
        let agent = CatalogAgent(deps: .init(makeBackend: { model.backend }, gate: { _ in nil }))
        let outcome = await agent.runSeed(.init(task: task, snapshot: snapshot, wiki: wiki, names: CatalogTestKit.names, run: run, now: started))
        XCTAssertEqual(outcome.stop, .outlineSubmitted)
        XCTAssertTrue(outcome.persisted)
        let store = WikiProposalStore(wiki: wiki)
        let outline = try XCTUnwrap(store.load(task.id))
        let directions = outline.items.compactMap(\.change.direction)
        XCTAssertEqual(Set(directions.map(\.path)), ["{{user}}/写生", "{{user}}/画具", "主题/风筝"])
        let pageItems = directions.map { direction in
            WikiProposal.Item(change: .newPage(page: WikiPage(path: direction.path, title: direction.title,
                records: (direction.sources ?? []).map { "未注明 · 云桥的虚构见闻（\($0)）" })))
        }
        var proposal = WikiProposal(origin: .seed, createdAt: started, items: pageItems)
        proposal.seedTask = task.id
        try store.save(proposal)
        let output = scratch.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifest = try Data(contentsOf: snapshot.folder.appendingPathComponent(CatalogSeedMaterials.manifestFileName))
        let prepared = Prepared(wiki: wiki, snapshot: snapshot, carded: [:], manifestSHA256: WikiStore.version(of: manifest))
        let target = try Self.export(wiki: wiki, task: outcome.task, outline: outline, names: CatalogTestKit.names, prepared: prepared,
                                     output: output, started: started, model: "fake", stage: "pages", cost: nil, timings: [:], normal: true)
        let bytes = try Data(contentsOf: target.appendingPathComponent("summary.json"))
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(summary["schemaVersion"] as? Int, 2)
        XCTAssertEqual(summary["prefixCorrections"] as? Int, 1)
        XCTAssertEqual(summary["poolReassignments"] as? Int, 1)
        XCTAssertEqual(summary["titleFallbacks"] as? Int, 2)
        XCTAssertEqual(summary["success"] as? Bool, true)
        XCTAssertEqual(summary["droppedClusters"] as? [String], [])
        let split = try XCTUnwrap(summary["splitBatches"] as? [String: Int])
        XCTAssertEqual(split, ["count": 1, "recovered": 9])
        XCTAssertEqual(summary["requestCount"] as? Int, model.backend.requests.count)
        let coverage = try XCTUnwrap(summary["recordCoverage"] as? [String: Any])
        XCTAssertEqual(coverage["cardCount"] as? Int, 9)
        XCTAssertEqual(coverage["coveredCardCount"] as? Int, 9)
        XCTAssertEqual(coverage["uncoveredPaths"] as? [String], [])
        let domains = try XCTUnwrap(summary["factDomains"] as? [String: Any])
        let domainCards = try XCTUnwrap(domains["cards"] as? [String: Int])
        XCTAssertEqual(domainCards.values.reduce(0, +), summary["cardCount"] as? Int)
        XCTAssertEqual(domains["cardCount"] as? Int, 9)
        XCTAssertEqual(domainCards, ["realWorld": 9, "inWorld": 0, "mixed": 0, "unspecified": 0])
        let thresholds = try XCTUnwrap(summary["thresholds"] as? [String: Any])
        XCTAssertEqual(thresholds["theatrePool"] as? Int, 0)
        XCTAssertEqual(thresholds["pendingPool"] as? Int, 0)
        let expected = ["{{user}}/写生": ("写生", Array(own.prefix(3))),
                        "{{user}}/画具": ("画具整理", Array(own.suffix(3))), "主题/风筝": ("风筝", loose)]
        for (path, value) in expected {
            let direction = try XCTUnwrap(directions.first { $0.path == path })
            XCTAssertEqual(direction.title, value.0)
            XCTAssertEqual(Set(direction.sources ?? []), Set(value.1))
            let markdown = try String(contentsOf: target.appendingPathComponent("proposal-pages/\(path).md"), encoding: .utf8)
            XCTAssertTrue(markdown.contains(value.0))
            XCTAssertFalse(markdown.contains("卡片标题"))
            for source in value.1 { XCTAssertTrue(markdown.contains("（\(source)）")) }
        }
    }

    private enum LabError: Error { case invalid(String) }
    private struct Relay: Decodable, Sendable { var name: String; var url: String; var key: String }

    private nonisolated static func officialRelay() throws -> Relay {
        guard let user = getpwuid(getuid()) else { throw LabError.invalid("找不到真实家目录") }
        let home = URL(fileURLWithPath: String(cString: user.pointee.pw_dir), isDirectory: true)
        let url = home.appendingPathComponent(".mp-test-keys/relays.json")
        let rows = try JSONDecoder().decode([Relay].self, from: Data(contentsOf: url))
        guard let relay = rows.first(where: { $0.name == "anthropic-official" }), !relay.key.isEmpty,
              let endpoint = URL(string: relay.url), endpoint.scheme == "https", endpoint.host == "api.anthropic.com" else {
            throw LabError.invalid("缺少 anthropic-official 官方凭据（不使用其他 key）")
        }
        return relay
    }

    private struct Prepared: Sendable {
        var wiki: WikiStore
        var snapshot: CatalogSeedMaterials.Snapshot
        var carded: [String: String]
        var manifestSHA256: String
    }

    private nonisolated static func prepare(source: URL, cards: URL?, baseline: URL? = nil, entry: CatalogSeedEntry = .cc,
                                           scratch: URL, output: URL, taskId: String) throws -> Prepared {
        let fm = FileManager.default
        var ancestor = output.resolvingSymlinksInPath().standardizedFileURL
        while ancestor.path != "/" {
            if fm.fileExists(atPath: ancestor.appendingPathComponent(".git").path) { throw LabError.invalid("输出必须在仓库外") }
            ancestor.deleteLastPathComponent()
        }
        guard (try SafeWiki.itemType(source)) == .typeDirectory else { throw LabError.invalid("快照必须是真实文件夹") }
        let manifest = source.appendingPathComponent(CatalogSeedMaterials.manifestFileName)
        guard SafeWiki.isPlainFile(manifest) else { throw CatalogSeedMaterials.SnapshotError.missingManifest }
        // 只读清单再过滤；private_* 的正文和缓存从未打开，也不拷进临时 wiki。
        let manifestBytes = try Data(contentsOf: manifest)
        let entries = try JSONDecoder().decode([CatalogSeedMaterials.Snapshot.Entry].self, from: manifestBytes).filter {
            !$0.path.split(separator: "/").contains(where: { $0.hasPrefix("private_") }) && !$0.file.hasPrefix("private_")
        }
        let selected = CatalogSeedMaterials.Snapshot(folder: source, entries: entries)
        var materials = CatalogSeedMaterials(items: try selected.items())
        if let baseline {
            guard !baseline.pathComponents.contains(where: { $0.lowercased().hasPrefix("private_") }),
                  try SafeWiki.itemType(baseline) == .typeDirectory else { throw LabError.invalid("已有 wiki 必须是真实公开目录") }
            let inputWiki = WikiStore(root: baseline)
            var imported = CatalogSeedMaterials()
            imported.addWiki(inputWiki, memoryRoot: baseline.deletingLastPathComponent())
            guard imported.skipped.isEmpty else { throw LabError.invalid(imported.skipped.joined(separator: "；")) }
            // 显式 --wiki 是本轮唯一已有页基线；替换快照自带 wiki，其他原料不变。
            materials.items.removeAll { $0.layer == "wiki" }
            materials.items.append(contentsOf: imported.items)
        }
        let wiki = WikiStore(root: scratch.appendingPathComponent("wiki", isDirectory: true))
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        _ = try tasks.writeSnapshot(materials, id: taskId)
        let snapshot = try tasks.loadSnapshot(taskId)
        try fm.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        // 已有页基线保留原始字节与版本，不经 save 重新序列化。
        for item in materials.items where item.layer == "wiki" {
            let relative: String
            if let page = CatalogSeedMaterials.pagePath(item.path) { relative = page + ".md" }
            else if let folder = CatalogSeedMaterials.indexFolder(item.path) { relative = (folder.isEmpty ? "" : folder + "/") + WikiStore.indexFileName }
            else { continue }
            let target = wiki.root.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(item.text.utf8).write(to: target, options: .atomic)
        }
        var carded: [String: String] = [:]
        if let cards {
            guard (try SafeWiki.itemType(cards)) == .typeDirectory else { throw LabError.invalid("cards 必须是真实文件夹") }
            let store = SeedNoteStore(wiki: wiki)
            try fm.createDirectory(at: store.folder, withIntermediateDirectories: true)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            for item in materials.items where SeedNoteBatcher.cardable(layer: item.layer, entry: entry) {
                let entry = item
                let filename = SeedNoteStore.key(path: entry.path, version: entry.version) + ".json"
                let original = cards.appendingPathComponent(filename)
                guard SafeWiki.isPlainFile(original) else { continue }
                let bytes = try Data(contentsOf: original)
                guard let card = try? decoder.decode(SeedNoteCard.self, from: bytes), card.path == entry.path, card.version == entry.version else { continue }
                try bytes.write(to: store.url(path: entry.path, version: entry.version), options: .atomic)
                carded[entry.path] = entry.version
            }
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let effectiveManifest = try Data(contentsOf: snapshot.folder.appendingPathComponent(CatalogSeedMaterials.manifestFileName))
        return Prepared(wiki: wiki, snapshot: snapshot, carded: carded, manifestSHA256: WikiStore.version(of: baseline == nil ? manifestBytes : effectiveManifest))
    }

    private struct Page: Encodable {
        var path: String; var title: String; var group: String; var sourceCount: Int; var sources: [String]
    }
    private struct NameSignals: Encodable {
        var english: Int; var singleCharacter: Int; var abstractWord: Int
        var heuristic = "英文=含 ASCII 字母；单字=去空白后仅一字；抽象词候选=恰好两个汉字（结构启发式，会把人名/地名计入，只报不判，无关键词表）"
    }
    private struct Shape: Encodable {
        var pageCount: Int; var medianCardCount: Double; var maximumCardCount: Int
        var largestPages: [Page]; var unclassifiedCardCount: Int
        var cardDistribution: [String: Int]; var oversizedPages: [Page]; var pageNames: NameSignals
    }
    private struct CardCoverage: Encodable {
        var path: String; var pages: [String]
    }
    private struct RecordCoverage: Encodable {
        var basis: String; var cardCount: Int; var coveredCardCount: Int; var ratio: Double
        var uncoveredPaths: [String]; var cards: [CardCoverage]
    }
    private struct Unplaced: Encodable { var path: String; var name: String; var title: String; var gist: String }
    private struct Below: Encodable { var name: String; var group: String; var sourceCount: Int }
    private struct Thresholds: Encodable {
        var entities: Int; var alignedEntities: Int; var opened: Int; var belowThreshold: Int
        var movedToLoose: Int; var userPool: Int; var loosePool: Int
        var theatrePool: Int; var pendingPool: Int; var below: [Below]
        var sourceQualified: Int; var personaDirectOpened: Int
        var aliasEntityCount: Int; var entityAliases: [EntityAliases]
    }
    private struct EntityAliases: Encodable {
        var id: String; var name: String; var group: String; var aliasCount: Int; var aliases: [String]
    }
    private struct SplitBatches: Encodable { var count: Int; var recovered: Int }
    private struct DomainRelation: Encodable, Equatable { var path: String; var page: String }
    private struct FactDomains: Encodable {
        var basis: String; var cardCount: Int; var cards: [String: Int]; var pages: [String: Int]
        var legacyNilCount: Int; var contextIssueCount: Int; var contextMissingCount: Int; var contextConflictCount: Int
        var theatrePool: Int; var pendingPool: Int
        var incompatibleRelationCount: Int; var incompatibleRelations: [DomainRelation]; var uncoveredCardCount: Int
    }
    private struct Summary: Encodable {
        var schemaVersion = 2
        var startedAt: String; var model: String; var stage: String; var taskId: String; var success: Bool
        var entry: String
        var manifestSHA256: String
        var materialCount: Int; var cardCount: Int; var reusedCardCount: Int
        var outlineCount: Int; var groupCounts: [String: Int]; var sourceDistribution: [String: Int]
        var outline: [Page]; var unplaced: [Unplaced]; var thresholds: Thresholds; var thinPages: [Page]
        var droppedClusters: [String]; var requestCount: Int; var costUSD: Double?; var timingsSeconds: [String: Double]
        var shape: Shape; var prefixCorrections: Int; var poolReassignments: Int; var titleFallbacks: Int; var recordCoverage: RecordCoverage
        var splitBatches: SplitBatches
        var factDomains: FactDomains?
    }

    /// 三类互斥：已有页或份数足够 / 人设层直开（人）/ 不够；别名仅作字面归一去重。
    private nonisolated static func entityMetrics(_ entities: [SeedNoteGroup]) -> (qualified: Int, persona: Int, aliases: [EntityAliases]) {
        let qualified = entities.filter { $0.existingPage != nil || Set($0.paths).count >= CatalogSettings.seedEntityPageMinSources }.count
        let persona = entities.filter {
            $0.existingPage == nil && Set($0.paths).count < CatalogSettings.seedEntityPageMinSources && CatalogSeedNotes.opensEntityPage($0)
        }.count
        let aliases = entities.map { entity in
            let own = CatalogSeedNotes.normalize(entity.display)
            let names = Array(Set(entity.aliases.map(CatalogSeedNotes.normalize).filter { !$0.isEmpty && $0 != own })).sorted()
            return EntityAliases(id: entity.key, name: entity.display, group: entity.group, aliasCount: names.count, aliases: names)
        }.sorted { $0.id < $1.id }
        return (qualified, persona, aliases)
    }

    /// 来源按路径去重；一张卡可合理地出现在多页，不把跨页重复算成漏卡。
    private nonisolated static func coverage(cardPaths: [String], pages: [Page], records: [String: [String]]?) -> RecordCoverage {
        let cards = Set(cardPaths).sorted().map { path in
            CardCoverage(path: path, pages: pages.filter { page in
                if let records {
                    // 完整行末出处匹配，也容纳 path 自身带全角括号。
                    return (records[page.path] ?? []).contains {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("（\(path)）")
                    }
                }
                return page.sources.contains(path)
            }.map(\.path).sorted())
        }
        let missing = cards.filter { $0.pages.isEmpty }.map(\.path)
        return RecordCoverage(basis: records == nil ? "outline.sources" : "pages.proposal.records+baseline",
                              cardCount: cards.count, coveredCardCount: cards.count - missing.count,
                              ratio: cards.isEmpty ? 1 : Double(cards.count - missing.count) / Double(cards.count),
                              uncoveredPaths: missing, cards: cards)
    }

    private nonisolated static func factDomains(cards: [SeedNoteCard], directions: [WikiProposal.Direction],
                                                records: [String: [String]]?, recordCoverage: RecordCoverage) -> FactDomains {
        let unique = Dictionary(cards.map { (SeedNoteStore.key(path: $0.path, version: $0.version), $0) }, uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(unique.values.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let knownPaths = Set(byPath.keys).union(directions.flatMap { $0.sources ?? [] })
        var cardCounts = ["realWorld": 0, "inWorld": 0, "mixed": 0, "unspecified": 0]
        var pageCounts = ["realWorld": 0, "inWorld": 0, "mixed": 0, "unspecified": 0, "nil": 0]
        for card in unique.values { cardCounts[card.effectiveFactDomain?.rawValue ?? "unspecified", default: 0] += 1 }
        var incompatible: [DomainRelation] = []
        for direction in directions {
            pageCounts[direction.factDomain?.rawValue ?? "nil", default: 0] += 1
            let paths: Set<String>
            if let records {
                paths = Set(knownPaths.filter { path in
                    (records[direction.path] ?? []).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("（\(path)）") }
                })
            } else {
                paths = Set(direction.sources ?? [])
            }
            for path in paths.sorted() where !CatalogSeedDrafts.accepts(sourceDomain: byPath[path]?.effectiveFactDomain, pageDomain: direction.factDomain) {
                incompatible.append(DomainRelation(path: path, page: direction.path))
            }
        }
        return FactDomains(basis: "卡按 path|version 去重；effectiveFactDomain（nil 计 unspecified）；页按目录项 factDomain；正式 source→page 关系（\(records == nil ? "outline.sources" : "pages.pending.records")），候选不计；未覆盖沿 recordCoverage；旧目录 nil 未声明域，不推断不兼容",
                           cardCount: unique.count, cards: cardCounts, pages: pageCounts, legacyNilCount: unique.values.filter { $0.factDomain == nil }.count,
                           contextIssueCount: unique.values.filter { $0.sourceContextIssue != nil }.count,
                           contextMissingCount: unique.values.filter { $0.sourceContextIssue == .missing }.count,
                           contextConflictCount: unique.values.filter { $0.sourceContextIssue == .conflict }.count,
                           theatrePool: unique.values.filter { $0.effectiveFactDomain == .inWorld }.count,
                           pendingPool: unique.values.filter { $0.effectiveFactDomain != .realWorld && $0.effectiveFactDomain != .inWorld }.count,
                           incompatibleRelationCount: incompatible.count, incompatibleRelations: incompatible.sorted { ($0.path, $0.page) < ($1.path, $1.page) },
                           uncoveredCardCount: recordCoverage.uncoveredPaths.count)
    }

    private nonisolated static func shape(pages: [Page], cardPaths: [String]) -> Shape {
        let preferred = CatalogSettings.seedClusterPagePreferredSources
        let counts = pages.map(\.sourceCount).sorted()
        let middle = counts.count / 2
        let median = counts.isEmpty ? 0 : counts.count.isMultiple(of: 2)
            ? Double(counts[middle - 1] + counts[middle]) / 2 : Double(counts[middle])
        let maximum = counts.last ?? 0
        let titles = pages.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        let names = NameSignals(english: titles.filter { $0.range(of: "[A-Za-z]", options: .regularExpression) != nil }.count,
                                singleCharacter: titles.filter { $0.count == 1 }.count,
                                abstractWord: titles.filter { $0.range(of: #"^\p{Han}{2}$"#, options: .regularExpression) != nil }.count)
        let unclassified = Set(pages.filter { $0.path.hasSuffix("/待归类") }.flatMap(\.sources))
        return Shape(pageCount: pages.count, medianCardCount: median, maximumCardCount: maximum,
                     largestPages: pages.filter { $0.sourceCount == maximum },
                     unclassifiedCardCount: unclassified.intersection(cardPaths).count,
                     cardDistribution: ["<=4": counts.filter { $0 < preferred.lowerBound }.count,
                                        "5-15": counts.filter { preferred.contains($0) }.count,
                                        ">15": counts.filter { $0 > preferred.upperBound }.count],
                     oversizedPages: pages.filter { $0.sourceCount > preferred.upperBound }, pageNames: names)
    }

    /// 只在内存里渲染待批正文，绝不调用 approve/save；更新页从真实基线合入。
    private nonisolated static func proposalPages(baseline: [String: WikiPage], proposals: [WikiProposal]) -> [String: WikiPage] {
        var pages = baseline
        for proposal in proposals.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            for item in proposal.items where item.state == .pending {
                switch item.change {
                case .newPage(let page): pages[page.path] = page
                case .appendRecords(let path, let lines): pages[path]?.records.append(contentsOf: lines)
                case .rewriteNow(let path, _, let new, let until):
                    pages[path]?.now = new
                    pages[path]?.validUntil = until
                case .retag(let path, _, let hook, _, let triggers):
                    pages[path]?.hook = hook
                    pages[path]?.triggers = triggers
                case .link(let path, let link): pages[path]?.links.append(link)
                default: break
                }
            }
        }
        return pages
    }

    private nonisolated static func export(wiki: WikiStore, task: CatalogSeedTask, outline: WikiProposal?, names: MemoryExtractor.Names, prepared: Prepared,
                                           output: URL, started: Date, model: String, stage: String, cost: Double?, timings: [String: Double], normal: Bool) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        let target = output.appendingPathComponent(formatter.string(from: started) + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        for folder in [".runs", ".cards"] {
            let source = wiki.root.appendingPathComponent(folder)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: target.appendingPathComponent(folder)) }
        }
        // JSON / notes / checkpoint 原样拷贝；不导出原料全文。
        for file in try fm.contentsOfDirectory(at: tasks.folder(task.id), includingPropertiesForKeys: nil) where file.lastPathComponent != CatalogSeedMaterials.snapshotFolderName {
            try fm.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
        }
        var rendered: [String: WikiPage] = [:]
        var pendingRecords: [String: [String]] = [:]
        if stage == "pages" {
            let baseline = Dictionary(wiki.pagePaths().compactMap { path in wiki.read(path).map { (path, $0) } }, uniquingKeysWith: { first, _ in first })
            let proposals = WikiProposalStore(wiki: wiki).list().filter { $0.seedTask == task.id && $0.id != task.id }
            for proposal in proposals {
                for item in proposal.items where item.state == .pending {
                    switch item.change {
                    case .newPage(let page): pendingRecords[page.path, default: []] += page.records
                    case .appendRecords(let path, let lines): pendingRecords[path, default: []] += lines
                    default: break
                    }
                }
            }
            rendered = proposalPages(baseline: baseline, proposals: proposals)
            let folder = target.appendingPathComponent("proposal-pages", isDirectory: true)
            for (path, page) in rendered {
                let dest = folder.appendingPathComponent(path + ".md")
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(page.markdown.utf8).write(to: dest, options: .atomic)
            }
        }
        let cardStore = SeedNoteStore(wiki: wiki)
        var seenCards = Set<String>()
        let cards = task.cardable.compactMap { material -> SeedNoteCard? in
            guard seenCards.insert(SeedNoteStore.key(path: material.path, version: material.version)).inserted,
                  var card = cardStore.load(path: material.path, version: material.version) else { return nil }
            card.sourceContextIssue = card.contextIssue(for: material.sourceContext)
            return card
        }
        let agg = CatalogSeedNotes.aggregate(cards: cards, names: names)
        let alignment = tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: task.id) ?? SeedNoteAlignment(groups: agg.entities)
        let clusters = tasks.loadNotes(SeedNoteClusters.self, name: CatalogSeedTaskStore.clusteredFileName, id: task.id) ?? SeedNoteClusters()
        let below = alignment.groups.filter { !CatalogSeedNotes.opensEntityPage($0) }
        let user = Set(agg.userPaths).union(alignment.userPaths)
        let entity = Set(alignment.groups.filter(CatalogSeedNotes.opensEntityPage).flatMap(\.paths))
        let excluded = Set(agg.theatrePaths + agg.pendingPaths)
        let loose = cards.filter { !user.contains($0.path) && !entity.contains($0.path) && !excluded.contains($0.path) }
        let belowPaths = Set(below.flatMap(\.paths))
        let pages = (outline?.items ?? []).compactMap { item -> Page? in
            guard let d = item.change.direction else { return nil }
            let sources = Array(Set(d.sources ?? [])).sorted()
            return Page(path: d.path, title: d.title, group: String(d.path.split(separator: "/").first ?? ""), sourceCount: sources.count, sources: sources)
        }
        let placed = Set(pages.flatMap(\.sources))
        var groups: [String: Int] = [:]
        var distribution = ["1": 0, "2": 0, "3": 0, ">=4": 0]
        for page in pages {
            groups[page.group, default: 0] += 1
            distribution[page.sourceCount >= 4 ? ">=4" : String(page.sourceCount), default: 0] += 1
        }
        let recordCoverage = coverage(cardPaths: cards.map(\.path), pages: pages, records: stage == "pages" ? rendered.mapValues(\.records) : nil)
        let metrics = entityMetrics(alignment.groups)
        let summary = Summary(startedAt: ISO8601DateFormatter().string(from: started), model: model, stage: stage, taskId: task.id, success: normal && recordCoverage.uncoveredPaths.isEmpty,
                              entry: task.entry.rawValue, manifestSHA256: prepared.manifestSHA256,
                              materialCount: task.materials.count, cardCount: cards.count, reusedCardCount: prepared.carded.count,
                              outlineCount: pages.count, groupCounts: groups, sourceDistribution: distribution, outline: pages,
                              unplaced: cards.filter { !placed.contains($0.path) }.map { Unplaced(path: $0.path, name: $0.name, title: $0.title, gist: $0.gist) },
                              thresholds: Thresholds(entities: agg.entities.count, alignedEntities: alignment.groups.count, opened: alignment.groups.count - below.count, belowThreshold: below.count,
                                                     movedToLoose: loose.filter { belowPaths.contains($0.path) }.count, userPool: cards.filter { user.contains($0.path) }.count, loosePool: loose.count,
                                                     theatrePool: agg.theatrePaths.count, pendingPool: agg.pendingPaths.count,
                                                     below: below.map { Below(name: $0.display, group: $0.group, sourceCount: Set($0.paths).count) },
                                                     sourceQualified: metrics.qualified, personaDirectOpened: metrics.persona,
                                                     aliasEntityCount: metrics.aliases.filter { $0.aliasCount > 0 }.count, entityAliases: metrics.aliases),
                              thinPages: pages.filter { $0.sourceCount < CatalogSettings.seedClusterPageMinSources }, droppedClusters: clusters.dropped, requestCount: task.rounds, costUSD: cost, timingsSeconds: timings,
                              shape: shape(pages: pages, cardPaths: cards.map(\.path)), prefixCorrections: clusters.normalizedPrefixCount,
                              poolReassignments: clusters.reassignedPoolCount, titleFallbacks: clusters.copiedTitleCount, recordCoverage: recordCoverage,
                              splitBatches: SplitBatches(count: task.notes?.splitBatches?.count ?? 0,
                                                        recovered: task.notes?.splitBatches?.reduce(0) { $0 + $1.recovered } ?? 0),
                              factDomains: factDomains(cards: cards, directions: (outline?.items ?? []).compactMap(\.change.direction),
                                                       records: stage == "pages" ? pendingRecords : nil, recordCoverage: recordCoverage))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary).write(to: target.appendingPathComponent("summary.json"), options: .atomic)
        XCTAssertEqual(summary.recordCoverage.uncoveredPaths, [], "每张卡必须由正式 sources / 实际正文记录覆盖；诊断见 summary.recordCoverage")
        return target
    }
}

@MainActor
private final class StageClock {
    private var last = ProcessInfo.processInfo.systemUptime
    private let start = ProcessInfo.processInfo.systemUptime
    private var current = "prepare"
    private(set) var seconds: [String: Double] = [:]
    func begin(_ stage: String) {
        let now = ProcessInfo.processInfo.systemUptime
        seconds[current, default: 0] += now - last
        current = stage
        last = now
    }
    func finish() {
        begin("finished")
        seconds["total"] = last - start
        for stage in ["cards", "aggregate", "align", "backfill", "cluster", "outline", "pages"] where seconds[stage] == nil { seconds[stage] = 0 }
    }
}

// 只在网络出口换鉴权；ProviderManager / 钥匙串 / .runs 永远只见占位符。
final class SeedLabAuthProtocol: URLProtocol, URLSessionDataDelegate {
    static let placeholder = "seedlab-runtime-key"
    nonisolated(unsafe) static var key: String?
    nonisolated(unsafe) static var host: String?
    nonisolated(unsafe) private static var factories: [(Method, Method)] = []
    nonisolated(unsafe) static var nonStreamingSession: URLSession?

    static func install() throws {
        guard let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.default)),
              let replacement = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.seedLabDefault)),
              let shared = class_getClassMethod(URLSession.self, #selector(getter: URLSession.shared)),
              let sharedReplacement = class_getClassMethod(URLSession.self, #selector(URLSession.seedLabShared)) else {
            throw URLError(.unsupportedURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeedLabAuthProtocol.self]
        nonStreamingSession = URLSession(configuration: configuration)
        factories = [(original, replacement), (shared, sharedReplacement)]
        for pair in factories { method_exchangeImplementations(pair.0, pair.1) }
    }
    static func uninstall() {
        for pair in factories.reversed() { method_exchangeImplementations(pair.0, pair.1) }
        factories = []
        nonStreamingSession?.invalidateAndCancel()
        nonStreamingSession = nil
    }
    private var session: URLSession?
    private var forwardingTask: URLSessionDataTask?
    private var rejected = false
    private var errorBytes = Data()
    static func redacted(_ text: String) -> String {
        guard let key, !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "[REDACTED]")
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host && (request.value(forHTTPHeaderField: "x-api-key") == placeholder || request.value(forHTTPHeaderField: "Authorization") == "Bearer " + placeholder)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let key = Self.key else { client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired)); return }
        var outgoing = request
        if let stream = outgoing.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(buffer, count: count)
            }
            outgoing.httpBodyStream = nil
            outgoing.httpBody = bytes
        }
        if outgoing.value(forHTTPHeaderField: "x-api-key") != nil { outgoing.setValue(key, forHTTPHeaderField: "x-api-key") }
        if outgoing.value(forHTTPHeaderField: "Authorization") != nil { outgoing.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        forwardingTask = session.dataTask(with: outgoing)
        forwardingTask?.resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        rejected = (response as? HTTPURLResponse).map { $0.statusCode >= 400 } ?? false
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if rejected { errorBytes.append(data) } else { client?.urlProtocol(self, didLoad: data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !errorBytes.isEmpty { client?.urlProtocol(self, didLoad: Data(Self.redacted(String(decoding: errorBytes, as: UTF8.self)).utf8)) }
        if let error { client?.urlProtocol(self, didFailWithError: error) } else { client?.urlProtocolDidFinishLoading(self) }
        session.finishTasksAndInvalidate()
        forwardingTask = nil
        self.session = nil
    }
    override func stopLoading() { forwardingTask?.cancel(); session?.invalidateAndCancel() }
}

private extension URLSessionConfiguration {
    @objc dynamic class func seedLabDefault() -> URLSessionConfiguration {
        let configuration = seedLabDefault()
        configuration.protocolClasses = [SeedLabAuthProtocol.self] + (configuration.protocolClasses ?? [])
        return configuration
    }
}
private extension URLSession {
    @objc dynamic class func seedLabShared() -> URLSession {
        guard let session = SeedLabAuthProtocol.nonStreamingSession else { preconditionFailure("seedlab 鉴权会话未安装") }
        return session
    }
}
