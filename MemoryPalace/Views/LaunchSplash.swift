import SwiftUI

/// closure 延迟到 CA 提交之后才求值：通知晚于 SwiftUI 建 root、或 flush 重入时也不先建三页。
@MainActor
struct LaunchSplashRoot<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(iOS)
        if LaunchSplash.contentGate.isOpen {
            content()
        } else {
            Color(red: 0.929, green: 0.914, blue: 0.875).ignoresSafeArea()
                .onAppear { LaunchSplash.prepareForPageConstruction() }
        }
        #else
        content()
        #endif
    }
}

#if os(iOS)
import UIKit
import AVFoundation

@MainActor @Observable
final class LaunchContentGate {
    var isOpen = false
}

/// 单次冷启动罩；DFL 锚定软截止，CA 提交时刻锚定动画；触摸/AX 透传，热恢复不重播。
@MainActor
enum LaunchSplash {
    enum Timing {
        static let animScale: TimeInterval = 0.6
        // 保留测量台读取的 minimum / lift 名称：现在是动画的前段 / 退场段。
        static let minimum: TimeInterval = 1.78 * animScale
        static let lift: TimeInterval = (2.18 - 1.78) * animScale
        static let deadline: TimeInterval = 1.2
    }
    enum Phase: String { case waiting, lifting, finished }
    static private(set) var phase: Phase = .finished
    static private(set) var pushLaunch = false
    static private(set) var finishReason = "notInstalled"
    static private(set) var usesBakedArtwork = false
    static private(set) var reduceMotion = false
    static let animationRevision = "pinTulipCA-v1"
    static let requestedPolicy = ProcessInfo.processInfo.environment["MP_LAUNCH_PREWARM"] ?? "eager"
    private static var installed = false
    private static var start: CFTimeInterval = 0
    private static var animationStart: CFTimeInterval = 0
    private static var earliestExit: CFTimeInterval = 0
    private static var scheduledExit: CFTimeInterval = 0
    private static var scheduledReason = "animation"
    private static var run = UUID()
    private static var window: UIWindow?
    private static var animationView: LaunchSplashAnimationView?
    private static var artwork: LaunchSplashAnimationView.Artwork?
    static let contentGate = LaunchContentGate()
    private static let artworkPreparation = LaunchArtworkPreparation()
    private nonisolated static let sound = LaunchSplashSound()
    private static var preloaded = false
    private static var artworkReady = false
    private static var sceneConnectedAt: CFTimeInterval = 0
    private static var presenting = false
    private static weak var scene: UIWindowScene?
    private static weak var readiness: LaunchReadiness?
    private static weak var latestRegistration: LaunchReadiness?
    private static var connectionObserver: NSObjectProtocol?
    private static var observers: [NSObjectProtocol] = []
    private static var exitWork: DispatchWorkItem?
    private static var completionWork: DispatchWorkItem?
    private static var sceneDeadlineWork: DispatchWorkItem?

    static var hasCover: Bool { window != nil && phase == .waiting && CACurrentMediaTime() < scheduledExit }
    static var isFinished: Bool { phase == .finished }
    static var policyEligible: Bool {
        installed && phase == .waiting && !pushLaunch && !isDisabled
            && (window == nil || CACurrentMediaTime() < scheduledExit)
    }

    static func preload() {
        guard !preloaded else { return }
        preloaded = true
        guard !isDisabled else { LaunchMarks.mark("splashRelease"); contentGate.isOpen = true; return }
        artworkPreparation.start()
    }

    static func artworkDidPrepare() {
        consumePreparedArtwork()
        if phase == .waiting, let scene { show(in: scene) }
    }

    private static func consumePreparedArtwork() {
        guard !artworkReady, let result = artworkPreparation.takeResult() else { return }
        artworkReady = true
        artwork = result.artwork
        #if DEBUG || PERF_BENCH
        LaunchTrace.recordBackgroundSpan("splash.artworkLoad", began: result.began, ended: result.ended,
            fields: ["success": result.artwork != nil, "imageCount": result.artwork?.images.count ?? 0,
                     "decodedBytes": result.artwork?.images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height } ?? 0])
        #endif
    }

    private static func releaseContent() {
        // 避免 show 从 SwiftUI onAppear / layout 重入时在同一更新栈发布状态。
        DispatchQueue.main.async { LaunchMarks.mark("splashRelease"); contentGate.isOpen = true }
    }

    static func install(fromPush: Bool) {
        guard !installed else { return }
        installed = true
        preload()
        start = CACurrentMediaTime()
        pushLaunch = pushLaunch || fromPush
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.event("didFinishLaunching", fields: ["push": fromPush])
        #endif
        // 即便禁用开屏，scene 锚仍来自同一个生命周期通知。
        connectionObserver = NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard let connected = note.object as? UIWindowScene, scene == nil else { return }
                scene = connected
                sceneConnectedAt = CACurrentMediaTime()
                if let observer = connectionObserver { NotificationCenter.default.removeObserver(observer) }
                connectionObserver = nil
                #if (DEBUG || PERF_BENCH) && os(iOS)
                LaunchTrace.event("sceneConnected", at: sceneConnectedAt, fields: ["scene": connected.session.persistentIdentifier, "source": "willConnectNotification"])
                #endif
                // 在 scene 连接通知内同步建 layer / 加完整动画 / flush，不 dispatch 到下一轮。
                if phase == .waiting { show(in: connected) }
            }
        }
        if pushLaunch || isDisabled {
            finishReason = pushLaunch ? "push" : "disabled"
            consumePreparedArtwork()
            artwork = nil; artworkPreparation.cancel()
            releaseContent()
            trace("splashSkipped", reason: finishReason)
            return
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { requestFinish(reason: "background", immediately: true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let disconnected = note.object as? UIWindowScene, disconnected === scene {
                    requestFinish(reason: "sceneDisconnected", immediately: true)
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if UIAccessibility.isReduceMotionEnabled { sound.stop() }
            }
        })
        phase = .waiting
        finishReason = "waiting"
        if !UIAccessibility.isReduceMotionEnabled, ProcessInfo.processInfo.environment["MP_SPLASH_SOUND"] != "0" {
            sound.preload()
        }
        // 没有可显示的 scene 也要收口；此 work 不参与视觉帧驱动。
        let ticket = run
        let deadline = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard ticket == run, animationView == nil else { return }
                requestFinish(reason: window == nil ? "noScene" : "artworkTimeout", immediately: true)
            }
        }
        sceneDeadlineWork = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, start + Timing.deadline - CACurrentMediaTime()), execute: deadline)
    }

    /// makeUIViewController 的第一步，早于 PagingViewController 初始化和所有 HC/root 赋值。
    static func prepareForPageConstruction() {
        guard phase == .waiting, animationView == nil, !pushLaunch else { return }
        if let scene { show(in: scene); return }
        let candidates = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if candidates.count == 1, let candidate = candidates.first {
            scene = candidate
            sceneConnectedAt = CACurrentMediaTime()
            if let observer = connectionObserver { NotificationCenter.default.removeObserver(observer) }
            connectionObserver = nil
            #if (DEBUG || PERF_BENCH) && os(iOS)
            LaunchTrace.event("sceneConnected", at: sceneConnectedAt, fields: ["scene": candidate.session.persistentIdentifier, "source": "rootGate"])
            #endif
            show(in: candidate)
        } else {
            // 不把罩挂到别的 scene；此分支需要主 session 用 trace 核实宿主连接顺序。
            trace("splashAwaitingScene", reason: "noUniqueScene")
        }
    }

    /// 通知响应走这里；晚到的响应也立即撤罩，不等动画。
    nonisolated static func silenceForNotification() {
        // UN delegate 收到 response 即可取消硬件排程，不必等正在建页的 main actor。
        sound.stop()
    }

    static func notificationLaunch() {
        pushLaunch = true
        latestRegistration?.forceEager(reason: "push")
        requestFinish(reason: "push", immediately: true)
    }

    private static var isDisabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["MP_SPLASH"] == "0" { return true }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.anyRole && env["MP_PERF_SPLASH"] != "1" { return true }
        #endif
        return false
    }

    static func register(_ state: LaunchReadiness) {
        latestRegistration = state
        readiness = nil
        evaluate()
    }

    static func bind(_ state: LaunchReadiness, in candidate: UIWindowScene) {
        guard candidate === scene, state.valid, latestRegistration === state else { return }
        readiness = state
        evaluate()
    }

    static func changed(_ state: LaunchReadiness) {
        guard readiness === state || latestRegistration === state else { return }
        evaluate()
    }

    private static func evaluate() {
        guard phase == .waiting, let view = animationView else { return }
        let now = CACurrentMediaTime()
        // CA 可能已在主线程阻塞期间开始退场；不能再把已透明的罩重新盖回来。
        if now >= scheduledExit { requestFinish(reason: scheduledReason); return }
        var readyReason: String?
        if view.shortPresentation { readyReason = view.usesBakedArtwork ? "reduceMotion" : "missingArtwork" }
        else if requestedPolicy != "covered" { readyReason = "animation" }
        else if let latestRegistration {
            if !latestRegistration.valid { readyReason = "invalidated" }
            else if !latestRegistration.required { readyReason = "notApplicable" }
            else if latestRegistration.effectivePolicy == "eager" { readyReason = "eagerFallback" }
            else if readiness === latestRegistration, latestRegistration.allPrepared { readyReason = "ready" }
        }
        let target = readyReason == nil ? max(earliestExit, start + Timing.deadline) : max(earliestExit, now)
        let reason = readyReason ?? "deadline"
        guard abs(target - scheduledExit) > 0.0001 else { scheduledReason = reason; return }
        scheduledExit = target; scheduledReason = reason
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.scheduleExit(at: target)
        CATransaction.commit(); CATransaction.flush()
        trace("splashExitRescheduled", reason: reason)
        scheduleLifecycleCallbacks()
    }

    private static func show(in scene: UIWindowScene) {
        guard phase == .waiting, !pushLaunch, animationView == nil, !presenting else { return }
        #if DEBUG || PERF_BENCH
        let showSpan = LaunchTrace.begin("splash.show")
        defer { LaunchTrace.end("splash.show", showSpan) }
        #endif
        presenting = true
        defer { presenting = false }
        consumePreparedArtwork() // 锁只取已完成结果；绝不等解码，更不在 main 补解码。
        let w: UIWindow
        if let window { w = window }
        else {
            w = UIWindow(windowScene: scene)
            w.frame = scene.coordinateSpace.bounds
            w.windowLevel = .alert + 1
            w.isUserInteractionEnabled = false
            w.accessibilityElementsHidden = true
            let root = UIViewController()
            root.view = UIView(frame: w.bounds)
            root.view.backgroundColor = UIColor(red: 0.929, green: 0.914, blue: 0.875, alpha: 1)
            w.rootViewController = root
            window = w
        }
        guard artworkReady else {
            // 冷缓存仍在解码：先交纸底窗口，真实页面保持未构造；完成回调从 t=0 提交整段。
            CATransaction.begin(); CATransaction.setDisableActions(true)
            w.isHidden = false
            CATransaction.commit(); CATransaction.flush()
            trace("splashWindowCommitted", reason: "awaitingArtwork")
            return
        }
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        let view = LaunchSplashAnimationView(frame: w.bounds, artwork: artwork, reducedMotion: reduceMotion)
        usesBakedArtwork = view.usesBakedArtwork
        w.rootViewController?.view = view
        animationView = view
        sceneDeadlineWork?.cancel(); sceneDeadlineWork = nil
        // 固定所有布局后再取媒体时钟，解析/贴图查找不会吞掉动画的第一段。
        CATransaction.begin(); CATransaction.setDisableActions(true)
        w.isHidden = false // 不 makeKey，焦点留给主窗口。
        w.layoutIfNeeded(); view.layoutIfNeeded()
        animationStart = CACurrentMediaTime()
        earliestExit = animationStart + view.preExitDuration
        let covered = requestedPolicy == "covered" && !view.shortPresentation
        scheduledExit = covered ? max(earliestExit, start + Timing.deadline) : earliestExit
        scheduledReason = view.shortPresentation ? (view.usesBakedArtwork ? "reduceMotion" : "missingArtwork") : (covered ? "deadline" : "animation")
        view.start(at: animationStart, exitAt: scheduledExit)
        let preparedEpoch = animationStart
        animationStart = CACurrentMediaTime()
        view.alignPreparedTimeline(from: preparedEpoch, to: animationStart)
        earliestExit = animationStart + view.preExitDuration
        let finalExit = covered ? max(earliestExit, start + Timing.deadline) : earliestExit
        // 默认退场随整棵 layer 平移；只有仍被 DFL 软截止约束时才需重排。
        if abs(finalExit - (scheduledExit + animationStart - preparedEpoch)) > 0.0001 {
            view.scheduleExit(at: finalExit)
        }
        scheduledExit = finalExit
        #if DEBUG || PERF_BENCH
        let flushSpan = LaunchTrace.begin("splash.flush")
        #endif
        CATransaction.commit()
        CATransaction.flush() // 必须在 main 同步建三页之前，把含等待/退场的整段交给渲染进程。
        let committedAt = CACurrentMediaTime()
        #if DEBUG || PERF_BENCH
        LaunchTrace.end("splash.flush", flushSpan)
        #endif
        trace("splashShown", reason: "sceneConnected", at: committedAt)
        trace("splashCACommitted", reason: scheduledReason, at: committedAt)
        if !view.shortPresentation, !pushLaunch, ProcessInfo.processInfo.environment["MP_SPLASH_SOUND"] != "0" {
            sound.play(epoch: animationStart)
        }
        releaseContent()
        scheduleLifecycleCallbacks()
        evaluate()
    }

    /// 只推进状态和回收 UIWindow；两段视觉动画早已提交，不由这些 one-shot 回调开播。
    private static func scheduleLifecycleCallbacks() {
        exitWork?.cancel(); completionWork?.cancel()
        guard let view = animationView else { return }
        let ticket = run, expectedExit = scheduledExit
        let begin = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard ticket == run, expectedExit == scheduledExit else { return }
                requestFinish(reason: scheduledReason)
            }
        }
        let end = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard ticket == run, expectedExit == scheduledExit else { return }
                requestFinish(reason: scheduledReason, completed: true)
            }
        }
        exitWork = begin; completionWork = end
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, scheduledExit - CACurrentMediaTime()), execute: begin)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, scheduledExit + view.exitDuration - CACurrentMediaTime()), execute: end)
    }

    /// 单一完成入口：ready / 截止 / 动画完成 / background / push 都竞争 phase + run。
    private static func requestFinish(reason: String, immediately: Bool = false, completed: Bool = false) {
        guard phase != .finished else { return }
        if phase == .waiting {
            phase = .lifting
            finishReason = reason
            trace("dismissRequested", reason: reason)
            // 回调时间是 main 观察到退场的时刻；实际排程见 scheduledExit，不冒充呈现帧。
            trace("liftStart", reason: reason)
        }
        if immediately || completed { cleanup(ticket: run, reason: reason) }
    }

    private static func cleanup(ticket: UUID, reason: String) {
        guard ticket == run, phase != .finished else { return }
        phase = .finished
        finishReason = reason
        window?.isHidden = true; window = nil
        animationView = nil; artwork = nil
        artworkPreparation.cancel()
        sound.stop()
        releaseContent()
        exitWork?.cancel(); exitWork = nil
        completionWork?.cancel(); completionWork = nil
        sceneDeadlineWork?.cancel(); sceneDeadlineWork = nil
        trace("splashRemoved", reason: reason)
        run = UUID()
        if let observer = connectionObserver { NotificationCenter.default.removeObserver(observer) }
        connectionObserver = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private static func trace(_ name: String, reason: String, at: CFTimeInterval? = nil) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let timestamp = at ?? CACurrentMediaTime()
        PerfHarness.mark(name)
        if ["splashShown", "liftStart", "splashRemoved"].contains(name) { LaunchTrace.sampleMemory(name) }
        LaunchTrace.event(name, at: timestamp, fields: ["reason": reason, "minimum": earliestExit,
            "deadline": start + Timing.deadline, "latenessMs": max(0, CACurrentMediaTime() - start - Timing.deadline) * 1000,
            "animationStart": animationStart, "scheduledExit": scheduledExit, "animScale": Timing.animScale,
            "sceneElapsedMs": sceneConnectedAt > 0 ? (timestamp - sceneConnectedAt) * 1000 : 0,
            "epochToCommitMs": name == "splashCACommitted" ? (timestamp - animationStart) * 1000 : 0,
            "bakedArtwork": usesBakedArtwork, "reduceMotion": reduceMotion, "animationRevision": animationRevision,
            "pendingPages": readiness?.pendingPages ?? [0, 1, 2], "scene": scene?.session.persistentIdentifier ?? "unknown"])
        #endif
    }
}

/// AVAudioPlayer 和 session 操作只在这条串行队列上；不会阻塞 scene 的 CA 提交。
/// unchecked Sendable 的边界仅为队列封装，player 不向 main 或其它队列暴露。
private final class LaunchSplashSound: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mp.launch.sound", qos: .userInitiated)
    private var player: AVAudioPlayer?
    private var stopped = false

    @MainActor func preload() {
        queue.async { [self] in
            guard !stopped else { return }
            let began = CACurrentMediaTime()
            var reason = "ready"
            do {
                guard let data = NSDataAsset(name: "LaunchAnimSound")?.data else {
                    report("splashSoundSkipped", fields: ["reason": "missingAudio"])
                    return
                }
                // ambient 自带 mixWithOthers，遵守静音键；不使用 playback / duckOthers。
                let session = AVAudioSession.sharedInstance()
                // 另一个功能若已接管 session，不抢回分类。
                guard session.category == .soloAmbient || session.category == .ambient else {
                    report("splashSoundSkipped", fields: ["reason": "audioSessionInUse"])
                    return
                }
                try session.setCategory(.ambient, mode: .default)
                let prepared = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.caf.rawValue)
                guard prepared.prepareToPlay() else {
                    report("splashSoundSkipped", fields: ["reason": "prepareFailed"])
                    return
                }
                player = prepared
            } catch { reason = "prepareError" }
            let ended = CACurrentMediaTime()
            #if DEBUG || PERF_BENCH
            let outcome = reason
            DispatchQueue.main.async {
                LaunchTrace.recordBackgroundSpan("splash.audioPrepare", began: began, ended: ended, fields: ["reason": outcome])
            }
            #endif
        }
    }

    @MainActor func play(epoch: CFTimeInterval) {
        queue.async { [self] in
            guard !stopped, let player else { return }
            guard AVAudioSession.sharedInstance().category == .ambient else {
                report("splashSoundSkipped", fields: ["reason": "audioSessionInUse"])
                return
            }
            // 轨道有 432ms 静音前导。跳过已逝去的静音，预留 20ms 硬件排程余量；
            // 声音零点仍对应 epoch，不能把整条声音拖到 preload 完成时才从零播放。
            let deviceNow = player.deviceCurrentTime
            let mediaNow = CACurrentMediaTime()
            let offset = max(0.020, epoch - mediaNow)
            let seek = max(0, mediaNow + offset - epoch)
            guard seek < 0.72 * 0.6 else {
                report("splashSoundSkipped", fields: ["reason": "missedFirstCue", "latenessMs": seek * 1000])
                return
            }
            player.currentTime = seek
            let started = player.play(atTime: deviceNow + offset)
            report("splashSoundScheduled", fields: ["success": started, "animationStart": epoch,
                "deviceStart": deviceNow + offset, "trackOffset": seek, "animScale": 0.6])
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            player?.stop(); player = nil
            // session 为全 app 共享；这里不 deactivate，避免停掉随后接管的音乐/通话。
        }
    }

    private func report(_ name: String, fields: [String: Any]) {
        #if DEBUG || PERF_BENCH
        let at = CACurrentMediaTime()
        DispatchQueue.main.async { LaunchTrace.event(name, at: at, fields: fields) }
        #endif
    }
}

/// 仅本 VC 的本地内容/布局状态；不强持有 VC、VM 或 modelContext。
@MainActor
final class LaunchReadiness {
    let vcID = UUID().uuidString
    weak var owner: PagingViewController?
    private(set) var profile = ""
    private(set) var sceneID: String?
    private(set) var epoch = 0
    private(set) var layoutGeneration = 0
    private(set) var size: CGSize = .zero
    private(set) var required = true
    private(set) var valid = true
    private(set) var effectivePolicy = "eager"
    private(set) var fallbackReason = "default"
    private(set) var realRoots: Set<Int> = []
    private var rootRevisions: [Int: Int] = [:]
    private var assigningRoots: Set<Int> = []
    func revision(_ page: Int) -> Int { rootRevisions[page, default: 0] }
    // 「根版本号 + 已布局」常开的一小块（plan-paging-decouple §3.3 B-4）：翻页命令等「新内容已应用并布局过一次」用，只是整数
    private var hostLayoutCounts: [Int: Int] = [:]
    private var hostLaidOutRevisions: [Int: Int] = [:]
    func layoutCount(_ page: Int) -> Int { hostLayoutCounts[page, default: 0] }
    func laidOutRevision(_ page: Int) -> Int { hostLaidOutRevisions[page, default: -1] }
    func hostLaidOut(page: Int, revision: Int) {
        hostLayoutCounts[page, default: 0] += 1
        hostLaidOutRevisions[page] = revision
    }
    private var content: Set<Int> = []
    private var layouts: Set<Int> = []
    private var gestures: Set<Int> = []
    private var reported: Set<Int> = []
    var chatCondition: (() -> Bool)?
    var page2Condition: (() -> Bool)?
    var enabled: Bool {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if LaunchTrace.enabled || UITestHooks.active { return true }
        #endif
        return LaunchSplash.requestedPolicy == "covered"
    }
    var pendingPages: [Int] { [0, 1, 2].filter { !isPrepared($0) } }
    var allPrepared: Bool { required && valid && pendingPages.isEmpty }

    func configure(profile: String, required: Bool) {
        guard self.profile != profile || self.required != required else { return }
        self.profile = profile; self.required = required; valid = true
        epoch += 1; layoutGeneration += 1
        content.removeAll(); layouts.removeAll(); gestures.removeAll(); reported.removeAll()
        realRoots.removeAll(); assigningRoots.removeAll()
        effectivePolicy = LaunchSplash.requestedPolicy == "covered" && LaunchSplash.policyEligible && required ? "covered" : "eager"
        if effectivePolicy == "covered" { fallbackReason = "eligible" }
        else if LaunchSplash.requestedPolicy == "eager" { fallbackReason = "requestedEager" }
        else if !required { fallbackReason = "notApplicable" }
        else { fallbackReason = LaunchSplash.pushLaunch ? "push" : "noLaunchCoverEligibility" }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.env["MP_PERF_L4", default: "off"] != "off" || LaunchTrace.mountSequence != nil {
            effectivePolicy = "eager"; fallbackReason = "diagnosticMount"
        }
        LaunchTrace.event("vcRegistered", state: self, fields: ["required": required, "policy": effectivePolicy, "reason": fallbackReason])
        #endif
        LaunchSplash.register(self)
    }

    func forceEager(reason: String) {
        effectivePolicy = "eager"; fallbackReason = reason
    }

    func invalidate() {
        valid = false; epoch += 1
        forceEager(reason: "cancelled")
        content.removeAll(); layouts.removeAll(); gestures.removeAll(); reported.removeAll()
        chatCondition = nil; page2Condition = nil
        LaunchSplash.changed(self)
    }

    func resize(_ size: CGSize) {
        guard enabled, size.width > 0, size.height > 0, self.size != size else { return }
        self.size = size; layoutGeneration += 1
        layouts.removeAll(); reported.removeAll()
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.event("layoutGeneration", state: self, fields: ["width": size.width, "height": size.height])
        #endif
        LaunchSplash.changed(self)
    }

    func expectContent(_ page: Int) {
        content.remove(page); layouts.remove(page); reported.remove(page)
        LaunchSplash.changed(self)
    }

    func beginRootUpdate(_ pages: [Int]) {
        guard enabled else { return }
        for page in pages { layouts.remove(page); reported.remove(page) }
        layouts.remove(-1) // updatePages 随后会更新独立输入条，不能沿用它的上一棵 root 布局。
    }

    func inputAssigned() {
        guard enabled else { return }
        rootRevisions[-1, default: 0] += 1
        layouts.remove(-1)
    }

    func inputLaidOut(epoch: Int, layout: Int, revision: Int, size: CGSize, in window: UIWindow?) {
        guard enabled, valid, self.epoch == epoch, layoutGeneration == layout, self.revision(-1) == revision,
              size.width > 0, size.height > 0, let window, window === owner?.viewIfLoaded?.window else { return }
        if layouts.insert(-1).inserted {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            LaunchTrace.event("inputLayout", state: self, page: 1, fields: ["inputRevision": revision])
            #endif
        }
        check()
    }

    func rootCommitted(_ page: Int) {
        assigningRoots.remove(page)
        check()
    }

    func rootAssigned(_ page: Int, real: Bool) {
        rootRevisions[page, default: 0] += 1
        guard enabled else { return }
        assigningRoots.insert(page)
        if real { realRoots.insert(page) } else { realRoots.remove(page) }
        layouts.remove(page); reported.remove(page)
    }

    func note(_ stage: String, page: Int, epoch: Int, revision: Int? = nil) {
        guard enabled, valid, owner != nil, self.epoch == epoch, revision == nil || revision == self.revision(page), realRoots.contains(page) else { return }
        let inserted: Bool
        switch stage {
        case "contentReady": inserted = content.insert(page).inserted
        case "gestureReady": inserted = gestures.insert(page).inserted
        default: return
        }
        if stage == "contentReady", inserted {
            layouts.remove(page)
            owner?.launchContentChanged(page)
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if inserted { LaunchTrace.event(stage, state: self, page: page) }
        #endif
        check()
    }

    func laidOut(page: Int, epoch: Int, layout: Int, revision: Int, size: CGSize, in window: UIWindow?) {
        guard enabled, valid, owner != nil, self.epoch == epoch, layoutGeneration == layout, self.revision(page) == revision, realRoots.contains(page), let scene = window?.windowScene,
              self.size.width > 0, abs(size.width - self.size.width) < 1, abs(size.height - self.size.height) < 1 else { return }
        sceneID = scene.session.persistentIdentifier
        if page == 0 || page == 1 { note("gestureReady", page: page, epoch: epoch) }
        if layouts.insert(page).inserted {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            LaunchTrace.event("rootLayout", state: self, page: page)
            #endif
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if page == 0 { PerfHarness.refreshListRegistration(self) }
        #endif
        LaunchSplash.bind(self, in: scene)
        check()
    }

    func isPrepared(_ page: Int) -> Bool {
        guard valid, owner != nil, required, !assigningRoots.contains(page), realRoots.contains(page), layouts.contains(page), gestures.contains(page) else { return false }
        if page == 1 { return layouts.contains(-1) && chatCondition?() == true }
        if page == 2 { return content.contains(page) && page2Condition?() == true }
        return content.contains(page)
    }

    func check() {
        guard enabled, valid else { return }
        for page in 0..<3 where isPrepared(page) && reported.insert(page).inserted {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if page == 1 { LaunchTrace.event("contentReady", state: self, page: page) }
            LaunchTrace.event("pagePrepared", state: self, page: page)
            if page == 1 { LaunchTrace.event("chatStructuralReady", state: self, page: page) }
            #endif
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if allPrepared, LaunchTrace.time("allRequiredPagesPrepared", state: self) == nil {
            LaunchTrace.event("allRequiredPagesPrepared", state: self)
        }
        #endif
        LaunchSplash.changed(self)
    }
}

struct LaunchPageSignal {
    let state: LaunchReadiness
    let epoch: Int
    let page: Int
    let revision: Int
    @MainActor func note(_ stage: String) { state.note(stage, page: page, epoch: epoch, revision: revision) }
}
extension EnvironmentValues {
    @Entry var launchPageSignal: LaunchPageSignal? = nil
}

/// 真实 HC 完成自身布局后回报；placeholder 没有 realRoots 资格，绝不凭非零 bounds 放行。
@MainActor
final class LaunchRootHost: UIHostingController<AnyView> {
    weak var launchState: LaunchReadiness?
    let page: Int
    var launchEpoch: Int
    var launchRevision: Int
    init(rootView: AnyView, state: LaunchReadiness, page: Int) {
        launchState = state; self.page = page; launchEpoch = state.epoch; launchRevision = state.revision(page)
        super.init(rootView: rootView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func viewDidLayoutSubviews() {
        let epoch = launchEpoch
        let layout = launchState?.layoutGeneration ?? -1
        let revision = launchRevision
        super.viewDidLayoutSubviews()
        if page >= 0 { launchState?.hostLaidOut(page: page, revision: revision) }
        if page >= 0 { launchState?.laidOut(page: page, epoch: epoch, layout: layout, revision: revision, size: view.bounds.size, in: view.window) }
        else { launchState?.inputLaidOut(epoch: epoch, layout: layout, revision: revision, size: view.bounds.size, in: view.window) }
    }
}
#endif
