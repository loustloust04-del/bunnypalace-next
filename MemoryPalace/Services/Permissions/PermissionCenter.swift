import Foundation
import SwiftData

// MARK: - 档位

/// 三档权限（plan-权限管理 §2，OpenMinis 同构）。
/// rawValue 落 UserDefaults `perm.<domain>`；缺省回落 descriptor 的 defaultLevel。
enum PermissionLevel: Int, CaseIterable, Identifiable {
    case bypass = 0      // 自动允许（= 旧「开」）
    case askOnce = 1     // 每次询问（per 对话问一次）
    case notAllowed = 2  // 不允许（= 旧「关」；工具被调时返回 permission_denied）

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .bypass: return "自动允许"
        case .askOnce: return "每次询问"
        case .notAllowed: return "不允许"
        }
    }
    var iconName: String {
        switch self {
        case .bypass: return "checkmark.circle"
        case .askOnce: return "questionmark.circle"
        case .notAllowed: return "nosign"
        }
    }
}

// MARK: - 域

/// 权限域（plan-权限管理 §1）。三档域新增 `perm.<rawValue>` 为真相源，旧 Bool key 只做迁移源；
/// 二值域（自主行为类）不加新 key，适配器直通旧闸（askOnce 对无对话语境的后台行为无意义）。
enum PermissionDomain: String, CaseIterable, Identifiable {
    // 注入类（AI 能看什么）—— 三档
    case healthApple, healthWeight, healthMeds, healthCycle, healthIntimacy
    case memory, images, fileLibrary
    // 话题盒只进粟粟的 Debug 包（#096）
    // 工具类（AI 能做什么）—— 三档
    case toolsMaster, webSearch, voiceProactive, pocket
    // 设备工具（plan-设备工具 P1）：三档；notifications 两档（AI 主动打扰，无对话语境）
    case calendar, reminders, clipboard, notifications
    // 本地推特（page2 推特子应用）：AI 在本楼层的推特上发推、刷推；纯本地、不碰真 X，默认允许
    case twitter
    // 运行命令（plan-离线沙箱 phase1/phase2）：macOS 原生 shell / iOS app 内 Alpine 沙箱；默认 askOnce（粟粟拍）
    case shell
    #if os(macOS)
    // 编程会话（W-N N5 AI 工具，mac only）：读这台 Mac 上编程 agent 的会话记录；默认不允许
    case codingSessions
    #endif

    var id: String { rawValue }
    var storageKey: String { "perm.\(rawValue)" }

    /// 迁移源：旧 Bool key + 旧代码默认（迁移时"无显式值的老装机"按它写档位，保行为不变）。
    var legacy: (key: String, oldDefault: Bool) {
        switch self {
        case .healthApple: return ("health.injectionEnabled", true)
        case .healthWeight: return ("health.inject.weight", true)
        case .healthMeds: return ("health.inject.meds", true)
        case .healthCycle: return ("health.inject.cycle", false)
        case .healthIntimacy: return ("health.inject.intimacy", false)
        case .memory: return ("mem_master", true)
        case .images: return ("sendImagesToModel", true)
        case .fileLibrary: return ("fileLibraryEnabled", true)
        case .toolsMaster: return ("sendToolsEnabled", true)
        case .webSearch: return ("webSearchEnabled", false)
        case .voiceProactive: return ("voice_proactive_enabled", false)
        case .pocket: return ("pocketEnabled", false)
        // 设备工具新域：无历史 key，旧默认 false（老装机迁移写 notAllowed，与新默认一致——新能力默认关）
        case .calendar: return ("deviceTools.calendar", false)
        case .reminders: return ("deviceTools.reminders", false)
        case .clipboard: return ("deviceTools.clipboard", false)
        case .notifications: return ("deviceTools.notifications", false)
        case .shell: return ("deviceTools.shell", false)
        case .twitter: return ("twitter.aiTool", true)   // 无历史 key；新能力纯本地，老装机迁移也写允许
        #if os(macOS)
        case .codingSessions: return ("codingTools.enabled", false)
        #endif
        }
    }

    /// 新装默认档（§4 收紧：健康组全关；其余映射旧默认）。
    var defaultLevel: PermissionLevel {
        switch self {
        case .healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy,
             .webSearch, .voiceProactive, .pocket,
             .calendar, .reminders, .clipboard, .notifications:
            return .notAllowed
        case .memory, .images, .fileLibrary, .toolsMaster, .twitter:
            return .bypass
        case .shell:
            return .askOnce   // 每对话首次弹卡问一次（粟粟 08-25 拍）
        #if os(macOS)
        case .codingSessions:
            return .notAllowed   // 母 plan W-N：AI 工具默认关
        #endif
        }
    }

    var displayName: String {
        switch self {
        case .healthApple: return "苹果健康"
        case .healthWeight: return "体重记录"
        case .healthMeds: return "用药记录"
        case .healthCycle: return "月经周期"
        case .healthIntimacy: return "亲密记录"
        case .memory: return "记忆"
        case .images: return "历史图片"
        case .fileLibrary: return "文件库"
        case .toolsMaster: return "工具调用"
        case .webSearch: return "联网搜索"
        case .voiceProactive: return "主动语音"
        case .pocket: return "遥控浏览器"
        case .calendar: return "日历"
        case .reminders: return "提醒事项"
        case .clipboard: return "剪贴板"
        case .notifications: return "发通知"
        case .shell: return "运行命令"
        case .twitter: return "推特"
        #if os(macOS)
        case .codingSessions: return "编程会话"
        #endif
        }
    }

    /// Minis 式一句话说明（只描述开了会发生什么——设置副文案老规矩）。
    var summary: String {
        switch self {
        case .healthApple: return "步数、睡眠、心率等今日摘要随对话发给 AI"
        case .healthWeight: return "近期体重记录随对话发给 AI"
        case .healthMeds: return "用药计划与今日打卡随对话发给 AI"
        case .healthCycle: return "周期阶段与预测随对话发给 AI"
        case .healthIntimacy: return "当天是否有亲密记录随对话发给 AI（不含备注）"
        case .memory: return "楼层记忆参与注入与提取"
        case .images: return "历史消息里的图片作为附件发给 AI"
        case .fileLibrary: return "AI 可读写文件库（含资料卡）"
        case .toolsMaster: return "请求携带工具，AI 可以调用"
        case .webSearch: return "AI 可搜索网页并读取链接"
        case .voiceProactive: return "AI 可主动发语音条"
        case .pocket: return "Claude Code 可遥控内置浏览器（开页/截图/读页面）"
        case .calendar: return "AI 可查看、创建、删除系统日历事件"
        case .reminders: return "AI 可查看、创建、完成系统提醒事项"
        case .clipboard: return "AI 可读取剪贴板内容（文本/链接/图片）"
        case .notifications: return "AI 可给你发本地通知"
        case .twitter: return "AI 可在本楼层的推特上发推、回复、点赞、关注和刷时间线（纯本地，不碰真 X）"
        case .shell:
            // 文案按平台分：macOS 是真机器上的 shell（零隔离），iOS 是 app 内的 Linux 沙箱
            #if os(macOS)
            return "AI 可在这台 Mac 上运行 shell 命令（默认在文件库目录里，会真实改动文件）"
            #else
            return "AI 可在 app 内的 Linux 沙箱里运行命令（碰不到沙箱外的东西）"
            #endif
        #if os(macOS)
        case .codingSessions: return "AI 可搜索、读取这台 Mac 上编程 agent 的会话记录（内容会发给当前模型并存进对话）"
        #endif
        }
    }

    /// 该工具调用属于哪个域（T5 调用时检查；不在表内的按 toolsMaster 兜底）。
    static func forTool(named name: String) -> PermissionDomain {
        if name.hasPrefix("fs_") || name == "update_profile_card" { return .fileLibrary }
        if name == "search_web" || name == "browse_url" { return .webSearch }
        if name.hasPrefix("calendar_") { return .calendar }
        if name.hasPrefix("reminders_") { return .reminders }
        if name == "clipboard_read" { return .clipboard }
        if name == "notify_schedule" { return .notifications }
        if name == "run_command" { return .shell }
        if name == "local_twitter" { return .twitter }   // 🔴 绝不能落进 toolsMaster 兜底（默认 bypass = shell 裸奔）
        #if os(macOS)
        // 精确四名，不按前缀：MCP 工具以原名下发，同前缀的 code_review 之类不能被劫持进这个域
        if CodingTools.names.contains(name) { return .codingSessions }
        #endif
        return .toolsMaster   // ocr_image / open_url / device_info：system 类，只随工具总开关
    }

    static var injectionDomains: [PermissionDomain] {
        var domains: [PermissionDomain] = [.healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy,
                                           .memory, .images, .fileLibrary]
        #if os(macOS)
        domains.append(.codingSessions)
        #endif
        return domains
    }
    static var toolDomains: [PermissionDomain] { [.toolsMaster, .webSearch, .voiceProactive, .pocket, .calendar, .reminders, .clipboard, .notifications, .shell, .twitter] }
}

// MARK: - 中心

/// 域级读写适配器（plan-权限管理 §1）：档位真相源 + per 对话 askOnce 授权判定。
/// 副作用类写路径（单例缓存/WS 帧）由 `setLevel` 统一触发，权限页与原 tab 都必须走这里。
enum PermissionCenter {

    private static var d: UserDefaults { .standard }

    // MARK: 档位读写

    static func level(_ domain: PermissionDomain) -> PermissionLevel {
        guard let raw = d.object(forKey: domain.storageKey) as? Int,
              let l = PermissionLevel(rawValue: raw) else { return domain.defaultLevel }
        return l
    }

    /// 唯一合法写入口。同步旧 key 投影（bypass→true / 其余→false）喂还没改造完的读点与单例缓存。
    static func setLevel(_ level: PermissionLevel, for domain: PermissionDomain) {
        d.set(level.rawValue, forKey: domain.storageKey)
        let projected = (level == .bypass)
        d.set(projected, forKey: domain.legacy.key)
        // 单例缓存域：直写 defaults 不改运行态（verify 挑刺 #2），必须踢缓存
        switch domain {
        case .healthApple:
            HealthService.shared.injectionEnabled = projected
        default:
            break
        }
    }

    // MARK: 判定（组装/下发路径用）

    /// 纯档位判定（不含 askOnce 授权语境）：schema 下发、hint 注入等"要不要给能力"用。
    /// askOnce 视为"给能力"（工具下发、真调用时再问）。
    static func capabilityEnabled(_ domain: PermissionDomain) -> Bool {
        level(domain) != .notAllowed
    }

    /// 注入判定：bypass 直过；askOnce 看该对话的授权记录，**无记录 = 不注入**
    /// （ask 只发生在交互发送路径；后台组装路径拿不到授权就安全缺省，见 plan §2）。
    static func injectionAllowed(_ domain: PermissionDomain, grants: PermissionGrants) -> Bool {
        switch level(domain) {
        case .bypass: return true
        case .notAllowed: return false
        case .askOnce: return grants.isAllowed(domain)
        }
    }

    // MARK: 一次性迁移（plan §4；MemoryFlags sentinel 同款）

    /// 老装机判定 + 旧 Bool → 档位。displayed 逻辑：
    /// - 旧 key 有显式值 → 开=bypass / 关=notAllowed
    /// - 无显式值且是老装机（库里有对话）→ 按旧代码默认写（行为不变）
    /// - 无显式值且是新装 → 不写，descriptor 新默认生效（§4 收紧）
    static func migrateIfNeeded(container: ModelContainer) {
        let sentinel = "perm_migrated_v1"
        guard !d.bool(forKey: sentinel) else { return }
        let convCount = (try? ModelContext(container).fetchCount(FetchDescriptor<Conversation>())) ?? 0
        let existingInstall = convCount > 0
        for domain in PermissionDomain.allCases {
            guard d.object(forKey: domain.storageKey) == nil else { continue }
            // shell 无历史 key，老装机也按新默认 askOnce 走（粟粟拍）；不写 notAllowed
            if domain == .shell { continue }
            if let explicit = d.object(forKey: domain.legacy.key) as? Bool {
                d.set((explicit ? PermissionLevel.bypass : .notAllowed).rawValue, forKey: domain.storageKey)
            } else if existingInstall {
                d.set((domain.legacy.oldDefault ? PermissionLevel.bypass : .notAllowed).rawValue, forKey: domain.storageKey)
                d.set(domain.legacy.oldDefault, forKey: domain.legacy.key)
            }
        }
        // §4 二值域默认收紧（nudge/夜跑），同款保护：老装机无显式值 → 写入旧默认 true
        if existingInstall {
            for (key, oldDefault) in [("ccNudgeEnabled", true)] where d.object(forKey: key) == nil {
                d.set(oldDefault, forKey: key)
            }
        }
        d.set(true, forKey: sentinel)
    }
}

// MARK: - per 对话授权

/// askOnce 的对话级授权快照。存于 `Conversation.permGrantsRaw`（"domain:allow,domain:deny" 逗号串——
/// SwiftData 加最简字段，参照 agentOrigin 先例）。值类型快照可安全带进后台组装。
struct PermissionGrants: Sendable, Equatable {
    private var allowed: Set<String> = []
    private var denied: Set<String> = []

    init(raw: String?) {
        for part in (raw ?? "").split(separator: ",") {
            let bits = part.split(separator: ":")
            guard bits.count == 2 else { continue }
            let domain = String(bits[0])
            if bits[1] == "allow" { allowed.insert(domain) } else if bits[1] == "deny" { denied.insert(domain) }
        }
    }

    /// 只在本设备有效的域（shell = 这台机器的 shell / 这台设备的沙箱）：跨设备导入时剥掉，别让另一台机器免问放行。
    /// codingSessions = 这台 Mac 上的编程会话（mac only 的域，这里写字面量两端都能编）
    static let deviceLocalDomains: Set<String> = [PermissionDomain.shell.rawValue, "codingSessions"]

    static func strippingDeviceLocal(_ raw: String?) -> String {
        (raw ?? "").split(separator: ",")
            .filter { part in !deviceLocalDomains.contains(String(part.split(separator: ":").first ?? "")) }
            .joined(separator: ",")
    }

    func isAllowed(_ domain: PermissionDomain) -> Bool { allowed.contains(domain.rawValue) }
    func isResolved(_ domain: PermissionDomain) -> Bool {
        allowed.contains(domain.rawValue) || denied.contains(domain.rawValue)
    }

    mutating func record(_ domain: PermissionDomain, allow: Bool) {
        denied.remove(domain.rawValue); allowed.remove(domain.rawValue)
        if allow { allowed.insert(domain.rawValue) } else { denied.insert(domain.rawValue) }
    }

    var raw: String {
        (allowed.sorted().map { "\($0):allow" } + denied.sorted().map { "\($0):deny" }).joined(separator: ",")
    }

    static let empty = PermissionGrants(raw: nil)
}
