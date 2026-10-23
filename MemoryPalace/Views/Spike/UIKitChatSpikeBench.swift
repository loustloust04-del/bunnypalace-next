#if (DEBUG || PERF_BENCH) && os(iOS)
import Combine
import SwiftData
import SwiftStreamingMarkdown
import SwiftUI
import UIKit

/// P1a-0 spike 测量台（docs/spike-uikit-chat-page.md）。env `MP_SPIKE_BENCH=perf|matrix|anim|kb` 起跑，
/// 只在测试楼层（perf-bench-profile）跑，不 save 任何东西：矩阵用的假行是不入库的 MessageNode。
/// 结果写 Documents/spike/<runId>.json + .log，跑完 exit(0)。
@MainActor
enum SpikeProbes {
    static weak var vc: SpikeChatViewController?
    static var sizing: [String: [Double]] = [:]
    static var configure: [String: [Double]] = [:]
    static var heights: [String: [[Double]]] = [:]
    static var tokenOwner: [UUID: String] = [:]
    static var tokensById: [String: [UUID]] = [:]
    static var leaks: [String] = []
    static let sheetRequests = PassthroughSubject<String, Never>()
    static var popInsertIds: Set<String> = []
    static var prelayout: [[Double]] = []
    static var pads: [[String: Any]] = []
    static var loop = 0
    /// ⑤ 重入：垫块 sink（嵌在 PagingVC.viewDidLayoutSubviews → publishKeyboardGeometry 里）同步 layout 期间发生的自测高变化
    static var inPadSink = false
    static var reentrant: [[String: Any]] = []
    static var t0: Double = CACurrentMediaTime()
    nonisolated(unsafe) static var logHandle: FileHandle?

    static func now() -> Double { CACurrentMediaTime() }
    static func rel(_ t: Double) -> Double { ((t - t0) * 10000).rounded() / 10 }

    static func log(_ s: String) {
        let line = String(format: "%.1f L%d ", (now() - t0) * 1000, loop) + s + "\n"
        if let d = line.data(using: .utf8) { try? logHandle?.write(contentsOf: d) }
        #if DEBUG
        KBProbe.log("[SPIKE] " + s)
        #endif
    }
    static func noteSizing(_ id: String, ms: Double) { sizing[id, default: []].append(ms) }
    static func noteConfigure(_ id: String, ms: Double) { configure[id, default: []].append(ms) }
    static func noteHeight(_ id: String, old: CGFloat, new: CGFloat) {
        heights[id, default: []].append([rel(now()), Double(new)])
        if inPadSink {
            reentrant.append(["t": rel(now()), "id": id, "old": Double(old), "new": Double(new)])
            log("⑤ reentrant height change in pad sink \(id) \(Int(old))→\(Int(new))")
        }
    }
    static func noteAppear(id: String, token: UUID) {
        if let owner = tokenOwner[token], owner != id {
            leaks.append("\(owner)->\(id)")
            log("① LEAK token of \(owner) now on \(id)")
        }
        tokenOwner[token] = id
        if tokensById[id]?.contains(token) != true { tokensById[id, default: []].append(token) }
    }
    static func notePrelayout(count: Int, ms: Double) { prelayout.append([Double(count), ms]) }
    static func notePad(_ pad: CGFloat, reason: String) {
        pads.append(["t": rel(now()), "loop": loop, "pad": Double(pad), "reason": reason])
        log("pad=\(Int(pad)) (\(reason))")
    }
}

/// 主线程忙：afterWaiting（最先）→ beforeWaiting（最后，含 CA 提交）
@MainActor
final class SpikeBusyMonitor {
    static let shared = SpikeBusyMonitor()
    private(set) var blocks: [(Double, Double)] = []
    private var start: Double?

    func install() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { _, _ in
            MainActor.assumeIsolated { SpikeBusyMonitor.shared.start = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated {
                let m = SpikeBusyMonitor.shared
                if let s = m.start { m.blocks.append((s, CACurrentMediaTime())) }
                m.start = nil
                SpikeProbes.loop += 1
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
    }

    private func all(now: Double) -> [(Double, Double)] { start.map { blocks + [($0, now)] } ?? blocks }

    func busy(_ a: Double, _ b: Double) -> Double {
        all(now: CACurrentMediaTime()).reduce(0) { $0 + max(0, min($1.1, b) - max($1.0, a)) } * 1000
    }
    func longest(_ a: Double, _ b: Double) -> Double {
        all(now: CACurrentMediaTime()).map { max(0, min($0.1, b) - max($0.0, a)) }.max().map { $0 * 1000 } ?? 0
    }
}

/// 逐帧驱动器（程序化滚动 / 采样）
@MainActor
final class SpikeFrameDriver: NSObject {
    private var link: CADisplayLink?
    private var tick: ((Double, Double) -> Bool)?
    private var last: Double = 0
    private var cont: CheckedContinuation<Void, Never>?

    func run(_ tick: @escaping (_ now: Double, _ dt: Double) -> Bool) async {
        self.tick = tick
        last = CACurrentMediaTime()
        await withCheckedContinuation { c in
            cont = c
            let l = CADisplayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    @objc private func step(_ l: CADisplayLink) {
        let t = CACurrentMediaTime()
        let dt = t - last
        last = t
        if tick?(t, dt) == false {
            link?.invalidate()
            link = nil
            tick = nil
            cont?.resume()
            cont = nil
        }
    }
}

@MainActor
enum UIKitChatSpikeBench {
    nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static let scenario = env["MP_SPIKE_BENCH"]
    nonisolated static var requested: Bool { scenario != nil }
    nonisolated static let runId = env["MP_SPIKE_RUNID"] ?? "\(Int(Date().timeIntervalSince1970))"
    private static var started = false
    private static var result: [String: Any] = [:]
    nonisolated(unsafe) private static var textKit: [String: Double] = [:]

    static var sv: UIScrollView? { StreamScrollAnchor.AnchorView.chatScrollView }
    static var vm: ConversationViewModel? { PerfHarness.viewModel }
    static var modeName: String { UIKitChatSpike.mode?.rawValue ?? "old" }

    static func startIfRequested(profileId: String?) {
        guard requested, !started else { return }
        started = true
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("spike")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("\(runId).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        SpikeProbes.logHandle = try? FileHandle(forWritingTo: logURL)
        SpikeBusyMonitor.shared.install()
        result = ["runId": runId, "scenario": scenario ?? "", "mode": modeName, "stableID": UIKitChatSpike.stableID,
                  "bubbleMode": UserDefaults.standard.bool(forKey: "chatBubbleMode"),
                  "thermalStart": ProcessInfo.processInfo.thermalState.rawValue,
                  "launchConv": vm?.selectedConversation?.id ?? NSNull(),
                  "buildSha": env["MP_SPIKE_BUILDSHA"] ?? "unknown", "dirty": env["MP_SPIKE_DIRTY"] ?? "unknown",
                  "config": buildConfig, "padMode": UIKitChatSpike.padMode, "bareHosting": UIKitChatSpike.bareHosting,
                  "prelayoutFirst": UIKitChatSpike.prelayoutFirst, "target": env["MP_SPIKE_TARGET"] ?? "B"]
        // L1 未提交改动的开关（池复用 / 宽度 / 容器高 / 同步门槛 / 流完预填），各臂都显式置 0 对齐上一轮口径
        result["l1Env"] = env.filter { $0.key.hasPrefix("MP_PERF_L1") }
        UIDevice.current.isBatteryMonitoringEnabled = true
        result["batteryStart"] = Double(UIDevice.current.batteryLevel)
        result["batteryState"] = UIDevice.current.batteryState.rawValue
        result["lowPower"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        SpikeProbes.log("bench start scenario=\(scenario ?? "") mode=\(modeName) profile=\(profileId ?? "nil")")
        guard profileId == PerfHarness.profileId else {
            result["failure"] = "not on bench profile (\(profileId ?? "nil"))"
            finish()
            return
        }
        // 设备条件门（车头 10-01）：电量 ≥ 50%、不在低电量模式，否则不测
        if UIDevice.current.batteryLevel >= 0, UIDevice.current.batteryLevel < 0.5 || ProcessInfo.processInfo.isLowPowerModeEnabled {
            result["failure"] = "battery gate (level \(UIDevice.current.batteryLevel), lowPower \(ProcessInfo.processInfo.isLowPowerModeEnabled))"
            finish()
            return
        }
        MarkdownPerfProbe.layout = { pass, a, b in
            UIKitChatSpikeBench.textKit[pass.rawValue, default: 0] += (b - a) * 1000
        }
        MarkdownPerfProbe.vend = { hit, a, b in
            UIKitChatSpikeBench.textKit[hit ? "vendHitMs" : "vendNewMs", default: 0] += (b - a) * 1000
            UIKitChatSpikeBench.textKit[hit ? "vendHit" : "vendNew", default: 0] += 1
        }
        Task { @MainActor in
            await sleep(2.5)
            switch scenario {
            case "perf": await perf()
            case "matrix": await matrix()
            case "anim": await anim()
            case "kb": await keyboard()
            case "stream": await stream()
            default: result["failure"] = "unknown scenario"
            }
            finish()
        }
    }

    private static func finish() {
        result["thermalEnd"] = ProcessInfo.processInfo.thermalState.rawValue
        result["batteryEnd"] = Double(UIDevice.current.batteryLevel)
        result["reentrantHeightChanges"] = SpikeProbes.reentrant
        result["leaks"] = SpikeProbes.leaks
        result["prelayout"] = SpikeProbes.prelayout
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("spike")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("\(runId).json"))
        }
        SpikeProbes.log("bench done")
        try? SpikeProbes.logHandle?.synchronize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    static func ms(_ s: Double) -> Double { (s * 10000).rounded() / 10 }

    // MARK: 打开对话

    static func fetchConv(_ id: String) -> Conversation? {
        guard let ctx = PerfHarness.modelContext else { return nil }
        return try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
    }

    /// 打开并等结构稳定：contentSize 与已量高度 300ms 不变
    @discardableResult
    static func open(_ convId: String, name: String, record: Bool = true) async -> [String: Any] {
        guard let vm, let ctx = PerfHarness.modelContext, let conv = fetchConv(convId) else {
            result["failure"] = "open \(convId): missing vm/ctx/conv"
            return [:]
        }
        let target = conv.currentNodeId
        textKit = [:]
        SpikeProbes.sizing = [:]
        SpikeProbes.configure = [:]
        SpikeProbes.heights = [:]
        let t0 = CACurrentMediaTime()
        vm.loadConversation(conv, context: ctx)
        var lastChange = t0
        var lastSig = ""
        var applied: Double?
        let deadline = t0 + 8
        while CACurrentMediaTime() < deadline {
            await sleep(0.008)
            let now = CACurrentMediaTime()
            guard vm.selectedConversation?.id == convId, !vm.isLoading, vm.currentPath.last?.id == target, let sv else { continue }
            if applied == nil { applied = now }
            let sig = "\(Int(sv.contentSize.height))|\(SpikeProbes.vc?.layout.measured.count ?? -1)|\(SpikeProbes.heights.values.reduce(0) { $0 + $1.count })"
            if sig != lastSig { lastSig = sig; lastChange = now }
            if now - lastChange > 0.3 { break }
        }
        let ready = lastChange
        if CACurrentMediaTime() < t0 + 1.6 { await sleep(t0 + 1.6 - CACurrentMediaTime()) }
        let mon = SpikeBusyMonitor.shared
        let longId = "\(PerfHarness.convB)-\(PerfSeed.longNodeIndex)"
        var r: [String: Any] = [
            "name": name, "conv": convId,
            "appliedMs": applied.map { ms($0 - t0) } ?? -1,
            "readyMs": ms(ready - t0),
            "busyToReadyMs": mon.busy(t0, ready + 0.02),
            "busy1sMs": mon.busy(t0, t0 + 1),
            "longestBlockMs": mon.longest(t0, t0 + 1.5),
            "textKitMs": textKit,
            "longSizingMs": SpikeProbes.sizing[longId] ?? [],
            "longConfigureMs": SpikeProbes.configure[longId] ?? [],
            "longHeights": SpikeProbes.heights[longId] ?? [],
            "t0": SpikeProbes.rel(t0),
            "sizingTotalMs": SpikeProbes.sizing.values.flatMap { $0 }.reduce(0, +),
            "configureTotalMs": SpikeProbes.configure.values.flatMap { $0 }.reduce(0, +),
            "contentHeight": sv?.contentSize.height ?? -1,
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
        ]
        r["timedOut"] = CACurrentMediaTime() >= deadline
        SpikeProbes.log("open \(name) ready=\(r["readyMs"]!) busy=\(r["busyToReadyMs"]!) longest=\(r["longestBlockMs"]!)")
        if record { result["opens"] = ((result["opens"] as? [[String: Any]]) ?? []) + [r] }
        return r
    }

    static func toBottom() {
        guard let sv else { return }
        sv.contentOffset.y = -sv.adjustedContentInset.top
    }

    // MARK: perf：开 A → 开 B（冷）→ 深翻 → 开 A → 开 B（热）→ 开 A（下次冷启落 A）

    #if DEBUG
    static let buildConfig = "Debug"
    #else
    static let buildConfig = "Release+PERF_BENCH"
    #endif

    /// 目标对话：B（300 + 3466 字长文）或 M（40 条中长文，块型轮换含代码块 / 表格）
    static var targetKey: String { env["MP_SPIKE_TARGET"] ?? "B" }
    static var targetConv: String { targetKey == "M" ? "perf-flash-conv-M" : PerfHarness.convB }

    static func perf() async {
        await open(PerfHarness.convA, name: "A1")
        await sleep(0.8)
        await open(targetConv, name: "\(targetKey)cold")
        await sleep(1.0)
        result["deep"] = await deepScroll(speed: 12000)
        await sleep(0.8)
        await open(PerfHarness.convA, name: "A2")
        await sleep(0.8)
        await open(targetConv, name: "\(targetKey)warm")
        await sleep(0.8)
        await open(PerfHarness.convA, name: "A3", record: false)
    }

    /// 程序化来回（同 P0：12000pt/s，每帧步长封顶 400pt）：上翻到最旧端、再回到底
    static func deepScroll(speed: Double) async -> [String: Any] {
        guard let sv else { return ["failure": "no scroll view"] }
        toBottom()
        await sleep(0.5)
        let mon = SpikeBusyMonitor.shared
        var out: [String: Any] = [:]
        for dir in ["up", "back"] {
            var dist = 0.0
            var frames = 0
            var maxDt = 0.0
            let t0 = CACurrentMediaTime()
            await SpikeFrameDriver().run { _, dt in
                frames += 1
                maxDt = max(maxDt, dt)
                let step = min(400, speed * dt)
                let bottom = -sv.adjustedContentInset.top
                let top = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
                if dir == "up" {
                    let next = min(top, sv.contentOffset.y + step)
                    dist += next - sv.contentOffset.y
                    sv.contentOffset.y = next
                    return next < top - 0.5 && dist < 150_000 && CACurrentMediaTime() - t0 < 30
                } else {
                    let next = max(bottom, sv.contentOffset.y - step)
                    dist += sv.contentOffset.y - next
                    sv.contentOffset.y = next
                    return next > bottom + 0.5 && CACurrentMediaTime() - t0 < 30
                }
            }
            let t1 = CACurrentMediaTime()
            let busy = mon.busy(t0, t1)
            out[dir] = ["distPt": dist.rounded(), "wallMs": ms(t1 - t0), "busyMs": busy.rounded(), "frames": frames,
                        "busyMsPerKPt": dist > 0 ? (busy / dist * 1000 * 10).rounded() / 10 : -1,
                        "busyRatio": ((busy / ((t1 - t0) * 1000)) * 1000).rounded() / 1000,
                        "worstFrameMs": ms(maxDt)]
            SpikeProbes.log("deep \(dir) \(out[dir]!)")
            await sleep(0.5)
        }
        return out
    }

    // MARK: 假行（不入库）

    static var synthCount = 0
    static func synth(_ role: String, _ body: String) -> MessageNode {
        synthCount += 1
        let id = "spike-syn-\(synthCount)"
        let content = "⟦\(id)⟧ " + body
        return MessageNode(id: id, role: role, content: content, contentType: "text", createTime: Date(),
                           parentId: nil, childrenIds: [], conversationId: vm?.selectedConversation?.id ?? "", profileId: PerfHarness.profileId)
    }
    static func longBody(_ seed: Int) -> String {
        var s = "## 冷长文 \(seed)\n\n"
        for k in 0..<34 {
            s += "### 段 \(k)·\(seed)\n\n第 \(k) 段（种子 \(seed)）：这是一条不入库的假长文，用来检查异步排版首见、身份切换与高度收敛。**加粗** 与 *斜体* 与 `代码`。\n\n- 要点 \(k)-1\n- 要点 \(k)-2\n\n"
        }
        return s
    }

    /// 列表改写：front = 物理顶（最新）前插；replace / removed 作用于真实行
    static var front: [String] = []
    static var replace: [String: String] = [:]
    static var removed: Set<String> = []
    static func installOverride() {
        SpikeProbes.vc?.idOverride = { base in
            front + base.filter { !removed.contains($0) }.map { replace[$0] ?? $0 }
        }
    }
    static func add(_ n: MessageNode) { SpikeProbes.vc?.synthetic[n.id] = n }

    static func texts(in view: UIView?) -> String {
        guard let view else { return "" }
        var out = ""
        func walk(_ v: UIView) {
            if let tv = v as? UITextView { out += tv.text ?? "" }
            if let l = v as? UILabel { out += l.text ?? "" }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }

    static func visibleIds() -> [String] {
        guard let vc = SpikeProbes.vc else { return [] }
        let ids = vc.layout.ids
        return vc.collectionView.indexPathsForVisibleItems.map(\.item).sorted().compactMap { $0 < ids.count ? ids[$0] : nil }
    }

    static func topPresented() -> String? {
        var vc = sv?.window?.rootViewController
        var name: String?
        while let p = vc?.presentedViewController { name = String(describing: type(of: p)); vc = p }
        return name
    }
    static func dismissPresented() async {
        var vc = sv?.window?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        if let vc, vc !== sv?.window?.rootViewController { vc.dismiss(animated: false) }
        await sleep(0.6)
    }

    // MARK: matrix：① 身份 ② presentation ④ 高度（文章模式）

    static func matrix() async {
        await open(PerfHarness.convB, name: "B", record: false)
        await sleep(1.0)
        guard let vc = SpikeProbes.vc, let sv else { result["failure"] = "matrix needs spike mode"; return }
        installOverride()
        var m1: [String: Any] = [:]
        var vis = visibleIds()
        SpikeProbes.log("visible \(vis)")
        // ①-1 同 ID 重配
        if let x = vis.first(where: { !$0.contains("-\(PerfSeed.longNodeIndex)") }) {
            let before = SpikeProbes.tokensById[x]?.count ?? 0
            vc.reconfigure([x])
            await sleep(0.5)
            m1["sameIdReconfigure"] = ["id": x, "tokensBefore": before, "tokensAfter": SpikeProbes.tokensById[x]?.count ?? 0]
        }
        // ①-2 同 cell 换 ID（替换可见行，不动画）
        vis = visibleIds()
        if vis.count > 1 {
            let x = vis[1]
            let cellX = vc.cell(for: x)
            let y = synth("assistant", "换 ID 后的新行，短。")
            add(y)
            replace[x] = y.id
            vc.reload(animated: false)
            await sleep(0.6)
            let cellY = vc.cell(for: y.id)
            let t = texts(in: cellY)
            m1["sameCellNewId"] = ["from": x, "to": y.id, "sameCell": cellX != nil && cellX === cellY,
                                   "tokensY": SpikeProbes.tokensById[y.id]?.count ?? 0,
                                   "leakToY": SpikeProbes.leaks.contains { $0.hasSuffix("->\(y.id)") },
                                   "ownMarker": t.contains("⟦\(y.id)⟧"), "textHead": String(t.prefix(40))]
        }
        // ①-3 滚出回入
        vis = visibleIds()
        if let x = vis.first {
            let before = SpikeProbes.tokensById[x]?.count ?? 0
            let off = sv.contentOffset.y
            sv.contentOffset.y = off + sv.bounds.height * 6
            await sleep(0.6)
            sv.contentOffset.y = off
            await sleep(0.6)
            let t = texts(in: vc.cell(for: x))
            m1["scrollOutBack"] = ["id": x, "tokensBefore": before, "tokensAfter": SpikeProbes.tokensById[x]?.count ?? 0,
                                   "textNonEmpty": !t.isEmpty]
        }
        // ①-4 解析在途换 ID：冷长文刚配上（异步解析未回）就把这一格换成短行
        vis = visibleIds()
        if vis.count > 2 {
            let x = vis[2]
            let l = synth("assistant", longBody(9001))
            let z = synth("assistant", "解析在途时被换上的短行。")
            add(l); add(z)
            replace[x] = l.id
            vc.reload(animated: false)
            await sleep(0.016)
            replace[x] = z.id
            vc.reload(animated: false)
            await sleep(1.5)
            let tz = texts(in: vc.cell(for: z.id))
            let strays = visibleIds().filter { texts(in: vc.cell(for: $0)).contains("⟦\(l.id)⟧") }
            m1["parseInFlightSwap"] = ["long": l.id, "short": z.id, "shortOwnMarker": tz.contains("⟦\(z.id)⟧"),
                                       "shortHasLongText": tz.contains("⟦\(l.id)⟧"), "cellsShowingLong": strays,
                                       "shortHeights": SpikeProbes.heights[z.id] ?? []]
        }
        result["identity"] = m1
        SpikeProbes.log("① \(m1)")

        // ② presentation（只有 a 有 SwiftUI sheet）
        if vc.mode == .a {
            var m2: [String: Any] = [:]
            replace = [:]
            vc.reload(animated: false)
            await sleep(0.6)
            vis = visibleIds()
            if let x = vis.first {
                SpikeProbes.sheetRequests.send(x)
                await sleep(1.2)
                let shown = topPresented()
                let off = sv.contentOffset.y
                sv.contentOffset.y = off + sv.bounds.height * 6
                await sleep(1.0)
                let afterScroll = topPresented()
                await dismissPresented()
                sv.contentOffset.y = off
                await sleep(0.8)
                m2["presentThenScrollOut"] = ["id": x, "presented": shown ?? "none", "afterScrollOut": afterScroll ?? "none"]
            }
            vis = visibleIds()
            if let x = vis.first {
                SpikeProbes.sheetRequests.send(x)
                await sleep(1.2)
                let shown = topPresented()
                removed.insert(x)
                vc.reload(animated: false)
                await sleep(1.0)
                let afterDelete = topPresented()
                await dismissPresented()
                removed.remove(x)
                vc.reload(animated: false)
                await sleep(0.8)
                m2["presentThenDeleteSource"] = ["id": x, "presented": shown ?? "none", "afterDelete": afterDelete ?? "none"]
            }
            vis = visibleIds()
            if let x = vis.first {
                SpikeProbes.sheetRequests.send(x)
                await sleep(1.2)
                let shown = topPresented()
                await open(PerfHarness.convA, name: "switchA", record: false)
                let afterSwitch = topPresented()
                await dismissPresented()
                await open(PerfHarness.convB, name: "backB", record: false)
                m2["presentThenSwitchConv"] = ["id": x, "presented": shown ?? "none", "afterSwitch": afterSwitch ?? "none"]
            }
            // sheet 修饰是否撑高：同一行的 hosting 测高 vs 已记录高度
            result["presentation"] = m2
            SpikeProbes.log("② \(m2)")
        }

        // ④ 高度
        var m4: [String: Any] = [:]
        replace = [:]
        removed = []
        vc.reload(animated: false)
        await sleep(0.5)
        toBottom()
        await sleep(0.5)
        func series(_ id: String) -> [String: Any] {
            let s = SpikeProbes.heights[id] ?? []
            let hs = s.map { $0[1] }
            var osc = false
            for i in 2..<max(2, hs.count) where abs(hs[i] - hs[i - 2]) < 0.5 && abs(hs[i] - hs[i - 1]) > 0.5 { osc = true }
            return ["changes": s.count, "series": s, "oscillation": osc, "final": hs.last ?? -1]
        }
        // ④-1 异步首见（冷长文插到底）
        let l1 = synth("assistant", longBody(9101))
        add(l1)
        front = [l1.id]
        vc.reload(animated: false)
        let tIns = CACurrentMediaTime()
        await sleep(2.0)
        m4["asyncFirstSight"] = series(l1.id).merging(["insertedAt": SpikeProbes.rel(tIns)]) { $1 }
        // ④-2 热：拿掉再放回同一条
        front = []
        vc.reload(animated: false)
        await sleep(0.5)
        let warmBefore = SpikeProbes.heights[l1.id]?.count ?? 0
        front = [l1.id]
        vc.reload(animated: false)
        await sleep(1.5)
        m4["warmReinsertChanges"] = (SpikeProbes.heights[l1.id]?.count ?? 0) - warmBefore
        // ④-3 流式突发：每 50ms 追加，3s 后停，看收敛
        let s = synth("assistant", "流式开始。")
        add(s)
        front = [s.id, l1.id]
        vc.reload(animated: false)
        await sleep(0.5)
        let streamStart = CACurrentMediaTime()
        var k = 0
        while CACurrentMediaTime() - streamStart < 3 {
            k += 1
            s.content += (k % 8 == 0 ? "\n\n" : "") + "第\(k)片，追加一点正文让它长高。"
            if vc.mode != .a { vc.reconfigure([s.id]) }
            await sleep(0.05)
        }
        let streamEnd = CACurrentMediaTime()
        await sleep(2.0)
        var st = series(s.id)
        let lastChangeT = (SpikeProbes.heights[s.id]?.last?.first) ?? -1
        st["settleAfterStopMs"] = lastChangeT - SpikeProbes.rel(streamEnd)
        st["chunks"] = k
        m4["streamBurst"] = st
        // ④-4 同 ID 改文（变短）
        let before4 = SpikeProbes.heights[s.id]?.count ?? 0
        s.content = "⟦\(s.id)⟧ 改成很短。"
        if vc.mode != .a { vc.reconfigure([s.id]) }
        await sleep(1.0)
        m4["sameIdShrink"] = ["changes": (SpikeProbes.heights[s.id]?.count ?? 0) - before4,
                              "final": SpikeProbes.heights[s.id]?.last?[1] ?? -1]
        // ④-5 宽度变化（模拟转屏）：窄 60pt 再复原，复原后高度应回到原值
        let visIds = visibleIds()
        let base = Dictionary(uniqueKeysWithValues: visIds.map { ($0, Double(vc.layout.heights[$0] ?? -1)) })
        let frame = vc.collectionView.frame
        vc.collectionView.frame = frame.insetBy(dx: 30, dy: 0)
        await sleep(1.0)
        let narrow = Dictionary(uniqueKeysWithValues: visIds.map { ($0, Double(vc.layout.heights[$0] ?? -1)) })
        vc.collectionView.frame = frame
        await sleep(1.0)
        let restored = Dictionary(uniqueKeysWithValues: visIds.map { ($0, Double(vc.layout.heights[$0] ?? -1)) })
        let mismatched = visIds.filter { abs((restored[$0] ?? 0) - (base[$0] ?? 0)) > 1 }
        m4["widthChange"] = ["ids": visIds.count, "changedWhenNarrow": visIds.filter { abs((narrow[$0] ?? 0) - (base[$0] ?? 0)) > 1 }.count,
                             "notRestored": mismatched, "oscillating": visIds.filter { (series($0)["oscillation"] as? Bool) == true }]
        result["height"] = m4
        SpikeProbes.log("④ \(m4)")
        front = []
        vc.reload(animated: false)
        await sleep(0.5)
        await open(PerfHarness.convA, name: "A-end", record: false)
    }

    // MARK: anim：③ 气泡模式三种插入能不能弹（launch arg -chatBubbleMode YES）

    /// 一个 cell（含所有子层）的表现层：最小不透明度、最小缩放
    static func layerStats(_ view: UIView) -> [Double] {
        var minOp = 1.0, minScale = 1.0
        func walk(_ l: CALayer, _ depth: Int) {
            let p = l.presentation() ?? l
            if p.bounds.width * p.bounds.height > 400 || depth == 0 {
                minOp = min(minOp, Double(p.opacity))
                let t = p.transform
                minScale = min(minScale, Double(sqrt(t.m11 * t.m11 + t.m12 * t.m12)))
            }
            if depth < 12 { l.sublayers?.forEach { walk($0, depth + 1) } }
        }
        walk(view.layer, 0)
        return [minOp, minScale]
    }

    static func sampleInsertion(_ id: String, name: String, insert: () -> Void) async -> [String: Any] {
        guard let vc = SpikeProbes.vc else { return [:] }
        var samples: [[Double]] = []
        insert()
        let t0 = CACurrentMediaTime()
        await SpikeFrameDriver().run { t, _ in
            if let c = vc.cell(for: id) { samples.append([((t - t0) * 1000).rounded()] + layerStats(c)) }
            return t - t0 < 0.8
        }
        let final = samples.last ?? [0, 1, 1]
        let animFrames = samples.filter { $0[1] < final[1] - 0.05 || $0[2] < final[2] - 0.03 }.count
        let out: [String: Any] = ["frames": samples.count, "animatedFrames": animFrames, "popped": animFrames >= 3,
                                  "minOpacity": samples.map { $0[1] }.min() ?? -1, "minScale": samples.map { $0[2] }.min() ?? -1,
                                  "first": samples.prefix(4).map { $0 }]
        SpikeProbes.log("③ \(name) \(out)")
        return out
    }

    static func anim() async {
        await open(PerfHarness.convB, name: "B", record: false)
        await sleep(1.0)
        guard let vc = SpikeProbes.vc, let vm else { result["failure"] = "anim needs spike mode"; return }
        installOverride()
        toBottom()
        await sleep(0.5)
        var m3: [String: Any] = [:]
        // P1：UIKit 插入动画（layout 的 initialLayoutAttributes）
        let u1 = synth("user", "UIKit 插入弹")
        add(u1)
        m3["uikitInsert"] = await sampleInsertion(u1.id, name: "uikitInsert") {
            vc.layout.popIds = [u1.id]
            front = [u1.id] + front
            vc.reload(animated: true)
        }
        vc.layout.popIds = []
        await sleep(0.6)
        // P2：hosting 首渲 + 真实 popNodeIds 白名单（BubbleModeRow popPending），UIKit 不加动画属性
        let u2 = synth("user", "hosting 首渲弹")
        add(u2)
        m3["hostingFirstRender"] = await sampleInsertion(u2.id, name: "hostingFirstRender") {
            vm.popNodeIds.insert(u2.id)
            front = [u2.id] + front
            vc.reload(animated: true)
        }
        await sleep(0.6)
        // P3：已有子树插入：行先挂空壳，onAppear 里 withAnimation 插入真实 BubbleView
        let u3 = synth("user", "子树插入弹")
        add(u3)
        m3["subtreeInsert"] = await sampleInsertion(u3.id, name: "subtreeInsert") {
            SpikeProbes.popInsertIds.insert(u3.id)
            front = [u3.id] + front
            vc.reload(animated: true)
        }
        result["animation"] = m3
        front = []
        vc.reload(animated: false)
        await sleep(0.5)
        await open(PerfHarness.convA, name: "A-end", record: false)
    }

    // MARK: kb：⑤ 键盘弹 / 收（在底 / 近底 / 深翻），逐帧看参照行与输入条的表现层

    /// 屏上那个聊天输入框（别的页也可能有 ChatInputTextView：取在屏幕内的）
    static func findInput(_ root: UIView?) -> UITextView? {
        guard let root else { return nil }
        var found: [UITextView] = []
        func walk(_ v: UIView) {
            if let tv = v as? ChatInputTextView { found.append(tv) }
            v.subviews.forEach(walk)
        }
        walk(root)
        let screen = root.window?.bounds ?? UIScreen.main.bounds
        SpikeProbes.log("inputs \(found.map { KBProbe.f(windowRect($0)) })")
        return found.first { let r = windowRect($0); return r.minX >= -1 && r.maxX <= screen.maxX + 1 && r.height > 0 }
    }

    static func windowRect(_ v: UIView) -> CGRect {
        guard let w = v.window else { return .zero }
        let p = v.layer.presentation() ?? v.layer
        let wp = w.layer.presentation() ?? w.layer
        return p.convert(p.bounds, to: wp)
    }

    /// 参照：在底 / 近底 = 输入条上方最贴近的那段正文；深翻 = 离视口中心最近的那段
    static func pickReference(center: Bool, barTop: CGFloat) -> UIView? {
        guard let sv else { return nil }
        var cands: [UIView] = []
        func walk(_ v: UIView) {
            if let tv = v as? UITextView, !tv.isEditable, !(tv is ChatInputTextView) { cands.append(tv) }
            else if v is SpikeDrawnParagraphView { cands.append(v) }
            v.subviews.forEach(walk)
        }
        walk(sv)
        let svRect = windowRect(sv)
        SpikeProbes.log("⑤ candidates \(cands.count) first \(cands.prefix(3).map { KBProbe.f(windowRect($0)) })")
        let visible = cands.map { ($0, windowRect($0)) }.filter { $0.1.height > 10 && $0.1.maxY > svRect.minY + 60 && $0.1.minY < barTop - 4 }
        if center {
            let mid = svRect.midY
            return visible.min { abs($0.1.midY - mid) < abs($1.1.midY - mid) }?.0
        }
        return visible.filter { $0.1.maxY <= barTop + 2 }.max { $0.1.maxY < $1.1.maxY }?.0
    }

    static func kbCycle(_ name: String, center: Bool, input: UITextView) async -> [String: Any] {
        guard let sv else { return ["failure": "no sv"] }
        let barView: UIView = input
        let barTop0 = windowRect(barView).minY
        SpikeProbes.log("⑤ \(name) barTop=\(Int(barTop0)) sv=\(KBProbe.f(windowRect(sv))) off=\(Int(sv.contentOffset.y)) adjTop=\(Int(sv.adjustedContentInset.top))")
        guard let ref = pickReference(center: center, barTop: barTop0) else { return ["failure": "no reference", "barTop": Double(barTop0)] }
        var out: [String: Any] = [:]
        let y0 = windowRect(ref).maxY
        for phase in ["rise", "fall"] {
            var rows: [[Double]] = []
            let t0 = CACurrentMediaTime()
            let loop0 = SpikeProbes.loop
            let ok = phase == "rise" ? input.becomeFirstResponder() : input.resignFirstResponder()
            SpikeProbes.log("⑤ \(name) \(phase) responder=\(ok)")
            await SpikeFrameDriver().run { t, _ in
                rows.append([((t - t0) * 1000).rounded(), Double(windowRect(ref).maxY), Double(windowRect(barView).minY),
                             Double((sv.layer.presentation() ?? sv.layer).bounds.origin.y), Double(SpikeProbes.loop - loop0),
                             Double(SpikeProbes.vc?.layout.padHeight ?? KeyboardInsetBridge.shared.extra)])
                return t - t0 < 1.3
            }
            // 每帧：参照位移 dRef、输入条位移 dBar；在底 = 内容跟条走（dRef - dBar 应≈0），深翻 = 内容不动（dRef≈0）
            var maxRel = 0.0, over4 = 0, maxSecond = 0.0
            for i in 1..<max(1, rows.count) {
                let dRef = rows[i][1] - rows[i - 1][1]
                let dBar = rows[i][2] - rows[i - 1][2]
                let rel = center ? dRef : dRef - dBar
                maxRel = max(maxRel, abs(rel))
                if abs(rel) > 4 { over4 += 1 }
                if i >= 2 { maxSecond = max(maxSecond, abs(dRef - (rows[i - 1][1] - rows[i - 2][1]))) }
            }
            var ph: [String: Any] = [:]
            ph["frames"] = rows.count
            ph["maxRelJumpPt"] = (maxRel * 10).rounded() / 10
            ph["framesRelOver4pt"] = over4
            ph["maxSecondDiffPt"] = (maxSecond * 10).rounded() / 10
            let first: [Double] = rows.first ?? [-1, -1, -1]
            let last: [Double] = rows.last ?? [-1, -1, -1]
            ph["refStart"] = first[1]
            ph["refEnd"] = last[1]
            ph["barStart"] = first[2]
            ph["barEnd"] = last[2]
            ph["rows"] = rows.filter { $0[0] < 600 }
            out[phase] = ph
            await sleep(0.4)
        }
        out["refDriftAfterCyclePt"] = ((Double(windowRect(ref).maxY) - Double(y0)) * 10).rounded() / 10
        out["ref"] = String(describing: type(of: ref))
        SpikeProbes.log("⑤ \(name) rise=\((out["rise"] as? [String: Any])?["maxRelJumpPt"] ?? -1) fall=\((out["fall"] as? [String: Any])?["maxRelJumpPt"] ?? -1) drift=\(out["refDriftAfterCyclePt"]!)")
        return out
    }

    // MARK: stream：原生 / hosting 在底流式，每节拍主线程（Release）

    /// 合成流：在底插一条不入库的 assistant 假行，每 100ms 追加 15 字（每 8 拍一个空行起新段），133 拍 ≈ P0 S 场景的 1969 字 / 13.8s。
    /// 原生（b / c / m）每拍 reconfigure 这一行（cell 原地换段内容）；a 靠 BubbleView 自己观察 node.content。
    /// 每拍主线程 = 这一拍到下一拍之间的主线程忙；不经过 StreamPacer / provider，和 P0 旧页的 14ms 不是同一条路径（只作量级参照）
    static func stream() async {
        await open(PerfHarness.convB, name: "B", record: false)
        await sleep(1.0)
        guard let vc = SpikeProbes.vc, let sv else { result["failure"] = "stream needs spike mode"; return }
        installOverride()
        toBottom()
        let s = synth("assistant", "流式开始。")
        add(s)
        front = [s.id]
        vc.reload(animated: false)
        await sleep(1.0)
        let mon = SpikeBusyMonitor.shared
        var beats: [[Double]] = []
        let chunk = "流式片段追加的正文十五个字。"
        for k in 1...133 {
            let t0 = CACurrentMediaTime()
            s.content += (k % 8 == 0 ? "\n\n" : "") + chunk
            if vc.mode != .a { vc.reconfigure([s.id]) }
            await sleep(0.1)
            let t1 = CACurrentMediaTime()
            beats.append([mon.busy(t0, t1), mon.longest(t0, t1)])
        }
        await sleep(1.0)
        let busy = beats.map { $0[0] }.sorted()
        let longest = beats.map { $0[1] }.sorted()
        func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? -1 : (a[min(a.count - 1, Int(Double(a.count) * p))] * 10).rounded() / 10 }
        result["stream"] = ["beats": beats.count, "busyPerBeatP50": pct(busy, 0.5), "busyPerBeatP95": pct(busy, 0.95),
                            "busyPerBeatMax": pct(busy, 1), "longestBlockP95": pct(longest, 0.95), "longestBlockMax": pct(longest, 1),
                            "fromBottomEnd": Double(sv.contentOffset.y + sv.adjustedContentInset.top),
                            "finalHeight": Double(vc.layout.heights[s.id] ?? -1), "chars": s.content.count]
        SpikeProbes.log("stream \(result["stream"]!)")
        front = []
        vc.reload(animated: false)
        await sleep(0.5)
        await open(PerfHarness.convA, name: "A-end", record: false)
    }

    /// 深翻弹键盘（垫块被抑制）→ 动画滚回近底半屏 → 等 liftPadSuppression 长垫块回底。逐帧记表现层 offset 与垫块，
    /// 内容的视觉位移 = Δ垫块 − Δoffset（垫块是内容，物理顶长高 = 视觉上整体上移）；跳帧 = 这条曲线的二阶差分尖峰
    static func liftCycle(input: UITextView) async -> [String: Any] {
        guard let sv else { return ["failure": "no sv"] }
        let h = sv.bounds.height
        toBottom()
        await sleep(0.3)
        sv.contentOffset.y = -sv.adjustedContentInset.top + h * 6
        await sleep(0.8)
        _ = input.becomeFirstResponder()
        await sleep(1.2)
        let b = KeyboardInsetBridge.shared
        let suppressedBefore = b.padSuppressed
        let padBefore = Double(b.extra)
        var rows: [[Double]] = []
        let t0 = CACurrentMediaTime()
        sv.setContentOffset(CGPoint(x: 0, y: -sv.adjustedContentInset.top + h * 0.5), animated: true)
        await SpikeFrameDriver().run { t, _ in
            let pad = Double(SpikeProbes.vc?.layout.padHeight ?? b.extra)
            let off = Double((sv.layer.presentation() ?? sv.layer).bounds.origin.y)
            rows.append([((t - t0) * 1000).rounded(), off, pad, pad - off])
            return t - t0 < 2.0
        }
        var maxSecond = 0.0
        for i in 2..<max(2, rows.count) {
            maxSecond = max(maxSecond, abs((rows[i][3] - rows[i - 1][3]) - (rows[i - 1][3] - rows[i - 2][3])))
        }
        let out: [String: Any] = ["suppressedBefore": suppressedBefore, "padBefore": padBefore,
                                  "suppressedAfter": b.padSuppressed, "padAfter": Double(b.extra),
                                  "fromBottomEnd": Double(sv.contentOffset.y + sv.adjustedContentInset.top),
                                  "maxSecondDiffPt": (maxSecond * 10).rounded() / 10, "rows": rows]
        _ = input.resignFirstResponder()
        await sleep(1.2)
        SpikeProbes.log("⑤ lift suppressed \(suppressedBefore)→\(b.padSuppressed) pad \(padBefore)→\(b.extra) 2nd=\(out["maxSecondDiffPt"]!)")
        return out
    }

    static func keyboard() async {
        await open(PerfHarness.convB, name: "B", record: false)
        await sleep(1.0)
        guard let sv, let input = findInput(sv.window) else { result["failure"] = "no input text view"; return }
        var m5: [String: Any] = [:]
        toBottom()
        await sleep(0.8)
        m5["bottom"] = await kbCycle("bottom", center: false, input: input)
        toBottom()
        sv.contentOffset.y = -sv.adjustedContentInset.top + sv.bounds.height * 0.5
        await sleep(0.8)
        m5["near"] = await kbCycle("near", center: true, input: input)
        toBottom()
        await sleep(0.3)
        sv.contentOffset.y = -sv.adjustedContentInset.top + sv.bounds.height * 6
        await sleep(0.8)
        m5["deep"] = await kbCycle("deep", center: true, input: input)
        m5["deep2"] = await kbCycle("deep2", center: true, input: input)
        toBottom()
        await sleep(0.8)
        m5["bottom2"] = await kbCycle("bottom2", center: false, input: input)
        m5["lift"] = await liftCycle(input: input)
        m5["pads"] = SpikeProbes.pads
        result["keyboard"] = m5
        await open(PerfHarness.convA, name: "A-end", record: false)
    }
}
#endif
