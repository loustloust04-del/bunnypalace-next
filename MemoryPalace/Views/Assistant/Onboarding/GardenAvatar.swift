import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - 花园随机头像（§11-7；小样 design-onboarding-xiaoya-v2.html C 的 garAvatar）
// 纯程序画：圆底 + 点点花 / 小动物 / 一个字 / 金星。卡片只存种子（XiaoyaAvatarSeed），重画 / 恢复都从种子算；
// 确认时 ImageRenderer 出 512px JPEG 写进楼层。配色约束写死：底色只用暖奶白 / 浅灰薄荷 / 浅粉 / 浅紫 / 浅杏，
// 薄荷底上不放绿色元素，不出蓝。随机数照小样 mulberry32，同一个种子两端画出来一样。

struct GardenRNG {
    private var a: UInt32

    init(_ seed: UInt32) { a = seed }

    mutating func next() -> Double {
        a = a &+ 0x6D2B79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[min(Int(next() * Double(items.count)), items.count - 1)]
    }

    mutating func shuffled<T>(_ items: [T]) -> [T] {
        var a = items
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = min(Int(next() * Double(i + 1)), i)
            a.swapAt(i, j)
        }
        return a
    }
}

struct GardenAvatar: Equatable {
    enum Figure: Equatable {
        case flower(petal: String)
        case cat(fur: String)
        case bunny, bear, sheep, fox
        case letter(String, zh: Bool, color: String)
        case star
    }

    let background: String
    let figure: Figure

    static let backgrounds = ["#FFFBF6", "#E7EEEC", "#F3E4E4", "#ECE7F1", "#F4E8DC", "#EFEAE0"]
    static let greenBackgrounds: Set<String> = ["#E7EEEC"]
    static let chars = ["栗", "梨", "满", "禾", "月", "柚", "糯", "桃", "云", "星"]
    static let letters = ["M", "L", "S", "Y", "K", "N", "A", "Q"]

    /// 照小样 garAvatar 的取数顺序：同一个种子画出来的头像固定
    init(_ seed: XiaoyaAvatarSeed) {
        var r = GardenRNG(seed.seed)
        let kind = ["flower", "animal", "letter", "star"].contains(seed.kind) ? seed.kind : "star"
        var bg = r.pick(Self.backgrounds)
        if kind == "flower", Self.greenBackgrounds.contains(bg) { bg = "#F3E4E4" }
        background = bg
        let onGreen = Self.greenBackgrounds.contains(bg)
        switch kind {
        case "flower":
            figure = .flower(petal: r.pick(["#d99aa5", "#e3a9b0", "#c98f9e", "#b3a2cc", "#d9a07f"]))
        case "animal":
            let species = seed.species ?? r.pick(["cat", "bunny", "bear", "sheep", "fox"])
            switch species {
            case "cat": figure = .cat(fur: r.pick(["#3D3533", "#d9b99b", "#F7F3EC"]))
            case "bunny": figure = .bunny
            case "bear": figure = .bear
            case "sheep": figure = .sheep
            default: figure = .fox
            }
        case "letter":
            let zh = r.next() < 0.6
            let ch = zh ? r.pick(Self.chars) : r.pick(Self.letters)
            let color = onGreen ? "#3D3533" : r.pick(["#3D3533", "#5f8f74", "#a46b74"])
            figure = .letter(ch, zh: zh, color: color)
        default:
            figure = .star
        }
    }

    /// 收起后的一行「头像选好了 · 小猫」
    var label: String {
        switch figure {
        case .flower: "点点花"
        case .cat: "小猫"
        case .bunny: "小兔"
        case .bear: "小熊"
        case .sheep: "小羊"
        case .fox: "小狐狸"
        case .letter(_, let zh, _): zh ? "一个字" : "字母"
        case .star: "金星"
        }
    }

    /// 一批 6 个（小样 avatarCard.fill）：点点花 1 + 小动物 3（不重样）+ 字 1 + 金星 1，顺序打乱
    static func batch(_ batch: UInt32) -> [XiaoyaAvatarSeed] {
        var r = GardenRNG(batch &* 977 &+ 3)
        let kinds = r.shuffled(["flower", "animal", "animal", "animal", "letter", "star"])
        let species = r.shuffled(["cat", "bunny", "bear", "sheep", "fox"])
        var ai = 0
        return kinds.enumerated().map { i, kind in
            var sp: String?
            if kind == "animal" { sp = species[ai % species.count]; ai += 1 }
            return XiaoyaAvatarSeed(seed: batch &* 7 &+ UInt32(i) &* 131 &+ 1, kind: kind, species: sp)
        }
    }

    /// 确认时出 512px JPEG（整张方图铺底色，显示时再裁圆——JPEG 没有透明，角上不留黑）
    @MainActor
    static func jpeg(_ seed: XiaoyaAvatarSeed, side: CGFloat = 512) -> Data? {
        let renderer = ImageRenderer(content: GardenAvatarView(seed: seed, size: side, clipped: false))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
        #else
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #endif
    }
}

/// 一个花园头像（64 单位坐标系，按 size 缩放）
struct GardenAvatarView: View {
    let seed: XiaoyaAvatarSeed
    var size: CGFloat = 72
    /// 显示时裁圆；导出 JPEG 时铺满方图
    var clipped = true

    var body: some View {
        let avatar = GardenAvatar(seed)
        Canvas { ctx, canvasSize in
            let k = canvasSize.width / 64
            ctx.scaleBy(x: k, y: k)
            if clipped {
                ctx.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: 64, height: 64)), with: .color(gardenColor(avatar.background)))
            } else {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: 64, height: 64)), with: .color(gardenColor(avatar.background)))
            }
            draw(avatar.figure, in: &ctx)
        }
        .frame(width: size, height: size)
        .clipShape(clipped ? AnyShape(Circle()) : AnyShape(Rectangle()))
        .accessibilityLabel(Text(avatar.label))
    }

    // MARK: 画

    private func draw(_ figure: GardenAvatar.Figure, in ctx: inout GraphicsContext) {
        let eye = "#3D3533", cheek = "#e3a9b0"
        switch figure {
        case .flower(let petal):
            dotFlower(32, 24, petal, 11, stem: "#7fa58d", stemLen: 5, in: &ctx)
            dot(22, 46, 2.4, "#7fa58d", in: &ctx)
            dot(42, 44, 2.4, "#7fa58d", in: &ctx)
        case .cat(let fur):
            let e = fur == "#3D3533" ? "#F2EEE4" : eye
            let edge: String? = fur == "#F7F3EC" ? "#d8cfc4" : nil
            var ears = Path()
            ears.addLines([CGPoint(x: 17, y: 26), CGPoint(x: 19, y: 10), CGPoint(x: 30, y: 20)]); ears.closeSubpath()
            ears.addLines([CGPoint(x: 47, y: 26), CGPoint(x: 45, y: 10), CGPoint(x: 34, y: 20)]); ears.closeSubpath()
            fill(ears, fur, stroke: edge, in: &ctx)
            fill(circle(32, 35, 17), fur, stroke: edge, in: &ctx)
            dot(25, 34, 2.2, e, in: &ctx); dot(39, 34, 2.2, e, in: &ctx)
            dot(21, 40, 2.6, cheek, opacity: 0.7, in: &ctx); dot(43, 40, 2.6, cheek, opacity: 0.7, in: &ctx)
            var mouth = Path()
            mouth.move(to: CGPoint(x: 30, y: 39)); mouth.addQuadCurve(to: CGPoint(x: 34, y: 39), control: CGPoint(x: 32, y: 41))
            ctx.stroke(mouth, with: .color(gardenColor(e)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        case .bunny:
            fill(Path(ellipseIn: CGRect(x: 19, y: 3, width: 10, height: 24)), "#FFFFFF", stroke: "#d8cfc4", in: &ctx)
            fill(Path(ellipseIn: CGRect(x: 35, y: 3, width: 10, height: 24)), "#FFFFFF", stroke: "#d8cfc4", in: &ctx)
            ctx.fill(Path(ellipseIn: CGRect(x: 21.8, y: 9, width: 4.4, height: 14)), with: .color(gardenColor(cheek).opacity(0.6)))
            ctx.fill(Path(ellipseIn: CGRect(x: 37.8, y: 9, width: 4.4, height: 14)), with: .color(gardenColor(cheek).opacity(0.6)))
            fill(circle(32, 38, 16), "#FFFFFF", stroke: "#d8cfc4", in: &ctx)
            dot(26, 37, 2, eye, in: &ctx); dot(38, 37, 2, eye, in: &ctx)
            dot(22, 43, 2.6, cheek, opacity: 0.7, in: &ctx); dot(42, 43, 2.6, cheek, opacity: 0.7, in: &ctx)
            dot(32, 41, 1.3, cheek, in: &ctx)
        case .bear:
            dot(18, 20, 7, "#b98f72", in: &ctx); dot(46, 20, 7, "#b98f72", in: &ctx)
            dot(18, 20, 3.4, "#e7cdb6", in: &ctx); dot(46, 20, 3.4, "#e7cdb6", in: &ctx)
            dot(32, 35, 17, "#b98f72", in: &ctx)
            ctx.fill(Path(ellipseIn: CGRect(x: 24, y: 35, width: 16, height: 12)), with: .color(gardenColor("#ecd9c6")))
            dot(32, 38.5, 2.2, eye, in: &ctx)
            dot(25, 32, 2, eye, in: &ctx); dot(39, 32, 2, eye, in: &ctx)
        case .sheep:
            for i in 0..<12 {
                let a = Double(i) / 12 * .pi * 2
                fill(circle(32 + cos(a) * 16, 33 + sin(a) * 15, 6.5), "#FFFFFF", stroke: "#e2dbd0", lineWidth: 0.8, in: &ctx)
            }
            dot(32, 33, 15, "#FFFFFF", in: &ctx)
            ctx.fill(Path(ellipseIn: CGRect(x: 23, y: 27, width: 18, height: 20)), with: .color(gardenColor("#4a3f3c")))
            dot(28.5, 35, 1.6, "#F2EEE4", in: &ctx); dot(35.5, 35, 1.6, "#F2EEE4", in: &ctx)
            dot(26, 41, 2, cheek, opacity: 0.6, in: &ctx); dot(38, 41, 2, cheek, opacity: 0.6, in: &ctx)
        case .fox:
            var ears = Path()
            ears.addLines([CGPoint(x: 15, y: 30), CGPoint(x: 17, y: 9), CGPoint(x: 29, y: 20)]); ears.closeSubpath()
            ears.addLines([CGPoint(x: 49, y: 30), CGPoint(x: 47, y: 9), CGPoint(x: 35, y: 20)]); ears.closeSubpath()
            ctx.fill(ears, with: .color(gardenColor("#d9a07f")))
            var head = Path()
            head.move(to: CGPoint(x: 15, y: 28))
            head.addQuadCurve(to: CGPoint(x: 49, y: 28), control: CGPoint(x: 32, y: 62))
            head.addQuadCurve(to: CGPoint(x: 32, y: 18), control: CGPoint(x: 46, y: 18))
            head.addQuadCurve(to: CGPoint(x: 15, y: 28), control: CGPoint(x: 18, y: 18))
            head.closeSubpath()
            ctx.fill(head, with: .color(gardenColor("#d9a07f")))
            var face = Path()
            face.move(to: CGPoint(x: 20, y: 34))
            face.addQuadCurve(to: CGPoint(x: 44, y: 34), control: CGPoint(x: 32, y: 56))
            face.addQuadCurve(to: CGPoint(x: 32, y: 46), control: CGPoint(x: 38, y: 40))
            face.addQuadCurve(to: CGPoint(x: 20, y: 34), control: CGPoint(x: 26, y: 40))
            face.closeSubpath()
            ctx.fill(face, with: .color(gardenColor("#FFFBF6")))
            dot(25, 31, 2, eye, in: &ctx); dot(39, 31, 2, eye, in: &ctx); dot(32, 44, 2, eye, in: &ctx)
        case .letter(let ch, let zh, let color):
            let font: Font = zh ? .system(size: 28, weight: .regular, design: .serif)
                                : .system(size: 32, weight: .regular, design: .serif).italic()
            ctx.draw(Text(ch).font(font).foregroundColor(gardenColor(color)), at: CGPoint(x: 32, y: zh ? 32 : 33), anchor: .center)
            goldStar(50, 14, n: 2, step: 2.4, rad: 1.1, in: &ctx)
        case .star:
            goldStar(32, 32, n: 4, step: 4.2, rad: 2.2, in: &ctx)
            for i in 0..<20 {
                let a = Double(i) / 20 * .pi * 2
                dot(32 + cos(a) * 24, 32 + sin(a) * 24, i % 2 == 1 ? 1 : 1.6, "#3a4a41", opacity: 0.35, in: &ctx)
            }
        }
    }

    private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    private func dot(_ x: Double, _ y: Double, _ r: Double, _ color: String, opacity: Double = 1, in ctx: inout GraphicsContext) {
        ctx.fill(circle(x, y, r), with: .color(gardenColor(color).opacity(opacity)))
    }

    private func fill(_ path: Path, _ color: String, stroke: String?, lineWidth: CGFloat = 1, in ctx: inout GraphicsContext) {
        ctx.fill(path, with: .color(gardenColor(color)))
        if let stroke { ctx.stroke(path, with: .color(gardenColor(stroke)), lineWidth: lineWidth) }
    }

    /// 小样 dotFlower：八瓣点点 + 金芯 + 一串珠子花茎
    private func dotFlower(_ cx: Double, _ cy: Double, _ c: String, _ r: Double, stem: String, stemLen: Int,
                           in ctx: inout GraphicsContext) {
        let pts: [(Double, Double)] = [(0, -1), (1, 0), (0, 1), (-1, 0), (0.7, -0.7), (0.7, 0.7), (-0.7, 0.7), (-0.7, -0.7)]
        for (i, p) in pts.enumerated() {
            let f = i < 4 ? 1 : 0.62
            dot(cx + p.0 * r * f, cy + p.1 * r * f, i < 4 ? r * 0.37 : r * 0.29, c, in: &ctx)
        }
        dot(cx, cy, r * 0.31, "#c7b27a", in: &ctx)
        for k in 1...stemLen {
            let kk = Double(k)
            dot(cx + sin(kk * 0.5) * r * 0.21, cy + r * 1.29 + kk * r * 0.66, k % 2 == 1 ? r * 0.21 : r * 0.16, stem, in: &ctx)
        }
    }

    /// 小样 gstar：点点十字金星
    private func goldStar(_ cx: Double, _ cy: Double, n: Int, step: Double, rad: Double, in ctx: inout GraphicsContext) {
        for i in -n...n {
            let r = max(0.4, rad - Double(abs(i)) * rad * 0.15)
            dot(cx + Double(i) * step, cy, r, "#b8954c", in: &ctx)
            dot(cx, cy + Double(i) * step, r, "#b8954c", in: &ctx)
        }
    }
}

/// "#RRGGBB" → Color（头像 / tip 插图的固定花园配色，不跟主题）
func gardenColor(_ string: String) -> Color {
    var s = string
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0
    return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}
