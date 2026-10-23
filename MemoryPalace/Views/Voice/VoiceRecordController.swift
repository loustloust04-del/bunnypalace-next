#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation

/// 录语音的逐帧数据（plan-voice-note M5c）：**不被 SwiftUI 观察**。手势回调 / 录音器 display link 写，
/// 浮层与输入条行内的 `TimelineView(.animation)` 自己读——每帧变化不拖着输入条 body 重算（playbook-perf）。
/// 坐标都在输入条栈的 `chatInputBar` 空间（原点 = 可见栈顶）。时间 = `Date.timeIntervalSinceReferenceDate`。
final class VoiceRecordLive {
    /// 输入框玻璃框的 frame（InputFieldContainer 自报）：发送键 / + 号 / 行内红点的位置都由它推
    var fieldBoxFrame: CGRect = .zero
    /// 浮层自己的原点（换算成浮层本地坐标用）
    var overlayOrigin: CGPoint = .zero

    /// 拖动位移（只留左 / 上，录音中才写）
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    /// 录音器最新电平 0…1
    var rawLevel: Double = 0

    var recordStart: TimeInterval = 0
    var shownAt: TimeInterval = 0
    var hiddenAt: TimeInterval?
    var lockedAt: TimeInterval?
    /// 正在录（录音中 / 锁定）：浮层电平跟着走；false 后电平衰减
    var capturing = false

    /// 取消点点花：起点（红点 / 删除键）、终点（+ 号），开始时刻
    var bloomAt: TimeInterval?
    var bloomFrom: CGPoint = .zero
    var bloomTo: CGPoint = .zero

    /// 浮层逐帧状态（VoiceRecordOverlay 自己推进）
    var frame = VoiceBlobState()

    // 输入条里几个点的位置（chatInputBar 空间），布局同 InputFieldContainer.fieldBox：
    // 发送键 44 宽 + 右 4、底对齐；+ 号 32 + 左 6 + 底 6；行内容从左 38 开始，红点左 6 宽 10
    var sendCenter: CGPoint { CGPoint(x: fieldBoxFrame.maxX - 26, y: fieldBoxFrame.maxY - 22) }
    var plusCenter: CGPoint { CGPoint(x: fieldBoxFrame.minX + 22, y: fieldBoxFrame.maxY - 22) }
    var dotCenter: CGPoint { CGPoint(x: fieldBoxFrame.minX + 49, y: fieldBoxFrame.maxY - 22) }
    var trashCenter: CGPoint { CGPoint(x: fieldBoxFrame.minX + 55, y: fieldBoxFrame.maxY - 22) }

    /// 锁定后上方点得到的区域（锁 + 大按钮，chatInputBar 空间）：锁中心在发送键上方 122，大按钮直径 110
    var lockedHitRect: CGRect {
        let c = sendCenter
        let top = c.y - VoiceRecordOverlay.lockLift - 24
        return CGRect(x: c.x - 55, y: top, width: 110, height: c.y + 55 - top)
    }

    func reset(now: TimeInterval) {
        dx = 0; dy = 0; rawLevel = 0
        recordStart = now; shownAt = now
        hiddenAt = nil; lockedAt = nil
        capturing = true
        frame = VoiceBlobState()
    }
}

/// 按住 waveform 录语音的状态机（plan-voice-note M5）：手势事件 → `VoiceRecordGesture.decide` → 录音器 / 动画 / 发送。
/// 被观察的只有几次状态切换（phase / 浮层挂没挂 / + 号缩没缩 / 交货号），每帧数据在 `live`。
/// iOS 只有一条聊天输入条，单例；录完交给 ChatInputBar（`deliveryToken` 变 → `takeDelivery()` → `sendVoiceNote`）。
@MainActor
@Observable
final class VoiceRecordController {
    static let shared = VoiceRecordController()

    enum Phase: Equatable { case idle, recording, locked, preview }

    struct Delivery {
        let url: URL
        let duration: Double
        var analysisBucket: String? = nil
        let conversationId: String
    }

    private(set) var phase: Phase = .idle
    /// 浮层挂着：录音中 + 退场 / 取消花的尾巴（TimelineView 只在这时跑）
    private(set) var overlayMounted = false
    /// 取消花绽放时 + 号缩没，1000ms 弹回（小样 cancelBloom）
    private(set) var plusHidden = false
    /// 预览态的录音（删除 / 回放 / 发送）
    private(set) var preview: VoiceNoteRecorder.Recording?
    private(set) var deliveryToken = 0
    /// 太短：waveform 键抖一下（小样 .shake）
    private(set) var shakeToken = 0
    /// 锁定后几何变了（转屏 / 分屏 / 输入条变高）：透明按钮跟着挪（低频，sol P2-6）
    private(set) var layoutRevision = 0

    let live = VoiceRecordLive()
    /// 当前对话（ChatInputBar 写）；开录时记下，录完交给那个对话
    @ObservationIgnored var conversationId: String?
    /// 正在编辑旧消息：不能录（sol P1-3，ChatInputBar 写）
    @ObservationIgnored var isEditing = false

    @ObservationIgnored private var pendingDelivery: Delivery?
    @ObservationIgnored private var recorderStorage: VoiceNoteRecorder?
    @ObservationIgnored private var recordingConvId: String?
    @ObservationIgnored private var touchActive = false
    /// 这次触摸不再处理（防连点 / 正在转写 / 弹了权限框 / 已取消或锁定）
    @ObservationIgnored private var touchSpent = false
    @ObservationIgnored private var armWork: DispatchWorkItem?
    @ObservationIgnored private var lastTouchEnd: TimeInterval = -.infinity
    @ObservationIgnored private let pagingOwner = UUID()
    @ObservationIgnored private weak var pagingLockedScroll: UIScrollView?
    /// 浮层卸载排期的代号：新一轮开录后，上一轮的卸载不生效
    @ObservationIgnored private var generation = 0

    private init() {}

    private var recorder: VoiceNoteRecorder {
        if let r = recorderStorage { return r }
        let r = VoiceNoteRecorder()
        recorderStorage = r
        return r
    }

    private static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    func takeDelivery() -> Delivery? {
        defer { pendingDelivery = nil }
        return pendingDelivery
    }

    // MARK: - 手势入口（VoiceHoldGesture）

    func touchChanged(translation: CGSize) {
        if !touchActive { touchBegan() }
        guard !touchSpent else { return }
        let recording = phase == .recording
        if recording {
            live.dx = min(0, translation.width)
            live.dy = min(0, translation.height)
        }
        switch VoiceRecordGesture.decide(.move(dx: translation.width, dy: translation.height, recording: recording)) {
        case .cancel: cancel(fromTrash: false)
        case .lock: lock()
        default: break
        }
    }

    func touchEnded(translation: CGSize, velocity: CGSize) {
        guard touchActive else { return }
        touchActive = false
        lastTouchEnd = Self.now
        let spent = touchSpent
        touchSpent = false
        if let work = armWork {
            work.cancel()
            armWork = nil
            if !spent, phase == .idle {
                ToastCenter.shared.show("按住说话")
            }
        }
        guard !spent, phase == .recording else {
            if phase == .idle { releasePaging() }
            return
        }
        let outcome = VoiceRecordGesture.decide(.up(dx: translation.width, dy: translation.height,
                                                    vx: velocity.width, vy: velocity.height,
                                                    recordedDuration: recorder.currentTime))
        switch outcome {
        case .cancel: cancel(fromTrash: false)
        case .lock: lock()
        case .send, .tooShort: sendCaptured()
        default: break
        }
    }

    /// 手势被系统收走（来电、权限框、滚动抢走）没走 onEnded：没锁定的录音直接取消
    func touchReset() {
        guard touchActive else { return }
        touchActive = false
        touchSpent = false
        lastTouchEnd = Self.now
        armWork?.cancel()
        armWork = nil
        if phase == .recording { cancel(fromTrash: false) } else if phase == .idle { releasePaging() }
    }

    private func touchBegan() {
        touchActive = true
        touchSpent = false
        guard phase == .idle else { touchSpent = true; return }
        guard VoiceRecordGesture.decide(.down(sinceLastTouchEnd: Self.now - lastTouchEnd)) == .arm else {
            touchSpent = true
            return
        }
        if let reason = blockedReason {
            touchSpent = true
            ToastCenter.shared.show(reason)
            return
        }
        lockPaging()   // 按下第一帧就锁翻页：左滑取消和翻页同方向
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.touchActive else { return }
                self.armWork = nil
                if !self.beginRecording() { self.touchSpent = true; self.releasePaging() }
            }
        }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceRecordGesture.holdToRecord, execute: work)
    }

    /// 不能开录的原因：上一条还在转写（一次只转一条，sol P1-2）/ 正在编辑旧消息（录音只发新消息，sol P1-3）
    private var blockedReason: String? {
        if VoiceNoteTranscribing.shared.isBusy { return "上一条语音还在转文字" }
        if isEditing { return "编辑中不能录语音" }
        return nil
    }

    // MARK: - 几何 / 离页

    /// 输入框框 / 浮层原点变了（低频）：锁定态同步刷新命中框和透明按钮（sol P2-6）；逐帧值照旧不被观察
    func geometryChanged(fieldBox: CGRect? = nil, overlayOrigin: CGPoint? = nil) {
        if let fieldBox { live.fieldBoxFrame = fieldBox }
        if let overlayOrigin { live.overlayOrigin = overlayOrigin }
        guard phase == .locked else { return }
        KeyboardInsetBridge.shared.recordingHitRect = live.lockedHitRect
        layoutRevision &+= 1
    }

    /// 聊天页不再是当前页（拖动翻页 / 顶部箭头 / tab 等任何途径，PagingViewController 报）：
    /// 录音中 / 锁定 / 预览一律丢弃并清临时文件（sol P1-1，不只靠 onDisappear——页隐藏不撤输入条）
    func chatPageLeft() {
        discard()
    }

    // MARK: - 状态切换

    /// 麦克风权限 + 开录。没开成返回 false（这次按压作废）
    private func beginRecording() -> Bool {
        guard phase == .idle, let convId = conversationId else { return false }
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            Task { @MainActor in
                let granted = await AVAudioApplication.requestRecordPermission()
                ToastCenter.shared.show(granted ? "再按住说话" : "麦克风没开——设置里打开")
            }
            return false
        case .denied:
            ToastCenter.shared.show("麦克风没开——设置里打开")
            return false
        default:
            break
        }
        let r = recorder
        guard r.start() == .started else {
            ToastCenter.shared.show("录音没开起来")
            return false
        }
        r.onTick = { [weak self, weak r] in
            guard let self, let r else { return }
            self.live.rawLevel = r.level
        }
        r.onLimitReached = { [weak self] in self?.stopToPreview() }
        r.onInterrupted = { [weak self] in
            guard let self else { return }
            if self.phase == .locked { self.stopToPreview() } else if self.phase == .recording { self.cancel(fromTrash: false) }
        }
        recordingConvId = convId
        generation += 1
        live.reset(now: Self.now)
        phase = .recording
        overlayMounted = true
        plusHidden = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    private func lock() {
        guard phase == .recording else { return }
        touchSpent = true
        live.dx = 0
        live.dy = 0
        live.lockedAt = Self.now
        phase = .locked
        KeyboardInsetBridge.shared.recordingHitRect = live.lockedHitRect
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // 锁定瞬间收键盘（车头裁定：按住期间不收，免得输入条跟着键盘走）
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// 锁里的 ■ / 10 分钟到点 / 锁定后被打断 → 预览
    func stopToPreview() {
        guard phase == .locked || phase == .recording else { return }
        touchSpent = true
        guard let rec = recorder.stop() else { finishIdle(hideOverlay: true); return }
        live.capturing = false
        live.hiddenAt = Self.now
        KeyboardInsetBridge.shared.recordingHitRect = nil
        preview = rec
        phase = .preview
        releasePaging()   // 录音结束就放开翻页（sol P2-5）；离页由 chatPageLeft 丢弃预览
        scheduleUnmount(after: 0.25)
    }

    /// 锁定后点大按钮
    func sendLocked() {
        guard phase == .locked else { return }
        sendCaptured()
    }

    /// 预览里点发送
    func sendPreview() {
        guard phase == .preview, let rec = preview else { return }
        VoiceMessagePlayer.shared.stop(id: rec.url.path)
        preview = nil
        deliver(rec)
    }

    private func sendCaptured() {
        guard let rec = recorder.stop() else { finishIdle(hideOverlay: true); return }
        deliver(rec)
    }

    private func deliver(_ rec: VoiceNoteRecorder.Recording) {
        guard rec.duration >= VoiceRecordGesture.minDuration, let convId = recordingConvId else {
            try? FileManager.default.removeItem(at: rec.url)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            ToastCenter.shared.show("太短了，按住说话")
            shakeToken &+= 1
            finishIdle(hideOverlay: true)
            return
        }
        pendingDelivery = Delivery(url: rec.url, duration: rec.duration, analysisBucket: rec.analysisBucket, conversationId: convId)
        deliveryToken &+= 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        finishIdle(hideOverlay: true)
    }

    /// 左滑 / 「取消」/ 预览里删除：红点飞回 + 号绽成四叶点点花（小样 cancelBloom）
    func cancel(fromTrash: Bool) {
        guard phase != .idle else { return }
        touchSpent = true
        if phase == .preview, let rec = preview {
            VoiceMessagePlayer.shared.stop(id: rec.url.path)
            try? FileManager.default.removeItem(at: rec.url)
        } else {
            recorder.cancel()
        }
        preview = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let now = Self.now
        live.bloomAt = now
        live.bloomFrom = fromTrash || phase == .preview ? live.trashCenter : live.dotCenter
        live.bloomTo = live.plusCenter
        if live.hiddenAt == nil { live.hiddenAt = now }
        live.capturing = false
        overlayMounted = true
        plusHidden = true
        generation += 1   // 之前排的「退场后卸载」作废：花还没开完
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceRecordOverlay.bloomRegrow) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { self.plusHidden = false }
            }
        }
        finishIdle(hideOverlay: false)
        scheduleUnmount(after: VoiceRecordOverlay.bloomTotal)
    }

    /// 切对话 / 退后台 / 输入条离场：不动画，全部丢掉
    func discard() {
        guard phase != .idle || overlayMounted || touchActive else { return }
        armWork?.cancel()
        armWork = nil
        touchActive = false
        touchSpent = false
        if let rec = preview {
            VoiceMessagePlayer.shared.stop(id: rec.url.path)
            try? FileManager.default.removeItem(at: rec.url)
        }
        preview = nil
        recorder.cancel()
        live.capturing = false
        live.bloomAt = nil
        generation += 1
        overlayMounted = false
        plusHidden = false
        finishIdle(hideOverlay: false)
    }

    func conversationChanged(to id: String?) {
        if id != conversationId, phase != .idle || touchActive { discard() }
        conversationId = id
    }

    /// VoiceOver（拖不了）：「开始录音」直接进锁定态，再触发一次进预览
    func accessibilityToggle() {
        switch phase {
        case .idle:
            if let reason = blockedReason { ToastCenter.shared.show(reason); return }
            lockPaging()
            if beginRecording() { lock() } else { releasePaging() }
        case .recording, .locked:
            stopToPreview()
        case .preview:
            break
        }
    }

    private func finishIdle(hideOverlay: Bool) {
        let now = Self.now
        live.capturing = false
        if hideOverlay {
            if live.hiddenAt == nil { live.hiddenAt = now }
            scheduleUnmount(after: 0.25)
        }
        KeyboardInsetBridge.shared.recordingHitRect = nil
        phase = .idle
        recordingConvId = nil
        releasePaging()
    }

    private func scheduleUnmount(after delay: TimeInterval) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, self.phase == .idle || self.phase == .preview else { return }
                self.live.bloomAt = nil
                self.overlayMounted = false
            }
        }
    }

    // MARK: - 翻页锁（plan 第二节 4）

    private func lockPaging() {
        guard pagingLockedScroll == nil, let scroll = PagingViewController.sharedScrollView else { return }
        if PagingViewController.setPage2DragLocked(true, owner: pagingOwner, scrollView: scroll) {
            pagingLockedScroll = scroll
        }
    }

    private func releasePaging() {
        guard let scroll = pagingLockedScroll else { return }
        _ = PagingViewController.setPage2DragLocked(false, owner: pagingOwner, scrollView: scroll)
        pagingLockedScroll = nil
    }
}
#endif
