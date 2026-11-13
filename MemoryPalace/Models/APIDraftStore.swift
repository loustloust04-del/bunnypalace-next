import Foundation
#if os(iOS)
import UIKit
#endif

/// API 卡编辑页 / 引导「接 API」页没存完的内容（plan-api-draft-and-fix-jump §2）。
/// 切后台那一刻写一次，App 被系统杀掉再打开能原样带回。单槽：最后切后台的那一页赢。
struct APIDraft: Codable, Equatable {
    static let newSlot = "__new__"
    static let onboardingSlot = "__onboarding__"

    struct DraftModel: Codable, Equatable {
        var modelId: String
        var name: String
    }

    /// 卡 id；新建 = `newSlot`；引导 = `onboardingSlot`
    var slot: String
    var emoji = ""
    var nickname = ""
    /// 编辑页：`_custom_` 或预设 id；引导：服务商（`OnbProvider` rawValue）
    var presetSelection = ""
    /// 调用方给完整地址；落盘时带凭据的（query / userinfo / 像 key 的）整条进钥匙串，这里只留空（astra #2）
    var customBaseURL = ""
    var customType = ProviderType.openaiCompatible.rawValue
    var toolsSupported = true
    /// Optional：旧草稿没这个 key 也要解得出（nil = 开）
    var sideCallStreaming: Bool?
    var models: [DraftModel] = []
    /// 编辑页：预设的区域 id / 接口格式（`ProviderType` rawValue）。Optional：合成的 Decodable 不认默认值，旧草稿缺 key 也要解得出
    var regionSelection: String?
    var presetProtocol: String?
    /// key 是否在草稿钥匙串里（false = 恢复时用卡上已存的）
    var keyStored = false
    /// 地址在草稿钥匙串里（带凭据的地址不进偏好）
    var baseURLInSecret = false
    /// 这一版草稿的钥匙串 account（每版一个，astra #1：元数据和 key 不会串版本）
    var secretAccount: String?
    /// 冷启动自动回到编辑页只弹一次（Q2）
    var resumeOffered = false
    var savedAt = Date()
}

/// 非敏感字段进 UserDefaults `apiDraftV1`；key（和带凭据的地址）进钥匙串单独 service，不进卡 key 的 `getAll()` 预热、不跟 iCloud 同步。
enum APIDraftStore {
    static let defaultsKey = "apiDraftV1"
    static let keychainService = "com.susu.MemoryPalace.apikey.draft"
    static let accountPrefix = "draft-"
    /// Q3：24 小时
    static let ttl: TimeInterval = 24 * 3600

    /// 钥匙串读写口（测试换成会失败的，验证半截写入不串卡）
    nonisolated(unsafe) static var writeSecret: (_ value: String, _ account: String) -> Bool = {
        KeychainStore.set($0, account: $1, sync: false, service: keychainService)
    }
    nonisolated(unsafe) static var readSecret: (_ account: String) -> String? = {
        KeychainStore.get(account: $0, service: keychainService)
    }

    private struct Secret: Codable {
        var key: String?
        var baseURL: String?
    }

    // MARK: 地址

    /// 地址能不能明文放偏好：只认干净的 http(s)://host[:port]/path，有 userinfo / query / fragment / 像 key 的段都不行
    static func isSafeBaseURL(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        guard let c = URLComponents(string: text), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, !text.contains("@") else { return false }
        let lower = text.lowercased()
        if ["key", "token", "secret", "sk-", "password", "auth"].contains(where: lower.contains) { return false }
        // 长串（像 key）的路径段
        return !c.path.split(separator: "/").contains { $0.count >= 24 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    // MARK: 存

    /// `key` 为 nil = 不存 key（已存卡的 key 没改）；非 nil（含空串）= 存这一份。
    /// 顺序：先写这一版的钥匙串（新 account）→ 成功了才发布元数据 → 再删旧版。半路被杀只会留下旧的一致版本 + 孤儿条目。
    @discardableResult
    static func save(_ draft: APIDraft, key: String?, defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        var d = draft
        d.keyStored = key != nil
        d.savedAt = now
        d.resumeOffered = false
        let fullURL = d.customBaseURL
        d.baseURLInSecret = !isSafeBaseURL(fullURL)
        if d.baseURLInSecret { d.customBaseURL = "" }
        d.secretAccount = nil

        let secret = Secret(key: (key?.isEmpty == false) ? key : nil, baseURL: d.baseURLInSecret ? fullURL : nil)
        return withBackgroundTime {
            if secret.key != nil || secret.baseURL != nil {
                let account = accountPrefix + UUID().uuidString
                guard let data = try? JSONEncoder().encode(secret), let text = String(data: data, encoding: .utf8),
                      writeSecret(text, account) else { return false }
                d.secretAccount = account
            }
            guard let data = try? JSONEncoder().encode(d) else { return false }
            defaults.set(data, forKey: defaultsKey)
            removeSecrets(except: d.secretAccount)
            return true
        }
    }

    // MARK: 取

    /// 新鲜草稿（不读钥匙串；带凭据的地址在这里是空的）；过期顺手清
    static func peek(defaults: UserDefaults = .standard, now: Date = Date()) -> APIDraft? {
        guard let d = decoded(defaults) else { return nil }
        guard now.timeIntervalSince(d.savedAt) < ttl, d.savedAt <= now.addingTimeInterval(60) else {
            clear(defaults: defaults)
            return nil
        }
        return d
    }

    /// 这一页的草稿 + key（slot 不符 / 过期返回 nil）。地址还原成完整的。
    /// 元数据说有钥匙串里的东西但读不到（被清 / 半截）→ 整份作废，绝不拿别的版本的 key 顶上
    static func load(slot: String, defaults: UserDefaults = .standard, now: Date = Date()) -> (draft: APIDraft, key: String?)? {
        guard var d = peek(defaults: defaults, now: now), d.slot == slot else { return nil }
        var secret = Secret()
        if let account = d.secretAccount {
            guard let text = readSecret(account), let data = text.data(using: .utf8),
                  let s = try? JSONDecoder().decode(Secret.self, from: data) else {
                clear(defaults: defaults)
                return nil
            }
            secret = s
        } else if d.baseURLInSecret {
            clear(defaults: defaults)
            return nil
        }
        if d.baseURLInSecret { d.customBaseURL = secret.baseURL ?? "" }
        let key = d.keyStored ? (secret.key ?? "") : nil
        return (d, key)
    }

    // MARK: 清

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
        removeSecrets(except: nil)
    }

    /// 只清属于这一页的草稿：打开别的卡不删不属于它的
    static func clear(slot: String, defaults: UserDefaults = .standard) {
        guard let d = decoded(defaults), d.slot == slot else { return }
        clear(defaults: defaults)
    }

    /// 冷启动自动回到编辑页用：有新鲜的卡草稿（不含引导）且没弹过 → 记成弹过并返回。草稿本身留着
    static func takePendingResume(defaults: UserDefaults = .standard, now: Date = Date()) -> APIDraft? {
        guard var d = peek(defaults: defaults, now: now), d.slot != APIDraft.onboardingSlot, !d.resumeOffered else { return nil }
        d.resumeOffered = true
        if let data = try? JSONEncoder().encode(d) { defaults.set(data, forKey: defaultsKey) }
        return d
    }

    // MARK: 内部

    private static func decoded(_ defaults: UserDefaults) -> APIDraft? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(APIDraft.self, from: data)
    }

    /// 草稿 service 下除当前版本外全删（顺带收掉半截写入留下的孤儿）
    private static func removeSecrets(except keep: String?) {
        for account in KeychainStore.allAccounts(service: keychainService) where account != keep {
            KeychainStore.remove(account: account, service: keychainService)
        }
    }

    /// iOS 切后台时同步写完再挂起（astra #11 裁定：保持同步，包一层后台时间）
    private static func withBackgroundTime<T>(_ work: () -> T) -> T {
        #if os(iOS)
        guard Thread.isMainThread else { return work() }
        let task = UIApplication.shared.beginBackgroundTask(withName: "api-draft")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        #endif
        return work()
    }
}
