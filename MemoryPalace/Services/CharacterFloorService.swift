import Foundation
import SwiftData

/// 卡模板只在首次进入时物化。跨存储写入全部完成后才发布楼层。
@MainActor
final class CharacterFloorService {
    enum Failure: LocalizedError {
        case cardMissing, floorMissing, notCurrent, rollback(String)
        var errorDescription: String? {
            switch self {
            case .cardMissing: "这张卡已经不在了"
            case .floorMissing: "这个楼层已经不在了"
            case .notCurrent: "请先进入这张卡的楼层"
            case .rollback(let detail): "创建失败，清理未完成：\(detail)"
            }
        }
    }

    private unowned let cards: CharacterCardManager
    private let profiles: ProfileManager
    private let presets: PresetManager
    private var inFlight: [String: Task<Profile, Error>] = [:]
    /// 新楼层继承的默认头像（§11-7）；测试换临时文件
    var defaultAvatar: DefaultUserAvatar = .live

    init(cards: CharacterCardManager, profiles: ProfileManager, presets: PresetManager) {
        self.cards = cards
        self.profiles = profiles
        self.presets = presets
    }

    /// activate = false：楼层照建、照发布，但不切过去（小芽引导里导卡，人留在小芽 app 里，H6）
    func enter(card: CharacterCard, activate: Bool = true) async throws -> Profile {
        if let task = inFlight[card.id] { return try await task.value }
        let task = Task { @MainActor in try self.enterOnce(cardId: card.id, activate: activate) }
        inFlight[card.id] = task
        defer { inFlight[card.id] = nil }
        return try await task.value
    }

    private func enterOnce(cardId: String, activate: Bool) throws -> Profile {
        // #037：只读时楼层列表是 seed，找不到绑定楼层不等于楼层没了，别把卡标成 missing
        try profiles.ensureWritable()
        // 重新读模板，连点和旧视图快照都不能覆盖刚提交的绑定。
        guard var card = cards.cards.first(where: { $0.id == cardId }) else { throw Failure.cardMissing }
        if card.bindingState == .missing { throw Failure.floorMissing }
        if card.bindingState == .active {
            guard let profile = profiles.profiles.first(where: { $0.id == card.linkedProfileId }) else {
                card.bindingState = .missing
                try cards.update(card)
                throw Failure.floorMissing
            }
            if activate { profiles.switchTo(profile) }
            return profile
        }

        let (profile, preset, book) = try Self.makeFloor(card: card, presets: presets, userName: Self.floorUserName(profiles),
                                                         userAvatar: defaultAvatar.load())
        let context = ModelContext(profiles.container)
        context.autosaveEnabled = false
        var presetSaved = false
        var profileSaved = false
        var bookSaved = false
        do {
            try presets.persistNew(preset)
            presetSaved = true
            if let book { context.insert(book); try context.save(); bookSaved = true }
            try profiles.persistNew(profile)
            profileSaved = true
            card.bindingState = .active
            card.linkedProfileId = profile.id
            try cards.update(card)
        } catch {
            let original = error
            var cleanupErrors: [String] = []
            // 独立 context 只含本次新书；清理失败也必须向上报告。
            if bookSaved, let book {
                context.delete(book)
                do { try context.save() } catch { cleanupErrors.append(error.localizedDescription) }
            } else { context.rollback() }
            if profileSaved {
                do { try profiles.discardUnpublished(profile) } catch { cleanupErrors.append(error.localizedDescription) }
            }
            if presetSaved {
                do { try presets.discardNew(preset) } catch { cleanupErrors.append(error.localizedDescription) }
            }
            if !cleanupErrors.isEmpty { throw Failure.rollback(([original.localizedDescription] + cleanupErrors).joined(separator: "；")) }
            throw original
        }
        profiles.publish(profile, activate: activate)
        return profile
    }

    /// 无副作用构造（③a 第一阶段）：楼层、楼层预设实例、卡内书，不写任何存储。首次进入和整包导入（⑧c）共用
    static func makeFloor(card: CharacterCard, presets: PresetManager, userName: String = "你",
                          userAvatar: Data? = nil) throws -> (profile: Profile, preset: Preset, book: WorldBook?) {
        let report = card.hasWorldBook ? try card.decodeWorldBook() : nil
        var profile = Profile(name: card.name, emoji: "🎭", description: "\(card.name)的楼层",
                              userName: userName, assistantName: card.name,
                              systemPrompt: card.systemPrompt, characterDescription: card.description,
                              characterPersonality: card.personality, scenario: card.scenario,
                              chatExamples: card.mesExample, postInstructions: card.postHistoryInstructions,
                              characterCardID: card.name,
                              // ⑧c-4 B：楼层头像存 ≤512px 缩略图，原 PNG 只在卡上留一份
                              coverImageData: card.originals.thumbnail ?? CardImageThumbnail.make(from: card.imageData))
        // 默认头像（§11-7）：跟默认称呼一样，卡楼层里的「你」带上她挑过的头像
        profile.userAvatarData = userAvatar
        var preset = presets.preset(byId: profile.presetId) ?? .balanced
        preset.id = UUID().uuidString
        preset.ownerProfileId = profile.id
        preset.sourceTemplateId = profile.presetId
        for (slotId, value) in [(PromptSlot.mainId, card.systemPrompt), (PromptSlot.jailbreakId, card.postHistoryInstructions)] {
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let index = preset.prompts.firstIndex(where: { $0.id == slotId && !$0.forbidOverrides }) {
                preset.prompts[index].content = value
            }
        }
        // ④a：卡级 depth_prompt → 楼层预设实例里的 absolute 插槽（role 照存；实发按 role 分流是 ④b）
        preset = SlotOrder.appendingCardDepthPrompt(cardJSON: card.rawJSONData, to: preset)
        profile.presetId = preset.id
        var book: WorldBook?
        if let report {
            let value = WorldBook(name: report.name ?? card.characterBookName ?? "\(card.name)的世界书",
                                  profileId: profile.id, entries: report.entries)
            value.rawJSONData = report.rawJSONData
            book = value
            profile.linkedWorldBookIDs = [value.id.uuidString]
        }
        return (profile, preset, book)
    }

    /// B6：卡楼层里的 {{user}} 用当前楼层的称呼，没填用全局用户名，都没有才「你」。
    /// 链首是默认称呼（H9，plan-onboarding-xiaoya-impl §4.4）：引导里导卡时人在哪层不一定，那层的称呼不算数
    static func floorUserName(_ profiles: ProfileManager, defaults: UserDefaults = .standard) -> String {
        TavernSync.userName([defaults.string(forKey: DefaultUserName.key), profiles.currentProfile.userName,
                             defaults.string(forKey: "userName"), defaults.string(forKey: "onboardingUserName")])
    }

    static func boundCard(profileId: String, cards: [CharacterCard]) -> CharacterCard? {
        cards.first { $0.bindingState == .active && $0.linkedProfileId == profileId }
    }

    /// B5：楼层是从卡建的、卡有开场白 → 新对话要带的开场白；不是卡楼层返回空
    static func greetings(profileId: String, cards: [CharacterCard]) -> [String] {
        boundCard(profileId: profileId, cards: cards)?.greetings ?? []
    }

    /// B1：绑着这张卡的楼层（目前一张卡最多绑一个）
    func boundFloors(card: CharacterCard) -> [Profile] {
        guard card.bindingState == .active, let id = card.linkedProfileId else { return [] }
        return profiles.profiles.filter { $0.id == id }
    }

    /// B1：把卡写进绑着它的楼层 + 楼层预设实例的 main / jailbreak 槽（只换导卡时原样拷过去、之后没改过的槽）。
    /// previous = 改卡前那版；连同导入原件一起当「楼层可能拷自的版本」。返回同步了几个楼层、哪些槽你改过没覆盖
    @discardableResult
    func syncFloors(card: CharacterCard, previous: CharacterCard?, onlyProfileId: String? = nil) throws -> (floors: Int, skipped: [String]) {
        try profiles.ensureWritable()
        let original = card.rawJSONData.flatMap { try? CharacterCard(from: TavernCard.parseJSON(data: $0)) }
        let sources = [previous, original].compactMap { $0 }
        var skipped: [String] = []
        let floors = boundFloors(card: card).filter { onlyProfileId == nil || $0.id == onlyProfileId }
        for profile in floors {
            // 只动这个楼层自己的实例，不碰共享模板
            let instance = presets.preset(byId: profile.presetId).flatMap { $0.ownerProfileId == profile.id ? $0 : nil }
            let template = instance?.sourceTemplateId.flatMap { presets.preset(byId: $0) }
            let outcome = TavernSync.apply(card: card, sources: sources, profile: profile, preset: instance, template: template)
            if outcome.profile != profile { profiles.updateProfile(outcome.profile) }
            if let preset = outcome.preset, preset.prompts != instance?.prompts { presets.save(preset) }
            skipped += outcome.skipped
        }
        return (floors.count, skipped)
    }

    func newChat(card: CharacterCard) throws -> Conversation {
        guard let latest = cards.cards.first(where: { $0.id == card.id }) else { throw Failure.cardMissing }
        guard latest.bindingState == .active, let profileId = latest.linkedProfileId,
              profiles.profiles.contains(where: { $0.id == profileId }) else { throw Failure.floorMissing }
        guard profiles.currentProfile.id == profileId else { throw Failure.notCurrent }
        return try saveChat(title: latest.name, greetings: latest.greetings, profileId: profileId)
    }

    func newChat(profile: Profile) throws -> Conversation {
        guard profiles.currentProfile.id == profile.id else { throw Failure.notCurrent }
        return try saveChat(title: profile.name, greetings: [], profileId: profile.id)
    }

    private func saveChat(title: String, greetings: [String], profileId: String) throws -> Conversation {
        let context = ModelContext(profiles.container)
        context.autosaveEnabled = false
        let (conversation, nodes) = Self.makeChat(title: title, greetings: greetings, profileId: profileId)
        context.insert(conversation)
        nodes.forEach { context.insert($0) }
        do { try context.save() } catch { context.rollback(); throw error }
        return conversation
    }

    /// 同一隐形根下按源顺序存兄弟候选；空开场只建空聊天。
    static func makeChat(title: String, greetings: [String], profileId: String) -> (Conversation, [MessageNode]) {
        let now = Date()
        let conversation = Conversation(id: UUID().uuidString, title: title, createTime: now,
                                        updateTime: now, currentNodeId: "", provider: "sillytavern", profileId: profileId)
        let values = greetings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !values.isEmpty else { return (conversation, []) }
        let root = MessageNode(id: UUID().uuidString, role: "system", content: "", contentType: "text",
                               createTime: now, parentId: nil, childrenIds: [], conversationId: conversation.id, profileId: profileId)
        root.isSyntheticRoot = true
        let children = values.map { value in
            MessageNode(id: UUID().uuidString, role: "assistant", content: value, contentType: "text",
                        createTime: now, parentId: root.id, childrenIds: [], conversationId: conversation.id, profileId: profileId)
        }
        root.childrenIds = children.map(\.id)
        conversation.currentNodeId = children[0].id
        conversation.nodeCount = children.count
        return (conversation, [root] + children)
    }
}

/// 同名旧卡和楼层互不猜关联；归档卡仍保有绑定，不让楼层换壳重新上墙。
struct CharacterWallItem: Identifiable {
    let id: String
    let profile: Profile?
    let card: CharacterCard?
    var name: String { card?.name ?? profile?.name ?? "" }
    var imageData: Data? { card?.coverImageData ?? profile?.coverImageData }
    var hasWorldBook: Bool { card?.hasWorldBook ?? !(profile?.linkedWorldBookIDs.isEmpty ?? true) }
    var hasRegex: Bool { !(card?.regexScripts.isEmpty ?? profile?.regexScripts.isEmpty ?? true) }

    static func make(cards: [CharacterCard], profiles: [Profile]) -> [Self] {
        let bound = Set(cards.filter { $0.bindingState == .active }.compactMap(\.linkedProfileId))
        return cards.filter { $0.archivedAt == nil }.map { card in
            Self(id: card.id, profile: card.bindingState == .active ? profiles.first { $0.id == card.linkedProfileId } : nil, card: card)
        } + profiles.filter { !bound.contains($0.id) }.map { Self(id: "floor:\($0.id)", profile: $0, card: nil) }
    }
}
