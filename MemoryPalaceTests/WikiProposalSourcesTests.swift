import MemoryCore
import XCTest
@testable import 记忆花园

/// 整理提案目录项的原料（粟粟 10-23「看每个原料是啥」）：一份一行 + 全文，private_ 永远读不到（含 wiki 私人页和索引）
final class WikiProposalSourcesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(CCMemorySync.subdir, isDirectory: true), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let ccDir = root.appendingPathComponent(CCMemorySync.subdir)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: ccDir.path)) ?? [] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ccDir.appendingPathComponent(name).path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private var wiki: WikiStore { WikiStore(root: root.appendingPathComponent("wiki", isDirectory: true)) }

    private func cc(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(CCMemorySync.subdir).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func task() -> CatalogSeedTask {
        CatalogSeedTask(id: UUID().uuidString, profileId: "p", entry: .cc, modelName: "", createdAt: Date(), run: .init(path: ".runs/x.md"))
    }

    /// 把这几份原料写成任务的快照（同 `CatalogRunner`：清单、版本从快照来；已经填了的清单 / 版本照留）
    private func snapshot(_ t: inout CatalogSeedTask, _ items: [(path: String, text: String)]) throws {
        var m = CatalogSeedMaterials()
        for (path, text) in items {
            let existing = t.materials.first { $0.path == path }
            m.items.append(.init(path: path, name: existing?.name ?? (path as NSString).lastPathComponent, layer: existing?.layer ?? WikiProposalSources.guessLayer(path),
                                 text: text, version: existing?.version ?? WikiStore.version(of: Data(text.utf8)),
                                 sourceContext: existing?.sourceContext))
        }
        let folder = CatalogSeedTaskStore(wiki: wiki).materialsFolder(t.id)
        try? FileManager.default.removeItem(at: folder)
        let written = try m.snapshot(to: folder)
        if t.materials.isEmpty { t.materials = written.materials }
        for (p, v) in written.read where t.read[p] == nil { t.read[p] = v }
    }

    private func current(_ paths: [String], task: CatalogSeedTask? = nil, floorBase: CatalogFloorBase? = nil) -> [String: WikiProposalSources.Current] {
        WikiProposalSources.current(paths: paths, layers: WikiProposalSources.layers(paths, task: task), task: task,
                                    floorBase: floorBase, memoryRoot: root, wiki: wiki)
    }

    private func one(_ path: String, task: CatalogSeedTask?, receipts: [String: String] = [:]) -> WikiProposalSources.Source? {
        WikiProposalSources.seed(paths: [path], task: task, receipts: receipts, current: current([path], task: task), wiki: wiki).first
    }

    private func card(path: String, version: String, context: SeedSourceContext?, domain: SeedFactDomain?) throws {
        try SeedNoteStore(wiki: wiki).save(SeedNoteCard(path: path, version: version, name: "云桥城", layer: "Prompt",
            title: "夜航", gist: "设定中的航线", mentions: [], aboutUser: false, group: "主题", when: [],
            model: "fictional", madeAt: Date(timeIntervalSince1970: 1_000), run: .init(path: ".runs/fictional.md"),
            sourceContext: context, factDomain: domain))
    }

    func testAuditKeepsFrozenSourceAndDomainSeparateFromCurrentChangeNote() throws {
        var t = task()
        let path = "prompt/人设#01"
        let context = SeedSourceContext(slotPath: "prompt/人设", slotName: "人设", headingPath: ["云桥城", "航线"])
        t.materials = [.init(path: path, name: "夜航", layer: "Prompt", version: "frozen", sourceContext: context)]
        try card(path: path, version: "frozen", context: context, domain: .inWorld)
        try card(path: path, version: "new", context: context, domain: .realWorld)
        let source = try XCTUnwrap(WikiProposalSources.seed(paths: [path], task: t, receipts: [path: "冻结正文"],
            current: [path: .present(text: "当前正文", version: "new")], wiki: wiki).first)
        XCTAssertEqual(source.sourceContext, context)
        XCTAssertEqual(source.factDomain, .inWorld)
        XCTAssertEqual(source.domainNote, "模型判断")
        XCTAssertEqual(source.text, "冻结正文")
        let block = try XCTUnwrap(WikiProposalItemDocument.document(title: "夜航", fields: [], sources: [source]).blocks.first)
        XCTAssertEqual(block.name, "夜航 · Prompt · 域：设定")
        XCTAssertEqual(block.summary, WikiProposalSources.changedNote)
        XCTAssertEqual(block.note, WikiProposalSources.changedNote)
        var unchanged = source
        unchanged.note = nil
        let unchangedBlock = try XCTUnwrap(WikiProposalItemDocument.document(title: "夜航", fields: [], sources: [unchanged]).blocks.first)
        XCTAssertEqual(unchangedBlock.summary, "快照来源：人设 › 云桥城 › 航线 · 模型判断")
    }

    func testAuditMissingLegacyAndContextIssueDomainsStayUnknownOrPending() throws {
        let frozen = SeedSourceContext(slotPath: "prompt/人设", slotName: "人设", headingPath: ["云桥城"])
        let other = SeedSourceContext(slotPath: "prompt/人设", slotName: "人设", headingPath: ["星砚"])
        let cases: [(String, Bool, SeedSourceContext?, SeedFactDomain?, String)] = [
            ("missing-card", false, nil, nil, "旧格式未记录"),
            ("legacy-card", true, frozen, nil, "旧格式未记录"),
            ("missing-context", true, nil, .realWorld, "上下文缺失，本轮按待判"),
            ("conflicting-context", true, other, .inWorld, "上下文冲突，本轮按待判"),
        ]
        for (version, hasCard, context, declared, note) in cases {
            var t = task()
            let path = "prompt/人设#01"
            t.materials = [.init(path: path, name: "夜航", layer: "Prompt", version: version, sourceContext: frozen)]
            if hasCard { try card(path: path, version: version, context: context, domain: declared) }
            let source = try XCTUnwrap(WikiProposalSources.seed(paths: [path], task: t,
                receipts: [path: "冻结正文"], current: [:], wiki: wiki).first)
            XCTAssertEqual(source.sourceContext, frozen)
            XCTAssertEqual(source.domainNote, note)
            XCTAssertEqual(source.factDomain, declared == nil ? nil : .unspecified)
            let block = try XCTUnwrap(WikiProposalItemDocument.document(title: "夜航", fields: [], sources: [source]).blocks.first)
            XCTAssertEqual(block.name, "夜航 · Prompt · 域：" + (declared == nil ? "未记录" : "待判"))
            XCTAssertEqual(block.summary, "快照来源：人设 › 云桥城 · \(note)")
        }
    }

    func testAuditDomainNoteDistinguishesMissingTaskUncardedLayerAndLegacyCard() throws {
        let path = "prompt/人设#01", wikiPath = CatalogSeedMaterials.wikiPath("主题/云桥城")
        let t = task()
        let missingTask = try XCTUnwrap(WikiProposalSources.seed(paths: [path], task: nil, receipts: [path: "冻结正文"],
            current: [:], wiki: wiki).first)
        let uncarded = try XCTUnwrap(WikiProposalSources.seed(paths: [wikiPath], task: t, receipts: [wikiPath: "冻结页"],
            current: [:], wiki: wiki).first)
        let legacy = try XCTUnwrap(WikiProposalSources.seed(paths: [path], task: t, receipts: [path: "冻结正文"],
            current: [:], wiki: wiki).first)
        XCTAssertEqual(missingTask.domainNote, "任务快照不在")
        XCTAssertEqual(uncarded.domainNote, "无要点卡")
        XCTAssertEqual(legacy.domainNote, "旧格式未记录")
    }

    func testAuditMixedDomainUsesPageDomainLabel() throws {
        var t = task()
        let path = "prompt/人设#01"
        let context = SeedSourceContext(slotPath: "prompt/人设", slotName: "人设", headingPath: ["云桥城"])
        t.materials = [.init(path: path, name: "夜航", layer: "Prompt", version: "frozen", sourceContext: context)]
        try card(path: path, version: "frozen", context: context, domain: .mixed)
        let sources = WikiProposalSources.seed(paths: [path], task: t, receipts: [path: "冻结正文"], current: [:], wiki: wiki)
        let block = try XCTUnwrap(WikiProposalItemDocument.document(title: "夜航", fields: [], sources: sources).blocks.first)
        XCTAssertEqual(block.name, "夜航 · Prompt · 域：混合待判")
    }

    func testCandidateAuditUsesDeclaredDomainAndRemainsSeparateFromFormalSources() throws {
        var t = task()
        let formal = "prompt/人设#01", candidate = "prompt/人设#02"
        let context = SeedSourceContext(slotPath: "prompt/人设", slotName: "人设", headingPath: ["云桥城"])
        t.materials = [formal, candidate].map { .init(path: $0, name: $0, layer: "Prompt", version: "frozen", sourceContext: context) }
        try snapshot(&t, [(formal, "正式原料"), (candidate, "候选原料")])
        try CatalogSeedTaskStore(wiki: wiki).save(t)
        try card(path: formal, version: "frozen", context: context, domain: .realWorld)
        try card(path: candidate, version: "frozen", context: context, domain: .inWorld)
        let direction = WikiProposal.Direction(path: "主题/云桥城", title: "云桥城", action: .newPage, reason: "",
            mode: .seed, sources: [formal], candidates: [.init(path: candidate, hits: ["云桥城"], factDomain: .realWorld)],
            factDomain: .mixed)
        let target = WikiProposalItemTarget(proposalId: "fictional", item: .init(change: .direction(direction)), seedTask: t.id, fragments: [])
        let blocks = WikiProposalItemDocument.build(target, wiki: wiki, floorBase: nil).blocks
        XCTAssertEqual(blocks.map(\.text), ["正式原料", "候选原料"])
        XCTAssertTrue(blocks[0].name.contains("域：现实"))
        XCTAssertFalse(blocks[0].name.contains("回扫候选"))
        XCTAssertTrue(blocks[1].name.contains("域：现实"))
        XCTAssertTrue(blocks[1].name.contains("回扫候选"))
        XCTAssertEqual(WikiProposalItemDocument.fields(target.item).first { $0.0 == "页域" }?.1, "混合待判")
    }

    // MARK: - private_（CC）

    /// private_ 开头（大小写不论）的 CC 文件：不取现状；就算任务清单 / 回执里伪造了，这个入口也不列、不取正文
    func testPrivateCCFilesAreNeverListedOrRead() throws {
        try cc("ok.md", "# 好的\n正文 A")
        try cc("private_secret.md", "# 机密\n不能看的内容")
        try cc("PRIVATE_upper.md", "# 机密二\n不能看的内容")
        let secret = "memory/cc/private_secret.md", upper = "memory/cc/PRIVATE_upper.md", ok = "memory/cc/ok.md"
        let now = current([secret, upper, ok])
        XCTAssertEqual(Set(now.keys), [ok], "私人文件连现状都不取")
        XCTAssertEqual(WikiProposalSources.cc(secret, memoryRoot: root), .missing, "直接问也不读")

        var t = task()
        t.materials = [.init(path: secret, name: "机密", layer: "CC", version: "v")]
        t.read = [secret: "v"]
        try snapshot(&t, [(secret, "不能看的内容")])
        let out = WikiProposalSources.seed(paths: [secret, upper, ok], task: t, receipts: WikiProposalSources.receipts(t, wiki: wiki), current: now, wiki: wiki)
        XCTAssertEqual(out.map(\.path), [ok], "private_ 不列")
        XCTAssertFalse(out.contains { ($0.text ?? "").contains("不能看的内容") || $0.name.contains("机密") })

        let doc = WikiProposalItemDocument.document(title: "t", fields: [], sources: out)
        XCTAssertFalse(doc.blocks.contains { $0.text.contains("不能看的内容") || $0.name.contains("机密") }, "页面上也看不到")
        XCTAssertTrue(WikiProposalSources.isPrivate("memory/cc/Private_x.md"))
        XCTAssertTrue(WikiProposalSources.isPrivate("memory/wiki/主题/private_box/甲.md"), "路径上任何一段是私人的都算")
        XCTAssertFalse(WikiProposalSources.isPrivate("memory/cc/not_private.md"))
    }

    // MARK: - private_（wiki：种子原料链本身）

    private func seedWikiWithPrivatePages() throws {
        _ = try wiki.save(WikiPage(path: "人/阿青", hook: "聊到阿青", title: "阿青", now: "公开的内容"))
        _ = try wiki.save(WikiPage(path: "人/private_secret", hook: "秘密钩子", title: "机密标题", now: "私人正文"))
        _ = try wiki.save(WikiPage(path: "人/Private_Upper", hook: "秘密钩子二", title: "机密标题二", now: "私人正文二"))
        _ = try wiki.save(WikiPage(path: "主题/private_box/甲", hook: "秘密钩子三", title: "机密标题三", now: "私人正文三"))
    }

    /// astra 10-23 P1：SafeWiki 在打开文件、生成索引之前就跳过私人页和私人文件夹——种子 gather 和详情页都受这条保护
    func testSafeWikiSkipsPrivatePagesBeforeReadingAndIndexing() throws {
        try seedWikiWithPrivatePages()
        let safe = SafeWiki.scan(wiki, memoryRoot: root)
        XCTAssertEqual(safe.pages.map(\.path), ["人/阿青"])
        XCTAssertFalse(safe.folders.contains { $0.lowercased().contains("private_") })
        let indexes = [""] + safe.folders
        for folder in indexes {
            let text = safe.index(folder)
            for leak in ["private_", "Private_", "机密", "秘密钩子"] {
                XCTAssertFalse(text.contains(leak), "索引「\(folder)」带出了私人页：\(text)")
            }
        }
        let gathered = try CatalogSeedMaterials.gather(floorBase: nil, memoryRoot: root, wiki: wiki)
        XCTAssertFalse(gathered.items.contains { $0.path.lowercased().contains("private_") || $0.text.contains("私人正文") || $0.text.contains("机密") },
                       "种子原料链本身也不带私人页")

        let indexPath = CatalogSeedMaterials.indexPath("人")
        guard case .present(let text, _)? = current([indexPath])[indexPath] else { return XCTFail("索引现状应该在") }
        XCTAssertTrue(text.contains("阿青"))
        XCTAssertFalse(text.contains("机密") || text.contains("private_"))
        XCTAssertEqual(WikiProposalSources.wikiPage(CatalogSeedMaterials.wikiPath("人/阿青"), wiki: wiki, memoryRoot: root),
                       .present(text: try XCTUnwrap(safe.pages.first?.text), version: try XCTUnwrap(safe.pages.first?.version)),
                       "单页现状和种子收集同一个版本")
    }

    /// 历史 INDEX 回执里指向私人页的行剥掉（修之前生成的回执可能带着）
    func testHistoricIndexReceiptDropsPrivateLines() throws {
        try seedWikiWithPrivatePages()
        let indexPath = CatalogSeedMaterials.indexPath("人")
        var t = task()
        t.materials = [.init(path: indexPath, name: "wiki 索引 · 人", layer: "wiki", version: "旧")]
        t.read = [indexPath: "旧"]
        try snapshot(&t, [(indexPath, "# 人\n\n- [[人/阿青]] 阿青 — 聊到阿青\n- [[人/private_secret]] 机密标题 — 秘密钩子\n- [[人/PRIVATE_x]] 机密二\n")])
        let s = try XCTUnwrap(one(indexPath, task: t, receipts: WikiProposalSources.receipts(t, wiki: wiki)))
        let text = try XCTUnwrap(s.text)
        XCTAssertTrue(text.contains("阿青"))
        XCTAssertFalse(text.contains("机密") || text.contains("秘密钩子") || text.lowercased().contains("private_"), text)
        XCTAssertEqual(WikiProposalSources.strippingPrivateLinks("普通一行\n[[a/private_b]] x\n[[a/b]] y"), "普通一行\n[[a/b]] y")
    }

    // MARK: - 现状四态（astra 10-23 P2）

    private func readTask(_ path: String, receiptText: String, version: String = "旧版本") throws -> CatalogSeedTask {
        var t = task()
        t.materials = [.init(path: path, name: "好的", layer: "CC", version: version)]
        t.read = [path: version]
        try snapshot(&t, [(path, receiptText)])
        return t
    }

    /// 先取提案生成时读到的那一份（快照）；现状版本不一样标「改过」，一样不标
    func testSnapshotWinsAndChangeIsFlagged() throws {
        try cc("ok.md", "# 好的\n正文 新")
        let path = "memory/cc/ok.md"
        guard case .present(_, let version)? = current([path])[path] else { return XCTFail() }
        var t = try readTask(path, receiptText: "类型：未标注\n标题：好的\n\n正文 旧")
        let changed = try XCTUnwrap(one(path, task: t, receipts: WikiProposalSources.receipts(t, wiki: wiki)))
        XCTAssertEqual(changed.text, "类型：未标注\n标题：好的\n\n正文 旧", "给她看的是提案读到的那一版")
        XCTAssertEqual(changed.note, WikiProposalSources.changedNote)
        XCTAssertEqual(changed.layer, "CC")

        t.read = [path: version]
        XCTAssertNil(one(path, task: t, receipts: WikiProposalSources.receipts(t, wiki: wiki))?.note, "版本一样不标")
    }

    /// 清空了 = 内容变了（不是「不在了」）
    func testEmptiedFileIsChangedNotGone() throws {
        try cc("ok.md", "   \n")
        let path = "memory/cc/ok.md"
        XCTAssertEqual(current([path])[path], .empty)
        let t = try readTask(path, receiptText: "当时的正文")
        let s = try XCTUnwrap(one(path, task: t, receipts: WikiProposalSources.receipts(t, wiki: wiki)))
        XCTAssertEqual(s.text, "当时的正文")
        XCTAssertEqual(s.note, WikiProposalSources.emptiedNote)
    }

    /// 只有真的不存在才标「不在了」；没快照也没现状写「没读到」
    func testMissingIsGone() throws {
        let path = "memory/cc/gone.md"
        XCTAssertEqual(current([path])[path], .missing)
        let t = try readTask(path, receiptText: "当时的正文")
        XCTAssertEqual(one(path, task: t, receipts: WikiProposalSources.receipts(t, wiki: wiki))?.note, WikiProposalSources.goneNote)
        let none = try XCTUnwrap(one(path, task: nil))
        XCTAssertNil(none.text)
        XCTAssertEqual(none.note, WikiProposalSources.missingNote)
    }

    /// 读失败（没权限 / 是链接）另标「现在读不了」
    func testUnreadableIsNotGone() throws {
        try cc("ok.md", "# 好的\n正文")
        try cc("locked.md", "# 锁\n正文")
        let ccDir = root.appendingPathComponent(CCMemorySync.subdir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ccDir.appendingPathComponent("locked.md").path)
        try FileManager.default.createSymbolicLink(at: ccDir.appendingPathComponent("link.md"), withDestinationURL: ccDir.appendingPathComponent("ok.md"))
        for name in ["locked.md", "link.md"] {
            let path = "memory/cc/" + name
            guard case .unreadable? = current([path])[path] else { return XCTFail("\(name) 应是读不了：\(String(describing: current([path])[path]))") }
            let t = try readTask(path, receiptText: "当时的正文")
            let s = try XCTUnwrap(one(path, task: t, receipts: WikiProposalSources.receipts(t, wiki: wiki)))
            XCTAssertEqual(s.text, "当时的正文")
            XCTAssertTrue(s.note?.hasPrefix("这份原料现在读不了") == true, s.note ?? "")
        }
    }

    /// wiki 页：路径上有链接 = 读不了；页不在 = 不在
    func testWikiPageStates() throws {
        _ = try wiki.save(WikiPage(path: "人/阿青", hook: "", title: "阿青", now: "内容"))
        let real = wiki.root.appendingPathComponent("人")
        try FileManager.default.createSymbolicLink(at: wiki.root.appendingPathComponent("人/链"), withDestinationURL: real)
        XCTAssertEqual(WikiProposalSources.wikiPage(CatalogSeedMaterials.wikiPath("人/没有"), wiki: wiki, memoryRoot: root), .missing)
        guard case .unreadable = WikiProposalSources.wikiPage(CatalogSeedMaterials.wikiPath("人/链/阿青"), wiki: wiki, memoryRoot: root) else {
            return XCTFail("经过链接的页不读")
        }
    }

    /// 没接 Prompt 底图：Prompt 原料现状未知，不乱标
    func testPromptWithoutFloorBaseIsNotFlagged() throws {
        var t = task()
        t.materials = [.init(path: "prompt/人设", name: "人设", layer: "Prompt", version: "v")]
        t.read = ["prompt/人设": "v"]
        try snapshot(&t, [("prompt/人设", "人设全文")])
        XCTAssertEqual(current(["prompt/人设"], task: t)["prompt/人设"], .legacySegmentation)
        let s = try XCTUnwrap(one("prompt/人设", task: t, receipts: WikiProposalSources.receipts(t, wiki: wiki)))
        XCTAssertEqual(s.text, "人设全文")
        XCTAssertEqual(s.note, WikiProposalSources.legacySegmentationNote)
        let base = CatalogFloorBase(sections: [.init(path: "prompt/人设", name: "人设", text: "改过的人设", isEnabled: true)])
        let withBase = WikiProposalSources.seed(paths: ["prompt/人设"], task: t, receipts: WikiProposalSources.receipts(t, wiki: wiki),
                                                current: current(["prompt/人设"], task: t, floorBase: base), wiki: wiki).first
        XCTAssertEqual(withBase?.text, "人设全文")
        XCTAssertEqual(withBase?.note, WikiProposalSources.legacySegmentationNote)
    }

    private func personaFixture() throws -> (task: CatalogSeedTask, floor: CatalogFloorBase, items: [CatalogSeedMaterials.Item]) {
        let text = "# 星砚\n" + String(repeating: "星砚陪岚舟写生。", count: 100)
            + "\n\n## 林栖\n" + String(repeating: "林栖在旧码头修木船。", count: 100)
        let floor = CatalogFloorBase(sections: [.init(path: "prompt/人设", name: "人设", text: text, isEnabled: true)])
        let items = CatalogSeedMaterials.personaItems(path: "prompt/人设", name: "人设", text: text)
        var t = task()
        t.entry = .persona
        let written = try CatalogSeedTaskStore(wiki: wiki).writeSnapshot(.init(items: items), id: t.id)
        t.materials = written.materials
        t.read = written.read
        return (t, floor, items)
    }

    func testPromptSegmentCurrentMatchesSnapshotVersion() throws {
        let fixture = try personaFixture()
        let paths = ["prompt/人设#01", "prompt/人设#02"]
        let now = current(paths, task: fixture.task, floorBase: fixture.floor)
        let sources = WikiProposalSources.seed(paths: paths, task: fixture.task,
            receipts: WikiProposalSources.receipts(fixture.task, wiki: wiki), current: now, wiki: wiki)
        XCTAssertEqual(sources.map(\.path), paths)
        for source in sources {
            let original = try XCTUnwrap(fixture.items.first { $0.path == source.path })
            XCTAssertEqual(now[source.path], .present(text: original.text, version: original.version))
            XCTAssertEqual(source.text, original.text)
            XCTAssertNil(source.note, "同一算法重切后的段版本一致，不应报原料消失或改过")
        }
        XCTAssertNil(current([paths[0]], task: fixture.task)[paths[0]], "未提供底图仍是现状未知")
    }

    func testPromptSegmentTextChangeIsFlaggedWithoutChangingOtherSegments() throws {
        let fixture = try personaFixture()
        let changedText = fixture.floor.sections[0].text.replacingOccurrences(of: "星砚陪岚舟写生。", with: "星砚陪岚舟看船。")
        let changedFloor = CatalogFloorBase(sections: [.init(path: "prompt/人设", name: "人设", text: changedText, isEnabled: true)])
        let paths = ["prompt/人设#01", "prompt/人设#02"]
        let now = current(paths, task: fixture.task, floorBase: changedFloor)
        guard case .present(let firstText, let firstVersion)? = now[paths[0]] else { return XCTFail("改过的段仍存在") }
        XCTAssertTrue(firstText.contains("星砚陪岚舟看船。"))
        XCTAssertFalse(firstText.contains("林栖在旧码头修木船。"), "不能把整槽当作本段现状")
        XCTAssertNotEqual(firstVersion, fixture.task.read[paths[0]])
        XCTAssertEqual(firstVersion, WikiStore.version(of: Data(firstText.utf8)))
        let second = try XCTUnwrap(fixture.items.first { $0.path == paths[1] })
        XCTAssertEqual(now[paths[1]], .present(text: second.text, version: second.version))
        let sources = WikiProposalSources.seed(paths: paths, task: fixture.task,
            receipts: WikiProposalSources.receipts(fixture.task, wiki: wiki), current: now, wiki: wiki)
        XCTAssertEqual(sources.first?.note, WikiProposalSources.changedNote)
        XCTAssertEqual(sources.first?.text, fixture.items.first?.text, "详情正文保留提案快照")
        XCTAssertNil(sources.last?.note, "同槽另一段没有变化")
    }

    func testPromptSegmentOutOfRangeIsChangedWhileSlotExists() throws {
        let fixture = try personaFixture()
        let original = try XCTUnwrap(fixture.items.first { $0.path == "prompt/人设#02" })
        let remaining = try XCTUnwrap(fixture.items.first { $0.path == "prompt/人设#01" })
        let floor = CatalogFloorBase(sections: [.init(path: "prompt/人设", name: "人设", text: remaining.text, isEnabled: true)])
        let now = current([original.path], task: fixture.task, floorBase: floor)
        XCTAssertEqual(now[original.path], .resegmented)
        let source = WikiProposalSources.seed(paths: [original.path], task: fixture.task,
            receipts: WikiProposalSources.receipts(fixture.task, wiki: wiki), current: now, wiki: wiki).first
        XCTAssertEqual(source?.text, original.text, "保留编辑前的段快照")
        XCTAssertEqual(source?.note, WikiProposalSources.resegmentedNote)
    }

    func testPromptSegmentMissingSlotIsGone() throws {
        let fixture = try personaFixture()
        let path = "prompt/人设#01"
        let now = current([path], task: fixture.task, floorBase: CatalogFloorBase(sections: []))
        XCTAssertEqual(now[path], .missing)
        let source = WikiProposalSources.seed(paths: [path], task: fixture.task,
            receipts: WikiProposalSources.receipts(fixture.task, wiki: wiki), current: now, wiki: wiki).first
        XCTAssertEqual(source?.note, WikiProposalSources.goneNote, "槽位确实删除才报原料不在")
    }

    func testEmptiedPromptSlotMarksSegmentChangedNotGone() throws {
        let fixture = try personaFixture()
        let path = "prompt/人设#01"
        let floor = CatalogFloorBase(sections: [.init(path: "prompt/人设", name: "人设", text: " \n\t", isEnabled: true)])
        let now = current([path], task: fixture.task, floorBase: floor)
        XCTAssertEqual(now[path], .empty)
        let source = WikiProposalSources.seed(paths: [path], task: fixture.task,
            receipts: WikiProposalSources.receipts(fixture.task, wiki: wiki), current: now, wiki: wiki).first
        XCTAssertEqual(source?.note, WikiProposalSources.emptiedNote)
        XCTAssertEqual(source?.text, fixture.items.first?.text)
    }

    func testLegacyPromptSegmentNeverBorrowsCurrentSameNumber() throws {
        var fixture = try personaFixture()
        fixture.task.materials = fixture.task.materials.map {
            var material = $0
            material.sourceContext = nil
            return material
        }
        let path = fixture.items[0].path
        let floor = CatalogFloorBase(sections: [.init(path: "prompt/人设", name: "人设", text: "# 云桥城\n全新的同号正文", isEnabled: true)])
        let now = current([path], task: fixture.task, floorBase: floor)
        XCTAssertEqual(now[path], .legacySegmentation)
        let source = try XCTUnwrap(WikiProposalSources.seed(paths: [path], task: fixture.task,
            receipts: WikiProposalSources.receipts(fixture.task, wiki: wiki), current: now, wiki: wiki).first)
        XCTAssertEqual(source.text, fixture.items[0].text)
        XCTAssertEqual(source.note, WikiProposalSources.legacySegmentationNote)
        XCTAssertNil(WikiProposalSources.seed(paths: [path], task: fixture.task, receipts: [:], current: now, wiki: wiki).first?.text)
    }

    func testPromptAncestorRenameAndRenumberingAreResegmented() throws {
        let fixture = try personaFixture()
        let path = "prompt/人设#02"
        let original = try XCTUnwrap(fixture.items.first { $0.path == path })
        for text in [
            fixture.floor.sections[0].text.replacingOccurrences(of: "# 星砚", with: "# 云桥城"),
            "# 云桥城\n前置章节\n" + fixture.floor.sections[0].text
        ] {
            let floor = CatalogFloorBase(sections: [.init(path: "prompt/人设", name: "人设", text: text, isEnabled: true)])
            let now = current([path], task: fixture.task, floorBase: floor)
            XCTAssertEqual(now[path], .resegmented)
            let source = WikiProposalSources.seed(paths: [path], task: fixture.task,
                receipts: WikiProposalSources.receipts(fixture.task, wiki: wiki), current: now, wiki: wiki).first
            XCTAssertEqual(source?.text, original.text)
            XCTAssertEqual(source?.note, WikiProposalSources.resegmentedNote)
        }
    }

    func testPromptSlotRenameIsChangedEvenWithIdenticalText() throws {
        let fixture = try personaFixture()
        let path = fixture.items[0].path
        let floor = CatalogFloorBase(sections: [.init(path: "prompt/人设", name: "林栖", text: fixture.floor.sections[0].text, isEnabled: true)])
        let now = current([path], task: fixture.task, floorBase: floor)
        XCTAssertEqual(now[path], .contextChanged)
        let source = WikiProposalSources.seed(paths: [path], task: fixture.task,
            receipts: WikiProposalSources.receipts(fixture.task, wiki: wiki), current: now, wiki: wiki).first
        XCTAssertEqual(source?.text, fixture.items[0].text)
        XCTAssertEqual(source?.note, WikiProposalSources.contextChangedNote)
    }

    // MARK: - 只取列着的、能取消、回执索引 / 缓存（astra 10-23 P2）

    /// 只取这一项列着的那几份；每份之前一个检查点，取消就停
    func testOnlyListedPathsAndCancellation() throws {
        try cc("a.md", "# 甲\n正文")
        try cc("b.md", "# 乙\n正文")
        try cc("unrelated.md", "# 无关\n正文")
        var checks = 0
        let got = WikiProposalSources.current(paths: ["memory/cc/a.md"], layers: [:], task: nil, floorBase: nil,
                                              memoryRoot: root, wiki: wiki, check: { checks += 1 })
        XCTAssertEqual(Set(got.keys), ["memory/cc/a.md"], "没列的不取")
        XCTAssertEqual(checks, 1)

        struct Stop: Error {}
        var calls = 0
        XCTAssertThrowsError(try WikiProposalSources.current(paths: ["memory/cc/a.md", "memory/cc/b.md"], layers: [:], task: nil,
                                                             floorBase: nil, memoryRoot: root, wiki: wiki,
                                                             check: { calls += 1; if calls == 2 { throw Stop() } }))
        XCTAssertEqual(calls, 2, "第二份之前就停")

        let d = WikiProposal.Direction(path: "人/阿青", title: "阿青", action: .newPage, reason: "", mode: .seed, sources: ["memory/cc/a.md"])
        let target = WikiProposalItemTarget(proposalId: "p", item: .init(change: .direction(d), baseVersion: nil), seedTask: nil, fragments: [])
        XCTAssertThrowsError(try WikiProposalItemDocument.build(target, wiki: wiki, floorBase: nil, check: { throw Stop() }), "取消了不交结果")
        XCTAssertEqual(WikiProposalItemDocument.build(target, wiki: wiki, floorBase: nil).blocks.map(\.name),
                       ["a.md · CC · 域：未记录"], "不取消就能交出原料卡")
    }

    /// 快照索引一次读完，和逐份 `readText` 一致（同一路径取清单里第一份）
    func testSnapshotIndexMatchesReadText() throws {
        var t = task()
        try snapshot(&t, [("memory/cc/a.md", "第一次"), ("memory/cc/a.md", "第二次"), ("memory/cc/b.md", "乙")])
        let index = WikiProposalSources.receipts(t, wiki: wiki)
        XCTAssertEqual(index["memory/cc/a.md"], t.readText("memory/cc/a.md", wiki: wiki))
        XCTAssertEqual(index["memory/cc/a.md"], "第一次")
        XCTAssertEqual(index["memory/cc/b.md"], "乙")
        XCTAssertNil(t.readText("memory/cc/没有.md", wiki: wiki))
    }

    /// 原料身份按快照清单里的路径认，不从名字反推：一份的名字恰好像另一份的路径也认得对；版本空的那份不取
    func testSnapshotIdentityIsByPathNotName() throws {
        var t = task()
        let a = "memory/wiki/人/A.md", b = "memory/wiki/人/A.md · wiki · X.md"
        t.materials = [.init(path: a, name: "X.md · 标题", layer: "wiki", version: "va"), .init(path: b, name: "B", layer: "wiki", version: "vb"),
                       .init(path: "memory/cc/gone.md", name: "没了", layer: "CC", version: "")]
        try snapshot(&t, [(a, "甲的正文"), (b, "乙的正文"), ("memory/cc/gone.md", "")])
        t.read["memory/cc/gone.md"] = ""
        XCTAssertEqual(t.readText(a, wiki: wiki), "甲的正文")
        XCTAssertEqual(t.readText(b, wiki: wiki), "乙的正文")
        XCTAssertEqual(WikiProposalSources.receipts(t, wiki: wiki), [a: "甲的正文", b: "乙的正文"])
    }

    /// task.json 没改过就复用解析结果；改了重读
    func testSeedTaskCacheReusesUntilFileChanges() throws {
        let store = CatalogSeedTaskStore(wiki: wiki)
        var t = task()
        try snapshot(&t, [("memory/cc/a.md", "第一版")])
        try store.save(t)
        let file = store.folder(t.id).appendingPathComponent(CatalogSeedTaskStore.fileName).path
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file)
        XCTAssertEqual(SeedTaskCache.shared.load(t.id, store: store)?.receipts["memory/cc/a.md"], "第一版")

        t.materials = []
        t.read = [:]
        try snapshot(&t, [("memory/cc/a.md", "第二版")])
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        try store.save(t)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file)
        XCTAssertEqual(SeedTaskCache.shared.load(t.id, store: store)?.receipts["memory/cc/a.md"], "第一版", "时间戳没变：复用")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: file)
        XCTAssertEqual(SeedTaskCache.shared.load(t.id, store: store)?.receipts["memory/cc/a.md"], "第二版", "改过：重读")
        XCTAssertFalse(data.isEmpty)
    }

    func testSeedBodyWithOnlyCitesOpensFrozenMaterialDetail() throws {
        var t = task()
        let path = "memory/cc/云桥城.md"
        try snapshot(&t, [(path, "设定中云桥城有夜航。")])
        try CatalogSeedTaskStore(wiki: wiki).save(t)
        let item = WikiProposal.Item(change: .appendRecords(path: "主题/云桥城", lines: ["夜航"]),
                                     cites: [.init(layer: "CC", filePath: path)])
        XCTAssertTrue(WikiProposalItemTarget.hasDetail(item))
        let target = WikiProposalItemTarget(proposalId: "fictional", item: item, seedTask: t.id, fragments: [])
        let document = WikiProposalItemDocument.build(target, wiki: wiki, floorBase: nil)
        XCTAssertEqual(document.blocks.map(\.text), ["设定中云桥城有夜航。"])
    }

    func testDailyBodyWithOnlyA2CiteDoesNotOfferMaterialDetail() {
        let item = WikiProposal.Item(change: .appendRecords(path: "主题/夜航", lines: ["夜航"]),
                                     cites: [.init(layer: "A2", windowId: "0001aaaa", segment: 1)])
        XCTAssertFalse(WikiProposalItemTarget.hasDetail(item))
    }

    func testSurveyBodyCitesResolveEachAnswerAsSurveyMaterial() throws {
        var t = task()
        t.entry = .survey
        let answers = CatalogSurvey.answers(["岚舟", "在云桥城修船", ""])
        t.answers = answers
        let day = CatalogSurvey.day(t.createdAt)
        try snapshot(&t, answers.map { ($0.path, CatalogSurvey.answerText($0, day: day)) })
        try CatalogSeedTaskStore(wiki: wiki).save(t)
        let item = WikiProposal.Item(change: .appendRecords(path: "主题/修船", lines: ["修船"]),
            cites: answers.map { CatalogSurvey.cite(key: $0.key, taskId: t.id, day: day) })
        XCTAssertTrue(WikiProposalItemTarget.hasDetail(item))
        XCTAssertEqual(WikiProposalItemTarget.seedCitePaths(item), ["问卷/称呼", "问卷/在做什么"])
        let target = WikiProposalItemTarget(proposalId: "fictional", item: item, seedTask: t.id, fragments: [])
        let document = WikiProposalItemDocument.build(target, wiki: wiki, floorBase: nil)
        XCTAssertEqual(document.blocks.map(\.name), ["称呼 · 问卷 · 域：未记录", "在做什么 · 问卷 · 域：未记录"])
        XCTAssertEqual(document.blocks.map(\.text), answers.map { CatalogSurvey.answerText($0, day: day) })
    }

    // MARK: - 页面（复用整理记录那套原生查看）

    func testDocumentRowsAndCards() {
        let sources = [
            WikiProposalSources.Source(path: "memory/cc/a.md", name: "甲", layer: "CC", text: "一行", note: WikiProposalSources.changedNote),
            WikiProposalSources.Source(path: "x", name: "碎片标题", layer: "碎片", text: "第一行\n第二行", note: nil),
        ]
        let doc = WikiProposalItemDocument.document(title: "阿青", fields: [("路径", "人/阿青"), ("钩子", " ")], sources: sources)
        XCTAssertEqual(doc.rows.count, 5, "标题 + 路径（空钩子不写）+ 原料头 + 两张卡")
        guard case .heading("阿青", 1) = doc.rows[0], case .prose("路径：人/阿青") = doc.rows[1],
              case .heading("原料 2 份 · CC 1 · 碎片 1", 2) = doc.rows[2] else { return XCTFail("\(doc.rows)") }
        let blocks = doc.blocks
        XCTAssertEqual(blocks.map(\.id), [3, 4])
        XCTAssertTrue(blocks.allSatisfy { $0.alwaysCard && !RunRecordTypography.isSingleLine($0) }, "一行的原料也折成卡（看得见名字）")
        XCTAssertEqual(blocks.map(\.name), ["甲 · CC · 域：未记录", "碎片标题 · 碎片"])
        XCTAssertEqual(blocks[0].summary, WikiProposalSources.changedNote, "卡上就看得出改过")
        XCTAssertEqual(blocks[1].summary, "第一行")
        XCTAssertEqual(blocks[0].note, WikiProposalSources.changedNote)
        XCTAssertEqual(WikiProposalItemDocument.document(title: "t", fields: [], sources: []).rows.count, 2)
    }

    func testFieldsForSeedDirection() {
        let d = WikiProposal.Direction(path: "人/阿青", title: "阿青", hook: "提到阿青时", kind: .person, action: .newPage,
                                       reason: "CC 里反复出现", mode: .seed, sources: ["memory/cc/a.md"])
        let item = WikiProposal.Item(state: .pending, change: .direction(d), baseVersion: nil)
        let fields = WikiProposalItemDocument.fields(item)
        XCTAssertEqual(fields.map(\.0), ["路径", "类", "标题", "页域", "钩子", "理由", "批了以后"])
        XCTAssertEqual(fields[1].1, WikiPage.Kind.person.rawValue)
        XCTAssertEqual(fields.first { $0.0 == "页域" }?.1, "未记录")
        XCTAssertTrue(WikiProposalItemTarget.hasDetail(item))
        let plain = WikiProposal.Item(state: .pending, change: .appendRecords(path: "人/阿青", lines: ["a"]), baseVersion: nil)
        XCTAssertFalse(WikiProposalItemTarget.hasDetail(plain), "没碎片出处的正文条目不出「看详情」")
    }

    func testDeletedFragmentSource() {
        let id = UUID()
        let gone = WikiProposalItemTarget.fragment(id: id, title: nil, content: nil, quote: nil, day: nil)
        XCTAssertNil(gone.text)
        XCTAssertEqual(gone.layer, "碎片")
        let live = WikiProposalItemTarget.fragment(id: id, title: "标题", content: "正文", quote: "原话", day: "2026-10-01")
        XCTAssertEqual(live.text, "正文\n\n原话：原话\n发生在：2026-10-01")
    }
}
