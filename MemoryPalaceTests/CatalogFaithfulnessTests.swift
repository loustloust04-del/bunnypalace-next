import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 第 10 段：来源检查一个入口（只认这次实际、完整给模型的出处）、Coverage / Preservation 和正文分开解析且只记日志、纯代码 wiki 体检
@MainActor
final class CatalogFaithfulnessTests: XCTestCase {
    private let pid = "xctest-catalog-faithfulness"
    private let names = CatalogTestKit.names
    private var root: URL!
    private var wiki: WikiStore { WikiStore(root: root.appendingPathComponent("wiki", isDirectory: true)) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-faithfulness-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private func container() throws -> ModelContainer {
        let schema = ProfileManager.makeFullSchema()
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// 沿提案上的 run 链接打开那一份记录，取锚点那一节（到下一个锚点为止）
    private func section(_ link: CatalogRunLink?) throws -> (file: String, section: String) {
        let link = try XCTUnwrap(link, "提案带着整理记录的链接")
        let url = try XCTUnwrap(CatalogRunRecord.resolve(link, wiki: wiki))
        let text = try String(contentsOf: url, encoding: .utf8)
        let anchor = try XCTUnwrap(link.anchor)
        let start = try XCTUnwrap(text.range(of: "<a id=\"\(anchor)\"></a>"))
        let rest = text[start.upperBound...]
        let end = rest.range(of: "<a id=\"")?.lowerBound ?? rest.endIndex
        return (text, String(rest[..<end]))
    }

    // MARK: - 来源检查

    private let day = Date(timeIntervalSince1970: 1_791_800_000)
    private let given = CatalogFragment(id: UUID(), content: "豆包改吃处方粮", category: "fact", day: "2026-10-12")
    private let tail = CatalogFragment(id: UUID(), content: "豆包怕吸尘器", category: "fact", day: "2026-10-13")

    private func segment(_ parts: [String] = ["兽医说要控制体重"]) -> CatalogALineReader.Hit {
        .init(layer: .a2, conversationId: "0001aaaa-conv", title: "看病", start: day, end: day, day: "2026-10-12",
              segment: 2, messages: 12..<30, parts: parts.map { .init(text: $0, isBody: true) }, old: nil)
    }

    private func a4(_ date: String, _ lines: [String]) -> CatalogALineReader.Hit {
        .init(layer: .a4, conversationId: nil, title: "", start: day, end: day, day: date,
              parts: lines.map { CatalogSearchPart(text: $0, isBody: true) }, old: nil)
    }

    /// 一条新开页混进各种出处，逐行断言留下哪些：只认这次实际给过的碎片、A2 段、A3 层、原文节点、Prompt 槽、CC 文件、日 A4；
    /// 回执截掉的尾部（碎片、那一天）不算给过
    func testMixedCitationsKeepOnlyWhatWasActuallyGiven() throws {
        let node = SearchService.CatalogNode(profileId: pid, conversationId: "original-conversation", nodeId: "shown-node", title: "看病",
                                             created: day, role: "user", onMain: true, body: "豆包今天体检")
        var receipt = CatalogSearchReceipt(vectorStatus: "不可用")
        receipt.append("\n- f1 · ")
        receipt.appendBody(given.content, kind: .fragment, source: .fragment("f1", given))
        receipt.append("\n")
        receipt.appendALine(segment())
        receipt.append("\n")
        receipt.appendALine(a4("2026-10-12", ["带豆包看病"]))
        receipt.append("\n【原文】")
        receipt.appendBody(node.body, kind: .original, source: .original(node))
        let cut = receipt.text.count
        receipt.append("\n- f2 · ")
        receipt.appendBody(tail.content, kind: .fragment, source: .fragment("f2", tail))
        receipt.append("\n")
        receipt.appendALine(a4("2026-10-13", ["买猫砂"]))

        var sources = CatalogSources()
        receipt.prefix(cut).register(in: &sources)
        let slot = PromptFolder.path(for: .slot(presetId: "preset-1", slotId: "persona"))
        sources.addFile(slot, cite: .init(layer: "Prompt", filePath: slot, name: "人设"))
        sources.addFile("memory/cc/user_cat.md", cite: .init(layer: "CC", filePath: "memory/cc/user_cat.md"))

        let parsed = try XCTUnwrap(CatalogItems.parse("""
        {"items":[{"type":"new_page","path":"人/豆包","kind":"人","title":"豆包","records":[
          {"text":"2026-10-12 改吃处方粮","fragments":["f1"]},
          {"text":"2026-10-12 没出处"},
          {"text":"2026-10-12 伪造编号","fragments":["f99"]},
          {"text":"2026-10-13 截掉的尾部碎片","fragments":["f2"]},
          {"text":"2026-10-12 给过的段","aline":[{"layer":"A2","window":"0001aaaa","segment":2}]},
          {"text":"2026-10-12 没给的段","aline":[{"layer":"A2","window":"0001aaaa","segment":9}]},
          {"text":"2026-10-12 没给的层","aline":[{"layer":"A3","window":"0001aaaa"}]},
          {"text":"2026-10-12 给过的原文","aline":[{"layer":"原文","nodeId":"shown-node"}]},
          {"text":"2026-10-12 没给的原文","aline":[{"layer":"原文","nodeId":"other-node"}]},
          {"text":"日期未注明 Prompt 槽","sources":["\(slot)"]},
          {"text":"日期未注明 CC 文件","sources":["memory/cc/user_cat.md"]},
          {"text":"日期未注明 没读的 CC 文件","sources":["memory/cc/user_other.md"]},
          {"text":"2026-10-12 给过的那天","aline":[{"layer":"A4","day":"2026-10-12"}]},
          {"text":"2026-10-13 截掉的那天","aline":[{"layer":"A4","day":"2026-10-13"}]},
          {"text":"2026-10-12 伪造编号配真段","fragments":["f99"],"aline":[{"layer":"A2","window":"0001aaaa","segment":2}]}
        ]}]}
        """, sources: sources, wiki: wiki))

        guard case .newPage(let page) = try XCTUnwrap(parsed.items.first).change else { return XCTFail("应该是新开页") }
        XCTAssertEqual(page.records.map { CatalogSources.split($0).body }, [
            "2026-10-12 改吃处方粮", "2026-10-12 给过的段", "2026-10-12 给过的原文", "日期未注明 Prompt 槽", "日期未注明 CC 文件",
            "2026-10-12 给过的那天", "2026-10-12 伪造编号配真段",
        ])
        XCTAssertEqual(page.records.map { CatalogSources.split($0).labels?.first }, [
            CatalogSources.label(given.id), "A2《看病》第 2 段",
            WikiProposalDisplay.citeText(try XCTUnwrap(parsed.items.first?.cites.first { $0.layer == "原文" }), titles: ["original-conversation": "看病"]),
            "Prompt 人设", "CC memory/cc/user_cat.md", "A4 2026-10-12", "A2《看病》第 2 段",
        ])
        XCTAssertEqual(parsed.dropReasons.map { String($0.prefix { $0 != "：" }) },
                       [1, 2, 3, 5, 6, 8, 11, 13].map { "items[0] 人/豆包.records[\($0)]" })
        XCTAssertEqual(parsed.items[0].fragmentIds, [given.id], "伪造编号、截掉的尾部碎片都挂不上")
    }

    /// 正文中途被截断：截到半截的碎片、A2 段（后一段正文没进来）、日 A4（后几项没进来）都不能引用；截点之前完整的照常
    func testSourceCutMidwayIsNotCitable() throws {
        var receipt = CatalogSearchReceipt(vectorStatus: "不可用")
        receipt.appendBody(given.content, kind: .fragment, source: .fragment("f1", given))
        receipt.append("\n")
        receipt.appendALine(a4("2026-10-12", ["带豆包看病", "下午买猫砂"]))
        receipt.append("\n")
        receipt.appendALine(segment(["兽医说要控制体重", "回家路上豆包一直叫"]))
        let text = receipt.text
        func citable(_ count: Int) -> (fragment: Bool, day: Bool, segment: Bool) {
            var s = CatalogSources()
            receipt.prefix(count).register(in: &s)
            return (s.fragments["f1"] != nil, s.days.contains("2026-10-12"), s.segments["0001aaaa#2"] != nil)
        }
        let inFragment = given.content.count - 2
        let inDay = text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: "下午买")).upperBound)
        let inSegment = text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: "回家路上")).upperBound)
        XCTAssertTrue(citable(inFragment) == (false, false, false), "碎片只出现了半截")
        XCTAssertTrue(citable(inDay) == (true, false, false), "那天第二项只出现半截：整天不能引用")
        XCTAssertTrue(citable(inSegment) == (true, true, false), "A2 第二段正文只出现半截：这一段不能引用")
        XCTAssertTrue(citable(text.count) == (true, true, true))
    }

    // MARK: - 诊断和正文分开解析

    private let f1 = CatalogFragment(id: UUID(), content: "豆包改吃处方粮", category: "fact", day: "2026-10-12")
    private let f2 = CatalogFragment(id: UUID(), content: "豆包体重 6kg", category: "fact", day: "2026-10-13")
    private let f3 = CatalogFragment(id: UUID(), content: "豆包怕吸尘器", category: "fact", day: "2026-10-14")
    private let path = "人/豆包"
    private var rewrite: String {
        """
        {"items":[
          {"type":"rewrite_now","path":"\(path)","now":"橘猫，公，2 岁（自 2026-09 起）。改吃处方粮（自 2026-10-12 起）。","fragments":["f1"]},
          {"type":"append","path":"\(path)","records":[{"text":"2026-10-12 改吃处方粮","fragments":["f1"]},{"text":"2026-10-13 体重 6kg","fragments":["f99"]}]}]}
        """
    }

    private func existingPage() throws {
        try wiki.save(WikiPage(path: path, kind: .person, triggers: ["豆包"], hook: "当粟粟说豆包时先看这页", title: "豆包",
                               now: "橘猫，公，2 岁（自 2026-09 起）。吃普通猫粮（自 2026-09 起）。"))
    }

    private func material() async throws -> CatalogWriter.Material {
        let topic = CatalogSorter.Topic(path: path, title: "豆包", kind: .person, existing: true, fragmentIds: [f1.id, f2.id, f3.id])
        return await CatalogWriter.material(topic, fragments: [f1, f2, f3], floorPrompt: "", wiki: wiki, memoryRoot: root, now: Date(),
                                            embedder: CatalogFakeEmbedder.unavailable())
    }

    /// 写手先交正文对象、再交诊断对象：诊断完整就收；诊断被截断或坏了，正文照收、不重来、不修订，诊断记未评估
    func testWriterDiagnosticsAreSeparateAndBrokenOrTruncatedOnesNeverCostTheBody() async throws {
        try existingPage()
        let m = try await material()
        let diagnostics = """
        {"coverage":[{"input":"f1","at":"现在 + 记录"},{"input":"f2","at":"记录"},{"input":"f3","why":"只是随口一提"},{"input":"f7","at":"记录"}],
         "preservation":[{"page":"\(path)","old":"吃普通猫粮","status":"改了","new":"改吃处方粮","why":"f1"},{"old":"会开橱柜门","status":"疑似漏了"}]}
        """
        for (label, tail, expectCoverage) in [("完整", "\n" + diagnostics, true),
                                               ("截断", "\n" + String(diagnostics.prefix(60)), false),
                                               ("坏了", "\n{\"coverage\":[{\"input\":\"f1\",\"at\":\"记录\" \"why\":}]}", false)] {
            var calls = 0
            let written = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in
                calls += 1
                return self.rewrite + tail
            }, drafts: nil)
            let parsed = try XCTUnwrap(written, label)
            XCTAssertEqual(calls, 1, "\(label)：不追加请求")
            XCTAssertNil(parsed.revision, "\(label)：不触发修订")
            XCTAssertEqual(parsed.items.map(\.change.kindLabel), ["改现在", "追加记录"], label)
            XCTAssertEqual(parsed.coverage != nil, expectCoverage, label)
            let coverage = CatalogDiagnostics.coverage(parsed, sources: m.sources)
            if expectCoverage {
                XCTAssertTrue(coverage.contains("- f1：「现在 + 记录」"))
                XCTAssertTrue(coverage.contains("- f2：写手说在「记录」，交审条目上没挂它"), "坏行不能冒充覆盖")
                XCTAssertTrue(coverage.contains("声明了没覆盖：\n- f3：只是随口一提"))
                XCTAssertTrue(coverage.contains("不是这次给的输入，不算：\n- f7"))
                XCTAssertTrue(CatalogDiagnostics.preservation(parsed).contains("- 疑似漏了：会开橱柜门"))
            } else {
                XCTAssertTrue(coverage.contains("没交代（未评估）：f1、f2、f3"), coverage)
                XCTAssertTrue(CatalogDiagnostics.preservation(parsed).contains("未评估"))
            }
            XCTAssertFalse(coverage.contains("通过"))
        }
    }

    /// 真模型（iPhone 14 live）的形状：正文、诊断各包一段 ```json 围栏，中间空一行；另验没有围栏、中间隔一句说明文字。诊断都要认出来
    func testDiagnosticsAfterBodyInSeparateFencesOrAfterProseAreRead() async throws {
        try existingPage()
        let m = try await material()
        let body = """
        {"items":[{"type":"rewrite_now","path":"\(path)","now":"橘猫，公，2 岁（自 2026-09 起）。改吃处方粮（自 2026-10-12 起）。","judgment":"conflict"},{"type":"append","path":"\(path)","records":[{"text":"2026-10-12 改吃处方粮","fragments":["f1"]},{"text":"2026-10-13 体重 6kg","fragments":["f2"]}],"judgment":"conflict"}],"covered":["f1","f2"],"single":["f3"]}
        """
        let diagnostics = """
        {"coverage":[{"input":"f1","at":"\(path) · 现在 + 记录"},{"input":"f2","at":"\(path) · 记录"},{"input":"f3","why":"与豆包无关"}],"preservation":[{"page":"\(path)","old":"吃普通猫粮（自 2026-09 起）","status":"改了","new":"改吃处方粮","why":"f1"},{"page":"\(path)","old":"橘猫，公，2 岁（自 2026-09 起）","status":"保留"}]}
        """
        for (label, raw) in [("两段围栏", "```json\n\(body)\n```\n\n```json\n\(diagnostics)\n```"),
                             ("说明文字", "\(body)\n\n诊断如下：\n\(diagnostics)")] {
            let written = try await CatalogWriter.write(m, names: names, wiki: wiki, caller: { _, _ in raw }, drafts: nil)
            let parsed = try XCTUnwrap(written, label)
            XCTAssertEqual(parsed.items.count, 2, label)
            XCTAssertEqual(parsed.coverage?.count, 3, label)
            XCTAssertEqual(parsed.preservation?.count, 2, label)
            let coverage = CatalogDiagnostics.coverage(parsed, sources: m.sources)
            XCTAssertTrue(coverage.contains("- f1：「\(path) · 现在 + 记录」"), "\(label)：\(coverage)")
            XCTAssertTrue(coverage.contains("- f2：「\(path) · 记录」"), label)
            XCTAssertFalse(coverage.contains("未评估"), label)
            XCTAssertTrue(CatalogDiagnostics.preservation(parsed).contains("- 改了：吃普通猫粮（自 2026-09 起） → 改吃处方粮（f1）"), label)
        }
    }

    /// 交审诊断按最终条目算：没挂到任何条目上的 covered 不算写进了页
    func testUnattachedCoveredDoesNotCountAsCovered() throws {
        var sources = CatalogSources()
        sources.addFragments([f1])
        var parsed = try XCTUnwrap(CatalogItems.parse("{\"items\":[],\"covered\":[\"f1\"]}\n{\"coverage\":[{\"input\":\"f1\",\"at\":\"人/没有的页\"}]}",
                                                      sources: sources, wiki: wiki))
        parsed.covered = CatalogItems.attachCovered(&parsed.items, covered: parsed.covered, path: "人/没有的页", version: nil)
        XCTAssertEqual(parsed.covered, [f1.id], "页不在，挂不上")
        XCTAssertTrue(CatalogDiagnostics.coverage(parsed, sources: sources).contains("- f1：写手说在「人/没有的页」，交审条目上没挂它"))
    }

    // MARK: - 三条路：提案上的 run 链接打开同一份记录，交审诊断就在那一节

    private func memories(_ subject: String, _ contents: [String], in container: ModelContainer) throws {
        let ctx = ModelContext(container)
        for (i, content) in contents.enumerated() {
            let m = Memory(content: content, category: "fact", profileId: pid)
            m.subject = subject
            m.occurredDay = "2026-10-1\(i)"
            m.reviewedAt = Date()
            ctx.insert(m)
        }
        try ctx.save()
    }

    /// 回执里「- f3 · … · 内容」那一行的编号
    private static func label(of content: String, in text: String) -> String? {
        text.components(separatedBy: "\n").first { $0.hasPrefix("- f") && $0.hasSuffix(" · " + content) }
            .map { String($0.dropFirst(2).prefix { $0 != " " }) }
    }

    /// 自动：批了方向才写；正文对象 + 诊断对象，坏行进不了正文，交审诊断按最终条目算，记在提案 run 链接指的那一节
    func testDailyProposalLinksToItsFinalDiagnostics() async throws {
        let container = try container()
        try memories("甲", ["甲一", "甲二", "甲三"], in: container)
        let caller: SessionSegmentWriter.Caller = { _, user in
            let labels = ["甲一", "甲二", "甲三"].compactMap { Self.label(of: $0, in: user) }
            let records = labels.map { "{\"text\":\"2026-10-10 \($0) 那件事\",\"fragments\":[\"\($0)\"]}" }.joined(separator: ",")
            return """
            {"items":[{"type":"new_page","path":"主题/甲","kind":"主题","title":"甲","now":"在做甲（自 2026-10 起）。",
              "records":[\(records),{"text":"2026-10-11 编的","fragments":["f99"]}]}]}
            {"coverage":[{"input":"\(labels[0])","at":"记录"},{"input":"\(labels[1])","why":"重复"}]}
            """
        }
        let job = CatalogTestKit.job(pid: pid, root: root, container: container, caller: caller)
        let store = WikiProposalStore(wiki: wiki)
        _ = await CatalogSession(job: job).daily(now: Date())
        let directions = try XCTUnwrap(store.list().first)
        try await WikiProposalReview.approve(directions.id, store: store, profileId: pid, context: ModelContext(container))

        let report = await CatalogSession(job: job).directions(directions.id)

        XCTAssertEqual(report.proposals, 1)
        let content = try XCTUnwrap(store.list().first { $0.directionRef != nil })
        guard case .newPage(let page) = try XCTUnwrap(content.items.first).change else { return XCTFail("应该是新开页") }
        XCTAssertEqual(page.records.count, 3, "编的那行进不了正文提案")
        let (_, diag) = try section(content.run)
        XCTAssertTrue(diag.contains("交审诊断"))
        XCTAssertTrue(diag.contains("records[3]：记录没有可用出处"))
        XCTAssertTrue(diag.contains("写进了页（交审条目上挂着）"))
        XCTAssertTrue(diag.contains("声明了没覆盖"))
        XCTAssertTrue(diag.contains("这次没改已有页的「现在」"))
    }

    /// 手动：同一轮先查再交，交的那份只认这一轮之前已经给过的出处；下一轮再交才认得到。
    /// 输入清单按实际给过的全部碎片：写进了页、声明了没覆盖、没交代分开记；中间稿和交审的分开标
    func testManualSameRoundSearchThenSubmitAndDynamicInputs() async throws {
        let container = try container()
        try memories("电影", ["看电影一", "看电影二", "看电影三"], in: container)
        try wiki.save(WikiPage(path: "事/电影", kind: .event, title: "电影", now: "在追片（自 2026-10 起）。"))
        var labels: [String] = []
        let backend = FakeCatalogBackend { n, request in
            @MainActor func submit(_ coverage: String) -> ToolCallBlock {
                let l = labels.isEmpty ? ["f1", "f2", "f3"] : labels
                return CatalogTestKit.call(CatalogAgentTools.submit, """
                {"items":[{"type":"append","path":"事/电影","records":[{"text":"2026-10-10 看电影","fragments":["\(l[0])"]}]}],\(coverage)}
                """)
            }
            if n == 1 {
                return .toolCalls([CatalogTestKit.call("search_fragments", "{\"terms\":[\"电影\"]}"), submit("\"reason\":\"同轮\"")])
            }
            let fed = request.toolTurns.flatMap(\.results).map(\.text).joined(separator: "\n")
            labels = ["看电影一", "看电影二", "看电影三"].compactMap { Self.label(of: $0, in: fed) }
            return .toolCalls([submit("\"coverage\":[{\"input\":\"\(labels[0])\",\"at\":\"记录\"},{\"input\":\"\(labels[1])\",\"why\":\"重复\"}]")])
        }
        let session = CatalogSession(job: CatalogTestKit.job(pid: pid, root: root, container: container, backend: backend))

        let report = await session.organizeTopic("电影")

        XCTAssertEqual(report.proposals, 1)
        XCTAssertEqual(backend.requests.count, 2, "同轮交的那份全被扔，下一轮才认得到")
        XCTAssertTrue(backend.requests[1].toolTurns[0].results[1].text.contains("全部被扔掉"))
        let p = try XCTUnwrap(WikiProposalStore(wiki: wiki).list().first)
        guard case .appendRecords(_, let lines) = try XCTUnwrap(p.items.first).change else { return XCTFail("应该是追加记录") }
        XCTAssertEqual(lines.count, 1)
        let (file, diag) = try section(p.run)
        XCTAssertTrue(file.contains("中间稿诊断"), "第一轮那份标中间稿")
        XCTAssertTrue(diag.contains("交审诊断"))
        XCTAssertTrue(diag.contains("- \(labels[0])：「记录」"))
        XCTAssertTrue(diag.contains("声明了没覆盖：\n- \(labels[1])：重复"))
        XCTAssertTrue(diag.contains("没交代（未评估）：\(labels[2])"), "检索新增的输入也要交代")
    }

    /// 手动：参数截断只截在诊断里，正文照收，不要它重交
    func testManualTruncatedInsideDiagnosticsKeepsTheBody() async throws {
        let container = try container()
        try memories("电影", ["看电影一"], in: container)
        let args = """
        {"items":[{"type":"new_page","path":"事/电影","kind":"事","title":"电影","now":"在追片（自 2026-10 起）。",
          "records":[{"text":"2026-10-10 看电影","fragments":["f1"]}]}],"coverage":[{"input":"f1","a
        """
        let backend = FakeCatalogBackend { n, _ in
            n == 1 ? .toolCalls([CatalogTestKit.call("search_fragments", "{\"terms\":[\"电影\"]}")])
                : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, args, truncated: true)])
        }
        let report = await CatalogSession(job: CatalogTestKit.job(pid: pid, root: root, container: container, backend: backend)).organizeTopic("电影")
        XCTAssertEqual(report.proposals, 1)
        XCTAssertEqual(backend.requests.count, 2)
        let p = try XCTUnwrap(WikiProposalStore(wiki: wiki).list().first)
        XCTAssertEqual(p.items.count, 1)
        XCTAssertTrue(try section(p.run).section.contains("这次没有可用的 coverage"))
    }

    // MARK: - 审计台手改

    /// 普通提案改记录走同一套出处口径：改错字但留着原出处 → 出处不变；新加没写出处的 → 标「用户编辑」；
    /// 删掉一行 → 那条碎片不再挂、批了不标已整理；删掉出处、写不认识的出处 → 拒存
    func testAuditEditOfOrdinaryProposalKeepsSourcesAndRecomputesFragments() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let kept = Memory(content: "豆包改吃处方粮", category: "fact", profileId: pid)
        let removed = Memory(content: "豆包体重 6kg", category: "fact", profileId: pid)
        for m in [kept, removed] {
            m.reviewedAt = Date()
            ctx.insert(m)
        }
        try ctx.save()
        let first = "2026-10-12 改吃处方粮（出处：\(CatalogSources.label(kept.id))）"
        let second = "2026-10-13 体重 6kg（出处：\(CatalogSources.label(removed.id))）"
        let page = WikiPage(path: path, kind: .person, title: "豆包", now: "橘猫。", records: [first, second])
        let item = WikiProposal.Item(change: .newPage(page: page), fragmentIds: [kept.id, removed.id], baseVersion: nil)
        let store = WikiProposalStore(wiki: wiki)
        let p = WikiProposal(origin: .manual, createdAt: Date(), items: [item])
        try store.save(p)
        func edit(_ records: [String]) async throws -> WikiProposal.Item {
            var changed = page
            changed.records = records
            return try await WikiProposalReview.edit(p.id, itemId: item.id, change: .newPage(page: changed), judgment: nil, store: store).items[0]
        }
        for bad in [["2026-10-12 改吃处方粮"], ["2026-10-12 改吃处方粮（出处：碎片 ffffffff）"]] {
            do {
                _ = try await edit(bad)
                XCTFail("\(bad) 应该拒存")
            } catch {}
        }
        let typo = "2026-10-12 改吃肾脏处方粮（出处：\(CatalogSources.label(kept.id))）"
        let saved = try await edit([typo, "2026-10-15 换了猫砂"])
        guard case .newPage(let out) = saved.change else { return XCTFail("应该是新开页") }
        XCTAssertEqual(out.records, [typo, "2026-10-15 换了猫砂（出处：用户编辑）"], "改错字出处不变；新加的标用户编辑")
        XCTAssertEqual(saved.fragmentIds, [kept.id], "删掉的那行引用的碎片不再挂")

        try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: ctx)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Memory>())
        XCTAssertNotNil(rows.first { $0.id == kept.id }?.organizedAt)
        XCTAssertNil(rows.first { $0.id == removed.id }?.organizedAt, "回到池子里")
        XCTAssertEqual(wiki.read(path)?.records, [typo, "2026-10-15 换了猫砂（出处：用户编辑）"])
    }

    // MARK: - wiki 体检

    /// 断链、目录漂移各一例（孤页不再算）：每天自动整理后跑，零模型调用、零写页；漂移按代码重建索引，结果进记忆日志和 C3 页读的那份
    func testHealthCheckFindsBrokenOrphanAndDriftWithoutModelOrPageWrites() async throws {
        let w = wiki
        try w.save(WikiPage(path: "人/甲", kind: .person, title: "甲",
                            links: [.init(target: "人/不存在", relation: .supplement, why: "x"), .init(target: "主题/有人连", relation: .citation, why: "y")]))
        try w.save(WikiPage(path: "主题/散页", title: "散页"))
        try w.save(WikiPage(path: "主题/有人连", title: "有人连"))
        try w.save(WikiPage(path: "人/乙", kind: .person, title: "乙"))
        try w.rebuildAllIndexes()
        try w.save(WikiPage(path: "人/新页", kind: .person, title: "新页"))
        let versions = w.versionSnapshot()
        let container = try container()
        var calls = 0
        let backend = FakeCatalogBackend { _, _ in .failed("不该调模型") }
        let job = CatalogTestKit.job(pid: pid, root: root, container: container, caller: { _, _ in calls += 1; return nil }, backend: backend)

        _ = await CatalogSession(job: job).daily(now: Date())

        XCTAssertEqual(calls, 0)
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(w.versionSnapshot(), versions, "一页都没改")
        XCTAssertTrue(WikiProposalStore(wiki: w).list().isEmpty)
        let health = try XCTUnwrap(WikiHealth.load(w))
        XCTAssertEqual(health.brokenLinks, [.init(from: "人/甲", to: "人/不存在")])
        XCTAssertEqual(health.orphans, [], "根下 9 组本身就是分组：孤页不再算")
        XCTAssertFalse(health.summary.contains("孤页") || health.details.contains("孤页"), "孤页不再显示")
        XCTAssertTrue(health.drift.contains("人：「人/新页」没列进索引"), "\(health.drift)")
        XCTAssertTrue(health.drift.contains("根索引：「人/新页」没列进索引"), "\(health.drift)")
        XCTAssertNil(health.rebuildError)
        XCTAssertTrue(WikiHealth.drift(w, hasPages: true).isEmpty, "漂移照代码重建了索引")
        MemoryWriteLog.flush()
        let entry = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).last { $0.note.hasPrefix("wiki 体检") })
        XCTAssertEqual(entry.note, "wiki 体检：" + health.summary)
        XCTAssertTrue(health.summary.hasPrefix("断链 1 · 目录漂移 "))
        let (_, logged) = try section(entry.run)
        XCTAssertTrue(logged.contains("- 人/甲 → 人/不存在"), "日志点开到体检那一节")

        _ = await CatalogSession(job: job).daily(now: Date())
        XCTAssertEqual(try XCTUnwrap(WikiHealth.load(w)).drift, [], "重建之后下一次没有漂移")
    }

    /// 体检拿审批锁：批提案写页、重建索引的中间不插进来
    func testHealthCheckWaitsForTheApprovalLock() async throws {
        let w = wiki
        try w.save(WikiPage(path: "人/甲", kind: .person, title: "甲"))
        try w.rebuildAllIndexes()
        let container = try container()
        let job = CatalogTestKit.job(pid: pid, root: root, container: container)
        var daily: Task<CatalogRunReport, Never>?
        try await WikiProposalReview.exclusive(WikiProposalStore(wiki: w)) {
            try w.save(WikiPage(path: "人/乙", kind: .person, title: "乙"))
            daily = Task { await CatalogSession(job: job).daily(now: Date()) }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertNil(WikiHealth.load(w), "锁还在，体检等着")
            try w.rebuildAllIndexes()
        }
        _ = await daily?.value
        XCTAssertEqual(try XCTUnwrap(WikiHealth.load(w)).drift, [], "没看到写页和重建之间的半截状态")
    }

    func testEmptyWikiIsHealthyAndUntouched() async throws {
        let container = try container()
        let job = CatalogTestKit.job(pid: pid, root: root, container: container)
        _ = await CatalogSession(job: job).daily(now: Date())
        let health = try XCTUnwrap(WikiHealth.load(wiki))
        XCTAssertEqual(health.summary, "断链 0 · 目录漂移 0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wiki.folderURL("人").path), "空 wiki 不因体检建出分组")
    }
}
