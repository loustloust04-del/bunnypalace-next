import Foundation
import SwiftData

/// 酒馆整包持久新增导入（卡库 ⑧c，plan §6.1 表 + §6.2）。
///
/// 流程：分类（同 hash 跳过 / 变化只归档 / 新文件建对象）→ 无副作用构造全部对象并预分配全部 ID、查冲突 →
/// 写 PendingImportBatch（完整目标清单）→ 原件归档 → 逐类落库 → 从存储重读验证并算首次内容 hash →
/// 存来源映射 + 报告 → 批次标 committed → 发布（楼层进列表 / 文件库 / 推送，默认不切楼层）→ 删批次。
/// committed 之前任何失败 / 中断按完整清单清掉本批全部新增；之后中断幂等续完。
///
/// 只新增不改旧对象；不执行卡脚本、不联网、不调模型；导入的历史消息不触发记忆提取。
/// 整个提交在主线程一次跑完、中间不让出，界面上的相关写入没有机会插进来（plan §6.2-2「暂停相关写入」）。
@MainActor
enum SillyTavernImportCommitter {

    struct Environment {
        let container: ModelContainer
        let profiles: ProfileManager
        let presets: PresetManager
        let cards: CharacterCardManager
        let globalRegex: GlobalRegexStore
        let globalBooks: GlobalWorldBookManager
        let personas: UserPersonaStore
        let sources: ImportSourceStore
        /// 验证用：从存储重读（不信内存）
        let defaults: UserDefaults
        /// BlobStore 根（⑧c-4 起卡 / 楼层 / 预设 / 全局书都在这）；卡原件在同级 cardlibrary/cards/
        let cardsRoot: URL?
        let cardLibraryRoot: URL?
    }

    /// app 里用：正式管理器 + 默认存储位置（全局正则 / 身份 / 导入来源用各自 shared）
    static func liveEnvironment(profiles: ProfileManager, presets: PresetManager, cards: CharacterCardManager,
                                globalBooks: GlobalWorldBookManager) -> Environment {
        Environment(container: profiles.container, profiles: profiles, presets: presets, cards: cards,
                    globalRegex: .shared, globalBooks: globalBooks, personas: .shared, sources: .shared,
                    defaults: .standard, cardsRoot: nil, cardLibraryRoot: nil)
    }

    enum SourceChoice {
        case new(name: String)
        case existing(id: String)
    }

    enum Failure: LocalizedError {
        case batchPending
        case sourceMissing
        case idConflict([String])
        case verifyFailed(String)
        case rollback(original: String, cleanup: String)

        var errorDescription: String? {
            switch self {
            case .batchPending: "上一次导入还没收尾，先恢复再导入"
            case .sourceMissing: "找不到这个导入来源"
            case .idConflict(let ids): "目标 ID 撞上已有对象（\(ids.count) 个），本批没写入"
            case .verifyFailed(let detail): "写入后核对不一致：\(detail)；本批已清理"
            case .rollback(let original, let cleanup): "导入失败（\(original)），清理也没完成：\(cleanup)"
            }
        }
    }

    /// 提交 / 恢复 / 撤回进行中：UI 据此停相关写入入口
    static var isBusy = false
    /// 测试注入点（生产恒为 nil）：afterBatch / afterArchive / afterObjects / afterSources / afterCommitted。
    /// 钩子里抛错 = 失败路径（进程内按清单清理）；钩子里直接退出进程 = 崩溃（下次启动恢复）
    static var faultHook: ((String) throws -> Void)?

    // MARK: - 提交

    static func commit(plan: SillyTavernPackagePlan, source choice: SourceChoice, excluded: Set<String> = [],
                       env: Environment) throws -> SillyTavernImportReport {
        guard !isBusy else { throw Failure.batchPending }
        isBusy = true
        defer { isBusy = false }
        if try env.sources.pendingBatch() != nil { throw Failure.batchPending }

        var builder = try Builder(plan: plan, choice: choice, excluded: excluded, env: env)
        try builder.build()
        try builder.checkConflicts()

        var batch = PendingImportBatch(id: builder.batchId, sourceId: builder.source.id, sourceIsNew: builder.sourceIsNew,
                                       phase: .writing, createdAt: Date(),
                                       newArchiveBlobs: builder.blobsToArchive.filter { !env.sources.hasArchived($0) },
                                       targets: builder.allTargets, reportFile: "\(builder.batchId).json")
        try env.sources.writePendingBatch(batch)
        try faultHook?("afterBatch")

        let report: SillyTavernImportReport
        do {
            for (sha, path) in builder.archiveSources { try env.sources.archive(file: plan.snapshot.url(for: path), sha256: sha) }
            try faultHook?("afterArchive")
            try builder.writeObjects()
            try faultHook?("afterObjects")
            let hashes = try verify(builder, env: env)
            report = try builder.saveSourceAndReport(hashes: hashes, reportFile: batch.reportFile, newBlobCount: batch.newArchiveBlobs.count)
            try faultHook?("afterSources")
            batch.phase = .committed
            try env.sources.writePendingBatch(batch)
        } catch {
            do { try rollback(batch, env: env) } catch let cleanup {
                throw Failure.rollback(original: error.localizedDescription, cleanup: cleanup.localizedDescription)
            }
            throw error
        }
        try faultHook?("afterCommitted")
        try finish(batch, env: env)
        return report
    }

    /// 发布 + 删批次。重复调用安全（publish 对已在列表的楼层只补副作用）
    private static func finish(_ batch: PendingImportBatch, env: Environment) throws {
        let floorIds = Set(batch.targets.filter { $0.kind == .floor }.map(\.id))
        if !floorIds.isEmpty {
            let stored = storedProfiles(env.defaults, root: env.cardsRoot)
            for profile in stored where floorIds.contains(profile.id) { env.profiles.publish(profile, activate: false) }
        }
        try env.sources.removePendingBatch()
    }

    // MARK: - 恢复

    enum RecoveryOutcome: Equatable {
        case none
        case rolledBack(batchId: String, targets: Int)
        case finished(batchId: String)
    }

    /// 有未完成批次：writing → 按完整清单清掉本批全部新增；committed → 续完发布并删批次
    @discardableResult
    static func recover(env: Environment) throws -> RecoveryOutcome {
        isBusy = true
        defer { isBusy = false }
        guard let batch = try env.sources.pendingBatch() else { return .none }
        switch batch.phase {
        case .writing:
            try rollback(batch, env: env)
            return .rolledBack(batchId: batch.id, targets: batch.targets.count)
        case .committed:
            try finish(batch, env: env)
            return .finished(batchId: batch.id)
        }
    }

    /// 启动期：在任何管理器读存储之前跑，用一套临时、无副作用的管理器清理；之后正式管理器读到的就是干净状态
    @discardableResult
    static func recoverAtLaunch(container: ModelContainer) -> RecoveryOutcome {
        let sources = ImportSourceStore()
        guard FileManager.default.fileExists(atPath: sources.pendingBatchURL.path) else { return .none }
        let loaded = ProfileManager.loadProfilesChecked()
        // #037：楼层列表读坏时回滚会拿 seed 判断 / 覆盖，批次留着下次启动再恢复
        guard loaded.error == nil else {
            NSLog("酒馆导入：楼层列表读不了，启动恢复推迟到下次")
            return .none
        }
        let manager = ProfileManager(container: container, profiles: loaded.profiles, currentProfile: loaded.profiles[0],
                                     loadError: nil, sideEffectsEnabled: false)
        let cards = CharacterCardManager()
        manager.characterCardManager = cards
        let env = Environment(container: container, profiles: manager, presets: PresetManager(), cards: cards,
                              globalRegex: GlobalRegexStore(), globalBooks: GlobalWorldBookManager(), personas: UserPersonaStore(),
                              sources: sources, defaults: .standard, cardsRoot: nil, cardLibraryRoot: nil)
        do {
            let outcome = try recover(env: env)
            NSLog("酒馆导入：启动恢复 %@", "\(outcome)")
            return outcome
        } catch {
            // 清理失败：批次文件留着，下次启动再试；新导入被 batchPending 挡住
            NSLog("酒馆导入：启动恢复失败，批次保留待重试：%@", error.localizedDescription)
            return .none
        }
    }

    /// 按完整清单清理；只删本批预分配的 ID（导入前已核对不与任何已有对象冲突），幂等
    private static func rollback(_ batch: PendingImportBatch, env: Environment) throws {
        func ids(_ kind: ImportTarget.Kind) -> Set<String> { Set(batch.targets.filter { $0.kind == kind }.map(\.id)) }

        let context = ModelContext(env.container)
        context.autosaveEnabled = false
        let conversationIds = Array(ids(.conversation))
        for chunk in conversationIds.chunked(200) {
            for conversation in try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { chunk.contains($0.id) })) {
                context.delete(conversation)
            }
            for node in try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { chunk.contains($0.conversationId) })) {
                context.delete(node)
            }
        }
        let bookIds = ids(.worldBook).compactMap(UUID.init(uuidString:))
        for chunk in bookIds.chunked(200) {
            for book in try context.fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { chunk.contains($0.id) })) { context.delete(book) }
        }
        try context.save()

        try env.profiles.discardUnpublished(ids: ids(.floor))
        try env.presets.discardNew(ids: ids(.floorPreset).union(ids(.preset)))
        try env.cards.remove(ids: ids(.card))
        try env.globalBooks.remove(ids: ids(.globalWorldBook))
        let regexIds = ids(.globalRegex)
        if env.globalRegex.scripts.contains(where: { regexIds.contains($0.id) }) {
            try env.globalRegex.save(env.globalRegex.scripts.filter { !regexIds.contains($0.id) })
        }
        try env.personas.remove(ids: ids(.persona))

        if var source = env.sources.source(id: batch.sourceId) {
            for (path, versions) in source.files {
                let kept = versions.filter { $0.batchId != batch.id }
                source.files[path] = kept.isEmpty ? nil : kept
            }
            source.batches.removeAll { $0.id == batch.id }
            if batch.sourceIsNew && source.files.isEmpty { try env.sources.remove(sourceId: source.id) } else { try env.sources.save(source) }
        }
        env.sources.removeReport(file: batch.reportFile)
        env.sources.removeArchived(batch.newArchiveBlobs)
        try env.sources.removePendingBatch()
    }

    // MARK: - 验证（从存储重读，算首次内容 hash）

    private static func verify(_ builder: Builder, env: Environment) throws -> [String: String] {
        var hashes: [String: String] = [:]
        var problems: [String] = []
        let context = ModelContext(env.container)
        for item in builder.conversations {
            let id = item.payload.id
            let found = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
            let nodes = try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == id }))
            guard let found, nodes.count == item.payload.nodes.count, found.profileId == item.profileId else {
                problems.append("对话 \(item.relativePath)"); continue
            }
            hashes[id] = ImportFingerprint.conversation(found, nodes: nodes)
        }
        for book in builder.floorBooks {
            let id = book.id
            guard let found = try context.fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.id == id })).first else {
                problems.append("楼层书 \(book.name)"); continue
            }
            hashes[id.uuidString] = ImportFingerprint.worldBook(found)
        }
        let profiles = Dictionary(storedProfiles(env.defaults, root: env.cardsRoot).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for profile in builder.newProfiles {
            guard let stored = profiles[profile.id] else { problems.append("楼层 \(profile.name)"); continue }
            hashes[profile.id] = ImportFingerprint.of(stored)
        }
        let presets = PresetManager(root: env.cardsRoot, defaults: env.defaults)
        for preset in builder.newPresets {
            guard let stored = presets.preset(byId: preset.id) else { problems.append("预设 \(preset.name)"); continue }
            hashes[preset.id] = ImportFingerprint.of(stored)
        }
        let cards = CharacterCardManager(root: env.cardsRoot, libraryRoot: env.cardLibraryRoot, defaults: env.defaults)
        for card in builder.newCards {
            guard let stored = cards.cards.first(where: { $0.id == card.id }), cards.originalsPresent(stored) else { problems.append("卡 \(card.name)"); continue }
            hashes[card.id] = ImportFingerprint.of(stored)
        }
        let globalBooks = GlobalWorldBookManager(root: env.cardsRoot, defaults: env.defaults)
        for book in builder.globalBooks {
            guard let stored = globalBooks.books.first(where: { $0.id == book.id }) else { problems.append("全局书 \(book.name)"); continue }
            hashes[book.id] = ImportFingerprint.of(stored)
        }
        let regex = GlobalRegexStore(defaults: env.defaults)
        for script in builder.globalRegex {
            guard let stored = regex.scripts.first(where: { $0.id == script.id }) else { problems.append("全局正则"); continue }
            hashes[script.id] = ImportFingerprint.of(stored)
        }
        let personas = UserPersonaStore(root: env.cardLibraryRoot)
        for persona in builder.newPersonas {
            guard let stored = personas.personas.first(where: { $0.id == persona.id }) else { problems.append("身份 \(persona.name)"); continue }
            hashes[persona.id] = ImportFingerprint.of(stored)
        }
        guard problems.isEmpty else { throw Failure.verifyFailed(problems.prefix(5).joined(separator: "、") + (problems.count > 5 ? " 等 \(problems.count) 项" : "")) }
        return hashes
    }

    nonisolated static func storedProfiles(_ defaults: UserDefaults, root: URL?) -> [Profile] {
        (try? BlobStore.read(forKey: "savedProfiles", root: BlobStore.resolvedRoot(root, defaults: defaults), defaults: defaults))
            .flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
    }
}

// MARK: - 构造（无副作用）+ 写入

extension SillyTavernImportCommitter {

    struct PlannedConversation {
        let relativePath: String
        let profileId: String
        let payload: ImportedConversationPayload
        let memoryEnabled: Bool
    }

    @MainActor
    struct Builder {
        let plan: SillyTavernPackagePlan
        let env: Environment
        let excluded: Set<String>
        let batchId = UUID().uuidString
        var source: ImportSource
        let sourceIsNew: Bool

        /// 文件处置（只含要记新版本的；同 hash 跳过的不在里面）
        var dispositions: [String: ImportFileVersion.Disposition] = [:]
        var skipped: Set<String> = []
        /// 路径 → 目标（contentHash 验证后补）
        var targetsByPath: [String: [ImportTarget]] = [:]

        var newCards: [CharacterCard] = []
        var newProfiles: [Profile] = []
        var newPresets: [Preset] = []
        var floorBooks: [WorldBook] = []
        var conversations: [PlannedConversation] = []
        var globalBooks: [GlobalWorldBook] = []
        var globalRegex: [RegexScript] = []
        var newPersonas: [UserPersona] = []
        var personaAvatars: [String: Data] = [:]

        var issues: [SillyTavernImportReport.Issue] = []
        var numbers = SillyTavernImportReport.Numbers()
        var unsupportedByCategory: [String: Int] = [:]

        /// 本批要用到的楼层：卡相对路径 → 楼层 id（含之前导入、仍在的）
        private var floorByCardPath: [String: String] = [:]
        private var profileIndex: [String: Int] = [:]
        private var newCardIndexByPath: [String: Int] = [:]
        /// 源 persona key（头像文件名）→ persona id
        private var personaByKey: [String: String] = [:]
        /// ③-4：settings 里身份 ↔ 角色关联（persona_descriptions[*].connections type=character）：卡文件名 → 身份 id；默认身份
        private var personaIdsByCardFile: [String: [String]] = [:]
        private var defaultPersonaId: String?
        /// 聊天相对路径 → (楼层, 对话 id)
        private var conversationByChatPath: [String: (profileId: String, conversationId: String)] = [:]
        private let entriesByPath: [String: SillyTavernManifestEntry]

        init(plan: SillyTavernPackagePlan, choice: SourceChoice, excluded: Set<String>, env: Environment) throws {
            self.plan = plan
            self.env = env
            self.excluded = excluded
            switch choice {
            case .new(let name):
                source = ImportSource(name: name)
                sourceIsNew = true
            case .existing(let id):
                guard let existing = env.sources.source(id: id) else { throw Failure.sourceMissing }
                source = existing
                sourceIsNew = false
            }
            entriesByPath = Dictionary(plan.snapshot.entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        }

        private func isNew(_ path: String) -> Bool { dispositions[path] == .imported }

        private mutating func target(_ path: String, _ kind: ImportTarget.Kind, _ id: String, profileId: String? = nil) {
            targetsByPath[path, default: []].append(ImportTarget(kind: kind, id: id, profileId: profileId, contentHash: ""))
        }

        private mutating func issue(_ path: String, line: Int? = nil, field: String? = nil, _ reason: String, action: String,
                                    retryable: Bool = false, archived: Bool = true) {
            let sha = entriesByPath[path]?.sha256
            issues.append(.init(relativePath: path, line: line, field: field, reason: reason, action: action, retryable: retryable,
                                archivePath: archived ? sha.map(ImportSourceStore.archivePath) : nil))
        }

        var allTargets: [ImportTarget] { targetsByPath.values.flatMap { $0 } }

        /// 要归档的原件：sha → 一个源路径（同内容只拷一次）
        var archiveSources: [(String, String)] {
            var seen = Set<String>()
            var out: [(String, String)] = []
            for path in dispositions.keys.sorted() {
                guard let sha = entriesByPath[path]?.sha256, seen.insert(sha).inserted else { continue }
                out.append((sha, path))
            }
            return out
        }

        var blobsToArchive: [String] { archiveSources.map(\.0) }

        // MARK: 分类

        mutating func build() throws {
            for entry in plan.snapshot.entries {
                guard let sha = entry.sha256, entry.category != .credentials else { continue }
                var latest = source.latest(entry.relativePath)
                // 上次盘点时排除的、上次解析失败而这次内容变了（修好了）的：之前没建对象，这次按新文件算
                if let last = latest, last.disposition == .excluded || (last.disposition == .failed && last.sha256 != sha) {
                    latest = nil
                }
                if let latest {
                    if latest.sha256 == sha { skipped.insert(entry.relativePath) } else {
                        dispositions[entry.relativePath] = .changedArchived
                        issue(entry.relativePath, "内容和上次导入不同", action: "保留新版原件，未覆盖已导入对象")
                    }
                } else if excluded.contains(entry.relativePath) {
                    dispositions[entry.relativePath] = .excluded
                    let path = entry.relativePath
                    let why = plan.problems.first { $0.relativePath == path || path.hasPrefix($0.relativePath + "/") }?.reason
                    issue(path, "盘点时排除" + (why.map { "：\($0)" } ?? ""), action: "只归档原件，没建对象；下次导入可取消排除", retryable: true)
                } else {
                    switch entry.category {
                    case .card, .chat, .groupChat, .group, .world, .preset, .settings, .userFile, .userImage, .personaAvatar:
                        dispositions[entry.relativePath] = .imported
                    default:
                        dispositions[entry.relativePath] = .archivedOnly
                    }
                }
            }
            if plan.summary.hasCredentials {
                issue(SillyTavernPackageParser.credentialsPath, "含 API 凭据", action: "不读、不存、不导入", archived: false)
            }
            // 解析阶段的问题（坏行 / 读不出 / 缺卡）原样带进报告；只报本批碰到的文件
            for problem in plan.problems where problem.relativePath != SillyTavernPackageParser.credentialsPath {
                let path = problem.relativePath
                // 排除的文件上面已报排除原因，不再报「其余照导」
                let touched = (dispositions[path] != nil && dispositions[path] != .excluded)
                    || (entriesByPath[path] == nil && dispositions.keys.contains { $0.hasPrefix(path + "/") && dispositions[$0] == .imported })
                guard touched else { continue }
                let action: String
                if problem.line != nil { action = "坏行隔离，其余照导" }
                else if entriesByPath[path] == nil { action = "建最小占位角色楼层" }
                else { action = "原件已归档，可修好后重试" }
                issue(path, line: problem.line, problem.reason, action: action,
                      retryable: problem.line == nil && entriesByPath[path] != nil)
            }

            buildCards()
            buildPersonasAndRegex()
            buildCharacters()
            buildGroups()
            bindFloorPersonas()
            buildWorlds()
            buildPresets()
            buildAttachments()
            markFailedAndEmpty()
        }

        // MARK: 卡

        private mutating func buildCards() {
            for dto in plan.cards where isNew(dto.relativePath) {
                let card = CharacterCard(from: dto.card)
                newCardIndexByPath[dto.relativePath] = newCards.count
                newCards.append(card)
                target(dto.relativePath, .card, card.id)
                if dto.hasHelperScripts {
                    unsupportedByCategory["card", default: 0] += 1
                    issue(dto.relativePath, field: "extensions.tavern_helper", "带酒馆助手脚本", action: "原样保存，不执行；许可 unknown")
                }
            }
            for dto in plan.cards where !isNew(dto.relativePath) {
                // 之前导入过的卡：沿用它仍在的楼层
                if let cardId = source.liveTargets(dto.relativePath).first(where: { $0.kind == .card })?.id,
                   let card = env.cards.cards.first(where: { $0.id == cardId }), card.bindingState == .active,
                   let pid = card.linkedProfileId, env.profiles.profiles.contains(where: { $0.id == pid }) {
                    floorByCardPath[dto.relativePath] = pid
                }
            }
        }

        // MARK: persona + 全局正则（settings.json）

        private mutating func buildPersonasAndRegex() {
            let settingsPath = "settings.json"
            if isNew(settingsPath) {
                let raw = (try? Data(contentsOf: plan.snapshot.url(for: settingsPath)))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let power = raw?["power_user"] as? [String: Any] ?? [:]
                let names = power["personas"] as? [String: Any] ?? [:]
                let descriptions = power["persona_descriptions"] as? [String: Any] ?? [:]
                for dto in plan.personas {
                    var record: [String: Any] = [:]
                    if let name = names[dto.avatarFile] { record["name"] = name }
                    if let info = descriptions[dto.avatarFile] { record["description"] = info }
                    var persona = UserPersona(name: dto.name, description: dto.description,
                                              rawJSONData: try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                                              origin: ImportOrigin(sourceId: source.id, batchId: batchId, relativePath: settingsPath, key: dto.avatarFile))
                    let avatarPath = "User Avatars/\(dto.avatarFile)"
                    if dto.hasAvatarFile, entriesByPath[avatarPath] != nil, let data = try? Data(contentsOf: plan.snapshot.url(for: avatarPath)) {
                        let ext = (dto.avatarFile as NSString).pathExtension.lowercased()
                        persona.avatarAssetRef = "avatars/\(persona.id).\(ext.isEmpty ? "png" : ext)"
                        personaAvatars[persona.id] = data
                        if isNew(avatarPath) { target(avatarPath, .persona, persona.id) }
                    } else {
                        issue(settingsPath, field: "power_user.personas", "身份没有头像文件", action: "显示首字")
                    }
                    newPersonas.append(persona)
                    personaByKey[dto.avatarFile] = persona.id
                    target(settingsPath, .persona, persona.id)
                    let connections = (descriptions[dto.avatarFile] as? [String: Any])?["connections"] as? [[String: Any]] ?? []
                    for connection in connections where connection["type"] as? String == "character" {
                        if let file = connection["id"] as? String, !file.isEmpty { personaIdsByCardFile[file, default: []].append(persona.id) }
                    }
                }
                if let key = power["default_persona"] as? String, !key.isEmpty {
                    defaultPersonaId = personaByKey[key]
                    if defaultPersonaId == nil {
                        issue(settingsPath, field: "power_user.default_persona", "默认身份不在包里", action: "不指定楼层身份")
                    }
                }
                var enabledBefore = 0
                for script in plan.globalRegex {
                    var copy = script
                    copy.id = UUID().uuidString
                    if !copy.disabled { enabledBefore += 1 }
                    copy.disabled = true
                    globalRegex.append(copy)
                    target(settingsPath, .globalRegex, copy.id)
                }
                numbers.globalRegexDisabledOnImport = globalRegex.count
                if !globalRegex.isEmpty {
                    issue(settingsPath, field: "extension_settings.regex", "全局正则 \(globalRegex.count) 条（源里开着 \(enabledBefore) 条）",
                          action: "已导入，默认关闭；到正则页手动开")
                }
                let attachments = plan.summary.attachments
                if attachments.globalDataBankRefs + attachments.characterDataBankRefs > 0 {
                    unsupportedByCategory["settings", default: 0] += 1
                    issue(settingsPath, field: "extension_settings.attachments", "Data Bank 引用", action: "原件归档，暂不接入")
                }
            } else {
                // 之前导入过的身份：按源 key 找回（聊天绑身份用）
                for persona in env.personas.personas where persona.origin?.sourceId == source.id {
                    if let key = persona.origin?.key { personaByKey[key] = persona.id }
                }
            }
            // 头像文件变了但身份没新建：只归档
            for entry in plan.snapshot.entries(in: .personaAvatar) where isNew(entry.relativePath)
                && targetsByPath[entry.relativePath] == nil {
                dispositions[entry.relativePath] = .archivedOnly
            }
        }

        // MARK: 楼层 + 聊天

        private mutating func addFloor(card: CharacterCard, path: String, placeholderNote: String?) throws -> String {
            let made = try CharacterFloorService.makeFloor(card: card, presets: env.presets)
            var profile = made.profile
            let preset = made.preset, book = made.book
            if let placeholderNote { profile.description = placeholderNote }
            profileIndex[profile.id] = newProfiles.count
            newProfiles.append(profile)
            newPresets.append(preset)
            target(path, .floor, profile.id, profileId: profile.id)
            target(path, .floorPreset, preset.id, profileId: profile.id)
            if let book {
                floorBooks.append(book)
                target(path, .worldBook, book.id.uuidString, profileId: profile.id)
            }
            return profile.id
        }

        private mutating func buildCharacters() {
            for character in plan.characters {
                let chats = character.chats.filter { isNew($0.relativePath) }
                for chat in chats where !chatIsUsable(chat) {
                    dispositions[chat.relativePath] = .failed
                }
                let usable = chats.filter(chatIsUsable)
                guard let first = usable.first else { continue }
                var floorId: String?
                if let cardPath = character.cardPath {
                    if let index = newCardIndexByPath[cardPath] {
                        // 新卡 + 新聊天：物化唯一新楼层（③a 同一构造）
                        do {
                            let pid = try addFloor(card: newCards[index], path: cardPath, placeholderNote: nil)
                            newCards[index].bindingState = .active
                            newCards[index].linkedProfileId = pid
                            floorByCardPath[cardPath] = pid
                            floorId = pid
                        } catch {
                            issue(cardPath, field: "character_book", "卡内世界书读不出：\(error.localizedDescription)", action: "这张卡的聊天放进占位楼层")
                        }
                    } else if let pid = floorByCardPath[cardPath] {
                        floorId = pid
                    }
                }
                if floorId == nil {
                    // 缺卡（或卡没有可用楼层）：最小占位角色楼层，从楼层生成楼层卡
                    let prefix = "chats/\(character.stem)/"
                    let previous = source.files.filter { $0.key.hasPrefix(prefix) }.values.flatMap { $0 }.flatMap(\.targets)
                        .first { t in t.kind == .floor && t.retractedAt == nil && env.profiles.profiles.contains { $0.id == t.id } }
                    if let previous {
                        floorId = previous.id
                    } else {
                        let stand = CharacterCard(profile: Profile(name: character.stem, emoji: "🎭", description: "", userName: "你", assistantName: character.stem))
                        floorId = try? addFloor(card: stand, path: first.relativePath,
                                                placeholderNote: "酒馆导入的占位角色（\(prefix) 没有对应的卡）")
                        numbers.placeholderFloors += floorId == nil ? 0 : 1
                    }
                }
                guard let pid = floorId else { continue }
                for chat in usable {
                    addConversation(chat.built, path: chat.relativePath, profileId: pid, personaRef: chat.personaRef,
                                    header: chatHeader(chat.relativePath), badLines: chat.badLines, archiveKind: nil, extra: [:])
                }
            }
        }

        private func chatIsUsable(_ chat: SillyTavernChatDTO) -> Bool {
            if case .failed = chat.status { return false }
            return true
        }

        private func chatHeader(_ path: String) -> String? {
            guard let data = try? Data(contentsOf: plan.snapshot.url(for: path)) else { return nil }
            let line = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first.map { Data($0) }
            guard let line, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  SillyTavernChatParser.isHeader(object) else { return nil }
            return String(decoding: line, as: UTF8.self)
        }

        private mutating func buildGroups() {
            var floorByGroup: [String: String] = [:]
            for chat in plan.groupChats where isNew(chat.relativePath) {
                if case .failed = chat.status { dispositions[chat.relativePath] = .failed; continue }
                let group = plan.groups.first { $0.id == chat.groupId }
                let key = group?.id ?? "?"
                if floorByGroup[key] == nil {
                    let name = group.map { $0.name.isEmpty ? $0.id : $0.name } ?? "未归属的群聊"
                    let stand = CharacterCard(profile: Profile(name: name, emoji: "👥", description: "", userName: "你", assistantName: name))
                    let anchor = group.map(\.relativePath).flatMap { isNew($0) ? $0 : nil } ?? chat.relativePath
                    guard let pid = try? addFloor(card: stand, path: anchor, placeholderNote: "酒馆群聊只读归档（不续聊、不进记忆）") else { continue }
                    floorByGroup[key] = pid
                    numbers.groupArchiveFloors += 1
                }
                var extra: [String: Any] = [:]
                if let group { extra["groupId"] = group.id; extra["members"] = group.members }
                addConversation(chat.built, path: chat.relativePath, profileId: floorByGroup[key]!, personaRef: nil,
                                header: chatHeader(chat.relativePath), badLines: [], archiveKind: Conversation.groupReadOnlyArchive, extra: extra)
            }
        }

        /// ③-4：这次新建的楼层落 Profile.personaId——身份连着这张卡（唯一）就用它，没连就用默认身份；
        /// 一张卡连了多个身份不猜，报告。settings 没新导入（重导 / 变化只归档）不追溯已导入的楼层
        private mutating func bindFloorPersonas() {
            let settingsPath = "settings.json"
            guard isNew(settingsPath), !personaIdsByCardFile.isEmpty || defaultPersonaId != nil else { return }
            var cardFileByFloor: [String: String] = [:]
            for (path, pid) in floorByCardPath { cardFileByFloor[pid] = (path as NSString).lastPathComponent }
            var matchedFiles = Set<String>()
            for index in newProfiles.indices {
                let file = cardFileByFloor[newProfiles[index].id]
                if let file, let ids = personaIdsByCardFile[file] {
                    matchedFiles.insert(file)
                    let unique = Array(Set(ids))
                    if unique.count == 1 {
                        newProfiles[index].personaId = unique[0]
                    } else {
                        issue(settingsPath, field: "power_user.persona_descriptions", "「\(file)」连了 \(unique.count) 个身份",
                              action: "不指定楼层身份，到角色页自己选")
                    }
                } else if let defaultPersonaId {
                    newProfiles[index].personaId = defaultPersonaId
                }
            }
            for file in personaIdsByCardFile.keys.sorted() where !matchedFiles.contains(file) {
                issue(settingsPath, field: "power_user.persona_descriptions", "身份连着「\(file)」，这次没给它新建楼层",
                      action: "不改已有楼层的身份")
            }
        }

        private mutating func addConversation(_ built: SillyTavernBuiltConversation, path: String, profileId: String, personaRef: String?,
                                              header: String?, badLines: [SillyTavernBadLine], archiveKind: String?, extra: [String: Any]) {
            var idMap: [String: String] = [:]
            for node in built.payload.nodes { idMap[node.id] = UUID().uuidString }
            func mapped(_ id: String) -> String { idMap[id] ?? id }
            let conversationId = UUID().uuidString
            var nodes: [ImportedNodePayload] = []
            for node in built.payload.nodes {
                let src = built.nodeSources[node.id]
                var visibility: String?
                if let src, src.visibility != .normal { visibility = src.visibility.rawValue }
                nodes.append(ImportedNodePayload(
                    id: mapped(node.id), role: node.role, content: node.content, contentType: node.contentType,
                    createTime: node.createTime, parentId: node.parentId.map(mapped), childrenIds: node.childrenIds.map(mapped),
                    segmentsData: nil, isSyntheticRoot: node.isSyntheticRoot,
                    sourceMetadata: src.flatMap { nodeMetadata($0, chatPath: path) }, sourceVisibility: visibility))
                if let src, src.isSelected, isHiddenSourceVisibility(visibility) { numbers.hiddenMessages += 1 }
            }
            var meta: [String: Any] = ["source": "sillytavern", "sourceId": source.id, "batchId": batchId, "relativePath": path]
            if let header { meta["header"] = header }
            if !badLines.isEmpty { meta["badLines"] = badLines.map { ["line": $0.line, "reason": $0.reason] } }
            if let personaRef { meta["personaRef"] = personaRef }
            for (key, value) in extra { meta[key] = value }
            let personaId = personaRef.flatMap { personaByKey[$0] }
            if personaRef != nil && personaId == nil {
                issue(path, field: "chat_metadata.persona", "聊天绑定的身份不在包里", action: "保留引用，不指定身份")
            }
            let payload = ImportedConversationPayload(
                id: conversationId, title: built.payload.title, createTime: built.payload.createTime, updateTime: built.payload.updateTime,
                currentNodeId: built.payload.currentNodeId.isEmpty ? "" : mapped(built.payload.currentNodeId),
                provider: built.payload.provider, nodes: nodes,
                branchSelectionData: BranchSelection.remap(built.payload.branchSelectionData) { idMap[$0] },
                personaId: personaId, archiveKind: archiveKind,
                sourceMetadata: try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]))
            conversations.append(PlannedConversation(relativePath: path, profileId: profileId, payload: payload,
                                                     memoryEnabled: archiveKind == nil))
            conversationByChatPath[path] = (profileId, conversationId)
            target(path, .conversation, conversationId, profileId: profileId)
            numbers.messages += built.messageCount
            numbers.messagesWithSwipes += built.swipeGroupCount
            numbers.multiCandidateMessages += built.multiCandidateCount
            numbers.candidates += built.candidateCount
            numbers.contentNodes += built.contentNodeCount
            numbers.syntheticRoots += built.syntheticRootId == nil ? 0 : 1
            numbers.mesDiffers += built.mesDiffCount
            numbers.swipeIdOutOfRange += built.issues.count
            numbers.badLines += badLines.count
            for problem in built.issues {
                if case .swipeIdOutOfRange(let sourceId, let count, let matched) = problem.kind {
                    issue(path, line: problem.line, field: "swipe_id",
                          "swipe_id \(sourceId.map(String.init) ?? "缺") 不在 0…\(count - 1)",
                          action: matched.map { "按 mes 选第 \($0 + 1) 个候选，原值留在 metadata" } ?? "退回首候选，原值留在 metadata")
                }
            }
        }

        /// 候选 raw、swipe_info、源 swipe 原文、variables 等原样：只存不执行
        private mutating func nodeMetadata(_ src: SillyTavernNodeSource, chatPath: String) -> Data? {
            func object(_ data: Data?) -> Any? { data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } }
            var meta: [String: Any] = ["source": "sillytavern", "line": src.line, "candidate": src.candidateIndex,
                                       "candidates": src.candidateCount, "selected": src.isSelected, "name": src.name,
                                       "visibility": src.visibility.rawValue]
            if let raw = src.sendDateRaw { meta["sendDate"] = raw }
            if let text = src.sourceSwipeText { meta["sourceSwipeText"] = text }
            if let info = object(src.swipeInfo) { meta["swipeInfo"] = info }
            if let id = src.sourceSwipeId { meta["sourceSwipeId"] = id }
            if let raw = src.rawLine {
                meta["rawLine"] = String(decoding: raw, as: UTF8.self)
                let refs = attachmentRefs(raw)
                if !refs.isEmpty {
                    meta["attachments"] = refs.map { ref -> [String: Any] in
                        if let entry = entriesByPath[ref], let sha = entry.sha256 {
                            numbers.attachmentRefsResolved += 1
                            return ["ref": ref, "resource": "archive:\(sha)"]
                        }
                        numbers.attachmentRefsMissing += 1
                        issue(chatPath, line: src.line, field: "extra", "附件 \(ref) 不在包里", action: "留占位，不联网补取", archived: true)
                        return ["ref": ref, "missing": true]
                    }
                }
            }
            if !src.preservedFields.isEmpty {
                meta["fields"] = src.preservedFields.compactMapValues { object($0) }
            }
            return try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        }

        /// extra.file / files / image / media 里的站内路径 → default-user 相对路径
        private func attachmentRefs(_ rawLine: Data) -> [String] {
            guard let object = try? JSONSerialization.jsonObject(with: rawLine) as? [String: Any],
                  let extra = object["extra"] as? [String: Any] else { return [] }
            var urls: [String] = []
            if let file = extra["file"] as? [String: Any], let url = file["url"] as? String { urls.append(url) }
            for file in extra["files"] as? [[String: Any]] ?? [] { if let url = file["url"] as? String { urls.append(url) } }
            if let image = extra["image"] as? String { urls.append(image) }
            for media in extra["media"] as? [[String: Any]] ?? [] { if let url = media["url"] as? String { urls.append(url) } }
            return urls.compactMap { url in
                guard !url.hasPrefix("data:"), !url.contains("://") else { return nil }
                var path = url.removingPercentEncoding ?? url
                while path.hasPrefix("/") { path.removeFirst() }
                return path.isEmpty ? nil : path
            }
        }

        // MARK: 世界书

        private mutating func buildWorlds() {
            let cardPathByFile = Dictionary(plan.cards.map { (($0.relativePath as NSString).lastPathComponent, $0.relativePath) },
                                            uniquingKeysWith: { a, _ in a })
            for binding in plan.worldBindings where binding.resolvedPath == nil {
                let owner: String
                switch binding.owner {
                case .card(let path), .chat(let path): owner = path
                case .persona, .global, .characterExtra: owner = "settings.json"
                }
                if dispositions[owner] == .imported {
                    issue(owner, field: "world", "引用的世界书「\(binding.bookName)」包里没有", action: "只记引用，不猜")
                }
            }
            for world in plan.worlds where isNew(world.relativePath) {
                let bindings = plan.worldBindings.filter { $0.resolvedPath == world.relativePath }
                var floors: [String] = []
                var chats: [(profileId: String, conversationId: String)] = []
                var global = false
                var personaKeys: [String] = []
                var floorlessCards = 0
                for binding in bindings {
                    switch binding.owner {
                    case .global: global = true
                    case .persona(let key): personaKeys.append(key)
                    case .card(let path):
                        if let pid = floorByCardPath[path] { if !floors.contains(pid) { floors.append(pid) } } else { floorlessCards += 1 }
                    case .characterExtra(let name):
                        if let path = cardPathByFile[name], let pid = floorByCardPath[path] {
                            if !floors.contains(pid) { floors.append(pid) }
                        } else { floorlessCards += 1 }
                    case .chat(let path):
                        if let hit = conversationByChatPath[path] ?? previousConversation(path) { chats.append(hit) }
                    }
                }
                var refs: [String] = []
                var first = true
                func entries() -> [WorldBookEntry] {
                    // 同一本书进多个楼层时条目 id 各自一份，避免跨书同 id
                    defer { first = false }
                    return first ? world.report.entries : world.report.entries.map { var e = $0; e.id = UUID(); return e }
                }
                for pid in floors {
                    let book = WorldBook(name: world.name, profileId: pid, entries: entries())
                    book.rawJSONData = world.report.rawJSONData
                    floorBooks.append(book)
                    target(world.relativePath, .worldBook, book.id.uuidString, profileId: pid)
                    if let index = profileIndex[pid] { newProfiles[index].linkedWorldBookIDs.append(book.id.uuidString) }
                    refs.append("floor:\(book.id.uuidString)")
                }
                for chat in chats where !floors.contains(chat.profileId) {
                    let book = WorldBook(name: world.name, profileId: chat.profileId, entries: entries())
                    book.scopeConversationId = chat.conversationId
                    book.rawJSONData = world.report.rawJSONData
                    floorBooks.append(book)
                    target(world.relativePath, .worldBook, book.id.uuidString, profileId: chat.profileId)
                    refs.append("floor:\(book.id.uuidString)")
                }
                if global || refs.isEmpty {
                    // 全局引用 → 全局书开着；没绑到任何楼层 / 对话的独立书 → 停用（未知位置的条目本来就不注入）
                    var book = GlobalWorldBook(name: world.name, entries: entries(), isEnabled: global)
                    book.rawJSONData = world.report.rawJSONData
                    globalBooks.append(book)
                    target(world.relativePath, .globalWorldBook, book.id)
                    refs.append("global:\(book.id)")
                    if !global {
                        numbers.unboundWorldsDisabled += 1
                        issue(world.relativePath, floorlessCards > 0 ? "绑定它的卡没有聊天、这次没建楼层" : "没有绑到任何角色 / 聊天",
                              action: "进全局书库，已停用")
                    }
                }
                for key in personaKeys {
                    if let index = newPersonas.firstIndex(where: { $0.id == personaByKey[key] }) {
                        newPersonas[index].worldSourceRefs.append(contentsOf: refs)
                    }
                }
                if !world.report.issues.isEmpty {
                    unsupportedByCategory["world", default: 0] += world.report.unsupportedEntryCount
                    issue(world.relativePath, field: "entries", "\(world.report.unsupportedEntryCount) 条用了还不支持的设置",
                          action: "原值保留，不生效；未知位置不注入")
                }
            }
            // persona 绑了包里没有的书：留源书名
            for persona in plan.personas {
                guard let book = persona.lorebook, !plan.worlds.contains(where: { $0.name == book }),
                      let index = newPersonas.firstIndex(where: { $0.id == personaByKey[persona.avatarFile] }) else { continue }
                newPersonas[index].worldSourceRefs.append("name:\(book)")
            }
        }

        private func previousConversation(_ chatPath: String) -> (profileId: String, conversationId: String)? {
            source.liveTargets(chatPath).first { $0.kind == .conversation }.flatMap { t in t.profileId.map { ($0, t.id) } }
        }

        // MARK: 预设

        private mutating func buildPresets() {
            for dto in plan.presets where isNew(dto.relativePath) {
                var preset = dto.preset
                preset.id = UUID().uuidString
                preset.ownerProfileId = nil
                preset.sourceTemplateId = nil
                preset.isBuiltIn = false
                newPresets.append(preset)
                target(dto.relativePath, .preset, preset.id)
                for note in dto.notes { issue(dto.relativePath, field: "prompt_order", note, action: "未决前不启用相关排序，见预设页") }
            }
        }

        // MARK: 附件

        private mutating func buildAttachments() {
            for entry in plan.snapshot.entries where (entry.category == .userFile || entry.category == .userImage) && isNew(entry.relativePath) {
                if let sha = entry.sha256 { target(entry.relativePath, .attachment, "archive:\(sha)") }
            }
        }

        /// 新文件里没建出对象的：解析失败的标 failed，其余（空聊天目录外的 group json 等）标仅归档
        private mutating func markFailedAndEmpty() {
            let parsedCards = Set(plan.cards.map(\.relativePath))
            let parsedWorlds = Set(plan.worlds.map(\.relativePath))
            let parsedPresets = Set(plan.presets.map(\.relativePath))
            for (path, disposition) in dispositions where disposition == .imported && targetsByPath[path] == nil {
                let category = entriesByPath[path]?.category
                switch category {
                case .card where !parsedCards.contains(path): dispositions[path] = .failed
                case .world where !parsedWorlds.contains(path): dispositions[path] = .failed
                case .preset where !parsedPresets.contains(path): dispositions[path] = .failed
                case .card, .world, .preset, .chat, .groupChat, .settings: break
                default: dispositions[path] = .archivedOnly
                }
            }
        }

        // MARK: 冲突

        func checkConflicts() throws {
            var hits: [String] = []
            let context = ModelContext(env.container)
            let conversationIds = conversations.map(\.payload.id)
            let nodeIds = conversations.flatMap { $0.payload.nodes.map(\.id) }
            for chunk in conversationIds.chunked(300) {
                hits += try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { chunk.contains($0.id) })).map(\.id)
            }
            for chunk in nodeIds.chunked(300) {
                hits += try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { chunk.contains($0.id) })).map(\.id)
            }
            for chunk in floorBooks.map(\.id).chunked(300) {
                hits += try context.fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { chunk.contains($0.id) })).map(\.id.uuidString)
            }
            let profileIds = Set(env.profiles.profiles.map(\.id)).union(storedProfiles(env.defaults, root: env.cardsRoot).map(\.id))
            hits += newProfiles.map(\.id).filter(profileIds.contains)
            hits += newPresets.map(\.id).filter { env.presets.preset(byId: $0) != nil }
            hits += newCards.map(\.id).filter { id in env.cards.cards.contains { $0.id == id } }
            hits += globalBooks.map(\.id).filter { id in env.globalBooks.books.contains { $0.id == id } }
            hits += globalRegex.map(\.id).filter { id in env.globalRegex.scripts.contains { $0.id == id } }
            hits += newPersonas.map(\.id).filter { id in env.personas.personas.contains { $0.id == id } }
            if !hits.isEmpty { throw Failure.idConflict(hits) }
        }

        // MARK: 写入

        func writeObjects() throws {
            try env.presets.persistNew(newPresets)
            try env.profiles.persistNew(newProfiles)
            let context = ModelContext(env.container)
            context.autosaveEnabled = false
            for book in floorBooks { context.insert(book) }
            try context.save()
            for (index, item) in conversations.enumerated() {
                let conversation = makeImportedConversation(item.payload, profileId: item.profileId)
                conversation.memoryEnabled = item.memoryEnabled
                context.insert(conversation)
                for node in item.payload.nodes {
                    context.insert(makeImportedNode(node, conversationId: item.payload.id, profileId: item.profileId))
                }
                if index % 20 == 19 { try context.save() }
            }
            try context.save()
            try env.cards.add(contentsOf: newCards)
            try env.globalBooks.add(contentsOf: globalBooks)
            if !globalRegex.isEmpty { try env.globalRegex.save(env.globalRegex.scripts + globalRegex) }
            try env.personas.add(newPersonas, avatars: personaAvatars)
        }

        // MARK: 来源映射 + 报告

        mutating func saveSourceAndReport(hashes: [String: String], reportFile: String, newBlobCount: Int) throws -> SillyTavernImportReport {
            let now = Date()
            for (path, disposition) in dispositions {
                guard let entry = entriesByPath[path], let sha = entry.sha256 else { continue }
                let targets = (targetsByPath[path] ?? []).map { target -> ImportTarget in
                    var t = target
                    t.contentHash = hashes[t.id] ?? (t.kind == .attachment ? sha : "")
                    return t
                }
                source.files[path, default: []].append(ImportFileVersion(
                    sha256: sha, size: entry.size, category: entry.category.rawValue, batchId: batchId, importedAt: now,
                    disposition: disposition, targets: targets))
            }
            source.updatedAt = now
            source.batches.append(ImportBatchSummary(id: batchId, date: now, reportFile: reportFile))
            numbers.archivedBlobsNew = newBlobCount
            numbers.archivedBlobsReused = blobsToArchive.count - newBlobCount
            let report = makeReport(date: now)
            try env.sources.writeReport(report, file: reportFile)
            try env.sources.save(source)
            return report
        }

        private func makeReport(date: Date) -> SillyTavernImportReport {
            var categories: [String: SillyTavernImportReport.Category] = [:]
            for kind in SillyTavernFileCategory.allCases {
                categories[kind.rawValue] = .init(key: kind.rawValue, title: Self.title(kind))
            }
            for entry in plan.snapshot.entries {
                let key = entry.category.rawValue
                categories[key]!.sourceFiles += 1
                if entry.category == .credentials || skipped.contains(entry.relativePath) { categories[key]!.skipped += 1; continue }
                switch dispositions[entry.relativePath] {
                case .imported: categories[key]!.created += 1
                case .archivedOnly: categories[key]!.archivedOnly += 1
                case .changedArchived: categories[key]!.changed += 1
                case .failed: categories[key]!.failed += 1
                case .excluded: categories[key]!.excluded += 1
                case nil: break
                }
            }
            for (key, count) in unsupportedByCategory { categories[key]?.unsupported += count }
            categories[SillyTavernFileCategory.quickReply.rawValue]!.unsupported = categories[SillyTavernFileCategory.quickReply.rawValue]!.sourceFiles
            categories[SillyTavernFileCategory.extensionFile.rawValue]!.unsupported = categories[SillyTavernFileCategory.extensionFile.rawValue]!.sourceFiles
            var objects: [String: Int] = [:]
            for kind in ImportTarget.Kind.allCases {
                objects[kind.rawValue] = Set(allTargets.filter { $0.kind == kind }.map(\.id)).count
            }
            return SillyTavernImportReport(
                batchId: batchId, sourceId: source.id, sourceName: source.name, createdAt: date, isReimport: !sourceIsNew,
                categories: SillyTavernFileCategory.allCases.map { categories[$0.rawValue]! }, objects: objects, numbers: numbers,
                issues: issues.sorted { ($0.relativePath, $0.line ?? 0) < ($1.relativePath, $1.line ?? 0) },
                warnings: ["导入完成不代表脚本 / 插件兼容：酒馆助手脚本、QuickReplies、扩展只保存原件，不执行",
                           "卡的网页脚本许可一律「未决定」，第一次用卡时再问"])
        }

        private static func title(_ category: SillyTavernFileCategory) -> String {
            switch category {
            case .card: "角色卡"
            case .cardAsset: "卡的辅助图片"
            case .chat: "聊天"
            case .groupChat: "群聊记录"
            case .group: "群组"
            case .world: "世界书"
            case .preset: "预设"
            case .quickReply: "快捷回复"
            case .personaAvatar: "身份头像"
            case .userFile: "附件文件"
            case .userImage: "附件图片"
            case .backup: "酒馆备份"
            case .extensionFile: "扩展 / 插件"
            case .settings: "设置（全局正则 / 身份）"
            case .credentials: "API 凭据"
            case .unknown: "其它文件"
            }
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
