#if (DEBUG || PERF_BENCH) && os(iOS)
import Combine
import SwiftUI
import SwiftStreamingMarkdown
import UIKit

/// P1a-0 spike（docs/spike-uikit-chat-page.md）：在真实 PagingVC → chat HC 链里把 CardFlowView 换成最小反转
/// UICollectionView。一次性挂载壳，不进产品路径；普通 Release 不编。删除时机由车头定。
/// 开关：env `MP_SPIKE_UIKIT=a|b|c|d`（测量台）或「开发调试 → UIKit 聊天页 spike」（UserDefaults，冷启动生效）。
enum UIKitChatSpike {
    /// a = UIHostingConfiguration 包现有 BubbleView；b = 原生 cell + 现有 ParagraphUIView（自测高）；
    /// c = 原生 cell + 后台预排版 + 高度缓存（显示仍用 ParagraphUIView）；d = c 的高度缓存 + 纯绘制（不用 UITextView）；
    /// e = 对照：c 的高度缓存 + 空 cell（只有头 / 操作条，不放正文），拆容器底；m = 混合：常见消息走 c，复杂消息（isComplex）走 hosting
    enum CellMode: String, CaseIterable { case a, b, c, d, e, m }
    static let defaultsKey = "spikeUIKitChatMode"
    static let env = ProcessInfo.processInfo.environment
    /// R13-07：PERF_BENCH 测量包只认 env，不读开发调试里存的 UserDefaults
    static let mode: CellMode? = {
        #if DEBUG
        let raw = env["MP_SPIKE_UIKIT"] ?? UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        #else
        let raw = env["MP_SPIKE_UIKIT"] ?? ""
        #endif
        return CellMode(rawValue: raw)
    }()
    /// hosting 行去掉测量探针修饰（.sheet / .onReceive / VStack / transition），只剩 BubbleView —— 量兜底成本
    static let bareHosting = env["MP_SPIKE_BARE"] == "1"
    /// c / d / e / m 的后台预排版：all = 全部排完再上；first = 首屏（最新 20 条）先排先上，其余后台补高度
    static let prelayoutFirst = env["MP_SPIKE_PRELAYOUT"] == "first"
    /// 混合臂的复杂消息判定（写死）：含代码块围栏 ``` 或 markdown 表格（| 开头的行 + 分隔行），或带附件段 / 思考链。
    /// 标题、列表、引用、强调、行内代码都算常见消息，走原生（spike 的原生实现把它们退化成段落，成本同量级）
    static func isComplex(_ node: MessageNode) -> Bool {
        if node.segmentsData != nil { return true }
        if let t = node.ccThinking, !t.isEmpty { return true }
        let c = node.content
        if c.contains("```") { return true }
        let lines = c.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, l) in lines.enumerated() where i > 0 && l.hasPrefix("|") && l.contains("---") && lines[i - 1].hasPrefix("|") { return true }
        return false
    }
    /// ① 对照：MP_SPIKE_NOID=1 时 hosting 行不加 .id(node.id)
    static let stableID = env["MP_SPIKE_NOID"] != "1"
    /// ⑤ 垫块落地方式：lazy = 只 invalidate 等别人的 layout pass；chain = 再把祖先链全标脏（保证 PagingVC 的
    /// hc.view.layoutIfNeeded 一定走到）；now = sink 里立刻无动画 layoutIfNeeded
    static let padMode = env["MP_SPIKE_PADMODE"] ?? "now"
    /// 进程启动读一次（ContentView body 里只读这个 let，不碰 UserDefaults / @Observable）
    static let engaged: Bool = mode != nil || UIKitChatSpikeBench.requested
}

/// ContentView 里唯一的挂载点：spike 关时直接是 CardFlowView（测量台在旧页上也要跑，所以壳在旧页模式也可能在）
struct UIKitChatSpikeSwitch: View {
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    var body: some View {
        Group {
            if UIKitChatSpike.mode != nil {
                // 同旧页列表：上下安全区由内容 inset 自己管（CardFlowView 的 .ignoresSafeArea(.container, [.top, .bottom])）
                UIKitChatSpikeHost(viewModel: viewModel)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
            } else {
                CardFlowView(viewModel: viewModel, stickerVM: stickerVM)
            }
        }
        .onAppear { UIKitChatSpikeBench.startIfRequested(profileId: profileManager?.currentProfile.id) }
    }
}

struct UIKitChatSpikeHost: UIViewControllerRepresentable {
    var viewModel: ConversationViewModel

    func makeUIViewController(context: Context) -> SpikeChatViewController {
        SpikeChatViewController(viewModel: viewModel, env: context.environment, mode: UIKitChatSpike.mode ?? .a)
    }

    /// ContentView.body 每次重算都会调到这里：只换 env，不碰列表
    func updateUIViewController(_ vc: SpikeChatViewController, context: Context) {
        vc.env = context.environment
    }
}

// MARK: - 文本模型（原生 cell 用；可在后台线程构建 / 测高）

struct SpikeTextModel: @unchecked Sendable {
    static let headerHeight: CGFloat = 22
    static let paraSpacing: CGFloat = 10
    /// 底部操作条（时间 + 4 个图标），对齐真实气泡的行尾 chrome 份量
    static let footerHeight: CGFloat = 28
    let header: String
    let paras: [NSMutableAttributedString]
    var heights: [CGFloat]?
    var width: CGFloat = 0
    var total: CGFloat? {
        guard let heights else { return nil }
        return Self.headerHeight + heights.reduce(0, +) + Self.paraSpacing * CGFloat(max(0, heights.count)) + Self.footerHeight
    }

    static func make(role: String, content: String, userName: String, assistantName: String) -> SpikeTextModel {
        let font = UIFont.systemFont(ofSize: 17 * CGFloat(UserDefaults.standard.object(forKey: "fontScale") as? Double ?? 1.2) / 1.2)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        let blocks = content.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let paras: [NSMutableAttributedString] = blocks.map { block in
            var text = block
            while text.hasPrefix("#") { text.removeFirst() }
            text = text.replacingOccurrences(of: "\n- ", with: "\n• ")
            if text.hasPrefix("- ") { text = "• " + text.dropFirst(2) }
            let parsed = (try? AttributedString(markdown: text.trimmingCharacters(in: .whitespaces),
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                .map { NSMutableAttributedString(attributedString: NSAttributedString($0)) }
                ?? NSMutableAttributedString(string: text)
            let all = NSRange(location: 0, length: parsed.length)
            parsed.addAttributes([.font: font, .foregroundColor: UIColor.label, .paragraphStyle: style], range: all)
            return parsed
        }
        return SpikeTextModel(header: role == "user" ? userName : assistantName, paras: paras)
    }

    /// 后台预排版（c / d）：NSAttributedString 的 TextKit 测高是线程安全的（不挂视图）
    mutating func measure(width: CGFloat) {
        self.width = width
        heights = paras.map { Self.paraHeight($0, width: width) }
    }

    /// 段高缓存（键 = 宽 + 段文本）：流式只量新增 / 变了的那段
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var heightCache: [String: CGFloat] = [:]
    static func paraHeight(_ para: NSAttributedString, width: CGFloat) -> CGFloat {
        let key = "\(Int(width))|\(para.string)"
        cacheLock.lock()
        let hit = heightCache[key]
        cacheLock.unlock()
        if let hit { return hit }
        let h = para.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height.rounded(.up)
        cacheLock.lock()
        heightCache[key] = h
        cacheLock.unlock()
        return h
    }
}

// MARK: - 布局：反转列表（物理顶 = 视觉底），垫块是内容（物理顶的一段空），高度缓存 + 同帧 contentOffsetAdjustment

final class SpikeListLayout: UICollectionViewLayout {
    var ids: [String] = []
    var heights: [String: CGFloat] = [:]
    /// 已量过（非估高）的 id
    var measured: Set<String> = []
    var padHeight: CGFloat = 0
    var spacing: CGFloat = 31
    var insetH: CGFloat = 16
    var insetV: CGFloat = 12
    var maxWidth: CGFloat = 760
    var estimated: CGFloat = 140
    /// UIKit 插入弹（③ P1）：这些 id 出现时从缩小 + 透明开始
    var popIds: Set<String> = []
    var onHeightChange: ((String, CGFloat, CGFloat) -> Void)?
    var onPrepare: (() -> Void)?

    private var attrs: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var laidOutWidth: CGFloat = 0
    private var preparedPad: CGFloat = 0
    private static let flip = CGAffineTransform(scaleX: 1, y: -1)

    var itemWidth: CGFloat {
        let w = collectionView?.bounds.width ?? 0
        return max(0, min(w - insetH * 2, maxWidth))
    }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        if laidOutWidth != cv.bounds.width {
            // 宽度变了：全部降为估高（值留作估计），让 cell 重新自测
            if laidOutWidth != 0 { measured.removeAll() }
            laidOutWidth = cv.bounds.width
        }
        let w = itemWidth
        let x = (cv.bounds.width - w) / 2
        var y = padHeight + insetV
        if attrs.count != ids.count {
            attrs = (0..<ids.count).map { UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: $0, section: 0)) }
        }
        for (i, id) in ids.enumerated() {
            let h = heights[id] ?? estimated
            let a = attrs[i]
            a.transform = .identity
            a.size = CGSize(width: w, height: h)
            a.center = CGPoint(x: x + w / 2, y: y + h / 2)
            a.transform = Self.flip
            a.alpha = 1
            y += h + spacing
        }
        contentHeight = ids.isEmpty ? padHeight : y - spacing + insetV
        if padHeight != preparedPad {
            SpikeProbes.log(String(format: "prepare pad %.0f→%.0f inAnim=%.2f off=%.0f", preparedPad, padHeight,
                                   UIView.inheritedAnimationDuration, cv.contentOffset.y))
            preparedPad = padHeight
        }
        onPrepare?()
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // 二分找第一个 maxY >= rect.minY
        var lo = 0, hi = attrs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if attrs[mid].frame.maxY < rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var out: [UICollectionViewLayoutAttributes] = []
        var i = lo
        while i < attrs.count, attrs[i].frame.minY <= rect.maxY { out.append(attrs[i]); i += 1 }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < attrs.count ? attrs[indexPath.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != laidOutWidth
    }

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        guard preferred.indexPath.item < ids.count else { return false }
        let id = ids[preferred.indexPath.item]
        let h = preferred.size.height
        if !measured.contains(id) { return true }
        return abs((heights[id] ?? estimated) - h) > 0.5
    }

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let ctx = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        guard preferred.indexPath.item < ids.count, let cv = collectionView else { return ctx }
        let id = ids[preferred.indexPath.item]
        let old = heights[id] ?? estimated
        let new = preferred.size.height
        heights[id] = new
        measured.insert(id)
        let delta = new - old
        if abs(delta) > 0.01 {
            onHeightChange?(id, old, new)
            // 生长补偿同帧：变化的行整个在视口物理上方（= 视觉下方、更新的那侧之外）→ 推 offset 保住所看
            if original.frame.maxY <= cv.bounds.minY + 0.5 {
                ctx.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
            }
            ctx.contentSizeAdjustment = CGSize(width: 0, height: delta)
        }
        return ctx
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard itemIndexPath.item < ids.count, popIds.contains(ids[itemIndexPath.item]),
              let a = layoutAttributesForItem(at: itemIndexPath)?.copy() as? UICollectionViewLayoutAttributes else {
            return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
        }
        a.alpha = 0
        a.transform = Self.flip.scaledBy(x: 0.6, y: 0.6)
        return a
    }
}

// MARK: - cell

/// 所有 cell 共用：记 id、测高计时
class SpikeBaseCell: UICollectionViewCell {
    var nodeId = ""
    override func preferredLayoutAttributesFitting(_ a: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let t0 = CACurrentMediaTime()
        let h = fittingHeight(width: a.size.width)
        SpikeProbes.noteSizing(nodeId, ms: (CACurrentMediaTime() - t0) * 1000)
        guard let h else { return a }
        let r = a.copy() as! UICollectionViewLayoutAttributes
        r.size = CGSize(width: a.size.width, height: h)
        return r
    }
    /// nil = 高度已知（预排版），不自测
    func fittingHeight(width: CGFloat) -> CGFloat? { nil }
}

final class SpikeHostingCell: SpikeBaseCell {
    override func fittingHeight(width: CGFloat) -> CGFloat? {
        contentView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                            withHorizontalFittingPriority: .required,
                                            verticalFittingPriority: .fittingSizeLevel).height.rounded(.up)
    }
}

/// b / c：头 + 一串 ParagraphUIView；d：头 + 一串纯绘制段落
final class SpikeNativeCell: SpikeBaseCell {
    private let header = UILabel()
    private let time = UILabel()
    private let icons: [UIImageView] = ["doc.on.doc", "arrow.clockwise", "star", "ellipsis"].map {
        let v = UIImageView(image: UIImage(systemName: $0))
        v.tintColor = .tertiaryLabel
        v.contentMode = .scaleAspectFit
        return v
    }
    enum Body { case text, drawn, empty }
    private var paraViews: [UIView] = []
    private(set) var model: SpikeTextModel?
    private var body: Body = .text

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabel
        contentView.addSubview(header)
        time.font = .systemFont(ofSize: 11)
        time.textColor = .tertiaryLabel
        contentView.addSubview(time)
        icons.forEach { contentView.addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        // ParagraphUIView 摘下即回池（池只认 superview == nil）
        paraViews.forEach { $0.removeFromSuperview() }
        paraViews = []
    }

    func configure(_ model: SpikeTextModel, body: Body) {
        let t0 = CACurrentMediaTime()
        self.model = model
        if body != self.body {
            paraViews.forEach { $0.removeFromSuperview() }
            paraViews = []
        }
        self.body = body
        header.text = model.header
        time.text = "10:24"
        let n = body == .empty ? 0 : model.paras.count
        while paraViews.count > n { paraViews.removeLast().removeFromSuperview() }
        for (i, para) in model.paras.prefix(n).enumerated() {
            if i < paraViews.count {
                // 同 cell 重配（流式）：原地换内容，setParagraphContents 内容没变就早退
                if let tv = paraViews[i] as? UITextView { ParagraphSpikeAccess.setContents(tv, para, lineSpacing: nil) }
                else if let dv = paraViews[i] as? SpikeDrawnParagraphView, dv.text != para { dv.text = para }
                continue
            }
            if body == .drawn {
                let v = SpikeDrawnParagraphView()
                v.text = para
                contentView.addSubview(v)
                paraViews.append(v)
            } else {
                // R13-01：取一个立刻挂上——池只认 superview == nil，攒着最后一起挂会反复拿到同一个视图（多段只剩最后一段）
                let v = ParagraphSpikeAccess.vend()
                contentView.addSubview(v)
                ParagraphSpikeAccess.setContents(v, para, lineSpacing: nil)
                paraViews.append(v)
            }
        }
        setNeedsLayout()
        SpikeProbes.noteConfigure(nodeId, ms: (CACurrentMediaTime() - t0) * 1000)
    }

    override func fittingHeight(width: CGFloat) -> CGFloat? {
        guard let model else { return nil }
        if let total = model.total, abs(model.width - width) < 0.5 { return total }
        let hs = paraViews.map { $0.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up) }
        return SpikeTextModel.headerHeight + hs.reduce(0, +) + SpikeTextModel.paraSpacing * CGFloat(hs.count) + SpikeTextModel.footerHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        header.frame = CGRect(x: 0, y: 0, width: w, height: SpikeTextModel.headerHeight)
        var y = SpikeTextModel.headerHeight + SpikeTextModel.paraSpacing
        let cached = (model?.width ?? -1) == w ? model?.heights : nil
        for (i, v) in paraViews.enumerated() {
            let h = cached?[i] ?? v.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height.rounded(.up)
            v.frame = CGRect(x: 0, y: y, width: w, height: h)
            y += h + SpikeTextModel.paraSpacing
        }
        time.frame = CGRect(x: 0, y: y, width: 60, height: 20)
        for (i, v) in icons.enumerated() { v.frame = CGRect(x: 70 + CGFloat(i) * 30, y: y, width: 18, height: 18) }
    }
}

/// d：不用 UITextView，只画（每段一个小 layer，避免整条 5000pt 大位图）
final class SpikeDrawnParagraphView: UIView {
    var text = NSAttributedString() { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        layer.drawsAsynchronously = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: text.boundingRect(with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height.rounded(.up))
    }
}

// MARK: - hosting 行（a）：真实 BubbleView + 探针（① token、② sheet、③ 子树插入）

struct SpikeBubbleRow: View {
    let node: MessageNode
    let viewModel: ConversationViewModel
    let popInsert: Bool
    @State private var token = UUID()
    @State private var showSheet = false
    @State private var shown: Bool

    init(node: MessageNode, viewModel: ConversationViewModel, popInsert: Bool) {
        self.node = node
        self.viewModel = viewModel
        self.popInsert = popInsert
        _shown = State(initialValue: !popInsert)
    }

    var body: some View {
        VStack(spacing: 0) {
            if shown {
                bubble.transition(BubblePopTuning.popTransition(isUser: node.role == "user"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            SpikeProbes.noteAppear(id: node.id, token: token)
            if popInsert, !shown { withAnimation(BubblePopTuning.popAnimation) { shown = true } }
        }
        .onReceive(SpikeProbes.sheetRequests) { id in if id == node.id { showSheet = true } }
        .sheet(isPresented: $showSheet) {
            Text("spike sheet \(node.id)").presentationDetents([.medium])
        }
    }

    private var bubble: some View { Self.bubble(node: node, viewModel: viewModel) }

    static func bubble(node: MessageNode, viewModel: ConversationViewModel) -> BubbleView {
        let convId = viewModel.selectedConversation?.id ?? ""
        let info = viewModel.branchInfoMap[node.id]
        return BubbleView(
            node: node,
            hasBranches: info != nil,
            branchInfo: info,
            isStreaming: viewModel.isNodeStreaming(nodeId: node.id, conversationId: convId) && node.role == "assistant",
            viewModel: viewModel,
            isHighlighted: viewModel.highlightedNodeId == node.id,
            isSearchMatch: false,
            onToggleFavorite: {},
            onTogglePin: {},
            onSoftDelete: {},
            onSwitchBranch: { _, _ in }
        )
    }
}

// MARK: - 控制器

@MainActor
final class SpikeChatViewController: UIViewController, UICollectionViewDelegate {
    let viewModel: ConversationViewModel
    let mode: UIKitChatSpike.CellMode
    var env: EnvironmentValues
    let layout = SpikeListLayout()
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var nodes: [String: MessageNode] = [:]
    /// 测量台塞的假行（不入库的 MessageNode）：id → (node, 物理位置：在 currentPath 倒序里的插入下标)
    var synthetic: [String: MessageNode] = [:]
    var idOverride: (([String]) -> [String])?
    private var models: [String: SpikeTextModel] = [:]
    /// 混合臂（m）里走 hosting 的复杂消息
    private(set) var complexIds: Set<String> = []
    private var usesPrelayout: Bool { mode == .c || mode == .d || mode == .e || mode == .m }
    private var loadedConvId: String?
    private var bag: Set<AnyCancellable> = []
    private var curExtra: CGFloat = 0
    private var curGrowth: CGFloat = 0
    private var isAtBottom = true
    private let prelayoutQueue = DispatchQueue(label: "spike.prelayout", qos: .userInitiated)
    private var prelayoutGen = 0
    /// 测量台：每次 apply 完回调（id 列表）
    var onApplied: (([String]) -> Void)?

    init(viewModel: ConversationViewModel, env: EnvironmentValues, mode: UIKitChatSpike.CellMode) {
        self.viewModel = viewModel
        self.env = env
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        layout.spacing = CGFloat(UserDefaults.standard.object(forKey: "bubbleSpacing") as? Double ?? 31)
        layout.insetH = env.chatMetrics.listInsetH
        layout.insetV = env.chatMetrics.listInsetV
        layout.maxWidth = Theme.contentMaxWidth
        layout.onHeightChange = { id, old, new in SpikeProbes.noteHeight(id, old: old, new: new) }
        let cv = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        cv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cv.backgroundColor = .clear
        cv.transform = CGAffineTransform(scaleX: 1, y: -1)
        cv.contentInsetAdjustmentBehavior = .never
        cv.contentInset = UIEdgeInsets(top: 100, left: 0, bottom: 150, right: 0)
        cv.scrollsToTop = false
        cv.showsVerticalScrollIndicator = false
        cv.keyboardDismissMode = .none
        cv.delegate = self
        cv.selfSizingInvalidation = .enabled
        view.addSubview(cv)
        collectionView = cv
        // 接管 PagingVC / 补偿器 / 滚动条用的静态引用：AnchorView 必须直接是 collectionView 的子视图（cell 里有 UITextView）
        let anchor = StreamScrollAnchor.AnchorView(frame: .zero)
        anchor.isHidden = true
        cv.addSubview(anchor)
        StreamScrollAnchor.AnchorView.onAtBottomChange = { [weak self] atBottom in
            guard let self else { return }
            self.isAtBottom = atBottom
            self.viewModel.isViewAtBottom = atBottom
            if atBottom { self.maybeLiftPadSuppression() }
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapList))
        tap.cancelsTouchesInView = false
        cv.addGestureRecognizer(tap)

        let hostingReg = UICollectionView.CellRegistration<SpikeHostingCell, String> { [weak self] cell, _, id in
            guard let self, let node = self.node(id) else { return }
            let t0 = CACurrentMediaTime()
            cell.nodeId = id
            let row = SpikeBubbleRow(node: node, viewModel: self.viewModel, popInsert: SpikeProbes.popInsertIds.contains(id))
            let env = self.env
            if UIKitChatSpike.bareHosting {
                let bare = SpikeBubbleRow.bubble(node: node, viewModel: self.viewModel)
                cell.contentConfiguration = UIHostingConfiguration { bare.id(id).environment(\.self, env) }.margins(.all, 0)
            } else if UIKitChatSpike.stableID {
                cell.contentConfiguration = UIHostingConfiguration { row.id(id).environment(\.self, env) }.margins(.all, 0)
            } else {
                cell.contentConfiguration = UIHostingConfiguration { row.environment(\.self, env) }.margins(.all, 0)
            }
            SpikeProbes.noteConfigure(id, ms: (CACurrentMediaTime() - t0) * 1000)
        }
        let nativeReg = UICollectionView.CellRegistration<SpikeNativeCell, String> { [weak self] cell, _, id in
            guard let self, let node = self.node(id) else { return }
            cell.nodeId = id
            cell.configure(self.model(for: node), body: self.mode == .d ? .drawn : (self.mode == .e ? .empty : .text))
        }
        let mode = self.mode
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: cv) { [weak self] cv, ip, id in
            let hosting = mode == .a || (mode == .m && self?.complexIds.contains(id) == true)
            return hosting ? cv.dequeueConfiguredReusableCell(using: hostingReg, for: ip, item: id)
                           : cv.dequeueConfiguredReusableCell(using: nativeReg, for: ip, item: id)
        }

        let bridge = KeyboardInsetBridge.shared
        curExtra = bridge.extra
        curGrowth = bridge.barGrowth
        layout.padHeight = max(0, curExtra) + max(0, curGrowth)
        // @Published 是 willSet：sink 里只用传进来的新值
        bridge.$extra.dropFirst().sink { [weak self] new in
            MainActor.assumeIsolated { self?.extraChanged(to: new) }
        }.store(in: &bag)
        bridge.$barGrowth.dropFirst().sink { [weak self] new in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.curGrowth = new
                self.applyPad(reason: "growth")
            }
        }.store(in: &bag)
        observeViewModel()
        reload()
        SpikeProbes.vc = self
    }

    func node(_ id: String) -> MessageNode? { nodes[id] ?? synthetic[id] }

    private func model(for node: MessageNode) -> SpikeTextModel {
        if let m = models[node.id], mode != .b { return m }
        let m = SpikeTextModel.make(role: node.role, content: node.content, userName: "你", assistantName: "助手")
        if mode == .b { return m }
        var measured = m
        measured.measure(width: layout.itemWidth)
        models[node.id] = measured
        return measured
    }

    private func observeViewModel() {
        withObservationTracking {
            _ = viewModel.currentPath
            _ = viewModel.isLoading
            _ = viewModel.selectedConversation?.id
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.reload()
                    self?.observeViewModel()
                }
            }
        }
    }

    /// 当前要显示的 id（物理顺序 = 最新在前）
    func currentIDs() -> [String] {
        let base = viewModel.currentPath.reversed().map(\.id)
        return idOverride?(base) ?? base
    }

    func reload(animated: Bool? = nil) {
        guard !viewModel.isLoading else { return }
        for n in viewModel.currentPath { nodes[n.id] = n }
        let ids = currentIDs()
        let convChanged = loadedConvId != viewModel.selectedConversation?.id
        loadedConvId = viewModel.selectedConversation?.id
        if mode == .m {
            complexIds = Set(ids.filter { id in node(id).map(UIKitChatSpike.isComplex) ?? false })
        }
        if usesPrelayout {
            let missing = ids.compactMap { id -> (String, String, String)? in
                guard !complexIds.contains(id), models[id] == nil || models[id]?.width != layout.itemWidth, let n = node(id) else { return nil }
                return (id, n.role, n.content)
            }
            if !missing.isEmpty {
                prelayoutGen += 1
                let gen = prelayoutGen
                let width = layout.itemWidth
                // 首屏优先：最新 20 条先排先上，其余排完只补高度（视口外，物理上在下面，不推 offset）
                let firstIds = Set(ids.prefix(20))
                let head = UIKitChatSpike.prelayoutFirst ? missing.filter { firstIds.contains($0.0) } : missing
                let tail = UIKitChatSpike.prelayoutFirst ? missing.filter { !firstIds.contains($0.0) } : []
                let t0 = CACurrentMediaTime()
                let build: @Sendable ([(String, String, String)]) -> [String: SpikeTextModel] = { items in
                    var built: [String: SpikeTextModel] = [:]
                    for (id, role, content) in items {
                        var m = SpikeTextModel.make(role: role, content: content, userName: "你", assistantName: "助手")
                        m.measure(width: width)
                        built[id] = m
                    }
                    return built
                }
                prelayoutQueue.async {
                    let built = build(head)
                    let t1 = CACurrentMediaTime()
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, gen == self.prelayoutGen else { return }
                            SpikeProbes.notePrelayout(count: head.count, ms: (t1 - t0) * 1000)
                            self.models.merge(built) { $1 }
                            self.apply(ids: ids, convChanged: convChanged, animated: animated)
                        }
                    }
                    guard !tail.isEmpty else { return }
                    let rest = build(tail)
                    let t2 = CACurrentMediaTime()
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, gen == self.prelayoutGen else { return }
                            SpikeProbes.notePrelayout(count: tail.count, ms: (t2 - t1) * 1000)
                            self.models.merge(rest) { $1 }
                            for (id, m) in rest where self.layout.ids.contains(id) && m.width == self.layout.itemWidth {
                                if let total = m.total { self.layout.heights[id] = total; self.layout.measured.insert(id) }
                            }
                            self.layout.invalidateLayout()
                        }
                    }
                }
                return
            }
        }
        apply(ids: ids, convChanged: convChanged, animated: animated)
    }

    private func apply(ids: [String], convChanged: Bool, animated: Bool?) {
        for id in ids {
            if let total = models[id]?.total, models[id]?.width == layout.itemWidth, usesPrelayout {
                layout.heights[id] = total
                layout.measured.insert(id)
            }
        }
        let old = dataSource.snapshot().itemIdentifiers
        var snap = NSDiffableDataSourceSnapshot<Int, String>()
        snap.appendSections([0])
        snap.appendItems(ids)
        layout.ids = ids
        let anim = animated ?? (!convChanged && ids.count == old.count + 1)
        dataSource.apply(snap, animatingDifferences: anim)
        if convChanged {
            collectionView.layoutIfNeeded()
            collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
        }
        onApplied?(ids)
    }

    func reconfigure(_ ids: [String]) {
        var snap = dataSource.snapshot()
        let present = ids.filter { snap.indexOfItem($0) != nil }
        if mode != .a { present.forEach { models[$0] = nil } }
        snap.reconfigureItems(present)
        dataSource.apply(snap, animatingDifferences: false)
    }

    func cell(for id: String) -> UICollectionViewCell? {
        guard let ip = dataSource.indexPath(for: id) else { return nil }
        return collectionView.cellForItem(at: ip)
    }

    // MARK: 键盘（KeyboardInsetBridge 唯一消费者）

    private func extraChanged(to new: CGFloat) {
        let old = curExtra
        curExtra = new
        applyPad(reason: "extra \(Int(old))→\(Int(new))")
        let bridge = KeyboardInsetBridge.shared
        // 收键盘 release：同一 runloop 里先落布局（塌垫块）再写 offset = 同帧焊住
        if new == 0, old > 0, let target = bridge.hideReleaseOffset {
            bridge.hideReleaseOffset = nil
            if !collectionView.isDragging {
                collectionView.layoutIfNeeded()
                collectionView.contentOffset.y = target
                SpikeProbes.log("hide release same-frame off→\(Int(target))")
            }
        }
        // 冷弹回底（离底但在 1 屏内）
        if old == 0, new > 0, !isAtBottom, !viewModel.inConvSearchActive {
            let cv = collectionView!
            let dist = cv.contentOffset.y + cv.adjustedContentInset.top
            let farAway = dist > cv.bounds.height * KeyboardInsetBridge.returnToBottomScreens
            SpikeProbes.log("cold-scroll dist=\(Int(dist)) farAway=\(farAway ? 1 : 0)")
            if !farAway { StreamScrollAnchor.scrollChatToBottom() }
        }
    }

    /// 垫块高变化走 layout invalidation（离屏也生效），不动 inset、不换 view
    private func applyPad(reason: String) {
        let pad = max(0, curExtra) + max(0, curGrowth)
        guard pad != layout.padHeight else { return }
        layout.padHeight = pad
        layout.invalidateLayout()
        collectionView.setNeedsLayout()
        switch UIKitChatSpike.padMode {
        case "now":
            SpikeProbes.inPadSink = true
            UIView.performWithoutAnimation { collectionView.layoutIfNeeded() }
            SpikeProbes.inPadSink = false
        case "chain":
            var v: UIView? = collectionView.superview
            while let cur = v { cur.setNeedsLayout(); v = cur.superview }
        default:
            break
        }
        SpikeProbes.notePad(pad, reason: reason)
    }

    @objc private func tapList() {
        guard KeyboardInsetBridge.shared.extra > 0 else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func maybeLiftPadSuppression() {
        let b = KeyboardInsetBridge.shared
        guard b.padSuppressed, b.kbVisible, let cv = collectionView, !cv.isTracking, !cv.isDragging else { return }
        let dist = cv.contentOffset.y + cv.adjustedContentInset.top
        guard dist < cv.bounds.height * KeyboardInsetBridge.returnToBottomScreens else { return }
        b.liftPadSuppression?()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { maybeLiftPadSuppression() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { maybeLiftPadSuppression() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { maybeLiftPadSuppression() }
}
#endif
