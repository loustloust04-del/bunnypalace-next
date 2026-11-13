#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// 桌面三个毛病（dock 被挤 / 小组件滚动穿模 / 编辑态不抖，docs/research-page2-desktop-three-bugs.md）的 Air 常驻探针。
/// Debug 包常开，只记几何和开关标量，不记内容；值变了才写一行。粟粟看到毛病就截屏：截屏那一刻整份快照一次（= 打点）。
/// 落盘 Documents/page2-desktop-probe/<启动时间>.jsonl，单文件 2 MiB 封顶，只留最近 8 个启动。
@MainActor
final class Page2DesktopProbe {
    static let shared = Page2DesktopProbe()

    private weak var dock: WindowFrameProbe?
    private let stacks = NSHashTable<UIViewController>.weakObjects()
    private var homePhase = "?"
    private var motionKey = ""
    private var dockKey = ""
    private var ticks = 0
    private var lastTickLog = 0.0
    private var keyboard = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "page2.desktop-probe", qos: .utility)
    private let launch = CACurrentMediaTime()

    private init() {
        let events: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"), (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"), (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIResponder.keyboardDidShowNotification, "keyboardShown"), (UIResponder.keyboardDidHideNotification, "keyboardHidden"),
            (UIApplication.userDidTakeScreenshotNotification, "screenshot")
        ]
        for (name, label) in events {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Page2DesktopProbe.shared.lifecycle(label) }
            }
        }
        queue.async { Self.open() }
        write(["type": "launch", "uiState": UIApplication.shared.applicationState.rawValue])
        if UIApplication.shared.applicationState == .active { startTimer() }
    }

    // MARK: 挂点

    func attach(dock probe: WindowFrameProbe) {
        dock = probe
        sampleDock("attach", force: true)
    }

    func noteHomePhase(_ phase: ScenePhase) {
        homePhase = Self.name(phase)
        write(["type": "homePhase", "phase": homePhase, "uiState": UIApplication.shared.applicationState.rawValue])
        sampleDock("homePhase")
    }

    func noteEditing(_ editing: Bool) {
        motionKey = ""; ticks = 0; lastTickLog = CACurrentMediaTime()
        write(["type": "editing", "on": editing, "homePhase": homePhase, "uiState": UIApplication.shared.applicationState.rawValue,
               "page2Active": Page2SceneState.shared.isActive])
    }

    /// 抖动修饰器 body 每次重算都调；enabled 的实例读到的环境一样，签名去重，只在变化时（和每次进编辑后第一次）落一行
    func motion(enabled: Bool, desktopActive: Bool, scenePhase: ScenePhase, reduceMotion: Bool) {
        guard enabled else { return }
        let key = "\(desktopActive)|\(Self.name(scenePhase))|\(reduceMotion)"
        guard key != motionKey else { return }
        motionKey = key
        write(["type": "motion", "desktopActive": desktopActive, "envPhase": Self.name(scenePhase), "reduceMotion": reduceMotion,
               "active": desktopActive && scenePhase == .active && !reduceMotion,
               "uiState": UIApplication.shared.applicationState.rawValue, "homePhase": homePhase,
               "page2Active": Page2SceneState.shared.isActive])
    }

    /// 抖动时间线真在走：每 2 秒最多落一行，带这段的帧回调数（所有抖动实例合计）
    func tick() {
        ticks += 1
        let now = CACurrentMediaTime()
        guard now - lastTickLog >= 2 else { return }
        write(["type": "tick", "calls": ticks])
        ticks = 0; lastTickLog = now
    }

    func attach(stack controller: UIViewController) { stacks.add(controller) }

    func stackScroll(_ controller: UIViewController, began: Bool) {
        write(["type": "stack", "phase": began ? "began" : "ended", "stack": Self.stackState(controller)])
    }

    /// home 宿主（Page2AppHostingController，contentViews["home"]）安全区变了
    func safeAreaChanged(_ view: UIView) {
        guard view === Page2AppShell.shared.contentViews["home"]?.view else { return }
        sampleDock("homeSafeArea")
    }

    // MARK: 采样

    private func lifecycle(_ label: String) {
        switch label {
        case "didBecomeActive": startTimer()
        case "willResignActive": timer?.invalidate(); timer = nil
        case "keyboardShown": keyboard = true
        case "keyboardHidden": keyboard = false
        default: break
        }
        write(["type": "life", "event": label, "uiState": UIApplication.shared.applicationState.rawValue,
               "homePhase": homePhase, "motion": motionKey])
        if label == "screenshot" {
            sampleDock("screenshot", force: true)
            write(["type": "snapshot", "motion": motionKey, "homePhase": homePhase,
                   "rendering": Page2AppearanceStore.shared.displayed.rendering,
                   "stacks": stacks.allObjects.map(Self.stackState)])
        } else if label == "didBecomeActive" || label.hasPrefix("keyboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Page2DesktopProbe.shared.sampleDock(label + "+0.6") }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { Page2DesktopProbe.shared.sampleDock("poll") }
        }
    }

    /// dock 下沿 vs 窗口：对的时候 dockMaxY ≈ 窗口高 − 窗口底部安全区 + 17（research §2.2），delta 偏离 0 就是毛病 1
    private func sampleDock(_ why: String, force: Bool = false) {
        guard force || Page2SceneState.shared.isActive, let frame = dock?.windowFrame,
              let home = Page2AppShell.shared.contentViews["home"]?.view, let window = home.window else { return }
        let expected = window.bounds.height - window.safeAreaInsets.bottom + 17
        let windowSafe = [Self.r(window.safeAreaInsets.top), Self.r(window.safeAreaInsets.bottom)]
        let key = "\(Self.r(frame.maxY))|\(Self.r(frame.height))|\(windowSafe)|\(Self.r(home.safeAreaInsets.bottom))|\(keyboard)|\(Self.r(Page2AppShell.shared.stripProgress))"
        guard force || why != "poll" || key != dockKey else { return }
        dockKey = key
        var chain: [[String: Any]] = []
        var responder: UIResponder? = home
        while let next = responder?.next, chain.count < 8 {
            if let vc = next as? UIViewController {
                chain.append(["vc": Self.shortName(vc), "safeBottom": Self.r(vc.view.safeAreaInsets.bottom),
                              "addBottom": Self.r(vc.additionalSafeAreaInsets.bottom), "addTop": Self.r(vc.additionalSafeAreaInsets.top)])
            }
            responder = next
        }
        write([
            "type": "dock", "why": why, "dock": Self.rect(frame), "delta": Self.r(frame.maxY - expected),
            "window": [Self.r(window.bounds.width), Self.r(window.bounds.height)], "windowSafe": windowSafe,
            "homeHost": ["frame": Self.rect(home.convert(home.bounds, to: nil)), "hidden": home.isHidden,
                         "safe": [Self.r(home.safeAreaInsets.top), Self.r(home.safeAreaInsets.bottom)]],
            "chain": chain, "strip": Self.r(Page2AppShell.shared.stripProgress), "keyboard": keyboard,
            "page2Active": Page2SceneState.shared.isActive, "uiState": UIApplication.shared.applicationState.rawValue
        ])
    }

    private static func stackState(_ controller: UIViewController) -> [String: Any] {
        guard let view = controller.viewIfLoaded else { return [:] }
        let scroll = view.subviews.compactMap { $0 as? UIScrollView }.first
        return [
            "frame": rect(view.convert(view.bounds, to: nil)), "clips": view.clipsToBounds, "radius": r(view.layer.cornerRadius),
            "inWindow": view.window != nil,
            "offset": scroll.map { [r($0.contentOffset.x), r($0.contentOffset.y)] } ?? [],
            "pages": controller.children.map { ["frame": rect($0.view.convert($0.view.bounds, to: nil)), "clips": $0.view.clipsToBounds] },
            "ancestors": ancestors(of: view)
        ]
    }

    /// 往上到窗口：哪层 clipsToBounds、哪层 transform 非单位（编辑态抖动 / 竖条缩放），穿模时看裁切落在哪层
    private static func ancestors(of view: UIView) -> [String] {
        var out: [String] = []
        var current = view.superview
        while let v = current, out.count < 12 {
            let transformed = !CATransform3DIsIdentity(v.layer.transform) || v.transform != .identity
            out.append("\(String(describing: type(of: v)).prefix(28))\(v.clipsToBounds ? "[clip]" : "")\(transformed ? "[T]" : "")")
            current = v.superview
        }
        return out
    }

    // MARK: 落盘

    private nonisolated static func open() {
        let fm = FileManager.default
        guard let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let dir = docs.appendingPathComponent("page2-desktop-probe", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in old.dropLast(7) { try? fm.removeItem(at: url) }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(stamp).jsonl")
        fm.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
    }

    /// 只在 queue 上读写
    private nonisolated(unsafe) static var fileHandle: FileHandle?
    private nonisolated(unsafe) static var fileBytes = 0

    private func write(_ record: [String: Any]) {
        var record = record
        record["t"] = Self.r(CACurrentMediaTime() - launch)
        record["wall"] = Date().timeIntervalSince1970.rounded()
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let line = data
        queue.async {
            guard let handle = Self.fileHandle, Self.fileBytes < 2 << 20 else { return }
            try? handle.write(contentsOf: line)
            Self.fileBytes += line.count
        }
    }

    private static func name(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
    private static func shortName(_ vc: UIViewController) -> String {
        String(String(describing: type(of: vc)).prefix { $0 != "<" })
    }
    private static func r(_ value: CGFloat) -> Double { (Double(value) * 10).rounded() / 10 }
    private static func rect(_ rect: CGRect) -> [Double] { [r(rect.minX), r(rect.minY), r(rect.width), r(rect.height)] }
}

/// 挂在 Page2HomeView 上：和 HomeView 同一个宿主，读到的 scenePhase 就是 HomeView 读到的那份
struct Page2DesktopProbeHook: ViewModifier {
    let dock: WindowFrameProbe
    let editing: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { Page2DesktopProbe.shared.attach(dock: dock); Page2DesktopProbe.shared.noteHomePhase(scenePhase) }
            .onChange(of: scenePhase) { _, phase in Page2DesktopProbe.shared.noteHomePhase(phase) }
            .onChange(of: editing) { _, on in Page2DesktopProbe.shared.noteEditing(on) }
    }
}
#endif
