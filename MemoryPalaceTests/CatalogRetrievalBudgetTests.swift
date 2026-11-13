import MemoryCore
import XCTest
@testable import 记忆花园

@MainActor
final class CatalogRetrievalBudgetTests: XCTestCase {
    private var root: URL!
    private let query = "solarship"
    private let a2Body = "solarship solarship solarship solarship solarship 高分云桥航线"
    private let vectorBody = "solarship solarship solarship solarship 银帆每逢周末停泊北湾"
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 20))! }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-budget-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func corpus() throws -> ([CatalogFragment], CatalogFakeEmbedder) {
        let start = now.addingTimeInterval(-86_400)
        let entries = (0..<40).map { i in
            TimelineEntry(start: start, end: start.addingTimeInterval(600), conversationId: String(format: "a4%06d-window", i),
                          title: "编造背景窗口", text: "- solarship " + String(repeating: "背景材料", count: 220), pending: "", day: MemoryDay.key(start))
        }
        try TimelineStore.write(entries, month: "2026-10", in: TimelineStore.dir(root: root))
        let segment = SessionSegment(kind: .rolling, title: "航线", start: start, end: start.addingTimeInterval(600),
                                     from: 0, to: 8, lastNodeId: nil, story: a2Body, quotes: "", pending: "")
        try SessionSummaryStore.save(SessionSummary(conversationId: "targeta2-window", title: "航线", compressedCount: 8,
                                                    segments: [segment], updatedAt: start), in: SessionSummaryStore.dir(root: root))
        var fragments = (0..<30).map { _ in
            CatalogFragment(id: UUID(), content: "solarship " + String(repeating: "碎片背景", count: 30), category: "fact", day: "2026-10-17")
        }
        for i in fragments.indices {
            fragments[i].embeddingData = MemoryVector.data(from: [0, 1])
            fragments[i].embeddingRevision = 7
        }
        var vector = CatalogFragment(id: UUID(), content: vectorBody, category: "fact", day: "2026-10-17")
        vector.embeddingData = MemoryVector.data(from: [1, 0])
        vector.embeddingRevision = 7
        fragments.append(vector)
        let fake = CatalogFakeEmbedder()
        fake.vectors[query] = [1, 0]
        return (fragments, fake)
    }

    private func weakOriginals() -> [SearchService.CatalogNode] {
        (0..<15).map {
            .init(profileId: "synthetic-budget", conversationId: "raw-window", nodeId: "weak-\($0)", title: "弱相关原文",
                  created: now, role: "user", onMain: true,
                  body: "solarship " + String(repeating: "宽泛背景", count: 220))
        }
    }

    func testAutomaticWriterReceivesGlobalBudgetWithHighRankA2AndLateFragmentF31() async throws {
        let (fragments, fake) = try corpus()
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let topic = CatalogSorter.Topic(path: "主题/航线", title: query, kind: .topic, existing: false)
        let originals = weakOriginals()
        let material = await CatalogWriter.material(topic, fragments: [], floorPrompt: "", wiki: wiki, memoryRoot: root,
                                                     now: now, snapshot: fragments, embedder: fake, originalSearch: { _, _, _ in originals })
        let run = CatalogRunRecord(wiki: wiki, topic: query, kind: "限量回归")
        var actual = ""
        let result = try await CatalogWriter.write(material, names: .init(userName: "{u}", assistantName: "{c}"), wiki: wiki, caller: { _, user in
            actual = user
            return "{\"items\":[{\"type\":\"new_page\",\"path\":\"主题/航线\",\"kind\":\"主题\",\"title\":\"航线\",\"records\":[{\"text\":\"北湾航线\",\"fragments\":[\"f31\"],\"aline\":[{\"layer\":\"A2\",\"window\":\"targeta2\",\"segment\":1}]}]}]}"
        }, drafts: nil, run: run)
        XCTAssertTrue(actual.contains(a2Body))
        let fragmentLine = try XCTUnwrap(actual.components(separatedBy: "\n").first { $0.hasPrefix("- f31 · ") })
        XCTAssertTrue(fragmentLine.hasPrefix("- f31 · 2026-10-17 · 没整理 · "))
        XCTAssertTrue(fragmentLine.hasSuffix(" · " + vectorBody))
        XCTAssertLessThanOrEqual(material.search.receipt.evidence().searchedChars, CatalogRetrieval.Limits.chars)
        XCTAssertLessThanOrEqual(material.search.aline.hits.count + material.search.fragments.count + material.search.originals.count, 10)
        XCTAssertEqual(result?.items.first?.fragmentIds, [fragments[30].id])
        XCTAssertEqual(result?.items.first?.cites.first?.segment, 1)
        await run.flush()
        let evidence = CatalogRunRecord.searchEvidence(in: try String(contentsOf: run.url, encoding: .utf8))
        XCTAssertLessThanOrEqual(evidence.reduce(0) { $0 + $1.searchedChars }, 6000)
        XCTAssertTrue(evidence.flatMap(\.fragments).contains(vectorBody))
        print("[P1 SMOKE] automatic: actual=\(actual.count), body=\(material.search.receipt.evidence().searchedChars), high-rank A2+f31 reached writer")
    }

    func testManualWriterReceivesSameGlobalBudgetAndCanCiteBothLateSources() async throws {
        let (fragments, fake) = try corpus()
        let submit = "{\"items\":[{\"type\":\"new_page\",\"path\":\"主题/航线\",\"kind\":\"主题\",\"title\":\"航线\",\"records\":[{\"text\":\"北湾航线\",\"fragments\":[\"f31\"],\"aline\":[{\"layer\":\"A2\",\"window\":\"targeta2\",\"segment\":1}]}]}]}"
        let backend = FakeCatalogBackend { round, _ in
            .toolCalls([round == 1 ? CatalogTestKit.call("search_aline", "{\"terms\":[\"solarship\"],\"before\":\"2026-10-18\"}") : CatalogTestKit.call(CatalogAgentTools.submit, submit)])
        }
        let originals = weakOriginals()
        let agent = CatalogAgent(deps: .init(makeBackend: { backend }, gate: { _ in nil }))
        let outcome = await agent.run(.init(topic: query, profileId: "synthetic-budget", memoryRoot: root,
                                            names: .init(userName: "{u}", assistantName: "{c}"), floorPrompt: "", snapshot: fragments,
                                            modelName: "假模型", embedder: fake, originalSearch: { _, _, _ in originals }))
        let feedback = try XCTUnwrap(backend.requests.last?.toolTurns.first?.results.first?.text)
        XCTAssertEqual(outcome.stop, .submitted)
        XCTAssertTrue(feedback.contains(a2Body))
        let fragmentLine = try XCTUnwrap(feedback.components(separatedBy: "\n").first { $0.hasPrefix("- f31 · ") })
        XCTAssertTrue(fragmentLine.hasPrefix("- f31 · 2026-10-17 · 没整理 · "))
        XCTAssertTrue(fragmentLine.hasSuffix(" · " + vectorBody))
        XCTAssertLessThanOrEqual(outcome.searchedChars, 6000)
        XCTAssertEqual(outcome.items.first?.fragmentIds, [fragments[30].id])
        XCTAssertEqual(outcome.items.first?.cites.first?.segment, 1)
        print("[P1 SMOKE] manual: feedback=\(feedback.count), body=\(outcome.searchedChars), cited A2#1+f31")
    }

    func testGlobalTenHitCapReplacesPerLayerBuckets() {
        let hits: [CatalogALineReader.Hit] = [CatalogALineReader.Layer.a4, .a3, .a2].flatMap { layer -> [CatalogALineReader.Hit] in
            (0..<12).map { i in
                CatalogALineReader.Hit(layer: layer, conversationId: "window-\(i)", title: "窗口", start: now, end: now,
                                      day: "2026-10-18", segment: layer == .a2 ? i : nil, messages: nil,
                                      parts: [.init(text: "虚构正文", isBody: true)], old: nil)
            }
        }
        let result = CatalogRetrieval.Result(aline: .init(terms: ["虚构"], hits: hits, found: [.a4: 12, .a3: 12, .a2: 12]),
                                             fragments: [], labels: [:], vectorStatus: "未检索")
        XCTAssertEqual(result.aline.hits.count, 10)
        let fragments = (0..<100).map { CatalogFragment(id: UUID(), content: "画帆\($0)", category: "fact", day: "2026-10-18") }
        let fragmentResult = CatalogRetrieval.Result(aline: .init(terms: ["画帆"], hits: [], found: [:]), fragments: fragments,
                                                     labels: [:], vectorStatus: "未检索")
        XCTAssertEqual(fragmentResult.fragments.count, 10)
        XCTAssertFalse(fragmentResult.receipt.evidence().fragments.contains("画帆10"))
    }

    func testLongMetadataDoesNotConsumeSearchBodyBudget() async throws {
        let start = now.addingTimeInterval(-86_400)
        let word = "solarship"
        try TimelineStore.seedLegacy(TimelineEntry(start: start, end: start.addingTimeInterval(600), conversationId: "metazero-window",
                                               title: word + " " + String(repeating: "标题说明", count: 2000), text: "- " + word, pending: "",
                                               day: MemoryDay.key(start)), in: TimelineStore.dir(root: root))
        let fake = CatalogFakeEmbedder.unavailable()
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let material = await CatalogWriter.material(.init(path: "主题/云桥", title: word, kind: .topic, existing: false),
                                                     fragments: [], floorPrompt: "", wiki: wiki, memoryRoot: root, now: now, embedder: fake)
        let run = CatalogRunRecord(wiki: wiki, topic: word, kind: "正文边界回归")
        _ = try await CatalogWriter.write(material, names: .init(userName: "{u}", assistantName: "{c}"), wiki: wiki,
                                          caller: { _, _ in "{\"items\":[]}" }, drafts: nil, run: run)
        await run.flush()
        let evidence = CatalogRunRecord.searchEvidence(in: try String(contentsOf: run.url, encoding: .utf8))
        XCTAssertEqual(evidence.reduce(0) { $0 + $1.searchedChars }, word.count)
        let output = await CatalogAgentTools(wiki: wiki, memoryRoot: root, fragments: [], embedder: fake)
            .execute(name: "search_aline", argumentsJSON: "{\"terms\":[\"solarship\"]}", now: now)
        XCTAssertEqual(output.receipt?.evidence().aline, [word])
        var sources = CatalogSources()
        output.receipt?.register(in: &sources)
        XCTAssertNotNil(sources.windows["metazero"])
    }
}
