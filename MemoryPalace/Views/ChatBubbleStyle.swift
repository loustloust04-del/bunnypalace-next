import SwiftUI
import SwiftStreamingMarkdown   // P3 menu 探针起给 assistant 静态分支用 fork；splitBlocks 的围栏配对也用它（两端都链接 fork）

// MARK: - 气泡尾巴 Shape（iMessage 式）
//
// 圆角 = 系统 `Path(roundedRect:style:.continuous)`（Apple 连续曲率，与文章模式同款，无尖棱）。
// 尾巴 = 港自粟粟矢量稿（pao.svg）的脚丫子路径，addPath 并入同一 Path 一次填充
// （单次 fill，半透明气泡重叠区也不会叠深）。脚丫按顺时针构造，与系统矩形 winding 一致。
// isUser=true → 尾巴右下；assistant → 左下（pt 镜像）。

/// 输入框正在编辑这条消息时的气泡描边（plan-edit-in-composer §6）：稀、段稍长、稍粗、圆头。
/// 圆头各伸出半个线宽，看上去 ≈ 实 10 / 空 7。
enum EditingBubbleDash {
    static let lineWidth: CGFloat = 2.2
    static let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [8, 9])
}

struct BubbleTailShape: Shape {
    var isUser: Bool
    var radius: CGFloat = 16
    var hasTail: Bool = true
    /// 尾巴大小（按圆角半径的倍数；群聊用 0.8，一对一保持 1）
    var tailScale: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        let bodyR = min(radius, min(rect.width, rect.height) / 2)
        // 主体：系统连续曲率圆角矩形
        var p = Path(roundedRect: rect, cornerSize: CGSize(width: bodyR, height: bodyR), style: .continuous)
        guard hasTail else { return p }
        let r = bodyR * tailScale

        let minX = rect.minX, maxX = rect.maxX, maxY = rect.maxY
        // 镜像：assistant 尾巴翻到左下
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: isUser ? x : minX + maxX - x, y: y)
        }
        // 脚丫：必须让 tail 在它自己（镜像后的）局部坐标里仍是 CW，才与矩形 winding 同向、nonZero fill 不相消挖洞。
        // 镜像本身会反转绕向，所以 user / assistant 两套 addCurve 顺序必须相反：
        //  - isUser=true（右下，不镜像）：原顺序 e0→e1→…→e5（视觉 CW）
        //  - isUser=false（左下，镜像）：反序 e5→e4→…→e0（镜像后视觉 CW）
        var t = Path()
        if isUser {
            t.move(to: pt(maxX, maxY - r))
            t.addCurve(to: pt(maxX - 0.4621 * r, maxY - 0.1641 * r),
                       control1: pt(maxX, maxY - 0.6496 * r),
                       control2: pt(maxX - 0.1858 * r, maxY - 0.3427 * r))
            t.addCurve(to: pt(maxX - 0.4762 * r, maxY + 0.2789 * r),
                       control1: pt(maxX - 0.5986 * r, maxY - 0.0555 * r),
                       control2: pt(maxX - 0.5922 * r, maxY + 0.1357 * r))
            t.addCurve(to: pt(maxX - 0.4503 * r, maxY + 0.3571 * r),
                       control1: pt(maxX - 0.4563 * r, maxY + 0.3042 * r),
                       control2: pt(maxX - 0.4333 * r, maxY + 0.3244 * r))
            t.addCurve(to: pt(maxX - 0.5543 * r, maxY + 0.3822 * r),
                       control1: pt(maxX - 0.4752 * r, maxY + 0.4050 * r),
                       control2: pt(maxX - 0.5281 * r, maxY + 0.3902 * r))
            t.addCurve(to: pt(maxX - 1.3789 * r, maxY),
                       control1: pt(maxX - 0.7326 * r, maxY + 0.3286 * r),
                       control2: pt(maxX - 0.9753 * r, maxY + 0.0322 * r))
        } else {
            t.move(to: pt(maxX - 1.3789 * r, maxY))
            t.addCurve(to: pt(maxX - 0.5543 * r, maxY + 0.3822 * r),
                       control1: pt(maxX - 0.9753 * r, maxY + 0.0322 * r),
                       control2: pt(maxX - 0.7326 * r, maxY + 0.3286 * r))
            t.addCurve(to: pt(maxX - 0.4503 * r, maxY + 0.3571 * r),
                       control1: pt(maxX - 0.5281 * r, maxY + 0.3902 * r),
                       control2: pt(maxX - 0.4752 * r, maxY + 0.4050 * r))
            t.addCurve(to: pt(maxX - 0.4762 * r, maxY + 0.2789 * r),
                       control1: pt(maxX - 0.4333 * r, maxY + 0.3244 * r),
                       control2: pt(maxX - 0.4563 * r, maxY + 0.3042 * r))
            t.addCurve(to: pt(maxX - 0.4621 * r, maxY - 0.1641 * r),
                       control1: pt(maxX - 0.5922 * r, maxY + 0.1357 * r),
                       control2: pt(maxX - 0.5986 * r, maxY - 0.0555 * r))
            t.addCurve(to: pt(maxX, maxY - r),
                       control1: pt(maxX - 0.1858 * r, maxY - 0.3427 * r),
                       control2: pt(maxX, maxY - 0.6496 * r))
        }
        t.closeSubpath()
        p.addPath(t)
        return p
    }
}

// MARK: - 头像（自选头像有图显示图，nil 回退灰色占位圈）

struct AvatarBox: View {
    var size: CGFloat = 32
    var image: Image? = nil
    var body: some View {
        if let image {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(Theme.textMuted.opacity(0.25), lineWidth: 1)
                )
        } else {
            Circle()
                .fill(Theme.textMuted.opacity(0.18))
                .overlay(
                    Circle().strokeBorder(Theme.textMuted.opacity(0.25), lineWidth: 1)
                )
                .frame(width: size, height: size)
        }
    }
}

/// 气泡两侧头像（一个参数穿透 CardFlowView → BubbleView → BubbleModeRow）
struct ChatAvatars {
    let user: Image?
    let assistant: Image?
    static let none = ChatAvatars(user: nil, assistant: nil)
}

/// Profile 头像 Data → SwiftUI Image 解码缓存。气泡行是 hot path，禁止每 body 解码。
/// 指纹 = (字节数, 头8字节, 尾8字节)，O(1) 校验；数据变了才重新解码。主线程（SwiftUI body）专用。
enum AvatarImageCache {
    private struct Entry {
        let count: Int
        let head: [UInt8]
        let tail: [UInt8]
        let image: Image
    }
    private static var cache: [String: Entry] = [:]

    static func image(for data: Data?, key: String) -> Image? {
        guard let data, !data.isEmpty else {
            cache[key] = nil
            return nil
        }
        let head = [UInt8](data.prefix(8))
        let tail = [UInt8](data.suffix(8))
        if let e = cache[key], e.count == data.count, e.head == head, e.tail == tail {
            return e.image
        }
        guard let platformImage = PlatformImage(data: data) else { return nil }
        let image = Image(platformImage: platformImage)
        cache[key] = Entry(count: data.count, head: head, tail: tail, image: image)
        return image
    }
}

// MARK: - 气泡模式单条渲染（第 1 步：整条一个气泡，不拆）
//
// iMessage 式：assistant 左（头像 + 气泡），user 右（气泡 + 头像）。
// 头像 + 名字/时间戳在组顶显示，尾巴挂在气泡上。
// 按段落自动拆多气泡（splitBlocks）；B6 A2' 流式=已完成段落逐泡弹入 + 尾部 typing dots，不吐字。

/// 等待/流式指示：思考球（Vendor/ThinkingOrbsKit，px20 设计放大到 34）+ 轮换 shimmer 文案，
/// 流式尾泡 + CC 等待泡 + 文章模式空占位三处共用；样式跟设置页 `thinkingOrbStyle`（含怀旧三点）。
/// 球用 textSecondary 棕灰 mask 染色（点的透明度=深度保留；粟粟：原版偏浅一点的棕灰）。
/// 纯 TimelineView 驱动没有 @State，不碰泡的 transition
/// （interpolatingSpring additive 叠加教训——见 feedback_swiftui_animation_transaction_traps）。
struct TypingDotsView: View {
    @AppStorage(OrbState.storageKey) private var styleRaw = OrbState.working.rawValue

    var body: some View {
        if styleRaw == OrbState.legacyDotsRaw {
            BouncingDotsView()
        } else {
            HStack(spacing: 8) {
                Theme.textSecondary
                    .mask { ThinkingOrb(state: OrbState.stored(styleRaw), size: .px20, displaySize: 34) }
                    .frame(width: 34, height: 34)
                RotatingShimmerLabel()
            }
            .padding(.vertical, 2)
        }
    }
}

/// 怀旧三点：原版等待动画（三点错峰小幅弹跳），设置里选「三个点」时用。
struct BouncingDotsView: View {
    @State private var bouncing = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.textMuted.opacity(0.5))
                    .frame(width: 5, height: 5)
                    .offset(y: bouncing ? -3 : 1)
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.15),
                        value: bouncing
                    )
            }
        }
        .padding(.vertical, 4)
        .onAppear { bouncing = true }
    }
}

/// CC 等待泡（收口即发，plan-跨对话排队）：消息发给 CC、回复未落地时挂在列表底部的弹跳点行。
/// 纯 UI 合成行不是 MessageNode；样式对齐气泡模式 assistant 泡（固定 iMessage 外观值）。
struct CCWaitingBubbleRow: View {
    var body: some View {
        HStack {
            TypingDotsView()
                .padding(.horizontal, BubbleModeRow.fixedPaddingH)
                .padding(.vertical, BubbleModeRow.fixedPaddingV)
                .background(
                    BubbleTailShape(isUser: false, radius: 23, hasTail: true)
                        .fill(Theme.assistantBubble)
                )
            Spacer(minLength: 60)
        }
    }
}

struct BubbleModeRow: View {
    let node: MessageNode
    let isUser: Bool
    var isStreaming: Bool = false
    /// B6 A2'：流式数据源（Phase 5 后 node.content 流式中不更新）。
    /// 非 nil = 弹泡模式：只渲染已完成段落 + 尾部 typing dots，不逐 token 吐字。
    var streamingText: String? = nil
    /// CC 入场弹泡（research-cc-bubble-entrance）：true=待入场 reveal（消息已完整，按节奏逐泡放出）
    var entrancePending: Bool = false
    /// reveal 弹完回调（调用点从 vm 待弹集合移除）
    var onEntranceDone: (() -> Void)? = nil
    /// pop-tuner v7：发消息弹泡（行内泡级）——true=本行的泡带弹入 transition（头像/昵称直出）。
    /// 白名单在 vm 自动销账（duration+0.6s），滚回重挂载不重弹
    var popPending: Bool = false
    let selectedFont: String
    let fontScale: Double
    let lineSpacingScale: Double
    let paragraphSpacingScale: Double
    let regexScripts: [RegexScript]
    let bubbleCornerRadius: Double
    let bubblePaddingH: Double
    let bubblePaddingV: Double
    let userName: String
    let assistantName: String
    var hideTimestamp: Bool = false
    var hideRoleName: Bool = false
    var showAvatar: Bool = true
    var avatars: ChatAvatars = .none
    /// A4：每个气泡（block）的长按菜单 spec，参数=该气泡文字（引用/复制本段作用于它）+ 她的语音泡的音频路径（菜单加「分享」）。
    /// 父层 BubbleView 构造。iOS 走 UIKit 桥 marker（反转列表 contextMenu 修复），macOS 从 spec 渲染 .contextMenu。
    var blockMenuSpecs: ((_ text: String, _ voicePath: String?) -> [MenuActionSpec])? = nil
    /// 浮条「引用」通道（选段引用；长按菜单整块引用已删）
    var onQuoteText: ((String) -> Void)? = nil
    /// 跳到这条（对话内查找 / pin）时闪一下
    var isHighlighted: Bool = false
    var branchInfo: BranchInfo? = nil
    var onSwitchBranch: (String, Int) -> Void = { _, _ in }
    @State private var showBranchPicker = false
    /// 输入框正在编辑这条：所有分泡一起变透明 + 圆角虚线（plan-edit-in-composer §6）
    var isBeingEdited: Bool = false

    private let avatarSize: CGFloat = 32
    private let rowGap: CGFloat = 8

    /// 思考链回传开关：关=不渲染 CC thinking（数据照落库）
    @AppStorage("ccShowThinking") private var showCCThinking = true

    /// CC 入场 reveal：非 nil=进行中（只放出前 N 块，0=只有 dots 前奏）。滚走重置，滚回从头重弹。
    @State private var revealedCount: Int? = nil
    @State private var revealTask: Task<Void, Never>? = nil
    @State private var flashOpacity: Double = 0
    /// 对话内查找命中这条时的词（用户纯 Text 气泡自己上底色；AI 正文走 ChatMarkdownView 划线层）
    @Environment(\.chatSearchTerms) private var searchTerms
    @Environment(\.modelContext) private var modelContext

    // 气泡模式锁定外观：iMessage 固定值，不受「气泡外观（高级）」滑块影响（仅普通模式可调）
    static let fixedPaddingH: Double = 18
    static let fixedPaddingV: Double = 15
    static let fixedLineSpacing: Double = 1.45
    static let fixedParagraphSpacing: Double = 1.65

    var body: some View {
        HStack(alignment: .top, spacing: rowGap) {
            if isUser {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) { header; attachmentStrip; bubbleStack.chatReactionBadge(target: ChatReactionTarget(node: node), isUser: true); branchPager }
                if showAvatar { AvatarBox(size: avatarSize, image: avatars.user) }
            } else {
                if showAvatar { AvatarBox(size: avatarSize, image: avatars.assistant) }
                VStack(alignment: .leading, spacing: 8) {
                    header
                    attachmentStrip
                    bubbleStack.chatReactionBadge(target: ChatReactionTarget(node: node), isUser: false)
                    RecallCardView(node: node).padding(.horizontal, 18)
                    branchPager
                    usageFooter
                }
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        #if os(macOS)
        // R9 I2：气泡模式排版锁定——行内正文（含 MessageSegmentsView 里的 ChatMarkdownView）吃固定值，
        // 不被「外观 › 排版」全局滑杆带跑（普通模式/思考表不注入，照旧读全局）
        .environment(\.chatSpacingOverride,
                     ChatSpacingOverride(lineSpacing: Self.fixedLineSpacing,
                                         paragraphSpacing: Self.fixedParagraphSpacing))
        #endif
    }

    @ViewBuilder
    private var branchPager: some View {
        if let branchInfo {
            BranchIndicator(info: branchInfo, showPicker: $showBranchPicker, onSwitchBranch: onSwitchBranch)
        }
    }

    @AppStorage("showMessageUsage") private var showMessageUsage = true

    /// D2：每轮 usage footer（气泡模式版；文章模式在 BubbleView 内）。外观设置「显示消息用量」可隐藏。
    @ViewBuilder
    private var usageFooter: some View {
        if showMessageUsage, let pt = node.usagePromptTokens, let ct = node.usageCompletionTokens {
            let hit: String = {
                guard let read = node.usageCacheReadTokens, read > 0, pt > 0 else { return "" }
                return " · 命中 \(Int(Double(read) / Double(pt) * 100))%"
            }()
            let cost: String = {
                guard let c = node.usageCostUSD, c > 0 else { return "" }
                return String(format: " · $%.4f", c)
            }()
            Text("↑\(Self.fmtTok(pt)) ↓\(Self.fmtTok(ct))" + hit + cost)
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted.opacity(0.5))
                .padding(.horizontal, 2)
        }
    }

    private static func fmtTok(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    @ViewBuilder
    private var header: some View {
        // 时间挪到列表中间的分割线 + 长按菜单底部（TASK page1-消息-20）
        if !hideRoleName || (isUser && (node.styleIdSnapshot != nil || node.cardEventsData != nil)) {
            HStack(spacing: 4) {
                if !hideRoleName {
                    Text(isUser ? userName : assistantName)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(Theme.textMuted)
                }
                if isUser { StyleChip(styleId: node.styleIdSnapshot); CardEventsChip(node: node) }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if let segs = ChatDisplaySnapshot.segments(of: node)?.hydratedForDisplay(profileId: node.profileId) {
            let items: [BubbleAttachmentItem] = segs.compactMap { seg in
                if case .image(let n, _, let d) = seg { return .image(name: n, data: d) }
                if case .attachment(let n, let t, let c) = seg { return .file(name: n, type: t, content: c) }
                if case .fileData(let n, let m, let d) = seg { return .fileData(name: n, mime: m, data: d) }
                return nil
            }
            if !items.isEmpty {
                BubbleAttachmentStrip(items: items, isUser: isUser)
            }
        }
    }

    // 第 2 步：按段落（块）拆多气泡。
    // 复杂消息（带思考/工具段）整块单气泡（思考链气泡留第 3 步）；纯文本按块拆，
    // iMessage 式只有最后一块带尾巴。
    private var bubbleStack: some View {
        // B6 A2'：blocks 数提到闭包外给 .animation(value:) 用，避免二次算 parsedContent
        let parsed: (thinking: String?, blocks: [String]) = isComplex ? (nil, []) : parsedContent
        // CC 入场 reveal：进行中只放出前 N 块；partial 态（流式 or reveal）尾部挂 dots 泡
        let shownBlocks = revealedCount.map { Array(parsed.blocks.prefix($0)) } ?? parsed.blocks
        let showPartialDots = isLiveStreaming || revealedCount != nil
        // 语音气泡（正文气泡上方，一条一泡）：正文空时尾巴归最后一条语音；复杂消息泡自带尾巴不让。
        // 她的语音条在文字下面（plan-voice-note M7），尾巴归最后一条语音，文字块不带
        let voices = voiceSegs
        let userVoicesBelow = isUser && !voices.isEmpty
        let voiceTail = !isComplex && (shownBlocks.isEmpty || userVoicesBelow) && !showPartialDots
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if !isUser {
                // 长按挂在气泡壳这层（胶囊自己的菜单关掉）：浮层预览带壳带尾巴，同她的语音泡
                ForEach(voices.indices, id: \.self) { i in
                    quotable("", actions: VoiceCapsuleView.menuSpecs(isUser: false, nodeId: node.id, path: voices[i].path,
                                                                     profileId: node.profileId, script: nil, speaker: assistantName,
                                                                     date: node.createTime, context: modelContext)) { forceTail in
                        singleBubble(hasTail: forceTail || (voiceTail && i == voices.count - 1)) {
                            VoiceCapsuleView(path: voices[i].path, duration: voices[i].duration,
                                             nodeId: node.id, profileId: node.profileId,
                                             isUser: isUser, embedded: true, ownMenu: blockMenuSpecs == nil,
                                             speaker: assistantName, createTime: node.createTime)
                        }
                    }
                }
            }
            if !isUser, node.contentType == "heartvoice" || node.content.hasPrefix("💭 心声\n\n") {
                HeartvoiceCardView(text: node.contentType == "heartvoice" ? node.content : String(node.content.dropFirst("💭 心声\n\n".count)),
                                   time: node.createTime)
            } else if isComplex {
                // 附件消息不拆块：reveal 前奏=dots 一拍，然后整泡弹入
                if revealedCount == 0 {
                    singleBubble(hasTail: true) { typingDots }
                        .transition(BubblePopTuning.popTransition(isUser: false))
                } else {
                    quotable(node.content) { _ in
                        singleBubble(hasTail: true) {
                            MessageSegmentsView(
                                segments: ChatDisplaySnapshot.segments(of: node) ?? [],
                                selectedFont: selectedFont,
                                fontScale: fontScale,
                                lineSpacingScale: lineSpacingScale,
                                paragraphSpacingScale: paragraphSpacingScale,
                                regexScripts: regexScripts,
                                isUser: isUser,
                                profileId: node.profileId,
                                simplifyMarkdown: true,
                                nodeId: node.id,
                                isStreaming: isStreaming,   // 整条消息定稿前不出外链卡 / 不截网页（终审 I2）
                                onQuoteText: onQuoteText,
                                toolNode: isUser ? nil : node,
                                suppressTrailingError: !isUser
                            )
                        }
                    }
                    // 群弹真凶修（探针定案）：只在 reveal 进行中或 popPending（发消息）挂弹入；静态直出
                    .transition(revealedCount != nil || popPending
                        ? BubblePopTuning.popTransition(isUser: isUser)
                        : .identity)
                }
            } else {
                if let thinking = parsed.thinking ?? (showCCThinking ? node.ccThinking : nil), !thinking.isEmpty {
                    ThinkingBubble(text: thinking, nodeId: node.id, profileId: node.profileId)
                }
                ForEach(shownBlocks.indices, id: \.self) { i in
                    quotable(shownBlocks[i]) { forceTail in
                        // partial 态（流式/reveal）中尾巴归 dots 泡；定格后回到末块
                        singleBubble(hasTail: forceTail || (i == shownBlocks.count - 1 && !showPartialDots && !userVoicesBelow)) {
                            blockText(shownBlocks[i])
                        }
                    }
                    // 群弹真凶修（探针定案）：块级弹入只在 partial 态（流式弹泡/CC reveal 进行中）
                    // 或 popPending（发消息，v7 弹泡下沉行内）挂——静态渲染一律 .identity 直出。
                    .transition(showPartialDots || popPending
                        ? BubblePopTuning.popTransition(isUser: isUser)
                        : .identity)
                }
                // B6 A2'：partial 尾部 typing dots 独立泡（固定 identity，不混进块 ForEach——
                // 否则「dots 变正文」被 transition 当内容替换而不是新泡弹入）
                if showPartialDots {
                    singleBubble(hasTail: true) { typingDots }
                        .transition(BubblePopTuning.popTransition(isUser: false))
                }
            }
            // 她的语音条：语音泡 + 下面「转文字 ›」。长按走这条消息的块菜单（复制本段 = 转写，没有编辑），胶囊自己的菜单关掉
            if isUser {
                ForEach(voices.indices, id: \.self) { i in
                    VStack(alignment: .trailing, spacing: 4) {
                        quotable(voices[i].script ?? "", voicePath: voices[i].path) { forceTail in
                            singleBubble(hasTail: forceTail || (voiceTail && i == voices.count - 1)) {
                                VoiceCapsuleView(path: voices[i].path, duration: voices[i].duration,
                                                 nodeId: node.id, profileId: node.profileId,
                                                 isUser: true, embedded: true,
                                                 script: voices[i].script, ownMenu: blockMenuSpecs == nil,
                                                 speaker: userName, createTime: node.createTime)
                            }
                        }
                        VoiceTranscriptToggle(script: voices[i].script)
                    }
                }
            }
        }
        .animation(BubblePopTuning.popAnimation, value: shownBlocks.count)
        .animation(BubblePopTuning.popAnimation, value: showPartialDots)
        .animation(BubblePopTuning.popAnimation, value: revealedCount)
        .animation(.easeInOut(duration: 0.2), value: isBeingEdited)
        .onAppear { startEntranceIfNeeded(blocks: parsed.blocks) }
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
            revealedCount = nil
        }
        .overlay(
            RoundedRectangle(cornerRadius: bubbleCornerRadius)
                .fill(Theme.branchIndicator.opacity(0.2 * flashOpacity))
                .allowsHitTesting(false)
        )
        .onChange(of: isHighlighted, initial: true) { _, highlighted in
            guard highlighted else { return }
            withAnimation(.easeIn(duration: 0.3)) { flashOpacity = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.5)) { flashOpacity = 0 }
            }
        }
    }

    /// CC 入场 reveal 节奏器：dots 前奏 → 按泡长自适应间隔逐块放出 → 收 dots + 回调移除待弹。
    private func startEntranceIfNeeded(blocks: [String]) {
        guard entrancePending, !isUser, !isLiveStreaming, revealTask == nil else { return }
        let total = isComplex ? 1 : blocks.count
        guard total > 0 else { onEntranceDone?(); return }  // 空消息不弹，直接销账
        revealedCount = 0
        revealTask = Task { @MainActor in
            for i in 0..<total {
                let len = isComplex ? node.content.count : blocks[i].count
                let delay = Self.entranceDelay(forBlockLength: len, isFirst: i == 0)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                revealedCount = i + 1
            }
            revealedCount = nil
            revealTask = nil
            onEntranceDone?()
        }
    }

    /// 流式 typing 指示（弹泡模式尾泡 + blockText 空块 fallback 共用）
    private var typingDots: some View { TypingDotsView() }

    /// 有 thinking / tool / attachment 段 = 复杂，整块不拆（思考链气泡是第 3 步）。
    /// audioRef 不算数（对齐 hasRenderableSegments）：语音走独立语音气泡，
    /// 只挂语音条的消息正文仍走纯文本拆块分支。
    private var isComplex: Bool {
        guard let segs = ChatDisplaySnapshot.segments(of: node) else { return false }
        return segs.contains { seg in
            switch seg {
            case .text, .image, .audioRef: return false
            default: return true
            }
        }
    }

    /// 语音段：气泡模式渲染成独立语音气泡（文章模式在 BubbleView 外侧胶囊，此处对应版）
    private var voiceSegs: [(path: String, duration: Double?, script: String?)] {
        ChatDisplaySnapshot.segments(of: node)?.audioRefs ?? []
    }

    /// B6 A2'：弹泡模式生效中（assistant 流式且有活文本源）
    private var isLiveStreaming: Bool {
        isStreaming && !isUser && streamingText != nil
    }

    /// 纯文本：先分离思考链（[thinking]…[/thinking]），正文按段落拆块
    private var parsedContent: (thinking: String?, blocks: [String]) {
        // B6 A2' 弹泡模式：数据源换 streamingText，只出已完成段落（尾段生长中不渲染，
        // 思考标签未闭合时整段留在尾块 → 思考阶段自然只显示 dots）
        if isLiveStreaming, let live = streamingText {
            let cleaned = ContentCleaner.clean(live, cacheKey: "\(node.id)_\(live.count)")
            let extracted = ContentCleaner.extractThinking(from: cleaned)
            let blocks = Self.streamingBlocks(extracted.content)
                .filter { !BubbleMarkdownSimplifier.isRenderEmpty($0) }
            #if (DEBUG || PERF_BENCH) && os(iOS)
            // 渲染输入进度（perf P0 §5.2 streamInput）：交给气泡的已完成块总长（末块不渲染）
            if PerfHarness.strictMeasure { PerfRenderLedger.noteStreamInput(nodeId: node.id, chars: blocks.reduce(0) { $0 + $1.count }, mode: "bubble") }
            #endif
            return (extracted.thinking, blocks)
        }
        // 卡开场的 {{char}}/{{user}} 只在显示副本展开（③b）
        let displayContent = isUser ? node.content : ChatSystemMessage.split(node.content).body
        let cleaned = EffectiveCharacterContext(charName: assistantName, userName: userName)
            .expand(ContentCleaner.clean(displayContent, cacheKey: "\(node.id)_\(displayContent.count)"))
        if cleaned.isEmpty && isStreaming { return (nil, [""]) }
        let extracted = isUser ? nil : ContentCleaner.extractThinking(from: cleaned)
        // 她带语音的消息：content 里 [语音 m:ss] 那行只给 AI 看，气泡显示读 .text 段（打的字原文），同文章模式（sol P2-4）；
        // 没语音段的普通消息照用 content，手打的 [语音 0:07] 行原样
        let typed = isUser ? ChatDisplaySnapshot.segments(of: node)?.userTypedTextIfVoice : nil
        let body = extracted?.content ?? typed.map {
            EffectiveCharacterContext(charName: assistantName, userName: userName)
                .expand(ContentCleaner.clean($0, cacheKey: "\(node.id)_typed_\($0.count)"))
        } ?? cleaned
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 卡库 ⑦：先把明确 HTML 包成 ```html 再拆块（文档里的空行不再把它拆碎）
        var blocks = trimmed.isEmpty ? [] : Self.splitBlocks(MessageHTMLSegments.markdownPromotingHTML(body))
        if !isUser {
            // 气泡模式简化会把纯分隔线块删空——拆块时就过滤掉，避免渲染出空气泡
            blocks = blocks.filter { !BubbleMarkdownSimplifier.isRenderEmpty($0) }
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        // 渲染账本 consumed（perf P0 §5.2）：静态拆块消费的 node.content 快照摘要
        if PerfHarness.strictMeasure { PerfRenderLedger.noteConsumed(nodeId: node.id, content: node.content, mode: "bubble") }
        #endif
        return (extracted?.thinking, blocks)
    }

    @ViewBuilder
    private func blockText(_ block: String) -> some View {
        if block.isEmpty && isStreaming {
            typingDots
        } else if isUser {
            // ⑤a：用户块也跑显示规则（placement 1），只改显示副本
            let block = RegexPipeline.run(regexScripts, text: block, phase: .display, placement: RegexPipeline.userPlacement,
                                          userName: userName, charName: assistantName)
            // 用户块整块是卡片（分气泡已把卡片单独成块）→ 画卡，不露 JSON（research-chat-cards §6）
            if let card = ChatCardRegistry.standaloneCardBlock(block),
               let view = ChatCardRegistry.view(language: card.language, code: card.code, nodeId: node.id, streaming: false) {
                view
            } else if let link = StandaloneLinkDetector.detect(markdownBlock: block),
                      let view = ChatCardRegistry.linkView(url: link.url, label: link.label, streaming: false) {
                view
            } else {
                Text(InConvFind.highlighted(block, terms: searchTerms))
                    .font(FontManager.font(size: 13.5))
                    .foregroundColor(Theme.userText)
                    .textSelection(.enabled)
                    .lineSpacing(4 * (fontScale > 0 ? fontScale : 1.0) * lineSpacingScale)
            }
        } else {
            let regexed = RegexPipeline.run(regexScripts, text: block, phase: .display,
                                            placement: RegexPipeline.placement(forRole: node.role),
                                            userName: userName, charName: assistantName)
            // 气泡模式抹平文档感 Markdown（标题/嵌套列表/分隔线）；正则脚本先吃原文，简化只发生在渲染前
            let display = BubbleMarkdownSimplifier.simplify(regexed)
            // B6 A2'：单渲染器收敛——弹泡模式下块一旦出现内容已定格，流式/静态都走 fork 静态渲染
            // （原 isStreaming 的 MarkdownUI 分支随 Phase 5 数据断链已近死代码，删）
            // R2-4b：统一走 ChatMarkdownView（划词收生词）
            ChatMarkdownView(
                text: MessageHTMLSegments.markdownPromotingHTML(display),   // 卡库 ⑦：显示正则产出的 HTML 同样交给网页卡
                fontName: selectedFont,
                scale: fontScale > 0 ? fontScale : 1.0,
                nodeId: node.id,
                profileId: node.profileId,
                onQuote: onQuoteText,
                // M1 三格：这里是 blockText 的 else 分支（非 user），恒为 AI 正文；
                // 同函数的 user 分支是上面那个纯 Text，走 Theme.userText
                role: .assistant
            )
            // 整条消息定稿前不抓链接（research-chat-cards §7.4）；已写完的网页块例外，不用等整条结束（TASK page1-卡片-05）
            .chatCardRenderer(nodeId: node.id, streaming: isStreaming && !ChatCardRegistry.isFinishedHTMLBlock(display))
        }
    }

    /// 给单个气泡挂 block 级长按菜单（blockMenuSpecs 为 nil 时原样返回，不挂菜单）。
    /// iOS：wrapper 登记 marker 命中区 + 活副本，长按走 Telegram 式浮层
    /// （见 docs/plan-contextmenu-telegram-style.md）；macOS 从同 spec 渲染 .contextMenu。
    /// content 的 Bool 参数 = 预览强制带尾巴（列表渲染传 false 走原逻辑）。
    /// actions 有值 = 换成这份条目（AI 语音泡：换一版），仍只在 blockMenuSpecs 非 nil（挂菜单的场合）时挂
    @ViewBuilder
    private func quotable<Content: View>(_ text: String, voicePath: String? = nil, actions: [MenuActionSpec]? = nil,
                                         @ViewBuilder _ content: @escaping (Bool) -> Content) -> some View {
        if let blockMenuSpecs {
            #if os(iOS)
            BubbleMenuLiftWrapper(
                isUser: isUser,
                cornerRadius: bubbleCornerRadius,
                tailBackdrop: true,
                actions: actions ?? blockMenuSpecs(text, voicePath),
                content: { content(false) },
                previewContent: { AnyView(content(true)) }
            )
            #else
            content(false).contextMenu { MenuActionSpec.menuItems(from: actions ?? blockMenuSpecs(text, voicePath)) }
            #endif
        } else {
            content(false)
        }
    }

    private func singleBubble<Content: View>(hasTail: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, bubblePaddingH)
            .padding(.vertical, bubblePaddingV)
            .background {
                if isBeingEdited {
                    // 泡形带尾巴不是 InsettableShape：往里收半个线宽再描，虚线不出原外框
                    BubbleTailShape(isUser: isUser, radius: bubbleCornerRadius, hasTail: hasTail)
                        .stroke(Theme.branchIndicator, style: EditingBubbleDash.style)
                        .padding(EditingBubbleDash.lineWidth / 2)
                } else {
                    // 你的气泡可以是锚在聊天区的两色渐变（plan-bubble-gradient）；列表是反转的（CardFlowView.flippedUpsideDown）
                    UserBubbleFill(
                        shape: BubbleTailShape(isUser: isUser, radius: bubbleCornerRadius, hasTail: hasTail),
                        base: isUser ? Theme.userBubble : Theme.assistantBubble,
                        gradient: isUser ? Theme.userBubbleGradient : nil,
                        anchor: .scrollView(flipped: true)
                    )
                }
            }
    }

    /// B6 A2'：流式期间的「已完成段落」——最后一个块视为正在生长不渲染（弹泡模式不吐字）。
    /// 未闭合代码围栏整体留在尾块不会被切半；文本以空行收尾时尾块其实已闭合，保守晚弹一拍。
    static func streamingBlocks(_ text: String) -> [String] {
        Array(splitBlocks(text).dropLast())
    }

    /// CC 入场弹泡节奏（粟粟拍的时长感）：弹某泡**之前**停「打这段字的时间」——
    /// 0.15s + 字数×0.004s，clamp [0.18, 0.7]；首泡前至少 0.4s（dots 前奏一拍）。纯函数可测。
    static func entranceDelay(forBlockLength count: Int, isFirst: Bool) -> TimeInterval {
        let d = min(max(0.15 + Double(count) * 0.004, 0.18), 0.7)
        return isFirst ? max(0.4, d) : d
    }

    /// 按段落拆块：空行分隔成块；围栏代码块整块保留不拆（```` 包 ``` 的嵌套按 CommonMark 配对，不会被内层切断）。
    static func splitBlocks(_ text: String) -> [String] {
        // 三个反引号包三个反引号：先推断嵌套、把外层围栏加长，再按标准配对
        let text = MarkdownFenceNormalizer.normalize(text)
        var blocks: [String] = []
        var buf: [String] = []
        var fence = MarkdownFenceTracker()
        func flush() {
            let s = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { blocks.append(s) }
            buf.removeAll()
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let wasInside = fence.isInsideFence
            if fence.consume(line) {
                if !wasInside { flush() }                     // 开围栏：前面的段落先成块
                buf.append(line)
                if !fence.isInsideFence { flush() }           // 关围栏：整块代码成块
            } else if t.isEmpty {
                flush()
            } else {
                buf.append(line)
            }
        }
        flush()
        return blocks.isEmpty ? [text] : blocks
    }
}

// MARK: - 思考链气泡（灰色窄气泡，可折叠，区别于聊天气泡）

struct ThinkingBubble: View {
    let text: String
    var nodeId: String? = nil
    var profileId: String = ""

    var body: some View {
        // 展开/弹 sheet 分流统一在 ThinkingDisclosure（「思考过程弹出显示」开关）
        ThinkingDisclosure(label: "思考", text: text, nodeId: nodeId, profileId: profileId)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.textMuted.opacity(0.1))
            )
    }
}
