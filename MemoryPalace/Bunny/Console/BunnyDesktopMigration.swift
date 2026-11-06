import Foundation

// MARK: - [Bunny patch BP-007] 老用户桌面补「Caelum's Console」图标（只跑一次，只在缺的时候加）
//
// 工具表会自动补新内置工具，但粟粟桌面另存图标布局：独立桌面名单已播种后不会追加，自由桌面已初始化后
// bootstrap 直接返回（GPT T3，audit/gpt/console/T3-upstream-entrypoints.md）。这里两种桌面各补一次，
// 不重置用户的顺序；自由桌面若还没有任何页（未初始化）就不标记完成，下次再试。

@MainActor
enum BunnyDesktopMigration {
    static let doneKey = "bunny.desktop.consoleIcon.v1"
    static let toolId = "bunnyConsole"

    static func runIfNeeded(tools: RightPanelToolManager) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        Page2DesktopManager.shared.addToDesktop(toolId, tm: tools)   // 已在名单里则什么都不做
        let home = Page2HomeStore.shared
        guard let board = home.layout.boards.first else { return }   // 自由桌面未初始化：下次再来
        let exists = home.layout.items.contains { $0.kind == "app" && $0.toolID == toolId }
        if !exists, !home.insert(.app(toolId), capacity: board.capacityKey) { return }   // 落盘失败：下次再来
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
