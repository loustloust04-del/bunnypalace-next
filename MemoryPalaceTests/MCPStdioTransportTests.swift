#if os(macOS)
import XCTest
@testable import 记忆花园

/// W-M stdio MCP 传输（plan-wake-mcp §2.5）：假 server 是 tmp 里的 python3 脚本，按行回 JSON-RPC。
@MainActor
final class MCPStdioTransportTests: XCTestCase {

    private static let fakeServer = #"""
    import sys, json, os, time
    mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
    if mode == "die":
        sys.stderr.write("wake-mcp: no index here, launch Wake once\n")
        sys.stderr.flush()
        sys.exit(2)
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        msg = json.loads(raw)
        if "id" not in msg:
            continue
        method = msg.get("method")
        if method == "initialize":
            result = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "fake", "version": "0"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "echo_env", "description": os.environ.get("FAKE_MCP_TAG", ""),
                                 "inputSchema": {"type": "object", "properties": {}}}]}
        elif method == "tools/call":
            if mode == "exit_on_call":
                sys.exit(0)
            result = {"content": [{"type": "text", "text": "ok"}], "isError": False}
        else:
            result = {}
        out = json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result})
        if mode == "split":
            half = len(out) // 2
            sys.stdout.write(out[:half]); sys.stdout.flush(); time.sleep(0.05)
            sys.stdout.write(out[half:] + "\n"); sys.stdout.flush()
        elif mode == "batch" and method == "tools/list":
            note = json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {}})
            sys.stdout.write(note + "\n" + out + "\n"); sys.stdout.flush()
        else:
            sys.stdout.write(out + "\n"); sys.stdout.flush()
    """#

    private var scriptPath = ""

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-mcp-stdio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake_mcp.py")
        try Self.fakeServer.write(to: url, atomically: true, encoding: .utf8)
        scriptPath = url.path
    }

    private func transport(_ mode: String, env: [String: String] = [:]) throws -> MCPStdioTransport {
        try MCPStdioTransport(command: "/usr/bin/python3 -u '\(scriptPath)' \(mode)", env: env)
    }

    // T1 + T6：initialize + tools/list 往返；env 透传给子进程
    func testInitializeListToolsAndEnv() async throws {
        let client = MCPClient(requestTimeout: 5)
        try await client.connect(transport: try transport("normal", env: ["FAKE_MCP_TAG": "tag-123"]))
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo_env"])
        XCTAssertEqual(tools.first?.description, "tag-123")
        client.disconnect()
    }

    // T2：一条 JSON 拆两次写 / 通知 + 回包一次写
    func testSplitAndBatchedLines() async throws {
        for mode in ["split", "batch"] {
            let client = MCPClient(requestTimeout: 5)
            try await client.connect(transport: try transport(mode))
            let tools = try await client.listTools()
            XCTAssertEqual(tools.map(\.name), ["echo_env"], mode)
            client.disconnect()
        }
    }

    // T3：缺索引式早退 → 几秒内报错且带 stderr 原因，不等 30 s 请求超时
    func testEarlyExitReportsStderrQuickly() async throws {
        let client = MCPClient(requestTimeout: 30)
        let start = Date()
        do {
            try await client.connect(transport: try transport("die"))
            XCTFail("connect 应失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("launch Wake once"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("code 2"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        client.disconnect()
    }

    // T4：server 在工具调用中途退出 → 调用抛错、再发也抛错，测试进程（= MP）活着
    func testServerDiesMidCallDoesNotCrash() async throws {
        let client = MCPClient(requestTimeout: 5)
        try await client.connect(transport: try transport("exit_on_call"))
        do {
            _ = try await client.callTool(name: "echo_env", arguments: [:])
            XCTFail("server 退出后调用应失败")
        } catch {}
        do {
            _ = try await client.callTool(name: "echo_env", arguments: [:])
            XCTFail("连接已断，再调应失败")
        } catch {}
        client.disconnect()
    }

    // T4b：直接对已退出的进程写，不 SIGPIPE
    func testSendAfterExitThrows() async throws {
        let t = try transport("exit_on_call")
        try await t.connect()
        let pid = try XCTUnwrap(t.processIdentifier)
        try await t.send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "x", "arguments": [:]]])
        await waitUntilGone(pid)
        do {
            for i in 0..<50 {
                try await t.send(["jsonrpc": "2.0", "id": 2 + i, "method": "ping", "params": [:]])
            }
            XCTFail("进程已退出，send 应抛错")
        } catch {}
        t.close()
    }

    // T5：close 后子进程确实退出
    func testCloseTerminatesProcess() async throws {
        let client = MCPClient(requestTimeout: 5)
        let t = try transport("normal")
        try await client.connect(transport: t)
        let pid = try XCTUnwrap(t.processIdentifier)
        XCTAssertEqual(kill(pid, 0), 0)
        client.disconnect()
        await waitUntilGone(pid)
        XCTAssertNotEqual(kill(pid, 0), 0, "close 后 3 s 内子进程应退出")
    }

    func testEmptyCommandRejected() {
        XCTAssertThrowsError(try MCPStdioTransport(command: "   ", env: [:]))
    }

    // T7：配置编解码
    func testConfigRoundTripAndLegacyDecode() throws {
        let config = MCPServerConfig(name: "Wake", transport: .stdio, url: "", command: "/x/wake-mcp --db '/a b'", env: ["A": "1"])
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.transport, .stdio)
        XCTAssertEqual(decoded.command, "/x/wake-mcp --db '/a b'")
        XCTAssertEqual(decoded.env, ["A": "1"])

        let legacy = try JSONDecoder().decode(MCPServerConfig.self, from: Data(#"{"name":"a","url":"https://x","transport":"sse"}"#.utf8))
        XCTAssertEqual(legacy.command, "")
        XCTAssertEqual(legacy.env, [:])
        XCTAssertEqual(legacy.transport, .sse)
        let unknown = try JSONDecoder().decode(MCPServerConfig.self, from: Data(#"{"name":"a","url":"https://x","transport":"weird"}"#.utf8))
        XCTAssertEqual(unknown.transport, .sse)
    }

    // T7b：env-only 条目落盘时 env 进 Keychain 值，UserDefaults 副本里没有明文（R-WM #1）
    func testSplitSecretsKeepsEnvOutOfDefaults() throws {
        let envOnly = MCPServerConfig(name: "Wake", transport: .stdio, url: "", command: "x", env: ["TOKEN": "s3cret"])
        let plain = MCPServerConfig(name: "p", transport: .sse, url: "https://x")
        let split = MCPProvider.splitSecrets([envOnly, plain])
        XCTAssertEqual(split.stored.map(\.env), [[:], [:]])
        let storedJSON = String(decoding: try JSONEncoder().encode(split.stored), as: UTF8.self)
        XCTAssertFalse(storedJSON.contains("s3cret"))
        XCTAssertTrue(split.secrets[0].json?.contains("s3cret") == true)
        XCTAssertNil(split.secrets[1].json)
    }

    func testPickerCasesIncludeStdioOnMac() {
        XCTAssertTrue(MCPTransportType.pickerCases.contains(.stdio))
        XCTAssertEqual(MCPTransportType.stdio.displayName, "本地命令")
    }

    // T8：真 wake-mcp（没装就跳过）。WAKE_HOME 指空 tmp + --db tmp 库：不碰她的 agent 目录和真索引
    func testRealWakeMCPAgainstEmptyIndex() async throws {
        let app = "/Applications/Wake.app/Contents/MacOS"
        guard FileManager.default.isExecutableFile(atPath: "\(app)/wake-mcp"),
              FileManager.default.isExecutableFile(atPath: "\(app)/wake-cli") else {
            throw XCTSkip("Wake 未安装")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mp-wake-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let db = home.appendingPathComponent("wake.db").path

        let index = Process()
        index.executableURL = URL(fileURLWithPath: "\(app)/wake-cli")
        index.arguments = ["--db", db, "index"]
        index.environment = ["WAKE_HOME": home.path, "HOME": home.path]
        index.standardOutput = Pipe()
        index.standardError = Pipe()
        try index.run()
        index.waitUntilExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: db), "wake-cli index 应在 tmp 建库")

        let client = MCPClient(requestTimeout: 10)
        let t = try MCPStdioTransport(command: "'\(app)/wake-mcp' --db '\(db)'", env: ["WAKE_HOME": home.path])
        try await client.connect(transport: t)
        let names = Set(try await client.listTools().map(\.name))
        XCTAssertEqual(names, ["wake_search", "wake_list_sessions", "wake_get_session", "wake_list_projects"])
        let result = try await client.callTool(name: "wake_list_projects", arguments: [:])
        XCTAssertFalse(result.isError)
        client.disconnect()
    }

    private func waitUntilGone(_ pid: Int32) async {
        for _ in 0..<30 where kill(pid, 0) == 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
#endif
