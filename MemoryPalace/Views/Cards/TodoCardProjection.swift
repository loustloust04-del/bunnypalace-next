import Foundation
import Observation

/// 聊天待办卡 ↔ 真待办的关联（research-chat-cards §14）：按「对话 + 卡片 id」存，每项按文字对到 TodoItem 的 id。
/// 同 id 的新版本卡文字对得上就接着用；改了文字的算新项（旧关联留着不显示）。只存本机（同 TodoManager）
@MainActor
@Observable
final class ChatTodoLinkStore {
    static let shared = ChatTodoLinkStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var byCard: [String: [String: UUID]]

    init(defaults: UserDefaults = .standard, key: String = "chatTodoLinks.v1") {
        self.defaults = defaults
        self.storageKey = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [String: UUID]].self, from: data) {
            byCard = decoded
        } else {
            byCard = [:]
        }
    }

    /// 文字归一：去首尾空白（大小写原样，待办是中文为主）
    nonisolated static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cardKey(_ conversationId: String, _ cardId: String) -> String { "\(conversationId)|\(cardId)" }

    func links(conversationId: String, cardId: String) -> [String: UUID] {
        byCard[Self.cardKey(conversationId, cardId)] ?? [:]
    }

    func link(_ text: String, to id: UUID, conversationId: String, cardId: String) {
        byCard[Self.cardKey(conversationId, cardId), default: [:]][Self.key(text)] = id
        if let data = try? JSONEncoder().encode(byCard) { defaults.set(data, forKey: storageKey) }
    }
}

/// 卡上一项在真待办里的样子
enum TodoCardProjection {
    enum State: Equatable {
        /// 还没加进待办
        case unlinked
        /// 读真待办（勾选状态以它为准）
        case linked(TodoItem)
        /// 加过，但粟粟在日历里删掉了
        case removed
    }

    static func state(of item: TodoCard.Item, links: [String: UUID], todos: [TodoItem]) -> State {
        guard let id = links[ChatTodoLinkStore.key(item.text)] else { return .unlinked }
        return todos.first { $0.id == id }.map(State.linked) ?? .removed
    }
}

/// 粟粟在卡上点的动作：写真待办 + 记关联 + 捎带给模型（只有点了才写，模型写的卡不会自己写）
@MainActor
struct TodoCardActions {
    var todos: TodoManager = .shared
    var links: ChatTodoLinkStore = .shared
    var outbox: ChatCardEventOutbox = .shared

    /// 整张加入：只加还没关联的（删掉的也重新加）；日期 = 卡上的 date，没写就是今天；模型写成 done 的照样勾上。返回加了几项
    @discardableResult
    func addAll(_ card: TodoCard, conversationId: String, today: String) -> Int {
        guard let cardId = card.id, !cardId.isEmpty else { return 0 }
        let current = links.links(conversationId: conversationId, cardId: cardId)
        var added = 0
        for item in card.items {
            if case .linked = TodoCardProjection.state(of: item, links: current, todos: todos.items) { continue }
            if insert(item, cardId: cardId, date: card.date ?? today, conversationId: conversationId) { added += 1 }
        }
        if added > 0 {
            let title = card.title.isEmpty ? "" : "「\(card.title)」"
            outbox.add("把待办卡\(title)加进了我的待办（\(added) 项）", conversationId: conversationId)
        }
        return added
    }

    /// 关联后新冒出来的项，行尾「+」单独加
    func addOne(_ item: TodoCard.Item, card: TodoCard, conversationId: String, today: String) {
        guard let cardId = card.id, !cardId.isEmpty,
              insert(item, cardId: cardId, date: card.date ?? today, conversationId: conversationId) else { return }
        outbox.add("把「\(ChatTodoLinkStore.key(item.text))」加进了我的待办", conversationId: conversationId)
    }

    /// 已关联的卡上「加一项」：写真待办并关联（新版本卡照旧进输入框，模型从那里看到，不再捎带）
    func addNewItem(_ text: String, card: TodoCard, conversationId: String, today: String) {
        guard let cardId = card.id, !cardId.isEmpty else { return }
        _ = insert(.init(text: text, done: false), cardId: cardId, date: card.date ?? today, conversationId: conversationId)
    }

    /// 勾 / 取消勾真待办。同一项来回点，还没发出去的互相抵掉
    func toggle(_ id: UUID, text: String, conversationId: String) {
        guard let before = todos.items.first(where: { $0.id == id }) else { return }
        todos.toggle(id)
        let key = "todo:\(id.uuidString)"
        guard !outbox.remove(key: key, conversationId: conversationId) else { return }
        let name = ChatTodoLinkStore.key(text)
        outbox.add(before.done ? "把待办「\(name)」改回没做" : "勾掉了待办「\(name)」", conversationId: conversationId, key: key)
    }

    private func insert(_ item: TodoCard.Item, cardId: String, date: String, conversationId: String) -> Bool {
        guard let id = todos.add(item.text, date: date) else { return false }
        if item.done { todos.toggle(id) }
        links.link(item.text, to: id, conversationId: conversationId, cardId: cardId)
        return true
    }
}
