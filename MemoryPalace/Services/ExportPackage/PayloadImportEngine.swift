import Foundation
import SwiftData

/// 一次导入的计数。「已在其他楼层」（conflicts）不算在 ignored 里（#061 起；之前的导入记录是并在一起的）
struct ImportCounts: Equatable {
    var processed = 0
    var added = 0
    var copied = 0
    var updated = 0
    var skipped = 0
    var ignored = 0
    var conflicts = 0
    /// 「已在其他楼层」按对方楼层分（#061）；楼层 id 可能已经不在楼层列表里（删楼层时没删数据）
    var conflictsByProfile: [String: Int] = [:]
    /// 其中对方那份在回收站里的
    var conflictsTrashed = 0
    /// 同一次导入里多个文件都有、合进先导入那份的对话数（D10 / plan §2.4）
    var mergedDuplicates = 0
    var nodes = 0

    static func + (a: ImportCounts, b: ImportCounts) -> ImportCounts {
        ImportCounts(processed: a.processed + b.processed, added: a.added + b.added, copied: a.copied + b.copied,
                     updated: a.updated + b.updated, skipped: a.skipped + b.skipped, ignored: a.ignored + b.ignored,
                     conflicts: a.conflicts + b.conflicts,
                     conflictsByProfile: a.conflictsByProfile.merging(b.conflictsByProfile, uniquingKeysWith: +),
                     conflictsTrashed: a.conflictsTrashed + b.conflictsTrashed,
                     mergedDuplicates: a.mergedDuplicates + b.mergedDuplicates, nodes: a.nodes + b.nodes)
    }
}

/// ChatGPT / Claude 共用的写库循环（#043 D10：原先两个导入器 × 普通 / 叠加 各抄一份）。
///
/// 语义照搬原循环：
/// - 普通：本楼层已有 → 跳过
/// - 叠加：本楼层已有 → `shouldMergeConversation` 判断，要合就先存快照再合（只增不删）
/// - 两者都先查跨楼层冲突：撞了跳过，或按 copyConflicts 复制成本楼层副本
///
/// 多出来的三件：
/// - 每批 save 前把计数和 supportsUndo 写进导入记录（中途失败，已落库的批次也能撤回）
/// - 本次导入里先建过、后面文件又出现的对话强制合并，**不写 updated 快照**——
///   它已有一条 created，撤回时整条删；再存快照会被按快照复原回来
/// - 计数返回给调用方
final class PayloadImportEngine {
    let context: ModelContext
    let profileId: String
    let record: ImportRecord
    let merge: Bool
    let copyConflicts: Bool
    /// 注意事项（#050 E9）：同一次导入的几个引擎共用一个，完成页汇总
    let warnings: ImportWarnings
    private(set) var counts = ImportCounts()
    /// 导入清单（#061 B 期）：调用方每开始一个文件调 `beginSource`，之后的去向记在它名下
    private(set) var sources: [ImportManifest.Source] = []
    /// 楼层 id → 名字（导入当时的快照），清单里的冲突带上；不在里面 = 楼层已删
    var floorNames: [String: String] = [:]

    /// 本楼层已有的对话 id（开始前的 + 本次新建的）
    private var localIds: Set<String>
    /// 本次新建的对话 id
    private(set) var createdThisRun: Set<String> = []
    /// 本次见过的对话 id（多文件重复时第二次起不再计「跳过」）
    private var seenThisRun: Set<String> = []
    /// 本次已存过「导入前」快照的对话 id——一条对话只存一次，撤回才能回到真正的导入前
    private var snapshotted: Set<String> = []
    /// 本地原有对话的最终归类：同一条在多个文件里出现，只要有一次真改了就算「更新」，否则算「跳过」
    private var skippedIds: Set<String> = []
    private var updatedIds: Set<String> = []
    /// 写过任何撤回记录（created / updated）——撤回入口看它，不看计数
    private var wroteChange = false
    /// 开始前已有的对话，叠加模式才需要整表（原逻辑如此）
    private var localById: [String: Conversation] = [:]

    init(context: ModelContext, profileId: String, record: ImportRecord, merge: Bool, copyConflicts: Bool,
         warnings: ImportWarnings = ImportWarnings()) throws {
        self.context = context
        self.warnings = warnings
        self.profileId = profileId
        self.record = record
        self.merge = merge
        self.copyConflicts = copyConflicts
        let pid = profileId
        let local = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == pid }))
        localIds = Set(local.map(\.id))
        if merge { localById = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    /// 当前来源里已记成「跳过」的 id（同一文件重复出现只记一次，后来改判更新就撤掉）（sol #2）
    private var sourceSkipped: Set<String> = []

    func beginSource(_ label: String, kind: ImportManifest.Kind = .conversations) {
        sources.append(ImportManifest.Source(label: label, kind: kind))
        sourceSkipped = []
    }

    /// 记到当前文件名下；调用方没开过（测试直接调 importBatch）就记在一个没名字的来源里
    func note(_ body: (inout ImportManifest.Source) -> Void) {
        if sources.isEmpty { beginSource("") }
        body(&sources[sources.count - 1])
    }

    private func noteSkipped(_ payload: ImportedConversationPayload) {
        guard sourceSkipped.insert(payload.id).inserted else { return }
        note {
            $0.skippedCount += 1
            if $0.skipped.count < ImportManifest.listLimit { $0.skipped.append(.init(id: payload.id, title: payload.title)) }
        }
    }

    private func noteUpdated(_ id: String) {
        let wasSkipped = sourceSkipped.remove(id) != nil
        note {
            if wasSkipped {
                $0.skippedCount -= 1
                $0.skipped.removeAll { $0.id == id }
            }
            if !$0.updated.contains(id) { $0.updated.append(id) }
        }
    }

    /// 写一批。nil = 解析出来没有有效内容（计未导入）。
    /// offset：这批第一段在文件里是第几段（从 0 起），清单里空白段记「第 N 段」（sol #5）
    func importBatch(_ payloads: [ImportedConversationPayload?], offset: Int = 0) throws {
        let candidates = payloads.compactMap { $0 }.filter {
            merge || !localIds.contains($0.id) || createdThisRun.contains($0.id)
        }
        let conflicted = try crossProfileConflicts(payloads: candidates, currentProfileId: profileId, in: context)

        for (k, payload) in payloads.enumerated() {
            counts.processed += 1
            guard var incoming = payload else {
                counts.ignored += 1
                note {
                    $0.emptyCount += 1
                    if $0.empty.count < ImportManifest.listLimit { $0.empty.append("第 \(offset + k + 1) 段") }
                }
                continue
            }
            var isCopy = false

            if let hit = conflicted[incoming.id] {
                guard copyConflicts else {
                    counts.conflicts += 1
                    counts.conflictsByProfile[hit.profileId, default: 0] += 1
                    if hit.trashed { counts.conflictsTrashed += 1 }
                    let title = incoming.title, id = incoming.id, floor = floorNames[hit.profileId]
                    note {
                        $0.conflictCount += 1
                        if $0.conflicts.count < ImportManifest.listLimit {
                            $0.conflicts.append(.init(id: id, title: title, profileId: hit.profileId,
                                                      floorName: floor, trashed: hit.trashed))
                        }
                    }
                    continue
                }
                incoming = payloadAsCopy(incoming, profileId: profileId)
                isCopy = true
            }

            let seenBefore = !seenThisRun.insert(incoming.id).inserted
            if seenBefore {
                counts.mergedDuplicates += 1
                note { $0.mergedDuplicates += 1 }
            }
            if localIds.contains(incoming.id) {
                let createdInRun = createdThisRun.contains(incoming.id)
                guard merge || createdInRun else {
                    if !seenBefore {
                        markSkipped(incoming.id)
                        noteSkipped(incoming)
                    }
                    continue
                }
                try mergeExisting(incoming, createdInRun: createdInRun)
                continue
            }
            incoming = prepared(incoming)

            let conversation = makeImportedConversation(incoming, profileId: profileId)
            conversation.importBatchId = record.id
            conversation.folderId = incoming.folderId
            context.insert(conversation)
            for node in incoming.nodes {
                context.insert(makeImportedNode(node, conversationId: incoming.id, profileId: profileId))
            }
            context.insert(ImportConversationChange(
                recordId: record.id, conversationId: incoming.id, changeKind: .created, profileId: profileId))
            wroteChange = true

            localIds.insert(incoming.id)
            createdThisRun.insert(incoming.id)
            localById[incoming.id] = conversation
            if isCopy { counts.copied += 1 } else { counts.added += 1 }
            let id = incoming.id
            note { if isCopy { $0.copied.append(id) } else { $0.created.append(id) } }
            counts.nodes += incoming.nodes.count
        }

        writeRecordCounts()
        try context.save()
    }

    /// 附件字节 / 内联媒体转存进文件库（#050 E6）：只在真要写的时候做，跳过 / 冲突的对话不留孤儿文件
    private func prepared(_ payload: ImportedConversationPayload) -> ImportedConversationPayload {
        ImportAssetResolver.resolve(payload, profileId: profileId, warnings: warnings)
    }

    private func markSkipped(_ id: String) {
        guard !updatedIds.contains(id), skippedIds.insert(id).inserted else { return }
        counts.skipped += 1
    }

    private func markUpdated(_ id: String) {
        if skippedIds.remove(id) != nil { counts.skipped -= 1 }
        if updatedIds.insert(id).inserted { counts.updated += 1 }
    }

    /// - createdInRun: 本次前面文件刚建的（多文件重复）：不存快照（它已有 created，撤回整条删）；
    ///   这份比已导入的旧，就只补消息，不拿旧内容盖共同消息和标题（共同内容以新的为准）
    private func mergeExisting(_ incoming: ImportedConversationPayload, createdInRun: Bool) throws {
        let existing: Conversation
        if let known = localById[incoming.id] {
            existing = known
        } else {
            let id = incoming.id, pid = profileId
            guard let fetched = try context.fetch(FetchDescriptor<Conversation>(
                predicate: #Predicate { $0.id == id && $0.profileId == pid })).first
            else {
                markSkipped(incoming.id)
                noteSkipped(incoming)
                return
            }
            existing = fetched
        }
        let existingNodes = try fetchConversationNodes(conversationId: incoming.id, profileId: profileId, in: context)
        guard shouldMergeConversation(existing: existing, existingNodes: existingNodes, incoming: incoming) else {
            if !createdInRun {
                markSkipped(incoming.id)
                noteSkipped(incoming)
            }
            return
        }
        // 先判要不要合，再转存附件：不合的不往文件库写（sol #6）。转存后再判一次——
        // 附件占位换成文件库引用后可能跟本地已有的一模一样
        let incoming = prepared(incoming)
        guard shouldMergeConversation(existing: existing, existingNodes: existingNodes, incoming: incoming) else {
            if !createdInRun {
                markSkipped(incoming.id)
                noteSkipped(incoming)
            }
            return
        }
        let incomingIsOlder = createdInRun && incoming.updateTime < existing.updateTime

        if !createdInRun && !snapshotted.contains(incoming.id) {
            let snapshots = try encodeSnapshots(conversation: existing, nodes: existingNodes)
            context.insert(ImportConversationChange(
                recordId: record.id, conversationId: incoming.id, changeKind: .updated,
                beforeConversationData: snapshots.conversationData, beforeNodesData: snapshots.nodesData,
                profileId: profileId))
            snapshotted.insert(incoming.id)
            wroteChange = true
        }

        var merged = existingNodes
        var byId = Dictionary(existingNodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = 0
        for node in incoming.nodes {
            if let current = byId[node.id] {
                if incomingIsOlder {
                    current.childrenIds = mergedChildrenIds(incoming: node.childrenIds, existing: current.childrenIds)
                } else if applyImportedNode(node, to: current) {
                    changed += 1
                }
            } else {
                let fresh = makeImportedNode(node, conversationId: incoming.id, profileId: profileId)
                context.insert(fresh)
                merged.append(fresh)
                byId[node.id] = fresh
                changed += 1
            }
        }

        let mergedCount = countDisplayableOnPath(merged, leafId: incomingIsOlder ? existing.currentNodeId : incoming.currentNodeId)
        if !incomingIsOlder, importedConversationMetadataDiffers(from: existing, incoming: incoming) {
            applyImportedConversationMetadata(incoming, to: existing, nodeCount: mergedCount)
        } else {
            existing.nodeCount = mergedCount
        }

        if !createdInRun {
            markUpdated(incoming.id)
            noteUpdated(incoming.id)
        }
        counts.nodes += changed
    }

    /// 计数口径照旧：conversationCount = 新增 + 副本 + 更新；addedConversationCount 含副本。
    func writeRecordCounts() {
        record.conversationCount = counts.added + counts.copied + counts.updated
        record.nodeCount = counts.nodes
        record.addedConversationCount = counts.added + counts.copied
        record.updatedConversationCount = counts.updated
        record.skippedConversationCount = counts.skipped
        record.ignoredConversationCount = counts.ignored
        record.conflictConversationCount = counts.conflicts
        record.supportsUndo = record.supportsUndo || wroteChange
    }
}
