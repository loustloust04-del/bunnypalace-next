import Foundation
import SwiftData

/// 撤回这次导入（plan §6.2-5）：按长期来源记录逐项核对，只删仍未修改（首次内容 hash 不变）且未被引用的对象；
/// 先定全部去留再从叶到根删；保留的逐项报告原因。原件与报告保留，留下的对象不回滚。
extension SillyTavernImportCommitter {

    /// batchId = nil：撤回该来源全部批次
    static func retract(sourceId: String, batchId: String? = nil, env: Environment) throws -> SillyTavernRetractReport {
        guard !isBusy else { throw Failure.batchPending }
        // #037：只读时楼层列表是 seed，按它判「没人引用」会删掉真楼层在用的东西
        try env.profiles.ensureWritable()
        isBusy = true
        defer { isBusy = false }
        if try env.sources.pendingBatch() != nil { throw Failure.batchPending }
        guard var source = env.sources.source(id: sourceId) else { throw Failure.sourceMissing }

        // 目标 id → (目标, 相对路径)；同一对象挂在多个路径时只算一次
        var targets: [String: (target: ImportTarget, path: String)] = [:]
        for (path, versions) in source.files.sorted(by: { $0.key < $1.key }) {
            for version in versions where batchId == nil || version.batchId == batchId {
                for target in version.targets where target.retractedAt == nil && target.kind != .attachment && targets[target.id] == nil {
                    targets[target.id] = (target, path)
                }
            }
        }
        func ids(_ kind: ImportTarget.Kind) -> [String] { targets.values.filter { $0.target.kind == kind }.map(\.target.id).sorted() }

        var items: [SillyTavernRetractReport.Item] = []
        func note(_ id: String, _ action: SillyTavernRetractReport.Item.Action, _ reason: String) {
            guard let entry = targets[id] else { return }
            items.append(.init(kind: entry.target.kind.rawValue, id: id, relativePath: entry.path, action: action, reason: reason))
        }
        func modified(_ id: String, _ current: String) -> Bool { targets[id]?.target.contentHash != current }

        let context = ModelContext(env.container)
        context.autosaveEnabled = false

        // 1. 对话：改过（加消息 / 切支 / 编辑 / 收藏…）或被收藏夹 / 贴纸 / 卡片引用 → 留
        var conversations: [String: Conversation] = [:]
        var deleteConversations = Set<String>()
        var keptConversations = Set<String>()
        for id in ids(.conversation) {
            guard let conversation = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first else {
                note(id, .alreadyGone, "已经不在了"); continue
            }
            let profileId = conversation.profileId
            let nodes = try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == id && $0.profileId == profileId }))
            conversations[id] = conversation
            if modified(id, ImportFingerprint.conversation(conversation, nodes: nodes)) {
                keptConversations.insert(id); note(id, .kept, "导入后有新消息或改动")
            } else if let reason = try externalReference(conversation: conversation, nodes: nodes, context: context) {
                keptConversations.insert(id); note(id, .kept, reason)
            } else {
                deleteConversations.insert(id)
            }
        }

        // 2. 楼层书 / 楼层预设实例先看改没改：改过的留，并让所属楼层也留
        var books: [String: WorldBook] = [:]
        var modifiedBooks = Set<String>()
        for id in ids(.worldBook) {
            guard let uuid = UUID(uuidString: id),
                  let book = try context.fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.id == uuid })).first else {
                note(id, .alreadyGone, "已经不在了"); continue
            }
            books[id] = book
            if modified(id, ImportFingerprint.worldBook(book)) { modifiedBooks.insert(id) }
        }
        var modifiedPresets = Set<String>()
        for id in ids(.floorPreset) + ids(.preset) {
            if let preset = env.presets.preset(byId: id), modified(id, ImportFingerprint.of(preset)) { modifiedPresets.insert(id) }
        }
        let editedFloors = Set(modifiedBooks.compactMap { books[$0]?.profileId })
            .union(modifiedPresets.compactMap { env.presets.preset(byId: $0)?.ownerProfileId })

        // 3. 楼层：改过、楼层书 / 预设改过、还有别的对话（她后来聊的 / 保留的导入对话）、记忆 / 后加的书、当前楼层 → 留
        let bookTargetIds = Set(ids(.worldBook))
        var deleteFloors: [Profile] = []
        for id in ids(.floor) {
            guard let profile = env.profiles.profiles.first(where: { $0.id == id }) else { note(id, .alreadyGone, "已经不在了"); continue }
            if modified(id, ImportFingerprint.of(profile)) { note(id, .kept, "楼层设定改过"); continue }
            if editedFloors.contains(id) { note(id, .kept, "楼层的世界书或预设改过"); continue }
            if env.profiles.currentProfile.id == id { note(id, .kept, "是当前楼层"); continue }
            let others = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == id }))
                .filter { !deleteConversations.contains($0.id) }
            if !others.isEmpty {
                note(id, .kept, others.contains { keptConversations.contains($0.id) } ? "有保留的对话" : "有导入后新建的对话")
                continue
            }
            let memories = try context.fetchCount(FetchDescriptor<Memory>(predicate: #Predicate { $0.profileId == id }))
                + context.fetchCount(FetchDescriptor<MemoryNote>(predicate: #Predicate { $0.profileId == id }))
            let laterBooks = try context.fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == id }))
                .filter { !bookTargetIds.contains($0.id.uuidString) }
            if memories > 0 || !laterBooks.isEmpty {
                note(id, .kept, memories > 0 ? "楼层里有记忆" : "楼层里有后来加的世界书"); continue
            }
            deleteFloors.append(profile)
        }
        let deleteFloorIds = Set(deleteFloors.map(\.id))

        // 世界书：改过留；对话书跟对话走，楼层书跟楼层走
        var deleteBooks: [WorldBook] = []
        for (id, book) in books.sorted(by: { $0.key < $1.key }) {
            if modifiedBooks.contains(id) { note(id, .kept, "书改过"); continue }
            if let scope = book.scopeConversationId {
                let survives = try !deleteConversations.contains(scope)
                    && context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == scope })) > 0
                if survives { note(id, .kept, "所属对话保留"); continue }
            } else if !deleteFloorIds.contains(book.profileId) && env.profiles.profiles.contains(where: { $0.id == book.profileId }) {
                note(id, .kept, "所属楼层保留"); continue
            }
            deleteBooks.append(book)
        }

        // 4. 楼层预设实例：所属楼层留下、改过、或被别的楼层用 → 留
        var deletePresets = Set<String>()
        for id in ids(.floorPreset) {
            guard let preset = env.presets.preset(byId: id) else { note(id, .alreadyGone, "已经不在了"); continue }
            if modifiedPresets.contains(id) { note(id, .kept, "预设改过"); continue }
            if let owner = preset.ownerProfileId, !deleteFloorIds.contains(owner) { note(id, .kept, "所属楼层保留"); continue }
            if env.profiles.profiles.contains(where: { $0.presetId == id && !deleteFloorIds.contains($0.id) }) { note(id, .kept, "别的楼层在用"); continue }
            deletePresets.insert(id)
        }

        // 5. 卡：改过（含之后用卡建了楼层）或绑定的楼层留下 → 留
        var deleteCards = Set<String>()
        for id in ids(.card) {
            guard let card = env.cards.cards.first(where: { $0.id == id }) else { note(id, .alreadyGone, "已经不在了"); continue }
            // ⑧c-4 前导入的卡，首次 hash 是原件内嵌时的编码：两种都对不上才算改过
            // 第二批 B1 重算了脚本数缓存：B1 前导入的卡按旧编码再比一次
            if modified(id, ImportFingerprint.of(card)) && modified(id, ImportFingerprint.legacyCard(card))
                && modified(id, ImportFingerprint.preB1Card(card)) { note(id, .kept, "卡改过或已用卡"); continue }
            if let pid = card.linkedProfileId, card.bindingState == .active, !deleteFloorIds.contains(pid) { note(id, .kept, "绑定的楼层保留"); continue }
            deleteCards.insert(id)
        }

        // 6. 身份：改过或还有对话在用 → 留
        var deletePersonas = Set<String>()
        var keptPersonaRefs: [String] = []
        for id in ids(.persona) {
            guard let persona = env.personas.personas.first(where: { $0.id == id }) else { note(id, .alreadyGone, "已经不在了"); continue }
            let users = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.personaId == id }))
                .filter { !deleteConversations.contains($0.id) }
            if modified(id, ImportFingerprint.of(persona)) { keptPersonaRefs += persona.worldSourceRefs; note(id, .kept, "身份改过"); continue }
            if !users.isEmpty { keptPersonaRefs += persona.worldSourceRefs; note(id, .kept, "还有对话用这个身份"); continue }
            if env.profiles.profiles.contains(where: { $0.personaId == id && !deleteFloorIds.contains($0.id) }) {
                keptPersonaRefs += persona.worldSourceRefs; note(id, .kept, "还有楼层用这个身份"); continue
            }
            deletePersonas.insert(id)
        }
        for persona in env.personas.personas where !deletePersonas.contains(persona.id) && targets[persona.id] == nil {
            keptPersonaRefs += persona.worldSourceRefs
        }

        // 7. 全局书：改过或被保留的身份引用 → 留
        var deleteGlobalBooks = Set<String>()
        for id in ids(.globalWorldBook) {
            guard let book = env.globalBooks.books.first(where: { $0.id == id }) else { note(id, .alreadyGone, "已经不在了"); continue }
            if modified(id, ImportFingerprint.of(book)) { note(id, .kept, "书改过（含开关）"); continue }
            if keptPersonaRefs.contains("global:\(id)") { note(id, .kept, "保留的身份绑着它"); continue }
            deleteGlobalBooks.insert(id)
        }

        // 8. 预设模板：改过或被楼层 / 实例引用 → 留
        for id in ids(.preset) {
            guard env.presets.preset(byId: id) != nil else { note(id, .alreadyGone, "已经不在了"); continue }
            if modifiedPresets.contains(id) { note(id, .kept, "预设改过"); continue }
            if env.profiles.profiles.contains(where: { $0.presetId == id && !deleteFloorIds.contains($0.id) })
                || env.presets.presets.contains(where: { $0.sourceTemplateId == id && !deletePresets.contains($0.id) }) {
                note(id, .kept, "有楼层在用"); continue
            }
            deletePresets.insert(id)
        }

        // 9. 全局正则：改过（含手动打开）→ 留
        var deleteRegex = Set<String>()
        for id in ids(.globalRegex) {
            guard let script = env.globalRegex.scripts.first(where: { $0.id == id }) else { note(id, .alreadyGone, "已经不在了"); continue }
            if modified(id, ImportFingerprint.of(script)) { note(id, .kept, "规则改过（含手动打开）"); continue }
            deleteRegex.insert(id)
        }

        // —— 从叶到根删 ——
        for id in deleteConversations.sorted() {
            guard let conversation = conversations[id] else { continue }
            try deleteConversationArtifacts(conversationId: id, profileId: conversation.profileId, in: context)
            note(id, .deleted, "未改动、未被引用")
        }
        for book in deleteBooks {
            context.delete(book)
            note(book.id.uuidString, .deleted, "未改动、所属楼层 / 对话已删")
        }
        try context.save()
        for profile in deleteFloors {
            env.profiles.deleteProfile(profile, deleteData: false)
            guard !env.profiles.profiles.contains(where: { $0.id == profile.id }) else {
                note(profile.id, .kept, "楼层删不掉（至少留一个楼层或卡绑定保存失败）"); continue
            }
            note(profile.id, .deleted, "未改动，里面的导入对话都已删")
        }
        let floorsGone = Set(deleteFloors.map(\.id)).subtracting(env.profiles.profiles.map(\.id))
        let presetIds = deletePresets.filter { id in
            guard let owner = env.presets.preset(byId: id)?.ownerProfileId else { return true }
            return floorsGone.contains(owner)
        }
        try env.presets.discardNew(ids: presetIds)
        for id in presetIds { note(id, .deleted, "未改动、没人用") }
        for id in deletePresets.subtracting(presetIds) { note(id, .kept, "所属楼层没删掉") }
        let cardIds = deleteCards.filter { id in
            guard let pid = env.cards.cards.first(where: { $0.id == id })?.linkedProfileId else { return true }
            return !env.profiles.profiles.contains { $0.id == pid }
        }
        try env.cards.remove(ids: cardIds)
        for id in cardIds { note(id, .deleted, "未改动、楼层已删或没楼层") }
        for id in deleteCards.subtracting(cardIds) { note(id, .kept, "绑定的楼层没删掉") }
        try env.personas.remove(ids: deletePersonas)
        for id in deletePersonas { note(id, .deleted, "未改动、没对话在用") }
        try env.globalBooks.remove(ids: deleteGlobalBooks)
        for id in deleteGlobalBooks { note(id, .deleted, "未改动、没人引用") }
        if !deleteRegex.isEmpty { try env.globalRegex.save(env.globalRegex.scripts.filter { !deleteRegex.contains($0.id) }) }
        for id in deleteRegex { note(id, .deleted, "未改动") }

        // 来源记录：删掉的 / 已不在的目标标撤回；原件与报告保留
        let now = Date()
        let gone = Set(items.filter { $0.action != .kept }.map(\.id))
        var batchIds = Set<String>()
        for (path, versions) in source.files {
            source.files[path] = versions.map { version in
                var copy = version
                guard batchId == nil || version.batchId == batchId else { return copy }
                batchIds.insert(version.batchId)
                copy.targets = version.targets.map { target in
                    var t = target
                    if gone.contains(t.id) && t.retractedAt == nil { t.retractedAt = now }
                    return t
                }
                return copy
            }
        }
        for index in source.batches.indices where batchIds.contains(source.batches[index].id) { source.batches[index].retractedAt = now }
        let report = SillyTavernRetractReport(sourceId: sourceId, batchIds: batchIds.sorted(), date: now,
                                              items: items.sorted { ($0.kind, $0.relativePath, $0.id) < ($1.kind, $1.relativePath, $1.id) })
        try env.sources.writeReport(report, file: "\(batchId ?? "source-\(sourceId)")-retract.json")
        try env.sources.save(source)
        return report
    }

    /// 收藏夹 / 贴纸 / 节点卡片引用了这份对话
    private static func externalReference(conversation: Conversation, nodes: [MessageNode], context: ModelContext) throws -> String? {
        let id = conversation.id
        let profileId = conversation.profileId
        if try context.fetchCount(FetchDescriptor<FavoriteItem>(predicate: #Predicate { $0.conversationId == id && $0.profileId == profileId })) > 0 {
            return "被收藏引用"
        }
        if try context.fetchCount(FetchDescriptor<PlacedSticker>(predicate: #Predicate { $0.conversationId == id })) > 0 {
            return "贴着贴纸"
        }
        let nodeIds = Set(nodes.map(\.id))
        let cards = try context.fetch(FetchDescriptor<UserCard>(predicate: #Predicate { $0.profileId == profileId }))
        if cards.contains(where: { $0.attachedToNodeId.map(nodeIds.contains) ?? false }) { return "消息上挂着卡片" }
        return nil
    }
}
