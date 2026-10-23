import SwiftUI

// MARK: - 小芽 v2 · 剪纸舞台（plan-小芽-v2 §3.6；设计 docs/design-小芽-v2-剪纸舞台.html）
// 舞台是一件自带颜色的纸剧场，不跟亮暗主题换底色；只有天上的东西跟主题：亮色太阳、暗色月亮。
// 整台用一个 Canvas 画；底边锯齿 / 撕纸边是裁剪形状，不依赖下面聊天区的颜色。

enum XiaoyaStageTheme: String, CaseIterable, Identifiable {
    case mint, rouge, circus, collage

    static let storageKey = "xiaoya.stageTheme"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mint: "薄荷夜场"
        case .rouge: "胭脂剧场"
        case .circus: "粉绿马戏"
        case .collage: "拼贴剧场"
        }
    }

    func palette(dark: Bool) -> XiaoyaStagePalette {
        switch self {
        case .mint:
            XiaoyaStagePalette(backdrop: .xy(0x2F5D57), valance: .xy(0x264C47), curtainA: .xy(0xF2EEE4), curtainB: .xy(0x9DBFA9),
                               flagA: .xy(0xC9694F), flagB: .xy(0xF2EEE4), star: .xy(0xF2EEE4), celestial: .xy(0xE9DFC8),
                               floor: .xy(0x1F3F3A), ticket: .xy(0xF2EEE4), ticketInk: .xy(0x23302A), onBackdrop: .xy(0xF2EEE4))
        case .rouge:
            XiaoyaStagePalette(backdrop: .xy(0x2D5B66), valance: .xy(0x244B55), curtainA: .xy(0xF2EDE3), curtainB: .xy(0xD65A43),
                               flagA: .xy(0xF2EDE3), flagB: .xy(0xB8805A), star: .xy(0xC99A64), celestial: .xy(0xC99A64),
                               floor: .xy(0x1E3F47), ticket: .xy(0xF2EDE3), ticketInk: .xy(0x2A2A2A), onBackdrop: .xy(0xF2EDE3))
        case .circus:
            XiaoyaStagePalette(backdrop: .xy(0x1F4E4A), valance: .xy(0x193F3C), curtainA: .xy(0xF6EDE8), curtainB: .xy(0xE6B3AC),
                               flagA: .xy(0x3F7D4E), flagB: .xy(0xF6EDE8), star: .xy(0xC98E6C), celestial: .xy(0xC98E6C),
                               floor: .xy(0x15332F), ticket: .xy(0xF6EDE8), ticketInk: .xy(0x2A2A2A), onBackdrop: .xy(0xF6EDE8))
        case .collage:
            // 暗色时整张纸换夜蓝：亮羊皮纸块在暗色 UI 里太刺眼
            XiaoyaStagePalette(backdrop: dark ? .xy(0x2E3656) : .xy(0xEFE5D0), valance: .xy(0x8A6436),
                               curtainA: .xy(0x2F4A8A), curtainB: .xy(0xF1EAD9), flagA: .xy(0xB23A22), flagB: .xy(0x6E1E14),
                               star: .xy(0xB8863B), celestial: .xy(0xE3BE7A), floor: dark ? .xy(0xC9B38A) : .xy(0x7A5A3C),
                               ticket: .xy(0xF7F0DF), ticketInk: .xy(0x3A2A1C), onBackdrop: dark ? .xy(0xF1EAD9) : .xy(0x3A2A1C))
        }
    }

    static var current: XiaoyaStageTheme {
        UserDefaults.standard.string(forKey: storageKey).flatMap(XiaoyaStageTheme.init(rawValue:)) ?? .mint
    }
}

struct XiaoyaStagePalette {
    var backdrop: Color
    var valance: Color
    var curtainA: Color
    var curtainB: Color
    var flagA: Color
    var flagB: Color
    var star: Color
    var celestial: Color
    /// 条纹帘剧场：地台；拼贴剧场：手描边线色
    var floor: Color
    var ticket: Color
    var ticketInk: Color
    /// 直接压在幕布底色上的字 / 钮的颜色
    var onBackdrop: Color
}

extension Color {
    fileprivate static func xy(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - 布景

struct XiaoyaStageBackdrop: View {
    let theme: XiaoyaStageTheme
    let dark: Bool
    let collapsed: Bool
    /// 顶部安全区高度：布景漫到状态栏下面，装饰从这条线往下排
    var topInset: CGFloat = 0

    static let edgeDepth: CGFloat = 8

    var body: some View {
        let p = theme.palette(dark: dark)
        Canvas { ctx, size in
            ctx.clip(to: bottomEdge(size))
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(p.backdrop))
            if theme == .collage {
                drawCollage(&ctx, size, p)
            } else {
                drawStriped(&ctx, size, p)
            }
        }
    }

    // MARK: 条纹帘剧场（薄荷 / 胭脂 / 粉绿）

    private func drawStriped(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: XiaoyaStagePalette) {
        let w = size.width, h = size.height, top = topInset
        let bottom = h - Self.edgeDepth
        if !collapsed {
            // 天上的东西都排在上半部：下半部是小芽和名字小票
            celestial(&ctx, CGPoint(x: w * 0.62, y: top + (bottom - top) * 0.34), r: 15, color: p.celestial, face: nil, backdrop: p.backdrop)
            for (fx, fy, r) in [(0.4, 0.3, 9.0), (0.78, 0.26, 6.0), (0.5, 0.44, 5.0), (0.3, 0.22, 4.0)] {
                ctx.fill(eightPointStar(CGPoint(x: w * fx, y: top + (bottom - top) * fy), r: r), with: .color(p.star))
            }
            ctx.fill(Path(CGRect(x: 0, y: bottom - 30, width: w, height: 30)), with: .color(p.floor))
            let curtainW = min(78, w * 0.24)
            for leading in [true, false] {
                let path = curtainPath(w: w, top: top + 12, bottom: bottom - 24, width: curtainW, leading: leading)
                ctx.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.28), radius: 0, x: 1.5, y: 3))
                    layer.clip(to: path)
                    var x: CGFloat = leading ? 0 : w - curtainW - 12
                    var i = 0
                    while x < (leading ? curtainW + 12 : w) {
                        layer.fill(Path(CGRect(x: x, y: top, width: 9, height: bottom - top)), with: .color(i % 2 == 0 ? p.curtainA : p.curtainB))
                        x += 9; i += 1
                    }
                }
            }
        }
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.28), radius: 0, x: 1.5, y: 3))
            layer.fill(Path(CGRect(x: 0, y: top, width: w, height: 12)), with: .color(p.valance))
            var x: CGFloat = 0
            var i = 0
            while x < w {
                var tri = Path()
                tri.move(to: CGPoint(x: x, y: top + 11))
                tri.addLine(to: CGPoint(x: x + 20, y: top + 11))
                tri.addLine(to: CGPoint(x: x + 10, y: top + (collapsed ? 24 : 33)))
                tri.closeSubpath()
                layer.fill(tri, with: .color(i % 2 == 0 ? p.flagA : p.flagB))
                x += 20; i += 1
            }
        }
    }

    private func curtainPath(w: CGFloat, top: CGFloat, bottom: CGFloat, width: CGFloat, leading: Bool) -> Path {
        var path = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: leading ? x : w - x, y: y) }
        path.move(to: pt(0, top))
        path.addLine(to: pt(width, top))
        path.addCurve(to: pt(width * 0.64, bottom), control1: pt(width * 0.95, top + (bottom - top) * 0.4),
                      control2: pt(width * 0.5, top + (bottom - top) * 0.7))
        path.addLine(to: pt(0, bottom))
        path.closeSubpath()
        return path
    }

    // MARK: 拼贴剧场

    private func drawCollage(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: XiaoyaStagePalette) {
        let w = size.width, h = size.height, top = topInset
        let bottom = h - Self.edgeDepth
        let bandH: CGFloat = collapsed ? 22 : 30
        let navy = p.curtainA, cream = p.curtainB, ink = p.floor
        if !collapsed {
            // 手描棕边
            ctx.stroke(Path(CGRect(x: 12, y: top + bandH + 8, width: w - 24, height: bottom - top - bandH)),
                       with: .color(ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.4, dash: [36, 2, 16, 1.5]))
            // 天上的东西都排在上半部：下半部是小芽和名字小票
            let sparkleColor: Color = dark ? .xy(0xE9D8A8) : .xy(0xC9A062)
            ctx.fill(sparkle(CGPoint(x: w * 0.12, y: top + bandH + 30), l: 14), with: .color(sparkleColor))
            ctx.fill(sparkle(CGPoint(x: w * 0.19, y: top + bandH + 48), l: 7), with: .color(sparkleColor))
            // 右侧红丝绒
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 0, x: 1.5, y: 2.5))
                var drape = Path()
                let dTop = top + bandH + 4
                drape.move(to: CGPoint(x: w - 78, y: dTop))
                drape.addCurve(to: CGPoint(x: w - 26, y: bottom - 30), control1: CGPoint(x: w - 58, y: dTop + 50),
                               control2: CGPoint(x: w - 64, y: bottom - 70))
                drape.addLine(to: CGPoint(x: w, y: bottom - 34))
                drape.addLine(to: CGPoint(x: w, y: dTop))
                drape.closeSubpath()
                layer.fill(drape, with: .linearGradient(
                    Gradient(colors: [.xy(0x6E1E14), .xy(0xB23A22), .xy(0x7E2416), .xy(0xA93320)]),
                    startPoint: CGPoint(x: w - 78, y: 0), endPoint: CGPoint(x: w, y: 0)))
                layer.fill(Path(CGRect(x: w - 86, y: dTop - 2, width: 86, height: 6)), with: .color(p.valance))
            }
            cloud(&ctx, at: CGPoint(x: w * 0.56, y: top + bandH + 30), scale: 0.85, fill: dark ? .xy(0xD9CCB0) : .xy(0xF3E9D2), ink: ink)
            celestial(&ctx, CGPoint(x: w * 0.42, y: top + bandH + 32), r: 20, color: p.celestial,
                      face: dark ? nil : .xy(0x7A5A3C), backdrop: p.backdrop)
        }
        // 菱格金星边：顶上一条 + 左右窄条
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 0, x: 1, y: 2))
            var x: CGFloat = -4
            while x < w {
                layer.fill(Path(CGRect(x: x, y: top, width: 20, height: bandH)), with: .color(cream))
                var diamond = Path()
                diamond.move(to: CGPoint(x: x + 20, y: top))
                diamond.addLine(to: CGPoint(x: x + 40, y: top + bandH / 2))
                diamond.addLine(to: CGPoint(x: x + 20, y: top + bandH))
                diamond.addLine(to: CGPoint(x: x, y: top + bandH / 2))
                diamond.closeSubpath()
                layer.fill(diamond, with: .color(navy))
                layer.fill(eightPointStar(CGPoint(x: x + 20, y: top + bandH / 2), r: bandH * 0.2), with: .color(p.star))
                x += 40
            }
            if !collapsed {
                var y = top + bandH
                while y < bottom {
                    for leading in [true, false] {
                        var tri = Path()
                        let x0: CGFloat = leading ? 0 : w
                        tri.move(to: CGPoint(x: x0, y: y))
                        tri.addLine(to: CGPoint(x: leading ? 7 : w - 7, y: y + 13))
                        tri.addLine(to: CGPoint(x: x0, y: y + 26))
                        tri.closeSubpath()
                        layer.fill(tri, with: .color(navy))
                    }
                    y += 26
                }
            }
        }
    }

    private func cloud(_ ctx: inout GraphicsContext, at o: CGPoint, scale s: CGFloat, fill: Color, ink: Color) {
        var c = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        c.move(to: pt(0, 22))
        c.addQuadCurve(to: pt(14, 8), control: pt(-2, 8))
        c.addQuadCurve(to: pt(34, 0), control: pt(18, -4))
        c.addQuadCurve(to: pt(58, 0), control: pt(44, -10))
        c.addQuadCurve(to: pt(74, 14), control: pt(74, -2))
        c.addQuadCurve(to: pt(80, 24), control: pt(82, 16))
        c.closeSubpath()
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 0, x: 1.5, y: 2.5))
            layer.fill(c, with: .color(fill))
        }
        ctx.stroke(c, with: .color(ink), lineWidth: 1.1)
        var swirl = Path()
        swirl.move(to: pt(18, 14)); swirl.addQuadCurve(to: pt(28, 14), control: pt(23, 6))
        swirl.move(to: pt(44, 10)); swirl.addQuadCurve(to: pt(54, 11), control: pt(50, 4))
        ctx.stroke(swirl, with: .color(ink), lineWidth: 0.9)
    }

    private func sparkle(_ c: CGPoint, l: CGFloat) -> Path {
        var p = Path()
        let t: CGFloat = 1.6
        p.move(to: CGPoint(x: c.x, y: c.y - l))
        p.addLine(to: CGPoint(x: c.x + t, y: c.y - t))
        p.addLine(to: CGPoint(x: c.x + l * 0.45, y: c.y))
        p.addLine(to: CGPoint(x: c.x + t, y: c.y + t))
        p.addLine(to: CGPoint(x: c.x, y: c.y + l))
        p.addLine(to: CGPoint(x: c.x - t, y: c.y + t))
        p.addLine(to: CGPoint(x: c.x - l * 0.45, y: c.y))
        p.addLine(to: CGPoint(x: c.x - t, y: c.y - t))
        p.closeSubpath()
        return p
    }

    // MARK: 天上的：亮色太阳 / 暗色月亮

    private func celestial(_ ctx: inout GraphicsContext, _ c: CGPoint, r: CGFloat, color: Color, face: Color?, backdrop: Color) {
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.28), radius: 0, x: 1.5, y: 3))
            if dark {
                // 月牙：整圆减去偏移的圆（在独立图层里挖空，不会挖到背后的布景）
                layer.drawLayer { moon in
                    let big = Path(ellipseIn: CGRect(x: c.x - r * 1.2, y: c.y - r * 1.2, width: r * 2.4, height: r * 2.4))
                    moon.fill(big, with: .color(color))
                    moon.blendMode = .destinationOut
                    moon.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.55, y: c.y - r * 1.45, width: r * 2.4, height: r * 2.4)), with: .color(.black))
                }
            } else {
                var rays = Path()
                for i in 0..<16 {
                    let a = Double.pi / 8 * Double(i)
                    let len = i % 2 == 0 ? r * 1.95 : r * 1.55
                    let w = 0.13
                    rays.move(to: CGPoint(x: c.x + r * 0.9 * cos(a - w), y: c.y + r * 0.9 * sin(a - w)))
                    rays.addLine(to: CGPoint(x: c.x + len * cos(a), y: c.y + len * sin(a)))
                    rays.addLine(to: CGPoint(x: c.x + r * 0.9 * cos(a + w), y: c.y + r * 0.9 * sin(a + w)))
                    rays.closeSubpath()
                }
                layer.fill(rays, with: .color(color))
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
            }
        }
        guard !dark, let face else { return }
        var f = Path()
        f.move(to: CGPoint(x: c.x - r * 0.42, y: c.y - r * 0.12)); f.addQuadCurve(to: CGPoint(x: c.x - r * 0.12, y: c.y - r * 0.12), control: CGPoint(x: c.x - r * 0.27, y: c.y - r * 0.3))
        f.move(to: CGPoint(x: c.x + r * 0.12, y: c.y - r * 0.12)); f.addQuadCurve(to: CGPoint(x: c.x + r * 0.42, y: c.y - r * 0.12), control: CGPoint(x: c.x + r * 0.27, y: c.y - r * 0.3))
        f.move(to: CGPoint(x: c.x, y: c.y - r * 0.05)); f.addLine(to: CGPoint(x: c.x - r * 0.08, y: c.y + r * 0.25)); f.addLine(to: CGPoint(x: c.x + r * 0.04, y: c.y + r * 0.25))
        f.move(to: CGPoint(x: c.x - r * 0.2, y: c.y + r * 0.45)); f.addQuadCurve(to: CGPoint(x: c.x + r * 0.2, y: c.y + r * 0.45), control: CGPoint(x: c.x, y: c.y + r * 0.58))
        ctx.stroke(f, with: .color(face), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }

    private func eightPointStar(_ c: CGPoint, r: CGFloat) -> Path {
        var p = Path()
        for i in 0..<16 {
            let a = Double.pi / 8 * Double(i) - .pi / 2
            let rr = i % 2 == 0 ? r : r * 0.38
            let pt = CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    // MARK: 底边：条纹剧场锯齿，拼贴剧场撕纸

    private func bottomEdge(_ size: CGSize) -> Path {
        let w = size.width, h = size.height, d = Self.edgeDepth
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: h - d))
        var x = w
        var i = 0
        while x > 0 {
            x -= theme == .collage ? 8 : 10
            let y: CGFloat = theme == .collage
                ? h - d + CGFloat((i * 37) % 7)           // 撕纸：不规则小起伏
                : (i % 2 == 0 ? h : h - d)                // 锯齿
            p.addLine(to: CGPoint(x: max(x, 0), y: y))
            i += 1
        }
        p.addLine(to: CGPoint(x: 0, y: h - d))
        p.closeSubpath()
        return p
    }
}
