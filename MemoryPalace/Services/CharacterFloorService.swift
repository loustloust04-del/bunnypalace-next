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

    init(cards: CharacterCardManager, profiles: ProfileManager, presets: PresetManager) {
        self.cards = cards
        self.profiles = profiles
        self.presets = presets
    }

    func enter(card: CharacterCard) async throws -> Profile {
        if let task = inFlight[card.id] { return try await task.value }
        let task = Task { @MainActor in try self.enterOnce(cardId: card.id) }
        inFlight[card.id] = task
        defer { inFlight[card.id] = nil }
        return try await task.value
    }

    private func enterOnce(cardId: String) throws -> Profile {
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
            profiles.switchTo(profile)
            return profile
        }

        let (profile, preset, book) = try Self.makeFloor(card: card, presets: presets)
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
        profiles.publish(profile, activate: true)
        return profile
    }

    /// 无副作用构造（③a 第一阶段）：楼层、楼层预设实例、卡内书，不写任何存储。首次进入和整包导入（⑧c）共用
    static func makeFloor(card: CharacterCard, presets: PresetManager) throws -> (profile: Profile, preset: Preset, book: WorldBook?) {
        let report = card.hasWorldBook ? try card.decodeWorldBook() : nil
        var profile = Profile(name: card.name, emoji: "🎭", description: "\(card.name)的楼层",
                              userName: "你", assistantName: card.name,
                              systemPrompt: card.systemPrompt, characterDescription: card.description,
                              characterPersonality: card.personality, scenario: card.scenario,
                              chatExamples: card.mesExample, postInstructions: card.postHistoryInstructions,
                              characterCardID: card.name,
                              // ⑧c-4 B：楼层头像存 ≤512px 缩略图，原 PNG 只在卡上留一份
                              coverImageData: card.originals.thumbnail ?? CardImageThumbnail.make(from: card.imageData))
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
