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

    /// 种子 read 工具的回执（同 `CatalogSeedAgent`：头一行【路径 · 层 · 名】，下面是全文）
    private func receipt(_ path: String, _ text: String) -> CatalogSeedTask.Turn {
        let id = UUID().uuidString
        let args = String(data: try! JSONSerialization.data(withJSONObject: ["path": path]), encoding: .utf8)!
        return CatalogSeedTask.Turn(calls: [.init(id: id, name: CatalogSeedTools.read, argumentsJSON: args, truncated: false)],
                                    results: [.init(toolUseId: id, text: "【\(path) · x · x】\n" + text, isError: false)])
    }

    private func current(_ paths: [String], task: CatalogSeedTask? = nil, floorBase: CatalogFloorBase? = nil) -> [String: WikiProposalSources.Current] {
        WikiProposalSources.current(paths: paths, layers: WikiProposalSources.layers(paths, task: task), task: task,
                                    floorBase: floorBase, memoryRoot: root, wiki: wiki)
    }

    private func one(_ path: String, task: CatalogSeedTask?, receipts: [String: String] = [:]) -> WikiProposalSources.Source? {
        WikiProposalSources.seed(paths: [path], task: task, receipts: receipts, current: current([path], task: task)).first
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
        t.turns = [receipt(secret, "不能看的内容")]
        let out = WikiProposalSources.seed(paths: [secret, upper, ok], task: t, receipts: WikiProposalSources.receipts(t), current: now)
        XCTAssertEqual(out.map(\.path), [ok], "private_ 不列")
        XCTAssertFalse(out.contains { ($0.text ?? "").contains("不能看的内容") || $0.name.contains("机密") })

        let doc = WikiProposalItemDocument.document(title: "t", fields: [], sources: out)
        XCTAssertFalse(doc.blocks.contains { $0.text.contains("不能看的内容") || $0.name.contains("机密") }, "页面上也看不到")
        XCTAssertTrue(WikiProposalSources.isPrivate("memory/cc/Private_x.md"))
        XCTAssertTrue(WikiProposalSources.isPrivate("memory/wiki/楼层/private_box/甲.md"), "路径上任何一段是私人的都算")
        XCTAssertFalse(WikiProposalSources.isPrivate("memory/cc/not_private.md"))
    }

    // MARK: - private_（wiki：种子原料链本身）

    private func seedWikiWithPrivatePages() throws {
        _ = try wiki.save(WikiPage(path: "楼层/人/阿青", hook: "聊到阿青", title: "阿青", now: "公开的内容"))
        _ = try wiki.save(WikiPage(path: "楼层/人/private_secret", hook: "秘密钩子", title: "机密标题", now: "私人正文"))
        _ = try wiki.save(WikiPage(path: "楼层/人/Private_Upper", hook: "秘密钩子二", title: "机密标题二", now: "私人正文二"))
        _ = try wiki.save(WikiPage(path: "楼层/private_box/甲", hook: "秘密钩子三", title: "机密标题三", now: "私人正文三"))
    }

    /// astra 10-23 P1：SafeWiki 在打开文件、生成索引之前就跳过私人页和私人文件夹——种子 gather 和详情页都受这条保护
    func testSafeWikiSkipsPrivatePagesBeforeReadingAndIndexing() throws {
        try seedWikiWithPrivatePages()
        let safe = SafeWiki.scan(wiki, memoryRoot: root)
        XCTAssertEqual(safe.pages.map(\.path), ["楼层/人/阿青"])
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

        let indexPath = CatalogSeedMaterials.indexPath("楼层/人")
        guard case .present(let text, _)? = current([indexPath])[indexPath] else { return XCTFail("索引现状应该在") }
        XCTAssertTrue(text.contains("阿青"))
        XCTAssertFalse(text.contains("机密") || text.contains("private_"))
        XCTAssertEqual(WikiProposalSources.wikiPage(CatalogSeedMaterials.wikiPath("楼层/人/阿青"), wiki: wiki, memoryRoot: root),
                       .present(text: try XCTUnwrap(safe.pages.first?.text), version: try XCTUnwrap(safe.pages.first?.version)),
                       "单页现状和种子收集同一个版本")
    }

    /// 历史 INDEX 回执里指向私人页的行剥掉（修之前生成的回执可能带着）
    func testHistoricIndexReceiptDropsPrivateLines() throws {
        try seedWikiWithPrivatePages()
        let indexPath = CatalogSeedMaterials.indexPath("楼层/人")
        var t = task()
        t.materials = [.init(path: indexPath, name: "wiki 索引 · 楼层/人", layer: "wiki", version: "旧")]
        t.read = [indexPath: "旧"]
        t.turns = [receipt(indexPath, "# 楼层/人\n\n- [[楼层/人/阿青]] 阿青 — 聊到阿青\n- [[楼层/人/private_secret]] 机密标题 — 秘密钩子\n- [[楼层/人/PRIVATE_x]] 机密二\n")]
        let s = try XCTUnwrap(one(indexPath, task: t, receipts: WikiProposalSources.receipts(t)))
        let text = try XCTUnwrap(s.text)
        XCTAssertTrue(text.contains("阿青"))
        XCTAssertFalse(text.contains("机密") || text.contains("秘密钩子") || text.lowercased().contains("private_"), text)
        XCTAssertEqual(WikiProposalSources.strippingPrivateLinks("普通一行\n[[a/private_b]] x\n[[a/b]] y"), "普通一行\n[[a/b]] y")
    }

    // MARK: - 现状四态（astra 10-23 P2）

    private func readTask(_ path: String, receiptText: String, version: String = "旧版本") -> CatalogSeedTask {
        var t = task()
        t.materials = [.init(path: path, name: "好的", layer: "CC", version: version)]
        t.read = [path: version]
        t.turns = [receipt(path, receiptText)]
        return t
    }

    /// 先取提案生成时读到的那一份（回执）；现状版本不一样标「改过」，一样不标
    func testReceiptWinsAndChangeIsFlagged() throws {
        try cc("ok.md", "# 好的\n正文 新")
        let path = "memory/cc/ok.md"
        guard case .present(_, let version)? = current([path])[path] else { return XCTFail() }
        var t = readTask(path, receiptText: "类型：未标注\n标题：好的\n\n正文 旧")
        let changed = try XCTUnwrap(one(path, task: t, receipts: WikiProposalSources.receipts(t)))
        XCTAssertEqual(changed.text, "类型：未标注\n标题：好的\n\n正文 旧", "给她看的是提案读到的那一版")
        XCTAssertEqual(changed.note, WikiProposalSources.changedNote)
        XCTAssertEqual(changed.layer, "CC")

        t.read = [path: version]
        XCTAssertNil(one(path, task: t, receipts: WikiProposalSources.receipts(t))?.note, "版本一样不标")
    }

    /// 清空了 = 内容变了（不是「不在了」）
    func testEmptiedFileIsChangedNotGone() throws {
        try cc("ok.md", "   \n")
        let path = "memory/cc/ok.md"
        XCTAssertEqual(current([path])[path], .empty)
        let t = readTask(path, receiptText: "当时的正文")
        let s = try XCTUnwrap(one(path, task: t, receipts: WikiProposalSources.receipts(t)))
        XCTAssertEqual(s.text, "当时的正文")
        XCTAssertEqual(s.note, WikiProposalSources.emptiedNote)
    }

    /// 只有真的不存在才标「不在了」；没回执也没现状写「没读到」
    func testMissingIsGone() throws {
        let path = "memory/cc/gone.md"
        XCTAssertEqual(current([path])[path], .missing)
        let t = readTask(path, receiptText: "当时的正文")
        XCTAssertEqual(one(path, task: t, receipts: WikiProposalSources.receipts(t))?.note, WikiProposalSources.goneNote)
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
            let t = readTask(path, receiptText: "当时的正文")
            let s = try XCTUnwrap(one(path, task: t, receipts: WikiProposalSources.receipts(t)))
            XCTAssertEqual(s.text, "当时的正文")
            XCTAssertTrue(s.note?.hasPrefix("这份原料现在读不了") == true, s.note ?? "")
        }
    }

    /// wiki 页：路径上有链接 = 读不了；页不在 = 不在
    func testWikiPageStates() throws {
        _ = try wiki.save(WikiPage(path: "楼层/人/阿青", hook: "", title: "阿青", now: "内容"))
        let real = wiki.root.appendingPathComponent("楼层/人")
        try FileManager.default.createSymbolicLink(at: wiki.root.appendingPathComponent("楼层/链"), withDestinationURL: real)
        XCTAssertEqual(WikiProposalSources.wikiPage(CatalogSeedMaterials.wikiPath("楼层/人/没有"), wiki: wiki, memoryRoot: root), .missing)
        guard case .unreadable = WikiProposalSources.wikiPage(CatalogSeedMaterials.wikiPath("楼层/链/阿青"), wiki: wiki, memoryRoot: root) else {
            return XCTFail("经过链接的页不读")
        }
    }

    /// 没接 Prompt 底图：Prompt 原料现状未知，不乱标
    func testPromptWithoutFloorBaseIsNotFlagged() throws {
        var t = task()
        t.materials = [.init(path: "prompt/人设", name: "人设", layer: "Prompt", version: "v")]
        t.read = ["prompt/人设": "v"]
        t.turns = [receipt("prompt/人设", "人设全文")]
        XCTAssertNil(current(["prompt/人设"], task: t)["prompt/人设"])
        let s = try XCTUnwrap(one("prompt/人设", task: t, receipts: WikiProposalSources.receipts(t)))
        XCTAssertEqual(s.text, "人设全文")
        XCTAssertNil(s.note)
        let base = CatalogFloorBase(sections: [.init(path: "prompt/人设", name: "人设", text: "改过的人设", isEnabled: true)])
        let withBase = WikiProposalSources.seed(paths: ["prompt/人设"], task: t, receipts: WikiProposalSources.receipts(t),
                                                current: current(["prompt/人设"], task: t, floorBase: base)).first
        XCTAssertEqual(withBase?.note, WikiProposalSources.changedNote)
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

        let d = WikiProposal.Direction(path: "楼层/人/阿青", title: "阿青", action: .newPage, reason: "", mode: .seed, sources: ["memory/cc/a.md"])
        let target = WikiProposalItemTarget(proposalId: "p", item: .init(change: .direction(d), baseVersion: nil), seedTask: nil, fragments: [])
        XCTAssertThrowsError(try WikiProposalItemDocument.build(target, wiki: wiki, floorBase: nil, check: { throw Stop() }), "取消了不交结果")
        XCTAssertEqual(WikiProposalItemDocument.build(target, wiki: wiki, floorBase: nil).blocks.map(\.name), ["a.md · CC"])
    }

    /// 回执索引一次扫完，和逐份 `readText` 一致（同一路径取第一次成功的）
    func testReceiptIndexMatchesReadText() {
        var t = task()
        t.turns = [receipt("memory/cc/a.md", "第一次"), receipt("memory/cc/a.md", "第二次"), receipt("memory/cc/b.md", "乙")]
        let index = WikiProposalSources.receipts(t)
        XCTAssertEqual(index["memory/cc/a.md"], t.readText("memory/cc/a.md"))
        XCTAssertEqual(index["memory/cc/a.md"], "第一次")
        XCTAssertEqual(index["memory/cc/b.md"], "乙")
    }

    /// task.json 没改过就复用解析结果；改了重读
    func testSeedTaskCacheReusesUntilFileChanges() throws {
        let store = CatalogSeedTaskStore(wiki: wiki)
        var t = task()
        t.turns = [receipt("memory/cc/a.md", "第一版")]
        try store.save(t)
        let file = store.folder(t.id).appendingPathComponent(CatalogSeedTaskStore.fileName).path
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file)
        XCTAssertEqual(SeedTaskCache.shared.load(t.id, store: store)?.receipts["memory/cc/a.md"], "第一版")

        t.turns = [receipt("memory/cc/a.md", "第二版")]
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        try store.save(t)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file)
        XCTAssertEqual(SeedTaskCache.shared.load(t.id, store: store)?.receipts["memory/cc/a.md"], "第一版", "时间戳没变：复用")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: file)
        XCTAssertEqual(SeedTaskCache.shared.load(t.id, store: store)?.receipts["memory/cc/a.md"], "第二版", "改过：重读")
        XCTAssertFalse(data.isEmpty)
    }

    // MARK: - 页面（复用整理记录那套原生查看）

    func testDocumentRowsAndCards() {
        let sources = [
            WikiProposalSources.Source(path: "memory/cc/a.md", name: "甲", layer: "CC", text: "一行", note: WikiProposalSources.changedNote),
            WikiProposalSources.Source(path: "x", name: "碎片标题", layer: "碎片", text: "第一行\n第二行", note: nil),
        ]
        let doc = WikiProposalItemDocument.document(title: "阿青", fields: [("路径", "楼层/人/阿青"), ("钩子", " ")], sources: sources)
        XCTAssertEqual(doc.rows.count, 5, "标题 + 路径（空钩子不写）+ 原料头 + 两张卡")
        guard case .heading("阿青", 1) = doc.rows[0], case .prose("路径：楼层/人/阿青") = doc.rows[1],
              case .heading("原料 2 份 · CC 1 · 碎片 1", 2) = doc.rows[2] else { return XCTFail("\(doc.rows)") }
        let blocks = doc.blocks
        XCTAssertEqual(blocks.map(\.name), ["甲 · CC", "碎片标题 · 碎片"])
        XCTAssertEqual(blocks.map(\.id), [3, 4])
        XCTAssertTrue(blocks.allSatisfy { $0.alwaysCard && !RunRecordTypography.isSingleLine($0) }, "一行的原料也折成卡（看得见名字）")
        XCTAssertEqual(blocks[0].note, WikiProposalSources.changedNote)
        XCTAssertEqual(blocks[0].summary, WikiProposalSources.changedNote, "卡上就看得出改过")
        XCTAssertEqual(blocks[1].summary, "第一行")
        XCTAssertEqual(WikiProposalItemDocument.document(title: "t", fields: [], sources: []).rows.count, 2)
    }

    func testFieldsForSeedDirection() {
        let d = WikiProposal.Direction(path: "楼层/人/阿青", title: "阿青", hook: "提到阿青时", kind: .person, action: .newPage,
                                       reason: "CC 里反复出现", mode: .seed, sources: ["memory/cc/a.md"])
        let item = WikiProposal.Item(state: .pending, change: .direction(d), baseVersion: nil)
        let fields = WikiProposalItemDocument.fields(item)
        XCTAssertEqual(fields.map(\.0), ["路径", "类", "标题", "钩子", "理由", "批了以后"])
        XCTAssertEqual(fields[1].1, WikiPage.Kind.person.rawValue)
        XCTAssertTrue(WikiProposalItemTarget.hasDetail(item))
        let plain = WikiProposal.Item(state: .pending, change: .appendRecords(path: "楼层/人/阿青", lines: ["a"]), baseVersion: nil)
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
