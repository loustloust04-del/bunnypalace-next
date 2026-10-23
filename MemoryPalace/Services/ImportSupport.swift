import Foundation
import SwiftData

struct ImportedNodePayload {
    let id: String
    let role: String
    let content: String
    let contentType: String
    let createTime: Date?
    let parentId: String?
    let childrenIds: [String]
    /// Claude v2 导入：JSON 编码的 [MessageSegment]。非 Claude 或 fallback 场景为 nil。
    var segmentsData: Data? = nil
    var isSyntheticRoot: Bool = false
    /// 卡库 ⑧c：来源 / metadata JSON 与源可见性；ChatGPT / Claude 不给 = nil（不改它们的语义）
    var sourceMetadata: Data? = nil
    var sourceVisibility: String? = nil
}

struct ImportedConversationPayload {
    let id: String
    let title: String
    let createTime: Date
    let updateTime: Date
    let currentNodeId: String
    let provider: String
    let nodes: [ImportedNodePayload]
    /// 卡库 ③b 分支选择表；外部导出格式没有 = nil（加载时从 currentNodeId 路径重建）
    var branchSelectionData: Data? = nil
    /// 卡库 ⑧c：身份、归档类型、来源 metadata；外部导出格式没有 = nil
    var personaId: String? = nil
    var archiveKind: String? = nil
    var sourceMetadata: Data? = nil
    /// #043：新建时放进哪个文件夹（Claude 项目 → 花园文件夹）；已有对话不动它
    var folderId: String? = nil
    /// #050 E6：分段里 `.file(name, uuid)` 的 uuid → 包里的字节。写库引擎只对真写入的对话读，换成文件库里的图
    var pendingAssets: [String: ImportAssetRef] = [:]
    /// #050：分段里有内联的 `.image` / `.fileData`，写库时转存进文件库（只对真写入的对话做）
    var externalizeOnWrite = false
}

// MARK: - 跨楼层冲突防护（P0-1）
//
// SwiftData `@Attribute(.unique)` 在 insert 撞 id 时的行为是 **upsert**：把现有行的全部属性
// （包括 profileId）改写成新值——等于把别的楼层的同 id 数据整行"抢"过来，原楼层静默丢失。
// 导入/迁移的去重只查目标楼层，挡不住这种跨楼层改写。所以任何
// `context.insert(Conversation/MessageNode)` 之前必须先查"同 id 是否已存在于其它楼层"，
// 命中的对话整条跳过。分批 IN 查询（id 有 unique 索引，快），绝不全量 fetch。

private let crossProfileQueryBatchSize = 500

/// 返回 candidateIds 中已被**其它**楼层占用的 Conversation id 集合。
func findCrossProfileConversationConflicts(
    candidateIds: [String],
    currentProfileId: String,
    in context: ModelContext
) throws -> Set<String> {
    var conflicts = Set<String>()
    guard !candidateIds.isEmpty else { return conflicts }
    for start in stride(from: 0, to: candidateIds.count, by: crossProfileQueryBatchSize) {
        let chunk = Array(candidateIds[start..<min(start + crossProfileQueryBatchSize, candidateIds.count)])
        let pid = currentProfileId
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { chunk.contains($0.id) && $0.profileId != pid }
        )
        for hit in try context.fetch(descriptor) {
            conflicts.insert(hit.id)
        }
    }
    return conflicts
}

/// 返回 candidateIds 中已被**其它**楼层占用的 MessageNode id 集合。
/// （同 id 节点若已在当前楼层，merge 路径会走 update 不会 insert，所以只需查其它楼层。）
func findCrossProfileNodeConflicts(
    candidateIds: [String],
    currentProfileId: String,
    in context: ModelContext
) throws -> Set<String> {
    var conflicts = Set<String>()
    guard !candidateIds.isEmpty else { return conflicts }
    for start in stride(from: 0, to: candidateIds.count, by: crossProfileQueryBatchSize) {
        let chunk = Array(candidateIds[start..<min(start + crossProfileQueryBatchSize, candidateIds.count)])
        let pid = currentProfileId
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { chunk.contains($0.id) && $0.profileId != pid }
        )
        for hit in try context.fetch(descriptor) {
            conflicts.insert(hit.id)
        }
    }
    return conflicts
}

/// 撞上的那份在哪（#061）：楼层 id（可能是已删除的楼层）、在不在那边的回收站
struct CrossProfileConflictHit: Equatable {
    let profileId: String
    let trashed: Bool
}

/// 一个 batch 的 payload 里需要整条跳过的对话：自身 id 撞别的楼层，或任一节点 id 撞别的楼层。
/// 值是撞上的那份在哪；节点撞的取节点所在对话（对话查不到就当不在回收站）。
func crossProfileConflicts(
    payloads: [ImportedConversationPayload],
    currentProfileId: String,
    in context: ModelContext
) throws -> [String: CrossProfileConflictHit] {
    guard !payloads.isEmpty else { return [:] }
    var hits = try crossProfileConversationHits(payloads.map(\.id), currentProfileId: currentProfileId, in: context)
    let pending = payloads.filter { hits[$0.id] == nil }
    let nodeOwner = try crossProfileNodeOwners(pending.flatMap { $0.nodes.map(\.id) },
                                               currentProfileId: currentProfileId, in: context)
    guard !nodeOwner.isEmpty else { return hits }
    let owners = try crossProfileConversationHits(Array(Set(nodeOwner.values.map(\.conversationId))),
                                                  currentProfileId: currentProfileId, in: context)
    for payload in pending {
        guard let node = payload.nodes.lazy.compactMap({ nodeOwner[$0.id] }).first else { continue }
        hits[payload.id] = CrossProfileConflictHit(profileId: node.profileId,
                                                   trashed: owners[node.conversationId]?.trashed ?? false)
    }
    return hits
}

/// 对话 id → 别的楼层里那份在哪
func crossProfileConversationHits(
    _ ids: [String],
    currentProfileId: String,
    in context: ModelContext
) throws -> [String: CrossProfileConflictHit] {
    var out: [String: CrossProfileConflictHit] = [:]
    let pid = currentProfileId
    for start in stride(from: 0, to: ids.count, by: crossProfileQueryBatchSize) {
        let chunk = Array(ids[start..<min(start + crossProfileQueryBatchSize, ids.count)])
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { chunk.contains($0.id) && $0.profileId != pid })
        descriptor.propertiesToFetch = [\.id, \.profileId, \.isTrashed]
        for hit in try context.fetch(descriptor) {
            out[hit.id] = CrossProfileConflictHit(profileId: hit.profileId, trashed: hit.isTrashed)
        }
    }
    return out
}

private func crossProfileNodeOwners(
    _ ids: [String],
    currentProfileId: String,
    in context: ModelContext
) throws -> [String: (profileId: String, conversationId: String)] {
    var out: [String: (profileId: String, conversationId: String)] = [:]
    let pid = currentProfileId
    for start in stride(from: 0, to: ids.count, by: crossProfileQueryBatchSize) {
        let chunk = Array(ids[start..<min(start + crossProfileQueryBatchSize, ids.count)])
        var descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { chunk.contains($0.id) && $0.profileId != pid })
        descriptor.propertiesToFetch = [\.id, \.profileId, \.conversationId]
        for hit in try context.fetch(descriptor) {
            out[hit.id] = (hit.profileId, hit.conversationId)
        }
    }
    return out
}

/// 完成文案的冲突提示后缀（两个 importer 共用）。
func crossProfileConflictSuffix(_ count: Int) -> String {
    count > 0 ? "；⚠️ \(count) 条对话已存在于其他楼层，已跳过（同一对话只能存在于一个楼层）" : ""
}

// MARK: - 复制为副本（plan-import-as-copy）

/// 副本 id 确定性派生：同源同楼层永远得到同一个 id——同一份文件第二次复制导入时
/// 派生 id 已在本楼层 → 命中常规去重走"保持本地"（merge 模式走 update），副本不会翻倍。
/// 不同楼层前缀不同，不会撞别层。
func copyId(_ oldId: String, profileId: String) -> String {
    "\(oldId)#c-\(profileId.prefix(8))"
}

/// 把 payload 整条重映射为本楼层副本：对话 id、全部节点 id、parentId / childrenIds /
/// currentNodeId 按同一规则替换。映射表里没有的引用（Claude root sentinel 等悬空 parent）
/// 保留原值——树构建端按 id+profileId fetch 不到别层节点，等价于根，已验证容忍。
/// segmentsData 内部引用（toolUseId 等）是段内自洽 id，不需要动。
func payloadAsCopy(_ payload: ImportedConversationPayload, profileId: String) -> ImportedConversationPayload {
    let nodeIds = Set(payload.nodes.map(\.id))
    func mapped(_ id: String) -> String {
        nodeIds.contains(id) ? copyId(id, profileId: profileId) : id
    }
    let nodes = payload.nodes.map { node in
        ImportedNodePayload(
            id: copyId(node.id, profileId: profileId),
            role: node.role,
            content: node.content,
            contentType: node.contentType,
            createTime: node.createTime,
            parentId: node.parentId.map(mapped),
            childrenIds: node.childrenIds.map(mapped),
            segmentsData: node.segmentsData,
            isSyntheticRoot: node.isSyntheticRoot,
            sourceMetadata: node.sourceMetadata,
            sourceVisibility: node.sourceVisibility
        )
    }
    var copy = ImportedConversationPayload(
        id: copyId(payload.id, profileId: profileId),
        title: payload.title,
        createTime: payload.createTime,
        updateTime: payload.updateTime,
        currentNodeId: mapped(payload.currentNodeId),
        provider: payload.provider,
        nodes: nodes,
        branchSelectionData: BranchSelection.remap(payload.branchSelectionData) { nodeIds.contains($0) ? copyId($0, profileId: profileId) : nil },
        personaId: payload.personaId,
        archiveKind: payload.archiveKind,
        sourceMetadata: payload.sourceMetadata,
        folderId: payload.folderId
    )
    copy.pendingAssets = payload.pendingAssets
    copy.externalizeOnWrite = payload.externalizeOnWrite
    return copy
}

func fetchConversationNodes(conversationId: String, profileId: String, in context: ModelContext) throws -> [MessageNode] {
    let targetConvId = conversationId
    let targetProfileId = profileId
    let descriptor = FetchDescriptor<MessageNode>(
        predicate: #Predicate<MessageNode> {
            $0.conversationId == targetConvId && $0.profileId == targetProfileId
        }
    )
    return try context.fetch(descriptor)
}

func countDisplayableNodes(_ nodes: [ImportedNodePayload]) -> Int {
    nodes.reduce(into: 0) { count, node in
        if !node.isSyntheticRoot && !isHiddenSourceVisibility(node.sourceVisibility) && isDisplayableNode(role: node.role, content: node.content) {
            count += 1
        }
    }
}

/// 对话行 nodeCount 口径：只数当前分支路径（从末端沿 parentId 走到根），重新生成的旁支不算，和聊天页发消息时同口径。
/// 末端缺失 / 不在节点里 → 退回全部可计条数（老数据兜底）。
func countDisplayableOnPath<Node>(_ nodes: [Node], leafId: String?, id: (Node) -> String,
                                  parentId: (Node) -> String?, counts: (Node) -> Bool) -> Int {
    let byId = Dictionary(nodes.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
    guard let leafId, var node = byId[leafId] else { return nodes.filter(counts).count }
    var count = 0
    var seen: Set<String> = []
    while seen.insert(id(node)).inserted {
        if counts(node) { count += 1 }
        guard let pid = parentId(node), let parent = byId[pid] else { break }
        node = parent
    }
    return count
}

func countDisplayableOnPath(_ nodes: [ImportedNodePayload], leafId: String?) -> Int {
    countDisplayableOnPath(nodes, leafId: leafId, id: \.id, parentId: \.parentId) {
        !$0.isSyntheticRoot && !isHiddenSourceVisibility($0.sourceVisibility) && isDisplayableNode(role: $0.role, content: $0.content)
    }
}

func countDisplayableOnPath(_ nodes: [MessageNode], leafId: String?) -> Int {
    countDisplayableOnPath(nodes, leafId: leafId, id: \.id, parentId: \.parentId) {
        !$0.isSyntheticRoot && !$0.isSourceHidden && ($0.role == "user" || $0.role == "assistant") && $0.hasDisplayableContent
    }
}

func isHiddenSourceVisibility(_ value: String?) -> Bool {
    value == "hidden" || value == "uiSystem"
}

func isDisplayableNode(role: String, content: String) -> Bool {
    (role == "user" || role == "assistant") && !content.isEmpty
}

func mergedChildrenIds(incoming: [String], existing: [String]) -> [String] {
    var seen = Set<String>()
    var merged: [String] = []

    for childId in incoming + existing {
        if seen.insert(childId).inserted {
            merged.append(childId)
        }
    }

    return merged
}

func importedNodeDiffers(from existing: MessageNode, incoming: ImportedNodePayload) -> Bool {
    let existingChildren = Set(existing.childrenIds)
    let incomingChildren = Set(incoming.childrenIds)

    return existing.role != incoming.role ||
    existing.content != incoming.content ||
    existing.contentType != incoming.contentType ||
    existing.createTime != incoming.createTime ||
    existing.parentId != incoming.parentId ||
    !incomingChildren.isSubset(of: existingChildren) ||
    segmentsDiffer(existing.segmentsData, incoming.segmentsData) ||
    existing.isSyntheticRoot != incoming.isSyntheticRoot ||
    (incoming.sourceMetadata != nil && existing.sourceMetadata != incoming.sourceMetadata) ||
    (incoming.sourceVisibility != nil && existing.sourceVisibility != incoming.sourceVisibility)
}

/// 分段比内容不比字节：没排键的 JSONEncoder 同样的分段两次编出来字节可能不同（Dex3 #049 实测），
/// 老数据也是没排键编的——按字节比会把没改的对话当「改过」，白存一份撤回快照
func segmentsDiffer(_ a: Data?, _ b: Data?) -> Bool {
    guard a != b else { return false }
    guard let a, let b,
          let da = try? JSONDecoder().decode([MessageSegment].self, from: a),
          let db = try? JSONDecoder().decode([MessageSegment].self, from: b) else { return true }
    return da != db
}

func importedConversationMetadataDiffers(from existing: Conversation, incoming: ImportedConversationPayload) -> Bool {
    existing.title != incoming.title ||
    existing.createTime != incoming.createTime ||
    existing.updateTime != incoming.updateTime ||
    existing.currentNodeId != incoming.currentNodeId ||
    existing.provider != incoming.provider ||
    (incoming.branchSelectionData != nil && existing.branchSelectionData != incoming.branchSelectionData) ||
    (incoming.personaId != nil && existing.personaId != incoming.personaId) ||
    (incoming.archiveKind != nil && existing.archiveKind != incoming.archiveKind) ||
    (incoming.sourceMetadata != nil && existing.sourceMetadata != incoming.sourceMetadata)
}

func shouldMergeConversation(
    existing: Conversation,
    existingNodes: [MessageNode],
    incoming: ImportedConversationPayload
) -> Bool {
    let existingNodeMap = Dictionary(uniqueKeysWithValues: existingNodes.map { ($0.id, $0) })
    let existingNodeIds = Set(existingNodeMap.keys)
    let incomingNodeIds = Set(incoming.nodes.map(\.id))

    if !incomingNodeIds.isSubset(of: existingNodeIds) {
        return true
    }

    if importedConversationMetadataDiffers(from: existing, incoming: incoming),
       incoming.updateTime >= existing.updateTime {
        return true
    }

    for incomingNode in incoming.nodes {
        guard let existingNode = existingNodeMap[incomingNode.id] else { continue }
        if importedNodeDiffers(from: existingNode, incoming: incomingNode),
           incoming.updateTime >= existing.updateTime {
            return true
        }
    }

    return false
}

func applyImportedConversationMetadata(
    _ incoming: ImportedConversationPayload,
    to conversation: Conversation,
    nodeCount: Int
) {
    conversation.title = incoming.title
    conversation.createTime = incoming.createTime
    conversation.updateTime = incoming.updateTime
    // 选择表随 currentNodeId 走：带表就用表；不带表但换了末端 → 清掉本地表，加载时按新末端重建
    if incoming.branchSelectionData != nil || conversation.currentNodeId != incoming.currentNodeId {
        conversation.branchSelectionData = incoming.branchSelectionData
    }
    conversation.currentNodeId = incoming.currentNodeId
    conversation.provider = incoming.provider
    conversation.nodeCount = nodeCount
    // 缺键（ChatGPT / Claude）不清本地值
    if let personaId = incoming.personaId { conversation.personaId = personaId }
    if let archiveKind = incoming.archiveKind { conversation.archiveKind = archiveKind }
    if let sourceMetadata = incoming.sourceMetadata { conversation.sourceMetadata = sourceMetadata }
}

@discardableResult
func applyImportedNode(_ incoming: ImportedNodePayload, to node: MessageNode) -> Bool {
    let changed = importedNodeDiffers(from: node, incoming: incoming)

    node.role = incoming.role
    node.content = incoming.content
    node.contentType = incoming.contentType
    node.createTime = incoming.createTime
    node.parentId = incoming.parentId
    node.childrenIds = mergedChildrenIds(incoming: incoming.childrenIds, existing: node.childrenIds)
    node.segmentsData = incoming.segmentsData
    node.isSyntheticRoot = incoming.isSyntheticRoot
    if let sourceMetadata = incoming.sourceMetadata { node.sourceMetadata = sourceMetadata }
    if let sourceVisibility = incoming.sourceVisibility { node.sourceVisibility = sourceVisibility }

    return changed
}

func makeImportedNode(_ incoming: ImportedNodePayload, conversationId: String, profileId: String) -> MessageNode {
    let node = MessageNode(
        id: incoming.id,
        role: incoming.role,
        content: incoming.content,
        contentType: incoming.contentType,
        createTime: incoming.createTime,
        parentId: incoming.parentId,
        childrenIds: incoming.childrenIds,
        conversationId: conversationId,
        profileId: profileId
    )
    node.segmentsData = incoming.segmentsData
    node.isSyntheticRoot = incoming.isSyntheticRoot
    node.sourceMetadata = incoming.sourceMetadata
    node.sourceVisibility = incoming.sourceVisibility
    return node
}

/// 卡库 ⑧c：按导入 payload 新建 Conversation（只新增路径用；ChatGPT / Claude 导入器仍走各自原逻辑）
func makeImportedConversation(_ incoming: ImportedConversationPayload, profileId: String) -> Conversation {
    let conversation = Conversation(id: incoming.id, title: incoming.title, createTime: incoming.createTime,
                                    updateTime: incoming.updateTime, currentNodeId: incoming.currentNodeId,
                                    provider: incoming.provider, profileId: profileId)
    conversation.branchSelectionData = incoming.branchSelectionData
    conversation.personaId = incoming.personaId
    conversation.archiveKind = incoming.archiveKind
    conversation.sourceMetadata = incoming.sourceMetadata
    conversation.nodeCount = countDisplayableOnPath(incoming.nodes, leafId: incoming.currentNodeId)
    return conversation
}

func encodeSnapshots(
    conversation: Conversation,
    nodes: [MessageNode]
) throws -> (conversationData: Data, nodesData: Data) {
    let encoder = JSONEncoder()
    let conversationSnapshot = ConversationSnapshot(conversation: conversation)
    let nodeSnapshots = nodes.map(MessageNodeSnapshot.init(node:))
    let conversationData = try encoder.encode(conversationSnapshot)
    let nodesData = try encoder.encode(nodeSnapshots)
    return (conversationData, nodesData)
}

func decodeConversationSnapshot(from data: Data?) throws -> ConversationSnapshot? {
    guard let data else { return nil }
    return try JSONDecoder().decode(ConversationSnapshot.self, from: data)
}

func decodeNodeSnapshots(from data: Data?) throws -> [MessageNodeSnapshot] {
    guard let data else { return [] }
    return try JSONDecoder().decode([MessageNodeSnapshot].self, from: data)
}

func cleanupNodeArtifacts(
    in context: ModelContext,
    conversationId: String,
    profileId: String,
    removedNodeIds: Set<String>
) throws {
    guard !removedNodeIds.isEmpty else { return }

    let targetConvId = conversationId
    let targetProfileId = profileId
    let favoriteDescriptor = FetchDescriptor<FavoriteItem>(
        predicate: #Predicate<FavoriteItem> {
            $0.conversationId == targetConvId && $0.profileId == targetProfileId
        }
    )
    let favorites = try context.fetch(favoriteDescriptor)
    for favorite in favorites {
        if let nodeId = favorite.nodeId, removedNodeIds.contains(nodeId) {
            context.delete(favorite)
        }
    }

    let userCardDescriptor = FetchDescriptor<UserCard>(
        predicate: #Predicate<UserCard> { $0.profileId == targetProfileId }
    )
    let userCards = try context.fetch(userCardDescriptor)
    for card in userCards {
        if let nodeId = card.attachedToNodeId, removedNodeIds.contains(nodeId) {
            context.delete(card)
        }
    }
}

func deleteConversationArtifacts(
    conversationId: String,
    profileId: String,
    in context: ModelContext
) throws {
    let nodes = try fetchConversationNodes(conversationId: conversationId, profileId: profileId, in: context)
    let nodeIds = Set(nodes.map(\.id))

    try cleanupNodeArtifacts(in: context, conversationId: conversationId, profileId: profileId, removedNodeIds: nodeIds)

    for node in nodes {
        context.delete(node)
    }

    let targetConvId = conversationId
    let targetProfileId = profileId
    let favoriteDescriptor = FetchDescriptor<FavoriteItem>(
        predicate: #Predicate<FavoriteItem> {
            $0.conversationId == targetConvId && $0.profileId == targetProfileId
        }
    )
    let conversationFavorites = try context.fetch(favoriteDescriptor)
    for favorite in conversationFavorites {
        context.delete(favorite)
    }

    let conversationDescriptor = FetchDescriptor<Conversation>(
        predicate: #Predicate<Conversation> {
            $0.id == targetConvId && $0.profileId == targetProfileId
        }
    )
    if let conversation = try context.fetch(conversationDescriptor).first {
        context.delete(conversation)
    }
}

func restoreConversationChange(
    _ change: ImportConversationChange,
    in context: ModelContext
) throws {
    // change 自带 profileId（ImportConversationChange @Model 已加字段）
    let profileId = change.profileId
    // 不认识的种类（更新版本写的）不动——以前兜底成 .created 会把整段对话删掉（#057）
    guard let kind = ImportConversationChangeKind(rawValue: change.changeKindRaw) else { return }
    switch kind {
    case .backfilledImage:
        guard let data = change.beforeNodesData,
              let payload = try? JSONDecoder().decode(ImageBackfill.UndoPayload.self, from: data) else { return }
        try ImageBackfill.undo(payload, conversationId: change.conversationId, profileId: profileId, context: context)
    case .created:
        try deleteConversationArtifacts(conversationId: change.conversationId, profileId: profileId, in: context)
    case .createdMemory:
        // 已被删掉的找不到就算了；内容跟导入时不一样（园丁合并改写 / 你编辑过）就留着（撤回确认框里说了）
        guard let memoryId = UUID(uuidString: change.conversationId) else { return }
        let descriptor = FetchDescriptor<Memory>(predicate: #Predicate<Memory> {
            $0.id == memoryId && $0.profileId == profileId
        })
        let imported = change.beforeConversationData.map { String(decoding: $0, as: UTF8.self) }
        for memory in try context.fetch(descriptor) where imported == nil || memory.content == imported {
            context.delete(memory)
        }
    case .createdFolder:
        // 同侧栏删文件夹：里面的对话移回「全部」，挂在它上的气泡收藏一起清
        let tagId = change.conversationId
        let tagDescriptor = FetchDescriptor<ConversationTag>(predicate: #Predicate<ConversationTag> {
            $0.id == tagId && $0.profileId == profileId
        })
        for tag in try context.fetch(tagDescriptor) {
            context.delete(tag)
        }
        // folderId 是 optional，#Predicate 比 optional 会静默查不到 → 按楼层取再在内存里筛
        let memberDescriptor = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.profileId == profileId
        })
        for conversation in try context.fetch(memberDescriptor) where conversation.folderId == tagId {
            conversation.folderId = nil
        }
        let favoriteDescriptor = FetchDescriptor<FavoriteItem>(predicate: #Predicate<FavoriteItem> {
            $0.tagId == tagId && $0.profileId == profileId
        })
        for favorite in try context.fetch(favoriteDescriptor) {
            context.delete(favorite)
        }
    case .updated:
        guard let conversationSnapshot = try decodeConversationSnapshot(from: change.beforeConversationData) else {
            return
        }
        let nodeSnapshots = try decodeNodeSnapshots(from: change.beforeNodesData)
        let targetId = change.conversationId
        let targetProfileId = profileId

        let conversationDescriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> {
                $0.id == targetId && $0.profileId == targetProfileId
            }
        )
        let existingConversation = try context.fetch(conversationDescriptor).first
        let conversation = existingConversation ?? conversationSnapshot.makeConversation(profileId: profileId)
        if existingConversation == nil {
            context.insert(conversation)
        }
        conversationSnapshot.apply(to: conversation)

        let currentNodes = try fetchConversationNodes(conversationId: change.conversationId, profileId: profileId, in: context)
        let currentNodeMap = Dictionary(uniqueKeysWithValues: currentNodes.map { ($0.id, $0) })
        let snapshotNodeIds = Set(nodeSnapshots.map(\.id))
        let currentNodeIds = Set(currentNodes.map(\.id))
        let removedNodeIds = currentNodeIds.subtracting(snapshotNodeIds)

        try cleanupNodeArtifacts(in: context, conversationId: change.conversationId, profileId: profileId, removedNodeIds: removedNodeIds)

        for node in currentNodes where removedNodeIds.contains(node.id) {
            context.delete(node)
        }

        for snapshot in nodeSnapshots {
            if let existingNode = currentNodeMap[snapshot.id] {
                snapshot.apply(to: existingNode)
            } else {
                context.insert(snapshot.makeNode(profileId: profileId))
            }
        }
    }
}
