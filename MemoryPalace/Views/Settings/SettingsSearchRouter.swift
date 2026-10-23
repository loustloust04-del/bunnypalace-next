import SwiftUI

// MARK: - Settings Search Router

/// 搜索命中 → 目标页面的一次性信箱。
///
/// 跳转链路是「赋值 `selectedSettingsTab` push 页面」，页面自己没法知道用户是搜进来的、
/// 想看哪一行；所以跳转前把 anchor 投进这里，页面上树后取走（取走即清，防重入）。
///
/// 只在 iOS 用（搜索面板是 iOS-only），但 CC / 数据 / 权限这些页是双端共用源码，
/// 所以这里不包 `#if os(iOS)`，macOS 上就是个没人写值的空信箱。
@MainActor
final class SettingsSearchRouter: ObservableObject {
    static let shared = SettingsSearchRouter()

    /// 待消费的锚点（页面上树后取走）
    @Published private(set) var pendingAnchor: String?
    /// 正在闪的锚点（`.searchAnchor` 据此上薄荷底）
    @Published private(set) var flashingAnchor: String?

    /// 薄荷底停留多久再开始退（让眼睛捕捉得到）
    static let flashHold: TimeInterval = 0.25
    /// 退场时长
    static let flashFade: TimeInterval = 1.2

    private var flashTask: Task<Void, Never>?

    private init() {}

    /// 跳转前投信。`nil` = 这条没锚点（页面级 / 占位 / 降级页），页面照旧不滚。
    func request(anchor: String?) {
        pendingAnchor = anchor
    }

    /// 页面取走待消费锚点；取走即清。
    func takePending() -> String? {
        defer { pendingAnchor = nil }
        return pendingAnchor
    }

    /// 命中行薄荷一闪：先点亮，停 `flashHold` 后 `flashFade` 内退场。
    func flash(_ anchor: String) {
        flashTask?.cancel()
        flashingAnchor = anchor
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flashHold * 1_000_000_000))
            guard !Task.isCancelled, let self, self.flashingAnchor == anchor else { return }
            withAnimation(.easeOut(duration: Self.flashFade)) {
                self.flashingAnchor = nil
            }
        }
    }

    /// 测试 / 退出页面时的即时熄灯
    func clearFlash() {
        flashTask?.cancel()
        flashingAnchor = nil
    }
}

// MARK: - .searchAnchor

private struct SearchAnchorModifier: ViewModifier {
    let anchorID: String
    @ObservedObject private var router = SettingsSearchRouter.shared

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // 薄荷（`Theme.accent` 是浅背景色，醒目那支是 branchIndicator）
                    .fill(Theme.branchIndicator.opacity(router.flashingAnchor == anchorID ? 0.22 : 0))
                    .padding(.horizontal, -10)
                    .padding(.vertical, -6)
                    .allowsHitTesting(false)
            )
            // 常量 id，不会变身份 → 不触发整树重建
            .id(anchorID)
    }
}

extension View {
    /// 给设置页的一行挂搜索锚点：`scrollTo` 的落点 + 命中时薄荷一闪。
    /// id 直接用注册表条目的 `id`（两边好 grep，唯一性由注册表单测兜住）。
    func searchAnchor(_ anchorID: String) -> some View {
        modifier(SearchAnchorModifier(anchorID: anchorID))
    }
}

// MARK: - 页面侧接线

private struct SettingsAnchorScroll: ViewModifier {
    let proxy: ScrollViewProxy
    @ObservedObject private var router = SettingsSearchRouter.shared

    func body(content: Content) -> some View {
        content
            .onAppear { consume() }
            .onChange(of: router.pendingAnchor) { _, _ in consume() }
            .onDisappear { router.clearFlash() }
    }

    private func consume() {
        guard let anchor = router.takePending() else { return }
        // push 动画还在飞、List 首帧也没排完版，同帧 scrollTo 落空 → 等导航稳定再滚
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
            router.flash(anchor)
        }
    }
}

extension View {
    /// 长页面在 `ScrollViewReader` 里挂这一条：消费 pendingAnchor → 滚到位 → 闪。
    func settingsAnchorScroll(_ proxy: ScrollViewProxy) -> some View {
        modifier(SettingsAnchorScroll(proxy: proxy))
    }
}
