#if os(iOS)
import SwiftUI
import UIKit

/// page0 顶栏的人（11-15 粟粟定）：当前这个人 → 人页；最近聊过的两个人 → 一步切过去；⋯ / 全部 → atrium。
/// 两种样子（11-15 挑刺稿里的 B / D），粟粟说都留着，设置 › 外观 › 对话列表 › 顶栏的人 切：
/// - segment（D）：一条玻璃分段条，当前这个人那格亮着、带名字，别人只露头像，⋯ 用细线隔开
/// - row（B）：一排人，头像下面都写名字，当前这个人大一号、带一圈薄荷色环
struct Page0PeopleBar: View {
    var dark: Bool
    var glass: Bool
    var zoom: Namespace.ID?
    var onOpenProfile: () -> Void

    @AppStorage("page0PeopleBarStyle") private var style = "segment"
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(AtriumPresenter.self) private var atriumPresenter: AtriumPresenter?
    @State private var recent: [Profile] = []
    /// 当前层还在回话时点了别人：先问一句（同 atrium）
    @State private var interruptTarget: Profile?

    private var fg: Color { dark ? .white : Theme.textPrimary }
    private var current: Profile? { profileManager?.currentProfile }

    var body: some View {
        Group {
            if style == "row" { row } else { segment }
        }
        .task(id: profileManager?.profiles.map(\.id)) {
            guard let pm = profileManager else { return }
            let rows = await AtriumRowLoader.latestTimes(profileIds: pm.profiles.map(\.id), container: pm.container)
            recent = Array(AtriumRowLoader.recentFirst(pm.profiles, rows: rows)
                .filter { $0.id != pm.currentProfile.id }
                .prefix(2))
        }
        .confirmationDialog(interruptTitle, isPresented: Binding(get: { interruptTarget != nil }, set: { if !$0 { interruptTarget = nil } }),
                            titleVisibility: .visible, presenting: interruptTarget) { target in
            Button("切过去", role: .destructive) { switchTo(target) }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - D：分段条

    private var segment: some View {
        HStack(spacing: 2) {
            Button(action: onOpenProfile) {
                HStack(spacing: 6) {
                    ProfileAvatarView(profile: current, size: 28)
                    Text(current?.name ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 112, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.45)
                }
                .foregroundColor(fg)
                .padding(.leading, 4)
                .padding(.trailing, 10)
                .frame(height: 36)
                .background(Capsule().fill(dark ? Color.white.opacity(0.2) : Color.white.opacity(0.9)))
                .contentShape(Capsule())
                .modifier(Page0ProfileZoomSource(namespace: zoom))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("page0-profile")

            ForEach(recent) { profile in
                Button { select(profile) } label: {
                    avatar(profile, size: 28)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切到\(profile.name)")
                .accessibilityIdentifier("page0-recent-\(profile.id)")
            }

            Rectangle()
                .fill(fg.opacity(0.15))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 3)

            Button { atriumPresenter?.present() } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(fg)
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("所有人")
            .accessibilityIdentifier("page0-atrium")
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
        .if(glass) { $0.glassEffect(.regular.tint(Color.white.opacity(0.15)), in: .capsule) }
    }

    // MARK: - B：人行

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onOpenProfile) {
                VStack(spacing: 5) {
                    ProfileAvatarView(profile: current, size: 46)
                        .padding(3)
                        .overlay(Circle().stroke(Theme.branchIndicator, lineWidth: 2))
                        .modifier(Page0ProfileZoomSource(namespace: zoom))
                    HStack(spacing: 1) {
                        Text(current?.name ?? "").lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(0.5)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                }
                .frame(width: 72)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("page0-profile")

            Rectangle()
                .fill(fg.opacity(0.15))
                .frame(width: 1, height: 30)
                .padding(.top, 13)

            ForEach(recent) { profile in
                Button { select(profile) } label: {
                    VStack(spacing: 5) {
                        avatar(profile, size: 44)
                            .padding(4)
                        Text(profile.name)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .opacity(0.7)
                    }
                    .frame(width: 62)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切到\(profile.name)")
                .accessibilityIdentifier("page0-recent-\(profile.id)")
            }

            Button { atriumPresenter?.present() } label: {
                VStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(fg.opacity(0.08)))
                        .padding(4)
                    Text("全部 \(profileManager?.profiles.count ?? 0)")
                        .font(.system(size: 11.5))
                        .opacity(0.7)
                }
                .frame(width: 62)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("所有人")
            .accessibilityIdentifier("page0-atrium")
        }
        .foregroundColor(fg)
    }

    // MARK: -

    /// 没头像也没 emoji 的人用名字第一个字，别画成一个空圈（深色背景上像个洞）
    @ViewBuilder
    private func avatar(_ profile: Profile, size: CGFloat) -> some View {
        if profile.assistantAvatarData == nil, profile.coverImageData == nil, profile.emoji.isEmpty {
            Text(String(profile.name.prefix(1)))
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.accent))
        } else {
            ProfileAvatarView(profile: profile, size: size)
        }
    }

    private var interruptTitle: String {
        let busy = ProfileTurnActivity.shared.generatingProfileId
        let name = profileManager?.profiles.first { $0.id == busy }?.name ?? ""
        return "\(name) 还在回话，切走会打断"
    }

    private func select(_ profile: Profile) {
        if let busy = ProfileTurnActivity.shared.generatingProfileId, busy != profile.id {
            interruptTarget = profile
            return
        }
        switchTo(profile)
    }

    /// 换人：轻震一下；整树按 .id 重建，先盖一张旧画面的截图再淡出，看起来是交叉淡入而不是硬切；留在列表页
    private func switchTo(_ profile: Profile) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let cover = window?.snapshotView(afterScreenUpdates: false)
        if let window, let cover {
            cover.frame = window.bounds
            cover.isUserInteractionEnabled = false
            window.addSubview(cover)
        }
        LastLocationResume.pendingProfileSwitch = profile.id
        LastLocationResume.pendingProfileSwitchPage = 0
        profileManager?.switchTo(profile)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
                cover?.alpha = 0
            } completion: { _ in
                cover?.removeFromSuperview()
            }
        }
    }
}

/// 人页的缩放转场从这里起（原在 SidebarView，顶栏的人挪进来后跟着搬）
struct Page0ProfileZoomSource: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: SidebarView.page0ProfileZoomID, in: namespace) { $0.clipShape(RoundedRectangle(cornerRadius: 22)) }
        } else {
            content
        }
    }
}

/// 字标藏在灵动岛 / 刘海后面（11-15 粟粟定，page0 / page1 都有）：真机看不见，截图里带着。没岛没刘海的屏（顶部安全区很浅）就不画
struct IslandWordmark<Mark: View>: View {
    @ViewBuilder var mark: () -> Mark

    var body: some View {
        let top = Self.safeAreaTop
        if top >= 44 {
            // 灵动岛约在 y 11–48（顶部安全区 ≥ 59），刘海约在 y 0–30
            let height: CGFloat = 16
            let center: CGFloat = top >= 59 ? 29.5 : 15
            mark()
                .frame(height: height)
                .padding(.top, center - height / 2)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private static var safeAreaTop: CGFloat {
        guard
            let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return 0 }
        return window.safeAreaInsets.top
    }
}
#endif
