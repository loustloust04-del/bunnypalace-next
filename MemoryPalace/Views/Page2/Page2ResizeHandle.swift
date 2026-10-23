#if os(iOS)
import SwiftUI
import UIKit

struct Page2ResizeHandle: UIViewControllerRepresentable {
    let identifier: String
    let title: String
    var onGesture: (UIGestureRecognizer.State, CGSize) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onGesture = onGesture
        controller.view.accessibilityIdentifier = identifier
        controller.view.accessibilityLabel = "调整\(title)尺寸"
        return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.onGesture = onGesture }
    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) { controller.cancel() }

    final class Controller: UIViewController {
        var onGesture: ((UIGestureRecognizer.State, CGSize) -> Void)?
        private let host = UIHostingController(rootView: GlassCorner())
        private let gesture = UILongPressGestureRecognizer()
        private var start: CGPoint?
        private var parents: [ObjectIdentifier] = []

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isAccessibilityElement = true
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            host.view.isUserInteractionEnabled = false
            addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
            gesture.minimumPressDuration = 0
            gesture.addTarget(self, action: #selector(changed))
            view.addGestureRecognizer(gesture)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            host.view.frame = view.bounds
            var ancestor = view.superview
            while let current = ancestor {
                // 翻页 scrollView 的 pan 挂在舞台视图上（PagingViewController.stageMode），不在 scrollView 自己的祖先链里
                var pans = (current.gestureRecognizers ?? []).filter { $0 === ($0.delegate as? UIScrollView)?.panGestureRecognizer }
                if let scroll = current as? UIScrollView { pans.append(scroll.panGestureRecognizer) }
                for pan in pans where !parents.contains(ObjectIdentifier(pan)) {
                    pan.require(toFail: gesture)
                    parents.append(ObjectIdentifier(pan))
                }
                ancestor = current.superview
            }
        }
        @objc private func changed() {
            guard let window = view.window else { cancel(); return }
            let point = gesture.location(in: window)
            if gesture.state == .began { start = point }
            guard let start else { return }
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            onGesture?(gesture.state, delta)
            if [.ended, .cancelled, .failed].contains(gesture.state) { self.start = nil }
        }
        func cancel() {
            if start != nil { onGesture?(.cancelled, .zero) }
            start = nil
            gesture.isEnabled = false
            onGesture = nil
        }
    }
}

private struct GlassCorner: View {
    var body: some View {
        Color.clear.frame(width: 32, height: 32)
            .glassEffect(.clear, in: ResizeCornerShape())
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }
}

private struct ResizeCornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var arc = Path()
        let width = min(rect.width, rect.height)
        let inset = width * 6 / 32
        arc.addArc(center: CGPoint(x: rect.minX + inset, y: rect.minY + inset), radius: width * 20 / 32,
                   startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        return arc.strokedPath(StrokeStyle(lineWidth: width * 12 / 32, lineCap: .round))
    }
}
#endif
