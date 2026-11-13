#if PERSONAL_APPS
#if os(iOS)
import Foundation

/// Uses actual placed desktop and dock entries; callers provide the existing mode gate.
enum TutuWuEntrySelection {
    // Legacy stitch has an app grid and a fixed vocabulary entry, but no live dock.
    // Classic Dashboard widgets present their own content, not Page2 app routes.
    static func legacyTools(presentation: String, desktopIDs: [String], tools: [RightPanelTool]) -> [RightPanelTool] {
        guard presentation == "stitch" else { return [] }
        var emitted = Set<String>()
        return (["vocab"] + desktopIDs).compactMap { id in
            guard emitted.insert(id).inserted else { return nil }
            return tools.first { $0.id == id }
        }
    }

    static func tools(layout: Page2Layout, board: Page2Board, tools: [RightPanelTool], visible: (RightPanelTool) -> Bool) -> [RightPanelTool] {
        let roots = board.pages.filter { !$0.isHidden }.flatMap { page in
            board.placements.filter { $0.pageID == page.id }.sorted {
                $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
            }.map(\.id)
        } + (layout.dockItemIDs ?? [])
        var visited = Set<UUID>(), emitted = Set<String>(), result: [RightPanelTool] = []
        func visit(_ id: UUID) {
            guard visited.insert(id).inserted, let item = layout.item(id) else { return }
            if item.isContainer { item.children.forEach(visit); return }
            guard let toolID = item.toolID, let tool = tools.first(where: { $0.id == toolID }),
                  tool.isEnabled, visible(tool), emitted.insert(toolID).inserted else { return }
            result.append(tool)
        }
        roots.forEach(visit)
        return result
    }
}
#endif
#endif
