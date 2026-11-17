#if DEBUG && os(iOS)
import SwiftUI
import UIKit
import Combine
import SwiftStreamingMarkdown
import TranscriptCore
import TranscriptUIKit

// 重构 R2（docs/plan-重构.md §3.4）：新对话页接进 app 的地方。
// 这个文件是过渡期唯一同时认识两边的代码：旧的中心对象 / SwiftData 模型 ←→ TranscriptKit 的行。
// TranscriptKit 自己不认识这里的任何类型。验收前只在 Debug 构建里存在。

/// 聊天页用哪套引擎。冷启动读一次（测试可以按次覆盖）
enum ChatPageEngine: String, CaseIterable {
    case swiftui, uikit

    static let defaultsKey = "chatPageEngine"
    private static let stored = ChatPageEngine(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .swiftui
    /// 像素对拍用：同一个进程里先后挂旧页和新页
    nonisolated(unsafe) static var override: ChatPageEngine?

    static var active: ChatPageEngine { override ?? stored }
}

/// `ContentView.iOSChatPage` 里顶替 `CardFlowView` 的那一个视图：列表 + 套在列表外面的页面级装饰。
/// 装饰照旧页的修饰链原样、原顺序套（CardFlowView :1151 / :1162）：伸到安全区外 → 成组 → 上下边缘渐隐蒙版。
struct TranscriptChatPage: View {
    let viewModel: ConversationViewModel
    @ObservedObject private var keyboardBridge = KeyboardInsetBridge.shared

    var body: some View {
        TranscriptList(viewModel: viewModel)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .compositingGroup()
            .mask {
                ChatEdgeFadeMask(
                    enabled: !viewModel.currentPath.isEmpty,
                    inputFieldTop: keyboardBridge.inputFieldTop,
                    inputBarBottom: keyboardBridge.containerTop + keyboardBridge.barVisibleHeight,
                    keyboardVisible: keyboardBridge.kbVisible,
                    hasInputGeometry: keyboardBridge.containerTop > 0
                )
            }
    }
}

private struct TranscriptList: UIViewControllerRepresentable {
    let viewModel: ConversationViewModel
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    func makeCoordinator() -> ChatPageAdapter { ChatPageAdapter(viewModel: viewModel) }

    func makeUIViewController(context: Context) -> TranscriptViewController {
        let controller = TranscriptViewController()
        // 旧页：contentMargins 起点 100 / 终点 150（CardFlowView :1156 / :1159），再加列表自己的竖向留白 16
        controller.setInsets(start: 100 + 16, end: 150 + 16)
        context.coordinator.attach(controller, profileManager: profileManager, presetManager: presetManager)
        return controller
    }

    func updateUIViewController(_ controller: TranscriptViewController, context: Context) {
        context.coordinator.managersChanged(profileManager: profileManager, presetManager: presetManager)
    }
}

/// 观察旧的中心对象，把当前分支上的消息投影成行交给列表。它自己盯变化，不靠 SwiftUI 的重算
@MainActor
final class ChatPageAdapter {
    private let viewModel: ConversationViewModel
    private weak var controller: TranscriptViewController?
    private var profileManager: ProfileManager?
    private var presetManager: PresetManager?
    private var generation = 0
    private var subscriptions = Set<AnyCancellable>()
    /// 最近一次键盘通知带的时长和曲线（收键盘的通知不带时长，所以存着）
    private var keyboardMotion = TranscriptEngine.KeyboardMotion(duration: 0.25, curve: 7)
    private var keyboardExtra: CGFloat?
    private var barGrowth: CGFloat = 0
    /// 消息滑到顶栏 / 输入条底下时的渐进模糊：就是旧页那一个（它自己找到列表外面的容器挂滤镜）
    private let edgeBlur = ChatContentEdgeBlur.AttachmentView()
    private var inputBarTop: CGFloat = 0
    private var keyboardVisible = false
    private var hasRows = false
    private let projector = TranscriptProjector()
    /// 现在交给列表的行（流式每拍只换其中一条消息的那一段）
    private var rows: [TranscriptRow] = []
    /// 正在流式的那条消息；它的字来自流式缓冲，经节拍器匀速放出来（同旧页）
    private var streamNode: MessageNode?
    private var streamIsNewest = false
    private var streamThinking: String?
    private var streamToken = 0
    private var streamTicks = 0
    private let pacer = StreamPacer()

    /// 像素对拍失败时打出来看的：最近挂上的那一页，列表和引擎各自的状态
    private static let live = NSHashTable<ChatPageAdapter>.weakObjects()
    /// 所有还活着的适配层的状态（SwiftUI 一次挂载会建好几个，只有一个留在屏上）
    static var debugStates: String {
        let states = live.allObjects.map(\.debugState)
        return states.isEmpty ? "新页没挂上" : states.joined(separator: "\n  ")
    }
    /// 测试用：把屏上那一页滚到「这条消息的底边贴着输入条上沿」，返回离最新消息多远。走引擎的事务，和用户滚过去等价
    static func debugScroll(toMessage nodeID: String) -> CGFloat? {
        guard let controller = live.allObjects.compactMap(\.controller).first(where: { $0.view.window != nil }),
              let last = controller.engine.layout.rows.first(where: { $0.id.hasPrefix("\(nodeID)#") }) else { return nil }
        controller.submit(.scrollToRow(id: last.id, alignment: .start, animated: false))
        return controller.engine.distanceFromStart
    }

    private var refreshes = 0
    /// 测试看：屏上那一页流式了几拍、复用 / 重排了多少块
    static var debugStream: (ticks: Int, reusedBlocks: Int, laidOutBlocks: Int, shown: String, rowIDs: [String])? {
        onScreen.map { ($0.streamTicks, $0.projector.reusedBlocks, $0.projector.laidOutBlocks, $0.pacer.shown, $0.rows.map(\.id)) }
    }
    /// 测试用：屏上那一页背后的中心对象（对拍台挂的是真实 ContentView，外面拿不到它）
    static var debugViewModel: ConversationViewModel? { onScreen?.viewModel }
    private static var onScreen: ChatPageAdapter? { live.allObjects.first(where: { $0.controller?.view.window != nil }) }
    var debugState: String {
        guard let controller else { return "列表已经没了" }
        let scroll = controller.scrollView
        let engine = controller.engine
        let cells = (scroll as? UICollectionView)?.visibleCells.count ?? -1
        return "投影 \(refreshes) 次，消息 \(viewModel.currentPath.count) 条，行 \(engine.layout.rows.count)，宽 \(engine.layout.width)，"
            + "列表 \(scroll.frame) 在窗口里 \(scroll.window != nil)，内容高 \(scroll.contentSize.height)（引擎 \(engine.layout.contentLength)），"
            + "位置 \(scroll.contentOffset.y)（引擎 \(engine.offset)），内缩 \(scroll.contentInset)，垫块 \(engine.layout.leadingPad)，屏上 cell \(cells) 个"
    }

    init(viewModel: ConversationViewModel) {
        self.viewModel = viewModel
        Self.live.add(self)
    }

    func attach(_ controller: TranscriptViewController, profileManager: ProfileManager?, presetManager: PresetManager?) {
        self.controller = controller
        self.profileManager = profileManager
        self.presetManager = presetManager
        controller.onLayoutWidthChange = { [weak self] in self?.refresh() }
        edgeBlur.isUserInteractionEnabled = false
        controller.scrollView.addSubview(edgeBlur)
        refresh()
        observeKeyboard()
    }

    /// 键盘高度还是只有旧的那一个出处（PagingViewController → KeyboardInsetBridge.extra）。
    /// 这里只把「垫块变成多少、为什么变」交给引擎；滑不滑、滑到哪、垫块什么时候塌，都是引擎的事。
    /// 旧页那几段直接写滚动位置的代码找的是旧列表的 scroll view，新页挂着时它是 nil，自然不执行。
    private func observeKeyboard() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .sink { [weak self] note in
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval)
                    .flatMap { $0 > 0 ? $0 : nil } ?? 0.25
                let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
                self?.keyboardMotion = .init(duration: duration, curve: curve)
            }
            .store(in: &subscriptions)
        // 垫块 = 键盘高 + 输入条比单行多出来的高（附件条、引用条、多行），同旧页（CardFlowView :1030）
        KeyboardInsetBridge.shared.$barGrowth
            .removeDuplicates()
            .sink { [weak self] growth in self?.barGrowthChanged(to: growth) }
            .store(in: &subscriptions)
        KeyboardInsetBridge.shared.$extra
            .removeDuplicates()
            .sink { [weak self] extra in self?.keyboardExtraChanged(to: extra) }
            .store(in: &subscriptions)
        KeyboardInsetBridge.shared.$containerTop
            .removeDuplicates()
            .sink { [weak self] top in
                self?.inputBarTop = top
                self?.updateEdgeBlur()
            }
            .store(in: &subscriptions)
        KeyboardInsetBridge.shared.$kbVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.keyboardVisible = visible
                self?.updateEdgeBlur()
            }
            .store(in: &subscriptions)
    }

    /// 参数同旧页（CardFlowView :1122）
    private func updateEdgeBlur() {
        edgeBlur.radius = CGFloat(UserDefaults.standard.object(forKey: "blurRadius") as? Double ?? 1.3)
        edgeBlur.inputBarBottom = inputBarTop + KeyboardInsetBridge.shared.barVisibleHeight
        edgeBlur.keyboardVisible = keyboardVisible
        edgeBlur.enabled = hasRows
        edgeBlur.topFadeEnd = 130
        edgeBlur.attach()
    }

    private func keyboardExtraChanged(to extra: CGFloat) {
        let reason: TranscriptEngine.PadReason
        if keyboardExtra == nil {
            reason = .layout                      // 挂上来时键盘已经在：不是一次起落
        } else if extra < 0.5, KeyboardInsetBridge.shared.lastHideWasSendDismiss {
            reason = .sendDismiss
        } else {
            reason = .keyboard(keyboardMotion)
        }
        keyboardExtra = extra
        controller?.submit(.setLeadingPad(max(0, extra) + barGrowth, reason: reason))
    }

    /// 输入条自己长高：瞬变，不滑（旧页同）
    private func barGrowthChanged(to growth: CGFloat) {
        barGrowth = max(0, growth)
        updateEdgeBlur()
        guard let keyboardExtra else { return }
        controller?.submit(.setLeadingPad(max(0, keyboardExtra) + barGrowth, reason: .layout))
    }

    func managersChanged(profileManager: ProfileManager?, presetManager: PresetManager?) {
        guard profileManager !== self.profileManager || presetManager !== self.presetManager else { return }
        self.profileManager = profileManager
        self.presetManager = presetManager
        refresh()
    }

    private func refresh() {
        guard let controller else { return }
        generation += 1
        refreshes += 1
        let current = generation
        let width = controller.engine.layout.width
        // 放字节拍器的值在观察范围外读：它 30Hz 地变，只该让流式那一条重排（streamTick），不该让整条对话重投影
        let live = streamNode == nil ? nil : TranscriptProjector.Live(body: pacer.shown, thinking: streamThinking)
        let output = withObservationTracking {
            width > 0 ? projector.rows(viewModel: viewModel, profile: profileManager?.currentProfile,
                                       preset: profileManager.flatMap { presetManager?.preset(byId: $0.currentProfile.presetId) },
                                       cards: profileManager?.characterCardManager?.cards ?? [], width: width,
                                       displayScale: controller.traitCollection.displayScale, live: live)
                : TranscriptProjector.Output()
        } onChange: { [weak self] in
            // 被观察的东西变了（换分支、来新消息、正文改了、一轮开始 / 结束）：下一轮主线程重投影
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.refresh()
            }
        }
        rows = output.rows
        controller.setRows(rows, measured: output.streamHeights, streaming: true)
        hasRows = !rows.isEmpty
        updateEdgeBlur()
        streamChanged(to: output.streamNode, isNewest: output.streamIsNewest)
    }

    // MARK: 流式

    /// 正在流式的那条消息换了（开始 / 结束 / 换了一条）
    private func streamChanged(to node: MessageNode?, isNewest: Bool) {
        streamIsNewest = isNewest
        guard node?.id != streamNode?.id else { return }
        streamNode = node
        streamToken += 1
        pacer.end()
        controller?.submit(.setStreaming(node != nil))
        guard node != nil else { return }
        // 挂上来时流已经在进行：已有的字直接铺满，只对后面来的匀速放
        let shown = projector.streamingDisplay(viewModel.streamingText)
        streamThinking = shown.thinking
        pacer.seed(shown.body)
        streamTick()
        observeStreamText()
        observePacer()
    }

    /// 流式缓冲每来一坨：加工成显示用的正文交给节拍器。只有这里读 `streamingText`
    private func observeStreamText() {
        guard streamNode != nil else { return }
        let token = streamToken
        let raw = withObservationTracking { viewModel.streamingText } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.streamToken == token else { return }
                self.observeStreamText()
            }
        }
        let shown = projector.streamingDisplay(raw)
        let thinkingChanged = shown.thinking != streamThinking
        streamThinking = shown.thinking
        pacer.push(shown.body)
        if thinkingChanged { streamTick() }
    }

    /// 节拍器每放出一点字：只重排流式那一条
    private func observePacer() {
        guard streamNode != nil else { return }
        let token = streamToken
        withObservationTracking { _ = pacer.shown } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.streamToken == token else { return }
                self.streamTick()
                self.observePacer()
            }
        }
    }

    private func streamTick() {
        guard let controller, let node = streamNode else { return }
        let next = projector.streamRows(node, live: .init(body: pacer.shown, thinking: streamThinking), isNewest: streamIsNewest)
        // 这条消息的行在列表里是连着的一段（最新的在前，通常就在最前面）：整段换掉
        let prefix = "\(node.id)#"
        guard let start = rows.firstIndex(where: { $0.id.hasPrefix(prefix) }) else { return }
        var end = start
        while end < rows.count, rows[end].id.hasPrefix(prefix) { end += 1 }
        rows.replaceSubrange(start..<end, with: next.rows)
        streamTicks += 1
        controller.setRows(rows, measured: next.heights, streaming: true)
    }
}

/// 「消息 → 行」（文章模式；气泡模式后补）。顺序：最新的在前。「什么情况画什么」全从 `MessageDisplay` 取，这里只管排成行。
/// 每条消息排好的行按「内容 + 设置」存着：对话里别的消息没变就不重排；流式那条按块复用，只重排变了的块
@MainActor
final class TranscriptProjector {
    /// 流式那条现在该显示的字（节拍器放出来的）和思考
    struct Live {
        var body: String
        var thinking: String?
    }

    struct Output {
        var rows: [TranscriptRow] = []
        /// 正在流式、而且正文走流式缓冲的那条消息
        var streamNode: MessageNode?
        var streamIsNewest = false
        /// 流式那条各行的高度（主线程量好的，和行集同一轮交给引擎）
        var streamHeights: [TranscriptEngine.HeightReport] = []
    }

    /// 一条消息从上到下的一部分；gapBelow = 它和下面那部分之间的空
    private struct Part {
        let id: String
        let version: Int
        let renderer: any TranscriptRowRenderer
        var gapBelow: CGFloat
    }

    /// 排版依赖的全部设置：变了就整份缓存作废
    private struct Style: Hashable {
        var fontName = ""
        var scale: CGFloat = 1.2
        var cornerRadius: CGFloat = 16
        var paddingH: CGFloat = 18
        var paddingV: CGFloat = 15
        var messageSpacing: CGFloat = 31
        var userName = ""
        var assistantName = ""
        var showCCThinking = true
        var scripts: [RegexScript] = []
        var width: CGFloat = 0
        var displayScale: CGFloat = 0
    }

    private var style = Style()
    private var cache: [String: (key: Int, parts: [Part])] = [:]
    /// 流式那条上一拍的块和排好的样子
    private var stream: (nodeID: String, blocks: [MarkdownBlock], layouts: [MarkdownBlockLayout?], versions: [Int])?
    private var blockSerial = 0
    private let parser = MarkdownParserImpl()
    /// 测试看：流式期间复用了多少块、重排了多少块
    private(set) var reusedBlocks = 0
    private(set) var laidOutBlocks = 0

    private var context: MessageDisplay.Context {
        .init(scripts: style.scripts, userName: style.userName, charName: style.assistantName,
              showCCThinking: style.showCCThinking)
    }

    func rows(viewModel: ConversationViewModel, profile: Profile?, preset: Preset?, cards: [CharacterCard],
              width: CGFloat, displayScale: CGFloat, live: Live?) -> Output {
        let defaults = UserDefaults.standard
        let storedScale = defaults.object(forKey: "fontScale") as? Double ?? 1.2
        let next = Style(
            fontName: defaults.string(forKey: "selectedFont") ?? "",
            scale: CGFloat(storedScale > 0 ? storedScale : 1.2),
            cornerRadius: CGFloat(defaults.object(forKey: "bubbleCornerRadius") as? Double ?? 16),
            paddingH: CGFloat(defaults.object(forKey: "bubblePaddingH") as? Double ?? 18),
            paddingV: CGFloat(defaults.object(forKey: "bubblePaddingV") as? Double ?? 15),
            messageSpacing: CGFloat(defaults.object(forKey: "bubbleSpacing") as? Double ?? 31),
            userName: viewModel.personaDisplayName(profile: profile) ?? defaults.string(forKey: "userName") ?? "你",
            assistantName: defaults.string(forKey: "assistantName") ?? "助手",
            showCCThinking: defaults.object(forKey: "ccShowThinking") as? Bool ?? true,
            scripts: profile.map { RegexPipeline.scripts(profile: $0, preset: preset, cards: cards) } ?? [],
            width: width, displayScale: displayScale)
        if next != style {
            style = next
            cache.removeAll()
            stream = nil
        }
        let conversationId = viewModel.selectedConversation?.id ?? ""

        var output = Output()
        var seen = Set<String>()
        var isNewest = true
        // 和旧页一样：路径上每个节点都有一行（含系统消息）
        for node in viewModel.currentPath.reversed() {
            seen.insert(node.id)
            let isStreaming = node.role == "assistant" && viewModel.isNodeStreaming(nodeId: node.id, conversationId: conversationId)
            var parts: [Part]
            if isStreaming {
                // 流式那条不进缓存：它的字不在消息里
                let made = messageParts(node, isStreaming: true, live: live)
                parts = made.parts
                if made.streams {
                    output.streamNode = node
                    output.streamIsNewest = isNewest
                }
            } else {
                var hasher = Hasher()
                hasher.combine(node.content)
                hasher.combine(node.segmentsData)
                hasher.combine(node.contentType)
                hasher.combine(node.replyOutcome)
                hasher.combine(node.ccThinking)
                hasher.combine(node.usesLegacyErrorMarker)
                let key = hasher.finalize()
                if let hit = cache[node.id], hit.key == key {
                    parts = hit.parts
                } else {
                    parts = messageParts(node, isStreaming: false, live: nil).parts
                    cache[node.id] = (key, parts)
                }
            }
            guard !parts.isEmpty else { continue }
            let rows = self.rows(node.id, parts, isNewest: isNewest, collapsedUntilMeasured: output.streamNode === node)
            if output.streamNode === node { output.streamHeights = heights(of: rows, parts) }
            output.rows.append(contentsOf: rows)
            isNewest = false
        }
        cache = cache.filter { seen.contains($0.key) }
        if let id = stream?.nodeID, output.streamNode?.id != id { stream = nil }
        return output
    }

    /// 流式那一条重排一遍（节拍器每拍调）
    func streamRows(_ node: MessageNode, live: Live, isNewest: Bool) -> (rows: [TranscriptRow], heights: [TranscriptEngine.HeightReport]) {
        let parts = messageParts(node, isStreaming: true, live: live).parts
        let rows = self.rows(node.id, parts, isNewest: isNewest, collapsedUntilMeasured: true)
        return (rows, heights(of: rows, parts))
    }

    /// 流式缓冲 → 显示用的正文和思考（清洗、剥思考标签、显示正则；同旧页流式的口径）
    func streamingDisplay(_ raw: String) -> MessageDisplayText.Result {
        MessageDisplayText.streaming(raw, scripts: style.scripts, userName: style.userName, charName: style.assistantName)
    }

    // MARK: 一条消息

    /// 行是「最新的在前」：一条消息里最下面的那一行排最前，它和更新的那条消息之间隔 messageSpacing。
    /// `collapsedUntilMeasured`（流式那条）：新出现的行先按 0 高进列表，真高度紧跟着报——这样长出来的部分由引擎滑上来，而不是一下跳出来
    private func rows(_ nodeID: String, _ parts: [Part], isNewest: Bool, collapsedUntilMeasured: Bool) -> [TranscriptRow] {
        var parts = parts
        parts[parts.count - 1].gapBelow = isNewest ? 0 : style.messageSpacing
        return parts.reversed().map { part in
            TranscriptRow(id: "\(nodeID)#\(part.id)", version: part.version, gapBefore: part.gapBelow,
                          estimatedHeight: collapsedUntilMeasured ? 0 : part.renderer.height(width: style.width),
                          renderer: part.renderer)
        }
    }

    private func heights(of rows: [TranscriptRow], _ parts: [Part]) -> [TranscriptEngine.HeightReport] {
        zip(rows, parts.reversed()).map { row, part in
            TranscriptEngine.HeightReport(id: row.id, version: row.version,
                                          height: part.renderer.height(width: style.width), tier: .prepared)
        }
    }

    /// `streams` = 这条的正文走流式缓冲
    private func messageParts(_ node: MessageNode, isStreaming: Bool, live: Live?) -> (parts: [Part], streams: Bool) {
        let width = style.width
        let isUser = node.role == "user"
        let frame = MessageDisplay.frame(of: node, isStreaming: isStreaming)
        var parts: [Part] = []
        var streams = false
        func pending(_ id: String, _ label: String) {
            parts.append(Part(id: id, version: "\(label)|\(width)".hashValue, renderer: ArticlePendingBlockRow(label: label),
                              gapBelow: ArticleMetrics.partSpacing))
        }

        if let system = frame.system {
            pending("system", "系统提示（新页还没画）：\(system.text.prefix(40))")
            return (parts, false)
        }
        if frame.hasBody {
            let body = MessageDisplay.articleBody(of: node, isStreaming: isStreaming, streamsLive: isStreaming, context: context)
            let shownName = isUser ? style.userName : style.assistantName
            parts.append(Part(id: "name", version: "\(shownName)|\(width)".hashValue,
                              renderer: ArticleNameRow(name: shownName, isUser: isUser, color: UIColor(Theme.chat.textMuted),
                                                       displayScale: style.displayScale),
                              gapBelow: ArticleMetrics.partSpacing))
            switch body {
            case .markdown(let shown, let thinking):
                if thinking != nil { pending("thinking", "思考过程（新页还没画）") }
                parts.append(contentsOf: blockParts(shown, node: node, isUser: isUser, incremental: false))
            case .streaming:
                streams = true
                let thinking = live?.thinking ?? (style.showCCThinking ? node.ccThinking : nil)
                if let thinking, !thinking.isEmpty { pending("thinking", "思考过程（新页还没画）") }
                let shown = live?.body ?? ""
                if shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pending("typing", "…")
                } else {
                    parts.append(contentsOf: blockParts(shown, node: node, isUser: false, incremental: true))
                }
            case .segments: pending("body", "分段消息（工具 / 思考 / 图片，新页还没画）")
            case .userVoiceNote: pending("body", "语音条（新页还没画）")
            case .heartvoice: pending("body", "心声（新页还没画）")
            case .meme: pending("body", "表情包（新页还没画）")
            case .empty: break
            }
        }
        switch frame.tail {
        case .error(let text)?: pending("tail", "报错（新页还没画）：\(text.prefix(40))")
        case .notice(let text)?: pending("tail", "提示（新页还没画）：\(text.prefix(40))")
        case .outcome?: pending("tail", "回复异常结束（新页还没画）")
        case nil: break
        }
        return (parts, streams)
    }

    /// 正文 → 每个块一行。`incremental`（流式）：和上一拍逐块比，内容没变的块连排好的样子一起复用
    private func blockParts(_ shown: String, node: MessageNode, isUser: Bool, incremental: Bool) -> [Part] {
        let palette = Theme.chat
        let role: ChatTextRole = isUser ? .user : .assistant
        let config = MarkdownRenderConfig.memoryPalace(fontName: style.fontName, scale: style.scale, animated: false,
                                                       textColor: role.color, palette: palette,
                                                       blockQuoteColor: Theme.chatBlockQuoteColor(for: role))
        var text = MessageHTMLSegments.markdownPromotingHTML(shown)
        #if PERSONAL_APPS
        if !incremental { text = TickerLinkifier.linkifyCached(text, cacheKey: node.id) }
        #endif
        let blocks = parser.parseSync(text: text, config: config).blocks
        let available = style.width - ArticleMetrics.listInsetH * 2
        let maxBubble = isUser ? min(available, ArticleMetrics.userBubbleMaxWidth) : available
        // 卡片注册表认领的代码块（html / mermaid / card-*）还没有原生实现，这里先不排，画占位行
        func layout(_ block: MarkdownBlock) -> MarkdownBlockLayout? {
            block.layout(width: maxBubble - style.paddingH * 2, config: config, displayScale: style.displayScale) { language, code in
                ChatCardRegistry.kind(language: language, code: code, streaming: incremental) != nil
            }
        }

        var layouts: [MarkdownBlockLayout?] = []
        var versions: [Int] = []
        if incremental {
            let previous = stream?.nodeID == node.id ? stream : nil
            for (index, block) in blocks.enumerated() {
                if let previous, index < previous.blocks.count, previous.blocks[index] == block {
                    layouts.append(previous.layouts[index])
                    versions.append(previous.versions[index])
                    reusedBlocks += 1
                } else {
                    blockSerial += 1
                    layouts.append(layout(block))
                    versions.append(blockSerial)
                    laidOutBlocks += 1
                }
            }
            stream = (node.id, blocks, layouts, versions)
        } else {
            layouts = blocks.map(layout)
            // 内容每变一次行的版本就得变：拿正文的摘要当版本（宽度和排版参数变了整份缓存作废，不用进版本）
            versions = Array(repeating: text.hashValue, count: blocks.count)
        }

        let bubbleWidth = (layouts.compactMap { $0?.size.width }.max() ?? 0) + style.paddingH * 2
        let fill = UIColor(isUser ? palette.userBubble : palette.assistantBubble)
        return blocks.indices.map { index in
            let isFirst = index == 0
            let isLast = index == blocks.count - 1
            var hasher = Hasher()
            hasher.combine(versions[index])
            hasher.combine(bubbleWidth)
            hasher.combine(isFirst)
            hasher.combine(isLast)
            let renderer: any TranscriptRowRenderer
            if let layout = layouts[index] {
                renderer = ArticleBlockRow(layout: layout, config: config, bubbleWidth: bubbleWidth,
                                           isUser: isUser, isFirst: isFirst, isLast: isLast, fill: fill,
                                           cornerRadius: style.cornerRadius, paddingH: style.paddingH, paddingV: style.paddingV)
            } else {
                renderer = ArticlePendingBlockRow(label: "还没有原生实现的块")
            }
            return Part(id: "\(index)", version: hasher.finalize(), renderer: renderer, gapBelow: 0)
        }
    }
}
#endif
