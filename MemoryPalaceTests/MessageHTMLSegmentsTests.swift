import XCTest
@testable import 记忆花园

/// 卡库 ⑦：明确 HTML 识别（围栏 / 完整文档 / 酒馆助手标记）、混排保前后文本、普通代码块和比较符号不误认
final class MessageHTMLSegmentsTests: XCTestCase {

    private func kinds(_ segs: [MessageHTMLSegment]?) -> [String] {
        (segs ?? []).map { "\($0.kind.rawValue):\($0.id)" }
    }

    // MARK: - 识别

    func testHTMLFenceMixedKeepsSurroundingText() throws {
        let text = "开场白第一段。\n\n```html\n<div class=\"panel\">所在：河岸</div>\n```\n\n后面的话。"
        let segs = try XCTUnwrap(MessageHTMLSegments.split(text))
        XCTAssertEqual(kinds(segs), ["text:t0", "html:h0", "text:t1"])
        XCTAssertEqual(segs[0].content, "开场白第一段。")
        XCTAssertEqual(segs[1].content, "<div class=\"panel\">所在：河岸</div>")
        XCTAssertEqual(segs[2].content, "后面的话。")
    }

    func testFenceLanguageCaseInsensitiveAndHtm() throws {
        XCTAssertEqual(kinds(MessageHTMLSegments.split("```HTML\n<p>x</p>\n```")), ["html:h0"])
        XCTAssertEqual(kinds(MessageHTMLSegments.split("```htm\n<p>x</p>\n```")), ["html:h0"])
    }

    func testFullDocumentOutsideFence() throws {
        let text = "看这个：\n<!DOCTYPE html>\n<html><head><title>状态</title></head>\n\n<body><p>hi</p></body>\n</html> 尾巴\n再一行"
        let segs = try XCTUnwrap(MessageHTMLSegments.split(text))
        XCTAssertEqual(kinds(segs), ["text:t0", "html:h0", "text:t1"])
        XCTAssertTrue(segs[1].content.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(segs[1].content.hasSuffix("</html>"))
        XCTAssertEqual(segs[2].content, " 尾巴\n再一行")
    }

    func testBodyStartDocumentEndsAtBodyClose() throws {
        let segs = try XCTUnwrap(MessageHTMLSegments.split("<body>\n<div>面板</div>\n</body>\n完"))
        XCTAssertEqual(kinds(segs), ["html:h0", "text:t0"])
        XCTAssertEqual(segs[0].content, "<body>\n<div>面板</div>\n</body>")
    }

    func testHelperMarkerInPlainFence() throws {
        // 酒馆助手 isFrontend：无语言 / text 围栏里带 <body / html> / <head> 就是前端
        let a = try XCTUnwrap(MessageHTMLSegments.split("```\n<body><div>x</div></body>\n```"))
        XCTAssertEqual(kinds(a), ["html:h0"])
        let b = try XCTUnwrap(MessageHTMLSegments.split("```text\n<!doctype html><html></html>\n```"))
        XCTAssertEqual(kinds(b), ["html:h0"])
    }

    func testMultipleSegmentsNumberedAndKeyed() throws {
        let text = "a\n```html\n<p>1</p>\n```\nb\n```html\n<p>2</p>\n```\nc"
        let segs = try XCTUnwrap(MessageHTMLSegments.split(text))
        XCTAssertEqual(kinds(segs), ["text:t0", "html:h0", "text:t1", "html:h1", "text:t2"])
        XCTAssertNotEqual(segs[1].key, segs[3].key)
        XCTAssertEqual(segs[1].key, MessageHTMLSegments.stableHash("<p>1</p>"))
        XCTAssertEqual(MessageHTMLSegments.stableHash("<p>1</p>"), MessageHTMLSegments.stableHash("<p>1</p>"))
    }

    func testCRLFLines() throws {
        let segs = try XCTUnwrap(MessageHTMLSegments.split("前\r\n```html\r\n<p>x</p>\r\n```\r\n后"))
        XCTAssertEqual(kinds(segs), ["text:t0", "html:h0", "text:t1"])
        XCTAssertEqual(segs[1].content, "<p>x</p>")
        XCTAssertEqual(segs[2].content, "后")
    }

    // MARK: - 不误认

    func testOrdinaryCodeBlocksAreNotHTML() {
        XCTAssertNil(MessageHTMLSegments.split("```python\nif a < b and b > c:\n    print('html')\n```"))
        XCTAssertNil(MessageHTMLSegments.split("```js\ndocument.body.innerHTML = '<body><p>x</p></body>';\n```"))
        XCTAssertNil(MessageHTMLSegments.split("```swift\nlet s = \"<html></html>\"\n```"))
    }

    func testComparisonsAndInlineMentionsAreNotHTML() {
        XCTAssertNil(MessageHTMLSegments.split("3 < 5 且 html 不是标签"))
        XCTAssertNil(MessageHTMLSegments.split("网页的 <body> 标签放正文，</body> 收尾。"))
        XCTAssertNil(MessageHTMLSegments.split("`<html>` 是根元素"))
        XCTAssertNil(MessageHTMLSegments.split("<bodyguard>保镖</bodyguard>"))
        XCTAssertNil(MessageHTMLSegments.split("<body> 这个词只是提一下，没有收尾"))
    }

    func testUnclosedStaysText() {
        XCTAssertNil(MessageHTMLSegments.split("前\n```html\n<div>写到一半"))
        XCTAssertNil(MessageHTMLSegments.split("<!doctype html>\n<html><body>写到一半"))
        XCTAssertNil(MessageHTMLSegments.split("```html\n\n```"))   // 空块不成段
    }

    func testHTMLInsideOtherFenceIsNotScannedAsDocument() {
        XCTAssertNil(MessageHTMLSegments.split("```xml\n<html>\n</html>\n```"))
    }

    // MARK: - 原生 Markdown 升格

    func testPromotionLeavesPlainAndFencedHTMLUntouched() {
        let plain = "普通消息 a < b"
        XCTAssertEqual(MessageHTMLSegments.markdownPromotingHTML(plain), plain)
        let fenced = "前\n```html\n<p>x</p>\n```\n后"
        XCTAssertEqual(MessageHTMLSegments.markdownPromotingHTML(fenced), fenced)
    }

    func testPromotionWrapsDocumentAndRelabelsHelperFence() {
        let doc = "前\n<html><body>`a` ``` b</body></html>\n后"
        let out = MessageHTMLSegments.markdownPromotingHTML(doc)
        XCTAssertEqual(out, "前\n````html\n<html><body>`a` ``` b</body></html>\n````\n\n后")
        let helper = "```\n<body>x</body>\n```"
        XCTAssertEqual(MessageHTMLSegments.markdownPromotingHTML(helper), "```html\n<body>x</body>\n```")
        // 升格后的文本再切段，得到同样的 HTML 内容
        XCTAssertEqual(MessageHTMLSegments.split(out)?.first(where: { $0.kind == .html })?.content,
                       "<html><body>`a` ``` b</body></html>")
    }
}

/// 卡库 ⑦：主桥守门 / 导航白名单 / 子文档 CSP / token 登记 / 权限 / 名额 / 调度器
@MainActor
final class HTMLEmbedTests: XCTestCase {
    private let doc = URL(fileURLWithPath: "/tmp/mp-test/ChatWeb/chat.html")

    func testBridgeGateRejectsSubframeAndForeignDocuments() {
        XCTAssertTrue(HTMLEmbedBridgeGate.acceptsHostMessage(isMainFrame: true, frameURL: doc, controlledDocument: doc))
        XCTAssertFalse(HTMLEmbedBridgeGate.acceptsHostMessage(isMainFrame: false, frameURL: doc, controlledDocument: doc))
        XCTAssertFalse(HTMLEmbedBridgeGate.acceptsHostMessage(isMainFrame: false, frameURL: URL(string: "mp-card://document/abc"),
                                                              controlledDocument: doc))
        XCTAssertFalse(HTMLEmbedBridgeGate.acceptsHostMessage(isMainFrame: true, frameURL: URL(string: "mp-card://document/abc"),
                                                              controlledDocument: doc))
        XCTAssertFalse(HTMLEmbedBridgeGate.acceptsHostMessage(isMainFrame: true, frameURL: URL(fileURLWithPath: "/tmp/other.html"),
                                                              controlledDocument: doc))
        XCTAssertFalse(HTMLEmbedBridgeGate.acceptsHostMessage(isMainFrame: true, frameURL: URL(string: "https://example.com/chat.html"),
                                                              controlledDocument: doc))
        XCTAssertFalse(HTMLEmbedBridgeGate.acceptsHostMessage(isMainFrame: true, frameURL: nil, controlledDocument: doc))
    }

    func testNavigationWhitelist() {
        let registered: (String) -> Bool = { $0 == "tok" }
        XCTAssertTrue(HTMLEmbedBridgeGate.allowsNavigation(to: doc, isMainFrame: true, controlledDocument: doc, isRegistered: registered))
        XCTAssertFalse(HTMLEmbedBridgeGate.allowsNavigation(to: URL(string: "https://evil.example"), isMainFrame: true,
                                                            controlledDocument: doc, isRegistered: registered))
        XCTAssertTrue(HTMLEmbedBridgeGate.allowsNavigation(to: URL(string: "mp-card://document/tok"), isMainFrame: false,
                                                           controlledDocument: doc, isRegistered: registered))
        XCTAssertFalse(HTMLEmbedBridgeGate.allowsNavigation(to: URL(string: "mp-card://document/other"), isMainFrame: false,
                                                            controlledDocument: doc, isRegistered: registered))
        XCTAssertFalse(HTMLEmbedBridgeGate.allowsNavigation(to: URL(string: "https://evil.example"), isMainFrame: false,
                                                            controlledDocument: doc, isRegistered: registered))
        XCTAssertFalse(HTMLEmbedBridgeGate.allowsNavigation(to: doc, isMainFrame: false, controlledDocument: doc, isRegistered: registered))
    }

    func testTokenParsingIsStrict() {
        XCTAssertEqual(HTMLEmbedSchemeHandler.token(from: URL(string: "mp-card://document/abc")), "abc")
        XCTAssertNil(HTMLEmbedSchemeHandler.token(from: URL(string: "mp-card://other/abc")))
        XCTAssertNil(HTMLEmbedSchemeHandler.token(from: URL(string: "mp-card://document/abc/x.png")))
        XCTAssertNil(HTMLEmbedSchemeHandler.token(from: URL(string: "mp-card://document/abc?x=1")))
        XCTAssertNil(HTMLEmbedSchemeHandler.token(from: URL(string: "mp-asset://document/abc")))
    }

    func testChildDocumentCSP() {
        let s = HTMLEmbedPolicy.contentSecurityPolicy(.staticView)
        let i = HTMLEmbedPolicy.contentSecurityPolicy(.interactive)
        for csp in [s, i] {
            for d in ["default-src 'none'", "connect-src 'none'", "form-action 'none'", "frame-src 'none'", "base-uri 'none'", "worker-src 'none'"] {
                XCTAssertTrue(csp.contains(d), "\(d) 缺失：\(csp)")
            }
            XCTAssertFalse(csp.contains("https:"))
            XCTAssertFalse(csp.contains("blob:"))
        }
        XCTAssertTrue(s.contains("script-src 'none'"))
        XCTAssertTrue(i.contains("script-src 'unsafe-inline';"))
    }

    func testDocumentInjectsCSPAfterDoctypeAndChannelOnlyWhenInteractive() {
        let st = HTMLEmbedPolicy.document(content: "<!doctype html><html><body>x</body></html>", mode: .staticView, token: "tok")
        XCTAssertTrue(st.hasPrefix("<!doctype html>\n<meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertFalse(st.contains("<script>"))
        let it = HTMLEmbedPolicy.document(content: "<p>x</p>", mode: .interactive, token: "tok")
        XCTAssertTrue(it.hasPrefix("<meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(it.contains("var T = \"tok\";"))
        XCTAssertTrue(it.hasSuffix("<p>x</p>"))
    }

    func testRegistryUnregisterRequiresMatchingIdentity() {
        let r = HTMLEmbedRegistry()
        let id = HTMLEmbedIdentity(profileId: "p", conversationId: "c", nodeId: "n1", segmentId: "h0")
        let t = r.register(id, content: "<p>x</p>", mode: .staticView)
        XCTAssertNil(r.unregister(t, nodeId: "n2", segmentId: "h0"))
        XCTAssertEqual(r.count, 1)
        XCTAssertNotNil(r.unregister(t, nodeId: "n1", segmentId: "h0"))
        XCTAssertEqual(r.count, 0)
    }

    func testRunPermission() {
        XCTAssertNil(HTMLEmbedPermission.runDenial(allowWebScripts: false, boundCard: nil))   // 非卡聊天不受总开关管
        XCTAssertNil(HTMLEmbedPermission.runDenial(allowWebScripts: true, boundCard: nil))
        var card = CharacterCard(name: "白石", description: "", personality: "", scenario: "", firstMes: "")
        card.linkedProfileId = "p"
        card.bindingState = .active
        XCTAssertNotNil(HTMLEmbedPermission.runDenial(allowWebScripts: true, boundCard: card))
        card.extensionConsent = .deferred
        XCTAssertNotNil(HTMLEmbedPermission.runDenial(allowWebScripts: true, boundCard: card))
        card.extensionConsent = .allowed
        XCTAssertNil(HTMLEmbedPermission.runDenial(allowWebScripts: true, boundCard: card))
        XCTAssertNotNil(HTMLEmbedPermission.runDenial(allowWebScripts: false, boundCard: card))
        XCTAssertEqual(HTMLEmbedPermission.boundCard(profileId: "p", cards: [card])?.name, "白石")
        XCTAssertNil(HTMLEmbedPermission.boundCard(profileId: "q", cards: [card]))
        card.bindingState = .missing
        XCTAssertNil(HTMLEmbedPermission.boundCard(profileId: "p", cards: [card]))
    }

    func testStaticSlotsLimit() {
        let slots = HTMLCardStaticSlots(limit: 2)
        XCTAssertTrue(slots.acquire("a"))
        XCTAssertTrue(slots.acquire("b"))
        XCTAssertFalse(slots.acquire("c"))
        XCTAssertTrue(slots.acquire("a"))
        slots.release("a")
        XCTAssertTrue(slots.acquire("c"))
    }

    func testMessageParsing() {
        XCTAssertEqual(HTMLEmbedMessage(body: ["type": "htmlMount", "nodeId": "n", "segmentId": "h0"]), .mount(nodeId: "n", segmentId: "h0"))
        XCTAssertNil(HTMLEmbedMessage(body: ["type": "htmlChild", "nodeId": "n", "segmentId": "h0", "token": "t", "kind": "generate"]))
        XCTAssertNil(HTMLEmbedMessage(body: ["type": "htmlMount", "nodeId": String(repeating: "x", count: 200), "segmentId": "h0"]))
        XCTAssertNil(HTMLEmbedMessage(body: ["type": "send", "nodeId": "n", "segmentId": "h0"]))
    }

    // MARK: - 调度器

    private final class Probe {
        var js: [String] = []
        var active: String?
        var opened: [URL] = []
    }

    private func makeHost(_ probe: Probe, denial: String? = nil) -> HTMLEmbedHost {
        let host = HTMLEmbedHost()
        host.eval = { probe.js.append($0) }
        host.activeKey = { probe.active }
        host.setActiveKey = { probe.active = $0 }
        host.confirmOpenLink = { probe.opened.append($0) }
        host.runDenial = denial
        host.replaceSources([(HTMLEmbedIdentity(profileId: "p", conversationId: "c", nodeId: "n1", segmentId: "h0"), "<p>面板</p>")])
        return host
    }

    func testHostMountRunStopAndSweep() throws {
        let probe = Probe()
        let host = makeHost(probe)
        host.handle(.mount(nodeId: "n1", segmentId: "h0"))
        XCTAssertEqual(host.registry.count, 1)
        XCTAssertTrue(probe.js.last?.contains("\"mode\":\"static\"") == true)
        host.handle(.mount(nodeId: "nX", segmentId: "h0"))            // 不在当前窗口的段不发 token
        XCTAssertEqual(host.registry.count, 1)

        host.handle(.run(nodeId: "n1", segmentId: "h0"))
        let running = try XCTUnwrap(host.interactive)
        XCTAssertEqual(probe.active, running.key)
        XCTAssertEqual(host.registry.count, 1)                        // 静态 token 作废，只剩交互 token
        XCTAssertEqual(host.registry.entry(running.token)?.mode, .interactive)

        host.activeKeyChanged("native-card")                          // 别处开了新的：这边收掉
        XCTAssertNil(host.interactive)
        XCTAssertEqual(host.registry.count, 0)
        XCTAssertTrue(probe.js.last?.contains("htmlDetach") == true)

        host.handle(.mount(nodeId: "n1", segmentId: "h0"))
        host.replaceSources([])                                       // 切对话 / 切分支：段没了 → token 注销
        XCTAssertEqual(host.registry.count, 0)
    }

    func testHostRunDeniedAndRevoked() {
        let probe = Probe()
        let host = makeHost(probe, denial: "网页脚本没开")
        host.handle(.run(nodeId: "n1", segmentId: "h0"))
        XCTAssertNil(host.interactive)
        XCTAssertEqual(host.registry.count, 0)
        XCTAssertTrue(probe.js.last?.contains("htmlNotice") == true)

        host.runDenial = nil
        host.handle(.run(nodeId: "n1", segmentId: "h0"))
        XCTAssertNotNil(host.interactive)
        host.runDenial = "撤了卡许可"                                  // 撤权：当场销毁
        XCTAssertNil(host.interactive)
        XCTAssertNil(probe.active)
        XCTAssertEqual(host.registry.count, 0)
    }

    func testHostChildMessagesAreNarrow() throws {
        let probe = Probe()
        let host = makeHost(probe)
        host.handle(.run(nodeId: "n1", segmentId: "h0"))
        let token = try XCTUnwrap(host.interactive?.token)
        host.handle(.child(token: "forged", nodeId: "n1", segmentId: "h0", kind: "openLink", text: "https://a.example"))
        host.handle(.child(token: token, nodeId: "n2", segmentId: "h0", kind: "openLink", text: "https://a.example"))
        host.handle(.child(token: token, nodeId: "n1", segmentId: "h0", kind: "openLink", text: "javascript:alert(1)"))
        XCTAssertTrue(probe.opened.isEmpty)
        host.handle(.child(token: token, nodeId: "n1", segmentId: "h0", kind: "openLink", text: "https://a.example/x"))
        XCTAssertEqual(probe.opened.map(\.absoluteString), ["https://a.example/x"])

        host.suspend()                                                // 后台：全部注销
        XCTAssertEqual(host.registry.count, 0)
        XCTAssertNil(host.interactive)
        XCTAssertTrue(probe.js.last?.contains("htmlSuspend") == true)
    }
}
