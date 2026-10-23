#if os(iOS)
import SwiftUI
import UIKit

struct Page2AppMotion {
    let token = UUID()
    let appID: String
    let fromSwitcher: Bool
    var cardProgress: CGFloat
    var homeProgress: CGFloat = 0
    var settling = false
}

/// 同一坐标空间里的全屏、卡片和图标端点；中途不更换承载应用的 view。
struct Page2AppGeometry {
    let size: CGSize
    let card: CGRect
    let icon: CGRect?
    let cardProgress: CGFloat
    let homeProgress: CGFloat

    var cardScale: CGFloat { card.width / max(size.width, 1) }
    var scale: CGFloat {
        let base = 1 + (cardScale - 1) * cardProgress
        let end = icon.map { $0.width / max(size.width, 1) } ?? base * 0.8
        return max(0.01, base + (end - base) * homeProgress)
    }
    var cropHeight: CGFloat { size.height + (card.height / max(cardScale, 0.01) - size.height) * cardProgress }
    var position: CGPoint {
        let p = cardProgress * cardProgress
        let base = CGPoint(x: size.width / 2 + (card.midX - size.width / 2) * p,
                           y: size.height / 2 + (card.midY - size.height / 2) * p)
        let end = icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? base
        return CGPoint(x: base.x + (end.x - base.x) * homeProgress,
                       y: base.y + (end.y - base.y) * homeProgress)
    }
    var radius: CGFloat { Page2DisplayCorner.radius + (Page2AppSwitcherView.cardCornerRadius - Page2DisplayCorner.radius) * cardProgress }
    var clipRadius: CGFloat {
        let card = Page2AppSwitcherView.cardCornerRadius * min(max(cardProgress, 0), 1)
        return card + (radius - card) * min(max(homeProgress, 0), 1)
    }
    var arcOpacity: CGFloat { max(0, 1 - cardProgress / 0.85) }
}

/// UIKit 内容单独持有，截图只截应用，不含弧线、后台和桌面。
struct Page2AppContentHost<Content: View>: UIViewControllerRepresentable {
    let id: String
    let interactive: Bool
    let visible: Bool
    let content: Content
    @Environment(\.self) private var environment
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    /// 隐藏宿主重交 rootView 的依据（plan-paging-decouple §3.4 B-6）：应用 id、交互 / 可见、它读的环境键（主题、楼层、外观、前后台）。
    /// 可见的宿主照旧每次 update 都重交（内容 / binding 随时可能变，后台应用变回前台也靠这一下拿到最新环境）；
    /// 隐藏的只在这把钥匙变了才重交——进出 page2 时外壳重跑（读 isActive），后台应用不再跟着整树重交。
    struct InputKey: Equatable {
        let id: String
        let interactive: Bool
        let visible: Bool
        let colorScheme: ColorScheme
        let dynamicType: DynamicTypeSize
        /// 前后台：隐藏宿主也要拿到 background → active 的边沿（桌面摘要靠它刷新，变回可见时补不回来，R2-03）
        let scenePhase: ScenePhase
        let theme: UUID?
        let profile: String?
    }

    final class Coordinator { var lastKey: InputKey? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private var inputKey: InputKey {
        InputKey(id: id, interactive: interactive, visible: visible, colorScheme: environment.colorScheme,
                 dynamicType: environment.dynamicTypeSize, scenePhase: environment.scenePhase, theme: themeManager?.themeChangeID, profile: profileManager?.currentProfile.id)
    }

    init(id: String, interactive: Bool, visible: Bool, @ViewBuilder content: () -> Content) {
        self.id = id
        self.interactive = interactive
        self.visible = visible
        self.content = content()
    }

    func makeUIViewController(context: Context) -> Page2AppHostingController<Page2HostedContent<ModifiedContent<Content, LaunchPage2ContentReady>>> {
        let host = Page2AppHostingController(rootView: Page2HostedContent(content: content.modifier(LaunchPage2ContentReady(id: id)), environment: environment))
        host.view.backgroundColor = .clear
        host.view.isHidden = !visible
        host.view.isUserInteractionEnabled = interactive
        host.view.accessibilityElementsHidden = !interactive
        Page2AppShell.shared.contentViews[id] = WeakContentView(host.view)
        context.coordinator.lastKey = inputKey
        return host
    }
    func updateUIViewController(_ host: Page2AppHostingController<Page2HostedContent<ModifiedContent<Content, LaunchPage2ContentReady>>>, context: Context) {
        // 拉进后台那一下桌面也会隐藏，但起手时的截图还对：再截一张换上去，模糊背景会在落定那帧变一下（⧫ 粟粟 10-11「突变」）
        if id == "home", !visible, !host.view.isHidden, !Page2AppShell.shared.showsSwitcher {
            Page2AppShell.shared.captureSnapshot(of: "home", deferPublication: true)
        }
        let key = inputKey
        let keyChanged = key != context.coordinator.lastKey
        context.coordinator.lastKey = key
        if visible || keyChanged {
            #if DEBUG || PERF_BENCH
            Page2StripProbe.hit("rootAssign:\(visible ? "visible" : "hidden"):\(id)")
            #endif
            if !visible { PagingFlip.hit(.hiddenAppRootAssign, excepted: "appInput:\(id)") }
            withTransaction(context.transaction) {
                host.rootView = Page2HostedContent(content: content.modifier(LaunchPage2ContentReady(id: id)), environment: environment)
            }
        }
        // SwiftUI 的 opacity/AX 修饰不保证移除独立 hosting 的 AX 子树。
        // 在 rootView 更新后同步真实 UIKit 可见性，后台卡片不再被旧节点遮挡。
        host.view.isHidden = !visible
        host.view.isUserInteractionEnabled = interactive
        host.view.accessibilityElementsHidden = !interactive
    }
    static func dismantleUIViewController(_ host: Page2AppHostingController<Page2HostedContent<ModifiedContent<Content, LaunchPage2ContentReady>>>, coordinator: Coordinator) {
        let shell = Page2AppShell.shared
        shell.contentViews = shell.contentViews.filter { $0.value.view != nil && $0.value.view !== host.view }
    }
}

/// 应用拉成卡片时整块被挪离屏幕顶，UIKit 按新位置把顶部安全区重算成 0，内容往上一跳；
/// 松手换成后台截图（全屏时截的，带顶部安全区）又跳回去（⧫ 粟粟 10-11「突变一下才变成后台」）。
/// 应用永远按全屏排版：顶部安全区钉在窗口的值，缺多少用 additionalSafeAreaInsets 补。
final class Page2AppHostingController<Root: View>: UIHostingController<Root> {
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        pinTop()
    }
    private func pinTop() {
        guard let window = view.window else { return }
        let natural = view.safeAreaInsets.top - additionalSafeAreaInsets.top
        let extra = max(0, window.safeAreaInsets.top - natural)
        if abs(additionalSafeAreaInsets.top - extra) > 0.5 { additionalSafeAreaInsets.top = extra }
    }
}

@MainActor final class WeakContentView {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}
#endif
