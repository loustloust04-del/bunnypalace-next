import Foundation

/// AI 资料卡店：memory/profile-card.md。
/// frontmatter：card(版本) + status（AI 当下状态一句话）+ statusUpdatedAt；body = bio。
/// status/bio 独立保存互不踩。body 空时写 "-" 哨兵（FrontmatterCodec.parse 空 body 返回 nil）。
/// 在 memory/ 树下 = AI 可 fs_read 看到，但 fs_write 对 memory/ 路径拒绝——只能走 update_profile_card 改。
enum ProfileCardStore {
    struct Card {
        var status: String? = nil
        var statusUpdatedAt: Date? = nil
        var bio: String? = nil
    }

    /// 卡主：AI（profile-card.md，工具可写）/ user（user-card.md，只有人编辑）
    enum Owner: String, Identifiable {
        case assistant, user
        var id: String { rawValue }
    }

    static let statusMaxLength = 30
    private static let bioEmptySentinel = "-"

    private static func url(profileId: String, owner: Owner) -> URL {
        let name = owner == .assistant ? "profile-card.md" : "user-card.md"
        return FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent(name)
    }

    static func load(profileId: String, owner: Owner = .assistant) -> Card {
        guard let raw = try? String(contentsOf: url(profileId: profileId, owner: owner), encoding: .utf8),
              let (meta, body) = FrontmatterCodec.parse(raw) else { return Card() }
        var card = Card()
        if let s = meta["status"], !s.isEmpty { card.status = s }
        card.statusUpdatedAt = meta["statusUpdatedAt"].flatMap { FrontmatterCodec.dateFormatter.date(from: $0) }
        if body != bioEmptySentinel, !body.isEmpty { card.bio = body }
        return card
    }

    static func saveStatus(_ status: String, profileId: String, owner: Owner = .assistant) {
        var card = load(profileId: profileId, owner: owner)
        let cleaned = status.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        card.status = cleaned.isEmpty ? nil : String(cleaned.prefix(statusMaxLength))
        card.statusUpdatedAt = Date()
        save(card, profileId: profileId, owner: owner)
    }

    static func saveBio(_ bio: String, profileId: String, owner: Owner = .assistant) {
        var card = load(profileId: profileId, owner: owner)
        let cleaned = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        card.bio = cleaned.isEmpty ? nil : cleaned
        save(card, profileId: profileId, owner: owner)
    }

    private static func save(_ card: Card, profileId: String, owner: Owner) {
        var meta: [(String, String)] = [("card", "v1")]
        if let s = card.status { meta.append(("status", s)) }
        if let at = card.statusUpdatedAt { meta.append(("statusUpdatedAt", FrontmatterCodec.dateFormatter.string(from: at))) }
        let content = FrontmatterCodec.render(meta: meta, body: card.bio ?? bioEmptySentinel)
        try? Data(content.utf8).write(to: url(profileId: profileId, owner: owner), options: .atomic)
    }
}

// MARK: - AI 自助接口：update_profile_card

/// AI 更新自己资料卡的工具。跟文件库工具一起下发（fileLibraryOn），一个工具管 status+bio（工具海阈值教训，不拆）。
/// 本接口服务 API provider 的工具循环；CC 桥 / heartbeat 自动填后续另接。
enum ProfileCardTool {
    static let toolName = "update_profile_card"
    private static let desc = "更新你自己的资料卡（用户点你的头像能看到）。status：一句你当下的状态（如「监控中」「被猫猫抛弃中」，\(ProfileCardStore.statusMaxLength) 字内，超出截断）；bio：你的自我介绍。至少传一个，只更新传了的字段。"
    private static let props: [String: Any] = [
        "status": ["type": "string", "description": "当下状态一句话"],
        "bio": ["type": "string", "description": "自我介绍（多行可）"],
    ]

    // B-D5（description 改提醒型 + execute 转 fs_edit）推迟到资料卡文件化落地后——
    // 现在卡存 ProfileCardStore 非文件，提醒型文案会指向不存在的 md。Phase 0 零动。
    static var definition: ToolDefinition {
        ToolDefinition(name: toolName, description: desc, properties: props, required: [])
    }

    static func execute(inputJSON: String, profileId: String) -> FileLibraryTools.Result {
        guard let data = inputJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .init(text: "参数解析失败，需要 JSON object", isError: true)
        }
        let status = obj["status"] as? String
        let bio = obj["bio"] as? String
        guard status != nil || bio != nil else {
            return .init(text: "status 和 bio 至少传一个", isError: true)
        }
        var done: [String] = []
        if let s = status {
            ProfileCardStore.saveStatus(s, profileId: profileId)
            done.append("status →「\(s.prefix(ProfileCardStore.statusMaxLength))」")
        }
        if let b = bio {
            ProfileCardStore.saveBio(b, profileId: profileId)
            done.append("bio 已更新")
        }
        return .init(text: "资料卡已更新：" + done.joined(separator: "；"), isError: false)
    }
}
