#if os(iOS)
import CoreHaptics
import SwiftUI
import UIKit

/// 页面装饰，必须放在应用的缩放/位移之前；卡片不显示弧线。
struct Page2CornerBar: View {
    var radius: CGFloat
    /// 底色恒暗的应用（终端）：不跟系统深浅，恒白
    var light = false
    static let edgeGap: CGFloat = 4
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        CornerArc(lineWidth: 3, span: 0.356, displayRadius: radius)
            .fill(light || colorScheme == .dark ? Color.white : Color.black)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// 输入保持在起手区域，视觉装饰随页面移动。只在全屏应用接管；后台用卡片打开/关闭。
struct Page2CornerGesture: View {
    /// 左上起手区边长
    static let zone: CGFloat = 76
    @Binding var selectedToolId: String
    @State private var shell = Page2AppShell.shared
    @State private var hold: Task<Void, Never>?
    @State private var dragging = false
    @State private var haptics = Page2ArcHaptics()
    @AppStorage(Page2Switcher.key) private var switcher = "strip"
    #if (DEBUG || PERF_BENCH) && os(iOS)
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    #endif
    /// 桌面上有后台应用时也接（⧫ 粟粟 10-11「在桌面的时候弧线也可以拉」：拉 = 进后台）
    private var active: Bool {
        switcher == "arc" && Page2SceneState.shared.isActive && (!onDesktop || !shell.stack.openApps.isEmpty)
            && !shell.showsSwitcher && shell.motion?.settling != true
    }
    private var onDesktop: Bool { selectedToolId == "home" }
    /// 松手回桌面那条线：屏幕高的一半（⧫ 粟粟 10-11「拉三分之一就回桌面了，改成拉二分之一才回」）
    private var homeLine: CGFloat { max(255, shell.sceneSize.height / 2) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            Page2ArcTouchSurface(enabled: active, onSwitcher: {
                shell.beginMotion(selectedToolId, fromSwitcher: false)
                shell.settle(card: 1) { shell.showsSwitcher = true }
            }, onHome: {
                shell.beginMotion(selectedToolId, fromSwitcher: false); goHome()
            }) { state, translation, predicted in
                switch state {
                case .began:
                    guard active else { return }
                    shell.cornerTouching = true
                    shell.lockPaging()
                    haptics.prepare()
                    hold?.cancel()
                    guard !onDesktop else { return }
                    hold = Task { @MainActor in
                        // 原 0.38s：按上去犹豫一下就回桌面（⧫ 粟粟 10-11「一不小心就回到桌面」）
                        try? await Task.sleep(for: .milliseconds(650))
                        guard !Task.isCancelled, active, !dragging else { return }
                        shell.beginMotion(selectedToolId, fromSwitcher: false)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        goHome()
                    }
                case .changed:
                    guard active else { return }
                    let distance = pull(translation)
                    if !dragging, distance > 6 {
                        hold?.cancel(); hold = nil; dragging = true
                        shell.beginMotion(selectedToolId, fromSwitcher: false)
                        // 起拖那帧已有 beginMotion（~95ms），震动挪到下一轮 runloop 再建（翻页1mac 审）
                        DispatchQueue.main.async { if dragging { haptics.begin() } }
                    }
                    if dragging {
                        track(distance)
                        haptics.update(distance, home: onDesktop ? nil : homeLine)
                    } else if hypot(translation.width, translation.height) > 12 { hold?.cancel(); hold = nil }
                case .ended:
                    hold?.cancel(); hold = nil
                    haptics.end()
                    shell.cornerTouching = false
                    guard dragging, let motion = shell.motion else {
                        if shell.motion == nil {
                            shell.unlockPaging()
                            // 轻点（没拖、没按到回桌面）= 应用内退一层：书开着就关书、浏览器就后退
                            // （plan-page2-app-shell §2.4 导航钮第 1 条；⧫ 粟粟 09-25：返回应该在左上）
                            if hypot(translation.width, translation.height) < 10 {
                                Page2AppBackRegistry.shared.goBack(selectedToolId)
                            }
                        }
                        return
                    }
                    dragging = false
                    // 回桌面只认实际拉过 homeLine（和桌面视觉、过线那下震对齐），往回收着松手（预测落回线内）不算；
                    // 原来用 max(实际, 预测)，预测对角线最多 +141pt，手快一点小划也判成回桌面
                    let distance = pull(translation)
                    let landing = pull(predicted)
                    if !onDesktop, distance >= homeLine, landing >= homeLine { goHome() }
                    else if max(distance, landing) >= 70 {
                        shell.settle(card: 1) { shell.showsSwitcher = true }
                    } else { shell.settle(card: motion.fromSwitcher ? 1 : 0) {} }
                case .cancelled, .failed:
                    hold?.cancel(); hold = nil; dragging = false
                    haptics.end()
                    shell.cornerTouching = false
                    if let motion = shell.motion, !motion.settling { shell.settle(card: motion.fromSwitcher ? 1 : 0) {} }
                    else if shell.motion == nil { shell.unlockPaging() }
                default: break
                }
            }
            .frame(width: Self.zone, height: Self.zone)

        }
        .allowsHitTesting(active)
        .onChange(of: active) { _, active in if !active { hold?.cancel(); hold = nil; haptics.end(); shell.cornerTouching = false } }
        .onChange(of: shell.motion == nil) { _, idle in if idle { dragging = false; hold?.cancel(); hold = nil; haptics.end() } }
        .onChange(of: selectedToolId) { _, _ in hold?.cancel(); hold = nil; dragging = false; haptics.end() }
        .onDisappear { hold?.cancel(); hold = nil; haptics.end(); shell.cornerTouching = false; shell.cancelMotion() }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        .task {
            await Page2ArcBench.run(.init(
                select: { selectedToolId = $0 },
                selected: { selectedToolId },
                touchDown: {
                    shell.cornerTouching = true
                    shell.lockPaging()
                },
                begin: { shell.beginMotion(selectedToolId, fromSwitcher: false) },
                progress: { track($0) },
                home: { shell.cornerTouching = false; goHome() },
                openLocal: { navigator?.pendingTarget = .init(tool: "ccTerminal", id: TerminalPanelRoot.newLocalTargetId) }
            ))
        }
        #endif
    }
    /// 拉动距离：对角线投影和往下拉的距离取大（她说的「往下拉」是竖着量）
    private func pull(_ delta: CGSize) -> CGFloat {
        max(0, (delta.width + delta.height) / CGFloat(2).squareRoot(), delta.height)
    }
    /// 0→170 缩成卡片；170→homeLine 飞向桌面图标（桌面起手没有这段）
    private func track(_ distance: CGFloat) {
        shell.motion?.cardProgress = min(distance / 170, 1)
        shell.motion?.homeProgress = onDesktop ? 0 : min(max(distance - 170, 0) / (homeLine - 170), 1)
    }
    private func goHome() {
        shell.settle(card: shell.motion?.cardProgress ?? 0, home: 1) {
            shell.showsSwitcher = false
            selectedToolId = "home"
        }
    }
}

private struct Page2ArcTouchSurface: UIViewRepresentable {
    @Environment(\.launchPageSignal) private var launchSignal
    @Environment(\.launchPage2Target) private var launchTarget
    let enabled: Bool
    var onSwitcher: () -> Void
    var onHome: () -> Void
    var onEvent: (UIGestureRecognizer.State, CGSize, CGSize) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let recognizer = Page2CornerTouchRecognizer()
        recognizer.onEvent = onEvent
        view.addGestureRecognizer(recognizer)
        configure(view)
        if launchTarget != "home" { launchSignal?.note("gestureReady") }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView.gestureRecognizers?.first as? Page2CornerTouchRecognizer)?.onEvent = onEvent
        configure(uiView)
        if launchTarget != "home" { launchSignal?.note("gestureReady") }
    }

    private func configure(_ view: UIView) {
        view.isHidden = !enabled
        view.isUserInteractionEnabled = enabled
        view.isAccessibilityElement = enabled
        view.accessibilityIdentifier = "page2.cornerGesture"
        view.accessibilityLabel = "应用切换手势"
        view.accessibilityTraits = .button
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "查看后台") { _ in onSwitcher(); return true },
            UIAccessibilityCustomAction(name: "回桌面") { _ in onHome(); return true }
        ]
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        guard let recognizer = uiView.gestureRecognizers?.first as? Page2CornerTouchRecognizer else { return }
        recognizer.isEnabled = false
        recognizer.onEvent = nil
    }
}

/// 拖弧线时的轻持续震动（⧫ 粟粟 10-11）：起拖开一段低强度连续震，越往里拉越强；
/// 跨「松手进后台」70pt、「松手回桌面」半屏那条线各敲一下，松手前就知道会落在哪。
@MainActor
private final class Page2ArcHaptics {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var band = 0
    private var target: Float = 0.4
    private var level: Float = -1
    private let bump = UIImpactFeedbackGenerator(style: .rigid)

    func prepare() {
        bump.prepare()
        guard engine == nil, CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let engine = try? CHHapticEngine() else { return }
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        // 媒体服务重置：player 全部作废；还在拖就重建
        engine.resetHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.player != nil else { return }
                self.player = nil
                self.begin()
            }
        }
        self.engine = engine
    }

    func begin() {
        prepare()
        level = -1
        guard let engine else { return }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            // 底子就是轻的：强度控制没发出去也不会满强度震
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)
        ], relativeTime: 0, duration: 30)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        self.player = player
        // 同步 start 会卡主线程几十毫秒，走回调；起来后补发当前强度
        engine.start { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor in
                guard let self, self.player === player else { return }
                try? player.start(atTime: CHHapticTimeImmediate)
                self.setLevel(self.target, force: true)
            }
        }
    }

    /// `home`：松手回桌面那条线；桌面起手为 nil（只有进后台一条线）
    func update(_ distance: CGFloat, home: CGFloat?) {
        let next = home.map { distance >= $0 } == true ? 2 : distance >= 70 ? 1 : 0
        if next != band {
            bump.impactOccurred(intensity: next > band ? 0.9 : 0.45)
            band = next
        }
        target = Float(0.4 + 0.6 * min(distance / (home ?? 170), 1))
        setLevel(target)
    }

    func end() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        band = 0
        target = 0.4
    }

    /// 强度 = 事件 0.5 × 控制值，实际 0.2→0.5；发成功才记账，没起来时发失败下次还会再发
    private func setLevel(_ value: Float, force: Bool = false) {
        guard force || abs(value - level) > 0.04, let player else { return }
        do {
            try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)],
                                      atTime: CHHapticTimeImmediate)
            level = value
        } catch {}
    }
}

private final class Page2CornerTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onEvent: ((State, CGSize, CGSize) -> Void)?
    private var trackedTouch: UITouch?
    private var origin = CGPoint.zero
    private var previous = CGPoint.zero
    private var previousTime: TimeInterval = 0
    private var translation = CGSize.zero
    private var velocity = CGSize.zero

    init() {
        super.init(target: nil, action: nil)
        delegate = self
        cancelsTouchesInView = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            state = .cancelled
            onEvent?(.cancelled, translation, translation)
            return
        }
        trackedTouch = touch
        origin = touch.location(in: view?.window)
        previous = origin
        previousTime = touch.timestamp
        state = .began
        onEvent?(.began, .zero, .zero)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        sample(touch)
        state = .changed
        onEvent?(.changed, translation, predicted)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        sample(touch)
        state = .ended
        onEvent?(.ended, translation, predicted)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
        onEvent?(.cancelled, translation, translation)
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        translation = .zero
        velocity = .zero
    }

    private func sample(_ touch: UITouch) {
        let point = touch.location(in: view?.window)
        let dt = touch.timestamp - previousTime
        if dt > 0 {
            velocity = CGSize(width: (point.x - previous.x) / dt, height: (point.y - previous.y) / dt)
        }
        translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        previous = point
        previousTime = touch.timestamp
    }

    private var predicted: CGSize {
        // Bounded projection is a tuning choice, not an Apple constant.
        CGSize(width: translation.width + min(max(velocity.width * 0.12, -100), 100),
               height: translation.height + min(max(velocity.height * 0.12, -100), 100))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard otherGestureRecognizer is UIPanGestureRecognizer,
              let ownView = view, let otherView = otherGestureRecognizer.view else { return false }
        return ownView.isDescendant(of: otherView)
    }
}

/// 同心的连续曲率圆角，只留左上角那段曲线正中的 `span`，描成圆头。线宽和长度都可动画。
/// 系统连续圆角的路径从右边中点起笔、顺时针走，左上角是紧挨着的三段曲线，没被起笔点切开；曲线左右对称，0.5 正好在对角线上。
private struct CornerArc: Shape {
    var lineWidth: CGFloat
    var span: CGFloat
    var displayRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(lineWidth, displayRadius) }
        set {
            lineWidth = newValue.first
            displayRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let inset = Page2CornerBar.edgeGap + lineWidth / 2
        let frame = rect.insetBy(dx: inset, dy: inset)
        let outline = RoundedRectangle(cornerRadius: max(1, displayRadius - inset), style: .continuous).path(in: frame)
        var corner = Path()
        var last = CGPoint.zero
        let inCorner = { (p: CGPoint) in p.x < frame.midX && p.y < frame.midY }
        outline.forEach { element in
            switch element {
            case .move(let to), .line(let to):
                last = to
            case .curve(let to, let c1, let c2):
                if inCorner(last), inCorner(to) {
                    if corner.isEmpty { corner.move(to: last) }
                    corner.addCurve(to: to, control1: c1, control2: c2)
                }
                last = to
            case .quadCurve(let to, let c):
                if inCorner(last), inCorner(to) {
                    if corner.isEmpty { corner.move(to: last) }
                    corner.addQuadCurve(to: to, control: c)
                }
                last = to
            case .closeSubpath:
                break
            }
        }
        // 小样定的是「正圆 90° 弧的中间 60%」，端点在 0.691r；连续圆角沿边拉得更长，
        // 截 32.2%–67.8%（span 0.356）时端点正好落在 0.691r（09-11 离线算的）
        return corner.trimmedPath(from: 0.5 - span / 2, to: 0.5 + span / 2)
            .strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}

/// 屏幕圆角半径（连续曲率，pt）。系统不公开这个数：UIKit `effectiveRadius` 和 SwiftUI `containerCornerInsets` 都给 0，
/// 所以按机型查表。表是 09-11 从 Xcode 模拟器机型的 framebufferMask 量出来的：沿对角线量凹进去的深度，再按连续圆角换算。
/// 表里没有的新机型：iPhone 按 55、iPad 按 19。
enum Page2DisplayCorner {
    static let radius: CGFloat = {
        if let value = table[modelIdentifier] { return value }
        return UIDevice.current.userInterfaceIdiom == .pad ? 19 : 55
    }()

    /// 内屏内容的固定设备轮廓；分屏/窗口化不套整屏半径。
    /// 用未变换的 bounds 判断，不让翻页位移、竖栏缩放或键盘改变圆度。
    static func radius(for view: UIView) -> CGFloat {
        guard let window = view.window,
              abs(view.bounds.width - window.bounds.width) < 1,
              abs(view.bounds.height - window.bounds.height) < 1 else { return 0 }
        let screen = window.screen.bounds.size
        let size = window.bounds.size
        guard abs(min(size.width, size.height) - min(screen.width, screen.height)) < 1,
              abs(max(size.width, size.height) - max(screen.width, screen.height)) < 1 else { return 0 }
        // Home 键 iPhone 是方角，不能套用未知 iPhone 的圆屏兜底值。
        if UIDevice.current.userInterfaceIdiom == .phone, window.safeAreaInsets.bottom == 0 { return 0 }
        return radius
    }

    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static let table: [String: CGFloat] = [
        "iPhone10,3": 40.2, "iPhone10,6": 40.2, "iPhone11,2": 40.2, "iPhone11,4": 39.1, "iPhone11,6": 39.1, "iPhone11,8": 41.4,
        "iPhone12,1": 41.4, "iPhone12,3": 40.2, "iPhone12,5": 39.1,
        "iPhone13,1": 42.5, "iPhone13,2": 48.3, "iPhone13,3": 48.3, "iPhone13,4": 54.0,
        "iPhone14,2": 48.3, "iPhone14,3": 54.0, "iPhone14,4": 42.5, "iPhone14,5": 48.3, "iPhone14,7": 48.3, "iPhone14,8": 54.0,
        "iPhone15,2": 55.2, "iPhone15,3": 55.2, "iPhone15,4": 55.2, "iPhone15,5": 55.2,
        "iPhone16,1": 55.2, "iPhone16,2": 55.2,
        "iPhone17,1": 63.2, "iPhone17,2": 63.2, "iPhone17,3": 55.2, "iPhone17,4": 55.2, "iPhone17,5": 48.3,
        "iPhone18,1": 63.2, "iPhone18,2": 63.2, "iPhone18,3": 63.2, "iPhone18,4": 65.5, "iPhone18,5": 48.3,
        "iPad8,1": 19.0, "iPad8,5": 19.0, "iPad8,9": 19.0, "iPad8,12": 19.0, "iPad13,5": 19.0, "iPad13,10": 19.0, "iPad13,17": 19.0,
        "iPad14,1": 22.4, "iPad14,3": 19.0, "iPad14,4": 19.0, "iPad14,5": 19.0, "iPad14,9": 19.0, "iPad14,11": 19.0,
        "iPad15,3": 19.0, "iPad15,5": 19.0, "iPad16,2": 22.4, "iPad16,4": 31.0, "iPad16,6": 31.0, "iPad16,9": 19.0, "iPad16,11": 19.0,
        "iPad17,2": 31.0, "iPad17,4": 31.0,
    ]
}
#endif
