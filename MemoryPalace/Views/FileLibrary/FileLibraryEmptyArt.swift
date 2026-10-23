import SwiftUI

/// 空状态的点点花：3 朵点点郁金香 + 2 颗点点金星 + 一条虚线地面（开屏页花园语言，坐标照小样 120×96）
struct FileLibraryEmptyArt: View {
    private static let flowers: [(x: CGFloat, color: UInt)] = [(40, 0xD99AA5), (62, 0x7FA58D), (82, 0xB3A2CC)]
    private static let petals: [(CGFloat, CGFloat)] = [(0, 0), (-4, 3), (4, 3), (-5, 8), (5, 8), (0, 5), (-2, 12), (2, 12), (0, 10), (-4, 13), (4, 13)]
    private static let stars: [(x: CGFloat, y: CGFloat, scale: CGFloat)] = [(96, 18, 1), (22, 30, 0.7)]
    private static let rays: [(CGFloat, CGFloat)] = [(0, -6), (0, -3), (0, 3), (0, 6), (-6, 0), (-3, 0), (3, 0), (6, 0), (0, 0)]

    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 120, y: size.height / 96)
            func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: UInt) {
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(Color(hex: color)))
            }
            for (k, flower) in Self.flowers.enumerated() {
                let top: CGFloat = 26 + CGFloat(k % 2) * 10
                var y = top + 18
                while y < 92 {
                    dot(flower.x, y, y.truncatingRemainder(dividingBy: 8) < 4 ? 1.5 : 1, 0x6F9A80)
                    y += 4.2
                }
                for (dx, dy) in Self.petals {
                    dot(flower.x + dx, top + dy, 2.1, flower.color)
                }
            }
            for star in Self.stars {
                for (dx, dy) in Self.rays {
                    dot(star.x + dx * star.scale, star.y + dy * star.scale, dx == 0 && dy == 0 ? 1.6 : 1, 0xB8954C)
                }
            }
            var ground = Path()
            ground.move(to: CGPoint(x: 8, y: 92))
            ground.addLine(to: CGPoint(x: 112, y: 92))
            ctx.stroke(ground, with: .color(Color(hex: 0xD5E0D8)), style: StrokeStyle(lineWidth: 1, dash: [1.5, 3]))
        }
        .accessibilityHidden(true)
    }
}
