import Foundation
import Observation

/// 一条要捎带给模型的事件（research-chat-cards §13）：网页卡 `mp.report`、表情回应
struct ChatCardEvent: Codable, Equatable, Identifiable {
    let id: String
    /// 同 key 的新事件替换旧的（表情回应用 "reaction:<node>:<emoji>"，取消时按 key 撤）
    let key: String?
    let text: String
    let date: Date

    init(id: String = UUID().uuidString, key: String? = nil, text: String, date: Date = Date()) {
        self.id = id
        self.key = key
        self.text = text
        self.date = date
    }
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

    func add(_ text: String, conversationId: String, key: String? = nil) {
        var list = events(for: conversationId)
        if let key { list.removeAll { $0.key == key } }
        list.append(ChatCardEvent(key: key, text: text))
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
}
