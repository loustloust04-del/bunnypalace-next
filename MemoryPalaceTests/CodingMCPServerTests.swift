#if os(macOS)
import SQLite3
import XCTest
@testable import 记忆花园

/// N6-c：MCP 协议层逐条（Wake `mcp/mod.rs` + `tests/mcp_stdio.rs` 的协议面 + R-WN6 S2 补的漏项），进程内直接喂 handleLine / serve；
/// 真二进制的 stdio 往返在端到端那边
final class CodingMCPServerTests: XCTestCase {
    private var dir: URL!
    private var indexURL: URL { dir.appendingPathComponent("index.sqlite") }
    private var server: CodingMCPServer!
    private var logged: [String] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-code-mcp-\(UUID().uuidString)")
        do { _ = try CodingSessionIndex(url: indexURL) }   // 建空库，写连接在作用域里关掉
        server = CodingMCPServer(index: try CodingSessionIndex(url: indexURL, readOnly: true), adapters: [], favorites: [])
        server.log = { [unowned self] in self.logged.append($0) }
    }

    override func tearDownWithError() throws {
        server = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func canonical(_ obj: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private func reply(_ line: String, file: StaticString = #filePath, line number: UInt = #line) throws -> [String: Any] {
        let text = try XCTUnwrap(server.handleLine(line), "应当有回包：\(line)", file: file, line: number)
        XCTAssertFalse(text.contains("\n"), "一行一条", file: file, line: number)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], file: file, line: number)
    }

    private func request(_ method: String, _ params: Any? = nil, id: Any = 1,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        return try reply(String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self), file: file, line: line)
    }

    private func errorCode(_ reply: [String: Any]) -> Int? {
        (reply["error"] as? [String: Any])?["code"] as? Int
    }

    private func result(_ reply: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(reply["result"] as? [String: Any], "应当是结果：\(reply)", file: file, line: line)
    }

    func testHandshakePingAndToolList() throws {
        let initReply = try request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                   "clientInfo": ["name": "t", "version": "0"]])
        XCTAssertEqual(initReply["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(initReply["id"] as? Int, 1)
        let initialized = try result(initReply)
        XCTAssertEqual(initialized["protocolVersion"] as? String, "2025-06-18")
        let info = try XCTUnwrap(initialized["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "mp-code")
        XCTAssertEqual(info["title"] as? String, CodingTools.appName)
        XCTAssertEqual(info["version"] as? String, CodingCLI.version)
        XCTAssertEqual(((initialized["capabilities"] as? [String: Any])?["tools"] as? [String: Any])?["listChanged"] as? Bool, false)
        XCTAssertTrue((initialized["instructions"] as? String ?? "").contains(CodingTools.search))
        // 客户端要的版本在支持表里就回显，否则回本方的
        XCTAssertEqual(try result(request("initialize", ["protocolVersion": "2024-11-05"]))["protocolVersion"] as? String, "2024-11-05")
        XCTAssertEqual(try result(request("initialize", ["protocolVersion": "2099-01-01"]))["protocolVersion"] as? String,
                       CodingMCPServer.protocolVersion)
        XCTAssertEqual(try result(request("initialize"))["protocolVersion"] as? String, CodingMCPServer.protocolVersion)

        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "通知不回包")
        XCTAssertEqual(logged, ["client initialized"], "initialized 只写 stderr")
        XCTAssertEqual(try canonical(result(request("ping"))), "{}")

        let tools = try XCTUnwrap(try result(request("tools/list"))["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       [CodingTools.search, CodingTools.listSessions, CodingTools.getSession, CodingTools.listProjects])
        XCTAssertEqual(try canonical(tools), try canonical(CodingTools.mcpDefinitions))
    }

    func testProtocolErrors() throws {
        // 解析失败：-32700、id 为 null
        let parse = try reply("{not json")
        XCTAssertEqual(errorCode(parse), -32700)
        XCTAssertTrue(parse["id"] is NSNull)
        // 空批量、非对象消息：-32600
        XCTAssertEqual(errorCode(try reply("[]")), -32600)
        let scalar = try reply("42")
        XCTAssertEqual(errorCode(scalar), -32600)
        XCTAssertTrue(scalar["id"] is NSNull)
        // 未知方法 -32601
        let unknown = try request("resources/list")
        XCTAssertEqual(errorCode(unknown), -32601)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["message"] as? String, "Method not found: resources/list")
        // 没有 method：带 result / error 的是响应，静默丢；带 id 却什么都没有的回 Invalid Request（id 回显）
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","id":7,"result":{}}"#))
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","id":7,"error":{"code":1,"message":"x"}}"#))
        let bare = try reply(#"{"jsonrpc":"2.0","id":7}"#)
        XCTAssertEqual(errorCode(bare), -32600)
        XCTAssertEqual(bare["id"] as? Int, 7)
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0"}"#), "没 id 也没 method：什么都不回")
        // 通知（无 id 或 id 为 null）不回包，不管认不认识
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","method":"nope"}"#))
        XCTAssertNil(server.handleLine(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#))
        // 字符串 id 原样回显
        XCTAssertEqual(try request("ping", id: "abc")["id"] as? String, "abc")
    }

    func testBatches() throws {
        let text = try XCTUnwrap(server.handleLine(
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"nope"}]"#))
        let replies = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(replies.map { $0["id"] as? Int }, [1, 2], "通知不占位")
        XCTAssertEqual(errorCode(replies[1]), -32601)
        XCTAssertNil(server.handleLine(#"[{"jsonrpc":"2.0","method":"a"},{"jsonrpc":"2.0","method":"b"}]"#), "全是通知的批量不回包")
        let scalars = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(server.handleLine("[1]")).utf8)) as? [[String: Any]])
        XCTAssertEqual(errorCode(scalars[0]), -32600, "批量里的非对象逐条回 Invalid Request")
    }

    func testToolsCall() throws {
        func call(_ params: [String: Any]) throws -> [String: Any] { try request("tools/call", params) }
        XCTAssertEqual(errorCode(try call([:])), -32602, "name 必须是串")
        XCTAssertEqual(errorCode(try call(["name": 3])), -32602)
        XCTAssertEqual(errorCode(try call(["name": CodingTools.listSessions, "arguments": [1]])), -32602, "arguments 必须是对象")
        XCTAssertEqual(errorCode(try call(["name": "code_delete_everything", "arguments": [String: Any]()])), -32602, "未知工具 = 参数错")
        XCTAssertEqual(errorCode(try call(["name": CodingTools.listSessions, "arguments": ["since": "yesterday"]])), -32602, "参数形状错是协议错误")
        XCTAssertEqual(errorCode(try call(["name": CodingTools.listSessions, "arguments": ["since": "7天"]])), -32602, "非 ASCII 收尾的 since 不崩")

        let ok = try result(call(["name": CodingTools.listSessions, "arguments": NSNull()]))
        XCTAssertEqual(ok["isError"] as? Bool, false, "arguments 为 null 照常跑")
        let content = try XCTUnwrap(ok["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertFalse((content.first?["text"] as? String ?? "").isEmpty)
        XCTAssertEqual(try result(call(["name": CodingTools.listProjects]))["isError"] as? Bool, false, "arguments 缺省照常跑")

        // 坏 key 是给模型看的失败结果，不是协议错误
        let missing = try result(call(["name": CodingTools.getSession, "arguments": ["key": "claude-code:nope"]]))
        XCTAssertEqual(missing["isError"] as? Bool, true)
        XCTAssertTrue(((missing["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").contains("No session with key"))

        // 查询炸了是内部错误 -32603
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(indexURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE sessions", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertEqual(errorCode(try call(["name": CodingTools.listSessions, "arguments": [String: Any]()])), -32603)
    }

    func testServeReadsLinesSkipsBlanksAndStopsAtEOF() throws {
        var lines = ["", #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, "   ", #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                     #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#]
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let code = server.serve(next: { lines.isEmpty ? nil : lines.removeFirst() }, fd: fds[1])
        close(fds[1])
        XCTAssertEqual(code, 0, "EOF 正常收场")
        let out = String(decoding: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(out.hasSuffix("\n"))
        let ids = out.split(separator: "\n").compactMap { line -> Int? in
            ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? Int
        }
        XCTAssertEqual(ids, [1, 2], out)

        // 客户端先走一步（读端关了）是正常收场
        var closed: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&closed), 0)
        _ = fcntl(closed[1], F_SETNOSIGPIPE, 1)
        close(closed[0])
        var more = [#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#]
        XCTAssertEqual(server.serve(next: { more.isEmpty ? nil : more.removeFirst() }, fd: closed[1]), 0)
        close(closed[1])
    }
}
#endif
