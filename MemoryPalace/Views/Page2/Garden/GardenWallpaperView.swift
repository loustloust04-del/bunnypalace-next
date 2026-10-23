#if os(iOS)
import UIKit
import Observation
import os

/// 花园四季壁纸本体：底图（10 分钟一换，1.5s 淡入）+ 会动的细节（只有主屏那一个实例，#039）。
/// 翻页纪律（翻页性能1mac 10-08）：可见性只在这里用 withObservationTracking 读，不进 SwiftUI body；layoutSubviews 只摆 frame；
/// 停一律暂停（GardenMotion 停时钟）、不隐藏；动画层等第一次落定在第二页之后才建；手指拖动时冻住：任何滚动视图拖着时 runloop 在
/// tracking、时钟（`.default`）自然不走，外层翻页 pan 被动挂着管「松手后静 0.5s 再走」（翻页代码零改动）。
final class GardenWallpaperView: UIView {
    /// 主屏传 true：建会动的细节；别的实例（缩略图、切换器、编辑器预览、小芽卡片）只放静帧
    var animated = false {
        didSet { if animated != oldValue { scheduleFrame() } }
    }

    private let imageView = UIImageView()
    private var motion: GardenMotion?
    private var shownKey: GardenClock.FrameKey?
    private var pendingKey: GardenClock.FrameKey?
    private var ticket: GardenClock.Ticket?
    private var generation = 0
    private var frameScheduled = false
    private var laidOutSize: CGSize = .zero
    private var observing = false
    /// 第一次落定在第二页之前不建动画层：page2 延迟挂载，可能在第一次拖动时才出现，建层不能压在那次翻页上
    private var everActive = false
    private weak var pagingPan: UIPanGestureRecognizer?
    /// 最近一次翻页事件（isActive / 子应用盖住变化、手指按下 / 松开）：之后静 `settleDelay` 才算落定，才恢复 / 建层 / 换部件。
    /// 程序翻页（点 tab）不经过 pan、页码在动画开始时就写了，也靠这道门躲开翻页途中
    private var lastPagingEvent: CFTimeInterval = 0
    private static let settleDelay: CFTimeInterval = 0.5
    private var gateToken = 0
    private var lastActive: Bool?
    private var lastCovered: Bool?
    /// 停着时到货的部件：先存着，恢复时再换（不在暂停 / 翻页途中建层）
    private var stashed: (frame: GardenClock.Frame, key: GardenClock.FrameKey)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        addSubview(imageView)
        let nc = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            nc.addObserver(self, selector: #selector(environmentChanged), name: name, object: nil)
        }
    }
    required init?(coder: NSCoder) { nil }

    override var isHidden: Bool {
        didSet {
            updateRunning()
            if !isHidden { scheduleFrame() }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            observe()
            if pageVisible { DispatchQueue.main.async { [weak self] in self?.noteActive() } }
            scheduleFrame()
            updateRunning()
        } else {
            dropPending()
            stashed = nil
            motion?.pause()
            pagingPan?.removeTarget(self, action: #selector(pagingPanChanged(_:)))
            pagingPan = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = bounds
        CATransaction.commit()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            scheduleFrame()
        }
    }

    @objc private func environmentChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateRunning()
            self?.scheduleFrame()
        }
    }

    /// 读 isActive / 子应用盖住 / 时刻档，变化后重新挂观察。onChange 在写入前触发：挪到下一轮主线程、读最新值再决定（快速来回翻只认最后状态）
    private func observe() {
        guard !observing else { return }
        observing = true
        withObservationTracking {
            _ = Page2SceneState.shared.isActive
            _ = Page2SceneState.shared.hidesStatusBarForApp
            _ = Page2SceneState.shared.stripOpen
            _ = Page2SceneState.shared.stripTransitioning
            _ = GardenClock.shared.frameBucket
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.observing = false
                guard self.window != nil else { return }
                self.observe()
                let active = self.pageVisible
                let covered = Page2SceneState.shared.hidesStatusBarForApp || Page2SceneState.shared.stripOpen || Page2SceneState.shared.stripTransitioning
                if active != self.lastActive || covered != self.lastCovered { self.notePagingEvent() }
                self.lastActive = active
                self.lastCovered = covered
                if active { self.noteActive() }
                self.updateRunning()
                self.scheduleFrame()
            }
        }
    }

    private func noteActive() {
        guard !everActive, pageVisible, window != nil else { return }
        everActive = true
        scheduleFrame()
    }

    private var pageVisible: Bool { Page2SceneState.shared.isActive }
    private var inForeground: Bool { UIApplication.shared.applicationState != .background }
    /// 减弱动态 / 过热只放静帧；低电量照样动（慢动档：帧率 20、飘落减半，粟粟 10-08 拍板）
    private var motionAllowed: Bool {
        !UIAccessibility.isReduceMotionEnabled && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }
    private var wantsParts: Bool { animated && everActive && motionAllowed }
    private var dragging: Bool {
        if tracking { return true }
        guard let state = pagingPan?.state else { return false }
        return state == .began || state == .changed
    }
    /// 有滚动视图被手指拖着（外层翻页之外还有第二页桌面分页、页内滚动，花园不挂它们的手势）
    private var tracking: Bool { RunLoop.main.currentMode == .tracking }
    private var trackingRecheckArmed = false
    private var settled: Bool { CACurrentMediaTime() - lastPagingEvent >= Self.settleDelay }
    /// 除了「落定后静够」以外都满足：用来判断要不要排一次落定后的复查
    private var runnableIgnoringSettle: Bool {
        window != nil && !isHidden && pageVisible && inForeground && motionAllowed
            && !Page2SceneState.shared.hidesStatusBarForApp && !Page2SceneState.shared.stripOpen
            && !Page2SceneState.shared.stripTransitioning && !dragging
    }
    private var shouldRun: Bool { runnableIgnoringSettle && settled }

    private func notePagingEvent() { lastPagingEvent = CACurrentMediaTime() }

    /// tracking 期间只停、到货只存；runloop 回到 default（松手）算一次翻页事件，再走落定门禁
    private func armTrackingRecheck() {
        guard tracking, !trackingRecheckArmed else { return }
        trackingRecheckArmed = true
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trackingRecheckArmed = false
                self.notePagingEvent()
                self.updateRunning()
            }
        }
    }

    private var stopReason: String {
        [(window == nil, "离窗"), (isHidden, "隐藏"), (!pageVisible, "不在第二页"), (!inForeground, "后台"), (!motionAllowed, "减弱动态/过热"),
         (Page2SceneState.shared.hidesStatusBarForApp, "子应用盖住"), (tracking, "滚动视图拖动"), (dragging && !tracking, "翻页拖动"), (!settled, "等落定")]
            .filter(\.0).map(\.1).joined(separator: "+")
    }

    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG || PERF_BENCH
        let m = message()
        GardenMotion.log.info("\(m, privacy: .public)")
        #endif
    }

    /// 所有「该不该动」都走这里：该动就补挂动画、恢复、换上存着的部件、补一次脏帧检查；不该动就标准暂停
    /// （不隐藏：暂停的层不产生脏区，被拖进来时也是完整的一帧）。只差「静够」就排一次复查，过期的复查作废
    private func updateRunning() {
        gateToken += 1
        if runnableIgnoringSettle && !settled {
            let token = gateToken
            let wait = Self.settleDelay - (CACurrentMediaTime() - lastPagingEvent) + 0.02
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, token == self.gateToken else { return }
                self.updateRunning()
            }
        }
        if window != nil, motion != nil || stashed != nil { attachPagingPan() }
        guard shouldRun else {
            armTrackingRecheck()
            if motion?.isPaused == false { trace("停：\(stopReason)") }
            motion?.pause()
            return
        }
        if let stashed {
            self.stashed = nil
            show(stashed.frame, key: stashed.key)
            return
        }
        guard let motion else {
            scheduleFrame()
            return
        }
        motion.ensureAnimations()
        motion.resume()
        scheduleFrame()
    }

    /// 楼层切换后分页壳可能重建：每次都核一下挂的是不是当前那个 pan
    private func attachPagingPan() {
        guard let pan = PagingViewController.sharedScrollView?.panGestureRecognizer, pan !== pagingPan else { return }
        pagingPan?.removeTarget(self, action: #selector(pagingPanChanged(_:)))
        pan.addTarget(self, action: #selector(pagingPanChanged(_:)))
        pagingPan = pan
    }

    @objc private func pagingPanChanged(_ pan: UIPanGestureRecognizer) {
        // .changed 不算翻页事件：只在按下 / 松开时重新计时，免得拖动途中堆出一串定时器
        switch pan.state {
        case .began, .ended, .cancelled, .failed:
            trace("翻页 pan state=\(pan.state.rawValue) running=\(motion.map { !$0.isPaused } ?? false)")
            notePagingEvent()
            updateRunning()
        default:
            break
        }
    }

    /// 合并到下一轮主线程：同一轮里尺寸 / 时刻档 / 可见性多次变化只看一次
    private func scheduleFrame() {
        guard !frameScheduled else { return }
        frameScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameScheduled = false
            self.requestFrame()
        }
    }

    private func dropPending() {
        if let ticket { GardenClock.shared.cancel(ticket) }
        ticket = nil
        pendingKey = nil
        generation += 1
    }

    private func requestFrame() {
        guard let window, !isHidden, inForeground, bounds.width > 1, bounds.height > 1 else { return }
        let clock = GardenClock.shared
        let key = clock.key(size: bounds.size, scale: min(window.screen.scale, 2), parts: wantsParts)
        if key == shownKey || key == pendingKey || key == stashed?.key { return }
        // 动画版部件只在该动时要：停着时只当「脏」，恢复时 updateRunning 会再进来
        if key.parts && !shouldRun { return }
        // 同尺寸同种类的换档只给看得见、在动的那份出；停着时只当「脏」，恢复时再进来
        if let shownKey, shownKey.pixelWidth == key.pixelWidth, shownKey.pixelHeight == key.pixelHeight, shownKey.scale == key.scale,
           shownKey.parts == key.parts, !(motion == nil ? pageVisible : shouldRun) { return }
        dropPending()
        let gen = generation
        pendingKey = key
        ticket = clock.frame(key) { [weak self] frame in
            guard let self, gen == self.generation else { return }
            self.ticket = nil
            self.pendingKey = nil
            guard let frame, self.window != nil else { return }
            if case .parts = frame, !self.shouldRun {
                self.armTrackingRecheck()
                self.stashed = (frame, key)
                return
            }
            self.show(frame, key: key)
        }
    }

    /// 换上新的一帧。静帧 → 动画版（同一时刻档）不淡入：动画层刚挂上的样子就是静帧；换档才 1.5s 淡入
    private func show(_ frame: GardenClock.Frame, key: GardenClock.FrameKey) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let shownKey, shownKey.bucket != key.bucket, !UIAccessibility.isReduceMotionEnabled {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 1.5
            layer.add(fade, forKey: "garden.fade")
        }
        imageView.image = frame.base
        motion?.root.removeFromSuperlayer()
        motion = nil
        if case .parts(let parts, _) = frame {
            let m = GardenMotion(parts: parts, lowPower: key.lowPower)
            m.root.frame = bounds
            layer.addSublayer(m.root)
            motion = m
            if !shouldRun { m.pause() }
        }
        CATransaction.commit()
        shownKey = key
        if stashed?.key.parts == true, !key.parts { stashed = nil }
        if let motion { shouldRun ? motion.resume() : motion.pause() }
    }
}
#endif
