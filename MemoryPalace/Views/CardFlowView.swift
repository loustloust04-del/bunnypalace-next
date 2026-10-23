import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
import SwiftStreamingMarkdown   // Phase 6 article mode 3 处 Markdown 切 fork

#endif

/// 反转列表 modifier（学 Stream Chat SwiftUI `ChatChannelHelpers.swift:7-18`）。
/// rotation + scaleEffect 组合 = 净效果 Y 轴颠倒；走 CALayer transform3D 不影响 subpixel 抗锯齿。
/// ScrollView 整体翻 + 每个 cell 翻回正 + ForEach 数据 reversed →
/// ScrollView offset=0 = 翻转后 = 屏幕底部 = 最新消息（不需要 scrollToLastMessage）。
struct FlippedUpsideDown: ViewModifier {
    func body(content: Content) -> some View {
        content
            .rotationEffect(.radians(Double.pi))
            .scaleEffect(x: -1, y: 1, anchor: .center)
    }
}
extension View {
    func flippedUpsideDown() -> some View { modifier(FlippedUpsideDown()) }
}

#if os(iOS)
/// 反转列表的副作用之一（学 Exyte UIList.swift:63 `tableView.scrollsToTop = false`）：
/// iOS 默认点状态栏 → UIScrollView.scrollsToTop = 滚到物理顶 (0,0) = 翻转后视觉底（最新消息）。
/// 我们要"点状态栏回视觉顶（最旧）" → 必须关掉默认行为，然后挂自己的 tap 区。
/// 顶栏状态岛收 / 展：列表拖动手势的 target（见 StreamScrollAnchor.AnchorView.handleTopBarPan）
final class TopBarPanWatcher: NSObject {
    @objc func handle(_ g: UIPanGestureRecognizer) {
        StreamScrollAnchor.AnchorView.handleTopBarPan(g)
    }
}

struct ScrollsToTopDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isHidden = true
        DispatchQueue.main.async {
            var node: UIView? = v.superview
            while let cur = node {
                if let sv = cur as? UIScrollView { sv.scrollsToTop = false; break }
                node = cur.superview
            }
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// P2.2 补账（research-scroll-drift-fix）：流式离底「拉一节」补偿器。
/// 反转列表把生长中的流式 cell 放在滚动原点侧，cell 长高 ΔH 时历史内容坐标整体平移——
/// 探针实锤 943 次增长零补偿；SwiftUI 层 defaultScrollAnchor(.sizeChanges) 实证无效。
/// 下沉 UIKit：KVO contentSize，离底且幅度像流式生长时同帧 contentOffset += ΔH，视口内容焊死；
/// 在底不补保持跟随吐字；万级巨幅变化 = LazyVStack 估算重排（变化位置未知侧）不补。
struct StreamScrollAnchor: UIViewRepresentable {
    /// 键盘冷弹回底（复现器场景③④）：proxy.scrollTo 对 LazyVStack 远端目标按估算高度跳，
    /// 落点差一大截（711→680 实测挪不动）；反转列表的「底」是绝对坐标 -adjustedContentInset.top，
    /// UIKit 直接 setContentOffset 不依赖内容测量。sv 引用借本补偿器已爬到的通道。
    static func scrollChatToBottom() {
        guard let sv = AnchorView.chatScrollView else { return }
        KBProbe.log(String(format: "scrollChatToBottom(cold) off=%.1f adjTop=%.1f fb=%.1f cs=%.0f bounds=%.0f",
                           sv.contentOffset.y, sv.adjustedContentInset.top,
                           sv.contentOffset.y + sv.adjustedContentInset.top, sv.contentSize.height, sv.bounds.height))
        // 静默补偿器 0.6s：回底动画期垫块 delta 会被当流式生长补偿（offset>200 → +301 抵消
        // 顶起+直接改 offset 打断本动画，log 实锤③停在 666）；动画~0.3s+垫块 KVO 都在窗内
        AnchorView.compensatorMutedUntil = CACurrentMediaTime() + 0.6
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: -sv.adjustedContentInset.top), animated: true)
    }

    /// 视觉顶（最旧消息）的 offset = 物理底。按当前估高算，LazyVStack 边测边修，末端要反复钉才到真顶
    static func oldestOffset(_ sv: UIScrollView) -> CGFloat {
        max(-sv.adjustedContentInset.top, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
    }

    /// 状态栏点一下 → 滚到最旧。不用 proxy.scrollTo(首条)：翻转列表首条在物理最末，精确定位要把全部行测一遍，
    /// 3000 条实测卡 8–9s（plan-chat-scrubber §8）。先动画滑到估算的底，再每 0.1s 钉一次当前最大 offset，
    /// 末端行被测一批、上限前推，几次收敛到真顶；手指碰到就停
    static func scrollChatToOldest() {
        guard let sv = AnchorView.chatScrollView else { return }
        muteCompensator(0.6)
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: oldestOffset(sv)), animated: true)
        settleAtOldest(sv, remaining: 6, delay: 0.45)
    }

    private static func settleAtOldest(_ sv: UIScrollView, remaining: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak sv] in
            guard let sv, remaining > 0, !sv.isTracking, !sv.isDragging, !AnchorView.scrubbing else { return }
            let target = oldestOffset(sv)
            if abs(sv.contentOffset.y - target) > 0.5 { sv.contentOffset.y = target }
            settleAtOldest(sv, remaining: remaining - 1, delay: 0.1)
        }
    }

    /// 垫块 barGrowth 变更前置静默（sol 终审 §3 漏窗：键盘已起后换行不重开静默窗，
    /// 生成中留白 delta 会被当流式生长补掉）。只前推不回拉，与冷弹 0.6s 窗共存取 max。
    static func muteCompensator(_ duration: CFTimeInterval) {
        AnchorView.compensatorMutedUntil = max(AnchorView.compensatorMutedUntil, CACurrentMediaTime() + duration)
    }

    /// 生成中才武装补偿（ThinkingExpandUITests T2 实锤）。
    var armed: Bool = false

    func makeUIView(context: Context) -> UIView {
        let v = AnchorView(frame: .zero)
        v.isHidden = true
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        AnchorView.streamingArmed = armed
    }

    /// 流式跟随控制器（plan-stream-follow-controller）。反转列表铁律：任何 cell 长高 Δ，物理上它下面
    /// （= 视觉上它上面、更老）的内容全被推 Δ。一条规则（§二）：生长点 g < 视口底 → offset += Δ 钉住；
    /// 钉前在底且 Δ 是一行/一段 → 再 glide 回底。信号 = 每个 cell 自报（CellGrowthAnchor），不看 contentSize。
    /// 不变量：生成中 contentOffset 只此一个写手（键盘写手靠 mute 窗互斥，mute 期钉/glide 都停）；
    /// 底每次现读；glide 是唯一动画（display link）；回底只在松手那一刻判。
    final class AnchorView: UIView {
        static weak var chatScrollView: UIScrollView?
        /// 探针（08-26）：offset 单次跳变 >300pt 记调用栈——定位「垫块长高后 offset 少了 ~2000」是谁写的
        private static var jumpObs: NSKeyValueObservation?
        private static func installJumpProbe(_ sv: UIScrollView) {
            #if DEBUG
            jumpObs = sv.observe(\.contentOffset, options: [.old, .new]) { sv, ch in
                // 拖滚动条是有意的大跳（每帧几千 pt），不抓栈（callStackSymbols 很贵，会扭曲测量）
                guard !scrubbing, let o = ch.oldValue?.y, let n = ch.newValue?.y, abs(n - o) > 300 else { return }
                let stack = Thread.callStackSymbols.dropFirst(2).prefix(14)
                    .map { $0.replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression) }
                    .map { String($0.prefix(110)) }
                KBProbe.log(String(format: "⚠️JUMP off %.0f→%.0f cs=%.0f drag=%d\n    %@", o, n, sv.contentSize.height, sv.isDragging ? 1 : 0, stack.joined(separator: "\n    ")))
            }
            #endif
        }
        static var compensatorMutedUntil: CFTimeInterval = 0
        static var streamingArmed = false
        /// 可拖滚动条抓取中（plan-chat-scrubber §2.2）：钉照做保住所看历史，glide / 松手回底 /
        /// 在底判定都让位；只由 beginScrub / endScrub 翻转
        private(set) static var scrubbing = false

        static func beginScrub() {
            scrubbing = true
            stopGlide()
            chatScrollView?.stopScrollingAndZooming()
        }

        /// 放掉所有权：补一次在底判定（捕获期不发）；只有停在最新端（resumeFollow）才在生成中滑回跟随，
        /// 停在历史就留在那条（R2-B02）
        static func endScrub(resumeFollow: Bool) {
            guard scrubbing else { return }
            scrubbing = false
            guard let sv = chatScrollView else { return }
            let fromBottom = sv.contentOffset.y + sv.adjustedContentInset.top
            let atBottom = abs(fromBottom) < 200
            if atBottom != lastAtBottom {
                lastAtBottom = atBottom
                onAtBottomChange?(atBottom)
            }
            guard resumeFollow, streamingArmed, glide == nil, CACurrentMediaTime() >= compensatorMutedUntil,
                  !sv.isTracking, !sv.isDragging, !sv.isDecelerating, fromBottom > 0.5 else { return }
            startGlide(sv)
        }

        /// L2-T3b 回归修复（09-09）：isAtBottom 的 onScrollGeometryChange 判定在首帧同步渲染
        /// 落地后卡死（只翻 0 不回 1，模拟器+真机双实锤；geometry API stuck 记忆卡家族）。
        /// 换 UIKit KVO 直读，语义等价（off + adjustedTop < 200，含 margin 修正——裸 offset
        /// 判定假翻的教训沿用）。closure 由 CardFlowView onAppear 挂，楼层重建时覆盖指向新 State。
        private static var atBottomObs: NSKeyValueObservation?
        private static var lastAtBottom = true
        static var onAtBottomChange: ((Bool) -> Void)?
        /// 顶栏状态岛收 / 展（粟粟 09-28 稿）：挂在列表自己的拖动手势上，只看手指这次拖了多远（窗口坐标，翻转无关）；
        /// 流式补偿、惯性、回弹、键盘写 offset 都不算（真机反馈「不灵敏、有时反着来」后从 contentOffset 改过来）
        static var onTopBarCollapse: ((Bool) -> Void)?
        private static var collapsePan = TopBarCollapse.Pan()
        private static let panWatcher = TopBarPanWatcher()

        /// 本控制器（及借它写 offset 的地方）的写入标记：外来写观察器据此区分（10-03）
        static func withProgrammaticOffset(_ write: () -> Void) { writing = true; write(); writing = false }
        private static var writing = false
        /// SwiftUI 偶尔自己先为 cell 长高挪了 offset（mask 10-03 取证：气泡离底流式 4 次里 2 次，AttributeGraph 更新里
        /// 写 +51，≈1ms 后同一 cell 自报 Δ=51）→ 再钉 = 双补，离底锚点漂 51pt。记最近一次非本控制器、非手势的写，
        /// cellGrew 同帧见到等量的就当已钉
        private static var foreignShift: (dy: CGFloat, t: CFTimeInterval)?
        private static var foreignObs: NSKeyValueObservation?
        private static func installForeignWatch(_ sv: UIScrollView) {
            foreignObs = sv.observe(\.contentOffset, options: [.old, .new]) { sv, ch in
                guard !writing, !scrubbing, !sv.isTracking, !sv.isDragging, !sv.isDecelerating,
                      let o = ch.oldValue?.y, let n = ch.newValue?.y, abs(n - o) > 0.5 else { return }
                foreignShift = (n - o, CACurrentMediaTime())
            }
        }

        private static func installCollapseWatch(_ sv: UIScrollView) {
            sv.panGestureRecognizer.removeTarget(panWatcher, action: nil)
            sv.panGestureRecognizer.addTarget(panWatcher, action: #selector(TopBarPanWatcher.handle(_:)))
        }

        fileprivate static func handleTopBarPan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                collapsePan.began()
            case .changed:
                let before = collapsePan.collapsed
                collapsePan.changed(fingerUp: -g.translation(in: nil).y)
                if collapsePan.collapsed != before { onTopBarCollapse?(collapsePan.collapsed) }
            default:
                break
            }
        }

        /// 点药丸展开 / 切对话：判定状态跟着回到展开
        static func resetTopBarCollapse() { collapsePan.expand() }

        private static func installAtBottomWatch(_ sv: UIScrollView) {
            atBottomObs = sv.observe(\.contentOffset, options: [.new]) { sv, _ in
                guard !scrubbing else { return }
                let atBottom = abs(sv.contentOffset.y + sv.adjustedContentInset.top) < 200
                guard atBottom != lastAtBottom else { return }
                #if DEBUG
                KBProbe.log(String(format: "[ABOT] flip off=%.0f adjTop=%.0f → %d",
                                   sv.contentOffset.y, sv.adjustedContentInset.top, atBottom ? 1 : 0))
                #endif
                lastAtBottom = atBottom
                DispatchQueue.main.async { onAtBottomChange?(atBottom) }
            }
        }

        #if (DEBUG || PERF_BENCH) && os(iOS)
        /// 测量探针（perf P0 §5.1）：强持有，注册表只 weak；非严格测量角色恒 nil
        var perfProbe: SwiftUIChatListProbe?
        #endif

        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if PerfHarness.strictMeasure { perfProbeMoved() }
            #endif
            // 09-09：guard 原为「chatScrollView 非 nil 即不再爬」——列表重建换 UIScrollView 后
            // 观察器仍盯旧实例（isAtBottom 回底不翻 1 的根因链之一）。改为跟随最新 sv 重装。
            guard window != nil else { return }
            var node: UIView? = superview
            while let cur = node {
                if let sv = cur as? UIScrollView {
                    if Self.chatScrollView !== sv {
                        Self.installJumpProbe(sv)
                        Self.installAtBottomWatch(sv)
                        Self.installForeignWatch(sv)
                        Self.installCollapseWatch(sv)
                        Self.chatScrollView = sv
                        #if (DEBUG || PERF_BENCH) && os(iOS)
                        if AirPerfProbe.enabled { AirPerfProbe.shared.attachChatScroll(sv) }
                        #endif
                        ChatScrubberModel.shared.attach(sv)
                    }
                    break
                }
                node = cur.superview
            }
        }

        /// 某 cell 长高 Δ（rect = 变化后的物理 rect，content 坐标）
        static func cellGrew(delta: CGFloat, rect: CGRect, isStreamingCell: Bool) {
            guard let sv = chatScrollView else { return }
            // 幅度阈值 300（08-26 P0，plan-keyboard-single-truth）：节拍器后真实 cell 生长最大一段 ≈60；
            // 发送时探针实测 Δ=1222/519 是新气泡插入+折叠重算的整表重排，照补 = 视口被推走 289pt（Bug3）
            // 流式泡自己的生长不设上限（10-03，bug-bubble-stream-follow-drift）：气泡模式按段整块弹出，
            // 一段 Δ=578/906 是真实内容；丢掉 = 离底时锚点被整段推走
            guard abs(delta) <= 300 || isStreamingCell else {
                KBProbe.log(String(format: "pin drop huge Δ=%.0f", delta))
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure { PerfChatV1.noteGrowth(delta: delta, branch: "dropHuge", fromBottom: sv.contentOffset.y + sv.adjustedContentInset.top, streaming: isStreamingCell) }
                #endif
                return
            }
            let bottom = -sv.adjustedContentInset.top
            // SwiftUI 已为这次生长挪过 offset：按挪之前的位置判，只是不再写
            let alreadyPinned = foreignShift.map { CACurrentMediaTime() - $0.t < 0.05 && abs($0.dy - delta) < 0.5 } ?? false
            if alreadyPinned { foreignShift = nil }
            let o = sv.contentOffset.y - (alreadyPinned ? delta : 0)
            let H = sv.bounds.height
            let fromBottom = o - bottom
            let g = rect.minY + (rect.height - delta)      // 变化前物理底边 = 生长点
            let moving = sv.isTracking || sv.isDragging || sv.isDecelerating
            let muted = CACurrentMediaTime() < compensatorMutedUntil
            if muted {
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure { PerfChatV1.noteGrowth(delta: delta, branch: "muted", fromBottom: fromBottom, streaming: isStreamingCell) }
                #endif
                return
            }
            // 推的全在视口外更老处：不动
            if g >= o + H {
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure { PerfChatV1.noteGrowth(delta: delta, branch: "outsideOlder", fromBottom: fromBottom, streaming: isStreamingCell) }
                #endif
                return
            }
            let wasAtBottom = fromBottom <= 12
            KBProbe.log(String(format: "pin Δ=%.0f fb=%.0f s=%d mov=%d", delta, fromBottom, isStreamingCell ? 1 : 0, moving ? 1 : 0))
            if !alreadyPinned { withProgrammaticOffset { sv.contentOffset.y = max(bottom, o + delta) } }
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if PerfHarness.strictMeasure {
                if !alreadyPinned { PerfChatV1.notePin() }   // perf P0 §6.5：深翻报钉位次数
                PerfChatV1.noteGrowth(delta: delta, branch: alreadyPinned ? "pinnedBySwiftUI" : "pinned", fromBottom: fromBottom, streaming: isStreamingCell)
            }
            #endif
            // 在底 + 一行/一段级生长 → 滑入回底（跟随）；离底 / 大幅展开收起 → 只钉。
            // 流式泡不限幅：气泡模式一段 Δ=139/179 只钉不滑 = 离底一段，之后每次都「离底只钉」，跟随永久断（10-03）
            if (wasAtBottom || glide != nil), delta > 0, delta <= 120 || isStreamingCell, !moving, !scrubbing {
                startGlide(sv)
            }
        }

        /// 手指松开 / 惯性停住那一刻判一次（节拍器轮询边沿触发）：落在底半屏内 → 回底跟随。
        private static var wasMoving = false
        static func pollScrollSettled() {
            guard let sv = chatScrollView else { return }
            let moving = sv.isTracking || sv.isDragging || sv.isDecelerating
            defer { wasMoving = moving }
            guard wasMoving, !moving, streamingArmed, glide == nil, !scrubbing else { return }
            guard CACurrentMediaTime() >= compensatorMutedUntil else { return }
            let fromBottom = sv.contentOffset.y + sv.adjustedContentInset.top
            guard fromBottom > 0.5, fromBottom < sv.bounds.height / 2 else { return }
            startGlide(sv)
        }

        // MARK: 回底滑入（display link 逐帧推；底每帧现读；静默/触摸即停）
        private static var glide: CADisplayLink?
        private static var glideLast: CFTimeInterval = 0
        private static weak var glideScrollView: UIScrollView?

        private static func startGlide(_ sv: UIScrollView) {
            glideScrollView = sv
            guard glide == nil else { return }
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if PerfHarness.strictMeasure { PerfChatV1.noteGlide() }   // perf P0 §6.5：深翻报滑入次数
            #endif
            glideLast = CACurrentMediaTime()
            let link = CADisplayLink(target: GlideTarget.shared, selector: #selector(GlideTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            glide = link
        }

        fileprivate static func glideTick(_ link: CADisplayLink) {
            guard let sv = glideScrollView else { stopGlide(); return }
            if sv.isTracking || sv.isDragging || sv.isDecelerating || scrubbing { stopGlide(); return }
            if CACurrentMediaTime() < compensatorMutedUntil { stopGlide(); return }
            let bottom = -sv.adjustedContentInset.top
            let now = link.timestamp
            let dt = max(0, now - glideLast)
            glideLast = now
            let remaining = sv.contentOffset.y - bottom
            if remaining <= 0.5 {
                withProgrammaticOffset { sv.contentOffset.y = bottom }
                stopGlide()
                return
            }
            let step = max(1, remaining * (1 - exp(-dt / 0.08)))
            withProgrammaticOffset { sv.contentOffset.y = max(bottom, sv.contentOffset.y - step) }
        }

        private static func stopGlide() {
            glide?.invalidate()
            glide = nil
        }

        private final class GlideTarget: NSObject {
            static let shared = GlideTarget()
            @objc func tick(_ link: CADisplayLink) { AnchorView.glideTick(link) }
        }
    }
}

/// 每个 BubbleView 背景里的高度标记：自己的 bounds 高度变化 = 该 cell 精确长高量（LazyVStack 别的 cell
/// 估算跟它无关）。挂载后 300ms 内的变化丢掉（新建 cell 首次测量修正 = 估算噪声进门的那扇门）。
struct CellGrowthAnchor: UIViewRepresentable {
    let isStreamingCell: Bool
    #if (DEBUG || PERF_BENCH) && os(iOS)
    /// 测量探针按行取 window rect（perf P0 §5.1）；只在严格测量角色下登记
    var perfNodeId = ""
    #endif
    func makeUIView(context: Context) -> CellView {
        let v = CellView(frame: .zero)
        v.isHidden = true
        v.isUserInteractionEnabled = false
        v.isStreamingCell = isStreamingCell
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { v.perfNodeId = perfNodeId }
        #endif
        return v
    }
    func updateUIView(_ uiView: CellView, context: Context) {
        uiView.isStreamingCell = isStreamingCell
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure, uiView.perfNodeId != perfNodeId {
            uiView.perfNodeId = perfNodeId
            PerfRowRegistry.moved(uiView, id: perfNodeId)
        }
        #endif
    }

    final class CellView: UIView {
        var isStreamingCell = false
        #if (DEBUG || PERF_BENCH) && os(iOS)
        var perfNodeId = ""
        #endif
        private var lastHeight: CGFloat?
        private var mountedAt: CFTimeInterval = 0
        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if PerfHarness.strictMeasure { PerfRowRegistry.moved(self, id: perfNodeId) }
            #endif
            if window != nil { mountedAt = CACurrentMediaTime(); lastHeight = bounds.height }
        }
        override var frame: CGRect { didSet { report() } }
        override var bounds: CGRect { didSet { report() } }
        private func report() {
            let h = bounds.height
            guard let last = lastHeight else { lastHeight = h; return }
            let d = h - last
            guard abs(d) > 0.5 else { return }
            lastHeight = h
            guard window != nil, let sv = StreamScrollAnchor.AnchorView.chatScrollView else {
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure { PerfChatV1.noteGrowth(delta: d, branch: window == nil ? "noWindow" : "noScrollView", fromBottom: nil, streaming: isStreamingCell) }
                #endif
                return
            }
            guard CACurrentMediaTime() - mountedAt > 0.3 else {
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure { PerfChatV1.noteGrowth(delta: d, branch: "mountGuard", fromBottom: sv.contentOffset.y + sv.adjustedContentInset.top, streaming: isStreamingCell) }
                #endif
                return
            }
            // 物理 rect（content 坐标）：layer convert 吃到 SwiftUI 的 180° 翻转变换
            let rect = layer.convert(layer.bounds, to: sv.layer)
            StreamScrollAnchor.AnchorView.cellGrew(delta: d, rect: rect, isStreamingCell: isStreamingCell)
        }
    }
}
#endif

struct CardFlowView: View {
    @Environment(\.chatMetrics) private var metrics
    /// mac 全屏模式下正文装在卡里：卡自己画了底（可能带壁纸），卡内就不再各画一层
    @Environment(\.macChatCarded) private var macChatCarded
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    // globalWBManager 通过 ContentView 同步到 viewModel.globalWorldBookEntries
    @AppStorage("blurRadius") private var blurRadius = 1.3
    @AppStorage("bubbleSpacing") private var bubbleSpacing: Double = 31
    @AppStorage("gardenSceneEnabled") private var gardenSceneEnabled = true
    /// pop-tuner：行级弹入只在气泡模式（文章模式粟粟拍了不弹）
    @AppStorage("chatBubbleMode") private var chatBubbleMode = false
    /// 「隐藏时间戳」现在管列表中间的时间分割线（TASK page1-消息-20）
    @AppStorage("hideTimestamp") private var hideTimestamp: Bool = false
    #if os(iOS)
    /// 键盘避让值（外层 PagingViewController 单一信源经桥发布）：并入列表视觉底 margin +
    /// 键盘期间隐藏回底按钮。见 research-keyboard-list-inset.md
    @ObservedObject private var keyboardBridge = KeyboardInsetBridge.shared
    /// 回底钮 / 查找上下钮锚、查找列表底边用的全局 minY（只要 minY：GeometryReader 闭包里直读 .global 会在任何全局位置变化（含翻页的水平平移、layerSync）时整段重跑；onGeometryChange 去重，minY 不变不触发（plan-paging-decouple A-7，同 Page2HomeView 顶栏））
    @State private var overlayGlobalMinY: CGFloat = 0
    @State private var findListGlobalMinY: CGFloat = 0
    #endif
    @FocusState private var inConvSearchFocused: Bool
    // B2：showStickerPanel→stickerVM / selectedAttachments→viewModel（跨容器共享）
    // Only message/sticker lifecycle belongs to the transcript; mac drafts live in MacChatComposerHost.
    @State private var loadedConv: Conversation?
    // iOS 下 PinBar 已挪到 ContentView.iOSChatTopBar，state 同步搬走。
    @State private var isAtBottom: Bool = true
    #if os(macOS)
    /// 拖文件上传（plan-mac-code-mode-gaps §6）：正文层 / 外层（输入条）各一个 isTargeted
    @State private var fileDropTargeted = false
    @State private var fileDropTargetedOuter = false
    @State private var fileDropError: String?
    #endif
    /// 聊天 ScrollView 视口高（气泡渐变整屏锚定用，见 UserBubbleFill）；0 = 还没量到
    @State private var chatViewportHeight: CGFloat = 0
    /// 在上面翻历史时来了新回复/生成完成 → 回底按钮亮徽章；回到底自动熄灭
    @State private var hasUnseenReply = false

    /// 深翻抑制解除判定（§4f）：键盘可见 + 垫块被抑制 + 手不在屏上 + 离底 < returnToBottomScreens 屏
    private func maybeLiftPadSuppression() {
        #if os(iOS)
        guard keyboardBridge.padSuppressed, keyboardBridge.kbVisible, !StreamScrollAnchor.AnchorView.scrubbing,
              let sv = StreamScrollAnchor.AnchorView.chatScrollView, !sv.isTracking, !sv.isDragging else { return }
        let dist = sv.contentOffset.y + sv.adjustedContentInset.top
        guard dist < sv.bounds.height * KeyboardInsetBridge.returnToBottomScreens else { return }
        KBProbe.log(String(format: "near bottom (dist=%.0f) with suppressed pad → lift", dist))
        keyboardBridge.liftPadSuppression?()
        #endif
    }
    #if os(iOS)
    /// 语音通话页（plan-voice-note M6）：入口是 + 号条的 📞，面板和输入条的共同上级持有
    @State private var showCallScreen = false
    /// Telegram 式长按浮层会话（marker 经 environment 拿到它发会话）
    @StateObject private var bubbleMenuModel = BubbleMenuOverlayModel()
    #endif

    #if (DEBUG || PERF_BENCH) && os(iOS)
    /// 声明遮挡带（§4.4-3、§14-3）：视觉底 = contentMargins.top 100 + LazyVStack 竖向 padding；
    /// 视觉顶 = contentMargins.bottom 150 + 同一 padding；键盘垫块 = 上方 Color.clear 的高
    private func perfNoteApplied() {
        PerfRenderLedger.noteApplied(
            revision: viewModel.perfPathRevision, path: viewModel.currentPath,
            profileId: profileManager?.currentProfile.id, conversationId: viewModel.selectedConversation?.id,
            occlusionBottom: 100 + metrics.listInsetV, occlusionTop: 150 + metrics.listInsetV,
            keyboardPad: max(0, keyboardBridge.extra) + max(0, keyboardBridge.barGrowth), spacing: bubbleSpacing)
    }
    #endif

    /// L4 A3：列表内容求值一次的共享显示数据（正则 / 引用索引走纯数据快照，头像在 SwiftUI 侧一并取一次）
    private typealias RowDisplay = (snapshot: ChatDisplaySnapshot, avatars: ChatAvatars)

    private func makeRowDisplay() -> RowDisplay {
        let p = profileManager?.currentProfile
        let snapshot = ChatDisplaySnapshot(
            path: viewModel.currentPath, profile: p,
            preset: p.flatMap { presetManager?.preset(byId: $0.presetId) },
            cards: profileManager?.characterCardManager?.cards ?? [])
        let avatars = p.map {
            ChatAvatars(user: AvatarImageCache.image(for: $0.userAvatarData, key: $0.id + "-user"),
                        assistant: AvatarImageCache.image(for: $0.assistantAvatarData, key: $0.id + "-assistant"))
        } ?? .none
        return (snapshot, avatars)
    }

    @ViewBuilder
    private func makeBubbleView(for node: MessageNode, display: RowDisplay?) -> some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = AirPerfProbe.enabled ? PerfCount.hit("chatRowBody") : ()
        let _ = PerfHarness.noteBubble(node.id)
        #endif
        let info = viewModel.branchInfoMap[node.id]
        // Phase 4 流式重写 Contract 3：用 turn-level VM helper（含 tool 间隙保 true），
        // 不再用 providerRouter.isStreaming（provider 级 + 全局，tool 间隙闪 + 跨对话串扰）
        let convId = viewModel.selectedConversation?.id ?? ""
        let isNodeStreaming = viewModel.isNodeStreaming(nodeId: node.id, conversationId: convId)
            && node.role == "assistant"
        let isNodeHighlighted = viewModel.highlightedNodeId == node.id
        let isNodeSearchMatch = viewModel.inConvMatches.contains(node.id)
        // A4：reply_to 引用预览——按 replyToId 在当前 path 找被引用消息（user 的 id 或 cc 的 ccMessageId）
        let quoted: String? = {
            if let display { return display.snapshot.quotedPreview(for: node) }
            // 选段引用：优先落库的选段文本（她选哪段显示哪段）；老数据回退按 replyToId 找整条截断
            if let rq = node.replyQuote, !rq.isEmpty { return String(rq.prefix(50)) }
            guard let rid = node.replyToId,
                  let target = viewModel.currentPath.first(where: { $0.id == rid || $0.ccMessageId == rid }) else { return nil }
            let t = target.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(50))
        }()
        let avatars: ChatAvatars = {
            if let display { return display.avatars }
            guard let p = profileManager?.currentProfile else { return .none }
            return ChatAvatars(
                user: AvatarImageCache.image(for: p.userAvatarData, key: p.id + "-user"),
                assistant: AvatarImageCache.image(for: p.assistantAvatarData, key: p.id + "-assistant")
            )
        }()
        BubbleView(
            node: node,
            quotedPreview: quoted,
            hasBranches: info != nil,
            branchInfo: info,
            isStreaming: isNodeStreaming,
            viewModel: viewModel,
            isHighlighted: isNodeHighlighted,
            isSearchMatch: isNodeSearchMatch,
            avatars: avatars,
            onToggleFavorite: { viewModel.toggleFavorite(node) },
            onTogglePin: { viewModel.togglePin(node) },
            onSoftDelete: { MessageDust.vanish(key: node.id) { viewModel.softDelete(node) } },   // 散成灰再删（§12）
            onSwitchBranch: { nodeId, idx in viewModel.switchBranch(at: nodeId, to: idx) },
            onRegenerate: makeRegenerateAction(for: node),
            onEdit: makeEditAction(for: node),
            isBeingEdited: viewModel.editingMessage?.nodeId == node.id,
            onQuoteText: { txt in
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                viewModel.startQuotingText(txt, node: node)
            },
            regexScripts: {
                if let display { return display.snapshot.regexScripts }
                // ⑤a：与发送同一解析（全局 → 预设实例 → 绑定卡 / 楼层旧规则），显示阶段在气泡里再按 user / assistant 分流
                guard let profile = profileManager?.currentProfile else { return [] }
                return RegexPipeline.scripts(profile: profile, preset: presetManager?.preset(byId: profile.presetId),
                                             cards: profileManager?.characterCardManager?.cards ?? [])
            }()
        )
        // 对话内查找：只给命中的气泡注入词（没命中的恒为空，词变了不牵动它们）
        .environment(\.chatSearchTerms, viewModel.inConvHitIds.contains(node.id) ? viewModel.inConvTerms : [])
    }

    /// 多选气泡的行修饰（research-multi-select-bubbles §9-3）
    private func selectionRow(for node: MessageNode) -> ChatSelectionRow {
        let selectable = !isStreamingRow(node)
        return ChatSelectionRow(
            selection: viewModel.messageSelection,
            nodeId: node.id,
            isUser: node.role == "user",
            bubbleMode: chatBubbleMode,
            selectable: selectable,
            rowSpacing: bubbleSpacing,
            onTap: { handleSelectionTap(node) },
            onCommandTap: { [viewModel] in
                guard selectable, viewModel.editingMessage == nil else { return }
                viewModel.beginMessageSelection(with: node.id)
            }
        )
    }

    private func isStreamingRow(_ node: MessageNode) -> Bool {
        node.role == "assistant"
            && viewModel.isNodeStreaming(nodeId: node.id, conversationId: viewModel.selectedConversation?.id ?? "")
    }

    /// 多选态点一行：切换选中；mac ⇧ 点 = 从上次点的那条到这条整段选中
    private func handleSelectionTap(_ node: MessageNode) {
        let selection = viewModel.messageSelection
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.shift) {
            selection.extend(to: node.id, in: viewModel.currentPath, selectable: { !isStreamingRow($0) })
            return
        }
        #endif
        selection.toggle(node.id)
    }

    private func makeRegenerateAction(for node: MessageNode) -> (() -> Void)? {
        guard node.role == "assistant" || node.role == "user", let pm = providerManager else { return nil }
        return {
            guard let prof = self.profileManager?.currentProfile else { return }
            let preset = self.presetManager?.preset(byId: prof.presetId) ?? Preset.balanced
            let model = pm.resolveModel(
                conversationModelId: self.viewModel.selectedConversation?.selectedModelId,
                globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
            self.viewModel.selectedConversation?.selectedModelId = model.id
            if node.role == "assistant" {
                self.viewModel.regenerate(assistantNodeId: node.id, model: model, profile: prof, preset: preset, providerManager: pm, context: self.modelContext)
            } else {
                // user 重新生成 = 原文重发建分支（editAndResend 同链，newText=原文）
                self.viewModel.editAndResend(node.id, newText: node.content, model: model, profile: prof, preset: preset, providerManager: pm, context: self.modelContext)
            }
        }
    }

    private func makeEditAction(for node: MessageNode) -> (() -> Void)? {
        guard node.role == "user", providerManager != nil else { return nil }
        return { self.viewModel.beginEditing(node) }
    }

    /// 回底钮：两端同一颗 `ScrollToBottomButton` + 同一个回底动作，只差锚（面 2.2）——
    /// mac 固定 16/16；iOS 锚输入字段真实顶边上方 8pt（键盘桥双分量），键盘期间隐。
    @ViewBuilder
    private func scrollToBottomOverlay(proxy: ScrollViewProxy) -> some View {
        #if os(macOS)
        scrollToBottomButton(proxy: proxy, isVisible: !isAtBottom && !viewModel.currentPath.isEmpty)
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        #else
        GeometryReader { geo in
            // 按钮常驻（只用锚定位），显隐交给 ScrollToBottomButton 自己的
            // isVisible 内部动画。锚 = containerTop（UIKit KVO 发布，容器分量）
            // + fieldOffsetInBar（ChatInputBar 白盒自报，字段在栈内偏移）——
            // sol 终审 §1：容器顶≠字段顶（差 6~88pt 随 chip 浮动），必须双分量合成。
            // containerTop 未就绪(<=0)时退默认 108。
            let fieldTop = keyboardBridge.containerTop + keyboardBridge.fieldOffsetInBar
            let globalMinY = overlayGlobalMinY
            let rawInset = geo.size.height - (fieldTop - globalMinY) + 8
            let bottomInset = keyboardBridge.containerTop > 0 ? max(rawInset, 8) : 108
            // 对话内查找：输入栏换成了面板，锚直接用面板顶（containerTop），不加字段偏移
            let panelInset = keyboardBridge.containerTop > 0
                ? max(geo.size.height - (keyboardBridge.containerTop - globalMinY) + 8, 8) : 108
            let searching = viewModel.inConvSearchActive
            ZStack(alignment: .bottomTrailing) {
                scrollToBottomButton(
                    proxy: proxy,
                    // 键盘期间隐藏（粟粟点名）；数据源=桥（单一键盘信源）。
                    // kbTransitioning：收键盘动画开始时 extra 已清零，不加过渡门
                    // 按钮会提前露头压在未落稳的输入条上（sol 终审 §3）
                    isVisible: !searching && !isAtBottom && !viewModel.currentPath.isEmpty
                        && keyboardBridge.extra == 0 && !keyboardBridge.kbTransitioning
                )
                .padding(.trailing, 16)
                // 多选：输入栏换成了操作栏，字段偏移是旧值，锚同查找面板（容器顶）
                .padding(.bottom, viewModel.messageSelection.isActive ? panelInset : bottomInset)
                // 查找上下钮：键盘开着也显示（面板贴在键盘上），只在键盘过渡中先藏
                ChatFindNavButtons(
                    isVisible: searching && !viewModel.inConvHits.isEmpty && !viewModel.inConvListMode
                        && !keyboardBridge.kbTransitioning,
                    canGoOlder: (viewModel.inConvHitCursor ?? 0) > 0,
                    onOlder: { viewModel.stepInConvHitOlder() },
                    onNewer: {
                        if !viewModel.stepInConvHitNewer(), let lastId = viewModel.currentPath.last?.id {
                            withAnimation { proxy.scrollTo(lastId, anchor: .top) }
                        }
                    }
                )
                .padding(.trailing, 14)
                .padding(.bottom, panelInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { overlayGlobalMinY = $0 }
        #endif
    }

    #if os(iOS)
    /// 可拖滚动条（plan-chat-scrubber）：iPhone 专用，贴右缘、翻转层外
    @ViewBuilder
    private func chatScrubberOverlay() -> some View {
        if ChatScrubberModel.isEnabledDevice {
            let enabled = !stickerVM.isEditingStickers && !viewModel.inConvSearchActive
                && !viewModel.messageSelection.isActive
                && bubbleMenuModel.session == nil && !viewModel.isLoading
                && !keyboardBridge.kbVisible && !keyboardBridge.kbTransitioning
            ChatScrubber(
                path: viewModel.currentPath,
                conversationId: viewModel.selectedConversation?.id ?? "",
                enabled: enabled
            )
        }
    }

    /// 对话内查找的列表模式：盖在聊天区上，底边让到面板顶（同上下钮的锚）
    @ViewBuilder
    private var findListOverlay: some View {
        if viewModel.inConvSearchActive, viewModel.inConvListMode {
            GeometryReader { geo in
                let panelInset = keyboardBridge.containerTop > 0
                    ? max(geo.size.height - (keyboardBridge.containerTop - findListGlobalMinY) + 8, 8) : 108
                ChatFindListView(
                    hits: viewModel.inConvHits,
                    terms: viewModel.inConvTerms,
                    avatars: {
                        guard let p = profileManager?.currentProfile else { return .none }
                        return ChatAvatars(
                            user: AvatarImageCache.image(for: p.userAvatarData, key: p.id + "-user"),
                            assistant: AvatarImageCache.image(for: p.assistantAvatarData, key: p.id + "-assistant")
                        )
                    }(),
                    bottomInset: panelInset,
                    onSelect: { index in
                        viewModel.inConvListMode = false
                        viewModel.jumpToInConvHit(index)
                    }
                )
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { findListGlobalMinY = $0 }
            .transition(.opacity)
        }
    }
    #endif

    private func scrollToBottomButton(proxy: ScrollViewProxy, isVisible: Bool) -> some View {
        ScrollToBottomButton(
            isVisible: isVisible,
            isGenerating: viewModel.assistantTurnInFlight,
            hasNewReply: hasUnseenReply,
            action: {
                // 反转后 .top = 视觉底（用哨兵也行，但 lastId 语义更直观）
                if let lastId = viewModel.currentPath.last?.id {
                    withAnimation { proxy.scrollTo(lastId, anchor: .top) }
                }
                hasUnseenReply = false
            }
        )
    }

    var body: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = PerfCount.hit("cardFlowBody")
        #endif
        #if DEBUG
        let _ = {
            PerfCounters.cardFlowBody += 1
            let line = String(format: "[PERF] CardFlowView.body #%d t=%.3f", PerfCounters.cardFlowBody, CFAbsoluteTimeGetCurrent())
            print(line)
            KBProbe.log(line)   // 落盘：input-jank T0 基线（每键几次整页 body）
        }()
        #endif
        if viewModel.isLoading {
            VStack {
                Spacer()
                ProgressView("加载中...")
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            .background(macChatCarded ? Color.clear : Theme.mainBg)
            #endif
            // iOS 下路线 C chat page 有 wallpaper，loading 区透明让 wallpaper 可见
        } else {
            VStack(spacing: 0) {
                #if os(macOS)
                // In-conversation search bar（iOS 走顶栏搜索栏 + 底部面板）
                if viewModel.inConvSearchActive {
                    InConversationSearchBar(
                        viewModel: viewModel,
                        focused: $inConvSearchFocused,
                        onDismiss: { viewModel.endInConvSearch() }
                    )
                }
                #endif

                ScrollViewReader { proxy in
                    ScrollView {
                        // 方案 2 v2：恢复 ZStack sibling 结构（之前 .overlay() 把 sticker overlay
                        // frame 锁定到 LazyVStack 大小，sticker 拖到 LazyVStack 之外就接不到 touch）。
                        // StickerCanvasLayer 自己声明 minHeight = max sticker maxY + buffer，让
                        // ZStack 自然 layout 时 height = max(LazyVStack.h, sticker overlay 声明 h)，
                        // 保证 overlay 永远覆盖所有 sticker 实际位置。
                        // 详见 docs/plan-sticker-pan-relationship-fix-2026-04-25.md 方案 2 v2。
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                            #if os(iOS)
                            // 键盘列表避让·垫块法（research-keyboard-list-inset v3 终版）：物理顶（视觉底）
                            // 插键盘高垫块——content 内变化不动 ScrollView 修饰链（margin 动态变化会把
                            // safeAreaInset 输入框打回键盘后，消融实验实锤）。⚠️ 必须在 LazyVStack 外
                            // （非 lazy 的 VStack）：lazy 窗口外的 child 高度变化不被重测，翻远时键盘起
                            // 垫块不生效（复现器场景③实锤 marker 停无垫位置）。在底者内容被自然顶起；
                            // 离底者由 onChange(extra) 冷弹回底（UIKit 绝对 offset）。
                            // + barGrowth：输入条超出 compact 单行的增量（chip/引用/多行，ChatInputBar
                            // 白盒自报）——B2 后列表不再吃 safeAreaInset，多行/附件必须由垫块推高
                            // 否则输入条盖列表尾（sol 终审 §2：固定 margin 100 是留白预算不是输入条高，
                            // 不能当基线做差）。growth 变更不挂动画（旧版 inset 即时推等价），动画 value
                            // 仍只绑 extra。
                            // 垫块瞬变零动画（SwiftUI 动画路线判死：逐帧改高度=每帧全列表重排，
                            // 真机长对话跟不满帧率=正文慢半拍+cell 参差「乱动」，模拟器 22 条简单
                            // 消息假绿——2026-08-16 三轮真机取证）。正文平移动画由 UIKit 滚动层
                            // 承担：PagingVC 垫块瞬变同帧 offset 补偿焊死画面 + 键盘真实曲线
                            // UIView.animate 滚回（补偿器同款技法，GPU 平移绝对整体）。
                            Color.clear.frame(height: max(0, keyboardBridge.extra) + max(0, keyboardBridge.barGrowth))
                            #endif
                            LazyVStack(spacing: bubbleSpacing) {
                                // 审批卡（粟粟 10-03）：AI 要跑命令 / 调要授权的工具时垫底显示，不弹窗
                                if let request = PermissionPromptCenter.shared.pendingRequest, request.inline,
                                   request.approval?.conversationId == viewModel.selectedConversation?.id {
                                    ApprovalCardView(request: request)
                                        .id(request.id)
                                        .flippedUpsideDown()
                                }
                                // 进度卡（粟粟 10-03）：API 模型连调工具时在审批卡上面；读 VM 都在 Host 里
                                if let cid = viewModel.selectedConversation?.id {
                                    TurnActivityHost(viewModel: viewModel, conversationId: cid,
                                                     onStop: { viewModel.cancelAssistantTurn(context: modelContext) })
                                        .flippedUpsideDown()
                                }
                                // CC 等待泡（收口即发）：该对话发出未回时垫底显示。
                                // 反转列表：物理最前 = 视觉最底，所以放 ForEach 前面。
                                // 进度卡 B（粟粟 10-03）：hub 推了 CC 状态就出状态卡（干活中 / 等你 / 做完了），没有就照旧三个点
                                if let cid = viewModel.selectedConversation?.id {
                                    CCPhaseHost(conversationId: cid, waitingForReply: viewModel.ccWaitingSince[cid] != nil)
                                        .flippedUpsideDown()
                                }
                                #if (DEBUG || PERF_BENCH) && os(iOS)
                                let _ = AirPerfProbe.enabled ? AirPerfProbe.shared.noteList(
                                    conversationID: viewModel.selectedConversation?.id,
                                    count: viewModel.currentPath.count, bubble: chatBubbleMode) : ()
                                // 渲染账本 applied（perf P0 §5.2）：只登记本 body 已读的值 + @ObservationIgnored 的 revision
                                let _ = PerfHarness.strictMeasure ? perfNoteApplied() : ()
                                #endif
                                // L4 A3：开关开时整列表求值一次，行闭包共用
                                let rowDisplay = ChatPerfSwitch.a3 ? makeRowDisplay() : nil
                                // 反转列表：ForEach 倒序（最新在前 = 物理顶 = 翻转后视觉底）+ 每个 cell 翻回正
                                // 时间分割线（TASK page1-消息-20）：隔 3 小时以上 / 第一条，那条消息顶上出；「隐藏时间戳」关掉它
                                #if (DEBUG || PERF_BENCH) && os(iOS)
                                let dividers = hideTimestamp ? [:] : (AirPerfProbe.enabled
                                    ? AirPerfProbe.measure("dividerBuild") {
                                        viewModel.timeDividerCache.dividers(for: viewModel.currentPath)
                                    }
                                    : viewModel.timeDividerCache.dividers(for: viewModel.currentPath))
                                #else
                                let dividers = hideTimestamp ? [:] : viewModel.timeDividerCache.dividers(for: viewModel.currentPath)
                                #endif
                                ForEach(viewModel.currentPath.reversed(), id: \.id) { node in
                                    VStack(spacing: 0) {
                                        if let time = dividers[node.id] { ChatTimeDividerView(date: time, spacing: bubbleSpacing) }
                                        makeBubbleView(for: node, display: rowDisplay)
                                            // 多选气泡：行只读「是否在多选」，选中与否只有勾选圆 / 选中底两个叶子读
                                            .modifier(selectionRow(for: node))
                                    }
                                        .id(node.id)
                                        // pop-tuner v7：行级不再弹整行（头像+昵称+泡一起弹=视觉过重，
                                        // 调音台与真实差距主因）——弹泡下沉 BubbleModeRow 内（popPending），
                                        // 头像/昵称直出只有泡弹，与调音台预览同形态。
                                        // v6 对称反转保留：默认事务=push 柔和（旧行让位在容器层结算），
                                        // 白名单新泡行升级 popAnimation（行内泡的 transition 插值用它）
                                        .transaction { t in
                                            if t.animation != nil, viewModel.popNodeIds.contains(node.id) {
                                                t.animation = BubblePopTuning.popAnimation
                                            }
                                        }
                                        .background(
                                            GeometryReader { geo in
                                                Color.clear.task(id: geo.frame(in: .named("scrollContent")).midY) {
                                                    stickerVM.bubblePositions[node.id] = geo.frame(in: .named("scrollContent")).midY
                                                    #if os(iOS)
                                                    let f = geo.frame(in: .named("scrollContent"))
                                                    ChatScrubberModel.shared.rowFrames[node.id] = f.minY...f.maxY
                                                    #endif
                                                }
                                            }
                                        )
                                        .flippedUpsideDown()  // 反转列表：cell 翻回正
                                        #if os(iOS)
                                        // 可拖滚动条抓点：只在已实化行里找视口中心那条
                                        .modifier(ChatScrubberRowTracker(id: node.id))
                                        // 删除散成灰：截这一行用的锚点（§12）
                                        .background(MessageDustAnchor(key: node.id))
                                        #endif
                                }
                            }
                            // pop-tuner v3：旧行推移用无冲劲柔和 spring（popAnimation 的 initialVelocity
                            // 会把倒数第二条"甩"出去=粟粟报的干扰，新泡的爆发绑在 transition 自身）；
                            // 门=白名单非空，打开对话首帧集合为空天然关死
                            .animation(
                                chatBubbleMode && !viewModel.popNodeIds.isEmpty ? BubblePopTuning.pushAnimation : nil,
                                value: viewModel.currentPath.count
                            )
                            .padding(.horizontal, metrics.listInsetH)
                            .padding(.vertical, metrics.listInsetV)
                            .frame(maxWidth: Theme.contentMaxWidth)
                            .frame(maxWidth: .infinity)
                            }

                            StickerCanvasLayer(
                                stickerVM: stickerVM,
                                profileId: profileManager?.currentProfile.id ?? ""
                            )
                        }
                        .coordinateSpace(name: "scrollContent")
                        #if os(macOS)
                        // 拖文件 = 上传成附件（plan-mac-code-mode-gaps §6）。挂在贴纸 drop 里面一层：Finder 拖文件
                        // 可能也带纯文字，让贴纸那层先接到会吞掉；贴纸拖动不带 fileURL，照旧穿到下面那层
                        .onDrop(of: FileDrop.types, isTargeted: $fileDropTargeted, perform: acceptFileDrop)
                        #endif
                        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers, location in
                            handleStickerDrop(providers: providers, location: location)
                        }
                        #if os(iOS)
                        // 反转列表副作用：点状态栏默认会滚到物理顶 = 视觉底，要关。
                        // 状态栏 tap 区由下面 .overlay(alignment: .top) 区自己接管。
                        .background(ScrollsToTopDisabler().frame(width: 0, height: 0))
                        // P2.2 补账：流式离底防推补偿器（research-scroll-drift-fix）
                        .background(StreamScrollAnchor(armed: viewModel.assistantTurnInFlight).frame(width: 0, height: 0))
                        .background {
                            ChatContentEdgeBlur(
                                radius: blurRadius,
                                inputBarBottom: keyboardBridge.containerTop + keyboardBridge.barVisibleHeight,
                                keyboardVisible: keyboardBridge.kbVisible,
                                enabled: !viewModel.currentPath.isEmpty && !stickerVM.isEditingStickers
                            )
                            .frame(width: 0, height: 0)
                        }
                        #endif
                    }
                    // 气泡渐变（plan-bubble-gradient）：量 ScrollView 自己的高给 UserBubbleFill 铺整屏渐变
                    //（visualEffect 里 bounds(of: .scrollView) 拿不到，实测 nil）。键盘期量到的矮值不跟（feedback_keyboard_shrinks_measuring_layer）。
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        #if os(iOS)
                        if keyboardBridge.kbVisible && height < chatViewportHeight { return }
                        #endif
                        if height > 0 && height != chatViewportHeight { chatViewportHeight = height }
                    }
                    .environment(\.chatViewportHeight, chatViewportHeight > 0 ? chatViewportHeight : nil)
                    .flippedUpsideDown()  // 反转列表：ScrollView 整体翻
                    .clipped()            // 学 Stream：翻转后子 view frame 可能溢出 bounds
                    // 平台修饰链一处（面 5.1）：iOS = 安全区 / 边距 / 边缘遮罩 → 状态栏 tap → KVO 到底判定 → 键盘收放 / 冷弹 / 回底钮；
                    // mac = 底色 / 回底钮 → geometry 到底判定。共享段（翻页垫块 / 花园底 / path 变化 / 禁滚）在门后，两端一份。
                    // 反转列表：offset≈0 = 物理顶 = 视觉底 = 在最新消息。
                    // iOS 走 AnchorView 的 UIKit KVO（T3b 后 onScrollGeometryChange 卡死，回归修复
                    // 见 AnchorView.installAtBottomWatch）；macOS 无 AnchorView 保留 geometry 版。
                    #if os(iOS)
                    // 消息视口覆盖上下安全区，内容滤镜与 alpha mask 才能连续处理边缘。
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                    // contentMargins.top = 物理顶 = 反转后视觉底 = 最新消息位置；留 100pt 给输入框避免最新消息被挡（保守值含 home indicator + 输入框 + chip 行余量）
                    // + 键盘避让 extra（外层单一信源经桥同步，见 research-keyboard-list-inset）——
                    // 实验证实 SwiftUI 把 margin 落成底层 contentInset，这是布局正道；
                    // 上一刀炸因=自起第二个键盘 observer 抢时序，非 margin 机制本身
                    .contentMargins(.top, 100, for: .scrollContent)
                    // contentMargins.bottom = 物理底 = 反转后视觉顶 = 给 nav/blur 区留空间
                    // （150：顶部玻璃胶囊行压到 ~144pt，50 会让翻到顶的消息被挡——粟粟真机两轮定稿，两模式统一）
                    .contentMargins(.bottom, 150, for: .scrollContent)
                    // + iPhone 系统竖条换成自绘 ChatScrubber（plan-chat-scrubber）；iPad 保持系统条
                    .modifier(ChatListScrollChrome())
                    .compositingGroup()
                    .mask {
                        ChatEdgeFadeMask(
                            enabled: !viewModel.currentPath.isEmpty && !stickerVM.isEditingStickers,
                            inputFieldTop: keyboardBridge.inputFieldTop,
                            inputBarBottom: keyboardBridge.containerTop + keyboardBridge.barVisibleHeight,
                            keyboardVisible: keyboardBridge.kbVisible,
                            hasInputGeometry: keyboardBridge.containerTop > 0
                        )
                    }
                    // 状态栏 tap → 滚视觉顶（最旧消息 = 物理底）。走 UIKit 绝对 offset，不 scrollTo 首条（长对话卡数秒）
                    .overlay(alignment: .top) {
                        Color.clear
                            .frame(height: 80)
                            .ignoresSafeArea(.all, edges: .top)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                KBProbe.log("[TOP] status-bar tap → oldest")
                                StreamScrollAnchor.scrollChatToOldest()
                            }
                    }
                    .onAppear {
                        StreamScrollAnchor.AnchorView.onAtBottomChange = { atBottom in
                            if isAtBottom != atBottom { KBProbe.log("isAtBottom→\(atBottom ? 1 : 0)") }
                            isAtBottom = atBottom
                            // CC 到达跟随判定要用（在底才滚）；回到底 = 新回复已看到，徽章熄灭
                            viewModel.isViewAtBottom = atBottom
                            if atBottom { hasUnseenReply = false; maybeLiftPadSuppression() }
                        }
                    }
                    // 收键盘交互（2026-08-16 粟粟拍）：滑动不收，点列表区收。
                    // tap 挂 ScrollView 链=子 view（气泡按钮/chip/thinking）自己的手势优先，
                    // 只有落空的 tap 冒到这里；无键盘时 guard 掉零副作用
                    .scrollDismissesKeyboard(.never)
                    .onTapGesture {
                        guard keyboardBridge.extra > 0 else { return }
                        KBProbe.log("tap-list → resign (extra=\(Int(keyboardBridge.extra)))")
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    // 键盘冷弹（0→正）回底：粟粟「键盘弹起来最好整个界面滚到最后」。近底时垫块
                    // 顶起已够看到最新；离底（>200pt，补偿器钉视口区）必须主动滚——复现器场景④
                    // 实锤离底弹键盘列表纹丝不动。候选栏高度变化（正→正）不触发，收键盘不触发。
                    .onChange(of: keyboardBridge.extra) { old, new in
                        KBProbe.log("extra \(Int(old))→\(Int(new)) isAtBottom=\(isAtBottom ? 1 : 0)")
                        // 收键盘 release（research-keyboard-follow-animation §4b）：垫块由 PagingVC hold 到收起流程
                        // 结束，此刻 extra→0 = 塌垫块；同一次 update 里直写 offset（在底归底 / 离底减 hold）= 同帧焊住。
                        // offset 越不过底边（-inset-312 会被夹回），所以在底的"旧画面"只能靠垫块先不塌来保住。
                        if new == 0, old > 0, let target = keyboardBridge.hideReleaseOffset {
                            keyboardBridge.hideReleaseOffset = nil
                            if let sv = StreamScrollAnchor.AnchorView.chatScrollView, !sv.isDragging {
                                StreamScrollAnchor.AnchorView.withProgrammaticOffset { sv.contentOffset.y = target }
                                KBProbe.log("hide release same-frame off→\(Int(target))")
                            }
                        }
                        // 对话内查找时不拉回底部：会冲掉跳到的那条命中（plan-chat-find 方案 5）
                        if old == 0, new > 0, !isAtBottom, !viewModel.inConvSearchActive {
                            // 深翻历史（离底 > returnToBottomScreens 屏）原地不动；以内才冷弹回底。
                            // 自己现读列表离底距离判，不靠 PagingVC 置旗：extra 现在在 layout 里发布、
                            // 键盘通知后到，旗子永远晚一步（08-26 粟粟报「对话中弹起也被拉回底」）
                            let sv = StreamScrollAnchor.AnchorView.chatScrollView
                            let dist = sv.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? 0
                            let farAway = sv.map { dist > $0.bounds.height * KeyboardInsetBridge.returnToBottomScreens } ?? false
                            KBProbe.log("cold-scroll trigger: extra \(Int(old))→\(Int(new)) dist=\(Int(dist)) farAway=\(farAway ? 1 : 0) cs=\(Int(sv?.contentSize.height ?? -1))")
                            if !farAway {
                                StreamScrollAnchor.scrollChatToBottom()
                                hasUnseenReply = false
                            }
                        }
                    }
                    // 回底按钮：挂在 ScrollView（safeAreaInset 之后）跨整个滚动区，按钮飘在
                    // 输入字段真实顶边上方 8pt——锚到字段而非会被 chip 顶高的输入栏顶边，
                    // 选附件时位置稳定。挂这层而非 inset 内层是因为 inset 内层 child HC
                    // clipsToBounds 会裁掉飘出输入栏区的按钮。
                    .overlay { findListOverlay }
                    .overlay {
                        scrollToBottomOverlay(proxy: proxy)
                        chatScrubberOverlay()
                    }
                    .animation(.easeInOut(duration: 0.25), value: stickerVM.showStickerPanel)
                    .animation(.easeInOut(duration: 0.25), value: stickerVM.isEditingStickers)
                    #else
                    // 卡内让开：卡自己画了底（可能还带壁纸），这里再画一层就是补丁（R-FS S1.4）
                    .background(macChatCarded ? Color.clear : Theme.mainBg)
                    .overlay(alignment: .bottomTrailing) { scrollToBottomOverlay(proxy: proxy) }
                    // 正文那层之外（输入条）拖文件也收
                    .onDrop(of: FileDrop.types, isTargeted: $fileDropTargetedOuter, perform: acceptFileDrop)
                    .overlay { fileDropHint }
                    .alert("附件读取失败", isPresented: Binding(get: { fileDropError != nil }, set: { if !$0 { fileDropError = nil } })) {
                        Button("好") { fileDropError = nil }
                    } message: {
                        Text(fileDropError ?? "")
                    }
                    .onChange(of: viewModel.macCCTailRevision) { _, _ in
                        guard viewModel.isViewAtBottom, viewModel.scrollToNodeId == nil,
                              let tail = viewModel.currentPath.last?.id else { return }
                        // This list is inverted: physical top is the visible latest edge.
                        // Centering a tall updated bubble would jump away from its end.
                        proxy.scrollTo(tail, anchor: .top)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        // + contentInsets.top：margin（=底层 inset，实验证实）变化时在底 offset=-margin，
                        // 裸 offset 判定会翻假（上一刀回底按钮乱冒的根因）
                        abs(geometry.contentOffset.y + geometry.contentInsets.top) < 200
                    } action: { _, atBottom in
                        if isAtBottom != atBottom { KBProbe.log("isAtBottom→\(atBottom ? 1 : 0)") }
                        isAtBottom = atBottom
                        // CC 到达跟随判定要用（在底才滚）；回到底 = 新回复已看到，徽章熄灭
                        viewModel.isViewAtBottom = atBottom
                        if atBottom { hasUnseenReply = false; maybeLiftPadSuppression() }
                    }
                    #endif
                    // 深翻抑制的垫块（§4f）：松手停在 returnToBottomScreens 以内 → 让 PagingVC 长垫块并回底
                    .onScrollPhaseChange { _, phase in
                        if phase == .idle { maybeLiftPadSuppression() }
                    }
                    // （v7 的 keyboardWillShow scrollTo 已删：滚到的"底"本身在键盘后=白滚，
                    // 且与 KeyboardInsetBridge margin 避让抢时序；列表键盘避让唯一路径=bridge margin）
                    // （defaultScrollAnchor .sizeChanges 曾试修「拉一节」——探针实证 943:0 零介入已撤；
                    // 真修法 = StreamScrollAnchor UIKit 补偿器，见 research-scroll-drift-fix.md）
                    .background {
                        // 空对话（草稿/新对话）= 记忆花园开场：底部本层记忆长成的花 + 天空星点。
                        // 发出第一条消息后 currentPath 非空 → 自动隐去，变正常聊天。
                        if viewModel.currentPath.isEmpty && gardenSceneEnabled {
                            GardenSceneView()
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.35), value: viewModel.currentPath.isEmpty)
                    .onChange(of: viewModel.isLoading) { _, loading in
                        // 反转列表：offset=0 自然在最新 → 不需要 scrollToLastMessage 三步走
                        // 只保留 sticker 同步（B20 修复）
                        if !loading, !viewModel.currentPath.isEmpty {
                            stickerVM.currentPathCount = viewModel.currentPath.count
                            stickerVM.migrateStickerPositions(context: modelContext)
                        }
                    }
                    .onChange(of: viewModel.currentPath.count) { _, n in
                        // B20 修复：path 变（新消息进来等）→ 同步给 stickerVM，让 clampStickerY
                        // 在 drag end 时拿到最新 path 长度
                        stickerVM.currentPathCount = n
                        // 在上面翻历史时来了新 assistant 消息（CC 到达不再拽底）→ 回底按钮亮徽章
                        if !isAtBottom, viewModel.currentPath.last?.role == "assistant" {
                            hasUnseenReply = true
                        }
                    }
                    .onChange(of: viewModel.assistantTurnInFlight) { _, inFlight in
                        // 在上面翻历史时流式生成完 → 亮徽章（生成中按钮显示呼吸点）
                        if !inFlight, !isAtBottom, !viewModel.currentPath.isEmpty {
                            hasUnseenReply = true
                        }
                    }
                    .onChange(of: viewModel.scrollToNodeId) { _, nodeId in
                        // P2.1 反转列表：anchor .center 不受翻转影响（rotation 相对 view 自身）。
                        // 旧两步走（无动画+50ms 后动画微调，等 LazyVStack mount 目标）反转后不需要 → 单步。
                        #if os(iOS)
                        // 正在拖滚动条：CC 跟随 / 程序跳转让位（plan-chat-scrubber §2.3）
                        if nodeId != nil, StreamScrollAnchor.AnchorView.scrubbing {
                            #if DEBUG || PERF_BENCH
                            if PerfHarness.strictMeasure, let nodeId { PerfRenderLedger.noteJump(target: nodeId, outcome: "droppedByScrub") }
                            #endif
                            viewModel.scrollToNodeId = nil
                            return
                        }
                        #endif
                        #if (DEBUG || PERF_BENCH) && os(iOS)
                        // 测试钩子（perf P0 §6.6 反作弊）：收尾导航目标不被消费 → 收尾导航断言必须判红
                        if PerfHarness.testDropFinishJump, let nodeId, nodeId == PerfRenderLedger.dropJumpTarget { return }
                        #endif
                        if let nodeId {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(nodeId, anchor: .center)
                            }
                            viewModel.scrollToNodeId = nil
                            #if (DEBUG || PERF_BENCH) && os(iOS)
                            if PerfHarness.strictMeasure { PerfRenderLedger.noteJump(target: nodeId, outcome: "scrolled") }
                            #endif
                        }
                    }
                    // 反转列表：流式跟随暂停（粟粟说"先不管流式"，将来用 SwiftStreamingMarkdown 一并重写）
                    // 反转列表：offset=0 = 视觉底，打开即在最新，不需要 onAppear 兜底
                    .scrollDisabled(stickerVM.isEditingStickers)
                }


            }
            .animation(.easeInOut(duration: 0.25), value: stickerVM.isEditingStickers)
            #if os(macOS)
            .animation(.easeInOut(duration: 0.25), value: stickerVM.showStickerPanel)
            #endif
            #if os(iOS)
            .overlay(alignment: .bottom) { stickerPanel }
            .modifier(CardFlowCallPresentation(conversationID: viewModel.selectedConversation?.id, presented: $showCallScreen, callContent: callScreen))
            .animation(.easeInOut(duration: 0.25), value: stickerVM.showStickerPanel)
            .animation(.easeInOut(duration: 0.25), value: stickerVM.isEditingStickers)
            // Telegram 式长按浮层：environment 给树内 marker 递 model；
            // 浮层本体由 BubbleMenuOverlayPresenter 挂 window 层（压住页级 chrome + 材质采样真实内容）
            .environment(\.bubbleMenuOverlayModel, bubbleMenuModel)
            .modifier(ChatSelectionLifecycle(viewModel: viewModel, menuModel: bubbleMenuModel))
            #else
            .modifier(ChatSelectionLifecycle(viewModel: viewModel))
            #endif
            .background {
                // Hidden button for Cmd+F shortcut
                Button("") {
                    if viewModel.inConvSearchActive {
                        viewModel.endInConvSearch()
                    } else {
                        #if os(iOS)
                        ChatInputHandle.shared.finalizeCompositionAndCommit()
                        #endif
                        viewModel.beginInConvSearch()
                        inConvSearchFocused = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
            // 审批卡只出在正看着的对话里；切走 / 离开聊天页时挂着的卡改走弹窗（粟粟 10-03）
            .onChange(of: viewModel.selectedConversation?.id, initial: true) { _, id in
                PermissionPromptCenter.shared.visibleConversationId = id
            }
            .onDisappear {
                if PermissionPromptCenter.shared.visibleConversationId == viewModel.selectedConversation?.id {
                    PermissionPromptCenter.shared.visibleConversationId = nil
                }
            }
            .onChange(of: viewModel.selectedConversation?.id) { _, convId in
                viewModel.endInConvSearch()
                viewModel.messageSelection.end()
                loadedConv = viewModel.selectedConversation
                SpeechService.shared.stop()
                loadStickersForConversation(convId)
                isAtBottom = true
                viewModel.isViewAtBottom = true
                hasUnseenReply = false
            }
            .onAppear {
                // 只在「换了对话 / 冷启动首次」时载入；从对话列表切回同一对话别 reload，
                // 否则会拿对话里还没 flush 的空草稿把正在打的字冲掉。
                if loadedConv?.id != viewModel.selectedConversation?.id {
                    loadedConv = viewModel.selectedConversation
                }
                loadStickersForConversation(viewModel.selectedConversation?.id)
                // 注入贴纸 mutation callback：加/删贴纸时推对话走 3s debounce 重排
                stickerVM.onConversationMutated = { [viewModel] convId in
                    if let conv = viewModel.selectedConversation, conv.id == convId {
                        conv.updateTime = Date()
                        viewModel.markConversationDirty()
                    }
                }
            }
            #if os(iOS)
            .toolbarBackground(Theme.mainBg, for: .navigationBar)
            #endif
            .overlay(alignment: .top) {
                // B20 part 2: transient toast (e.g. "已切换到分支")
                if let notice = viewModel.transientNotice {
                    TransientNoticeCapsule(text: notice.text)
                        .id(notice.id)
                        .padding(.top, 16)
                        .onAppear {
                            let id = notice.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                                if viewModel.transientNotice?.id == id {
                                    viewModel.transientNotice = nil
                                }
                            }
                        }
                }
            }
            // 计时器卡到点自动告诉模型（research-chat-cards §8.2 / §8.5）；store 在这里首次懒加载
            .timerDelivery(viewModel: viewModel)
            #if os(macOS)
            // 切到别的对话时音乐继续放：顶上一个小玻璃胶囊，点回去（粟粟 09-27）。iOS 挂在顶栏下面（ContentView.iOSChatTopBar）
            .overlay(alignment: .top) { MusicNowPlayingCapsule(viewModel: viewModel).padding(.top, 6) }
            #endif
        }
    }

    // B2：iOSBottomInset 已整体搬迁 InputBarStack（输入条挂 UIKit host + keyboardLayoutGuide）
    /// 「+」/ 贴纸面板（两端同一套 StickerKeyboardPanel）：iOS 挂 overlay 贴底，mac 顶替输入条（面 4.1b）
    @ViewBuilder
    private var stickerPanel: some View {
        if stickerVM.showStickerPanel || stickerVM.isEditingStickers {
            @Bindable var vm = viewModel
            StickerKeyboardPanel(
                stickerVM: stickerVM,
                viewModel: viewModel,
                showCard: stickerVM.showStickerPanel,
                onDismiss: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if stickerVM.showStickerPanel {
                            stickerVM.showStickerPanel = false
                        } else {
                            stickerVM.isEditingStickers = false
                            stickerVM.selectedPlacedStickerId = nil
                        }
                    }
                },
                onStickerTap: {
                    withAnimation(.easeInOut(duration: 0.25)) { stickerVM.showStickerPanel.toggle() }
                },
                selectedAttachments: $vm.selectedAttachments,
                onCallStart: startCall
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// + 号条 📞（plan-voice-note M6）：收起面板 → 打开通话页
    private var startCall: (() -> Void)? {
        #if os(iOS)
        return {
            withAnimation(.easeInOut(duration: 0.25)) {
                stickerVM.showStickerPanel = false
                stickerVM.isEditingStickers = false
                stickerVM.selectedPlacedStickerId = nil
            }
            showCallScreen = true
        }
        #else
        return nil
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var callScreen: some View {
        if let pm = providerManager {
            CallScreen(
                viewModel: viewModel,
                modelContext: modelContext,
                profileManager: profileManager,
                providerManager: pm,
                presetManager: presetManager,
                currentModel: pm.resolveModel(
                    conversationModelId: viewModel.selectedConversation?.selectedModelId,
                    globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel")),
                nativeCallID: NativeCallCoordinator.shared.current?.call_id
            )
        }
    }
    #endif

    // MARK: - Sticker Helpers

    private func loadStickersForConversation(_ convId: String?) {
        stickerVM.bubblePositions.removeAll()
        guard let convId, let pid = profileManager?.currentProfile.id else {
            stickerVM.placedStickers = []
            return
        }
        stickerVM.loadPlacedStickers(conversationId: convId, profileId: pid, context: modelContext)
    }

    #if os(macOS)
    /// 拖进来的文件走「选文件上传」同一条路（`StickerKeyboardPanel.handleAttachmentImport`）
    private func acceptFileDrop(_ providers: [NSItemProvider]) -> Bool {
        FileDrop.loadURLs(providers) { urls in
            var failures: [String] = []
            for url in urls {
                do {
                    viewModel.selectedAttachments.append(try AttachmentTextExtractor.extract(from: url))
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { fileDropError = failures.joined(separator: "\n") }
        }
    }

    private var fileDropHint: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.branchIndicator.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.branchIndicator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .overlay {
                Label("松手上传", systemImage: "arrow.down.doc")
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .opacity(fileDropTargeted || fileDropTargetedOuter ? 1 : 0)
            .allowsHitTesting(false)
    }
    #endif

    private func handleStickerDrop(providers: [NSItemProvider], location: CGPoint) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
            // completion 在后台线程回调：第一时间 hop 主线程再碰任何共享状态
            //（bubblePositions 是主线程高频写的字典，并发读可直接崩；SwiftData model 也有线程约束）
            let idString = (data as? Data).flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async {
                guard let idString,
                      let assetId = UUID(uuidString: idString),
                      let convId = viewModel.selectedConversation?.id,
                      let pid = profileManager?.currentProfile.id else { return }

                let nearestId = findNearestMessageId(y: location.y)
                print("[贴纸定位] drop y=\(location.y), bubblePositions=\(stickerVM.bubblePositions.count)条, nearest=\(nearestId ?? "nil")")

                // 查 asset 类型——便签需要复制 noteContent/noteStyle
                let asset = stickerVM.stickerAssets.first(where: { $0.id == assetId })

                if let asset, asset.isNote {
                    stickerVM.placeNote(
                        content: asset.noteContent ?? "",
                        style: asset.noteStyle ?? "yellow_square",
                        conversationId: convId,
                        position: location,
                        nearestMessageId: nearestId,
                        profileId: pid,
                        context: modelContext
                    )
                } else {
                    stickerVM.placeSticker(
                        assetId: assetId,
                        conversationId: convId,
                        position: location,
                        nearestMessageId: nearestId,
                        profileId: pid,
                        context: modelContext
                    )
                }
            }
        }
        return true
    }

    /// 找 Y 坐标最近的消息 ID（用 GeometryReader 测量的真实位置）
    private func findNearestMessageId(y: CGFloat) -> String? {
        guard !stickerVM.bubblePositions.isEmpty else {
            // fallback：没有测量数据时用第一条消息
            return viewModel.currentPath.first?.id
        }
        var bestId: String?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for (nodeId, centerY) in stickerVM.bubblePositions {
            let dist = abs(centerY - y)
            if dist < bestDist {
                bestDist = dist
                bestId = nodeId
            }
        }
        return bestId
    }
}

// MARK: - In-Conversation Search Bar

struct InConversationSearchBar: View {
    var viewModel: ConversationViewModel
    var focused: FocusState<Bool>.Binding
    var onDismiss: () -> Void
    @State private var keyword: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)

            TextField("搜索当前对话...", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
                .onSubmit {
                    viewModel.searchInConversation(keyword: keyword)
                }
                .onChange(of: keyword) { _, newValue in
                    if newValue.isEmpty {
                        viewModel.clearInConvSearch()
                    }
                }

            if !viewModel.inConvMatches.isEmpty {
                Text("\(viewModel.inConvMatchIndex + 1)/\(viewModel.inConvMatches.count)")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
                    .monospacedDigit()

                Button(action: { viewModel.navigateInConvMatch(direction: -1) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.navigateInConvMatch(direction: 1) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            } else if !keyword.isEmpty && viewModel.inConvMatchIndex == -1 {
                Text("无结果")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.sidebarBg)
    }
}

// MARK: - Chat Input Bar

struct ChatInputBar: View {
    @Environment(\.chatMetrics) private var metrics
    @Environment(\.macChatCarded) private var macChatCarded
    var viewModel: ConversationViewModel
    var modelContext: ModelContext
    var profileManager: ProfileManager?
    var providerManager: ProviderManager
    var presetManager: PresetManager?
    @Binding var selectedAttachments: [PendingChatAttachment]
    @Binding var draftText: String
    var onStickerTap: (() -> Void)? = nil

    @AppStorage("selectedChatModel") private var selectedModelId = ""
    @State private var showModelPicker = false
    /// 当前对话的语音正在转文字 → 输入条行内显示「转文字中…」（M5b；不再占附件条，输入条不跳高）。
    /// 忙状态在 VoiceNoteTranscribing 单例上（sol P1-2：输入条重挂不丢）
    private var isTranscribingVoice: Bool {
        let busy = VoiceNoteTranscribing.shared.conversationId
        return busy != nil && busy == viewModel.selectedConversation?.id
    }
    #if os(iOS)
    /// UIKit 化后 iOS 侧没有 SwiftUI 可聚焦视图挂 FocusState（无绑定视图时写入被焦点系统丢弃，
    /// T5 实测 focused=N 聚不了焦），改平 State 通道：representable 的 delegate 是唯一真相回写方
    @State private var isFocused: Bool = false
    #else
    @FocusState private var isFocused: Bool
    #endif
    #if os(iOS)
    /// 真机探针铁证（KB-RT）：聚焦态样式若由 isFocused 驱动，会在键盘动画开始前先抖一下
    ///（下沉 9px 静止 30ms 再飞=粟粟的「点-往下卡一下-才弹起」）——改由键盘真实到位驱动，
    /// 布局变化并进键盘大位移窗口内不可感。Bridge 是 iOS-only，声明必须平台守卫（共用源码教训）
    @ObservedObject private var keyboardBridge = KeyboardInsetBridge.shared
    private var kbUp: Bool { keyboardBridge.kbVisible }
    /// compact 单行时 InputFieldContainer 的高：发送键固定 44pt 框撑死（HStack center 对齐，
    /// 单行文本 ~36 < 44）——源码构造常数非实测猜测；垫块基线不能拿 margin 100 做差
    ///（sol 终审 §2 打回项）。字段实高超出它的部分 = 多行增量，进 barGrowth。
    #endif

    /// chip 行（引用/附件/排队）可见性——barGrowth 的 chip 分量开关，与 body 内渲染条件同源
    private var hasChipRow: Bool {
        viewModel.quotingPreview != nil || !selectedAttachments.isEmpty || !viewModel.pendingSends.isEmpty
            || !pendingCardEvents.isEmpty
    }

    /// §13 待捎带箱里这个对话的事件（下次发消息带给模型）
    private var pendingCardEvents: [ChatCardEvent] {
        guard let id = viewModel.selectedConversation?.id else { return [] }
        return viewModel.cardEventOutbox.events(for: id)
    }

    private var isEditingMessage: Bool { viewModel.editingMessage != nil }

    /// @ 选中的文件库文件 → 附件条（和📎同一条抽取，后台读；失败轻提示）
    private func attachLibraryFile(_ path: String) {
        guard let pid = profileManager?.currentProfile.id else { return }
        let key = FileMention.composerKey(viewModel)
        Task {
            let r = await FileMention.attach(paths: [path], profileId: pid)
            guard FileMention.composerKey(viewModel) == key else {
                ToastCenter.shared.show("换了对话，文件没加上")
                return
            }
            selectedAttachments.append(contentsOf: r.attachments)
            if let msg = r.failures.first { ToastCenter.shared.show(msg) }
        }
    }

    /// 输入框圆角 + 4（iOS 输入框 20 / mac 11）
    private var editCardRadius: CGFloat {
        #if os(iOS)
        24
        #else
        15
        #endif
    }

    private var editingHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            editingTitleRow
            // 拿不回来的附件（被移走 / 导入旧对话只有名字）：不放 chip，这里说一声（plan-edit-attachments 拍板 2）
            if let missing = viewModel.editingMessage?.restored.missingCount, missing > 0 {
                Text("\(missing) 个附件找不到了，发送后不会带上")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .padding(.leading, 10)
                    .padding(.bottom, 4)
            }
        }
    }

    private var editingTitleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .medium))
            Text("编辑消息")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button { endEditing() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消编辑")
            #if os(macOS)
            .help("取消编辑（Esc）")
            #endif
        }
        .foregroundColor(Theme.textPrimary)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
    }

    /// 输入框里现在的真文字（iOS 真相在 UITextView，先定稿组字再读）
    private func currentComposerText() -> String {
        #if os(iOS)
        ChatInputHandle.shared.finalizeCompositionAndCommit()
        return ChatInputHandle.shared.liveText ?? draftText
        #else
        return draftText
        #endif
    }

    private func setComposerText(_ text: String) {
        draftText = text
        #if os(iOS)
        ChatInputHandle.shared.issueText(text)
        #endif
    }

    /// 消息行 beginEditing 后接手：首次进入收起草稿 / 附件 / 引用；再放原消息拆回的文字 / 附件 / 引用，聚焦。
    /// 编辑中换一条：stash 已在，整体换成新那条的。applied 防重挂载覆盖改到一半的内容。
    private func applyEditingIfNeeded() {
        guard var e = viewModel.editingMessage, !e.applied else { return }
        if e.stash == nil {
            e.stash = ConversationViewModel.ComposerStash(
                text: currentComposerText(),
                attachments: selectedAttachments,
                quotePreview: viewModel.quotingPreview,
                quoteReplyTo: viewModel.quotingReplyTo)
            selectedAttachments = []
            viewModel.clearQuoting()
        }
        e.applied = true
        viewModel.editingMessage = e
        setComposerText(e.restored.text)
        selectedAttachments = e.restored.attachments
        viewModel.quotingPreview = e.restored.quotePreview
        viewModel.quotingReplyTo = e.restored.quoteReplyTo
        isFocused = true
    }

    /// 表单卡提交即发（粟粟 10-03）：只发这张卡（同输入框发送一样过预算检查、认领模型），草稿不动
    private func applyCardSend() {
        guard let request = viewModel.cardSendRequest else { return }
        viewModel.cardSendRequest = nil
        guard request.conversationId == viewModel.selectedConversation?.id else { return }
        let prof = profileManager?.currentProfile ?? Profile(name: "", emoji: "", description: "", userName: "你", assistantName: "AI")
        let preset = presetManager?.preset(byId: prof.presetId) ?? Preset.balanced
        let attachments = [PendingChatAttachment.card(request.card)]
        guard viewModel.preCheckBudget(text: ChatAttachmentPromptBuilder.modelInput(text: "", attachments: attachments),
                                       model: currentModel, profile: prof, preset: preset,
                                       providerManager: providerManager) else { return }
        viewModel.selectedConversation?.selectedModelId = currentModel.id
        viewModel.sendMessage("", model: currentModel, profile: prof, preset: preset,
                              providerManager: providerManager, context: modelContext, attachments: attachments)
    }

    /// 语音条发送入口（plan-voice-note M4，录音器 M2/M5 录完调这里）：临时 m4a + 时长 + **开录时**的对话 id。
    /// 存文件库 → 转写（期间 VoiceNoteTranscribing 记着那个对话）→ .voice 附件 → deliverVoiceNote。存不上 = 提示并丢弃
    func sendVoiceNote(tempFileURL: URL, duration: Double, conversationId: String, analysisBucket: String? = nil) {
        let current = viewModel.selectedConversation
        let conv = current?.id == conversationId ? current : VoiceNoteSender.conversation(id: conversationId, context: modelContext)
        guard let conv else {
            try? FileManager.default.removeItem(at: tempFileURL)
            ToastCenter.shared.show("那个对话不在了，语音没发出去")
            return
        }
        let jobs = VoiceNoteTranscribing.shared
        guard let job = jobs.begin(conversationId: conversationId) else {
            try? FileManager.default.removeItem(at: tempFileURL)
            ToastCenter.shared.show("上一条语音还在转文字，这条没发")
            return
        }
        let profileId = conv.profileId
        let path: String
        do {
            path = try VoiceNoteSender.persist(tempFileURL: tempFileURL, conversationId: conversationId,
                                               conversationTitle: conv.title, profileId: profileId)
        } catch {
            jobs.finish(job)
            ToastCenter.shared.show("语音没存上，这条没发")
            return
        }
        // 不绑输入条生命周期：只抓 viewModel / context / manager 这些稳定引用，输入条撤掉重挂照样发到位
        let prosodyStore = VoiceProsodyStore.shared
        let ticket = analysisBucket.flatMap { prosodyStore.begin(bucket: $0, source: profileId + ":" + path) }
        let recognizeSpeaker = UserDefaults.standard.bool(forKey: SpeakerIdentityStore.enabledKey)
        Task { @MainActor in
            async let speaker: SpeakerMatch = {
                guard recognizeSpeaker, let url = FileLibraryStore.absoluteURL(path, profileId: profileId) else { return SpeakerMatch(status: .unavailable) }
                return await SpeakerIdentityStore.shared.recognize(url: url)
            }()
            async let measurement: VoiceProsody? = {
                guard ticket != nil, let url = FileLibraryStore.absoluteURL(path, profileId: profileId) else { return nil }
                return await VoiceProsody.analyze(fileURL: url)
            }()
            let transcript = await VoiceNoteSender.transcribe(path: path, profileId: profileId)
            var attachment = PendingChatAttachment.voice(path: path, duration: duration, transcript: transcript)
            let result = await measurement
            let who = await speaker
            if UserDefaults.standard.bool(forKey: SpeakerIdentityStore.enabledKey),
               await SpeakerIdentityStore.shared.isCurrent(who),
               let url = FileLibraryStore.absoluteURL(path, profileId: profileId), FileManager.default.fileExists(atPath: url.path) {
                attachment.speakerCue = who.cue
            }
            if let ticket, let url = FileLibraryStore.absoluteURL(path, profileId: profileId),
               FileManager.default.fileExists(atPath: url.path) {
                attachment.voiceProsody = prosodyStore.finish(ticket, measurement: result, transcript: transcript)
            }
            jobs.finish(job)
            deliverVoiceNote(attachment, conversationId: conversationId)
        }
    }

    /// 被预算 / 发送拦下的语音放回草稿（sol P1-3）：编辑旧消息中 → 进收起的那份草稿（stash），不混进编辑附件；
    /// 否则进附件条。录音永远是发新消息
    private func restoreBlockedVoice(_ attachment: PendingChatAttachment) {
        if var e = viewModel.editingMessage, let st = e.stash {
            e.stash = ConversationViewModel.ComposerStash(text: st.text, attachments: st.attachments + [attachment],
                                                          quotePreview: st.quotePreview, quoteReplyTo: st.quoteReplyTo)
            viewModel.editingMessage = e
            ToastCenter.shared.show("语音没发出去，退出编辑后在附件条里")
        } else {
            selectedAttachments.append(attachment)
        }
    }

    /// 还在那个对话：只发这条语音（输入框文字 / 附件不动），同打字发送过预算、认领模型；被拦就放回附件条不丢。
    /// 切走了：追加进那个对话的草稿附件（粟粟 10-04：不发，存进输入框），回去时 loadDraft 装回附件条
    private func deliverVoiceNote(_ attachment: PendingChatAttachment, conversationId: String) {
        if viewModel.selectedConversation?.id == conversationId {
            let prof = profileManager?.currentProfile ?? Profile(name: "", emoji: "", description: "", userName: "你", assistantName: "AI")
            let preset = presetManager?.preset(byId: prof.presetId) ?? Preset.balanced
            let attachments = [attachment]
            guard viewModel.preCheckBudget(text: ChatAttachmentPromptBuilder.modelInput(text: "", attachments: attachments),
                                           model: currentModel, profile: prof, preset: preset,
                                           providerManager: providerManager) else {
                restoreBlockedVoice(attachment)
                return
            }
            viewModel.selectedConversation?.selectedModelId = currentModel.id
            if !viewModel.sendMessage("", model: currentModel, profile: prof, preset: preset,
                                      providerManager: providerManager, context: modelContext, attachments: attachments) {
                restoreBlockedVoice(attachment)
            }
            return
        }
        guard let conv = VoiceNoteSender.conversation(id: conversationId, context: modelContext) else {
            ToastCenter.shared.show("那个对话不在了，语音没发出去")
            return
        }
        conv.draftAttachmentsData = VoiceNoteSender.appendingToDraft(conv.draftAttachmentsData, attachment)
        try? modelContext.save()
        ToastCenter.shared.show("语音存进「\(conv.title)」的输入框了")
    }

    /// §13 网页卡 mp.ask：追加到输入框（不聚焦，不弹键盘）
    private func applyComposerInsert() {
        guard let insert = viewModel.composerInsert else { return }
        viewModel.composerInsert = nil
        guard insert.conversationId == viewModel.selectedConversation?.id else { return }
        setComposerText(ConversationViewModel.appending(insert.text, to: currentComposerText()))
    }

    /// 退出编辑（✕ / Esc / 发送成功）：先清编辑态（之后的写回才算草稿落盘），再放回 stash
    private func endEditing() {
        guard let e = viewModel.editingMessage else { return }
        viewModel.editingMessage = nil
        let stash = e.stash
        setComposerText(stash?.text ?? "")
        selectedAttachments = stash?.attachments ?? []
        viewModel.quotingPreview = stash?.quotePreview
        viewModel.quotingReplyTo = stash?.quoteReplyTo
    }

    private var currentModel: ProviderModel {
        providerManager.resolveModel(
            conversationModelId: viewModel.selectedConversation?.selectedModelId,
            globalFallbackId: selectedModelId)
    }

    /// 底部模型胶囊要的那一项：cc-bridge 卡且对话已绑会话才有。只取对象、不读模型（读在 ModelCapsule 里，审查 R1-6）
    private var capsuleModelEntry: CCSessionModelEntry? {
        ModelCapsule.entry(isCCBridge: providerManager.credential(for: currentModel)?.type == .ccBridge,
                           sessionName: viewModel.selectedConversation?.ccBridgeSessionName)
    }

    private var systemPrompt: String? {
        let prompt = profileManager?.currentProfile.systemPrompt ?? ""
        return prompt.isEmpty ? nil : prompt
    }

    #if os(iOS)
    /// 字段顶偏移 → 桥（去重 + 异步：onGeometryChange 在布局事务内回调，直写 @Published
    /// 会撞 "Publishing changes from within view updates"，与 extra 同款延后一帧）
    private func publishFieldOffset(_ y: CGFloat) {
        guard abs(y - keyboardBridge.fieldOffsetInBar) > 0.5 else { return }
        DispatchQueue.main.async { KeyboardInsetBridge.shared.fieldOffsetInBar = y }
    }

    /// 输入条超出 compact 单行的增量 → 桥。变更先静默补偿器 0.3s（sol 终审 §3 漏窗：
    /// growth 落到垫块改 contentSize，生成中会被当流式生长补掉；mute 同步先行，
    /// growth 下一 runloop 才落 = 静默必然先于 contentSize 变化生效）
    /// 输入条尺寸变了 → 让 UIKit 容器 re-solve（真值随后由 publishKeyboardGeometry 从容器 frame 派生）。
    /// ⚠️ P1：不再在 SwiftUI 侧自算 barGrowth——旧法数值对了但容器没 re-solve = 输入框上移不复位（Bug3）
    private func kickBarLayout() {
        #if DEBUG
        HitchProbe.mark("kickBarLayout")
        #endif
        StreamScrollAnchor.muteCompensator(0.3)
        DispatchQueue.main.async { KeyboardInsetBridge.shared.barKick.send() }
    }
    #endif

    var body: some View {
        #if DEBUG
        let _ = {
            PerfCounters.chatInputBarBody += 1
            print(String(format: "[PERF] ChatInputBar.body #%d t=%.3f focused=%@",
                         PerfCounters.chatInputBarBody,
                         CFAbsoluteTimeGetCurrent(),
                         isFocused ? "Y" : "N"))
            #if os(iOS)
            // iu0902 C2 验收：把计数挂到输入框 a11y label 上给 XCUITest 读（--kb-probe-seed 才开）
            InputPerfProbe.publish(bar: PerfCounters.chatInputBarBody, field: PerfCounters.inputFieldBody)
            #endif
        }()
        #endif
        return VStack(spacing: metrics.composerStackSpacing) {
            // A4：引用 + 附件同一横排（AttachmentChipRow 里引用排第一个）。✕ 取消引用。
            // 排队消息也在这排（⏳ chip，✕ = 取消排队写回输入框）。
            if hasChipRow {
                AttachmentChipRow(
                    attachments: selectedAttachments,
                    onRemove: { id in
                        selectedAttachments.removeAll { $0.id == id }
                    },
                    quotePreview: viewModel.quotingPreview,
                    onClearQuote: { viewModel.clearQuoting() },
                    pendingSends: viewModel.pendingSends.map { ($0.id, $0.text) },
                    cardEvents: pendingCardEvents,
                    onRemoveCardEvent: { id in
                        guard let convId = viewModel.selectedConversation?.id else { return }
                        viewModel.cardEventOutbox.remove(id: id, conversationId: convId)
                    },
                    voiceProfileId: viewModel.selectedConversation?.profileId ?? "",
                    onCancelPending: { id in
                        guard let p = viewModel.cancelPendingSend(id: id) else { return }
                        #if os(iOS)
                        // 提交点 8（kimi B1）：下面这行基于 draftText 拼接后经 binding 反灌
                        // UITextView，不先提交就会把还没提交的尾巴覆盖掉。拼接底座直接读
                        // liveText，不依赖「@State 写完立刻读得到」。
                        // ime-residual T1b：必须 finalize 不是裸 commitNow——组字期 commitNow 把拼音
                        // 提交进 lastCommitted，拼接值≠lastCommitted 被存成 pendingExternal，候选落字
                        // 后「外部写赢」重放会拿拼音+排队文本覆盖刚选的汉字（双席收敛的唯一闭合回灌链）
                        ChatInputHandle.shared.finalizeCompositionAndCommit()
                        let base = ChatInputHandle.shared.liveText ?? draftText
                        #else
                        let base = draftText
                        #endif
                        draftText = base.isEmpty ? p.text : base + "\n" + p.text
                        #if os(iOS)
                        ChatInputHandle.shared.issueText(draftText)   // 命令通道：合并值即时落 tv
                        #endif
                        // 卡片按 id 合并，不放回两张同 id（research-chat-cards 终审 #4）
                        selectedAttachments = ConversationViewModel.restoring(p.attachments, into: selectedAttachments)
                        if let qp = p.quotePreview {
                            viewModel.quotingPreview = qp
                            viewModel.quotingReplyTo = p.quoteReplyTo
                        }
                    }
                )
                #if os(iOS)
                // 滚动横截面右端给回底按钮让位（按钮 ≈16 trailing + 44 宽），两者并排不打架
                .padding(.trailing, 52)
                // barGrowth 的 chip 分量：实测行高（不硬编码 72——sol 终审 §2 白盒路线），
                // 行消失时由 onChange(hasChipRow) 把分量清零
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _ in kickBarLayout() }
                #endif
            }

            // 编辑旧消息（plan-edit-in-composer 方案 A）：卡片把输入框包住，标题行在上。
            // if 在 VStack 里占独立槽位，InputFieldContainer 身份不变（不丢焦点）
            VStack(spacing: 0) {
            if isEditingMessage {
                editingHeader
                    .transition(.opacity)
            }
            // Input container — inputText 持在子 view 里，打字只重建子 view 不重建整个 ChatInputBar
            InputFieldContainer(
                text: $draftText,
                isFocused: $isFocused,
                // turn 级状态（含工具执行/多轮 loop 空窗），不是 provider 级 isStreaming——
                // 空窗期放行发送会造成 user+user 连排（consecutive-user-turns bug）。
                // 用 isCurrentConvResponding 而不是 assistantTurnInFlight：A 在跑切到 B，
                // B 的 InputBar 不应该显示暂停（B 没在跑）。串行单流的实发逻辑不变，
                // 这里只修 UI 状态对齐到当前 conv。
                isResponding: viewModel.isCurrentConvResponding,
                hasAttachments: !selectedAttachments.isEmpty,
                onSend: { text in send(text) },
                onCancelStream: { viewModel.cancelAssistantTurn(context: modelContext) },
                onStickerTap: onStickerTap,
                isCCBridge: providerManager.credential(for: currentModel)?.type == .ccBridge,
                stopWhileResponding: isEditingMessage,
                voiceEnabled: true,
                voiceTranscribing: isTranscribingVoice,
                profileId: profileManager?.currentProfile.id ?? "",
                onPickFile: { path in attachLibraryFile(path) }
            )
            #if os(iOS)
            // 回底按钮锚分量②：字段顶在输入条栈根（"chatInputBar" 空间）内的偏移，白盒自报给桥
            //（B2 跨 host 后 preference 断链；容器顶不能当锚——sol 终审 §1）。字段实高同时喂
            // barGrowth 的多行分量。
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("chatInputBar")).minY }) { y in
                publishFieldOffset(y)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _ in kickBarLayout() }
            #endif
            }
            .padding(isEditingMessage ? 4 : 0)
            .background {
                if isEditingMessage {
                    RoundedRectangle(cornerRadius: editCardRadius)
                        .fill(Theme.textPrimary.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: editCardRadius).strokeBorder(Theme.textPrimary.opacity(0.08), lineWidth: 1))
                        .transition(.opacity)
                }
            }
            #if os(macOS)
            .onKeyPress(.escape) {
                guard isEditingMessage else { return .ignored }
                endEditing()
                return .handled
            }
            #endif

            #if os(iOS)
            // 收起工具排是 iOS 键盘空间优化；mac 聚焦是常态，恒显示。
            // 驱动源=kbUp（键盘真开始动）非 isFocused：聚焦瞬间收行=容器矮 19pt、
            // 底钉导轨顶边下坐=「输入框先闪下 10pt 模型选择器异位再上滑」的起步预抖
            //（2026-08-16 粟粟终验点名；KB-RT 聚焦预抖同方子）。kbUp 时刻收行=19pt
            // 混进键盘大位移不可感。插回带淡入过渡（「底部闪一帧」修）。
            if !kbUp {
                bottomControlRow
                    // 纯淡入不带位移：.move(edge:.bottom) 的滑动成分被看成「灰色块推下去」
                    .transition(.opacity)
            }
            #else
            bottomControlRow
            #endif
        }
        #if os(iOS)
        .animation(.easeOut(duration: 0.22), value: kbUp)
        #endif
        #if os(iOS)
        .padding(.horizontal, metrics.composerInsetH)
        .padding(.bottom, kbUp ? 5 : -6) // 静息底距实调史：4→-4→-8→-12→-6。-12 时模型胶囊泡进系统底缘手势带（touch 被延迟+双击唤 Apple 智能），-6 是好看和能点的平衡点；focused 时键盘上方留 5px 呼吸不动。KB-RT：驱动源 isFocused→kbUp（键盘真到位），防聚焦预抖
        .padding(.top, 6)
        // 内容先夹宽，再由外层撑满居中。
        .frame(maxWidth: Theme.contentMaxWidth)
        .frame(maxWidth: .infinity)
        // 关键 fix：让 ChatInputBar VStack 自己吞掉空白区 hit。
        // 没这一句的话 VStack 空白（input field 跟 capsule 之间、capsule 左边 Spacer、
        // 上下 padding 区）会让 hit 穿透到底下 ScrollView 的气泡 → 触发 contextMenu。
        // 子 view（InputField / 模型胶囊 Button）有自己 hit area，不受影响。
        .contentShape(Rectangle())
        // 录语音浮层（plan-voice-note M5c）：贴底往上溢出（carrier 整页高），挂在 contentShape 之后（不被它裁命中）、
        // 坐标系之内（浮层用 chatInputBar 空间对位）。录音状态只有 host 读，这里的 body 不因录音重算
        .overlay(alignment: .bottom) {
            VoiceRecordOverlayHost(
                voice: .shared,
                conversationId: viewModel.selectedConversation?.id,
                editing: isEditingMessage,
                onDeliver: { d in sendVoiceNote(tempFileURL: d.url, duration: d.duration, conversationId: d.conversationId, analysisBucket: d.analysisBucket) }
            )
        }
        // 字段偏移测量的参考系（含 top/bottom padding，原点 = 输入条栈根 = UIKit 容器顶）
        .coordinateSpace(name: "chatInputBar")
        // chip 行插拔改变 growth 的 chip 分量（行消失时测高回调不再来，这里兜清零/重算）
        .onChange(of: hasChipRow) { _, _ in
            kickBarLayout()
            KeyboardInsetBridge.shared.barKick.send()
        }
        // 控制行显隐（kbUp 驱动）= 栈高变化，同样要踢 UIKit 层跟上（KB-P3）
        .onChange(of: keyboardBridge.kbVisible) { _, _ in
            KeyboardInsetBridge.shared.barKick.send()
        }
        #else
        .padding(.horizontal, metrics.composerInsetH)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .frame(maxWidth: Theme.contentMaxWidth)
        // 全屏模式：她在参数台里再往里收 / 再加间距（默认都是 0 = 现状不动）。
        // 门控住——这一段是 mode 无关的，不门控她一拖滑杆浮窗的输入条也跟着缩（R-FS I4）
        .padding(.horizontal, macChatCarded ? MacShellMetrics.shared.composerInset : 0)
        .padding(.top, macChatCarded ? MacShellMetrics.shared.composerGap : 0)
        .frame(maxWidth: .infinity)
        .background(macChatCarded ? Color.clear : Theme.mainBg)
        #endif
        #if os(iOS)
        .sheet(isPresented: $showModelPicker) {
            modelPickerContent
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        #else
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
            modelPickerContent
        }
        #endif
        // 问问题选择卡（API 工具循环 + CC 桥双源）：pending 且属于当前对话才弹。
        // 拖拽关闭走 set(false) → dismissActiveAskCard（API=剩余跳过回灌 / CC=整卡 Esc）；
        // 程序性收起（答完/cancel/切对话）时 pending 已 nil / get 已 false，guard 自然 no-op，
        // 切对话不误跳过——切回来 pending 还在会重新弹。
        .sheet(isPresented: Binding(
            get: {
                let convId = viewModel.selectedConversation?.id
                if let p = viewModel.pendingUserQuestion { return p.conversationId == convId }
                if let c = viewModel.pendingCCQuestion { return c.chatId == convId }
                return false
            },
            set: { if !$0 { viewModel.dismissActiveAskCard() } }
        )) {
            AskUserQuestionSheet(viewModel: viewModel)
        }
        // 权限 askOnce 弹卡的宿主 T6c ② 挪到根视图（MemoryPalaceApp 的 WindowGroup）——
        // 挂这儿会跟下面那些 sheet/alert/fileImporter 抢同一个 view 的 present 名额
        .onAppear {
            providerManager.resolveStaleSelectedModel()
            providerManager.resolveStaleFavorites()
        }
        .onChange(of: viewModel.editingMessage?.token, initial: true) { _, _ in applyEditingIfNeeded() }
        .onChange(of: viewModel.composerInsert?.token) { _, _ in applyComposerInsert() }
        .onChange(of: viewModel.cardSendRequest?.token) { _, _ in applyCardSend() }
        .animation(.easeOut(duration: 0.22), value: isEditingMessage)
        #if os(iOS)
        // 编辑卡插拔 = 栈高变化，同 chip 行：踢 UIKit 容器 re-solve（Bug3 同款）
        .onChange(of: isEditingMessage) { _, _ in
            kickBarLayout()
            KeyboardInsetBridge.shared.barKick.send()
        }
        #endif
        .alert("预算保险闸", isPresented: Binding(
            get: { viewModel.budgetBlockedMessage != nil },
            set: { if !$0 { viewModel.budgetBlockedMessage = nil } }
        )) {
            Button("好") { viewModel.budgetBlockedMessage = nil }
        } message: {
            Text(viewModel.budgetBlockedMessage ?? "")
        }
    }

    /// 返回 true 表示发送成功（子 view 应清空 text），false = 预算被拦（text 保留）
    private func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !selectedAttachments.isEmpty else { return false }

        let prof = profileManager?.currentProfile ?? Profile(name: "", emoji: "", description: "", userName: "你", assistantName: "AI")
        let preset = presetManager?.preset(byId: prof.presetId) ?? Preset.balanced

        // 编辑旧消息：走 editAndResend 开新分支（v1 纯文字）；失败返回 false 字留在框里
        if let editing = viewModel.editingMessage {
            viewModel.selectedConversation?.selectedModelId = currentModel.id
            guard viewModel.editAndResend(editing.nodeId, newText: trimmed, attachments: selectedAttachments,
                                          replyToId: viewModel.quotingReplyTo, replyQuote: viewModel.quotingPreview, isEdit: true,
                                          model: currentModel, profile: prof, preset: preset,
                                          providerManager: providerManager, context: modelContext) else { return false }
            // 失败什么都不清；成功后编辑用的附件 / 引用清掉（CC 头已读完），放回草稿要排在子 view 清空之后
            selectedAttachments = []
            viewModel.clearQuoting()
            DispatchQueue.main.async { endEditing() }
            return true
        }
        let modelInput = ChatAttachmentPromptBuilder.modelInput(text: trimmed, attachments: selectedAttachments)

        // 预算 pre-check：被拦时返回 false，子 view 保留 text
        guard viewModel.preCheckBudget(
            text: modelInput,
            model: currentModel,
            profile: prof,
            preset: preset,
            providerManager: providerManager
        ) else { return false }

        // 认领：把这条消息实际用的模型记到对话上（点1：下次打开=最后一条消息的模型）
        viewModel.selectedConversation?.selectedModelId = currentModel.id
        // globalWorldBookEntries 已由 ContentView 同步
        viewModel.sendMessage(
            trimmed,
            model: currentModel,
            profile: prof,
            preset: preset,
            providerManager: providerManager,
            context: modelContext,
            attachments: selectedAttachments
        )
        selectedAttachments = []
        // 发送后清空该对话的草稿持久化（draftText 由子 view 清空）
        viewModel.selectedConversation?.draftText = ""
        viewModel.selectedConversation?.draftAttachmentsData = nil
        viewModel.selectedConversation?.draftQuotePreview = ""
        viewModel.selectedConversation?.draftQuoteReplyTo = ""
        return true
    }

    private var bottomControlRow: some View {
        HStack(spacing: 8) {
            #if os(macOS)
            // 「+」进面板态：附件 / 相册 / 贴纸 / 便签 / 画板 / 风格都在面板里，底排只剩它和模型胶囊——跟 iOS（面 4.1b，⧫1）
            Button { onStickerTap?() } label: {
                MacShellLabel(symbol: "plus").fixedSize()
            }
            .buttonStyle(MacShellButton(compact: true, horizontalPadding: 7))
            .help("附件、相册、贴纸、风格")
            #endif

            Spacer()

            ModelCapsule(cardName: currentModel.name, entry: capsuleModelEntry) { showModelPicker.toggle() }
            #if os(iOS)
                .padding(.trailing, 8) // 模型胶囊左移 8px（粟粟实调）
            #endif
        }
        .padding(.horizontal, 4)
    }

    /// 模型选择器正文两端同一份（面 0.2 去重）：iOS 走 .sheet(+detents)，mac 走 .popover
    @ViewBuilder
    private var modelPickerContent: some View {
        ModelPickerPopover(
            providerManager: providerManager,
            selectedModelId: currentModel.id,
            onSelect: { model in
                viewModel.selectedConversation?.selectedModelId = model.id
                selectedModelId = model.id
                // 切到 Codex 模型时自动配一个 codex 会话（防呆：没绑 mp-codex-* 就发消息
                // 会经 hub fallback 落到 claude 默认会话——引擎和会话必须成对）
                if model.credentialId == "codex-bridge",
                   let conv = viewModel.selectedConversation,
                   !(conv.ccBridgeSessionName?.hasPrefix("mp-codex") ?? false) {
                    conv.ccBridgeSessionName = "mp-codex-1"
                }
                try? modelContext.save()
                providerManager.touchLastUsed(credentialId: model.credentialId, modelId: model.modelId)
                showModelPicker = false
            },
            presetManager: presetManager,
            profileManager: profileManager,
            ccBridgeConversation: viewModel.selectedConversation,
            onCCSessionPick: { newSession in
                if let conv = viewModel.selectedConversation {
                    conv.ccBridgeSessionName = newSession
                    try? modelContext.save()
                }
                showModelPicker = false
            }
        )
    }

}

// MARK: - ChatInputBar Equatable (B3 性能优化)
//
// 目的：流式响应期间 CardFlowView body 因读 viewModel.providerRouter.streamingText 每
// token 重算 → ContentView.iOSLayout 重算 → PagingContainerView.updatePages 无条件
// 大锤 → child HC.rootView 替换 → ChatInputBar 整棵重 diff（log 实测 326 次 / 19 次
// ContentView.body，放大 17×）。
//
// EquatableView 拦下"父重建传来的 instance 相等" case，body 跳过。@FocusState /
// @State / @AppStorage / @Observable 的 invalidation 走独立通路，focus/打字/流式
// isStreaming/切对话 的响应都还在。
//
// 5 个 class ref 跨 session 稳定，切楼层由 ContentView.id(profile.id) 重建整棵 →
// ref 全换 → == false → 重算。onStickerTap 闭包 nil/non-nil 二值：iOS 永远 non-nil、
// macOS 永远 nil，当前代码下 behavior 稳定；若未来 closure 变条件性，需加 UUID signal。
//
// Research: docs/research-chatinputbar-equatable.md
extension ChatInputBar: Equatable {
    static func == (lhs: ChatInputBar, rhs: ChatInputBar) -> Bool {
        lhs.viewModel === rhs.viewModel
            && lhs.modelContext === rhs.modelContext
            && lhs.profileManager === rhs.profileManager
            && lhs.providerManager === rhs.providerManager
            && lhs.presetManager === rhs.presetManager
            && (lhs.onStickerTap == nil) == (rhs.onStickerTap == nil)
    }
}

private struct AttachmentChipRow: View {
    let attachments: [PendingChatAttachment]
    let onRemove: (UUID) -> Void
    var quotePreview: String? = nil          // A4：引用预览（跟附件同排，排第一个）
    var onClearQuote: (() -> Void)? = nil
    /// 排队消息（id + 文本预览），✕ 取消排队写回输入框
    var pendingSends: [(id: UUID, preview: String)] = []
    /// §13 待捎带的事件（网页卡 report / 表情回应），✕ 删掉就不带了
    var cardEvents: [ChatCardEvent] = []
    var onRemoveCardEvent: ((String) -> Void)? = nil
    /// 语音小签试听：storedRef 相对这个楼层的文件库解析
    var voiceProfileId: String = ""
    var onCancelPending: ((UUID) -> Void)? = nil

    private let thumbH: CGFloat = 72
    #if os(iOS)
    @State private var previewIndex: IdentifiableInt?
    #else
    @State private var previewRequest: AttachmentPreviewRequest?
    #endif

    var body: some View {
        ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
            HStack(spacing: 6) {
                if let quotePreview {
                    quoteChip(quotePreview)
                }
                ForEach(attachments) { att in
                    if att.kind == .voice {
                        voiceChip(att: att)
                    } else if att.isImage, let data = att.imageData {
                        imageThumb(att: att, data: data)
                    } else if let card = att.chatCard {
                        cardChip(att: att, card: card)
                    } else {
                        fileChip(att: att)
                    }
                }
                ForEach(pendingSends, id: \.id) { pending in
                    pendingChip(pending.id, preview: pending.preview)
                }
                ForEach(cardEvents) { event in
                    cardEventChip(event)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .horizontalScrollEdgeFade()
        // 预发送附件预览：复用已发送那套 AttachmentPreviewSheet（图片全屏缩放 / 文件 QuickLook）
        .sheet(item: $previewIndex) { wrapper in
            AttachmentPreviewSheet(items: bubbleItems, initialIndex: wrapper.value)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
                .presentationCornerRadius(20)
        }
        #else
        .attachmentQuickLook($previewRequest)
        #endif
    }

    /// 点缩略图 / 文件 chip = 预览：iOS 复用已发送那套 sheet，mac 系统 QuickLook（面 3b）
    private func presentPreview(_ att: PendingChatAttachment) {
        #if os(iOS)
        if let idx = attachments.firstIndex(where: { $0.id == att.id }) {
            previewIndex = IdentifiableInt(value: idx)
        }
        #else
        previewRequest = AttachmentPreviewRequest(att)
        #endif
    }

    #if os(iOS)
    /// PendingChatAttachment → BubbleAttachmentItem（喂给已发送同款预览 sheet）
    private var bubbleItems: [BubbleAttachmentItem] {
        attachments.map { att in
            if att.isImage, let data = att.imageData {
                return .image(name: att.name, data: data)
            } else {
                return .file(name: att.name, type: att.typeDescription, content: att.extractedText)
            }
        }
    }
    #endif

    // 删除角标：可见叉仍 18pt 贴右上角，但命中区放大到 36（向左下扩进 chip）。
    // Button 在 ZStack 顶层 → 这 36 区内必胜（删除），其余才是预览 tap，治误触。
    // iOS 加删除震动（项目统一 UIImpactFeedbackGenerator）。
    private func removeButton(_ att: PendingChatAttachment) -> some View {
        Button {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            if att.kind == .voice, let ref = att.storedRef { VoiceMessagePlayer.shared.stop(id: ref) }   // 文件库里的文件不删
            onRemove(att.id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white, .black.opacity(0.5))
                .frame(width: 36, height: 36, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: -3, y: 3)
    }

    /// 图片缩略图两端一份（面 2.3，`PlatformImage` 工厂）；点图预览两端（iOS sheet / mac QuickLook，面 3b）
    private func imageThumb(att: PendingChatAttachment, data: Data) -> some View {
        ZStack(alignment: .topTrailing) {
            if let img = PlatformImage(data: data) {
                Image(platformImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbH, height: thumbH)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    // 点图片本体 = 预览；xmark Button 在上层各管各的（不嵌套 Button）
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { presentPreview(att) }
            }
            removeButton(att)
        }
    }

    // 引用 = 小方块（学官端：左竖条 + 文字，无图标），跟附件同尺寸 + xmark 角标
    private func quoteChip(_ text: String) -> some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.branchIndicator.opacity(0.6))
                    .frame(width: 2.5)
                Text(text)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(width: thumbH, height: thumbH)
            .attachmentFileBlockStyle(cornerRadius: 10)

            Button {
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                onClearQuote?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .frame(width: 36, height: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: -3, y: 3)
        }
    }

    // 排队消息 = 小方块（学 quoteChip：时钟 + 文字），✕ = 取消排队写回输入框
    private func pendingChip(_ id: UUID, preview: String) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 8))
                        .foregroundColor(Theme.textMuted)
                    Text("已排队")
                        .font(.system(size: 8))
                        .foregroundColor(Theme.textMuted)
                }
                Text(preview)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(width: thumbH, height: thumbH)
            .attachmentFileBlockStyle(cornerRadius: 10)

            Button {
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                onCancelPending?(id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .frame(width: 36, height: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: -3, y: 3)
        }
    }

    // §13 待捎带事件：同排队 chip 的小方块，标「捎带」
    private func cardEventChip(_ event: ChatCardEvent) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 8))
                        .foregroundColor(Theme.textMuted)
                    Text("捎带")
                        .font(.system(size: 8))
                        .foregroundColor(Theme.textMuted)
                }
                Text(event.text)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(width: thumbH, height: thumbH)
            .attachmentFileBlockStyle(cornerRadius: 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("捎带：\(event.text)")

            Button {
                onRemoveCardEvent?(event.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .frame(width: 36, height: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: -3, y: 3)
            .accessibilityLabel("不带这条")
        }
    }

    // 文件 = 小方块（学已发送 fileBlock：图标+名+类型），跟图片缩略图同尺寸 + xmark 角标
    private func fileChip(att: PendingChatAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Image(systemName: attachmentFileIcon(for: att.name))
                    .font(.system(size: 20))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
                Text(att.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if !att.typeDescription.isEmpty {
                    Text(att.typeDescription)
                        .font(.system(size: 8))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
            .frame(width: thumbH, height: thumbH)
            .attachmentFileBlockStyle(cornerRadius: 10)
            // 点方块本体 = 预览（QuickLook）；xmark Button 在上层各管各的
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { presentPreview(att) }

            removeButton(att)
        }
    }

    /// 语音小签（plan-voice-note M4b）：🎤 + 时长，点一下试听（再点暂停），✕ 移出附件条
    private func voiceChip(att: PendingChatAttachment) -> some View {
        let ref = att.storedRef ?? ""
        let playing = VoiceMessagePlayer.shared.state(for: ref) == .playing
        return ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Image(systemName: playing ? "pause.fill" : "mic.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
                Text(VoiceWave.clock(att.audioDuration ?? 0))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
                Text("语音")
                    .font(.system(size: 8))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
            .padding(.horizontal, 4)
            .frame(width: thumbH, height: thumbH)
            .attachmentFileBlockStyle(cornerRadius: 10)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                guard let url = FileLibraryStore.absoluteURL(ref, profileId: voiceProfileId) else {
                    ToastCenter.shared.show("语音文件不在了")
                    return
                }
                VoiceMessagePlayer.shared.toggle(url: url, id: ref)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("语音，\(VoiceWave.clock(att.audioDuration ?? 0))")
            .accessibilityAddTraits(.isButton)

            removeButton(att)
        }
    }

    /// 待发卡片（research-chat-cards §4.4）：外观同 fileChip，不接预览
    private func cardChip(att: PendingChatAttachment, card: ChatCard) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Image(systemName: {
                    switch card {
                    case .todo: return "checklist"
                    case .dice: return "dice"
                    case .timer: return "timer"
                    case .chart: return "chart.bar"
                    case .music: return "music.note"
                    case .ask: return "questionmark.bubble"
                    case .word: return "character.book.closed"
                    case .timeline: return "calendar.day.timeline.left"
                    }
                }())
                    .font(.system(size: 20))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
                Text(card.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(card.kindLabel)
                    .font(.system(size: 8))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .frame(width: thumbH, height: thumbH)
            .attachmentFileBlockStyle(cornerRadius: 10)

            removeButton(att)
        }
    }
}

#if os(iOS)
/// 附件条左右淡出遮罩的边状态（onScrollGeometryChange 用，需 Equatable）。
private struct ScrollFadeEdges: Equatable {
    let leading: Bool
    let trailing: Bool
}

/// 横向滚动条左右 alpha 淡出：内容溢出且该侧有隐藏内容才淡（滚到头/不溢出不淡）。
/// 预发送附件条 + 已发送附件条共用。.mask 让边缘 alpha 渐隐（露背景），不是盖白色。
private struct HorizontalScrollEdgeFade: ViewModifier {
    @State private var fadeLeading = false
    @State private var fadeTrailing = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollFadeEdges.self) { geo in
                ScrollFadeEdges(
                    leading: geo.contentOffset.x > 1,
                    trailing: geo.contentOffset.x < geo.contentSize.width - geo.containerSize.width - 1
                )
            } action: { _, edges in
                fadeLeading = edges.leading
                fadeTrailing = edges.trailing
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: fadeLeading ? 0.05 : 0),
                        .init(color: .black, location: fadeTrailing ? 0.95 : 1),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
    }
}

extension View {
    func horizontalScrollEdgeFade() -> some View { modifier(HorizontalScrollEdgeFade()) }
}
#endif

/// 附件文件图标（按扩展名）。预发送方块 + 已发送 fileBlock 共用。
private func attachmentFileIcon(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "pdf": return "doc.richtext"
    case "txt", "md", "markdown": return "doc.text"
    case "json", "csv", "xml", "yaml", "yml": return "doc.badge.gearshape"
    case "swift", "py", "js", "ts", "html", "css": return "chevron.left.forwardslash.chevron.right"
    default: return "doc"
    }
}

extension View {
    /// 文件附件方块底：奶油白填充 + 淡薄荷描边（学 page2 日历卡片样式）。
    /// 预发送 + 已发送共用，保持一致。
    func attachmentFileBlockStyle(cornerRadius: CGFloat) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.mainBg.opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.accent.opacity(0.72), lineWidth: 1)
            )
    }
}

// MARK: - InputFieldContainer — 独立子 view 持有 inputText
//
// 把 inputText + TextField + Send Button + glassEffect 封装成 fileprivate 子 view，
// 打字时只重建这个子 view（~80ms），外层 ChatInputBar（底部按钮行 /
// sheet / alert）不受影响。粟粟 2026-04-19 log 实测 150-170ms/字 → 预期 ≤80ms/字。

/// 发送键 = 停止键的防连点闸（T6c，粟粟 08-27 拍「按你推荐」）。
///
/// 三态设计里发送成功后 `text` 立刻清空、`isResponding` 翻真，**同一个按钮当场变成 stop**
/// （见 `InputFieldContainer.showStopButton`）。冷启动第一条最慢，自动化/用户
/// 「点了没反应再点一下」正好落在这瞬间，第二下就把整轮取消了，气泡只剩「（已停止）」
/// ——T6b 穷举调用链确认这是那行字的唯一来源。
///
/// 这里只堵那一瞬：发送后 500ms 内对 stop 的点击**忽略**（不取消、不重发、不弹东西），
/// 窗口过后行为一点不变。不换位、不加二次确认。
enum ComposerStopGuard {
    static let ignoreWindow: TimeInterval = 0.5

    /// `sentAt` = 上一次发送成功的时刻；nil = 这轮不是自己发起的（比如重新生成），不拦
    static func shouldIgnoreStopTap(sentAt: Date?, now: Date) -> Bool {
        guard let sentAt else { return false }
        let elapsed = now.timeIntervalSince(sentAt)
        // 负数 = 时钟往回跳（改系统时间）：当作窗口内，宁可漏一次 stop 也别误取消
        return elapsed < ignoreWindow
    }
}

/// 聊天页的输入框本体。编程会话详情页（阶段 B7）复用同一个——她要的就是「平常聊天那个输入框」，
/// 所以这里从 private 放开到模块内可见，别在别处再造一个
struct InputFieldContainer: View {
    @Environment(\.chatMetrics) private var metrics
    @Binding var text: String
    #if os(iOS)
    @Binding var isFocused: Bool
    #else
    @FocusState.Binding var isFocused: Bool
    #endif
    /// turn 级 busy（streaming + 工具执行 + 多轮 loop 全程），非 provider isStreaming
    let isResponding: Bool
    @AppStorage(LiquidMetalTuning.enabledKey) private var liquidMetalRingEnabled = true
    let hasAttachments: Bool
    let onSend: (String) -> Bool
    let onCancelStream: () -> Void
    // iOS 贴纸按钮内嵌到输入框左侧；macOS 无（nil）
    let onStickerTap: (() -> Void)?
    /// L3：当前 model 是否走 cc-bridge — 决定是否启用斜杠命令变色 + 浮板
    let isCCBridge: Bool
    /// 编辑旧消息时 AI 在回复：按钮恒为停止——编辑重发不排队，排队态点了会没反应（plan-edit-attachments H5）
    var stopWhileResponding: Bool = false
    /// 按住 waveform 录语音条（plan-voice-note M5，只有聊天页 iOS 开；编程会话详情页不开）
    var voiceEnabled: Bool = false
    /// 有语音在转文字：空闲无字时行内显示「转文字中…」
    var voiceTranscribing: Bool = false
    /// 「@ 文件库文件」（plan-input-file-mention）：nil = 不开（终端会话输入框）。选中把路径交出去，宿主后台抽取进附件条
    var profileId: String = ""
    var onPickFile: ((String) -> Void)? = nil

    @State private var mentionHits: [FileLibraryStore.FileMeta] = []
    /// mentionHits 是哪个 query 的结果：打字快于后台排名时，旧结果不许被选中（sol 审 #3）
    @State private var mentionHitsQuery: String? = nil
    @State private var mentionIndex = 0
    /// mac Esc 关掉的那次 query：换了字再出
    @State private var dismissedMention: String? = nil
    #if os(macOS)
    @State private var mentionKeyMonitor: Any? = nil
    /// 监视器只截这个窗口的键（多窗口不串，sol 审 #5）
    @State private var mentionKeyWindow: Int? = nil
    #endif

    /// 上一次发送成功的时刻，喂 `ComposerStopGuard`（防连点，见那个 enum 的注释）
    @State private var lastSentAt: Date? = nil

    private var canSend: Bool {
        isResponding || hasAttachments || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 空闲无字 = waveform 占位态（按住录语音条挂在这个态上）
    private var isVoicePlaceholder: Bool { !canSend && !showStopButton }

    #if os(iOS)
    private var voice: VoiceRecordController? { voiceEnabled ? .shared : nil }
    private var voicePhase: VoiceRecordController.Phase { voice?.phase ?? .idle }
    /// waveform 键这会儿能按住录（AI 回复中那个位置是停止键，不能录）
    private var voiceAvailable: Bool { voice != nil && isVoicePlaceholder }
    #else
    private var voiceAvailable: Bool { false }
    #endif

    // 按钮三态：空闲=发送 / busy+没打字=stop / busy+打了字=排队发送（带时钟角标）。
    // 没打字时唯一有意义的操作是停止；打了字说明想发下一条 → 点击入队，不必先 stop。
    // 代价：打了字想 stop 得先清空输入框（plan 批注定的取舍）。
    private var showStopButton: Bool {
        isResponding && (stopWhileResponding || (!hasAttachments && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }
    private var isQueueMode: Bool { isResponding && !showStopButton }

    /// 输入框字号基准（research-input-field §二①）：默认与正文基准 13.5 同，×fontScale + 用户字体 由 FontManager 统一
    @AppStorage("inputFontBase") private var inputFontBase: Double = 13.5
    private var inputFont: Font { FontManager.font(size: inputFontBase) }
    #if os(iOS)
    /// §二③ 换行布局：多行时按钮从两侧挪到底行（GPT 式）。
    /// ⚠️ 模式判定不能按**当前**字段宽测：发送键离行→字段变宽→文字回一行→发送键回来→又变窄……振荡
    ///（iu0831 审查阻断 1）。用「单行窄宽」做稳定坐标系 + 迟滞闸（切回留 40pt 余量）。
    /// 测量走 ChatInputTextView 静态测量器：同字体同 inset 的自家度量，boundingRect 估算已死。
    @State private var singleLineWidth: CGFloat = 0
    @State private var fieldWidth: CGFloat = 0
    /// input-jank C3：打字空闲态（键入后 600ms 无新键入）——驱动液态金属环暂停
    @State private var typingIdle = true
    @State private var showExpand = false
    @State private var isMultiline = false
    private var inputUIFont: UIFont { FontManager.uiFont(size: inputFontBase) }
    /// coordinator 判提交点 1 用的「模式探针宽」——必须与 `updateMultiline` 用的那个宽一致，
    /// 否则「多行删到能回单行了但本宽下高度没变」这一步不触发提交，回单行会滞后到 300ms 去抖。
    private var modeProbeWidth: CGFloat {
        let narrow = singleLineWidth > 0 ? singleLineWidth : 240
        return isMultiline ? narrow - 40 : narrow
    }
    private func updateMultiline() {
        let narrow = singleLineWidth > 0 ? singleLineWidth : 240
        let next: Bool
        if text.isEmpty {
            next = false
        } else if text.contains("\n") {
            next = true
        } else if !isMultiline {
            next = ChatInputTextView.lineCount(text: text, font: inputUIFont, width: narrow,
                                               inset: ChatInputTextView.singleInset) >= 2
        } else {
            next = ChatInputTextView.lineCount(text: text, font: inputUIFont, width: narrow - 40,
                                               inset: ChatInputTextView.singleInset) >= 2
        }
        guard next != isMultiline else { return }
        KBProbe.log("input multiline→\(next ? 1 : 0)")
        // input-jank C7b：SwiftUI 内容与 UIKit 容器用**同一条** easeOut(0.22) 一起动（容器侧见
        // PagingViewController 的 kick 处理）；按钮不再 hero 飞行（粟粟：只要一个 easeOut，不要复杂轨迹）
        withAnimation(.easeOut(duration: 0.22)) { isMultiline = next }
    }
    /// 放大钮：≥3 行就出（粟粟：第三四行就该有）。多行态字段宽稳定（右侧固定留 36），按当前宽测无振荡
    private var showExpandButton: Bool {
        guard isMultiline else { return false }
        return ChatInputTextView.lineCount(text: text, font: inputUIFont,
                                           width: fieldWidth > 0 ? fieldWidth : 330,
                                           inset: ChatInputTextView.multiInset) >= 3
    }
    #endif

    /// L3：text 开头是 / 时整段变荧光绿（IDE 代码色），仅在 ccBridge 路径下
    private var inputTextColor: Color {
        if isCCBridge && text.hasPrefix("/") {
            return Color(red: 0.22, green: 0.94, blue: 0.49)
        }
        return Theme.textPrimary
    }

    /// L3：是否显示斜杠命令浮板
    private var showSlashSuggestions: Bool {
        isCCBridge && text.hasPrefix("/")
    }

    /// 末尾 @token（iOS 靠提交点 10 逐键送到这里）
    private var mentionQuery: String? {
        onPickFile == nil || profileId.isEmpty ? nil : FileMention.query(in: text)
    }

    private var showMention: Bool { !showSlashSuggestions && !mentionHits.isEmpty }

    private func refreshMention(_ q: String?) async {
        guard let q, q != dismissedMention else {
            if q == nil { dismissedMention = nil }
            mentionHits = []
            mentionHitsQuery = nil
            return
        }
        let hits = await FileMention.suggestions(for: q, profileId: profileId)
        // 回来时再核一次：期间 Esc 关掉了 / 又打了字，这批结果作废（sol 审 #4）
        guard !Task.isCancelled, q == mentionQuery, q != dismissedMention else { return }
        mentionHits = hits
        mentionHitsQuery = q
        mentionIndex = 0
    }

    /// 选中候选：删掉末尾「@字」，文件交给宿主进附件条
    private func pickMention(_ path: String) {
        #if os(iOS)
        // 同排队消息回填（提交点 8）：先定稿组字再读 tv 真相，别拿落后的 binding 拼
        ChatInputHandle.shared.finalizeCompositionAndCommit()
        let base = ChatInputHandle.shared.liveText ?? text
        #else
        let base = text
        #endif
        // 候选必须是当前尾部 query 的结果，否则点到的是上一个字时的旧候选（sol 审 #3）
        guard FileMention.query(in: base) == mentionHitsQuery else { return }
        let next = FileMention.removingQuery(from: base)
        text = next
        #if os(iOS)
        ChatInputHandle.shared.issueText(next)   // 命令通道：删字即时落 tv
        #endif
        mentionHits = []
        mentionHitsQuery = nil
        onPickFile?(path)
    }

    #if os(macOS)
    /// 候选开着时截 ↑↓ / 回车 / Tab / Esc（回车不换行不发送）。本地事件监视器：TextField 的字段编辑器先吃方向键，onKeyPress 拿不稳
    private func syncMentionKeyMonitor(_ on: Bool) {
        if on, mentionKeyMonitor == nil {
            mentionKeyWindow = NSApp.keyWindow?.windowNumber
            mentionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                handleMentionKey(e) ? nil : e
            }
        } else if !on, let m = mentionKeyMonitor {
            NSEvent.removeMonitor(m)
            mentionKeyMonitor = nil
        }
    }

    private func handleMentionKey(_ e: NSEvent) -> Bool {
        let n = mentionHits.count
        guard n > 0, !showSlashSuggestions, isFocused, e.window?.isKeyWindow == true,
              let w = mentionKeyWindow, e.window?.windowNumber == w else { return false }
        if let editor = e.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch e.keyCode {
        case 126: mentionIndex = (mentionIndex - 1 + n) % n          // ↑
        case 125: mentionIndex = (mentionIndex + 1) % n              // ↓
        case 36, 76, 48: pickMention(mentionHits[min(mentionIndex, n - 1)].path)   // 回车 / 小键盘回车 / Tab
        case 53:                                                     // Esc
            dismissedMention = mentionQuery
            mentionHits = []
            mentionHitsQuery = nil
        default: return false
        }
        return true
    }
    #endif

    var body: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = AirPerfProbe.enabled ? AirPerfProbe.shared.noteCC(isCCBridge) : ()
        #endif
        #if DEBUG
        let _ = {
            PerfCounters.inputFieldBody += 1
            print(String(format: "[PERF] InputFieldContainer.body #%d t=%.3f len=%d",
                         PerfCounters.inputFieldBody,
                         CFAbsoluteTimeGetCurrent(),
                         text.count))
            #if os(iOS)
            InputPerfProbe.publish(bar: PerfCounters.chatInputBarBody, field: PerfCounters.inputFieldBody)
            #endif
        }()
        #endif
        return VStack(spacing: 6) {
            // L3: 斜杠命令 autocomplete 浮板（仅 ccBridge model + text 开头是 /）
            if showSlashSuggestions {
                CCSlashCommandSuggestions(prefix: text) { picked in
                    // 命令名 + 占位符 + 空格 → 让粟粟继续打参数
                    text = picked + " "
                    #if os(iOS)
                    ChatInputHandle.shared.issueText(picked + " ")   // 命令通道：补全即时落 tv
                    #endif
                }
            }

            // @ 文件库候选（plan-input-file-mention）：同一挂载位，两端都有；斜杠浮板优先
            if showMention {
                #if os(macOS)
                FileMentionSuggestions(hits: mentionHits, profileId: profileId, highlighted: mentionIndex, onPick: pickMention)
                #else
                FileMentionSuggestions(hits: mentionHits, profileId: profileId, onPick: pickMention)
                #endif
            }

            fieldBox
                #if os(macOS)
                .padding(10)
                .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(isFocused ? Theme.branchIndicator : ShellStyle.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                #else
                // 输入框 chrome 两端同一句（面 4.4，C4）：iOS 26 / mac 26 真玻璃，mac 15 退材质 + hairline（ShellGlass shim，tint 与原 iOS 参数逐项相同）
                .shellGlass(in: .rect(cornerRadius: 20), tint: 0.15, interactive: true)
                #endif
                // S1 fix: glassEffect .interactive() 在真机上 tap-through 有时序延迟
                // （经粟粟 iPhone 17 Air A/B 测确认）。在外层抢焦点绕过去，保留玻璃发光视觉。
                // mac 同款（面 5.3）：点到框内留白也聚焦；AppKit 文本框自己吃鼠标，落不到这层
                .contentShape(Rectangle())
                .onTapGesture { KBProbe.log("tap-glass → focus"); isFocused = true }
        } // end VStack（浮板 + 输入框）
        .task(id: mentionQuery) { await refreshMention(mentionQuery) }
        #if os(macOS)
        .onChange(of: showMention && isFocused, initial: true) { _, on in syncMentionKeyMonitor(on) }
        .onDisappear { syncMentionKeyMonitor(false) }
        #endif
    }

    // 输入框本体一处分平台（面 5.3）：iOS 的占位 / 框 / 垫高 / 钉底按钮 overlay / 放大 sheet / 金属环全在这一份，mac 一行 TextField + 发送键；
    // chrome（shellGlass）和点框聚焦在 body 里两端一份。
    #if os(iOS)
    /// 输入框本体（research-input-field §二③）：TextField 永远在同一个 HStack 同一位置（身份稳定=不丢焦点），
    /// 单行时 + / 发送做它的左右兄弟（原样）；多行时兄弟消失、底下出 GPT 式按钮行；到上限开始内滚时右上角出放大钮。
    private var fieldBox: some View {
        VStack(spacing: 0) {
        HStack(alignment: .center, spacing: 0) {
        // 按钮钉位（09-03 粟粟「按钮不要闪」）：+/发送不再随单行⇄多行换容器——两个形态下它们的
        // 屏幕位置本就重合（抽帧实证中心同坐标），改成胶囊 overlay 常驻钉底（见下方 .overlay），
        // 布局里只留等宽透明占位。稳态外观逐像素不变，过渡期按钮零消失零位移。
        if onStickerTap != nil, !isMultiline { Color.clear.frame(width: 38, height: 44) }

        // UIKit 化文本框（research-input-uikit 方案 B）：inset 承担 padding（单行 6/10、多行 15/15/2/36），
        // 高度经 sizeThatFits 报给 SwiftUI，光标/内滚/指示条全原生。a11y id 在 view 自身。
        // input-jank C2：`text` 语义 = 「**提交后**文本」。稳态打字不进 SwiftUI——
        // coordinator 持 UITextView 真相，只在提交点（行数/高度变、焦点变、空⇄非空、
        // `/` 翻转、斜杠逐键、300ms 去抖）写回这个 Binding。
        ChatInputRepresentable(text: $text,
                               focused: $isFocused,
                               typingIdle: $typingIdle,
                               font: inputUIFont,
                               textColor: UIColor(inputTextColor),
                               isMultiline: isMultiline,
                               modeProbeWidth: modeProbeWidth,
                               slashLive: isCCBridge)
            // 录语音时行内换成红点计时 / 预览（plan-voice-note M5b）：文本框留在原位只藏起来，输入条高度不变
            .opacity(voicePhase == .idle ? 1 : 0)
            .onChange(of: isFocused) { _, f in KBProbe.log("focus=\(f ? 1 : 0)") }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { sz in
                fieldWidth = sz.width
                if !isMultiline { singleLineWidth = sz.width }
            }
            // C2 后这条只在提交点跑（不再每键）；C3 的 typingIdle 已挪进 coordinator，
            // 那里每键重排定时器、只在翻转时写 SwiftUI
            .onChange(of: text) { _, _ in updateMultiline() }
            .onChange(of: singleLineWidth) { _, _ in updateMultiline() }
            #if DEBUG
            .onChange(of: text) { _, newVal in
                print(String(format: "[PERF] TextField onChange len=%d t=%.3f", newVal.count, CFAbsoluteTimeGetCurrent()))
            }
            #endif

        if !isMultiline { Color.clear.frame(width: 48, height: 44) }
        } // end HStack（字段行）
        // 多行底部按钮区：纯占位撑高度（按钮本体在 overlay 钉死，见上）
        Color.clear.frame(height: isMultiline ? 42 : 0)
        } // end VStack（输入框本体）
        // 换行/切换按曲线（GPT 轨迹）：容器高度与按钮位置随文本变化做 0.22s easeOut；
        // 按钮靠 matchedGeometryEffect 在两个落位之间飞（不是淡出再淡入，所以没重影）
        .overlay(alignment: .topTrailing) {
            if showExpandButton {
                Button {
                    // 提交点 8（kimi B1）：sheet 直接绑 $text，打开前先把 UITextView 里
                    // 还没提交的尾巴刷进 binding，否则最后 300ms 打的字不出现在 sheet 里、
                    // 且 sheet 第一次回写就把它覆盖掉
                    ChatInputHandle.shared.commitNow()
                    isFocused = false
                    showExpand = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .padding(.trailing, 8)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showExpandButton)
        // 录语音行内三态 / 转文字中（plan-voice-note M5b）：盖在单行文本框那一段（左让 + 号 38、右让发送键 48）
        .overlay(alignment: .leading) {
            if let voice {
                VoiceInlineRow(voice: voice, transcribing: voiceTranscribing && isVoicePlaceholder)
                    .padding(.leading, 38)
                    .padding(.trailing, 48)
            }
        }
        // 按钮本体：胶囊 overlay 钉底（bottomLeading/bottomTrailing）。单行行高 44（send 外框）
        // 与多行底行（40+2 底距）里按钮中心同为「胶囊底上方 22pt」——plus 32 高补 6pt 底距对齐。
        // 全程一颗按钮：不换容器、不插拔、不裁剪，形态切换零闪烁（粟粟 09-03）。
        .overlay(alignment: .bottomLeading) {
            if onStickerTap != nil { plusButton().padding(.bottom, 6) }
        }
        .overlay(alignment: .bottomTrailing) {
            sendButton
        }
        // 浮层对位：发送键 / + 号 / 行内红点的位置都从这个框推（写进不被观察的 live，不触发重算）
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("chatInputBar")) }) { frame in
            voice?.geometryChanged(fieldBox: frame)
        }
        .sheet(isPresented: $showExpand, onDismiss: {
            // 命令通道：主框不再消费 binding，sheet 编辑的定稿文本关闭时显式交回
            ChatInputHandle.shared.issueText(text)
        }) {
            // sheet 里的真相是 ExpandInputTextView 提交的 binding，发送走 binding
            // 值而不是 tv.text（kimi 轴②：sheet 最后一次击键的外部写落没落 tv 不该由这条路依赖；
            // T7-R2 后组字确认即提交，binding 在点发送时必为最新）
            InputExpandSheet(text: $text, uiFont: FontManager.uiFont(size: inputFontBase), canSend: canSend) { triggerSend(fromBinding: true) }
        }
        // 键盘在（焦点在）时描一圈会流动的金属环（metal-fx 直译，research-liquid-metal-input）。
        // 放在 glassEffect **之前** = 环是玻璃的内容层，长按 interactive 弹缩时跟玻璃一起缩（放 overlay 在外面会穿模）。
        // if 挂载不用 opacity 0 常驻，收键盘 shader 不白跑；animation 只作用于这个 ZStack 子树
        .overlay {
            ZStack {
                if isFocused && liquidMetalRingEnabled {
                    LiquidMetalRing(cornerRadius: 20, paused: !typingIdle).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: isFocused)
        }
    }
    #else
    private var fieldBox: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发消息…", text: $text, axis: .vertical)
                // 复现器定位锚：气泡正文在 XCUI 树里同为 TextView，无 id 时 firstMatch 会抓错
                .accessibilityIdentifier("chat-input-field")
                .textFieldStyle(.plain)
                .font(inputFont)
                .foregroundColor(inputTextColor)
                .lineLimit(1...6)
                .focused($isFocused)
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        // Let the native editor finish IME composition before sending.
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
                            return .ignored
                        }
                        triggerSend()
                        return .handled
                    }
                    return .ignored
                }
            sendButton
                .help(showStopButton ? "停止回复" : "发送消息（⌘↩）；Return 换行")
        }
    }
    #endif

    #if os(iOS)
    /// inline = 行内落位（单行）；底行落位传 false。hero 匹配：只有**当前展示**的落位是 source，
    /// 否则过渡期间两个 source 并存 → 匹配失败退化成淡出淡入（60fps 抽帧实证按钮原地待 6 帧再瞬移）
    private func plusButton() -> some View {
        Button(action: { onStickerTap?() }) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Theme.textMuted.opacity(0.5))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 录语音取消：红点飞回 + 号绽成点点花，+ 号先缩没、1000ms 弹回；录音期间不接点按（会把输入条换成面板）
        .scaleEffect(voice?.plusHidden == true ? 0.001 : 1)
        .allowsHitTesting(voicePhase == .idle)
        .padding(.leading, 6)
        .transition(.identity)   // C7b：换行时按钮直接落位，不飞、不淡出重影
    }
    #endif

    private var sendButton: some View { sendButtonCore() }

    private func sendButtonCore() -> some View {
        #if os(iOS)
        // 录语音预览态：waveform 位置变成薄荷发送（发这条录音）；录音中 / 锁定：让位给浮层大按钮
        let previewing = voicePhase == .preview
        let capturing = voicePhase == .recording || voicePhase == .locked
        #else
        let previewing = false
        let capturing = false
        #endif
        let mintSend = canSend || previewing
        return Button(action: { triggerSend() }) {
            // 空闲没打字 = 按住录语音条（waveform）；打字/有附件 = 薄荷发送；busy 态 stop/排队不变。
            Image(systemName: showStopButton ? "stop.fill" : (mintSend ? "arrow.up" : "waveform"))
                .font(.system(size: metrics.sendIconSize, weight: .semibold))
                .foregroundColor(mintSend ? .white : Theme.textMuted.opacity(0.55))
                .frame(width: metrics.sendFrame, height: metrics.sendFrame)
                .background(
                    Circle().fill(
                        showStopButton
                            ? Theme.danger
                            : mintSend ? Theme.branchIndicator : Color.clear
                    )
                )
                .scaleEffect(capturing ? 0.3 : 1)
                .opacity(capturing ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: capturing)
                // 排队态角标：busy 期间点发送 = 入队不打断，时钟提示「会排队」
                .overlay(alignment: .bottomTrailing) {
                    if isQueueMode {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(2)
                            .background(Circle().fill(Theme.textMuted))
                            .offset(x: 3, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        // waveform 占位能按住录语音时保持可交互（tap 在 triggerSend 里 no-op / 预览态 = 发送，按住交给 VoiceHoldGesture）
        .disabled(!canSend && !voiceAvailable)
        #if os(iOS)
        .frame(width: 44, height: 44)
        .modifier(VoiceHoldGesture(voice: .shared, enabled: voiceAvailable && voicePhase != .preview))
        // 太短：抖一下（小样 .shake：-5 / 5 / -3 / 3，0.35s）
        .keyframeAnimator(initialValue: CGFloat(0), trigger: voice?.shakeToken ?? 0) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(CGFloat(-5), duration: 0.07)
                LinearKeyframe(CGFloat(5), duration: 0.07)
                LinearKeyframe(CGFloat(-3), duration: 0.07)
                LinearKeyframe(CGFloat(3), duration: 0.07)
                LinearKeyframe(CGFloat(0), duration: 0.07)
            }
        }
        // VoiceOver 拖不了：「开始录音」直接进锁定态，再触发一次停下进预览（plan-voice-note M5d）
        .accessibilityActions {
            if voiceAvailable, let voice, voicePhase != .preview {
                Button(voicePhase == .idle ? "开始录音" : "停止录音") { voice.accessibilityToggle() }
            }
        }
        .transition(.identity)   // C7b：换行时按钮直接落位，不飞、不淡出重影
        #endif
        .padding(.trailing, 4)
    }

    /// `fromBinding`：放大 sheet 的发送路径——那边的真相是 TextEditor 写的 binding。
    /// 默认（输入条自己的发送键）读 UITextView：提交点 5，**发出去的文本 == 屏幕上的文本**，
    /// 不等 300ms 去抖（C2 不变量）。
    private func triggerSend(fromBinding: Bool = false) {
        if showStopButton {
            // 刚发出去那 500ms 里的第二下：整个吞掉，不取消也不震
            if ComposerStopGuard.shouldIgnoreStopTap(sentAt: lastSentAt, now: Date()) { return }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            onCancelStream()
            return
        }
        // waveform 占位态：tap 无操作（按住才录）；录语音预览态 = 发这条录音
        if isVoicePlaceholder {
            #if os(iOS)
            if voicePhase == .preview { voice?.sendPreview() }
            #endif
            return
        }
        // busy + 有内容 → onSend 内部（sendMessage）自动排队，返回 true 清输入框
        #if os(iOS)
        // ime-residual T1：发送即定稿——组字中点发送先 unmark（冻结**当刻拼音串**，非选首候选），
        // 发出文本==屏幕文本、binding 同拍、IME 会话干净收束。预算拦截时组字已被定稿属预期（记债 3）。
        // sheet 路径（fromBinding）是另一颗 TextEditor，把手管不到，走 binding（记债 4）。
        let outgoing: String
        if fromBinding {
            outgoing = text
        } else {
            ChatInputHandle.shared.finalizeCompositionAndCommit()
            outgoing = ChatInputHandle.shared.liveText ?? text
        }
        #else
        let outgoing = text
        #endif
        if onSend(outgoing) {
            text = ""
            #if os(iOS)
            // 命令通道（plan-input-command-channel）：清空即时落 tv，不再依赖 binding 推断
            ChatInputHandle.shared.issueText("")
            #endif
            lastSentAt = Date()   // 防连点窗起点（两端都要）
            #if os(iOS)
            // 发送/暂停都微微震一下（粟粟 08-25）
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // 发送成功自动收键盘（粟粟：不然弹泡动画被键盘挡着看不见）。
            // 置发送瞬收窗：这次收键盘不走滑出让位动画（发送大跳案，见 bridge 注释）
            KBProbe.log("send len=\(text.count) growth=\(Int(KeyboardInsetBridge.shared.barGrowth)) fieldOff=\(Int(KeyboardInsetBridge.shared.fieldOffsetInBar))")
            KeyboardInsetBridge.shared.sendDismissUntil = CACurrentMediaTime() + 1.0
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
        }
        // 预算被拦 → 保留 text
    }
}

// MARK: - Model Picker Popover

struct ModelPickerPopover: View {
    let providerManager: ProviderManager
    let selectedModelId: String
    let onSelect: (ProviderModel) -> Void
    var presetManager: PresetManager? = nil
    var profileManager: ProfileManager? = nil

    /// L2：当前对话；非 nil + 当前 model 是 ccBridge 时，popover 顶部显示 CC Session section
    var ccBridgeConversation: Conversation? = nil
    /// L2：CC session 选定回调（写 conversation.ccBridgeSessionName + dismiss popover）
    var onCCSessionPick: ((String?) -> Void)? = nil

    /// M4：永远只显示 ☆ 收藏模型。收藏空时给空态引导（去设置加 ☆）；不再 fallback 全部 enabled。
    private var groupedSource: [(APICredential, [ProviderModel])] {
        providerManager.favoritesByCredential
    }

    private var hasAnyCredentialWithKey: Bool {
        providerManager.credentials.contains { providerManager.isUsable($0) }
    }

    /// 「＋ 从 xx 添加模型」点开的那张卡（就地列出它没收藏的模型，点一个 = 收藏并选中；#092 D）
    @State private var expandedCredentialId: String?

    private func unfavorited(_ c: APICredential) -> [ProviderModel] {
        c.models.filter { !providerManager.isFavoriteModel(id: $0.id) }
    }

    /// 能用、但一个模型都没收藏的卡：在收藏分组下面各给一行「＋」
    private var cardsWithoutFavorites: [APICredential] {
        let shown = Set(groupedSource.map(\.0.id))
        return providerManager.credentials.filter {
            !shown.contains($0.id) && providerManager.isUsable($0) && !$0.models.isEmpty
        }
    }

    @ViewBuilder
    private func addFromCardRows(_ c: APICredential) -> some View {
        let others = unfavorited(c)
        if !others.isEmpty {
            let open = expandedCredentialId == c.id
            Button {
                expandedCredentialId = open ? nil : c.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "plus")
                        .font(.system(size: Theme.F.caption, weight: .semibold))
                    Text("从 \(c.emoji) \(c.name) 添加模型")
                        .font(.system(size: Theme.F.caption))
                    Spacer()
                }
                .foregroundColor(Theme.branchIndicator)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(others, id: \.id) { model in
                    Button {
                        providerManager.toggleFavoriteModel(id: model.id)
                        expandedCredentialId = nil
                        onSelect(model)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "star")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted.opacity(0.6))
                            Text(model.name)
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textSecondary)
                            Spacer()
                        }
                        .padding(.leading, 24)
                        .padding(.trailing, 10)
                        .padding(.vertical, Theme.optionRowVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// L2：当前选中的 model 是否走 ccBridge
    private var isCurrentModelCCBridge: Bool {
        guard let m = providerManager.model(byId: selectedModelId) else { return false }
        return providerManager.credential(for: m)?.type == .ccBridge
    }

    /// codex-bridge 卡 = codex 引擎（同通道，session picker 列 mp-codex-*）
    private var currentBridgeEngine: String {
        guard let m = providerManager.model(byId: selectedModelId) else { return "claude" }
        return providerManager.credential(for: m)?.id == "codex-bridge" ? "codex" : "claude"
    }

    var body: some View {
        let source = groupedSource

        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                // L2: CC Session section — 仅在当前 model 是 ccBridge 且有对话时显示
                if isCurrentModelCCBridge,
                   let conv = ccBridgeConversation,
                   let pick = onCCSessionPick {
                    CCSessionPickerContent(conversation: conv, engine: currentBridgeEngine, onPick: pick)
                    Divider()
                        .padding(.vertical, 4)
                }

                if let psm = presetManager, let pm = profileManager {
                    ReasoningPickerRow(
                        presetManager: psm,
                        profileManager: pm,
                        providerManager: providerManager,
                        selectedModelId: selectedModelId
                    )
                    Divider().opacity(0.15).padding(.horizontal, 10)
                }

                if source.isEmpty && cardsWithoutFavorites.isEmpty {
                    emptyFavoritesState
                } else {
                    ForEach(source, id: \.0.id) { pair in
                        let credential = pair.0
                        let models = pair.1

                        HStack(spacing: 4) {
                            ProviderIconView(presetId: credential.presetId, displayName: credential.name,
                                             size: AppIconSize.mini, tint: Theme.textMuted)
                            Text(credential.name)
                                .font(.system(size: Theme.F.caption, weight: .semibold))
                                .foregroundColor(Theme.textMuted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                        ForEach(models, id: \.id) { model in
                            let isSelected = model.id == selectedModelId
                            Button {
                                onSelect(model)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: Theme.F.body))
                                        .foregroundColor(isSelected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                                    Text(model.name)
                                        .font(.system(size: Theme.F.body))
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, Theme.optionRowVerticalPadding)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected ? Theme.accent.opacity(0.4) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        addFromCardRows(credential)
                    }
                    ForEach(cardsWithoutFavorites, id: \.id) { c in
                        addFromCardRows(c)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            #if os(macOS)
            .frame(width: 260)
            #else
            .frame(maxWidth: .infinity)
            #endif
        }
        #if os(macOS)
        .frame(maxHeight: 360)
        #endif
    }

    @ViewBuilder
    private var emptyFavoritesState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "star")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
                Text(hasAnyCredentialWithKey ? "还没有收藏的模型" : "还没有 API")
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            Text(hasAnyCredentialWithKey
                 ? "去 设置 → API → 全部模型，收藏几个常用的，这里就显示了。"
                 : "去 设置 → API 加一张 API key 卡，再到「全部模型」里收藏几个模型。")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
    }
}

private struct ReasoningPickerRow: View {
    let presetManager: PresetManager
    let profileManager: ProfileManager
    let providerManager: ProviderManager
    let selectedModelId: String
    /// 档位存在 UserDefaults 字典里，不会自动刷新：选完 +1 让滑块重画
    @State private var bump = 0

    private var currentPreset: Preset {
        let prof = profileManager.currentProfile
        return presetManager.preset(byId: prof.presetId) ?? Preset.balanced
    }

    /// 当前模型走哪条路 + 凭据 id（档位按「凭据 / 模型」各记各的，research-reasoning-effort §2.2）
    private var resolved: (route: ReasoningEffort.Route, credentialId: String, modelId: String)? {
        guard let model = providerManager.model(byId: selectedModelId),
              let provider = providerManager.provider(for: model) else { return nil }
        return (ReasoningEffort.route(providerType: provider.type, credentialId: provider.id,
                                      baseURL: provider.baseURL, modelId: model.modelId),
                provider.id, model.modelId)
    }

    /// 第一格永远是「默认」（不发，用官方默认）；后面是这个模型能选的档位（模型目录 → 补表）
    private var stops: [(label: String, value: String)] {
        let route = resolved?.route ?? .chatCompletions
        let levels = resolved.map { ReasoningEffort.levels(route: $0.route, modelId: $0.modelId) } ?? []
        return [(ReasoningEffort.label(ReasoningEffort.auto), ReasoningEffort.auto)]
            + levels.map { (ReasoningEffort.label($0, route: route), $0) }
    }

    /// 选中的 = 实际会发的（这个模型记过的 → 预设起点 → 取最近一档），不再显示一个、发另一个
    private var selectedIndex: Int {
        _ = bump
        guard let r = resolved else { return 0 }
        let levels = ReasoningEffort.levels(route: r.route, modelId: r.modelId)
        let value = ReasoningEffort.effective(
            stored: ReasoningEffort.stored(credentialId: r.credentialId, modelId: r.modelId),
            presetDefault: currentPreset.sampling.reasoningEffort, levels: levels)
        return stops.firstIndex { $0.value == value } ?? 0
    }

    private var subtitle: String {
        ReasoningEffort.subtitle(resolved?.route ?? .chatCompletions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                Text("思考强度")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                Text("·")
                    .foregroundColor(Theme.textMuted.opacity(0.3))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }

            DiscreteTrackSlider(
                count: stops.count,
                selectedIndex: selectedIndex,
                labels: stops.map(\.label),
                onSelect: { idx in
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                    guard let r = resolved, stops.indices.contains(idx) else { return }
                    ReasoningEffort.store(stops[idx].value, credentialId: r.credentialId, modelId: r.modelId)   // 记在这个模型上
                    bump += 1
                }
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct DiscreteTrackSlider: View {
    let count: Int
    let selectedIndex: Int
    let labels: [String]
    let onSelect: (Int) -> Void

    private let trackH: CGFloat = 6
    private let stopDot: CGFloat = 4
    private let thumbW: CGFloat = 6
    private let thumbH: CGFloat = 22
    private let gapW: CGFloat = 4

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let inset = thumbW / 2 + gapW + 8
                let usable = geo.size.width - inset * 2
                let step = count > 1 ? usable / CGFloat(count - 1) : 0
                let thumbX = inset + CGFloat(selectedIndex) * step

                ZStack {
                    // inactive track (full)
                    Capsule()
                        .fill(Theme.textMuted.opacity(0.12))
                        .frame(height: trackH)

                    // active track (left of thumb, with gap)
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(Theme.branchIndicator.opacity(0.5))
                            .frame(width: max(0, thumbX - gapW - inset + 8), height: trackH)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 0)

                    // stop dots
                    ForEach(0..<count, id: \.self) { i in
                        let x = inset + CGFloat(i) * step
                        Circle()
                            .fill(i <= selectedIndex ? Theme.branchIndicator.opacity(0.6) : Theme.textMuted.opacity(0.25))
                            .frame(width: stopDot, height: stopDot)
                            .position(x: x, y: geo.size.height / 2)
                    }

                    // thumb — vertical pill
                    RoundedRectangle(cornerRadius: thumbW / 2)
                        .fill(Theme.branchIndicator)
                        .frame(width: thumbW, height: thumbH)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        .position(x: thumbX, y: geo.size.height / 2)
                        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: selectedIndex)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let x = value.location.x - inset
                            let frac = x / max(1, usable)
                            let idx = max(0, min(count - 1, Int((frac * CGFloat(count - 1) + 0.5).rounded(.down))))
                            if idx != selectedIndex { onSelect(idx) }
                        }
                )
            }
            .frame(height: max(thumbH, trackH) + 4)

            // labels row
            HStack {
                ForEach(0..<count, id: \.self) { i in
                    Text(labels[i])
                        .font(.system(size: 11, weight: i == selectedIndex ? .medium : .regular))
                        .foregroundColor(i == selectedIndex ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .onTapGesture {
                            #if os(iOS)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            #endif
                            onSelect(i)
                        }
                }
            }
        }
    }
}

// MARK: - Bubble Attachment Strip (气泡外独立附件条)

private struct IdentifiableInt: Identifiable {
    let id = UUID()
    let value: Int
}

enum BubbleAttachmentItem {
    case image(name: String, data: Data)
    case file(name: String, type: String?, content: String?)
    case fileData(name: String, mime: String, data: Data)   // C2：带原始字节的真文件（可 QuickLook/存 Files）
}

struct BubbleAttachmentStrip: View {
    let items: [BubbleAttachmentItem]
    let isUser: Bool
    private let thumbSize: CGFloat = 80
    private let gap: CGFloat = 4
    private let scrollThreshold = 3
    @State private var previewIndex: IdentifiableInt?
    #if os(macOS)
    @State private var previewRequest: AttachmentPreviewRequest?
    #endif

    var body: some View {
        Group {
            if items.count > scrollThreshold {
                ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
                    stripContent
                }
                #if os(iOS)
                .horizontalScrollEdgeFade()
                #endif
            } else {
                stripContent
            }
        }
        #if os(iOS)
        .sheet(item: $previewIndex) { wrapper in
            AttachmentPreviewSheet(items: items, initialIndex: wrapper.value)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
                .presentationCornerRadius(20)
        }
        #else
        .attachmentQuickLook($previewRequest)
        #endif
    }

    /// 点缩略图 / 文件块 = 预览：iOS 全屏 sheet（AttachmentPreviewSheet），mac 系统 QuickLook（面 3b）
    private func preview(_ idx: Int) {
        #if os(iOS)
        previewIndex = IdentifiableInt(value: idx)
        #else
        previewRequest = AttachmentPreviewRequest(items[idx])
        #endif
    }

    private var stripContent: some View {
        HStack(spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                Button { preview(idx) } label: {
                    switch item {
                    case .image(_, let data):
                        imageBlock(data: data)
                    case .file(let name, let type, _):
                        fileBlock(name: name, type: type)
                    case .fileData(let name, let mime, _):
                        fileBlock(name: name, type: mime)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func imageBlock(data: Data) -> some View {
        Group {
            #if os(iOS)
            if let uiImg = UIImage(data: data) {
                Image(uiImage: uiImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbSize, height: thumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            #else
            if let nsImg = NSImage(data: data) {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbSize, height: thumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            #endif
        }
    }

    private func fileBlock(name: String, type: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: attachmentFileIcon(for: name))
                .font(.system(size: 20))
                .foregroundColor(Theme.textMuted.opacity(0.6))
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let type, !type.isEmpty {
                Text(type)
                    .font(.system(size: 8))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .attachmentFileBlockStyle(cornerRadius: 8)
    }
}

// MARK: - Branch Info (value type passed to BubbleView)

struct BranchInfo {
    let displayedNodeId: String
    let branchNodeId: String
    let branchCount: Int
    /// 这条在分叉点孩子里的序号（`‹ 2 / 3 ›` 的 2 = currentIndex + 1）
    let currentIndex: Int
    let branchChildren: [(index: Int, node: MessageNode, isMainPath: Bool)]
}

// MARK: - Chat Bubble

struct BubbleView: View {
    @Environment(\.chatMetrics) private var metrics
    let node: MessageNode
    var quotedPreview: String? = nil   // A4：reply_to 引用的消息截断预览
    let hasBranches: Bool
    let branchInfo: BranchInfo?
    var isStreaming: Bool = false
    // Phase 4 流式重写：传 vm 给 SegmentedAssistantBody (iOS-only) 构造 source。
    // macOS 不用但加字段统一接口（mac 走静态渲染路径不需要 source，vm 字段仅持有不读）
    var viewModel: ConversationViewModel?
    var isHighlighted: Bool = false
    var isSearchMatch: Bool = false
    var avatars: ChatAvatars = .none
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void
    let onSoftDelete: () -> Void
    let onSwitchBranch: (String, Int) -> Void
    var onRegenerate: (() -> Void)? = nil
    /// 进入输入框编辑（plan-edit-in-composer）；nil = 这条不能编辑
    var onEdit: (() -> Void)? = nil
    /// 输入框正在编辑这条：气泡变透明 + 圆角虚线
    var isBeingEdited: Bool = false
    var onQuoteText: ((String) -> Void)? = nil   // A4：长按「引用」，传被引用文字（气泡模式=单 block，文章模式=整条）
    var regexScripts: [RegexScript] = []

    @Environment(\.modelContext) private var modelContext
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage("userName") private var floorUserName = "你"
    /// 卡库 ③-4：有效身份名（对话 → 楼层 → 楼层原有名字），只换显示副本
    private var userName: String { viewModel?.personaDisplayName(profile: profileManager?.currentProfile) ?? floorUserName }
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage("selectedFont") private var selectedFont = ""
    @AppStorage("ccShowThinking") private var showCCThinking = true
    @AppStorage("fontScale") private var fontScale = 1.2
    @AppStorage("showMessageUsage") private var showMessageUsage = true

    private func usageFooterText(prompt: Int, completion: Int) -> String {
        var s = "↑\(Self.fmtTok(prompt)) ↓\(Self.fmtTok(completion))"
        if let read = node.usageCacheReadTokens, read > 0, prompt > 0 {
            s += " · 命中 \(Int(Double(read) / Double(prompt) * 100))%"
        }
        if let cost = node.usageCostUSD, cost > 0 {
            s += String(format: " · $%.4f", cost)
        }
        return s
    }

    private static func fmtTok(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
    // 气泡外观自定义（DisclosureGroup "气泡外观（高级）"）
    @AppStorage("bubbleCornerRadius") private var bubbleCornerRadius: Double = 16
    @AppStorage("bubblePaddingH") private var bubblePaddingH: Double = 18
    @AppStorage("bubblePaddingV") private var bubblePaddingV: Double = 15
    @AppStorage("lineSpacingScale") private var lineSpacingScale: Double = 1.45
    @AppStorage("paragraphSpacingScale") private var paragraphSpacingScale: Double = 1.65
    @AppStorage("hideTimestamp") private var hideTimestamp: Bool = false
    @AppStorage("hideRoleName") private var hideRoleName: Bool = false
    @AppStorage("hideActionBar") private var hideActionBar: Bool = false
    @AppStorage("chatBubbleMode") private var chatBubbleMode = false
    @AppStorage("showAvatar") private var showAvatar = true
    @AppStorage("bubbleModeCornerRadius") private var bubbleModeCornerRadius: Double = 23
    @State private var showBranchPicker = false
    @State private var showTagPicker = false
    /// 流式显示节拍器（research-streaming-smoothness）：显示文本按 30Hz 追赶到达文本
    @State private var pacer = StreamPacer()
    @State private var highlightOpacity: Double = 0
    @State private var showTextSelect = false
    @State private var textSelectContent = ""
    /// 这条的送达异常 entry 建 / 删时 +1（K1 第 4b 步），只为让这一条重算、挂上 / 摘掉标记
    @State private var sendStatusTick = 0

    var isUser: Bool { node.role == "user" }

    private var messageError: String? {
        guard !isUser else { return nil }
        if case .text(let text)? = ChatDisplaySnapshot.segments(of: node)?.last,
           let error = ChatSystemMessage.split(text).error { return error }
        return ChatSystemMessage.split(node.content).error
    }

    private var messageNotice: String? {
        guard !isUser else { return nil }
        if case .text(let text)? = ChatDisplaySnapshot.segments(of: node)?.last,
           let notice = ChatSystemMessage.split(text).notice { return notice }
        return ChatSystemMessage.split(node.content).notice
    }

    private var hasMessageBody: Bool {
        if isStreaming || (messageError == nil && messageNotice == nil) { return true }
        if let segments = ChatDisplaySnapshot.segments(of: node), !segments.isEmpty {
            return !ChatSystemMessage.removingTrailingError(from: segments).isEmpty
        }
        return !ChatSystemMessage.split(node.content).body.isEmpty
    }

    /// 卡库第二批「edited」浮层里的卡名：当前楼层绑定的卡（只在有 cardEditedAt 时读）
    private var editedCardName: String? {
        HTMLEmbedPermission.boundCard(profileId: profileManager?.currentProfile.id,
                                      cards: profileManager?.characterCardManager?.cards ?? [])?.name
    }

    /// ⑤a：用户消息也跑显示规则（placement 1），只改显示副本，不写 MessageNode
    private func userDisplayText(_ text: String) -> String {
        RegexPipeline.run(regexScripts, text: text, phase: .display, placement: RegexPipeline.userPlacement,
                          userName: userName, charName: assistantName)
    }

    /// 正文渲染器一处选（面 5.2；ms0911 起两端同走 fork `ChatMarkdownView`——划词 / 引用 / HTML 卡；
    /// 流式 `animated`：逐词淡入只 iOS 有（mac 一期不做，R8 I3），transient 缓存策略两端同）。
    /// 纯文本 / simple 静态 / 气泡模式纯文本三处正文都从这里走。
    @ViewBuilder
    private func markdownBody(_ text: String, animated: Bool = false) -> some View {
        // B6 刀2：流式中开逐词淡入（fork MarkdownView 本身已 off-main parse，缺的只有动画）；
        // 流完 isStreaming 翻 false 回不动画 config，终文本不变无重动画。R2-4b：统一走 ChatMarkdownView（划词收生词）
        ChatMarkdownView(
            text: MessageHTMLSegments.markdownPromotingHTML(text),   // 卡库 ⑦：明确 HTML 交给网页卡
            fontName: selectedFont,
            scale: CGFloat(fontScale > 0 ? fontScale : 1.0),
            animated: animated,
            nodeId: node.id,
            profileId: node.profileId,
            onQuote: onQuoteText,
            // M1 三格：文章模式和气泡模式的纯文本正文都从这里走（本文件 :2734 注释）
            role: isUser ? .user : .assistant
        )
        .chatCardRenderer(nodeId: node.id, streaming: animated)
    }

    /// simple 消息静态正文（thinking 条 + 正文渲染）。L2-T2 后流式走 ArticleStreamingBody，
    /// 这里只服务定稿/用户/vm 缺失路径；抽出供 iOS/macOS 两分支复用（顺带治 type-check）。
    @ViewBuilder
    private func simpleStaticBody(thinkingResult: ContentCleaner.ThinkingResult?, cleaned: String) -> some View {
        // Thinking block (collapsible)：[thinking] 标签提取 或 CC 思考链回传（ccThinking）
        if let thinking = thinkingResult?.thinking ?? (showCCThinking ? node.ccThinking : nil), !thinking.isEmpty {
            ThinkingDisclosure(text: thinking, nodeId: node.id, profileId: node.profileId,
                               summary: node.thinkingSummary,
                               onNeedSummary: { [node, providerManager] in
                                   ThinkingSummarizer.request(node, thinking: thinking, providerManager: providerManager)
                               })
        }

        // Assistant content — 正则脚本渲染替换
        let displayText = RegexPipeline.run(regexScripts, text: cleaned, phase: .display,
                                            placement: RegexPipeline.placement(forRole: node.role),
                                            userName: userName, charName: assistantName)
        if displayText.isEmpty && isStreaming {
            TypingDotsView()
        } else if !displayText.isEmpty {
            markdownBody(displayText, animated: isStreaming)
        }
    }

    /// segmented 消息正文（Claude v2 导入/CC 复杂消息；抽出治 type-check 超时）。
    /// assistant（两端，ms0911 L4 起 mac 同）走 SegmentedAssistantBody（流式 tail），user 走 MessageSegmentsView。
    @ViewBuilder
    private func renderableSegmentsBody(_ segs: [MessageSegment]) -> some View {
        if !isUser, let vm = viewModel {
            SegmentedAssistantBody(
                node: node,
                viewModel: vm,
                conversationId: vm.selectedConversation?.id ?? "",
                segments: segs,
                selectedFont: selectedFont,
                fontScale: fontScale,
                lineSpacingScale: lineSpacingScale,
                paragraphSpacingScale: paragraphSpacingScale,
                regexScripts: regexScripts,
                onQuoteText: onQuoteText
            )
        } else {
            MessageSegmentsView(
                segments: segs,
                selectedFont: selectedFont,
                fontScale: fontScale,
                lineSpacingScale: lineSpacingScale,
                paragraphSpacingScale: paragraphSpacingScale,
                regexScripts: regexScripts,
                profileId: node.profileId,
                nodeId: node.id,
                onQuoteText: onQuoteText,
                toolNode: isUser ? nil : node,
                suppressTrailingError: !isUser
            )
        }
    }

    // MARK: - 长按菜单条目（Telegram 式浮层）
    // 菜单条目条件逻辑只写一份（spec），iOS 由 BubbleMenuLiftWrapper 走自定义浮层，
    // macOS 从 spec 渲染 SwiftUI .contextMenu。详见 docs/plan-contextmenu-telegram-style.md
    private func nodeMenuSpecs() -> [MenuActionSpec] {
        // 她的纯语音条：胶囊不挂自己的菜单，「分享」进这条消息的菜单
        let voicePath = isUserVoiceNote ? ChatDisplaySnapshot.segments(of: node)?.audioRefs.first?.path : nil
        return menuSpecs(copyTitle: "复制文本", copyText: { copyableContent }, voicePath: voicePath)
    }

    /// 复制 / 引用整条：她带语音的消息读段（打的字 + 转写，按段顺序；sol P2-4），不碰 content 里只给 AI 看的标记行；
    /// 没语音段的消息照旧复制正文（手打的 [语音 0:07] 行原样）
    private var copyableContent: String {
        if isUser, let voice = ChatDisplaySnapshot.segments(of: node)?.userVoiceCopyText { return voice }
        return ContentCleaner.clean(node.content, cacheKey: node.id)
    }

    /// 她发的纯语音条（plan-voice-note M7）：不画文字气泡，只画胶囊 + 转文字
    private var isUserVoiceNote: Bool {
        isUser && (ChatDisplaySnapshot.segments(of: node)?.userVoiceNote ?? false)
    }

    /// 她这条带语音（纯语音 / 文字 + 语音）：不能编辑——恢复回输入框只剩一行 [语音…] 文字（plan-voice-note 第二节 7）
    private var userHasVoice: Bool {
        isUser && !(ChatDisplaySnapshot.segments(of: node)?.audioRefs.isEmpty ?? true)
    }

    /// 两种模式共用一份条目（粟粟 10-01 定稿 B）：带 quickLabel 的进 iOS 浮层顶上那排图标
    /// （Copy / Star / Pin / Read / Delete），其余一行一个（编辑或重新生成 / 选择文本 / 收藏到标签）。
    /// 「引用」引的是 copyText（气泡模式=本 block，文章模式=整条）；编辑的是整条消息（plan-edit-in-composer §6）。
    /// voicePath 有值 = 她的语音条：Copy 后面跟 Share（分享音频本身，plan-voice-polish-1007 D）
    private func menuSpecs(copyTitle: String, copyText: @escaping () -> String, voicePath: String? = nil) -> [MenuActionSpec] {
        var specs: [MenuActionSpec] = []
        if isUser, let onEdit, !userHasVoice {
            specs.append(MenuActionSpec(title: "编辑", systemImage: "pencil", dividerAfter: true, handler: onEdit))
        }
        // 她的语音条也不出「重新生成」：user 重新生成 = 原文重发，会把那行 [语音…] 当文字发、丢掉音频
        if let onRegenerate, !isStreaming, !userHasVoice {
            specs.append(MenuActionSpec(title: "重新生成", systemImage: "arrow.counterclockwise", dividerAfter: true, handler: onRegenerate))
        }
        specs.append(MenuActionSpec(title: copyTitle, systemImage: "doc.on.doc", quickLabel: "Copy") {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyText(), forType: .string)
            #else
            UIPasteboard.general.string = copyText()
            #endif
        })
        if let voicePath {
            specs.append(VoiceNoteShare.spec(path: voicePath, profileId: node.profileId, speaker: userName,
                                             date: node.createTime, quickLabel: "Share"))
        }
        specs.append(MenuActionSpec(title: node.isFavorite ? "取消收藏" : "收藏", systemImage: node.isFavorite ? "star.fill" : "star",
                                    quickLabel: "Star", handler: onToggleFavorite))
        specs.append(MenuActionSpec(title: node.isPinned ? "取消钉住" : "钉住", systemImage: node.isPinned ? "pin.fill" : "pin",
                                    dividerAfter: isUser, quickLabel: "Pin", handler: onTogglePin))
        if !isUser {
            let speech = SpeechService.shared
            if speech.isSpeaking, speech.activeNodeId == node.id {
                specs.append(MenuActionSpec(title: "停止朗读", systemImage: "speaker.slash", dividerAfter: true, quickLabel: "Stop") {
                    speech.stop()
                })
            } else {
                specs.append(MenuActionSpec(title: "朗读", systemImage: "speaker.wave.2", dividerAfter: true, quickLabel: "Read") {
                    speech.speak(nodeId: node.id, text: SpeechService.speakableText(from: node))
                })
            }
        }
        // 10-03 粟粟要回「引用」（c4746e2fc 删过）：走 onQuoteText，同浮条选段引用一条链
        if let onQuoteText {
            specs.append(MenuActionSpec(title: "引用", systemImage: "quote.opening") {
                onQuoteText(copyText())
            })
        }
        // 多选气泡入口（粟粟拍板 1）：输入框正在编辑旧消息 / 这条还在流式时不出
        if let vm = viewModel, vm.editingMessage == nil, !isStreaming {
            specs.append(MenuActionSpec(title: "多选", systemImage: "checkmark.circle") { [node] in
                vm.beginMessageSelection(with: node.id)
            })
        }
        specs.append(MenuActionSpec(title: "选择文本", systemImage: "selection.pin.in.out") {
            textSelectContent = copyText()
            showTextSelect = true
        })
        // 10-02 收藏标签组：文件夹以后对标「项目」不再兼职收藏，这一行换成收藏页自己的 tag
        specs.append(MenuActionSpec(title: "收藏到标签…", systemImage: "tag", dividerAfter: true) {
            showTagPicker = true
        })
        specs.append(MenuActionSpec(title: "删除", systemImage: "trash", isDestructive: true, quickLabel: "Delete", handler: onSoftDelete))
        return specs
    }

    @State private var showBookRef = false

    /// M4：parse bookRef 字符串 "<safeName>#chapter<N>[#noteId]"。
    /// 用于在 user 气泡上挂"📖 书名·第N章" tag，点击打开对应书。
    private var bookRefInfo: (safeName: String, chapter: Int)? {
        guard let ref = node.bookRef, !ref.isEmpty else { return nil }
        let parts = ref.split(separator: "#", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let safe = String(parts[0])
        let chapterStr = String(parts[1]).replacingOccurrences(of: "chapter", with: "")
        guard let n = Int(chapterStr), !safe.isEmpty else { return nil }
        return (safe, n)
    }

    /// 真实显示名从 index.json 读（避免 safeName 跟 name 不一样的情况）
    private var bookDisplayName: String {
        guard let info = bookRefInfo else { return "" }
        return BookStore.loadIndex(safeName: info.safeName, profileId: node.profileId)?.name ?? info.safeName
    }

    @ViewBuilder
    private var bookRefTag: some View {
        if let info = bookRefInfo {
            Button { showBookRef = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 9))
                    Text("\(bookDisplayName) · 第 \(info.chapter) 章")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(Theme.branchIndicator)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.accent.opacity(0.6))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    var body: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = AirPerfProbe.enabled ? PerfCount.hit("bubbleBody") : ()
        #endif
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if isUser { bookRefTag }
            if node.role == "system" {
                ChatSystemCapsule(text: node.content, symbol: node.content.hasPrefix("⚠") ? "exclamationmark.circle" : "info.circle",
                                  isError: node.content.hasPrefix("⚠"))
            } else {
                if hasMessageBody { innerBody }
                if let messageError {
                    ChatSystemCapsule(text: messageError, symbol: "exclamationmark.circle", isError: true,
                                      actionTitle: onRegenerate == nil || isStreaming ? nil : "重试",
                                      action: isStreaming ? nil : onRegenerate)
                } else if let messageNotice {
                    ChatSystemCapsule(text: messageNotice, symbol: "pause.circle")
                }
                if !hasMessageBody, let branchInfo {
                    BranchIndicator(info: branchInfo, showPicker: $showBranchPicker, onSwitchBranch: onSwitchBranch)
                }
            }
            // cc-bridge 送达异常（plan-hub-perf K1 第 4b 步）：没异常就没有 entry，整个不画、不占行。
            // 索引不是 Observable（读它不订阅）；这条的 entry 建 / 删时下面 onReceive 认领、只翻这一条的 tick
            let _ = sendStatusTick
            if isUser, let entry = CCBridgeWebSocketClient.shared.sendTracker.store.entry(node.id) {
                CCSendStatusBadge(entry: entry)
            }
        }
        .onReceive(CCBridgeWebSocketClient.shared.sendTracker.store.membership) { id in
            if id == node.id { sendStatusTick &+= 1 }
        }
        // 长按浮层的表情条要知道是哪条消息（BubbleMenuMarker 读）。表情回应只属于气泡模式（粟粟 10-02）：
        // 文章模式给 nil = 浮层不画表情条，文章模式也不挂回应徽标
        .environment(\.reactionTarget, chatBubbleMode ? ChatReactionTarget(node: node) : nil)
        // 长按菜单底部的时间 / token 行（TASK page1-消息-20）：两种模式都有
        .environment(\.bubbleInfoNode, node)
        #if os(iOS)
        // 长高信号源：每条泡自报高度变化（见 CellGrowthAnchor / plan-stream-follow-controller）
        #if DEBUG || PERF_BENCH
        .background(CellGrowthAnchor(isStreamingCell: !isUser && isStreaming, perfNodeId: node.id))
        #else
        .background(CellGrowthAnchor(isStreamingCell: !isUser && isStreaming))
        #endif
        #endif
        // 只有流式中的 assistant 泡读 streamingText（非流式泡读常量 nil 不订阅）；initial 兜住滚回来时流已在进行
        .onChange(of: (!isUser && isStreaming) ? viewModel?.streamingText : nil, initial: true) { _, new in
            if let new { pacer.push(new) }
        }
        .onChange(of: isStreaming) { _, live in
            if !live { pacer.end() }
        }
        .sheet(isPresented: $showBookRef) {
            if let info = bookRefInfo {
                BookReaderSheet(bookSafeName: info.safeName, profileId: node.profileId)
                    .frame(minWidth: metrics.bookReaderMinSize?.width, minHeight: metrics.bookReaderMinSize?.height)
            }
        }
    }

    @ViewBuilder
    private var innerBody: some View {
        if chatBubbleMode {
            BubbleModeRow(
                node: node, isUser: isUser, isStreaming: isStreaming,
                // B6 A2'：弹泡数据源。只有流式中的 assistant 行才读 vm.streamingText
                //（三元短路 = 其他行不订阅，不吃 per-token body churn）
                streamingText: (!isUser && isStreaming) ? pacer.shown : nil,
                // CC 入场弹泡：待弹查集合，弹完销账
                entrancePending: viewModel?.pendingEntranceNodeIds.contains(node.id) ?? false,
                onEntranceDone: { viewModel?.pendingEntranceNodeIds.remove(node.id) },
                // pop-tuner v7：发消息弹泡（行内泡级，白名单自动销账防滚回重弹）
                popPending: viewModel?.popNodeIds.contains(node.id) ?? false,
                selectedFont: selectedFont, fontScale: fontScale,
                // 气泡模式外观锁定为 iMessage 固定值，不受「气泡外观（高级）」滑块影响
                // （圆角圆度 / padding / 行距段距只准普通模式调）。字号 fontScale 仍可调。
                lineSpacingScale: BubbleModeRow.fixedLineSpacing,
                paragraphSpacingScale: BubbleModeRow.fixedParagraphSpacing,
                regexScripts: regexScripts,
                bubbleCornerRadius: bubbleModeCornerRadius,
                bubblePaddingH: BubbleModeRow.fixedPaddingH,
                bubblePaddingV: BubbleModeRow.fixedPaddingV,
                userName: userName, assistantName: assistantName,
                hideTimestamp: hideTimestamp, hideRoleName: hideRoleName,
                showAvatar: showAvatar,
                avatars: avatars,
                blockMenuSpecs: { block, voicePath in bubbleMenuSpecs(quoteText: block, voicePath: voicePath) },
                onQuoteText: onQuoteText,
                isHighlighted: isHighlighted,
                branchInfo: branchInfo,
                onSwitchBranch: onSwitchBranch,
                isBeingEdited: isBeingEdited
            )
            .sheet(isPresented: $showTagPicker) {
                FavoriteTagSheet(target: FavoriteTags.Target(node: node))
            }
            .sheet(isPresented: $showTextSelect) {
                TextSelectSheet(text: textSelectContent, onQuoteText: onQuoteText)
            }
        } else {
            articleModeBody
        }
    }

    /// 气泡模式：每个气泡（block）各自的长按菜单。复制 / 选择文本作用于该 block，其余作用于整条。
    /// 同 nodeMenuSpecs：iOS 走 UIKit 桥 marker，macOS 从 spec 渲染 .contextMenu。
    private func bubbleMenuSpecs(quoteText: String, voicePath: String? = nil) -> [MenuActionSpec] {
        menuSpecs(copyTitle: "复制本段", copyText: { quoteText }, voicePath: voicePath)
    }

    private var articleModeBody: some View {
        let userVoiceNote = isUserVoiceNote
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            // Role label（时间挪到列表中间的分割线 + 长按菜单底部，TASK page1-消息-20；名字隐藏且没有小标时整行不 render）
            if !hideRoleName || (isUser && (node.styleIdSnapshot != nil || node.cardEventsData != nil)) {
                HStack(spacing: 4) {
                    if !hideRoleName {
                        Text(isUser ? userName : assistantName)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(Theme.textMuted)
                    }
                    if isUser { StyleChip(styleId: node.styleIdSnapshot); CardEventsChip(node: node) }
                }
                .padding(.horizontal, 4)
            }

            // 附件条（气泡外，上方）— 图片 + 文件都放这
            if let segs = ChatDisplaySnapshot.segments(of: node)?.hydratedForDisplay(profileId: node.profileId) {
                // 语音条（独立于 strip：不进 AttachmentPreviewSheet，tap 是播放不是预览）。
                // 她发的语音条不在这：纯语音画在气泡位、文字 + 语音画在气泡下面（plan-voice-note M7）
                let voiceSegs: [(path: String, duration: Double?)] = isUser ? [] : segs.compactMap { seg in
                    if case .audioRef(_, _, let p, let d, _) = seg { return (p, d) }
                    return nil
                }
                ForEach(voiceSegs, id: \.path) { v in
                    VoiceCapsuleView(path: v.path, duration: v.duration,
                                     nodeId: node.id, profileId: node.profileId, isUser: isUser,
                                     speaker: assistantName, createTime: node.createTime)
                        // 模型的语音条左缘对齐正文 / 卡片（它们在气泡里缩进 bubblePaddingH；默认主题气泡底看不见，
                        // 不缩就比正文往左凸 18pt——粟粟 09-26「还是没对齐」）；你的语音条仍贴你的气泡右缘
                        .padding(.leading, isUser ? 0 : bubblePaddingH)
                        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                }

                let attachmentItems: [BubbleAttachmentItem] = segs.compactMap { seg in
                    if case .image(let n, _, let d) = seg { return .image(name: n, data: d) }
                    if case .attachment(let n, let t, let c) = seg { return .file(name: n, type: t, content: c) }
                    if case .fileData(let n, let m, let d) = seg { return .fileData(name: n, mime: m, data: d) }
                    return nil
                }
                if !attachmentItems.isEmpty {
                    BubbleAttachmentStrip(items: attachmentItems, isUser: isUser)
                }
            }

            // Bubble（iOS 包 BubbleMenuLiftWrapper：长按浮层 marker + 活副本；macOS 透传走下方 .contextMenu）
            BubbleMenuLiftWrapper(isUser: isUser, cornerRadius: bubbleCornerRadius, actions: nodeMenuSpecs()) {
            VStack(alignment: .leading, spacing: 6) {
                // A4：reply_to 引用预览——气泡顶部一条「竖线 + 被引用消息截断文字」
                if let quotedPreview {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.branchIndicator.opacity(0.6))
                            .frame(width: 2.5, height: 14)
                        Text(quotedPreview)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                    .padding(.bottom, 1)
                }
                // L2-T2：流式正文改走 ArticleStreamingBody（fork 增量渲染），这里只管
                // 静态/用户路径（Phase 5 断链后流式中 node.content 是上次值/空，无妨——
                // 流式分支不再从这条链取数）
                // 卡开场的 {{char}}/{{user}} 只在显示副本展开（③b），存储原文不动
                let displayContent = isUser ? node.content : ChatSystemMessage.split(node.content).body
                let rawCleaned = EffectiveCharacterContext(charName: assistantName, userName: userName)
                    .expand(ContentCleaner.clean(displayContent, cacheKey: "\(node.id)_\(displayContent.count)"))
                let thinkingResult = isUser ? nil : ContentCleaner.extractThinking(from: rawCleaned)
                let cleaned = thinkingResult?.content ?? rawCleaned
                #if (DEBUG || PERF_BENCH) && os(iOS)
                // 渲染账本 consumed（perf P0 §5.2）：静态正文消费的 node.content 快照摘要
                let _ = PerfHarness.strictMeasure && (isUser || !isStreaming)
                    ? PerfRenderLedger.noteConsumed(nodeId: node.id, content: node.content, mode: "article") : ()
                #endif

                if isUser {
                    if let segs = ChatDisplaySnapshot.segments(of: node), !segs.isEmpty {
                        let textOnly = segs.compactMap { seg -> String? in
                            if case .text(let s) = seg { return s }
                            return nil
                        }.joined(separator: "\n\n")
                        let hasComplexSegments = segs.contains { seg in
                            switch seg {
                            case .text, .image, .imageRef, .attachment, .audioRef: return false
                            default: return true
                            }
                        }
                        if hasComplexSegments {
                            MessageSegmentsView(
                                segments: segs,
                                selectedFont: selectedFont,
                                fontScale: fontScale,
                                lineSpacingScale: lineSpacingScale,
                                paragraphSpacingScale: paragraphSpacingScale,
                                regexScripts: regexScripts,
                                isUser: true,
                                profileId: node.profileId,
                                nodeId: node.id,
                                onQuoteText: onQuoteText
                            )
                        } else if !textOnly.isEmpty {
                            // B34：user 和 assistant 走同一个 Markdown 渲染器 = 同字号同行距同段距
                            markdownBody(userDisplayText(textOnly))
                        } else if segs.userVoiceNote {
                            // 纯语音：不画文字（content 那行只给 AI 看），胶囊 + 转文字占气泡位；长按走外面这条消息的菜单
                            ForEach(segs.audioRefs, id: \.path) { v in
                                UserVoiceNoteView(path: v.path, duration: v.duration, script: v.script,
                                                  nodeId: node.id, profileId: node.profileId, ownMenu: false,
                                                  speaker: userName, createTime: node.createTime)
                            }
                        }
                    } else {
                        // B34：见上
                        markdownBody(userDisplayText(cleaned))
                    }
                } else if node.contentType == "heartvoice" || node.content.hasPrefix("💭 心声\n\n") {
                    // 心声：默认 collapsed 成 💭 chip，点开 = 日记本卡片
                    // 老消息兼容：早期 v1 把 "💭 心声\n\n" 前缀塞 content 里、contentType="text"，剥前缀
                    let heartText: String = {
                        if node.contentType == "heartvoice" { return node.content }
                        let prefix = "💭 心声\n\n"
                        return node.content.hasPrefix(prefix)
                            ? String(node.content.dropFirst(prefix.count))
                            : node.content
                    }()
                    HeartvoiceCardView(text: heartText, time: node.createTime)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let segs = ChatDisplaySnapshot.segments(of: node), segs.hasRenderableSegments {
                    // Claude v2 导入：按段渲染（每段独立折叠，顺序严格）。
                    // 只挂语音条（audioRef-only）的消息不进这里——正文继续走下面纯文本分支
                    renderableSegmentsBody(segs)
                } else {
                    // L2-T2 (D10=b)：流式中 thinking+正文整体交给 fork 增量渲染
                    // （BubbleView body 不再随 token 全文重进 markdown parse/diff）；
                    // 定稿（isStreaming 翻 false）回落静态分支（ChatMarkdownView + T3 缓存）
                    if !isUser, isStreaming, let vm = viewModel {
                        ArticleStreamingBody(
                            node: node,
                            viewModel: vm,
                            conversationId: vm.selectedConversation?.id ?? "",
                            regexScripts: regexScripts
                        )
                    } else {
                        simpleStaticBody(thinkingResult: thinkingResult, cleaned: cleaned)
                    }
                }

                // Anthropic server-side web search 引用源 chip 横排（segmented 渲染分支已在 MessageSegmentsView 内集成无需重复）
                if !isUser, !node.webSources.isEmpty {
                    WebSearchSourcesChipRow(sources: node.webSources)
                }


                // A4：被 edit_message 改过 → 右下角浅暖灰小标
                if node.ccEdited {
                    Text("edited")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }


                // D2：每轮 usage footer（外观设置「显示消息用量」可隐藏）
                if !isUser, showMessageUsage, let pt = node.usagePromptTokens, let ct = node.usageCompletionTokens {
                    Text(usageFooterText(prompt: pt, completion: ct))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // 她的纯语音条不画文字气泡：胶囊自带底，不套气泡壳 / 内边距（plan-voice-note M7）
            .padding(.horizontal, userVoiceNote ? 0 : bubblePaddingH)
            .padding(.vertical, userVoiceNote ? 0 : bubblePaddingV)
            .background {
                if isBeingEdited {
                    // 输入框正在编辑这条：底色透明 + 圆角虚线（plan-edit-in-composer §6）
                    RoundedRectangle(cornerRadius: bubbleCornerRadius)
                        .strokeBorder(Theme.branchIndicator, style: EditingBubbleDash.style)
                } else if !userVoiceNote {
                    // 文章模式你的消息卡也走气泡渐变（粟粟：气泡和文章都）；列表反转同上
                    UserBubbleFill(
                        shape: RoundedRectangle(cornerRadius: bubbleCornerRadius),
                        base: isUser ? Theme.userBubble : Theme.assistantBubble,
                        gradient: isUser ? Theme.userBubbleGradient : nil,
                        anchor: .scrollView(flipped: true)
                    )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isBeingEdited)
            }
            .overlay(
                RoundedRectangle(cornerRadius: bubbleCornerRadius)
                    .fill(Theme.branchIndicator.opacity(0.2 * highlightOpacity))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: bubbleCornerRadius)
                    .stroke(Theme.branchIndicator.opacity(isSearchMatch ? 0.6 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            )
            // initial：跳到很远的命中时气泡是跳过去之后才建出来的，建出来那刻就已经是高亮
            .onChange(of: isHighlighted, initial: true) { _, highlighted in
                if highlighted {
                    withAnimation(.easeIn(duration: 0.3)) { highlightOpacity = 1 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeOut(duration: 0.5)) { highlightOpacity = 0 }
                    }
                }
            }
            .if(isUser) { view in
                view.frame(maxWidth: 500, alignment: .trailing)
            }
            // iOS 菜单走 UIKit 桥（marker 在上面 .background 处），这里只剩 macOS 的 SwiftUI 菜单
            #if os(macOS)
            .contextMenu { MenuActionSpec.menuItems(from: nodeMenuSpecs()) }
            #endif

            if !isUser {
                RecallCardView(node: node)
                    .padding(.horizontal, bubblePaddingH)
            }

            if hasBranches, let info = branchInfo {
                HStack(spacing: 2) {
                    BranchIndicator(info: info, showPicker: $showBranchPicker, onSwitchBranch: onSwitchBranch)
                    if let editedAt = node.cardEditedAt { CardEditedMark(cardName: editedCardName, editedAt: editedAt) }
                }
            } else if let editedAt = node.cardEditedAt {
                CardEditedMark(cardName: editedCardName, editedAt: editedAt)
            }

            // 她的文字 + 语音一起发：文字气泡照画（.text 段本来就不含 [语音…] 那行），语音胶囊 + 转文字在气泡下面
            if isUser, !userVoiceNote, let segs = ChatDisplaySnapshot.segments(of: node) {
                ForEach(segs.audioRefs, id: \.path) { v in
                    UserVoiceNoteView(path: v.path, duration: v.duration, script: v.script,
                                      nodeId: node.id, profileId: node.profileId,
                                      speaker: userName, createTime: node.createTime)
                }
            }

            // Hover action buttons — isolated to avoid full bubble re-render
            if !hideActionBar {
                let selecting = viewModel?.messageSelection.isActive ?? false
                HoverButtons(
                    isFavorite: node.isFavorite,
                    isPinned: node.isPinned,
                    onCopy: {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyableContent, forType: .string)
                        #else
                        UIPasteboard.general.string = copyableContent
                        #endif
                    },
                    onToggleFavorite: onToggleFavorite,
                    onTogglePin: onTogglePin,
                    onSoftDelete: onSoftDelete,
                    onEdit: isUser && !userHasVoice ? onEdit : nil,
                    onRegenerate: !isUser && !isStreaming ? onRegenerate : nil
                )
                // 多选期间藏掉（只改透明度不撤位：撤位会让每条文章卡变矮、反转列表整体重排）
                .opacity(selecting ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        // 注意：删了 .contentShape(Rectangle())。它会把 contextMenu 命中区扩到整 row 宽
        // (maxWidth: .infinity)，导致 row 空白区 (input bar 后渗 / home indicator 上方那带)
        // 点击都触发 contextMenu。删后命中区缩到气泡视觉本身（line 1238 的 RoundedRectangle），
        // 即 .contextMenu 自己附着的那个 view 的 frame。
        .sheet(isPresented: $showTagPicker) {
            FavoriteTagSheet(target: FavoriteTags.Target(node: node))
        }
        .sheet(isPresented: $showTextSelect) {
            TextSelectSheet(text: textSelectContent, onQuoteText: onQuoteText)
        }
    }
}

// MARK: - Text Select Sheet

/// 「选择文本」弹层：纯文本 + textSelection，不挂 contextMenu，所以长按直接出坨坨拖选一段。
struct TextSelectSheet: View {
    let text: String
    /// 选中「引用」→ 关 sheet 落输入框（调用点传气泡的 onQuoteText）。
    var onQuoteText: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var toast: String? = nil

    var body: some View {
        NavigationStack {
            SelectableActionTextView(
                text: text,
                onCollectVocab: { word, sentence in collectWord(word, sentence: sentence) },
                onQuote: onQuoteText.map { quote in
                    { selected in
                        dismiss()
                        quote(selected)
                    }
                }
            )
            .background(Theme.mainBg)
            .navigationTitle("选择文本")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 520, minHeight: 420)   // mac sheet 里 NSViewRepresentable 不给 frame 塌成 0（同 5cea75b4 编辑主题；L research 未查证 #1）
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if let msg = toast {
                    Text(msg)
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Theme.branchIndicator)
                                .shadow(color: Theme.cardShadow, radius: 8, y: 2)
                        )
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toast)
        }
    }

    /// 划词收生词：进生词本带所在句快照；「划词收词进复习」开着就同步进牌堆。
    private func collectWord(_ raw: String, sentence: String) {
        guard let word = VocabCollector.collectManually(rawText: raw, anchor: sentence, context: modelContext) else {
            showToast("这段不适合收词")
            return
        }
        if VocabCollector.autoReviewEnabled {
            VocabCardStore.addIfAbsent(word: word, source: "chat", dir: VocabCollector.reviewDeckDir)
        }
        showToast("已收「\(word)」")
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == msg { toast = nil }
        }
    }
}

// MARK: - Hover Buttons (isolated state)

/// Separate view for hover buttons so hover state changes don't re-render the entire bubble
struct HoverButtons: View {
    let isFavorite: Bool
    let isPinned: Bool
    let onCopy: () -> Void
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void
    let onSoftDelete: () -> Void
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    /// 与气泡内文字左右线对齐（粟粟：按钮行出格）——同气泡内边距
    @AppStorage("bubblePaddingH") private var bubblePaddingH: Double = 18

    /// 统一按压反馈（粟粟：小按钮按了没反馈）：轻震 + 动作各自的 toast
    private func tap(_ action: @escaping () -> Void) -> () -> Void {
        {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            action()
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if let onEdit {
                Button(action: tap(onEdit)) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }

            if let onRegenerate {
                Button(action: tap(onRegenerate)) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }

            Button(action: tap {
                onCopy()
                ToastCenter.shared.show("已复制")
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)

            Button(action: tap {
                let wasFavorite = isFavorite
                onToggleFavorite()
                ToastCenter.shared.show(wasFavorite ? "已取消收藏" : "已收藏")
            }) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundColor(isFavorite ? Theme.favorite : Theme.textMuted)
            }
            .buttonStyle(.plain)

            Button(action: tap {
                let wasPinned = isPinned
                onTogglePin()
                ToastCenter.shared.show(wasPinned ? "已取消置顶" : "已置顶")
            }) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13))
                    .foregroundColor(isPinned ? Theme.branchIndicator : Theme.textMuted)
            }
            .buttonStyle(.plain)

            // 删除二次确认（粟粟：有时误触）
            Button(action: tap { showDeleteConfirm = true }) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .confirmationDialog("删除这条消息？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    onSoftDelete()
                    ToastCenter.shared.show("已移入回收站")
                }
            }
        }
        .foregroundColor(Theme.textMuted)
        .padding(.horizontal, CGFloat(bubblePaddingH))
        .padding(.top, 2)
        #if os(macOS)
        .opacity(isHovered ? 1 : 0)
        #endif
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        #endif
    }
}

// MARK: - Conditional Modifier

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Branch Indicator

struct BranchIndicator: View {
    let info: BranchInfo
    @Binding var showPicker: Bool
    let onSwitchBranch: (String, Int) -> Void

    /// `‹ 2 / 3 ›`：灰字无底（不做深绿套浅绿，plan-thinking-branch）；箭头直接切，点数字弹列表
    var body: some View {
        HStack(spacing: 0) {
            arrow("chevron.left", to: info.currentIndex - 1)
            Button { showPicker = true } label: {
                Text("\(info.currentIndex + 1) / \(info.branchCount)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(Theme.textMuted)
                    .frame(minWidth: 44, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("第 \(info.currentIndex + 1) 个版本，共 \(info.branchCount) 个，点开列表")
            arrow("chevron.right", to: info.currentIndex + 1)
        }
        #if os(iOS)
        .sheet(isPresented: $showPicker) {
            BranchPickerList(info: info, onPick: pick)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.mainBg)
        }
        #else
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            BranchPickerList(info: info, onPick: pick)
                .frame(width: 380, height: 420)
        }
        #endif
    }

    private func arrow(_ symbol: String, to index: Int) -> some View {
        let enabled = index >= 0 && index < info.branchCount
        return Button { pick(index) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textMuted.opacity(enabled ? 1 : 0.3))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func pick(_ index: Int) {
        guard index != info.currentIndex else { showPicker = false; return }
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
        showPicker = false
        onSwitchBranch(info.branchNodeId, index)
    }
}

/// 分支列表（底部面板 / mac popover）：每条两行预览 +「谁 · 时间 [· ★ 主线]」；当前条 = 深色字压浅薄荷面 + ✓
struct BranchPickerList: View {
    let info: BranchInfo
    let onPick: (Int) -> Void
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage("userName") private var floorUserName = "你"
    /// 卡库 ③-4：有效身份名，只换显示副本
    private var userName: String { viewModel?.personaDisplayName(profile: profileManager?.currentProfile) ?? floorUserName }
    @AppStorage("assistantName") private var assistantName = "助手"

    var body: some View {
        VStack(spacing: 0) {
            Text("\(info.branchCount) 条分支")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .padding(.top, 16)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(info.branchChildren, id: \.index) { branch in
                        row(branch)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.mainBg)
    }

    private func row(_ branch: (index: Int, node: MessageNode, isMainPath: Bool)) -> some View {
        let isCurrent = branch.index == info.currentIndex
        let node = branch.node
        var meta = node.role == "user" ? userName : assistantName
        if let t = node.createTime { meta += " · " + t.formatted(.dateTime.month().day().hour().minute()) }
        return HStack(alignment: .top, spacing: 10) {
            Text("\(branch.index + 1)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(Theme.textMuted)
                .frame(width: 18, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(ConversationTitler.plainText(EffectiveCharacterContext(charName: assistantName, userName: userName)
                    .expand(ContentCleaner.clean(node.content, cacheKey: node.id))).prefix(200)))
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(meta)
                    if branch.isMainPath { Label("主线", systemImage: "star.fill") }
                }
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
            }
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(isCurrent ? Theme.accent : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { onPick(branch.index) }
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - TagPickerPopover（聊天页 nav ⋯ Menu 的「移到文件夹」sheet）
//
// 09-26 标签 → 文件夹（一对一）：单选，写 `Conversation.folderId`；再点当前那个 = 移出。

struct TagPickerPopover: View {
    let conversationId: String
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var tags: [ConversationTag]
    @Query private var conversations: [Conversation]

    init(conversationId: String, profileId: String) {
        self.conversationId = conversationId
        self.profileId = profileId
        _tags = Query(
            filter: #Predicate<ConversationTag> { $0.profileId == profileId },
            sort: \ConversationTag.order
        )
        _conversations = Query(filter: #Predicate<Conversation> { $0.id == conversationId })
    }

    private var conversation: Conversation? { conversations.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("移到文件夹")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("完成") { dismiss() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if tags.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 36))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                    Text("还没有文件夹")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                    Text("去对话列表顶上的 ＋ 新建")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(tags) { tag in
                            let isOn = conversation?.folderId == tag.id
                            Button {
                                conversation?.folderId = isOn ? nil : tag.id
                                try? modelContext.save()
                            } label: {
                                HStack(spacing: 10) {
                                    FolderIconView(tag: tag, size: 18)
                                    Text(tag.name)
                                        .font(.system(size: 15))
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer()
                                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundColor(isOn ? Theme.branchIndicator : Theme.textMuted.opacity(0.4))
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
        .macEscapeToDismiss { dismiss() }   // S1-5
    }
}

// MARK: - Transient Notice Capsule (B20 part 2)

/// 极简临时提示胶囊（已切换到分支等）。挂在 chat page 顶部。
/// 透明度自驱：onAppear fade in，2s 后由 caller 清 viewModel.transientNotice。
private struct TransientNoticeCapsule: View {
    let text: String
    @State private var opacity: Double = 0

    var body: some View {
        ChatSystemCapsule(text: text)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.18)) { opacity = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeIn(duration: 0.32)) { opacity = 0 }
                }
            }
    }
}

#if os(macOS)
#endif

#if os(iOS)
/// 独立 modifier，避免给 CardFlow 的大视图表达式叠加两个 Observation 泛型。
private struct CardFlowCallPresentation<CallContent: View>: ViewModifier {
    let conversationID: String?
    @Binding var presented: Bool
    let callContent: CallContent
    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $presented) { callContent }
            .modifier(NativeCallPresentation(conversationID: conversationID, presented: $presented))
    }
}

private struct NativeCallPresentation: ViewModifier {
    let conversationID: String?
    @Binding var presented: Bool
    func body(content: Content) -> some View {
        content
            .onChange(of: NativeCallCoordinator.shared.readyToPresent, initial: true) { _, _ in presentIfReady() }
            .onChange(of: conversationID) { _, _ in presentIfReady() }
    }
    private func presentIfReady() {
        if NativeCallCoordinator.shared.readyToPresent,
           NativeCallCoordinator.shared.current?.chat_id == conversationID { presented = true }
    }
}
#endif
