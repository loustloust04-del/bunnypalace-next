#if os(iOS)
import SwiftUI

/// 设置 →「子应用」：Page2 各子应用自己的设置。
struct SubAppsSettingsPage: View {
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ChatSkinSettingsPage()
                } label: {
                    HStack(spacing: 8) {
                        Text("聊天（css自定义）")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Text(ChatSkinStore.activeSkinName() ?? "默认")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            } footer: {
                Text("用 CSS 自己装修聊天界面，能直接导入 KakaoTalk 主题。")
            }
            .listRowBackground(Theme.mainBg)

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("子应用")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
