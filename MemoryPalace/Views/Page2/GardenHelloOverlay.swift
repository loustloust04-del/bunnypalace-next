#if os(iOS)
import SwiftUI
import UIKit
import QuartzCore
import CoreImage

// MARK: - 第一次回到 gardenOS 桌面：开机 hello（占位，§11-5；小样 design-onboarding-xiaoya-v2.html B）
// 黑屏 → 手写 hello 一笔写完（渐变主线 + 发光 + 沿笔画跑的白高光）→ 放大淡出 → 从中间圆形揭开桌面 → 桌面一条条落位，3.3 秒。
// 只放一次（新装用户：onboarding.xiaoyaV1 = started / done；老用户升级不放），放之前就记 garden.helloShown，中途被杀不重放。
// 跟开屏 LaunchSplashAnimation 一个路子：盖一层独立 UIWindow，全是 Core Animation 关键帧，不逐帧回调、不碰桌面本体
// （Page2GridView 那棵一行不改）。落位用桌面截图切条：底下垫一张糊过的截图当墙纸，清楚的截图一条条落下来，落完撤掉浮层就是真桌面。
// 画面以后换粟粟那版开屏花，只换这一个文件。重播只在 DEBUG（设置 › 开发调试）。

@MainActor
enum GardenHello {
    static let shownKey = "garden.helloShown"

    /// 新装用户（走过新引导）且没放过
    static func shouldPlay(_ defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: shownKey) else { return false }
        // UI 测试 / 探针 / 测量台（启动参数 page2-ui-test、--xxx）不放：3.3 秒黑屏会挡住它们的第一步
        guard !ProcessInfo.processInfo.arguments.dropFirst().contains(where: { $0 == "page2-ui-test" || $0.hasPrefix("--") }) else { return false }
        let state = defaults.string(forKey: XiaoyaScriptRunner.onboardingKey)
        return state == "started" || state == "done"
    }

    /// 回到桌面停稳了：记下来再放
    static func playIfNeeded() {
        guard shouldPlay(), UIApplication.shared.applicationState == .active, !LaunchSplash.hasCover else { return }
        UserDefaults.standard.set(true, forKey: shownKey)
        GardenHelloOverlay.shared.play()
    }

    #if DEBUG
    /// 设置 › 开发调试「重放开机 hello」：直接盖在当前画面上放
    static func replay() {
        GardenHelloOverlay.shared.play()
    }
    #endif
}

/// 挂在 page2 外壳上：桌面露出来（第二页 + 选中桌面 + 没在拖后台卡片）停 0.45 秒再放。
/// 「去找 X」那条路也会先把选中改成桌面再翻回第一页——等这一下，页已经翻走，不会误放
struct GardenHelloTrigger: ViewModifier {
    let atDesk: Bool
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: atDesk && Page2SceneState.shared.isActive, initial: true) { _, showing in
                pending?.cancel()
                pending = nil
                guard showing, GardenHello.shouldPlay() else { return }
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.45))
                    guard !Task.isCancelled, Page2SceneState.shared.isActive else { return }
                    GardenHello.playIfNeeded()
                }
            }
    }
}

@MainActor
final class GardenHelloOverlay {
    static let shared = GardenHelloOverlay()

    private var window: UIWindow?
    private var finishing = false
    private var token = 0
    private var resignObserver: NSObjectProtocol?

    static let total: CFTimeInterval = 3.3

    func play() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        token += 1
        let current = token
        finishing = false
        let w = UIWindow(windowScene: scene)
        w.frame = scene.effectiveGeometry.coordinateSpace.bounds
        w.windowLevel = .alert + 1
        w.accessibilityElementsHidden = true
        let root = HelloRootController()
        root.onTap = { [weak self] in self?.finish(fast: true) }
        w.rootViewController = root
        w.isHidden = false
        window = w
        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(fast: false) }
        }
        if UIAccessibility.isReduceMotionEnabled {
            // 减弱动态效果：不描边，黑底直接淡到桌面
            root.buildStill()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard self?.token == current else { return }
                self?.finish(fast: false, duration: 0.4)
            }
            return
        }
        root.buildAnimated()
        // 1.5 秒时桌面已经在浮层底下画好了：截一张，后台糊一张当墙纸，2 秒前到了就用切条落位，没到就整张揭开
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard self?.token == current else { return }
            Page2AppShell.shared.captureSnapshot(of: "home")
            guard let image = Page2AppShell.shared.desktopSnapshot,
                  let home = Page2AppShell.shared.contentViews["home"]?.view, home.window != nil else { return }
            let frame = home.convert(home.bounds, to: nil)
            DispatchQueue.global(qos: .userInitiated).async {
                let blurred = Self.blur(image)
                DispatchQueue.main.async {
                    guard self?.token == current, let blurred else { return }
                    root.addDesk(sharp: image, blurred: blurred, frame: frame, startAt: root.startTime + 2.05)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.total) { [weak self] in
            guard self?.token == current else { return }
            self?.finish(fast: false)
        }
    }

    /// fast = 点了跳过 / 点任意处：0.25 秒淡掉
    func finish(fast: Bool, duration: TimeInterval? = nil) {
        guard let w = window, !finishing else { return }
        finishing = true
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        let d = duration ?? (fast ? 0.25 : 0.2)
        UIView.animate(withDuration: d, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            w.alpha = 0
        } completion: { [weak self] _ in
            w.isHidden = true
            if self?.window === w { self?.window = nil }
        }
    }

    nonisolated private static func blur(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(26, forKey: kCIInputRadiusKey)
        guard let output = filter?.outputImage?.cropped(to: input.extent),
              let result = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: result, scale: image.scale, orientation: .up)
    }
}

/// 浮层本体：黑底挖洞 + hello 描边 + 跳过钮。全部 CA 关键帧，beginTime 对齐同一个 startTime
private final class HelloRootController: UIViewController {
    var onTap: (() -> Void)?
    private(set) var startTime: CFTimeInterval = 0
    private let black = CAShapeLayer()
    private let deskHost = CALayer()

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        view = v
    }

    @objc private func tapped() { onTap?() }

    private var bounds: CGRect { view.window?.bounds ?? view.bounds }

    func buildStill() {
        view.frame = bounds
        view.backgroundColor = UIColor(red: 0.047, green: 0.051, blue: 0.047, alpha: 1)
    }

    func buildAnimated() {
        let b = bounds
        view.frame = b
        startTime = CACurrentMediaTime() + 0.05
        let t0 = startTime

        deskHost.frame = b
        view.layer.addSublayer(deskHost)

        // 黑底：外框 + 圆洞（even-odd），洞从 0 长到盖满——揭开下面的桌面
        let center = CGPoint(x: b.midX, y: b.height * 0.44)
        let far = hypot(max(center.x, b.width - center.x), max(center.y, b.height - center.y)) + 8
        black.frame = b
        black.fillRule = .evenOdd
        black.fillColor = UIColor(red: 0.047, green: 0.051, blue: 0.047, alpha: 1).cgColor
        black.path = Self.holed(b, center: center, radius: 0.01)
        view.layer.addSublayer(black)
        let hole = CABasicAnimation(keyPath: "path")
        hole.fromValue = Self.holed(b, center: center, radius: 0.01)
        hole.toValue = Self.holed(b, center: center, radius: far)
        hole.beginTime = t0 + 2.05
        hole.duration = 0.6
        hole.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
        hole.fillMode = .forwards
        hole.isRemovedOnCompletion = false
        black.add(hole, forKey: "hole")

        // 背后一团柔光
        let pool = CAGradientLayer()
        pool.type = .radial
        pool.colors = [UIColor(red: 0.89, green: 0.66, blue: 0.69, alpha: 0.16).cgColor,
                       UIColor(red: 0.56, green: 0.74, blue: 0.62, alpha: 0.08).cgColor, UIColor.clear.cgColor]
        pool.locations = [0, 0.55, 1]
        pool.startPoint = CGPoint(x: 0.5, y: 0.5)
        pool.endPoint = CGPoint(x: 1, y: 1)
        pool.bounds = CGRect(x: 0, y: 0, width: 340, height: 240)
        pool.position = center
        pool.opacity = 0
        view.layer.addSublayer(pool)
        pool.add(Self.keyframes("opacity", values: [0, 0, 1, 1, 0], times: [0, 0.1, 0.54, 1.86, 2.3], begin: t0), forKey: "pool")

        // hello：viewBox 300×150 放大 1.1 倍
        let k: CGFloat = 1.1
        let word = CALayer()
        word.bounds = CGRect(x: 0, y: 0, width: 300 * k, height: 150 * k)
        word.position = center
        word.opacity = 0
        view.layer.addSublayer(word)
        var scale = CGAffineTransform(scaleX: k, y: k)
        let path = Self.hello.copy(using: &scale) ?? Self.hello
        let width: CGFloat = 7.5 * k

        let glow = gradient(word.bounds, mask: stroke(path, width: width * 1.9))
        glow.opacity = 0.6
        let glowHost = CALayer()
        glowHost.frame = word.bounds
        glowHost.shadowColor = UIColor(red: 0.89, green: 0.66, blue: 0.69, alpha: 1).cgColor
        glowHost.shadowRadius = 7
        glowHost.shadowOpacity = 0.9
        glowHost.shadowOffset = .zero
        glowHost.addSublayer(glow)
        word.addSublayer(glowHost)
        let main = gradient(word.bounds, mask: stroke(path, width: width))
        word.addSublayer(main)
        let shine = stroke(path, width: width * 0.22, color: UIColor.white.withAlphaComponent(0.55))
        shine.frame = word.bounds.offsetBy(dx: -0.9, dy: -1.4)
        word.addSublayer(shine)
        let glint = stroke(path, width: width * 0.42, color: .white)
        glint.frame = word.bounds.offsetBy(dx: -0.6, dy: -1)
        glint.strokeStart = 0
        glint.strokeEnd = 0
        word.addSublayer(glint)

        let ease = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.28, 1)
        for layer in [glow.mask, main.mask, shine].compactMap({ $0 as? CAShapeLayer }) {
            layer.strokeEnd = 0
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.beginTime = t0 + 0.15
            draw.duration = 1.55
            draw.timingFunction = ease
            draw.fillMode = .both
            draw.isRemovedOnCompletion = false
            layer.add(draw, forKey: "draw")
        }
        let glintEnd = CABasicAnimation(keyPath: "strokeEnd")
        glintEnd.fromValue = 0.05
        glintEnd.toValue = 1
        let glintStart = CABasicAnimation(keyPath: "strokeStart")
        glintStart.fromValue = 0
        glintStart.toValue = 1
        let glintFade = CAKeyframeAnimation(keyPath: "opacity")
        glintFade.values = [0, 0.95, 0.95, 0]
        glintFade.keyTimes = [0, 0.03, 0.85, 1]
        let glintGroup = CAAnimationGroup()
        glintGroup.animations = [glintEnd, glintStart, glintFade]
        glintGroup.beginTime = t0 + 0.15
        glintGroup.duration = 1.55
        glintGroup.timingFunction = ease
        glintGroup.fillMode = .both
        glintGroup.isRemovedOnCompletion = false
        glint.opacity = 0
        glint.add(glintGroup, forKey: "glint")

        // 整个词：出现 → 写完停一拍 → 放大一点淡出
        word.add(Self.keyframes("opacity", values: [0, 0, 1, 1, 0], times: [0, 0.15, 0.17, 1.75, 2.2], begin: t0), forKey: "fade")
        word.add(Self.keyframes("transform.scale", values: [1, 1, 1.06], times: [0, 1.75, 2.2], begin: t0), forKey: "grow")

        // 跳过
        let skip = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = "跳过 ›"
        config.baseForegroundColor = UIColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 0.75)
        config.background.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        config.background.cornerRadius = 99
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
        skip.configuration = config
        skip.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        skip.sizeToFit()
        skip.frame.origin = CGPoint(x: b.width - skip.frame.width - 18, y: max(60, (view.window?.safeAreaInsets.top ?? 0) + 8))
        view.addSubview(skip)
        skip.layer.add(Self.keyframes("opacity", values: [1, 1, 0], times: [0, 3.0, 3.3], begin: t0), forKey: "skipOut")
    }

    /// 桌面截图到了（< 2.05 s）：糊图当墙纸，清楚的截图横切 7 条，2.4 s 起从上往下一条条落位
    func addDesk(sharp: UIImage, blurred: UIImage, frame: CGRect, startAt: CFTimeInterval) {
        guard CACurrentMediaTime() < startAt, let sharpCG = sharp.cgImage else { return }
        let backdrop = CALayer()
        backdrop.frame = frame
        backdrop.contents = blurred.cgImage
        backdrop.contentsGravity = .resize
        deskHost.addSublayer(backdrop)
        let bands = 7
        let t0 = startTime
        for i in 0..<bands {
            let band = CALayer()
            let h = frame.height / CGFloat(bands)
            band.frame = CGRect(x: frame.minX, y: frame.minY + CGFloat(i) * h, width: frame.width, height: h)
            band.contents = sharpCG
            band.contentsRect = CGRect(x: 0, y: CGFloat(i) / CGFloat(bands), width: 1, height: 1 / CGFloat(bands))
            band.contentsGravity = .resize
            band.opacity = 0
            deskHost.addSublayer(band)
            let begin = 2.4 + Double(i) * 0.09
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let drop = CABasicAnimation(keyPath: "transform.translation.y")
            drop.fromValue = -22
            drop.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [fade, drop]
            group.beginTime = t0 + begin
            group.duration = 0.45
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.4, 1)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            band.add(group, forKey: "drop")
        }
    }

    private func gradient(_ frame: CGRect, mask: CAShapeLayer) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.frame = frame
        g.colors = ["#8EBD9F", "#e3a9b0", "#b3a2cc", "#d9a07f"].map { Self.color($0).cgColor }
        g.locations = [0, 0.35, 0.65, 1]
        g.startPoint = CGPoint(x: 0, y: 0.4)
        g.endPoint = CGPoint(x: 1, y: 0.6)
        mask.frame = g.bounds
        g.mask = mask
        return g
    }

    private func stroke(_ path: CGPath, width: CGFloat, color: UIColor = .black) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path = path
        s.fillColor = nil
        s.strokeColor = color.cgColor
        s.lineWidth = width
        s.lineCap = .round
        s.lineJoin = .round
        return s
    }

    private static func holed(_ rect: CGRect, center: CGPoint, radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addRect(rect)
        p.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return p
    }

    private static func keyframes(_ keyPath: String, values: [Double], times: [Double], begin: CFTimeInterval) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        let total = times.last ?? 1
        a.values = values.map { NSNumber(value: $0) }
        a.keyTimes = times.map { NSNumber(value: $0 / total) }
        a.duration = total
        a.beginTime = begin
        a.fillMode = .both
        a.isRemovedOnCompletion = false
        return a
    }

    private static func color(_ hex: String) -> UIColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// 小样 HELLO 路径（同一份坐标，M + C）
    static let hello: CGPath = svgPath("M18,112 C34,104 52,80 60,52 C66,30 58,18 50,30 C42,44 40,84 38,122 C44,100 54,86 66,86 C78,86 78,104 78,114 C78,124 86,126 96,118 C108,110 120,102 120,94 C120,86 110,84 104,92 C96,102 98,124 114,124 C128,124 140,112 150,96 C160,78 170,56 170,40 C170,26 158,26 156,42 C152,64 150,100 156,116 C160,126 172,124 182,110 C192,92 202,70 202,46 C202,30 190,30 188,46 C184,68 182,102 188,116 C192,126 204,124 214,114 C222,104 230,96 240,96 C252,96 256,110 250,120 C244,130 228,130 226,116 C224,104 236,94 248,98 C260,102 270,100 284,90")

    /// 只认 M / C（绝对坐标），够这一条路径用
    static func svgPath(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var command: Character = "M"
        var numbers: [CGFloat] = []
        var token = ""
        func flushToken() {
            if let v = Double(token) { numbers.append(CGFloat(v)) }
            token = ""
        }
        func consume() {
            switch command {
            case "M":
                while numbers.count >= 2 {
                    p.move(to: CGPoint(x: numbers[0], y: numbers[1]))
                    numbers.removeFirst(2)
                }
            case "C":
                while numbers.count >= 6 {
                    p.addCurve(to: CGPoint(x: numbers[4], y: numbers[5]),
                               control1: CGPoint(x: numbers[0], y: numbers[1]),
                               control2: CGPoint(x: numbers[2], y: numbers[3]))
                    numbers.removeFirst(6)
                }
            default:
                numbers.removeAll()
            }
        }
        for ch in d {
            if ch.isLetter {
                flushToken(); consume()
                command = ch
            } else if ch == "," || ch == " " {
                flushToken(); consume()
            } else {
                token.append(ch)
            }
        }
        flushToken(); consume()
        return p
    }
}
#endif
