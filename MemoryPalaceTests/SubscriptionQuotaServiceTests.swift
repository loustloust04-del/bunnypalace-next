#if os(macOS)
import XCTest
@testable import 记忆花园

/// 订阅额度（research-magpie §2.2）：解析走 fixture JSON；服务的传输 / 凭据 / 钟全注入，绝不碰她的 Keychain 与网络
final class SubscriptionQuotaServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: fixture

    private static let claudeUsage = """
    {"five_hour":{"utilization":42.0,"resets_at":"2026-09-21T15:00:00.123456+00:00"},
     "seven_day":{"utilization":18,"resets_at":"2026-09-25T08:00:00+00:00"},
     "seven_day_opus":null,
     "seven_day_sonnet":{"utilization":3.5,"resets_at":null},
     "extra_usage":{"is_enabled":false}}
    """

    /// 本机 09-24 实拍形状（secondary 为 null、值改过）
    private static let codexUsage = """
    {"plan_type":"prolite","rate_limit":{"allowed":true,"limit_reached":false,
     "primary_window":{"used_percent":27,"limit_window_seconds":604800,"reset_after_seconds":581899,"reset_at":1790849296},
     "secondary_window":null},"credits":{"has_credits":false}}
    """

    private static let codexUsageTwoWindows = """
    {"plan_type":"plus","rate_limit":{
     "primary_window":{"used_percent":61.4,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":0},
     "secondary_window":{"used_percent":9,"limit_window_seconds":604800,"reset_at":1790500000}}}
    """

    private func claudeCredentialJSON(expiresMs: Double, token: String = "sk-ant-oat-test") -> Data {
        Data("""
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"rt-never-touch","expiresAt":\(Int64(expiresMs)),
         "scopes":["user:inference"],"subscriptionType":"max"},"mcpOAuth":{}}
        """.utf8)
    }

    private func jwt(_ claims: [String: Any]) -> String {
        let body = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJub25lIn0.\(body).sig"
    }

    private func codexAuthJSON(exp: TimeInterval, accountInIdToken: Bool = false) -> Data {
        let access = jwt(["exp": exp])
        let id = jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-from-id"]])
        let account = accountInIdToken ? "" : "acct-123"
        return Data("""
        {"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"\(id)","access_token":"\(access)",
         "refresh_token":"rt-never-touch","account_id":"\(account)"},"last_refresh":"2026-09-20T00:00:00Z"}
        """.utf8)
    }

    // MARK: 纯函数

    func testClaudeUsageParsesAllPresentWindows() throws {
        let windows = try SubscriptionQuotaParser.claudeWindows(Data(Self.claudeUsage.utf8))
        XCTAssertEqual(windows.map(\.label), ["5 小时", "7 天", "7 天 · Sonnet"])
        XCTAssertEqual(windows.map(\.usedPercent), [42, 18, 3.5])
        XCTAssertEqual(windows[0].resetsAt?.timeIntervalSince1970 ?? 0, 1_790_002_800.123, accuracy: 0.01)
        XCTAssertEqual(windows[1].resetsAt, Date(timeIntervalSince1970: 1_790_323_200))
        XCTAssertNil(windows[2].resetsAt)
        XCTAssertThrowsError(try SubscriptionQuotaParser.claudeWindows(Data("<html>".utf8)))
    }

    func testCodexUsageParsesWindowsAndNullSecondary() throws {
        let one = try SubscriptionQuotaParser.codexUsage(Data(Self.codexUsage.utf8), now: now)
        XCTAssertEqual(one.plan, "prolite")
        XCTAssertEqual(one.windows, [QuotaWindow(label: "7 天", usedPercent: 27, resetsAt: Date(timeIntervalSince1970: 1_790_849_296))])

        let two = try SubscriptionQuotaParser.codexUsage(Data(Self.codexUsageTwoWindows.utf8), now: now)
        XCTAssertEqual(two.windows.map(\.label), ["5 小时", "7 天"])
        XCTAssertEqual(two.windows[0].usedPercent, 61.4, accuracy: 0.001)
        // reset_at 为 0 时退回 reset_after_seconds
        XCTAssertEqual(two.windows[0].resetsAt, now.addingTimeInterval(3600))
    }

    func testClaudeCredentialReadsTokenExpiryAndPlan() {
        let c = SubscriptionQuotaParser.claudeCredential(claudeCredentialJSON(expiresMs: 1_790_000_600_000))
        XCTAssertEqual(c?.accessToken, "sk-ant-oat-test")
        XCTAssertEqual(c?.plan, "max")
        XCTAssertEqual(c?.expiresAt, Date(timeIntervalSince1970: 1_790_000_600))
        XCTAssertEqual(c?.isExpired(now: now), false)
        XCTAssertEqual(c?.isExpired(now: now.addingTimeInterval(600)), true)
        // 秒级 expiresAt 也认
        XCTAssertEqual(SubscriptionQuotaParser.claudeCredential(claudeCredentialJSON(expiresMs: 1_790_000_600))?.expiresAt,
                       Date(timeIntervalSince1970: 1_790_000_600))
        // 只有 MCP OAuth、没有 claudeAiOauth 的项 = 没登录
        XCTAssertNil(SubscriptionQuotaParser.claudeCredential(Data(#"{"mcpOAuth":{}}"#.utf8)))
    }

    func testCodexCredentialReadsJWTExpiryAndAccountFallback() {
        let c = SubscriptionQuotaParser.codexCredential(codexAuthJSON(exp: 1_790_003_600))
        XCTAssertEqual(c?.accountId, "acct-123")
        XCTAssertEqual(c?.expiresAt, Date(timeIntervalSince1970: 1_790_003_600))
        XCTAssertEqual(SubscriptionQuotaParser.codexCredential(codexAuthJSON(exp: 1_790_003_600, accountInIdToken: true))?.accountId,
                       "acct-from-id")
        // API key 模式不是订阅登录
        XCTAssertNil(SubscriptionQuotaParser.codexCredential(Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x"}"#.utf8)))
    }

    func testClaudeKeychainServiceNameFollowsConfigDir() {
        XCTAssertEqual(SubscriptionQuotaParser.claudeKeychainService(root: "/Users/x/.claude", isDefaultRoot: true), "Claude Code-credentials")
        // sha256("/Users/susu/.claude-b") 前 8 位——本机 Keychain 实测存在这个服务名
        XCTAssertEqual(SubscriptionQuotaParser.claudeKeychainService(root: "/Users/susu/.claude-b", isDefaultRoot: false),
                       "Claude Code-credentials-ddaba61f")
    }

    func testResetText() {
        XCTAssertEqual(SubscriptionQuotaParser.resetText(now.addingTimeInterval(3 * 3600 + 100), now: now), "3 小时后重置")
        XCTAssertEqual(SubscriptionQuotaParser.resetText(now.addingTimeInterval(25 * 60), now: now), "25 分钟后重置")
        XCTAssertEqual(SubscriptionQuotaParser.resetText(now.addingTimeInterval(5 * 86_400), now: now), "5 天后重置")
        XCTAssertEqual(SubscriptionQuotaParser.resetText(now.addingTimeInterval(10), now: now), "即将重置")
        XCTAssertNil(SubscriptionQuotaParser.resetText(nil, now: now))
    }

    func testSourcesFollowCodingLocationsIncludingCustomRoots() throws {
        let home = URL(fileURLWithPath: "/tmp/mp-quota-home-\(UUID().uuidString)")
        let custom = home.appendingPathComponent(".claude-b")
        try FileManager.default.createDirectory(at: custom.appendingPathComponent("projects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let overrides = CodingLocationOverrides(customRoots: [CodingLocationEntry(agent: CodingAgent.claudeCode.rawValue, path: custom.path)])
        let roster = CodingSessionRoster.configured(home: home, environment: [:], overrides: overrides)
        let sources = SubscriptionQuotaService.sources(adapters: roster.active, home: home)
        XCTAssertEqual(sources.map(\.provider), [.claude, .claude, .codex])
        XCTAssertEqual(sources.map(\.root.lastPathComponent), [".claude", ".claude-b", ".codex"])
        XCTAssertEqual(sources.map(\.isDefaultRoot), [true, false, true])

        // 她移除了 Claude 默认位置：默认根不再出现
        let removed = CodingSessionRoster.configured(home: home, environment: [:],
                                                     overrides: CodingLocationOverrides(removedDefaults: [.claudeCode]))
        XCTAssertEqual(SubscriptionQuotaService.sources(adapters: removed.active, home: home).map(\.provider), [.codex])
    }

    // MARK: 服务

    /// 记录请求、按 URL 回话的假传输
    private final class FakeTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { _requests } }
        var handler: @Sendable (URLRequest) async throws -> SubscriptionQuotaService.Response

        init(handler: @escaping @Sendable (URLRequest) async throws -> SubscriptionQuotaService.Response) {
            self.handler = handler
        }

        func send(_ request: URLRequest) async throws -> SubscriptionQuotaService.Response {
            lock.withLock { _requests.append(request) }
            return try await handler(request)
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var date: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private let claudeRoot = URL(fileURLWithPath: "/fake/.claude", isDirectory: true)
    private let codexRoot = URL(fileURLWithPath: "/fake/.codex", isDirectory: true)

    private func makeService(transport: FakeTransport, clock: Clock, files: [String: Data],
                             keychain: [String: Data] = [:], timeout: TimeInterval = 10) -> SubscriptionQuotaService {
        let claude = claudeRoot, codex = codexRoot
        return SubscriptionQuotaService(
            sources: { [.init(provider: .claude, root: claude, isDefaultRoot: true), .init(provider: .codex, root: codex, isDefaultRoot: true)] },
            transport: { try await transport.send($0) },
            readFile: { files[$0.path] },
            readKeychain: { keychain[$0] },
            now: { clock.date },
            timeout: timeout)
    }

    private func ok(_ body: String) -> SubscriptionQuotaService.Response { .init(status: 200, data: Data(body.utf8)) }

    func testFetchesBothProvidersWithMagpieRequestShapeAndOnlyGET() async {
        let transport = FakeTransport { request in
            request.url == SubscriptionQuotaService.claudeUsageURL
                ? .init(status: 200, data: Data(Self.claudeUsage.utf8)) : .init(status: 200, data: Data(Self.codexUsage.utf8))
        }
        let clock = Clock(now)
        let service = makeService(transport: transport, clock: clock, files: [
            codexRoot.appendingPathComponent("auth.json").path: codexAuthJSON(exp: now.timeIntervalSince1970 + 3600),
        ], keychain: ["Claude Code-credentials": claudeCredentialJSON(expiresMs: (now.timeIntervalSince1970 + 3600) * 1000)])

        let quotas = await service.quotas()
        XCTAssertEqual(quotas.map(\.provider), [.claude, .codex])
        XCTAssertEqual(quotas.map(\.status), [.ok, .ok])
        XCTAssertEqual(quotas[0].plan, "max")
        XCTAssertEqual(quotas[0].primaryWindows.map(\.usedPercent), [42, 18])
        XCTAssertEqual(quotas[1].plan, "prolite")

        let requests = transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil }, "只许读，不许写 / 刷新")
        let claude = requests.first { $0.url == SubscriptionQuotaService.claudeUsageURL }
        XCTAssertEqual(claude?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat-test")
        XCTAssertEqual(claude?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        let codex = requests.first { $0.url == SubscriptionQuotaService.codexUsageURL }
        XCTAssertEqual(codex?.value(forHTTPHeaderField: "chatgpt-account-id"), "acct-123")
    }

    func testCredentialsFileBeatsKeychain() async {
        let transport = FakeTransport { _ in .init(status: 200, data: Data(Self.claudeUsage.utf8)) }
        let expiry = (now.timeIntervalSince1970 + 3600) * 1000
        let service = makeService(transport: transport, clock: Clock(now), files: [
            claudeRoot.appendingPathComponent(".credentials.json").path: claudeCredentialJSON(expiresMs: expiry, token: "from-file"),
        ], keychain: ["Claude Code-credentials": claudeCredentialJSON(expiresMs: expiry, token: "from-keychain")])
        _ = await service.quotas()
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer from-file")
    }

    func testExpiredTokenAsksForCLIRunAndNeverCallsNetwork() async {
        let transport = FakeTransport { _ in XCTFail("过期不该发请求（更不该去刷新）"); return .init(status: 500, data: Data()) }
        let service = makeService(transport: transport, clock: Clock(now), files: [
            codexRoot.appendingPathComponent("auth.json").path: codexAuthJSON(exp: now.timeIntervalSince1970 - 10),
        ], keychain: ["Claude Code-credentials": claudeCredentialJSON(expiresMs: (now.timeIntervalSince1970 - 60) * 1000)])
        let quotas = await service.quotas()
        XCTAssertEqual(quotas.map(\.status), [.needsLogin, .needsLogin])
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(quotas[0].statusText, "登录已过期——在终端跑一次 claude 就会续上")
        XCTAssertEqual(quotas[1].statusText, "登录已过期——在终端跑一次 codex 就会续上")
    }

    func testSignedOutProviderIsOmittedAnd401MeansLogin() async {
        let transport = FakeTransport { _ in .init(status: 401, data: Data()) }
        // Claude 没凭据（不出行）；Codex 服务端 401 → 需要重新登录
        let service = makeService(transport: transport, clock: Clock(now), files: [
            codexRoot.appendingPathComponent("auth.json").path: codexAuthJSON(exp: now.timeIntervalSince1970 + 3600),
        ])
        let quotas = await service.quotas()
        XCTAssertEqual(quotas.map(\.provider), [.codex])
        XCTAssertEqual(quotas.first?.status, .needsLogin)
    }

    func testOneProviderFailingOrHangingDoesNotBlockTheOther() async {
        let transport = FakeTransport { request in
            if request.url == SubscriptionQuotaService.claudeUsageURL {
                try await Task.sleep(nanoseconds: 5_000_000_000)   // 挂住
            }
            return .init(status: 200, data: Data(Self.codexUsage.utf8))
        }
        let service = makeService(transport: transport, clock: Clock(now), files: [
            codexRoot.appendingPathComponent("auth.json").path: codexAuthJSON(exp: now.timeIntervalSince1970 + 3600),
        ], keychain: ["Claude Code-credentials": claudeCredentialJSON(expiresMs: (now.timeIntervalSince1970 + 3600) * 1000)],
                                  timeout: 0.3)
        let started = Date()
        let quotas = await service.quotas()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "总超时没兜住")
        XCTAssertEqual(quotas.map(\.provider), [.claude, .codex])
        XCTAssertEqual(quotas[0].status, .failed("请求超时"))
        XCTAssertEqual(quotas[1].status, .ok)
        XCTAssertEqual(quotas[1].windows.first?.usedPercent, 27)
    }

    func testCacheServesFreshThenStaleWhileRefreshingInBackground() async {
        let calls = Counter()
        let transport = FakeTransport { _ in
            let n = calls.increment()
            return .init(status: 200, data: Data("""
            {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":\(n * 10),"limit_window_seconds":18000,"reset_at":1790500000}}}
            """.utf8))
        }
        let clock = Clock(now)
        let service = makeService(transport: transport, clock: clock, files: [
            codexRoot.appendingPathComponent("auth.json").path: codexAuthJSON(exp: now.timeIntervalSince1970 + 7200),
        ])
        let first = await service.quotas()
        XCTAssertEqual(first.first?.windows.first?.usedPercent, 10)

        // 1 分钟内：直接给缓存，不发请求
        clock.advance(30)
        let cached = await service.snapshot()
        XCTAssertNil(cached.pending)
        XCTAssertEqual(cached.current?.first?.windows.first?.usedPercent, 10)
        XCTAssertEqual(transport.requests.count, 1)

        // 过期：立刻给旧的，同时交回后台刷新
        clock.advance(40)
        let stale = await service.snapshot()
        XCTAssertEqual(stale.current?.first?.windows.first?.usedPercent, 10)
        XCTAssertNotNil(stale.pending)
        let refreshed = await stale.pending!.value
        XCTAssertEqual(refreshed.first?.windows.first?.usedPercent, 20)
        let after = await service.snapshot()
        XCTAssertEqual(after.current?.first?.windows.first?.usedPercent, 20)
    }

    func testFailedRefreshKeepsPreviousWindowsMarkedFailed() async {
        let calls = Counter()
        let transport = FakeTransport { _ in
            calls.increment() == 1 ? .init(status: 200, data: Data(Self.codexUsage.utf8)) : .init(status: 503, data: Data())
        }
        let clock = Clock(now)
        let service = makeService(transport: transport, clock: clock, files: [
            codexRoot.appendingPathComponent("auth.json").path: codexAuthJSON(exp: now.timeIntervalSince1970 + 7200),
        ])
        _ = await service.quotas()
        clock.advance(120)
        let again = await service.snapshot().pending!.value
        XCTAssertEqual(again.first?.status, .failed("额度接口返回 503"))
        XCTAssertEqual(again.first?.windows.first?.usedPercent, 27, "单次失败别把旧条清空")
        XCTAssertEqual(SubscriptionQuotaParser.summaryLine(again[0], now: now), "Codex 额度 · 7 天 27% · 10 天后重置 · 旧数据")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        @discardableResult func increment() -> Int { lock.withLock { value += 1; return value } }
    }
}
#endif
