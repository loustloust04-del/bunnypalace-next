#if os(iOS)
import Foundation
import SwiftData

/// 喂给 web 的数据形状。**这是冻结的契约**——皮肤作者按 DOM 结构写 CSS，
/// DOM 由这些字段生成，改字段等于改契约。加字段安全，改/删字段要升协议版本。
///
/// P1 只有假数据；P2 从 `MessageNode` 映射（正则脚本在 Swift 侧跑完再进 `text`）。
struct ChatMessageDTO: Codable {
    let id: String
    let role: String            // user | assistant
    let text: String            // 正则脚本处理后的成品文本
    let time: String
    let name: String
    var avatarURL: String?      // mp-asset://avatar/…（P3 起）
    var attachments: [ChatAttachmentDTO] = []
    var thinking: String?
    var quoted: String?
    var branch: ChatBranchDTO?
    var isFavorite: Bool = false
    var isPinned: Bool = false
    /// "heartvoice" 等。v1 只落到 `data-kind` 让皮肤能选，不特殊渲染（心声推 v2）
    var kind: String?
    var streaming: Bool = false
    /// 卡库 ⑦：正文里有明确 HTML 时按段给（文本段 + HTML 段）；nil = 纯文本，走 `text`。
    /// `text` 始终是完整成品文本（旧 runtime / 皮肤的 fallback）；HTML 源码不进宿主 DOM，由原生 mp-card:// 发给 iframe
    var segments: [ChatSegmentDTO]?
    /// 段渲染器版本（MessageHTMLSegments.rendererVersion），segments 为 nil 时也为 nil
    var renderer: Int?
    /// 卡库第二批：被卡里的网页改过正文（`cardEditedAt`）→ 分支行后的「edited」+ 浮层说明
    var edited: ChatEditedDTO?
}

struct ChatEditedDTO: Codable, Equatable {
    /// 浮层第一行：这条消息被「卡名」的网页在 HH:mm 改过
    let title: String
    let note: String
}

/// 正文的一段。html 段只带 ID / 内容指纹 / 标题，内容本身留在原生
struct ChatSegmentDTO: Codable, Equatable {
    let id: String
    let kind: String            // text | html
    var text: String?           // 文本段正文
    var key: String?            // html 段内容指纹：变了 iframe 才换
    var title: String?          // html 段 <title>，没有为 nil（runtime 显示「网页」）
}

struct ChatAttachmentDTO: Codable {
    let id: String
    let kind: String            // image | file
    let name: String
    var url: String?            // mp-asset://msg/…（P3 起）
}

struct ChatBranchDTO: Codable {
    let index: Int
    let total: Int
}

struct ChatRenderPayload: Codable {
    var messages: [ChatMessageDTO]
    var theme: String           // light | dark
    var placeholder: String
}

// MARK: - MessageNode → DTO
//
// ⚠️ 这里**只读**主聊天的模型和工具（RegexEngine / ContentCleaner / segments），
// 不改它们任何一行。渲染口径尽量对齐 BubbleView，口径变了就在这里跟。

/// 发送一条消息需要的依赖。SwiftUI 的 @Environment 到不了 Coordinator，从 View 层灌进来。
struct ChatSendDeps {
    var profile: Profile?
    var preset: Preset?
    var providerManager: ProviderManager?
    var modelContext: ModelContext?
}

/// 一次渲染需要的上下文，省得每条消息都重新取一遍
struct ChatRenderContext {
    let regexScripts: [RegexScript]
    let userName: String
    let assistantName: String
    let showThinking: Bool
    let branchInfo: [String: BranchInfo]
    let streamingNodeId: String?
    /// 当前楼层绑定的卡名（「edited」浮层用）；nil = 非卡聊天 / 卡没了
    var cardName: String? = nil

    /// 长对话窗口化：只渲染最近 N 条（花园真有几千条的对话）。
    /// v1 不做完整虚拟列表——原生 CardFlowView 也没做，靠 LazyVStack。
    static let windowSize = 200
}

extension ChatMessageDTO {
    init(node: MessageNode, ctx: ChatRenderContext) {
        let isUser = node.role == "user"

        // ① 正则脚本在 Swift 侧跑完，web 只拿成品（口径抄 CardFlowView:3417）
        //    ⑤a：按角色分流（1 用户 / 2 AI；system / tool 不冒充 assistant），只跑显示阶段
        let placement = RegexPipeline.placement(forRole: node.role)
        //    正文里的 {{char}}/{{user}}（卡开场）先按显示副本展开，存储原文不动（③b，与原生气泡同源）
        let displayContent = EffectiveCharacterContext(charName: ctx.assistantName, userName: ctx.userName).expand(node.content)
        let raw = RegexPipeline.run(ctx.regexScripts, text: displayContent, phase: .display, placement: placement,
                                    userName: ctx.userName, charName: ctx.assistantName)

        // ② thinking 从正文里剥出来（user 消息不剥）
        let extracted = isUser ? nil : ContentCleaner.extractThinking(from: raw)
        let body = extracted?.content ?? raw
        let think: String? = {
            guard !isUser, ctx.showThinking else { return nil }
            let t = extracted?.thinking ?? node.ccThinking
            return (t?.isEmpty == false) ? t : nil
        }()

        // ③ 附件（口径抄 CardFlowView:3272）。P2 只给名字和类型，
        //    图片字节要等 P3 的 mp-asset:// 才喂得过去。
        // 图片按「第几张图」编号，URL 交给 ChatAssetSchemeHandler 按需取字节，
        // 不走 base64（大图撑爆 DOM + 每次重渲重编码）
        var imageIndex = 0
        let atts: [ChatAttachmentDTO] = (node.segments?.hydratedForDisplay(profileId: node.profileId) ?? [])
            .compactMap { seg -> ChatAttachmentDTO? in
                switch seg {
                case .image(let n, _, _):
                    defer { imageIndex += 1 }
                    return ChatAttachmentDTO(id: "\(node.id)#\(imageIndex)", kind: "image", name: n,
                                             url: "mp-asset://msg/\(node.id)/\(imageIndex)")
                case .attachment(let n, _, _):   return ChatAttachmentDTO(id: n, kind: "file", name: n)
                case .fileData(let n, _, _):     return ChatAttachmentDTO(id: n, kind: "file", name: n)
                default: return nil
                }
            }

        // ④ 引用条：优先落库的选段，老数据回退整条截断
        let quoted: String? = {
            if let rq = node.replyQuote, !rq.isEmpty { return String(rq.prefix(50)) }
            return nil
        }()

        let branch: ChatBranchDTO? = ctx.branchInfo[node.id].flatMap { info in
            guard info.branchCount > 1 else { return nil }
            return ChatBranchDTO(index: info.currentIndex, total: info.branchCount)
        }

        let kind: String? = {
            if node.contentType == "heartvoice" || node.content.hasPrefix("💭 心声\n\n") { return "heartvoice" }
            return nil
        }()

        // ⑤ 明确 HTML 切段（卡库 ⑦；只切显示副本，原文 / 发送不受影响）
        let segs = MessageHTMLSegments.split(body)

        self.init(
            id: node.id,
            role: isUser ? "user" : "assistant",
            text: body,
            time: node.createTime.map { Self.timeFormatter.string(from: $0) } ?? "",
            name: isUser ? ctx.userName : ctx.assistantName,
            avatarURL: "mp-asset://avatar/\(node.profileId)/\(isUser ? "user" : "ai")",
            attachments: atts,
            thinking: think,
            quoted: quoted,
            branch: branch,
            isFavorite: node.isFavorite,
            isPinned: node.isPinned,
            kind: kind,                     // v1 只落 data-kind，心声推 v2
            streaming: node.id == ctx.streamingNodeId,
            segments: segs.map { $0.map(ChatSegmentDTO.init) },
            renderer: segs == nil ? nil : MessageHTMLSegments.rendererVersion,
            edited: node.cardEditedAt.map { ChatEditedDTO(title: CardEditedText.title(cardName: ctx.cardName, at: $0), note: CardEditedText.note) }
        )
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// 结构指纹：id 序列变了（切分支/删除/新消息）就得整棵重渲，patchNode 表达不了
    static func structureFingerprint(_ nodes: [MessageNode]) -> Int {
        var h = Hasher()
        for n in nodes { h.combine(n.id) }
        return h.finalize()
    }

    /// 内容指纹：单条的可见字段变了就 patchNode（MessageNode 没有 updatedAt，只能自己算）
    var contentFingerprint: Int {
        var h = Hasher()
        h.combine(text); h.combine(thinking); h.combine(quoted)
        h.combine(isFavorite); h.combine(isPinned); h.combine(streaming)
        h.combine(branch?.index); h.combine(branch?.total)
        h.combine(attachments.count)
        for a in attachments { h.combine(a.url) }
        h.combine(renderer)             // 段来自 text，text 已进指纹；渲染器升版本也要重推
        h.combine(edited?.title)
        return h.finalize()
    }
}

extension ChatSegmentDTO {
    init(_ seg: MessageHTMLSegment) {
        switch seg.kind {
        case .text:
            self.init(id: seg.id, kind: "text", text: seg.content)
        case .html:
            self.init(id: seg.id, kind: "html", key: seg.key, title: HTMLCardView.pageTitle(seg.content))
        }
    }
}
#endif
