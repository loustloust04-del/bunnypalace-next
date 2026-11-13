#if os(iOS)
import SwiftUI

/// 人页「权限」里的「TA 主屏上的 App」（atrium P3⑥a §3.3）：给这个人装卸 page2 App，没单独改的跟着默认（gardenOS 设置 App › 默认）。
/// 没装的 App 连着的 AI 能力对这个人关掉（`PermissionCenter.level` 的前置门），所以连着权限的行尾标出来。
/// 装没装一律读 `Page2Apps`（不读 manager 的生效值：manager 只跟当前层）
struct PersonAppSections: View {
    let profileId: String
    /// 节头；nil = 人页的「TA 主屏上的 App」。gardenOS 设置 App 传「{名字}的主屏上的 App」（atrium P4 §3.3）
    var header: String? = nil
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?
    @Environment(\.settingsMetrics) private var m
    @State private var confirmReset = false
    @State private var tick = 0

    private var readOnly: Bool { profileManager?.isReadOnly == true || profileId.isEmpty }

    /// 行尾「连着：…」：这个 App 连着哪些权限域；不连 → nil
    static func linkedCaption(_ toolId: String) -> String? {
        let domains = PermissionDomain.allCases.filter { $0.page2App == toolId }
        guard let first = domains.first else { return nil }
        return domains.count == 1 ? "连着：\(first.displayName)" : "连着：\(Page2Apps.displayName(toolId)) \(domains.count) 项"
    }

    var body: some View {
        let _ = tick
        Section {
            if let tm = toolManager {
                ForEach(tm.allToolsSorted.filter { !RightPanelToolManager.systemToolIds.contains($0.id) && (Page2Apps.isInstalled($0.id, profileId: profileId) || !RightPanelToolManager.secretToolIds.contains($0.id)) }) { tool in
                    row(tool, tm: tm)
                }
            }
        } header: {
            Text(header ?? "TA 主屏上的 App")
        } footer: {
            Text("没装的 App，TA 也用不了里面的东西（比如没装文件库 = 读不了文件库）。默认在 设置 App › 默认 里改。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
        .disabled(readOnly)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            tick += 1
        }

        Section {
            Button("App 全部恢复跟随默认") { confirmReset = true }
                .font(m.body)
                .foregroundColor(Theme.textSecondary)
                .settingsActionButton()
                .confirmationDialog("这个人主屏上的 App 全部恢复跟随默认？", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("恢复", role: .destructive) {
                        Page2Apps.clearAll(profileId: profileId)
                        tick += 1
                    }
                    Button("取消", role: .cancel) {}
                }
        } footer: {
            Text("删掉这个人单独装卸的，全部跟着默认走。权限档位不受影响。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
        .disabled(readOnly)
    }

    private func row(_ tool: RightPanelTool, tm: RightPanelToolManager) -> some View {
        let installed = Page2Apps.isInstalled(tool.id, profileId: profileId)
        let follows = Page2Apps.floors().stored(tool.id, profileId: profileId) == nil
        return HStack(spacing: 12) {
            AppIconView(name: tool.icon, size: 16,
                        tint: installed ? Theme.textSecondary : Theme.textMuted, toolID: tool.id)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(m.body)
                    .foregroundColor(installed ? Theme.textPrimary : Theme.textMuted)
                if follows {
                    Text("跟随默认")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer(minLength: 8)
            if let linked = Self.linkedCaption(tool.id) {
                Text(linked)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            Toggle("", isOn: Binding(
                get: { installed },
                set: { tm.setEnabled(tool.id, $0, target: .floor(profileId)); tick += 1 }
            ))
            .tint(Theme.branchIndicator)
            .labelsHidden()
        }
    }
}
#endif
