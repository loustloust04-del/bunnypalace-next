#if (DEBUG || PERF_BENCH) && os(iOS)
import os
import SwiftUI
import UIKit

/// #070 测量台：env `MP_ARC_BENCH=<轮数>` 时，外壳自己反复「开某个应用 → 拉左上弧线回桌面」，
/// 走和手指同一套 `beginMotion → 逐帧 cardProgress → goHome`（只是没有真触摸），每轮打一行 `ARC_BENCH {json}` 到 stdout。
/// `MP_ARC_APP`（默认 ccTerminal）选应用，用别的应用做对照；`MP_ARC_LOCAL=1` 先开一个小电脑终端再拉。
/// 口径（harness arc-r3）：帧间隔 = CADisplayLink 到达间隔（主线程回调间隔，不是 presented-frame）；主线程忙 = 双观察者 split
/// 口径（含布局 + CA 提交，playbook §3.2），窗口末端未闭合的段也算进去。键盘事件是进程范围的 willShow/willHide 请求序列。
/// 每轮带 `valid`：落点真在桌面、键盘场景开局终端真是第一响应者；统计只用 valid 的轮。与 AirPerfProbe 互斥。
@MainActor
enum Page2ArcBench {
    static let rounds = Int(ProcessInfo.processInfo.environment["MP_ARC_BENCH"] ?? "") ?? 0
    static let app = ProcessInfo.processInfo.environment["MP_ARC_APP"] ?? "ccTerminal"
    static let local = ProcessInfo.processInfo.environment["MP_ARC_LOCAL"] == "1"
    /// 每轮拉弧线前让终端弹键盘（她在终端里通常开着键盘）
    static let keyboard = ProcessInfo.processInfo.environment["MP_ARC_KEYBOARD"] == "1"
    /// 开局往小电脑终端里打一行命令（走键盘输入同一路径），比如 `top -d 0.2` 模拟一直在刷的 TUI
    static let typed = ProcessInfo.processInfo.environment["MP_ARC_TYPE"]
    static let signposter = OSSignposter(subsystem: "com.susu.MemoryPalace.perf", category: .pointsOfInterest)
    private static var blocks: [MainBlockMonitor.Block] = []
    private static let frames = FrameMonitor()
    private static var keyboardEvents: [String] = []
    private static var keyboardObservers: [NSObjectProtocol] = []
    private static var running = false

    struct Hooks {
        let select: (String) -> Void
        let selected: () -> String
        /// 手指按下（Page2CornerGesture .began）
        let touchDown: () -> Void
        /// 拖过 6pt（.changed 里 beginMotion）
        let begin: () -> Void
        let progress: (CGFloat) -> Void
        let home: () -> Void
        let openLocal: () -> Void
    }

    static func run(_ hooks: Hooks) async {
        guard rounds > 0, !running else { return }
        guard !AirPerfProbe.enabled else { print("ARC_BENCH skipped: AirPerfProbe 开着（共用 split 观察者）"); return }
        running = true
        defer {
            frames.stop()
            keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
            keyboardObservers.removeAll()
            MainBlockMonitor.observeSplit { _ in }
            running = false
        }
        MainBlockMonitor.observeSplit { blocks.append($0) }
        for (name, tag) in [(UIResponder.keyboardWillShowNotification, "show"), (UIResponder.keyboardWillHideNotification, "hide")] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { keyboardEvents.append(tag) }
            })
        }
        guard await pause(4) else { return }
        hooks.select(app)
        guard await pause(3) else { return }
        if local, app == "ccTerminal" {
            hooks.openLocal()
            guard await pause(5) else { return }
            if let typed, let terminal = terminalView(in: Page2AppShell.shared.contentViews[app]?.view) {
                terminal.insertText(typed + "\n")
                guard await pause(2) else { return }
            }
        }
        for round in 0..<rounds {
            if keyboard {
                _ = terminalView(in: Page2AppShell.shared.contentViews[app]?.view)?.becomeFirstResponder()
                guard await pause(1.5) else { return }
            }
            guard await arc(round, hooks), await pause(2) else { return }
            hooks.select(app)
            guard await pause(3) else { return }
            let focused = terminalView(in: Page2AppShell.shared.contentViews[app]?.view)?.isFirstResponder ?? false
            print("ARC_BENCH_REOPEN round=\(round) focused=\(focused)")
        }
        print("ARC_BENCH done")
    }

    /// 取消（页面离开）就返回 false，别再驱动外壳
    private static func pause(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(for: .seconds(seconds)); return true } catch { return false }
    }

    private static func arc(_ round: Int, _ hooks: Hooks) async -> Bool {
        let shell = Page2AppShell.shared
        blocks.removeAll()
        keyboardEvents.removeAll()
        let focusedAtStart = terminalView(in: Page2AppShell.shared.contentViews[app]?.view)?.isFirstResponder ?? false
        let hostReady = Page2AppShell.shared.contentViews[app]?.view?.window != nil && hooks.selected() == app
        frames.start()
        guard await pause(0.2) else { return false }
        let state = signposter.beginInterval("arc", "\(round)")
        let t0 = CACurrentMediaTime()
        hooks.touchDown()
        // 按下到拖过 6pt：至少睡 33ms（60Hz 两帧；主线程忙时实际更长，见 touchToBeginMs）
        guard await pause(0.033) else { return false }
        let focusedAfterTouch = terminalView(in: Page2AppShell.shared.contentViews[app]?.view)?.isFirstResponder ?? false
        let tBegin = CACurrentMediaTime()
        hooks.begin()
        let beginMs = (CACurrentMediaTime() - tBegin) * 1000
        // 手指 180ms 匀速拉到投影 183pt（≥170 回桌面），按墙钟每 ~8ms 推一次进度（主线程堵住时会跳）
        let dragStart = CACurrentMediaTime()
        while true {
            let t = min((CACurrentMediaTime() - dragStart) / 0.18, 1)
            hooks.progress(183 * t)
            if t >= 1 { break }
            guard await pause(0.008) else { return false }
        }
        let release = CACurrentMediaTime()
        hooks.home()
        while shell.motion != nil, CACurrentMediaTime() - release < 3 {
            guard await pause(0.016) else { return false }
        }
        let settled = CACurrentMediaTime()
        guard await pause(0.5) else { return false }
        let end = CACurrentMediaTime()
        signposter.endInterval("arc", state)
        frames.stop()
        let gaps = frameGaps(from: t0, to: settled)
        let window = (blocks + [MainBlockMonitor.currentSplit(now: end)].compactMap { $0 }).filter { $0.end > t0 && $0.start < end }
        let landedHome = shell.motion == nil && hooks.selected() == "home" && !shell.showsSwitcher
        let report: [String: Any] = [
            "harness": "arc-r3", "round": round, "app": app,
            "focusGuard": ProcessInfo.processInfo.environment["MP_TERM_FOCUS_GUARD"] ?? "default",
            "touchToBeginMs": (tBegin - t0) * 1000,
            "windowMs": (end - t0) * 1000,
            "valid": landedHome && hostReady && (!keyboard || focusedAtStart),
            "beginMs": beginMs,
            "dragMs": (release - dragStart) * 1000,
            "settleMs": (settled - release) * 1000,
            "worstGapMs": gaps.max() ?? 0,
            "framesOver25": gaps.filter { $0 > 25 }.count,
            "framesOver50": gaps.filter { $0 > 50 }.count,
            "frames": gaps.count,
            "busyMs": window.reduce(0) { $0 + (min($1.end, end) - max($1.start, t0)) } * 1000,
            "blocksOver50": window.filter { $0.end - $0.start > 0.05 }.map { [($0.start - t0) * 1000, ($0.end - $0.start) * 1000] },
            "landedHome": landedHome,
            "keyboard": keyboard,
            "focusedAtStart": focusedAtStart,
            "focusedAfterTouch": focusedAfterTouch,
            "keyboardEvents": keyboardEvents,
            "focusedAtEnd": terminalView(in: Page2AppShell.shared.contentViews[app]?.view)?.isFirstResponder ?? false,
            "typed": typed ?? "",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print("ARC_BENCH \(line)")
        }
        return true
    }

    private static func terminalView(in view: UIView?) -> ScrollableTerminalView? {
        guard let view else { return nil }
        if let terminal = view as? ScrollableTerminalView { return terminal }
        for subview in view.subviews { if let found = terminalView(in: subview) { return found } }
        return nil
    }

    private static func frameGaps(from start: Double, to end: Double) -> [Double] {
        let times = frames.arrivals
        return zip(times, times.dropFirst()).compactMap { a, b in b > start && a < end ? (b - a) * 1000 : nil }
    }
}
#endif
