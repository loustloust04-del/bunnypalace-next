import Foundation
import SwiftData

// MARK: - 小芽引导 · 建 Ta 的楼层（plan-onboarding-xiaoya-impl §4.3）
// 导卡 / 起名建出来的楼层一律发布但不切（H6）：人留在小芽 app 里，出口卡「去找 X」才切。
// 追加导入（世界书 / 预设）显式以 Ta 楼层 id 为落点，不读 currentProfile（旧引导读当前楼层就是 H7 的病根）。

/// 默认称呼（H9）：起名卡「Ta 怎么称呼你」/ 设置 › 通用「我的名字」写；新建 / 导卡的楼层继承，不再硬编码「你」
enum DefaultUserName {
    static let key = "garden.defaultUserName"

    static func value(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func set(_ name: String, defaults: UserDefaults = .standard) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: key)
    }
}

/// 默认头像（§11-7，仿默认称呼 H9）：小白线挑的「你」的头像 / 设置 › 通用「你的头像」写；新建 / 导卡的楼层继承。
/// 512px JPEG 存 Application Support 一个文件——不进 UserDefaults（域 3.8MB 卡过收放面板）
struct DefaultUserAvatar: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static var live: DefaultUserAvatar {
        DefaultUserAvatar(fileURL: StagingPaths.applicationSupportRoot.appendingPathComponent("default-user-avatar.jpg"))
    }

    func load() -> Data? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return data
    }

    /// nil / 空 = 不动（同默认称呼：空串不清掉已有的）
    func save(_ data: Data?) {
        guard let data, !data.isEmpty else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
struct OnboardingFloorFactory {
    enum Failure: LocalizedError {
        case floorMissing, emptyWorldBook
        var errorDescription: String? {
            switch self {
            case .floorMissing: "Ta 的楼层已经不在了"
            case .emptyWorldBook: "世界书没有条目"
            }
        }
    }

    let profiles: ProfileManager
    let presets: PresetManager
    let cards: CharacterCardManager
    var defaults: UserDefaults = .standard
    var avatar: DefaultUserAvatar = .live

    /// 酒馆线：进卡库 → 建楼层（不切）。建楼层失败把刚进卡库的卡撤掉，重试不会多出一张
    func importCard(at url: URL) async throws -> Profile {
        try profiles.ensureWritable()
        let card = try cards.importFromFile(url: url)
        do {
            let floor = try await cards.floors(profileManager: profiles, presetManager: presets).enter(card: card, activate: false)
            // 导卡卡拷进临时目录的那份用完了
            if url.path.contains("/xiaoya-import/") { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return floor
        } catch {
            try? cards.remove(ids: [card.id])
            throw error
        }
    }

    /// 陪伴线：照 ProfileEditorSheet.save 的 create 分支 + instantiatePreset，但 persistNew + publish(activate: false)，不切楼层。
    /// 称呼空 → 默认称呼 → 「你」；「Ta 是谁」填了才写 Ta 楼层预设实例的 charDescription 槽。
    /// id 由剧本先定好记进 script.json：这个 id 的楼层已经在了（上次建完没来得及记）就直接还它，不再多建一个（sol #4）。
    /// 预设走可抛错的 persistNew，先落预设再落楼层，楼层落不下回滚预设（sol #5：预设存不下不能宣布建好了）
    func createTa(id: String = UUID().uuidString, name: String, userName: String, who: String) throws -> Profile {
        try profiles.ensureWritable()
        if let existing = profiles.profiles.first(where: { $0.id == id }) { return existing }
        var profile = Profile(id: id, name: name, emoji: "🌸", description: "",
                              userName: TavernSync.userName([userName, DefaultUserName.value(defaults)]),
                              assistantName: name, systemPrompt: "")
        profile.userAvatarData = avatar.load()
        // 上次落了预设、楼层没落就被杀：那份实例没人用，先清掉
        let stale = Set(presets.presets.filter { $0.ownerProfileId == id }.map(\.id))
        if !stale.isEmpty { try presets.discardNew(ids: stale) }
        var inst = presets.preset(byId: profile.presetId) ?? .balanced
        inst.id = UUID().uuidString
        inst.ownerProfileId = id
        inst.sourceTemplateId = profile.presetId
        if let idx = inst.prompts.firstIndex(where: { $0.id == PromptSlot.mainId }) {
            inst.prompts[idx].content = ""
        }
        let trimmedWho = who.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWho.isEmpty, let idx = inst.prompts.firstIndex(where: { $0.id == PromptSlot.charDescriptionId }) {
            inst.prompts[idx].content = trimmedWho
        }
        try presets.persistNew(inst)
        profile.presetId = inst.id
        do {
            try profiles.persistNew(profile)
        } catch {
            try? presets.discardNew(inst)
            throw error
        }
        profiles.publish(profile, activate: false)
        return profile
    }

    /// 小白线挑头像 + 名字（§11-7）：写当前楼层。你 → 称呼 / 头像，同时写默认称呼 / 默认头像（之后新建 / 导卡的楼层继承）；
    /// Ta → 当前楼层 AI 的名字 / 头像（小芽自己的名字不动）。名字空 = 先不改；只读时 updateProfile 自己不落
    func applyFace(_ answer: XiaoyaFaceAnswer, avatarJPEG: Data?) {
        var profile = profiles.currentProfile
        let name = answer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch answer.target {
        case .user:
            if !name.isEmpty {
                profile.userName = name
                DefaultUserName.set(name, defaults: defaults)
            }
            if let avatarJPEG {
                profile.userAvatarData = avatarJPEG
                avatar.save(avatarJPEG)
            }
        case .ta:
            if !name.isEmpty { profile.assistantName = name }
            if let avatarJPEG { profile.assistantAvatarData = avatarJPEG }
        }
        guard profile != profiles.currentProfile else { return }
        profiles.updateProfile(profile)
    }

    /// 三问「想让我叫你什么」：写目标楼层的称呼 + 默认称呼（同起名卡）。空 = 不动；不回写已有的记忆
    func applyUserName(_ name: String, profileId: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        DefaultUserName.set(name, defaults: defaults)
        guard var profile = profiles.profiles.first(where: { $0.id == profileId }), profile.userName != name else { return }
        profile.userName = name
        profiles.updateProfile(profile)
    }

    /// 出口卡「＋ 导入世界书」：落到 Ta 楼层（新书 profileId = Ta，挂进 Ta 的 linkedWorldBookIDs）
    @discardableResult
    func importWorldBook(_ data: Data, fallbackName: String, into profileId: String) throws -> String {
        guard var profile = profiles.profiles.first(where: { $0.id == profileId }) else { throw Failure.floorMissing }
        let report = try WorldBookCodec.decodeImport(data)
        guard !report.entries.isEmpty else { throw Failure.emptyWorldBook }
        let book = WorldBook(name: report.name ?? fallbackName, profileId: profileId, entries: report.entries)
        book.rawJSONData = report.rawJSONData
        let context = ModelContext(profiles.container)
        context.autosaveEnabled = false
        context.insert(book)
        try context.save()
        profile.linkedWorldBookIDs.append(book.id.uuidString)
        profiles.updateProfile(profile)
        return book.name
    }

    /// 出口卡「＋ 导入预设」：酒馆预设进模板库，再给 Ta 楼层实例化一份换上（旧实例留着，切回能复用）
    @discardableResult
    func importPreset(_ data: Data, into profileId: String) throws -> (name: String, notes: [String]) {
        guard var profile = profiles.profiles.first(where: { $0.id == profileId }) else { throw Failure.floorMissing }
        let imported = try presets.importFromSillyTavern(data)
        let inst = presets.instantiate(templateId: imported.preset.id, for: profileId)
        profile.presetId = inst.id
        profiles.updateProfile(profile)
        return (imported.preset.name, imported.notes)
    }

    /// 导预设前要不要先问一句：Ta 楼层带着卡自带的系统指令，换预设会把它换掉
    func presetReplacesCardPrompt(profileId: String) -> Bool {
        guard let profile = profiles.profiles.first(where: { $0.id == profileId }) else { return false }
        return !profile.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
