import XCTest
#if os(macOS)
import Network
#endif
@testable import 记忆花园

/// OpenRouter 登录的归属与生命周期：换家 / 取消后回来的结果不写 key、不动新一轮；本机监听分片 + 无关请求不结束登录。
/// 换 key 走延迟 URLProtocol 桩，不发真网络请求；本机监听只连回环
@MainActor
final class OpenRouterLoginRunnerTests: XCTestCase {

    /// 延迟回包的桩：stopLoading（任务取消）后不再回
    private final class SlowStub: URLProtocol {
        nonisolated(unsafe) static var body = #"{"key":"sk-or-v1-late"}"#
        nonisolated(unsafe) static var delay: TimeInterval = 0.3
        private var pending: DispatchWorkItem?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let item = DispatchWorkItem { [weak self] in
                guard let self, let client = self.client else { return }
                let resp = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: Data(SlowStub.body.utf8))
                client.urlProtocolDidFinishLoading(self)
            }
            pending = item
            DispatchQueue.global().asyncAfter(deadline: .now() + SlowStub.delay, execute: item)
        }
        override func stopLoading() { pending?.cancel() }
    }

    /// 测试里的「页面」：当前提供商 + 输入框里的 key
    private final class Page {
        var providerKey = "openrouter/openrouter/openaiCompatible"
        var apiKey = ""
    }

    private var slow: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        SlowStub.body = #"{"key":"sk-or-v1-late"}"#
        SlowStub.delay = 0.3
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SlowStub.self]
        slow = URLSession(configuration: cfg)
    }

    private func slowExchange(_ code: String, _ verifier: String) async throws -> String {
        try await OpenRouterLogin.exchange(code: code, verifier: verifier, session: slow)
    }

    /// 不理会取消、过一会儿照样交出结果的老任务（最坏情况）
    private func stubbornKey(_ key: String) async -> String {
        await withCheckedContinuation { c in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { c.resume() }
        }
        return key
    }

    // MARK: 1. 登录中换了家

    func testProviderSwitchedMidLoginKeepsUserKey() async {
        let page = Page()
        let runner = OpenRouterLoginRunner()
        runner.start(providerKey: page.providerKey, context: { page.providerKey },
                     work: { try await self.slowExchange("c", "v") },
                     apply: { page.apiKey = $0 })
        let task = runner.task
        XCTAssertTrue(runner.isWaiting)
        // 切到别家并填好它的 key；这里故意不调 providerChanged，只靠回填前的核对兜
        page.providerKey = "deepseek/deepseek/openaiCompatible"
        page.apiKey = "sk-deepseek-own"
        await task?.value
        XCTAssertEqual(page.apiKey, "sk-deepseek-own", "OpenRouter 的 key 不能写到别家的卡上")
        XCTAssertFalse(runner.isWaiting)
        XCTAssertNil(runner.errorText)
    }

    func testProviderChangedCancelsLogin() async {
        let page = Page()
        let runner = OpenRouterLoginRunner()
        runner.start(providerKey: page.providerKey, context: { page.providerKey },
                     work: { await self.stubbornKey("sk-or-v1-old") },
                     apply: { page.apiKey = $0 })
        let task = runner.task
        runner.providerChanged(to: page.providerKey)
        XCTAssertTrue(runner.isWaiting, "同一家不作废")
        page.providerKey = "custom/openaiCompatible"
        runner.providerChanged(to: page.providerKey)
        XCTAssertFalse(runner.isWaiting)
        XCTAssertNil(runner.task)
        // 换回 OpenRouter，老结果回来也不认
        page.providerKey = "openrouter/openrouter/openaiCompatible"
        await task?.value
        XCTAssertEqual(page.apiKey, "")
    }

    func testCancelledAutoLoginNotAppliedAndNewOneUntouched() async {
        let page = Page()
        let runner = OpenRouterLoginRunner()
        runner.start(providerKey: page.providerKey, context: { page.providerKey },
                     work: { await self.stubbornKey("sk-or-v1-old") },
                     apply: { page.apiKey = $0 })
        let old = runner.task
        runner.cancel()   // 关页 / 点取消
        runner.start(providerKey: page.providerKey, context: { page.providerKey },
                     work: { try await Task.sleep(nanoseconds: 5_000_000_000); return "sk-or-v1-new" },
                     apply: { page.apiKey = $0 })
        await old?.value
        XCTAssertEqual(page.apiKey, "")
        XCTAssertTrue(runner.isWaiting, "老结果不能把新一轮的状态清掉")
        runner.cancel()
    }

    func testAutoLoginSuccessApplies() async {
        let page = Page()
        let runner = OpenRouterLoginRunner()
        runner.start(providerKey: page.providerKey, context: { page.providerKey },
                     work: { try await self.slowExchange("c", "v") },
                     apply: { page.apiKey = $0 })
        await runner.task?.value
        XCTAssertEqual(page.apiKey, "sk-or-v1-late")
        XCTAssertFalse(runner.isWaiting)
        XCTAssertNil(runner.task)
    }

    func testAutoLoginUserCancelIsSilent() async {
        let runner = OpenRouterLoginRunner()
        runner.start(providerKey: "k", context: { "k" },
                     work: { throw OpenRouterLogin.LoginError.cancelled },
                     apply: { _ in XCTFail() })
        await runner.task?.value
        XCTAssertNil(runner.errorText)
        XCTAssertFalse(runner.isWaiting)
    }

    // MARK: 2. 粘授权码：换 key 归这一轮

    func testManualCancelDuringExchangeDropsResult() async {
        let page = Page()
        let runner = OpenRouterLoginRunner()
        let first = runner.beginManual(providerKey: page.providerKey)
        runner.finishManual(pasted: "code-1", context: { page.providerKey },
                            exchange: { try await self.slowExchange($0, $1) },
                            apply: { page.apiKey = $0 })
        let task = runner.task
        XCTAssertTrue(runner.isExchanging)
        runner.cancel()
        XCTAssertNil(runner.manualAttempt)
        XCTAssertFalse(runner.isExchanging)
        let second = runner.beginManual(providerKey: page.providerKey)
        XCTAssertNotEqual(first, second)
        await task?.value
        try? await Task.sleep(nanoseconds: 400_000_000)   // 桩的回包时间过了也不能落进来
        XCTAssertEqual(page.apiKey, "")
        XCTAssertEqual(runner.manualAttempt, second, "旧请求不能把新一轮清成 nil")
        XCTAssertFalse(runner.isExchanging)
    }

    func testManualStaleExchangeIgnoredEvenIfNotCancellable() async {
        let page = Page()
        let runner = OpenRouterLoginRunner()
        runner.beginManual(providerKey: page.providerKey)
        runner.finishManual(pasted: "code-1", context: { page.providerKey },
                            exchange: { _, _ in await self.stubbornKey("sk-or-v1-old") },
                            apply: { page.apiKey = $0 })
        let task = runner.task
        runner.cancel()
        let second = runner.beginManual(providerKey: page.providerKey)
        runner.finishManual(pasted: "code-2", context: { page.providerKey },
                            exchange: { _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return "sk-or-v1-new" },
                            apply: { page.apiKey = $0 })
        await task?.value
        XCTAssertEqual(page.apiKey, "")
        XCTAssertEqual(runner.manualAttempt, second)
        XCTAssertTrue(runner.isExchanging, "新一轮还在换，老结果不能改它的状态")
        runner.cancel()
    }

    func testManualProviderSwitchedDuringExchange() async {
        let page = Page()
        let runner = OpenRouterLoginRunner()
        runner.beginManual(providerKey: page.providerKey)
        runner.finishManual(pasted: "code-1", context: { page.providerKey },
                            exchange: { try await self.slowExchange($0, $1) },
                            apply: { page.apiKey = $0 })
        let task = runner.task
        page.providerKey = "deepseek/deepseek/openaiCompatible"
        page.apiKey = "sk-deepseek-own"
        await task?.value
        XCTAssertEqual(page.apiKey, "sk-deepseek-own")
        XCTAssertNil(runner.manualAttempt)
    }

    func testManualSuccessAndRetryAfterError() async {
        let page = Page()
        let runner = OpenRouterLoginRunner()
        let attempt = runner.beginManual(providerKey: page.providerKey)
        var seenVerifier: String?
        runner.finishManual(pasted: "  ", context: { page.providerKey },
                            exchange: { _, _ in XCTFail("空授权码不该去换"); return "" },
                            apply: { page.apiKey = $0 })
        await runner.task?.value
        XCTAssertEqual(runner.errorText, OpenRouterLogin.LoginError.missingCode.errorDescription)
        XCTAssertEqual(runner.manualAttempt, attempt, "出错留着这一轮，改了再点")

        runner.finishManual(pasted: "code-ok", context: { page.providerKey },
                            exchange: { code, verifier in
                                seenVerifier = verifier
                                return try await self.slowExchange(code, verifier)
                            },
                            apply: { page.apiKey = $0 })
        XCTAssertNil(runner.errorText)
        await runner.task?.value
        XCTAssertEqual(page.apiKey, "sk-or-v1-late")
        XCTAssertEqual(seenVerifier, attempt.verifier)
        XCTAssertNil(runner.manualAttempt)
        XCTAssertFalse(runner.isExchanging)
    }

    // MARK: 3/4/5. 本机监听：取消立即收、无关请求不结束登录、分片累积

    #if os(macOS)
    private func send(_ port: UInt16, _ chunks: [String], close: Bool = false) async throws -> String {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn.start(queue: .global())
        defer { conn.cancel() }
        for chunk in chunks {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                conn.send(content: Data(chunk.utf8), completion: .contentProcessed { _ in k.resume() })
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        if close { return "" }
        return await withCheckedContinuation { k in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                k.resume(returning: data.map { String(decoding: $0, as: UTF8.self) } ?? "")
            }
        }
    }

    func testLocalServerIgnoresJunkAndAccumulatesFragments() async throws {
        let server = try OpenRouterLocalCallback()
        let port = try await server.start()
        server.expect(callback: OpenRouterLogin.localhostCallback(port: port), state: "s1")
        async let code = server.waitForCode(timeoutSeconds: 15)

        for junk in ["GET /callback-not-real?code=x&state=s1 HTTP/1.1\r\n\r\n",
                     "GET /callback?code=x&state=evil HTTP/1.1\r\n\r\n",
                     "GET /callback?code=x&state= HTTP/1.1\r\n\r\n",
                     "GET /callback?state=s1 HTTP/1.1\r\n\r\n",
                     "POST /callback?code=x&state=s1 HTTP/1.1\r\n\r\n"] {
            let resp = try await send(port, [junk])
            XCTAssertTrue(resp.hasPrefix("HTTP/1.1 404"), junk)
        }
        // 半截请求就断开：只结束那条连接
        _ = try await send(port, ["GET /callback?code=trunc"], close: true)
        // 分片到达：请求行拼完整才判，不会把截断的 code 交出去
        let ok = try await send(port, ["GET /call", "back?code=real-", "code&st", "ate=s1 HTTP/1.1\r", "\nHost: localhost\r\n\r\n"])
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
        let got = try await code
        XCTAssertEqual(got, "real-code")
    }

    func testLocalServerCancelEndsWaitImmediately() async throws {
        let server = try OpenRouterLocalCallback()
        let port = try await server.start()
        server.expect(callback: OpenRouterLogin.localhostCallback(port: port), state: "s1")
        let waiter = Task { try await server.waitForCode(timeoutSeconds: 60) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let began = Date()
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("取消后不该拿到结果")
        } catch {
            XCTAssertEqual(error as? OpenRouterLogin.LoginError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
    }
    #endif
}
