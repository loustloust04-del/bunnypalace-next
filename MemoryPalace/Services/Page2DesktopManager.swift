import Foundation

/// Page 2 布局管理器：iOS dock 与新桌面网格各自独立的成员+顺序（mac 逻辑：
/// dock 放常用，桌面放桌面的，设置页 isEnabled 是全局总开关）。
/// 未播种（nil）时跟随 pinnedTools 现状；首次编辑时快照播种，此后各编各的。
/// 渲染时按 isEnabled 过滤：设置页关掉的工具隐身不除名，重开自动回来。
@MainActor
@Observable
final class Page2DesktopManager {
    static let shared = Page2DesktopManager()
    private static let desktopKey = "page2DesktopApps_v1"
    private static let dockKey = "page2DockTools_v1"

    @ObservationIgnored private var dockObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private(set) var desktopAppIds: [String]?
    private(set) var dockToolIds: [String]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        desktopAppIds = defaults.stringArray(forKey: Self.desktopKey)
        dockToolIds = defaults.stringArray(forKey: Self.dockKey)
        dockObserver = NotificationCenter.default.addObserver(forName: Notification.Name("page2DockLayoutChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dockToolIds = self.defaults.stringArray(forKey: Self.dockKey)
            }
        }
    }

    deinit { if let dockObserver { NotificationCenter.default.removeObserver(dockObserver) } }

    // MARK: - 读取口（view 只用这两个）

    func desktopTools(_ tm: RightPanelToolManager) -> [RightPanelTool] {
        resolve(desktopAppIds, tm: tm)
    }

    func dockTools(_ tm: RightPanelToolManager) -> [RightPanelTool] {
        resolve(dockToolIds, tm: tm)
    }

    func isInDock(_ id: String, tm: RightPanelToolManager) -> Bool {
        dockTools(tm).contains { $0.id == id }
    }

    private func resolve(_ ids: [String]?, tm: RightPanelToolManager) -> [RightPanelTool] {
        guard let ids else { return tm.pinnedTools }
        return ids.compactMap { id in
            // isEnabled = 用户存档开关；isVisibleInCurrentMode = lite 白名单（不动存档）
            guard let tool = tm.tool(byId: id), tool.isEnabled, tm.isVisibleInCurrentMode(tool) else { return nil }
            return tool
        }
    }

    // MARK: - 桌面三件套

    func addToDesktop(_ id: String, tm: RightPanelToolManager) {
        var ids = seededDesktop(tm)
        guard !ids.contains(id) else { return }
        ids.append(id)
        setDesktop(ids)
    }

    func removeFromDesktop(_ id: String, tm: RightPanelToolManager) {
        var ids = seededDesktop(tm)
        ids.removeAll { $0 == id }
        setDesktop(ids)
    }

    func moveDesktopApp(_ fromId: String, before toId: String, tm: RightPanelToolManager) {
        setDesktop(moved(seededDesktop(tm), fromId: fromId, before: toId))
    }

    // MARK: - dock 三件套

    func addToDock(_ id: String, tm: RightPanelToolManager) {
        var ids = seededDock(tm)
        guard !ids.contains(id) else { return }
        ids.append(id)
        setDock(ids)
    }

    func removeFromDock(_ id: String, tm: RightPanelToolManager) {
        var ids = seededDock(tm)
        ids.removeAll { $0 == id }
        setDock(ids)
    }

    func moveDock(_ fromId: String, before toId: String, tm: RightPanelToolManager) {
        setDock(moved(seededDock(tm), fromId: fromId, before: toId))
    }

    // MARK: - 播种 / 持久化

    private func seededDesktop(_ tm: RightPanelToolManager) -> [String] {
        desktopAppIds ?? tm.pinnedTools.map(\.id)
    }

    private func seededDock(_ tm: RightPanelToolManager) -> [String] {
        dockToolIds ?? tm.pinnedTools.map(\.id)
    }

    private func setDesktop(_ ids: [String]) {
        desktopAppIds = ids
        defaults.set(ids, forKey: Self.desktopKey)
    }

    private func setDock(_ ids: [String]) {
        dockToolIds = ids
        defaults.set(ids, forKey: Self.dockKey)
    }

    private func moved(_ list: [String], fromId: String, before toId: String) -> [String] {
        guard fromId != toId, let from = list.firstIndex(of: fromId) else { return list }
        var ids = list
        let item = ids.remove(at: from)
        if let to = ids.firstIndex(of: toId) {
            ids.insert(item, at: to)
        } else {
            ids.append(item)
        }
        return ids
    }
}
