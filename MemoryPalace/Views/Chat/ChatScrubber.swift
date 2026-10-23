#if os(iOS)
import SwiftUI
import UIKit

/// 聊天页可拖滚动条（plan-chat-scrubber v2）。iPhone 专用；列表是翻转的 LazyVStack，
/// 系统竖条已关，这根自己画：平时细条只在手滚时出现，可见时抓住变粗 + 提示 + 震动，拖动按消息跳。
@Observable
final class ChatScrubberModel {
    static let shared = ChatScrubberModel()

    static var isEnabledDevice: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    /// iPhone 关系统竖条（换自绘），iPad 保持
    static var systemIndicator: ScrollIndicatorVisibility { isEnabledDevice ? .hidden : .automatic }

    /// 几何进度：0 = 视觉最旧（顶）、1 = 最新（底）
    var progress: CGFloat = 1
    /// 可滚距离够（D > ε）
    var scrollable = false
    /// 手滚时淡入，停 1.2s 淡出
    var shown = false
    /// 捕获期间 thumb 中心（轨道坐标），由手势驱动；nil = 跟几何进度
    var dragThumbY: CGFloat?
    var hint: Hint?

    struct Hint: Equatable {
        var day: String?
        var turn: Int
        var userLine: String
    }

    /// LazyVStack 已实化的行（row onAppear/onDisappear）
    @ObservationIgnored var realizedRows: Set<String> = []
    /// 行在 scrollContent（= 物理 content）坐标的上下沿，行背景 GeometryReader 写；远端的是陈旧值，只信已实化行
    @ObservationIgnored var rowFrames: [String: ClosedRange<CGFloat>] = [:]
    /// 进行中的抓取立即放手（换 ScrollView 实例 / 键盘开始过渡），由视图挂
    @ObservationIgnored var cancelActive: (() -> Void)?
    /// 抓取期间 10Hz：行 frame 是异步到的，拖动那一刻常常还没测；最旧端要持续往真顶收敛
    @ObservationIgnored var ticker: Timer?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private weak var scrollView: UIScrollView?
    @ObservationIgnored private var hideWork: DispatchWorkItem?

    /// AnchorView.didMoveToWindow 换到新 sv 时调
    func attach(_ sv: UIScrollView) {
        guard Self.isEnabledDevice, scrollView !== sv else { return }
        observations.removeAll()
        scrollView = sv
        cancelActive?()
        observations = [
            sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in self?.geometryChanged(sv, userScroll: true) },
            sv.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in self?.geometryChanged(sv, userScroll: false) },
            sv.observe(\.bounds, options: [.new]) { [weak self] sv, _ in self?.geometryChanged(sv, userScroll: false) },
        ]
        geometryChanged(sv, userScroll: false)
    }

    private func geometryChanged(_ sv: UIScrollView, userScroll: Bool) {
        let t = sv.adjustedContentInset.top
        let d = max(0, sv.contentSize.height - sv.bounds.height + t + sv.adjustedContentInset.bottom)
        let canScroll = d > 1
        if scrollable != canScroll { scrollable = canScroll }
        guard dragThumbY == nil else { return }
        if canScroll {
            let p = 1 - min(max((sv.contentOffset.y + t) / d, 0), 1)
            if abs(p - progress) > 0.0005 { progress = p }
        }
        // 只认手滚（拖 / 惯性）：流式钉住、glide、程序跳转不闪条
        if userScroll, sv.isDragging || sv.isDecelerating { flash() }
    }

    /// 捕获结束后按当前几何重算（捕获期间 KVO 只记不画）
    func refresh() {
        if let sv = scrollView { geometryChanged(sv, userScroll: false) }
    }

    func flash() {
        if !shown { shown = true }
        scheduleHide()
    }

    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dragThumbY == nil else { return }
            self.shown = false
        }
        hideWork = work
        // UI 测试用启动参数 `-chatScrubberHideDelay 30` 拉长（XCUITest 等静止的空当会错过 1.2s）
        let override = UserDefaults.standard.double(forKey: "chatScrubberHideDelay")
        let delay = override > 0 ? override : 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func holdVisible() {
        hideWork?.cancel()
        if !shown { shown = true }
    }

    var chatScrollView: UIScrollView? { scrollView }
}


/// 聊天列表滚动装饰：隐藏竖向边缘效果 + iPhone 关系统竖条（修饰链已在编译器类型检查上限边上，合成一个）
struct ChatListScrollChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .vertical)
            .scrollIndicators(ChatScrubberModel.systemIndicator, axes: .vertical)
    }
}

/// 行实化 / 回收登记（LazyVStack onAppear/onDisappear）
struct ChatScrubberRowTracker: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content
            .onAppear { _ = ChatScrubberModel.shared.realizedRows.insert(id) }
            .onDisappear { _ = ChatScrubberModel.shared.realizedRows.remove(id) }
    }
}

struct ChatScrubber: View {
    let path: [MessageNode]
    let conversationId: String
    /// 贴纸编辑 / 查找 / 长按菜单 / 加载中 / 键盘在 → false（进行中遇到即取消）
    let enabled: Bool

    @ObservedObject private var keyboardBridge = KeyboardInsetBridge.shared
    private var model: ChatScrubberModel { ChatScrubberModel.shared }

    private static let thumbLength: CGFloat = 44
    private static let hitWidth: CGFloat = 30
    private static let hitHeight: CGFloat = 64

    /// 一次抓取。拖动 = 按像素写 offset（同系统滚动条）：thumb 与几何进度 1:1，首抓零跳；
    /// 不按消息 ID 远跳——3000 条实测 `scrollTo(首条)` 要把中间两千多行测一遍，主线程卡 8s（plan §8）
    private struct Session {
        let hints: [String: ChatScrubberModel.Hint]
        let fingerOffset: CGFloat   // 手指 − fingerOffset = thumb 中心
        let minY: CGFloat
        let maxY: CGFloat
        var progress: CGFloat
        var centerId: String?
        var atEnd: Int?             // 0 = 最旧端、1 = 最新端；离开端点才重置
        var cancelled = false
    }
    @State private var session: Session?
    @State private var generation = 0
    /// 轨道换算用的全局 minY（只要 minY：GeometryReader 闭包里直读 .global 会在任何全局位置变化（含翻页的水平平移、layerSync）时整段重跑；onGeometryChange 去重，minY 不变不触发（plan-paging-decouple A-7，同 Page2HomeView 顶栏））
    @State private var globalMinY: CGFloat = 0
    @GestureState private var pressing = false

    var body: some View {
        GeometryReader { geo in
            let track = trackRange(geo)
            let visible = enabled && model.scrollable && path.count > 1 && track.upperBound - track.lowerBound > 120
            let grabbed = session.map { !$0.cancelled } ?? false
            let thumbY = model.dragThumbY ?? idleThumbY(track)
            ZStack(alignment: .topTrailing) {
                Capsule()
                    .fill(Theme.textMuted.opacity(grabbed ? 0.55 : 0.32))
                    .frame(width: grabbed ? 9 : 4, height: Self.thumbLength)
                    .position(x: geo.size.width - (grabbed ? 7.5 : 6), y: thumbY)
                    .allowsHitTesting(false)

                if grabbed, let hint = model.hint {
                    hintBubble(hint)
                        .frame(width: max(0, geo.size.width - 34), alignment: .trailing)
                        .position(x: max(0, geo.size.width - 34) / 2, y: thumbY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                Color.clear
                    .frame(width: Self.hitWidth, height: Self.hitHeight)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(track: track))
                    .allowsHitTesting(visible && (model.shown || grabbed))
                    .position(x: geo.size.width - Self.hitWidth / 2, y: thumbY)
            }
            .opacity(visible && (model.shown || grabbed) ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: model.shown)
            .animation(.spring(duration: 0.22), value: grabbed)
            .coordinateSpace(name: "chatScrubTrack")
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { globalMinY = $0 }
        .accessibilityHidden(true)
        .onAppear { model.cancelActive = { cancel() } }
        .onDisappear { cancel(); model.cancelActive = nil }
        .onChange(of: pressing) { _, isPressing in
            // 系统取消手势时 onEnded 不一定来：按压态复位即收尾
            if !isPressing, session != nil { end() }
        }
        .onChange(of: enabled) { _, on in if !on { cancel() } }
        .onChange(of: keyboardBridge.kbTransitioning) { _, t in if t { cancel() } }
        .onChange(of: keyboardBridge.barGrowth) { _, _ in cancel() }
        .onChange(of: conversationId) { _, _ in cancel() }
    }

    // MARK: 几何

    /// 轨道（本视图坐标）：顶栏下缘 ~ 输入字段顶上方让开回底钮 / 查找钮
    private func trackRange(_ geo: GeometryProxy) -> ClosedRange<CGFloat> {
        let minY = globalMinY
        let safeTop = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.first ?? 47
        let top = safeTop + 64 - minY
        let fieldTop = keyboardBridge.containerTop > 0 ? keyboardBridge.inputFieldTop : geo.size.height + minY - 108
        let bottom = fieldTop - 60 - minY
        return top...max(top, bottom)
    }

    private func thumbBounds(_ track: ClosedRange<CGFloat>) -> (CGFloat, CGFloat) {
        let lo = track.lowerBound + Self.thumbLength / 2
        return (lo, max(lo, track.upperBound - Self.thumbLength / 2))
    }

    private func idleThumbY(_ track: ClosedRange<CGFloat>) -> CGFloat {
        let (lo, hi) = thumbBounds(track)
        return lo + (hi - lo) * model.progress
    }

    // MARK: 手势

    private func dragGesture(track: ClosedRange<CGFloat>) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("chatScrubTrack"))
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { value in
                if session == nil {
                    begin(startY: value.startLocation.y, track: track)
                }
                update(fingerY: value.location.y)
            }
            .onEnded { _ in end() }
    }

    private func begin(startY: CGFloat, track: ClosedRange<CGFloat>) {
        guard enabled, !keyboardBridge.kbTransitioning, path.count > 1, model.chatScrollView != nil else { return }
        let (lo, hi) = thumbBounds(track)
        let y0 = min(max(model.dragThumbY ?? idleThumbY(track), lo), hi)
        let p = hi > lo ? (y0 - lo) / (hi - lo) : 1
        let hintList = Self.buildHints(path)
        var hints: [String: ChatScrubberModel.Hint] = [:]
        hints.reserveCapacity(path.count)
        for (node, hint) in zip(path, hintList) { hints[node.id] = hint }
        generation += 1
        var s = Session(
            hints: hints, fingerOffset: startY - y0, minY: lo, maxY: hi,
            progress: p, atEnd: p <= 0.001 ? 0 : (p >= 0.999 ? 1 : nil)
        )
        s.centerId = centerId()
        session = s
        model.holdVisible()
        model.dragThumbY = y0
        model.hint = s.centerId.flatMap { hints[$0] }
        StreamScrollAnchor.AnchorView.beginScrub()
        model.ticker?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        model.ticker = t
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        KBProbe.log("[SCRUB] begin p=\(String(format: "%.3f", p)) track=\(Int(lo))…\(Int(hi))")
    }

    private func update(fingerY: CGFloat) {
        guard var s = session, !s.cancelled, let sv = model.chatScrollView else { return }
        let y = min(max(fingerY - s.fingerOffset, s.minY), s.maxY)
        model.dragThumbY = y
        let p = s.maxY > s.minY ? (y - s.minY) / (s.maxY - s.minY) : 1
        guard abs(p - s.progress) > 0.0001 else { return }
        s.progress = p
        // 可滚距离每次现读（LazyVStack 边测边修 contentSize）；p=1 恰好是绝对底 -T
        let t = sv.adjustedContentInset.top
        sv.contentOffset.y = -t + (1 - p) * Self.scrollRange(sv)

        // 端点：进入一次 medium，离开 ≥2% 才重置
        let end: Int? = p <= 0.001 ? 0 : (p >= 0.999 ? 1 : nil)
        if let end, s.atEnd != end {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            s.atEnd = end
        } else if end == nil, let at = s.atEnd, at == 0 ? p > 0.02 : p < 0.98 {
            s.atEnd = nil
        }
        refreshHint(&s)
        session = s
    }

    private static func scrollRange(_ sv: UIScrollView) -> CGFloat {
        max(0, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom)
    }

    /// 提示 / 换天：跟视口中心那条走
    private func refreshHint(_ s: inout Session) {
        guard let id = centerId(), id != s.centerId else { return }
        let old = s.centerId.flatMap { s.hints[$0] }
        let new = s.hints[id]
        if s.atEnd == nil, let day = new?.day, let oldDay = old?.day, day != oldDay {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        s.centerId = id
        if let new { model.hint = new }
    }

    /// 最旧端：估高把「顶」估近了，每次钉到当前最大 offset，末端行被测一批、上限前推，几次收敛到真顶。
    /// 不用 scrollTo(首条)——翻转列表里首条在物理最末，精确定位要把全部行测一遍（3000 条卡 9s）
    private func pinOldestEnd() {
        guard let sv = model.chatScrollView else { return }
        let target = StreamScrollAnchor.oldestOffset(sv)
        if abs(sv.contentOffset.y - target) > 0.5 { sv.contentOffset.y = target }
    }

    private func tick() {
        guard var s = session, !s.cancelled else { return }
        if s.progress <= 0.001 { pinOldestEnd() }
        refreshHint(&s)
        session = s
    }

    private func end() {
        guard let s = session else { return }
        guard !s.cancelled else { finish(); return }
        finish()
        let live = s.progress >= 0.999
        let gen = generation
        KBProbe.log("[SCRUB] end p=\(String(format: "%.3f", s.progress)) center=\(s.centerId ?? "-")")
        #if DEBUG
        if let sv = model.chatScrollView {
            let rows = model.realizedRows.compactMap { id in model.rowFrames[id].map { (id, $0) } }
            let span = rows.map(\.1.lowerBound).min().map { lo in "\(Int(lo))…\(Int(rows.map(\.1.upperBound).max() ?? 0))" } ?? "-"
            KBProbe.log("[SCRUB] end diag off=\(Int(sv.contentOffset.y)) cs=\(Int(sv.contentSize.height)) H=\(Int(sv.bounds.height)) realized=\(model.realizedRows.count) framed=\(rows.count) span=\(span) ids=\(rows.map(\.0).sorted().prefix(3))")
        }
        #endif
        // 最旧端：松手后再钉 5 次（0.1s 一次）收敛到真顶，然后才放所有权
        let settleTicks = s.progress <= 0.001 ? 5 : 0
        func settle(_ n: Int) {
            guard generation == gen, session == nil else { return }
            if n > 0 {
                pinOldestEnd()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle(n - 1) }
            } else {
                StreamScrollAnchor.AnchorView.endScrub(resumeFollow: live)
            }
        }
        DispatchQueue.main.async { settle(settleTicks) }
    }

    /// 键盘 / 会话 / 禁用门：放掉所有权，手指还按着就等它抬起
    private func cancel() {
        guard var s = session, !s.cancelled else { return }
        s.cancelled = true
        session = s
        model.ticker?.invalidate()
        model.ticker = nil
        withAnimation(.easeOut(duration: 0.2)) {
            model.dragThumbY = nil
            model.refresh()
        }
        model.hint = nil
        model.scheduleHide()
        StreamScrollAnchor.AnchorView.endScrub(resumeFollow: false)
        KBProbe.log("[SCRUB] cancel")
    }

    private func finish() {
        model.ticker?.invalidate()
        model.ticker = nil
        session = nil
        withAnimation(.easeOut(duration: 0.2)) {
            model.dragThumbY = nil
            model.refresh()
        }
        model.hint = nil
        model.scheduleHide()
    }

    // MARK: 视口中心 / 提示

    /// 视口中心所在的那条：只看已实化且与视口相交的行；包含中心的优先，落在间距里取最近边
    private func centerId() -> String? {
        guard let sv = model.chatScrollView else { return nil }
        let top = sv.contentOffset.y
        let bottom = top + sv.bounds.height
        let center = (top + bottom) / 2
        var best: (id: String, distance: CGFloat)?
        for id in model.realizedRows {
            guard let f = model.rowFrames[id], f.upperBound >= top, f.lowerBound <= bottom else { continue }
            let d = f.contains(center) ? 0 : min(abs(f.lowerBound - center), abs(f.upperBound - center))
            if best == nil || d < best!.distance { best = (id, d) }
        }
        return best?.id
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let yearDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f
    }()

    /// 一次 O(N)：第几轮（截至该条的 user 数，开头 assistant 算第 1 轮）/ 那轮问的话 / 日历日
    static func buildHints(_ path: [MessageNode]) -> [ChatScrubberModel.Hint] {
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        var turn = 0
        var line = ""
        var dayCache: [Date: String] = [:]
        return path.map { node in
            if node.role == "user" {
                turn += 1
                let head = node.content.prefix(240)
                let first = head.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                let trimmed = first.trimmingCharacters(in: .whitespaces)
                line = trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
            }
            var day: String?
            if let t = node.createTime {
                let start = cal.startOfDay(for: t)
                if let cached = dayCache[start] {
                    day = cached
                } else {
                    let f = cal.component(.year, from: t) == thisYear ? dayFormatter : yearDayFormatter
                    let s = f.string(from: t)
                    dayCache[start] = s
                    day = s
                }
            }
            return .init(day: day, turn: max(turn, 1), userLine: line)
        }
    }

    private func hintBubble(_ hint: ChatScrubberModel.Hint) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text([hint.day, "第 \(hint.turn) 轮"].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            if !hint.userLine.isEmpty {
                Text(hint.userLine)
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fixedSize()
    }
}
#endif
