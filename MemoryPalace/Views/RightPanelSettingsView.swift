import SwiftUI

// MARK: - 右栏设置页

/// 设置 · 右栏：工具开关（+ iOS 的 Page 2 桌面样式）。
///
/// 一份 body 两端共用（plan-settings-merge-x 刀 3）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`；
/// 「桌面样式」是 iOS-only 的 Page 2 功能（第 2 类），连 `@AppStorage` 声明一起包进 `#if`，免得 mac 白订阅。
/// 工具之间不手画 `Divider`——mac 的 `MacSettingsCard` 已经在 subview 之间插 hairline，手画会双线。
/// atrium P3⑥a：「工具管理」是默认（没单独改过的人都用这一套），开关显示 / 改的都是默认；按人装卸在 iOS 人页
/// atrium P4-a：iOS 上这页只从 gardenOS 设置 App 的「默认 ›」进（页名「默认」），桌面样式 / 切换应用搬去 `Page2HomeOptionsSections`；mac 不变
struct RightPanelPage: View {
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var overridesFor: String?
    @State private var tick = 0

    var body: some View {
        SettingsSectionList(.list) {
            Section("工具管理") {
                let _ = tick
                #if os(iOS)
                Text("这里是默认：没单独改过的人都用这一套。单独给某个人装卸，去 TA 的人页 › 权限，或在 TA 主屏的「设置」App 里。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
                if let tm = toolManager {
                    // 显示默认那份（manager 的生效值跟当前层，这页不看层）
                    ForEach(tm.allToolsSorted.filter { !RightPanelToolManager.systemToolIds.contains($0.id) && (Page2Apps.defaultInstalled($0.id) || !RightPanelToolManager.secretToolIds.contains($0.id)) }) { tool in
                        let on = Page2Apps.defaultInstalled(tool.id)
                        let overrideCount = Page2AppOverridesPage.entries(tool.id, profiles: profileManager?.profiles ?? []).count
                        HStack(spacing: 12) {
                            AppIconView(name: tool.icon, size: 16,
                                        tint: on ? Theme.textSecondary : Theme.textMuted, toolID: tool.id)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                    .font(m.body)
                                    .foregroundColor(on ? Theme.textPrimary : Theme.textMuted)
                                if overrideCount > 0 {
                                    Button("\(overrideCount) 个人单独改了 ›") { overridesFor = tool.id }
                                        .buttonStyle(.borderless)
                                        .font(m.caption)
                                        .foregroundColor(Theme.branchIndicator)
                                }
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { on },
                                set: { tm.setEnabled(tool.id, $0, target: .defaults); tick += 1 }
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
                Text("关闭的工具不会出现在右栏工具栏和抽屉中，也会让 AI 用不了里面的东西。未来可在此管理插件。")
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
        .navigationTitle("默认")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: Binding(get: { overridesFor != nil }, set: { if !$0 { overridesFor = nil } })) {
            NavigationStack {
                Page2AppOverridesPage(toolId: overridesFor ?? "")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { overridesFor = nil }
                        }
                    }
            }
            .environment(profileManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            tick += 1
        }
    }
}

// MARK: - 「N 个人单独改了」

/// 「右栏」某个 App 的「N 个人单独改了」点开：谁单独装卸了 +〔都回到跟默认〕（atrium P3⑥a §3.4，照 ⑤a `PermissionOverridesPage` 复制一份）
struct Page2AppOverridesPage: View {
    let toolId: String
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var tick = 0
    @State private var confirmClear = false

    /// 只数还在的楼层（删过的层残留的设置不算）
    static func entries(_ toolId: String, profiles: [Profile]) -> [(profile: Profile, installed: Bool)] {
        let stored = Page2Apps.overrides(toolId)
        return profiles.compactMap { p in stored[p.id].map { (p, $0) } }
    }

    private static func title(_ installed: Bool) -> String { installed ? "装着" : "没装" }

    var body: some View {
        let _ = tick
        let rows = Self.entries(toolId, profiles: profileManager?.profiles ?? [])
        let name = Page2Apps.displayName(toolId)
        SettingsSectionList(.list) {
            Section {
                if rows.isEmpty {
                    Text("没有人单独改，都跟着默认")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(rows, id: \.profile.id) { row in
                        HStack {
                            Text("\(row.profile.emoji) \(row.profile.name)")
                                .font(m.body)
                            Spacer()
                            Text(Self.title(row.installed))
                                .font(m.caption)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
            } footer: {
                Text("默认现在是「\(Self.title(Page2Apps.defaultInstalled(toolId)))」。这些人用自己单独装卸的，改默认不影响他们。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            if !rows.isEmpty {
                Section {
                    Button("都回到跟默认") { confirmClear = true }
                        .font(m.body)
                        .foregroundColor(Theme.textSecondary)
                        .settingsActionButton()
                }
                .listRowBackground(Theme.mainBg)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBg)
        .navigationTitle(name)
        .confirmationDialog("「\(name)」所有人都回到跟默认？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("都回到跟默认", role: .destructive) {
                Page2Apps.clearFloor(toolId)
                tick += 1
            }
            Button("取消", role: .cancel) {}
        }
    }
}
