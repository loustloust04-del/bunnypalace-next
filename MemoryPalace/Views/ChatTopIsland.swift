import SwiftData
import SwiftUI
import SwiftStreamingMarkdown

/// 顶栏状态岛什么时候收起（粟粟 09-28 稿；真机反馈「不灵敏、有时反着来」后改）：只看这一次手指拖动——
/// 往下读（手指往上）满 24pt → 收；往回翻（手指往下）满 24pt → 展；中途反向从拐点重新量。
/// 不看列表位置（流式补偿、惯性、回弹、键盘都不算），也没有「靠近最新消息强制展开」。
enum TopBarCollapse {
    struct Pan {
        static let threshold: CGFloat = 24
        private(set) var collapsed: Bool
        /// 当前方向上走到的最远点（拐点）
        private var anchor: CGFloat = 0

        init(collapsed: Bool = false) { self.collapsed = collapsed }

        mutating func began() { anchor = 0 }

        /// fingerUp：这次拖动里手指在屏幕上往上走了多少（往上 = 往下读新消息）
        mutating func changed(fingerUp t: CGFloat) {
            if collapsed {
                if t > anchor { anchor = t } else if anchor - t >= Self.threshold { collapsed = false; anchor = t }
            } else {
                if t < anchor { anchor = t } else if t - anchor >= Self.threshold { collapsed = true; anchor = t }
            }
        }

        mutating func expand() {
            collapsed = false
            anchor = 0
        }
    }
}

/// 收 / 展状态只给岛自己读：放在 ContentView 的 @State 里会让收起那一帧整页（翻页容器 + 整个聊天列表）陪着重算（#027）
@Observable
final class TopBarCollapseState {
    var collapsed = false
}

/// 顶栏排版：左右两侧占同样宽，中间的岛按屏幕真居中（粟粟：「没有完全居中」）
enum ChatTopBarLayout {
    static let backButton: CGFloat = 44
    static let rightCluster: CGFloat = 88          // ⋯ + ›
    static func sideWidth(left: CGFloat, right: CGFloat) -> CGFloat { max(left, right) }
    static var side: CGFloat { sideWidth(left: backButton, right: rightCluster) }
}

/// 置顶条照 Telegram（ChatPinnedMessageTitlePanelNode / AnimatedNavigationStripeNode，粟粟 09-28「去看 tg 源代码」）：
/// 置顶按聊天先后排（0 = 最旧），默认显示最新；点一下跳到这条、换成更旧的一条，最旧再点回到最新。
enum PinCycle {
    static let stripeHeight: CGFloat = 36
    static let gap: CGFloat = 2
    static let minSegment: CGFloat = 8

    static func defaultIndex(count: Int) -> Int { max(0, count - 1) }

    static func clamp(index: Int?, count: Int) -> Int {
        guard let index, index >= 0, index < count else { return defaultIndex(count: count) }
        return index
    }

    static func afterTap(index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return index == 0 ? count - 1 : index - 1
    }

    static func title(index: Int, count: Int) -> String {
        if count == 2, index == 0 { return "上一条置顶" }
        if count >= 3, index != count - 1 { return "置顶消息 #\(index + 1)" }
        return "置顶消息"
    }

    static func segmentHeight(count: Int) -> CGFloat {
        let n = CGFloat(max(count, 1))
        return max((stripeHeight - gap * (n - 1)) / n, minSegment)
    }

    /// 段多了放不下时整列上移，让当前段居中（两端贴边）
    static func stripeOffset(index: Int, count: Int) -> CGFloat {
        let h = segmentHeight(count: count)
        let total = CGFloat(count) * h + CGFloat(max(count - 1, 0)) * gap
        guard total > stripeHeight + 0.5 else { return 0 }
        let center = CGFloat(index) * (h + gap) + h / 2
        return min(0, max(stripeHeight - total, stripeHeight / 2 - center))
    }
}

/// 置顶条左侧的分段竖条：当前段实心，其余半透明；多了整列滚动、上下淡出
struct PinStripe: View {
    let index: Int
    let count: Int
    let color: Color

    var body: some View {
        let h = PinCycle.segmentHeight(count: count)
        VStack(spacing: PinCycle.gap) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(color.opacity(i == index ? 1 : 0.5)).frame(width: 2, height: h)
            }
        }
        .offset(y: PinCycle.stripeOffset(index: index, count: count))
        .frame(width: 2, height: PinCycle.stripeHeight, alignment: .top)
        .clipped()
        .mask {
            if count > 4 {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                       .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Rectangle()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: index)
        .accessibilityHidden(true)
    }
}

/// 顶栏中间的玻璃「岛」：置顶消息 + 正在放的音乐合在一块玻璃里（两样都没有就不出现）。
/// 展开：图钉 + 置顶文字 ｜ 黑胶 + 歌名 + 暂停；收起：小药丸（图钉 + 跳动的均衡器 + 黑胶），点一下展开。
struct ChatTopIsland: View {
    enum Content: Equatable {
        case pin, music, both
        init?(hasPin: Bool, hasMusic: Bool) {
            switch (hasPin, hasMusic) {
            case (true, true): self = .both
            case (true, false): self = .pin
            case (false, true): self = .music
            case (false, false): return nil
            }
        }
        var hasPin: Bool { self != .music }
        var hasMusic: Bool { self != .pin }
        var fillsExpandedWidth: Bool { self != .music }
        var collapsedWidth: CGFloat {
            switch self {
            case .pin: 44
            case .music: 68
            case .both: 104
            }
        }
    }

    let content: Content
    /// 聊天先后（0 = 最旧）
    let pinnedNodes: [MessageNode]
    let pinIndex: Int
    /// 换条方向：切到更新的一条 = 文字往上走（Telegram slideToTop），更旧的 = 从上面落下
    let pinSlideUp: Bool
    let collapseState: TopBarCollapseState
    let viewModel: ConversationViewModel
    let onPinTap: () -> Void
    let onExpand: () -> Void
    /// 长按：弹出置顶消息 + 音乐卡预览（学 Telegram）
    let onLongPress: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var collapsed: Bool { collapseState.collapsed }
    private var player: MusicCardPlayer { .shared }
    private var musicPlaying: Bool { player.currentKey.map { [.playing, .loading].contains(player.phase(for: $0)) } ?? false }
    private var morph: Animation { ChatCardMotion.animation(ChatCardMotion.morph, reduceMotion: reduceMotion) }
    private static let mint = Color(red: 0.561, green: 0.702, blue: 0.604)
    private static let mintDeep = Color(red: 0.435, green: 0.604, blue: 0.482)

    var body: some View {
        HStack(spacing: 8) {
            if content.hasPin { pinSegment }
            if content == .both, !collapsed {
                Rectangle().fill(Color.primary.opacity(0.08))
                    .frame(width: 1, height: 20)
            }
            if content.hasMusic, collapsed { EqualizerBars(playing: musicPlaying && !reduceMotion) }
            if content.hasMusic { musicSegment }
        }
        .allowsHitTesting(!collapsed)
        .accessibilityHidden(collapsed)
        .padding(.leading, collapsed ? 0 : (content == .music ? 6 : 13))
        .padding(.trailing, collapsed ? 0 : (content == .pin ? 13 : 6))
        .frame(height: collapsed ? 34 : 48)
        .frame(width: collapsed ? content.collapsedWidth : nil)
        .frame(maxWidth: !collapsed && content.fillsExpandedWidth ? .infinity : nil,
               alignment: collapsed || content == .music ? .center : .leading)
        .modifier(IslandGlass(cornerRadius: collapsed ? 17 : 24))
        .frame(minHeight: 44)
        .overlay {
            if collapsed {                                                  // 收起时整颗药丸只管「展开」
                Button(action: onExpand) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开顶栏")
            }
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            onLongPress()
        })
        .frame(maxWidth: .infinity)
        .animation(morph, value: collapsed)
        .animation(morph, value: content)
    }

    // MARK: 置顶

    private var pinSegment: some View {
        let idx = PinCycle.clamp(index: pinIndex, count: pinnedNodes.count)
        return Group {
            if collapsed {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Self.mintDeep)
                    .frame(height: 24)
            } else if pinnedNodes.indices.contains(idx) {
                let node = pinnedNodes[idx]
                HStack(spacing: 9) {
                    PinStripe(index: idx, count: pinnedNodes.count, color: Self.mintDeep)
                    ZStack(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(PinCycle.title(index: idx, count: pinnedNodes.count))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Self.mintDeep)
                            Text(Self.preview(node))
                                .font(.system(size: 14))
                                .lineLimit(1)
                        }
                        .id(node.id)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .offset(y: pinSlideUp ? 10 : -10).combined(with: .opacity),
                            removal: .offset(y: pinSlideUp ? -10 : 10).combined(with: .opacity)))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                }
                .frame(height: 44)
            }
        }
        .frame(maxWidth: collapsed ? nil : .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPinTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pinnedNodes.indices.contains(idx)
            ? "\(PinCycle.title(index: idx, count: pinnedNodes.count))：\(Self.preview(pinnedNodes[idx]))，点按跳过去"
            : "置顶消息")
    }

    private static func preview(_ node: MessageNode) -> String {
        String(ContentCleaner.clean(node.content, cacheKey: node.id).prefix(60))
    }

    // MARK: 音乐

    @ViewBuilder
    private var musicSegment: some View {
        if let origin = player.origin {
            HStack(spacing: collapsed ? 0 : 8) {
                VinylCover(spinning: musicPlaying && !reduceMotion)
                    .frame(width: collapsed ? 24 : 28, height: collapsed ? 24 : 28)
                    .clipShape(Circle())
                if !collapsed {
                    Text(origin.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { goBackOrToggle(origin) }
            .padding(.leading, collapsed ? 0 : 4)
            .modifier(MusicControl(show: !collapsed, playing: musicPlaying, reduceMotion: reduceMotion) {
                player.togglePauseCurrent()
            })
            .frame(height: collapsed ? 24 : 36)
            .accessibilityLabel("正在播放：\(origin.title)")
        }
    }

    /// 点黑胶 / 歌名：在别的对话里 → 回到那首歌的对话；就在这个对话 → 暂停 / 继续
    private func goBackOrToggle(_ origin: MusicOrigin) {
        guard origin.conversationId != viewModel.selectedConversation?.id else {
            player.togglePauseCurrent()
            return
        }
        let id = origin.conversationId
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let conversation = try? modelContext.fetch(descriptor).first else { return }
        viewModel.loadConversation(conversation, context: modelContext,
                                   scrollTargetNodeId: origin.nodeId.isEmpty ? nil : origin.nodeId)
    }
}

/// 音乐胶囊右端的暂停 / 继续（展开时才有）
private struct MusicControl: ViewModifier {
    let show: Bool
    let playing: Bool
    let reduceMotion: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            if show {
                PlayPauseShape(morph: playing ? 1 : 0)
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 12, height: 12)
                    .animation(ChatCardMotion.animation(ChatCardMotion.snappy, reduceMotion: reduceMotion), value: playing)
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: action)
                    .accessibilityLabel(playing ? "暂停" : "继续播放")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
            }
        }
        .background {
            if show { Capsule().fill(Color(red: 0.561, green: 0.702, blue: 0.604).opacity(0.16)) }
        }
    }
}

/// 收起态里跟着音乐跳的三根小柱（暂停时停住）
private struct EqualizerBars: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let base: [CGFloat] = [6, 12, 8]
                    let phase = playing ? (sin(t * 2 * .pi + Double(i) * 1.26) + 1) / 2 : 1
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(red: 0.561, green: 0.702, blue: 0.604))
                        .frame(width: 2, height: base[i] * (0.4 + 0.6 * CGFloat(phase)))
                }
            }
            .frame(width: 10, height: 12, alignment: .bottom)
        }
        .transition(.opacity)
    }
}

/// 岛的玻璃：iOS 26 真玻璃；mac（最低 15）退回毛玻璃
struct IslandGlass: ViewModifier {
    let cornerRadius: CGFloat
    var clear = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if os(iOS)
        content.glassEffect(clear ? .identity : .regular, in: shape)
        #else
        content.background(shape.fill(clear ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial)))
        #endif
    }
}

/// 长按岛弹出的预览（照 Telegram 长按置顶条：所有置顶的列表 + 「取消所有置顶」；另加正在放的音乐卡，直接复用、能播能拖）。
/// 背景压暗，点外面收起（不铺满全屏的 ScrollView，免得挡住暗背景）。
struct ChatTopIslandPeek: View {
    /// 聊天先后（0 = 最旧）
    let pins: [MessageNode]
    let currentIndex: Int
    let showsPins: Bool
    let onJump: (MessageNode) -> Void
    let onUnpin: (MessageNode) -> Void
    let onUnpinAll: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var player: MusicCardPlayer { .shared }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(appeared ? 0.18 : 0)
                .background(.ultraThinMaterial.opacity(appeared ? 1 : 0))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityLabel("关闭预览")
                .accessibilityAddTraits(.isButton)
            VStack(spacing: 12) {
                if showsPins, !pins.isEmpty { pinList }
                if let origin = player.origin, let card = origin.card {
                    MusicCardView(card: card, nodeId: origin.nodeId.isEmpty ? nil : origin.nodeId)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 66)                                   // 顶栏下面
            .scaleEffect(appeared || reduceMotion ? 1 : 0.94, anchor: .top)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(ChatCardMotion.animation(ChatCardMotion.morph, reduceMotion: reduceMotion)) { appeared = true }
        }
    }

    private var pinList: some View {
        ChatCardShell(kindLabel: pins.count > 1 ? "\(pins.count) 条置顶消息" : "置顶消息") {
            VStack(alignment: .leading, spacing: 0) {
                let rows = VStack(spacing: 0) {
                    ForEach(Array(pins.enumerated().reversed()), id: \.element.id) { i, node in   // 最新在上
                        row(node, current: i == currentIndex)
                        if i != 0 { MintHairline() }
                    }
                }
                if pins.count > 4 {
                    ScrollView { rows }.frame(height: 300)
                } else {
                    rows
                }
                if pins.count > 1 {
                    Button { onUnpinAll(); close() } label: {
                        Label("取消所有置顶", systemImage: "pin.slash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(CodeBlockStyle.label)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Capsule().strokeBorder(CodeBlockStyle.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
            }
        }
    }

    private func row(_ node: MessageNode, current: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(current ? Color(red: 0.435, green: 0.604, blue: 0.482) : Color.clear)
                .frame(width: 2, height: 36)
            Text(ContentCleaner.clean(node.content, cacheKey: node.id))
                .font(.system(size: 14))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onJump(node); close() }
            Button { onUnpin(node) } label: {
                Image(systemName: "pin.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(CodeBlockStyle.label)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消钉住这条")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func close() {
        withAnimation(ChatCardMotion.animation(ChatCardMotion.snappy, reduceMotion: reduceMotion)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onDismiss)
    }
}
