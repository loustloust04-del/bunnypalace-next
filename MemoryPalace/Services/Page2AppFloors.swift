import Foundation

/// page2 装了哪些 App 按层（atrium P3⑥，plan-atrium-p3-page2 §1）：`rightPanelTools` 原样当「默认」，
/// 这里只记「谁单独装卸了什么」，存 UserDefaults `page2.apps.floors.v1`（照 `PermissionFloors`）。
/// 键用字符串：内置表随编译条件变，Debug 包存的话题盒到 Release 认不出也原样留着。每台设备各记各的，不进 config 文件。
struct Page2AppFloors: Codable, Equatable {
    /// profileId → toolId → 装 / 不装；只存单独改过的
    var floors: [String: [String: Bool]] = [:]

    var isEmpty: Bool { floors.isEmpty }

    /// 这一层单独改的；nil = 跟默认
    func stored(_ toolId: String, profileId: String) -> Bool? {
        floors[profileId]?[toolId]
    }

    /// nil = 删这条；层空了删整层
    mutating func set(_ installed: Bool?, for toolId: String, profileId: String) {
        var floor = floors[profileId] ?? [:]
        floor[toolId] = installed
        floors[profileId] = floor.isEmpty ? nil : floor
    }

    mutating func clear(profileId: String) {
        floors[profileId] = nil
    }

    mutating func clear(toolId: String) {
        for pid in floors.keys {
            floors[pid]?[toolId] = nil
            if floors[pid]?.isEmpty == true { floors[pid] = nil }
        }
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// nil 数据 = 空；解不开 = nil（调用方：读当空，写拒写不覆盖）
    static func decoded(_ data: Data?) -> Page2AppFloors? {
        guard let data else { return Page2AppFloors() }
        return try? JSONDecoder().decode(Page2AppFloors.self, from: data)
    }
}

/// 「装没装」的唯一读法（非 MainActor，AI 门控 / 后台组装也能读）。默认 = `rightPanelTools` 存档 × 内置表；
/// 层 = `page2.apps.floors.v1`。只有这里写 `page2.apps.floors.v1`；`rightPanelTools` 只由 `RightPanelToolManager` 写默认。
enum Page2Apps {
    static let floorsKey = "page2.apps.floors.v1"

    /// 测试换成 suite，tearDown 换回
    static var defaults: UserDefaults = .standard {
        didSet { cacheLock.withLock { floorsCache = nil; defaultsCache = nil } }
    }

    // MARK: 读

    /// 默认装没装 = 存档 × 内置表（merged 后的 isEnabled）；认不出的 id → false；系统 App 恒 true（atrium P4）
    static func defaultInstalled(_ toolId: String) -> Bool {
        if RightPanelToolManager.systemToolIds.contains(toolId) { return true }
        let data = defaults.data(forKey: RightPanelToolManager.storageKey)
        return cacheLock.withLock {
            if let defaultsCache, defaultsCache.data == data { return defaultsCache.installed[toolId] ?? false }
            let installed = Dictionary(RightPanelToolManager.decodedTools(data).map { ($0.id, $0.isEnabled) },
                                       uniquingKeysWith: { first, _ in first })
            defaultsCache = (data, installed)
            return installed[toolId] ?? false
        }
    }

    /// 这一层装没装；`profileId` nil（没有楼层语境）或这一层没单独改 → 默认
    static func isInstalled(_ toolId: String, profileId: String?) -> Bool {
        if RightPanelToolManager.systemToolIds.contains(toolId) { return true }
        if let profileId, let v = floors().stored(toolId, profileId: profileId) { return v }
        return defaultInstalled(toolId)
    }

    /// 这个 App 单独改了的人：profileId → 装 / 不装（楼层存不存在调用方筛）
    static func overrides(_ toolId: String) -> [String: Bool] {
        floors().floors.compactMapValues { $0[toolId] }
    }

    /// 界面 / 拒绝文案里的名字：内置表的名字，认不出的 id 原样
    static func displayName(_ toolId: String) -> String {
        RightPanelToolManager.builtInTools.first { $0.id == toolId }?.name ?? toolId
    }

    // MARK: 层写（⑥a 起：人页「TA 主屏上的 App」、「右栏」页「N 个人单独改了」；P4-b 主屏长按卸载）

    /// nil = 回到跟默认；和默认相同也存成 nil。系统 App 拒写（atrium P4）
    static func setFloor(_ installed: Bool?, for toolId: String, profileId: String) {
        guard !RightPanelToolManager.systemToolIds.contains(toolId) else {
            NSLog("[Page2Apps] 系统 App \(toolId) 恒装，拒写")
            return
        }
        let stored = installed == defaultInstalled(toolId) ? nil : installed
        updateFloors { $0.set(stored, for: toolId, profileId: profileId) }
    }

    /// 主屏长按出不出「给 TA 卸载」：系统 App（恒装）、secret App（不暴露）不出（atrium P4-b §4.3）
    static func canUninstallFromHome(_ toolId: String) -> Bool {
        !RightPanelToolManager.systemToolIds.contains(toolId) && !RightPanelToolManager.secretToolIds.contains(toolId)
    }

    /// 主屏长按「给 TA 卸载」：只收紧、只写这一层；`rightPanelTools`、别的层、布局文件、appearance.json 都不碰。
    /// 装回去走「设置」App 第一节或人页（同一个 `setFloor`）
    static func uninstallFromHome(_ toolId: String, profileId: String) {
        guard !profileId.isEmpty, canUninstallFromHome(toolId) else {
            NSLog("[Page2Apps] 长按卸载拒写：\(toolId) @ \(profileId.isEmpty ? "无楼层" : profileId)")
            return
        }
        setFloor(false, for: toolId, profileId: profileId)
    }

    /// 这个人全部回到跟默认
    static func clearAll(profileId: String) {
        updateFloors { $0.clear(profileId: profileId) }
    }

    /// 这个 App 所有人都回到跟默认
    static func clearFloor(_ toolId: String) {
        updateFloors { $0.clear(toolId: toolId) }
    }

    /// 新建复制：只抄单独改过的（来源跟默认 → 新层也空）
    static func copyFloor(from: String, to: String) {
        updateFloors { $0.floors[to] = $0.floors[from] }
    }

    // MARK: 层存取（读缓存：Data 没变复用上次解出来的值；有后台读者，加锁）

    private static let cacheLock = NSLock()
    private static var floorsCache: (data: Data?, floors: Page2AppFloors)?
    private static var defaultsCache: (data: Data?, installed: [String: Bool])?

    static func floors() -> Page2AppFloors {
        let data = defaults.data(forKey: floorsKey)
        return cacheLock.withLock {
            if let floorsCache, floorsCache.data == data { return floorsCache.floors }
            let decoded = Page2AppFloors.decoded(data)
            if decoded == nil { NSLog("[Page2Apps] \(floorsKey) 解不开，按空读（写入口拒写）") }
            let value = decoded ?? Page2AppFloors()
            floorsCache = (data, value)
            return value
        }
    }

    /// 解不开的数据拒写，不覆盖（plan §6-3）。写 UserDefaults 放在锁外：写会同步发 didChangeNotification，
    /// `RightPanelToolManager` 收到要回头读 `floors()`，锁里写就自己等自己。写入口都在主线程，不会并发写
    private static func updateFloors(_ body: (inout Page2AppFloors) -> Void) {
        guard var next = Page2AppFloors.decoded(defaults.data(forKey: floorsKey)) else {
            NSLog("[Page2Apps] \(floorsKey) 解不开，拒写")
            return
        }
        body(&next)
        let encoded = next.isEmpty ? nil : next.encoded()
        cacheLock.withLock { floorsCache = (encoded, next) }
        if let encoded {
            defaults.set(encoded, forKey: floorsKey)
        } else {
            defaults.removeObject(forKey: floorsKey)
        }
    }
}
