import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// 编辑类 sheet 防误关（plan A3）：有没保存的改动时不让下滑关掉，下滑 / 点「取消」都问「放弃改动？」。
    /// 「取消」按钮自己判断：有改动置 `confirming`，没有直接关。
    func discardChangesGuard(isDirty: Bool, confirming: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        self
            .interactiveDismissDisabled(isDirty)
            #if os(iOS)
            .background(DismissAttemptHook(onAttempt: { if isDirty { confirming.wrappedValue = true } }))
            #endif
            .alert("放弃改动？", isPresented: confirming) {
                Button("放弃", role: .destructive, action: onDiscard)
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("改了还没保存，放弃就回到打开前的样子。")
            }
    }
}

#if os(iOS)
/// 拿到 sheet 的 presentationController，在 SwiftUI 自己的 delegate 外面套一层，只多接「下滑被拦下」这一下，其余原样转发
private struct DismissAttemptHook: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.proxy.onAttempt = onAttempt
        controller.install()
    }

    final class Controller: UIViewController {
        let proxy = Proxy()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        func install() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard let presentation = root.presentationController, presentation.delegate !== proxy else { return }
            proxy.forward = presentation.delegate
            presentation.delegate = proxy
        }
    }

    final class Proxy: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var forward: UIAdaptivePresentationControllerDelegate?
        var onAttempt: () -> Void = {}

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forward?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            forward?.responds(to: aSelector) == true ? forward : nil
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            forward?.presentationControllerDidAttemptToDismiss?(presentationController)
            onAttempt()
        }
    }
}
#endif
