import Foundation
import SwiftData

@Model
final class Conversation {
    #Index<Conversation>(
        [\.profileId],
        [\.profileId, \.lastOpenedAt],
        [\.profileId, \.isTrashed, \.lastOpenedAt]
    )

    @Attribute(.unique) var id: String
    /// 楼层隔离。路线 B 单 ModelContainer 下所有 fetch 必须带 profileId predicate。
    /// 新建时必填；迁移老数据时补填。默认 "" 只为 SwiftData lightweight migration。
    var profileId: String = ""
    var title: String
    var createTime: Date
    var updateTime: Date
    var currentNodeId: String
    var isFavorite: Bool = false
    var folderId: String?

    /// 列表置顶时间，nil = 未置顶。默认排序按它浮顶（DESC 时 SQLite NULL 垫底）；
    /// 回收站/搜索筛选不浮。可选列走 lightweight migration。
    var pinnedAt: Date? = nil
    var isPinned: Bool { pinnedAt != nil }

    /// AI 主动消息未读数（insertProactiveAssistantMessage 落到非当前对话时 +1，
    /// loadConversation 打开时清零）。默认值走 lightweight migration。
    var unreadCount: Int = 0

    var nodeCount: Int = 0
    var lastOpenedAt: Date?

    /// ⚠️ 框架保留名：`isDeleted` 与 NSManagedObject.isDeleted 冲突，显式 save() 会被
    /// 框架逆转回 false（research-isDeleted-clash.md）。业务一律用 isTrashed/trashedAt。
    /// 老字段保留：兼容 lightweight migration 老数据库；UnifiedContainerMigration 启动期
    /// 把 isDeleted=true 的搬到 isTrashed=true，再把 isDeleted=false 把框架脏值清掉。
    /// 等几个稳定版本后再彻底删 isDeleted/deletedAt 字段。
    var isDeleted: Bool = false
    var deletedAt: Date?

    /// 业务态：是否在回收站。所有产品逻辑读写这个字段，不再用 isDeleted。
    var isTrashed: Bool = false
    var trashedAt: Date?

    /// "chatgpt", "claude", "gemini", "aistudio", "rikkahub", "kelivo"（导入的归档，见 `importedProviders`）, "api", "sillytavern"
    var provider: String = "chatgpt"

    /// Links to ImportRecord.id for batch undo
    var importBatchId: UUID?

    /// 记忆参与开关（默认 true）
    /// false = 此对话不贡献记忆到楼层池，也不接收记忆注入
    var memoryEnabled: Bool = true

    /// cc-bridge L2：绑定到哪个 tmux/CC session。nil = 默认 "mp-cc"
    /// 只在 provider == "cc-bridge" 的对话上有意义；其它 provider 此字段忽略。
    /// spawn 出来的 mp-cc-N 不带 --continue，无跨重启历史 continuity。
    var ccBridgeSessionName: String? = nil

    /// 该对话当前选中的模型 combinedId（providerId+modelId）。
    /// "" = 没单独选过，回退全局 selectedChatModel。手动切/发送时写入。
    var selectedModelId: String = ""

    /// 该对话当前选中的写作风格 id（WritingStyle.id）。"" = 无风格（Normal，不注入）。
    /// 选一次持续生效，发送时拼到最后一条 user message 末尾，历史轮不复读。
    var currentStyleId: String = ""

    /// 本对话启用的 MCP server id 列表。（MCP 已改全局生效，此字段保留不再读，仅为 SwiftData schema 兼容）
    var mcpServerIds: [String] = []

    /// 权限 askOnce 的对话级授权记录（"domain:allow,domain:deny" 逗号串，PermissionGrants 编解码）。
    /// "" = 本对话没问过任何域。字符串而非数组：SwiftData 加最简字段（agentOrigin 先例）。
    var permGrantsRaw: String = ""

    /// 输入框草稿（跨重启）。切对话/进后台时写入，发送后清空。
    var draftText: String = ""
    /// 草稿附件，JSON 编码的 [PendingChatAttachment]。externalStorage 因为含图片/文件 blob。
    @Attribute(.externalStorage) var draftAttachmentsData: Data? = nil
    /// 草稿引用（跨重启）：预览文字 + reply_to 目标 id。"" = 没引用。
    var draftQuotePreview: String = ""
    var draftQuoteReplyTo: String = ""

    /// 分支选择表（卡库 ③b）：JSON `[父 id: 选中孩子 id]`，BranchSelection 编解码。
    /// nil = 旧对话还没生成 / 没有分叉。currentNodeId 是它派生出的路径末端缓存。
    var branchSelectionData: Data? = nil

    /// 卡库 ⑧c：本对话用的身份（UserPersonaStore id）。nil = 没指定，回退楼层 / Profile 身份文本
    var personaId: String? = nil
    /// 卡库 ⑧c：归档类型。nil = 普通对话；"groupReadOnly" = 酒馆群聊只读归档（不续聊、不进记忆）
    var archiveKind: String? = nil
    /// 卡库 ⑧c：导入来源 / 元数据（JSON：来源、相对路径、header 原件等），不参与显示和发送
    @Attribute(.externalStorage) var sourceMetadata: Data? = nil
    /// 卡库第二批 B4：卡里网页的 chat 变量（JSON 对象）。nil = 还没写过，读时从 sourceMetadata 的 header.chat_metadata.variables 惰性取
    @Attribute(.externalStorage) var cardVariablesData: Data? = nil

    init(id: String, title: String, createTime: Date, updateTime: Date, currentNodeId: String, provider: String = "chatgpt", profileId: String = "") {
        self.id = id
        self.title = title
        self.createTime = createTime
        self.updateTime = updateTime
        self.currentNodeId = currentNodeId
        self.provider = provider
        self.profileId = profileId
    }
}

extension Conversation {
    static let groupReadOnlyArchive = "groupReadOnly"

    /// 只读归档（群聊首批）：不续聊、不重生成
    var isReadOnlyArchive: Bool { archiveKind == Self.groupReadOnlyArchive }

    /// 不在显示路径上的追加（后台 / 别的对话）：新节点接在 parentId 下，父有多个孩子时把它记成选中，
    /// 否则选择表还指着旧孩子，重开会回到旧分支
    func recordBranchChoice(parentId: String, childId: String, parentChildCount: Int) {
        guard parentChildCount > 1 else { return }
        var selection = BranchSelection.decode(branchSelectionData)
        guard selection[parentId] != childId else { return }
        selection[parentId] = childId
        branchSelectionData = BranchSelection.encode(selection)
    }
}

@Model
final class MessageNode {
    #Index<MessageNode>(
        [\.profileId],
        [\.profileId, \.conversationId],
        [\.profileId, \.conversationId, \.isTrashed]
    )

    @Attribute(.unique) var id: String
    /// 楼层隔离。Migration 会给老数据补填。注：MessageNode 用 parentId: String? 做树
    /// 关系，不是 @Relationship —— migration 时 1-pass copy 即可，无需 2-pass。
    var profileId: String = ""
    var isSyntheticRoot: Bool = false
    var role: String            // user, assistant, system, tool
    var content: String
    var contentType: String     // text, code, multimodal_text, segmented 等
    var createTime: Date?
    var parentId: String?
    var childrenIds: [String] = []
    var conversationId: String

    var isFavorite: Bool = false
    var isPinned: Bool = false
    var pinnedAt: Date? = nil
    /// ⚠️ 框架保留名（见 Conversation.isDeleted 同样注释）。业务一律用 isTrashed/trashedAt。
    var isDeleted: Bool = false
    var deletedAt: Date?
    var isTrashed: Bool = false
    var trashedAt: Date?

    /// 结构化分段（Claude importer v2 写入）。JSON 编码的 [MessageSegment]。
    /// 为 nil 时消息按旧路径渲染（基于 content 字符串 + extractThinking）。
    @Attribute(.externalStorage) var segmentsData: Data?

    /// A4：hub 给 CC 消息的可见 id（s_…），用于 edit_message / reply_to 引用定位。nil = 非 CC 消息或老数据。
    var ccMessageId: String? = nil
    /// A4：本消息引用的消息 id（user 的 MessageNode.id 或别的 ccMessageId）。
    var replyToId: String? = nil
    /// 引用的选段文本（浮条选段引用；组装时注入给 AI + 气泡引用条精准显示）。nil = 老数据/无引用。
    var replyQuote: String? = nil
    /// A4：是否被 edit_message 改过（气泡右下角显示「edited」）。
    var ccEdited: Bool = false

    /// 发送时快照的写作风格 id（WritingStyle.id）。仅 user 节点有意义，仅气泡 chip 显示用，
    /// 不参与注入。快照而非实时，历史 chip 不随当前 style 切换而变。nil = 发送时无风格。
    var styleIdSnapshot: String? = nil
    /// 思考链回传：CC 当轮 thinking（Stop hook 经 hub 锚定到本消息）。nil = 无/老数据。
    var ccThinking: String? = nil

    // 每轮 usage 落盘（assistant 节点，可选=旧数据无值；语义已归一化：prompt 含缓存部分）
    var usagePromptTokens: Int? = nil
    var usageCompletionTokens: Int? = nil
    var usageCacheReadTokens: Int? = nil   // >0 即「命中」（new-api 判定法）
    var usageCacheWriteTokens: Int? = nil  // Anthropic 独有
    var usageCostUSD: Double? = nil        // 显示用 cache-aware 费用，不参与预算
    var usageSavedUSD: Double? = nil       // 缓存命中省下的钱（read × 0.9 × 单价），仪表盘聚合用

    // M7 图片转述：图片name → 80字描述（旧图换文字省 token），可选列轻量迁移
    var imageDescsData: Data? = nil

    /// 思考过程的一句话总结（小模型生成，plan-thinking-branch）；nil = 还没有。可选列轻量迁移
    var thinkingSummary: String? = nil
    /// 主对话工具组摘要：[内容指纹: 一句话]，可选列兼容旧库。
    var toolSummariesData: Data? = nil

    var toolSummaries: [String: String] {
        get { toolSummariesData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        set { toolSummariesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// M3-B 读书功能：消息来自哪本书/章/笔记的锚点。
    /// 格式：`"<safeName>#chapter<N>"` 或 `"<safeName>#chapter<N>#<noteId>"`。
    /// nil = 普通对话消息。可选列轻量迁移，零成本。主聊天 UI 看到带这字段的消息可挂"📖 书名·第N章" tag。
    var bookRef: String? = nil

    /// 联网搜索（Anthropic server-side web_search_tool_result 解析出来的 sources）。
    /// JSON 编码的 [WebSearchSource]。assistant 气泡底部 chip 横排引用源时读这个。
    /// nil = 没用联网搜索 / 老消息，无 chip。
    var webSourcesData: Data? = nil

    /// AUTONOMY：本消息来自自主 agent outbox 时的来源 uuid（drain 查重 + 将来轻标记用）。
    /// nil = 普通消息。D1 已定：agent 消息与普通消息同待遇，v1 不渲染特殊 UI。
    /// optional 轻量迁移安全（B11 版本化基线立起来之前不再动 schema）。
    var agentOrigin: String? = nil

    /// 召回可见性：本轮注入命中的记忆（volatile 层）。JSON 编码的 [InjectionHit]，含用户 👍/👎 状态。
    /// nil = 老消息 / 无命中 / 卡片诞生前的数据，不渲染卡片。
    var recallHitsData: Data? = nil

    /// 卡库 ⑧c：导入来源 / metadata（JSON：候选 raw、swipe_info、源 swipe 原文、variables 等），只存不执行
    @Attribute(.externalStorage) var sourceMetadata: Data? = nil
    /// 卡库 ⑧c：源可见性（SillyTavernMessageVisibility rawValue）。nil = 普通；hidden / uiSystem 不进显示、记忆、API
    var sourceVisibility: String? = nil
    /// 卡库第二批 B4：卡里网页的 message 变量（JSON 对象，每个候选节点一份）。nil = 还没写过，读时从选中候选的 variables[i] 惰性取
    @Attribute(.externalStorage) var cardVariablesData: Data? = nil
    /// 卡库第二批 B4：正文被卡里网页改过的时间；有值就挂「网页改过」标记（UI 等小样定稿）
    var cardEditedAt: Date? = nil

    /// 网页卡事件 / 表情回应捎带（research-chat-cards §13）：发送时从待捎带箱取走的 [ChatCardEvent] JSON。
    /// nil = 没捎带。拼上下文时放在这条用户消息正文前面
    var cardEventsData: Data? = nil

    /// 源里隐藏的消息（酒馆 /hide、界面提示）：和合成根一样不进显示 / 记忆 / API
    var isSourceHidden: Bool { sourceVisibility == "hidden" || sourceVisibility == "uiSystem" }

    // Computed: has branches (more than 1 child)
    var hasBranches: Bool {
        childrenIds.count > 1
    }

    var branchCount: Int {
        childrenIds.count
    }

    /// 解码 segmentsData。nil 表示这是旧数据 / 非 Claude v2 导入的节点。
    var segments: [MessageSegment]? {
        guard let data = segmentsData else { return nil }
        return try? JSONDecoder().decode([MessageSegment].self, from: data)
    }

    /// 是否「有可显示内容」——文字非空 **或** 带 segment（图/文件附件）。
    /// 用于树重建/显示过滤：CC 发来的纯附件消息 content 为空，不能被当空节点丢掉。
    /// （segmentsData 为 NULL 时读取很便宜，不会加载外部 blob。）
    var hasDisplayableContent: Bool {
        !isSyntheticRoot && !isSourceHidden && (!content.isEmpty || segmentsData != nil)
    }

    /// M7 图片转述描述表
    var imageDescs: [String: String] {
        imageDescsData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// 联网搜索 sources（Anthropic server tool 解出来的）
    var webSources: [WebSearchSource] {
        webSourcesData.flatMap { try? JSONDecoder().decode([WebSearchSource].self, from: $0) } ?? []
    }

    func setWebSources(_ sources: [WebSearchSource]) {
        webSourcesData = sources.isEmpty ? nil : (try? JSONEncoder().encode(sources))
    }

    /// 召回卡片命中（volatile 层）
    var recallHits: [InjectionHit] {
        recallHitsData.flatMap { try? JSONDecoder().decode([InjectionHit].self, from: $0) } ?? []
    }

    func setRecallHits(_ hits: [InjectionHit]) {
        recallHitsData = hits.isEmpty ? nil : (try? JSONEncoder().encode(hits))
    }

    func setImageDesc(_ desc: String, for name: String) {
        var d = imageDescs
        d[name] = desc
        imageDescsData = try? JSONEncoder().encode(d)
    }

    /// 一次写入分段数组。内联附件（.image/.fileData）统一外置到文件库存 ref（附件一份存储）；
    /// 落盘失败保持内联不丢数据。幂等，tool loop 每轮重复调用安全。
    /// conversationTitle 只是目录名的可读糖，nil 时复用已有目录或建 untitled。
    func setSegments(_ segs: [MessageSegment], conversationTitle: String? = nil) {
        // [Bunny patch BP-002] 正文段里的 [thinking]…[/thinking] 拆成 .thinking 段：显示走思考折叠，工具回合不把思考当正文回传
        let segs: [MessageSegment] = segs.flatMap { seg -> [MessageSegment] in
            guard case .text(let t) = seg, t.range(of: "[thinking]", options: .caseInsensitive) != nil else { return [seg] }
            let ex = ContentCleaner.extractThinking(from: t)
            var out: [MessageSegment] = []
            if let th = ex.thinking { out.append(.thinking(text: th, signature: nil)) }
            if !ex.content.isEmpty { out.append(.text(ex.content)) }
            return out
        }
        let externalized = AttachmentStore.externalize(
            segs,
            conversationId: conversationId,
            conversationTitle: conversationTitle,
            profileId: profileId
        )
        self.segmentsData = try? JSONEncoder().encode(externalized)
    }

    init(id: String, role: String, content: String, contentType: String,
         createTime: Date?, parentId: String?, childrenIds: [String], conversationId: String,
         profileId: String = "") {
        self.id = id
        self.role = role
        self.content = content
        self.contentType = contentType
        self.createTime = createTime
        self.parentId = parentId
        self.childrenIds = childrenIds
        self.conversationId = conversationId
        self.profileId = profileId
    }
}

@Model
final class UserCard {
    #if os(iOS)
    #Index<UserCard>(
        [\.profileId],
        [\.profileId, \.attachedToNodeId]
    )
    #endif

    var id: UUID = UUID()
    /// 楼层隔离。新建角色卡必填。
    var profileId: String = ""
    var content: String = ""
    var imageData: Data?
    var attachedToNodeId: String?
    var positionX: Double = 0
    var positionY: Double = 0
    var createTime: Date = Date()

    init(content: String = "", attachedToNodeId: String? = nil, profileId: String = "") {
        self.content = content
        self.attachedToNodeId = attachedToNodeId
        self.profileId = profileId
    }
}

extension Conversation {
    /// 从别家导出包导进来的归档（对话列表 / 日历的归档图标、导入历史的来源名都看这里）
    static let importedProviders: Set<String> = ["chatgpt", "claude", "gemini", "aistudio", "rikkahub", "kelivo"]

    static func importedProviderName(_ provider: String) -> String? {
        switch provider {
        case "chatgpt": return "ChatGPT"
        case "claude": return "Claude"
        case "gemini": return "Gemini"
        case "aistudio": return "AI Studio"
        case "rikkahub": return "RikkaHub"
        case "kelivo": return "Kelivo"
        default: return nil
        }
    }
}
