#if os(iOS)
import SwiftUI

/// SwiftUI 包装 `PagingViewController` 的 representable。
///
/// 用法：外层给 `.ignoresSafeArea()` 让 PagingContainerView 占满屏（含 safe area），
/// 这样每页 `UIHostingController.view` 的 bounds 也覆盖整屏，各页内部 `.ignoresSafeArea()`
/// 能正确延伸到 status bar / home indicator 区域。
///
/// Wallpaper：通过 `wallpaper: WallpaperConfig` 参数传入，PagingViewController 在 UIKit
/// 层 UIImageView + CAGradientLayer 渲染，绕开 SwiftUI `.background` 在 child HC +
/// keyboard safeArea 下的 frame 响应坑（见 docs/research-wallpaper-uikit-layer.md）。
///
/// Env 注入：child HC 不继承 parent SwiftUI env，ChatInputBar 消费的
/// ProviderManager / ProfileManager / PresetManager 在**这里**订阅 + 转注给每页 rootView，
/// 避免 ContentView 订阅这 3 个 @Observable Manager 引起 body 全量重算（master R1
/// revert 原罪防复活，见 docs/postmortem-kelivo-keyboard-wallpaper.md）。
/// themeManager / globalWBManager / modelContext 由外层 ContentView.injectPagingEnv 注入
/// 后作为 `*Page: AnyView` 传入，这里再叠加 3 个 Manager 的注入。
struct PagingContainerView: UIViewControllerRepresentable {
    let listPage: AnyView
    let chatPage: AnyView
    let dashPage: AnyView
    /// B2：输入条栈（挂 chat HC.view + keyboardLayoutGuide 约束），环境注入同 page 链
    let inputBar: AnyView
    /// 原 binding 链（`MP_PAGING_PAGESYNC=0`）才传：ContentView.body 读 iOSPage、这里比对后程序化翻页。
    /// PageSync 开着时传 nil——翻页走 PagingCommands，ContentView.body 不再因翻页重算（plan-paging-decouple §3.2）
    let currentPage: Int?
    /// 手势落定回写 iOSPage（下一 runloop）
    let onPageChanged: (Int) -> Void
    /// 三页 rootView 重交正当与否的内容键（C 的精确例外）
    let contentKey: PagingContentKey
    let disableScroll: Bool
    /// 宽屏悬浮面板形态：三页横滑收成固定聊天页，列表/更多改由浮层承载（传进来的
    /// listPage/dashPage 此时是 EmptyView，避免与浮层重复渲染）
    let widePanelMode: Bool
    let initialPage: Int
    let launchProfile: String
    let launchRequired: Bool
    let launchChatReady: () -> Bool
    let wallpaper: WallpaperConfig
    /// B2 窄版：流式响应期间 skip updatePages。用户几乎不会在 AI 吐字时切对话 / 切楼层 /
    /// 放贴纸，窗口安全。isStreaming 变化本身 @Observable，边界时刻（开始前 / 结束后）
    /// SwiftUI 天然触发 updateUIViewController，外部 parent 那次会照刷。
    /// Plan: docs/plan-paging-isStreaming-skip.md
    let isStreaming: Bool

    // 订阅 scope 从 ContentView 收敛到 Representable 层
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    /// 把 3 个 Manager 转注给 page。app 启动后这 3 个一般都 non-nil（App 注入保证），
    /// 用 if-let 防御性 unwrap，nil 时 page 不带这 3 个 env（ChatInputBar 不会 render，
    /// 但不 crash）。
    @ViewBuilder
    private func injectChatManagers<V: View>(_ page: V) -> some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = LaunchTrace.event("environmentInner", fields: ["providerManager": LaunchTrace.identity(providerManager),
            "profileManager": LaunchTrace.identity(profileManager), "presetManager": LaunchTrace.identity(presetManager),
            "profile": launchProfile])
        #endif
        if let prov = providerManager, let prof = profileManager, let pres = presetManager {
            page
                .environment(prov)
                .environment(prof)
                .environment(pres)
        } else {
            page
        }
    }

    func makeUIViewController(context: Context) -> PagingViewController {
        LaunchSplash.prepareForPageConstruction()
        let vc = PagingViewController(
            pages: [
                AnyView(injectChatManagers(listPage)),
                AnyView(injectChatManagers(chatPage)),
                AnyView(injectChatManagers(dashPage))
            ],
            inputBar: AnyView(injectChatManagers(inputBar)),
            initialPage: initialPage,
            launchProfile: launchProfile,
            launchRequired: launchRequired,
            launchChatReady: launchChatReady
        )
        vc.onPageChanged = { newPage in
            DispatchQueue.main.async {
                onPageChanged(newPage)
            }
        }
        // 禁滑两个来源：贴纸编辑 / 宽屏浮层形态。shield 只跟贴纸走——它挡的是
        // home indicator 区误触，宽屏下照样需要。
        vc.setScrollEnabled(!disableScroll && !widePanelMode)
        vc.setShieldHiddenByCaller(disableScroll)   // sticker 编辑时让 home indicator 给 toolbar
        vc.setWidePanelMode(widePanelMode)
        vc.applyWallpaper(wallpaper)
        return vc
    }

    static func dismantleUIViewController(_ vc: PagingViewController, coordinator: ()) {
        vc.cancelLaunchRegistration()
        PagingCommands.shared.unregister(vc)
    }

    func updateUIViewController(_ vc: PagingViewController, context: Context) {
        vc.configureLaunch(profile: launchProfile, required: launchRequired, chatReady: launchChatReady)
        vc.contentStreaming = isStreaming
        // B2 窄版 skip：流式响应期间不刷 3 个 HC rootView 避免 CardFlowView 整棵每 token
        // 重 diff。isStreaming false 时照旧 updatePages（= 原行为）。B2a 宽 signature 被
        // 证伪（贴纸 stale / 切对话 stale / 切楼层 race）后的保守版。
        if !isStreaming {
            // 内容键变了 = 这次重交是正当的（精确例外，按事件不按场景，plan §4.1）
            let cause = contentKey.changedName(from: vc.lastContentKey).map { "content:\($0)" }
            vc.lastContentKey = contentKey
            PagingFlip.withCause(cause) {
                vc.updatePages([
                    AnyView(injectChatManagers(listPage)),
                    AnyView(injectChatManagers(chatPage)),
                    AnyView(injectChatManagers(dashPage))
                ])
                vc.updateInputBar(AnyView(injectChatManagers(inputBar)))
            }
        } else {
            #if DEBUG
            print(String(format: "[PERF] updatePages skip (streaming) t=%.3f", CFAbsoluteTimeGetCurrent()))
            #endif
        }
        // 进宽屏先归位到 page1，再禁滑：拖动中进宽屏直接按 page1 收尾，不先回源页（R2-01）。
        // 宽屏归位必须排在下面那个 binding 归位之前：这样后面的 programmaticCurrentPage 比对就不会再补一次带动画的滑动。
        vc.setWidePanelMode(widePanelMode)
        vc.setScrollEnabled(!disableScroll && !widePanelMode)
        vc.setShieldHiddenByCaller(disableScroll)
        vc.applyWallpaper(wallpaper)
        if let currentPage, vc.programmaticCurrentPage != currentPage {
            vc.scrollToPage(currentPage, animated: true)
        }
    }
}
#endif
