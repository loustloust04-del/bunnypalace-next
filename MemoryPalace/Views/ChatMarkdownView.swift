import SwiftUI
import SwiftData
import SwiftStreamingMarkdown

/// 聊天正文统一 Markdown 渲染 + 划词收生词浮条（R2-4b）。
///
/// ⚠️ 教训（2026-07-09）：聊天正文有 5 个 MarkdownView 调用点（article 分段/article 纯文/
/// user 两处/气泡模式），只接一个 = 粟粟划词"还是没有"。全部走这个包装，别再散装接。
/// 流式尾巴（StreamingTextView）不走——生成中不收词。
/// 09-16 MarkdownUI 退役第二刀后，文件库预览 / 说明书 / 笔记 / 话题卡 / 标的页也都走这里（各自的差异靠
/// `nodeId`（划线锚）、`profileId`（存成问题）、`linkifyTickers`（$NVDA）三个参数分流）。
/// 词卡来源跳转时闪一下的底色（暖橙 1.8s）。划线本身的颜色走共用色板 HighlightPalette。
private let flashHighlightColor = PlatformColor(red: 0.91, green: 0.61, blue: 0.28, alpha: 0.28)  // #E89B47

/// 对话内查找的词（CardFlowView 只给命中的气泡注入，其余为空）
private struct ChatSearchTermsKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

extension EnvironmentValues {
    var chatSearchTerms: [String] {
        get { self[ChatSearchTermsKey.self] }
        set { self[ChatSearchTermsKey.self] = newValue }
    }
}

/// 段落簇合并（跨段选择）开关：列表里恒 false（粟粟 10-03：Air 一合并就卡），
/// 只有长按浮层预览（BubbleMenuOverlayView.previewBox）注入 true。mac 没有长按浮层，恒不合并。
private struct ChatMergesTextRunsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatMergesTextRuns: Bool {
        get { self[ChatMergesTextRunsKey.self] }
        set { self[ChatMergesTextRunsKey.self] = newValue }
    }
}

struct ChatMarkdownView: View {
    let text: String
    var fontName: String = ""
    var scale: CGFloat = 1.2
    var animated: Bool = false
    /// 划线锚定的消息节点；nil = 无划线功能（浮条不出划线子菜单）。
    var nodeId: String? = nil
    var profileId: String = ""
    /// 浮条「引用」（粟粟：双击坨坨直接引用，长按菜单的整块引用删了）；nil = 浮条不出引用项
    var onQuote: ((String) -> Void)? = nil
    /// 打开时高亮闪一下的词（词卡来源跳转定位用，1.8s 后熄）。
    var flashQuote: String? = nil
    /// `$NVDA` 链接化。聊天 / 笔记 / 标的页要它（交易语境本意）；
    /// 文件库预览和说明书传 false——那是任意内容，`$PATH` / `$HOME` 也是 1–5 位全大写，会变成假 ticker（R-MD #1）
    var linkifyTickers: Bool = true
    /// 正文按角色取字色（plan-theme-decouple M1 三格）。默认 `.global` = 主文字，
    /// 非聊天调用方（文件库预览等）不用传；聊天由 `CardFlowView.markdownBody` 按 `isUser` 给。
    var role: ChatTextRole = .global

    #if os(macOS)
    // ms0911 R8 B3 / R8b N2：设置「外观 › 排版」两根滑杆 mac 自己读（key/默认值与 CardFlowView 同名键一致），
    // 滑杆只在 mac 传 config、只在 mac 进 cacheDims；iOS 的 fork 渲染器本来就不吃滑杆（写死块距 30 / 行距 5），
    // 声明包门避免 dead 订阅（feedback_appstorage_dead_subscription）。
    @AppStorage("lineSpacingScale") private var lineSpacingScale: Double = 1.45
    @AppStorage("paragraphSpacingScale") private var paragraphSpacingScale: Double = 1.65

    // R9 I2：气泡模式行内固定排版覆盖（BubbleModeRow 注入；普通模式/思考表为 nil 读全局滑杆）。
    @Environment(\.chatSpacingOverride) private var spacingOverride
    private var effectiveLineSpacingScale: Double { spacingOverride?.lineSpacing ?? lineSpacingScale }
    private var effectiveParagraphSpacingScale: Double { spacingOverride?.paragraphSpacing ?? paragraphSpacingScale }
    #endif

    // R9 B1：主题维度——主题色在 parse 时写进 attributed string，token 集/深浅色换了缓存键必须跟着换。
    // themeChangeID 覆盖主题选择/自定义编辑/纯色开关/系统深浅色（syncSystemColorScheme touch）；
    // activeScheme 再兜一层深浅色。body 里读 @Observable 属性 = 订阅，变了视图自然重算。
    // M1：原来只包在 `#if os(macOS)` 里 → iOS 改完颜色旧消息不刷新（LRU 里 ≤200 条留着旧色）。
    // 它读的是 @Observable 属性不是 @AppStorage，两端都用不会有 dead 订阅问题。
    private var themeDim: String {
        "\(ThemeManager.shared.themeChangeID)|\(ThemeManager.shared.activeScheme)"
    }

    @State private var flashing = true
    @Environment(\.chatSearchTerms) private var searchTerms
    @Environment(\.chatMergesTextRuns) private var focusMerges
    /// 只有聚焦态（浮层预览）且定稿才合并；流式中（animated）不合并
    private var mergesTextRuns: Bool { focusMerges && !animated }

    @Environment(\.modelContext) private var modelContext

    /// 轻点划线弹的时间线小窗（fork patch 7.1 → id "highlight.tap"），和读书共用 NoteQuickLookSheet。
    private struct ManagedHighlight: Identifiable {
        let quote: String
        var id: String { quote }
    }
    @State private var managedHighlight: ManagedHighlight? = nil
    @AppStorage(HighlightPalette.lastColorKey) private var lastHighlightColor = HighlightPalette.userDefault
    @AppStorage(HighlightPalette.lastStyleKey) private var lastHighlightStyle = HighlightStyle.fill.rawValue

    /// 浮条注入项（fork 上游 textContextMenu 管线 → ParagraphUIView.editMenuForTextIn）：
    /// 收生词恒有；引用=onQuote 调用点；划线=有 nodeId 的调用点（一点就按上次的颜色 / 样式划，改色在时间线小窗里）。
    private var contextMenu: TextContextMenu {
        var inline = [TextContextMenuItem(id: "collectVocab", title: "收生词")]
        if onQuote != nil {
            inline.append(TextContextMenuItem(id: "quote", title: "引用"))
        }
        // 没有 profileId 的调用点（编程会话详情页）不出这一项：存问题要写进那个楼层的文件库，
        // profileId 为空会被 floorSlug 兜底成「楼层-profile」建出一个谁也看不见的幻影楼层（R-CD #1）
        if nodeId != nil {
            inline.insert(TextContextMenuItem(id: "highlight.add", title: "划线"), at: 0)
        }
        return TextContextMenu(menuGroups: [TextContextMenuGroup(title: nil, image: nil, displayInline: true, items: inline)])
    }

    /// 本节点划线 + 词卡跳转闪词（暖橙 1.8s，fork 划线层动态更新熄灭即 repaint）。
    private var effectiveHighlights: [TextHighlight] {
        // 划线画在字下面一层（底色 / 下划线 / 彩笔，同一段可叠，和读书同一种画法）
        var highlights: [TextHighlight] = nodeId.map { nid in
            ChatHighlightStore.shared.strokes(nodeId: nid, profileId: profileId).map { h in
                let style: TextHighlightStyle
                let alpha: CGFloat
                switch h.strokeStyle {
                case .fill: style = .fill; alpha = 0.30
                case .underline: style = .underline; alpha = 0.9
                case .pen: style = .pen; alpha = 0.45
                }
                return TextHighlight(quote: h.quote,
                                     color: PlatformColor(HighlightPalette.color(h.strokeColorHex)).withAlphaComponent(alpha),
                                     style: style, strokeId: h.id)
            }
        } ?? []
        if let flash = flashQuote, flashing {
            highlights.append(TextHighlight(quote: flash, color: flashHighlightColor))
        }
        return highlights
    }

    /// 对话内查找高亮：按 hitRanges 规则从正文取出实际写法的子串当 quote（划线层按原文精确匹配）
    private var searchQuotes: [String] {
        guard !searchTerms.isEmpty else { return [] }
        var seen = Set<String>()
        return MacSearchQuery.hitRanges(in: text, words: searchTerms)
            .map { String(text[$0]) }
            .filter { seen.insert($0).inserted }
    }

    /// 画出来的高亮 = 划线 / 闪词 + 查找词。查找词**不进 cacheDims**：每按一个键都变，进了会让可见气泡全部重新排版；
    /// fork 解析不读高亮，段落层 updateUIView 时 setTextHighlights 重画即可
    private var renderHighlights: [TextHighlight] {
        let quotes = searchQuotes
        guard !quotes.isEmpty else { return effectiveHighlights }
        let color = PlatformColor(InConvFind.highlightColor)
        return effectiveHighlights + quotes.map { TextHighlight(quote: $0, color: color) }
    }

    /// L2-T3 缓存维度摘要：排版相关的全部输入（listener 除外）。划线用 quote+color 拼摘要，
    /// 深翻主流场景（零划线+恒定字体）下 key 退化为纯文本。
    private var cacheDims: String {
        let hl = effectiveHighlights.map { "\($0.quote.hashValue):\($0.color.hashValue):\($0.style.rawValue):\($0.strokeId)" }.joined(separator: ",")
        // M1：主题维度两端都进（iOS 原来没有 → 换色旧消息不刷新）；role 也必须两端都进——
        // 同一句话用户发过、AI 也说过，不带 role 就共用一份缓存串色（mac 原来就有这个洞）。
        // 合并在 parse 时生效（Document+ TextRunMerger），缓存的是合并后的块，必须进 key；
        // 只在合并时追加，列表侧（不合并）key 与原来逐字相同，不多一次重算
        let base = "\(fontName)|\(scale)|\(animated)|q\(onQuote != nil ? 1 : 0)n\(nodeId != nil ? 1 : 0)|\(hl)|t\(themeDim)|r\(role.rawValue)"
            + (mergesTextRuns ? "|m" : "")
        #if os(macOS)
        // 排版滑杆仍只 mac 进 key（R8b N1：iOS 调滑杆不换缓存键，fork 渲染器不吃）
        return base + "|ls\(effectiveLineSpacingScale)|ps\(effectiveParagraphSpacingScale)"
        #else
        return base
        #endif
    }

    /// 渲染 config。Swift 5.10 不支持实参位 `#if`，提为计算属性：#else 分支 = 原调用表达式逐字，
    /// mac 分支追加排版滑杆两值（R8 B3 / R8b N2）。
    /// 段落簇合并只在聚焦态（长按浮层预览）开，见 `mergesTextRuns`；合并维度进 cacheDims（`|m`）。
    private var renderConfig: MarkdownRenderConfig {
        #if os(macOS)
        return .memoryPalace(fontName: fontName, scale: scale, animated: animated,
                             contextMenu: contextMenu,
                             textHighlights: renderHighlights,
                             lineSpacingScale: effectiveLineSpacingScale,
                             paragraphSpacingScale: effectiveParagraphSpacingScale,
                             textColor: role.color,
                             mergesTextRuns: mergesTextRuns)
        #else
        return .memoryPalace(fontName: fontName, scale: scale, animated: animated,
                             contextMenu: contextMenu,
                             textHighlights: renderHighlights,
                             textColor: role.color,
                             mergesTextRuns: mergesTextRuns)
        #endif
    }

    private var renderedText: String {
        text
    }

    var body: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        // perf P0 R5 C-03：本行 nodeId 交给紧接着构造的 CachedMarkdownView（无标记长文的异步回执）
        let _ = PerfHarness.strictMeasure ? PerfRenderLedger.setBodyNode(nodeId) : ()
        #endif
        CachedMarkdownView(
            // $NVDA link 化只作用于渲染文本（按 node.id 缓存防热路径放大）；
            // listener 的 blockText 保持原始 text——收生词/划线锚定不受 link 化影响。
            text: renderedText,
            config: renderConfig,
            cacheDims: cacheDims,
            // animated ⟺ 流式中（唯一传 true 的调用点是 BubbleView 流式分支）：中间态不进缓存
            transient: animated,
            // listener 被 MarkdownView 的 StateObject 钉在首次创建——流式中途完成的消息
            // blockText 是首帧快照，找不到选段时 anchor 退化为选中原文（可接受）
            listener: TranscriptVocabListener(blockText: text) { id, selected, blockText in
                handleMenuTap(id: id, selected: selected, blockText: blockText)
            },
            // perf L1c：刚流完的这条首见未命中也同步解析，翻回静态不闪空
            syncOnMiss: !animated && nodeId.map { MarkdownRenderCache.shared.isFreshlyStreamed($0) } == true
        )
        .task {
            if flashQuote != nil {
                try? await Task.sleep(for: .seconds(1.8))
                flashing = false
            }
        }
        .sheet(item: $managedHighlight) { h in
            let store = ChatHighlightStore.shared
            let notes = nodeId.map { store.highlights(nodeId: $0, profileId: profileId) } ?? []
            NoteQuickLookSheet(
                noteIds: notes.filter { $0.replyTo == nil && $0.quote == h.quote }.map(\.id),
                allNotes: notes,
                assistantName: "",
                onChange: { change in store.mutate(change) },
                onShowChat: { _ in }
            )
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 460)   // mac sheet 不给 frame 塌小（先例 CardFlowView TextSelectSheet）
            #endif
        }
    }

    /// 浮条动作分发：收生词 / 引用 / 存成问题 / 划线 / 轻点划线开时间线。
    @MainActor
    private func handleMenuTap(id: String, selected: String, blockText: String) {
        if id == "collectVocab" {
            collect(selected: selected, blockText: blockText)
            return
        }
        if id == "quote" {
            onQuote?(selected)
            return
        }
        guard id.hasPrefix("highlight."), let nodeId else { return }
        if id == "highlight.tap" {
            // 查找高亮 / 闪词不是划线：点它不出小窗（同一段也划过线的除外）
            guard ChatHighlightStore.shared.strokes(nodeId: nodeId, profileId: profileId).contains(where: { $0.quote == selected }) else { return }
            managedHighlight = ManagedHighlight(quote: selected)
            return
        }
        if id == "highlight.add" {
            ChatHighlightStore.shared.add(
                nodeId: nodeId, profileId: profileId, quote: selected, color: lastHighlightColor,
                style: HighlightStyle(rawValue: lastHighlightStyle) ?? .fill)
            showToast("已划线")
        }
    }

    /// 收生词：生词本 + 所在句快照 + 开关开着同步进复习牌堆。
    @MainActor
    private func collect(selected: String, blockText: String) {
        let sentence: String
        if let r = blockText.range(of: selected) {
            sentence = VocabCollector.sentence(containing: r, in: blockText)
        } else {
            sentence = selected   // 渲染文本 ≠ markdown 源（跨格式边界选段），退选中原文
        }
        guard let word = VocabCollector.collectManually(rawText: selected, anchor: sentence,
                                                        chatNodeId: nodeId, context: modelContext) else {
            showToast("这段不适合收词")
            return
        }
        if VocabCollector.autoReviewEnabled {
            VocabCardStore.addIfAbsent(word: word, source: "chat", dir: VocabCollector.reviewDeckDir)
        }
        showToast("已收「\(word)」✨")
    }

    private func showToast(_ msg: String) {
        ToastCenter.shared.show(msg)
    }

    /// MarkdownListener 适配：id 原样透传（收生词/划线统一走 handleMenuTap 分发）。
    /// 探针留着——再出"没有"先拉 console 分层。
    private struct TranscriptVocabListener: MarkdownListener {
        let blockText: String
        let onTap: @MainActor (String, String, String) -> Void   // (id, selected, blockText)

        func onRender(markdown: RenderableDocument) async {}
        func onTableCopyTap(content: String) async {}
        func onTableDownloadTap(content: String) async {}

        func onContextMenuAppear(id: String, selectedContent: String) async {
            #if DEBUG
            print("[PROBE] transcript editMenu appear id=\(id) sel=\(selectedContent.prefix(20))")
            #endif
        }

        func onContextMenuTap(id: String, selectedContent: String) async {
            #if DEBUG
            print("[PROBE] transcript editMenu tap id=\(id)")
            #endif
            let trimmed = selectedContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            await onTap(id, trimmed, blockText)
        }
    }
}

#if os(macOS)
/// R9 I2：气泡模式行内正文的固定排版覆盖（值 = BubbleModeRow.fixedLineSpacing/fixedParagraphSpacing）。
/// 只在 mac 定义/注入/消费——iOS 的 fork 渲染器本来就不吃排版滑杆，无需此机制。
struct ChatSpacingOverride: Equatable {
    let lineSpacing: Double
    let paragraphSpacing: Double
}

private struct ChatSpacingOverrideKey: EnvironmentKey {
    static let defaultValue: ChatSpacingOverride? = nil
}

extension EnvironmentValues {
    var chatSpacingOverride: ChatSpacingOverride? {
        get { self[ChatSpacingOverrideKey.self] }
        set { self[ChatSpacingOverrideKey.self] = newValue }
    }
}
#endif
