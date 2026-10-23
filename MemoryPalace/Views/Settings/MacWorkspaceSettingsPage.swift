#if os(macOS)
import SwiftUI

struct MacWorkspaceSettingsPage: View {
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @State private var preferences = MacWorkspacePreferences.shared
    @State private var legacy = Page2DesktopManager.shared
    @State private var showLocations = false
    @State private var updater = AppUpdater.shared
    private var seed: [String] { legacy.dockToolIds ?? tools?.pinnedTools.map(\.id) ?? [] }
    private var items: [MacWorkspacePreferences.DockItem] { preferences.items(seed: seed) }

    var body: some View {
        @Bindable var preferences = self.preferences
        List {
            Section("编程会话") {
                Toggle("左栏面板显示 Code tab", isOn: $preferences.showCodingSessions)
                Toggle("在菜单栏显示", isOn: $preferences.showMenuBarExtra)
                    .help("菜单栏快看：在跑 / 等你回答的 Code 会话、订阅额度、新建对话")
                Button("会话来源与远程主机…") { showLocations = true }
                Text("隐藏入口不会删除编程会话，也不会关闭 Codex 或 Claude Code 连接。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Section {
                HStack {
                    Menu("添加图标或分隔线") {
                        Button("分隔线") { preferences.insertDivider(seed: seed) }
                        Divider()
                        ForEach(availableTools) { tool in
                            Button(tool.name) {
                                preferences.addTool(tool.id, seed: seed)
                                tools?.setEnabled(tool.id, true)
                            }
                        }
                        if !items.contains(where: { $0.toolID == MacWorkspacePreferences.homeID }) {
                            Button("桌面") { preferences.addTool(MacWorkspacePreferences.homeID, seed: seed) }
                        }
                        if !items.contains(where: { $0.toolID == MacWorkspacePreferences.modeID }) {
                            Button("面板布局") { preferences.addTool(MacWorkspacePreferences.modeID, seed: seed) }
                        }
                    }
                    Spacer()
                    Button("恢复默认排列") { preferences.resetDock() }
                }
                ForEach(items) { item in
                    dockRow(item)
                        .contextMenu {
                            Button("移除") { preferences.remove(item.id, seed: seed) }
                            Button("在后面添加分隔线") { preferences.insertDivider(after: item.id, seed: seed) }
                        }
                }
                .onMove { preferences.move(from: $0, to: $1, seed: seed) }
            } header: {
                Text("Dock 排列")
            } footer: {
                Text("拖动图标、分隔线或这里的行来排序，也可用上下按钮微调。移除只影响 Dock；添加已停用工具会同时启用它。")
            }
            // 面板模式 / 吸边 / 桌面排版 / dock 位置（10-02 从 外观 › 面板 挪来，和 Dock 排列放一起）
            Section("面板") {
                PanelLayoutSettingsRows(layout: IPadPanelLayout.shared, labelFont: .body, captionFont: .caption)
            }
            softwareUpdateSection
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showLocations) { CodingLocationsSheet() }
    }

    /// 软件更新（Sparkle，AppUpdater）。默认：自动检查开、自动下载开
    @ViewBuilder
    private var softwareUpdateSection: some View {
        @Bindable var updater = self.updater
        Section {
            Toggle("自动检查更新", isOn: $updater.automaticallyChecksForUpdates)
            Toggle("自动下载更新", isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)
            HStack {
                Button("检查更新…") { updater.checkForUpdates() }
                    .disabled(updater.isStarted && !updater.canCheckForUpdates)
                Spacer()
                Text("当前版本 \(Self.versionString)")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        } header: {
            Text("软件更新")
        } footer: {
            Text(updateFooter)
        }
    }

    private var updateFooter: String {
        if !updater.isConfigured { return "这个版本还没有配置更新源，暂时只能手动下载新版。" }
        var parts: [String] = []
        if AppUpdater.isDebugBuild { parts.append("开发版不会在后台自动检查，只响应手动检查。") }
        parts.append("自动下载的更新会在退出或重新启动时安装。")
        if let date = updater.lastCheckDate {
            parts.append("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " ")
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（\(build)）"
    }

    private var availableTools: [RightPanelTool] {
        tools?.allToolsSorted.filter { tool in
            !items.contains { $0.toolID == tool.id } && (tool.isEnabled || !RightPanelToolManager.secretToolIds.contains(tool.id))
        } ?? []
    }

    private func name(_ item: MacWorkspacePreferences.DockItem) -> String {
        if item.kind == .divider { return "分隔线" }
        switch item.toolID {
        case MacWorkspacePreferences.homeID: return "桌面"
        case MacWorkspacePreferences.modeID: return "面板布局"
        case .some(let id): return tools?.tool(byId: id)?.name ?? "暂不可用的工具"
        case .none: return "工具"
        }
    }

    private func icon(_ item: MacWorkspacePreferences.DockItem) -> String {
        if item.kind == .divider { return "minus" }
        switch item.toolID {
        case MacWorkspacePreferences.homeID: return "square.grid.2x2"
        case MacWorkspacePreferences.modeID: return "rectangle.split.3x1"
        case .some(let id): return tools?.tool(byId: id)?.icon ?? "questionmark.square"
        case .none: return "square"
        }
    }

    private func dockRow(_ item: MacWorkspacePreferences.DockItem) -> some View {
        let index = items.firstIndex { $0.id == item.id } ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(Theme.textMuted)
                .help("拖动排序")
            AppIconView(name: icon(item), size: 15, tint: Theme.textSecondary, toolID: item.toolID).frame(width: 22)
            Text(name(item))
            if let id = item.toolID, let tool = tools?.tool(byId: id), !tool.isEnabled {
                Button("启用") { tools?.setEnabled(id, true) }.controlSize(.small)
            }
            Spacer()
            Button {
                guard index > 0 else { return }
                preferences.move(item.id, relativeTo: items[index - 1].id, seed: seed)
            } label: { Image(systemName: "chevron.up") }
            .disabled(index == 0).help("上移").accessibilityLabel("上移\(name(item))")
            Button {
                guard index + 1 < items.count else { return }
                preferences.move(item.id, relativeTo: items[index + 1].id, after: true, seed: seed)
            } label: { Image(systemName: "chevron.down") }
            .disabled(index + 1 == items.count).help("下移").accessibilityLabel("下移\(name(item))")
            Button { preferences.remove(item.id, seed: seed) } label: { Image(systemName: "minus.circle") }
                .help("从 Dock 移除").accessibilityLabel("从 Dock 移除\(name(item))")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
    }
}
#endif
