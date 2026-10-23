#if os(macOS)
import CryptoKit
import Foundation
import Observation

// 订阅额度（docs/research-magpie.md §2.2，照 magpie `internal/provider/subscription_usage.go`）：
// 读本机已登录 CLI 的凭据，只读请求官方额度接口。
// - **绝不刷新、绝不写回 token**：refresh token 只能有一个持有者，厂商每次刷新都会轮换它，我们刷一次就会把 CLI 挤下线
//   （magpie `logins.go` 头注释）。token 过期 → 状态「在终端跑一次 claude / codex」，CLI 自己会续上。
// - 凭据只在内存里用：不落盘、不打日志、不进错误文案。
// - 多家并行、总超时 10 s、缓存 1 分钟、有旧数据先给旧的再后台刷（magpie issue #6：串行整页卡死）、单家失败不连累别家。

/// 哪一家的订阅
enum QuotaProvider: String, Sendable, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// 过期时让她在终端跑的那条命令
    var cliCommand: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    init?(agent: CodingAgent) {
        switch agent {
        case .claudeCode: self = .claude
        case .codex: self = .codex
        default: return nil
        }
    }
}

/// 一个滚动额度窗口（5 小时 / 7 天 …）
struct QuotaWindow: Equatable, Sendable {
    var label: String
    /// 0–100
    var usedPercent: Double
    var resetsAt: Date?
}

/// 一家（一个登录根）的额度
struct SubscriptionQuota: Equatable, Sendable, Identifiable {
    enum Status: Equatable, Sendable {
        case ok
        /// token 过期 / 被拒：需要她在终端跑一次 CLI（我们不代刷）
        case needsLogin
        /// 网络 / 超时 / 限流等；windows 可能是上一次的旧数据
        case failed(String)
    }

    var provider: QuotaProvider
    /// 登录根（`~/.claude`、`~/.codex` 或位置配置里的自定义根）
    var root: String
    /// 非默认根时的区分标签（`~/.claude-b`）；默认根 nil
    var accountLabel: String?
    var plan: String?
    var windows: [QuotaWindow]
    var status: Status
    var fetchedAt: Date

    var id: String { provider.rawValue + ":" + root }

    var title: String {
        accountLabel.map { "\(provider.displayName) · \($0)" } ?? provider.displayName
    }

    /// 卡片上的两条：Claude 取 5 小时 + 7 天，Codex 取 primary + secondary（没有就只一条）
    var primaryWindows: [QuotaWindow] { Array(windows.prefix(2)) }

    var statusText: String? {
        switch status {
        case .ok: return nil
        case .needsLogin: return "登录已过期——在终端跑一次 \(provider.cliCommand) 就会续上"
        case .failed(let reason): return reason
        }
    }
}

// MARK: - 纯函数：凭据、接口响应、文案（fixture 可测）

enum SubscriptionQuotaParser {
    struct Credential: Equatable, Sendable {
        var accessToken: String
        var accountId: String?
        var expiresAt: Date?
        var plan: String?

        /// 余量不足 30 s 就当过期：我们不刷新，请求到一半过期只会换来 401
        func isExpired(now: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) < 30
        }
    }

    enum ParseError: Error, Equatable {
        case malformed
    }

    // MARK: 凭据

    /// Claude Code 的 `.credentials.json` / Keychain 项：`{"claudeAiOauth": {"accessToken", "expiresAt"(ms), "subscriptionType"}}`
    static func claudeCredential(_ data: Data) -> Credential? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = raw["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expiry: Date?
        if let value = (oauth["expiresAt"] as? NSNumber)?.doubleValue, value > 0 {
            // 有的版本存秒、有的存毫秒（magpie `claudeExpiry`）
            expiry = Date(timeIntervalSince1970: value < 1e12 ? value : value / 1000)
        }
        let plan = (oauth["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Credential(accessToken: token, accountId: nil, expiresAt: expiry, plan: plan)
    }

    /// Codex 的 `auth.json`：`{"tokens": {"access_token", "account_id", "id_token"}}`；API key 模式（没有 tokens）不算订阅登录
    static func codexCredential(_ data: Data) -> Credential? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = raw["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        var account = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if account == nil, let idToken = tokens["id_token"] as? String,
           let auth = jwtClaims(idToken)?["https://api.openai.com/auth"] as? [String: Any] {
            account = auth["chatgpt_account_id"] as? String
        }
        let expiry = (jwtClaims(token)?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Credential(accessToken: token, accountId: account, expiresAt: expiry, plan: nil)
    }

    /// JWT 中段（不验签，只读 exp / 账号）
    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Claude Code 存 Keychain 用的服务名：默认根 `Claude Code-credentials`；`CLAUDE_CONFIG_DIR` 指到别处时
    /// 后缀 `-` + sha256(目录)前 8 位（本机 `~/.claude-b` 实测对得上）
    static func claudeKeychainService(root: String, isDefaultRoot: Bool) -> String {
        guard !isDefaultRoot else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }

    // MARK: 接口响应

    /// `GET api.anthropic.com/api/oauth/usage` → five_hour / seven_day / seven_day_opus / seven_day_sonnet
    static func claudeWindows(_ data: Data) throws -> [QuotaWindow] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.malformed }
        let keys: [(String, String)] = [("five_hour", "5 小时"), ("seven_day", "7 天"),
                                        ("seven_day_opus", "7 天 · Opus"), ("seven_day_sonnet", "7 天 · Sonnet")]
        return keys.compactMap { key, label in
            guard let window = raw[key] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return QuotaWindow(label: label, usedPercent: used, resetsAt: (window["resets_at"] as? String).flatMap(parseISODate))
        }
    }

    /// `GET chatgpt.com/backend-api/wham/usage` → plan_type + rate_limit.primary_window / secondary_window（可为 null）
    static func codexUsage(_ data: Data, now: Date) throws -> (plan: String?, windows: [QuotaWindow]) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.malformed }
        let plan = (raw["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let limits = raw["rate_limit"] as? [String: Any] ?? [:]
        let windows = ["primary_window", "secondary_window"].compactMap { key -> QuotaWindow? in
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let seconds = (window["limit_window_seconds"] as? NSNumber)?.int64Value ?? 0
            var resets: Date?
            if let at = (window["reset_at"] as? NSNumber)?.doubleValue, at > 0 {
                resets = Date(timeIntervalSince1970: at)
            } else if let after = (window["reset_after_seconds"] as? NSNumber)?.doubleValue, after > 0 {
                resets = now.addingTimeInterval(after)
            }
            return QuotaWindow(label: durationLabel(seconds), usedPercent: used, resetsAt: resets)
        }
        return (plan, windows)
    }

    static func durationLabel(_ seconds: Int64) -> String {
        if seconds > 0, seconds % 86_400 == 0 { return "\(seconds / 86_400) 天" }
        if seconds > 0, seconds % 3_600 == 0 { return "\(seconds / 3_600) 小时" }
        return "额度"
    }

    /// RFC 3339；小数秒超过 3 位（Anthropic 回微秒）先截到毫秒，Foundation 的解析器不认更长的
    static func parseISODate(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            if digits.count > 3 {
                text.replaceSubrange(digits.index(digits.startIndex, offsetBy: 3)..<digits.endIndex, with: "")
            }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    // MARK: 文案

    /// 「x 小时后重置」：不到 1 小时按分钟，不到 2 天按小时，再往后按天
    static func resetText(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "即将重置" }
        if seconds < 3_600 { return "\(Int((seconds / 60).rounded(.up))) 分钟后重置" }
        if seconds < 48 * 3_600 { return "\(Int((seconds / 3_600).rounded())) 小时后重置" }
        return "\(Int((seconds / 86_400).rounded())) 天后重置"
    }

    static func percentText(_ used: Double) -> String { "\(Int(used.rounded()))%" }

    /// ⋯ 菜单底注那一行：「Claude 额度 · 5 小时 42% · 7 天 18% · 3 小时后重置」
    static func summaryLine(_ quota: SubscriptionQuota, now: Date) -> String {
        if quota.windows.isEmpty, let status = quota.statusText { return "\(quota.title) 额度：\(status)" }
        var parts = ["\(quota.title) 额度"]
        parts += quota.primaryWindows.map { "\($0.label) \(percentText($0.usedPercent))" }
        if let reset = resetText(quota.primaryWindows.first?.resetsAt, now: now) { parts.append(reset) }
        if quota.status != .ok { parts.append("旧数据") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 服务

/// 拉额度的服务。依赖全部可注入：测试用假传输 / 假凭据，不碰她的 Keychain 与网络
actor SubscriptionQuotaService {
    /// 一个登录根
    struct Source: Equatable, Sendable {
        var provider: QuotaProvider
        var root: URL
        var isDefaultRoot: Bool
    }

    struct Response: Sendable {
        var status: Int
        var data: Data
    }

    typealias Transport = @Sendable (URLRequest) async throws -> Response

    static let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let sources: @Sendable () async -> [Source]
    private let transport: Transport
    private let readFile: @Sendable (URL) -> Data?
    private let readKeychain: @Sendable (String) -> Data?
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    private let ttl: TimeInterval

    private var cache: [SubscriptionQuota]?
    private var cachedAt: Date?
    private var inflight: Task<[SubscriptionQuota], Never>?

    init(sources: @escaping @Sendable () async -> [Source],
         transport: @escaping Transport = SubscriptionQuotaService.urlSessionTransport,
         readFile: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) },
         readKeychain: @escaping @Sendable (String) -> Data? = { SubscriptionQuotaService.readKeychainPassword(service: $0) },
         now: @escaping @Sendable () -> Date = { Date() },
         timeout: TimeInterval = 10,
         ttl: TimeInterval = 60) {
        self.sources = sources
        self.transport = transport
        self.readFile = readFile
        self.readKeychain = readKeychain
        self.now = now
        self.timeout = timeout
        self.ttl = ttl
    }

    /// 现有数据 + 正在进行的刷新。有缓存就立刻返回（新鲜的不刷；过期的起后台刷新交回 pending）；
    /// 一次都没拉过才让调用方等 pending
    func snapshot(force: Bool = false) -> (current: [SubscriptionQuota]?, pending: Task<[SubscriptionQuota], Never>?) {
        let fresh = cachedAt.map { now().timeIntervalSince($0) < ttl } ?? false
        if (!fresh || force), inflight == nil {
            let task = Task { await self.refreshAll() }
            inflight = task
        }
        return (cache, inflight)
    }

    /// 等到有数据为止（首拉会等，之后先给缓存）
    func quotas(force: Bool = false) async -> [SubscriptionQuota] {
        let (current, pending) = snapshot(force: force)
        if let current { return current }
        return await pending?.value ?? []
    }

    private func refreshAll() async -> [SubscriptionQuota] {
        let list = await sources()
        let previous = cache ?? []
        let deadline = timeout
        let fetched = await withTaskGroup(of: (Int, SubscriptionQuota?).self) { group in
            for (index, source) in list.enumerated() {
                group.addTask { (index, await self.fetchBounded(source, deadline: deadline)) }
            }
            var out = [SubscriptionQuota?](repeating: nil, count: list.count)
            for await (index, quota) in group { out[index] = quota }
            return out.compactMap { $0 }
        }
        // 这次失败的家留上一次的窗口（标旧），别让一次网络抖动把条清空
        let merged = fetched.map { quota -> SubscriptionQuota in
            guard case .failed = quota.status, quota.windows.isEmpty,
                  let old = previous.first(where: { $0.id == quota.id }), !old.windows.isEmpty else { return quota }
            var kept = quota
            kept.windows = old.windows
            kept.plan = kept.plan ?? old.plan
            return kept
        }
        cache = merged
        cachedAt = now()
        inflight = nil
        return merged
    }

    private enum Outcome: Sendable {
        case finished(SubscriptionQuota?)
        case timedOut
    }

    /// 单家：与计时器赛跑，超时的这家记失败，不拖别家。nil = 这家没登录（不占一行）
    private nonisolated func fetchBounded(_ source: Source, deadline: TimeInterval) async -> SubscriptionQuota? {
        let stamp = now()
        let outcome = await withTaskGroup(of: Outcome.self) { group -> Outcome in
            group.addTask { .finished(await self.fetch(source)) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        switch outcome {
        case .finished(let quota): return quota
        case .timedOut: return base(source, at: stamp, status: .failed("请求超时"))
        }
    }

    private nonisolated func base(_ source: Source, at date: Date, status: SubscriptionQuota.Status) -> SubscriptionQuota {
        let root = source.root.path
        let label = source.isDefaultRoot ? nil : CodingLocations.tildePath(root)
        return SubscriptionQuota(provider: source.provider, root: root, accountLabel: label, plan: nil,
                                 windows: [], status: status, fetchedAt: date)
    }

    /// 一家的一次拉取。nil 凭据 → 这家不出现（没登录就不占一行）由 `credential` 决定；过期 → needsLogin，不发请求
    private nonisolated func fetch(_ source: Source) async -> SubscriptionQuota? {
        let stamp = now()
        guard let credential = credential(for: source) else { return nil }
        var quota = base(source, at: stamp, status: .ok)
        quota.plan = credential.plan
        if credential.isExpired(now: stamp) {
            quota.status = .needsLogin
            return quota
        }
        var request: URLRequest
        switch source.provider {
        case .claude:
            request = URLRequest(url: Self.claudeUsageURL)
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        case .codex:
            request = URLRequest(url: Self.codexUsageURL)
            if let account = credential.accountId { request.setValue(account, forHTTPHeaderField: "chatgpt-account-id") }
        }
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MemoryPalace", forHTTPHeaderField: "User-Agent")
        do {
            let response = try await transport(request)
            switch response.status {
            case 200..<300:
                switch source.provider {
                case .claude:
                    quota.windows = try SubscriptionQuotaParser.claudeWindows(response.data)
                case .codex:
                    let usage = try SubscriptionQuotaParser.codexUsage(response.data, now: stamp)
                    quota.windows = usage.windows
                    quota.plan = usage.plan ?? quota.plan
                }
            case 401, 403:
                quota.status = .needsLogin
            case 429:
                quota.status = .failed("请求太频繁，稍后再试")
            default:
                quota.status = .failed("额度接口返回 \(response.status)")
            }
        } catch is SubscriptionQuotaParser.ParseError {
            quota.status = .failed("额度接口返回了看不懂的数据")
        } catch {
            // 只报类别，不带请求细节（URLError 的描述里可能挂着 URL / 头）
            quota.status = .failed(Task.isCancelled ? "请求超时" : "网络不通")
        }
        return quota
    }

    private nonisolated func credential(for source: Source) -> SubscriptionQuotaParser.Credential? {
        switch source.provider {
        case .claude:
            if let data = readFile(source.root.appendingPathComponent(".credentials.json")),
               let credential = SubscriptionQuotaParser.claudeCredential(data) {
                return credential
            }
            let service = SubscriptionQuotaParser.claudeKeychainService(root: source.root.path, isDefaultRoot: source.isDefaultRoot)
            return readKeychain(service).flatMap(SubscriptionQuotaParser.claudeCredential)
        case .codex:
            return readFile(source.root.appendingPathComponent("auth.json")).flatMap(SubscriptionQuotaParser.codexCredential)
        }
    }

    // MARK: 默认依赖

    static let urlSessionTransport: Transport = { request in
        let configuration = URLSessionConfiguration.ephemeral   // 不落 cookie / 缓存
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return Response(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    /// Keychain 里 Claude Code 的那项。走 `/usr/bin/security`：条目是 CLI 用它写的，它在 ACL 里，不会弹授权框。
    /// 先按当前用户名找（新版 CLI 按 `-a $USER` 存），再不带账号兜底；5 s 没回就放弃。输出只留在内存
    static func readKeychainPassword(service: String) -> Data? {
        // #035：mac 测试宿主不起 security 子进程读 CC 的钥匙串条目。mp-code 也编这个文件，用环境变量判，不引 TestHostIsolation
        if ProcessInfo.processInfo.environment["MP_TEST_HOST"] == "1" { return nil }
        for account in [NSUserName(), nil] as [String?] {
            var arguments = ["find-generic-password", "-s", service, "-w"]
            if let account { arguments += ["-a", account] }
            if let data = runSecurity(arguments), !data.isEmpty { return data }
        }
        return nil
    }

    private static func runSecurity(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        DispatchQueue.global(qos: .utility).async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let trimmed = String(decoding: box.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    /// 登录根从编程会话位置配置里推（自定义根跟着走）：Claude 数据根 `<根>/projects`、Codex `<根>/sessions`；远程实例不算
    static func sources(adapters: [CodingSessionAdapter], home: URL) -> [Source] {
        let defaultClaude = home.appendingPathComponent(".claude").standardizedFileURL.path
        let defaultCodex = home.appendingPathComponent(".codex").standardizedFileURL.path
        var seen = Set<String>()
        var out: [Source] = []
        for adapter in adapters where adapter.host.isEmpty {
            let root: URL
            let provider: QuotaProvider
            if let claude = adapter as? ClaudeCodeAdapter {
                provider = .claude
                root = claude.root.lastPathComponent == "projects" ? claude.root.deletingLastPathComponent() : claude.root
            } else if let codex = adapter as? CodexAdapter {
                provider = .codex
                root = codex.sessionsDir.lastPathComponent == "sessions" ? codex.sessionsDir.deletingLastPathComponent() : codex.sessionsDir
            } else {
                continue
            }
            let path = root.standardizedFileURL.path
            guard seen.insert(provider.rawValue + ":" + path).inserted else { continue }
            let isDefault = path == (provider == .claude ? defaultClaude : defaultCodex)
            out.append(Source(provider: provider, root: URL(fileURLWithPath: path, isDirectory: true), isDefaultRoot: isDefault))
        }
        // Claude 默认根排前、Codex 其次
        return out.sorted { lhs, rhs in
            if lhs.provider != rhs.provider { return lhs.provider == .claude }
            return lhs.isDefaultRoot && !rhs.isDefaultRoot
        }
    }
}

// MARK: - 界面用的可观察外壳

@Observable
@MainActor
final class SubscriptionQuotaStore {
    static let shared = SubscriptionQuotaStore(service: SubscriptionQuotaService(sources: {
        // 位置配置在主线程那份用户状态里：每轮刷新现读，她在位置 sheet 里加的自定义根下一轮就生效
        let overrides = await MainActor.run { CodingSessionState.shared.locationOverrides }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roster = CodingSessionRoster.configured(home: home, environment: ProcessInfo.processInfo.environment, overrides: overrides)
        return SubscriptionQuotaService.sources(adapters: roster.active, home: home)
    }))

    private(set) var quotas: [SubscriptionQuota] = []
    private(set) var isLoading = false
    private(set) var loaded = false

    @ObservationIgnored private let service: SubscriptionQuotaService

    init(service: SubscriptionQuotaService) {
        self.service = service
    }

    /// 先把手上有的给界面，后台那轮回来再换
    func refresh(force: Bool = false) async {
        let (current, pending) = await service.snapshot(force: force)
        if let current {
            quotas = current
            loaded = true
        }
        guard let pending else { return }
        isLoading = true
        let fresh = await pending.value
        quotas = fresh
        loaded = true
        isLoading = false
    }

    func quota(for agent: CodingAgent) -> SubscriptionQuota? {
        guard let provider = QuotaProvider(agent: agent) else { return nil }
        return quotas.first { $0.provider == provider && $0.accountLabel == nil } ?? quotas.first { $0.provider == provider }
    }
}
#endif
