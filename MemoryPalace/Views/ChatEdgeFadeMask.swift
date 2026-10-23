import SwiftUI

#if os(iOS)
struct ChatEdgeFadeMask: View {
    let enabled: Bool
    let inputFieldTop: CGFloat
    let inputBarBottom: CGFloat
    let keyboardVisible: Bool
    let hasInputGeometry: Bool
    /// 只要 minY：GeometryReader 闭包里直读 .global 会在任何全局位置变化（含翻页的水平平移、layerSync）时整段重跑；onGeometryChange 去重，minY 不变不触发（plan-paging-decouple A-7，同 Page2HomeView 顶栏）
    @State private var globalMinY: CGFloat = 0

    private static func transitionStops(from start: CGFloat, to end: CGFloat, fadingOut: Bool, opacityExponent: Double = 1) -> [Gradient.Stop] {
        (0...16).map { index in
            let t = Double(index) / 16
            let smooth = t * t * (3 - 2 * t)
            let opacity = fadingOut ? 1 - smooth : smooth
            return .init(color: .black.opacity(pow(opacity, opacityExponent)),
                         location: start + (end - start) * CGFloat(t))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if enabled {
                let height = max(geometry.size.height, 1)
                // 与回底按钮共用输入字段锚点；遮罩挂在翻转后的视口，y 按视觉方向递增。
                let fieldY = inputFieldTop - globalMinY
                let barBottomY = inputBarBottom - globalMinY
                let clearEnd = keyboardVisible && hasInputGeometry
                    ? min(height, max(0, barBottomY)) : height
                let topEnd = min(130, clearEnd * 0.5)
                let bottomStart = min(clearEnd, max(topEnd, hasInputGeometry ? fieldY - 40 : clearEnd - 140))
                LinearGradient(stops:
                    Self.transitionStops(from: 0, to: topEnd / height, fadingOut: false)
                    + Self.transitionStops(from: bottomStart / height, to: clearEnd / height, fadingOut: true, opacityExponent: 1.25)
                    + [.init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom)
            } else {
                Color.black
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { globalMinY = $0 }
        .ignoresSafeArea(.container, edges: .vertical)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
