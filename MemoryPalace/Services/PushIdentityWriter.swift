#if os(iOS)
import Foundation
import SwiftData

/// App Group 共享的「chat → profile → AI 名字 + 头像」轻量索引。
/// NSE（Notification Service Extension）按 chat_id 反查 → 改写推送 title 和 sender 头像。
/// 这里只负责**写**，NSE 端有独立的 SharedIdentityStore 负责**读**。
///
/// 数据形态（落盘在 group.com.susu.MemoryPalace/push-identity/）：
/// - chat-index.json     { entries: {chatId: profileId}, lru: [chatId, ...] }
/// - profile-cards.json  { entries: {profileId: {name, hasAvatar}} }
/// - avatars/<profileId>.jpg  楼层 AI 头像（assistantAvatarData 原图）
///
/// LRU 上限 2000：超出从头部剔；陈年 chat 推送来 → NSE 查不到 → fallback hub 默认 title（"助手"）。
enum PushIdentityWriter {
    static let appGroupId = "group.com.susu.MemoryPalace"
    static let chatIndexLimit = 2000
    /// lp0929-R3：0 恢复完整实体 fetch；查询时点、主 context、排序和队列 FIFO 不变。
    static let launchProjectedFetch = ProcessInfo.processInfo.environment["MP_LAUNCH_PUSH_PROJECTION"] != "0"

    private static let queue = DispatchQueue(label: "push-identity-writer", qos: .utility)

    // MARK: - Paths

    private static var rootURL: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            // App Group 没配 → 静默；NSE 也读不到 → 自然 fallback hub 默认 title
            return nil
        }
        let dir = base.appendingPathComponent("push-identity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var chatIndexURL: URL? { rootURL?.appendingPathComponent("chat-index.json") }
    private static var profileCardsURL: URL? { rootURL?.appendingPathComponent("profile-cards.json") }

    private static var avatarsDir: URL? {
        guard let root = rootURL else { return nil }
        let dir = root.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func avatarURL(profileId: String) -> URL? {
        avatarsDir?.appendingPathComponent("\(profileId).jpg")
    }

    // MARK: - Data shapes (NSE 端 SharedIdentityStore 必须用同样 Codable 结构)

    struct ChatIndex: Codable {
        var entries: [String: String] = [:]
        var lru: [String] = []
    }
    struct ProfileCard: Codable {
        var name: String
        var hasAvatar: Bool
    }
    struct ProfileCards: Codable {
        var entries: [String: ProfileCard] = [:]
    }

    // MARK: - Public API

    /// 楼层 create / 改名 / 换头像后调。覆盖 profile-cards.json 该 profileId 条目，重写头像文件。
    static func upsertProfile(_ profile: Profile) {
        let id = profile.id
        let name = profile.assistantName
        // Canonical AI 头像取值跟 AIProfileSheet.swift:29 对齐：
        // assistantAvatarData 覆盖（设置-通用上传的）→ coverImageData 默认（角色卡封面）
        let avatarData = profile.assistantAvatarData ?? profile.coverImageData

        queue.async {
            var cards = readProfileCards()
            cards.entries[id] = ProfileCard(name: name, hasAvatar: avatarData != nil)
            writeProfileCards(cards)

            if let data = avatarData, let url = avatarURL(profileId: id) {
                try? data.write(to: url, options: .atomic)
            } else if let url = avatarURL(profileId: id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func removeProfile(id: String) {
        queue.async {
            var cards = readProfileCards()
            cards.entries.removeValue(forKey: id)
            writeProfileCards(cards)
            if let url = avatarURL(profileId: id) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// proactive message 落到某 chat / cc-bridge 会话被激活时调。
    /// 写入 chat-index.json + 把 chatId 推到 LRU 末尾，超 limit 从头剔。
    static func touchConversation(chatId: String, profileId: String) {
        guard !chatId.isEmpty, !profileId.isEmpty else { return }
        queue.async {
            var index = readChatIndex()
            index.entries[chatId] = profileId
            index.lru.removeAll(where: { $0 == chatId })
            index.lru.append(chatId)
            while index.lru.count > chatIndexLimit {
                let dead = index.lru.removeFirst()
                index.entries.removeValue(forKey: dead)
            }
            writeChatIndex(index)
        }
    }

    static func removeConversation(chatId: String) {
        guard !chatId.isEmpty else { return }
        queue.async {
            var index = readChatIndex()
            index.entries.removeValue(forKey: chatId)
            index.lru.removeAll(where: { $0 == chatId })
            writeChatIndex(index)
        }
    }

    /// 启动期一次性全量 dump：所有 provider 的 conversation 按 lastOpenedAt 倒序取 limit 个，
    /// 一次性塞进 chat-index.json。覆盖式写，不增量。
    @MainActor
    static func rebuildFromContext(_ context: ModelContext, limit: Int = chatIndexLimit) {
        // 不再 filter cc-bridge —— 任何 provider 的 chat 都可能收到 hub APNs 推送
        // （chat_id 是 conversation.id，跟 provider 字段无关；hub 推谁不取决于 provider）。
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.isTrashed == false },
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        // perf-flash L2：排序后只取前 limit 条（原来全量实体化再 prefix）
        desc.fetchLimit = limit
        if launchProjectedFetch { desc.propertiesToFetch = [\.id, \.profileId] }
        guard let taken = try? context.fetch(desc) else { return }
        // 两臂都在 context 所属 actor 取值，后台只接收不可变标量，不能跨队列读取 @Model。
        let identities = taken.map { (id: $0.id, profileId: $0.profileId) }

        queue.async {
            var index = ChatIndex()
            for c in identities {
                index.entries[c.id] = c.profileId
                index.lru.append(c.id)
            }
            index.lru.reverse()
            writeChatIndex(index)
        }
    }

    // MARK: - Read/Write helpers

    private static func readChatIndex() -> ChatIndex {
        guard let url = chatIndexURL, let data = try? Data(contentsOf: url) else { return ChatIndex() }
        return (try? JSONDecoder().decode(ChatIndex.self, from: data)) ?? ChatIndex()
    }

    private static func writeChatIndex(_ index: ChatIndex) {
        guard let url = chatIndexURL, let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func readProfileCards() -> ProfileCards {
        guard let url = profileCardsURL, let data = try? Data(contentsOf: url) else { return ProfileCards() }
        return (try? JSONDecoder().decode(ProfileCards.self, from: data)) ?? ProfileCards()
    }

    private static func writeProfileCards(_ cards: ProfileCards) {
        guard let url = profileCardsURL, let data = try? JSONEncoder().encode(cards) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
#endif
