import Foundation

/// RikkaHub 一段对话 → `ImportedConversationPayload`（不写库）。附件段默认内联；导入时 `attachments` 传外置到文件库的函数。
///
/// 树形状同酒馆 swipes（`SwipeBranchBuilder`）：每个位置的候选是一组兄弟，挂在上一位置选中的候选下；
/// 只有选中候选接后续（RikkaHub 重新生成会截掉后面，research §5.1）；首组挂合成根。
/// id 带对话前缀：fork 出来的对话复用原消息 id（research §5.2）。
enum RikkaHubPayloadBuilder {
    static let provider = "rikkahub"

    /// 原 id 放前面：附件目录按对话 id 前 8 位分（`AttachmentStore.prefix8`），写成 `rikkahub:…` 会让
    /// 所有 RikkaHub 对话共用一个附件目录、硬删一段清掉全部
    static func conversationId(_ sourceId: String) -> String { "\(sourceId)@\(provider)" }

    /// 消息 id：`rikkahub:<原对话id>:<消息id>`
    static func nodeIdPrefix(_ sourceId: String) -> String { "\(provider):\(sourceId)" }

    static func build(row: RikkaHubConversationRow, positions: [RikkaHubPosition], assistantName: String?,
                      timeZone: TimeZone, resolver: RikkaHubAttachmentResolver,
                      attachments: (_ segments: [MessageSegment], _ conversationId: String, _ title: String) -> [MessageSegment]
                          = { segments, _, _ in segments },
                      warnings: inout RikkaHubWarnings) -> ImportedConversationPayload? {
        let convId = conversationId(row.id)
        let nodePrefix = nodeIdPrefix(row.id)
        let trimmedTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? "RikkaHub 对话" : trimmedTitle
        var usedIds = Set<String>()
        func nodeId(_ message: RikkaHubMessage, position: Int, candidate: Int) -> String {
            let base = message.id.map { "\(nodePrefix):\($0)" } ?? "\(nodePrefix):p\(position)-\(candidate)"
            var id = base
            var n = 2
            while !usedIds.insert(id).inserted {
                id = "\(base)#\(n)"
                n += 1
            }
            return id
        }

        // 位置 → (候选消息, 选中下标)；tool 角色位置并进上一个位置选中的消息
        var groups: [(ids: [String], messages: [RikkaHubMessage], selected: Int)] = []
        for (index, position) in positions.enumerated() {
            guard !position.messages.isEmpty else {
                warnings.emptyPositions += 1
                continue
            }
            var selected = position.selectIndex
            if !position.messages.indices.contains(selected) {
                warnings.clampedSelections += 1
                selected = min(max(selected, 0), position.messages.count - 1)
            }
            let messages = position.messages.map {
                RikkaHubMessageMapper.message($0, timeZone: timeZone, resolver: resolver, warnings: &warnings)
            }
            if messages[selected].role == "tool", let last = groups.indices.last {
                groups[last].messages[groups[last].selected].segments += messages[selected].segments
                continue
            }
            let ids = messages.enumerated().map { nodeId($1, position: index, candidate: $0) }
            groups.append((ids, messages, selected))
        }

        let rootId = "\(nodePrefix):root"
        let firstDate = groups.lazy.flatMap(\.messages).compactMap(\.createdAt).first
            ?? row.createAt.map(Self.date(epochMillis:)) ?? Date.distantPast
        var nodes: [ImportedNodePayload] = []
        var selection: [String: String] = [:]
        var parentId = rootId
        let encoder = JSONEncoder()
        for (index, group) in groups.enumerated() {
            let children = index + 1 < groups.count ? groups[index + 1].ids : []
            for (k, message) in group.messages.enumerated() {
                let isSelected = k == group.selected
                var node = ImportedNodePayload(
                    id: group.ids[k],
                    role: message.role,
                    content: ClaudeImporter.flattenSegmentsForSearch(message.segments),
                    contentType: "segmented",
                    createTime: message.createdAt,
                    parentId: parentId,
                    childrenIds: isSelected ? children : [],
                    segmentsData: try? encoder.encode(attachments(message.segments, convId, title))
                )
                node.sourceMetadata = message.sourceMetadata
                nodes.append(node)
            }
            if group.ids.count > 1 { selection[parentId] = group.ids[group.selected] }
            parentId = group.ids[group.selected]
        }

        guard countDisplayableNodes(nodes) > 0 else {
            warnings.emptyConversations += 1
            return nil
        }
        nodes.insert(ImportedNodePayload(id: rootId, role: "system", content: "", contentType: "text", createTime: firstDate,
                                         parentId: nil, childrenIds: groups.first?.ids ?? [], isSyntheticRoot: true), at: 0)

        let createTime = row.createAt.map(Self.date(epochMillis:)) ?? firstDate
        return ImportedConversationPayload(
            id: convId,
            title: title,
            createTime: createTime,
            updateTime: row.updateAt.map(Self.date(epochMillis:)) ?? createTime,
            currentNodeId: parentId,
            provider: provider,
            nodes: nodes,
            branchSelectionData: BranchSelection.encode(selection),
            sourceMetadata: conversationMetadata(row, assistantName: assistantName)
        )
    }

    static func date(epochMillis: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
    }

    /// 只存不激活：对话自带的系统提示词进来源信息，不进花园的提示词 / 文件夹说明
    private static func conversationMetadata(_ row: RikkaHubConversationRow, assistantName: String?) -> Data? {
        var info: [String: Any] = ["source": provider, "assistantId": row.assistantId, "pinned": row.isPinned]
        if let assistantName { info["assistantName"] = assistantName }
        if !row.folderId.isEmpty { info["folderId"] = row.folderId }
        if !row.customSystemPrompt.isEmpty { info["customSystemPrompt"] = row.customSystemPrompt }
        if !row.workspaceCwd.isEmpty { info["workspaceCwd"] = row.workspaceCwd }
        return try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
    }
}

/// settings.json 里只碰 `assistants[].id / name`（plan D1/D2）：别的键不解析、不返回、不落盘
enum RikkaHubSettingsPeek {
    /// 读进内存的上限（plan §3.2）
    static let maxBytes: UInt64 = 8 << 20

    /// nil = 不像 RikkaHub 的设置（没有 `assistants` 数组）
    static func assistantNames(fromSettingsJSON data: Data) -> [String: String]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let assistants = root["assistants"] as? [[String: Any]] else { return nil }
        var names: [String: String] = [:]
        for assistant in assistants {
            guard let id = assistant["id"] as? String,
                  let name = (assistant["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}
