import MemoryCore
import XCTest
@testable import 记忆花园

/// 种子「要点卡」流程第 1 段（plan-seed-notes-flow）：切批 / 解析（硬软检查、一次重写）/ 落盘复用 / 聚合 / 对齐 / 回扫补配 / 聚类 / 目录 / 快照。
/// 全是纯函数 + 临时目录，名字全是编的（岚舟 / 星砚 / 云桥城 / 林栖）
final class CatalogSeedNotesTests: XCTestCase {
    private var root: URL!
    private var wiki: WikiStore!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "小桥")
    private let run = CatalogRunLink(path: ".runs/x.md", anchor: nil)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("seed-notes-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root.appendingPathComponent("wiki", isDirectory: true))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    private func item(_ path: String, _ text: String, name: String = "", layer: String = "CC") -> CatalogSeedMaterials.Item {
        .init(path: path, name: name.isEmpty ? path : name, layer: layer, text: text, version: WikiStore.version(of: Data(text.utf8)))
    }

    private func card(_ path: String, title: String = "一份原料", gist: String = "要点", mentions: [(String, String)] = [],
                      aboutUser: Bool = false, group: String = "主题", name: String = "", version: String = "v1", factDomain: SeedFactDomain? = .realWorld) -> SeedNoteCard {
        SeedNoteCard(path: path, version: version, name: name.isEmpty ? path : name, layer: "CC", title: title, gist: gist,
                     mentions: mentions.map { .init(name: $0.0, group: $0.1) }, aboutUser: aboutUser, group: group, when: [],
                     model: "fake", madeAt: t0, run: run, factDomain: factDomain)
    }

    private func task(read: [String: String], entry: CatalogSeedEntry = .cc) -> CatalogSeedTask {
        var t = CatalogSeedTask(id: UUID().uuidString, profileId: "p", entry: entry, modelName: "fake", modelKey: nil, createdAt: t0, run: run)
        t.materials = read.keys.sorted().map { .init(path: $0, name: $0, layer: "CC", version: read[$0]!) }
        t.read = read
        return t
    }

    private func cardsJSON(_ cards: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["cards": cards]), as: UTF8.self)
    }

    private func okCard(_ m: String, title: String = "岚舟陪星砚写生", gist: String = "岚舟每周三去旧码头陪星砚写生", mentions: [[String: String]] = [["name": "星砚", "group": "人"]],
                        group: String = "{{user}}", aboutUser: Bool = true, factDomain: SeedFactDomain = .realWorld) -> [String: Any] {
        ["m": m, "title": title, "gist": gist, "mentions": mentions, "about_user": aboutUser, "group": group, "fact_domain": factDomain.rawValue]
    }

    // MARK: - 切批

    func testBatchesByCharsKeepOrderAndNeverSplitOne() {
        let a = item("m/a.md", String(repeating: "甲", count: 5_000))
        let b = item("m/b.md", String(repeating: "乙", count: 5_000))
        let c = item("m/c.md", String(repeating: "丙", count: 5_000))
        let big = item("m/big.md", String(repeating: "丁", count: 13_000))
        let d = item("m/d.md", String(repeating: "戊", count: 100))
        let page = item("memory/wiki/人/林栖.md", "wiki 页", layer: "wiki")
        let batches = SeedNoteBatcher.batches([a, b, c, big, d, page], limit: 12_000, carded: [:], entry: .cc)
        XCTAssertEqual(batches.map { $0.map(\.path) }, [["m/a.md", "m/b.md"], ["m/c.md"], ["m/big.md"], ["m/d.md"]], "按字数累加、顺序稳定、一份不拆、单份超上限自成一批、wiki 不出卡")

        let again = SeedNoteBatcher.batches([a, b, c], limit: 12_000, carded: ["m/a.md": a.version, "m/b.md": "旧版本"], entry: .cc)
        XCTAssertEqual(again.map { $0.map(\.path) }, [["m/b.md", "m/c.md"]], "同版本已出卡的跳过，版本变了重出")

        let answer = item("问卷/在做什么", "在做模型船", layer: "问卷")
        let survey = SeedNoteBatcher.batches([a, answer, page], limit: 12_000, carded: [:], entry: .survey)
        XCTAssertEqual(survey.map { $0.map(\.path) }, [["问卷/在做什么"]], "三问只给答案出卡")
        XCTAssertEqual(SeedNoteBatcher.label(2), "m3")
    }

    func testBatchBudgetIncludesMechanicalSourceHeaders() {
        var a = item("prompt/设定#01", String(repeating: "甲", count: 100), layer: "Prompt")
        a.sourceContext = .init(slotPath: "prompt/设定", slotName: "云桥城设定", headingPath: ["城邦背景"])
        let b = item("memory/cc/海图.md", String(repeating: "乙", count: 100))
        let limit = a.text.count + b.text.count
        XCTAssertEqual(SeedNoteBatcher.batches([a, b], limit: limit, carded: [:], entry: .cc).map { $0.map(\.path) },
                       [[a.path], [b.path]], "正文恰好不超限，加入实际发送的来源头行后必须分批")
    }

    func testFailedBatchIsTheOnlyOneRebatchedOnResume() {
        let a = item("m/a.md", "甲"), b = item("m/b.md", "乙"), c = item("m/c.md", "丙")
        var progress = SeedNoteProgress()
        progress.batches = [.init(index: 1, paths: ["m/a.md"], ok: true), .init(index: 2, paths: ["m/b.md", "m/c.md"], ok: false, reason: "重写一次仍不合格")]
        XCTAssertEqual(progress.failedPaths, ["m/b.md", "m/c.md"])
        // 出了卡的记进 carded；failed 批的没记，续跑重新切批只剩它们
        let carded = ["m/a.md": a.version]
        XCTAssertEqual(SeedNoteBatcher.batches([a, b, c], limit: 12_000, carded: carded, entry: .cc).map { $0.map(\.path) }, [["m/b.md", "m/c.md"]])
    }

    func testRequestShapeIsOneUserMessageNoTools() {
        let r = SeedNoteRequest.make(system: "S", user: "U")
        XCTAssertEqual(r.history.count, 1)
        XCTAssertEqual(r.history.first?.role, "user")
        XCTAssertEqual(r.history.first?.content, "U")
        XCTAssertTrue(r.tools.isEmpty)
        XCTAssertTrue(r.toolTurns.isEmpty)
        XCTAssertEqual(r.maxTokens, CatalogAgent.seedMaxTokens)
        let rewrite = SeedNoteRequest.make(system: "S", user: "U", rewrite: "缺了 m2")
        XCTAssertEqual(rewrite.history.count, 1, "重写也是一条，不带上一次的坏回复")
        XCTAssertTrue(rewrite.history.first!.content.hasPrefix("U\n\n") && rewrite.history.first!.content.contains("缺了 m2"))
    }

    func testCardsUserIncludesMechanicalSourcesWithoutChangingLabelsOrText() {
        var headed = item("prompt/人设#01", "星砚不去北岸", name: "第一份", layer: "Prompt")
        headed.sourceContext = .init(slotPath: "prompt/人设", slotName: "人设", headingPath: ["星砚", "雷区"])
        var plain = item("prompt/补充#01", "林栖守着旧码头", name: "第二份", layer: "Prompt")
        plain.sourceContext = .init(slotPath: "prompt/补充", slotName: "补充", headingPath: [])
        let cc = item("memory/cc/海图.md", "岚舟收集海图", name: "第三份")
        let batch = [headed, plain, cc]
        let labels = ["m7", "m2", "m9"]
        let request = SeedNotePrompts.cardsUser(batch, labels: labels)
        let headers = request.components(separatedBy: "\n").filter { $0.hasPrefix("【m") }
        for (index, material) in batch.enumerated() {
            XCTAssertTrue(headers[index].contains(labels[index]))
            XCTAssertTrue(headers[index].contains(material.layer))
            XCTAssertTrue(headers[index].contains(material.name))
            XCTAssertTrue(request.contains("\n" + material.text))
        }
        XCTAssertTrue(headers[0].contains("来源：人设 › 星砚 › 雷区"))
        XCTAssertTrue(headers[1].contains("来源：补充"))
        XCTAssertFalse(headers[1].contains(" › "))
        XCTAssertTrue(headers[2].contains("来源：CC 记忆"))
        XCTAssertFalse(headers[2].contains("prompt/"))
    }

    // MARK: - 解析（硬检查）

    func testParserAcceptsFencedAndThinkWrappedReplyAndRestoresUserGroup() throws {
        let raw = "<think>想一想</think>\n```json\n" + cardsJSON([okCard("m1", group: "岚舟"), okCard("m2", mentions: [], group: "主题", aboutUser: false)]) + "\n```"
        let cards = try SeedNoteParser.cards(raw, labels: ["m1", "m2"], user: names.user).get().cards
        XCTAssertEqual(cards["m1"]?.group, "{{user}}", "本人那组按 .notes 的 cards.group 位置还原成 {{user}}")
        XCTAssertEqual(cards["m1"]?.mentions, [.init(name: "星砚", group: "人")])
        XCTAssertEqual(cards["m1"]?.aboutUser, true)
        XCTAssertEqual(cards["m2"]?.group, "主题")
        XCTAssertEqual(cards["m2"]?.title, "岚舟陪星砚写生")
    }

    func testParserAcceptsAllFourDeclaredFactDomainsWithoutReplacingEnumValuesAsUserNames() throws {
        let domains: [SeedFactDomain] = [.realWorld, .inWorld, .mixed, .unspecified]
        let labels = domains.indices.map(SeedNoteBatcher.label)
        let raw = cardsJSON(zip(labels, domains).map { okCard($0.0, factDomain: $0.1) })
        for user in domains.map(\.rawValue) {
            let reply = try SeedNoteParser.cards(raw, labels: labels, user: user).get()
            XCTAssertTrue(reply.problems.isEmpty)
            XCTAssertTrue(reply.batchProblems.isEmpty)
            for (label, domain) in zip(labels, domains) {
                XCTAssertEqual(reply.cards[label]?.factDomain, domain)
            }
        }
    }

    func testMissingAndInvalidFactDomainsStayCardProblemsEvenWhenSalvaging() throws {
        var missing = okCard("m1")
        missing["fact_domain"] = nil
        for invalidValue in ["real", 42] as [Any] {
            var invalid = okCard("m2")
            invalid["fact_domain"] = invalidValue
            let raw = cardsJSON([missing, invalid, okCard("m3", factDomain: .inWorld)])
            for salvaging in [false, true] {
                let reply = try SeedNoteParser.cards(raw, labels: ["m1", "m2", "m3"], user: names.user, salvaging: salvaging).get()
                XCTAssertEqual(Set(reply.cards.keys), ["m3"])
                XCTAssertEqual(reply.cards["m3"]?.factDomain, .inWorld)
                XCTAssertEqual(Set(reply.problems.keys), ["m1", "m2"])
                XCTAssertTrue(reply.problems.values.allSatisfy { $0.contains { $0.contains("fact_domain") } })
                XCTAssertTrue(reply.batchProblems.isEmpty)
            }
        }
    }

    func testMissingFactDomainStillFailsAfterRewriteAndSingletonFallback() async {
        for hasGoodCard in [true, false] {
            let labels = hasGoodCard ? ["m1", "m2"] : ["m2"]
            var requests: [[String]] = []
            var reasons: [String?] = []
            let result = await SeedNoteParser.cardsWithOneRewrite(labels: labels, user: names.user) { requested, reason in
                requests.append(requested)
                reasons.append(reason)
                return self.cardsJSON(requested.map { label in
                    var body = self.okCard(label)
                    if label == "m2" { body["fact_domain"] = nil }
                    return body
                })
            }
            XCTAssertEqual(requests, hasGoodCard ? [labels, ["m2"]] : [labels, labels, ["m2"]])
            XCTAssertTrue(reasons[1]?.contains("fact_domain") == true)
            XCTAssertEqual(Set(result.cards.keys), hasGoodCard ? ["m1"] : [])
            XCTAssertNil(result.cards["m2"])
            XCTAssertEqual(Set(result.failures.keys), ["m2"])
            XCTAssertTrue(result.failures["m2"]?.contains("缺 fact_domain") == true)
            XCTAssertEqual(result.split, !hasGoodCard)
        }
    }

    func testParserSeparatesCardFailuresFromBatchProblems() throws {
        let missing = try SeedNoteParser.cards(cardsJSON([okCard("m1")]), labels: ["m1", "m2"], user: names.user).get()
        XCTAssertEqual(Set(missing.cards.keys), ["m1"])
        XCTAssertEqual(Set(missing.problems.keys), ["m2"])
        XCTAssertTrue(missing.batchProblems.isEmpty)
        let extra = try SeedNoteParser.cards(cardsJSON([okCard("m1"), okCard("m2"), okCard("m3")]), labels: ["m1", "m2"], user: names.user).get()
        XCTAssertEqual(Set(extra.cards.keys), ["m1", "m2"])
        XCTAssertEqual(extra.batchProblems.count, 1)
        let duplicate = try SeedNoteParser.cards(cardsJSON([okCard("m1"), okCard("m1"), okCard("m2")]), labels: ["m1", "m2"], user: names.user).get()
        XCTAssertEqual(Set(duplicate.cards.keys), ["m2"])
        XCTAssertEqual(Set(duplicate.problems.keys), ["m1"])
        XCTAssertEqual(duplicate.batchProblems.count, 1)
        for first in [okCard("m1"), okCard("m1", gist: "")] {
            for salvaging in [false, true] {
                let repeated = try SeedNoteParser.cards(cardsJSON([first, okCard("m1"), okCard("m1"), okCard("m2")]),
                                                        labels: ["m1", "m2"], user: names.user, salvaging: salvaging).get()
                XCTAssertEqual(Set(repeated.cards.keys), ["m2"])
                XCTAssertEqual(repeated.problems["m1"], ["m1 有两张卡"])
                XCTAssertEqual(repeated.batchProblems, ["m1 有两张卡"])
            }
        }
        for bad in [okCard("m1", group: "朋友"), okCard("m1", gist: ""), okCard("m1", mentions: [["name": "星砚", "group": "主题"]])] {
            let reply = try SeedNoteParser.cards(cardsJSON([bad, okCard("m2")]), labels: ["m1", "m2"], user: names.user).get()
            XCTAssertEqual(Set(reply.cards.keys), ["m2"])
            XCTAssertEqual(Set(reply.problems.keys), ["m1"])
            XCTAssertTrue(reply.batchProblems.isEmpty)
        }
        XCTAssertThrowsError(try SeedNoteParser.cards("不是 JSON", labels: ["m1"], user: names.user).get())
    }

    func testParserRequiresFieldsEvenWhenSalvaging() throws {
        for field in ["title", "gist", "mentions", "about_user", "group", "fact_domain"] {
            for value in [nil, NSNull()] as [Any?] {
                var bad = okCard("m1")
                bad[field] = value
                let reply = try SeedNoteParser.cards(cardsJSON([bad, okCard("m2")]), labels: ["m1", "m2"], user: names.user, salvaging: true).get()
                XCTAssertEqual(Set(reply.cards.keys), ["m2"], field)
                XCTAssertEqual(Set(reply.problems.keys), ["m1"], field)
            }
        }
        let empty = try SeedNoteParser.cards(cardsJSON([okCard("m1", mentions: [], group: "主题", aboutUser: false)]), labels: ["m1"], user: names.user).get()
        XCTAssertEqual(empty.cards["m1"]?.mentions, [])
        XCTAssertEqual(empty.cards["m1"]?.aboutUser, false)
    }

    func testTitleAndMentionsRequireRewriteThenSalvageOnlyRepairableFields() throws {
        for count in [20, 21, 30, 31, 33] {
            let title = String(repeating: "字", count: count)
            let raw = cardsJSON([okCard("m1", title: title)])
            let first = try SeedNoteParser.cards(raw, labels: ["m1"], user: names.user).get()
            XCTAssertEqual(first.cards["m1"]?.title, count <= 20 ? title : nil)
            let salvaged = try SeedNoteParser.cards(raw, labels: ["m1"], user: names.user, salvaging: true).get()
            XCTAssertEqual(salvaged.cards["m1"]?.title, count <= 30 ? title : nil)
            if (21...30).contains(count) {
                XCTAssertEqual(salvaged.softNotes["m1"]?.count, 1)
                XCTAssertTrue(salvaged.softNotes["m1"]?.first?.contains("title \(count) 字（目标 20）") == true)
            } else if count > 30 {
                XCTAssertNotNil(salvaged.problems["m1"])
                XCTAssertNil(salvaged.softNotes["m1"])
            } else {
                XCTAssertTrue(salvaged.softNotes["m1"]?.isEmpty == true)
            }
        }
        for title in ["两行\n标题", "两行\r标题", "两行\u{2028}标题", "\n标题", "  "] {
            let reply = try SeedNoteParser.cards(cardsJSON([okCard("m1", title: title)]), labels: ["m1"], user: names.user, salvaging: true).get()
            XCTAssertNil(reply.cards["m1"])
            XCTAssertNotNil(reply.problems["m1"])
        }
        let ten = (1...10).map { ["name": "星砚\($0)", "group": "人"] }
        let mentions = ten + [["name": "星砚11", "group": "人"]]
        let crowded = cardsJSON([okCard("m1", mentions: mentions)])
        XCTAssertNil(try SeedNoteParser.cards(crowded, labels: ["m1"], user: names.user).get().cards["m1"])
        let trimmed = try SeedNoteParser.cards(crowded, labels: ["m1"], user: names.user, salvaging: true).get()
        XCTAssertEqual(trimmed.cards["m1"]?.mentions.map(\.name), ten.map { $0["name"]! })
        XCTAssertEqual(trimmed.softNotes["m1"]?.count, 1)
        let invalid = cardsJSON([okCard("m1", mentions: [["name": "星砚", "group": "梗"], ["name": "  ", "group": "人"], ["name": "云桥城", "group": "地点"]])])
        let cleaned = try SeedNoteParser.cards(invalid, labels: ["m1"], user: names.user, salvaging: true).get()
        XCTAssertEqual(cleaned.cards["m1"]?.mentions, [.init(name: "云桥城", group: "地点")])
        XCTAssertEqual(cleaned.softNotes["m1"]?.count, 2)
    }

    func testSoftCheckOnlyLogsConnectors() throws {
        let story = "岚舟先去了旧码头，然后遇到星砚，之后一起画画，接着聊了很久，最后约了下周再去"
        let cards = try SeedNoteParser.cards(cardsJSON([okCard("m1", gist: story), okCard("m2")]), labels: ["m1", "m2"], user: names.user).get().cards
        XCTAssertEqual(cards.count, 2, "软检查不打回")
        let notes = SeedNoteParser.softNotes(cards)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].hasPrefix("m1 的 gist 像流水账：连接词 4 处"), notes[0])
        XCTAssertTrue(SeedNoteParser.softNotes(["m1": cards["m2"]!]).isEmpty, "一处以内不记")
    }

    func testOneRewriteWithReasonThenFailed() async {
        var asked: [String?] = []
        let failed: Result<Int, SeedNoteParser.Failure> = await SeedNoteParser.withOneRewrite(ask: { reason in asked.append(reason); return "坏" },
                                                                                               parse: { _ in .failure(.init(message: "缺了 m2")) })
        XCTAssertEqual(asked.count, 2, "只重写一次")
        XCTAssertNil(asked[0])
        XCTAssertEqual(asked[1], "缺了 m2", "重写带原因")
        if case .failure(let f) = failed { XCTAssertEqual(f.message, "重写一次仍不合格：缺了 m2") } else { XCTFail() }

        var n = 0
        let fixed: Result<Int, SeedNoteParser.Failure> = await SeedNoteParser.withOneRewrite(ask: { _ in n += 1; return n == 1 ? "坏" : "好" },
                                                                                              parse: { $0 == "好" ? .success(1) : .failure(.init(message: "x")) })
        XCTAssertEqual(try? fixed.get(), 1)
        let dead: Result<Int, SeedNoteParser.Failure> = await SeedNoteParser.withOneRewrite(ask: { _ in nil }, parse: { _ in .success(1) })
        if case .failure(let f) = dead { XCTAssertEqual(f.message, "请求没有回复") } else { XCTFail() }
    }

    // MARK: - 落盘复用

    func testStoreKeyIsSha256OfPathAndVersionAndReusesSameVersionOnly() throws {
        let store = SeedNoteStore(wiki: wiki)
        let c = card("memory/cc/user_ship.md", version: "v1")
        try store.save(c)
        XCTAssertEqual(store.load(path: c.path, version: "v1"), c)
        XCTAssertNil(store.load(path: c.path, version: "v2"), "版本变了重出")
        XCTAssertNil(store.load(path: c.path, version: ""), "空版本（读不到的）没有卡")
        XCTAssertEqual(SeedNoteStore.key(path: "a", version: "b"), WikiStore.version(of: Data("a|b".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wiki.root.appendingPathComponent(".cards/" + SeedNoteStore.key(path: c.path, version: "v1") + ".json").path))
    }

    func testCardsFolderSurvivesRunsAndProposalsPruning() throws {
        let store = SeedNoteStore(wiki: wiki)
        try store.save(card("m/a.md"))
        let url = store.url(path: "m/a.md", version: "v1")
        let old = t0.addingTimeInterval(-400 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: store.folder.path)
        CatalogRunRecord.prune(wiki: wiki, now: t0)
        _ = WikiProposalStore(wiki: wiki).purgeFinished(now: t0)
        XCTAssertEqual(store.load(path: "m/a.md", version: "v1"), card("m/a.md"), ".cards 不随 .runs / .proposals 的 30 天清理")
    }

    func testOriginalBytesContextAndIdempotentReuseBeforeCardPublication() throws {
        let store = SeedNoteStore(wiki: wiki)
        let c = card("memory/cc/星砚.md")
        let text = " \r\n星砚 e\u{301} 👩🏽‍🚀\n尾部  \n"
        let context = SeedSourceContext(slotPath: "memory/prompt/云桥城", slotName: "云桥城", headingPath: ["星砚"])
        try store.saveOriginal(path: c.path, version: c.version, text: text, sourceContext: context)
        XCTAssertNil(store.load(path: c.path, version: c.version))
        let txt = store.folder.appendingPathComponent(SeedNoteStore.key(path: c.path, version: c.version) + ".txt")
        XCTAssertEqual(try Data(contentsOf: txt), Data(text.utf8))
        let date = Date(timeIntervalSince1970: 1234)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: txt.path)
        try store.saveOriginal(path: c.path, version: c.version, text: text, sourceContext: context)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: txt.path)[.modificationDate] as? Date, date)
        try store.save(c)
        XCTAssertEqual(store.load(path: c.path, version: c.version), c)
        XCTAssertEqual(store.original(path: c.path, version: c.version), .init(text: text, sourceContext: context))
    }

    func testConflictingOriginalNeverOverwritesOrPublishesCard() throws {
        let store = SeedNoteStore(wiki: wiki), c = card("memory/cc/岚舟.md")
        try store.saveOriginal(path: c.path, version: c.version, text: "岚舟原文", sourceContext: nil)
        XCTAssertThrowsError(try store.saveOriginal(path: c.path, version: c.version, text: "另一份", sourceContext: nil)) {
            XCTAssertEqual($0 as? SeedNoteStore.OriginalError, .conflict(c.path))
        }
        XCTAssertNil(store.load(path: c.path, version: c.version))
        XCTAssertEqual(store.original(path: c.path, version: c.version)?.text, "岚舟原文")
    }

    func testJSONFailureLeavesOriginalForNextPublication() throws {
        let store = SeedNoteStore(wiki: wiki), c = card("memory/cc/云桥城.md")
        try store.saveOriginal(path: c.path, version: c.version, text: "星砚在云桥城", sourceContext: nil)
        let json = store.url(path: c.path, version: c.version)
        try FileManager.default.createDirectory(at: json, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(c))
        XCTAssertEqual(store.original(path: c.path, version: c.version)?.text, "星砚在云桥城")
        try FileManager.default.removeItem(at: json)
        try store.saveOriginal(path: c.path, version: c.version, text: "星砚在云桥城", sourceContext: nil)
        try store.save(c)
        XCTAssertEqual(store.load(path: c.path, version: c.version), c)
    }

    func testOriginalRejectsLinkedFileAndLinkedFolder() throws {
        let store = SeedNoteStore(wiki: wiki), c = card("memory/cc/星砚.md")
        let outside = root.appendingPathComponent("outside.txt")
        try Data("不改".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let txt = store.folder.appendingPathComponent(SeedNoteStore.key(path: c.path, version: c.version) + ".txt")
        try FileManager.default.createSymbolicLink(at: txt, withDestinationURL: outside)
        XCTAssertThrowsError(try store.saveOriginal(path: c.path, version: c.version, text: "覆盖", sourceContext: nil))
        XCTAssertNil(store.original(path: c.path, version: c.version))
        XCTAssertEqual(try Data(contentsOf: outside), Data("不改".utf8))
        try FileManager.default.removeItem(at: store.folder)
        try FileManager.default.createSymbolicLink(at: store.folder, withDestinationURL: root)
        XCTAssertThrowsError(try store.saveOriginal(path: c.path, version: c.version, text: "覆盖", sourceContext: nil))
        XCTAssertNil(store.original(path: c.path, version: c.version))
    }

    // MARK: - 聚合

    func testAggregateNormalizesNamesRoutesUserAndVotesGroup() {
        let cards = [
            card("m/1.md", mentions: [("星砚", "人"), ("Lumen", "项目")]),
            card("m/2.md", mentions: [(" 星砚", "人"), ("ＬＵＭＥＮ", "工程")]),
            card("m/3.md", mentions: [("星·砚", "物"), ("lumen ", "工程"), ("岚舟", "人")]),
            card("m/4.md", aboutUser: true, group: "{{user}}"),
            card("m/5.md"),
        ]
        let agg = CatalogSeedNotes.aggregate(cards: cards, names: names)
        XCTAssertEqual(agg.entities.map(\.key), ["星砚", "lumen"])
        XCTAssertEqual(agg.entities[0].display, "星砚")
        XCTAssertEqual(agg.entities[0].aliases, ["星·砚"], "别的原写法留给回扫（去空白后和 display 一样的不算）")
        XCTAssertEqual(agg.entities[1].aliases, ["ＬＵＭＥＮ", "lumen"])
        XCTAssertEqual(CatalogSeedNotes.scanNames(agg.entities[1]), ["Lumen", "ＬＵＭＥＮ", "lumen"])
        XCTAssertEqual(agg.entities[0].paths, ["m/1.md", "m/2.md", "m/3.md"])
        XCTAssertEqual(agg.entities[0].group, "人", "多数票")
        XCTAssertEqual(agg.entities[0].count, 3)
        XCTAssertEqual(agg.entities[1].display, "Lumen")
        XCTAssertEqual(agg.entities[1].group, "工程", "2 票胜 1 票")
        XCTAssertEqual(agg.entities[1].kind, .project, "工程组的类按项目")
        XCTAssertEqual(agg.userPaths, ["m/3.md", "m/4.md"], "mentions 里写了本人名字的 + about_user 的进本人池")
        XCTAssertEqual(agg.loosePaths, ["m/5.md"])

        let tie = CatalogSeedNotes.aggregate(cards: [card("m/1.md", mentions: [("岚", "物")]), card("m/2.md", mentions: [("岚", "人")])], names: names)
        XCTAssertEqual(tie.entities[0].group, "物", "平票按先出现")
    }

    func testIsUserComparesConfiguredNameNotLabelFallback() {
        XCTAssertTrue(CatalogSeedNotes.isUser(" 岚舟 ", names: names))
        XCTAssertFalse(CatalogSeedNotes.isUser("用户", names: names), "没配名字时的「用户」不是本人")
        let unnamed = MemoryExtractor.Names(userName: "", assistantName: "小桥")
        XCTAssertFalse(CatalogSeedNotes.isUser("用户", names: unnamed), "名字为空（Names 回退「用户」）只靠 about_user / 本人锚")
        let agg = CatalogSeedNotes.aggregate(cards: [card("m/1.md", mentions: [("用户", "人")])], names: unnamed)
        XCTAssertEqual(agg.entities.map(\.display), ["用户"])
        XCTAssertEqual(agg.userPaths, [])
        let slash = MemoryExtractor.Names(userName: "人", assistantName: "小桥")
        XCTAssertTrue(CatalogSeedNotes.isUser("人", names: slash), "名字和组同名时 userLabel 回退成「用户」，但实体身份仍按配置名「人」认")
        XCTAssertFalse(CatalogSeedNotes.isUser("用户", names: slash))
    }

    // MARK: - 对齐

    private var baseGroups: [SeedNoteGroup] {
        [SeedNoteGroup(key: "星砚", display: "星砚", group: "人", paths: ["m/1.md"], count: 1),
         SeedNoteGroup(key: "星砚老师", display: "星砚老师", group: "人", paths: ["m/2.md"], count: 1),
         SeedNoteGroup(key: "栖栖", display: "栖栖", group: "人", paths: ["m/3.md"], count: 1),
         SeedNoteGroup(key: "小岚", display: "小岚", group: "人", paths: ["m/4.md"], count: 1)]
    }

    private var anchors: [SeedNoteAnchor] {
        [SeedNoteAnchor.wiki(WikiPage(path: "人/林栖", kind: .person, triggers: ["栖栖"], title: "林栖")), .user]
    }

    func testAlignMergesIntoNameWikiAnchorAndUser() throws {
        let raw = #"{"merge":[{"into":"星砚","names":["星砚老师"]},{"into":"wiki:人/林栖","names":["栖栖"]},{"into":"岚舟","names":["小岚"]}]}"#
        let merges = try SeedNoteParser.merges(raw, user: names.user).get()
        XCTAssertEqual(merges[2].into, "{{user}}", "merge.into 的本人名字按 .notes 还原")
        let aligned = CatalogSeedNotes.align(groups: baseGroups, anchors: anchors, merges: merges)
        XCTAssertEqual(aligned.dropped, [])
        XCTAssertEqual(aligned.groups.map(\.key), ["星砚", "栖栖"])
        XCTAssertEqual(aligned.groups[0].paths, ["m/1.md", "m/2.md"])
        XCTAssertEqual(aligned.groups[0].mergedFrom, ["星砚老师"])
        XCTAssertEqual(aligned.groups[0].count, 2)
        XCTAssertEqual(aligned.groups[1].existingPage, "人/林栖")
        XCTAssertEqual(aligned.groups[1].aliases, ["林栖", "栖栖"])
        XCTAssertEqual(aligned.userPaths, ["m/4.md"], "合进本人锚的原料进本人池")
        XCTAssertEqual(SeedNotePrompts.alignUser(groups: baseGroups, anchors: anchors),
                       "【名字清单】（共 4 个）\n- 星砚 · 人 · 1\n- 星砚老师 · 人 · 1\n- 栖栖 · 人 · 1\n- 小岚 · 人 · 1\n\n【锚】\n- wiki:人/林栖（标题 林栖，触发词 栖栖）\n- {{user}}（本人）")
    }

    func testAlignDropsWholeGroupOnUnknownMemberOrDoubleUseAndKeepsNamesOnFailure() {
        let merges = [SeedNoteParser.Merge(into: "星砚", names: ["星砚老师", "不存在的人"]),
                      SeedNoteParser.Merge(into: "栖栖", names: ["小岚"]),
                      SeedNoteParser.Merge(into: "星砚", names: ["小岚"]),
                      SeedNoteParser.Merge(into: "wiki:人/没这页", names: ["星砚老师"])]
        let aligned = CatalogSeedNotes.align(groups: baseGroups, anchors: anchors, merges: merges)
        XCTAssertEqual(aligned.groups, baseGroups, "成员不在名单整组丢；一个名字两组都丢；into 不在名单丢")
        XCTAssertEqual(aligned.dropped.count, 4)
        XCTAssertTrue(aligned.dropped[0].contains("「不存在的人」不在名单里"))
        XCTAssertTrue(aligned.dropped[1].contains("into「wiki:人/没这页」不在名单里"))
        XCTAssertTrue(aligned.dropped[2].contains("「小岚」同时进了两组") && aligned.dropped[3].contains("「小岚」同时进了两组"))
        XCTAssertEqual(CatalogSeedNotes.align(groups: baseGroups, anchors: anchors, merges: nil).groups, baseGroups, "对齐没成，目录按原名")
        if case .failure = SeedNoteParser.merges("{\"merge\":[{\"into\":1}]}", user: names.user) {} else { XCTFail("坏结构要报出来给重写") }
    }

    // MARK: - 回扫补配（车头追加 (b)）

    func testBackfillAddsMaterialsMentioningAnyNameButSkipsShortAndGroupNames() {
        var groups = [SeedNoteGroup(key: "星砚", display: "星砚", group: "人", paths: ["m/1.md"], mergedFrom: ["星砚老师"], count: 2),
                      SeedNoteGroup(key: "砚", display: "砚", group: "物", paths: ["m/1.md"], count: 1),
                      SeedNoteGroup(key: "地点", display: "地点", group: "地点", paths: ["m/1.md"], count: 1),
                      SeedNoteGroup(key: "栖栖", display: "栖栖", group: "人", paths: [], existingPage: "人/林栖", aliases: ["林栖", "栖栖"], count: 1)]
        let texts = ["m/1.md": "星砚周三来过", "m/2.md": "卡漏提了：星砚老师说周四改期，地点没变", "m/3.md": "砚台上有人名", "m/4.md": "林栖寄来一张明信片", "memory/wiki/人/林栖.md": "林栖本人的页"]
        groups = CatalogSeedNotes.backfill(groups: groups, texts: texts)
        XCTAssertEqual(groups[0].paths, ["m/1.md"], "回扫命中不升级成正式原料")
        XCTAssertEqual(groups[0].candidates, [.init(path: "m/2.md", hits: ["星砚", "星砚老师"])], "合并进来的成员名也回扫，命中的名字都记成证据")
        XCTAssertNil(groups[1].candidates, "一个字符的名字不回扫")
        XCTAssertNil(groups[2].candidates, "等于九组名的不回扫")
        XCTAssertEqual(groups[3].paths, [])
        XCTAssertEqual(groups[3].candidates, [.init(path: "m/4.md", hits: ["林栖"]), .init(path: "memory/wiki/人/林栖.md", hits: ["林栖"])],
                       "锚页标题 / 触发词回扫（传进来的 texts 由调用方限定在出了卡的原料）")
    }

    func testBackfillIgnoresHitsInsideLongerKnownNameAndUsesAliases() {
        let groups = [SeedNoteGroup(key: "小岚", display: "小岚", group: "人", paths: [], count: 1),
                      SeedNoteGroup(key: "小岚舟", display: "小岚舟", group: "人", paths: [], count: 1),
                      SeedNoteGroup(key: "星砚", display: "星砚", group: "人", paths: [], aliases: ["星·砚"], count: 2),
                      SeedNoteGroup(key: "lumen", display: "Lumen", group: "工程", paths: [], count: 1)]
        let texts = ["m/1.md": "小岚舟今天搬家", "m/2.md": "小岚和小岚舟都来了", "m/3.md": "星·砚寄信来", "m/4.md": "Lumens 不是它；lumen 才是", "m/5.md": "Lumenary 里面"]
        let out = CatalogSeedNotes.backfill(groups: groups, texts: texts)
        XCTAssertEqual(out[0].candidates?.map(\.path), ["m/2.md"], "「小岚」在「小岚舟」里的命中不算；单独出现才记")
        XCTAssertEqual(out[1].candidates?.map(\.path), ["m/1.md", "m/2.md"])
        XCTAssertEqual(out[2].candidates, [.init(path: "m/3.md", hits: ["星·砚"])], "别的原写法也能回扫")
        XCTAssertEqual(out[3].candidates?.map(\.path), ["m/4.md", "m/5.md"], "没有别的已知实体名包着它时，字面命中照记（英文单词内部的不消歧，候选的命中证据里看得见）")
        XCTAssertTrue(out.allSatisfy { $0.paths.isEmpty }, "候选都不进正式原料")
    }

    // MARK: - 聚类

    func testClustersDropBadMembersAndPathsAndListUnplaced() throws {
        let user = [card("m/u1.md", title: "作息", gist: "早起"), card("m/u2.md", title: "写生", gist: "周三写生")]
        let loose = [card("m/l1.md", title: "风筝", gist: "纸鸢"), card("m/l2.md", title: "灯", gist: "囤灯")]
        let labels = CatalogSeedNotes.clusterLabels(user: user, loose: loose)
        XCTAssertEqual(labels.user.map(\.label), ["c1", "c2"])
        XCTAssertEqual(labels.loose.map(\.label), ["c3", "c4"])
        let raw = """
        {"user_pages":[{"title":"岚舟的作息","path":"岚舟/作息","members":["c1","c9","c3"]},{"title":"错组","path":"人/作息","members":["c2"]}],
         "topics":[{"title":"纸鸢风筝","path":"主题/纸鸢风筝","members":["c3","c1"]},{"title":"又一页","path":"主题/又一页","members":["c3"]}],"theatre":[],"pending":[]}
        """
        let reply = try SeedNoteParser.clusters(raw, user: names.user).get()
        XCTAssertEqual(reply.userPages[0].path, "{{user}}/作息", "user_pages.path 按 .notes 还原")
        let out = CatalogSeedNotes.clusters(user: user, loose: loose, reply: reply)
        XCTAssertEqual(out.userPages, [SeedNoteCluster(title: "岚舟的作息", path: "{{user}}/作息", paths: ["m/u1.md"], factDomain: .realWorld)])
        XCTAssertEqual(out.topics, [SeedNoteCluster(title: "岚舟的作息", path: "主题/作息", paths: ["m/l1.md"], factDomain: .realWorld)])
        XCTAssertEqual(out.unplaced.map(\.path), ["m/u2.md", "m/l2.md"])
        XCTAssertEqual(out.reassignedPoolCount, 1)
        XCTAssertEqual(out.normalizedPrefixCount, 0)
        XCTAssertTrue(out.dropped.contains { $0.contains("c9") })
        XCTAssertTrue(out.dropped.contains { $0.contains("人/作息") })
        XCTAssertFalse(out.dropped.contains { $0.contains("不是这个池") })
        XCTAssertEqual(out.dropped.count, 5, "\(out.dropped)")

        if case .failure(let f) = SeedNoteParser.clusters("{}", user: names.user) { XCTAssertTrue(f.message.contains("缺少字段"), f.message) } else { XCTFail("两个数组都要有") }
        if case .failure = SeedNoteParser.clusters(#"{"user_pages":[]}"#, user: names.user) {} else { XCTFail("缺 topics 也不合格") }

        let failed = CatalogSeedNotes.clusters(user: user, loose: loose, reply: nil)
        XCTAssertEqual(failed.unplaced.map(\.path), ["m/u1.md", "m/u2.md", "m/l1.md", "m/l2.md"], "聚类没成，两个池整体进没归进目录")
    }

    func testClusterRequestsUseOnlyL0TitleAndGroupInBothRounds() {
        let user = [card("m/u", title: "岚舟雨天难入睡", gist: "不会进入聚类请求的本人要点", aboutUser: true, group: "{{user}}")]
        let loose = [card("m/l", title: "云桥城旧码头写生", gist: "不会进入聚类请求的话题要点", group: "地点")]
        let labels = CatalogSeedNotes.clusterLabels(user: user, loose: loose)
        let first = SeedNotePrompts.clusterUser(user: labels.user, loose: labels.loose)
        let recovery = SeedNotePrompts.clusterRecovery(user: [], loose: labels.loose, existing: .init())
        XCTAssertTrue(first.contains("- c1 · 岚舟雨天难入睡 · {{user}}"))
        XCTAssertTrue(first.contains("- c2 · 云桥城旧码头写生 · 地点"))
        XCTAssertTrue(recovery.contains("- c2 · 云桥城旧码头写生 · 地点"))
        XCTAssertFalse(recovery.contains("- c1 ·"))
        for request in [first, recovery] {
            for c in user + loose {
                XCTAssertFalse(request.contains(c.gist))
                XCTAssertFalse(request.contains(c.path))
            }
        }
    }

    func testFirstRoundRoutesSwappedArraysByMemberPool() {
        let user = (1...3).map { card("m/u\($0)") }
        let loose = (1...3).map { card("m/l\($0)") }
        let result = CatalogSeedNotes.clusters(user: user, loose: loose, reply: .init(
            userPages: [.init(title: "云桥城的写生约定", path: "{{user}}/写生约定", members: ["c4", "c5", "c6"])],
            topics: [.init(title: "岚舟的雨天焦虑", path: "主题/雨天/焦虑", members: ["c1", "c2", "c3"])]))
        XCTAssertEqual(result.userPages, [.init(title: "岚舟的雨天焦虑", path: "{{user}}/雨天/焦虑", paths: user.map(\.path), factDomain: .realWorld)])
        XCTAssertEqual(result.topics, [.init(title: "云桥城的写生约定", path: "主题/写生约定", paths: loose.map(\.path), factDomain: .realWorld)])
        XCTAssertTrue(result.unplaced.isEmpty)
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertEqual(result.reassignedPoolCount, 2)
        XCTAssertEqual(result.normalizedPrefixCount, 0)
    }

    func testMixedPoolEntrySplitsBothPagesWithSameTitleInBothRounds() throws {
        let user = (1...3).map { card("m/u\($0)") }
        let loose = (1...3).map { card("m/l\($0)") }
        let first = CatalogSeedNotes.clusters(user: user, loose: loose, reply: .init(
            userPages: [.init(title: "雨天的写生约定", path: "主题/雨天/写生", members: ["c1", "c4"])], topics: []))
        XCTAssertEqual(first.userPages.map(\.path), ["{{user}}/雨天/写生"])
        XCTAssertEqual(first.topics.map(\.path), ["主题/雨天/写生"])
        XCTAssertEqual(first.normalizedPrefixCount, 1)
        XCTAssertEqual(first.reassignedPoolCount, 1, "跨数组但前缀已经正确也算归位")
        let second = CatalogSeedNotes.clusters(user: user, loose: loose, reply: .init(
            userPages: [.init(title: "雨天的写生约定", path: "主题/雨天/写生", members: ["c2", "c3", "c5", "c6"])], topics: []), existing: first)
        XCTAssertEqual(second.userPages, [.init(title: "雨天的写生约定", path: "{{user}}/雨天/写生", paths: user.map(\.path), factDomain: .realWorld)])
        XCTAssertEqual(second.topics, [.init(title: "雨天的写生约定", path: "主题/雨天/写生", paths: loose.map(\.path), factDomain: .realWorld)])
        XCTAssertEqual(second.normalizedPrefixCount, 2)
        XCTAssertEqual(second.reassignedPoolCount, 2)
        XCTAssertTrue(second.unplaced.isEmpty)
        XCTAssertTrue(second.dropped.isEmpty)
        let final = CatalogSeedNotes.completeClusters(second, user: user, loose: loose)
        let saved = try JSONDecoder().decode(SeedNoteClusters.self, from: JSONEncoder().encode(final))
        XCTAssertEqual(saved, final)
        XCTAssertTrue(CatalogSeedNotes.reusableClusters(saved, user: user, loose: loose))
    }

    func testNeitherRoundNormalizesInvalidPathsOrUnrelatedBranches() {
        let cards = [card("m/1")]
        let paths = ["主题/../焦虑", "主题/焦虑.md", "主题/INDEX", "主题//焦虑", "/主题/焦虑", "人/星砚", "主题"]
        for path in paths {
            for existing in [SeedNoteClusters(), SeedNoteClusters(dropped: ["上轮非法项"])] {
                let result = CatalogSeedNotes.clusters(user: cards, loose: [], reply: .init(
                    userPages: [.init(title: "岚舟的雨天焦虑", path: path, members: ["c1"])], topics: []), existing: existing)
                XCTAssertTrue(result.userPages.isEmpty && result.topics.isEmpty, path)
                XCTAssertEqual(result.unplaced.map(\.path), ["m/1"], path)
                XCTAssertEqual(result.normalizedPrefixCount, 0, path)
                XCTAssertEqual(result.reassignedPoolCount, 0, path)
                XCTAssertEqual(result.copiedTitleCount, 0, path)
                XCTAssertEqual(result.dropped.count, existing.dropped.count + 1, path)
            }
        }
    }

    func testClusterTitlesUsePageNameOnlyForNormalizedMemberCopies() throws {
        let cards = [
            card("m/first", title: "第一张卡不是页名"),
            card("m/second", title: "ＡＢＣ 约定"),
            card("m/outside", title: "没有入页的卡"),
        ]
        for (title, copied) in [("ABC约定", true), ("　Ａ ＢＣ\t约定\n", true),
                                ("ABC约定的变更", false), ("没有入页的卡", false), ("", false)] {
            let result = CatalogSeedNotes.clusters(user: cards, loose: [], reply: .init(userPages: [
                .init(title: title, path: "{{user}}/雨天/写生约定", members: ["c1", "c2"])], topics: []))
            XCTAssertEqual(result.userPages.first?.title, copied || title.isEmpty ? "写生约定" : title)
            XCTAssertEqual(result.userPages.first?.paths, ["m/first", "m/second"])
            XCTAssertEqual(result.copiedTitleCount, copied ? 1 : 0)
            XCTAssertTrue(result.dropped.isEmpty)
            let saved = try JSONDecoder().decode(SeedNoteClusters.self, from: JSONEncoder().encode(result))
            XCTAssertEqual(saved, result)
        }
    }

    func testMixedPoolCopiedTitleFallsBackForBothPages() {
        let result = CatalogSeedNotes.clusters(user: [card("m/user", title: "岚舟准备画具")],
            loose: [card("m/loose", title: "约定周三去码头")], reply: .init(userPages: [], topics: [
                .init(title: "约定周三去码头", path: "{{user}}/雨天写生", members: ["c1", "c2"])]))
        XCTAssertEqual(result.userPages, [.init(title: "雨天写生", path: "{{user}}/雨天写生", paths: ["m/user"], factDomain: .realWorld)])
        XCTAssertEqual(result.topics, [.init(title: "雨天写生", path: "主题/雨天写生", paths: ["m/loose"], factDomain: .realWorld)])
        XCTAssertEqual(result.copiedTitleCount, 2)
        XCTAssertEqual(result.normalizedPrefixCount, 1)
        XCTAssertEqual(result.reassignedPoolCount, 1)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testClustersWithoutCorrectionFieldsCanResume() throws {
        let raw = #"{"userPages":[{"title":"雨天写生","path":"{{user}}/雨天写生","paths":["m/1"]}],"topics":[],"unplaced":[],"dropped":[]}"#
        let saved = try JSONDecoder().decode(SeedNoteClusters.self, from: Data(raw.utf8))
        let result = CatalogSeedNotes.clusters(user: [card("m/1"), card("m/2")], loose: [], reply: .init(userPages: [
            .init(title: "雨天写生", path: "{{user}}/雨天写生", members: ["c2"])], topics: []), existing: saved)
        XCTAssertEqual(result.userPages.first?.paths, ["m/1", "m/2"])
        XCTAssertTrue(result.unplaced.isEmpty)
        XCTAssertEqual(result.normalizedPrefixCount, 0)
        XCTAssertEqual(result.reassignedPoolCount, 0)
        XCTAssertEqual(result.copiedTitleCount, 0)
    }

    func testSameEntryDuplicatesAreNotReportedAsCrossPageConflicts() {
        let cards = [card("m/1"), card("m/2")]
        let out = CatalogSeedNotes.clusters(user: cards, loose: [], reply: .init(userPages: [
            .init(title: "岚舟的雨天焦虑", path: "{{user}}/雨天焦虑", members: ["c1", "c1"]),
            .init(title: "岚舟的雨天焦虑", path: "{{user}}/雨天焦虑", members: ["c1", "c2"]),
            .init(title: "岚舟的入睡习惯", path: "{{user}}/入睡习惯", members: ["c1"])], topics: []))
        XCTAssertEqual(out.userPages.count, 1)
        XCTAssertEqual(out.userPages.first?.paths, cards.map(\.path))
        XCTAssertEqual(out.dropped, [
            "user_pages「{{user}}/雨天焦虑」：c1 在本条重复，已去重",
            "user_pages「{{user}}/雨天焦虑」：c1 已在本页",
            "user_pages「{{user}}/入睡习惯」：c1 已经分到别页"])
        XCTAssertTrue(out.unplaced.isEmpty)
    }

    func testTwoThinPagesCanMergeIntoOneFourCardPageInEitherPool() {
        let cards = (1...4).map { card("m/\($0)") }
        for userPool in [true, false] {
            let user = userPool ? cards : []
            let loose = userPool ? [] : cards
            let branch = userPool ? "{{user}}" : "主题"
            let entries: [SeedNoteParser.ClusterEntry] = [
                .init(title: "岚舟的雨天焦虑", path: branch + "/雨天焦虑", members: ["c1", "c2"]),
                .init(title: "岚舟的入睡习惯", path: branch + "/入睡习惯", members: ["c3", "c4"])]
            let first = CatalogSeedNotes.clusters(user: user, loose: loose, reply: .init(
                userPages: userPool ? entries : [], topics: userPool ? [] : entries))
            let reopened = CatalogSeedNotes.reopenThinClusters(first, user: user, loose: loose)
            XCTAssertTrue(reopened.userPages.isEmpty && reopened.topics.isEmpty)
            XCTAssertEqual(reopened.unplaced.map(\.path), cards.map(\.path))
            let merged = SeedNoteParser.ClusterEntry(title: "岚舟雨天的入睡困扰", path: branch + "/雨天入睡", members: ["c1", "c2", "c3", "c4"])
            let second = CatalogSeedNotes.clusters(user: user, loose: loose, reply: .init(
                userPages: userPool ? [merged] : [], topics: userPool ? [] : [merged]), existing: reopened)
            let final = CatalogSeedNotes.completeClusters(second, user: user, loose: loose)
            XCTAssertEqual((final.userPages + final.topics).map(\.paths), [cards.map(\.path)])
            XCTAssertEqual((final.userPages + final.topics).map(\.path), [branch + "/雨天入睡"])
            XCTAssertTrue(CatalogSeedNotes.reusableClusters(final, user: user, loose: loose))
        }
    }

    func testClusterTitleLengthIsSoftOnlyAfterRewriteAndOtherTitleErrorsStillFail() async throws {
        for count in [20, 21, 30, 31, 33] {
            let title = String(repeating: "舟", count: count)
            let raw = #"{"user_pages":[{"title":"\#(title)","path":"{{user}}/作息","members":["c1"]}],"topics":[{"title":"\#(title)","path":"主题/写生","members":["c2"]}],"theatre":[],"pending":[]}"#
            if count <= 20 {
                XCTAssertEqual(try SeedNoteParser.clusters(raw, user: names.user).get().userPages[0].title, title)
            } else {
                XCTAssertThrowsError(try SeedNoteParser.clusters(raw, user: names.user).get())
            }
            var asked = 0
            let result = await SeedNoteParser.withOneRewrite(ask: { _ in asked += 1; return raw },
                                                           parse: { SeedNoteParser.clusters($0, user: self.names.user) },
                                                           salvage: { SeedNoteParser.clusters($0, user: self.names.user, salvaging: true) })
            XCTAssertEqual(asked, count <= 20 ? 1 : 2)
            if count <= 30 {
                let reply = try result.get()
                XCTAssertEqual(reply.userPages[0].title, title)
                XCTAssertEqual(reply.topics[0].title, title)
                XCTAssertEqual(reply.softNotes.count, count <= 20 ? 0 : 2)
                for note in reply.softNotes {
                    XCTAssertTrue(note.contains("title \(count) 字（目标 20）"))
                }
            } else {
                XCTAssertThrowsError(try result.get())
            }
        }
        for title in ["", "两行\n标题", "两行\r标题", "两行\u{2028}标题"] {
            let data = try JSONSerialization.data(withJSONObject: ["user_pages": [["title": title, "path": "{{user}}/作息", "members": ["c1"]]], "topics": [], "theatre": [], "pending": []])
            XCTAssertThrowsError(try SeedNoteParser.clusters(String(decoding: data, as: UTF8.self), user: names.user, salvaging: true).get())
        }
        for value in [nil, NSNull()] as [Any?] {
            var entry: [String: Any] = ["path": "{{user}}/作息", "members": ["c1"]]
            entry["title"] = value
            let data = try JSONSerialization.data(withJSONObject: ["user_pages": [entry], "topics": [], "theatre": [], "pending": []])
            XCTAssertThrowsError(try SeedNoteParser.clusters(String(decoding: data, as: UTF8.self), user: names.user, salvaging: true).get())
        }
    }

    func testBatchRewriteKeepsAcceptedCardsEvenIfRewriteHasNoReply() async throws {
        let first = cardsJSON([okCard("m1"), okCard("m2", gist: "")])
        var requests: [[String]] = []
        let result = await SeedNoteParser.cardsWithOneRewrite(labels: ["m1", "m2"], user: names.user) { labels, _ in
            requests.append(labels)
            return requests.count == 1 ? first : nil
        }
        XCTAssertEqual(requests, [["m1", "m2"], ["m2"]])
        XCTAssertEqual(Set(result.cards.keys), ["m1"])
        XCTAssertEqual(Set(result.failures.keys), ["m2"])
    }

    func testBatchProblemsRetryWholeBatchWithoutReplacingAcceptedCards() async throws {
        let labels = ["m1", "m2"]
        let cases = [("不是 JSON", false), (cardsJSON([]), false),
                     (cardsJSON([okCard("m1"), okCard("m2"), okCard("m3")]), true),
                     (cardsJSON([okCard("m1"), okCard("m2"), okCard("m2")]), true)]
        for (first, hadAcceptedCard) in cases {
            var requested: [[String]] = []
            let second = cardsJSON([okCard("m1", title: "改写的标题"), okCard("m2")])
            let result = await SeedNoteParser.cardsWithOneRewrite(labels: labels, user: names.user) { labels, _ in
                requested.append(labels)
                return requested.count == 1 ? first : second
            }
            XCTAssertEqual(requested, [labels, labels])
            XCTAssertEqual(Set(result.cards.keys), Set(labels))
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(result.cards["m1"]?.title, hadAcceptedCard ? "岚舟陪星砚写生" : "改写的标题")
        }
    }

    func testZeroCardsAfterRewriteSplitsOnceAndRecoversOnlyValidSingletons() async throws {
        let labels = ["m1", "m2", "m3"]
        let refusal = String(repeating: "原文", count: 80) + "不可保留的尾部"
        var requests: [[String]] = []
        var reasons: [String?] = []
        let result = await SeedNoteParser.cardsWithOneRewrite(labels: labels, user: names.user) { requested, reason in
            requests.append(requested)
            reasons.append(reason)
            if requests.count <= 2 { return "不是 JSON" }
            return requested == ["m2"] ? self.cardsJSON([self.okCard("m2")]) : refusal
        }
        XCTAssertEqual(requests, [labels, labels, ["m1"], ["m2"], ["m3"]])
        XCTAssertNil(reasons[0])
        XCTAssertNotNil(reasons[1])
        XCTAssertTrue(reasons.dropFirst(2).allSatisfy { $0 == nil })
        XCTAssertTrue(result.split)
        XCTAssertEqual(Set(result.cards.keys), ["m2"])
        XCTAssertEqual(Set(result.failures.keys), ["m1", "m3"])
        for failure in result.failures.values {
            XCTAssertTrue(failure.hasPrefix(String(refusal.prefix(120))))
            XCTAssertFalse(failure.contains("不可保留的尾部"))
        }
    }

    func testAnyAcceptedCardPreventsBatchSplitting() async {
        for recoveredOnRewrite in [false, true] {
            var requests: [[String]] = []
            let good = cardsJSON([okCard("m1")])
            let result = await SeedNoteParser.cardsWithOneRewrite(labels: ["m1", "m2"], user: names.user) { requested, _ in
                requests.append(requested)
                return requests.count == (recoveredOnRewrite ? 2 : 1) ? good : "不是 JSON"
            }
            XCTAssertFalse(result.split)
            XCTAssertEqual(Set(result.cards.keys), ["m1"])
            XCTAssertEqual(Set(result.failures.keys), ["m2"])
            XCTAssertEqual(requests, [["m1", "m2"], recoveredOnRewrite ? ["m1", "m2"] : ["m2"]])
        }
    }

    // MARK: - 目录（车头追加 (a) 来源定位进 reason，不带要点原文）

    func testOutlineSourcesExactSortedMergedByPathWithoutLeakingGists() throws {
        let cards = [card("m/2.md", title: "改期", gist: "周四", name: "002.md"),
                     card("m/1.md", title: "写生", gist: "周三", name: "001.md"),
                     card("m/3.md", title: "明信片", gist: "寄信", name: "003.md"),
                     card("m/4.md", title: "作息", gist: "早起", name: "004.md"),
                     card("m/5.md", title: "来信", gist: "问候", name: "005.md")]
        let groups = [SeedNoteGroup(key: "星砚", display: "星砚", group: "人", paths: ["m/3.md", "m/2.md", "m/1.md"], mergedFrom: ["星砚老师"],
                                    candidates: [.init(path: "m/4.md", hits: ["星砚"]), .init(path: "m/1.md", hits: ["星砚"]), .init(path: "m/5.md", hits: ["星砚老师"])], count: 3),
                      SeedNoteGroup(key: "栖栖", display: "栖栖", group: "人", paths: ["m/3.md"], existingPage: "人/林栖", aliases: ["林栖", "栖栖"], count: 1)]
        _ = try wiki.save(WikiPage(path: "人/林栖", kind: .person, triggers: ["栖栖"], title: "林栖", factDomain: .realWorld), now: t0)
        let clusters = SeedNoteClusters(userPages: [.init(title: "岚舟的作息", path: "{{user}}/作息", paths: ["m/4.md"])],
                                        topics: [.init(title: "星砚", path: "人/星砚", paths: ["m/4.md"])])
        let t = task(read: Dictionary(uniqueKeysWithValues: cards.map { ($0.path, $0.version) }))
        let out = CatalogSeedNotes.outline(groups: groups, clusters: clusters, cards: cards, names: names, task: t, wiki: wiki)
        XCTAssertEqual(out.dropped, [])
        let items = out.items.compactMap { $0.change.direction }
        XCTAssertEqual(items.map(\.path), ["人/星砚", "{{user}}/作息", "人/林栖"])
        let xy = items[0]
        XCTAssertEqual(xy.sources, ["m/1.md", "m/2.md", "m/3.md", "m/4.md"], "同路径实体与聚类合并，正式原料精确且升序")
        XCTAssertEqual(xy.title, "星砚")
        XCTAssertEqual(xy.kind, .person)
        XCTAssertEqual(xy.action, .newPage)
        XCTAssertEqual(xy.hook, "")
        XCTAssertEqual(xy.mode, .seed)
        XCTAssertTrue(xy.reason.contains("合并自：星砚老师 · 3 份原料"))
        XCTAssertTrue(xy.reason.contains("- 001.md · 写生\n- 002.md · 改期\n- 003.md · 明信片"))
        XCTAssertEqual(xy.candidates, [.init(path: "m/5.md", hits: ["星砚老师"], label: "005.md · 来信", factDomain: .realWorld)], "正式原料不重复算候选，保留候选的命中与卡标题")
        XCTAssertTrue(xy.reason.contains("回扫候选 1 份"))
        XCTAssertTrue(xy.reason.hasSuffix("- 回扫候选 · 005.md · 来信"))
        XCTAssertEqual(items[2].action, .update, "wiki 锚一份原料仍更新")
        XCTAssertEqual(items[2].title, "林栖")
        XCTAssertEqual(items[2].sources, ["m/3.md"])
        XCTAssertEqual(items[1].kind, .user)
        XCTAssertEqual(items[1].reason, "本人 · 1 份原料\n- 004.md · 作息")
        for direction in items {
            for card in cards { XCTAssertFalse(direction.reason.contains(card.gist), "理由不带卡要点原文") }
        }
    }

    func testOutlineDropsUnreadableSourcesAndEmptyIsEmpty() {
        let groups = [SeedNoteGroup(key: "星砚", display: "星砚", group: "人", paths: ["m/7.md", "m/8.md", "m/9.md"], count: 3)]
        let out = CatalogSeedNotes.outline(groups: groups, clusters: SeedNoteClusters(), cards: [card("m/9.md")], names: names, task: task(read: ["m/1.md": "v1"]), wiki: wiki)
        XCTAssertTrue(out.items.isEmpty)
        XCTAssertEqual(out.dropped.count, 1)
        XCTAssertTrue(out.dropped[0].contains("不是这次读过的"))
        XCTAssertEqual(CatalogSeedNotes.outline(groups: [], clusters: SeedNoteClusters(), cards: [], names: names, task: task(read: [:]), wiki: wiki), SeedNoteOutline())
    }

    func testUntitledMaterialsOutlineByCardsOnly() throws {
        let items = [item("memory/import/001.md", "星砚约岚舟写生", name: "001.md"),
                     item("memory/import/002.md", "星砚老师改期", name: "002.md"),
                     item("memory/import/003.md", "星砚又来写生", name: "003.md")]
        let cards = items.enumerated().map { index, it in
            card(it.path, title: "写生", gist: it.text, mentions: [(index == 1 ? "星砚老师" : "星砚", "人")], group: "人", name: it.name, version: it.version)
        }
        let agg = CatalogSeedNotes.aggregate(cards: cards, names: names)
        let aligned = CatalogSeedNotes.align(groups: agg.entities, anchors: [.user], merges: [.init(into: "星砚", names: ["星砚老师"])])
        let t = task(read: Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.version) }))
        let out = CatalogSeedNotes.outline(groups: aligned.groups, clusters: SeedNoteClusters(), cards: cards, names: names, task: t, wiki: wiki)
        let d = try XCTUnwrap(out.items.first?.change.direction)
        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(d.path, "人/星砚")
        XCTAssertEqual(d.sources, items.map(\.path))
        XCTAssertEqual(d.reason, "合并自：星砚老师 · 3 份原料\n- 001.md · 写生\n- 002.md · 写生\n- 003.md · 写生")
    }

    func testEntityPageThresholdCountsOnlyDistinctFormalPaths() {
        let cards = (1...4).map { card("m/\($0).md") }
        let t = task(read: Dictionary(uniqueKeysWithValues: cards.map { ($0.path, $0.version) }))
        for paths in [["m/1.md", "m/2.md"], ["m/1.md", "m/1.md", "m/2.md"], ["m/1.md", "m/2.md", "m/3.md"]] {
            let group = SeedNoteGroup(key: "星砚", display: "星砚", group: "人", paths: paths,
                                      candidates: [.init(path: "m/3.md", hits: ["星砚"]), .init(path: "m/4.md", hits: ["星砚"])], count: 99)
            let out = CatalogSeedNotes.outline(groups: [group], clusters: .init(), cards: cards, names: names, task: t, wiki: wiki)
            XCTAssertEqual(out.items.count, Set(paths).count == 3 ? 1 : 0, "候选、重复 paths 和 count 都不能凑门槛")
            XCTAssertEqual(out.items.first?.change.direction?.sources, Set(paths).count == 3 ? ["m/1.md", "m/2.md", "m/3.md"] : nil)
        }
    }

    func testPromptDirectOpeningIsOnlyForPeopleAndOtherKindsKeepSourceThreshold() {
        for kind in ["人", "物", "工程", "项目", "地点", "事"] {
            var group = SeedNoteGroup(key: "星砚", display: "星砚", group: kind, paths: ["m/1.md"], sourceLayers: ["Prompt"])
            XCTAssertEqual(CatalogSeedNotes.opensEntityPage(group), kind == "人", kind)
            group.paths = ["m/1.md", "m/2.md", "m/3.md"]
            XCTAssertTrue(CatalogSeedNotes.opensEntityPage(group), kind)
            group.paths = ["m/1.md"]
            group.existingPage = kind + "/星砚"
            XCTAssertTrue(CatalogSeedNotes.opensEntityPage(group), "已有页不受 kind 和份数限制")
        }
    }

    func testAlignedEntitiesOpenOnlyAfterThreeDistinctFormalPaths() {
        let cards = (1...3).map { card("m/\($0).md") }
        let t = task(read: Dictionary(uniqueKeysWithValues: cards.map { ($0.path, $0.version) }))
        for extra in ["m/2.md", "m/3.md"] {
            let groups = [SeedNoteGroup(key: "星砚", display: "星砚", group: "人", paths: ["m/1.md", "m/2.md"], count: 2),
                          SeedNoteGroup(key: "老师", display: "老师", group: "人", paths: [extra], count: 1)]
            let aligned = CatalogSeedNotes.align(groups: groups, anchors: [], merges: [.init(into: "星砚", names: ["老师"])])
            let out = CatalogSeedNotes.outline(groups: aligned.groups, clusters: .init(), cards: cards, names: names, task: t, wiki: wiki)
            XCTAssertEqual(out.items.count, extra == "m/3.md" ? 1 : 0)
            XCTAssertEqual(out.items.first?.change.direction?.sources, extra == "m/3.md" ? cards.map(\.path) : nil)
        }
    }

    func testLowThresholdNamesDoNotBecomeOutlineAliases() throws {
        let cards = (1...3).map { card("m/\($0).md") }
        let t = task(read: Dictionary(uniqueKeysWithValues: cards.map { ($0.path, $0.version) }))
        let groups = [SeedNoteGroup(key: "星砚", display: "星砚", group: "人", paths: ["m/1.md"],
                                    mergedFrom: ["老师"], aliases: ["星·砚"], count: 1)]
        let clusters = SeedNoteClusters(topics: [.init(title: "写生", path: "主题/写生", paths: cards.map(\.path))])
        let out = CatalogSeedNotes.outline(groups: groups, clusters: clusters, cards: cards, names: names, task: t, wiki: wiki)
        let direction = try XCTUnwrap(out.items.first?.change.direction)
        XCTAssertEqual(direction.sources, cards.map(\.path))
        XCTAssertTrue(direction.aliases.isEmpty)
    }

    func testRecoveryKeepsLabelsAndMergesMembersOfExistingPath() {
        let user = [card("m/u1"), card("m/u2"), card("m/u3")]
        let loose = [card("m/l1"), card("m/l2"), card("m/l3")]
        let first = CatalogSeedNotes.clusters(user: user, loose: loose, reply: .init(
            userPages: [.init(title: "作息", path: "{{user}}/作息", members: ["c1", "c2"])],
            topics: [.init(title: "写生", path: "主题/写生", members: ["c4", "c5"])]))
        let labels = CatalogSeedNotes.clusterLabels(user: user, loose: loose)
        let missing = Set(first.unplaced.map(\.path))
        let request = SeedNotePrompts.clusterRecovery(user: labels.user.filter { missing.contains($0.card.path) },
                                                     loose: labels.loose.filter { missing.contains($0.card.path) }, existing: first)
        XCTAssertTrue(request.contains("- c3 ·") && request.contains("- c6 ·"))
        XCTAssertFalse(request.contains("- c1 ·") || request.contains("- c2 ·") || request.contains("- c4 ·") || request.contains("- c5 ·"))
        XCTAssertTrue(request.contains("{{user}}/作息") && request.contains("主题/写生"))
        let second = CatalogSeedNotes.clusters(user: user, loose: loose, reply: .init(
            userPages: [.init(title: "作息", path: "{{user}}/作息", members: ["c3"])],
            topics: [.init(title: "写生", path: "主题/写生", members: ["c6"])]), existing: first)
        let final = CatalogSeedNotes.completeClusters(second, user: user, loose: loose)
        XCTAssertEqual(final.userPages.count, 1)
        XCTAssertEqual(Set(final.userPages[0].paths), Set(user.map(\.path)))
        XCTAssertEqual(final.topics.count, 1)
        XCTAssertEqual(Set(final.topics[0].paths), Set(loose.map(\.path)))
        XCTAssertTrue(CatalogSeedNotes.reusableClusters(final, user: user, loose: loose))
        XCTAssertFalse(CatalogSeedNotes.reusableClusters(first, user: user, loose: loose))
    }

    func testRemainingCardsFallBackWithinTheirOwnPoolsAndReasonListsEveryCard() throws {
        let user = [card("m/u1"), card("m/u2")]
        let loose = [card("m/l1"), card("m/l2")]
        let first = CatalogSeedNotes.clusters(user: user, loose: loose, reply: nil)
        let second = CatalogSeedNotes.clusters(user: user, loose: loose, reply: .init(
            userPages: [.init(title: "跨池", path: "{{user}}/错", members: ["c3"])],
            topics: [.init(title: "跨池", path: "主题/错", members: ["c1"])]), existing: first)
        let final = CatalogSeedNotes.completeClusters(second, user: user, loose: loose)
        XCTAssertEqual(final.userPages, [.init(title: "还没归类的", path: "{{user}}/待归类", paths: user.map(\.path), factDomain: .realWorld)])
        XCTAssertEqual(final.topics, [.init(title: "还没归类的", path: "主题/待归类", paths: loose.map(\.path), factDomain: .realWorld)])
        XCTAssertTrue(final.unplaced.isEmpty)
        let cards = user + loose
        let out = CatalogSeedNotes.outline(groups: [], clusters: final, cards: cards, names: names,
                                          task: task(read: Dictionary(uniqueKeysWithValues: cards.map { ($0.path, $0.version) })), wiki: wiki)
        XCTAssertEqual(out.items.count, 2)
        for d in out.items.compactMap(\.change.direction) {
            for path in d.sources ?? [] {
                let c = try XCTUnwrap(cards.first { $0.path == path })
                XCTAssertFalse(d.reason.contains(c.gist), "兜底页理由也不带卡要点原文")
            }
        }
    }

    func testThinPagesOnlyMergeWhenSecondReplyExplicitlyAssignsTheirCards() {
        let cards = (1...4).map { card("m/\($0)") }
        let first = CatalogSeedNotes.clusters(user: cards, loose: [], reply: .init(userPages: [
            .init(title: "作息", path: "{{user}}/作息", members: ["c1", "c2", "c3"]),
            .init(title: "写生", path: "{{user}}/写生", members: ["c4"])], topics: []))
        let reopened = CatalogSeedNotes.reopenThinClusters(first, user: cards, loose: [])
        XCTAssertEqual(reopened.unplaced.map(\.path), ["m/4"])
        XCTAssertEqual(reopened.userPages.map(\.path), ["{{user}}/作息"])
        let assigned = CatalogSeedNotes.clusters(user: cards, loose: [], reply: .init(userPages: [
            .init(title: "作息", path: "{{user}}/作息", members: ["c4"])], topics: []), existing: reopened)
        let merged = CatalogSeedNotes.completeClusters(assigned, user: cards, loose: [])
        XCTAssertEqual(merged.userPages.count, 1)
        XCTAssertEqual(Set(merged.userPages[0].paths), Set(cards.map(\.path)))
        let untouched = CatalogSeedNotes.completeClusters(reopened, user: cards, loose: [])
        XCTAssertEqual(untouched.userPages.first { $0.path == "{{user}}/作息" }?.paths.count, 3)
        XCTAssertEqual(untouched.userPages.first { $0.path == "{{user}}/待归类" }?.paths, ["m/4"], "不按最大页猜归属")
        let topics = CatalogSeedNotes.clusters(user: [], loose: cards, reply: .init(userPages: [], topics: [
            .init(title: "写生", path: "主题/写生", members: ["c1"]),
            .init(title: "写生", path: "主题/写生", members: ["c2", "c3"]),
            .init(title: "纸鸢", path: "主题/纸鸢", members: ["c4"])]))
        XCTAssertEqual(topics.topics.count, 2, "同路径先合成员")
        let topicReopened = CatalogSeedNotes.reopenThinClusters(topics, user: [], loose: cards)
        let second = CatalogSeedNotes.clusters(user: [], loose: cards, reply: .init(userPages: [], topics: [
            .init(title: "写生", path: "主题/写生", members: ["c4"])]), existing: topicReopened)
        XCTAssertEqual(CatalogSeedNotes.completeClusters(second, user: [], loose: cards).topics.count, 1)
        let isolated = CatalogSeedNotes.completeClusters(.init(userPages: [.init(title: "作息", path: "{{user}}/作息", paths: ["m/1"])]), user: [cards[0]], loose: [])
        XCTAssertEqual(isolated.userPages.first?.path, "{{user}}/待归类")
        XCTAssertFalse(CatalogSeedNotes.reusableClusters(first, user: cards, loose: []))
    }

    func testExistingUserAndTopicPageUpdatesAreNotTreatedAsNewThinPages() {
        let user = [card("m/user")], loose = [card("m/topic")]
        let existing: [String: SeedFactDomain?] = ["{{user}}/作息": .realWorld, "主题/纸鸢": .realWorld]
        let assigned = CatalogSeedNotes.clusters(user: user, loose: loose, reply: .init(
            userPages: [.init(title: "作息", path: "{{user}}/作息", members: ["c1"])],
            topics: [.init(title: "纸鸢", path: "主题/纸鸢", members: ["c2"])]))
        let completed = CatalogSeedNotes.completeClusters(assigned, user: user, loose: loose, existingPages: existing)
        XCTAssertEqual(completed.userPages.first?.paths, ["m/user"])
        XCTAssertEqual(completed.topics.first?.paths, ["m/topic"])
        XCTAssertEqual(Set((completed.userPages + completed.topics).map(\.path)), Set(existing.keys))
        XCTAssertTrue(CatalogSeedNotes.reusableClusters(completed, user: user, loose: loose, existingPages: existing))
    }

    func testEffectiveDomainsIsolateSameNamedEntitiesAndIgnoreTheatreAboutUser() {
        let real = card("m/现实", mentions: [("林栖", "人")])
        let theatre = card("m/设定", mentions: [("林栖", "人"), ("岚舟", "人")], aboutUser: true, factDomain: .inWorld)
        let mixed = card("m/混合", aboutUser: true, factDomain: .mixed)
        let unspecified = card("m/不明", factDomain: .unspecified)
        let legacy = card("m/旧卡", mentions: [("林栖", "人")], factDomain: nil)
        var conflict = card("m/上下文冲突", mentions: [("林栖", "人")])
        conflict.sourceContextIssue = .conflict
        let aggregate = CatalogSeedNotes.aggregate(cards: [real, theatre, mixed, unspecified, legacy, conflict], names: names)
        XCTAssertEqual(aggregate.entities.map(\.display), ["林栖"])
        XCTAssertEqual(aggregate.entities.first?.paths, [real.path])
        XCTAssertEqual(aggregate.userPaths, [])
        XCTAssertEqual(aggregate.loosePaths, [])
        XCTAssertEqual(aggregate.theatrePaths, [theatre.path])
        XCTAssertEqual(aggregate.pendingPaths, [mixed.path, unspecified.path, legacy.path, conflict.path])
        XCTAssertEqual(aggregate.legacyDomainCount, 1)
    }

    func testFourArrayReplyRehomesMembersWithinTheirPoolsAndDropsDuplicateClaims() throws {
        let user = [card("m/本人", aboutUser: true)]
        let loose = [card("m/现实主题")]
        let theatre = [card("m/设定", aboutUser: true, factDomain: .inWorld)]
        let pending = [card("m/混合", factDomain: .mixed)]
        let raw = """
        {"user_pages":[{"title":"林栖与造船","path":"{{user}}/造船","members":["c3"]}],
         "topics":[{"title":"岚舟的作息","path":"主题/作息","members":["c1"]}],
         "theatre":[{"title":"云桥城纸鸢","path":"{{user}}/纸鸢","members":["c2"]}],
         "pending":[{"title":"星砚的待判笔记","path":"主题/写生","members":["c4","c3","c99"]}]}
        """
        let reply = try SeedNoteParser.clusters(raw, user: names.user).get()
        let result = CatalogSeedNotes.clusters(user: user, loose: loose, theatre: theatre, pending: pending, reply: reply)
        XCTAssertEqual(result.userPages.first?.paths, user.map(\.path))
        XCTAssertEqual(result.userPages.first?.path, "{{user}}/作息")
        XCTAssertEqual(result.topics.first?.paths, loose.map(\.path))
        XCTAssertEqual(result.topics.first?.path, "主题/纸鸢")
        XCTAssertEqual(result.theatre.first?.paths, theatre.map(\.path))
        XCTAssertEqual(result.theatre.first?.factDomain, .inWorld)
        XCTAssertEqual(result.pending.first?.paths, pending.map(\.path))
        XCTAssertEqual(result.pending.first?.factDomain, .mixed)
        XCTAssertEqual(result.reassignedPoolCount, 3)
        XCTAssertEqual(result.dropped.count, 2)
        XCTAssertTrue(result.unplaced.isEmpty)

        let final = CatalogSeedNotes.completeClusters(result, user: user, loose: loose, theatre: theatre, pending: pending)
        XCTAssertEqual(final.theatre.first?.path, "主题/待归类（设定）")
        XCTAssertEqual(final.pending.first?.path, "主题/待归类（待判）")
        XCTAssertTrue(CatalogSeedNotes.reusableClusters(final, user: user, loose: loose, theatre: theatre, pending: pending))
        XCTAssertFalse(CatalogSeedNotes.reusableClusters(final, user: user, loose: loose, theatre: pending, pending: theatre))
    }

    func testPendingPageDomainIsMixedOnlyWhenEveryEffectiveMemberIsMixed() throws {
        let mixed = [card("m/混合一", factDomain: .mixed), card("m/混合二", factDomain: .mixed), card("m/混合三", factDomain: .mixed)]
        for extra in [[], [card("m/不明", factDomain: .unspecified), card("m/旧卡", factDomain: nil)]] {
            let cards = mixed + extra
            let labels = CatalogSeedNotes.clusterLabels(user: [], loose: [], pending: cards)
            let reply = SeedNoteParser.ClusterReply(userPages: [], topics: [], pending: [
                .init(title: "林栖的待判记录", path: "主题/林栖", members: labels.pending.map(\.label))])
            let partial = CatalogSeedNotes.clusters(user: [], loose: [], pending: cards, reply: reply)
            let final = CatalogSeedNotes.completeClusters(partial, user: [], loose: [], pending: cards)
            let expected: SeedFactDomain = extra.isEmpty ? .mixed : .unspecified
            XCTAssertEqual(final.pending.first?.factDomain, expected)
            let outline = CatalogSeedNotes.outline(groups: [], clusters: final, cards: cards, names: names,
                task: task(read: Dictionary(uniqueKeysWithValues: cards.map { ($0.path, $0.version) })), wiki: wiki)
            XCTAssertEqual(outline.items.first?.change.direction?.factDomain, expected)
            XCTAssertEqual(outline.items.first?.change.direction?.sources, cards.map(\.path).sorted())
        }
    }

    func testCrossDomainPathsRelocateWithoutMergingAndDoNotUpdateUnknownPages() {
        let real = (1...3).map { card("m/现实\($0)") }
        let theatre = (1...3).map { card("m/设定\($0)", factDomain: .inWorld) }
        let pending = (1...3).map { card("m/待判\($0)", factDomain: .unspecified) }
        let labels = CatalogSeedNotes.clusterLabels(user: [], loose: real, theatre: theatre, pending: pending)
        let reply = SeedNoteParser.ClusterReply(userPages: [], topics: [
            .init(title: "林栖与云桥城", path: "主题/云桥城", members: labels.loose.map(\.label))],
            theatre: [.init(title: "设定中的云桥城", path: "主题/云桥城", members: labels.theatre.map(\.label))],
            pending: [.init(title: "待判的云桥城", path: "主题/云桥城", members: labels.pending.map(\.label))])
        let partial = CatalogSeedNotes.clusters(user: [], loose: real, theatre: theatre, pending: pending, reply: reply)
        let final = CatalogSeedNotes.completeClusters(partial, user: [], loose: real, theatre: theatre, pending: pending)
        XCTAssertEqual(final.topics.first?.path, "主题/云桥城")
        XCTAssertEqual(final.theatre.first?.path, "主题/云桥城（设定）")
        XCTAssertEqual(final.pending.first?.path, "主题/云桥城（待判）")
        XCTAssertEqual(final.relocated.count, 2)
        XCTAssertEqual(final.theatre.first?.paths, theatre.map(\.path))
        XCTAssertTrue(final.dropped.isEmpty)

        let existing: [String: SeedFactDomain?] = ["主题/云桥城": nil, "主题/云桥城（设定）": .realWorld]
        let unknown = CatalogSeedNotes.completeClusters(partial, user: [], loose: real, theatre: theatre, pending: pending, existingPages: existing)
        XCTAssertEqual(unknown.topics.first?.path, "主题/云桥城（现实）")
        XCTAssertEqual(unknown.pending.first?.path, "主题/云桥城（待判）")
        XCTAssertFalse(unknown.all.contains { $0.path == "主题/云桥城" })
        XCTAssertEqual(unknown.theatre.first?.path, "主题/云桥城（设定）2")
        XCTAssertEqual(unknown.relocated.count, 3)
        XCTAssertTrue(unknown.all.allSatisfy { WikiStore.isValidPagePath($0.path) })
        XCTAssertTrue(CatalogSeedNotes.reusableClusters(unknown, user: [], loose: real, theatre: theatre, pending: pending, existingPages: existing))

        let sameDomain: [String: SeedFactDomain?] = ["主题/云桥城": .inWorld]
        let one = CatalogSeedNotes.clusters(user: [], loose: [], theatre: [theatre[0]], reply: .init(userPages: [], topics: [],
            theatre: [.init(title: "设定中的云桥城", path: "主题/云桥城", members: ["c1"])]))
        let update = CatalogSeedNotes.completeClusters(one, user: [], loose: [], theatre: [theatre[0]], existingPages: sameDomain)
        XCTAssertEqual(update.theatre.first?.path, "主题/云桥城")
        XCTAssertTrue(update.relocated.isEmpty)
    }

    func testRealFallbackRelocationDoesNotTakePendingFallbackAndRemainsReusable() {
        let user = [card("m/本人", aboutUser: true)]
        let loose = [card("m/现实")]
        let pending = [card("m/待判", factDomain: .unspecified)]
        let existing: [String: SeedFactDomain?] = ["{{user}}/待归类": nil, "主题/待归类": nil]
        let final = CatalogSeedNotes.completeClusters(.init(), user: user, loose: loose, pending: pending, existingPages: existing)
        XCTAssertEqual(final.userPages.first?.path, "{{user}}/待归类（现实）")
        XCTAssertEqual(final.topics.first?.path, "主题/待归类（现实）")
        XCTAssertEqual(final.pending.first?.path, "主题/待归类（待判）")
        XCTAssertTrue(CatalogSeedNotes.reusableClusters(final, user: user, loose: loose, pending: pending, existingPages: existing))
    }

    func testLegacyTwoArrayReplyLeavesNewPoolsToTheirOwnFallbacks() throws {
        let user = (1...3).map { card("m/本人\($0)", aboutUser: true) }
        let theatre = [card("m/设定", factDomain: .inWorld)]
        let pending = [card("m/待判", factDomain: .mixed)]
        let reply = try SeedNoteParser.clusters(
            #"{"user_pages":[{"title":"岚舟的作息","path":"岚舟/作息","members":["c1","c2","c3"]}],"topics":[]}"#,
            user: names.user).get()
        let partial = CatalogSeedNotes.clusters(user: user, loose: [], theatre: theatre, pending: pending, reply: reply)
        let final = CatalogSeedNotes.completeClusters(partial, user: user, loose: [], theatre: theatre, pending: pending)
        XCTAssertEqual(final.userPages.first?.path, "{{user}}/作息")
        XCTAssertEqual(final.userPages.first?.paths, user.map(\.path))
        XCTAssertEqual(final.theatre.first, .init(title: "还没归类的", path: "主题/待归类（设定）", paths: theatre.map(\.path), factDomain: .inWorld))
        XCTAssertEqual(final.pending.first, .init(title: "还没归类的", path: "主题/待归类（待判）", paths: pending.map(\.path), factDomain: .mixed))
    }

    func testNamedPathsInTheatreAndPendingRepliesReturnToMemberPools() throws {
        let theatre = [card("m/设定", factDomain: .inWorld)]
        let pending = [card("m/待判", factDomain: .unspecified)]
        let reply = try SeedNoteParser.clusters(
            #"{"user_pages":[],"topics":[],"theatre":[{"title":"星砚的记录","path":"岚舟/写生","members":["c2"]}],"pending":[{"title":"林栖的造船记录","path":"岚舟/造船","members":["c1"]}]}"#,
            user: names.user).get()
        XCTAssertEqual(reply.theatre.first?.path, "{{user}}/写生")
        XCTAssertEqual(reply.pending.first?.path, "{{user}}/造船")
        let partial = CatalogSeedNotes.clusters(user: [], loose: [], theatre: theatre, pending: pending, reply: reply)
        XCTAssertEqual(partial.theatre.first?.path, "主题/造船")
        XCTAssertEqual(partial.theatre.first?.paths, theatre.map(\.path))
        XCTAssertEqual(partial.pending.first?.path, "主题/写生")
        XCTAssertEqual(partial.pending.first?.paths, pending.map(\.path))
        XCTAssertTrue(partial.userPages.isEmpty)
    }

    func testNewEntitiesRelocatePastLegacyAndOtherDomainPagesButSurveyDoesNot() throws {
        let cards = (1...3).map { card("m/现实\($0)", mentions: [("林栖", "人"), ("云桥城", "地点")]) }
        let groups = CatalogSeedNotes.aggregate(cards: cards, names: names).entities
        try wiki.save(WikiPage(path: "人/林栖", kind: .person, title: "林栖"))
        try wiki.save(WikiPage(path: "人/林栖（现实）", kind: .person, title: "林栖旧页", factDomain: .realWorld))
        try wiki.save(WikiPage(path: "地点/云桥城", kind: .place, title: "云桥城", factDomain: .inWorld))
        let existing: [String: SeedFactDomain?] = ["人/林栖": nil, "人/林栖（现实）": .realWorld, "地点/云桥城": .inWorld]
        let read = Dictionary(uniqueKeysWithValues: cards.map { ($0.path, $0.version) })
        let outline = CatalogSeedNotes.outline(groups: groups, clusters: .init(), cards: cards, names: names,
            task: task(read: read), wiki: wiki, existingPages: existing)
        let directions = outline.items.compactMap(\.change.direction)
        XCTAssertEqual(Set(directions.map(\.path)), ["人/林栖（现实）2", "地点/云桥城（现实）"])
        XCTAssertTrue(directions.allSatisfy { $0.factDomain == .realWorld && $0.action == .newPage && $0.sources == read.keys.sorted() })
        XCTAssertEqual(outline.relocated.count, 2)
        XCTAssertTrue(outline.dropped.isEmpty)
        let survey = CatalogSeedNotes.outline(groups: groups, clusters: .init(), cards: cards, names: names,
            task: task(read: read, entry: .survey), wiki: wiki, existingPages: existing)
        XCTAssertTrue(survey.items.isEmpty)
        XCTAssertTrue(survey.relocated.isEmpty)
        XCTAssertEqual(survey.dropped.count, 2)
    }

    func testLegacyClusterCheckpointRemainsRealWorldAndCannotSupplyNewDomainPools() throws {
        let raw = #"{"userPages":[],"topics":[{"title":"还没归类的","path":"主题/待归类","paths":["m/现实"]}],"unplaced":[],"dropped":[]}"#
        let saved = try JSONDecoder().decode(SeedNoteClusters.self, from: Data(raw.utf8))
        XCTAssertNil(saved.topics.first?.factDomain)
        XCTAssertTrue(saved.theatre.isEmpty && saved.pending.isEmpty && saved.relocated.isEmpty)
        let cards = [card("m/现实")]
        XCTAssertTrue(CatalogSeedNotes.reusableClusters(saved, user: [], loose: cards))
        XCTAssertFalse(CatalogSeedNotes.reusableClusters(saved, user: [], loose: [], theatre: [card("m/现实", factDomain: .inWorld)]))
        let outline = CatalogSeedNotes.outline(groups: [], clusters: saved, cards: cards, names: names,
            task: task(read: ["m/现实": "v1"]), wiki: wiki)
        XCTAssertEqual(outline.items.first?.change.direction?.factDomain, .realWorld)
    }

    func testOutlineDropsUnresolvedCrossDomainPathInsteadOfCombiningSources() {
        let cards = [card("m/现实"), card("m/设定", factDomain: .inWorld)]
        let clusters = SeedNoteClusters(topics: [.init(title: "云桥城", path: "主题/云桥城", paths: ["m/现实"])],
            theatre: [.init(title: "设定云桥城", path: "主题/云桥城", paths: ["m/设定"], factDomain: .inWorld)])
        let outline = CatalogSeedNotes.outline(groups: [], clusters: clusters, cards: cards, names: names,
            task: task(read: ["m/现实": "v1", "m/设定": "v1"]), wiki: wiki)
        XCTAssertEqual(outline.items.first?.change.direction?.sources, ["m/现实"])
        XCTAssertEqual(outline.dropped.count, 1)
        XCTAssertTrue(outline.dropped[0].contains("页域不合"))
    }

    // MARK: - 快照

    private func sampleMaterials() -> CatalogSeedMaterials {
        var materials = CatalogSeedMaterials()
        materials.items = [item("memory/cc/a.md", "甲 正文", name: "a"), item("memory/wiki/人/林栖.md", "林栖页", name: "林栖", layer: "wiki")]
        return materials
    }

    private var snapshotFolder: URL {
        CatalogSeedTaskStore(wiki: wiki).folder(UUID().uuidString).appendingPathComponent(CatalogSeedMaterials.snapshotFolderName, isDirectory: true)
    }

    func testSnapshotWritesManifestAndTextsAndLoadsBack() throws {
        let materials = sampleMaterials()
        let folder = snapshotFolder
        XCTAssertThrowsError(try CatalogSeedMaterials.Snapshot.load(folder: folder)) { XCTAssertEqual($0 as? CatalogSeedMaterials.SnapshotError, .badFolder, "没写过") }
        let written = try materials.snapshot(to: folder)
        let loaded = try CatalogSeedMaterials.Snapshot.load(folder: folder)
        XCTAssertEqual(loaded, written)
        XCTAssertEqual(loaded.entries.map(\.file), ["001.txt", "002.txt"])
        XCTAssertEqual(loaded.entries.map(\.digest), materials.items.map(\.version), "正常时摘要 = 版本")
        XCTAssertEqual(loaded.text("memory/cc/a.md"), "甲 正文")
        XCTAssertEqual(loaded.item("memory/wiki/人/林栖.md"), materials.items[1])
        XCTAssertEqual(try loaded.items(), materials.items)
        XCTAssertEqual(loaded.read, ["memory/cc/a.md": materials.items[0].version, "memory/wiki/人/林栖.md": materials.items[1].version], "task.read 一次填齐")
        XCTAssertEqual(loaded.materials.map(\.path), ["memory/cc/a.md", "memory/wiki/人/林栖.md"])
        XCTAssertNil(loaded.text("memory/cc/没有.md"))
    }

    func testSourceContextSurvivesSnapshotCheckpointAndCardStorage() throws {
        let context = SeedSourceContext(slotPath: "prompt/人设", slotName: "人设", headingPath: ["云桥城", "星砚"])
        var prompt = item("prompt/人设#01", "林栖在云桥城看船", layer: "Prompt")
        prompt.sourceContext = context
        let written = try CatalogSeedMaterials(items: [prompt]).snapshot(to: snapshotFolder)
        let loaded = try CatalogSeedMaterials.Snapshot.load(folder: written.folder)
        XCTAssertEqual(loaded.item(prompt.path), prompt)
        XCTAssertEqual(loaded.entries.first?.sourceContext, context)
        var checkpoint = task(read: written.read, entry: .persona)
        checkpoint.materials = loaded.materials
        try CatalogSeedTaskStore(wiki: wiki).save(checkpoint)
        let restored = try XCTUnwrap(CatalogSeedTaskStore(wiki: wiki).load(checkpoint.id))
        XCTAssertEqual(restored.materials.first?.sourceContext, context)
        XCTAssertNil(restored.snapshotMismatch(loaded))
        var mismatched = loaded
        mismatched.entries[0].sourceContext?.headingPath = ["岚舟"]
        XCTAssertNotNil(restored.snapshotMismatch(mismatched))
        for domain in [SeedFactDomain.realWorld, .inWorld, .mixed, .unspecified] {
            var c = card(prompt.path, version: prompt.version)
            c.layer = "Prompt"
            c.sourceContext = context
            c.factDomain = domain
            try SeedNoteStore(wiki: wiki).save(c)
            XCTAssertEqual(SeedNoteStore(wiki: wiki).load(path: c.path, version: c.version), c)
        }
    }

    func testEffectiveFactDomainTrustsOnlyCardsWithoutContextIssues() {
        for domain in [nil, .realWorld, .inWorld, .mixed, .unspecified] as [SeedFactDomain?] {
            var c = card("prompt/人设#01")
            c.factDomain = domain
            XCTAssertEqual(c.effectiveFactDomain, domain)
            for issue in [SeedNoteCard.ContextIssue.missing, .conflict] {
                c.sourceContextIssue = issue
                XCTAssertNil(c.effectiveFactDomain)
                XCTAssertEqual(c.factDomain, domain)
            }
        }
    }

    func testCardContextIssuesAreExcludedFromEncodedJSON() throws {
        for issue in [SeedNoteCard.ContextIssue.missing, .conflict] {
            var c = card("prompt/人设#01")
            c.sourceContext = .init(slotPath: "prompt/人设", slotName: "人设", headingPath: ["星砚"])
            c.factDomain = .inWorld
            c.sourceContextIssue = issue
            let data = try JSONEncoder().encode(c)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(json["sourceContextIssue"])
            let decoded = try JSONDecoder().decode(SeedNoteCard.self, from: data)
            XCTAssertNil(decoded.sourceContextIssue)
            XCTAssertEqual(decoded.sourceContext, c.sourceContext)
            XCTAssertEqual(decoded.factDomain, c.factDomain)
        }
    }

    func testLegacyManifestCheckpointAndCardRemainUnknownWithoutNewFields() throws {
        let text = "林栖在云桥城看船"
        let digest = WikiStore.version(of: Data(text.utf8))
        let folder = snapshotFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent("001.txt"))
        let manifest = """
        [{"path":"prompt/人设#01","name":"人设","layer":"Prompt","version":"\(digest)","file":"001.txt","digest":"\(digest)"}]
        """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent(CatalogSeedMaterials.manifestFileName))
        let snapshot = try CatalogSeedMaterials.Snapshot.load(folder: folder)
        XCTAssertNil(snapshot.entries.first?.sourceContext)
        XCTAssertNil(snapshot.item("prompt/人设#01")?.sourceContext)
        var old = task(read: snapshot.read, entry: .persona)
        old.materials = snapshot.materials
        try CatalogSeedTaskStore(wiki: wiki).save(old)
        let restored = try XCTUnwrap(CatalogSeedTaskStore(wiki: wiki).load(old.id))
        XCTAssertNil(restored.materials.first?.sourceContext)
        let rawCard = """
        {"path":"prompt/人设#01","version":"\(digest)","name":"人设","layer":"Prompt","title":"林栖看船",
         "gist":"林栖在云桥城看船","mentions":[],"aboutUser":false,"group":"主题","when":[],
         "model":"fake","madeAt":1800000000,"run":{"path":".runs/x.md"}}
        """
        let store = SeedNoteStore(wiki: wiki)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data(rawCard.utf8).write(to: store.url(path: "prompt/人设#01", version: digest))
        let c = try XCTUnwrap(store.load(path: "prompt/人设#01", version: digest))
        XCTAssertNil(c.sourceContext)
        XCTAssertNil(c.factDomain)
        XCTAssertNil(c.sourceContextIssue)
        XCTAssertEqual(c.contextIssue(for: nil), .missing)
        XCTAssertNil(card("memory/cc/林栖.md").contextIssue(for: nil), "CC 没有槽位上下文，不误报")
    }

    func testSnapshotLoadRejectsMissingOrTamperedTextAndNeverOverwritesCompleteOne() throws {
        let materials = sampleMaterials()
        let folder = snapshotFolder
        let stale = try materials.snapshot(to: folder)
        XCTAssertThrowsError(try materials.snapshot(to: folder)) { XCTAssertEqual($0 as? CatalogSeedMaterials.SnapshotError, .exists, "完整快照不覆盖") }

        let first = folder.appendingPathComponent("001.txt")
        try Data("被改过".utf8).write(to: first)
        XCTAssertThrowsError(try CatalogSeedMaterials.Snapshot.load(folder: folder)) { XCTAssertEqual($0 as? CatalogSeedMaterials.SnapshotError, .corruptText("memory/cc/a.md")) }
        XCTAssertNil(stale.text("memory/cc/a.md"), "正文摘要对不上 = 读不到，不把改过的当原版")
        XCTAssertThrowsError(try stale.items()) { XCTAssertEqual($0 as? CatalogSeedMaterials.SnapshotError, .missingText("memory/cc/a.md"), "items 不静默少一份") }

        try FileManager.default.removeItem(at: first)
        XCTAssertThrowsError(try CatalogSeedMaterials.Snapshot.load(folder: folder)) { XCTAssertEqual($0 as? CatalogSeedMaterials.SnapshotError, .missingText("memory/cc/a.md")) }
        XCTAssertFalse(CatalogSeedMaterials.Snapshot.exists(at: folder), "有 manifest 不等于完整")
        try materials.snapshot(to: folder)
        XCTAssertEqual(try CatalogSeedMaterials.Snapshot.load(folder: folder).text("memory/cc/a.md"), "甲 正文", "残缺的能清掉重写")

        try FileManager.default.removeItem(at: folder.appendingPathComponent(CatalogSeedMaterials.manifestFileName))
        XCTAssertThrowsError(try CatalogSeedMaterials.Snapshot.load(folder: folder)) { XCTAssertEqual($0 as? CatalogSeedMaterials.SnapshotError, .missingManifest) }
    }

    func testSnapshotDoesNotFollowSymlinksOrLeaveTheFolder() throws {
        let materials = sampleMaterials()
        let folder = snapshotFolder
        let snap = try materials.snapshot(to: folder)
        // 正文换成指向外面私人文件的链接（内容和原正文一样，摘要也对得上）：仍不读
        let outside = root.appendingPathComponent("private_secret.md")
        try Data("甲 正文".utf8).write(to: outside)
        let first = folder.appendingPathComponent("001.txt")
        try FileManager.default.removeItem(at: first)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: outside)
        XCTAssertThrowsError(try CatalogSeedMaterials.Snapshot.load(folder: folder)) { XCTAssertEqual($0 as? CatalogSeedMaterials.SnapshotError, .missingText("memory/cc/a.md"), "链接不算普通文件") }
        XCTAssertNil(snap.text("memory/cc/a.md"))
        // manifest 里的文件名带路径段 / 点开头：不认
        var escaped = snap.entries
        escaped[0].file = "../private_secret.md"
        XCTAssertNil(CatalogSeedMaterials.Snapshot(folder: folder, entries: escaped).text("memory/cc/a.md"))
        escaped[0].file = ".hidden"
        XCTAssertNil(CatalogSeedMaterials.Snapshot(folder: folder, entries: escaped).text("memory/cc/a.md"))
        // 快照文件夹本身是链接：整个不认
        let link = root.appendingPathComponent("materials-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try CatalogSeedMaterials.Snapshot.load(folder: link)) { XCTAssertEqual($0 as? CatalogSeedMaterials.SnapshotError, .badFolder) }
    }

    /// P1（astra 10-24）：.cards / notes / 快照和它们的祖先（.proposals/<任务>）从 wiki 根起逐级不跟链接，创建 / 删除 / 读 / 写前都查
    func testInternalStoresRefuseSymlinkedFoldersAndAncestors() throws {
        let other = root.appendingPathComponent("other-floor", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let fm = FileManager.default

        // .cards 是指向别的楼层的链接：存不进、读不出
        let cardsLink = wiki.root.appendingPathComponent(SeedNoteStore.folderName)
        try fm.createSymbolicLink(at: cardsLink, withDestinationURL: other)
        let store = SeedNoteStore(wiki: wiki)
        XCTAssertThrowsError(try store.save(card("m/1.md"))) { XCTAssertEqual($0 as? SafeWiki.PathError, .link(".cards")) }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: other.path), [], "一个字都没写到链接那头")
        try Data("{}".utf8).write(to: other.appendingPathComponent(SeedNoteStore.key(path: "m/1.md", version: "v1") + ".json"))
        XCTAssertNil(store.load(path: "m/1.md", version: "v1"))
        try fm.removeItem(at: cardsLink)
        try store.save(card("m/1.md"))
        XCTAssertNotNil(store.load(path: "m/1.md", version: "v1"))
        // 卡文件本身是链接：读不出
        let cardFile = wiki.root.appendingPathComponent(".cards/" + SeedNoteStore.key(path: "m/2.md", version: "v1") + ".json")
        try fm.createSymbolicLink(at: cardFile, withDestinationURL: other.appendingPathComponent(SeedNoteStore.key(path: "m/1.md", version: "v1") + ".json"))
        XCTAssertNil(store.load(path: "m/2.md", version: "v1"))
        XCTAssertThrowsError(try store.save(card("m/2.md")), "目标文件是链接也不写")

        // notes 是链接 / 任务文件夹是链接：对齐结果存不进、读不出，task.json 也一样
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        let id = UUID().uuidString
        try fm.createDirectory(at: tasks.folder(id), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: tasks.notesFolder(id), withDestinationURL: other)
        XCTAssertThrowsError(try tasks.saveNotes(SeedNoteAlignment(groups: []), name: CatalogSeedTaskStore.alignedFileName, id: id))
        try JSONEncoder().encode(SeedNoteAlignment(groups: [])).write(to: other.appendingPathComponent(CatalogSeedTaskStore.alignedFileName))
        XCTAssertNil(tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: id))
        let linkedTask = UUID().uuidString
        try fm.createSymbolicLink(at: tasks.folder(linkedTask), withDestinationURL: other)
        XCTAssertThrowsError(try tasks.saveNotes(SeedNoteAlignment(groups: []), name: CatalogSeedTaskStore.alignedFileName, id: linkedTask))
        XCTAssertThrowsError(try tasks.writeSnapshot(sampleMaterials(), id: linkedTask)) { XCTAssertEqual($0 as? SafeWiki.PathError, .link(".proposals/\(linkedTask)")) }
        XCTAssertFalse(fm.fileExists(atPath: other.appendingPathComponent(CatalogSeedMaterials.snapshotFolderName).path), "祖先是链接：快照一个字都不写")
        var t = task(read: [:])
        t.id = linkedTask
        XCTAssertThrowsError(try tasks.save(t))

        // 快照写在真文件夹里，之后把 materials 换成指向它的链接 / 把 .proposals 换成链接：都读不到，也不清掉链接那头
        let real = UUID().uuidString
        let written = try tasks.writeSnapshot(sampleMaterials(), id: real)
        var realTask = task(read: [:])
        realTask.id = real
        try tasks.save(realTask)
        XCTAssertNotNil(tasks.load(real))
        XCTAssertEqual(try tasks.loadSnapshot(real), written)
        let moved = other.appendingPathComponent("moved-materials", isDirectory: true)
        try fm.moveItem(at: tasks.materialsFolder(real), to: moved)
        try fm.createSymbolicLink(at: tasks.materialsFolder(real), withDestinationURL: moved)
        XCTAssertThrowsError(try tasks.loadSnapshot(real)) { XCTAssertEqual($0 as? CatalogSeedMaterials.SnapshotError, .badFolder) }
        XCTAssertNil(written.text("memory/cc/a.md"), "已拿到手的快照读正文前也逐级查")
        XCTAssertThrowsError(try tasks.writeSnapshot(sampleMaterials(), id: real), "快照目录是链接：不清不写")
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent(CatalogSeedMaterials.manifestFileName).path), "链接那头原样")

        let proposals = wiki.root.appendingPathComponent(WikiStore.proposalsFolder)
        let movedProposals = other.appendingPathComponent("moved-proposals", isDirectory: true)
        try fm.moveItem(at: proposals, to: movedProposals)
        try fm.createSymbolicLink(at: proposals, withDestinationURL: movedProposals)
        XCTAssertNil(tasks.load(real), ".proposals 是链接：任务读不到")
        tasks.remove(real)
        XCTAssertTrue(fm.fileExists(atPath: movedProposals.appendingPathComponent(real).path), ".proposals 是链接：删任务不删到链接那头")
    }

    func testCheckDirectionKeepsOnlyReadableCandidatesThatAreNotSources() {
        let t = task(read: ["m/1.md": "v1", "m/2.md": "v1"])
        var d = WikiProposal.Direction(path: "人/星砚", title: "星砚", kind: .person, action: .newPage, reason: "", mode: .seed, sources: ["m/1.md"])
        d.candidates = [.init(path: "m/1.md", hits: ["星砚"]), .init(path: "m/2.md", hits: ["星砚"]), .init(path: "m/9.md", hits: ["星砚"])]
        guard case .success(let checked) = CatalogSeedTools.checkDirection(d, task: t, wiki: wiki) else { return XCTFail() }
        XCTAssertEqual(checked.candidates, [.init(path: "m/2.md", hits: ["星砚"])], "没读过的 / 已是正式原料的候选去掉，不打回这一项")
        d.candidates = [.init(path: "m/9.md", hits: ["星砚"])]
        guard case .success(let none) = CatalogSeedTools.checkDirection(d, task: t, wiki: wiki) else { return XCTFail() }
        XCTAssertNil(none.candidates)
    }

    /// 😷 真机回归（10-24）：楼层在 /private/var/… 下、任务文件夹还没建时快照写不进。根上方的系统链接（/var → /private/var、自建的上层链接）
    /// 两边按同一口径规范化，写快照 / 卡 / notes / 任务 / 提案 / 完成标记都得成；根以下有链接仍拒
    func testStoresWorkWhenWikiRootIsReachedThroughLinksAboveTheFloor() throws {
        let fm = FileManager.default
        guard let resolved = realpath(root.path, nil) else { return XCTFail("realpath") }
        let canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        XCTAssertNotEqual(canonical.path, root.path, "mac 临时目录 /var/folders 本身就经过 /var → /private/var 这条系统链接")
        let real = root.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let up = root.appendingPathComponent("up")
        try fm.createSymbolicLink(at: up, withDestinationURL: real)
        let roots = [
            canonical.appendingPathComponent("floor-private/memory/wiki", isDirectory: true),   // /private/var/… 写法（同真机）
            root.appendingPathComponent("floor-var/memory/wiki", isDirectory: true),              // /var/… 写法
            up.appendingPathComponent("floor-up/memory/wiki", isDirectory: true),                 // 楼层目录上方有一层自建链接
        ]
        for wikiRoot in roots {
            // 根先在、任务文件夹还没建：正是真机出错的那个状态
            try fm.createDirectory(at: wikiRoot, withIntermediateDirectories: true)
            let w = WikiStore(root: wikiRoot)
            let tasks = CatalogSeedTaskStore(wiki: w)
            let id = UUID().uuidString
            let written = try tasks.writeSnapshot(sampleMaterials(), id: id)
            XCTAssertEqual(try tasks.loadSnapshot(id).text("memory/cc/a.md"), "甲 正文", wikiRoot.path)
            XCTAssertEqual(written.text("memory/cc/a.md"), "甲 正文")
            var t = task(read: [:])
            t.id = id
            try tasks.save(t)
            XCTAssertNotNil(tasks.load(id), wikiRoot.path)
            try tasks.saveNotes(SeedNoteAlignment(groups: []), name: CatalogSeedTaskStore.alignedFileName, id: id)
            XCTAssertNotNil(tasks.loadNotes(SeedNoteAlignment.self, name: CatalogSeedTaskStore.alignedFileName, id: id))
            let cards = SeedNoteStore(wiki: w)
            try cards.save(card("m/1.md"))
            XCTAssertNotNil(cards.load(path: "m/1.md", version: "v1"), wikiRoot.path)
            let proposals = WikiProposalStore(wiki: w)
            var outline = WikiProposal(id: id, origin: .seed, createdAt: t0, items: [])
            outline.seedTask = id
            try proposals.save(outline)
            XCTAssertEqual(proposals.load(id)?.id, id, wikiRoot.path)
            XCTAssertEqual(proposals.list().map(\.id), [id])
            try CatalogSeed.finish(wiki: w, at: t0, taskId: id)
            XCTAssertEqual(CatalogSeed.completion(wiki: w)?.taskId, id, wikiRoot.path)
            // 根以下有链接：照样拒
            let elsewhere = root.appendingPathComponent("elsewhere-\(UUID().uuidString.prefix(4))", isDirectory: true)
            try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try fm.removeItem(at: wikiRoot.appendingPathComponent(SeedNoteStore.folderName))
            try fm.createSymbolicLink(at: wikiRoot.appendingPathComponent(SeedNoteStore.folderName), withDestinationURL: elsewhere)
            XCTAssertThrowsError(try cards.save(card("m/2.md"))) { XCTAssertEqual($0 as? SafeWiki.PathError, .link(".cards"), wikiRoot.path) }
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: elsewhere.path), [])
        }
    }

    /// astra 二审 P1：wiki 根本身（或楼层目录）是指向别层的链接 → 卡 / 任务 / 快照 / 提案 / 完成标记一律拒，删也不删到那头
    func testWikiRootOrFloorThatIsALinkIsRefusedEverywhere() throws {
        let fm = FileManager.default
        // 另一层楼，里面有一份真提案、一个任务、完成标记
        let otherWiki = WikiStore(root: root.appendingPathComponent("other/memory/wiki", isDirectory: true))
        let id = UUID().uuidString
        var t = task(read: [:])
        t.id = id
        try CatalogSeedTaskStore(wiki: otherWiki).save(t)
        var outline = WikiProposal(id: id, origin: .seed, createdAt: t0, items: [])
        outline.seedTask = id
        try WikiProposalStore(wiki: otherWiki).save(outline)
        try CatalogSeed.finish(wiki: otherWiki, at: t0, taskId: id)

        func assertRefused(_ w: WikiStore, _ what: String) {
            let tasks = CatalogSeedTaskStore(wiki: w)
            let proposals = WikiProposalStore(wiki: w)
            XCTAssertNil(tasks.load(id), what)
            XCTAssertTrue(tasks.all().isEmpty, what)
            XCTAssertNil(proposals.load(id), what)
            XCTAssertTrue(proposals.list().isEmpty, what)
            XCTAssertNil(CatalogSeed.completion(wiki: w), what)
            XCTAssertNil(CatalogSeed.stateData(wiki: w), what)
            XCTAssertThrowsError(try SeedNoteStore(wiki: w).save(card("m/1.md")), what)
            XCTAssertThrowsError(try tasks.writeSnapshot(sampleMaterials(), id: UUID().uuidString), what)
            XCTAssertThrowsError(try proposals.save(outline), what)
            XCTAssertThrowsError(try CatalogSeed.restoreState(wiki: w, data: nil), what)
            proposals.remove(id)
            tasks.remove(id)
            XCTAssertEqual(proposals.purgeFinished(now: t0.addingTimeInterval(400 * 86_400)), 0, what)
            XCTAssertNotNil(WikiProposalStore(wiki: otherWiki).load(id), "\(what)：另一层的提案原样")
            XCTAssertNotNil(CatalogSeedTaskStore(wiki: otherWiki).load(id), "\(what)：另一层的任务原样")
            XCTAssertNotNil(CatalogSeed.completion(wiki: otherWiki), "\(what)：另一层的完成标记原样")
        }

        // wiki 根本身是链接
        let floor = root.appendingPathComponent("mine/memory", isDirectory: true)
        try fm.createDirectory(at: floor, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: floor.appendingPathComponent("wiki"), withDestinationURL: otherWiki.root)
        assertRefused(WikiStore(root: floor.appendingPathComponent("wiki", isDirectory: true)), "wiki 根是链接")
        // 楼层目录是链接
        try fm.createDirectory(at: root.appendingPathComponent("mine2"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("mine2/memory"), withDestinationURL: otherWiki.root.deletingLastPathComponent())
        assertRefused(WikiStore(root: root.appendingPathComponent("mine2/memory/wiki", isDirectory: true)), "楼层目录是链接")
    }

    /// astra 二审 P1：.proposals 或其中的任务文件夹是链接 → 提案看不见、写不进、清理不删到那头
    func testProposalStoreSkipsLinkedProposalsFolderAndTaskFolders() throws {
        let fm = FileManager.default
        let otherWiki = WikiStore(root: root.appendingPathComponent("other/memory/wiki", isDirectory: true))
        let id = UUID().uuidString
        var outline = WikiProposal(id: id, origin: .seed, createdAt: t0, items: [])
        outline.seedTask = id
        outline.finishedAt = t0
        try WikiProposalStore(wiki: otherWiki).save(outline)
        let daily = WikiProposal(origin: .manual, createdAt: t0, items: [])
        try WikiProposalStore(wiki: otherWiki).save(daily)

        // 任务文件夹是链接（.proposals 是真的）
        let proposals = WikiProposalStore(wiki: wiki)
        try fm.createDirectory(at: proposals.folder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: proposals.folder.appendingPathComponent(id), withDestinationURL: WikiProposalStore(wiki: otherWiki).folder.appendingPathComponent(id))
        XCTAssertNil(proposals.load(id))
        XCTAssertTrue(proposals.list().isEmpty)
        XCTAssertThrowsError(try proposals.save(outline))
        // 顶层提案文件是链接
        try fm.createSymbolicLink(at: proposals.folder.appendingPathComponent(daily.id + ".json"),
                                  withDestinationURL: WikiProposalStore(wiki: otherWiki).folder.appendingPathComponent(daily.id + ".json"))
        XCTAssertNil(proposals.load(daily.id))
        XCTAssertTrue(proposals.list().isEmpty)
        proposals.remove(daily.id)
        XCTAssertEqual(proposals.purgeFinished(now: t0.addingTimeInterval(400 * 86_400)), 0)
        // .proposals 本身是链接
        try fm.removeItem(at: proposals.folder)
        try fm.createSymbolicLink(at: proposals.folder, withDestinationURL: WikiProposalStore(wiki: otherWiki).folder)
        XCTAssertTrue(proposals.list().isEmpty)
        XCTAssertNil(proposals.load(daily.id))
        proposals.remove(daily.id)
        XCTAssertEqual(proposals.purgeFinished(now: t0.addingTimeInterval(400 * 86_400)), 0)
        XCTAssertEqual(Set(WikiProposalStore(wiki: otherWiki).list().map(\.id)), [id, daily.id], "另一层的提案一份没少")
    }

    /// astra 二审 P3：编辑后候选进了正式原料 / 候选读不到 → 理由里的计数和说明跟着最终那份走
    func testCandidateNoteFollowsFinalCandidatesAfterEdits() {
        let t = task(read: ["m/1.md": "v1", "m/2.md": "v1", "m/3.md": "v1"])
        var d = WikiProposal.Direction(path: "人/星砚", title: "星砚", kind: .person, action: .newPage,
                                       reason: "1 份原料 · 回扫候选 2 份\n- 001.md · 周三写生：岚舟陪星砚写生\n- 回扫候选 · 002.md · 改期（命中：星砚）\n- 回扫候选 · 003.md · 明信片（命中：星砚老师）",
                                       mode: .seed, sources: ["m/1.md", "m/2.md"])
        d.candidates = [.init(path: "m/2.md", hits: ["星砚"], label: "002.md · 改期"), .init(path: "m/3.md", hits: ["星砚老师"], label: "003.md · 明信片")]
        guard case .success(let checked) = CatalogSeedTools.checkDirection(d, task: t, wiki: wiki) else { return XCTFail() }
        XCTAssertEqual(checked.candidates?.map(\.path), ["m/3.md"], "002 进了正式原料：不再列作候选")
        XCTAssertEqual(checked.reason, "1 份原料 · 回扫候选 1 份\n- 001.md · 周三写生：岚舟陪星砚写生\n- 回扫候选 · 003.md · 明信片")
        d.sources = ["m/1.md", "m/2.md", "m/3.md"]
        guard case .success(let none) = CatalogSeedTools.checkDirection(d, task: t, wiki: wiki) else { return XCTFail() }
        XCTAssertNil(none.candidates)
        XCTAssertEqual(none.reason, "1 份原料\n- 001.md · 周三写生：岚舟陪星砚写生")
        XCTAssertEqual(CatalogSeedNotes.candidateNote(checked.reason, candidates: checked.candidates ?? []), checked.reason, "再过一遍不变")
    }

    /// astra 二审 P3：候选的命中名变了，这一页的对话 key 跟着变（重开）；命中名只是顺序 / 重复不同不算变
    func testPageKeyIncludesNormalizedCandidateHits() {
        let t = task(read: ["m/1.md": "v1", "m/2.md": "v1"])
        var d = WikiProposal.Direction(path: "人/星砚", title: "星砚", kind: .person, action: .newPage, reason: "", mode: .seed, sources: ["m/1.md"])
        d.candidates = [.init(path: "m/2.md", hits: ["星砚", "星砚老师"])]
        let key = CatalogAgent.pageKey(d, task: t)
        d.candidates = [.init(path: "m/2.md", hits: ["星砚老师", "星砚", "星砚"])]
        XCTAssertEqual(CatalogAgent.pageKey(d, task: t), key)
        d.candidates = [.init(path: "m/2.md", hits: ["星砚"])]
        XCTAssertNotEqual(CatalogAgent.pageKey(d, task: t), key)
    }

    // MARK: - 对齐名单切片

    func testAlignSlicesPartitionListAndMergeResultsEqualUnsliced() {
        let groups = (0..<2_500).map { SeedNoteGroup(key: "n\($0)", display: "N\($0)", group: "人", paths: ["m/\($0).md"], count: 1) }
        let slices = CatalogSeedNotes.alignSlices(groups, limit: 1_000)
        XCTAssertEqual(slices.map(\.count), [1_000, 1_000, 500])
        XCTAssertEqual(slices.flatMap { $0.map(\.key) }, groups.map(\.key), "按名单顺序切、一个名字只在一片里")
        XCTAssertEqual(CatalogSeedNotes.alignSlices(groups, limit: 5_000).count, 1)
        XCTAssertEqual(CatalogSeedNotes.alignSlices([], limit: 1_000).count, 0)

        // 每片模型只看本片：各片第一个名字吃掉本片第二个；拼起来喂全名单 = 逐片对齐再拼
        let perSlice = slices.map { s in [SeedNoteParser.Merge(into: s[0].display, names: [s[1].display])] }
        let whole = CatalogSeedNotes.align(groups: groups, anchors: [.user], merges: perSlice.flatMap { $0 })
        let pieces = zip(slices, perSlice).flatMap { CatalogSeedNotes.align(groups: $0, anchors: [.user], merges: $1).groups }
        XCTAssertEqual(whole.groups, pieces)
        XCTAssertEqual(whole.groups.count, 2_497)
        XCTAssertEqual(whole.groups[0].mergedFrom, ["N1"])
        XCTAssertEqual(whole.dropped, [])
        // 跨片的合并（模型看不到另一片的名字，真跑不会出现）喂全名单也只是正常合并，不会坏
        let cross = CatalogSeedNotes.align(groups: groups, anchors: [.user], merges: [.init(into: "N0", names: ["N1500"])])
        XCTAssertEqual(cross.groups[0].paths, ["m/0.md", "m/1500.md"])
    }

    // MARK: - 提示词口径 + .notes 位置

    func testMentionAliasesDoNotCastAdditionalGroupVotes() throws {
        var first = card("m/first", mentions: [("星砚", "物")])
        first.mentions[0].aliases = ["阿砚", "ＡＹ", "ay", "星砚", " 岚·舟 "]
        let second = card("m/second", mentions: [("星砚", "人")])
        let third = card("m/third", mentions: [("星砚", "人")])
        let g = try XCTUnwrap(CatalogSeedNotes.aggregate(cards: [first, second, third], names: names).entities.first)
        XCTAssertEqual(g.group, "人")
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g.aliases, ["阿砚", "ＡＹ"])
        XCTAssertEqual(g.paths, ["m/first", "m/second", "m/third"])
    }

    func testMentionAliasesSurviveParsingStorageAggregationAlignmentAndOutline() throws {
        let raw = #"{"cards":[{"m":"m1","title":"星砚陪伴写生","gist":"星砚又叫阿砚","mentions":[{"name":"星砚","group":"人","aliases":[" 阿砚 ","阿砚","ＡＹ","ay","星砚"," "]}],"about_user":false,"group":"人","fact_domain":"realWorld"}]}"#
        let body = try XCTUnwrap(try SeedNoteParser.cards(raw, labels: ["m1"], user: names.user).get().cards["m1"])
        var c = card("m/persona", title: body.title, gist: body.gist)
        c.mentions = body.mentions
        c.layer = "Prompt"
        let store = SeedNoteStore(wiki: wiki)
        try store.save(c)
        let loaded = try XCTUnwrap(store.load(path: c.path, version: c.version))
        XCTAssertEqual(loaded.mentions, body.mentions)
        let g = try XCTUnwrap(CatalogSeedNotes.aggregate(cards: [loaded], names: names).entities.first)
        XCTAssertEqual(g.aliases, ["阿砚", "ＡＹ"])
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.group, "人")
        XCTAssertEqual(g.sourceLayers, ["Prompt"])
        XCTAssertTrue(SeedNotePrompts.alignUser(groups: [g], anchors: []).contains("阿砚"))
        XCTAssertTrue(CatalogSeedNotes.opensEntityPage(g))
        let other = SeedNoteGroup(key: "砚老师", display: "砚老师", group: "人", paths: ["m/other"], sourceLayers: ["CC"])
        let aligned = CatalogSeedNotes.align(groups: [other, g], anchors: [], merges: [.init(into: "砚老师", names: ["星砚"])])
        let merged = try XCTUnwrap(aligned.groups.first)
        XCTAssertEqual(merged.sourceLayers, ["CC", "Prompt"])
        XCTAssertTrue(merged.aliases.contains("阿砚"))
        XCTAssertTrue(CatalogSeedNotes.opensEntityPage(merged))
        let outline = CatalogSeedNotes.outline(groups: [merged], clusters: .init(), cards: [loaded],
            names: names, task: task(read: ["m/persona": "v1", "m/other": "v1"]), wiki: wiki)
        XCTAssertTrue(outline.dropped.isEmpty)
        guard case .direction(let direction) = try XCTUnwrap(outline.items.first).change else { return XCTFail("缺目录") }
        XCTAssertTrue(direction.aliases.contains("阿砚"))
        XCTAssertTrue(direction.aliases.contains("星砚"))
    }

    func testOldMentionAndGroupCheckpointsDecodeWithoutOptionalFields() throws {
        let mention = try JSONDecoder().decode(SeedNoteCard.Mention.self, from: Data(#"{"name":"星砚","group":"人"}"#.utf8))
        XCTAssertNil(mention.aliases)
        let group = try JSONDecoder().decode(SeedNoteGroup.self, from: Data(#"{"key":"星砚","display":"星砚","group":"人","paths":["m/a"],"mergedFrom":[],"aliases":[],"count":1}"#.utf8))
        XCTAssertNil(group.sourceLayers)
        XCTAssertFalse(CatalogSeedNotes.opensEntityPage(group))
        for layer in ["CC", "问卷"] {
            var g = group
            g.sourceLayers = [layer]
            XCTAssertFalse(CatalogSeedNotes.opensEntityPage(g))
            g.paths = ["m/a", "m/b", "m/c"]
            XCTAssertTrue(CatalogSeedNotes.opensEntityPage(g))
        }
    }

    func testRejectedOwnedMemberDoesNotTriggerCopiedTitleFallback() {
        let cards = [card("m/owned", title: "星砚喜欢雨天"), card("m/new", title: "岚舟准备画具")]
        let existing = SeedNoteClusters(userPages: [.init(title: "已有标题", path: "{{user}}/旧页", paths: ["m/owned"])])
        let result = CatalogSeedNotes.clusters(user: cards, loose: [], reply: .init(userPages: [
            .init(title: "星砚喜欢雨天", path: "{{user}}/新页", members: ["c1", "c2"])], topics: []), existing: existing)
        XCTAssertEqual(result.userPages.last?.title, "星砚喜欢雨天")
        XCTAssertEqual(result.userPages.last?.paths, ["m/new"])
        XCTAssertEqual(result.copiedTitleCount, 0)
        XCTAssertEqual(result.dropped.count, 1)
    }

    func testRecoveryCopiedTitlePreservesFirstRoundGoodTitleAndCanReplaceFallback() {
        let cards = [card("m/first"), card("m/second", title: "星砚喜欢雨天")]
        for original in ["雨天写生的准备约定", "写生"] {
            let existing = SeedNoteClusters(userPages: [.init(title: original, path: "{{user}}/写生", paths: ["m/first"])])
            let copied = CatalogSeedNotes.clusters(user: cards, loose: [], reply: .init(userPages: [
                .init(title: "星砚喜欢雨天", path: "{{user}}/写生", members: ["c2"])], topics: []), existing: existing)
            XCTAssertEqual(copied.userPages.first?.title, original)
            XCTAssertEqual(copied.userPages.first?.paths, ["m/first", "m/second"])
            let good = CatalogSeedNotes.clusters(user: cards, loose: [], reply: .init(userPages: [
                .init(title: "雨天的写生安排", path: "{{user}}/写生", members: ["c2"])], topics: []), existing: existing)
            XCTAssertEqual(good.userPages.first?.title, original == "写生" ? "雨天的写生安排" : original)
        }
    }

    func testNotesPathFieldsRestoreUserName() throws {
        func object(_ s: String) throws -> [String: Any] { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) }
        let cards = try object(WikiStore.storedJSON(#"{"cards":[{"m":"m1","group":"岚舟","mentions":[{"name":"岚舟","group":"人"}],"gist":"岚舟说"}]}"#, fields: .notes, user: "岚舟"))
        let c = try XCTUnwrap((cards["cards"] as? [[String: Any]])?.first)
        XCTAssertEqual(c["group"] as? String, "{{user}}")
        XCTAssertEqual((c["mentions"] as? [[String: Any]])?.first?["name"] as? String, "岚舟", "mentions 的名字不是路径，不动")
        XCTAssertEqual(c["gist"] as? String, "岚舟说")
        let pages = try object(WikiStore.storedJSON(#"{"user_pages":[{"path":"岚舟/作息"}],"topics":[{"path":"主题/岚舟"}],"merge":[{"into":"岚舟","names":["小岚"]}]}"#, fields: .notes, user: "岚舟"))
        XCTAssertEqual((pages["user_pages"] as? [[String: Any]])?.first?["path"] as? String, "{{user}}/作息")
        XCTAssertEqual((pages["topics"] as? [[String: Any]])?.first?["path"] as? String, "主题/岚舟", "第一段不是名字的不动")
        XCTAssertEqual((pages["merge"] as? [[String: Any]])?.first?["into"] as? String, "{{user}}")
        XCTAssertEqual((pages["merge"] as? [[String: Any]])?.first?["names"] as? [String], ["小岚"])
    }
}
