#if os(iOS)
import SwiftUI
import UIKit

/// page0 在不在屏幕上：ContentView 翻页时写，液态金属背景读（不在屏上就停帧）。
/// 走 @Observable 单例而不是 env——page0 挂在 UIKit 分页的子 HC 里，env 不连通。
@Observable
final class Page0Stage {
    static let shared = Page0Stage()
    var isOnScreen = false
    /// page0 底是深色金属时状态栏用浅色字（PagingViewController 读）
    var lightStatusBar = false
}

/// page0 底色：液态金属（`Page0LiquidMetal.metal`，小样 docs/design-liquid-metal.html 「铬」）。
/// 只在 page0 在屏上时 30fps 跑；减弱动态效果 / 低电量 / 退后台停在当前帧（静止也是完整的画面）。
/// 半分辨率算、再放大一倍：液面是平滑的，放大看不出来，GPU 只算四分之一的像素。
struct Page0LiquidMetalBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @AppStorage("page0MetalFlowers") private var showFlowers = true

    private var paused: Bool {
        reduceMotion || lowPower || scenePhase != .active || !Page0Stage.shared.isOnScreen
    }

    var body: some View {
        GeometryReader { geo in
            // 暂停时 TimelineView 不再出新帧，画面就停在最后一帧
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                ZStack {
                    Rectangle()
                        .fill(ShaderLibrary.page0LiquidMetal(.boundingRect, .float(Float(t))))
                        .frame(width: geo.size.width / 2, height: geo.size.height / 2)
                        .drawingGroup()
                        .scaleEffect(2)
                        .frame(width: geo.size.width, height: geo.size.height)
                    if showFlowers {
                        Page0MetalFlowers(time: t, size: geo.size)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}
/// 液态金属底上的白色点点花（小样 docs/design-page0-metal-flowers.html）：
/// 底边一排矮花（搜索栏下面那条带，一部分从搜索栏玻璃后面透出来）+ 两侧几株高花沿窄边往上探。
/// 花田按固定种子生成，每次打开都是同一片；茎是一串点，花头随风轻晃，偶尔一朵慢慢亮一下。
struct Page0MetalFlowers: View {
    let time: Double
    let size: CGSize

    private struct Flower {
        let x: CGFloat, scale: CGFloat, shape: Int, phase: Double, stem: CGFloat, breath: Double, lean: CGFloat
    }

    /// 开屏同款点点花形状：单位网格间距 0.3
    private static let shapes: [[CGPoint]] = {
        func grid(_ test: (CGFloat, CGFloat) -> Bool) -> [CGPoint] {
            var pts: [CGPoint] = []
            for yi in 0...8 { for xi in 0...8 {
                let x = -1.2 + CGFloat(xi) * 0.3, y = -1.2 + CGFloat(yi) * 0.3
                if test(x, y) { pts.append(CGPoint(x: x, y: y)) }
            } }
            return pts
        }
        func inC(_ x: CGFloat, _ y: CGFloat, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Bool {
            (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
        }
        return [
            grid { x, y in inC(x, y, 0.5, 0, 0.52) || inC(x, y, -0.5, 0, 0.52) || inC(x, y, 0, 0.5, 0.52) || inC(x, y, 0, -0.5, 0.52) },
            grid { x, y in (inC(x, y, 0, 0.15, 0.72) && y > -0.25) || inC(x, y, -0.42, -0.42, 0.3) || inC(x, y, 0, -0.62, 0.3) || inC(x, y, 0.42, -0.42, 0.3) },
            grid { x, y in inC(x, y, 0, 0, 0.82) && !inC(x, y, 0, 0, 0.25) },
            grid { x, y in (inC(x, y, 0, -0.1, 0.6) && y > -0.5) || (y >= 0.3 && y < 0.7 && abs(x) < 0.75 - (y - 0.3) * 0.2) },
        ]
    }()

    /// mulberry32：和小样同一个随机，种子固定 → 同一片花田
    private static func field(width: CGFloat) -> [Flower] {
        var state: UInt32 = 11
        func rnd() -> CGFloat {
            state &+= 0x6D2B79F5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return CGFloat(t ^ (t >> 14)) / 4294967296
        }
        // 底边一排矮花：长在搜索栏下面那条带里，一部分从搜索栏玻璃后面透出来
        var out: [Flower] = []
        let row = 12
        for i in 0..<row {
            let x = 8 + (CGFloat(i) + 0.2 + 0.6 * rnd()) / CGFloat(row) * (width - 16)
            let scale = 0.8 + rnd() * 0.45, shape = Int(rnd() * 4), phase = Double(rnd()) * 6.28
            let stem = (8 + rnd() * 18) * (1 + rnd() * 0.45)       // 中～高之间随机
            out.append(Flower(x: x, scale: scale, shape: shape, phase: phase, stem: stem,
                              breath: Double(rnd()) * 30, lean: (rnd() - 0.5) * 0.15))
        }
        // 两侧攀援的高花：沿窄边往上长，花头从卡片边上探出来
        for i in 0..<6 {
            let left = i % 2 == 0
            let x = left ? 4 + rnd() * 7 : width - 4 - rnd() * 7
            let scale = 0.95 + rnd() * 0.4, shape = Int(rnd() * 4), phase = Double(rnd()) * 6.28
            let stem = (60 + rnd() * 190) * (1 + rnd() * 0.45)
            out.append(Flower(x: x, scale: scale, shape: shape, phase: phase, stem: stem,
                              breath: Double(rnd()) * 30, lean: (left ? 1 : -1) * rnd() * 0.03))
        }
        return out.sorted { $0.scale < $1.scale }
    }

    var body: some View {
        let flowers = Self.field(width: size.width)
        Canvas { ctx, canvasSize in
            let base = canvasSize.height + 2
            for f in flowers {
                let s = f.scale, hr = 8.2 * s, dotR = 1.3 * s
                let sway = CGFloat(sin(time * 0.9 + f.phase)) * 3.2 * s + CGFloat(sin(time * 0.37 + f.phase * 2.1)) * 1.6 * s
                let glow = pow(max(0, sin((time + f.breath) * 0.21)), 18)
                let alpha = 0.62 + 0.12 * s / 1.5 + 0.26 * glow
                let step = 2.5 * s
                var y: CGFloat = 0
                while y < f.stem {
                    let k = y / f.stem
                    let x = f.x + sway * k * k + f.lean * y
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.8 * s, y: base - y - 0.8 * s, width: 1.6 * s, height: 1.6 * s)),
                             with: .color(.white.opacity(alpha * 0.7)))
                    y += step
                }
                let hx = f.x + sway + f.lean * f.stem, hy = base - f.stem - hr * 0.55
                ctx.drawLayer { layer in
                    if glow > 0.05 { layer.addFilter(.shadow(color: .white.opacity(0.9), radius: 6 * glow)) }
                    var head = Path()
                    // 小样是 y 向下的画布，形状里 y 为负是上方——这里同一套坐标，直接用
                    for p in Self.shapes[f.shape] {
                        head.addEllipse(in: CGRect(x: hx + p.x * hr - dotR, y: hy + p.y * hr - dotR, width: dotR * 2, height: dotR * 2))
                    }
                    if f.shape == 0 {
                        head.addEllipse(in: CGRect(x: hx - dotR * 1.25, y: hy - dotR * 1.25, width: dotR * 2.5, height: dotR * 2.5))
                    }
                    layer.fill(head, with: .color(.white.opacity(alpha)))
                }
            }
        }
    }
}
#endif
