import Foundation

/// Live Activity 的 push token 注册记录（D6 协议，`docs/prompts/2026-08-29-live-activity/README.md`）。
///
/// 跟 `register_push_token` / `pushTokens` / `push-tokens.json` 那套**完全隔离**：
/// 作用域（一个 activity vs 一台设备）、topic（`…push-type.liveactivity` vs 默认）、
/// payload（content-state vs alert）、路由身份（activity_id / install_id vs token）四不同。
///
/// 纯数据，不 import ActivityKit —— macOS target 也编（测试挂在 macOS 上）。
struct CCLiveActivityRegistration: Codable, Hashable {
    enum Kind: String, Codable {
        /// 一个具体 activity 的 update token（按 `activity_id` 存）
        case update
        /// 这台设备的 push-to-start token（按 `install_id` 存）
        case start
    }

    var kind: Kind
    var token: String
    var previousToken: String?
    var activityId: String?
    var sessionName: String?
    var installId: String
    /// "sandbox" | "production"
    var env: String
    /// "full" | "hidden"
    var preview: String
    /// 本包 bundle id；hub 派生 `<topic>.push-type.liveactivity`。nil 不落键，老 hub / 老数据照常。
    var topic: String? = nil

    enum CodingKeys: String, CodingKey {
        case kind
        case token
        case previousToken = "previous_token"
        case activityId = "activity_id"
        case sessionName = "session_name"
        case installId = "install_id"
        case env
        case preview
        case topic
    }

    /// 身份键：update 按 activity_id、start 按 install_id。
    /// token 轮换是**替换**同一条（Apple 要求服务端让旧 token 失效），不追加。
    var identity: String {
        switch kind {
        case .update: return "update:\(activityId ?? "")"
        case .start: return "start:\(installId)"
        }
    }

    /// 转 WS 帧字段（wire key 逐字来自 CodingKeys；nil 不落键）。
    func wireFields() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

/// 注册集合的持久化（`UserDefaults`）。WS 没连上时 `send` 直接失败，
/// 靠这份落盘 + `didOpen` 全量补报兜底。
enum CCLiveActivityRegistrationStore {
    static let installIdKey = "ccLiveActivityInstallId"
    static let registrationsKey = "ccLiveActivityRegistrations"

    /// 首次生成 UUID 存下，之后不变（push-to-start token 的路由身份）。
    static func installId(_ defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: installIdKey), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: installIdKey)
        return fresh
    }

    static func load(_ defaults: UserDefaults = .standard) -> [CCLiveActivityRegistration] {
        guard let data = defaults.data(forKey: registrationsKey) else { return [] }
        return (try? JSONDecoder().decode([CCLiveActivityRegistration].self, from: data)) ?? []
    }

    static func save(_ regs: [CCLiveActivityRegistration], _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(regs) else { return }
        defaults.set(data, forKey: registrationsKey)
    }

    /// 同 identity 替换，不追加。
    static func upsert(_ reg: CCLiveActivityRegistration,
                       into regs: [CCLiveActivityRegistration]) -> [CCLiveActivityRegistration] {
        var out = regs.filter { $0.identity != reg.identity }
        out.append(reg)
        return out
    }
}
