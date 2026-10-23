#if os(iOS)
import SwiftUI
import UIKit

/// 位于图标和内容下方；与退开几何订阅同一个同步发布事务。
struct Page2StripBackdrop: UIViewRepresentable {
    let motion: Page2StripMotion
    final class BackdropView: UIView { var presentationID: UUID? }

    func makeUIView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.backgroundColor = UIColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1)
        view.isUserInteractionEnabled = false
        view.layer.opacity = 0
        view.presentationID = motion.addPresentation { [weak view] p in view?.layer.opacity = p > 0 ? 1 : 0 }
        Task { @MainActor [weak view] in
            guard let view, view.presentationID != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer.opacity = motion.progress > 0 ? 1 : 0
            CATransaction.commit()
        }
        return view
    }
    func updateUIView(_ view: BackdropView, context: Context) {}
    func makeCoordinator() -> Page2StripMotion { motion }
    static func dismantleUIView(_ view: BackdropView, coordinator: Page2StripMotion) {
        if let id = view.presentationID { coordinator.removePresentation(id) }
        view.presentationID = nil
    }
}

struct Page2StripPresentation: ViewModifier {
    @State private var shell = Page2AppShell.shared

    func body(content: Content) -> some View {
        Page2StripSurface(motion: shell.stripMotion, close: { shell.setStrip(open: false) },
                          content: content.coordinateSpace(name: "page2-app-scene")
                            .accessibilityAction(named: Text("切换应用")) { shell.setStrip(open: true) })
    }
}

struct Page2StripIconReveal: ViewModifier {
    @State private var shell = Page2AppShell.shared

    func body(content: Content) -> some View {
        let p = min(max(shell.stripProgress, 0), 1.2)
        content
            .offset(x: (1 - p) * 28)
            .opacity(Double(min(p * 1.4, 1)))
            .allowsHitTesting(p > 0.9)
            .accessibilityHidden(p < 0.9)
    }
}
#endif
