import Foundation
import Observation

/// 一条要捎带给模型的事件（research-chat-cards §13）：网页卡 `mp.report`、表情回应
struct ChatCardEvent: Codable, Equatable, Identifiable {
    let id: String
    /// 同 key 的新事件替换旧的（表情回应用 "reaction:<node>:<emoji>"，取消时按 key 撤）
    let key: String?
    let text: String
    let date: Date
    /// 送出去的那轮没落地（AI 不回 / 准备被取消），原样还回箱里的：只跟下一条消息走，不再单独触发回复（10-29 返工 #4）
    var carried: Bool? = nil

    init(id: String = UUID().uuidString, key: String? = nil, text: String, date: Date = Date()) {
        self.id = id
        self.key = key
        self.text = text
        self.date = date
    }
}

extension ChatCardEvent {
    /// 她看得见吗：`ai-reaction:` 开头的（AI 贴表情后记的那笔）只给模型看
    var isVisible: Bool { !(key?.hasPrefix("ai-reaction:") ?? false) }
}

/// 待捎带箱：按对话存在本机（UserDefaults），粟粟下次在这个对话发消息时整箱挂到那条用户消息上。
/// 输入框上方看得见、能删（§13.2）
@MainActor
@Observable
final class ChatCardEventOutbox {
    static let shared = ChatCardEventOutbox()
    static let maxPerConversation = 20

    private let defaults: UserDefaults
    private let key: String
    private(set) var byConversation: [String: [ChatCardEvent]]

    init(defaults: UserDefaults = .standard, key: String = "chatCardEvents.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [ChatCardEvent]].self, from: data) {
            byConversation = decoded
        } else {
            byConversation = [:]
        }
    }

    func events(for conversationId: String) -> [ChatCardEvent] { byConversation[conversationId] ?? [] }

    /// 输入框上方捎带卡显示的：AI 自己贴表情的记录照旧带给模型，但她看不见（粟粟 10-30）
    func visibleEvents(for conversationId: String) -> [ChatCardEvent] { events(for: conversationId).filter(\.isVisible) }

    func add(_ text: String, conversationId: String, key: String? = nil) {
        var list = events(for: conversationId)
        if let key { list.removeAll { $0.key == key } }
        list.append(ChatCardEvent(key: key, text: text))
        if list.count > Self.maxPerConversation { list.removeFirst(list.count - Self.maxPerConversation) }
        set(list, for: conversationId)
    }

    /// 归还没落地的事件：保留原身份和先后，插回最前（它们比箱里现有的都早）；
    /// 箱里同 key 已有更新的操作（比如「收回了」）或同一条已经在了，旧的不覆盖
    func restore(_ returned: [ChatCardEvent], conversationId: String) {
        var list = events(for: conversationId)
        let keys = Set(list.compactMap(\.key))
        let ids = Set(list.map(\.id))
        let back = returned.filter { e in !ids.contains(e.id) && !(e.key.map(keys.contains) ?? false) }.map { e -> ChatCardEvent in
            var carried = e
            carried.carried = true
            return carried
        }
        guard !back.isEmpty else { return }
        list = back + list
        if list.count > Self.maxPerConversation { list.removeFirst(list.count - Self.maxPerConversation) }
        set(list, for: conversationId)
    }

    /// 按 key 撤（还没发出去才撤得到）
    @discardableResult
    func remove(key: String, conversationId: String) -> Bool {
        var list = events(for: conversationId)
        let before = list.count
        list.removeAll { $0.key == key }
        guard list.count != before else { return false }
        set(list, for: conversationId)
        return true
    }

    func remove(id: String, conversationId: String) {
        var list = events(for: conversationId)
        list.removeAll { $0.id == id }
        set(list, for: conversationId)
    }

    /// 发消息时取走整箱
    func drain(_ conversationId: String) -> [ChatCardEvent] {
        let list = events(for: conversationId)
        if !list.isEmpty { set([], for: conversationId) }
        return list
    }

    private func set(_ list: [ChatCardEvent], for conversationId: String) {
        byConversation[conversationId] = list.isEmpty ? nil : list
        if let data = try? JSONEncoder().encode(byConversation) { defaults.set(data, forKey: key) }
    }
}

/// 拼给模型：放在这条用户消息正文（和引用块）前面。API 每轮从节点上拼，模型翻历史也看得见；CC 发的那一刻拼进 content
enum ChatCardEventPrompt {
    static func prefix(_ events: [ChatCardEvent]) -> String {
        guard !events.isEmpty else { return "" }
        return "[附带事件]\n" + events.map { "- \($0.text)" }.joined(separator: "\n") + "\n\n"
    }

    /// 只有事件、没有正文的那条（10-29 贴表情立刻触发的一轮）
    static func turnContent(_ events: [ChatCardEvent]) -> String {
        prefix(events).trimmingCharacters(in: .newlines)
    }
}

extension MessageNode {
    /// 这条用户消息捎带的事件（cardEventsData 的 JSON）
    var cardEvents: [ChatCardEvent] {
        get {
            guard let data = cardEventsData else { return [] }
            return (try? JSONDecoder().decode([ChatCardEvent].self, from: data)) ?? []
        }
        set {
            cardEventsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    /// 消息上显示的捎带事件（去掉只给模型看的）
    var visibleCardEvents: [ChatCardEvent] { cardEvents.filter(\.isVisible) }
}
