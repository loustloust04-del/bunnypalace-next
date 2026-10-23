import CoreGraphics
import Foundation

/// 花园四季动画版的部件（#039）：`GardenRenderer.renderParts` 一遍画出来，主屏那一个实例拿去搭动画层。
/// 坐标单位都是 pt（整屏坐标系，y 朝下）。所有会动的东西都按小样的公式给出参数，t = `t0` 时的样子 = 静帧。
final class GardenParts {
    /// 静帧定格的时刻（`GardenRenderer.render` 默认 t）：动画层从这一刻起播，换上去的那一下和静帧对得上
    static let t0 = 30.0
    /// 涟漪在几个预选位置里轮（每 7 秒换一处）
    static let rippleCycles = 6
    /// 萤火绕着游的 10 个点（网格坐标，同小样）
    static let fireflySpots: [(Double, Double, Double)] = [(19, 33, 2), (33, 33, 2.5), (42, 20, 2), (6, 36, 2.2), (27, 46, 1.8), (46, 30, 2), (17, 42, 1.8), (22, 7, 3), (41, 40, 2), (4, 42, 2.4)]

    /// 一闪一闪的点：透明度 = alpha × (lo + amp·sin(omega·t + phase))
    struct Twinkle { let x, y, r: Double; let color: GardenRGB; let alpha, omega, phase, lo, amp: Double }
    /// 一朵云：贴图按锚点 (x, y) 的相对坐标 `box` 画；x(t) = start + (x(t0) − start + speed·(t − t0)) mod span
    struct Cloud { let image: CGImage; let box: CGRect; let y, x, start, span, speed: Double }
    /// 水面细纹：y(t) = 水面上沿 + frac(frac0 + rate·t) × 水面高；透明度 0.16·(0.5 + 0.5·sin(0.8t + phase))
    struct Line { let x, len, frac0, rate, phase: Double }
    /// 碎光：透明度 = alpha × max(0, sin(omega·t + phase))^6
    struct Glint { let x, y, len, alpha, omega, phase: Double }
    /// 飘落物（春花瓣 / 秋叶 / 冬雪）：每个粒子一条固定路径，同小样 fall()
    struct Fall { let count, seed: Int; let period: Double; let season: Int }
    static let falls = [Fall(count: 16, seed: 51, period: 12, season: 0), Fall(count: 12, seed: 52, period: 14, season: 2), Fall(count: 70, seed: 53, period: 16, season: 3)]

    let width, height, scale, hour, season: Double
    var base: CGImage?
    var stars: [Twinkle] = [], golds: [Twinkle] = []
    var goldStar: CGImage?, goldBox = CGRect.zero
    var clouds: [Cloud] = []
    /// 天际线：每 `skyStep` pt 一格，这一列从顶往下第一处被山 / 树 / 体素盖住的 y。星和云只该出现在它上面
    static let skyStep = 2.0
    private(set) var skyline: [Double]
    /// 月亮的圆（夜里才有）：星不该叠在月亮上
    var moon: CGRect?
    var water: CGImage?, front: CGImage?
    var waterRect: CGRect?, waterPath: CGPath?
    var waterBounds = CGRect.zero
    var waterContext: CGContext?
    var lineColor = GardenRGB(1, 1, 1), lineWidth = 0.5, rippleWidth = 0.5
    var lines: [Line] = []
    var ripples: [[CGPoint]] = []
    var glints: [Glint] = []
    var glintColor = GardenRGB(1, 1, 1)
    var halo: CGImage?, haloBox = CGRect.zero, halos: [CGPoint] = []
    /// 四角暗角，按 `vignetteScale` 缩小出图（极平滑的大渐变），盖在所有动画层最上面
    static let vignetteScale = 0.25
    var vignette: CGImage?
    var firefly: CGImage?, fireflyBox = CGRect.zero, fireflies: [CGPoint] = [], fireflyAlpha = 0.0

    init(width: Double, height: Double, scale: Double, hour: Double, season: Double) {
        self.width = width; self.height = height; self.scale = scale; self.hour = hour; self.season = season
        skyline = Array(repeating: height, count: Int((width / Self.skyStep).rounded(.up)) + 2)
    }

    /// x 从 x0 到 x1 这几列被盖到了 y
    func cover(_ x0: Double, _ x1: Double, _ y: Double) {
        let a = max(0, Int((min(x0, x1) / Self.skyStep).rounded(.down))), b = min(skyline.count - 1, Int((max(x0, x1) / Self.skyStep).rounded(.up)))
        guard a <= b else { return }
        for i in a...b where y < skyline[i] { skyline[i] = y }
    }

    /// 体素上沿：顶点 (cx, top)，左右各 half 宽、每横走 1 往下 1/2
    func coverTent(_ cx: Double, _ half: Double, _ top: Double) {
        let a = max(0, Int(((cx - half) / Self.skyStep).rounded(.up))), b = min(skyline.count - 1, Int(((cx + half) / Self.skyStep).rounded(.down)))
        guard a <= b else { return }
        for i in a...b {
            let y = top + abs(Double(i) * Self.skyStep - cx) / 2
            if y < skyline[i] { skyline[i] = y }
        }
    }

    func skyAt(_ x: Double) -> Double { skyline[min(skyline.count - 1, max(0, Int((x / Self.skyStep).rounded())))] }

    /// 一个半径 r 的点在 (x, y) 整个落在天上、也不压着月亮
    func inOpenSky(_ x: Double, _ y: Double, _ r: Double) -> Bool {
        var lowest = height
        var xx = x - r
        while xx <= x + r { lowest = min(lowest, skyAt(xx)); xx += Self.skyStep }
        if y + r >= lowest { return false }
        if let moon, moon.insetBy(dx: -r * 2, dy: -r * 2).contains(CGPoint(x: x, y: y)) { return false }
        return true
    }

    /// 天空区域（天际线以上）的轮廓，给云做 mask 用
    var skyPath: CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: width, y: 0))
        for i in stride(from: skyline.count - 1, through: 0, by: -1) { path.addLine(to: CGPoint(x: Double(i) * Self.skyStep, y: skyline[i])) }
        path.closeSubpath()
        return path
    }

    var env: GardenEnvironment { GardenEnvironment(hour: hour, season: season) }
    var voxel: Double { GardenRenderer.layout(width: width, height: height).s }
    var unit: Double { width / 390 }

    /// 第 i 个飘落物落完一趟要几秒
    static func fallPeriod(_ f: Fall, _ i: Int) -> Double { f.period * (0.8 + GardenMath.hash(i, f.seed, 1) * 0.6) }
    /// t0 时它落到哪（0…1）
    static func fallPhase0(_ f: Fall, _ i: Int) -> Double {
        (t0 / fallPeriod(f, i) + GardenMath.hash(i, f.seed, 2)).truncatingRemainder(dividingBy: 1)
    }
    /// 落到 ph（0…1）时的位置
    static func fallPoint(_ f: Fall, _ i: Int, _ ph: Double, width W: Double, height H: Double) -> CGPoint {
        CGPoint(x: (GardenMath.hash(i, f.seed, 3) * 1.3 - 0.15) * W + ph * W * 0.18 + sin(ph * 12 + Double(i)) * W * 0.03,
                y: -10 + ph * (H + 20))
    }
    /// 淡入淡出包络
    static func fallAlpha(_ ph: Double) -> Double { GardenMath.smooth(0, 0.08, ph) * GardenMath.smooth(1, 0.9, ph) }

    /// 时钟基准帧率（#051）：app 一条 display link 按它走，整屏合成 = 它（60Hz 屏上动画级帧率提示不管用）
    static func clockBase(lowPower: Bool) -> Int { lowPower ? 20 : 30 }
    /// 一组每几拍推一次时间：⌈基准 / 帧率⌉，所有组在同一条网格上
    static func clockStride(fps: Int, base: Int) -> Int { max(1, (base + fps - 1) / fps) }
    /// 一拍推多少秒：停过（拖动时 runloop 在 tracking、主线程卡）之后接着走，不跳
    static func clockStep(_ dt: Double, base: Int) -> Double { min(max(dt, 0), 2 / Double(base)) }
}
