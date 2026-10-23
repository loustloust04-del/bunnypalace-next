import SwiftUI

/// 个人主页头：横幅 + 压在横幅上的大头像 + 昵称/@handle/简介/统计。
struct TwitterProfileHeaderView: View {
    let account: TwitterArchiveAccount?
    let tweetCount: Int
    let span: (earliest: Date, latest: Date)?
    let mediaDir: URL
    let accent: Color
    var onEdit: () -> Void = {}
    /// 看的是自己的号：显示「编辑个人资料」；别的号：显示「关注 / 已关注」
    var isOwn: Bool = true
    var isFollowing: Bool = false
    var onFollow: () -> Void = {}
    /// 本站里的关注（粟粟 2026-09-25：主页要有关注数 / 粉丝数，点进去是列表）
    var followingCount = 0
    var followerCount = 0
    /// true = 看「正在关注」，false = 看「关注者」
    var onShowFollows: (Bool) -> Void = { _ in }

    private static let month: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy 年 M 月"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            // 内容必须压在横幅之上：横幅是定位层，会盖住后面的普通内容
            // （HTML 仿版上粟粟一眼看出头像被遮，就是这个）。
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    TwitterAvatarView(account: account, mediaDir: mediaDir, size: 72, accent: accent)
                        .overlay(Circle().stroke(Theme.mainBg, lineWidth: 4))
                        .offset(y: -36)
                    Spacer()
                    // 推特的位置：横幅下沿右侧，描边胶囊
                    if isOwn {
                        Button(action: onEdit) {
                            Text("编辑个人资料")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 14)
                                .frame(height: 32)
                                .overlay(Capsule().stroke(Theme.textMuted.opacity(0.5)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                    } else {
                        // 别的号：没关注是实心「关注」，关注了是描边「已关注」（推特的样子）
                        Button(action: onFollow) {
                            Text(isFollowing ? "已关注" : "关注")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(isFollowing ? Theme.textPrimary : Theme.mainBg)
                                .padding(.horizontal, 18)
                                .frame(height: 32)
                                .background(isFollowing ? Color.clear : Theme.textPrimary, in: Capsule())
                                .overlay(Capsule().stroke(Theme.textMuted.opacity(isFollowing ? 0.5 : 0)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                    }
                }
                .padding(.bottom, -28)

                HStack(spacing: 6) {
                    Text(account?.displayName ?? "我")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if account?.ownerKind == TwitterAccounts.ownerAI {
                        // 楼层 AI 的号标一下，免得分不清谁在说话
                        Text("AI")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().stroke(accent.opacity(0.6)))
                    }
                }
                if let handle = account?.screenName, !handle.isEmpty {
                    Text("@\(handle)")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textMuted)
                }
                if let bio = account?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                metaRows.padding(.top, 10)
                HStack(spacing: 16) {
                    followCount(followingCount, "正在关注") { onShowFollows(true) }
                    followCount(followerCount, "关注者") { onShowFollows(false) }
                }
                .padding(.top, 10)
                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 16)
            .zIndex(1)
        }
    }

    private var banner: some View {
        Group {
            if let name = account?.bannerFileName {
                TwitterMediaImage(url: mediaDir.appendingPathComponent(name))
            } else {
                Rectangle().fill(accent)
            }
        }
        .frame(height: 160)   // 顶进安全区了，灵动岛那一截也算在里面
        .frame(maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder private var metaRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let where_ = account?.location, !where_.isEmpty {
                Label(where_, systemImage: "mappin.and.ellipse")
            }
            if let site = account?.website, !site.isEmpty {
                Label { Text(site).foregroundStyle(accent) } icon: { Image(systemName: "link") }
            }
            if let joined = account?.accountCreatedAt {
                Label("\(Self.month.string(from: joined))加入", systemImage: "calendar")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.textMuted)
        .labelStyle(.titleAndIcon)
    }

    private func followCount(_ n: Int, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text(label).font(.system(size: 14)).foregroundStyle(Theme.textMuted)
            }
        }
        .buttonStyle(.plain)
    }

    /// 关注数是本站里的（存档本身不带 X 上的关注数据）；这里再给推文数和时间跨度。
    private var summary: String {
        var parts = ["\(tweetCount) 条推文"]
        if let span {
            let a = Self.month.string(from: span.earliest)
            let b = Self.month.string(from: span.latest)
            parts.append(a == b ? a : "\(a) – \(b)")
        }
        return parts.joined(separator: " · ")
    }
}
