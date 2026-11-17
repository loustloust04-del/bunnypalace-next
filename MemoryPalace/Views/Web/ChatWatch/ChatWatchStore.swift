import Foundation

/// 一起看小窗（docs/plan-chat-watch-together.md W1）：每个对话记自己的小窗——开没开、在看哪个网址、小窗多高、视频播到哪。
/// 存 UserDefaults，最多留最近 50 个对话。
struct ChatWatchState: Codable, Equatable {
    var open: Bool
    var url: String?
    var height: Double
    /// 视频播到哪（秒），W2 写；切回这个对话时跳回去
    var position: Double?
    var updatedAt: Date
}

enum ChatWatchStore {
    static let key = "chatWatch.v1"
    static let limit = 50
    static let defaultHeight: Double = 220

    static func load(_ conversationId: String, defaults: UserDefaults = .standard) -> ChatWatchState? {
        all(defaults)[conversationId]
    }

    static func save(_ state: ChatWatchState?, for conversationId: String, defaults: UserDefaults = .standard) {
        var map = all(defaults)
        map[conversationId] = state
        if map.count > limit {
            let keep = map.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(limit)
            map = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: key) }
    }

    static func all(_ defaults: UserDefaults = .standard) -> [String: ChatWatchState] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: ChatWatchState].self, from: data) else { return [:] }
        return map
    }
}
