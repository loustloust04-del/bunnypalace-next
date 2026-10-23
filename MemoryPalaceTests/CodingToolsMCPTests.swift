#if os(macOS)
import SQLite3
import XCTest
@testable import 记忆花园

/// N6-a1：两份定义同源（名字 / 参数名 / 类型 / required 一致，只差描述、title 与 get_session 的 max_chars 限额）+ MCP 定义是 Wake 形状 + 错误类别
final class CodingToolsMCPTests: XCTestCase {
    private func canonical(_ obj: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
    }

    private func stripped(_ spec: [String: Any], _ param: String) -> [String: Any] {
        var dict = spec
        dict["description"] = nil
        if param == "max_chars" {
            dict["maximum"] = nil
            dict["default"] = nil
        }
        return dict
    }

    func testMCPDefinitionsShareParameterSpecWithAppDefinitions() throws {
        let app = CodingTools.definitions
        let mcp = CodingTools.mcpDefinitions
        XCTAssertEqual(mcp.compactMap { $0["name"] as? String }, app.map(\.name))
        for (a, m) in zip(app, mcp) {
            let schema = try XCTUnwrap(m["inputSchema"] as? [String: Any], a.name)
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["required"] as? [String] ?? [], a.required, a.name)
            let props = try XCTUnwrap(schema["properties"] as? [String: Any], a.name)
            XCTAssertEqual(Set(props.keys), Set(a.properties.keys), a.name)
            for (param, spec) in a.properties {
                let appSpec = try XCTUnwrap(spec as? [String: Any])
                let mcpSpec = try XCTUnwrap(props[param] as? [String: Any])
                XCTAssertEqual(appSpec["description"] == nil, mcpSpec["description"] == nil, "\(a.name).\(param) 描述有无要一致")
                XCTAssertEqual(try canonical(stripped(appSpec, param)), try canonical(stripped(mcpSpec, param)), "\(a.name).\(param)")
            }
        }

        // max_chars：app 内收紧，MCP 照 Wake
        let appGet = try XCTUnwrap(app.first { $0.name == CodingTools.getSession })
        let appMaxChars = appGet.properties["max_chars"] as? [String: Any]
        XCTAssertEqual(appMaxChars?["maximum"] as? Int, CodingTools.Limits.inApp.maxCharsMax)
        XCTAssertEqual(appMaxChars?["default"] as? Int, CodingTools.Limits.inApp.maxCharsDefault)
        let mcpGet = try XCTUnwrap(mcp.first { $0["name"] as? String == CodingTools.getSession })
        let mcpMaxChars = ((mcpGet["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["max_chars"] as? [String: Any]
        XCTAssertEqual(mcpMaxChars?["maximum"] as? Int, 100_000)
        XCTAssertEqual(mcpMaxChars?["default"] as? Int, 20_000)
    }

    func testMCPDefinitionsAreWakeShaped() throws {
        let mcp = CodingTools.mcpDefinitions
        XCTAssertEqual(mcp.compactMap { $0["title"] as? String },
                       ["Search session history", "List recent sessions", "Read a session transcript", "List indexed projects"])
        let readOnly: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        for d in mcp {
            let name = d["name"] as? String ?? ""
            XCTAssertEqual(try canonical(d["annotations"] as Any), try canonical(readOnly), name)
            XCTAssertFalse((d["description"] as? String ?? "").isEmpty, name)
            if name == CodingTools.listSessions || name == CodingTools.listProjects {
                XCTAssertNil((d["inputSchema"] as? [String: Any])?["required"], "\(name)：没有必填参数不写 required（同 Wake）")
            }
        }
        let json = try canonical(mcp)
        XCTAssertFalse(json.lowercased().contains("wake"), "Wake 的工具名 / scheme / 应用名都换掉")
        XCTAssertTrue(json.contains("code_get_session"))
        XCTAssertTrue(json.contains("code://session/"))
        XCTAssertTrue(json.contains("starred in \(CodingTools.appName)."))
    }

    func testResultKinds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-code-kinds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        do { _ = try CodingSessionIndex(url: url) }   // 建空库，写连接在作用域里关掉
        func context() throws -> CodingTools.Context {
            CodingTools.Context(index: try CodingSessionIndex(url: url, readOnly: true), adapters: [], favorites: [], nowMs: 0,
                                cache: CodingTools.TranscriptCache())
        }
        let ctx = try context()
        XCTAssertEqual(CodingTools.invoke(name: CodingTools.listSessions, arguments: [:], context: ctx).kind, .ok)
        XCTAssertEqual(CodingTools.invoke(name: "code_nope", arguments: [:], context: ctx).kind, .invalidParams, "未知工具 = 参数错（Wake 同）")
        XCTAssertEqual(CodingTools.invoke(name: CodingTools.search, argumentsJSON: "[1]", context: ctx).kind, .invalidParams, "参数不是对象")
        XCTAssertEqual(CodingTools.invoke(name: CodingTools.search, arguments: [:], context: ctx).kind, .invalidParams, "query 必填")
        let missing = CodingTools.invoke(name: CodingTools.getSession, arguments: ["key": "claude-code:nope"], context: ctx)
        XCTAssertEqual(missing.kind, .failed, "坏 key = 执行失败")
        XCTAssertTrue(missing.isError)

        // 表没了 = 查询失败 = 内部错误（CLI 退 1、MCP -32603）。只读打开会校验表结构，所以先开连接再删表
        let brokenContext = try context()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE sessions", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let broken = CodingTools.invoke(name: CodingTools.listSessions, arguments: [:], context: brokenContext)
        XCTAssertEqual(broken.kind, .internal, broken.text)
        XCTAssertTrue(broken.isError)
    }
}
#endif
