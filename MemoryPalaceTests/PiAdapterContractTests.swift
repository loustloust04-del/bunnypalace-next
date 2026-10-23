#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-b Pi / Oh My Pi：逐条照抄 Wake `pi_parse_contract` + 全局 seq 契约
final class PiAdapterContractTests: XCTestCase {
    private var root: URL { CodingSessionAdapterTests.fixtures.appendingPathComponent("pi/agent/sessions") }
    private var file: URL {
        root.appendingPathComponent("--Users-tester-Github-wakefx--/2026-08-06T10-00-00-000Z_66666666-aaaa-bbbb-cccc-000000000006.jsonl")
    }

    func testPiParseContract() throws {
        let adapter = PiAdapter(agent: .pi, root: root)
        // file_ref：<timestamp>_<uuid>.jsonl 剥出 uuid 作 native id
        let ref = try XCTUnwrap(adapter.fileRef(file))
        XCTAssertEqual(ref.nativeId, "66666666-aaaa-bbbb-cccc-000000000006")

        let s = try adapter.parseSession(ref)
        let t = try adapter.parseTranscript(ref)
        XCTAssertEqual(s.meta.title, "Pi 查一下二维码组件的 useEffect() 清理")
        XCTAssertEqual(s.meta.key, "pi:66666666-aaaa-bbbb-cccc-000000000006")
        XCTAssertEqual(s.meta.projectPath, "/Users/tester/Github/wakefx", "cwd 来自 session 首行，不反推有损编码目录名")
        XCTAssertEqual(s.meta.model, "gpt-5.5")
        XCTAssertEqual(s.meta.tokensUsed, 4300, "最后一条 assistant 的 totalTokens")
        XCTAssertEqual(s.meta.messageCount, 2)
        XCTAssertEqual(s.meta.createdAt, CodingContract.ms("2026-08-06T10:00:00Z"))
        XCTAssertEqual(s.meta.updatedAt, CodingContract.ms("2026-08-06T10:00:12Z"))
        XCTAssertEqual(s.unknownLines, 1, "wibble-line 计 unknown；model_change / thinking_level_change 不计")

        XCTAssertEqual(CodingContract.rolesKinds(t.mainline), ["user/text", "assistant/text"], "连续 assistant（中间只隔 toolResult）合并")
        let assistant = t.mainline[1]
        XCTAssertEqual(assistant.text, "找到泄漏点,已补清理回调。")
        XCTAssertEqual(assistant.toolCalls.count, 1)
        XCTAssertEqual(assistant.toolCalls.first?.name, "bash")
        XCTAssertTrue(assistant.toolCalls.first?.output?.contains("QrScanner") == true, "toolResult 独立 role 行按 toolCallId 回填")
        XCTAssertFalse(assistant.toolCalls.first?.isError ?? true)
        XCTAssertEqual(s.units.map(\.seq), [0, 1])
        try CodingContract.assertSeqContract(adapter, ref)
    }

    func testOmpSharesTheParserWithItsOwnKey() throws {
        let omp = PiAdapter(agent: .omp, root: root)
        let ref = try XCTUnwrap(omp.fileRef(file))
        let s = try omp.parseSession(ref)
        XCTAssertEqual(s.meta.agent, .omp)
        XCTAssertEqual(s.meta.key, "omp:66666666-aaaa-bbbb-cccc-000000000006")
        XCTAssertEqual(s.meta.title, "Pi 查一下二维码组件的 useEffect() 清理")
        try CodingContract.assertSeqContract(omp, ref)
    }

    func testDefaultRootsAndListing() {
        let home = URL(fileURLWithPath: "/h")
        XCTAssertEqual(PiAdapter.make(home: home, agent: .pi).root.path, "/h/.pi/agent/sessions")
        XCTAssertEqual(PiAdapter.make(home: home, agent: .omp).root.path, "/h/.omp/agent/sessions")
        XCTAssertEqual(PiAdapter.nativeId("2026-08-06T10-00-00-000Z_abc"), "abc")
        XCTAssertEqual(PiAdapter.nativeId("plain"), "plain")
        XCTAssertEqual(PiAdapter(agent: .pi, root: root).listSessionFiles().map(\.nativeId), ["66666666-aaaa-bbbb-cccc-000000000006"])
        XCTAssertTrue(PiAdapter(agent: .pi, root: URL(fileURLWithPath: "/nonexistent/pi")).listSessionFiles().isEmpty, "缺根降级为空")
    }
}
#endif
