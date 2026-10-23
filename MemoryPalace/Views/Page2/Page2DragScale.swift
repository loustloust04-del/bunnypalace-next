#if os(iOS)
import SwiftUI

struct Page2DragScale: GeometryEffect {
    var scale: CGFloat
    let iconHeight: CGFloat
    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: size.width / 2, y: iconHeight / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -iconHeight / 2))
    }
}
#endif
