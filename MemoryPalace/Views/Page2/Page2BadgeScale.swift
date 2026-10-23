#if os(iOS)
import SwiftUI

struct Page2BadgeScale: GeometryEffect {
    var scale: CGFloat
    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: max(0.001, scale), y: max(0.001, scale))
            .translatedBy(x: -size.width / 2, y: -size.height / 2))
    }
}
#endif
