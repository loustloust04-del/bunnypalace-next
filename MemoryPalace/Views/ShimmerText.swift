import SwiftUI

/// Shimmer 文字：masked gradient 从右往左扫过文字（transitions.dev #15，
/// 参数抄 orbs.jakubantalik.com：band 4 倍宽 / 2s linear / 40%-50%-60% 三停）。
/// 薄荷巧克力：底是巧克力 textPrimary 55%，扫过去的带是薄荷 branchIndicator。
/// TimelineView 驱动不用 repeatForever——外层 withAnimation 事务会覆盖子 view 的隐式动画把扫光杀掉。
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2)
            band(phase: phase)
        }
    }

    private func band(phase: CGFloat) -> some View {
        let base = Text(text)
            .font(FontManager.font(size: size))
            .foregroundStyle(Theme.textPrimary.opacity(0.55))

        return base.overlay(alignment: .leading) {
            GeometryReader { geo in
                let w = geo.size.width
                Text(text)
                    .font(FontManager.font(size: size))
                    .foregroundStyle(Theme.branchIndicator)
                    .mask(alignment: .leading) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.4),
                                .init(color: .white, location: 0.5),
                                .init(color: .clear, location: 0.6),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: w * 4)
                        .offset(x: -3 * w * (1 - phase))
                    }
            }
        }
    }
}
