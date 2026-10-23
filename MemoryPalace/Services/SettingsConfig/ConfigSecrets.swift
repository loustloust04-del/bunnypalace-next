import Foundation

// MARK: - 设置导出里的 API key（research-magpie 2.8）
//
// 只在「包含 API key（需设口令）」时用：从 Keychain 取 key 塞进待加密的 bundle，
// 导入时按 magpie 规则写回：同 account 替换；备份没带的 account 不动（保留本机 key）。
// 打包范围（白名单）：
//   - API 卡（openaiCompatible / anthropic）的 key，account = credential id
//   - 联网搜索 key（websearch:*）、ElevenLabs 朗读 key（elevenlabs）、语音服务 key（voice.<服务 id>）
// 一律不打包：ChatGPT OAuth token、CC bridge / hub token、MCP 密钥、任何长得像 OAuth token 的值。
// 每台机器自己登录，跟 magpie 不带 subscription 同理。

/// Keychain 读写抽象 —— 测试注入内存实现，不碰真实 Keychain。
protocol ConfigSecretStore {
    func allAccounts() -> [String]
    func get(account: String) -> String?
    func set(_ value: String, account: String)
}

struct KeychainConfigSecretStore: ConfigSecretStore {
    /// 跟 ProviderManager.setApiKey 一致：按「API key iCloud 同步」开关写
    var defaults: UserDefaults = .standard

    func allAccounts() -> [String] { KeychainStore.allAccounts() }
    func get(account: String) -> String? { KeychainStore.get(account: account) }
    func set(_ value: String, account: String) {
        _ = KeychainStore.set(value, account: account, sync: defaults.bool(forKey: "apiKeyCloudSync"))
    }
}

enum ConfigSecrets {

    /// 可打包的 API 卡类型（ccBridge / chatgptOAuth / unsupported 都不带）
    private static let packableCardTypes: Set<String> = [
        ProviderType.openaiCompatible.rawValue,
        ProviderType.anthropic.rawValue,
    ]
    private static let extraAccountPrefixes = ["websearch:", "voice."]
    private static let extraAccounts: Set<String> = [VoiceTuning.keychainAccount]

    /// 收集要打包的 account → key。
    static func collect(defaults: UserDefaults, store: ConfigSecretStore) -> [String: String] {
        var accounts = Set<String>()
        if let data = defaults.data(forKey: "credentials"),
           let cards = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for card in cards {
                guard let id = card["id"] as? String,
                      let type = card["type"] as? String, packableCardTypes.contains(type) else { continue }
                accounts.insert(id)
            }
        }
        for account in store.allAccounts() where isExtraAccount(account) {
            accounts.insert(account)
        }

        var out: [String: String] = [:]
        for account in accounts {
            guard let value = store.get(account: account), isPackable(value) else { continue }
            out[account] = value
        }
        return out
    }

    /// 写回：同 account 替换；没带的不动。返回写入条数。
    @discardableResult
    static func restore(_ keys: [String: String], into store: ConfigSecretStore) -> Int {
        var n = 0
        for (account, value) in keys where isRestorable(account) && isPackable(value) {
            store.set(value, account: account)
            n += 1
        }
        return n
    }

    // MARK: - private

    private static func isExtraAccount(_ account: String) -> Bool {
        extraAccounts.contains(account) || extraAccountPrefixes.contains { account.hasPrefix($0) }
    }

    /// 导入侧再挡一次：不写 OAuth / hub 这类本机登录态 account（备份被人改过也写不进去）
    private static func isRestorable(_ account: String) -> Bool {
        let blocked: Set<String> = [APIProvider.chatgptOAuth.id, HubTokenStore.keychainAccount, "cc-bridge-hub-token"]
        return !blocked.contains(account)
    }

    /// 非空、且不是 OAuth token JSON（ChatGPT OAuth 卡的 value 是 token 三件套 JSON）
    private static func isPackable(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !v.isEmpty && OAuthTokenSet.fromKeychainString(v) == nil
    }
}
