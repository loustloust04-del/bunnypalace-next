import Foundation
import CryptoKit
import SwiftData

/// 时间机器(mp 版) - 定时备份引擎.
/// 详细设计: docs/plan-time-machine.md / docs/research-time-machine.md
///
/// 关键决策:
/// - 备份目录: iCloud/Documents/backup/<yyyy-MM-dd>/<pid>/conversations/<convId>.json
/// - 对话 JSON 复用 SyncStore.ConversationDocument schema(零新代码 + 跨用途读得通)
/// - 增量: sha256(JSON) 跟当天 day-manifest 比对, 没变直接跳过
/// - 触发: MemoryPalaceApp.swift scenePhase background, 跟 SyncStore.exportChanged 并列(独立开关)
/// - 稀疏: 7 天每天 / 7-30 天每周 / >30 删 (macOS Time Machine 同款)
/// - pre-restore-<ISO8601>: 还原前自动快照, 独立 30 天保留, 不参与稀疏
enum BackupStore {

    static let isEnabledKey = "backupAutoEnabled"
    static let lastSnapshotKey = "backupLastSnapshotAt"   // BreadcrumbLog/UI 显示用
    static let containerLowSpaceAlertKey = "backupLowSpaceAlertShown"

    /// 用户开关. 默认关. 首启 onboarding 让用户开启.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: isEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: isEnabledKey) }
    }

    /// 同设备并发(两次同时切后台)守护: NSLock 串行化 snapshot + prune.
    private static let opLock = NSLock()

    /// iCloud 容量阈值: < 200MB 暂停备份(用户清出空间后下次 background 自动恢复).
    private static let minFreeBytes: Int64 = 200 * 1024 * 1024

    // MARK: - Roots

    /// 测试注入用; nil = 用 iCloud 容器. (跟 SyncStore.overrideRoot 同款)
    static var overrideRoot: URL?

    /// 备份根: iCloud/Documents/backup/. nil = iCloud 未就绪.
    /// ⚠️ 不依赖 FileLibraryStore.iCloudDocumentsRoot() — 那个走 cachedUbiquityDocuments,
    /// 而 prime 只在 fileLibraryICloudEnabled 开关开时跑(文件库的开关), 跟时间机器无关。
    /// 时间机器自己拉 ubiquity URL: macOS 用 Mobile Documents 裸路径, iOS 用 ubiquity API。
    /// 后台线程调 url(forUbiquityContainerIdentifier:) 是文档允许的(主线程首调会卡才警告)。
    static func backupRoot() -> URL? {
        if let overrideRoot {
            try? FileManager.default.createDirectory(at: overrideRoot, withIntermediateDirectories: true)
            return overrideRoot
        }
        let docs: URL?
        #if os(macOS)
        docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~susu~MemoryPalace/Documents", isDirectory: true)
        #else
        // 优先用文件库的 cache (启动时若 prime 过更快), fallback 自己同步拉
        docs = FileLibraryStore.iCloudDocumentsRoot()
            ?? FileManager.default.url(forUbiquityContainerIdentifier: FileLibraryStore.iCloudContainerId)?
                .appendingPathComponent("Documents", isDirectory: true)
        #endif
        guard let docs else { return nil }
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let dir = docs.appendingPathComponent("backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func manifestURL() -> URL? {
        backupRoot()?.appendingPathComponent("manifest.json")
    }

    private static func dayRoot(date: String) -> URL? {
        guard let root = backupRoot() else { return nil }
        let dir = root.appendingPathComponent(date, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func dayManifestURL(date: String) -> URL? {
        dayRoot(date: date)?.appendingPathComponent(".day-manifest.json")
    }

    private static func profileRoot(date: String, profileId: String) -> URL? {
        guard let day = dayRoot(date: date) else { return nil }
        let dir = day.appendingPathComponent(profileId, isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Codec (跟 SyncStore 完全同款, 保持 JSON 互通)

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    // MARK: - Snapshot

    /// 增量定时快照. 调用时机: scenePhase = background 钩子 / 首次开启自动备份 / 手动"立即备份"按钮.
    /// 同日多次进 background → 同 conv 没变就 sha 命中跳过, 真变了才重写.
    /// progress: (processed, total) — 回调在调用线程, 调用方自己 dispatch 主线程.
    /// force: true 时跳过 isEnabled 检查("立即备份"按钮场景, 用户没开自动也能手动跑).
    static func snapshotIfNeeded(context: ModelContext, force: Bool = false, progress: ((Int, Int) -> Void)? = nil) -> SnapshotResult {
        guard force || isEnabled else {
            print("[BackupStore] snapshotIfNeeded SKIP: disabled")
            return SnapshotResult(error: "disabled")
        }
        guard opLock.try() else {
            print("[BackupStore] snapshotIfNeeded SKIP: busy")
            return SnapshotResult(error: "busy")
        }
        defer { opLock.unlock() }

        guard let root = backupRoot() else {
            print("[BackupStore] snapshotIfNeeded FAIL: backupRoot() returned nil — iCloud container not available")
            return SnapshotResult(error: "iCloud not ready")
        }
        print("[BackupStore] snapshotIfNeeded START root=\(root.path)")

        // 容量探测: < 200MB 时不写
        if let free = freeBytes(at: root), free < minFreeBytes {
            BreadcrumbLog.shared.add("⏰", "backup skipped: low iCloud free \(free / 1024 / 1024)MB")
            return SnapshotResult(error: "low space")
        }

        let date = todayDateString()
        var result = SnapshotResult()

        // 读当天 day-manifest, 没有就建空的
        var day = loadDayManifest(date: date) ?? DayManifest(date: date)

        // 跑当前所有 profile (走 ProfileManager.loadProfiles 静态而非 @State, 后台 context 安全)
        let profiles = ProfileManager.loadProfiles()

        // 预扫总对话数给 progress callback 用
        var totalConvCount = 0
        for profile in profiles {
            let pid = profile.id
            let countDesc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == pid }
            )
            totalConvCount += (try? context.fetchCount(countDesc)) ?? 0
        }
        var processedSoFar = 0
        progress?(0, totalConvCount)

        for profile in profiles {
            let pid = profile.id
            let convDescriptor = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == pid }
            )
            guard let conversations = try? context.fetch(convDescriptor) else { continue }

            // 既有 ProfileBackup 中的 sha 表(若有)
            var existing = day.profiles.first(where: { $0.profileId == pid })?.conversations ?? []
            var shaTable: [String: String] = [:]
            for ref in existing { shaTable[ref.conversationId] = ref.sha256 }

            var newRefs: [ConversationRef] = []
            for conv in conversations {
                let convId = conv.id
                let nodeDescriptor = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == pid }
                )
                let nodes = (try? context.fetch(nodeDescriptor)) ?? []
                guard let data = encodeConversation(conv, nodes: nodes, profileId: pid),
                      let convURL = profileRoot(date: date, profileId: pid)?
                          .appendingPathComponent("\(convId).json") else { continue }

                let sha = sha256Hex(data)
                if shaTable[convId] == sha, FileManager.default.fileExists(atPath: convURL.path) {
                    // 已写过且内容没变, 留旧引用
                    if let ref = existing.first(where: { $0.conversationId == convId }) {
                        newRefs.append(ref)
                    }
                    result.skipped += 1
                    processedSoFar += 1
                    progress?(processedSoFar, totalConvCount)
                    continue
                }

                do {
                    try data.write(to: convURL, options: .atomic)
                    newRefs.append(ConversationRef(
                        conversationId: convId,
                        title: conv.title,
                        nodeCount: nodes.count,
                        updateTime: conv.updateTime,
                        sizeBytes: data.count,
                        sha256: sha
                    ))
                    result.written += 1
                    result.totalSizeBytes += data.count
                } catch {
                    BreadcrumbLog.shared.add("⏰", "backup write failed conv=\(convId.prefix(8)) err=\(error)")
                }
                processedSoFar += 1
                progress?(processedSoFar, totalConvCount)
            }

            // 也顺手写 floor.json (楼层名片, 跟 SyncStore.publishFloorInfo 一致 schema)
            if let floorURL = dayRoot(date: date)?
                .appendingPathComponent(pid, isDirectory: true)
                .appendingPathComponent("floor.json") {
                let info = SyncStore.FloorInfo(
                    profileId: pid, name: profile.name, emoji: profile.emoji, updatedAt: Date()
                )
                if let data = try? encoder.encode(info) {
                    try? data.write(to: floorURL, options: .atomic)
                }
            }

            if !newRefs.isEmpty {
                let pb = ProfileBackup(
                    profileId: pid,
                    floorName: profile.name,
                    floorEmoji: profile.emoji,
                    conversations: newRefs
                )
                if let idx = day.profiles.firstIndex(where: { $0.profileId == pid }) {
                    day.profiles[idx] = pb
                } else {
                    day.profiles.append(pb)
                }
            }
            existing.removeAll()  // free
        }

        // 当天总大小: 含所有 profile 所有 conv(写过的 + sha 命中跳过的)
        result.totalSizeBytes = day.profiles.reduce(0) { acc, pb in
            acc + pb.conversations.reduce(0) { $0 + $1.sizeBytes }
        }

        saveDayManifest(day)
        updateGlobalManifest(date: date, kind: .scheduled, day: day)
        UserDefaults.standard.set(Date(), forKey: lastSnapshotKey)
        BreadcrumbLog.shared.add("⏰", "backup snapshot date=\(date) written=\(result.written) skipped=\(result.skipped)")
        return result
    }

    /// 还原前自动快照, 独立目录 pre-restore-<ISO8601Z>.
    /// 失败抛 throws, 调用方据此决定是否继续 restore.
    @discardableResult
    static func createPreRestoreSnapshot(context: ModelContext) throws -> BackupEntry {
        guard let root = backupRoot() else {
            throw BackupError.iCloudNotReady
        }
        if let free = freeBytes(at: root), free < minFreeBytes {
            throw BackupError.lowSpace
        }

        let stamp = preRestoreDateString()
        var day = DayManifest(date: stamp)

        let profiles = ProfileManager.loadProfiles()
        var written = 0
        var totalSize = 0
        for profile in profiles {
            let pid = profile.id
            let convDescriptor = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == pid }
            )
            guard let conversations = try? context.fetch(convDescriptor) else { continue }
            var refs: [ConversationRef] = []
            for conv in conversations {
                let convId = conv.id
                let nodeDescriptor = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == pid }
                )
                let nodes = (try? context.fetch(nodeDescriptor)) ?? []
                guard let data = encodeConversation(conv, nodes: nodes, profileId: pid),
                      let convURL = profileRoot(date: stamp, profileId: pid)?
                          .appendingPathComponent("\(convId).json") else { continue }
                try data.write(to: convURL, options: .atomic)
                refs.append(ConversationRef(
                    conversationId: convId, title: conv.title,
                    nodeCount: nodes.count, updateTime: conv.updateTime,
                    sizeBytes: data.count, sha256: sha256Hex(data)
                ))
                written += 1
                totalSize += data.count
            }
            if !refs.isEmpty {
                day.profiles.append(ProfileBackup(
                    profileId: pid, floorName: profile.name,
                    floorEmoji: profile.emoji, conversations: refs
                ))
            }
        }
        saveDayManifest(day)
        updateGlobalManifest(date: stamp, kind: .preRestore, day: day)
        BreadcrumbLog.shared.add("⏰", "pre-restore snapshot stamp=\(stamp) written=\(written)")

        guard let entry = listBackups().first(where: { $0.date == stamp }) else {
            throw BackupError.manifestNotWritten
        }
        return entry
    }

    // MARK: - Restore

    /// 三档粒度还原. 强制覆盖语义(scope 内 SwiftData 必须跟备份一致, 多的删, 缺的插).
    ///
    /// ⚠️ **后台线程上跑**: 大库整库还原节点数可上万, 主线程操作 SwiftData + 一次性 save 会
    /// 卡死 UI(粟粟实测整库还原直接卡死). 调用方必须 DispatchQueue.global async + 后台
    /// ModelContext(container), 完成后让用户重启 app 让主 ctx 重新 fetch。
    ///
    /// 流程:
    /// 1. 自动 pre-restore snapshot, 失败抛
    /// 2. 加载 day-manifest, 决定 scope 内要还原哪些 (pid, convId)
    /// 3. SwiftData 比对: 备份有 SwiftData 没 → insert; 都有 → force update; SwiftData 有 scope 内备份没 → delete
    /// 4. context.save()
    /// 5. 清 SyncStore export 指纹(避免回环把还原的版本当"新变化"再 export 上去)
    ///
    /// progress: (processed, total) — 调用方自己 dispatch 主线程。
    static func restore(date: String, scope: RestoreScope, context: ModelContext, progress: ((Int, Int) -> Void)? = nil) throws -> RestoreResult {
        guard backupRoot() != nil else { throw BackupError.iCloudNotReady }
        guard let day = loadDayManifest(date: date) else { throw BackupError.dayNotFound(date) }

        // 1. pre-restore (后台 ctx 上跑)
        let preEntry = try createPreRestoreSnapshot(context: context)

        var result = RestoreResult()
        result.preRestoreEntry = preEntry

        // 2. 决定 scope 内目标 (pid -> 备份里属于该 scope 的 conv 集)
        let targetByPid: [String: [ConversationRef]] = filterScope(day: day, scope: scope)
        // 洞 6: 本次还原覆盖到的楼层集合. 范围内的楼层之间可以互相覆盖归属(备份对它们是全局真相),
        // 范围外的楼层一律不许碰 —— 那是偷.
        let restoredProfileIds = Set(targetByPid.keys)
        let totalConv = targetByPid.values.reduce(0) { $0 + $1.count }
        var processed = 0
        progress?(0, totalConv)

        for (pid, refs) in targetByPid {
            // 删 scope 内 SwiftData 有但备份没的 conv
            try deleteOrphanConversations(scope: scope, pid: pid, backupConvIds: Set(refs.map(\.conversationId)), context: context, result: &result)

            for ref in refs {
                if let doc = loadConversationDocument(date: date, profileId: pid, convId: ref.conversationId) {
                    if try crossProfileBlocked(doc: doc, targetProfileId: pid,
                                               allowedProfileIds: restoredProfileIds, context: context) {
                        result.conversationsSkippedCrossProfile += 1
                        BreadcrumbLog.shared.add("⏰", "restore skip cross-profile conv=\(ref.conversationId.prefix(8))")
                    } else {
                        try restoreConversation(doc: doc, profileId: pid, context: context, result: &result)
                        result.conversationsRestored += 1
                    }
                }
                processed += 1
                progress?(processed, totalConv)
            }
            result.profilesRestored += 1

            // 清 SyncStore 指纹(下次 export 会重新计算; 不清会回环)
            clearSyncExportFingerprint(pid: pid)
        }

        do {
            try context.save()
        } catch {
            BreadcrumbLog.shared.add("⏰", "restore save failed date=\(date) err=\(error)")
            throw error
        }
        BreadcrumbLog.shared.add("⏰", "restore done date=\(date) scope=\(String(describing: scope)) +conv=\(result.conversationsRestored) +node=\(result.nodesInserted) ~node=\(result.nodesUpdated) -node=\(result.nodesDeleted)")
        return result
    }

    private static func filterScope(day: DayManifest, scope: RestoreScope) -> [String: [ConversationRef]] {
        var out: [String: [ConversationRef]] = [:]
        for pb in day.profiles {
            switch scope {
            case .everything:
                out[pb.profileId] = pb.conversations
            case .profile(let pid) where pb.profileId == pid:
                out[pb.profileId] = pb.conversations
            case .conversation(let pid, let convId) where pb.profileId == pid:
                let filtered = pb.conversations.filter { $0.conversationId == convId }
                if !filtered.isEmpty { out[pb.profileId] = filtered }
            default:
                continue
            }
        }
        return out
    }

    private static func loadConversationDocument(date: String, profileId: String, convId: String) -> SyncStore.ConversationDocument? {
        guard let url = profileRoot(date: date, profileId: profileId)?
            .appendingPathComponent("\(convId).json"),
              let data = try? Data(contentsOf: url),
              let doc = try? decoder.decode(SyncStore.ConversationDocument.self, from: data) else {
            return nil
        }
        guard doc.schemaVersion <= SyncStore.schemaVersion else { return nil }
        return doc
    }

    private static func deleteOrphanConversations(
        scope: RestoreScope, pid: String,
        backupConvIds: Set<String>,
        context: ModelContext, result: inout RestoreResult
    ) throws {
        // 单对话粒度的 restore: 不删任何"非该 conv"的对话(只动那一条)
        if case .conversation = scope { return }

        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == pid }
        )
        let current = (try? context.fetch(descriptor)) ?? []
        for conv in current where !backupConvIds.contains(conv.id) {
            let convId = conv.id
            let p = pid
            let nodeDesc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == p }
            )
            if let nodes = try? context.fetch(nodeDesc) {
                for n in nodes { context.delete(n); result.nodesDeleted += 1 }
            }
            context.delete(conv)
        }
    }

    /// 洞 6: 整份跳过判定.
    ///
    /// `Conversation.id` / `MessageNode.id` 是**全库** `@Attribute(.unique)`, `profileId` 只是普通列.
    /// 按 `id == X && profileId == 目标楼层` 查重挡不住"同 id 在另一楼层"——insert 会撞 unique
    /// 静默 upsert, 把那一行的全部属性(含 profileId)改写成新值 = 对话被从原楼层偷走.
    ///
    /// 先用 ImportSupport 那对批量冲突查询(四条导入路径同款)问"有没有撞别的楼层";
    /// 撞了再看占用方在不在本次还原范围内——在范围内不算偷(整库还原时备份是全局真相,
    /// 对话在被还原的楼层之间移动是既有语义), 范围外一律整份跳过.
    private static func crossProfileBlocked(
        doc: SyncStore.ConversationDocument,
        targetProfileId: String,
        allowedProfileIds: Set<String>,
        context: ModelContext
    ) throws -> Bool {
        let convConflicts = try findCrossProfileConversationConflicts(
            candidateIds: [doc.conversationId], currentProfileId: targetProfileId, in: context
        )
        let nodeConflicts = try findCrossProfileNodeConflicts(
            candidateIds: doc.nodes.map(\.id), currentProfileId: targetProfileId, in: context
        )
        guard !convConflicts.isEmpty || !nodeConflicts.isEmpty else { return false }

        if !convConflicts.isEmpty {
            let cid = doc.conversationId
            let owner = try context.fetch(FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.id == cid }
            )).first?.profileId
            if let owner, !allowedProfileIds.contains(owner) { return true }
        }

        if !nodeConflicts.isEmpty {
            let conflictIds = Array(nodeConflicts)
            for start in stride(from: 0, to: conflictIds.count, by: 500) {
                let chunk = Array(conflictIds[start..<min(start + 500, conflictIds.count)])
                let hits = try context.fetch(FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { chunk.contains($0.id) }
                ))
                if hits.contains(where: { !allowedProfileIds.contains($0.profileId) }) { return true }
            }
        }
        return false
    }

    private static func restoreConversation(
        doc: SyncStore.ConversationDocument,
        profileId: String,
        context: ModelContext,
        result: inout RestoreResult
    ) throws {
        let convId = doc.conversationId
        let pid = profileId

        // upsert Conversation
        let convDescriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.id == convId && $0.profileId == pid }
        )
        let existing = (try? context.fetch(convDescriptor))?.first
        let conv: Conversation
        if let existing {
            existing.title = doc.title
            existing.updateTime = doc.updateTime
            existing.currentNodeId = doc.currentNodeId
            existing.branchSelectionData = doc.branchSelectionData
            existing.provider = doc.provider
            existing.isFavorite = doc.isFavorite
            existing.folderId = doc.folderId
            existing.pinnedAt = doc.pinnedAt
            existing.memoryEnabled = doc.memoryEnabled
            existing.selectedModelId = doc.selectedModelId
            existing.isTrashed = doc.isDeleted ?? false
            existing.trashedAt = doc.deletedAt
            conv = existing
        } else {
            let created = Conversation(
                id: doc.conversationId, title: doc.title,
                createTime: doc.createTime, updateTime: doc.updateTime,
                currentNodeId: doc.currentNodeId, provider: doc.provider,
                profileId: profileId
            )
            created.isFavorite = doc.isFavorite
            created.folderId = doc.folderId
            created.pinnedAt = doc.pinnedAt
            created.memoryEnabled = doc.memoryEnabled
            created.selectedModelId = doc.selectedModelId
            created.branchSelectionData = doc.branchSelectionData
            created.isTrashed = doc.isDeleted ?? false
            created.trashedAt = doc.deletedAt
            context.insert(created)
            conv = created
        }

        // 节点强制对齐: 备份 ids → SwiftData
        let backupNodeIds = Set(doc.nodes.map(\.id))
        let nodeDescriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == pid }
        )
        let currentNodes = (try? context.fetch(nodeDescriptor)) ?? []
        var currentById: [String: MessageNode] = [:]
        for n in currentNodes { currentById[n.id] = n }

        // 删 scope 内 SwiftData 有备份没的
        for (nid, node) in currentById where !backupNodeIds.contains(nid) {
            context.delete(node)
            result.nodesDeleted += 1
        }

        // upsert 备份里的所有节点
        for nd in doc.nodes {
            if let local = currentById[nd.id] {
                local.role = nd.role
                local.content = nd.content
                local.contentType = nd.contentType
                local.createTime = nd.createTime
                local.parentId = nd.parentId
                local.childrenIds = nd.childrenIds
                local.isFavorite = nd.isFavorite
                local.isPinned = nd.isPinned
                local.pinnedAt = nd.pinnedAt
                local.segmentsData = nd.segmentsData
                local.isSyntheticRoot = nd.isSyntheticRoot ?? false
                local.ccMessageId = nd.ccMessageId
                local.replyToId = nd.replyToId
                local.replyQuote = nd.replyQuote
                local.ccEdited = nd.ccEdited
                local.ccThinking = nd.ccThinking
                local.imageDescsData = nd.imageDescsData
                result.nodesUpdated += 1
            } else {
                let node = MessageNode(
                    id: nd.id, role: nd.role, content: nd.content,
                    contentType: nd.contentType, createTime: nd.createTime,
                    parentId: nd.parentId, childrenIds: nd.childrenIds,
                    conversationId: convId, profileId: profileId
                )
                node.isFavorite = nd.isFavorite
                node.isPinned = nd.isPinned
                node.pinnedAt = nd.pinnedAt
                node.segmentsData = nd.segmentsData
                node.isSyntheticRoot = nd.isSyntheticRoot ?? false
                node.ccMessageId = nd.ccMessageId
                node.replyToId = nd.replyToId
                node.replyQuote = nd.replyQuote
                node.ccEdited = nd.ccEdited
                node.ccThinking = nd.ccThinking
                node.imageDescsData = nd.imageDescsData
                context.insert(node)
                result.nodesInserted += 1
            }
        }

        // nodeCount 重算
        conv.nodeCount = countDisplayableOnPath(doc.nodes, leafId: doc.currentNodeId, id: \.id, parentId: \.parentId) {
            $0.isSyntheticRoot != true && isDisplayableNode(role: $0.role, content: $0.content)
        }
    }

    private static func clearSyncExportFingerprint(pid: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryPalace/sync-state", isDirectory: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(pid).export.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(pid).import.json"))
    }

    // MARK: - Sparse Prune

    /// 7 天内每天保留 / 7-30 天每周保留 1 份 / >30 天删. pre-restore 独立 30 天.
    /// 跑在 snapshotIfNeeded 之后(轻量, 主要是 manifest 算+少量 removeItem).
    static func pruneOldBackups() {
        guard isEnabled, opLock.try() else { return }
        defer { opLock.unlock() }

        var manifest = loadGlobalManifest()
        let now = Date()
        let cal = Calendar(identifier: .iso8601)

        var keep: Set<String> = []
        var weekAnchors: Set<String> = []           // 7-30 天: 每 ISO 周保留一份(最早的)
        let scheduled = manifest.entries.filter { $0.kind == .scheduled }
            .sorted { $0.date < $1.date }   // 升序方便取每周第一份

        for entry in scheduled {
            guard let entryDate = parseDate(entry.date) else { continue }
            let days = cal.dateComponents([.day], from: entryDate, to: now).day ?? 9999
            if days <= 6 {
                keep.insert(entry.date)
            } else if days <= 29 {
                let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: entryDate)
                let bucket = "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
                if !weekAnchors.contains(bucket) {
                    weekAnchors.insert(bucket)
                    keep.insert(entry.date)
                }
            }
            // > 29 天 不进 keep, 准备删
        }

        // pre-restore 单独 30 天保留(不受稀疏)
        for entry in manifest.entries where entry.kind == .preRestore {
            guard let entryDate = parsePreRestoreDate(entry.date) else { continue }
            let days = cal.dateComponents([.day], from: entryDate, to: now).day ?? 9999
            if days <= 29 { keep.insert(entry.date) }
        }

        var removed = 0
        let toRemove = manifest.entries.filter { !keep.contains($0.date) }
        for entry in toRemove {
            if let url = dayRoot(date: entry.date) {
                try? FileManager.default.removeItem(at: url)
            }
            removed += 1
        }
        manifest.entries.removeAll { !keep.contains($0.date) }
        saveGlobalManifest(manifest)

        if removed > 0 {
            BreadcrumbLog.shared.add("⏰", "backup prune removed=\(removed) kept=\(keep.count)")
        }
    }

    // MARK: - Listing

    /// 全部备份按时间倒序(scheduled + preRestore 都含).
    static func listBackups() -> [BackupEntry] {
        loadGlobalManifest().entries.sorted { $0.lastWriteAt > $1.lastWriteAt }
    }

    /// 读某一天的详细清单(列对话用).
    static func loadDay(date: String) -> DayManifest? {
        loadDayManifest(date: date)
    }

    // MARK: - Internals: Encode / sha / manifest io

    private static func encodeConversation(_ conv: Conversation, nodes: [MessageNode], profileId: String) -> Data? {
        let doc = SyncStore.ConversationDocument(
            schemaVersion: SyncStore.schemaVersion,
            conversationId: conv.id,
            profileId: profileId,
            title: conv.title,
            createTime: conv.createTime,
            updateTime: conv.updateTime,
            currentNodeId: conv.currentNodeId,
            provider: conv.provider,
            isFavorite: conv.isFavorite,
            folderId: conv.folderId,
            pinnedAt: conv.pinnedAt,
            memoryEnabled: conv.memoryEnabled,
            selectedModelId: conv.selectedModelId,
            nodes: nodes.map { node in
                SyncStore.NodeDocument(
                    isSyntheticRoot: node.isSyntheticRoot,
                    id: node.id, role: node.role, content: node.content, contentType: node.contentType,
                    createTime: node.createTime, parentId: node.parentId, childrenIds: node.childrenIds,
                    isFavorite: node.isFavorite, isPinned: node.isPinned, pinnedAt: node.pinnedAt,
                    segmentsData: node.segmentsData, ccMessageId: node.ccMessageId,
                    replyToId: node.replyToId, replyQuote: node.replyQuote, ccEdited: node.ccEdited, ccThinking: node.ccThinking,
                    imageDescsData: node.imageDescsData
                )
            },
            isDeleted: conv.isTrashed,
            deletedAt: conv.trashedAt,
            branchSelectionData: conv.branchSelectionData
        )
        return try? encoder.encode(doc)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadGlobalManifest() -> BackupManifest {
        guard let url = manifestURL(),
              let data = try? Data(contentsOf: url),
              let m = try? decoder.decode(BackupManifest.self, from: data) else {
            return BackupManifest()
        }
        return m
    }

    private static func saveGlobalManifest(_ m: BackupManifest) {
        guard let url = manifestURL(), let data = try? encoder.encode(m) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadDayManifest(date: String) -> DayManifest? {
        guard let url = dayManifestURL(date: date),
              let data = try? Data(contentsOf: url),
              let m = try? decoder.decode(DayManifest.self, from: data) else { return nil }
        return m
    }

    private static func saveDayManifest(_ m: DayManifest) {
        guard let url = dayManifestURL(date: m.date), let data = try? encoder.encode(m) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func updateGlobalManifest(date: String, kind: BackupEntry.Kind, day: DayManifest) {
        var m = loadGlobalManifest()
        let now = Date()
        let totalConv = day.profiles.reduce(0) { $0 + $1.conversations.count }
        let totalSize = day.profiles.reduce(0) { acc, pb in
            acc + pb.conversations.reduce(0) { $0 + $1.sizeBytes }
        }
        if let idx = m.entries.firstIndex(where: { $0.date == date }) {
            m.entries[idx].lastWriteAt = now
            m.entries[idx].profileIds = day.profiles.map(\.profileId)
            m.entries[idx].totalConversations = totalConv
            m.entries[idx].totalSizeBytes = totalSize
        } else {
            m.entries.append(BackupEntry(
                date: date, createdAt: now, lastWriteAt: now,
                profileIds: day.profiles.map(\.profileId),
                totalConversations: totalConv, totalSizeBytes: totalSize,
                kind: kind
            ))
        }
        saveGlobalManifest(m)
    }

    // MARK: - Date helpers

    private static func todayDateString() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current     // 用户本地一天界限
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func preRestoreDateString() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let s = f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "pre-restore-\(s)"
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private static func parsePreRestoreDate(_ s: String) -> Date? {
        // "pre-restore-2026-06-17T22-30-15Z" → "2026-06-17T22:30:15Z"
        let body = s.replacingOccurrences(of: "pre-restore-", with: "")
        guard let tIdx = body.firstIndex(of: "T") else { return nil }
        let head = String(body[..<tIdx])
        let tail = String(body[tIdx...]).replacingOccurrences(of: "-", with: ":")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: head + tail)
    }

    private static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Errors

enum BackupError: LocalizedError {
    case iCloudNotReady
    case lowSpace
    case manifestNotWritten
    case dayNotFound(String)
    case conversationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .iCloudNotReady: return "iCloud 还没就绪, 请稍后再试"
        case .lowSpace: return "iCloud 剩余空间不足 200 MB, 请清理后再试"
        case .manifestNotWritten: return "备份索引写入失败"
        case .dayNotFound(let d): return "找不到日期 \(d) 的备份"
        case .conversationNotFound(let id): return "找不到对话 \(id)"
        }
    }
}

