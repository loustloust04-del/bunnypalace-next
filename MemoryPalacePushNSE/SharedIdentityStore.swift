import Foundation

/// NSE 端读 App Group 共享的「chat → profile → AI 名字 + 头像」索引。
/// 写入端是主 app 的 PushIdentityWriter——这两边的 Codable 结构必须保持一致。
enum SharedIdentityStore {
    private static let appGroupId = "group.com.susu.MemoryPalace"

    private struct ChatIndex: Codable {
        var entries: [String: String]
        var lru: [String]
    }
    private struct ProfileCard: Codable {
        var name: String
        var hasAvatar: Bool
    }
    private struct ProfileCards: Codable {
        var entries: [String: ProfileCard]
    }

    struct Lookup {
        let assistantName: String
        let avatarData: Data?
    }

    /// 按 chat_id 反查楼层 AI 名字 + 头像。任何一步失败 → nil → NSE 走 fallback 用 hub 默认 title。
    static func lookup(chatId: String) -> Lookup? {
        guard !chatId.isEmpty else { return nil }
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let root = base.appendingPathComponent("push-identity", isDirectory: true)

        let indexURL = root.appendingPathComponent("chat-index.json")
        guard let indexData = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(ChatIndex.self, from: indexData),
              let profileId = index.entries[chatId] else { return nil }

        let cardsURL = root.appendingPathComponent("profile-cards.json")
        guard let cardsData = try? Data(contentsOf: cardsURL),
              let cards = try? JSONDecoder().decode(ProfileCards.self, from: cardsData),
              let card = cards.entries[profileId] else { return nil }

        var avatar: Data? = nil
        if card.hasAvatar {
            let avatarURL = root.appendingPathComponent("avatars/\(profileId).jpg")
            avatar = try? Data(contentsOf: avatarURL)
        }
        return Lookup(assistantName: card.name, avatarData: avatar)
    }
}
