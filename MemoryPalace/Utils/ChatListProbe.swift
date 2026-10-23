#if (DEBUG || PERF_BENCH) && os(iOS)
import SwiftUI
import UIKit

/// 聊天列表测量探针（plan-chat-list-perf-p0 §5）：测量台只经它与渲染账本看列表。
/// 全部只在严格测量角色（`PerfHarness.strictMeasure`）下写；插入点首句判角色，非测量进程零行为。
enum ChatEngine: String { case swiftui, uikit }

struct AppliedSnapshot {
    let revision: Int
    let ids: [String]
    let at: Double
    let profileId: String?
    let conversationId: String?
}

struct ProbeVisibleRow {
    let id: String
    let windowRect: CGRect
    let mountGen: Int
}

@MainActor protocol ChatListProbing: AnyObject {
    var implementation: ChatEngine { get }
    var ownerToken: UUID { get }
    var mountGen: Int { get }
    var profileId: String? { get }
    var conversationId: String? { get }
    var scrollView: UIScrollView? { get }
    var appliedSnapshot: AppliedSnapshot? { get }
    var occlusion: PerfChatCore.Occlusion { get }
    var declaredRowSpacing: CGFloat { get }
    /// 列表可视区在 window 中的矩形（扣遮挡带之前）
    func viewportRect(in window: UIWindow) -> CGRect?
    func visibleRows(in window: UIWindow) -> [ProbeVisibleRow]
    /// R6 C-06 / K-03：深翻驱动只经这几项碰滚动几何，引擎各自声明。「往更旧走」时 offset 的符号（反转列表 +1、正向列表 −1）
    var olderOffsetSign: CGFloat { get }
    /// 最新端（视觉底）的 offset
    func newestOffset() -> CGFloat?
    /// 最旧端（视觉顶）按当前估高算的 offset（估高边测边修，到端前会往外长）
    func oldestOffsetEstimate() -> CGFloat?
    /// deepJump：产品自己的「滚到最旧 / 回到最新」入口（不是测量台写 offset）
    func scrollToOldest()
    func scrollToNewest()
    /// R7 C-08：流式场景只经这几项碰跟随，引擎各自实现。离最新端（视觉底）的距离（pt，≥ 0 往历史）
    func distanceFromBottom() -> CGFloat?
    /// 跟随状态：产品自己的「在底」判定与是否已让出跟随（让出期间不回底、不滑入）
    func followState() -> ChatFollowState?
    /// 让出跟随（≈ 手指 / 滚动条抓住列表：停掉回底滑入，之后程序化写位置不被拉回）
    func yieldFollow()
    /// 结束让出：resume = true 等价于停在最新端松手（生成中恢复跟随）；false = 停在历史、不回底
    func endYield(resumeFollow: Bool)
    /// 往历史方向移 `points`（不越过最旧端），语义写死为「抓住 → 拖过去 → 停在历史松手、不回底」= yield + 写位置 + endYield(false)。返回实际移动量
    func scrollAwayFromBottom(by points: CGFloat) -> CGFloat
    /// 流式行渲染输入的「应有长度」（同产品加工链：文章 = 正文快照长度；气泡 = 已完成块总长）
    func renderableLength(raw: String, article: Bool) -> Int
}

struct ChatFollowState {
    let fromBottom: CGFloat
    /// 产品自己的在底判定（旧页 = |fromBottom| < 200）
    let atBottom: Bool
    let yielded: Bool
}

/// 注册表只 weak 持有；token 规则见 PerfChatCore.ProbeRegistry（迟到注销不清新注册）
@MainActor enum ChatListProbe {
    private static var registry = PerfChatCore.ProbeRegistry()
    private static weak var probe: (any ChatListProbing)?

    static func register(_ p: any ChatListProbing) -> Int {
        let gen = registry.register(p.ownerToken)
        probe = p
        PerfChatV1.noteMount(gen)
        return gen
    }

    static func unregister(token: UUID) {
        if registry.unregister(token) { probe = nil }
    }

    static var current: (any ChatListProbing)? { probe }
    static var mountGen: Int { registry.mountGen }
}

/// 旧页 Probe：由 `StreamScrollAnchor.AnchorView` 强持有，随 ScrollView 挂载生灭
@MainActor final class SwiftUIChatListProbe: ChatListProbing {
    let implementation = ChatEngine.swiftui
    let ownerToken = UUID()
    private(set) var mountGen = 0
    private(set) weak var scrollView: UIScrollView?

    var appliedSnapshot: AppliedSnapshot? { PerfRenderLedger.applied }
    var profileId: String? { PerfRenderLedger.applied?.profileId }
    var conversationId: String? { PerfRenderLedger.applied?.conversationId }
    var occlusion: PerfChatCore.Occlusion { PerfRenderLedger.occlusion }
    var declaredRowSpacing: CGFloat { PerfRenderLedger.rowSpacing }

    func attach(_ sv: UIScrollView) {
        scrollView = sv
        mountGen = ChatListProbe.register(self)
    }

    func detach() { ChatListProbe.unregister(token: ownerToken) }

    func visibleRows(in window: UIWindow) -> [ProbeVisibleRow] {
        guard let sv = scrollView, sv.window === window else { return [] }
        return PerfRowRegistry.rows(in: window, under: sv).compactMap {
            $0.id == Self.testDropRow ? nil : ProbeVisibleRow(id: $0.id, windowRect: $0.rect, mountGen: mountGen)
        }
    }

    /// 测试钩子 MP_PERF_TEST_DROP_ROW=<nodeId>（R6 C-05 反例）：探针假装漏登记这一行（行照常实化、照常渲染）
    static let testDropRow = PerfHarness.strictMeasure ? PerfHarness.env["MP_PERF_TEST_DROP_ROW"] : nil

    /// 视口 = sv 可视区在 window 中的矩形（layer convert 吃到 SwiftUI 的翻转变换）
    func viewportRect(in window: UIWindow) -> CGRect? {
        guard let sv = scrollView, sv.window === window else { return nil }
        return sv.layer.convert(sv.layer.bounds, to: window.layer)
    }

    /// 反转 LazyVStack：更旧 = offset 增；底 = −adjustedContentInset.top；最旧端 = StreamScrollAnchor.oldestOffset（通用 UIScrollView 算术）
    let olderOffsetSign: CGFloat = 1

    func newestOffset() -> CGFloat? { scrollView.map { -$0.adjustedContentInset.top } }

    func oldestOffsetEstimate() -> CGFloat? { scrollView.map(StreamScrollAnchor.oldestOffset) }

    /// 旧页入口作用在 AnchorView.chatScrollView 上；与本探针挂的不是同一个 sv 时不动（deepJump 落到收敛超时，不滚错列表）
    func scrollToOldest() {
        guard let sv = scrollView, StreamScrollAnchor.AnchorView.chatScrollView === sv else { return }
        StreamScrollAnchor.scrollChatToOldest()
    }

    func scrollToNewest() {
        guard let sv = scrollView, StreamScrollAnchor.AnchorView.chatScrollView === sv else { return }
        StreamScrollAnchor.scrollChatToBottom()
    }

    /// 反转列表：offset − 最新端 offset（= contentOffset.y + adjustedContentInset.top）
    func distanceFromBottom() -> CGFloat? { scrollView.map { $0.contentOffset.y + $0.adjustedContentInset.top } }

    /// 产品在底阈值（CardFlowView atBottomWatch / endScrub：|fromBottom| < 200）
    static let productAtBottomPt: CGFloat = 200

    func followState() -> ChatFollowState? {
        guard let fb = distanceFromBottom() else { return nil }
        return ChatFollowState(fromBottom: fb, atBottom: abs(fb) < Self.productAtBottomPt, yielded: StreamScrollAnchor.AnchorView.scrubbing)
    }

    /// 旧页：经滚动条的抓取入口（停回底滑入 + 停惯性）。只在 AnchorView 盯的就是本探针的 sv 时转调
    func yieldFollow() {
        guard let sv = scrollView, StreamScrollAnchor.AnchorView.chatScrollView === sv else { return }
        StreamScrollAnchor.AnchorView.beginScrub()
    }

    func endYield(resumeFollow: Bool) {
        guard let sv = scrollView, StreamScrollAnchor.AnchorView.chatScrollView === sv else { return }
        StreamScrollAnchor.AnchorView.endScrub(resumeFollow: resumeFollow)
    }

    /// 旧页回底滑入（glide display link）在在底跟随时一直在跑，程序化写 offset 不置 isTracking、打断不了它：
    /// 必须先让出再写（§14-59），松手不恢复跟随
    func scrollAwayFromBottom(by points: CGFloat) -> CGFloat {
        guard let sv = scrollView, StreamScrollAnchor.AnchorView.chatScrollView === sv, points > 0 else { return 0 }
        let y = sv.contentOffset.y
        let target = min(y + olderOffsetSign * points, max(y, StreamScrollAnchor.oldestOffset(sv)))
        yieldFollow()
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: target), animated: false)
        endYield(resumeFollow: false)
        return target - y
    }

    func renderableLength(raw: String, article: Bool) -> Int {
        let content = ContentCleaner.extractThinking(from: ContentCleaner.clean(raw, cacheKey: nil, cached: false)).content
        guard !article else { return content.count }
        return BubbleModeRow.streamingBlocks(content).filter { !BubbleMarkdownSimplifier.isRenderEmpty($0) }.reduce(0) { $0 + $1.count }
    }
}

/// 每行的 UIKit 句柄（`CellGrowthAnchor.CellView`，挂在 BubbleView 背景上 = 整行 frame）：按 nodeId weak 持有
@MainActor enum PerfRowRegistry {
    private final class Box { weak var view: UIView?; init(_ v: UIView) { view = v } }
    /// R5 C-09 / K-07：句柄 ↔ id 双向表，换 id 先清旧键（UIKit 页 cell 复用是常态）
    private static var keys = PerfChatCore.RowKeys<ObjectIdentifier>()
    private static var boxes: [ObjectIdentifier: Box] = [:]

    static func moved(_ view: UIView, id: String) {
        guard PerfHarness.strictMeasure else { return }
        let c0 = CACurrentMediaTime()
        defer { PerfInlineCost.add(since: c0) }
        let h = ObjectIdentifier(view)
        keys.moved(h, id: id, inWindow: view.window != nil)
        boxes[h] = keys.byHandle[h] == nil ? nil : Box(view)
    }

    /// 已实化行（LazyVStack 只实化视口附近）：O(实化行数)，不扫全路径
    static func rows(in window: UIWindow, under sv: UIScrollView) -> [(id: String, rect: CGRect)] {
        var out: [(id: String, rect: CGRect)] = []
        for (id, h) in keys.byId {
            guard let v = boxes[h]?.view else { keys.drop(h); boxes[h] = nil; continue }
            guard v.window === window, v.isDescendant(of: sv) else { continue }
            out.append((id, v.layer.convert(v.layer.bounds, to: window.layer)))
        }
        return out
    }

    /// 登记表当前大小（深翻诊断：LazyVStack 留在窗口里的行数 = 每帧扫描量）
    static var count: Int { keys.byId.count }
}

/// R6 C-03 / C-08：产品路径上测量登记自身的耗时与次数（行登记、回执、标记解析），以及 MarkdownRenderCache 查找命中 / 未命中计数。
/// 只在严格角色下累加（调用点都已判角色）；深翻按阶段做差报。display-link 回调外的这部分不在 probeSelfMs 里
enum PerfInlineCost {
    nonisolated(unsafe) private(set) static var seconds = 0.0
    nonisolated(unsafe) private(set) static var calls = 0
    nonisolated(unsafe) private(set) static var mdHit = 0
    nonisolated(unsafe) private(set) static var mdMiss = 0

    static func add(since t0: Double) {
        seconds += CACurrentMediaTime() - t0
        calls += 1
    }

    static func noteMdLookup(hit: Bool) {
        if hit { mdHit += 1 } else { mdMiss += 1 }
    }
}

/// 渲染账本（§5.2）：静态、非观察；body 里只登记已用于渲染的值
@MainActor enum PerfRenderLedger {
    struct Consumed { let digest: UInt64?; let mode: String; let t: Double }
    struct Markdown { let nodeId: String; let digest: UInt64; let cacheDims: String; let kind: String; let reqId: Int; let t: Double }
    struct Jump { let target: String; let outcome: String; let t: Double }
    struct StreamInput { let nodeId: String; let chars: Int; let mode: String; let t: Double }

    private(set) static var applied: AppliedSnapshot?
    private static var appliedKey: PerfChatCore.AppliedKey?
    private(set) static var occlusion = PerfChatCore.Occlusion(bottom: 0, top: 0, keyboardPad: 0)
    private(set) static var rowSpacing: CGFloat = 0
    /// 每行最近一次消费回执
    private(set) static var consumed: [String: Consumed] = [:]
    /// R7-11：观察集节点的全部消费回执（收尾期闪过一帧错内容、后被覆盖也看得见）
    private(set) static var consumedLog: [String: [Consumed]] = [:]
    private(set) static var markdown: [Markdown] = []
    /// nodeId → markdown 回执下标（R5：就绪判定每帧只查链上行，不线性扫全账）
    private(set) static var markdownIndex: [String: [Int]] = [:]
    /// R5 C-03：ChatMarkdownView.body 构造 CachedMarkdownView 前放下本行 nodeId，init 同步取走；
    /// 没有 fixture 标记的长文（> 同步排版阈值）靠它登记异步回执
    private static var bodyNode: String?
    private(set) static var jumps: [Jump] = []
    /// 纵切 6 渲染输入进度（§5.2 streamInput）：只记变化
    private(set) static var streamInputs: [StreamInput] = []
    private static var lastStreamChars: [String: Int] = [:]
    /// 测试钩子 MP_PERF_TEST_DROP_FINISH_JUMP：测量台把收尾导航的目标（助手节点）写在这里，列表不消费它
    static var dropJumpTarget: String?
    /// 观察集：只对这些节点当场算正文摘要（测量台在请求时设为目标对话的 expectedRows）
    static var observed: Set<String> = []
    /// 测试钩子（§13 4.4 验收）：`top` = 视觉顶遮挡带当 0（覆盖率口径下分母会变，成链口径只是链更长）；
    /// `all` = 上下都当 0（视觉底带是 §14-3 成链的起点契约，声明错会挡住就绪）
    static let zeroOcclusion = PerfHarness.env["MP_PERF_TEST_ZERO_OCCLUSION"] ?? ""

    /// CardFlowView body 的 ForEach 处：revision 没变就不重算 ids（不逐帧 O(N)）
    static func noteApplied(revision: Int, path: [MessageNode], profileId: String?, conversationId: String?,
                            occlusionBottom: CGFloat, occlusionTop: CGFloat, keyboardPad: CGFloat, spacing: CGFloat) {
        guard PerfHarness.strictMeasure else { return }
        let c0 = CACurrentMediaTime()
        defer { PerfInlineCost.add(since: c0) }
        occlusion = PerfChatCore.Occlusion(bottom: zeroOcclusion == "all" ? 0 : occlusionBottom,
                                           top: zeroOcclusion.isEmpty ? occlusionTop : 0, keyboardPad: keyboardPad)
        rowSpacing = spacing
        // R5 C-10：revision 只作单调参考，另核行数与首末行身份（漏自增的写点改了路径也会重算）
        let key = PerfChatCore.AppliedKey(revision: revision, count: path.count, first: path.first.map(ObjectIdentifier.init),
                                          last: path.last.map(ObjectIdentifier.init), profileId: profileId, conversationId: conversationId)
        if key == appliedKey { return }
        appliedKey = key
        applied = AppliedSnapshot(revision: revision, ids: path.map(\.id), at: CACurrentMediaTime(),
                                  profileId: profileId, conversationId: conversationId)
    }

    /// 渲染输入消费处（文章模式静态正文 / 气泡模式静态拆块）：对本次消费的 node.content 当场算摘要
    static func noteConsumed(nodeId: String, content: String, mode: String) {
        guard PerfHarness.strictMeasure else { return }
        let c0 = CACurrentMediaTime()
        defer { PerfInlineCost.add(since: c0) }
        let digest = observed.contains(nodeId) ? PerfChatCore.fnv1a64(content) : nil
        let c = Consumed(digest: digest, mode: mode, t: CACurrentMediaTime())
        consumed[nodeId] = c
        if digest != nil { consumedLog[nodeId, default: []].append(c) }
    }

    /// fixture 标记 `⟦PERF:<nodeId>⟧`（文本前 64 字）；普通内容不带标记、不登记
    static func markerNode(_ text: String) -> String? {
        let c0 = CACurrentMediaTime()
        defer { PerfInlineCost.add(since: c0) }
        let head = text.prefix(64)
        guard let open = head.range(of: "⟦PERF:"), let close = head.range(of: "⟧", range: open.upperBound..<head.endIndex) else { return nil }
        return String(head[open.upperBound..<close.lowerBound])
    }

    static func setBodyNode(_ id: String?) {
        guard PerfHarness.strictMeasure else { return }
        bodyNode = id
    }

    static func takeBodyNode() -> String? {
        defer { bodyNode = nil }
        return bodyNode
    }

    static func noteMarkdown(nodeId: String, text: String, cacheDims: String, kind: String, reqId: Int) {
        guard PerfHarness.strictMeasure else { return }
        let c0 = CACurrentMediaTime()
        defer { PerfInlineCost.add(since: c0) }
        markdownIndex[nodeId, default: []].append(markdown.count)
        markdown.append(Markdown(nodeId: nodeId, digest: PerfChatCore.fnv1a64(text), cacheDims: cacheDims, kind: kind,
                                 reqId: reqId, t: CACurrentMediaTime()))
        if reqId < PerfHarness.currentReqId { PerfChatV1.noteLate("markdown") }
        // M3：真身落地（task 里命中 / 异步解析完）= 这一行的空占位收口
        if kind == "taskHit" || kind == "asyncEnd", let i = blankOpen.removeValue(forKey: nodeId) { blanks[i].end = CACurrentMediaTime() }
    }

    // MARK: M3 不闪空探针（plan-chat-list-perf §1）

    /// 一段空占位：CachedMarkdownView 以 renderable == nil 上屏到真身落地；frames = 期间 display-link 回调数，
    /// visibleFrames = 其中这一行与有效视口相交的帧（= 用户看得到的空白帧）
    struct Blank { let nodeId: String; let reqId: Int; let begin: Double; var end: Double?; var frames = 0; var visibleFrames = 0 }
    private(set) static var blanks: [Blank] = []
    private static var blankOpen: [String: Int] = [:]
    /// 反例钩子 MP_PERF_TEST_BLANK_NODE=<nodeId>：这一行首见强制空占位、迟 300ms 才填（MarkdownRenderCache）
    static let testBlankNode = PerfHarness.strictMeasure ? PerfHarness.env["MP_PERF_TEST_BLANK_NODE"] : nil
    /// R12-03 主线程忙版：配合 MP_PERF_TEST_BLANK_NODE，=1 时不是 sleep 300ms，而是先等一次提交再主线程空转 200ms
    static let testBlankBusy = PerfHarness.strictMeasure && PerfHarness.env["MP_PERF_TEST_BLANK_BUSY"] == "1"

    static func noteBlankBegin(nodeId: String, reqId: Int) {
        guard PerfHarness.strictMeasure, blankOpen[nodeId] == nil else { return }
        blankOpen[nodeId] = blanks.count
        blanks.append(Blank(nodeId: nodeId, reqId: reqId, begin: CACurrentMediaTime()))
    }

    /// ChatV1Sampler 每帧调：开着的空占位逐个记帧，行矩形与有效视口相交（空占位行高可能是 0，按上下边比）另记 visibleFrames
    static func blankTick() {
        guard !blankOpen.isEmpty else { return }
        var visible: Set<String> = []
        if let probe = ChatListProbe.current, let sv = probe.scrollView, let window = sv.window, let vp = probe.viewportRect(in: window),
           let eff = PerfChatCore.effectiveViewport(vp, occlusion: probe.occlusion) {
            for r in probe.visibleRows(in: window) where blankOpen[r.id] != nil && r.windowRect.maxY >= eff.minY && r.windowRect.minY <= eff.maxY {
                visible.insert(r.id)
            }
        }
        for (id, i) in blankOpen {
            blanks[i].frames += 1
            if visible.contains(id) { blanks[i].visibleFrames += 1 }
        }
    }

    /// 文章模式 StreamingMarkdownSource 实际 yield 给渲染器的正文长度 / 气泡模式交给气泡的已完成块总长（节拍器输出不当「已显示」）
    static func noteStreamInput(nodeId: String, chars: Int, mode: String) {
        guard PerfHarness.strictMeasure, lastStreamChars[nodeId] != chars else { return }
        lastStreamChars[nodeId] = chars
        streamInputs.append(StreamInput(nodeId: nodeId, chars: chars, mode: mode, t: CACurrentMediaTime()))
    }

    static func noteJump(target: String, outcome: String) {
        guard PerfHarness.strictMeasure else { return }
        jumps.append(Jump(target: target, outcome: outcome, t: CACurrentMediaTime()))
    }
}

extension StreamScrollAnchor.AnchorView {
    /// didMoveToWindow 首句调用：进窗口注册（新挂载代际），离窗口按自己的 token 注销
    func perfProbeMoved() {
        guard PerfHarness.strictMeasure else { return }
        guard window != nil else { perfProbe?.detach(); return }
        var node: UIView? = superview
        while let cur = node, !(cur is UIScrollView) { node = cur.superview }
        guard let sv = node as? UIScrollView else { return }
        let p = perfProbe ?? SwiftUIChatListProbe()
        perfProbe = p
        p.attach(sv)
    }
}
#endif
