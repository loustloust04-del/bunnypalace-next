import Foundation

/// 权限档位按层（atrium P3⑤，plan-atrium-p3-permissions §1）：`perm.<domain>` 原样当「默认」，
/// 这里只记「谁单独设了什么」，存 UserDefaults `perm.floors.v1`（照工具抽屉 `ToolDrawerState`）。
/// 键用字符串不用枚举：`PermissionDomain` 的 case 随编译条件变，认不出的域 / 档位原样留着，不丢、不报错。
/// 每台设备各记各的，不进 config 文件。
struct PermissionFloors: Codable, Equatable {
    /// profileId → domain rawValue → PermissionLevel rawValue；只存单独设过的
    var floors: [String: [String: Int]] = [:]

    var isEmpty: Bool { floors.isEmpty }

    /// 这一层单独设的档位；nil = 跟默认（没设 / 认不出的档位）
    func stored(_ d: PermissionDomain, profileId: String) -> PermissionLevel? {
        floors[profileId]?[d.rawValue].flatMap(PermissionLevel.init(rawValue:))
    }

    /// nil = 删这条；层空了删整层
    mutating func set(_ l: PermissionLevel?, for d: PermissionDomain, profileId: String) {
        var floor = floors[profileId] ?? [:]
        floor[d.rawValue] = l?.rawValue
        floors[profileId] = floor.isEmpty ? nil : floor
    }

    mutating func clear(profileId: String) {
        floors[profileId] = nil
    }

    mutating func clear(domain: PermissionDomain) {
        for pid in floors.keys {
            floors[pid]?[domain.rawValue] = nil
            if floors[pid]?.isEmpty == true { floors[pid] = nil }
        }
    }

    /// 三类规则（plan §1）：只全局恒 = 默认；只能更严取 max（rawValue 越大越严）；自由 = 层 ?? 默认。
    /// `profileId` nil（没有楼层语境）或这一层没设 → 默认。
    static func resolve(_ d: PermissionDomain, profileId: String?, defaultLevel: PermissionLevel, floors: PermissionFloors) -> PermissionLevel {
        guard let profileId, let l = floors.stored(d, profileId: profileId) else { return defaultLevel }
        switch d.floorRule {
        case .globalOnly: return defaultLevel
        case .stricterOnly: return l.rawValue > defaultLevel.rawValue ? l : defaultLevel
        case .free: return l
        }
    }

    // MARK: 存取（JSON）

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// nil 数据 = 空；解不开 = nil（调用方：读当空，写拒写不覆盖）
    static func decoded(_ data: Data?) -> PermissionFloors? {
        guard let data else { return PermissionFloors() }
        return try? JSONDecoder().decode(PermissionFloors.self, from: data)
    }
}

extension PermissionDomain {
    enum FloorRule: Equatable {
        /// 只在「我」里改，层上有值也不看
        case globalOnly
        /// 层上只能比默认严
        case stricterOnly
        /// 层上可宽可严
        case free
    }

    /// 解析和界面都读它（plan §1 三类表）。逐个列出：新加域必须在这里表态
    var floorRule: FloorRule {
        switch self {
        case .toolsMaster, .pocket, .memory:
            return .globalOnly
        case .shell:
            return .stricterOnly
        #if os(macOS)
        case .codingSessions:
            return .stricterOnly
        #endif
        case .healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy,
             .images, .fileLibrary, .webSearch, .voiceProactive,
             .calendar, .reminders, .clipboard, .notifications, .twitter, .browserOperate:
            return .free
        #if PERSONAL_APPS
        case .trading:
            return .free
        #if DEBUG
        case .topicBox:
            return .free
        #endif
        #endif
        }
    }

    /// 这个域连着 page2 上哪个 App（atrium P3⑥a「主屏有 = 授权」）：这一层没装那个 App → 不允许（`PermissionCenter.level` 的前置门）。
    /// 逐个列出：新加域必须在这里表态；nil = 不受 App 装卸影响
    var page2App: String? {
        switch self {
        case .fileLibrary:
            return "fileLibrary"
        case .twitter:
            return "twitter"
        case .healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy:
            return "health"
        #if PERSONAL_APPS
        case .trading:
            return "trading"
        #if DEBUG
        case .topicBox:
            return "topicBox"
        #endif
        #endif
        case .memory, .images, .toolsMaster, .webSearch, .voiceProactive, .pocket,
             .calendar, .reminders, .clipboard, .notifications, .shell:
            return nil
        case .browserOperate:
            return nil   // AI 要用时从聊天上弹浏览器，不靠主屏装没装浏览器 App
        #if os(macOS)
        case .codingSessions:
            return nil
        #endif
        }
    }
}
