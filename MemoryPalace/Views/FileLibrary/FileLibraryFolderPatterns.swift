import SwiftUI

/// 前片上的花园纹样（点点花 / 点点星 / 雪花 / 珠串）：一只文件夹一个 Canvas 画完。
/// 坐标照小样，viewBox 130×58（原 180×80，整体放大约 1.38 倍），按 slice（铺满、居中裁）缩放。
struct FileLibraryFolderPatternView: View {
    let pattern: FileLibraryFolderLook.Pattern
    let ink: Color

    var body: some View {
        Canvas { ctx, size in
            let s = max(size.width / Self.box.width, size.height / Self.box.height)
            let ox = (size.width - Self.box.width * s) / 2
            let oy = (size.height - Self.box.height * s) / 2
            for dot in Self.dots(pattern) {
                let r = dot.r * s
                let rect = CGRect(x: ox + dot.x * s - r, y: oy + dot.y * s - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(ink.opacity(dot.opacity)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    struct Dot {
        let x: CGFloat
        let y: CGFloat
        let r: CGFloat
        let opacity: Double
    }

    static let box = CGSize(width: 130, height: 58)

    static func dots(_ pattern: FileLibraryFolderLook.Pattern) -> [Dot] {
        switch pattern {
        case .flower: flower
        case .star: star
        case .snow: snow
        case .beads: beads
        }
    }

    private static let flower: [Dot] = {
        let petals: [(CGFloat, CGFloat)] = [(0, 0), (-3, 2), (3, 2), (0, 4), (-2, -2.5), (2, -2.5)]
        var out: [Dot] = []
        for row in 0..<3 {
            for col in 0..<7 {
                let x = CGFloat(14 + col * 24 + (row % 2) * 12)
                let y = CGFloat(14 + row * 24)
                out += petals.map { Dot(x: x + $0.0, y: y + $0.1, r: 1.5, opacity: 0.55) }
            }
        }
        return out
    }()

    private static let star: [Dot] = {
        let rays: [(CGFloat, CGFloat)] = [(0, -4), (0, -2), (0, 2), (0, 4), (-4, 0), (-2, 0), (2, 0), (4, 0), (0, 0)]
        var out: [Dot] = []
        for row in 0..<3 {
            for col in 0..<6 {
                let x = CGFloat(18 + col * 28 + (row % 2) * 14)
                let y = CGFloat(16 + row * 24)
                out += rays.map { Dot(x: x + $0.0, y: y + $0.1, r: $0 == (0, 0) ? 1.3 : 0.8, opacity: 0.6) }
            }
        }
        return out
    }()

    private static let snow: [Dot] = {
        var out: [Dot] = []
        for row in 0..<3 {
            for col in 0..<6 {
                let x = CGFloat(16 + col * 30 + (row % 2) * 15)
                let y = CGFloat(16 + row * 26)
                for arm in 0..<6 {
                    let t = CGFloat(arm) * .pi / 3
                    for d in 1...3 {
                        let step = CGFloat(d) * 2.2
                        out.append(Dot(x: x + cos(t) * step, y: y + sin(t) * step, r: d == 3 ? 0.9 : 0.75, opacity: 0.62))
                    }
                }
                out.append(Dot(x: x, y: y, r: 1.2, opacity: 0.7))
            }
        }
        return out
    }()

    private static let beads: [Dot] = {
        var out: [Dot] = []
        for row in 0..<4 {
            for col in 0..<26 {
                out.append(Dot(x: CGFloat(6 + col * 7), y: CGFloat(12 + row * 18), r: col % 2 == 1 ? 1 : 1.8, opacity: 0.5))
            }
        }
        return out
    }()
}
