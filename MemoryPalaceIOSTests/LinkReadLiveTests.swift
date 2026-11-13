import XCTest
@testable import 记忆花园

/// 11-09 iOS 真机 live（链接直读 #00683 把网页正文当文字附件发给模型 = 请求内容变了，10-17 规矩的 😷 真跑）：
/// 测试进程里放一页虚构网页 → 真的 LinkRead.read（离屏 WKWebView 抽正文）→ 文字附件 → anthropic-official Haiku 真发，
/// 看请求里附件在、模型答得出只有这页才有的事实、outcome=normal。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里经 CatalogLiveAuthProtocol 换进请求头；日志不打正文以外的东西。
@MainActor
final class LinkReadLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialId: String?
    private var page: ScriptedHTTPServer?

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>雾湾灯塔志</title></head><body><article>
    <h1>雾湾灯塔志</h1>
    <p>雾湾灯塔建在一块没有名字的礁石上，灯室朝北，透镜是三层叠起来的旧玻璃。每年第一场雾落下来的那天，守护人要把灯芯换成新的。</p>
    <p>灯塔的第七任守护人叫贝洛·栖川。他在任的那些年里，用海藻压成的纸一共记下了三百一十四次潮汐，每一页的右下角都画着一只没有尾巴的海鸥。</p>
    <p>栖川离开以后，那些海藻纸被收进灯塔底层的铁皮箱。箱子的锁是一把黄铜锁，钥匙据说被他丢进了港口里，至今没人找到。</p>
    <p>后来的守护人只在雾特别重的夜里打开灯，其余时候灯室是暗的。路过的渔船把这当成一种约定：灯亮了，就别出港。</p>
    </article></body></html>
    """

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "LinkReadLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = "api.anthropic.com"
        try CatalogLiveAuthProtocol.install()
        let server = try ScriptedHTTPServer(respond: { _, _ in (200, "text/html; charset=utf-8", Data(Self.html.utf8)) })
        try server.start()
        page = server
    }

    override func tearDown() async throws {
        if let credentialId { manager?.removeCredential(id: credentialId) }
        manager = nil
        credentialId = nil
        page?.stop()
        page = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
    }

    func testLiveHaikuAnswersFromReadLinkOnDevice() async throws {
        let base = try XCTUnwrap(page?.baseURL)
        let url = try XCTUnwrap(URL(string: base.replacingOccurrences(of: "/v1", with: "/lighthouse")))

        let result = try await LinkRead.read(url)
        print("[LINKREAD-LIVE-IOS] read: source=\(result.source.rawValue) title=\(result.title) chars=\(result.body.count)")
        XCTAssertTrue(result.body.contains("贝洛·栖川"), "正文要读到虚构的守护人名字")

        let question = "这页里灯塔的第七任守护人叫什么？只回答名字。 \(url.absoluteString)"
        let modelInput = ChatAttachmentPromptBuilder.modelInput(text: question, attachments: LinkRead.attachments(for: result))
        XCTAssertTrue(modelInput.contains("[附件：已读取：雾湾灯塔志 · 网页]"))
        XCTAssertTrue(modelInput.contains("三百一十四次潮汐"))

        let manager = ProviderManager()
        self.manager = manager
        let id = "xctest-linkread-live-ios-\(UUID().uuidString)"
        credentialId = id
        let model = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        manager.addCredential(APICredential(
            id: id, name: "LinkRead Live iOS", emoji: "", type: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            extraHeaders: ["anthropic-version": "2023-06-01"],
            models: [model], toolsSupported: false))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("linkread-live-ios-\(UUID().uuidString).jsonl"))
        var content = ""
        var failure: String?
        let done = expectation(description: "chat")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: modelInput)],
            systemPrompt: nil,
            providerManager: manager,
            samplingParams: SamplingParams(),
            onToken: { _ in },
            onComplete: { text, _ in content = text; done.fulfill() },
            onError: { message in failure = message; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 120)
        print("[LINKREAD-LIVE-IOS] chat: chars=\(content.count) outcome=\(router.lastReplyOutcome.rawValue) answer=\(content.prefix(40))")
        if let failure { XCTFail("真发失败：\(CatalogLiveAuthProtocol.redacted(failure))") }
        XCTAssertTrue(content.contains("栖川"), "模型要从附件里答出虚构名字")
        XCTAssertEqual(router.lastReplyOutcome, .normal)
    }
}

/// 不要 key 的那半：测试宿主里离屏 WKWebView 能不能把本地虚构页读成正文（模拟器上就能跑，省一趟 😷）
@MainActor
final class LinkReadPageTests: XCTestCase {
    func testReadsLocalFictionalPage() async throws {
        let server = try ScriptedHTTPServer(respond: { _, _ in (200, "text/html; charset=utf-8", Data(LinkReadLiveTests.html.utf8)) })
        try server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: server.baseURL.replacingOccurrences(of: "/v1", with: "/lighthouse")))
        let result = try await LinkRead.read(url)
        XCTAssertEqual(result.title, "雾湾灯塔志")
        XCTAssertTrue(result.body.contains("贝洛·栖川"))
        XCTAssertTrue(ChatAttachmentPromptBuilder.modelInput(text: "q", attachments: LinkRead.attachments(for: result))
            .contains("[附件：已读取：雾湾灯塔志 · 网页]"))
    }
}
