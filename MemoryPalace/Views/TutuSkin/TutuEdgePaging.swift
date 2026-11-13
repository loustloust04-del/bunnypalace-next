#if PERSONAL_APPS
import Foundation

enum TutuEdgePaging {
    enum Edge { case left, right }

    static let activationWidth: CGFloat = 16
    static let flickVelocity: CGFloat = 600

    static func acceptsStart(x: CGFloat, width: CGFloat, edge: Edge) -> Bool {
        guard width > 0, x >= 0, x <= width else { return false }
        switch edge {
        case .left: return x <= activationWidth
        case .right: return x >= width - activationWidth
        }
    }

    static func inwardTranslation(_ translation: CGFloat, edge: Edge) -> CGFloat {
        max(0, edge == .left ? translation : -translation)
    }

    static func offset(source: Int, pageCount: Int, width: CGFloat, translation: CGFloat, edge: Edge) -> CGFloat {
        guard width > 0, pageCount > 0 else { return 0 }
        let source = min(max(source, 0), pageCount - 1)
        let distance = min(inwardTranslation(translation, edge: edge), width)
        let direction: CGFloat = edge == .left ? -1 : 1
        let proposed = CGFloat(source) * width + direction * distance
        let maximum = CGFloat(pageCount - 1) * width
        if proposed < 0 { return -rubberBand(-proposed, width: width) }
        if proposed > maximum { return maximum + rubberBand(proposed - maximum, width: width) }
        return proposed
    }

    static func targetPage(source: Int, pageCount: Int, width: CGFloat, translation: CGFloat,
                           velocity: CGFloat, edge: Edge, cancelled: Bool = false) -> Int {
        guard pageCount > 0 else { return 0 }
        let source = min(max(source, 0), pageCount - 1)
        guard !cancelled, width > 0 else { return source }
        let inwardVelocity = edge == .left ? velocity : -velocity
        let passedThreshold = inwardTranslation(translation, edge: edge) > width / 3
        let commits = inwardVelocity >= flickVelocity || (passedThreshold && inwardVelocity > -flickVelocity)
        guard commits else { return source }
        return min(max(source + (edge == .left ? -1 : 1), 0), pageCount - 1)
    }

    private static func rubberBand(_ distance: CGFloat, width: CGFloat) -> CGFloat {
        let scaled = distance * 0.55
        return width * scaled / (width + scaled)
    }
}
#endif
