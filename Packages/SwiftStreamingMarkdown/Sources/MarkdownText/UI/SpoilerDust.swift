// 按 docs/spec-dust-cleanroom.md 净室实现（#007）
import CoreGraphics
import Foundation
import QuartzCore
#if !os(macOS)
import UIKit
#endif

// MARK: - 纯数值（可测）

/// 剧透粒子的几何 / 数值，全部是纯函数
enum SpoilerDustMath {
  /// 稳定时每平方点同时可见的点数（会动的版本）；静态点图按 staticDensityFactor 打折
  static let density: Double = 0.7
  static let staticDensityFactor: Double = 0.7
  /// 一层最多同时可见多少颗：大段剧透不无限加点
  static let maxVisible: Double = 20000
  /// 行矩形窄 / 矮于这个（点）就不撒
  static let minSide: CGFloat = 2
  static let minRevealRadius: CGFloat = 16
  /// 揭开圆最后多扩出去的余量（点）
  static let revealMargin: CGFloat = 4
  static let revealDurationRange: ClosedRange<TimeInterval> = 0.35...0.55
  static let reducedMotionRevealDuration: TimeInterval = 0.25
  /// 一颗的寿命包络：先淡入、在中段亮着、再淡出（u = 已活时间 / 寿命）
  static let lifeEnvelope: (values: [Double], locations: [Double]) = ([0, 0.9, 1, 0], [0, 0.25, 0.45, 1])

  /// 面积对应的同时可见颗数（封顶）
  static func visibleCount(area: Double) -> Double {
    guard area.isFinite, area > 0 else { return 0 }
    return min(area * density, maxVisible)
  }

  static func usableRects(_ rects: [CGRect]) -> [CGRect] {
    rects.filter {
      $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite
        && $0.width >= minSide && $0.height >= minSide
    }
  }

  /// 揭开圆的终点半径：从手指到所有行矩形最远的角，再加一点余量
  static func revealRadius(from point: CGPoint, rects: [CGRect]) -> CGFloat {
    let reach = farthestCorner(from: point, rects: rects)
    return max(minRevealRadius, reach + revealMargin)
  }

  /// 揭开时长：手指在剧透中间最长；越靠边（圆要扩得越远）越短——远的圆走得快，免得拖沓
  static func revealDuration(from point: CGPoint, rects: [CGRect]) -> TimeInterval {
    let union = rects.reduce(CGRect.null) { $0.union($1) }
    let lo = revealDurationRange.lowerBound, hi = revealDurationRange.upperBound
    guard !union.isNull, union.width > 0 || union.height > 0 else { return lo }
    let diagonal = Double(hypot(union.width, union.height))
    let ratio = min(max(Double(farthestCorner(from: point, rects: rects)) / diagonal, 0.5), 1)
    return hi - (hi - lo) * (ratio - 0.5) / 0.5
  }

  /// 弹簧式吸附的刚度：约 0.8 个揭开时长内走完四分之一周期（到达手指）
  static func attractorStiffness(duration: TimeInterval) -> Double {
    let quarter = max(duration, 0.05) * 0.8
    return pow(Double.pi / 2 / quarter, 2)
  }

  struct StaticDot: Equatable {
    var center: CGPoint
    var radius: CGFloat
    /// 0…2，三档深浅
    var shade: Int
  }

  static let staticShadeOpacities: [Float] = [0.35, 0.6, 0.9]

  /// 减弱动态效果的静态点图：随机数只由行矩形的几何决定，同样的排版每次画出来都一样
  static func staticDots(in rects: [CGRect]) -> [StaticDot] {
    let usable = usableRects(rects)
    let area = usable.reduce(0.0) { $0 + Double($1.width * $1.height) }
    let total = visibleCount(area: area) * staticDensityFactor
    guard total > 0 else { return [] }
    var dots: [StaticDot] = []
    dots.reserveCapacity(Int(total) + usable.count)
    for (index, rect) in usable.enumerated() {
      var rng = SplitMix64(seed: seed(for: rect, index: index))
      let count = Int((total * Double(rect.width * rect.height) / area).rounded())
      for _ in 0..<count {
        let r = 0.45 + 0.3 * CGFloat(rng.nextUnit())
        // 点整颗留在矩形里
        let x = rect.minX + r + (rect.width - 2 * r) * CGFloat(rng.nextUnit())
        let y = rect.minY + r + (rect.height - 2 * r) * CGFloat(rng.nextUnit())
        dots.append(StaticDot(center: CGPoint(x: x, y: y), radius: r, shade: Int(rng.next() % 3)))
      }
    }
    return dots
  }

  private static func farthestCorner(from p: CGPoint, rects: [CGRect]) -> CGFloat {
    var best: CGFloat = 0
    for r in rects where !r.isNull {
      for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
        best = max(best, hypot(c.x - p.x, c.y - p.y))
      }
    }
    return best
  }

  /// 按 1/4 点量化，排版的浮点抖动不改随机序列
  private static func seed(for rect: CGRect, index: Int) -> UInt64 {
    var h: UInt64 = 0x51_7C_C1_B7_27_22_0A_95 &+ UInt64(index)
    for v in [rect.minX, rect.minY, rect.width, rect.height] {
      let q = min(max((v * 4).rounded(), -9e18), 9e18)          // 夹住，超大坐标也不会让 Int64 转换崩
      h = (h ^ UInt64(bitPattern: Int64(q))) &* 0x100_0000_01B3
    }
    return h
  }
}

/// 小而稳的确定性随机数
struct SplitMix64 {
  private var state: UInt64
  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// [0, 1)
  mutating func nextUnit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
}

// MARK: - 未公开的发射器行为（拿不到就退化）

/// Core Animation 的 CAEmitterBehavior 没有公开头文件：按类名 + 运行时取，类 / 键不存在时返回 nil，
/// 调用方退回普通的点。只用了运行时自省看到的输入键（inputKeys）
enum SpoilerEmitterBehavior {
  /// 测试里替换成 { _ in nil } 模拟拿不到
  static var factory: (String) -> NSObject? = { type in
    guard let cls = NSClassFromString("CAEmitterBehavior") as? NSObject.Type else { return nil }
    let make = NSSelectorFromString("behaviorWithType:")
    guard cls.responds(to: make) else { return nil }
    return cls.perform(make, with: type)?.takeUnretainedValue() as? NSObject
  }

  /// 造一个行为并设好输入；任何一个键对方不认就整个放弃（KVC 未知键会抛异常，不能硬设）
  static func make(_ type: String, _ inputs: [String: Any], name: String? = nil) -> NSObject? {
    guard let behavior = factory(type) else { return nil }
    if let name {
      guard behavior.responds(to: NSSelectorFromString("setName:")) else { return nil }
      behavior.setValue(name, forKey: "name")
    }
    let keysSelector = NSSelectorFromString("inputKeys")
    guard behavior.responds(to: keysSelector),
          let keys = behavior.perform(keysSelector)?.takeUnretainedValue() as? [String],
          inputs.keys.allSatisfy(keys.contains) else { return nil }
    for (key, value) in inputs { behavior.setValue(value, forKey: key) }
    return behavior
  }

  static func attach(_ behaviors: [NSObject], to emitter: CAEmitterLayer) {
    guard emitter.responds(to: NSSelectorFromString("setEmitterBehaviors:")) else { return }
    emitter.setValue(behaviors, forKey: "emitterBehaviors")
  }

  static func pointValue(_ p: CGPoint) -> NSValue {
    #if os(macOS)
    NSValue(point: p)
    #else
    NSValue(cgPoint: p)
    #endif
  }
}

// MARK: - 粒子层

/// ||剧透|| 上那片会呼吸的细点。会动的版本用 CAEmitterLayer（每个行矩形一个、裁在矩形里，
/// 粒子在渲染服务里算）；减弱动态效果时画一张确定性的静态点图（CAShapeLayer，矢量，跟 contentsScale 走）
final class SpoilerDustLayer: CALayer {
  private(set) var rects: [CGRect] = []
  private(set) var isRevealing = false

  private let animated: Bool
  private var color: CGColor?
  private var builtScale: CGFloat = 0
  /// 会动的版本：每个可用行矩形一个发射器
  private(set) var emitterLayers: [CAEmitterLayer] = []
  /// 静态版本：三档深浅各一层
  private(set) var staticDotLayers: [CAShapeLayer] = []
  /// 发射器上挂好了（刚度为 0 的）吸附行为；拿不到私有行为时为 false
  private(set) var hasPullBehavior = false

  private static let inkCell = "ink"
  private static let beadCell = "bead"
  private static let pullBehavior = "pull"
  /// 细点占九成多，剩下是稍大、稍淡的「珠子」，让颗粒有层次
  private static let beadShare: Double = 0.08
  private static let inkLifetime: Float = 1.0
  private static let beadLifetime: Float = 1.3

  init(animated: Bool) {
    self.animated = animated
    super.init()
    actions = Self.quietActions
  }

  override init(layer: Any) {
    let other = layer as? SpoilerDustLayer
    animated = other?.animated ?? true
    super.init(layer: layer)
    rects = other?.rects ?? []
    isRevealing = other?.isRevealing ?? false
    color = other?.color
  }

  required init?(coder: NSCoder) {
    animated = true
    super.init(coder: coder)
  }

  private static let quietActions: [String: CAAction] = [
    "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "sublayers": NSNull(), "mask": NSNull(),
  ]

  /// 内容 / 宽度 / 颜色变了就再调一次；揭开过程中不理
  func update(rects newRects: [CGRect], color newColor: CGColor) {
    guard !isRevealing else { return }
    let recolor = color.map { $0 != newColor } ?? true
    let rescale = builtScale != contentsScale
    guard recolor || rescale || newRects != rects else { return }
    rects = newRects
    color = newColor
    builtScale = contentsScale
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if animated {
      layoutEmitters(rebuild: recolor || rescale)
    } else {
      drawStaticDots(newColor)
    }
    CATransaction.commit()
  }

  /// 点一下揭开：圆从手指扩开（字跟着露出来、圆里的点消失），圆外的点被吸向手指，后半程整层淡出
  func reveal(at point: CGPoint, textMask: SpoilerTextRevealMask?, completion: @escaping () -> Void) {
    guard !isRevealing else { return }
    isRevealing = true
    let duration: TimeInterval
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if animated {
      let radius = SpoilerDustMath.revealRadius(from: point, rects: rects)
      duration = SpoilerDustMath.revealDuration(from: point, rects: rects)
      let timing = CAMediaTimingFunction(name: .easeIn)
      collapse(toward: point, duration: duration)
      punchHole(at: point, radius: radius, duration: duration, timing: timing)
      fadeOut(duration: duration, holdFraction: 0.45)
      textMask?.expand(from: point, to: radius, duration: duration, timing: timing)
    } else {
      duration = SpoilerDustMath.reducedMotionRevealDuration
      fadeOut(duration: duration, holdFraction: 0)
      textMask?.fadeIn(duration: duration)
    }
    CATransaction.commit()
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { completion() }
  }

  // MARK: 会动的版本

  private func layoutEmitters(rebuild: Bool) {
    let usable = SpoilerDustMath.usableRects(rects)
    if rebuild {
      // 换色要即时生效：发射器的颜色只影响新生的点，所以整批换新（新发射器默认就是满密度状态）
      emitterLayers.forEach { $0.removeFromSuperlayer() }
      emitterLayers = []
    }
    // 行数变了（流式输出折行）只在尾部增删，已有行的点不动；种子按行序号定，同一行重建也是同一个序列
    while emitterLayers.count > usable.count { emitterLayers.removeLast().removeFromSuperlayer() }
    while emitterLayers.count < usable.count {
      let emitter = makeEmitter(line: emitterLayers.count)
      addSublayer(emitter)
      emitterLayers.append(emitter)
    }
    let area = usable.reduce(0.0) { $0 + Double($1.width * $1.height) }
    let total = SpoilerDustMath.visibleCount(area: area)
    for (rect, emitter) in zip(usable, emitterLayers) {
      // 流式输出时每个 token 都会走到这里：几何差 ≤1pt、出生率差 <10% 都不写，发射器不跟着每帧抖
      if Self.differs(emitter.frame, rect, by: 1) {
        emitter.frame = rect
        emitter.emitterPosition = CGPoint(x: rect.width / 2, y: rect.height / 2)
        emitter.emitterSize = rect.size
      }
      // 同时可见 = 出生率 × 寿命
      let share = area > 0 ? total * Double(rect.width * rect.height) / area : 0
      Self.setBirthRate(Float(share * (1 - Self.beadShare)) / Self.inkLifetime, cell: Self.inkCell, on: emitter)
      Self.setBirthRate(Float(share * Self.beadShare) / Self.beadLifetime, cell: Self.beadCell, on: emitter)
    }
  }

  private static func differs(_ a: CGRect, _ b: CGRect, by tolerance: CGFloat) -> Bool {
    abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance
      || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
  }

  private static func setBirthRate(_ rate: Float, cell name: String, on emitter: CAEmitterLayer) {
    let current = emitter.emitterCells?.first { $0.name == name }?.birthRate ?? 0
    guard rate != current, abs(rate - current) >= 0.1 * current else { return }
    emitter.setValue(rate, forKeyPath: "emitterCells.\(name).birthRate")
  }

  private func makeEmitter(line: Int) -> CAEmitterLayer {
    let emitter = CAEmitterLayer()
    emitter.actions = Self.quietActions
    emitter.emitterShape = .rectangle
    emitter.emitterMode = .surface
    emitter.masksToBounds = true                      // 点只在这一行矩形里
    emitter.contentsScale = contentsScale
    // 每行各自的随机序列（同宽的行不重复），且只由行序号决定：重建同一行不换花样
    emitter.seed = UInt32(truncatingIfNeeded: ((UInt64(line) &+ 1) &* 0x9E37_79B9_7F4A_7C15) >> 32)
    let baseAlpha = color?.alpha ?? 1
    let dot = Self.dotImage(scale: contentsScale)
    let fade = SpoilerEmitterBehavior.make("valueOverLife", [
      "keyPath": "color.alpha",
      "values": SpoilerDustMath.lifeEnvelope.values,
      "locations": SpoilerDustMath.lifeEnvelope.locations,
    ])

    let ink = CAEmitterCell()
    ink.name = Self.inkCell
    ink.lifetime = Self.inkLifetime
    ink.lifetimeRange = 0.3
    ink.velocity = 9
    ink.velocityRange = 9                              // 0…18 pt/s
    ink.emissionRange = .pi * 2
    ink.scale = 1
    ink.scaleRange = 0.3
    ink.alphaRange = 0.35
    ink.color = color?.copy(alpha: baseAlpha * 0.75)

    let bead = CAEmitterCell()
    bead.name = Self.beadCell
    bead.lifetime = Self.beadLifetime
    bead.lifetimeRange = 0.3
    bead.velocity = 5
    bead.velocityRange = 5
    bead.emissionRange = .pi * 2
    bead.scale = 1.6
    bead.scaleRange = 0.3
    bead.alphaRange = 0.15
    bead.color = color?.copy(alpha: baseAlpha * 0.4)

    for cell in [ink, bead] {
      cell.contents = dot.image
      cell.contentsScale = dot.pixelsPerPoint
      cell.minificationFilter = CALayerContentsFilter.trilinear.rawValue
      cell.birthRate = 0
      // 拿不到「先淡入再淡出」就退化成只淡出
      if fade == nil { cell.alphaSpeed = -Float(cell.color?.alpha ?? 1) / cell.lifetime }
    }
    emitter.emitterCells = [ink, bead]
    let pull = SpoilerEmitterBehavior.make("simpleAttractor", [
      "position": SpoilerEmitterBehavior.pointValue(.zero),
      "stiffness": NSNumber(value: 0),
    ], name: Self.pullBehavior)
    hasPullBehavior = pull != nil
    let behaviors = [fade, pull].compactMap { $0 }
    if !behaviors.isEmpty { SpoilerEmitterBehavior.attach(behaviors, to: emitter) }
    return emitter
  }

  /// 1pt 直径的白色圆点（颜色由 cell.color 乘上去）；按两倍设备像素画，缩下来边缘干净
  private static func dotImage(scale: CGFloat) -> (image: CGImage?, pixelsPerPoint: CGFloat) {
    let px = max(4, Int((max(scale, 1) * 2).rounded()))
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx?.fillEllipse(in: CGRect(x: 0, y: 0, width: px, height: px))
    return (ctx?.makeImage(), CGFloat(px))
  }

  /// 停止出生、把现有的点吸向手指（弹簧式吸附，拿不到就只是停止出生，剩下的照常淡出）。
  /// 吸附行为建发射器时就挂好、刚度为 0：揭开时再改它的参数。中途重设整个行为数组会让发射器按新行为
  /// 把已有粒子的历史重算一遍（实测点会瞬间缩成一团），只改参数则从这一刻起生效
  private func collapse(toward point: CGPoint, duration: TimeInterval) {
    let stiffness = SpoilerDustMath.attractorStiffness(duration: duration)
    for emitter in emitterLayers {
      emitter.birthRate = 0
      guard hasPullBehavior else { continue }
      let local = CGPoint(x: point.x - emitter.frame.minX, y: point.y - emitter.frame.minY)
      emitter.setValue(SpoilerEmitterBehavior.pointValue(local), forKeyPath: "emitterBehaviors.\(Self.pullBehavior).position")
      emitter.setValue(NSNumber(value: stiffness), forKeyPath: "emitterBehaviors.\(Self.pullBehavior).stiffness")
    }
  }

  /// 圆里的点消失：一层带圆洞的遮罩，洞跟揭开圆同时长、同缓动地扩开
  private func punchHole(at point: CGPoint, radius: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction) {
    let hole = CAShapeLayer()
    hole.frame = bounds
    hole.fillRule = .evenOdd
    hole.fillColor = CGColor(gray: 0, alpha: 1)
    let outer = bounds.insetBy(dx: -radius * 2, dy: -radius * 2)
    func path(_ r: CGFloat) -> CGPath {
      let p = CGMutablePath()
      p.addRect(outer)
      p.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
      return p
    }
    let from = path(0.5), to = path(radius)
    hole.path = to
    let anim = CABasicAnimation(keyPath: "path")
    anim.fromValue = from
    anim.toValue = to
    anim.duration = duration
    anim.timingFunction = timing
    hole.add(anim, forKey: "reveal")
    mask = hole
  }

  /// 整层淡出：前 holdFraction 保持，之后线性到 0（模型值直接设 0，动画结束到回调之间不会闪回）
  private func fadeOut(duration: TimeInterval, holdFraction: Double) {
    opacity = 0
    let anim = CAKeyframeAnimation(keyPath: "opacity")
    anim.values = [1, 1, 0]
    anim.keyTimes = [0, NSNumber(value: holdFraction), 1]
    anim.duration = duration
    add(anim, forKey: "reveal-fade")
  }

  // MARK: 静态版本

  private func drawStaticDots(_ color: CGColor) {
    if staticDotLayers.isEmpty {
      staticDotLayers = SpoilerDustMath.staticShadeOpacities.map { shade in
        let layer = CAShapeLayer()
        layer.actions = Self.quietActions.merging(["path": NSNull(), "fillColor": NSNull(), "contentsScale": NSNull()]) { $1 }
        layer.opacity = shade
        return layer
      }
      staticDotLayers.forEach(addSublayer)
    }
    let paths = SpoilerDustMath.staticShadeOpacities.map { _ in CGMutablePath() }
    for dot in SpoilerDustMath.staticDots(in: rects) {
      paths[dot.shade].addEllipse(in: CGRect(x: dot.center.x - dot.radius, y: dot.center.y - dot.radius,
                                             width: dot.radius * 2, height: dot.radius * 2))
    }
    for (layer, path) in zip(staticDotLayers, paths) {
      layer.frame = bounds
      layer.contentsScale = contentsScale
      layer.fillColor = color
      layer.path = path
    }
  }
}

// MARK: - 字的揭开遮罩

/// 揭开时挂在文字视图 layer.mask 上：剧透以外全显示；这个剧透的字只在从手指扩开的软边圆里显示
/// （减弱动态效果时整块淡入）。坐标与文字视图相同（左上原点）
final class SpoilerTextRevealMask: CALayer {
  private let spoilerRects: [CGRect]
  private let outside = CAShapeLayer()
  private let circle = CAGradientLayer()
  private let wholeSpoiler = CAShapeLayer()
  /// 圆边外沿渐隐的宽度（点）
  private static let feather: CGFloat = 10

  init(bounds: CGRect, spoilerRects: [CGRect]) {
    self.spoilerRects = spoilerRects
    super.init()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // bounds 原点也跟着设，子层就直接用文字视图的坐标
    self.bounds = bounds
    position = CGPoint(x: bounds.midX, y: bounds.midY)
    let black = CGColor(gray: 0, alpha: 1)

    let outsidePath = CGMutablePath()
    outsidePath.addRect(bounds.insetBy(dx: -1, dy: -1))
    spoilerRects.forEach { outsidePath.addRect($0) }
    outside.frame = bounds
    outside.bounds = bounds
    outside.fillRule = .evenOdd
    outside.fillColor = black
    outside.path = outsidePath
    addSublayer(outside)

    circle.type = .radial
    circle.colors = [black, black, CGColor(gray: 0, alpha: 0)]
    circle.startPoint = CGPoint(x: 0.5, y: 0.5)
    circle.endPoint = CGPoint(x: 1, y: 1)
    circle.isHidden = true
    addSublayer(circle)

    let spoilerPath = CGMutablePath()
    spoilerRects.forEach { spoilerPath.addRect($0) }
    wholeSpoiler.frame = bounds
    wholeSpoiler.bounds = bounds
    wholeSpoiler.fillColor = black
    wholeSpoiler.path = spoilerPath
    wholeSpoiler.opacity = 0
    addSublayer(wholeSpoiler)
    CATransaction.commit()
  }

  override init(layer: Any) {
    spoilerRects = (layer as? SpoilerTextRevealMask)?.spoilerRects ?? []
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) {
    spoilerRects = []
    super.init(coder: coder)
  }

  /// 圆从 point 扩到 radius（软边在 radius 外面，扩完时剧透整块完全露出）
  func expand(from point: CGPoint, to radius: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction) {
    let outer = radius + Self.feather
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    circle.bounds = CGRect(x: 0, y: 0, width: outer * 2, height: outer * 2)
    circle.position = point
    circle.locations = [0, NSNumber(value: Double(radius / outer)), 1]
    circle.isHidden = false
    circle.transform = CATransform3DIdentity
    let anim = CABasicAnimation(keyPath: "transform.scale")
    anim.fromValue = 0.001
    anim.toValue = 1
    anim.duration = duration
    anim.timingFunction = timing
    circle.add(anim, forKey: "reveal")
    CATransaction.commit()
  }

  /// 减弱动态效果：剧透整块淡入
  func fadeIn(duration: TimeInterval) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    wholeSpoiler.opacity = 1
    let anim = CABasicAnimation(keyPath: "opacity")
    anim.fromValue = 0
    anim.toValue = 1
    anim.duration = duration
    wholeSpoiler.add(anim, forKey: "reveal")
    CATransaction.commit()
  }
}
