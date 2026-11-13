import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 打开一个网页链接：iOS 按「链接打开方式」进花园浏览器或交给系统；mac 照旧交给默认浏览器
@MainActor
func openWebLink(_ url: URL) {
    #if os(iOS)
    GardenBrowser.open(url)
    #else
    NSWorkspace.shared.open(url)
    #endif
}

/// 自定义 OpenURLAction 的兜底（原来直接 .systemAction 的地方）：iOS 按「链接打开方式」进花园浏览器，否则交给系统。
/// 聊天正文在 UIKit 托管的子树里，根上的 gardenBrowserLinkRouting 环境传不进去，那里的 handler 要直接用这个。
@MainActor
func gardenOpenURLResult(_ url: URL) -> OpenURLAction.Result {
    #if os(iOS)
    GardenBrowser.handle(url)
    #else
    .systemAction(url)
    #endif
}

extension View {
    /// 根上挂一次：SwiftUI 树里走环境 openURL 的链接（设置页等），http(s) 进花园浏览器。
    /// 聊天正文 / 外链卡在 UIKit 托管的子树里收不到这个环境，各自用 gardenOpenURLResult / openWebLink。
    func gardenBrowserLinkRouting() -> some View {
        #if os(iOS)
        environment(\.openURL, OpenURLAction { url in GardenBrowser.handle(url) })
        #else
        self
        #endif
    }
}

#if os(iOS)
@MainActor
enum GardenBrowser {
    static func handle(_ url: URL) -> OpenURLAction.Result {
        openedInApp(url) ? .handled : .systemAction(url)
    }

    static func open(_ url: URL) {
        if !openedInApp(url) { UIApplication.shared.open(url) }
    }

    private static func openedInApp(_ url: URL) -> Bool {
        GardenBrowserRouting.destination(for: url, mode: GardenBrowserSettings.linkOpenMode) == .inApp && present(url)
    }

    /// 从最顶层的控制器弹 sheet（照思考过程面板：先到七成高、往上拖铺满、往下拖关；粟粟 11-08 选 A）。
    /// 从最顶层弹：sheet 里点的链接也能叠在上面。page2 浏览器 app 是内嵌全屏，不走这里
    @discardableResult
    static func present(_ url: URL) -> Bool {
        guard let top = topViewController() else { return false }
        let box = HostBox()
        let host = UIHostingController(rootView: GardenBrowserView(initialURL: url, onClose: { box.host?.dismiss(animated: true) }))
        box.host = host
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("garden72")) { $0.maximumDetentValue * 0.72 }, .large()]
            sheet.prefersGrabberVisible = true
        }
        top.present(host, animated: true)
        return true
    }

    /// AI 要动手（plan-ai-browser-operate）：用当前身份弹出来，直接铺满，你看着它操作
    @discardableResult
    static func presentForAI(_ url: URL, identity: BrowserIdentity) -> Bool {
        guard let top = topViewController() else { return false }
        let box = HostBox()
        let host = UIHostingController(rootView: GardenBrowserView(initialURL: url, identity: identity,
                                                                    onClose: { box.host?.dismiss(animated: true) }))
        box.host = host
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        top.present(host, animated: true)
        return true
    }

    private final class HostBox {
        weak var host: UIViewController?
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}
#endif
