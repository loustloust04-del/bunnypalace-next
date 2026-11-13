#if os(iOS)
import SwiftUI

/// gardenOS 设置（atrium P4 §1）：主屏上「设置」App 的内容，也是 iOS 设置树 `.rightPanel` 的落点（同一个 View，不复制）。
/// 自己不包 `NavigationStack`：App 宿主里由 tool switch 包一层，设置树里直接推。
/// 第一节是当前这个人的装卸（G2），默认在下一行「默认 ›」；桌面样式 / 切换应用 / 壁纸与图标所有人共用；最后「App 设置 ›」（P4-b）
struct GardenOSSettingsView: View {
    /// App 里叫「设置」；设置树里推出来叫「gardenOS 设置」，免得和「我」那棵设置混
    var title = "设置"
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var showsWallpaper = false

    var body: some View {
        let profile = profileManager?.currentProfile
        List {
            PersonAppSections(profileId: profile?.id ?? "", header: profile.map { "\($0.name)的主屏上的 App" })
            Section {
                NavigationLink {
                    RightPanelPage()
                } label: {
                    Text("默认（没单独改过的人都用）")
                        .font(m.body)
                }
            }
            .listRowBackground(Theme.mainBg)
            Page2HomeOptionsSections()
            // P4-b：完整的「主屏外观」页（壁纸 + 图标外观 + 大图标），自带 NavigationStack 和保存，开 sheet 不推页。「自定」半屏面板不搬
            Section {
                Button { showsWallpaper = true } label: {
                    HStack {
                        Text("壁纸与图标")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Text("所有人共用")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
            Section {
                NavigationLink {
                    SubAppsSettingsPage()
                } label: {
                    Text("App 设置")
                        .font(m.body)
                }
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .sheet(isPresented: $showsWallpaper) { Page2WallpaperEditor() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 桌面样式 + 切换应用（atrium P4-a 从 `RightPanelPage` 原样搬出来，加了节脚「所有人共用」）
struct Page2HomeOptionsSections: View {
    @Environment(\.settingsMetrics) private var m
    @AppStorage("page2HomePresentation_v1") private var page2DesktopStyle = "free"
    @AppStorage(Page2Switcher.key) private var page2Switcher = "strip"

    var body: some View {
        Section("桌面样式") {
            Picker("桌面样式", selection: $page2DesktopStyle) {
                Text("手机主屏").tag("free")
                Text("经典").tag("classic")
                Text("针脚点阵").tag("stitch")
            }
            .pickerStyle(.segmented)
            Text("切换 gardenOS 桌面的排版样式，旧组件和图标配置会保留。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)

        Section {
            Picker("切换应用", selection: $page2Switcher) {
                Text("右边竖条").tag("strip")
                Text("左上弧线").tag("arc")
            }
            .pickerStyle(.segmented)
            Text("右边竖条：在 gardenOS 桌面上的应用里往左划，拉出应用列表。左上弧线：从左上角往里拉，进后台或回桌面。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
            // §11-1：两种回桌面的示意插图（同小芽 Tip 1），选中的那张会动
            HStack(alignment: .top, spacing: 18) {
                switcherSample(.strip, title: "右边竖条", on: page2Switcher != "arc")
                switcherSample(.arc, title: "左上弧线", on: page2Switcher == "arc")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } header: {
            Text("切换应用")
        } footer: {
            Text("桌面样式和切换应用所有人共用。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
    }

    private func switcherSample(_ scene: XiaoyaTipScene, title: String, on: Bool) -> some View {
        VStack(spacing: 6) {
            XiaoyaTipIllustration(scene: scene, gate: on ? .appear : .still)
                .scaleEffect(0.8)
                .frame(width: 112 * 0.8 + 8, height: 228 * 0.8 + 8)
            Text(title)
                .font(m.caption)
                .foregroundColor(on ? Theme.textPrimary : Theme.textMuted)
        }
        .opacity(on ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { page2Switcher = scene == .arc ? "arc" : "strip" }
        .animation(.easeOut(duration: 0.2), value: on)
    }
}
#endif
