import SwiftUI
import SwiftStreamingMarkdown

/// 代码块 → 卡片（research-chat-cards §4.2）。html 给网页卡 HTMLCardView；card-* 解析成卡片；其他交回渲染器默认代码块。
enum ChatCardRegistry {
    enum Kind: Equatable {
        case html
        case htmlPlaceholder
        case mermaid
        case mermaidPlaceholder
        case card(ChatCard)
        case placeholder
    }

    static func kind(language: String, code: String, streaming: Bool) -> Kind? {
        let lang = language.lowercased()
        if lang == "html" { return streaming ? .htmlPlaceholder : .html }
        if lang == "mermaid" { return streaming ? .mermaidPlaceholder : .mermaid }   // 图表：写完才渲染（plan-mermaid）
        guard ChatCard.isCardLanguage(lang) else { return nil }
        if let card = ChatCard.parse(language: lang, code: code) {
            // 图表 / 音乐：流式中即使 JSON 已完整也只给占位（不在半路跑入场动画、不在流式中联网）（§10、R5 D3）
            switch card {
            case .chart, .music: if streaming { return .placeholder }   // ChatCardPlaceholder 默认「卡片生成中…」
            case .todo, .dice, .timer, .ask, .word, .timeline: break
            }
            return .card(card)
        }
        // 简写（```chart）解析不了多半就是普通代码：不给占位
        return streaming && lang.hasPrefix("card-") ? .placeholder : nil
    }

    /// nodeId = 卡片所在消息；nil（流式尾巴 / 文件库预览）时卡片只读
    static func view(language: String, code: String, nodeId: String?, streaming: Bool) -> AnyView? {
        switch kind(language: language, code: code, streaming: streaming) {
        case .html: return AnyView(HTMLCardView(content: code, nodeId: nodeId))
        case .htmlPlaceholder: return AnyView(ChatCardPlaceholder(label: "网页", text: "网页生成中…"))
        case .mermaid: return AnyView(MermaidCardView(code: code))
        case .mermaidPlaceholder: return AnyView(ChatCardPlaceholder(label: "图表", text: "图表生成中…"))
        case .card(.todo(let todo)): return AnyView(TodoCardView(card: todo, nodeId: nodeId))
        case .card(.dice(let dice)): return AnyView(DiceCardView(card: dice, nodeId: nodeId, streaming: streaming))
        case .card(.timer(let timer)): return AnyView(TimerCardView(card: timer, nodeId: nodeId, streaming: streaming))
        case .card(.chart(let chart)): return AnyView(ChartCardView(card: chart, nodeId: nodeId))
        case .card(.music(let music)): return AnyView(MusicCardView(card: music, nodeId: nodeId))
        case .card(.ask(let ask)): return AnyView(AskCardView(card: ask, nodeId: nodeId, streaming: streaming))
        case .card(.word(let word)): return AnyView(WordCardView(card: word, nodeId: nodeId))
        case .card(.timeline(let timeline)): return AnyView(TimelineCardView(card: timeline))
        case .placeholder: return AnyView(ChatCardPlaceholder())
        case nil: return nil
        }
    }

    /// 外链卡：定稿后才出；入口处再校验一次 http(s) + host（不只信渲染器）
    static func linkView(url: URL, label: String?, streaming: Bool) -> AnyView? {
        guard !streaming, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return AnyView(LinkCardView(url: url, label: label))
    }

    /// 气泡模式：这一块是已经写完（有收尾围栏）的网页块——不用等整条消息结束再出卡（TASK page1-卡片-05）。
    /// 图表 / 音乐仍按原设计等整条定稿（不在半路跑入场动画、不在流式中联网）
    static func isFinishedHTMLBlock(_ block: String) -> Bool {
        standaloneCardBlock(block)?.language.lowercased() == "html"
    }

    /// 一整块（去掉首尾空白）恰好是一个 card-* 或 html 围栏块时返回它的语言和内容
    static func standaloneCardBlock(_ block: String) -> (language: String, code: String)? {
        let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard lines.count >= 2, let first = lines.first, let last = lines.last,
              let open = MarkdownFenceTracker.fenceRun(first), let close = MarkdownFenceTracker.fenceRun(last),
              open.char == close.char, close.count >= open.count,
              last.dropFirst(close.count).allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        let language = first.dropFirst(open.count).trimmingCharacters(in: .whitespaces)
        let lang = language.lowercased()
        guard ChatCard.isCardLanguage(lang) || lang == "html" || lang == "mermaid" else { return nil }   // 网页块 / 图表块同卡片（§7.4）
        return (language, lines.dropFirst().dropLast().joined(separator: "\n"))
    }
}

extension View {
    /// 聊天正文统一注入（替代旧 htmlBlockRenderer）。nodeId 用于版本判定与交互；流式正文传 streaming: true。
    func chatCardRenderer(nodeId: String?, streaming: Bool = false) -> some View {
        self
            .environment(\.customBlockRenderer) { language, code in
                ChatCardRegistry.view(language: language, code: code, nodeId: nodeId, streaming: streaming)
            }
            .environment(\.standaloneLinkRenderer) { url, label in
                ChatCardRegistry.linkView(url: url, label: label, streaming: streaming)
            }
    }
}
