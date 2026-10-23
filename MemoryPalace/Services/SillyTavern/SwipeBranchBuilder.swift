import Foundation
import CryptoKit

/// 酒馆 swipes → 分支树（卡库 ⑧b，plan §6.1）：每条源消息一组兄弟候选（源序），`swipe_id` 选中的接后续；
/// 首组挂合成根（③a `isSyntheticRoot`）；输出 `ImportedConversationPayload` + ③b 选择表，纯值不写库。
/// 酒馆文件只有选中那条的后续历史，不给其它候选凭空复制后续。

struct SillyTavernNodeSource {
    let line: Int
    let candidateIndex: Int
    let candidateCount: Int
    let isSelected: Bool
    let visibility: SillyTavernMessageVisibility
    let name: String
    let sendDateRaw: String?
    /// 选中节点活动正文取 mes；mes 与源 swipe 不同时源 swipe 原文放这里（只这一处，不多算候选）
    let sourceSwipeText: String?
    let swipeInfo: Data?
    /// 以下只挂在选中节点：整行原件 + 核心键外字段原样（variables / hash_sheets / tableEditMatches …）
    let rawLine: Data?
    let preservedFields: [String: Data]
    /// 源 swipe_id 原值（越界时和实际选中不同）
    let sourceSwipeId: Int?
}

struct SillyTavernSwipeIssue: Equatable {
    enum Kind: Equatable {
        /// swipe_id 越界 / 缺：按 mes 匹配到 index，或匹配不到退回首候选（matched=nil）
        case swipeIdOutOfRange(sourceId: Int?, count: Int, matched: Int?)
    }

    let line: Int
    let kind: Kind
}

struct SillyTavernBuiltConversation {
    let payload: ImportedConversationPayload
    /// ③b 格式：父 id → 选中孩子 id（只记有多个孩子的分叉点）
    let selection: [String: String]
    let nodeSources: [String: SillyTavernNodeSource]
    let syntheticRootId: String?
    let issues: [SillyTavernSwipeIssue]

    let messageCount: Int
    /// 带 swipes 数组的消息（含只有 1 个候选的）
    let swipeGroupCount: Int
    /// swipes 多于 1 个的消息
    let multiCandidateCount: Int
    /// swipes 数组里的候选总数
    let candidateCount: Int
    /// swipe_id 有效但 mes 与选中 swipe 不同
    let mesDiffCount: Int

    /// 合成根另计
    var contentNodeCount: Int { payload.nodes.count - (syntheticRootId == nil ? 0 : 1) }
}

enum SwipeBranchBuilder {
    static let provider = "sillytavern"

    /// 源相对路径 → 稳定前缀；⑧c 预分配目标 ID 时整条重映射
    static func idPrefix(relativePath: String) -> String {
        let digest = SHA256.hash(data: Data(relativePath.utf8))
        return "st-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func build(_ chat: SillyTavernParsedChat, idPrefix: String, title: String, fallbackDate: Date) -> SillyTavernBuiltConversation {
        var nodes: [ImportedNodePayload] = []
        var sources: [String: SillyTavernNodeSource] = [:]
        var selection: [String: String] = [:]
        var issues: [SillyTavernSwipeIssue] = []
        var swipeGroups = 0, multi = 0, candidates = 0, mesDiff = 0

        let rootId = "\(idPrefix)-root"
        let firstDate = chat.messages.lazy.compactMap(\.sendDate).first ?? fallbackDate
        var parentId: String? = chat.messages.isEmpty ? nil : rootId
        // 先建各组，childrenIds 回填到上一组选中节点
        var groups: [(ids: [String], selected: Int)] = []
        var pending: [ImportedNodePayload] = []

        for message in chat.messages {
            let texts: [String]
            var selected = 0
            var sourceSwipeText: String?
            if let swipes = message.swipes, !swipes.isEmpty {
                swipeGroups += 1
                candidates += swipes.count
                if swipes.count > 1 { multi += 1 }
                texts = swipes
                if let id = message.swipeId, swipes.indices.contains(id) {
                    selected = id
                    if swipes[id] != message.mes { mesDiff += 1 }
                } else {
                    let matched = swipes.firstIndex(of: message.mes)
                    selected = matched ?? 0
                    issues.append(.init(line: message.line, kind: .swipeIdOutOfRange(sourceId: message.swipeId, count: swipes.count, matched: matched)))
                }
                if swipes[selected] != message.mes { sourceSwipeText = swipes[selected] }
            } else {
                texts = [message.mes]
            }

            let role = message.isUser ? "user" : "assistant"
            let ids = texts.indices.map { "\(idPrefix)-L\(message.line)-\($0)" }
            for (k, text) in texts.enumerated() {
                let isSelected = k == selected
                let info = message.swipeInfo.indices.contains(k) ? message.swipeInfo[k] : nil
                let infoDate = info.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? [String: Any] }
                    .flatMap { SillyTavernChatParser.parseDate($0["send_date"]) }
                pending.append(ImportedNodePayload(
                    id: ids[k],
                    role: role,
                    content: isSelected ? message.mes : text,
                    contentType: "text",
                    createTime: infoDate ?? message.sendDate ?? firstDate,
                    parentId: parentId,
                    childrenIds: []
                ))
                sources[ids[k]] = SillyTavernNodeSource(
                    line: message.line, candidateIndex: k, candidateCount: texts.count, isSelected: isSelected,
                    visibility: message.visibility, name: message.name, sendDateRaw: message.sendDateRaw,
                    sourceSwipeText: isSelected ? sourceSwipeText : nil, swipeInfo: info,
                    rawLine: isSelected ? message.rawLine : nil,
                    preservedFields: isSelected ? message.preservedFields : [:],
                    sourceSwipeId: message.swipeId
                )
            }
            if let parentId, texts.count > 1 { selection[parentId] = ids[selected] }
            groups.append((ids, selected))
            parentId = ids[selected]
        }

        // childrenIds：根 → 第一组；每组选中 → 下一组
        var children: [String: [String]] = [:]
        if let first = groups.first { children[rootId] = first.ids }
        for (index, group) in groups.enumerated() where index + 1 < groups.count {
            children[group.ids[group.selected]] = groups[index + 1].ids
        }
        if !groups.isEmpty {
            nodes.append(ImportedNodePayload(id: rootId, role: "system", content: "", contentType: "text",
                                             createTime: firstDate, parentId: nil, childrenIds: children[rootId] ?? [],
                                             isSyntheticRoot: true))
        }
        for node in pending {
            nodes.append(ImportedNodePayload(id: node.id, role: node.role, content: node.content, contentType: node.contentType,
                                             createTime: node.createTime, parentId: node.parentId,
                                             childrenIds: children[node.id] ?? []))
        }

        let lastDate = chat.messages.lazy.reversed().compactMap(\.sendDate).first ?? firstDate
        let payload = ImportedConversationPayload(
            id: idPrefix,
            title: title,
            createTime: firstDate,
            updateTime: lastDate,
            currentNodeId: groups.last.map { $0.ids[$0.selected] } ?? "",
            provider: provider,
            nodes: nodes,
            branchSelectionData: BranchSelection.encode(selection)
        )
        return SillyTavernBuiltConversation(
            payload: payload, selection: selection, nodeSources: sources,
            syntheticRootId: groups.isEmpty ? nil : rootId, issues: issues,
            messageCount: chat.messages.count, swipeGroupCount: swipeGroups, multiCandidateCount: multi,
            candidateCount: candidates, mesDiffCount: mesDiff
        )
    }
}
