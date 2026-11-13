import MemoryCore
import XCTest
@testable import 记忆花园

@MainActor
final class CatalogJSONRepairTests: XCTestCase {
    private var root: URL!
    private var wiki: WikiStore!
    private let fragment = CatalogFragment(id: UUID(), content: "开始整理测试书单", category: "fact", day: "2026-10-12")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-json-\(UUID().uuidString)", isDirectory: true)
        wiki = WikiStore(root: root.appendingPathComponent("wiki"))
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: "xctest-catalog-json-repair").deletingLastPathComponent())
    }

    private var sources: CatalogSources {
        var value = CatalogSources()
        value.addFragments([fragment])
        return value
    }

    private let items = #"[{"type":"new_page","path":"主题/书单","kind":"主题","title":"书单","now":"正在读「测试书」（自 2026-10 起）。","records":[{"text":"2026-10-12 开始整理书单","fragments":["f1"]},{"text":"没有出处"}]}]"#

    private func encoded(_ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    }

    private func assertPage(_ parsed: CatalogItems.Parsed?, now: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try XCTUnwrap(parsed, file: file, line: line)
        XCTAssertEqual(value.items.count, 1, file: file, line: line)
        XCTAssertEqual(value.dropped, 1, "修复不能绕过出处校验", file: file, line: line)
        let item = try XCTUnwrap(value.items.first, file: file, line: line)
        guard case .newPage(let page) = item.change else { return XCTFail("应生成新页提案", file: file, line: line) }
        XCTAssertEqual(page.path, "主题/书单", file: file, line: line)
        XCTAssertEqual(page.now, now, file: file, line: line)
        XCTAssertEqual(page.records, ["2026-10-12 开始整理书单（出处：碎片 \(fragment.id.uuidString.prefix(8).lowercased())）"], file: file, line: line)
        XCTAssertEqual(item.fragmentIds, [fragment.id], file: file, line: line)
        XCTAssertTrue(wiki.pagePaths().isEmpty, "解析只产提案，不能直接写页", file: file, line: line)
    }

    func testStringifiedValidItemsArray() throws {
        let json = "{\"items\":\(try encoded(items))}"
        try assertPage(CatalogItems.parse(json, sources: sources, wiki: wiki), now: "正在读「测试书」（自 2026-10 起）。")
    }

    func testStringifiedItemsWithUnescapedQuotes() throws {
        let broken = items.replacingOccurrences(of: "「测试书」", with: "\"测试书\"")
        let json = "{\"items\":\(try encoded(broken))}"
        try assertPage(CatalogItems.parse(json, sources: sources, wiki: wiki), now: "正在读\"测试书\"（自 2026-10 起）。")
    }

    func testUnrecoverableJSONReportsParserPosition() throws {
        let broken = "[\n  {\"type\":\"new_page\",\n    \"path\":\"主题/书单\",\n    \"records\": ???\n  }\n]"
        let json = "{\"items\":\(try encoded(broken))}"
        var error = ""
        XCTAssertNil(CatalogItems.parse(json, sources: sources, wiki: wiki) { error = $0 })
        XCTAssertTrue(error.contains("items 必须直接是数组"), error)
        XCTAssertTrue(error.contains("第 4 行") || error.contains("line 4"), error)
        XCTAssertTrue(error.contains("列") || error.contains("column"), error)
        XCTAssertTrue(error.contains("解析器"), error)
    }

    func testNormalArrayKeepsValidationAndText() throws {
        try assertPage(CatalogItems.parse("{\"items\":\(items)}", sources: sources, wiki: wiki), now: "正在读「测试书」（自 2026-10 起）。")
    }

    func testRepairDoesNotSwallowMissingSeparatorsOrTruncation() throws {
        for broken in [
            #"[{"type":"new_page" "path":"主题/书单"}]"#,
            #"[{"type":"new_page","path":"主题/书单","now":"正文" "records":[]}]"#,
            String(items.dropLast()),
            items + " trailing junk"
        ] {
            let json = "{\"items\":\(try encoded(broken))}"
            XCTAssertNil(CatalogItems.parse(json, sources: sources, wiki: wiki), broken)
        }
    }

    func testDirectMalformedQuotesAndEscapesKeepContent() throws {
        let broken = items.replacingOccurrences(of: "「测试书」", with: #"\"已转义\"和"未转义""#)
        try assertPage(CatalogItems.parse("{\"items\":\(broken)}", sources: sources, wiki: wiki), now: "正在读\"已转义\"和\"未转义\"（自 2026-10 起）。")
    }

    func testAgentFeedsBackInnerFailureBeforeAcceptingCorrection() async throws {
        let invalid = "{\"items\":\(try encoded("[\n  ???\n]"))}"
        let valid = "{\"items\":\(items)}"
        let backend = FakeCatalogBackend { n, _ in
            .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 1 ? invalid : valid)])
        }
        let agent = CatalogAgent(deps: .init(makeBackend: { backend }, gate: { _ in nil }))
        let job = CatalogAgent.Job(topic: "书单", fragmentIds: [fragment.id], profileId: "xctest-catalog-json-repair", memoryRoot: root,
                                   names: .init(userName: "测试者", assistantName: "测试助手"), floorPrompt: "",
                                   snapshot: [fragment], modelName: "合成后端", maxRounds: 3, embedder: CatalogFakeEmbedder.unavailable())
        let result = await agent.run(job)
        XCTAssertEqual(result.stop, .submitted)
        XCTAssertEqual(result.rounds, 2)
        try assertPage(.init(items: result.items, dropped: result.dropped), now: "正在读「测试书」（自 2026-10 起）。")
        let feedback = try XCTUnwrap(backend.requests.last?.toolTurns.last?.results.first)
        XCTAssertTrue(feedback.isError)
        XCTAssertTrue(feedback.text.contains("items 必须直接是数组"), feedback.text)
        XCTAssertTrue(feedback.text.contains("第 2 行") || feedback.text.contains("line 2"), feedback.text)
        XCTAssertTrue(feedback.text.contains("正文里的引号请用「」"), feedback.text)
    }

    func testAutomaticWriterRecoversAndFeedsBackUnrecoverablePosition() async throws {
        let topic = CatalogSorter.Topic(path: "主题/书单", title: "书单", kind: .topic, existing: false, fragmentIds: [fragment.id])
        let material = await CatalogWriter.material(topic, fragments: [fragment], floorPrompt: "", wiki: wiki, memoryRoot: root, now: Date(),
                                                   embedder: CatalogFakeEmbedder.unavailable())
        let broken = items.replacingOccurrences(of: "「测试书」", with: "\"测试书\"")
        let repairedReply = "{\"items\":\(try encoded(broken))}"
        let invalid = "{\"items\":\(try encoded("[\n  ???\n]"))}"
        var calls = 0
        var feedback = ""
        let parsed = try await CatalogWriter.write(material, names: .init(userName: "测试者", assistantName: "测试助手"), wiki: wiki, caller: { _, user in
            calls += 1
            if calls == 1 { return invalid }
            feedback = user
            return repairedReply
        }, drafts: nil)
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(feedback.contains("第 2 行") || feedback.contains("line 2"), feedback)
        try assertPage(parsed, now: "正在读\"测试书\"（自 2026-10 起）。")
    }
}
