import XCTest
import SwiftData
@testable import 记忆花园

/// C3 第二步 · 逐主题写 + 分组调整 + 每天自动那次（plan-memory-c3-catalog 4.1 / 2.1、todo 7 / 7c 提示词）：
/// 条目校验（无出处扔、关系四种、路径、记录只追加）、重试 ≤2、输出落盘、单主题失败不连坐、超 30 行出分组调整
@MainActor
final class CatalogWriterTests: XCTestCase {

    private let pid = "xctest-catalog-writer"
    private let names = CatalogTestKit.names
    private var root: URL!
    private var wiki: WikiStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-writer-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root.appendingPathComponent("wiki", isDirectory: true))
        try wiki.save(WikiPage(path: "楼层/人/小慧", kind: .person, triggers: ["小慧"], hook: "她提到小慧时", title: "小慧",
                               now: "室友（自 2026-09 起）。", records: ["2026-10-01 认识（出处：碎片 00000000）"]))
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private let f1 = CatalogFragment(id: UUID(), content: "阿杰请吃饭", category: "fact", day: "2026-10-12")
    private let f2 = CatalogFragment(id: UUID(), content: "小慧搬去七楼了", category: "fact", day: "2026-10-13")

    private var sources: CatalogSources {
        var s = CatalogSources()
        s.addFragments([f1, f2])
        s.windows["0001aaaa"] = .init(id: "0001aaaa-conv", title: "看片", day: "2026-10-12")
        s.segments["0001aaaa#2"] = .init(messages: 12..<30, day: "2026-10-12")
        s.versions = wiki.versionSnapshot()
        return s
    }

    // MARK: - 条目校验

    func testItemValidation() throws {
        let json = """
        {"items":[
          {"type":"new_page","path":"楼层/人/阿杰","kind":"人","title":"阿杰","triggers":["阿杰","杰哥"],"hook":"她提到阿杰时","now":"同事（自 2026-10 起）。",
           "records":[{"text":"- 2026-10-12 请吃饭","fragments":["f1"]},{"text":"2026-10-12 没出处"},
                      {"text":"2026-10-12 一起看片","aline":[{"layer":"a2","window":"conv 0001aaaa-conv","segment":2}]},
                      {"text":"2026-10-12 编的窗口","aline":[{"layer":"A3","window":"99999999"}]}],
           "links":[{"to":"楼层/人/小慧","relation":"补充","why":"室友的同事"},{"to":"楼层/人/小慧","relation":"替代"},{"to":"楼层/人/谁","relation":"引用"}]},
          {"type":"new_page","path":"楼层/人/小慧","title":"小慧","records":[{"text":"x","fragments":["f1"]}]},
          {"type":"append","path":"楼层/人/不存在","records":[{"text":"x","fragments":["f1"]}]},
          {"type":"append","path":"楼层/人/小慧","records":[{"text":"2026-10-13 搬去七楼","fragments":["f2"]}],"judgment":"共存"},
          {"type":"new_page","path":"其他/阿杰","records":[{"text":"x","fragments":["f1"]}]},
          {"type":"delete_records","path":"楼层/人/小慧"},
          {"type":"rewrite_records","path":"楼层/人/小慧","records":[{"text":"x","fragments":["f1"]}]},
          {"type":"rewrite_now","path":"楼层/人/小慧","now":"室友，搬去七楼了（自 2026-10-13 起）。","judgment":"conflict"},
          {"type":"link","path":"楼层/人/小慧","to":"楼层/人/阿杰","relation":"矛盾","why":"说法不一样"}
        ]}
        """

        let parsed = try XCTUnwrap(CatalogItems.parse(json, sources: sources, wiki: wiki))

        XCTAssertEqual(parsed.items.count, 4)
        XCTAssertEqual(parsed.dropped, 6, "2 行没出处 / 编的窗口 + 1 条连到不存在的页 + 已有页再新开 + 页不存在 + 路径不在两支下")
        XCTAssertEqual(parsed.unapplied.map(\.at), ["items[0] 楼层/人/阿杰.links[1]", "items[5] 楼层/人/小慧", "items[6] 楼层/人/小慧"],
                       "关系不在四种、改旧记录的两种不认识的类型：不扔，留在提案上给她看")
        XCTAssertEqual(parsed.dropReasons.count, parsed.dropped)
        for (location, reason) in [
            ("items[0] 楼层/人/阿杰.records[1]", "没有可用出处"),
            ("items[0] 楼层/人/阿杰.records[3]", "没有可用出处"),
            ("items[0] 楼层/人/阿杰.links[2]", "连线不合法"),
            ("items[1] 楼层/人/小慧", "新开页已存在"),
            ("items[2] 楼层/人/不存在", "未读版本"),
            ("items[4] 其他/阿杰", "路径不在工程 / 楼层下"),
        ] {
            XCTAssertTrue(parsed.dropReasons.contains { $0.hasPrefix(location + "：") && $0.contains(reason) }, "\(location)：\(reason)")
        }
        guard case .newPage(let page) = parsed.items[0].change else { return XCTFail() }
        XCTAssertEqual(page.records, [
            "2026-10-12 请吃饭（出处：碎片 \(f1.id.uuidString.prefix(8).lowercased())）",
            "2026-10-12 一起看片（出处：A2《看片》第 2 段）",
        ])
        XCTAssertEqual(page.links, [WikiPage.Link(target: "楼层/人/小慧", relation: .supplement, why: "室友的同事")])
        XCTAssertEqual(page.triggers, ["阿杰", "杰哥"])
        XCTAssertNil(parsed.items[0].baseVersion, "新开页没有版本")
        XCTAssertEqual(parsed.items[0].fragmentIds, [f1.id])
        XCTAssertEqual(parsed.items[0].cites, [.init(layer: "A2", day: "2026-10-12", windowId: "0001aaaa-conv", segment: 2, messageFrom: 12, messageTo: 30)])

        let version = wiki.version(of: "楼层/人/小慧")
        XCTAssertNotNil(version)
        guard case .appendRecords(let path, let lines) = parsed.items[1].change else { return XCTFail() }
        XCTAssertEqual(path, "楼层/人/小慧")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(parsed.items[1].judgment, .coexist)
        XCTAssertEqual(parsed.items[1].baseVersion, version, "baseVersion = 生成时页的版本")
        guard case .rewriteNow(_, let old, _, _) = parsed.items[2].change else { return XCTFail() }
        XCTAssertEqual(old, "室友（自 2026-09 起）。")
        XCTAssertEqual(parsed.items[2].judgment, .conflict)
        guard case .link(_, let link) = parsed.items[3].change else { return XCTFail() }
        XCTAssertEqual(link.relation, .contradiction, "连到同一份里新开的页也行")
    }

    func testOriginalNodesResolveToPersistentCitesWithRegisteredAttribution() throws {
        let created = Date(timeIntervalSince1970: 1_791_800_000)
        let user = SearchService.CatalogNode(profileId: pid, conversationId: "original-conversation", nodeId: "user-node",
                                             title: "云桥城", created: created, role: "user", onMain: true, body: "我想画《云桥城》。")
        let assistant = SearchService.CatalogNode(profileId: pid, conversationId: "original-conversation", nodeId: "assistant-node",
                                                  title: "云桥城", created: nil, role: "assistant", onMain: false, body: "我会陪你画《云桥城》。")
        var source = sources
        source.addOriginal(user)
        source.addOriginal(assistant)
        let parsed = try XCTUnwrap(CatalogItems.parse("""
        {"items":[{"type":"new_page","path":"楼层/主题/云桥城","title":"云桥城","records":[
          {"text":"用户想画《云桥城》","aline":[{"layer":"原文","nodeId":"user-node"}]},
          {"text":"助手承诺陪画《云桥城》","aline":[{"layer":"原文","nodeId":"assistant-node","window":"original-conversation","role":"user","onMain":true}]}
        ]}]}
        """, sources: source, wiki: wiki))
        let item = try XCTUnwrap(parsed.items.first)
        XCTAssertEqual(parsed.dropped, 0)
        XCTAssertEqual(item.cites, [
            .init(layer: "原文", day: MemoryDay.key(created), windowId: user.conversationId,
                  profileId: pid, nodeId: user.nodeId, role: "user", created: created, onMain: true),
            .init(layer: "原文", windowId: assistant.conversationId, profileId: pid, nodeId: assistant.nodeId, role: "assistant", onMain: false),
        ], "稳定定位与归因来自实际登记节点，不能由模型自报覆盖")
        guard case .newPage(let page) = item.change else { return XCTFail("应该是新开页") }
        XCTAssertEqual(page.records.count, 2)
        XCTAssertTrue(page.records[1].contains("助手发言"))
        XCTAssertTrue(page.records[1].contains("非用户事实"))
        XCTAssertTrue(page.records[1].contains(assistant.nodeId))
        let store = WikiProposalStore(wiki: wiki)
        let proposal = WikiProposal(origin: .topic, createdAt: created, items: [item])
        try store.save(proposal)
        XCTAssertEqual(store.load(proposal.id)?.items.first?.cites, item.cites)
    }

    func testOriginalCitationRejectsUnknownNodesAndMismatchedContext() throws {
        var source = sources
        source.addOriginal(.init(profileId: pid, conversationId: "original-conversation", nodeId: "known-node", title: "云桥城",
                                 created: nil, role: "user", onMain: true, body: "云桥城"))
        source.addOriginal(.init(profileId: pid, conversationId: "original-conversation", nodeId: "tool-node", title: "工具",
                                 created: nil, role: "tool", onMain: true, body: "工具日志不能做原文"))
        XCTAssertNil(source.originals["tool-node"])
        let parsed = try XCTUnwrap(CatalogItems.parse("""
        {"items":[{"type":"new_page","path":"楼层/主题/云桥城","records":[
          {"text":"没有登记","aline":[{"layer":"原文","nodeId":"invented-node"}]},
          {"text":"另一个窗口","aline":[{"layer":"原文","nodeId":"known-node","window":"wrong-window"}]},
          {"text":"相同前缀的伪窗口","aline":[{"layer":"原文","nodeId":"known-node","window":"original-fake"}]},
          {"text":"另一个楼层","aline":[{"layer":"原文","nodeId":"known-node","profileId":"other-floor"}]},
          {"text":"原文不能装段","aline":[{"layer":"原文","nodeId":"known-node","segment":2}]},
          {"text":"原文不能装A2","aline":[{"layer":"A2","nodeId":"known-node","window":"0001aaaa","segment":2}]},
          {"text":"工具日志","aline":[{"layer":"原文","nodeId":"tool-node"}]},
          {"text":"已登记节点","aline":[{"layer":"原文","nodeId":"known-node","window":"original"}]}
        ]}]}
        """, sources: source, wiki: wiki))
        XCTAssertEqual(parsed.dropped, 7)
        let item = try XCTUnwrap(parsed.items.first)
        XCTAssertEqual(item.cites.map(\.nodeId), ["known-node"])
        guard case .newPage(let page) = item.change else { return XCTFail("应该是新开页") }
        XCTAssertEqual(page.records.count, 1)
        XCTAssertTrue(page.records[0].hasPrefix("已登记节点"))
    }

    func testALineCitationRequiresActualLayerAndSegmentWithoutBorrowingA4Window() throws {
        let now = Date()
        var source = sources
        source.add(.init(terms: ["云桥城"], hits: [
            .init(layer: .a4, conversationId: "a4only00-conversation", title: "云桥城", start: now, end: now,
                  day: "2026-10-12", parts: [.init(text: "云桥城", isBody: true)], old: nil),
        ], found: [.a4: 1]))
        let parsed = try XCTUnwrap(CatalogItems.parse("""
        {"items":[{"type":"new_page","path":"楼层/主题/云桥城","records":[
          {"text":"没读过的段","aline":[{"layer":"A2","window":"0001aaaa","segment":99}]},
          {"text":"缺段号","aline":[{"layer":"A2","window":"0001aaaa"}]},
          {"text":"A4不能借成A2","aline":[{"layer":"A2","window":"a4only00","segment":2}]},
          {"text":"A4不能借成A3","aline":[{"layer":"A3","window":"a4only00"}]},
          {"text":"A4没有A2段号","aline":[{"layer":"A4","window":"a4only00","segment":2}]},
          {"text":"实际提供的A4","aline":[{"layer":"A4","window":"a4only00"}]},
          {"text":"实际提供的A2","aline":[{"layer":"A2","window":"0001aaaa","segment":2}]}
        ]}]}
        """, sources: source, wiki: wiki))
        XCTAssertEqual(parsed.dropped, 5)
        let item = try XCTUnwrap(parsed.items.first)
        XCTAssertEqual(item.cites.map(\.layer), ["A4", "A2"])
        XCTAssertNil(item.cites[0].segment)
        XCTAssertNil(item.cites[0].nodeId)
        XCTAssertEqual(item.cites[1].messageFrom, 12)
        XCTAssertEqual(item.cites[1].messageTo, 30)
    }

    /// 第 7 段：A4 一天一条按日期引用（不伪造窗口）；只认本次实际给过的那天
    func testA4DayRecordCitedByDate() throws {
        let now = Date()
        var source = sources
        source.add(.init(terms: ["云桥城"], hits: [
            .init(layer: .a4, conversationId: nil, title: "", start: now, end: now, day: "2026-10-12",
                  parts: [.init(text: "白天画云桥城", isBody: true)], old: nil),
        ], found: [.a4: 1]))
        XCTAssertEqual(source.days, ["2026-10-12"])
        let parsed = try XCTUnwrap(CatalogItems.parse("""
        {"items":[{"type":"new_page","path":"楼层/主题/云桥城","records":[
          {"text":"给过的那天","aline":[{"layer":"A4","day":"2026-10-12"}]},
          {"text":"没给过的那天","aline":[{"layer":"A4","day":"2026-10-13"}]},
          {"text":"日期配段号","aline":[{"layer":"A4","day":"2026-10-12","segment":1}]}
        ]}]}
        """, sources: source, wiki: wiki))
        XCTAssertEqual(parsed.dropped, 2)
        let cite = try XCTUnwrap(parsed.items.first?.cites.first)
        XCTAssertEqual(cite, WikiProposal.Cite(layer: "A4", day: "2026-10-12"))
        XCTAssertNil(cite.windowId)
        XCTAssertEqual(WikiProposalDisplay.citeText(cite, titles: [:]), "A4 · 2026-10-12")
    }

    func testNotItemsEnvelopeIsNil() {
        XCTAssertNil(CatalogItems.parse("{\"pages\":[]}", sources: sources, wiki: wiki))
        XCTAssertEqual(CatalogItems.parse("{\"items\":[]}", sources: sources, wiki: wiki)?.items, [])
    }

    /// 第 9 段起：带了不收的字段不扔，原样留在「没收进页的内容」里，诊断照旧说改用哪种
    func testFieldsNotConsumedByItemTypeAreKeptAsUnappliedWithRepairHint() throws {
        let parsed = try XCTUnwrap(CatalogItems.parse("""
        {"items":[
          {"type":"rewrite_now","path":"楼层/人/小慧","now":"新现在","records":[{"text":"记录","fragments":["f1"]}]},
          {"type":"append","path":"楼层/人/小慧","records":[{"text":"记录","fragments":["f1"]}],
           "links":[{"to":"楼层/人/小慧","relation":"补充"}]}
        ]}
        """, sources: sources, wiki: wiki))

        XCTAssertTrue(parsed.items.isEmpty)
        XCTAssertEqual(parsed.dropped, 0)
        XCTAssertEqual(parsed.revisionNotes, [
            "items[0] 楼层/人/小慧：type=rewrite_now 不收 records 字段，改用 append",
            "items[1] 楼层/人/小慧：type=append 不收 links 字段，改用 link",
        ])
        XCTAssertEqual(parsed.unapplied.map(\.page), ["楼层/人/小慧", "楼层/人/小慧"])
    }

    func testMalformedNestedValuesAndNoChangesHaveLocatedReasons() throws {
        let parsed = try XCTUnwrap(CatalogItems.parse("""
        {"items":[
          42,
          {"type":"new_page","path":"楼层/人/阿杰",
           "records":[{"text":3},{"text":"  "},{"text":"没有出处"},{"text":"有效","fragments":["f1"]}],
           "links":[7,{"to":"楼层/人/小慧"},{"to":"楼层/人/阿杰","relation":"补充"}]},
          {"type":"rewrite_now","path":"楼层/人/小慧","now":"室友（自 2026-09 起）。"},
          {"type":"retag","path":"楼层/人/小慧"},
          {"type":"unknown","path":"楼层/人/小慧"},
          {"type":"append","path":"楼层/人/小慧","records":[]}
        ],"reason":"  已有内容不重复写  "}
        """, sources: sources, wiki: wiki))
        XCTAssertEqual(parsed.items.count, 1, "坏记录和坏连线不改变新开页的接受范围")
        XCTAssertEqual(parsed.dropped, 10)
        XCTAssertEqual(parsed.unapplied.map(\.at), ["items[4] 楼层/人/小慧"], "不认识的类型不扔，留给她看")
        XCTAssertEqual(parsed.dropReasons.count, parsed.dropped)
        XCTAssertEqual(parsed.reason, "已有内容不重复写")
        for (location, reason) in [
            ("items[0]", "条目格式不合格"),
            ("items[1] 楼层/人/阿杰.records[0]", "记录格式不合格"),
            ("items[1] 楼层/人/阿杰.records[1]", "记录正文为空"),
            ("items[1] 楼层/人/阿杰.records[2]", "没有可用出处"),
            ("items[1] 楼层/人/阿杰.links[0]", "连线格式不合格"),
            ("items[1] 楼层/人/阿杰.links[1]", "连线格式不合格"),
            ("items[1] 楼层/人/阿杰.links[2]", "连线不合法"),
            ("items[2] 楼层/人/小慧", "无变化"),
            ("items[3] 楼层/人/小慧", "无变化"),
            ("items[5] 楼层/人/小慧", "没有可追加的有效记录"),
        ] {
            XCTAssertTrue(parsed.dropReasons.contains { $0.hasPrefix(location + "：") && $0.contains(reason) }, "\(location)：\(reason)")
        }
        var unread = sources
        unread.versions = [:]
        let noVersion = try XCTUnwrap(CatalogItems.parse(
            "{\"items\":[{\"type\":\"retag\",\"path\":\"楼层/人/小慧\",\"hook\":\"新钩子\"}]}",
            sources: unread, wiki: wiki))
        XCTAssertEqual(noVersion.items, [])
        XCTAssertEqual(noVersion.dropped, 1)
        XCTAssertTrue(noVersion.dropReasons[0].contains("未读版本"))
    }

    func testReasonWhitespaceIsNilAndDoesNotAffectEmptySubmission() throws {
        for json in ["{\"items\":[]}", "{\"items\":[],\"reason\":null}", "{\"items\":[],\"reason\":42}", "{\"items\":[],\"reason\":\"  \\n\\t  \"}"] {
            let parsed = try XCTUnwrap(CatalogItems.parse(json, sources: sources, wiki: wiki))
            XCTAssertEqual(parsed.items, [])
            XCTAssertEqual(parsed.dropped, 0)
            XCTAssertEqual(parsed.dropReasons, [])
            XCTAssertNil(parsed.reason)
        }
        let parsed = try XCTUnwrap(CatalogItems.parse("{\"items\":[],\"reason\":\" \\n没新事实\\t \"}", sources: sources, wiki: wiki))
        XCTAssertEqual(parsed.reason, "没新事实")
    }

    func testCoveredHangsOnFirstItemOfThatPage() throws {
        let parsed = try XCTUnwrap(CatalogItems.parse("""
        {"items":[{"type":"append","path":"楼层/人/小慧","records":[{"text":"2026-10-13 搬去七楼","fragments":["f2"]}]}],"covered":["f1","f2","f9"]}
        """, sources: sources, wiki: wiki))
        XCTAssertEqual(parsed.covered, [f1.id], "认不出的编号、条目里已经引用的不算 covered")

        var items: [WikiProposal.Item] = [
            .init(change: .link(from: "楼层/人/阿杰", link: .init(target: "楼层/人/小慧", relation: .resonance, why: "")), baseVersion: "v"),
            .init(change: .appendRecords(path: "楼层/人/小慧", lines: ["x"]), fragmentIds: [f2.id], baseVersion: "v"),
        ]
        XCTAssertEqual(CatalogItems.attachCovered(&items, covered: [f1.id], path: "楼层/人/小慧", version: "v"), [])
        XCTAssertEqual(items[1].fragmentIds, [f2.id], "covered 不混进明确引用的（驳回不连带）")
        XCTAssertEqual(items[1].covered, [f1.id])
        XCTAssertEqual(items[1].organizedIds, [f2.id, f1.id])
        XCTAssertNil(items[0].covered)
        XCTAssertEqual(CatalogItems.attachCovered(&items, covered: [f1.id], path: "楼层/人/谁", version: nil), [f1.id], "页不在 / 没看过版本：还给调用方，不打标")

        var only: [WikiProposal.Item] = []
        XCTAssertEqual(CatalogItems.attachCovered(&only, covered: [f1.id], path: "楼层/人/小慧", version: "v2"), [])
        XCTAssertEqual(only.map(\.change), [.confirmCovered(path: "楼层/人/小慧")], "这页一条都没写：单出一条「确认已覆盖」等批")
        XCTAssertEqual(only.first?.covered, [f1.id])
        XCTAssertEqual(only.first?.fragmentIds, [], "驳回不连带")
        XCTAssertEqual(only.first?.baseVersion, "v2")
    }

    /// astra 10-16 #1：基线取备料读页那一刻的版本，生成期间她改了页 → 批的时候置「页已变」
    func testBaseVersionTakenWhenMaterialRead() async throws {
        let path = "楼层/人/小慧"
        let v0 = try XCTUnwrap(wiki.version(of: path))
        let topic = CatalogSorter.Topic(path: path, title: "小慧", kind: .person, aliases: [], existing: true, fragmentIds: [f2.id])
        let m = await material(topic, fragments: [f2])
        XCTAssertEqual(m.versions[path], v0)
        let wiki = wiki!
        let parsed = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
            var hand = try XCTUnwrap(wiki.read(path))
            hand.now = "她手改了"
            try wiki.saveRaw(hand.markdown, path: path)
            return "{\"items\":[{\"type\":\"append\",\"path\":\"楼层/人/小慧\",\"records\":[{\"text\":\"2026-10-13 搬去七楼\",\"fragments\":[\"f1\"]}]}]}"
        }, drafts: nil)
        let item = try XCTUnwrap(parsed?.items.first)
        XCTAssertEqual(item.baseVersion, v0, "不是解析时才读的新版本")

        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let store = WikiProposalStore(wiki: wiki)
        let p = WikiProposal(origin: .scheduled, createdAt: Date(), items: [item])
        try store.save(p)
        let out = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: ModelContext(container))
        XCTAssertEqual(out.items[0].state, .stale)
        XCTAssertEqual(wiki.read(path)?.now, "她手改了", "不硬盖")
    }

    // MARK: - 楼层提示内容

    func testFloorPromptExpandsNamesAndLimitsLength() {
        let floor = CatalogFloorPrompt.text(sections: [("系统提示", "你是{{char}}，陪着{{user}}。"), ("场景", "  "), ("角色性格", "话少")],
                                            names: EffectiveCharacterContext(charName: "小克", userName: "粟粟"))
        XCTAssertEqual(floor, "〔系统提示〕\n你是小克，陪着粟粟。\n\n〔角色性格〕\n话少", "空段不带，名字换掉")
        let long = CatalogFloorPrompt.text(sections: [("系统提示", String(repeating: "长", count: 5000))],
                                           names: EffectiveCharacterContext(charName: "a", userName: "b"))
        XCTAssertEqual(long.count, CatalogFloorPrompt.maxChars + 1)
    }

    // MARK: - 写一个主题：重试 ≤2、落盘

    private func material(_ topic: CatalogSorter.Topic, fragments: [CatalogFragment]) async -> CatalogWriter.Material {
        await CatalogWriter.material(topic, fragments: fragments, floorPrompt: "她是程序员", wiki: wiki, memoryRoot: root, now: Date(),
                                     embedder: CatalogFakeEmbedder.unavailable())
    }

    func testWriterRunPreservesMaterialsRepliesValidationAndFeedback() async throws {
        let run = CatalogRunRecord(wiki: wiki, topic: "小慧", kind: "执行方向")
        let fragments = [f2, f1]
        let topic = CatalogSorter.Topic(path: "楼层/人/小慧", title: "小慧", kind: .person, aliases: ["小慧"], existing: true,
                                        fragmentIds: fragments.map(\.id))
        var m = await material(topic, fragments: fragments)
        let alineText = String(repeating: "完整 A 线原话，不截短。", count: 1200) + "\n```A线尾部"
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        m.search = .init(aline: .init(terms: ["小慧", "慧 慧", "带\"引号", "```"], hits: [
            .init(layer: .a2, conversationId: "0001aaaa-conv", title: "搬家原话", start: time, end: time,
                  day: "2026-10-13", segment: 2, messages: 12..<30, parts: [.init(text: alineText, isBody: true)], old: nil),
        ], found: [.a2: 1]), fragments: [], labels: m.labels, vectorStatus: "不可用")
        let expectedUser = CatalogWriter.userContent(m, names: names)
        let expectedSystem = CatalogWriter.systemPrompt(names: names)
        let invalid = "{\"items\":[\n```模型坏格式原文"
        let reason = String(repeating: "已有内容无需重复。", count: 3000) + "原文尾部```"
        let valid = """
        {"items":[{"type":"append","path":"楼层/人/小慧","records":[
        {"text":"2026-10-13 搬去七楼","fragments":["f1"]},
        {"text":"没有可用出处","fragments":["f99"]}]}],"covered":["f2"],"reason":"\(reason)"}
        """
        var requests: [(String, String)] = []
        let result = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { system, user in
            requests.append((system, user))
            return requests.count == 1 ? invalid : valid
        }, drafts: CatalogDrafts(wiki: wiki, now: time), run: run)
        let parsed = try XCTUnwrap(result)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.0), [expectedSystem, expectedSystem])
        XCTAssertEqual(requests[0].1, expectedUser)
        let retryPrefix = expectedUser + CatalogJSON.retryNote + "\n"
        XCTAssertTrue(requests[1].1.hasPrefix(retryPrefix))
        let actualParseError = String(requests[1].1.dropFirst(retryPrefix.count))
        XCTAssertFalse(actualParseError.isEmpty, "原有解析错误全文回灌，不改变重试文本")
        XCTAssertEqual(parsed.items.count, 1)
        XCTAssertEqual(parsed.items[0].fragmentIds, [f2.id])
        XCTAssertEqual(parsed.items[0].covered, [f1.id])
        XCTAssertEqual(parsed.covered, [])
        XCTAssertEqual(parsed.dropped, 1)
        XCTAssertEqual(parsed.reason, reason)
        await run.flush()
        let report = try String(contentsOf: run.url, encoding: .utf8)
        for text in [invalid, valid, expectedUser, expectedSystem, requests[1].1, actualParseError,
                     alineText, m.search.aline.render(), try XCTUnwrap(m.pageRaw), m.indexLines.joined(separator: "\n"), reason] {
            XCTAssertTrue(report.contains(text), "参数、全部材料、每轮输出及回灌原文均不截短")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for data in [try encoder.encode(m.search.aline.terms), try encoder.encode(parsed.items), try encoder.encode(parsed.dropReasons),
                     try encoder.encode([f1.id])] {
            XCTAssertTrue(report.contains(String(decoding: data, as: UTF8.self)), "记录实际搜索词、校验条目、丢弃原因及覆盖结果")
        }
        for text in ["校验失败", "校验成功", "实际返回", "下一轮回灌", "parseError", "dropped）：1"] {
            XCTAssertTrue(report.contains(text))
        }
        XCTAssertNotNil(run.latestAnchor)
    }

    func testWriterRunRecordsEmptyAndAllDroppedWithoutAddingRetries() async throws {
        let topic = CatalogSorter.Topic(path: "楼层/人/小慧", title: "小慧", kind: .person, existing: true)
        let m = await material(topic, fragments: [f2])
        let run = CatalogRunRecord(wiki: wiki, topic: "空交与全扔", kind: "种子")
        for raw in [
            "{\"items\":[],\"reason\":\"没有新事实\"}",
            "{\"items\":[{\"type\":\"append\",\"path\":\"楼层/人/小慧\",\"records\":[{\"text\":\"没有出处\"}]}],\"reason\":\"无法引用\"}",
        ] {
            var calls = 0
            let result = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
                calls += 1
                return raw
            }, drafts: nil, run: run)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(result?.items, [])
        }
        await run.flush()
        let report = try String(contentsOf: run.url, encoding: .utf8)
        for text in ["没有新事实", "无法引用", "记录没有可用出处", "没有可追加的有效记录", "dropped）：0", "dropped）：2", "实际返回"] {
            XCTAssertTrue(report.contains(text))
        }
    }

    func testWriteRetriesTwiceAndSavesDrafts() async throws {
        let topic = CatalogSorter.Topic(path: "楼层/人/小慧", title: "小慧", kind: .person, aliases: ["小慧"], existing: true, fragmentIds: [f2.id])
        let m = await material(topic, fragments: [f2])
        XCTAssertTrue(CatalogWriter.userContent(m, names: names).contains("【已有页全文】楼层/人/小慧"))
        XCTAssertTrue(CatalogWriter.userContent(m, names: names).contains("她是程序员"))
        let drafts = CatalogDrafts(wiki: wiki, now: Date())
        var calls = 0
        let ok = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
            calls += 1
            return calls < 3 ? "```json\n{\"items\":\n```x" : "{\"items\":[{\"type\":\"append\",\"path\":\"楼层/人/小慧\",\"records\":[{\"text\":\"2026-10-13 搬去七楼\",\"fragments\":[\"f1\"]}]}]}"
        }, drafts: drafts)
        XCTAssertEqual(calls, 3, "同一次里最多重来 2 次")
        XCTAssertEqual(ok?.items.first?.fragmentIds, [f2.id], "编号按这个主题自己的碎片排")
        let files = try FileManager.default.contentsOfDirectory(at: CatalogDrafts.folder(wiki), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3, "每次输出一份取证，不再额外保存裸输出")
        for round in 1...3 {
            let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("-submit-\(round).txt") })
            let report = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(report.contains("truncated：未知/不适用"))
            XCTAssertTrue(report.contains("无额外正文信息"))
            if round < 3 {
                XCTAssertTrue(report.contains("```json\n{\"items\":\n```x"))
                XCTAssertTrue(report.contains("解析结果：格式不合格"))
                XCTAssertTrue(report.contains("items：未知"))
            } else {
                XCTAssertTrue(report.contains("\"type\":\"append\""))
                XCTAssertTrue(report.contains("解析结果：成功"))
                XCTAssertTrue(report.contains("items：1\ndropped：0"))
            }
        }

        calls = 0
        do {
            _ = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in calls += 1; return "写好了" }, drafts: nil)
            XCTFail("三次都不合格应该抛")
        } catch MemoryWriterError.format {}
        XCTAssertEqual(calls, 3)
    }

    func testWriterEmptyAndAllDroppedSaveEvidenceWithoutRetrying() async throws {
        let topic = CatalogSorter.Topic(path: "楼层/人/小慧", title: "小慧", kind: .person, existing: true)
        let m = await material(topic, fragments: [f2])
        let drafts = CatalogDrafts(wiki: wiki, now: Date())
        for (raw, reason, dropped) in [
            ("{\"items\":[],\"reason\":\"  没有新事实  \"}", "没有新事实", 0),
            ("{\"items\":[{\"type\":\"append\",\"path\":\"楼层/人/小慧\",\"records\":[{\"text\":\"没有出处\"}]}],\"reason\":\"无法引用\"}", "无法引用", 2),
        ] {
            var calls = 0
            let parsed = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
                calls += 1
                return raw
            }, drafts: drafts)
            XCTAssertEqual(calls, 1, "空交和全扔不能新增重交")
            XCTAssertEqual(parsed?.items, [])
            XCTAssertEqual(parsed?.reason, reason)
            XCTAssertEqual(parsed?.dropped, dropped)
        }
        let files = try FileManager.default.contentsOfDirectory(at: drafts.folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), [
            "\(drafts.run)-小慧-submit-1.txt", "\(drafts.run)-小慧-submit-1-2.txt",
        ])
        let reports = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        let empty = try XCTUnwrap(reports.first { $0.contains("reason：没有新事实") })
        XCTAssertTrue(empty.contains("items：0\ndropped：0"))
        XCTAssertTrue(empty.contains("dropReasons：\n（无）"))
        let discarded = try XCTUnwrap(reports.first { $0.contains("reason：无法引用") })
        XCTAssertTrue(discarded.contains("items：0\ndropped：2"))
        XCTAssertTrue(discarded.contains("items[0] 楼层/人/小慧.records[0]：记录没有可用出处"))
        XCTAssertTrue(discarded.contains("items[0] 楼层/人/小慧：没有可追加的有效记录"))
        for report in reports {
            XCTAssertTrue(report.contains("truncated：未知/不适用"))
        }
    }

    func testWriterAllMalformedAttemptsHaveEvidence() async throws {
        let topic = CatalogSorter.Topic(path: "楼层/人/小慧", title: "小慧", kind: .person, existing: true)
        let m = await material(topic, fragments: [])
        let drafts = CatalogDrafts(wiki: wiki, now: Date())
        var calls = 0
        do {
            _ = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
                calls += 1
                return "坏格式第\(calls)次"
            }, drafts: drafts)
            XCTFail("三次格式错误必须仍然抛出")
        } catch MemoryWriterError.format {}
        XCTAssertEqual(calls, 3)
        let files = try FileManager.default.contentsOfDirectory(at: drafts.folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        for round in 1...3 {
            let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("-submit-\(round).txt") })
            let report = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(report.contains("argumentsJSON：\n坏格式第\(round)次"))
            XCTAssertTrue(report.contains("解析结果：格式不合格"))
            XCTAssertTrue(report.contains("dropReasons：整包格式不合格"))
        }
    }

    func testSubmitEvidenceLimitsArgumentsAndKeepsRoundAndDuplicateSuffix() async throws {
        let drafts = CatalogDrafts(wiki: wiki, now: Date())
        let topic = "楼层/" + String(repeating: "长主题", count: 30)
        let arguments = String(repeating: "参", count: 20_000) + "不能落盘的尾巴"
        let parsed = CatalogItems.Parsed(items: [], dropped: 1, dropReasons: ["items[2]：坏类型"], reason: "没有可交条目")
        let urls = await Task.detached(priority: .utility) {
            [
                drafts.saveSubmit(argumentsJSON: arguments, text: "提交正文", truncated: false, parsed: parsed, topic: topic, round: 12),
                drafts.saveSubmit(argumentsJSON: "{\"items\":[]}", text: "第二份正文", truncated: true, parsed: parsed, topic: topic, round: 12),
                drafts.saveSubmit(argumentsJSON: "{\"items\":[]}", text: "", truncated: nil, parsed: nil, topic: topic, round: 12),
            ]
        }.value.compactMap { $0 }
        let stem = "\(drafts.run)-\(CatalogDrafts.safeName(topic))-submit-12"
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["\(stem).txt", "\(stem)-2.txt", "\(stem)-3.txt"])
        let first = try String(contentsOf: urls[0], encoding: .utf8)
        let rawSection = try XCTUnwrap(first.components(separatedBy: "argumentsJSON：\n").last?.components(separatedBy: "\n【argumentsJSON").first)
        XCTAssertEqual(rawSection.count, 20_000)
        XCTAssertEqual(rawSection, String(repeating: "参", count: 20_000))
        XCTAssertFalse(first.contains("不能落盘的尾巴"))
        XCTAssertTrue(first.contains("【argumentsJSON 超过 20000 字符，已截断】"))
        XCTAssertTrue(first.contains("正文：\n提交正文"))
        XCTAssertTrue(first.contains("truncated：false"))
        XCTAssertTrue(first.contains("items：0\ndropped：1"))
        XCTAssertTrue(first.contains("- items[2]：坏类型"))
        XCTAssertTrue(first.contains("reason：没有可交条目"))
        let second = try String(contentsOf: urls[1], encoding: .utf8)
        XCTAssertTrue(second.contains("【argumentsJSON 完整】"))
        XCTAssertTrue(second.contains("第二份正文"))
        XCTAssertTrue(second.contains("truncated：true"))
        XCTAssertTrue(second.contains("解析结果：跳过（truncated=true）"))
        XCTAssertFalse(second.contains("reason：没有可交条目"))
        let third = try String(contentsOf: urls[2], encoding: .utf8)
        XCTAssertTrue(third.contains("truncated：未知/不适用"))
        XCTAssertTrue(third.contains("解析结果：格式不合格"))
    }

    func testSubmitEvidenceClipsBodyReasonsAndStopsAfterTwelvePerRun() async throws {
        let drafts = CatalogDrafts(wiki: wiki, now: Date())
        let body = "正文开头" + String(repeating: "正", count: 8_100) + "正文结尾"
        let reason = "原因开头" + String(repeating: "因", count: 4_100) + "原因结尾"
        let parsed = CatalogItems.Parsed(items: [], dropped: 1, covered: [], dropReasons: [reason], reason: nil)
        let firstURL = await Task.detached(priority: .utility) {
            drafts.saveSubmit(argumentsJSON: "{\"items\":[]}", text: body, truncated: false,
                              parsed: parsed, topic: "主题", round: 1)
        }.value
        let report = try String(contentsOf: XCTUnwrap(firstURL), encoding: .utf8)
        XCTAssertTrue(report.contains(String(body.prefix(8_000))))
        XCTAssertTrue(report.contains("【正文超过 8000 字符，已截断】"))
        XCTAssertTrue(report.contains("【原因列表超过 4000 字符，已截断】"))
        XCTAssertFalse(report.contains("正文结尾"))
        XCTAssertFalse(report.contains("原因结尾"))

        let urls = await Task.detached(priority: .utility) {
            (0..<12).map { index in
                drafts.saveSubmit(argumentsJSON: "{\"items\":[]}", text: "第 \(index) 份", truncated: false,
                                  parsed: nil, topic: "主题", round: index + 2)
            }
        }.value
        XCTAssertEqual(urls.compactMap { $0 }.count, 11)
        XCTAssertNil(urls[11])
        let files = try FileManager.default.contentsOfDirectory(atPath: drafts.folder.path)
        XCTAssertEqual(files.count, 12)
        let logUpdated = expectation(description: "提交上限日志已完成主队列更新")
        DispatchQueue.main.async { logUpdated.fulfill() }
        await fulfillment(of: [logUpdated], timeout: 3)
        XCTAssertTrue(CacheDiagLog.shared.entries.contains { $0.text.contains(drafts.run) && $0.text.contains("已达 12 份") })
    }

    // MARK: - 第 9 段：代码硬查 + 格式诊断共用一次修订；修订用不了交第一稿；坏关系的连线留在提案上；判不准的只记日志

    private let longRecord = "2026-10-13 和男朋友一起把全部家当从五楼搬到七楼的新房间里，还请大家吃了一顿火锅"

    private func append(_ text: String) -> String {
        "{\"type\":\"append\",\"path\":\"楼层/人/小慧\",\"records\":[{\"text\":\"\(text)\",\"fragments\":[\"f1\"]}]}"
    }

    private func existingTopic() -> CatalogSorter.Topic {
        CatalogSorter.Topic(path: "楼层/人/小慧", title: "小慧", kind: .person, existing: true, fragmentIds: [f2.id])
    }

    func testRecordLengthAndListLinesOnlyCountWhatCodeCanJudge() {
        let line = CatalogItems.recordLine("2026-10-13 搬去七楼（到 2026-10-22）（f1）", fragments: [f2], cites: ["A2《看片》第 2 段"])
        XCTAssertEqual(CatalogChecks.recordBody(line), "搬去七楼")
        XCTAssertEqual(CatalogChecks.recordBody("日期未注明 收藏纸质海图（出处：CC memory/cc/a.md）"), "收藏纸质海图")
        XCTAssertEqual(CatalogChecks.recordBody("2026-10-13 改用新工号（1234）"), "改用新工号（1234）", "说不准是不是日子的数字括号算正文")
        XCTAssertEqual(CatalogChecks.recordBody("2026-10-13 约复诊（自 2026-10 起）"), "约复诊")
        XCTAssertEqual(CatalogChecks.recordText("2026-10-13搬去七楼"), "搬去七楼")
        XCTAssertEqual(CatalogChecks.recordText("2026-10-131 号楼停电"), "2026-10-131 号楼停电", "开头日期要有边界")
        let thirty = "2026-10-13 " + String(repeating: "搬", count: 30)
        XCTAssertTrue(CatalogChecks.record(thirty + "（出处：碎片 1a2b3c4d）", at: "x").isEmpty, "正好 30 字不算超")
        XCTAssertEqual(CatalogChecks.record(thirty + "家（出处：碎片 1a2b3c4d）", at: "x").first?.message.contains("31 字"), true)
        XCTAssertEqual(CatalogChecks.listLines("对花生过敏。\n  - 喜欢面包\n· 不吃香菜\n●减糖\n▪ 近视\n-5 度也晨跑"),
                       ["- 喜欢面包", "· 不吃香菜", "▪ 近视"], "标记后面跟空格才算；负号、拿不准的不算")
    }

    /// 三项硬查、两种格式诊断各一条坏输出：被抓到 → 告诉模型哪一项、在哪儿 → 重写后通过，不留标记
    func testEachRevisionReasonIsCaughtAndPassesAfterOneRewrite() async throws {
        let fresh = CatalogSorter.Topic(path: "楼层/人/阿杰", title: "阿杰", kind: .person, existing: false, fragmentIds: [f2.id])
        let newPage = { (relation: String) in
            "{\"items\":[{\"type\":\"new_page\",\"path\":\"楼层/人/阿杰\",\"kind\":\"人\",\"title\":\"阿杰\",\"hook\":\"当她提到阿杰时先看这页\",\"now\":\"同事（自 2026-10 起）。\",\"records\":[{\"text\":\"2026-10-12 请吃饭\",\"fragments\":[\"f1\"]}],\"links\":[{\"to\":\"楼层/人/小慧\",\"relation\":\"\(relation)\",\"why\":\"室友的同事\"}]}]}"
        }
        let rewriteNow = "{\"type\":\"rewrite_now\",\"path\":\"楼层/人/小慧\",\"now\":\"室友，搬去七楼了（自 2026-10-13 起）。\"}"
        let cases: [(name: String, topic: CatalogSorter.Topic, bad: String, good: String, location: String, mention: String)] = [
            ("现在里的列表行", existingTopic(),
             "{\"items\":[{\"type\":\"rewrite_now\",\"path\":\"楼层/人/小慧\",\"now\":\"- 室友（自 2026-09 起）\\n- 搬去七楼了（自 2026-10-13 起）\"}]}",
             "{\"items\":[\(rewriteNow)]}", "items[0] 楼层/人/小慧", "「- 搬去七楼了（自 2026-10-13 起）」"),
            ("记录超 30 字", existingTopic(), "{\"items\":[\(append(longRecord))]}", "{\"items\":[\(append("2026-10-13 搬去七楼"))]}",
             "items[0] 楼层/人/小慧.records[0]", "超过 30 字"),
            ("关系不在四种", fresh, newPage("替代"), newPage("补充"), "items[0] 楼层/人/阿杰.links[0]", "「替代」不在 补充 / 矛盾 / 共鸣 / 引用 之内"),
            ("不认识的条目类型", existingTopic(),
             "{\"items\":[\(append("2026-10-13 搬去七楼")),{\"type\":\"rewrite_records\",\"path\":\"楼层/人/小慧\",\"records\":[{\"text\":\"2026-10-01 认识\",\"fragments\":[\"f1\"]}]}]}",
             "{\"items\":[\(append("2026-10-13 搬去七楼"))]}", "items[1] 楼层/人/小慧", "不支持的条目类型：rewrite_records"),
            ("条目带了不收的字段", existingTopic(),
             "{\"items\":[{\"type\":\"rewrite_now\",\"path\":\"楼层/人/小慧\",\"now\":\"室友，搬去七楼了（自 2026-10-13 起）。\",\"records\":[{\"text\":\"2026-10-13 搬去七楼\",\"fragments\":[\"f1\"]}]}]}",
             "{\"items\":[\(rewriteNow),\(append("2026-10-13 搬去七楼"))]}", "items[0] 楼层/人/小慧", "type=rewrite_now 不收 records 字段，改用 append"),
        ]
        for c in cases {
            let m = await material(c.topic, fragments: [f2])
            let run = CatalogRunRecord(wiki: wiki, topic: c.name, kind: "测试")
            var users: [String] = []
            let written = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, user in
                users.append(user)
                return users.count == 1 ? c.bad : c.good
            }, drafts: nil, run: run)
            let parsed = try XCTUnwrap(written, c.name)
            XCTAssertEqual(users.count, 2, "\(c.name)：只给一次重写")
            let note = String(users[1].dropFirst(users[0].count))
            XCTAssertTrue(note.contains(c.location + "：") && note.contains(c.mention), "\(c.name)：告诉模型哪项、在哪儿：\(note)")
            XCTAssertTrue(note.contains(c.bad), "\(c.name)：上次交的原样附上")
            XCTAssertEqual(parsed.revisionNotes, [], c.name)
            XCTAssertEqual(parsed.unapplied, [], c.name)
            XCTAssertEqual(parsed.revision, "重写一次后通过", "\(c.name)：如实显示修订状态")
            XCTAssertTrue(parsed.items.allSatisfy { $0.checks == nil }, c.name)
            XCTAssertFalse(parsed.items.isEmpty, c.name)
            await run.flush()
            XCTAssertTrue(try String(contentsOf: run.url, encoding: .utf8).contains("没过检查，重写一次"), c.name)
        }
    }

    /// 修订用不了：第二稿还没过就交第二稿；交坏、交上来的全被扔掉、没回、出错就交第一稿。都不截字、标明走到哪一步；取消照旧抛
    func testRevisionThatCannotBeUsedDeliversTheFirstDraftWithTheReason() async throws {
        let m = await material(existingTopic(), fragments: [f2])
        let bad = "{\"items\":[\(append(longRecord))]}"
        struct Down: LocalizedError { var errorDescription: String? { "服务商 503" } }
        let cases: [(second: () throws -> String?, revision: String)] = [
            ({ bad }, "重写一次后仍有没过的"),
            ({ "{\"items\":\n```坏了" }, "不是合格的 JSON"),
            ({ "{\"items\":[{\"type\":\"append\",\"path\":\"楼层/人/小慧\",\"records\":[{\"text\":\"2026-10-13 搬家\",\"fragments\":[\"f999\"]}]}]}" },
             "没有能用的内容"),
            ({ nil }, "没回"),
            ({ throw Down() }, "出错（服务商 503）"),
        ]
        for c in cases {
            var calls = 0
            let written = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
                calls += 1
                return calls == 1 ? bad : try c.second()
            }, drafts: nil)
            let parsed = try XCTUnwrap(written, c.revision)
            XCTAssertEqual(calls, 2, "重写只给一次")
            XCTAssertTrue(parsed.revision?.contains(c.revision) ?? false, "\(parsed.revision ?? "nil")")
            let item = try XCTUnwrap(parsed.items.first)
            guard case .appendRecords(_, let lines) = item.change else { return XCTFail() }
            XCTAssertTrue(lines[0].hasPrefix(longRecord + "（出处："), "不截字")
            XCTAssertTrue(item.checks?.first?.contains("超过 30 字") ?? false)
        }
        var calls = 0
        do {
            _ = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
                calls += 1
                if calls == 1 { return bad }
                throw CancellationError()
            }, drafts: nil)
            XCTFail("取消要照旧抛出")
        } catch is CancellationError {}
    }

    /// 收不进页的内容（关系不在四种、不认识的类型、带了不收的字段）合成一个列表：原文、来源页、原因；不挂到别页的条目上，整稿只有它也留下
    func testUnappliedContentKeepsTheOriginalOperationAndItsPage() throws {
        let json = """
        {"items":[\(append("2026-10-13 搬去七楼")),
          {"type":"new_page","path":"楼层/人/阿杰","kind":"人","title":"阿杰","now":"同事（自 2026-10 起）。",
           "records":[{"text":"2026-10-12 请吃饭","fragments":["f1"]}],"links":[{"to":"楼层/人/小慧","relation":"替代"}]},
          {"type":"link","path":"楼层/人/小慧","to":"楼层/人/阿杰","relation":"取代","why":"旧说法作废"},
          {"type":"delete_records","path":"楼层/人/小慧"},
          {"type":"rewrite_now","path":"楼层/人/小慧","now":"室友。","records":[{"text":"2026-10-01 认识","fragments":["f1"]}]}]}
        """
        let parsed = try XCTUnwrap(CatalogItems.parse(json, sources: sources, wiki: wiki))
        XCTAssertEqual(parsed.items.count, 2)
        XCTAssertTrue(parsed.items.allSatisfy { $0.checks == nil }, "不挂到别的条目上")
        XCTAssertEqual(parsed.unapplied.map(\.page), ["楼层/人/阿杰", "楼层/人/小慧", "楼层/人/小慧", "楼层/人/小慧"])
        XCTAssertEqual(parsed.unapplied[0].raw, #"{"relation":"替代","to":"楼层/人/小慧"}"#, "原样留下")
        XCTAssertTrue(parsed.unapplied[1].raw.contains(#""why":"旧说法作废""#) && parsed.unapplied[1].reason.contains("「取代」不在"))
        XCTAssertTrue(parsed.unapplied[2].raw.contains("delete_records") && parsed.unapplied[2].reason.contains("不支持的条目类型"))
        XCTAssertTrue(parsed.unapplied[3].raw.contains("2026-10-01 认识") && parsed.unapplied[3].reason.contains("不收 records 字段"))
        XCTAssertEqual(parsed.revisionNotes.count, 4, "都算没过，给那一次修订")
        XCTAssertEqual(parsed.dropped, 0, "不算扔掉")

        let alone = try XCTUnwrap(CatalogItems.parse("{\"items\":[{\"type\":\"link\",\"path\":\"楼层/人/小慧\",\"to\":\"楼层/人/阿杰\",\"relation\":\"取代\"}]}",
                                                     sources: sources, wiki: wiki))
        XCTAssertEqual(alone.items, [])
        XCTAssertEqual(alone.unapplied.map(\.page), ["楼层/人/小慧"], "没有条目可挂也留着")
        XCTAssertTrue(alone.deliverable)
    }

    /// 只有没收进页的内容的提案：她点「知道了」之前算待阅、计入角标、不进 30 天清理
    func testUnappliedOnlyProposalStaysUnreadUntilAcknowledged() throws {
        let store = WikiProposalStore(wiki: wiki)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        var p = WikiProposal(origin: .scheduled, createdAt: old, items: [])
        p.unapplied = [.init(page: "楼层/人/小慧", raw: #"{"relation":"取代"}"#, reason: "关系不对", at: "items[0]")]
        try store.save(p)
        XCTAssertEqual(store.load(p.id)?.status, .pending)
        XCTAssertEqual(store.pendingItemCount(), 1)
        XCTAssertEqual(WikiProposalDisplay.statusText(try XCTUnwrap(store.load(p.id))), "待阅 1 处没收进页的内容")
        XCTAssertEqual(store.purgeFinished(now: old.addingTimeInterval(90 * 86_400)), 0, "没看过不清")
        let seen = try store.acknowledgeUnapplied(p.id, now: old.addingTimeInterval(60 * 86_400))
        XCTAssertEqual(seen.status, .done)
        XCTAssertEqual(store.pendingItemCount(), 0)
        XCTAssertEqual(store.purgeFinished(now: old.addingTimeInterval(80 * 86_400)), 0, "从点「知道了」起算 30 天")
        XCTAssertEqual(store.purgeFinished(now: old.addingTimeInterval(91 * 86_400)), 1)
    }

    /// 每次真正要发的请求都重查：重写附上上一稿后放不下，就不发，交第一稿并写明原因
    func testRewriteThatNoLongerFitsIsNotSent() async throws {
        let m = await material(existingTopic(), fragments: [f2])
        let limit = CatalogWriter.userContent(m, names: names).count + 20
        let bad = "{\"items\":[\(append(longRecord))]}"
        var calls = 0
        let written = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
            calls += 1
            return bad
        }, drafts: nil, trim: { system, user in (system, String(user.suffix(limit))) })
        let parsed = try XCTUnwrap(written)
        XCTAssertEqual(calls, 1, "放不下的重写请求不发")
        XCTAssertTrue(parsed.revision?.contains("放不进当前模型") ?? false, parsed.revision ?? "nil")
        XCTAssertTrue(parsed.revision?.contains("楼层/人/小慧") ?? false, "说明挤掉的是哪页全文：\(parsed.revision ?? "")")
        XCTAssertTrue(parsed.items.first?.checks?.isEmpty == false)
    }

    /// 本机：系统提示送不全就不写，人话说明缺了哪几节、各多长；不裁剪、不换模型、不发请求
    func testLocalSystemPromptThatDoesntFitFailsInPlainWords() async throws {
        let m = await material(existingTopic(), fragments: [f2])
        let system = CatalogWriter.systemPrompt(names: names)
        XCTAssertGreaterThan(system.count, LocalChatProvider.systemBudget)
        var called = false
        do {
            _ = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
                called = true
                return nil
            }, drafts: nil, trim: CatalogLocalTrim.apply)
            XCTFail("系统提示送不全必须失败")
        } catch let error as CatalogWriterError {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("写作规则放不进当前模型") && text.contains("系统提示共 \(system.count) 字")
                          && text.contains("只收得下前 \(LocalChatProvider.systemBudget) 字") && text.contains("「记录」"), text)
        }
        XCTAssertFalse(called)
    }

    /// 判不准的三样只记日志，不触发重写
    func testSoftChecksOnlyGoToTheRunRecord() async throws {
        let topic = CatalogSorter.Topic(path: "楼层/人/阿杰", title: "阿杰", kind: .person, existing: false, fragmentIds: [f2.id])
        let m = await material(topic, fragments: [f2])
        let run = CatalogRunRecord(wiki: wiki, topic: "只记日志", kind: "测试")
        var calls = 0
        let written = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
            calls += 1
            return """
            {"items":[{"type":"new_page","path":"楼层/人/阿杰","kind":"人","title":"阿杰","hook":"阿杰的信息","now":"同事。爱吃辣（自 2026-10 起）。",
              "records":[{"text":"2026-10-12 粟粟请阿杰吃饭","fragments":["f1"]}]}]}
            """
        }, drafts: nil, run: run)
        let parsed = try XCTUnwrap(written)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(parsed.items.first?.checks)
        await run.flush()
        let report = try String(contentsOf: run.url, encoding: .utf8)
        for text in ["只记日志的检查", "钩子没写「当……时」的场景：阿杰的信息", "这句没有时间锚：同事", "以「粟粟」开头"] {
            XCTAssertTrue(report.contains(text), text)
        }
        XCTAssertFalse(report.contains("这句没有时间锚：爱吃辣"))
    }

    /// 带着标记被她改过的条目记一笔「编辑后未重新检查」
    func testEditingAFlaggedItemMarksItsChecksAsStale() throws {
        let store = WikiProposalStore(wiki: wiki)
        let flagged = WikiProposal.Item(change: .appendRecords(path: "楼层/人/小慧", lines: [longRecord]), baseVersion: wiki.version(of: "楼层/人/小慧"),
                                        checks: ["超过 30 字"])
        let clean = WikiProposal.Item(change: .appendRecords(path: "楼层/人/小慧", lines: ["2026-10-13 搬去七楼"]), baseVersion: wiki.version(of: "楼层/人/小慧"))
        let p = WikiProposal(origin: .scheduled, createdAt: Date(), items: [flagged, clean])
        try store.save(p)
        try store.edit(p.id, itemId: flagged.id, change: .appendRecords(path: "楼层/人/小慧", lines: ["2026-10-13 搬去七楼"]), judgment: nil)
        try store.edit(p.id, itemId: clean.id, change: .appendRecords(path: "楼层/人/小慧", lines: ["2026-10-13 搬家"]), judgment: nil)
        let saved = try XCTUnwrap(store.load(p.id))
        XCTAssertEqual(saved.items.map(\.checksEdited), [true, nil])
        XCTAssertEqual(saved.items[0].checks, ["超过 30 字"], "检查历史保留")
    }

    // MARK: - 分组调整

    private func crowd(_ n: Int) throws {
        for i in 0..<n {
            try wiki.save(WikiPage(path: "楼层/人/人\(i)", kind: .person, triggers: ["人\(i)"], hook: "", title: "人\(i)"))
        }
    }

    func testRegroupParse() throws {
        try crowd(31)
        try FileManager.default.createDirectory(at: wiki.folderURL("楼层/人/家人"), withIntermediateDirectories: true)
        XCTAssertEqual(wiki.overfullLayers(), ["楼层/人"])
        let raw = """
        {"groups":[
          {"name":"朋友","hook":"她提到朋友时","members":["楼层/人/人0","楼层/人/人1","楼层/人/人1","楼层/人/谁"]},
          {"name":"同事","hook":"她提到同事时","members":["楼层/人/人1","楼层/人/人2"]},
          {"name":"家人","members":["楼层/人/人3","楼层/人/人4"]},
          {"name":"a/b","members":["楼层/人/人5","楼层/人/人6"]},
          {"name":"邻居","members":["楼层/人/人7","/楼层/人/人8.md"]}
        ]}
        """

        let items = try XCTUnwrap(CatalogRegrouper.parse(raw, layer: "楼层/人", wiki: wiki))

        XCTAssertEqual(items.count, 1)
        guard case .regroup(let layer, let groups, let moves) = items[0].change else { return XCTFail() }
        XCTAssertEqual(layer, "楼层/人")
        XCTAssertEqual(groups, [.init(path: "楼层/人/朋友", hook: "她提到朋友时"), .init(path: "楼层/人/邻居", hook: "")],
                       "同事只剩 1 项、家人已有文件夹、名字带斜杠的都扔")
        XCTAssertEqual(moves, [.init(from: "楼层/人/人0", to: "楼层/人/朋友/人0"), .init(from: "楼层/人/人1", to: "楼层/人/朋友/人1"),
                               .init(from: "楼层/人/人7", to: "楼层/人/邻居/人7"), .init(from: "楼层/人/人8", to: "楼层/人/邻居/人8")])
        XCTAssertEqual(CatalogRegrouper.parse("{\"groups\":[]}", layer: "楼层/人", wiki: wiki), [])
        XCTAssertNil(CatalogRegrouper.parse("分好了", layer: "楼层/人", wiki: wiki))

        let store = WikiProposalStore(wiki: wiki)
        try store.save(WikiProposal(origin: .scheduled, createdAt: Date(), items: items))
        XCTAssertEqual(CatalogRegrouper.pendingLayers(store), ["楼层/人"], "她还没批的那层不再提")
    }

    // MARK: - 每天自动那次：先只提方向（代码，不调写手），批了才写；单个方向失败不连坐、超 30 行带分组调整

    func testDailyDirectionsThenWriteFailureIsolatedWithRegroup() async throws {
        try crowd(31)
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        let rows: [(String, String)] = [("看电影", "电影"), ("又看电影", "电影"), ("电影票", "电影"), ("电影院冷", "电影"),
                                        ("周五看剧", "剧场"), ("剧散场", "剧场"), ("剧票", "剧场"), ("怕香菜", "香菜")]
        for (i, row) in rows.enumerated() {
            let m = Memory(content: row.0, category: "fact", profileId: pid)
            m.subject = row.1
            m.occurredDay = "2026-10-1\(i)"
            m.reviewedAt = Date()
            ctx.insert(m)
        }
        try ctx.save()
        var writerCalls: [String: Int] = [:]
        var regroupCalls = 0
        let caller: SessionSegmentWriter.Caller = { system, user in
            if system.contains("太长了") {
                regroupCalls += 1
                return "{\"groups\":[{\"name\":\"朋友\",\"hook\":\"她提到朋友时\",\"members\":[\"楼层/人/人0\",\"楼层/人/人1\"]}]}"
            }
            let title = user.contains("标题：电影") ? "电影" : "剧场"
            writerCalls[title, default: 0] += 1
            if title == "剧场" { return "这个主题我写不出来" }
            return "{\"items\":[{\"type\":\"new_page\",\"path\":\"楼层/事/电影\",\"kind\":\"事\",\"title\":\"电影\",\"records\":[{\"text\":\"2026-10-10 看电影\",\"fragments\":[\"f1\"]}]}]}"
        }
        let job = CatalogTestKit.job(pid: pid, root: root, container: container, caller: caller)
        let store = WikiProposalStore(wiki: wiki)

        let report = await CatalogSession(job: job).daily(now: Date())

        XCTAssertEqual(writerCalls, [:], "第一批只提方向，一个写手都不调")
        XCTAssertEqual(report.proposals, 1, "方向和分组调整汇成一份")
        let p = try XCTUnwrap(store.list().first)
        XCTAssertEqual(p.origin, .scheduled)
        XCTAssertEqual(p.items.compactMap(\.change.direction?.path), ["楼层/主题/电影", "楼层/主题/剧场"], "碎片多的先；香菜只有 1 条不够开页")
        XCTAssertEqual(p.items.compactMap(\.change.direction?.clues.count), [4, 3])
        guard case .regroup(let layer, _, _) = p.items[2].change else { return XCTFail("第三条应该是分组调整") }
        XCTAssertEqual(layer, "楼层/人")
        XCTAssertEqual(regroupCalls, 1)

        let directionIds = Set(p.items.filter { $0.change.direction != nil }.map(\.id))
        try await WikiProposalReview.approve(p.id, itemIds: directionIds, store: store, profileId: pid, context: ModelContext(container))
        let run = await CatalogSession(job: job).directions(p.id)

        XCTAssertEqual(writerCalls, ["电影": 1, "剧场": 3], "批了才写；写坏的那个重来 2 次后放弃")
        XCTAssertEqual(run.failures.count, 1)
        XCTAssertEqual(run.proposals, 1)
        let content = try XCTUnwrap(store.list().first { $0.directionRef != nil })
        XCTAssertEqual(content.items.count, 1)
        XCTAssertEqual(content.items[0].fragmentIds.count, 1, "只挂明确引用的那条（astra #7），分到却没用上的留在池里")
        XCTAssertFalse(wiki.pageExists("楼层/事/电影"), "正文还没批，不落页")
        let results = try XCTUnwrap(store.load(p.id)).items.compactMap(\.change.direction?.result)
        XCTAssertTrue(results[0].hasPrefix("交了 1 条正文等批"))
        XCTAssertTrue(results[1].hasPrefix("出错"))

        _ = await CatalogSession(job: job).daily(now: Date())
        XCTAssertEqual(regroupCalls, 1, "那层的分组调整还没批，不再提")
        XCTAssertEqual(store.list().count, 2, "处理过的方向没有新碎片不再提，失败的也不自动续跑")
        XCTAssertEqual(writerCalls, ["电影": 1, "剧场": 3])
    }

    func testDailyMaxTopicsAndBlockedExecutionMarksNothing() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        var ids: [UUID] = []
        for i in 0..<6 {
            let m = Memory(content: "碎片\(i)", category: "fact", profileId: pid)
            m.subject = i < 3 ? "甲" : "乙"
            m.occurredDay = "2026-10-1\(i)"
            m.reviewedAt = Date()
            ctx.insert(m)
            ids.append(m.id)
        }
        try ctx.save()
        var calls = 0
        let job = CatalogTestKit.job(pid: pid, root: root, container: container, caller: { _, _ in calls += 1; return nil }, maxTopics: 1)
        let store = WikiProposalStore(wiki: wiki)

        let r = await CatalogSession(job: job).daily(now: Date())
        XCTAssertEqual(r.items, 1, "自动一次最多 maxTopics 个，剩下的下次")
        let p = try XCTUnwrap(store.list().first)
        XCTAssertEqual(p.items.first?.change.direction?.title, "甲")
        XCTAssertEqual(calls, 0)

        try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: ModelContext(container))
        let blocked = await CatalogSession(job: job).directions(p.id)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(blocked.blocked)
        XCTAssertEqual(blocked.proposals, 0)
        XCTAssertTrue(try XCTUnwrap(store.load(p.id)?.items.first?.change.direction?.result).hasPrefix("被拦"))
        let rows = try ModelContext(container).fetch(FetchDescriptor<Memory>())
        XCTAssertTrue(rows.allSatisfy { $0.organizedAt == nil && $0.organizeRejectedAt == nil }, "被拦不打标")

        _ = await CatalogSession(job: job).directions(p.id)
        XCTAssertEqual(calls, 1, "执行过（被拦也算）不自动续跑，不重付")
    }
}
