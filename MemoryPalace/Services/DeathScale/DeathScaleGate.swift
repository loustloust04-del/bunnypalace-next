#if PERSONAL_APPS
import Foundation

/// 解锁 / 设置开关的副作用收在一处：启用状态 + iOS 桌面图标 / mac Dock 图标。数据从不在这里删
@MainActor
enum DeathScaleGate {
    static let toolId = "deathScale"
    static let unlockedKey = "deathScale.unlocked"

    static func unlock(profileId: String?, tools: RightPanelToolManager?) {
        UserDefaults.standard.set(true, forKey: unlockedKey)
        if let profileId { DeathScaleStore.shared.grantRead(profileId) }
        setVisible(true, tools: tools)
    }

    static func setVisible(_ on: Bool, tools: RightPanelToolManager?) {
        tools?.setEnabled(toolId, on)
        #if os(iOS)
        let home = Page2HomeStore.shared
        let placed = home.layout.items.filter { $0.kind == "app" && $0.toolID == toolId }.map(\.id)
        if on {
            // 桌面还没初始化：bootstrap 会按 pinnedTools 把它带上，这里不抢先写档
            if home.isInitialized, placed.isEmpty {
                _ = home.insert(.app(toolId), capacity: home.layout.boards.first?.capacityKey ?? "")
            }
            // 针脚桌面编辑过（成员表已播种）就不再跟 pinnedTools 走，得显式摆上；关掉时按 isEnabled 自动藏，不除名
            if let tools, Page2DesktopManager.shared.desktopAppIds != nil {
                Page2DesktopManager.shared.addToDesktop(toolId, tm: tools)
            }
        } else {
            placed.forEach(home.remove)
            if IPadPanelLayout.shared.isOpen(toolId) { IPadPanelLayout.shared.close(toolId) }
        }
        #else
        let prefs = MacWorkspacePreferences.shared
        let seed = Page2DesktopManager.shared.dockToolIds ?? tools?.pinnedTools.map(\.id) ?? []
        if on {
            prefs.addTool(toolId, seed: seed)
        } else {
            prefs.remove(MacWorkspacePreferences.DockItem.tool(toolId).id, seed: seed)
            if IPadPanelLayout.shared.isOpen(toolId) { IPadPanelLayout.shared.close(toolId) }
        }
        #endif
    }
}
#endif
