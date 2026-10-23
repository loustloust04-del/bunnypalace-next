import SwiftUI

#if os(iOS)
import VariableBlur
struct ChatContentEdgeBlur: UIViewRepresentable {
    let radius: CGFloat
    let inputBarBottom: CGFloat
    let keyboardVisible: Bool
    let enabled: Bool

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {
        view.radius = radius
        view.inputBarBottom = inputBarBottom
        view.keyboardVisible = keyboardVisible
        view.enabled = enabled
        view.attach()
    }

    static func dismantleUIView(_ view: AttachmentView, coordinator: ()) {
        view.detach()
    }

    final class AttachmentView: UIView {
        var radius: CGFloat = 0
        var inputBarBottom: CGFloat = 0
        var keyboardVisible = false
        var enabled = false
        private weak var scrollView: UIScrollView?
        private weak var targetView: UIView?
        private var boundsObservation: NSKeyValueObservation?
        private var installedFilter: NSObject?
        private var previousOpaque: Bool?
        private var previousLayerOpaque: Bool?
        private var lastGeometry: Geometry?

        private struct Geometry: Equatable {
            let height: CGFloat
            let topY: CGFloat
            let bottomY: CGFloat
            let radius: CGFloat
            let barBottom: CGFloat
            let keyboardVisible: Bool
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }

        func attach() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    if scrollView !== scroll {
                        detach()
                        scrollView = scroll
                        boundsObservation = scroll.observe(\.bounds) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.apply() }
                        }
                    }
                    apply()
                    return
                }
                ancestor = view.superview
            }
        }

        func detach() {
            boundsObservation = nil
            removeFilter()
            scrollView = nil
            targetView = nil
            lastGeometry = nil
        }

        private func removeFilter() {
            if let filter = installedFilter, let targetView {
                targetView.layer.filters = targetView.layer.filters?.filter { ($0 as? NSObject) !== filter }
                if let previousOpaque { targetView.isOpaque = previousOpaque }
                if let previousLayerOpaque { targetView.layer.isOpaque = previousLayerOpaque }
            }
            installedFilter = nil
            previousOpaque = nil
            previousLayerOpaque = nil
        }

        private func apply() {
            guard let scroll = scrollView else { return }
            guard enabled, radius > 0, scroll.bounds.height > 0, window != nil else {
                removeFilter()
                lastGeometry = nil
                return
            }
            var responder: UIResponder? = scroll
            var host: UIView?
            while let current = responder {
                if let controller = current as? UIViewController {
                    host = controller.view
                    break
                }
                responder = current.next
            }
            guard let host else { return }
            // 只使用独占这个 ScrollView 的透明固定容器，禁止退回整个 hosting view。
            guard let target = scroll.superview, target !== host,
                  target.bounds.origin == .zero,
                  target.subviews.count == 1, target.subviews.first === scroll,
                  target.layer.sublayers?.count == 1, target.layer.sublayers?.first === scroll.layer,
                  target.layer.contents == nil,
                  (target.layer.backgroundColor?.alpha ?? 0) == 0 else {
                removeFilter()
                lastGeometry = nil
                return
            }
            if targetView !== target {
                removeFilter()
                targetView = target
                lastGeometry = nil
            }
            let top = (target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.minY), to: host).y * 2).rounded() / 2
            let bottom = (target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.maxY), to: host).y * 2).rounded() / 2
            let geometry = Geometry(height: target.bounds.height, topY: top, bottomY: bottom,
                                    radius: radius, barBottom: inputBarBottom, keyboardVisible: keyboardVisible)
            guard geometry != lastGeometry else { return }
            let end = inputBarBottom > 0 ? inputBarBottom + (keyboardVisible ? 10 : 40) : host.bounds.maxY
            let start = end - (keyboardVisible ? 60 : 120)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rows = max(2, Int(ceil(target.bounds.height)))
            let mask = UIGraphicsImageRenderer(size: CGSize(width: 1, height: rows), format: format).image { context in
                for row in 0..<rows {
                    let fraction = CGFloat(row) / CGFloat(rows - 1)
                    let visualY = top + (bottom - top) * fraction
                    let t = min(1, max(0, (130 - visualY) / 130))
                    let b = min(1, max(0, (visualY - start) / (end - start)))
                    // 匹配原渐进半径与 smoothstep 混合的方差；只过滤消息层，不采样壁纸。
                    let topAmount = t * sqrt(t * t * (3 - 2 * t)) / 3
                    let bottomAmount = b * sqrt(b * b * (3 - 2 * b))
                    context.cgContext.setFillColor(UIColor.black.withAlphaComponent(max(topAmount, bottomAmount)).cgColor)
                    context.cgContext.fill(CGRect(x: 0, y: row, width: 1, height: 1))
                }
            }
            let source = VariableBlurUIView(maxBlurRadius: radius * 3)
            guard let filter = source.subviews.first?.layer.filters?.first as? NSObject,
                  let image = mask.cgImage else { return }
            filter.setValue(image, forKey: "inputMaskImage")
            filter.setValue(false, forKey: "inputNormalizeEdges")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            removeFilter()
            previousOpaque = target.isOpaque
            previousLayerOpaque = target.layer.isOpaque
            target.isOpaque = false
            target.layer.isOpaque = false
            target.layer.filters = (target.layer.filters ?? []) + [filter]
            CATransaction.commit()
            installedFilter = filter
            lastGeometry = geometry
        }
    }
}
#endif
