#if os(macOS)
import XCTest
@testable import 记忆花园

/// N5-a4：照抄 Wake `mcp/tools.rs` 5 条单测 + `tests/mcp_stdio.rs` 工具层断言（进程内调用；stdio 协议层留 N6）。全部在 tmp：整套假 home + tmp 索引
final class CodingToolsTests: XCTestCase {
    func testAgentNamesParseLeniently() {
        XCTAssertEqual(CodingTools.parseAgent("claude-code"), .claudeCode)
        XCTAssertEqual(CodingTools.parseAgent("Claude Code"), .claudeCode)
        XCTAssertEqual(CodingTools.parseAgent("claude"), .claudeCode)
        XCTAssertEqual(CodingTools.parseAgent("Gemini CLI"), .gemini)
        XCTAssertEqual(CodingTools.parseAgent("oh-my-pi"), .omp)
        XCTAssertEqual(CodingTools.parseAgent("DeepSeek"), .dsh)
        XCTAssertEqual(CodingTools.parseAgent("opencode2"), .opencode)
        XCTAssertNil(CodingTools.parseAgent("chatgpt"))
    }

    func testKeyArgAcceptsRefs() {
        var parsed = CodingTools.parseKeyArg("code://session/claude-code:abc#12")
        XCTAssertEqual(parsed.key, "claude-code:abc")
        XCTAssertEqual(parsed.seq, 12)
        parsed = CodingTools.parseKeyArg("wake://session/claude-code:abc#3")
        XCTAssertEqual(parsed.key, "claude-code:abc", "Wake 复制来的引用照样认")
        XCTAssertEqual(parsed.seq, 3)
        parsed = CodingTools.parseKeyArg("codex:devbox:0195-xyz")
        XCTAssertEqual(parsed.key, "codex:devbox:0195-xyz")
        XCTAssertNil(parsed.seq)
        parsed = CodingTools.parseKeyArg(" claude-code:abc ")
        XCTAssertEqual(parsed.key, "claude-code:abc")
        XCTAssertNil(parsed.seq)
    }

    func testIntArgsClampAndAcceptNumericStrings() throws {
        let args: [String: Any] = ["limit": 500, "n": "7", "f": 3.0, "bad": "x", "flag": true]
        XCTAssertEqual(try CodingTools.intArg(args, "limit", 10, 1, 30), 30)
        XCTAssertEqual(try CodingTools.intArg(args, "n", 10, 1, 30), 7)
        XCTAssertEqual(try CodingTools.intArg(args, "f", 10, 1, 30), 3)
        XCTAssertEqual(try CodingTools.intArg(args, "missing", 10, 1, 30), 10)
        XCTAssertThrowsError(try CodingTools.intArg(args, "bad", 10, 1, 30))
        XCTAssertThrowsError(try CodingTools.intArg(args, "flag", 10, 1, 30), "布尔不是整数")
        XCTAssertEqual(try CodingTools.boolArg(["b": "true"], "b", false), true)
        XCTAssertThrowsError(try CodingTools.boolArg(["b": 1], "b", false), "数字不是布尔")
    }

    func testSnippetsDropHighlightSentinels() {
        let raw = "前文 \(CodingSessionIndex.highlightOpen)二维码\(CodingSessionIndex.highlightClose) 后文\n换行"
        XCTAssertEqual(CodingTools.cleanSnippet(raw), "前文 **二维码** 后文 换行")
    }

    func testDefinitionsAreStable() {
        let defs = CodingTools.definitions
        XCTAssertEqual(defs.map(\.name), [CodingTools.search, CodingTools.listSessions, CodingTools.getSession, CodingTools.listProjects])
        XCTAssertEqual(defs.first { $0.name == CodingTools.search }?.required, ["query"])
        XCTAssertEqual(defs.first { $0.name == CodingTools.getSession }?.required, ["key"])
        for d in defs {
            XCTAssertEqual((ToolSchemaRenderer.anthropic(d)["input_schema"] as? [String: Any])?["type"] as? String, "object")
            XCTAssertTrue(d.name.hasPrefix("code_"))
        }
    }

    private func seqs(in text: String) -> [Int] {
        let regex = try! NSRegularExpression(pattern: #"### \[seq (\d+)\]"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    private func nextSeqHint(_ text: String) -> Int? {
        let regex = try! NSRegularExpression(pattern: #"from_seq=(\d+)"#)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    func testToolsEndToEndOnFixtureIndex() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-code-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home")
        try CodingFakeHome.stage(home)
        let indexURL = dir.appendingPathComponent("index.sqlite")
        let adapters = CodingSessionRoster.adapters(home: home, environment: [:])
        let claudeKey = "claude-code:11111111-aaaa-bbbb-cccc-000000000001"
        let claudeProject = CodingFakeHome.project

        // 1. 建库 + 全量扫描，本进程算出 seq 契约的参照；写连接在这个作用域里关掉（落盘 checkpoint 之后再拍库文件快照）
        var expectedSeqs: [Int] = []
        var qrSeq = -1
        do {
            let index = try CodingSessionIndex(url: indexURL)
            _ = try CodingSessionScanner(index: index, adapters: adapters).run(full: true)
            XCTAssertGreaterThan(try index.countSessions(filter: CodingListFilter(), includeArchived: true), 10, "假 home 应该索引出很多会话")
            let meta = try XCTUnwrap(index.session(key: claudeKey), "claude 夹具没入库")
            XCTAssertEqual(meta.projectPath, claudeProject)
            let adapter = try XCTUnwrap(CodingSessionRoster.owner(of: meta, in: adapters))
            let ref = try XCTUnwrap(adapter.fileRef(URL(fileURLWithPath: meta.filePath)) ?? CodingSessionFileRef.fromMeta(meta))
            let transcript = try adapter.parseTranscript(ref)
            expectedSeqs = transcript.mainline.filter { $0.kind != .meta }.map(\.seq)
            qrSeq = try XCTUnwrap(transcript.mainline.first { $0.text.contains("二维码") }?.seq, "夹具里有二维码那句")
        }
        let before = try Data(contentsOf: indexURL)

        let context = CodingTools.Context(index: try CodingSessionIndex(url: indexURL, readOnly: true), adapters: adapters, favorites: [],
                                          nowMs: Int64(Date().timeIntervalSince1970 * 1000), cache: CodingTools.TranscriptCache())
        func call(_ name: String, _ args: [String: Any]) -> CodingTools.Result {
            CodingTools.invoke(name: name, arguments: args, context: context)
        }

        // 2. search 命中的 seq 与解析出的序号一致（seq 契约）；按 agent 收窄让断言不依赖相关度排位
        let everywhere = call(CodingTools.search, ["query": "二维码", "limit": 30])
        XCTAssertFalse(everywhere.isError, everywhere.text)
        XCTAssertTrue(everywhere.text.contains("sessions match `二维码`"), everywhere.text)
        let hit = call(CodingTools.search, ["query": "二维码", "agents": ["claude"], "project": claudeProject])
        XCTAssertFalse(hit.isError, hit.text)
        XCTAssertTrue(hit.text.contains(claudeKey), hit.text)
        XCTAssertTrue(hit.text.contains("ref: code://session/\(claudeKey)#\(qrSeq)"), "search hit must cite seq \(qrSeq):\n\(hit.text)")
        XCTAssertTrue(hit.text.contains("Index covers activity up to"))

        // 3. get_session：引用形态起点、分页衔接、覆盖全部非 Meta 消息
        let page = call(CodingTools.getSession, ["key": "code://session/\(claudeKey)#\(qrSeq)", "max_messages": 1])
        XCTAssertFalse(page.isError, page.text)
        XCTAssertEqual(seqs(in: page.text), [qrSeq])
        XCTAssertTrue(page.text.contains("二维码"))
        XCTAssertTrue(page.text.contains("key: `claude-code:"))
        var visited: [Int] = []
        var from = 0
        for _ in 0..<50 {
            let result = call(CodingTools.getSession, ["key": claudeKey, "from_seq": from, "max_messages": 2])
            XCTAssertFalse(result.isError, result.text)
            let pageSeqs = seqs(in: result.text)
            XCTAssertFalse(pageSeqs.isEmpty, "page from \(from) rendered nothing:\n\(result.text)")
            XCTAssertEqual(pageSeqs.first, pageSeqs.min())
            visited += pageSeqs
            if let next = nextSeqHint(result.text) {
                XCTAssertGreaterThan(next, from, "next_seq must advance")
                from = next
            } else {
                XCTAssertTrue(result.text.contains("End of transcript."), result.text)
                break
            }
        }
        XCTAssertEqual(visited, expectedSeqs, "paging must cover every non-Meta message exactly once")
        let toolsPage = call(CodingTools.getSession, ["key": claudeKey, "include_tools": true])
        XCTAssertTrue(toolsPage.text.contains("output:"), "include_tools should add tool output:\n\(toolsPage.text)")
        let plainPage = call(CodingTools.getSession, ["key": claudeKey])
        XCTAssertFalse(plainPage.text.contains("output:"))
        XCTAssertTrue(plainPage.text.contains("🔧"), "tool calls fold to one line by default")

        // 4. 项目匹配：cwd 在项目子目录里、没匹配上、项目清单、since
        let listed = call(CodingTools.listSessions, ["project": "\(claudeProject)/src/deep", "agents": ["claude"]])
        XCTAssertFalse(listed.isError)
        XCTAssertTrue(listed.text.contains(claudeKey), listed.text)
        let nowhere = call(CodingTools.listSessions, ["project": "/nowhere/at/all"])
        XCTAssertFalse(nowhere.isError, "没匹配上项目不是错误")
        XCTAssertTrue(nowhere.text.contains("No indexed project matches"), nowhere.text)
        XCTAssertTrue(nowhere.text.contains(claudeProject), "should list known projects:\n\(nowhere.text)")
        XCTAssertTrue(call(CodingTools.listProjects, [:]).text.contains(claudeProject))
        XCTAssertTrue(call(CodingTools.listSessions, ["since": "2999-01-01"]).text.hasPrefix("No sessions"))

        // 5. 坏参数 / 坏 key 是给模型看的失败结果，不是崩溃
        let missing = call(CodingTools.getSession, ["key": "claude-code:nope"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("No session with key"), missing.text)
        XCTAssertTrue(call(CodingTools.search, [:]).isError, "query 必填")
        XCTAssertTrue(call(CodingTools.listSessions, ["since": "昨天"]).isError, "since 看不懂 = 参数错误")
        XCTAssertTrue(call(CodingTools.listSessions, ["agents": ["chatgpt"]]).text.contains("valid ids"))
        XCTAssertTrue(CodingTools.invoke(name: CodingTools.search, argumentsJSON: "[1]", context: context).isError, "参数不是对象")

        // 6. 全程只读
        XCTAssertEqual(try Data(contentsOf: indexURL), before, "AI 工具绝不写索引")
    }
}
#endif
