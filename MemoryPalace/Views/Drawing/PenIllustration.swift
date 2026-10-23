import SwiftUI

/// 托盘 / 设置里的笔插画（docs/design-page1-画板UI.html 的 SVG 1:1 搬，30×96 坐标系），笔尖是当前颜色
struct PenIllustration: View {
    let tool: BoardTool
    let tip: Color

    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 30, y: size.height / 96)
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0, _ c: Color) {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .color(c))
            }
            func poly(_ pts: [(CGFloat, CGFloat)], _ c: Color) {
                var p = Path()
                p.addLines(pts.map { CGPoint(x: $0.0, y: $0.1) })
                p.closeSubpath()
                ctx.fill(p, with: .color(c))
            }
            let steel = Color(brushHex: "#d7d9dc"), band = Color(brushHex: "#c9a96a"), slit = Color(brushHex: "#8a8f96")
            switch tool {
            case .watercolor:
                rect(11, 34, 8, 62, r: 3, Color(brushHex: "#d9c6ad"))
                rect(10, 26, 10, 12, r: 2, Color(brushHex: "#c9ccd1"))
                var p = Path()
                p.move(to: CGPoint(x: 10, y: 27)); p.addQuadCurve(to: CGPoint(x: 20, y: 27), control: CGPoint(x: 15, y: 2)); p.closeSubpath()
                ctx.fill(p, with: .color(tip))
            case .pen:
                rect(9, 40, 12, 56, r: 5, Color(brushHex: "#2f3a45"))
                rect(9, 36, 12, 6, band)
                poly([(9, 37), (15, 6), (21, 37)], steel)
                rect(14.5, 9, 1, 21, slit)
                ctx.fill(Path(ellipseIn: CGRect(x: 13.4, y: 28.4, width: 3.2, height: 3.2)), with: .color(slit))
                poly([(14, 6), (16, 6), (15, 3)], tip)
            case .nib:
                rect(9, 40, 12, 56, r: 5, Color(brushHex: "#6b3f3a"))
                rect(9, 36, 12, 6, band)
                poly([(9, 37), (11, 8), (19, 8), (21, 37)], steel)
                rect(11, 5, 8, 4, tip)
                rect(14.5, 10, 1, 20, slit)
            case .pencil:
                rect(10, 30, 10, 66, Color(brushHex: "#f2d9a6"))
                rect(13, 30, 4, 66, Color(brushHex: "#e8c98e"))
                poly([(10, 31), (15, 8), (20, 31)], Color(brushHex: "#ead2b0"))
                poly([(13.3, 16), (15, 8), (16.7, 16)], tip)
            case .marker:
                rect(8, 34, 14, 62, r: 4, Color(brushHex: "#f4f2ee"))
                rect(8, 34, 14, 10, tip.opacity(0.85))
                poly([(10, 35), (12, 14), (18, 10), (20, 35)], Color(brushHex: "#e9e6e0"))
                poly([(12, 14), (18, 10), (18, 16), (12, 18)], tip)
            case .crayon:
                rect(9, 30, 12, 66, r: 2, tip)
                rect(9, 44, 12, 40, .white.opacity(0.35))
                poly([(9, 31), (13, 14), (17, 14), (21, 31)], tip)
            case .monoline:
                rect(10, 30, 10, 66, r: 4, Color(brushHex: "#ece8e1"))
                poly([(10, 31), (13.5, 14), (16.5, 14), (20, 31)], Color(brushHex: "#d9d4cc"))
                rect(14, 7, 2, 8, tip)
            case .eraser:
                rect(9, 22, 12, 74, r: 3, Color(brushHex: "#f4f2ee"))
                rect(9, 22, 12, 24, r: 3, Color(brushHex: "#f0b8b0"))
            case .lasso:
                rect(10, 34, 10, 62, r: 4, Color(brushHex: "#ece8e1"))
                poly([(10, 35), (13, 22), (17, 22), (20, 35)], Color(brushHex: "#d9d4cc"))
                ctx.stroke(Path(ellipseIn: CGRect(x: 6, y: 5, width: 18, height: 14)), with: .color(slit),
                           style: StrokeStyle(lineWidth: 1.4, dash: [2.5, 2]))
            }
        }
        .shadow(color: Color(red: 0.24, green: 0.16, blue: 0.08).opacity(0.15), radius: 1.5, y: 2)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// "#rrggbb"（画板 / 便利贴的颜色都这么存）
    init(brushHex hex: String) { self.init(cgColor: BrushEngine.cgColor(hex)) }
}
