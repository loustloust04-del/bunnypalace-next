import Foundation

/// 聊天卡片的 vm 侧（docs/research-chat-cards.md §4.3–4.4）
extension ConversationViewModel {
    /// 同 id 的待发卡片原地替换（保留附件 id），否则追加（纯函数，便于测）。
    static func staging(_ card: ChatCard, into attachments: [PendingChatAttachment]) -> [PendingChatAttachment] {
        var result = attachments
        if let id = card.id, let index = result.firstIndex(where: { $0.chatCard?.id == id }) {
            var replacement = PendingChatAttachment.card(card)
            replacement.id = result[index].id
            result[index] = replacement
        } else {
            result.append(.card(card))
        }
        return result
    }

    /// 取消排队恢复附件：卡片按 id 合并，输入框里已有同 id（更新的那份）就不再放回（终审 #4）
    static func restoring(_ queued: [PendingChatAttachment], into attachments: [PendingChatAttachment]) -> [PendingChatAttachment] {
        var result = attachments
        for att in queued {
            if let id = att.chatCard?.id, result.contains(where: { $0.chatCard?.id == id }) { continue }
            result.append(att)
        }
        return result
    }

    /// 待发版本：输入框优先，其次排队里最后一份（终审 #4）
    static func pendingCard(id: String, staged: [PendingChatAttachment], queued: [[PendingChatAttachment]]) -> ChatCard? {
        if let card = staged.lazy.compactMap(\.chatCard).first(where: { $0.id == id }) { return card }
        for attachments in queued.reversed() {
            if let card = attachments.lazy.compactMap(\.chatCard).first(where: { $0.id == id }) { return card }
        }
        return nil
    }

    /// baseNodeId = 这次改动是在哪条消息的卡上点的（待发版本只叠回那张，终审 #5）
    func stageCard(_ card: ChatCard, baseNodeId: String?) {
        selectedAttachments = Self.staging(card, into: selectedAttachments)
        if let id = card.id { cardStagingBase[id] = baseNodeId }
    }

    /// §13 网页卡 mp.ask：放进输入框，粟粟自己点发送
    struct ComposerInsert: Equatable {
        let token = UUID()
        let conversationId: String
        let text: String
    }

    /// 表单卡提交即发（粟粟 10-03）：发的只有这张卡，输入框里的字和别的附件不动
    struct CardSendRequest: Equatable {
        let token = UUID()
        let conversationId: String
        let card: ChatCard
    }

    func sendCardNow(_ card: ChatCard, baseNodeId: String?) {
        guard let conversationId = selectedConversation?.id else { return }
        if let id = card.id {
            selectedAttachments.removeAll { $0.chatCard?.id == id }   // 之前放进输入框的同一张卡的旧版本不再跟着下一条走
            cardStagingBase[id] = baseNodeId
        }
        cardSendRequest = CardSendRequest(conversationId: conversationId, card: card)
    }

    func insertIntoComposer(_ text: String) {
        guard let id = selectedConversation?.id else { return }
        composerInsert = ComposerInsert(conversationId: id, text: text)
    }

    /// 空草稿直接放；有字就换一行接在后面（同取消排队写回）
    static func appending(_ text: String, to draft: String) -> String {
        draft.isEmpty ? text : draft + "\n" + text
    }

    func pendingCard(id: String) -> ChatCard? {
        let queued = pendingSends
            .filter { $0.conversationId == selectedConversation?.id }
            .map(\.attachments)
        return Self.pendingCard(id: id, staged: selectedAttachments, queued: queued)
    }
}

enum ChatCardStatus: Equatable { case live, stale, readOnly }

/// 卡片版本判定（research-chat-cards §4.3 / §6）
enum ChatCardIndex {
    struct Entry: Equatable {
        let nodeId: String
        let card: ChatCard
    }

    /// 屏幕上看得到的正文：分段消息取全部 .text 段，否则 content（不扫工具结果 / 思考 / 附件）
    static func visibleText(content: String, segments: [MessageSegment]?) -> String {
        guard let segments else { return content }
        let texts = segments.compactMap { seg -> String? in
            if case .text(let t) = seg { return t }
            return nil
        }
        return texts.isEmpty ? content : texts.joined(separator: "\n\n")
    }

    /// 每个 id → 路径上最后一条含它的消息 + 该消息里最后一张
    static func build(_ nodes: [(id: String, text: String)]) -> [String: Entry] {
        var map: [String: Entry] = [:]
        for node in nodes {
            for card in ChatCardExtractor.cards(in: node.text) {
                if let id = card.id { map[id] = Entry(nodeId: node.id, card: card) }
            }
        }
        return map
    }

    /// 待发版本只叠在它的底稿那张上；底稿不明（➕ 新建 / 取消排队恢复）时照旧叠
    static func showsPending(baseNodeId: String?, nodeId: String?) -> Bool {
        baseNodeId == nil || baseNodeId == nodeId
    }

    static func status(of card: ChatCard, nodeId: String?, index: [String: Entry]) -> ChatCardStatus {
        guard let id = card.id, let nodeId else { return .readOnly }
        guard let latest = index[id] else { return .live }
        return latest.nodeId == nodeId && latest.card == card ? .live : .stale
    }
}

/// 卡片索引的缓存（终审 #1）：每条消息一个廉价键（不碰外部存储的分段数据），
/// 键不变不重读正文；整条路径的键序列不变就直接复用上次的索引。
struct ChatCardIndexCache {
    struct Node {
        let id: String
        let key: Int
        let text: () -> String
    }

    private var texts: [String: (key: Int, text: String)] = [:]
    private var last: (signature: [String], index: [String: ChatCardIndex.Entry])?
    private(set) var builds = 0

    mutating func index(_ nodes: [Node]) -> [String: ChatCardIndex.Entry] {
        let signature = nodes.map { "\($0.id)#\($0.key)" }
        if let last, last.signature == signature { return last.index }
        var withCards: [(id: String, text: String)] = []
        for node in nodes {
            let text: String
            if let cached = texts[node.id], cached.key == node.key {
                text = cached.text
            } else {
                let visible = node.text()
                text = ChatCardExtractor.mightContainCard(visible) ? visible : ""
                texts[node.id] = (node.key, text)
            }
            if !text.isEmpty { withCards.append((node.id, text)) }
        }
        let index = ChatCardIndex.build(withCards)
        builds += 1
        last = (signature, index)
        return index
    }

    mutating func reset() {
        texts = [:]
        last = nil
    }
}

extension ConversationViewModel {
    /// 当前路径的卡片索引。消息键 = 正文长度 + 是否有分段（分段 JSON 只在键变时才读），
    /// 路径不变时整张索引复用。
    var cardIndex: [String: ChatCardIndex.Entry] {
        let nodes = currentPath.map { node in
            ChatCardIndexCache.Node(
                id: node.id,
                key: node.content.utf16.count &* 2 &+ (node.segmentsData == nil ? 0 : 1),
                text: {
                    node.segmentsData != nil
                        ? ChatCardIndex.visibleText(content: node.content, segments: node.segments)
                        : node.content
                })
        }
        return cardIndexCache.index(nodes)
    }

    func cardStatus(_ card: ChatCard, nodeId: String?) -> ChatCardStatus {
        ChatCardIndex.status(of: card, nodeId: nodeId, index: cardIndex)
    }
}

// MARK: - 计时器：数据层登记 + 跨窗口判忙（第 3 期终审修复）

extension ConversationViewModel {
    /// 所有窗口的 vm（弱引用；mac 每个窗口一个）
    static let liveInstances = NSHashTable<ConversationViewModel>.weakObjects()

    /// 任何一个窗口正在回复这个对话，或 CC 还在等它的回复
    static func isBusy(conversationId: String) -> Bool {
        liveInstances.allObjects.contains { vm in
            (vm.assistantTurnInFlight && vm.activeConversationId == conversationId)
                || vm.ccWaitingSince[conversationId] != nil
        }
    }

    /// 正文里要自动开始（有 id、autoStart）的计时器
    static func autoStartTimers(in text: String) -> [TimerCard] {
        ChatCardExtractor.cards(in: text).compactMap { card in
            guard case .timer(let timer) = card, timer.autoStart, card.id != nil else { return nil }
            return timer
        }
    }

    /// 回复写完 / CC 回复落地时登记（不依赖卡片渲染）；测试宿主里不碰生产 store
    func registerAutoStartTimers(nodeId: String, conversationId: String, text: String, sentAt: Date) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        let timers = Self.autoStartTimers(in: text)
        guard !timers.isEmpty else { return }
        Task { @MainActor in
            for timer in timers {
                guard let id = ChatCard.timer(timer).id else { continue }
                TimerCardStore.shared.registerAutoStart(
                    key: TimerCardStore.key(conversationId: conversationId, nodeId: nodeId, cardId: id),
                    conversationId: conversationId, nodeId: nodeId, card: timer, sentAt: sentAt)
            }
        }
    }
}
