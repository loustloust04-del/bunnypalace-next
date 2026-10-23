import SwiftUI

/// 会流动的金属描边环（metal-fx 直译，见 LiquidMetal.metal）。挂在输入框 overlay，键盘在（焦点在）时显示。
/// Shader 直接当 strokeBorder 的 ShapeStyle——环就是描边本身，不用整块画再挖空。
/// 输入框金属环的可调参数（设置页仪表盘，AppStorage）。默认值 = 08-25 粟粟在仪表盘上调的那组。
enum LiquidMetalTuning {
    static let enabledKey = "lmRing.enabled"
    static let presetKey = "lmRing.preset"        // auto / chromatic / rainbowSilver / rainbowWhite / silver / chromaticLight / mintChocolate
    static let lineWidthKey = "lmRing.lineWidth"
    static let featherKey = "lmRing.feather"
    static let blurKey = "lmRing.blur"
    static let scaleKey = "lmRing.scale"
    static let complexityKey = "lmRing.complexity"
    static let speedKey = "lmRing.speed"
    static let haloKey = "lmRing.halo"
    static let haloStrengthKey = "lmRing.haloStrength"
    static let haloLapKey = "lmRing.haloLap"

    static let defaults: [String: Any] = [
        enabledKey: true, presetKey: "auto", lineWidthKey: 0.8, featherKey: 0.5, blurKey: 1.5,
        scaleKey: 0.7, complexityKey: 0.45, speedKey: 1.0, haloKey: true, haloStrengthKey: 0.65, haloLapKey: 7.0,
    ]

    static func reset() {
        for k in defaults.keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    static func preset(named raw: String, dark: Bool) -> LiquidMetalPreset {
        switch raw {
        case "chromatic": return .chromatic
        case "rainbowSilver": return .rainbowSilver
        case "rainbowWhite": return .rainbowWhite
        case "silver": return .silver
        case "chromaticLight": return .chromaticLight
        case "mintChocolate": return .mintChocolate
        default: return dark ? .chromatic : .silver   // 粟粟：深色彩虹黑身，浅色银
        }
    }

    static let presetOptions: [(raw: String, name: String)] = [
        ("auto", "跟主题"), ("chromatic", "彩虹·黑身"), ("rainbowSilver", "彩虹·银身"), ("rainbowWhite", "彩虹·白身"),
        ("silver", "银"), ("chromaticLight", "原版浅"), ("mintChocolate", "薄荷巧克力"),
    ]
}

/// 会流动的金属描边环（metal-fx 直译，见 LiquidMetal.metal）。挂在输入框 overlay，键盘在（焦点在）时显示。
/// 结构：环带 = 一张软 alpha mask（圆角矩形外扩 feather + 模糊 → 外沿虚；内圈按 lineWidth destinationOut 锐切 → 内沿实），
/// shader 面和 halo 都套这张 mask，所以不会有任何直边露出来（08-25 方框事故：halo 只挖内圈没套环带）。
/// 参数默认读设置页仪表盘（AppStorage），显式传入的覆盖它（harness 用）。
struct LiquidMetalRing: View {
    var cornerRadius: CGFloat = 20
    /// input-jank C3：打字期间暂停逐帧重画（600ms 无键入后恢复），聚焦时的环不再每帧烧 Canvas+shader
    var paused: Bool = false
    var lineWidth: CGFloat? = nil
    var feather: CGFloat? = nil
    var blurFactor: CGFloat? = nil
    var preset: LiquidMetalPreset? = nil
    var halo: Bool? = nil
    /// nil = 跟 app 当前主题底色亮度（不看系统 colorScheme——输入框在嵌套 HC 里环境值跟不上；也不看 themeMode——切主题定义也要跟）；预览用显式值
    var forceDark: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isDark: Bool {
        if let forceDark { return forceDark }
        let bg = ThemeManager.shared.currentTokenSet.mainBg
        return 0.2126 * bg.red + 0.7152 * bg.green + 0.0722 * bg.blue < 0.5
    }
    @AppStorage(LiquidMetalTuning.lineWidthKey) private var tLineWidth = 0.8
    @AppStorage(LiquidMetalTuning.featherKey) private var tFeather = 0.5
    @AppStorage(LiquidMetalTuning.blurKey) private var tBlur = 1.5
    @AppStorage(LiquidMetalTuning.scaleKey) private var tScale = 0.7
    @AppStorage(LiquidMetalTuning.complexityKey) private var tComplexity = 0.45
    @AppStorage(LiquidMetalTuning.speedKey) private var tSpeed = 1.0
    @AppStorage(LiquidMetalTuning.haloKey) private var tHalo = true
    @AppStorage(LiquidMetalTuning.haloStrengthKey) private var tHaloStrength = 0.65
    @AppStorage(LiquidMetalTuning.haloLapKey) private var tHaloLap = 7.0

    private var resolvedPreset: LiquidMetalPreset {
        // 预设键不再读（仪表盘已摘，旧值可能卡在「彩虹·黑身」让跟主题失效）：一律跟主题
        var p = preset ?? LiquidMetalTuning.preset(named: "auto", dark: isDark)
        if preset == nil {
            p.scale = Float(tScale); p.complexity = Float(tComplexity); p.speed = Float(tSpeed)
        }
        return p
    }
    private var lw: CGFloat { lineWidth ?? CGFloat(tLineWidth) }
    private var fe: CGFloat { feather ?? CGFloat(tFeather) }
    private var bf: CGFloat { blurFactor ?? CGFloat(tBlur) }
    private var haloOn: Bool { halo ?? tHalo }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || paused)) { tl in
            // 原版 JS 把 u_time 乘了 preset.speed；取模防 float 精度漂
            let now = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            let preset = resolvedPreset
            let t = Float(now) * preset.speed
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius + fe, style: .continuous)
                        .fill(ShaderLibrary.liquidMetal(.boundingRect, .float(t), .floatArray(preset.params)))
                        .frame(width: w + 2 * fe, height: h + 2 * fe)
                    if haloOn {
                        LiquidMetalHalo(cornerRadius: cornerRadius, lineWidth: lw, time: now,
                                        strength: tHaloStrength, lap: tHaloLap)
                            .frame(width: w, height: h)
                    }
                }
                .position(x: w / 2, y: h / 2)
                .mask(ringBand(w: w, h: h))
            }
        }
        .allowsHitTesting(false)
    }

    /// 环带 alpha：外扩圆角面整体模糊（外沿虚），内圈 destinationOut 锐切（内沿实）
    private func ringBand(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius + fe, style: .continuous)
                .fill(.white)
                .frame(width: w + 2 * fe, height: h + 2 * fe)
                .blur(radius: fe * bf)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .inset(by: lw)
                .fill(.black)
                .frame(width: w, height: h)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: w + 6 * fe + 20, height: h + 6 * fe + 20)
        .position(x: w / 2, y: h / 2)
    }
}

/// 沿周长滑动的高光（原版 glow SVG 近似）：4 层白色描边段（宽/模糊/透明度抄原版），mask 到环带里 screen 混合；
/// 原版位置跟 shader 最亮点走，这里近似成匀速绕圈 + 漫游 + 3s 呼吸。
struct LiquidMetalHalo: View {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let time: TimeInterval
    var strength: Double = 0.7
    var lap: Double = 9

    private static let layers: [(width: CGFloat, blur: CGFloat, opacity: Double)] = [
        (26.4, 8.4, 0.385), (15.6, 4.8, 0.595), (7.2, 2.1, 0.70), (3.0, 0.9, 0.70),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let perim = 2 * (w + h) - (8 - 2 * .pi) * cornerRadius
            let m = perim / (2 * (140 + 40) - (8 - 2 * .pi) * 20)   // 相对原版 140×40 r20 基准
            let halfFrac = (7.8 * m) / perim                        // 半长 7.8px × m，化成 trim 比例
            let wander = 0.02 * sin(time * 0.7)
            let center = ((time / lap) + wander).truncatingRemainder(dividingBy: 1)
            let pulse = 0.6 + 0.4 * (0.5 + 0.5 * sin(time * 2 * .pi / 3))
            ZStack {
                ForEach(Array(Self.layers.enumerated()), id: \.offset) { _, l in
                    segment(center: center, half: halfFrac, width: l.width, blur: l.blur, opacity: l.opacity)
                }
            }
            .opacity(strength * pulse)
            .blendMode(.screen)
        }
    }

    /// trim 段过 0/1 时拆两段
    @ViewBuilder
    private func segment(center: Double, half: Double, width: CGFloat, blur: CGFloat, opacity: Double) -> some View {
        let a = center - half, b = center + half
        let style = StrokeStyle(lineWidth: width, lineCap: .round)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .trim(from: max(0, a), to: min(1, b))
                .stroke(Color.white, style: style)
            if a < 0 {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .trim(from: 1 + a, to: 1).stroke(Color.white, style: style)
            }
            if b > 1 {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .trim(from: 0, to: b - 1).stroke(Color.white, style: style)
            }
        }
        .blur(radius: blur)
        .opacity(opacity)
    }
}

/// 预设 = 原版 light 侧参数 + 5 色（原版 7 色只用前 5）。
struct LiquidMetalPreset {
    var speed: Float = 1.2
    var intensity: Float = 2
    var scale: Float = 2.5
    var directionDeg: Float = 80
    var distortion: Float = 0.3
    var complexity: Float = 0.68
    var vignette: Float = 0.2
    var vigOpacity: Float = 0.26
    var blur: Float = 1
    var shaderOpacity: Float = 1
    var colors: [UInt32]
    /// 基准画布（原版 button 变体 134×40，circle 32×32）+ 取样放大 + dpr
    var baseW: Float = 134
    var baseH: Float = 40
    var shaderScale: Float = 1.6
    var dpr: Float = 2

    var params: [Float] {
        var p: [Float] = [intensity, scale, directionDeg * .pi / 180, distortion, complexity,
                          vignette, vigOpacity, blur, shaderOpacity]
        for hex in colors.prefix(5) {
            p.append(Float((hex >> 16) & 0xFF) / 255)
            p.append(Float((hex >> 8) & 0xFF) / 255)
            p.append(Float(hex & 0xFF) / 255)
        }
        p += [baseW, baseH, shaderScale, dpr]
        return p
    }

    /// 原版 chromatic **dark 侧**（站点默认那圈彩虹：黑 / 浅青 / 浅绿 / 粉 / 近黑）。scale/complexity 比原版 1.6/.68 调稀（粟粟：太密）
    static let chromatic = LiquidMetalPreset(scale: 1.0, complexity: 0.45, vignette: 0.26, vigOpacity: 0.6, colors: [0x000000, 0xAAE8FF, 0xC5FE9E, 0xF7888D, 0x0D0D0D])
    /// 浅底用：银灰身 + 同一组彩虹（白底上黑环难看，纯白身 halo 又看不出）
    static let rainbowSilver = LiquidMetalPreset(scale: 1.0, complexity: 0.45, vignette: 0.26, vigOpacity: 0.3, colors: [0xB4B4B4, 0xAAE8FF, 0xC5FE9E, 0xF7888D, 0xE6E6E6])
    /// 同一组彩虹把黑换成白：白底柔彩虹备选
    static let rainbowWhite = LiquidMetalPreset(scale: 1.0, complexity: 0.45, vignette: 0.26, vigOpacity: 0.3, colors: [0xFFFFFF, 0xAAE8FF, 0xC5FE9E, 0xF7888D, 0xF5F5F5])
    /// 原版 chromatic light 侧（白白白粉灰，shader 只用前 5 色所以没有彩虹）
    static let chromaticLight = LiquidMetalPreset(vignette: 0.24, vigOpacity: 0.16, colors: [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFB3B3, 0xADADAD])
    /// 原版 silver light
    static let silver = LiquidMetalPreset(colors: [0xF6F6F6, 0xFFFFFF, 0xFFFFFF, 0xF7F7F7, 0xC9C9C9])
    /// 暖奶白 / 浅薄荷 / 白 / 薄荷 / 浅棕灰（08-25 首版，粟粟打回：跟原版完全不一样）
    static let mintChocolate = LiquidMetalPreset(colors: [0xFFFBF6, 0xE7EEEC, 0xFFFFFF, 0x8EBD9F, 0xC9C4BE])
}
