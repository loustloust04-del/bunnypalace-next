import SwiftUI
import SwiftData

// MARK: - Profile

struct Profile: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var emoji: String
    var description: String
    var userName: String
    var assistantName: String
    var systemPrompt: String
    var preferredModel: String
    var createdAt: Date

    // Phase 3: 人格系统
    var presetId: String
    var userPersona: String
    var characterDescription: String
    var characterPersonality: String
    var scenario: String
    var chatExamples: String
    var postInstructions: String

    // Phase 4: 角色卡 + 世界书
    var characterCardID: String?             // 来源角色卡标识（角色名）
    var linkedWorldBookIDs: [String]         // 绑定的世界书 UUID 列表
    var coverImageData: Data?                // 封面图（PNG 卡的原图）；⑧c-4 起卡建楼层只存 ≤512px 缩略图
    var regexScriptsData: Data?              // JSON encoded [RegexScript]

    // 自选头像（设置-通用裁剪输出，512×512 JPEG）。Codable optional：老数据 decode 自动 nil，零迁移。
    var userAvatarData: Data? = nil
    var assistantAvatarData: Data? = nil

    // 发语音条：本楼层 AI 的 ElevenLabs voice（设置-人格选择）。name 只做显示缓存。
    var elevenVoiceId: String? = nil
    var elevenVoiceName: String? = nil

    // 语音服务（plan-voice-providers V1c）：楼层用哪个服务 / 哪个声音 / 语音条和通话各用哪个模型。
    // 老的 elevenVoiceId/Name 由 VoiceServiceMigration 挂过来；V3/V4 换完调用点前两套并存。
    var voiceServiceId: String? = nil
    var voiceId: String? = nil
    var voiceName: String? = nil
    var messageModel: String? = nil
    var callModel: String? = nil
    /// 嗓子补充说明（V3 追加到语音条提示词末尾）
    var voiceExtraNote: String? = nil
    /// 本机音效按楼层选；原数据 nil = 关闭，不改变旧语音条。
    var voiceEffects: VoiceEffectConfiguration? = nil

    // 角色时区（可选 = 老数据 decode 自动 nil，零迁移）。开关是全局的：设置-Agent「作息感知」
    var characterTimeZone: String? = nil

    /// 卡库 ③-4：楼层默认身份（UserPersonaStore id）。nil = 用楼层原有身份文本；对话自己的 personaId 优先
    var personaId: String? = nil

    /// 正则脚本列表
    var regexScripts: [RegexScript] {
        get {
            guard let data = regexScriptsData else { return [] }
            return (try? JSONDecoder().decode([RegexScript].self, from: data)) ?? []
        }
        set {
            regexScriptsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(id: String = UUID().uuidString, name: String, emoji: String, description: String, userName: String, assistantName: String, systemPrompt: String = "", preferredModel: String = "anthropic/claude-sonnet-4", createdAt: Date = Date(), presetId: String = "built-in-balanced", userPersona: String = "", characterDescription: String = "", characterPersonality: String = "", scenario: String = "", chatExamples: String = "", postInstructions: String = "", characterCardID: String? = nil, linkedWorldBookIDs: [String] = [], coverImageData: Data? = nil, regexScriptsData: Data? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.description = description
        self.userName = userName
        self.assistantName = assistantName
        self.systemPrompt = systemPrompt
        self.preferredModel = preferredModel
        self.createdAt = createdAt
        self.presetId = presetId
        self.userPersona = userPersona
        self.characterDescription = characterDescription
        self.characterPersonality = characterPersonality
        self.scenario = scenario
        self.chatExamples = chatExamples
        self.postInstructions = postInstructions
        self.characterCardID = characterCardID
        self.linkedWorldBookIDs = linkedWorldBookIDs
        self.coverImageData = coverImageData
        self.regexScriptsData = regexScriptsData
    }

    /// **Legacy** 路线 A 时期 per-profile store URL。路线 B 合并到 unified container 后
    /// 只给 `UnifiedContainerMigration` 用（读老数据迁到 unified store）。
    /// 迁移完会 rename 成 `.backup-YYYY-MM-DD`。
    var legacyStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MemoryPalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id).store")
    }

    /// Legacy ghost-lily 用 SwiftData default store —— 没有 explicit URL，由 SwiftData
    /// 自动放在 `Application Support/<BundleID>/default.store`。迁移时需要读它。
    var usesDefaultStore: Bool { id == "ghost-lily" }

    /// Legacy default store URL（for ghost-lily）—— SwiftData 没有公开 API 返回它，
    /// 只能按它的约定路径构造。
    static var legacyDefaultStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("default.store")
    }

    // Seed profiles for first-launch migration
    static let seedProfiles: [Profile] = [
        Profile(
            id: "default-workspace",
            name: "对话空间",
            emoji: "🏛️",
            description: "对话空间",
            userName: "你",
            assistantName: "助手",
            systemPrompt: "",
            preferredModel: "openai/gpt-4o",
            createdAt: Date(timeIntervalSince1970: 0)
        ),
    ]
}

// MARK: - Profile Manager

@Observable
final class ProfileManager {
    private static let profilesKey = "savedProfiles"

    var profiles: [Profile]
    var currentProfile: Profile
    weak var characterCardManager: CharacterCardManager?
    private let defaults: UserDefaults
    /// ⑧c-4：楼层列表存 BlobStore（root 可注入，测试 / 临时库不碰真实目录）
    private let root: URL?
    private let sideEffectsEnabled: Bool
    private var storageLoadError: Error?
    /// #037：启动读楼层列表失败，内存里是 seed 不是她的真列表。拿 profiles 判「楼层在不在」再写 / 删的地方都要先看它
    var isReadOnly: Bool { storageLoadError != nil }

    struct ReadOnlyError: LocalizedError {
        var errorDescription: String? { "楼层列表读取失败，为防覆盖本次只读，重启 app 再试" }
    }

    func ensureWritable() throws {
        if isReadOnly { throw ReadOnlyError() }
    }
    /// 路线 B：app lifetime 内固定的单一 container。所有 profile 共享这一个 container，
    /// 只靠 profileId 字段过滤数据。不再 swap，彻底消除 SwiftUI + SwiftData env update
    /// 带来的 race。
    let container: ModelContainer

    /// loadError 必传：来自 `loadProfilesChecked`，同一次读的成败（#037：不再自己复读，两次读结果不一致会拿 seed 覆盖真列表）
    init(container: ModelContainer, profiles: [Profile], currentProfile: Profile, loadError: Error?, root: URL? = nil, defaults: UserDefaults = .standard, sideEffectsEnabled: Bool = true) {
        self.defaults = defaults
        self.root = BlobStore.resolvedRoot(root, defaults: defaults)
        self.sideEffectsEnabled = sideEffectsEnabled
        self.container = container
        self.profiles = profiles
        self.currentProfile = currentProfile
        self.storageLoadError = loadError
        #if os(iOS)
        // App Group 索引：启动期把所有楼层全量同步给 NSE
        // （老用户首次升级到带 NSE 版本时也走这条路 → App Group 立即就绪）
        if sideEffectsEnabled { for p in profiles { PushIdentityWriter.upsertProfile(p) } }
        #endif
    }

    /// Shared schema definition —— 迁移脚本也用
    ///
    /// **每次返回新的 `Schema` 实例**而不是单例 static let。
    /// 主 container 和 staging container（GlobalImporter buildStagingContainer）
    /// 都调用同一个工厂函数，避免共享 `Schema` 实例 — codex Round 5 #7 提示：
    /// 长期硬编码两份 model list 是债务；现在抽工厂统一管理。
    ///
    /// （注：是否共享同一 Schema 实例会触发 SwiftData 跨 container 私有行为，
    /// 目前没有可验证证据，但 staging-store 数据漂移 bug 暂未坐实根因
    /// 详见 docs/research-staging-data-leak.md）
    static func makeFullSchema() -> Schema {
        Schema([
            Conversation.self,
            MessageNode.self,
            UserCard.self,
            ConversationTag.self,
            FavoriteItem.self,
            ImportRecord.self,
            ImportConversationChange.self,
            MemoryNote.self,
            Memory.self,
            WorldBook.self,
            StickerAsset.self,
            PlacedSticker.self,
            BookEntry.self,
            AudiobookItem.self,
            AudiobookBookmark.self,
            VocabProgress.self,
            WeightEntry.self,
            Medication.self,
            MedicationLog.self,
            CycleDay.self,
            IntimacyEntry.self,
            TickerEntry.self,
            TradeEntry.self,
            // page2「推特」子应用（plan-page2-twitter）：纯新增，走 SwiftData 轻量迁移
            TwitterArchiveAccount.self,
            TweetEntry.self,
            TweetMedia.self,
            TwitterBookmarkFolder.self,
            TwitterFollow.self,
            TwitterLike.self,
            TwitterDraft.self,
        ])
    }

    /// 旧 API 兼容（短期内还有别处 `ProfileManager.fullSchema` 引用）。
    /// **长期方向**：所有 caller 改调 `makeFullSchema()`，最终删除这个 static let。
    static let fullSchema: Schema = makeFullSchema()

    /// Unified store 的固定路径 —— 所有 profile 数据合并存这一个 SQLite 文件。
    static var unifiedStoreURL: URL {
        try? FileManager.default.createDirectory(at: unifiedStorePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        return unifiedStorePath
    }

    /// 同一路径但不建目录（启动闸门用，BFU 时不能有任何写）
    static var unifiedStorePath: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("unified.store")
    }

    /// 构造 unified container。App.init 调用一次，app lifetime 内不再重建。
    static func makeUnifiedContainer() -> ModelContainer {
        #if os(macOS)
        do {
            let count = try MacStoreQueryIndexes.repair(at: unifiedStoreURL)
            if count > 0 { print("[mac-store-index] restored \(count) query indexes") }
        } catch {
            // Index repair is an optimization. Keep the existing store usable on failure.
            print("[mac-store-index] repair skipped: \(error.localizedDescription)")
        }
        #endif
        // cloudKitDatabase 必须显式 .none：app 挂了 iCloud Drive entitlement 后，
        // 默认 .automatic 会尝试把整库接 CloudKit（unique 约束/非可选字段全不合规）→ 启动即炸。
        // 我们只用 iCloud 同步文件库文件，数据库永远本地。
        let config = ModelConfiguration(
            "unified",
            schema: fullSchema,
            url: unifiedStoreURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: fullSchema, configurations: [config])
        } catch {
            fatalError("Could not create unified ModelContainer: \(error)")
        }
    }

    // MARK: - Switch

    func switchTo(_ profile: Profile) {
        guard profile.id != currentProfile.id else { return }
        // post .profileWillSwitch（ultrareview B19 / bug_005）：让 6 处 observer
        // （StickerVM / ConversationVM / Sidebar / MemoryPanel / MemoryPage×2）
        // 在 currentProfile 切换前同步清掉持有的 SwiftData stale ref。
        // ContentView.id(currentProfile.id) 重建 subtree 是主防御，这是 defense-in-depth。
        // queue: nil 同步派发，确保 cleanup 跑完再继续。
        if sideEffectsEnabled { NotificationCenter.default.post(name: .profileWillSwitch, object: nil) }
        if sideEffectsEnabled { BreadcrumbLog.shared.add("🏠", "切楼层 \(currentProfile.name) → \(profile.name)") }
        defaults.set(profile.id, forKey: "lastProfileId")
        defaults.set(profile.userName, forKey: "userName")
        defaults.set(profile.assistantName, forKey: "assistantName")
        // 路线 B：container 不动，只翻 currentProfile。@Observable 触发 SwiftUI
        // view rebuild（ContentView 的 .id(currentProfile.id) 识别变化后重建整棵
        // subtree，@Query 用新 profileId predicate refetch）。无 race。
        currentProfile = profile
        // 修全局卡顿：新楼层的文件清单后台预热，第一次组 prompt 不在主线程现扫
        if sideEffectsEnabled { FileLibraryStore.warmList(profileId: profile.id) }
    }

    // MARK: - CRUD

    /// 仅提交存储；物化事务完成前不发布任何可见副作用。
    func persistNew(_ profile: Profile) throws {
        try writeProfiles(profiles.filter { $0.id != profile.id } + [profile])
    }

    func discardUnpublished(_ profile: Profile) throws {
        try writeProfiles(profiles.filter { $0.id != profile.id })
    }

    /// 整包导入（⑧c）：一次提交多个未发布楼层；逐个 persistNew 会互相覆盖（每次都以已发布列表为底）
    func persistNew(_ newProfiles: [Profile]) throws {
        let ids = Set(newProfiles.map(\.id))
        try writeProfiles(profiles.filter { !ids.contains($0.id) } + newProfiles)
    }

    /// 按清单清理（⑧c 恢复 / 撤回前未发布）：存储和内存列表都去掉，不发布任何副作用
    func discardUnpublished(ids: Set<String>) throws {
        try writeProfiles(profiles.filter { !ids.contains($0.id) })
        profiles.removeAll { ids.contains($0.id) }
    }

    func publish(_ profile: Profile, activate: Bool) {
        if !profiles.contains(where: { $0.id == profile.id }) { profiles.append(profile) }
        if sideEffectsEnabled {
            FileLibraryStore.prepareProfile(profile)
            #if os(iOS)
            PushIdentityWriter.upsertProfile(profile)
            #endif
        }
        if activate { switchTo(profile) }
    }

    func addProfile(_ profile: Profile) {
        do {
            try persistNew(profile)
            publish(profile, activate: true)
        } catch { NSLog("楼层保存失败：%@", error.localizedDescription) }
    }

    func updateProfile(_ profile: Profile) {
        // #037：只读时内存列表是 seed，改了也存不下；连内存和文件库目录都不动
        guard !isReadOnly else {
            NSLog("楼层列表只读，忽略楼层修改：%@", profile.id)
            return
        }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        saveProfiles()
        if sideEffectsEnabled { FileLibraryStore.prepareProfile(profile) }
        if currentProfile.id == profile.id {
            currentProfile = profile
            defaults.set(profile.userName, forKey: "userName")
            defaults.set(profile.assistantName, forKey: "assistantName")
        }
        #if os(iOS)
        if sideEffectsEnabled { PushIdentityWriter.upsertProfile(profile) }
        #endif
    }

    /// 批量改楼层并同步落盘；落盘失败返回 false（语音服务迁移靠它决定是否落完成标记）
    @discardableResult
    func updateProfilesPersisting(_ changed: [Profile]) -> Bool {
        for p in changed {
            guard let index = profiles.firstIndex(where: { $0.id == p.id }) else { continue }
            profiles[index] = p
            if currentProfile.id == p.id { currentProfile = p }
        }
        do {
            try writeProfiles(profiles)
            return true
        } catch {
            NSLog("楼层保存失败：%@", error.localizedDescription)
            return false
        }
    }

    /// 删楼层：从 profiles list 移除 + 可选地清 unified container 里该 profile 的所有数据
    /// （靠 #Predicate { $0.profileId == deletedId } batch delete）。legacy store 文件不动
    /// （留 .backup 兜底，这是粟粟批注：永久保留）。
    func deleteProfile(_ profile: Profile, deleteData: Bool) {
        guard profiles.count > 1 else { return } // 至少保留一个
        let deletedId = profile.id
        do { try characterCardManager?.markMissing(profileId: deletedId) }
        catch {
            NSLog("卡绑定保存失败，未删除楼层：%@", error.localizedDescription)
            return
        }
        profiles.removeAll(where: { $0.id == deletedId })
        saveProfiles()
        if sideEffectsEnabled { FileLibraryStore.prepareProfiles(profiles) }

        if deleteData {
            let ctx = ModelContext(container)
            // 按 profileId 批量删 unified store 里的所有数据
            try? ctx.delete(model: Conversation.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: MessageNode.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: UserCard.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: ConversationTag.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: FavoriteItem.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: Memory.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: MemoryNote.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: WorldBook.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: StickerAsset.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: PlacedSticker.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: ImportRecord.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: ImportConversationChange.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: WeightEntry.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: Medication.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: MedicationLog.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: CycleDay.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: IntimacyEntry.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: TickerEntry.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: TradeEntry.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.save()
            // 批删不发 didSave（S5 探针），索引得显式删
            if sideEffectsEnabled { SearchIndexer.shared.profileDeleted(deletedId) }
        }

        if currentProfile.id == deletedId {
            switchTo(profiles[0])
        }
        #if os(iOS)
        if sideEffectsEnabled { PushIdentityWriter.removeProfile(id: deletedId) }
        #endif
    }

    // MARK: - Persistence

    private func writeProfiles(_ values: [Profile]) throws {
        if let storageLoadError { throw storageLoadError }
        try BlobStore.set(try JSONEncoder().encode(values), forKey: Self.profilesKey, root: root)
    }

    private func saveProfiles() {
        do { try writeProfiles(profiles) }
        catch { NSLog("楼层保存失败：%@", error.localizedDescription) }
    }

    /// 只读调用点（备份快照 / 语音条）用；要建 ProfileManager 的走 `loadProfilesChecked`
    static func loadProfiles(root: URL? = nil, defaults: UserDefaults = .standard) -> [Profile] {
        loadProfilesChecked(root: root, defaults: defaults).profiles
    }

    static func loadProfilesChecked(root: URL? = nil, defaults: UserDefaults = .standard) -> (profiles: [Profile], error: Error?) {
        let root = BlobStore.resolvedRoot(root, defaults: defaults)
        // 读不到 / 解不开 ≠ 首次启动：只给内存里的 seed，不覆盖原文件，error 交给 ProfileManager 进只读
        do {
            if let stored = try BlobStore.read(forKey: profilesKey, root: root, defaults: defaults) {
                let profiles = try JSONDecoder().decode([Profile].self, from: stored)
                if !profiles.isEmpty { return (profiles, nil) }
            }
        } catch {
            NSLog("楼层列表读取失败，本次只读：%@", error.localizedDescription)
            return (Profile.seedProfiles, error)
        }
        return (seedAndSave(root: root), nil)
    }

    /// 启动闸门要探测的受保护文件：库 + 楼层列表（导入恢复中断时库可能暂时不在）
    static var launchGatePaths: [URL] {
        [unifiedStorePath, BlobStore.path(forKey: profilesKey)]
    }

    private static func seedAndSave(root: URL?) -> [Profile] {
        let seed = Profile.seedProfiles
        if let data = try? JSONEncoder().encode(seed) {
            try? BlobStore.set(data, forKey: profilesKey, root: root)
        }
        return seed
    }
}

// MARK: - Preset Manager

@Observable
final class PresetManager {
    private static let presetsKey = "savedPresets"

    var presets: [Preset]

    /// ⑧c-4：预设存 BlobStore（root 可注入）
    private let root: URL?
    private var loadError: Error?

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.root = BlobStore.resolvedRoot(root, defaults: defaults)
        do {
            let data = try BlobStore.read(forKey: Self.presetsKey, root: self.root, defaults: defaults)
            var values = try data.map { try JSONDecoder().decode([Preset].self, from: $0) } ?? []
            for preset in Preset.allBuiltIn where !values.contains(where: { $0.id == preset.id }) {
                values.append(preset)
            }
            // ④a：内存里一律是序列顺序（数组位 = sequenceIndex = 发送顺序），编辑器按下标读写才对得上；
            // 旧数据按 injectionOrder 读出同一顺序，下次保存才落 sequenceIndex
            presets = values.map { SlotOrder.normalized($0) }
        } catch { presets = []; loadError = error }
    }

    /// #037：楼层列表读坏时由启动调用，之后所有预设保存都拒绝（同自己读坏的处理）
    func blockWrites(_ error: Error) {
        if loadError == nil { loadError = error }
    }

    func persistNew(_ preset: Preset) throws {
        if let loadError { throw loadError }
        let next = presets.filter { $0.id != preset.id } + [SlotOrder.normalized(preset)]
        try BlobStore.set(try JSONEncoder().encode(next), forKey: Self.presetsKey, root: root)
        presets = next
    }

    func discardNew(_ preset: Preset) throws {
        let next = presets.filter { $0.id != preset.id }
        try BlobStore.set(try JSONEncoder().encode(next), forKey: Self.presetsKey, root: root)
        presets = next
    }

    /// 整包导入（⑧c）：一次写入多份，避免逐份整表重编码
    func persistNew(_ newPresets: [Preset]) throws {
        if let loadError { throw loadError }
        let ids = Set(newPresets.map(\.id))
        let next = presets.filter { !ids.contains($0.id) } + newPresets.map { SlotOrder.normalized($0) }
        try BlobStore.set(try JSONEncoder().encode(next), forKey: Self.presetsKey, root: root)
        presets = next
    }

    func discardNew(ids: Set<String>) throws {
        if let loadError { throw loadError }
        let next = presets.filter { !ids.contains($0.id) }
        try BlobStore.set(try JSONEncoder().encode(next), forKey: Self.presetsKey, root: root)
        presets = next
    }

    /// 选择器/管理列表用：只含模板（楼层实例不出现在全局列表）
    var templates: [Preset] { presets.filter { $0.ownerProfileId == nil } }

    func preset(byId id: String) -> Preset? {
        presets.first(where: { $0.id == id })
    }

    /// 某楼层对某模板已有的实例（切回时复用，保留改动）
    func instance(ownerProfileId: String, sourceTemplateId: String) -> Preset? {
        presets.first { $0.ownerProfileId == ownerProfileId && $0.sourceTemplateId == sourceTemplateId }
    }

    /// deep copy 模板 → 楼层实例（Preset 是值类型，赋值即深拷贝）
    func instantiate(templateId: String, for profileId: String) -> Preset {
        var copy = preset(byId: templateId) ?? .balanced
        copy.id = UUID().uuidString
        copy.ownerProfileId = profileId
        copy.sourceTemplateId = templateId
        presets.append(copy)
        persist()
        return copy
    }

    /// 删楼层时清理其全部实例
    func deleteInstances(ownerProfileId: String) {
        presets.removeAll { $0.ownerProfileId == ownerProfileId }
        persist()
    }

    /// 删除单条实例记录（楼层切走且源模板被删时的清理）
    func removeInstance(_ inst: Preset) {
        guard inst.ownerProfileId != nil else { return }
        presets.removeAll { $0.id == inst.id }
        persist()
    }

    func save(_ preset: Preset) {
        let preset = SlotOrder.normalized(preset)   // ④a：所有写入都落连续 sequenceIndex
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(_ preset: Preset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll(where: { $0.id == preset.id })
        persist()
    }

    func duplicate(_ preset: Preset) -> Preset {
        var copy = preset
        copy.id = UUID().uuidString
        copy.name = "\(preset.name) 副本"
        copy.isBuiltIn = false
        copy.ownerProfileId = nil          // 副本是模板（把当前楼层配置存成模板）
        copy.sourceTemplateId = nil
        presets.append(copy)
        persist()
        return copy
    }

    /// 导入酒馆 JSON 预设；notes 是 prompt_order 异常报告（空 = 按 100001 组导入），调用方负责提示
    func importFromSillyTavern(_ data: Data) throws -> (preset: Preset, notes: [String]) {
        let imported = try Preset.importSillyTavernJSON(data)
        var preset = imported.preset
        preset.id = UUID().uuidString // 新 ID，避免和已有预设冲突
        presets.append(preset)
        persist()
        return (preset: preset, notes: imported.notes)
    }

    // MARK: - Persistence

    private func persist() {
        do {
            if let loadError { throw loadError }
            try BlobStore.set(try JSONEncoder().encode(presets), forKey: Self.presetsKey, root: root)
        } catch { NSLog("预设保存失败：%@", error.localizedDescription) }
    }

}

// MARK: - App

#if os(macOS)
/// mac 的 app delegate（plan-mp-local-terminal §8）：**只为「终端里有 agent 在跑就先问一句」而存在**，
/// 除这几个方法（另加启动后挂 Sparkle 自动更新）外不接管任何默认行为。退出请求按来源分档（R-I8 B1）——注销 / 关机绝不挡，脚本不弹窗直接拒（否则
/// AppleScript 的 quit 会同步挂在这里等到 AE 超时），只有她本人的动作（⌘Q / 菜单 / Dock / app 内 terminate）才弹
final class MPAppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Sparkle 自动更新：Release 构建启动后延迟 start（Debug 不自动查；更新源未配置时是 no-op）
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !TestHostIsolation.active, NSClassFromString("XCTestCase") == nil else { return }
        AppUpdater.shared.startAfterLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 测试宿主也是这个 app（真正的护栏是测试不碰 .shared，这里只是保险，R-I8 I7）
        guard NSClassFromString("XCTestCase") == nil else { return .terminateNow }
        let store = LocalTerminalStore.shared
        store.refreshBadges()   // 判定别读上一秒的缓存（R-I8 I1）
        guard let text = LocalTerminalQuitPrompt.quit(store.quitItems) else { return .terminateNow }
        switch Self.quitSource() {
        case .system:
            return .terminateNow
        case .automation:
            CodingDiagnostics.log("退出请求来自脚本，但有终端在跑 agent，拒了：\(text.title)")
            return .terminateCancel
        case .userGesture:
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = text.title
            alert.informativeText = text.body
            // 一个按钮只能有一个 keyEquivalent（R-I8 I2）：Return 给「取消」，「退出」谁也不吃，手滑按不到
            let cancel = alert.addButton(withTitle: "取消")
            let quit = alert.addButton(withTitle: "退出")
            cancel.keyEquivalent = "\r"
            quit.keyEquivalent = ""
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    /// 当前这次 quit 是谁发的：AE 的 quit 带 `kAEQuitReason` = 注销 / 关机；发信方是 Dock 或压根没有 AE = 她本人
    private static func quitSource() -> LocalTerminalQuitPrompt.QuitSource {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else {
            return LocalTerminalQuitPrompt.source(isAppleEventQuit: false, hasQuitReason: false, senderName: nil)
        }
        let reason = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        return LocalTerminalQuitPrompt.source(isAppleEventQuit: true, hasQuitReason: reason != nil,
                                              senderName: sender.flatMap { LocalTerminalLaunch.processName($0) })
    }
}
#endif

/// 重启后还没解锁（BFU）时受数据保护的文件 open 会被拒（EPERM）
enum ProtectedDataGate {
    static func isLocked(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 { close(fd); return false }
        return errno == EPERM
    }
}

@main
enum AppEntry {
    static func main() {
        LaunchMarks.mark("entry")   // 秒连尺子：启动分段锚点
        // #035：mac 单测宿主核对改道 + 换偏好 / 钥匙串 / 闸，核不上直接退出（正常启动什么都不做）
        TestHostIsolation.installIfTestHost()
        #if os(iOS)
        // #024：BFU 被后台拉起时库、楼层列表、UserDefaults 都读不到；照常启动会崩在建容器，
        // 或把读空的状态写回盘。此刻用户看不见 app，在任何初始化之前退出，什么都不碰
        if ProfileManager.launchGatePaths.contains(where: ProtectedDataGate.isLocked) {
            NSLog("[launch-gate] protected data unavailable (BFU), exiting before init")
            exit(0)
        }
        #endif
        MemoryPalaceApp.main()
    }
}

struct MemoryPalaceApp: App {
    private let connectRulerPropsMark: Void = LaunchMarks.mark("props")   // 秒连尺子：属性初始化开始
    #if (DEBUG || PERF_BENCH) && os(iOS)
    private let launchPropertyAnchor: Void = LaunchTrace.start()
    #endif
    #if os(iOS)
    // 在 ThemeManager / ModelContainer 等属性和 App.init 之前并行准备开屏位图。
    private let launchArtworkAnchor: Void = LaunchSplash.preload()
    #endif
    #if os(macOS)
    @FocusedValue(\.macWorkspaceActions) private var macWorkspaceActions: MacWorkspaceActions?
    #endif
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #else
    @NSApplicationDelegateAdaptor(MPAppDelegate.self) private var appDelegate
    @State private var workspacePreferences = MacWorkspacePreferences.shared
    #endif
    #if (DEBUG || PERF_BENCH) && os(iOS)
    @State private var themeManager = LaunchTrace.measure("property.themeManager") { ThemeManager.shared }
    #else
    @State private var themeManager = ThemeManager.shared
    #endif
    @State private var profileManager: ProfileManager
    #if (DEBUG || PERF_BENCH) && os(iOS)
    @State private var providerManager = LaunchTrace.measure("property.providerManager") { ProviderManager() }
    #else
    @State private var providerManager = ProviderManager()
    #endif
    private let connectRulerProvidersMark: Void = LaunchMarks.mark("propProviders")
    @State private var presetManager: PresetManager
    #if (DEBUG || PERF_BENCH) && os(iOS)
    @State private var cardManager = LaunchTrace.measure("property.cardManager") { CharacterCardManager() }
    #else
    @State private var cardManager = CharacterCardManager()
    #endif
    private let connectRulerCardsMark: Void = LaunchMarks.mark("propCards")
    #if (DEBUG || PERF_BENCH) && os(iOS)
    @State private var toolManager = LaunchTrace.measure("property.toolManager") { RightPanelToolManager() }
    #else
    @State private var toolManager = RightPanelToolManager()
    #endif
    #if (DEBUG || PERF_BENCH) && os(iOS)
    @State private var globalWorldBookManager = LaunchTrace.measure("property.globalWorldBookManager") { GlobalWorldBookManager.makeLive() }
    #else
    @State private var globalWorldBookManager = GlobalWorldBookManager.makeLive()
    #endif
    #if (DEBUG || PERF_BENCH) && os(iOS)
    @State private var rightPanelNavigator = LaunchTrace.measure("property.rightPanelNavigator") { RightPanelNavigator() }
    #else
    @State private var rightPanelNavigator = RightPanelNavigator()
    #endif
    #if (DEBUG || PERF_BENCH) && os(iOS)
    @State private var mcpProvider = LaunchTrace.measure("property.mcpProvider") { MCPProvider.shared }
    #else
    @State private var mcpProvider = MCPProvider.shared
    #endif

    init() {
        LaunchMarks.mark("initBegin")
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.event("appPropertiesEnd")
        PerfHarness.appInit()
        if AirPerfProbe.enabled { AirPerfProbe.shared.start() }
        if AirStallSentinel.enabled { AirStallSentinel.start() }
        let launchInitSpan = LaunchTrace.begin("appInit")
        defer { LaunchTrace.end("appInit", launchInitSpan); LaunchTrace.event("appInitEnd"); LaunchTrace.sampleMemory("appInitEnd") }
        #endif
        let t0 = CFAbsoluteTimeGetCurrent()
        #if os(macOS)
        // 编程会话服务层的诊断接到调试页（W-N N6：服务层要编进 mp-code，不能直接引用 CacheDiagLog）
        CodingDiagnostics.setSink { CacheDiagLog.shared.log($0) }
        // 长期卡顿探针（plan-mac-hang-probe）：卡顿时记当时在哪
        HangProbe.context = {
            let layout = IPadPanelLayout.shared
            return "code=\(CodingSessionLibrary.shared.isActive ? 1 : 0) tool=\(layout.selectedTool ?? "-") tools=\(layout.openTools.count)"
        }
        HangProbe.shared.start()
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("fonts.bundled") { FontManager.registerBundledFonts() }
        #else
        FontManager.registerBundledFonts()
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("fonts.imported") { FontManager.registerImportedFonts() }
        #else
        FontManager.registerImportedFonts()
        #endif
        let tFont = CFAbsoluteTimeGetCurrent()

        BunnyLegacyStoreGuard.runIfNeeded()   // [Bunny patch BP-006] 换车保护：旧兔库原样挪开，绝不用新 schema 打开

        // 全量备份导入：two-phase crash-resumable apply（G-C.2）
        // **必须在 makeUnifiedContainer() 之前** — codex Round 3 强烈建议 #7
        // .pending-import.json flag 存在 → archive 主位 + install staging；done 后正常启动
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let pendingResult = LaunchTrace.measure("pending.apply") { PendingImportApplier.applyIfNeeded() }
        #else
        let pendingResult = PendingImportApplier.applyIfNeeded()
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("pending.handle") { Self.handlePendingImportResult(pendingResult) }
        #else
        Self.handlePendingImportResult(pendingResult)
        #endif
        LaunchMarks.bootstrapEligible(after: pendingResult)   // 秒连尺子：BFU 闸 + pending import 都过了，照理可以开始连（A2 起跑线）
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("archives.prune") { PendingImportApplier.pruneOldArchives() }
        #else
        PendingImportApplier.pruneOldArchives()
        #endif

        // 路线 B: 1 个 unified container. app lifetime 内不换.
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let container = LaunchTrace.measure("container") { ProfileManager.makeUnifiedContainer() }
        #else
        let container = ProfileManager.makeUnifiedContainer()
        #endif
        LaunchMarks.mark("container")
        // 卡库 ⑧c：酒馆整包导入留下未完成批次 → 先按完整清单恢复，再让各管理器读存储（plan §6.2-3）
        if SillyTavernImportCommitter.recoverAtLaunch(container: container) != .none {
            LaunchMarks.note("rec:stRecover")
            // 全局书管理器在属性初始化时已读过存储，恢复后重读
            self._globalWorldBookManager = State(initialValue: GlobalWorldBookManager.makeLive())
        }

        #if (DEBUG || PERF_BENCH) && os(iOS)
        let loaded = LaunchTrace.measure("profiles.load") { ProfileManager.loadProfilesChecked() }
        #else
        let loaded = ProfileManager.loadProfilesChecked()
        #endif
        LaunchMarks.mark("profiles")
        let profiles = loaded.profiles
        // #037：读坏时 profiles 是 seed，下面这些「按楼层列表写别的数据」的启动步骤一律跳过
        let profilesTrusted = loaded.error == nil
        if !profilesTrusted { LaunchMarks.note("rec:profilesUntrusted") }
        if profilesTrusted {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            LaunchTrace.measure("fileLibrary.prepare") { FileLibraryStore.prepareProfiles(profiles) }
            #else
            FileLibraryStore.prepareProfiles(profiles)
            #endif
            #if (DEBUG || PERF_BENCH) && os(iOS)
            LaunchTrace.measure("fileLibrary.prune") { FileLibraryStore.pruneSlugMap(keeping: Set(profiles.map(\.id))) }
            #else
            FileLibraryStore.pruneSlugMap(keeping: Set(profiles.map(\.id)))
            #endif
        }
        let lastId = UserDefaults.standard.string(forKey: "lastProfileId") ?? "ghost-lily"
        let current = profiles.first(where: { $0.id == lastId }) ?? profiles.first ?? Profile.seedProfiles[0]

        let tUnified = CFAbsoluteTimeGetCurrent()

        #if (DEBUG || PERF_BENCH) && os(iOS)
        let legacySpan = LaunchTrace.begin("legacyMigration")
        LaunchTrace.event("migrationState", fields: ["unified": UserDefaults.standard.bool(forKey: "hasUnifiedContainerMigrationV1"),
            "orphanAudit": UserDefaults.standard.bool(forKey: "orphanProfileAuditV1Done")])
        #endif
        // [probe-3] needsMigration check 前 — 看 sentinel + legacy 文件状态 + 决定
        let probe3Sentinel = UserDefaults.standard.bool(forKey: "hasUnifiedContainerMigrationV1")
        let probe3DefaultExists = FileManager.default.fileExists(atPath: Profile.legacyDefaultStoreURL.path)
        let probe3NeedsMig = UnifiedContainerMigration.needsMigration(profiles: profiles)
        NSLog("[probe-3] migration check: sentinel=\(probe3Sentinel) defaultExists=\(probe3DefaultExists) needsMig=\(probe3NeedsMig)")

        // 检测 legacy per-profile store 存在且没迁过 → 同步跑迁移
        // #037：读坏时拿 seed 跑完会落 done 标记，真楼层以后再也不迁
        if profilesTrusted, UnifiedContainerMigration.needsMigration(profiles: profiles) {
            print("[migration] legacy stores detected, running unified migration...")
            LaunchMarks.note("rec:unifiedMigration")
            let ctx = ModelContext(container)
            // 迁移走批删 + 大批插入，而且发生在索引接 didSave 之前：边车整个作废重建
            SearchIndexStore.removeFiles()
            do {
                try UnifiedContainerMigration.runMigration(profiles: profiles, unifiedCtx: ctx)
            } catch {
                print("[migration] FAILED: \(error)")
                // fail-safe: 不 crash. 让 app 启动（可能空）, 粟粟可查 .backup 手动恢复
            }
        }

        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.end("legacyMigration", legacySpan)
        let pm = LaunchTrace.measure("profileManager") { ProfileManager(container: container, profiles: profiles, currentProfile: current, loadError: loaded.error) }
        #else
        let pm = ProfileManager(container: container, profiles: profiles, currentProfile: current, loadError: loaded.error)
        #endif
        let cards = CharacterCardManager()
        cards.insertSampleCardIfNeeded()
        LaunchMarks.mark("cards")
        self._cardManager = State(initialValue: cards)
        pm.characterCardManager = cards
        RegexPipeline.liveCards = cards
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfHarness.prepare(pm: pm)
        #endif
        if profilesTrusted { VoiceServiceMigration.runAtLaunch(profileManager: pm) }
        let tProfile = CFAbsoluteTimeGetCurrent()
        self._profileManager = State(initialValue: pm)
        // 修全局卡顿：当前楼层的文件清单启动就后台预热（主线程只读缓存）
        if profilesTrusted { FileLibraryStore.warmList(profileId: pm.currentProfile.id) }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let psm = LaunchTrace.measure("presetManager") { PresetManager() }
        #else
        let psm = PresetManager()
        #endif
        // #037：seed 楼层指着共享内置模板，只读期间编辑人设会直接改模板；预设也一起只读
        if let error = loaded.error { psm.blockWrites(error) }
        if profilesTrusted {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            LaunchTrace.measure("fixup.presets") { Self.migratePresetInstances(profileManager: pm, presetManager: psm) }
            #else
            Self.migratePresetInstances(profileManager: pm, presetManager: psm)
            #endif
        }
        self._presetManager = State(initialValue: psm)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("fixup.notes") { Self.migrateMemoryNotesIfNeeded(container: pm.container) }
        #else
        Self.migrateMemoryNotesIfNeeded(container: pm.container)
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("fixup.orphans") { Self.auditOrphanProfileRowsIfNeeded(container: pm.container) }
        #else
        Self.auditOrphanProfileRowsIfNeeded(container: pm.container)
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("fixup.summary") { SummaryFileStore.migrateFromUserDefaultsIfNeeded(container: pm.container) }
        #else
        SummaryFileStore.migrateFromUserDefaultsIfNeeded(container: pm.container)
        #endif
        // S4.5：业务字段 isDeleted → isTrashed（一次性 batch，sentinel 防重复）
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("fixup.trash") { TrashedFieldMigration.run(container: pm.container) }
        #else
        TrashedFieldMigration.run(container: pm.container)
        #endif
        // 刀4（plan-memory-usable）：全量在场迁移——清显式检索开关旧键 + 旧预算 2000
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("fixup.memoryFlags") {
            MemoryFlags.migrateFullPresenceIfNeeded()
            MemoryFlags.migrateProfileInjectionSplitIfNeeded()
        }
        #else
        MemoryFlags.migrateFullPresenceIfNeeded()
        MemoryFlags.migrateProfileInjectionSplitIfNeeded()
        #endif
        // 权限 P1（plan-权限管理 §4）：旧 Bool 闸 → 三档；老装机无显式值按旧默认保行为，新装吃收紧后的默认
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("fixup.permissions") { PermissionCenter.migrateIfNeeded(container: pm.container) }
        #else
        PermissionCenter.migrateIfNeeded(container: pm.container)
        #endif

        #if DEBUG || PERF_BENCH
        MetricsRecorder.shared.start()
        #endif

        // AUTONOMY：hub 自主任务 outbox 落库（目录空 = 秒过；实时档等 Phase 2 接 WS 通知）
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("outbox") { AgentOutboxDrainer.drain(context: ModelContext(pm.container)) }
        #else
        AgentOutboxDrainer.drain(context: ModelContext(pm.container))
        #endif

        #if DEBUG && os(iOS)
        ProbeStickerSeed.resetLogFile()
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        ProbeStickerSeed.injectIfNeeded(container: pm.container, profileId: pm.currentProfile.id)
        UIRegressionSeed.injectIfNeeded(container: pm.container, profileId: pm.currentProfile.id)
        #endif
        #if DEBUG && os(iOS)
        KeyboardProbeSeed.injectIfNeeded(container: pm.container, profileId: pm.currentProfile.id)
        SearchProbeSeed.injectIfNeeded(container: pm.container, profileId: pm.currentProfile.id)
        PerfBenchSeed.injectIfNeeded(pm: pm)
        #endif
        #if DEBUG
        StreamSmokeSeed.injectIfNeeded(pm: pm, providers: providerManager)
        Page0ListSeed.injectIfNeeded(container: pm.container, profileId: pm.currentProfile.id)
        #endif
        #if DEBUG && os(iOS)
        PerfBenchSeed.guardNormalLaunch(pm: pm)
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfFloorGuard.run(pm: pm)   // perf P0 §3.3：PERF 包正常启动落在测试楼层也切回原楼层；Debug 旧防呆已先跑
        if PerfHarness.strictMeasure { PerfHarness.providers = providerManager; PerfHarness.presets = psm }
        #endif
        // S5 全文索引：后台低优先级回填 / 对账，不挡首屏。测试宿主不跑（宿主是 app 本体，会碰她的真库）
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            SearchIndexer.shared.start(container: pm.container, profileIds: profiles.map(\.id), delay: 3)
            // 日历按天统计：只挂保存监听（标脏），真正扫描等打开日历时再做
            CalendarActivityIndex.shared.start(container: pm.container)
            #if os(iOS)
            ChatParagraphPrewarm.schedule()   // perf L1 ①：正文段落视图池空闲预热
            #endif
        }
        let tMigrate = CFAbsoluteTimeGetCurrent()
        print(String(format: "[PERF] App.init total=%.0fms font=%.0fms unified=%.0fms profile=%.0fms migrate=%.0fms",
                     (tMigrate - t0) * 1000,
                     (tFont - t0) * 1000,
                     (tUnified - tFont) * 1000,
                     (tProfile - tUnified) * 1000,
                     (tMigrate - tProfile) * 1000))
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("breadcrumb") { BreadcrumbLog.shared.add("🚀", "启动 \(FeedbackStore.appVersionLine)") }
        #else
        BreadcrumbLog.shared.add("🚀", "启动 \(FeedbackStore.appVersionLine)")
        #endif
        // models.dev 模型目录：后台读缓存，过期（>1 天）再后台刷新；失败保旧缓存（research-magpie 2.5）
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.measure("modelCatalog") { ModelCatalog.shared.bootstrap() }
        #else
        ModelCatalog.shared.bootstrap()
        #endif

        // SBX-T0 runway 探针：只在 -sandboxT0Probe 1 / UserDefaults 开时跑（离线沙箱 Phase 2 前置）
        #if os(iOS) && DEBUG
        SandboxProbe.runIfRequested()
        #endif
        LaunchMarks.mark("initEnd")
    }

    /// 启动期 pending import 结果处理（G-C.2 + plan v2 R-4 失败恢复路径）。
    /// noFlag = 正常；其他三种情况都 print 探针 + 关键失败时显式提示 reverseRollback。
    /// 即便 versionMismatch/failedAtStep，主位永不被**完整**破坏（路线 A + verifyPrimaryStore 双闸）。
    private static func handlePendingImportResult(_ result: PendingImportApplier.ApplyResult) {
        switch result {
        case .noFlag:
            return
        case .versionMismatch(let reason):
            print("[PendingImport] ⚠️ versionMismatch: \(reason)")
            print("[PendingImport] Main library untouched; UI 'cleanup' button should be exposed in DataSettingsTab.")
        case .succeeded:
            print("[PendingImport] ✅ apply succeeded — main library replaced with staging.")
        case .failedAtStep(let step, let error):
            print("[PendingImport] ❌ failed at \(step.rawValue): \(error.localizedDescription)")
            print("[PendingImport] Marker preserved; user 三选一：")
            print("[PendingImport]   1) 继续重试 — 重启 app 让 applyIfNeeded() 续作 marker.completedSteps")
            print("[PendingImport]   2) 放弃恢复原状 — 调 PendingImportApplier.reverseRollback() 反向 move archive 回主位")
            print("[PendingImport]   3) 重启再试 — 不动 marker 自然重跑")
            // plan v2 R-4 关键提示：p2_verifyPrimary 失败时主位已被 staging-store 替换（P2.1+P2.2 完成）
            // 但 stickers/audiobooks/themes/floors 未动 — reverseRollback 把 store + external 反向
            // move 即可完整恢复（已在 PendingImportApplier.reverseRollback 实现内）。
            if case .primaryValidationFailed(let detail) = error {
                print("[PendingImport] 🔴 verifyPrimaryStore 失败 — 主位 store 已被置换但内容跟 expected 不符:")
                print("[PendingImport]   \(detail)")
                print("[PendingImport]   reverseRollback 会把主位 store + external 反向 move 回 archive/<ISO>/")
            }
            // v1.5 SplashView 接入 UI 三选一；当前走 print 探针 + 主位状态在 archive/<ISO>/ 可手动恢复
        }
    }

    /// 预设楼层实例化迁移：每楼层从当前 presetId 指向的对象 copy 一份实例（继承现状），
    /// 之后各层互不干涉。幂等：presetId 已指向自己的实例则跳过。
    /// 顺带把楼层编辑器写过的 profile.systemPrompt 救进实例 main 槽（旧组装链读不到它）。
    /// Plan: docs/plan-preset-floor-instance.md
    private static func migratePresetInstances(profileManager: ProfileManager, presetManager: PresetManager) {
        var migratedAny = false
        for var profile in profileManager.profiles {
            let resolved = presetManager.preset(byId: profile.presetId)
            if resolved?.ownerProfileId == profile.id { continue }
            var inst = presetManager.instantiate(templateId: profile.presetId, for: profile.id)
            if !profile.systemPrompt.isEmpty,
               let idx = inst.prompts.firstIndex(where: { $0.id == PromptSlot.mainId }),
               inst.prompts[idx].content.isEmpty {
                inst.prompts[idx].content = profile.systemPrompt
                presetManager.save(inst)
            }
            profile.presetId = inst.id
            profileManager.updateProfile(profile)
            migratedAny = true
        }
        // 各层已继承现状 → 内置模板的插槽恢复出厂，之后新建的楼层拿到干净模板
        if migratedAny {
            for builtIn in Preset.allBuiltIn {
                if var tpl = presetManager.preset(byId: builtIn.id), tpl.ownerProfileId == nil {
                    tpl.prompts = builtIn.prompts
                    presetManager.save(tpl)
                }
            }
            print("[migration] preset floor instances created for \(profileManager.profiles.count) profiles")
        }

        // 一次性清理：后置提醒的旧出厂句每层一份长得一样，看着像跨楼层。
        // 只清精确匹配旧默认句的（自定义内容不动），新默认已改为空。
        let jailbreakCleanupKey = "jailbreakDefaultClearedV1"
        if !UserDefaults.standard.bool(forKey: jailbreakCleanupKey) {
            let legacyDefault = "保持角色设定，用自然的语气回应。"
            for var preset in presetManager.presets {
                guard let idx = preset.prompts.firstIndex(where: { $0.id == PromptSlot.jailbreakId }),
                      preset.prompts[idx].content == legacyDefault else { continue }
                preset.prompts[idx].content = ""
                presetManager.save(preset)
            }
            UserDefaults.standard.set(true, forKey: jailbreakCleanupKey)
        }

        // 一次性迁移：给所有现存 preset（模板+楼层实例）补「上下文摘要」插槽（粟粟：顺序=位置，自己排）。
        // 插在对话历史 marker 之前；没有该 marker 的 preset 追加到末尾。
        let ctxSlotKey = "ctxSummarySlotAddedV1"
        if !UserDefaults.standard.bool(forKey: ctxSlotKey) {
            for var preset in presetManager.presets {
                guard !preset.prompts.contains(where: { $0.id == PromptSlot.contextSummaryId }) else { continue }
                let historyOrder = preset.prompts.first(where: { $0.id == PromptSlot.chatHistoryId })?.injectionOrder
                let slot = PromptSlot(id: PromptSlot.contextSummaryId, name: "📝 上下文摘要", role: "system",
                                      isSystemPrompt: true, isMarker: true,
                                      injectionOrder: historyOrder.map { $0 - 1 } ?? (preset.prompts.map(\.injectionOrder).max() ?? 0) + 10)
                if let idx = preset.prompts.firstIndex(where: { $0.id == PromptSlot.chatHistoryId }) {
                    preset.prompts.insert(slot, at: idx)
                } else {
                    preset.prompts.append(slot)
                }
                presetManager.save(preset)
            }
            UserDefaults.standard.set(true, forKey: ctxSlotKey)
            print("[migration] context summary slot added to presets")
        }

        // 一次性迁移：补「用户画像」插槽（M5），插在 🧠 记忆插槽前
        let profileSlotKey = "userProfileSlotAddedV1"
        if !UserDefaults.standard.bool(forKey: profileSlotKey) {
            for var preset in presetManager.presets {
                guard !preset.prompts.contains(where: { $0.id == PromptSlot.userProfileId }) else { continue }
                let memOrder = preset.prompts.first(where: { $0.id == PromptSlot.memoryInjectionId })?.injectionOrder
                let slot = PromptSlot(id: PromptSlot.userProfileId, name: "🌙 用户画像", role: "system",
                                      isSystemPrompt: true, isMarker: true,
                                      injectionOrder: memOrder.map { $0 - 1 } ?? 39)
                if let idx = preset.prompts.firstIndex(where: { $0.id == PromptSlot.memoryInjectionId }) {
                    preset.prompts.insert(slot, at: idx)
                } else {
                    preset.prompts.append(slot)
                }
                presetManager.save(preset)
            }
            UserDefaults.standard.set(true, forKey: profileSlotKey)
            print("[migration] user profile slot added to presets")
        }

        // 一次性迁移：补「📅 时间轴」插槽（M6），插在用户画像前（没有就记忆前/末尾）
        let timelineSlotKey = "timelineSlotAddedV1"
        if !UserDefaults.standard.bool(forKey: timelineSlotKey) {
            for var preset in presetManager.presets {
                guard !preset.prompts.contains(where: { $0.id == PromptSlot.timelineId }) else { continue }
                let anchorIdx = preset.prompts.firstIndex(where: { $0.id == PromptSlot.userProfileId })
                    ?? preset.prompts.firstIndex(where: { $0.id == PromptSlot.memoryInjectionId })
                let anchorOrder = anchorIdx.map { preset.prompts[$0].injectionOrder }
                let slot = PromptSlot(id: PromptSlot.timelineId, name: "📅 时间轴", role: "system",
                                      isSystemPrompt: true, isMarker: true,
                                      injectionOrder: anchorOrder.map { $0 - 1 } ?? 38)
                if let idx = anchorIdx {
                    preset.prompts.insert(slot, at: idx)
                } else {
                    preset.prompts.append(slot)
                }
                presetManager.save(preset)
            }
            UserDefaults.standard.set(true, forKey: timelineSlotKey)
            print("[migration] timeline slot added to presets")
        }

        // 一次性迁移（B27）：补「🌍 世界书(前/后)」插槽，锚 charDescription ±1（与现状注入位一致，零体感）。
        // 导入预设已有这俩 marker 的跳过，保留其 order/enabled。
        let worldInfoSlotsKey = "worldInfoSlotsAddedV1"
        if !UserDefaults.standard.bool(forKey: worldInfoSlotsKey) {
            for var preset in presetManager.presets {
                var changed = false
                if !preset.prompts.contains(where: { $0.id == PromptSlot.worldInfoBeforeId }) {
                    let charIdx = preset.prompts.firstIndex(where: { $0.id == PromptSlot.charDescriptionId })
                    let anchorIdx = charIdx ?? preset.prompts.firstIndex(where: { $0.id == PromptSlot.mainId }).map { $0 + 1 }
                    let charOrder = charIdx.map { preset.prompts[$0].injectionOrder }
                    let slot = PromptSlot(id: PromptSlot.worldInfoBeforeId, name: "🌍 世界书(前)", role: "system",
                                          isSystemPrompt: true, isMarker: true,
                                          injectionOrder: charOrder.map { $0 - 1 } ?? 19)
                    preset.prompts.insert(slot, at: min(anchorIdx ?? 0, preset.prompts.count))
                    changed = true
                }
                if !preset.prompts.contains(where: { $0.id == PromptSlot.worldInfoAfterId }) {
                    let charIdx = preset.prompts.firstIndex(where: { $0.id == PromptSlot.charDescriptionId })
                    let charOrder = charIdx.map { preset.prompts[$0].injectionOrder }
                    let slot = PromptSlot(id: PromptSlot.worldInfoAfterId, name: "🌍 世界书(后)", role: "system",
                                          isSystemPrompt: true, isMarker: true,
                                          injectionOrder: charOrder.map { $0 + 1 } ?? 21)
                    if let idx = charIdx {
                        preset.prompts.insert(slot, at: idx + 1)
                    } else {
                        preset.prompts.append(slot)
                    }
                    changed = true
                }
                if changed { presetManager.save(preset) }
            }
            UserDefaults.standard.set(true, forKey: worldInfoSlotsKey)
            print("[migration] world info slots added to presets")
        }
    }

    /// P0-2 善后审计（dry-run）：统计 profileId=="" 的孤儿行——历史角色卡导入 bug 的产物，
    /// 写入后任何楼层都查不到。**只打印不动数据**，归位还是删除等粟粟看了清单再定
    /// （REFACTOR_PLAN.md B1）。查到零孤儿就置 done 标记不再跑；有孤儿则每次启动都报。
    private static func auditOrphanProfileRowsIfNeeded(container: ModelContainer) {
        let key = "orphanProfileAuditV1Done"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let context = ModelContext(container)
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == "" })
        let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == "" })
        let orphanConvs = (try? context.fetch(convDesc)) ?? []
        let orphanNodeCount = (try? context.fetchCount(nodeDesc)) ?? 0

        guard !orphanConvs.isEmpty || orphanNodeCount > 0 else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }
        print("[orphan-audit] ⚠️ 发现 profileId==\"\" 孤儿数据（P0-2 历史 bug 产物，任何楼层不可见）：对话 \(orphanConvs.count) 条 / 节点 \(orphanNodeCount) 条")
        for conv in orphanConvs.prefix(20) {
            print("[orphan-audit]   · 「\(conv.title)」 provider=\(conv.provider) 创建=\(conv.createTime) id=\(conv.id.prefix(8))…")
        }
        if orphanConvs.count > 20 {
            print("[orphan-audit]   …（其余 \(orphanConvs.count - 20) 条略）")
        }
        print("[orphan-audit] 仅统计不处理——归位/删除策略定了之后再写清理（REFACTOR_PLAN.md B1）")
    }

    /// MemoryNote → Memory 一次性迁移
    private static func migrateMemoryNotesIfNeeded(container: ModelContainer) {
        let key = "memoryMigrationV2Done"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let context = ModelContext(container)

        // 查询所有旧 MemoryNote
        let descriptor = FetchDescriptor<MemoryNote>()
        guard let oldNotes = try? context.fetch(descriptor), !oldNotes.isEmpty else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }

        for note in oldNotes {
            // 只迁移手动创建的，auto 的丢弃（重新提取更好）
            if note.source == "manual" {
                let memory = Memory(
                    content: note.content,
                    category: "fact",
                    keywords: [],
                    profileId: note.profileId,
                    isUserExplicit: true,
                    extractedBy: "migration"
                )
                memory.decayWeight = 1.0
                memory.createdAt = note.createdAt
                memory.updatedAt = note.updatedAt
                context.insert(memory)
            }
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    var body: some Scene {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = LaunchTrace.event("appSceneBody")
        #endif
        WindowGroup {
            LaunchSplashRoot {
            // 路线 B：container 全局唯一不动。切楼层只翻 currentProfile → ContentView
            // .id(currentProfile.id) 识别变化后 SwiftUI re-init 整棵 ContentView，所有
            // @Query 用新 profileId predicate 自动 refetch。因为 container 不变，不会有
            // @Model instance 被 destroy，view tree 不论怎么 dismount 都不 crash。
            // Plan: docs/plan-unified-container.md
            Group {
                #if DEBUG && os(iOS)
                // [PROBE 脚手架] simctl launch 传 --pop-tuner-probe 直开调音台（模拟器录屏逐帧
                // 诊断用，simctl 不能点导航）。真机/正常启动零影响。抓完弹泡案即删。
                if ProcessInfo.processInfo.arguments.contains("--pop-tuner-probe") {
                    NavigationStack { BubblePopTunerPage() }
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
                .preferredColorScheme(themeManager.preferredColorScheme)
                // askOnce 权限弹卡的宿主（T6c ②）：**挂在根上，两端都挂**。
                // 原来挂在 CardFlowView 上（:1427），跟 AskUserQuestionSheet / 预算 alert /
                // fileImporter 抢同一个 view 的 present 名额——别的挡着时这张弹不出来，
                // 而计时器照走 → 「点了允许却收到超时」（BUG-9，t6b-report §3）。
                .background(PermissionPromptHost())
                #if DEBUG && os(macOS)
                .modifier(MacLaunchHook())
                #endif
                // 离线沙箱（SBX-T1）：首启解压 / boot / 失败时顶部露一条状态提示，就绪即消失
                #if os(iOS)
                .sandboxStatusOverlay()
                #endif
                #if os(macOS)
                // plan-mac-shape ⧫a：对话面板最小 240 + 工具道 412 + 正文 320 = 972 取整（以前 800/500 + 全屏观察者硬提 900 两处打架）
                .frame(minWidth: 980, minHeight: 600)
                .background(WindowConfigurator(glass: MacGlass.shared.enabled))
                #endif
                .environment(themeManager)
                .environment(profileManager)
                .environment(providerManager)
                .environment(presetManager)
                .environment(cardManager)
                .environment(toolManager)
                .environment(globalWorldBookManager)
                .environment(rightPanelNavigator)
                .environment(mcpProvider)
                .regexHygieneCheck(presetManager: presetManager)   // 🔴破限事故迁移：详见 docs/plan-fix-regex-markdownonly-trap.md
                .modelContainer(profileManager.container)
                .id(profileManager.currentProfile.id)
                .task {
                    #if os(iOS)
                    // #042：通话控制器拿 manager 不经界面（锁屏接原生来电）
                    CallController.shared.attach(profileManager: profileManager, providerManager: providerManager, presetManager: presetManager)
                    #endif
                    // 第三刀：窗口收尾巡检拿 manager 不经发消息那条路（cc-bridge 楼层也能收尾）
                    SessionCloseoutTrigger.shared.attach(profileManager: profileManager, providerManager: providerManager)
                    SessionCloseoutTrigger.shared.request()
                    // M1 一次性迁移：ProviderManager 初始化时已重写 UserDefaults 里的复合 id；
                    // SwiftData Conversation.selectedModelId 需要 ModelContext，在这里补做。
                    let remap = providerManager.consumePendingConversationRemap()
                    if !remap.isEmpty {
                        let ctx = ModelContext(profileManager.container)
                        do {
                            let convs = try ctx.fetch(FetchDescriptor<Conversation>())
                            var changed = 0
                            for conv in convs {
                                let current = conv.selectedModelId
                                guard !current.isEmpty, let slash = current.firstIndex(of: "/") else { continue }
                                let oldPid = String(current[..<slash])
                                let modelPart = String(current[current.index(after: slash)...])
                                if let newId = remap[oldPid] {
                                    conv.selectedModelId = "\(newId)/\(modelPart)"
                                    changed += 1
                                }
                            }
                            if changed > 0 { try? ctx.save() }
                            print("[migration] Conversation.selectedModelId remapped: \(changed)")
                        } catch {
                            print("[migration] Conversation remap failed: \(error)")
                        }
                        providerManager.resolveStaleSelectedModel()
                        providerManager.resolveStaleFavorites()
                    }

                    // iCloud 文件库：容器 URL 首调会卡，启动即后台预热（开关关着是 no-op）
                    if FileLibraryStore.iCloudEnabled {
                        FileLibraryStore.primeICloudContainer()
                    }
                    // Mermaid 渲染器：冷启动就绪后后台预热（只排一次，perf 角色跳过；plan-mermaid M8）
                    MermaidRenderer.schedulePrewarm()
                    await HealthService.shared.refreshToday()
                    // 吃药提醒重注册（幂等；无药无提醒 = 清完即返）
                    await MedReminderScheduler.shared.resyncFromStore(
                        container: profileManager.container,
                        profileId: profileManager.currentProfile.id
                    )
                    mcpProvider.loadAndConnectEnabledServers()
                    // 冷启动必须在这里 start：scenePhase onChange 不响应初始值（老教训），
                    // 只靠它 = 引擎在冷启动后永不上岗
                    SyncEngine.shared.start(
                        profileId: profileManager.currentProfile.id,
                        container: profileManager.container
                    )
                    #if os(iOS)
                    ShakeMonitor.shared.start()
                    // 「常驻」不存在：以 Activity.activities 为事实核对本地 LA 注册表
                    CCLiveActivityManager.shared.recheck()
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    // S2.5 准实时：前台跑引擎（导出泵+云端监听），后台停引擎并最后推一把
                    let pid = profileManager.currentProfile.id
                    switch phase {
                    case .active:
                        SyncEngine.shared.start(profileId: pid, container: profileManager.container)
                        SearchIndexer.shared.requestReconcile(profileIds: profileManager.profiles.map(\.id))
                        SessionCloseoutTrigger.shared.request()
                        #if os(iOS)
                        ShakeMonitor.shared.start()
                        CCLiveActivityManager.shared.recheck()
                        #endif
                    case .background:
                        SyncEngine.shared.stop()
                        // 进后台顺手巡检一次：跑得完就完，跑不完下次回前台再补（水位线保证不重不漏）
                        SessionCloseoutTrigger.shared.request()
                        #if os(iOS)
                        ShakeMonitor.shared.stop()
                        #endif
                        let container = profileManager.container
                        // 同步 + 时间机器备份(独立开关). 任一开就跑, 都关就不进 async.
                        let syncOn = SyncStore.isEnabled(profileId: pid)
                        let backupOn = BackupStore.isEnabled
                        guard syncOn || backupOn else { return }
                        DispatchQueue.global(qos: .utility).async {
                            let bgContext = ModelContext(container)
                            if syncOn {
                                _ = SyncStore.exportChanged(profileId: pid, context: bgContext)
                            }
                            if backupOn {
                                _ = BackupStore.snapshotIfNeeded(context: bgContext)
                                BackupStore.pruneOldBackups()
                            }
                        }
                    default:
                        break
                    }
                }
                .onChange(of: profileManager.currentProfile.id) { _, newPid in
                    // 切楼层重启引擎（幂等；该楼层没开同步则 start 内部直接返回）
                    SyncEngine.shared.start(profileId: newPid, container: profileManager.container)
                    // 吃药提醒跟楼层走：不重注册会响别的楼层的药
                    Task { @MainActor in
                        await MedReminderScheduler.shared.resyncFromStore(
                            container: profileManager.container, profileId: newPid
                        )
                    }
                }
            }
        }
        #if os(macOS)
        // 必须是 hiddenTitleBar：`.automatic` + WindowConfigurator 手动改 fullSizeContentView / 透明标题栏，
        // 系统标题栏那 32pt 带会截走带内所有 mouseDown——停靠壳标题行的钮整颗落在带内，她用手点不动（09-18）。
        // 最小复现 app 对照过：automatic 带内钮收不到点击，hiddenTitleBar 收得到、空处照样拖窗。
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .help) { ManualHelpCommand() }
            // 记忆花园 › 检查更新…（Sparkle，AppUpdater）。未配置更新源时点了弹说明，不置灰
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { AppUpdater.shared.checkForUpdates() }
                    .disabled(AppUpdater.shared.isStarted && !AppUpdater.shared.canCheckForUpdates)
            }
            // 单窗口（plan-mac-shape ⧫5 分期 / ⧫d）：拿掉「新建窗口」，IPadPanelLayout.shared 一份存档只服务一扇窗；
            // 不用 Window scene——主 scene 是 Window 时关窗即退出 app，会连带停同步 / MCP / CC 连接。
            // S1-4：整组被 replace 成空块的副作用是连 ⌘N 也没了，这里把「新建对话」放回来。
            CommandGroup(replacing: .newItem) {
                Button("新建对话") {
                    NotificationCenter.default.post(name: .newConversationRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                // ⌘K 全局搜索（⇧⌘F 别名挂在 ContentView 的隐藏钮上）；code 组里侧栏搜索钮先吃 ⌘K，预选编程会话
                Button("全局搜索") { macWorkspaceActions?.search() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(macWorkspaceActions == nil)
                Button("对话列表") {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { IPadPanelLayout.shared.leftShown.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button("工具 Dock") {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { IPadPanelLayout.shared.dockShown.toggle() }
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                // plan-panel-ps 阶段 4：底栏 / 左栏折成图标 ⇄ 展开（右栏就是上面的「工具 Dock」）
                Button("底栏") {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { IPadPanelLayout.shared.toggleColumnCollapsed(.bottom) }
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                Button("折叠左栏") {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { IPadPanelLayout.shared.toggleColumnCollapsed(.left) }
                }
                Picker("面板模式", selection: Binding(
                    get: { IPadPanelLayout.shared.mode },
                    set: { m in withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { IPadPanelLayout.shared.mode = m } }
                )) {
                    ForEach(IPadPanelLayout.Mode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
            }
            // 命名工作区（plan-panel-ps 阶段 1）：存 / 切 / 重置 / 恢复默认
            CommandMenu("工作区") { PanelWorkspaceMenu() }
            CommandGroup(after: .toolbar) {
                // 缺值默认与设置页 / FontManager 的 @AppStorage 默认一致（1.2）；以前菜单按 1.0 两个默认打架（⧫i）
                Button("放大") {
                    let current = UserDefaults.standard.double(forKey: "fontScale")
                    let scale = current > 0 ? current : 1.2
                    UserDefaults.standard.set(min(scale + 0.1, 2.0), forKey: "fontScale")
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("缩小") {
                    let current = UserDefaults.standard.double(forKey: "fontScale")
                    let scale = current > 0 ? current : 1.2
                    UserDefaults.standard.set(max(scale - 0.1, 0.5), forKey: "fontScale")
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("重置缩放") {
                    UserDefaults.standard.set(1.2, forKey: "fontScale")
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("记录反馈…") {
                    NotificationCenter.default.post(name: .feedbackGestureTriggered, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        #endif

        #if os(macOS)
        // 菜单栏快看（research-magpie §2.6）：设置 › 工作区「在菜单栏显示」开关（默认开）
        MenuBarExtra(isInserted: Bindable(workspacePreferences).showMenuBarExtra) {
            MacMenuBarQuickLook()
                .preferredColorScheme(themeManager.preferredColorScheme)
        } label: {
            Image(systemName: "leaf")
        }
        .menuBarExtraStyle(.window)

        // 菜单栏 帮助 › 记忆花园 帮助：独立窗口，边看边用
        Window("外观控制台", id: "mac-appearance-console") {
            MacShellTuner()
        }
        .defaultSize(width: 540, height: 680)
        .windowResizability(.contentMinSize)

        Window("记忆花园 帮助", id: "manual") {
            ManualView()
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 900, height: 680)

        // 设置独立窗口（plan-mac-shape ⧫6，A5）：⌘, 系统自动挂。兄弟 scene **不继承**主 WindowGroup 内容树上注的
        // env，manager / modelContainer 要在这里再注一遍（astra F5：不注的话 API / Prompt / 右栏 页直接空）。
        // 只复用实例，不复制主窗的启动 task 链；切楼层跟主窗一样整棵重建
        Settings {
            SettingsView()
                .preferredColorScheme(themeManager.preferredColorScheme)
                .environment(themeManager)
                .environment(profileManager)
                .environment(providerManager)
                .environment(presetManager)
                .environment(cardManager)
                .environment(toolManager)
                .environment(globalWorldBookManager)
                .environment(rightPanelNavigator)
                .environment(mcpProvider)
                .modelContainer(profileManager.container)
                .id(profileManager.currentProfile.id)
        }
        .defaultSize(width: 860, height: 600)
        .windowToolbarStyle(.unified(showsTitle: true))   // 页名进 toolbar（Tahoe 系统设置同款）；主窗那份仍 showsTitle: false
        #endif
    }
}

// MARK: - Profile Switcher (sidebar)

struct ProfileSwitcher: View {
    @Bindable var profileManager: ProfileManager
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @State private var isHovered = false
    @State private var showCreateSheet = false
    @State private var editingProfile: Profile? = nil
    @State private var profileToDelete: Profile? = nil
    @State private var profileToImport: Profile? = nil

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // 设置-通用「楼层」卡（J2b 第 4 条）：第一行「当前楼层 ‹emoji 名字› 弹出菜单」，
            // 第二行把新建 / 编辑 / 删除从菜单里提出来当按钮。切换语义与 sheet/确认框全部沿用下面同一套 state。
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("当前楼层")
                        .font(ShellStyle.bodyFont.weight(.regular))
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(profileManager.profiles) { profile in
                            Button {
                                profileManager.switchTo(profile)
                            } label: {
                                HStack {
                                    Text("\(profile.emoji) \(profile.name)")
                                    if profile.id == profileManager.currentProfile.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(profileManager.currentProfile.emoji)
                                .font(.system(size: 14))
                            Text(profileManager.currentProfile.name)
                                .font(ShellStyle.bodyFont.weight(.regular))
                                .foregroundColor(Theme.textPrimary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.textMuted)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: ShellStyle.chipHeight)
                        .background(
                            RoundedRectangle(cornerRadius: ShellStyle.chipRadius)
                                .fill(isHovered ? ShellStyle.pressed : ShellStyle.hover)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .onHover { isHovered = $0 }
                }
                Rectangle().fill(ShellStyle.hairline).frame(height: ShellStyle.hairlineWidth)
                HStack(spacing: 8) {
                    Text(profileManager.currentProfile.description)
                        .font(ShellStyle.secondaryFont)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("新建楼层") { showCreateSheet = true }
                        .buttonStyle(MacSettingsButton())
                    Button("编辑当前楼层") { editingProfile = profileManager.currentProfile }
                        .buttonStyle(MacSettingsButton())
                    if profileManager.profiles.count > 1 {
                        Button("删除当前楼层") { profileToDelete = profileManager.currentProfile }
                            .buttonStyle(MacSettingsButton())
                    }
                }
            }
            #else
            Menu {
                ForEach(profileManager.profiles) { profile in
                    Button {
                        profileManager.switchTo(profile)
                    } label: {
                        HStack {
                            Text("\(profile.emoji) \(profile.name)")
                            if profile.id == profileManager.currentProfile.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    showCreateSheet = true
                } label: {
                    Label("新建楼层", systemImage: "plus.circle")
                }

                Button {
                    editingProfile = profileManager.currentProfile
                } label: {
                    Label("编辑当前楼层", systemImage: "pencil")
                }

                if profileManager.profiles.count > 1 {
                    Button(role: .destructive) {
                        profileToDelete = profileManager.currentProfile
                    } label: {
                        Label("删除当前楼层", systemImage: "trash")
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(profileManager.currentProfile.emoji)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profileManager.currentProfile.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text(profileManager.currentProfile.description)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Theme.accent.opacity(0.3) : Theme.accent.opacity(0.1))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            #endif
        }
        .sheet(isPresented: $showCreateSheet, onDismiss: handlePendingImport) {
            ProfileEditorSheet(
                profileManager: profileManager,
                mode: .create,
                onRequestImport: { profile in profileToImport = profile }
            )
        }
        .sheet(item: $editingProfile, onDismiss: handlePendingImport) { profile in
            ProfileEditorSheet(
                profileManager: profileManager,
                mode: .edit(profile),
                onRequestImport: { profile in profileToImport = profile }
            )
        }
        .confirmationDialog(
            "删除楼层",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("仅移除（保留数据）", role: .destructive) {
                if let p = profileToDelete {
                    profileManager.deleteProfile(p, deleteData: false)
                    presetManager?.deleteInstances(ownerProfileId: p.id)   // 实例跟楼层走
                }
                profileToDelete = nil
            }
            Button("删除楼层和所有数据", role: .destructive) {
                if let p = profileToDelete {
                    profileManager.deleteProfile(p, deleteData: true)
                    presetManager?.deleteInstances(ownerProfileId: p.id)
                }
                profileToDelete = nil
            }
            Button("取消", role: .cancel) { profileToDelete = nil }
        } message: {
            if let p = profileToDelete {
                Text("确定要删除「\(p.emoji) \(p.name)」吗？")
            }
        }
    }

    /// ProfileEditorSheet dismiss 后，如果用户点了「导入聊天记录」，切到目标楼层再发请求导入的 notification
    /// （ContentView observe 并弹 ImportView；这样 sheet 不受 ProfileSwitcher 所在 view tree 重建影响）。
    private func handlePendingImport() {
        guard let profile = profileToImport else { return }
        profileToImport = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if profile.id != profileManager.currentProfile.id {
                profileManager.switchTo(profile)
            }
            NotificationCenter.default.post(name: .memoryPalaceRequestImport, object: nil)
        }
    }
}

extension Notification.Name {
    /// ProfileSwitcher 请求弹 ImportView（用户从「导入聊天记录」进入）。由 ContentView observe。
    static let memoryPalaceRequestImport = Notification.Name("MemoryPalaceRequestImport")

    /// ProfileManager.switchTo 即将切换 currentProfile + container 之前发出。
    /// 订阅者（ConversationViewModel / PagingViewController / MemoryPanelView 等）
    /// 应立即清空对旧 SwiftData 实例的所有 retain，避免路线 C 下旧 SwiftUI sub-tree
    /// 在 container 替换后再跑一次 body 读已 reset 实例触发 fatal。
    /// 见 docs/plan-profile-switch-atomic.md
    static let profileWillSwitch = Notification.Name("MemoryPalaceProfileWillSwitch")

    /// 小克通过文件工具写/改/删文件后发出，FileLibraryPanelView 订阅刷新。
    static let fileLibraryDidChange = Notification.Name("MemoryPalaceFileLibraryDidChange")

    /// AUDN 后台提取记忆并写入后发出，MemoryPanelView 订阅刷新（让自动记忆可见）。
    static let memoryDidChange = Notification.Name("MemoryPalaceMemoryDidChange")

    /// 搜索结果点击后请求把 iOS page 自动切到 chat（page=1）。
    /// 由 SidebarView.navigateToNodeById 发，ContentView 订阅。
    /// 用通知是因为同一对话内点击不会触发 selectedConversation?.id 变化。
    static let conversationNavigationRequested = Notification.Name("MemoryPalaceConversationNavigationRequested")

    /// ⌘N 新建对话（S1-4）。菜单「文件 › 新建对话」发，ContentView 订阅 → 起一条草稿。
    /// 走通知是因为 `commands` 在 scene 层，拿不到 ContentView 的 viewModel（`.memoryPalaceRequestImport` 同款）。
    static let newConversationRequested = Notification.Name("MemoryPalaceNewConversationRequested")

    /// 点击 APNs 推送后请求打开对应会话（chat_id 存在 UserDefaults"pendingPushChatId"）。
    /// PushAppDelegate.didReceive 发，ContentView 订阅 → 取会话跳转。
    static let pushConversationRequested = Notification.Name("MemoryPalacePushConversationRequested")

    /// assistant turn 收口（含工具循环全程；error/cancel 也发）。
    /// ConversationViewModel.finishAssistantTurn 发，userInfo: nodeId/conversationId。
    /// CR-3 vocab aiNote 回填 + CR-1 aiBubble 回填订阅（ContentView）。
    static let assistantTurnDidFinish = Notification.Name("MemoryPalaceAssistantTurnDidFinish")

    /// notes.json 被后台改写（aiBubble 回填）。userInfo: safeName。
    /// 开着的 BookReaderSheet 订阅 → reload + rerender（占位卡变真回答）。
    static let bookNotesDidChange = Notification.Name("MemoryPalaceBookNotesDidChange")

    /// ConversationTag 本体（增 / 删 / 改 order）被写入后发出。
    /// SidebarView 的 tag 列表从 `@Query` 改成显式 fetch（input-jank C4：@Query 随每次
    /// `modelContext.save()` 失效，打字落盘 / 流式每 token 都驱动整条会话列表重 diff），
    /// 失去了自动刷新，靠这条通知补回。**发送方 = 所有 ConversationTag 写点**，
    /// 见 docs/plan-input-jank-2.md §2 写点全集。
    /// FavoriteItem（tag ↔ 会话 join）变更不发——只改会话归属，不改 tag 列表。
    static let conversationTagsChanged = Notification.Name("MemoryPalaceConversationTagsChanged")
}

// MARK: - Profile Editor Sheet

struct ProfileEditorSheet: View {
    let profileManager: ProfileManager
    let mode: Mode
    /// 用户点「导入聊天记录」时触发（保存后），上层负责 switchTo + 弹 ImportView。
    var onRequestImport: ((Profile) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    @State private var importAfterSave = false
    @FocusState private var nameFieldFocused: Bool

    enum Mode: Identifiable {
        case create
        case edit(Profile)
        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let p): return p.id
            }
        }
    }

    @State private var name = ""
    @State private var emoji = ""
    @State private var description = ""
    @State private var userName = "你"
    @State private var assistantName = ""
    @State private var systemPrompt = ""
    @State private var preferredModel = "anthropic/claude-sonnet-4"

    // 角色卡导入
    @State private var characterDescription = ""
    @State private var characterPersonality = ""
    @State private var scenario = ""
    @State private var chatExamples = ""
    @State private var postInstructions = ""
    @State private var characterTimeZone = ""
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var cardImportSummary: String?

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// IANA 校验，无效存 nil（开关留着但注入端会静默跳过）
    private var normalizedTimeZone: String? {
        let t = characterTimeZone.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, TimeZone(identifier: t) != nil else { return nil }
        return t
    }

    private var normalizedEmoji: String {
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEmoji.isEmpty {
            return trimmedEmoji
        }
        return "🌸"
    }

    private var title: String {
        switch mode {
        case .create: return "新建楼层"
        case .edit: return "编辑楼层"
        }
    }

    var body: some View {
        let _ = themeManager?.themeChangeID
        Group {
            #if os(iOS)
            iOSBody
            #else
            macOSBody
            #endif
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json, .png],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard let cardManager, let presetManager else { return }
                do {
                    let card = try cardManager.importFromFile(url: url)
                    Task { @MainActor in
                        do {
                            let profile = try await cardManager.floors(profileManager: profileManager, presetManager: presetManager).enter(card: card)
                            navigator?.openCharacterHome(profileId: profile.id, cardId: card.id)
                            dismiss()
                        } catch { importError = error.localizedDescription }
                    }
                } catch { importError = error.localizedDescription }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("导入完成", isPresented: Binding(get: { cardImportSummary != nil }, set: { if !$0 { cardImportSummary = nil } })) {
            Button("好的") { cardImportSummary = nil }
        } message: { Text(cardImportSummary ?? "") }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好的") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onAppear {
            switch mode {
            case .create:
                if emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emoji = "🌸"
                }
            case .edit(let profile):
                name = profile.name
                emoji = profile.emoji
                description = profile.description
                userName = profile.userName
                assistantName = profile.assistantName
                // 单一来源 = 楼层实例 main 槽；实例缺失（异常路径）才退回 profile 字段
                if let inst = presetManager?.preset(byId: profile.presetId), inst.ownerProfileId == profile.id {
                    systemPrompt = inst.prompts.first(where: { $0.id == PromptSlot.mainId })?.content ?? ""
                } else {
                    systemPrompt = profile.systemPrompt
                }
                preferredModel = profile.preferredModel
                characterTimeZone = profile.characterTimeZone ?? ""
            }
        }
    }

    #if os(iOS)
    private var iOSBody: some View {
        editorNavigation
    }
    #endif

    private var macOSBody: some View {
        editorNavigation
            .frame(width: 460, height: 620)
    }

    private var editorNavigation: some View {
        NavigationStack {
            List {
                if case .create = mode {
                    Section("助手模板") {
                        characterCardImportRow
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)
                }

                Section("聊天记录") {
                    conversationImportRow
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("基本信息") {
                    HStack(spacing: 12) {
                        Text("图标")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)

                        Spacer()

                        TextField("🌸", text: $emoji)
                            .textFieldStyle(.plain)
                            .font(.system(size: 24))
                            .frame(width: 56)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 12) {
                        Text("楼层名")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)

                        TextField("例：二层阁楼", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                            .focused($nameFieldFocused)
                    }
                    labeledFieldRow(label: "描述", placeholder: "例：对话空间", text: $description)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("角色时区") {
                    labeledFieldRow(label: "时区", placeholder: "例：Asia/Shanghai", text: $characterTimeZone)
                    let tzInput = characterTimeZone.trimmingCharacters(in: .whitespaces)
                    if !tzInput.isEmpty && TimeZone(identifier: tzInput) == nil {
                        Text("时区名无效——用 IANA 名，如 Asia/Shanghai、Asia/Tokyo、America/New_York")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.danger)
                    } else {
                        Text("填了之后，问候和作息（深夜/清晨/工作时间）按角色的本地时间算。总开关在 设置 → Agent → 作息感知。")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("气泡标签") {
                    labeledFieldRow(label: "我", placeholder: "你", text: $userName)
                    labeledFieldRow(label: "AI", placeholder: "名字", text: $assistantName)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                // 「默认模型」一节已撤（#092 / 粟粟 10-14 拍 K4）：profile.preferredModel 从来没有地方读，
                // 选项还是内置预设不是用户的卡。字段留着保兼容，保存时原样写回。
                Section("系统提示词") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这里会作为当前楼层默认的系统提示词。")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)

                        TextEditor(text: $systemPrompt)
                            .font(.system(size: Theme.F.body))
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Theme.sidebarBg)
                            )
                            .scrollContentBackground(.hidden)
                    }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.plain)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定", action: save)
                        .foregroundColor(isValid ? Theme.branchIndicator : Theme.textMuted)
                        .disabled(!isValid)
                }
            }
        }
        .background(Theme.sidebarBg)
    }

    private var conversationImportRow: some View {
        Button {
            guard isValid else {
                nameFieldFocused = true
                return
            }
            importAfterSave = true
            save()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.branchIndicator.opacity(0.14))
                        .frame(width: 34, height: 34)

                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.branchIndicator)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("导入聊天记录")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)

                    Text("保存楼层后，打开 ChatGPT / Claude 导出包（zip / 文件夹 / json）导入对话。")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.F.secondary, weight: .semibold))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var characterCardImportRow: some View {
        Button {
            showFileImporter = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.branchIndicator.opacity(0.14))
                        .frame(width: 34, height: 34)

                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.branchIndicator)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("导入角色卡")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)

                    Text("支持 JSON / PNG，导入后进入这张卡的新楼层。")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.F.secondary, weight: .semibold))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func labeledFieldRow(
        label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textSecondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.F.body))
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalEmoji = normalizedEmoji
        guard !trimmedName.isEmpty else { return }

        switch mode {
        case .create:
            var profile = Profile(
                name: trimmedName,
                emoji: finalEmoji,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                userName: userName.isEmpty ? "你" : userName,
                assistantName: assistantName.trimmingCharacters(in: .whitespaces),
                systemPrompt: systemPrompt,
                preferredModel: preferredModel,
                characterDescription: characterDescription,
                characterPersonality: characterPersonality,
                scenario: scenario,
                chatExamples: chatExamples,
                postInstructions: postInstructions
            )
            profile.characterTimeZone = normalizedTimeZone
            profileManager.addProfile(profile)
            instantiatePreset(for: &profile)

            if importAfterSave { onRequestImport?(profile) }

        case .edit(let existing):
            var updated = existing
            updated.name = trimmedName
            updated.emoji = finalEmoji
            updated.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.userName = userName.isEmpty ? "你" : userName
            updated.assistantName = assistantName.trimmingCharacters(in: .whitespaces)
            updated.systemPrompt = systemPrompt
            updated.preferredModel = preferredModel
            updated.characterTimeZone = normalizedTimeZone
            profileManager.updateProfile(updated)
            // 系统提示词单一来源 = 楼层实例 main 槽（组装链读这里，profile.systemPrompt 只是暂存）
            if let psm = presetManager,
               var inst = psm.preset(byId: updated.presetId), inst.ownerProfileId == updated.id,
               let idx = inst.prompts.firstIndex(where: { $0.id == PromptSlot.mainId }) {
                inst.prompts[idx].content = systemPrompt
                psm.save(inst)
            }

            if importAfterSave { onRequestImport?(updated) }
        }

        dismiss()
    }

    /// 新楼层：从其 presetId 模板 deep copy 实例，并把表单系统提示词/卡的后置指令写进槽位
    private func instantiatePreset(for profile: inout Profile) {
        guard let psm = presetManager else { return }
        var inst = psm.instantiate(templateId: profile.presetId, for: profile.id)
        if let idx = inst.prompts.firstIndex(where: { $0.id == PromptSlot.mainId }) {
            inst.prompts[idx].content = systemPrompt
        }
        if !postInstructions.isEmpty,
           let idx = inst.prompts.firstIndex(where: { $0.id == PromptSlot.jailbreakId }) {
            inst.prompts[idx].content = postInstructions
        }
        psm.save(inst)
        profile.presetId = inst.id
        profileManager.updateProfile(profile)
    }


}

#if os(macOS)
// MARK: - NSWindow Transparent Titlebar

struct WindowConfigurator: NSViewRepresentable {
    /// 窗口玻璃开关：变了就进 updateNSView 重新配窗（plan-mac-glass-chrome §1.2）
    let glass: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                Self.configure(window, glass: glass)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        Self.configure(window, glass: glass)
    }

    private static func configure(_ window: NSWindow, glass: Bool) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // 玻璃开：窗口透明，底由 `MacWindowBackdrop` 画；关：维持原来的实底
        window.isOpaque = !glass
        window.backgroundColor = glass ? .clear : Theme.platformMainBackgroundColor
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
        // 全屏模式的标题栏那一行要给红绿灯让位——量出来，别写死（见 MacWindowChrome）
        MacWindowChrome.shared.measure(window)
        MacMainWindow.register(window)   // 菜单栏快看靠它把主窗拉到前面
        Self.pruneStaleAutosaveKeys(window: window)
    }

    private static var didPrune = false
    /// SwiftUI 给 WindowGroup 自动存窗口位置 / 分栏宽，键名是整棵视图的类型签名，里头带每次 build 都变的
    /// `unknown context at $…` 地址——每 build 一次多一份、永不回收。09-18 量到 637 个 NSWindow Frame + 55 个 NSSplitView
    /// 共 1.7MB，把偏好域撑到 3.8MB / 805 key；之后每写一个 key cfprefsd 都走超大消息整本重发、主线程重解析
    /// （收放面板 0.3–0.5s hang，trace 里 92% 在 __CFStringEqual，见 docs/research-prefs-domain-bloat.md）。
    /// 只留 `frameAutosaveName` 那一条（configure 时还是空串，延后 1.5s 再取），其余分批删——
    /// 一次删 166 条（键名各 2.5KB）的消息自己也超大，只生效了 3 条；每批 20 条。
    private static func pruneStaleAutosaveKeys(window: NSWindow) {
        if TestHostIsolation.blocks(.windowPrefs) { return }   // #035：直接 CFPreferences + bundle id，换 suite 管不到，测试宿主不做
        guard !didPrune, let appID = Bundle.main.bundleIdentifier else { return }
        didPrune = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
            guard let window, !window.frameAutosaveName.isEmpty else { return }
            let named = "NSWindow Frame " + window.frameAutosaveName
            let stale = UserDefaults.standard.dictionaryRepresentation().keys.filter { key in
                key.hasPrefix("NSSplitView Subview Frames SwiftUI.")
                    || (key.hasPrefix("NSWindow Frame SwiftUI.") && key != named)
            }
            guard !stale.isEmpty else { return }
            DispatchQueue.global(qos: .utility).async {
                // 逐个删：09-25 实测 CFPreferencesSetMultiple 的删除列表 ≥ 2 个 key 就整批静默不生效
                //（进程内缓存显示删了、cfprefsd / 磁盘上一个没少），1 个才生效。09-18 以为是消息太大改成 20 一批，其实从没删掉过
                for key in stale {
                    CFPreferencesSetValue(key as CFString, nil, appID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                }
                CFPreferencesAppSynchronize(appID as CFString)
                #if DEBUG
                ShellProbe.keep("[PROBE prefs.prune] 删 \(stale.count) 个陈旧自动存档 key")
                #endif
                // 删完从 cfprefsd 重读核一遍（进程内缓存会骗人），记进卡顿日志
                let left = ((CFPreferencesCopyKeyList(appID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]) ?? [])
                    .filter { $0.hasPrefix("NSWindow Frame SwiftUI.") }.count
                HangProbe.shared.note("[prefs.prune] removed=\(stale.count) left=\(left)")
            }
        }
    }
}
#endif

#if DEBUG && os(macOS)
/// DEBUG 启动钩子（拍照用，确定性导航，复用现有 layout / 会话，不造数据）：
/// `--mp-open-settings[=tab]` 开设置窗；`--mp-open-tool=<id>` 开右栏工具（`IPadPanelLayout.open`）。
private struct MacLaunchHook: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    @State private var fired = false

    func body(content: Content) -> some View {
        content.task {
            guard !fired else { return }
            let args = ProcessInfo.processInfo.arguments
            let wantsSettings = args.contains { $0 == "--mp-open-settings" || $0.hasPrefix("--mp-open-settings=") }
            let toolId = args.first { $0.hasPrefix("--mp-open-tool=") }.map { String($0.dropFirst("--mp-open-tool=".count)) }
            guard wantsSettings || toolId != nil else { return }
            fired = true
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            if let toolId, !toolId.isEmpty { IPadPanelLayout.shared.open(toolId) }
            if wantsSettings { openSettings() }
        }
    }
}
#endif
