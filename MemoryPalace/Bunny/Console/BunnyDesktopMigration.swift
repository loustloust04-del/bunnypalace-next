import Foundation

// MARK: - [Bunny patch BP-007] 老用户桌面补「Caelum's Console」图标（只跑一次，只在缺的时候加）
//
// 工具表会自动补新内置工具，但粟粟桌面另存图标布局：独立桌面名单已播种后不会追加，自由桌面已初始化后
// bootstrap 直接返回（GPT T3，audit/gpt/console/T3-upstream-entrypoints.md）。这里两种桌面各补一次，
// 不重置用户的顺序；自由桌面若还没有任何页（未初始化）就不标记完成，下次再试。

@MainActor
enum BunnyDesktopMigration {
    /// 每个兔兔 App 各补一次（各自的完成标记）
    static let apps: [(toolId: String, doneKey: String)] = [
        ("bunnyConsole", "bunny.desktop.consoleIcon.v1"),
        ("bunnyMusic", "bunny.desktop.musicIcon.v1"),
        (RightPanelToolManager.gardenOSToolId, "bunny.desktop.settingsIcon.v1"),   // 设置 App：老桌面可能没摆
    ]

    static func runIfNeeded(tools: RightPanelToolManager) {
        for app in apps where !UserDefaults.standard.bool(forKey: app.doneKey) {
            Page2DesktopManager.shared.addToDesktop(app.toolId, tm: tools)   // 已在名单里则什么都不做
            let home = Page2HomeStore.shared
            guard let board = home.layout.boards.first else { return }   // 自由桌面未初始化：下次再来
            let exists = home.layout.items.contains { $0.kind == "app" && $0.toolID == app.toolId }
            if !exists, !home.insert(.app(app.toolId), capacity: board.capacityKey) { continue }   // 落盘失败：下次再来
            UserDefaults.standard.set(true, forKey: app.doneKey)
        }
    }
}
