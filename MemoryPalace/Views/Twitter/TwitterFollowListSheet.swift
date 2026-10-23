import SwiftUI

/// 主页「正在关注 / 关注者」点进去的列表。点一个号去他的主页。
struct TwitterFollowListSheet: View {
    let title: String
    let accounts: [TwitterArchiveAccount]
    let mediaDir: URL
    let accent: Color
    var onOpen: (TwitterArchiveAccount) -> Void = { _ in }
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("完成", action: onClose).buttonStyle(.plain).foregroundStyle(accent)
            }
            .padding(16)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if accounts.isEmpty {
                        Text("还没有").font(.footnote).foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    ForEach(accounts, id: \.accountId) { a in
                        Button { onOpen(a) } label: { row(a) }.buttonStyle(.plain)
                        Divider().opacity(0.4).padding(.leading, 66)
                    }
                }
            }
        }
        .background(Theme.mainBg)
    }

    private func row(_ a: TwitterArchiveAccount) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TwitterAvatarView(account: a, mediaDir: mediaDir, size: 40, accent: accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.displayName).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    if a.ownerKind == TwitterAccounts.ownerAI {
                        Text("AI").font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(accent.opacity(0.6)))
                    }
                }
                if !a.screenName.isEmpty {
                    Text("@\(a.screenName)").font(.system(size: 14)).foregroundStyle(Theme.textMuted)
                }
                if !a.bio.isEmpty {
                    Text(a.bio).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
