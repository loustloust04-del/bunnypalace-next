import XCTest
@testable import 记忆花园

/// plan-opencli-in-app C2：chrome_read / site_query 的请求拼装、回帧解析、权限域、下发闸
final class ChromeBridgeToolsTests: XCTestCase {
    func testRequestFromModelArgs() throws {
        let read = try XCTUnwrap(ChromeBridgeTools.request(name: "chrome_read", inputJSON: #"{"url":" https://zhihu.com/q/1 ","start":12000}"#, blocked: ["mail.google.com"]))
        XCTAssertEqual(read["tool"] as? String, "chrome_read")
        XCTAssertEqual(read["url"] as? String, "https://zhihu.com/q/1")
        XCTAssertEqual(read["start"] as? Int, 12000)
        XCTAssertEqual(read["blocked"] as? [String], ["mail.google.com"])

        let list = try XCTUnwrap(ChromeBridgeTools.request(name: "site_query", inputJSON: #"{"site":"youtube"}"#, blocked: []))
        XCTAssertNil(list["command"])
        XCTAssertNil(list["args"])

        let query = try XCTUnwrap(ChromeBridgeTools.request(name: "site_query", inputJSON: #"{"site":"youtube","command":"transcript","args":{"url":"dQw4w9WgXcQ","lang":"en"}}"#, blocked: []))
        XCTAssertEqual(query["command"] as? String, "transcript")
        XCTAssertEqual((query["args"] as? [String: Any])?["lang"] as? String, "en")

        XCTAssertNil(ChromeBridgeTools.request(name: "chrome_read", inputJSON: "{}", blocked: []))
        XCTAssertNil(ChromeBridgeTools.request(name: "site_query", inputJSON: #"{"site":" "}"#, blocked: []))
        XCTAssertNil(ChromeBridgeTools.request(name: "run_command", inputJSON: #"{"site":"x"}"#, blocked: []))
    }

    func testReplyParseAndResultText() throws {
        let ok = try XCTUnwrap(HubOpencliReply.parse(["type": "opencli_result", "ok": true, "text": "[来源]\n正文", "next_start": 12000, "request_id": "r"]))
        let okText = ChromeBridgeTools.resultText(ok)
        XCTAssertFalse(okText.isError)
        XCTAssertEqual(okText.text, "[来源]\n正文\n\n[没读完：传 start=12000 接着读]")

        let done = try XCTUnwrap(HubOpencliReply.parse(["type": "opencli_result", "ok": true, "text": "全文"]))
        XCTAssertEqual(ChromeBridgeTools.resultText(done).text, "全文")

        let failed = try XCTUnwrap(HubOpencliReply.parse(["type": "opencli_result", "ok": false, "error": "Mac 上的 Chrome 没连上"]))
        let failedText = ChromeBridgeTools.resultText(failed)
        XCTAssertTrue(failedText.isError)
        XCTAssertTrue(failedText.text.contains("Mac 上的 Chrome 没连上"))

        if case .failure(let e) = try XCTUnwrap(HubOpencliReply.parse(["type": "opencli_result", "ok": true])) {
            XCTAssertEqual(e.reason, "Mac 没给结果")
        } else {
            XCTFail("ok 却没正文要当失败")
        }
        XCTAssertNil(HubOpencliReply.parse(["type": "dir_list"]))
    }

    func testBothToolsAreWebSearchDomain() {
        XCTAssertEqual(PermissionDomain.forTool(named: "chrome_read"), .webSearch)
        XCTAssertEqual(PermissionDomain.forTool(named: "site_query"), .webSearch)
    }

    @MainActor
    func testNotOfferedWithoutHubCapability() {
        XCTAssertFalse(ChromeBridgeTools.hubReady)
        for family in [ToolGateContext.Family.openAI, .anthropic] {
            let ctx = ToolGateContext(family: family, deferMCP: false)
            let offered = ToolRegistry.all.filter { $0.enabledIf(ctx) }.map(\.definition.name)
            XCTAssertFalse(offered.contains("chrome_read"))
            XCTAssertFalse(offered.contains("site_query"))
        }
    }

    func testRecommendedBlocklistCoversChromeLoginSites() {
        for host in ["mail.google.com", "claude.ai", "chatgpt.com", "appleid.apple.com", "1password.com"] {
            XCTAssertTrue(WebSearchSettings.recommendedBlocklist.contains(host), host)
        }
    }
}
