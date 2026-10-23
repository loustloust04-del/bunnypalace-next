import Foundation
import SwiftData

/// 路线 B 一次性迁移：per-profile store → unified single store。
/// 粟粟老数据（ghost-lily default store + 其他 profile 的 `.store` 文件）→ 合并进
/// `ProfileManager.unifiedStoreURL`，每条 @Model 设 profileId = 原 profile.id。
///
/// 迁完把 legacy store 文件 rename 成 `.backup-YYYY-MM-DD` 永久保留（粟粟批注）。
///
/// 幂等性（.ai L5）：每个 profile 迁移前先 clearProfileData 把该 profile 的残留
/// （上次半途 crash 留的）删干净再插入，保证重跑无重复数据。
///
/// MessageNode 用 `parentId: String?` 做树关系（不是 @Relationship），所以无需 2-pass
/// 复制 —— 1-pass 直接 copy 就行，parent/child 关系通过 id 字符串已经自动 match。
///
/// xcdoc: /documentation/SwiftData/ModelContext/delete(model:where:includeSubclasses:)
/// Plan: docs/plan-unified-container.md Step G
enum UnifiedContainerMigration {
    private static let doneKey = "hasUnifiedContainerMigrationV1"
    private static let inProgressKey = "unifiedContainerMigrationInProgressProfileId"
    private static let backupSuffix = "backup-2026-04-22"

    /// 返回是否需要迁移：UserDefaults flag 没置 + 至少一个 legacy store 存在
    static func needsMigration(profiles: [Profile]) -> Bool {
        if UserDefaults.standard.bool(forKey: doneKey) { return false }
        if FileManager.default.fileExists(atPath: Profile.legacyDefaultStoreURL.path) {
            return true
        }
        for profile in profiles where !profile.usesDefaultStore {
            if FileManager.default.fileExists(atPath: profile.legacyStoreURL.path) {
                return true
            }
        }
        return false
    }

    /// 主入口。App.init 同步调用，迁移期间 app 启动慢 ~数十秒（粟粟能接受）。
    static func runMigration(profiles: [Profile], unifiedCtx: ModelContext) throws {
        let t0 = Date()
        var openFailures = 0
        print("[migration] ===== start unified container migration =====")
        for profile in profiles {
            let legacyURL = legacyURL(for: profile)
            guard FileManager.default.fileExists(atPath: legacyURL.path) else {
                print("[migration] skip \(profile.id) — no legacy store")
                continue
            }

            UserDefaults.standard.set(profile.id, forKey: inProgressKey)
            let tProfile = Date()
            print("[migration] ▶ profile=\(profile.id)")

            // 打开 legacy container —— 用新 schema 做 lightweight migration（给老数据
            // 自动补 profileId="" + 建 #Index）。**必须 allowsSave: true** 让 SwiftData
            // 写入 migration metadata 到 legacy store；反正迁完 rename 成 .backup。
            // .ai L4 审计：allowsSave: false 会在 schema mismatch 时失败。
            let legacyConfig = ModelConfiguration(
                "legacy-\(profile.id)",
                schema: ProfileManager.fullSchema,
                url: legacyURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let legacyContainer: ModelContainer
            do {
                legacyContainer = try ModelContainer(
                    for: ProfileManager.fullSchema,
                    configurations: [legacyConfig]
                )
            } catch {
                print("[migration] ✗ failed opening legacy store for \(profile.id): \(error)")
                openFailures += 1
                continue
            }
            let legacyCtx = ModelContext(legacyContainer)

            // 幂等清 unified 里该 profile 的残留（.ai L5）
            try clearProfileData(profileId: profile.id, ctx: unifiedCtx)

            // 按依赖顺序迁（Conversation 先于 MessageNode；ImportRecord 先于 ImportConversationChange）
            let skippedConvIds = try migrateConversations(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateMessageNodes(profile: profile, skippedConversationIds: skippedConvIds, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateUserCards(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateConversationTags(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateFavoriteItems(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateMemories(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateMemoryNotes(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateWorldBooks(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateStickerAssets(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migratePlacedStickers(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateImportRecords(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)
            try migrateImportConversationChanges(profile: profile, legacyCtx: legacyCtx, unifiedCtx: unifiedCtx)

            // legacy store → .backup
            renameLegacyToBackup(url: legacyURL)

            let dt = Date().timeIntervalSince(tProfile)
            print(String(format: "[migration] ✓ profile=%@ in %.1fs", profile.id, dt))
        }

        UserDefaults.standard.removeObject(forKey: inProgressKey)
        // open 失败的 legacy store 没迁进来：不置 done，下次启动重试（重试成本 = 一次 open fail，毫秒级）
        // 旧行为无条件置 done → 打不开的库永远静默丢失（P1-2 缺口，Air 上 3917BA1A 等两库疑此路留下）
        if openFailures == 0 {
            UserDefaults.standard.set(true, forKey: doneKey)
        } else {
            print("[migration] ⚠︎ \(openFailures) legacy store(s) failed to open — done flag NOT set, will retry next launch")
        }
        let total = Date().timeIntervalSince(t0)
        print(String(format: "[migration] ===== ALL DONE in %.1fs =====", total))
    }

    // MARK: - Helpers

    private static func legacyURL(for profile: Profile) -> URL {
        profile.usesDefaultStore ? Profile.legacyDefaultStoreURL : profile.legacyStoreURL
    }

    // internal for MemoryPalaceTests（T4 sidecar 命名特征测试）
    static func renameLegacyToBackup(url: URL) {
        let backupURL = url.deletingPathExtension().appendingPathExtension("store.\(backupSuffix)")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            print("[migration] backup already exists, skip rename: \(backupURL.lastPathComponent)")
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: backupURL)
        } catch {
            print("[migration] ✗ rename main store failed: \(error)")
        }
        // SQLite sidecar 真实命名是连字符 xx.store-wal / xx.store-shm
        //（旧代码 appendingPathExtension 生成 xx.store.wal 永远匹配不到 →
        //  sidecar 原名残留、pending writes 留在原地，P0-B 实锤于 Air 容器取证）
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                let sidecarBackup = URL(fileURLWithPath: backupURL.path + suffix)
                try? FileManager.default.moveItem(at: sidecar, to: sidecarBackup)
            }
        }
    }

    // MARK: - Idempotent clear

    private static func clearProfileData(profileId: String, ctx: ModelContext) throws {
        let pid = profileId
        try ctx.delete(model: Conversation.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: MessageNode.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: UserCard.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: ConversationTag.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: FavoriteItem.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: Memory.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: MemoryNote.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: WorldBook.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: StickerAsset.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: PlacedSticker.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: ImportRecord.self, where: #Predicate { $0.profileId == pid })
        try ctx.delete(model: ImportConversationChange.self, where: #Predicate { $0.profileId == pid })
        try ctx.save()
        // .ai L2: flush pending changes, 防 delete + 后续 insert IO spike
        ctx.processPendingChanges()
    }

    // MARK: - Per-entity migration

    /// 返回因跨楼层冲突被跳过的对话 id（P0-1）：同 id 已属于其它 profile 时，
    /// insert 的 unique upsert 行为会把那行连 profileId 一起改写——必须跳过。
    private static func migrateConversations(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws -> Set<String> {
        let olds = try legacyCtx.fetch(FetchDescriptor<Conversation>())
        print("[migration]   conversations: \(olds.count)")
        let conflicted = try findCrossProfileConversationConflicts(
            candidateIds: olds.map(\.id),
            currentProfileId: profile.id,
            in: unifiedCtx
        )
        if !conflicted.isEmpty {
            print("[migration]   ⚠️ \(conflicted.count) conversations already owned by another profile — skipped")
        }
        for old in olds {
            if conflicted.contains(old.id) { continue }
            let new = Conversation(
                id: old.id,
                title: old.title,
                createTime: old.createTime,
                updateTime: old.updateTime,
                currentNodeId: old.currentNodeId,
                provider: old.provider,
                profileId: profile.id
            )
            new.isFavorite = old.isFavorite
            new.folderId = old.folderId
            new.nodeCount = old.nodeCount
            new.lastOpenedAt = old.lastOpenedAt
            // S4.5：老库可能 isDeleted=true（业务回收站态，框架冲突前的写入）
            // 或 isTrashed=true（已迁移过的）。两者都映射到新库的 isTrashed。
            new.isTrashed = old.isTrashed || old.isDeleted
            new.trashedAt = old.trashedAt ?? old.deletedAt
            new.importBatchId = old.importBatchId
            new.memoryEnabled = old.memoryEnabled
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
        unifiedCtx.processPendingChanges()
        return conflicted
    }

    private static func migrateMessageNodes(profile: Profile, skippedConversationIds: Set<String>, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<MessageNode>())
        print("[migration]   messageNodes: \(olds.count)")
        // P0-1：被跳过对话的节点不迁；节点自身 id 撞其它楼层的同样不迁（unique upsert 会抢行）
        let nodeConflicts = try findCrossProfileNodeConflicts(
            candidateIds: olds.map(\.id),
            currentProfileId: profile.id,
            in: unifiedCtx
        )
        if !nodeConflicts.isEmpty {
            print("[migration]   ⚠️ \(nodeConflicts.count) nodes already owned by another profile — skipped")
        }
        var counter = 0
        for old in olds {
            if skippedConversationIds.contains(old.conversationId) || nodeConflicts.contains(old.id) { continue }
            let new = MessageNode(
                id: old.id,
                role: old.role,
                content: old.content,
                contentType: old.contentType,
                createTime: old.createTime,
                parentId: old.parentId,
                childrenIds: old.childrenIds,
                conversationId: old.conversationId,
                profileId: profile.id
            )
            new.isFavorite = old.isFavorite
            new.isPinned = old.isPinned
            new.pinnedAt = old.pinnedAt
            // S4.5：见上方 Conversation 的同款注释
            new.isTrashed = old.isTrashed || old.isDeleted
            new.trashedAt = old.trashedAt ?? old.deletedAt
            unifiedCtx.insert(new)
            counter += 1
            // 每 500 条 save + flush，避免大数据量 OOM
            if counter % 500 == 0 {
                try unifiedCtx.save()
                unifiedCtx.processPendingChanges()
            }
        }
        try unifiedCtx.save()
        unifiedCtx.processPendingChanges()
    }

    private static func migrateUserCards(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<UserCard>())
        print("[migration]   userCards: \(olds.count)")
        for old in olds {
            let new = UserCard(content: old.content, attachedToNodeId: old.attachedToNodeId, profileId: profile.id)
            new.id = old.id
            new.imageData = old.imageData
            new.positionX = old.positionX
            new.positionY = old.positionY
            new.createTime = old.createTime
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }

    private static func migrateConversationTags(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<ConversationTag>())
        print("[migration]   conversationTags: \(olds.count)")
        for old in olds {
            let new = ConversationTag(name: old.name, emoji: old.emoji, order: old.order, profileId: profile.id)
            new.id = old.id
            new.createTime = old.createTime
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }

    private static func migrateFavoriteItems(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<FavoriteItem>())
        print("[migration]   favoriteItems: \(olds.count)")
        for old in olds {
            let new = FavoriteItem(
                nodeId: old.nodeId,
                conversationId: old.conversationId,
                tagId: old.tagId,
                contentPreview: old.contentPreview,
                profileId: profile.id
            )
            new.id = old.id
            new.createTime = old.createTime
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }

    private static func migrateMemories(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<Memory>())
        print("[migration]   memories: \(olds.count)")
        for old in olds {
            // Memory 已有 profileId 字段，legacy store 里可能是 "" 或正确值
            // 强制用当前 profile.id 覆盖
            let new = Memory(
                content: old.content,
                category: old.category,
                keywords: old.keywords,
                profileId: profile.id,
                isUserExplicit: old.isUserExplicit,
                extractedBy: old.extractedBy,
                sourceConversationId: old.sourceConversationId
            )
            new.id = old.id
            new.tokenCount = old.tokenCount
            new.accessCount = old.accessCount
            new.lastAccessedAt = old.lastAccessedAt
            new.decayWeight = old.decayWeight
            new.validUntil = old.validUntil
            new.createdAt = old.createdAt
            new.updatedAt = old.updatedAt
            new.embeddingData = old.embeddingData
            new.parentId = old.parentId
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }

    private static func migrateMemoryNotes(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<MemoryNote>())
        print("[migration]   memoryNotes: \(olds.count)")
        for old in olds {
            let new = MemoryNote(content: old.content, profileId: profile.id, source: old.source, isActive: old.isActive)
            new.id = old.id
            new.createdAt = old.createdAt
            new.updatedAt = old.updatedAt
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }

    private static func migrateWorldBooks(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<WorldBook>())
        print("[migration]   worldBooks: \(olds.count)")
        for old in olds {
            let new = WorldBook(name: old.name, profileId: profile.id, entries: old.entries)
            new.id = old.id
            new.scopeConversationId = old.scopeConversationId
            new.createdAt = old.createdAt
            new.updatedAt = old.updatedAt
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }

    private static func migrateStickerAssets(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<StickerAsset>())
        print("[migration]   stickerAssets: \(olds.count)")
        for old in olds {
            let new = StickerAsset(
                name: old.name,
                imagePath: old.imagePath,
                thumbnailPath: old.thumbnailPath,
                borderStyle: old.borderStyle,
                borderWidth: old.borderWidth,
                tags: old.tags,
                profileId: profile.id
            )
            new.id = old.id
            new.assetType = old.assetType
            new.originalImagePath = old.originalImagePath
            new.filterStyle = old.filterStyle
            new.noteContent = old.noteContent
            new.noteStyle = old.noteStyle
            new.createdAt = old.createdAt
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }

    private static func migratePlacedStickers(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<PlacedSticker>())
        print("[migration]   placedStickers: \(olds.count)")
        for old in olds {
            let new = PlacedSticker(
                stickerAssetId: old.stickerAssetId,
                conversationId: old.conversationId,
                nearestMessageId: old.nearestMessageId,
                positionX: old.positionX,
                positionY: old.positionY,
                rotation: old.rotation,
                scale: old.scale,
                zIndex: old.zIndex,
                noteContent: old.noteContent,
                noteStyle: old.noteStyle,
                profileId: profile.id
            )
            new.id = old.id
            new.isLocked = old.isLocked
            new.placedAt = old.placedAt
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }

    private static func migrateImportRecords(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<ImportRecord>())
        print("[migration]   importRecords: \(olds.count)")
        for old in olds {
            let new = ImportRecord(
                fileName: old.fileName,
                provider: old.provider,
                conversationCount: old.conversationCount,
                nodeCount: old.nodeCount,
                mode: old.mode,
                supportsUndo: old.supportsUndo,
                addedConversationCount: old.addedConversationCount,
                updatedConversationCount: old.updatedConversationCount,
                skippedConversationCount: old.skippedConversationCount,
                ignoredConversationCount: old.ignoredConversationCount,
                profileId: profile.id
            )
            new.id = old.id
            new.importDate = old.importDate
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }

    private static func migrateImportConversationChanges(profile: Profile, legacyCtx: ModelContext, unifiedCtx: ModelContext) throws {
        let olds = try legacyCtx.fetch(FetchDescriptor<ImportConversationChange>())
        print("[migration]   importConversationChanges: \(olds.count)")
        for old in olds {
            let new = ImportConversationChange(
                recordId: old.recordId,
                conversationId: old.conversationId,
                changeKind: old.changeKind,
                beforeConversationData: old.beforeConversationData,
                beforeNodesData: old.beforeNodesData,
                profileId: profile.id
            )
            new.id = old.id
            unifiedCtx.insert(new)
        }
        try unifiedCtx.save()
    }
}
