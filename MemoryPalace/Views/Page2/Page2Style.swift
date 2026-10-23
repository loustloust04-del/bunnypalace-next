#if os(iOS)
import SwiftUI
import UIKit

/// Page 2 针脚点阵样式 —— 独立硬编码调色板（D1：不读 Theme token，不随可选主题变）。
/// 设计真相源：Figma「小克 · 承粟粟底 v1」+ chassis-v2.html 验收值（2026-07-20 粟粟拍）。
enum Page2Palette {
    static let canvas      = Color(red: 1.0, green: 0.988, blue: 0.973)    // #FFFCF8 桌面底（粟粟 Figma 调白层，07-20 补抄）
    static let surface     = Color(red: 1.0,   green: 0.996, blue: 0.984)  // #FFFEFB 磁贴/白面
    static let planCard    = Color(red: 0.890, green: 0.929, blue: 0.906)  // #E3EDE7 撕纸计划卡
    static let todoCard    = Color(red: 0.929, green: 0.886, blue: 0.902)  // #EDE2E6 待办卡
    static let accentCard  = Color(red: 0.788, green: 0.482, blue: 0.494)  // #C97B7E 单词深卡
    static let ink         = Color(red: 0.243, green: 0.227, blue: 0.200)  // #3E3A33
    static let inkSoft     = Color(red: 0.541, green: 0.514, blue: 0.459)  // #8A8375
    static let inkFaint    = Color(red: 0.710, green: 0.675, blue: 0.612)  // #B5AC9C
    static let cream       = Color(red: 1.0,   green: 0.976, blue: 0.957)  // #FFF9F4 深卡上的字/点
    static let sage        = Color(red: 0.561, green: 0.682, blue: 0.612)  // #8FAE9C 十字绣 X
    static let blushDeep   = Color(red: 0.831, green: 0.541, blue: 0.600)  // #D48A99 twinkle 粉
}

/// 骨架常量 = chassis-v2.html 验收值（07-16），一个不改。
enum Page2Metrics {
    static let iconSize: CGFloat = 60
    static let iconRadius: CGFloat = 13.5
    static let gridMargin: CGFloat = 27
    static let gridRowGap: CGFloat = 24
    static let labelSize: CGFloat = 11
    static let labelGap: CGFloat = 4
    static let widgetSmall: CGFloat = 158
    static let widgetRadius: CGFloat = 22
    static let widgetPadding: CGFloat = 16
    static let widgetGap: CGFloat = 22
    static let widgetTop: CGFloat = 12
    static let gridTop: CGFloat = 24
}

/// 字体：标题中英都打字机（粟粟 07-16 拍）。EN = American Typewriter（iOS 内建）；
/// 中文打字机 = 仿宋族运行时探测，不存在则落苹方 semibold（不崩）。
enum Page2Fonts {
    static let cnTitleName: String? = {
        for name in ["STFangsong", "STSongti-SC-Semibold", "STSongti-SC-Regular"] {
            if UIFont(name: name, size: 12) != nil { return name }
        }
        return nil
    }()

    static func enLabel(_ size: CGFloat) -> Font { .custom("AmericanTypewriter", size: size) }
    static func enTitle(_ size: CGFloat) -> Font { .custom("AmericanTypewriter-Semibold", size: size) }
    static func cnTitle(_ size: CGFloat) -> Font {
        if let n = cnTitleName { return .custom(n, size: size) }
        return .system(size: size, weight: .semibold)
    }
}

/// 撕纸轮廓 —— 画布同款算法：种子伪随机，步长 4-13、毛边 ±2.5、14% 深豁口。
/// seed 固定 ⇒ 每次渲染同形（不闪）。
struct Page2TornShape: Shape {
    var seed: Double = 13.7

    func path(in rect: CGRect) -> Path {
        var k = seed
        func rr() -> CGFloat {
            k += 1
            let s = sin(k * 127.1 + 13.7) * 43758.545
            return CGFloat(s - floor(s))
        }
        var pts: [CGPoint] = []
        func edge(_ a: CGPoint, _ b: CGPoint) {
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { return }
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            let nx = -uy, ny = ux
            var p: CGFloat = 0
            while p < len {
                var amp = (rr() - 0.5) * 5
                if rr() < 0.14 { amp += (rr() - 0.5) * 15 }
                pts.append(CGPoint(x: a.x + ux * p + nx * amp, y: a.y + uy * p + ny * amp))
                p += 4 + rr() * 9
            }
        }
        let tl = CGPoint(x: rect.minX, y: rect.minY), tr = CGPoint(x: rect.maxX, y: rect.minY)
        let br = CGPoint(x: rect.maxX, y: rect.maxY), bl = CGPoint(x: rect.minX, y: rect.maxY)
        edge(tl, tr); edge(tr, br); edge(br, bl); edge(bl, tl)
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        return path
    }
}

/// 十字绣勾选：未选 = 虚线格；选中 = 实线格 + 鼠尾草双针脚 X。
struct StitchCheckbox: View {
    let done: Bool
    var size: CGFloat = 15

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(style: StrokeStyle(lineWidth: 1.4, dash: done ? [] : [3, 2.4]))
                .foregroundColor(Page2Palette.inkFaint)
            if done {
                Path { p in
                    p.move(to: CGPoint(x: 3, y: 3)); p.addLine(to: CGPoint(x: size - 3, y: size - 3))
                    p.move(to: CGPoint(x: size - 3, y: 3)); p.addLine(to: CGPoint(x: 3, y: size - 3))
                }
                .stroke(Page2Palette.sage, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// 点排进度：7 点量化（不是连续条——和 dither 同语言）。
struct DotProgressStrip: View {
    let filled: Int
    var total: Int = 7
    var onColor: Color = Page2Palette.sage
    var offColor: Color = Page2Palette.ink.opacity(0.12)

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < filled ? onColor : offColor)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// 像素小星 twinkle（5 点十字）。
struct TwinkleMark: View {
    var color: Color = Page2Palette.blushDeep
    var unit: CGFloat = 2.2

    var body: some View {
        Canvas { ctx, _ in
            for (x, y) in [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2)] {
                ctx.fill(Path(CGRect(x: CGFloat(x) * unit * 2, y: CGFloat(y) * unit * 2, width: unit, height: unit)),
                         with: .color(color))
            }
        }
        .frame(width: unit * 5, height: unit * 5)
    }
}
#endif
