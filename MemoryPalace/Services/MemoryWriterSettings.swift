import Foundation

/// 记忆 v5 的写入编号（`记忆系统v5.md` §1）：A 对话一层层往下压 / B {助手}自己的主观 / C 客观事实。
/// 设置页「写入 · 记什么」一个编号一行，点进去是这一项的二级页
enum MemoryWriterID: String, CaseIterable, Identifiable {
    case a2, a3, a4, b1, b2, b3, b4, c, c2, c3

    var id: String { rawValue }
    var code: String { rawValue.uppercased() }

    /// 还没做（照样列出，标「还没做」）
    var isTodo: Bool { [.b2, .b3].contains(self) }
    /// 有开关（C 只是看；还没做的没有）
    var hasSwitch: Bool { !isTodo && self != .c }
    /// 后台写手：算写入预算、有自己的模型 / 触发（B1 / B4 是{助手}本人调工具，不算）
    var isBackground: Bool { [.a2, .a3, .a4, .c2, .c3].contains(self) }
    /// 触发三选一（停 N 分钟 / 每 N 回合 / 只手动）；A4 一天一条固定过了 05:00 拼前一天
    var hasTrigger: Bool { [.a2, .a3].contains(self) }

    func title(assistant: String) -> String {
        switch self {
        case .a2: return "上下文摘要"
        case .a3: return "窗口总结"
        case .a4: return "时间轴"
        case .b1: return "心声"
        case .b2: return "\(assistant)日记"
        case .b3: return "做梦"
        case .b4: return "\(assistant)的记忆"
        case .c: return "档案"
        case .c2: return "碎片池"
        case .c3: return "整理编目"
        }
    }

    /// 列表行的一句话（小样原文）；还没做的写「还没做」
    func subtitle(assistant: String) -> String {
        switch self {
        case .a2: return "挤出视野的一段段记下"
        case .a3: return "一个窗口再压成约 \(MemoryWriterSettings.a3Chars) 字"
        case .a4: return "一天一条，跨所有窗口"
        case .b1: return "\(assistant)聊到触动处写独白"
        case .b4: return "\(assistant)自己记、改、划掉的"
        case .c: return "关键词 + 原文"
        case .c2: return "小模型填表，格式不对不收"
        case .c3: return "碎片和聊天整理成 wiki 页，先过目再写"
        case .b2, .b3: return "还没做"
        }
    }

    /// 状态卡 / 日志里用的健康种类（后台写手才有）
    var health: MemoryHealthStore.Kind? {
        switch self {
        case .a2: return .context
        case .a3: return .summary
        case .a4: return .timeline
        case .c2: return .extract
        default: return nil
        }
    }

    init?(health: MemoryHealthStore.Kind) {
        switch health {
        case .context: self = .a2
        case .summary: self = .a3
        case .timeline: self = .a4
        case .extract: self = .c2
        case .dream: return nil
        }
    }
}

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

    /// A3 约多少字
    static var a3Chars: Int {
        let v = UserDefaults.standard.integer(forKey: "mem_a3_chars")
        return v > 0 ? v : 300
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

/// 按勾走、对所有窗口每一轮生效。新键没写过 = 今天的值（A2 跟 `mem_content_summary`、A4 跟 `mem_content_timeline`），
/// 默认下各段逐字和今天一样。带不带 = 总开关 && 这一勾（对话记忆开关照今天各段自己的口径）
enum MemoryOpenWindow {
    static let a2Key = "mem_open_a2"
    static let a4Key = "mem_open_a4"
    static let b4Key = "mem_open_b4"
    static let cKey = "mem_open_c"

    static func isChecked(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> Bool {
        switch id {
        case .a2: return (defaults.object(forKey: a2Key) as? Bool) ?? ((defaults.object(forKey: "mem_content_summary") as? Bool) ?? true)
        case .a4: return (defaults.object(forKey: a4Key) as? Bool) ?? ((defaults.object(forKey: "mem_content_timeline") as? Bool) ?? true)
        case .b4: return (defaults.object(forKey: b4Key) as? Bool) ?? true
        // C 没写过 = 不勾（粟粟 10-16：等 C3 整理好再开）；点过勾 / 导入过的键里有值，照旧
        case .c: return (defaults.object(forKey: cKey) as? Bool) ?? false
        default: return false
        }
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

    /// 总开关 && 这一勾
    static func injects(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> Bool {
        ((defaults.object(forKey: "mem_master") as? Bool) ?? true) && isChecked(id, defaults: defaults)
    }

    /// 二级页里列的（A3 不注入、B1 是工具，都不列）
    static let rows: [MemoryWriterID] = [.a2, .a4, .b4, .c]
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

    /// 默认：A2 每 N 回合（= 今天）；A3 / A4 停 12 小时
    static func mode(_ id: MemoryWriterID, defaults: UserDefaults = .standard) -> MemoryTriggerMode {
        defaults.string(forKey: modeKey(id)).flatMap(MemoryTriggerMode.init(rawValue:)) ?? (id == .a2 ? .rounds : .idle)
    }

    static func defaultIdleMinutes(_ id: MemoryWriterID) -> Int { id == .a2 ? 60 : 720 }
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
