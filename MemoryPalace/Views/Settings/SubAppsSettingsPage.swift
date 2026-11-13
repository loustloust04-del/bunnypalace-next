#if os(iOS)
import SwiftUI

/// gardenOS 设置 App ›「App 设置」（原「子应用」，atrium P4-b 改名）：App 里没有自己 ⚙ 的那几个，每行打开它自己的那一页设置。
struct SubAppsSettingsPage: View {
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    #if PERSONAL_APPS
    @AppStorage("deathScale.unlocked") private var deathScaleUnlocked = false
    #endif

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ChatSkinSettingsPage()
                } label: {
                    HStack(spacing: 12) {
                        subAppIcon("bubble.left.and.bubble.right")
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

            Section {
                subAppRow(icon: "ri-emoji-sticker", title: "贴纸") { StickerPage() }
                subAppRow(icon: "heart.text.square", title: "健康") { HealthSettingsTab() }
                #if PERSONAL_APPS
                subAppRow(icon: "chart.line.uptrend.xyaxis", title: "交易") { TradingSettingsTab() }
                #endif
                subAppRow(icon: "person.2", title: "群聊") { GroupChatSettingsTab() }
            } footer: {
                Text("日历、书房、单词、终端、小芽的设置在各自 App 里。")
            }
            .listRowBackground(Theme.mainBg)

            #if PERSONAL_APPS
            if deathScaleUnlocked {
                Section {
                    Toggle("Mort sans sépulture", isOn: Binding(
                        get: { tools?.tool(byId: DeathScaleGate.toolId)?.isEnabled ?? false },
                        set: { DeathScaleGate.setVisible($0, tools: tools) }
                    ))
                    .tint(Theme.branchIndicator)
                } footer: {
                    Text("关掉只收起桌面图标，里面的记录都留着。")
                }
                .listRowBackground(Theme.mainBg)
            }
            if SkinState.shared.unlocked {
                Section {
                    subAppRow(icon: "hare", title: "caelumbunny") { TutuSkinSettingsPage() }
                }
                .listRowBackground(Theme.mainBg)
            }
            #endif
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("App 设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func subAppIcon(_ name: String) -> some View {
        AppIconView(name: name, size: 16, tint: Theme.textSecondary)
            .frame(width: 28)
    }

    private func subAppRow<Destination: View>(icon: String, title: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                subAppIcon(icon)
                Text(title)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
            }
        }
    }
}
#endif
