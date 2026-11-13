import MemoryCore
import Foundation


/// 写入那一行的开关（和二级页顶上的开关同一个键）。不含总开关
enum MemoryWriterSettings {
    /// 能拨的（滑条只动这些）
    static let switchable: [MemoryWriterID] = [.a2, .a3, .a4, .b1, .b4, .c2]

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

    /// 没写过的默认（= 今天新装的默认，滑条落「中」；C3 同 C2 默认开）。A3 没写过跟老键 `mem_content_summary`（拆开前 A2 / A3 一个开关）
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

// MARK: - 复杂度滑条（plan §五）

/// 不存值：位置由写入开关算出来；拖一档 = 改一组开关；对不上 = 自定义（nil）
enum MemoryComplexity {
    static let names = ["0", "轻", "中", "重"]
    static let levels: [Set<MemoryWriterID>] = [
        [.a2],
        [.a2, .a4],
        [.a2, .a3, .a4, .b4, .c2],
        [.a2, .a3, .a4, .b1, .b4, .c2],
    ]

    static func level(on: Set<MemoryWriterID>) -> Int? {
        levels.firstIndex(of: on.intersection(MemoryWriterSettings.switchable))
    }

    static func onSet(defaults: UserDefaults = .standard) -> Set<MemoryWriterID> {
        Set(MemoryWriterSettings.switchable.filter { MemoryWriterSettings.isOn($0, defaults: defaults) })
    }

    static func current(defaults: UserDefaults = .standard) -> Int? {
        level(on: onSet(defaults: defaults))
    }

    static func apply(_ level: Int, defaults: UserDefaults = .standard) {
        guard levels.indices.contains(level) else { return }
        for id in MemoryWriterSettings.switchable {
            MemoryWriterSettings.set(id, levels[level].contains(id), defaults: defaults)
        }
    }

    /// 「中 · 开 5 项」/「自定义 · 开 4 项」
    static func summary(defaults: UserDefaults = .standard) -> String {
        let on = onSet(defaults: defaults)
        let name = level(on: on).map { names[$0] } ?? "自定义"
        return "\(name) · 开 \(on.count) 项"
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
}
