import Foundation
import Combine

/// 联网搜索全局配置。
/// 持久化：providers 列表走 UserDefaults JSON、API key 走 KeychainStore（account="websearch:<id>"）、
/// 标量配置走 @AppStorage（resultSize/timeout/enabled/selectedId）。
@MainActor
final class WebSearchSettings: ObservableObject {
    static let shared = WebSearchSettings()

    @Published var providers: [WebSearchServiceOptions] = []
    @Published var selectedId: String = ""
    /// v2 Phase 3：黑名单。AI 通过 browse_url 永远不读这些域（后缀子域匹配）。
    /// 默认空——用户主动加；UI 提供"导入推荐"批量加敏感站。
    @Published var blockedDomains: [String] = []

    private let providersKey = "webSearchProviders_v1"
    private let selectedIdKey = "webSearchSelectedId"
    private let blockedDomainsKey = "webSearchBlockedDomains_v1"

    /// "导入推荐" 默认黑名单（支付/银行/邮箱常见 9 个敏感域）
    static let recommendedBlocklist: [String] = [
        "alipay.com",
        "weixin.qq.com",
        "paypal.com",
        "stripe.com",
        "icbc.com.cn",
        "abchina.com",
        "bankofchina.com",
        "mail.qq.com",
        "mail.163.com",
    ]

    private init() {
        load()
    }

    // MARK: - 标量（直接读 UserDefaults，UI 用 @AppStorage 同 key 即可）

    var searchEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: Self.kEnabled) as? Bool) ?? false }
        set { UserDefaults.standard.set(newValue, forKey: Self.kEnabled); objectWillChange.send() }
    }

    var resultSize: Int {
        get { (UserDefaults.standard.object(forKey: Self.kResultSize) as? Int) ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: Self.kResultSize); objectWillChange.send() }
    }

    var timeoutMs: Int {
        get { (UserDefaults.standard.object(forKey: Self.kTimeoutMs) as? Int) ?? 5000 }
        set { UserDefaults.standard.set(newValue, forKey: Self.kTimeoutMs); objectWillChange.send() }
    }

    var commonOptions: WebSearchCommonOptions {
        WebSearchCommonOptions(resultSize: resultSize, timeoutMs: timeoutMs)
    }

    static let kEnabled = "webSearchEnabled"
    static let kResultSize = "webSearchResultSize"
    static let kTimeoutMs = "webSearchTimeoutMs"

    // MARK: - providers 列表持久化

    func load() {
        if let data = UserDefaults.standard.data(forKey: providersKey),
           let decoded = try? JSONDecoder().decode([WebSearchServiceOptions].self, from: data) {
            providers = decoded
        }
        selectedId = UserDefaults.standard.string(forKey: selectedIdKey) ?? ""
        if selectedId.isEmpty || !providers.contains(where: { $0.id == selectedId }) {
            selectedId = providers.first?.id ?? ""
        }
        if let data = UserDefaults.standard.data(forKey: blockedDomainsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            blockedDomains = decoded
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: providersKey)
        }
        UserDefaults.standard.set(selectedId, forKey: selectedIdKey)
        if let data = try? JSONEncoder().encode(blockedDomains) {
            UserDefaults.standard.set(data, forKey: blockedDomainsKey)
        }
        objectWillChange.send()
    }

    // MARK: - 增删改

    func add(_ options: WebSearchServiceOptions) {
        providers.append(options)
        if selectedId.isEmpty { selectedId = options.id }
        save()
    }

    func update(_ options: WebSearchServiceOptions) {
        guard let idx = providers.firstIndex(where: { $0.id == options.id }) else { return }
        providers[idx] = options
        save()
    }

    func remove(id: String) {
        providers.removeAll { $0.id == id }
        KeychainStore.remove(account: "websearch:\(id)")
        if selectedId == id {
            selectedId = providers.first?.id ?? ""
        }
        save()
    }

    func select(id: String) {
        guard providers.contains(where: { $0.id == id }) else { return }
        selectedId = id
        save()
    }

    var selected: WebSearchServiceOptions? {
        providers.first { $0.id == selectedId }
    }

    // MARK: - API key（走 Keychain）

    func setAPIKey(_ key: String?, for options: WebSearchServiceOptions, sync: Bool = false) {
        KeychainStore.set(key, account: options.keychainAccount, sync: sync)
    }

    func apiKey(for options: WebSearchServiceOptions) -> String? {
        KeychainStore.get(account: options.keychainAccount)
    }

    // MARK: - 黑名单（v2 Phase 3）

    /// 规范化用户输入：strip scheme / 路径 / 端口 / 前后空白；lowercase
    /// "https://www.zhihu.com/path?x=1" → "www.zhihu.com"
    static func normalizeDomain(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("http://") { s.removeFirst("http://".count) }
        if s.hasPrefix("https://") { s.removeFirst("https://".count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s
    }

    func addBlocked(_ raw: String) {
        let d = Self.normalizeDomain(raw)
        guard !d.isEmpty, !blockedDomains.contains(d) else { return }
        blockedDomains.append(d)
        save()
    }

    func removeBlocked(_ domain: String) {
        blockedDomains.removeAll { $0 == domain }
        save()
    }

    func importRecommendedBlocklist() {
        var added = false
        for d in Self.recommendedBlocklist where !blockedDomains.contains(d) {
            blockedDomains.append(d)
            added = true
        }
        if added { save() }
    }

    /// 后缀子域匹配：黑名单 "example.com" 拦 "example.com" / "*.example.com"，
    /// 但**不**拦 "notexample.com"。
    func isBlocked(host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        for d in blockedDomains where !d.isEmpty {
            if h == d || h.hasSuffix("." + d) { return true }
        }
        return false
    }
}
