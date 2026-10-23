import SwiftUI

/// 通讯录组件（page2 仪表盘）：当前楼层的 user + AI 名册，点条目弹资料卡。
/// 卡片外壳学 TodoWidgetView（mainBg 圆角 + accent 描边）。
struct ContactsWidgetView: View {
    @Environment(\.usesSystemDesktop) private var systemDesktop
    var size: WidgetSize = .medium
    @Environment(\.pinnedOnDesktop) private var pinnedOnDesktop
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var presentedCard: ProfileCardStore.Owner? = nil

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #if os(macOS)
            .modifier(MacShellWidgetSurface())
            #else
            .modifier(Page2LegacySurface())
            #endif
            .sheet(item: $presentedCard) { owner in
                AIProfileSheet(owner: owner)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Theme.sidebarBg)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch size {
        case .small:
            VStack(alignment: .leading, spacing: 8) {
                header
                HStack(spacing: 14) {
                    avatarButton(.user, avatarSize: 40)
                    avatarButton(.assistant, avatarSize: 40)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        case .medium, .large:
            VStack(alignment: .leading, spacing: 10) {
                header
                row(.user)
                Divider().opacity(0.25)
                row(.assistant)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2.fill")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
            Text("通讯录")
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
            Spacer()
        }
    }

    private func name(_ owner: ProfileCardStore.Owner) -> String {
        guard let p = profileManager?.currentProfile else { return owner == .assistant ? "助手" : "你" }
        let n = owner == .assistant ? p.assistantName : p.userName
        return n.isEmpty ? (owner == .assistant ? "助手" : "你") : n
    }

    /// 小方：只有头像+名字的紧凑竖排
    private func avatarButton(_ owner: ProfileCardStore.Owner, avatarSize: CGFloat) -> some View {
        Button(action: { presentedCard = owner }) {
            VStack(spacing: 4) {
                ProfileAvatarView(profile: profileManager?.currentProfile, owner: owner, size: avatarSize)
                Text(name(owner))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(systemDesktop ? .primary.opacity(0.8) : Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    /// 长条/大方：整行（头像 + 名字 + AI 侧带状态小字）
    private func row(_ owner: ProfileCardStore.Owner) -> some View {
        Button(action: { presentedCard = owner }) {
            HStack(spacing: 10) {
                ProfileAvatarView(profile: profileManager?.currentProfile, owner: owner, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(owner))
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(systemDesktop ? .primary : Theme.textPrimary)
                        .lineLimit(1)
                    if owner == .assistant,
                       let status = ProfileCardStore.load(profileId: profileManager?.currentProfile.id ?? "", owner: .assistant).status {
                        Text("・\(status)")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
