#if os(iOS)
import SwiftUI

struct Page2EditingMotion: ViewModifier {
    var enabled: Bool
    var seed: Int
    var amplitude: Double = 1.659
    var pivotHeight: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isPage2Active) private var desktopActive

    private var active: Bool { enabled && desktopActive && scenePhase == .active && !reduceMotion }

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let phase = Double(seed) * 2.399963229728653
            GlassEffectContainer(spacing: 0) { content }
                .compositingGroup()
                .modifier(Page2RigidPose(
                angle: active ? amplitude * sin(time * 2 * .pi * 3.905 + phase + 0.26) * .pi / 180 : 0,
                horizontal: active ? sin(time * 2 * .pi * 3.73 + phase + 1.486) : 0,
                vertical: active ? sin(time * 2 * .pi * 3.52 + phase - 2.229) : 0,
                driftRatio: 1.187 / 203.8 * min(1, amplitude / 1.659),
                pivotHeight: pivotHeight
            ).ignoredByLayout())
        }
    }
}

private struct Page2RigidPose: GeometryEffect {
    var angle: Double
    var horizontal: Double
    var vertical: Double
    let driftRatio: Double
    let pivotHeight: CGFloat?

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(angle, AnimatablePair(horizontal, vertical)) }
        set { angle = newValue.first; horizontal = newValue.second.first; vertical = newValue.second.second }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let pivot = CGPoint(x: size.width / 2, y: (pivotHeight ?? size.height) / 2)
        let drift = min(size.width, pivotHeight ?? size.height) * driftRatio
        return ProjectionTransform(CGAffineTransform(translationX: pivot.x + horizontal * drift, y: pivot.y + vertical * drift)
            .rotated(by: angle)
            .translatedBy(x: -pivot.x, y: -pivot.y))
    }
}
#endif
