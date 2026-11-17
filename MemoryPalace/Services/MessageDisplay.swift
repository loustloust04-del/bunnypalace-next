import Foundation
import MemoryCore

/// 「一条消息在对话列表里显示成什么」的唯一出处（docs/plan-重构.md §3.5）。只产出数据，不认识界面。
/// 旧页 `BubbleView` 和新页 `TranscriptProjection` 都照这里的结果画——要改「什么情况画什么」只改这里。
/// 还没收进来的：气泡模式的正文、气泡外围（附件条 / 引用条 / 用量 / 分支…）、复制 / 查找 / 朗读 / 导出这些出口。
enum MessageDisplay {
    /// 气泡以外的骨架，两种模式共用：整条是不是系统胶囊、气泡画不画、气泡下面挂哪种结尾胶囊
    struct Frame: Equatable {
        struct SystemCapsule: Equatable {
            let text: String
            let isError: Bool
        }

        enum Tail: Equatable {
            case error(String)
            case notice(String)
            case outcome(ReplyOutcome)
        }

        /// role == system：整条只画一个胶囊，下面两项不用看
        var system: SystemCapsule?
        /// false = 只剩报错 / 已停止，不画空气泡
        var hasBody = true
        var tail: Tail?
    }

    /// 文章模式气泡里的正文是哪一种
    enum ArticleBody: Equatable {
        /// Markdown 正文；`thinking` 有值 = 正文上面一条「思考过程」。AI 的正文为空就只画思考
        case markdown(String, thinking: String?)
        /// 流式中的 AI 回复：正文不在消息里，在流式缓冲里
        case streaming
        /// 按段画（工具、思考、图片、导入的分段消息）
        case segments([MessageSegment])
        /// 她的纯语音条：不画文字气泡，只画胶囊 + 转文字
        case userVoiceNote
        case heartvoice(String)
        case meme(UUID)
        /// 她的消息只有附件段：气泡里没东西
        case empty
    }

    /// 文章模式要用到的显示设置和名字
    struct Context {
        var scripts: [RegexScript]
        var userName: String
        var charName: String
        /// 设置里的「显示 CC 思考」
        var showCCThinking: Bool
    }

    static func frame(of node: MessageNode, isStreaming: Bool) -> Frame {
        if node.role == "system" {
            return Frame(system: .init(text: node.content, isError: node.content.hasPrefix("⚠")))
        }
        let legacy = node.usesLegacyErrorMarker
        let segments = ChatDisplaySnapshot.segments(of: node)
        var error: String?
        var notice: String?
        if node.role != "user" {
            let content = ChatSystemMessage.split(node.content, legacy: legacy)
            var lastSegment: ChatSystemMessage.Content?
            if case .text(let text)? = segments?.last { lastSegment = ChatSystemMessage.split(text, legacy: legacy) }
            error = lastSegment?.error ?? content.error
            notice = lastSegment?.notice ?? content.notice
        }

        var frame = Frame()
        if let error {
            frame.tail = .error(error)
        } else if let notice {
            frame.tail = .notice(notice)
        } else if let raw = node.replyOutcome, let outcome = ReplyOutcome(rawValue: raw), outcome.isAbnormal {
            frame.tail = .outcome(outcome)
        }
        if !isStreaming, error != nil || notice != nil {
            if let segments, !segments.isEmpty {
                // 普通回复挂思考：正文看 content；只剩报错 / 已停止时只画思考行，思考隐藏就整个不画
                if segments.isAttachedThinkingReply {
                    frame.hasBody = !ChatSystemMessage.split(node.content, legacy: legacy).body.isEmpty
                        || (segments.attachedThinkingText != nil && DisclosureKind.thinking.mode != .hidden)
                } else {
                    frame.hasBody = !ChatSystemMessage.removingTrailingError(from: segments, legacy: legacy).isEmpty
                }
            } else {
                frame.hasBody = !ChatSystemMessage.split(node.content, legacy: legacy).body.isEmpty
            }
        }
        return frame
    }

    /// `streamsLive` = 这条正在流式、而且调用方接得上流式缓冲（旧页：有 viewModel）
    static func articleBody(of node: MessageNode, isStreaming: Bool, streamsLive: Bool, context: Context) -> ArticleBody {
        if let memeId = MemeToken.match(node.content) { return .meme(memeId) }
        let segments = ChatDisplaySnapshot.segments(of: node)
        func display() -> MessageDisplayText.Result {
            MessageDisplayText.make(node.content, role: node.role, scripts: context.scripts, userName: context.userName,
                                    charName: context.charName, cacheKey: node.id,
                                    legacyErrorMarker: node.usesLegacyErrorMarker)
        }

        if node.role == "user" {
            guard let segments, !segments.isEmpty else { return .markdown(display().body, thinking: nil) }
            let isComplex = segments.contains { segment in
                switch segment {
                case .text, .image, .imageRef, .attachment, .audioRef: return false
                default: return true
                }
            }
            if isComplex { return .segments(segments) }
            let typed = segments.compactMap { segment -> String? in
                if case .text(let text) = segment { return text }
                return nil
            }.joined(separator: "\n\n")
            if !typed.isEmpty {
                // 用户消息也跑显示规则，只改显示副本
                let text = RegexPipeline.run(context.scripts, text: typed, phase: .display,
                                             placement: RegexPipeline.userPlacement,
                                             userName: context.userName, charName: context.charName)
                return .markdown(text, thinking: nil)
            }
            return segments.userVoiceNote ? .userVoiceNote : .empty
        }

        // 老消息兼容：早期把「💭 心声」前缀塞在 content 里、contentType 还是 text
        let heartPrefix = "💭 心声\n\n"
        if node.contentType == "heartvoice" { return .heartvoice(node.content) }
        if node.content.hasPrefix(heartPrefix) { return .heartvoice(String(node.content.dropFirst(heartPrefix.count))) }
        // 只挂语音条 / 只挂原生思考的回复不算分段，正文照走下面
        if let segments, segments.hasRenderableSegments { return .segments(segments) }
        if streamsLive { return .streaming }

        let shown = display()
        // 思考从哪来：正文里的 [thinking] 标签 → CC 回传的思考链 → 原生思考摘要（回复完成后才有）
        let thinking = shown.thinking ?? (context.showCCThinking ? node.ccThinking : nil)
            ?? (isStreaming ? nil : segments?.nativeThinkingText)
        // AI 发的表情包只在气泡里画图；文章模式（切过模式的老对话）显示成〖表情包：名字〗
        let body = MemeIntentWriter.textForm(shown.body, detail: false) { MemeStore.fetch($0, in: node.modelContext) }
        return .markdown(body, thinking: thinking.flatMap { $0.isEmpty ? nil : $0 })
    }
}
