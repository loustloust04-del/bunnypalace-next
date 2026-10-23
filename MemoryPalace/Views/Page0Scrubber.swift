#if os(iOS)
import SwiftUI
import UIKit

/// page0 对话列表可拖滚动条（plan-page0-scrubber）。iPhone 专用；列表是正向 LazyVStack。
/// 外观 / 手势参数照 page1 的 ChatScrubber，但每个 SidebarView 自己一个 model——
/// page0 与聊天页同时活在横向分页器里，共用单例会互抢 scrollView。
@Observable
final class Page0ScrubberModel {
    static var isEnabledDevice: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    /// iPhone 关系统竖条（换自绘），iPad 保持
    static var systemIndicator: ScrollIndicatorVisibility { isEnabledDevice ? .hidden : .automatic }

    /// 几何进度：0 = 顶、1 = 已加载部分的底
    var progress: CGFloat = 0
    var scrollable = false
    /// 手滚时淡入，停 1.2s 淡出
    var shown = false
    /// 捕获期间 thumb 中心（轨道坐标），由手势驱动；nil = 跟几何进度
    var dragThumbY: CGFloat?
    var hint: Page0ScrubberHint?

    /// LazyVStack 已实化的行（row onAppear/onDisappear），取序号中位数当视口中心
    @ObservationIgnored var realizedRows: Set<String> = []
    /// 拖动中：loadMore 只记账不翻页（contentSize 中途变长会让 thumb↔offset 映射跳），松手补一次
    @ObservationIgnored var isScrubbing = false
    @ObservationIgnored var pendingLoadMore = false
    @ObservationIgnored var cancelActive: (() -> Void)?
    @ObservationIgnored var ticker: Timer?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private(set) weak var scrollView: UIScrollView?
    @ObservationIgnored private var hideWork: DispatchWorkItem?

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
        let d = Self.scrollRange(sv)
        let canScroll = d > 1
        if scrollable != canScroll { scrollable = canScroll }
        guard dragThumbY == nil else { return }
        if canScroll {
            let p = min(max((sv.contentOffset.y + sv.adjustedContentInset.top) / d, 0), 1)
            if abs(p - progress) > 0.0005 { progress = p }
        }
        // 只认手滚（拖 / 惯性）：程序跳转、下拉刷新回弹不闪条
        if userScroll, sv.isDragging || sv.isDecelerating { flash() }
    }

    static func scrollRange(_ sv: UIScrollView) -> CGFloat {
        max(0, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom)
    }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func holdVisible() {
        hideWork?.cancel()
        if !shown { shown = true }
    }
}

struct Page0ScrubberHint: Equatable {
    var label: String
    /// 跨桶才震：今天 / 昨天 / 本周 / 今年按月 / 往年按年；置顶一桶；标题排序按首字
    var bucket: String
    var position: Int
    var total: Int
}

/// 放在 LazyVStack 背景里，沿 superview 找到列表的 UIScrollView 交给 model（同 CardFlowView 的 StreamScrollAnchor 套路）
struct Page0ScrubberAnchor: UIViewRepresentable {
    let model: Page0ScrubberModel

    func makeUIView(context: Context) -> AnchorView {
        let v = AnchorView(frame: .zero)
        v.isHidden = true
        v.model = model
        return v
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        uiView.model = model
        uiView.attachIfNeeded()
    }

    final class AnchorView: UIView {
        weak var model: Page0ScrubberModel?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard window != nil, let model else { return }
            var node: UIView? = superview
            while let cur = node {
                if let sv = cur as? UIScrollView {
                    model.attach(sv)
                    return
                }
                node = cur.superview
            }
        }
    }
}

/// 行实化 / 回收登记（LazyVStack onAppear/onDisappear）
struct Page0ScrubberRowTracker: ViewModifier {
    let id: String
    let model: Page0ScrubberModel

    func body(content: Content) -> some View {
        content
            .onAppear { _ = model.realizedRows.insert(id) }
            .onDisappear { _ = model.realizedRows.remove(id) }
    }
}

struct Page0Scrubber: View {
    /// 一行用什么分组：置顶段 / 按标题排序取首字 / 其余按时间
    enum Key {
        case pinned
        case title(String)
        case date(Date)
    }

    /// 抓住那一刻的列表快照：行 id（列表顺序）、总数、按序号取分组（只算中心那行，不预算全表）
    struct Entries {
        let ids: [String]
        let total: Int
        let key: (Int) -> Key?
    }

    let model: Page0ScrubberModel
    /// 最近搜过盖着 → false（进行中遇到即取消）；键盘在本视图内判
    let enabled: Bool
    /// 轨道底让开卡片底部计数条
    let bottomInset: CGFloat
    let entries: () -> Entries
    let onLoadMore: () -> Void

    @ObservedObject private var keyboardBridge = KeyboardInsetBridge.shared

    private static let thumbLength: CGFloat = 44
    private static let hitWidth: CGFloat = 30
    private static let hitHeight: CGFloat = 64
    private static let trackTop: CGFloat = 10

    /// 一次抓取。拖动 = 按像素写 offset（同系统滚动条）：thumb 与几何进度 1:1，首抓零跳
    private struct Session {
        let entries: Entries
        let index: [String: Int]
        let fingerOffset: CGFloat   // 手指 − fingerOffset = thumb 中心
        let minY: CGFloat
        let maxY: CGFloat
        var progress: CGFloat
        var center: Int?
        var atEnd: Int?             // 0 = 顶、1 = 底；离开端点 ≥2% 才重置
        var cancelled = false
    }
    @State private var session: Session?
    @GestureState private var pressing = false

    private var keyboardUp: Bool { keyboardBridge.kbVisible || keyboardBridge.kbTransitioning }

    var body: some View {
        GeometryReader { geo in
            let track = trackRange(geo.size.height)
            let visible = enabled && !keyboardUp && model.scrollable && track.upperBound - track.lowerBound > 120
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
            .coordinateSpace(name: "page0ScrubTrack")
        }
        .accessibilityHidden(true)
        .onAppear { model.cancelActive = { cancel() } }
        .onDisappear { cancel(); model.cancelActive = nil }
        .onChange(of: pressing) { _, isPressing in
            // 系统取消手势时 onEnded 不一定来：按压态复位即收尾
            if !isPressing, session != nil { end() }
        }
        .onChange(of: enabled) { _, on in if !on { cancel() } }
        .onChange(of: keyboardUp) { _, up in if up { cancel() } }
    }

    // MARK: 几何

    private func trackRange(_ height: CGFloat) -> ClosedRange<CGFloat> {
        let top = Self.trackTop
        return top...max(top, height - bottomInset)
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
        DragGesture(minimumDistance: 0, coordinateSpace: .named("page0ScrubTrack"))
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
        guard enabled, !keyboardUp, let sv = model.scrollView else { return }
        let e = entries()
        guard e.ids.count > 1 else { return }
        let (lo, hi) = thumbBounds(track)
        let y0 = min(max(model.dragThumbY ?? idleThumbY(track), lo), hi)
        let p = hi > lo ? (y0 - lo) / (hi - lo) : 0
        var index: [String: Int] = [:]
        index.reserveCapacity(e.ids.count)
        for (i, id) in e.ids.enumerated() where index[id] == nil { index[id] = i }
        // 惯性还在滑就停住，免得和拖动同时写 offset
        sv.setContentOffset(sv.contentOffset, animated: false)
        var s = Session(
            entries: e, index: index, fingerOffset: startY - y0, minY: lo, maxY: hi,
            progress: p, atEnd: p <= 0.001 ? 0 : (p >= 0.999 ? 1 : nil)
        )
        s.center = centerIndex(s)
        session = s
        model.isScrubbing = true
        model.holdVisible()
        model.dragThumbY = y0
        model.hint = s.center.flatMap { hint(at: $0, s) }
        model.ticker?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        model.ticker = t
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func update(fingerY: CGFloat) {
        guard var s = session, !s.cancelled, let sv = model.scrollView else { return }
        let y = min(max(fingerY - s.fingerOffset, s.minY), s.maxY)
        model.dragThumbY = y
        let p = s.maxY > s.minY ? (y - s.minY) / (s.maxY - s.minY) : 0
        guard abs(p - s.progress) > 0.0001 else { return }
        s.progress = p
        // 可滚距离每次现读（LazyVStack 边测边修 contentSize）
        sv.contentOffset.y = -sv.adjustedContentInset.top + p * Page0ScrubberModel.scrollRange(sv)

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

    /// 行实化是布局后异步到的：手指停住时也要跟上中心行
    private func tick() {
        guard var s = session, !s.cancelled else { return }
        refreshHint(&s)
        session = s
    }

    private func end() {
        guard session != nil else { return }
        model.ticker?.invalidate()
        model.ticker = nil
        session = nil
        withAnimation(.easeOut(duration: 0.2)) {
            model.dragThumbY = nil
            model.refresh()
        }
        release()
    }

    /// 键盘 / 禁用门 / 换 ScrollView：放手，手指还按着就等它抬起再清 session
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
        release()
    }

    private func release() {
        model.hint = nil
        model.scheduleHide()
        guard model.isScrubbing else { return }
        model.isScrubbing = false
        if model.pendingLoadMore {
            model.pendingLoadMore = false
            let load = onLoadMore
            DispatchQueue.main.async { load() }
        }
    }

    // MARK: 视口中心 / 提示

    /// 已实化行序号的中位数 ≈ 视口中心；端点直接钉首 / 末行
    private func centerIndex(_ s: Session) -> Int? {
        let n = s.entries.ids.count
        guard n > 0 else { return nil }
        if s.progress <= 0.001 { return 0 }
        if s.progress >= 0.999 { return n - 1 }
        let realized = model.realizedRows.compactMap { s.index[$0] }.sorted()
        guard !realized.isEmpty else { return min(n - 1, Int((s.progress * CGFloat(n - 1)).rounded())) }
        return realized[realized.count / 2]
    }

    private func refreshHint(_ s: inout Session) {
        guard let i = centerIndex(s), i != s.center else { return }
        let old = s.center.flatMap { hint(at: $0, s) }
        let new = hint(at: i, s)
        if s.atEnd == nil, let new, let old, new.bucket != old.bucket {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        s.center = i
        if let new { model.hint = new }
    }

    private func hint(at i: Int, _ s: Session) -> Page0ScrubberHint? {
        guard i >= 0, i < s.entries.ids.count, let key = s.entries.key(i) else { return nil }
        let (label, bucket) = Self.describe(key)
        return .init(label: label, bucket: bucket, position: i + 1, total: max(s.entries.total, s.entries.ids.count))
    }

    static func describe(_ key: Key, now: Date = Date()) -> (label: String, bucket: String) {
        switch key {
        case .pinned:
            return ("置顶", "pinned")
        case .title(let title):
            let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "#"
            return (first, "title:" + first)
        case .date(let date):
            let cal = Calendar.current
            if cal.isDateInToday(date) { return ("今天", "today") }
            if cal.isDateInYesterday(date) { return ("昨天", "yesterday") }
            let label = ConversationRow.smartDate(date)
            if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return (label, "week") }
            let year = cal.component(.year, from: date)
            if year == cal.component(.year, from: now) { return (label, "month:\(cal.component(.month, from: date))") }
            return (label, "year:\(year)")
        }
    }

    private func hintBubble(_ hint: Page0ScrubberHint) -> some View {
        Text(verbatim: "\(hint.label) · 第 \(hint.position) / 共 \(hint.total)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.textPrimary)
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .fixedSize()
    }
}
#endif
