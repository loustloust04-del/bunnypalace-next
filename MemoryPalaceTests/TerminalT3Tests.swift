import XCTest
@testable import 记忆花园

/// #046 终端 T3：hello 帧解析容错。
final class HubHelloTests: XCTestCase {
    private func parse(_ json: String) -> HubHello? {
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return HubHello(frame: obj)
    }

    func testFullFrame() {
        let hello = parse("""
        {"type":"hello","hub_version":"1.4.0","host_name":"禾禾的 MacBook Pro","host_model_id":"Mac17,4",
         "host_model_name":"MacBook Air (15-inch, M5)",
         "dirs":{"claude_home":"/Users/a/cc-rp","codex_home":"/Users/a/gpt-rp","agent_workdir":"/Users/a/code"},
         "tools":{"tmux":true,"claude":true,"codex":false},"capabilities":["hello","dirs","end_window"]}
        """)
        XCTAssertEqual(hello?.hubVersion, "1.4.0")
        XCTAssertEqual(hello?.hostName, "禾禾的 MacBook Pro")
        XCTAssertEqual(hello?.hostModelId, "Mac17,4")
        XCTAssertEqual(hello?.displayName, "禾禾的 MacBook Pro · MacBook Air (15-inch, M5)")
        XCTAssertEqual(hello?.dirs, HubHello.Dirs(claudeHome: "/Users/a/cc-rp", codexHome: "/Users/a/gpt-rp", agentWorkdir: "/Users/a/code"))
        XCTAssertEqual(hello?.tools, HubHello.Tools(tmux: true, claude: true, codex: false))
        XCTAssertEqual(hello?.capabilities, ["hello", "dirs", "end_window"])
    }

    func testWrongTypeIsNil() {
        XCTAssertNil(parse(#"{"type":"terminal_state"}"#))
        XCTAssertNil(parse(#"{"host_name":"x"}"#))
    }

    func testMissingAndWrongTypedFieldsDoNotCrash() {
        let hello = parse("""
        {"type":"hello","host_name":42,"dirs":"oops","tools":{"tmux":null,"claude":1,"codex":"yes"},"capabilities":[1,"hello",null]}
        """)
        XCTAssertNotNil(hello)
        XCTAssertNil(hello?.hostName)
        XCTAssertNil(hello?.displayName)
        XCTAssertEqual(hello?.dirs, HubHello.Dirs())
        // 数字 1 / 字符串都不算布尔：当「不知道」，不拦
        XCTAssertEqual(hello?.tools, HubHello.Tools())
        XCTAssertEqual(hello?.capabilities, ["hello"])
    }

    func testNullAgentWorkdirMeansHome() {
        let hello = parse(#"{"type":"hello","dirs":{"claude_home":"/h","agent_workdir":null}}"#)
        XCTAssertNil(hello?.dirs.agentWorkdir)
        XCTAssertEqual(hello?.dirs.claudeHome, "/h")
    }

    func testMergeHubConfig() {
        var hello = HubHello(dirs: .init(claudeHome: "/h", codexHome: "/c", agentWorkdir: "/w"))
        hello.merge(hubConfig: ["type": "hub_config", "agent_workdir": NSNull()])
        XCTAssertNil(hello.dirs.agentWorkdir)
        XCTAssertEqual(hello.dirs.claudeHome, "/h")
        hello.merge(hubConfig: ["agent_workdir": "/new", "codex_home": "/c2"])
        XCTAssertEqual(hello.dirs, .init(claudeHome: "/h", codexHome: "/c2", agentWorkdir: "/new"))
    }

    func testDirListing() {
        let ok = HubDirListing.parse(["type": "dir_list", "path": "/Users/a", "parent": "/Users", "dirs": ["code", 3, "notes"], "truncated": true])
        XCTAssertEqual(try? ok?.get(), HubDirListing(path: "/Users/a", parent: "/Users", dirs: ["code", "notes"], truncated: true))
        let root = HubDirListing.parse(["type": "dir_list", "path": "/", "parent": NSNull(), "dirs": []])
        if case .success(let listing)? = root { XCTAssertNil(listing.parent) } else { XCTFail("根目录应当成功") }
        guard case .failure(let err)? = HubDirListing.parse(["type": "dir_list", "path": "/x", "error": "读不了这个文件夹"]) else {
            return XCTFail("error 帧应当失败")
        }
        XCTAssertEqual(err.reason, "读不了这个文件夹")
        XCTAssertNil(HubDirListing.parse(["type": "hello"]))
    }
}

/// #046 刀 2：配对页口令 / 端口的来源 + 外部 hub 闸。
final class PairingEndpointTests: XCTestCase {
    func testExternalHubWinsAndUses7890() {
        XCTAssertEqual(PairingEndpoint.resolve(externalHub: true, externalToken: "ext", embeddedPort: 51234, embeddedToken: "emb"),
                       .ready(port: 7890, token: "ext"))
    }

    func testExternalWithoutTokenIsMissingToken() {
        XCTAssertEqual(PairingEndpoint.resolve(externalHub: true, externalToken: nil, embeddedPort: nil, embeddedToken: nil), .missingToken)
        XCTAssertEqual(PairingEndpoint.resolve(externalHub: true, externalToken: "", embeddedPort: 1, embeddedToken: "e"), .missingToken)
    }

    func testEmbeddedRunningUsesItsPort() {
        XCTAssertEqual(PairingEndpoint.resolve(externalHub: false, externalToken: "ext", embeddedPort: 51234, embeddedToken: "emb"),
                       .ready(port: 51234, token: "emb"))
        XCTAssertEqual(PairingEndpoint.resolve(externalHub: false, externalToken: nil, embeddedPort: 51234, embeddedToken: nil), .missingToken)
    }

    func testNothingRunning() {
        let r = PairingEndpoint.resolve(externalHub: false, externalToken: "ext", embeddedPort: nil, embeddedToken: "emb")
        XCTAssertEqual(r, .noHub)
        XCTAssertNotNil(r.failureText)
        XCTAssertNil(PairingEndpoint.ready(port: 1, token: "t").failureText)
    }

    func testExternalGate() {
        XCTAssertTrue(ExternalHub.isExternal(plistExists: true, healthResponds: false, embeddedPort: nil))
        XCTAssertTrue(ExternalHub.isExternal(plistExists: false, healthResponds: true, embeddedPort: nil))
        XCTAssertTrue(ExternalHub.isExternal(plistExists: false, healthResponds: true, embeddedPort: 51234))
        // 应答的正是内嵌 hub 自己（OS 恰好分到 7890）
        XCTAssertFalse(ExternalHub.isExternal(plistExists: false, healthResponds: true, embeddedPort: 7890))
        XCTAssertFalse(ExternalHub.isExternal(plistExists: false, healthResponds: false, embeddedPort: nil))
    }

    func testPlistDetectionInTempDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("la-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(ExternalHub.plistExists(inLaunchAgents: dir))
        try Data().write(to: dir.appendingPathComponent("com.other.agent.plist"))
        XCTAssertFalse(ExternalHub.plistExists(inLaunchAgents: dir))
        try Data().write(to: dir.appendingPathComponent("com.someone.cc-bridge-hub.plist"))
        XCTAssertTrue(ExternalHub.plistExists(inLaunchAgents: dir))
        XCTAssertFalse(ExternalHub.plistExists(inLaunchAgents: dir.appendingPathComponent("nope")))
    }
}

/// #046 astra 实现审 #3：配置 / 目录请求按 request_id 认领，不再 FIFO。
final class HubPendingRequestsTests: XCTestCase {
    func testMatchesByIdNotOrder() {
        var table = HubPendingRequests<String>()
        table.add("a", "first")
        table.add("b", "second")
        // 后发的先回：按 id 认，不会把 b 的回帧交给 a
        XCTAssertEqual(table.take("b"), "second")
        XCTAssertEqual(table.take("a"), "first")
    }

    func testLateReplyAfterTimeoutIsDropped() {
        var table = HubPendingRequests<String>()
        table.add("a", "timed-out")
        XCTAssertEqual(table.take("a"), "timed-out")   // 超时那一路先收走
        table.add("b", "next")
        XCTAssertNil(table.take("a"))                  // a 的迟到回帧：找不到就丢，不顶给 b
        XCTAssertEqual(table.take("b"), "next")
    }

    func testFrameWithoutRequestIdConsumesNothing() {
        var table = HubPendingRequests<String>()
        table.add("a", "set")
        XCTAssertNil(table.take(nil))                  // GET 回帧 / 广播没带 id：只刷新显示
        XCTAssertNil(table.take("unknown"))
        XCTAssertEqual(table.take("a"), "set")
    }

    func testDisconnectTakesAllAndOldRepliesNoLongerMatch() {
        var table = HubPendingRequests<String>()
        table.add("a", "x")
        table.add("b", "y")
        XCTAssertEqual(Set(table.takeAll()), ["x", "y"])
        XCTAssertTrue(table.takeAll().isEmpty)
        XCTAssertNil(table.take("a"))                  // 旧连接的回帧之后才到：不认
    }

    func testRequestIdParsing() {
        XCTAssertEqual(CCBridgeWebSocketClient.requestId(["type": "dir_list", "request_id": "r1"]), "r1")
        XCTAssertNil(CCBridgeWebSocketClient.requestId(["type": "hub_config"]))
        XCTAssertNil(CCBridgeWebSocketClient.requestId(["type": "hub_config", "request_id": ""]))
        XCTAssertNil(CCBridgeWebSocketClient.requestId(["type": "hub_config", "request_id": 3]))
    }
}

/// #046 刀 3：终端错误 / 断桥原因的人话。
final class TerminalWordingTests: XCTestCase {
    func testTerminalErrorMapping() {
        XCTAssertEqual(TerminalErrorWording.humanize("send-keys: exit 1"), "刚才那下没发出去")
        XCTAssertEqual(TerminalErrorWording.humanize("capture failed: tmux died"), "画面没拉下来 · 点重新绘制")
        XCTAssertEqual(TerminalErrorWording.humanize("attach failed: no pane"), "画面没拉下来 · 点重新绘制")
        XCTAssertEqual(TerminalErrorWording.humanize("something odd"), "电脑那边出了点问题")
        // 自动恢复起不来时 hub 给的人话原样透出，不被盖成「出了点问题」/「窗口已经结束了」
        XCTAssertEqual(TerminalErrorWording.humanize("电脑上没装 tmux（brew install tmux）"), "电脑上没装 tmux（brew install tmux）")
        XCTAssertEqual(TerminalErrorWording.humanize("电脑上还没装 Claude Code"), "电脑上还没装 Claude Code")
        XCTAssertTrue(TerminalErrorWording.notAnErrorLine.contains("stream_session"))
        XCTAssertTrue(TerminalErrorWording.notAnErrorLine.contains("session_not_found"))
    }

    func testDisconnectReasons() {
        XCTAssertNil(BridgeDisconnectWording.humanize(nil))
        XCTAssertNil(BridgeDisconnectWording.humanize("  "))
        XCTAssertEqual(BridgeDisconnectWording.humanize("auth"), "口令不对：重新扫码配对一次")
        XCTAssertEqual(BridgeDisconnectWording.humanize("bundle"), "电脑上的 hub 不认这个 App")
        XCTAssertEqual(BridgeDisconnectWording.humanize("探测全败：192.168.1.5:7890 The request timed out."), "找不到电脑：所有地址都连不上")
        XCTAssertEqual(BridgeDisconnectWording.humanize("connect timeout"), "等了太久没回应：电脑可能睡着了")
        XCTAssertEqual(BridgeDisconnectWording.humanize("Could not connect to the server."), "电脑拒绝了连接：hub 可能没在跑")
        XCTAssertEqual(BridgeDisconnectWording.humanize("未能连接服务器。"), "电脑拒绝了连接：hub 可能没在跑")
        XCTAssertEqual(BridgeDisconnectWording.humanize("closed (1006)"), "连接断了")
    }

    func testTailscaleHintOnlyWhenProbeFailedAndTailscaleCandidate() {
        let failed = "探测全败：a；b"
        XCTAssertEqual(BridgeDisconnectWording.tailscaleHint(lastError: failed, candidateHosts: ["192.168.1.5", "100.101.2.3"]),
                       "在外面？要开 Tailscale")
        XCTAssertEqual(BridgeDisconnectWording.tailscaleHint(lastError: failed, candidateHosts: ["mac.tail1234.ts.net"]),
                       "在外面？要开 Tailscale")
        XCTAssertNil(BridgeDisconnectWording.tailscaleHint(lastError: failed, candidateHosts: ["192.168.1.5"]))
        XCTAssertNil(BridgeDisconnectWording.tailscaleHint(lastError: "connect timeout", candidateHosts: ["100.101.2.3"]))
    }

    func testRouteClassification() {
        XCTAssertEqual(NetworkRoute.classify("100.64.0.1"), .tailscale)
        XCTAssertEqual(NetworkRoute.classify("100.127.255.254"), .tailscale)
        XCTAssertEqual(NetworkRoute.classify("100.128.0.1"), .lan)
        XCTAssertEqual(NetworkRoute.classify("100.63.0.1"), .lan)
        XCTAssertEqual(NetworkRoute.classify("127.0.0.1"), .local)
        XCTAssertEqual(NetworkRoute.classify("192.168.31.20"), .lan)
    }
}
