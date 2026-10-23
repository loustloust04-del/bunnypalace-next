import SwiftUI

// MARK: - 右栏设置页

/// 设置 · 右栏：工具开关（+ iOS 的 Page 2 桌面样式）。
///
/// 一份 body 两端共用（plan-settings-merge-x 刀 3）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`；
/// 「桌面样式」是 iOS-only 的 Page 2 功能（第 2 类），连 `@AppStorage` 声明一起包进 `#if`，免得 mac 白订阅。
/// 工具之间不手画 `Divider`——mac 的 `MacSettingsCard` 已经在 subview 之间插 hairline，手画会双线。
struct RightPanelPage: View {
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?
    @Environment(\.settingsMetrics) private var m
    #if os(iOS)
    @AppStorage("page2HomePresentation_v1") private var page2DesktopStyle = "free"
    @AppStorage(Page2Switcher.key) private var page2Switcher = "strip"
    #endif

    var body: some View {
        SettingsSectionList(.list) {
            #if os(iOS)
            Section("桌面样式") {
                Picker("桌面样式", selection: $page2DesktopStyle) {
                    Text("手机主屏").tag("free")
                    Text("经典").tag("classic")
                    Text("针脚点阵").tag("stitch")
                }
                .pickerStyle(.segmented)
                Text("切换 Page 2 桌面的排版样式，旧组件和图标配置会保留。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("切换应用") {
                Picker("切换应用", selection: $page2Switcher) {
                    Text("右边竖条").tag("strip")
                    Text("左上弧线").tag("arc")
                }
                .pickerStyle(.segmented)
                Text("右边竖条：在 Page 2 往左划拉出应用列表。左上弧线：从左上角往里拉，进后台或回桌面。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            #endif

            Section("工具管理") {
                if let tm = toolManager {
                    ForEach(tm.allToolsSorted.filter { $0.isEnabled || !RightPanelToolManager.secretToolIds.contains($0.id) }) { tool in
                        HStack(spacing: 12) {
                            AppIconView(name: tool.icon, size: 16,
                                        tint: tool.isEnabled ? Theme.textSecondary : Theme.textMuted, toolID: tool.id)
                                .frame(width: 28)

                            Text(tool.name)
                                .font(m.body)
                                .foregroundColor(tool.isEnabled ? Theme.textPrimary : Theme.textMuted)

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { tool.isEnabled },
                                set: { tm.setEnabled(tool.id, $0) }
                            ))
                            .tint(Theme.branchIndicator)
                            .labelsHidden()
                        }
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                Text("关闭的工具不会出现在右栏工具栏和抽屉中。未来可在此管理插件。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("右栏")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
