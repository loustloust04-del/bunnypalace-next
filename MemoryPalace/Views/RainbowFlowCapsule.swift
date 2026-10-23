#if os(iOS)
import SwiftUI

// MARK: - 彩虹流光胶囊（退役组件橱窗）

/// 「帮我写」AI 生成按钮的流光版退役件：斜角底渐变 + 三团高模糊光斑按不同周期
/// 利萨如轨迹漂移（11/14/17 秒，不同步所以不规则），裁剪进胶囊。
/// 没舍得删，挪到「设置 → 开发调试」当组件橱窗。
struct RainbowFlowCapsule: View {
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Capsule().fill(LinearGradient(
                        colors: [Color(red: 0.96, green: 0.62, blue: 0.72),
                                 Color(red: 0.99, green: 0.82, blue: 0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    blob(Color(red: 0.94, green: 0.48, blue: 0.66), w: w, h: h, t: t,
                         periodX: 11, periodY: 7.3, phase: 0)
                    blob(Color(red: 0.72, green: 0.56, blue: 0.88), w: w, h: h, t: t,
                         periodX: 14, periodY: 9.1, phase: 2.1)
                    blob(Color(red: 0.52, green: 0.82, blue: 0.76), w: w, h: h, t: t,
                         periodX: 17, periodY: 11.7, phase: 4.4)
                }
            }
        }
        .clipShape(Capsule())
        .shadow(color: Color(red: 0.90, green: 0.60, blue: 0.75).opacity(0.5), radius: 6, y: 2)
    }

    private func blob(_ color: Color, w: CGFloat, h: CGFloat, t: Double,
                      periodX: Double, periodY: Double, phase: Double) -> some View {
        let size = w * 0.85
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: size * 0.22)
            .position(x: w * (0.5 + 0.45 * sin(2 * .pi * t / periodX + phase)),
                      y: h * (0.5 + 1.1 * cos(2 * .pi * t / periodY + phase * 1.7)))
    }
}
#endif
