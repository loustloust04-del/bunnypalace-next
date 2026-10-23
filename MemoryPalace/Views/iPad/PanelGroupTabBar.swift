import SwiftUI

/// 面板组里的一个面板（docs/design-panel-system-ps.md §1：面板组 = 一条 tab 栏 + 当前 tab 的内容）。
/// `id` 是面板 id——以后拖 tab 浮出 / 并组时直接当拖放 payload（同右栏工具 tab 的 toolId）。
struct PanelGroupTab: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
}

/// 面板头里的 tab 栏数据：有值时 `PanelHeader` 把写死的标题换成这条 tab 栏（mac）。
struct PanelGroupTabs {
    var items: [PanelGroupTab]
    var selected: String
    var onSelect: (String) -> Void
}

#if os(macOS)
/// 面板组的 tab 栏（mac）：外观跟右栏 `TabbedToolPanel.macTab` 同一套（图标 + 名，`MacShellControlSurface` 底，
/// 高 `ShellStyle.tabHeight`），只是不带 ×（关的是整组，× 在面板头右端）。
/// 这次只做切换；拖 tab 浮出 / 并组还没接（`PanelGroupTab.id` 已经是可当 payload 的面板 id）。
struct PanelGroupTabStrip: View {
    let tabs: PanelGroupTabs
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs.items) { tab in
                button(tab, selected: tab.id == tabs.selected)
            }
        }
    }

    private func button(_ tab: PanelGroupTab, selected: Bool) -> some View {
        Button {
            guard !selected else { return }
            tabs.onSelect(tab.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: ShellStyle.iconSize - 2, weight: .medium))
                    .foregroundStyle(ShellStyle.secondaryText)
                Text(tab.title)
                    .font(ShellStyle.bodyFont)
                    .foregroundStyle(selected ? ShellStyle.text : ShellStyle.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 64, minHeight: ShellStyle.tabHeight)
            .modifier(MacShellControlSurface(selected: selected, hovered: hovered == tab.id))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 左栏面板组（「对话 | Code」）的胶水：显示哪个 tab、点了怎么切。
/// 选中态**派生自** `CodingSessionLibrary.isActive`（⌘K 命中编程会话 / 终端「在编程会话里看」激活它，点对话退出它，
/// tab 都跟着走）；持久化与启动恢复在 `ContentView.macLayout`。
@MainActor
enum MacLeftPanelGroup {
    static var current: MacLeftPanelTab {
        CodingSessionLibrary.shared.isActive && MacWorkspacePreferences.shared.showCodingSessions ? .code : .chats
    }

    static var tabs: PanelGroupTabs {
        PanelGroupTabs(items: MacWorkspacePreferences.shared.leftPanelTabs.map(\.groupTab),
                       selected: current.panelID) { id in
            if let tab = MacLeftPanelTab(panelID: id) { select(tab) }
        }
    }

    static func select(_ tab: MacLeftPanelTab) {
        let library = CodingSessionLibrary.shared
        switch tab {
        case .chats:
            library.deactivate()
        case .code:
            if !library.isActive { library.activate() }
        }
        MacWorkspacePreferences.shared.leftPanelTab = tab
    }
}
#endif
