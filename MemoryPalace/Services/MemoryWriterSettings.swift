import MemoryCore
import Foundation


/// 写入那一行的开关（和二级页顶上的开关同一个键）。不含总开关
enum MemoryWriterSettings {
    static func key(_ id: MemoryWriterID) -> String? {
        switch id {
        case .a2: return "mem_content_summary"
        case .a3: return "mem_write_a3"
        case .a4: return "mem_content_timeline"
        case .b1: return "mem_content_heartvoice"
        case .b4: return "mem_write_b4"
        case .c2: return "mem_content_facts"
        case .c3: return "mem_write_c3"
        default: return nil
        }
    }

    /// 没写过的默认（= 今天新装的默认；C3 同 C2 默认开）。A3 没写过跟老键 `mem_content_summary`（拆开前 A2 / A3 一个开关）
    static func isOn(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> Bool {
        guard let key = key(id) else { return false }
        if let v = defaults.object(forKey: key) as? Bool { return v }
        switch id {
        case .a3: return (defaults.object(forKey: "mem_content_summary") as? Bool) ?? true
        case .b1: return false
        default: return true
        }
    }

    static func set(_ id: MemoryWriterID, _ on: Bool, defaults: UserDefaults = .standard) {
        guard let key = key(id) else { return }
        defaults.set(on, forKey: key)
    }

    /// 总开关 && 这一项
    static func writes(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> Bool {
        let master = (defaults.object(forKey: "mem_master") as? Bool) ?? true
        return master && isOn(id, defaults: defaults)
    }

}

// MARK: - 【开窗口】带什么（plan §三）

/// 楼层的新窗默认；未保存本窗选择的老窗仍每轮读取。原四键没写过时沿用旧开关，
/// 保持老窗各段逐字不变；新窗保存后的六项由 MemoryWindowChoices 管理。
enum MemoryOpenWindow {
    static let a2Key = "mem_open_a2"
    static let a4Key = "mem_open_a4"
    static let b4Key = "mem_open_b4"
    static let cKey = "mem_open_c"

    static func isChecked(_ id: MemoryWriterID, defaults: UserDefaults = MemoryReadEnvironment.defaults) -> Bool {
        switch id {
        case .a2: return (defaults.object(forKey: a2Key) as? Bool) ?? ((defaults.object(forKey: "mem_content_summary") as? Bool) ?? true)
        case .a4: return (defaults.object(forKey: a4Key) as? Bool) ?? ((defaults.object(forKey: "mem_content_timeline") as? Bool) ?? true)
        case .b4: return (defaults.object(forKey: b4Key) as? Bool) ?? true
        // C 没写过 = 不勾（粟粟 10-16：等 C3 整理好再开）；点过勾 / 导入过的键里有值，照旧
        case .c: return (defaults.object(forKey: cKey) as? Bool) ?? false
        default: return false
        }
    }

    static func isChecked(_ id: MemoryWriterID, profileId: String, defaults: UserDefaults = MemoryReadEnvironment.defaults) -> Bool {
        MemoryOpenWindowStore.load(id, profileId: profileId, defaults: defaults) ?? isChecked(id, defaults: defaults)
    }

    static func key(_ id: MemoryWriterID) -> String? {
        switch id {
        case .a2: return a2Key
        case .a4: return a4Key
        case .b4: return b4Key
        case .c: return cKey
        default: return nil
        }
    }

    /// 二级页里列的（A3 不注入、B1 是工具，都不列）
    static let rows: [MemoryWriterID] = [.a2, .a4, .b4, .c]

    /// 「每轮全带」：批过的原子事实每一轮都带（预算内）。楼层档，没写过 = 不勾；只听它自己，不跟别的开关
    static let everyRoundKey = "mem_open_every_round"

    static func everyRound(profileId: String, defaults: UserDefaults = MemoryReadEnvironment.defaults) -> Bool {
        MemoryOpenWindowStore.load(key: everyRoundKey, profileId: profileId, defaults: defaults) ?? false
    }

    static func setEveryRound(_ on: Bool, profileId: String, defaults: UserDefaults = .standard) {
        MemoryOpenWindowStore.save(key: everyRoundKey, on, profileId: profileId, defaults: defaults)
    }

    /// 二级页里另外三勾（纸条那几样的楼层默认）
    static let noteExtras: [MemoryNoteItem] = [.pending, .previousWindow, .pinned]

    /// 「开窗口带什么」页上勾着几项（一级页那行副标题的数）：上面四项 + 另外三勾 + 原子事实每轮全带
    static func checkedCount(profileId: String, defaults: UserDefaults = MemoryReadEnvironment.defaults) -> Int {
        let floor = MemoryWindowChoices.defaults(profileId: profileId, defaults: defaults)
        return rows.filter { isChecked($0, profileId: profileId, defaults: defaults) }.count
            + noteExtras.filter { floor[$0] }.count
            + (everyRound(profileId: profileId, defaults: defaults) ? 1 : 0)
    }
}

enum MemoryOpenWindowStore {
    static let storageKey = "memoryOpenWindowByProfile_v1"
    private static let lock = NSLock()

    static func load(_ id: MemoryWriterID, profileId: String, defaults: UserDefaults = .standard) -> Bool? {
        guard let key = MemoryOpenWindow.key(id) else { return nil }
        return load(key: key, profileId: profileId, defaults: defaults)
    }

    static func save(_ id: MemoryWriterID, _ checked: Bool, profileId: String, defaults: UserDefaults = .standard) {
        guard let key = MemoryOpenWindow.key(id) else { return }
        save(key: key, checked, profileId: profileId, defaults: defaults)
    }

    /// 段④：纸条新增的几勾（待续 / 上窗 / 钉住 / 弹纸条）没有写入编号，按键名存在同一楼层档里
    static func load(key: String, profileId: String, defaults: UserDefaults = .standard) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return archive(defaults: defaults)[profileId]?[key]
    }

    static func save(key: String, _ checked: Bool, profileId: String, defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        var values = archive(defaults: defaults)
        values[profileId, default: [:]][key] = checked
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: storageKey) }
    }

    private static func archive(defaults: UserDefaults) -> [String: [String: Bool]] {
        guard let data = defaults.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) else { return [:] }
        return values
    }
}

// MARK: - 触发三选一（plan §二 A2 / A3 / A4 页、§六）

enum MemoryTriggerMode: String, CaseIterable {
    case idle, rounds, manual

    var label: String {
        switch self {
        case .idle: return "停 N 分钟"
        case .rounds: return "每 N 回合"
        case .manual: return "只手动"
        }
    }
}

enum MemoryTriggers {
    static func modeKey(_ id: MemoryWriterID) -> String { "mem_trigger_\(id.rawValue)" }
    static func idleKey(_ id: MemoryWriterID) -> String { "mem_trigger_\(id.rawValue)_idle" }
    /// A2 的回合数就是今天的 `ctx_compress_interval`（Prompt 页那个步进器同一个键）
    static func roundsKey(_ id: MemoryWriterID) -> String { id == .a2 ? "ctx_compress_interval" : "mem_trigger_\(id.rawValue)_rounds" }
    static func onNewKey(_ id: MemoryWriterID) -> String { "mem_trigger_\(id.rawValue)_onnew" }
    /// A线提示词（完整版）§A3「什么时候写」：默认静默24小时；不写回显式值。
    static let defaultA3IdleMinutes = 24 * 60

    /// 默认：A2 每 N 回合；A3 停 24 小时。
    static func mode(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> MemoryTriggerMode {
        defaults.string(forKey: modeKey(id)).flatMap(MemoryTriggerMode.init(rawValue:)) ?? (id == .a2 ? .rounds : .idle)
    }

    static func defaultIdleMinutes(_ id: MemoryWriterID) -> Int { id == .a2 ? 60 : (id == .a3 ? defaultA3IdleMinutes : 720) }
    static func defaultRounds(_ id: MemoryWriterID) -> Int { id == .a2 ? 5 : 30 }

    static func idleMinutes(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: idleKey(id))
        return v > 0 ? v : defaultIdleMinutes(id)
    }

    static func idle(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> TimeInterval {
        TimeInterval(idleMinutes(id, defaults: defaults) * 60)
    }

    static func rounds(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: roundsKey(id))
        return v > 0 ? v : defaultRounds(id)
    }

    /// 新建对话时先写掉最近聊过的（A3 / A4，默认开 = 今天）
    static func closesOnNewConversation(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: onNewKey(id)) as? Bool) ?? true
    }

    /// 「12 小时」「1 小时 30 分」「45 分钟」
    static func idleText(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) 分钟" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
    }
}

// MARK: - 每项单选模型（plan A7）

/// A2 / A3 各自的模型：空 = 跟「提取模型」；选了的卡停了 / 模型删了也退回提取模型。A4 走 `TimelineModelRoute`，C2 走 `FragmentModelRoute`
enum MemoryWriterModels {
    static func key(_ id: MemoryWriterID) -> String { "mem_model_\(id.rawValue)" }

    static func choice(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key(id)) ?? ""
    }

    /// 「提取模型」现在实际解析成谁：写手运行时和设置页显示都走这一处（她选的 → 没选 / 停用了按自动：对话那张卡的便宜款 → 对话模型）。
    /// chat = 退回用的对话模型（nil = 全局选的）
    static func extract(providers: ProviderManager, chat: ProviderModel? = nil) -> ProviderModel {
        let chat = chat ?? providers.resolveModel(conversationModelId: nil, profileModelId: nil,
                                                  globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        return ConversationViewModel.memoryModel(providerManager: providers, fallback: chat)
    }

    /// A2 / A3 这个写手现在实际用谁（单选了且还在启用卡里 → 它；否则 → 提取模型实际解析出来的那个）
    static func actual(_ id: MemoryWriterID, providers: ProviderManager, chat: ProviderModel? = nil) -> ProviderModel {
        resolve(choice: choice(id), memoryModel: extract(providers: providers, chat: chat),
                available: FragmentModelRoute.remoteCredentials(providers.enabledProviders).flatMap(\.models))
    }

    /// 纯函数：单选了且还在启用卡里 → 它；否则 → 提取模型
    static func resolve(choice: String, memoryModel: ProviderModel, available: [ProviderModel]) -> ProviderModel {
        guard !choice.isEmpty, let m = available.first(where: { $0.id == choice }) else { return memoryModel }
        return m
    }
}

// MARK: - 一次性迁移

extension MemoryFlags {
    /// v5 拆键：A3 写、【开窗口】A2 / A4 的勾没写过时，按今天的老键定下来（升级后行为不变；之后各管各的）。只跑一次
    static func migrateV5SplitIfNeeded(defaults: UserDefaults = .standard) {
        let sentinel = "mem_v5_split_v1"
        guard !defaults.bool(forKey: sentinel) else { return }
        let summary = (defaults.object(forKey: "mem_content_summary") as? Bool) ?? true
        let timeline = (defaults.object(forKey: "mem_content_timeline") as? Bool) ?? true
        if defaults.object(forKey: "mem_write_a3") == nil { defaults.set(summary, forKey: "mem_write_a3") }
        if defaults.object(forKey: MemoryOpenWindow.a2Key) == nil { defaults.set(summary, forKey: MemoryOpenWindow.a2Key) }
        if defaults.object(forKey: MemoryOpenWindow.a4Key) == nil { defaults.set(timeline, forKey: MemoryOpenWindow.a4Key) }
        defaults.set(true, forKey: sentinel)
    }

    /// 11-15「每轮全带」从老开关里拆出来：改之前实际在全带的楼层（聊到才带关 + wiki 目录勾着 + 全量注入开着）勾上，
    /// 其余不写；之后这一项只听它自己。老键一个不动、不删。只跑一次
    static func migrateEveryRoundIfNeeded(profileIds: [String], defaults: UserDefaults = .standard) {
        let sentinel = "mem_every_round_split_v1"
        guard !defaults.bool(forKey: sentinel) else { return }
        if (defaults.object(forKey: "mem_inject_full") as? Bool) ?? true {
            for id in profileIds where MemoryOpenWindowStore.load(key: MemoryOpenWindow.everyRoundKey, profileId: id, defaults: defaults) == nil
                && MemoryOpenWindow.isChecked(.c, profileId: id, defaults: defaults)
                && !RecallTuningStore.load(profileId: id, defaults: defaults).archiveTriggerEnabled {
                MemoryOpenWindow.setEveryRound(true, profileId: id, defaults: defaults)
            }
        }
        defaults.set(true, forKey: sentinel)
    }
}
