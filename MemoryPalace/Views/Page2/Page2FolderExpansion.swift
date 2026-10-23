#if os(iOS)
import SwiftUI

enum Page2FolderExpansion {
    static let duration = 0.64
    static func progress(_ phase: CGFloat, closingFrom: CGFloat? = nil) -> CGFloat {
        if let closingFrom { return progress(closingFrom) * CGFloat(Page2FolderClosing.remaining(Double(phase))) }
        let time = max(0, min(1, phase)) * duration
        if phase >= 1 { return 1 }
        let amplitude = 0.56310625
        if time >= 0.065 { return 1 - amplitude * exp(-14.25 * (time - 0.065)) }
        let u = time / 0.065
        return (3 * u * u - 2 * u * u * u) * (1 - amplitude) + (u * u * u - u * u) * (0.065 * 14.25 * amplitude)
    }
    static func child(_ phase: CGFloat, closingFrom: CGFloat? = nil) -> (scale: CGFloat, inset: CGFloat) {
        if let closingFrom {
            let initial = child(closingFrom), end = child(0)
            let remaining = CGFloat(Page2FolderClosing.remaining(Double(phase)))
            return (end.scale + (initial.scale - end.scale) * remaining, end.inset + (initial.inset - end.inset) * remaining)
        }
        let time = max(0, min(1, phase)) * duration
        let samples: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 13.333333 / 68, 11.333333), (0.065, 0.5294, 28.333),
            (0.10, 0.70, 31.333), (0.128333, 0.799, 33.333),
            (0.173333, 0.89, 33.333), (0.22, 0.945, 33.333),
            (0.273333, 0.975, 33.333), (0.36, 1, 33), (0.64, 1, 33)
        ]
        for index in 1..<samples.count where time <= samples[index].0 {
            let a = samples[index - 1], b = samples[index]
            let u = (time - a.0) / (b.0 - a.0)
            return (a.1 + (b.1 - a.1) * u, a.2 + (b.2 - a.2) * u)
        }
        return (1, 33)
    }
    static func rect(_ phase: CGFloat, panel: CGRect, origin: CGPoint, side: CGFloat, closingFrom: CGFloat? = nil) -> CGRect {
        let p = progress(phase, closingFrom: closingFrom)
        return CGRect(x: origin.x - side / 2 + (panel.minX - origin.x + side / 2) * p,
                      y: origin.y - side / 2 + (panel.minY - origin.y + side / 2) * p,
                      width: side + (panel.width - side) * p, height: side + (panel.height - side) * p)
    }
}

struct Page2FolderPanelExpansion: GeometryEffect {
    var phase: CGFloat
    let panel: CGRect
    let origin: CGPoint
    let side: CGFloat
    var closingFrom: CGFloat? = nil
    var animatableData: CGFloat { get { phase } set { phase = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let rect = Page2FolderExpansion.rect(phase, panel: panel, origin: origin, side: side, closingFrom: closingFrom)
        return ProjectionTransform(CGAffineTransform(a: rect.width / panel.width, b: 0, c: 0, d: rect.height / panel.height,
                                                     tx: rect.minX - panel.minX, ty: rect.minY - panel.minY))
    }
}

struct Page2FolderContentExpansion: GeometryEffect {
    var phase: CGFloat
    let panel: CGRect
    let side: CGFloat
    var closingFrom: CGFloat? = nil
    var animatableData: CGFloat { get { phase } set { phase = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = Page2FolderExpansion.progress(phase, closingFrom: closingFrom)
        let sx = (side + (panel.width - side) * p) / panel.width
        let sy = (side + (panel.height - side) * p) / panel.height
        let child = Page2FolderExpansion.child(phase, closingFrom: closingFrom)
        let unit = panel.width / Page2FolderGeometry.referenceWidth
        return ProjectionTransform(CGAffineTransform(a: child.scale / sx, b: 0, c: 0, d: child.scale / sy,
                                                     tx: (child.inset - 33 * child.scale) * unit / sx,
                                                     ty: (child.inset - 33 * child.scale) * unit / sy))
    }
}

struct Page2FolderTitleReveal: ViewModifier, Animatable {
    var phase: CGFloat
    var closingFrom: CGFloat? = nil
    var animatableData: CGFloat { get { phase } set { phase = newValue } }
    func body(content: Content) -> some View {
        let value = max(0, min(1, ((closingFrom ?? phase) * Page2FolderExpansion.duration - 0.13) / 0.27))
        content.opacity(value * value * (3 - 2 * value) * (closingFrom == nil ? 1 : CGFloat(Page2FolderClosing.titleOpacity(Double(phase)))))
    }
}
@MainActor @Observable
final class Page2FolderMotionState {
    var phase: CGFloat = 0
    var closingFrom: CGFloat?
    var openedAt: TimeInterval?
    var active = false
    var generation = UUID()
    var duration: Double { closingFrom == nil ? Page2FolderExpansion.duration : Page2FolderClosing.duration }
}
#endif
