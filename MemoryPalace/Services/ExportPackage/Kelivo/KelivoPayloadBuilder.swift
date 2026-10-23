import Foundation

/// Kelivo 中间模型 → `ImportedConversationPayload`（#049）。
///
/// 重新生成（plan D2）：Kelivo 是「槽位序列」，同一槽位的各版本共享组键，会话记着每组选哪版。这里把**选中版本串成主干**
/// （上一槽位的选中版本 → 下一槽位所有版本的父），没选中的版本挂在同一个父下当兄弟分支（叶子）；`currentNodeId` = 最后一个槽位的
/// 选中版本。没选 / 选的版本不在 → 最大 version（并列取 order 大、id 大）。
/// 顶上总挂一个合成根（第一个槽位也可能有多个版本，不能各自当根，sol #5）；有分叉的位置写进分支选择表，
/// 叠加导入时换了选中版本也跟着换（sol #6）。
///
/// 附件：包里有的放 `.file(name, uuid: assetKey(成员路径))`，写库前由导入流程换成真图 / 文件；`data:` 图片直接解码内联；
/// 远端 URL / 缺失 / 导出时就不在的放带名字的占位（uuid 空）。
enum KelivoPayloadBuilder {
    static let assetKeyPrefix = "kelivo-asset:"
    static let maxInlineImageBytes = 20 * 1024 * 1024

    static func assetKey(_ member: String) -> String { assetKeyPrefix + member }

    struct Stats {
        var conversations = 0
        var regeneratedGroups = 0
        var packagedAttachments = 0
        var missingAttachments = 0
        var remoteAttachments = 0
        var hiddenParts = 0
        var unknownRoles = 0

        mutating func add(_ other: Stats) {
            conversations += other.conversations
            regeneratedGroups += other.regeneratedGroups
            packagedAttachments += other.packagedAttachments
            missingAttachments += other.missingAttachments
            remoteAttachments += other.remoteAttachments
            hiddenParts += other.hiddenParts
            unknownRoles += other.unknownRoles
        }

        var notes: [String] {
            var out: [String] = []
            if missingAttachments > 0 { out.append("\(missingAttachments) 个附件在备份里找不到（导出时没勾「文件」或文件已删），只放了带名字的占位") }
            if remoteAttachments > 0 { out.append("\(remoteAttachments) 张网络图片没下载，只放了带名字的占位") }
            if hiddenParts > 0 { out.append("\(hiddenParts) 段内容是 Kelivo 内部记录（工具轮次标记、授权失败等），已保留但不显示") }
            if unknownRoles > 0 { out.append("\(unknownRoles) 条消息角色不是你或 AI（如工具消息），已保留但不显示") }
            return out
        }
    }

    /// `members`：备份包里实际有的文件（`upload/…` 这类包内相对路径）。没有可显示内容的对话返回 nil
    static func payload(_ conv: KelivoBackup.Conversation, format: String, members: Set<String>,
                        stats: inout Stats) -> ImportedConversationPayload? {
        let conversationId = conv.id + "@kelivo"
        var groups: [String: [KelivoBackup.Revision]] = [:]
        var anchor: [String: Int] = [:]
        for r in conv.revisions {
            groups[r.groupKey, default: []].append(r)
            anchor[r.groupKey] = min(anchor[r.groupKey] ?? r.order, r.order)
        }
        let groupOrder = groups.keys.sorted { (anchor[$0]!, $0) < (anchor[$1]!, $1) }
        guard !groupOrder.isEmpty else { return nil }

        let rootId = "\(conversationId)#root"
        var nodes: [ImportedNodePayload] = []
        var selection: [String: String] = [:]
        var visibleCount = 0
        var parentId = rootId
        var current = ""
        var times: [Date] = []
        var firstUserText: String?
        for (g, key) in groupOrder.enumerated() {
            let versions = groups[key]!.sorted { ($0.version, $0.order, $0.id) < ($1.version, $1.order, $1.id) }
            if versions.count > 1 { stats.regeneratedGroups += 1 }
            let selected = conv.selections[key].flatMap { v in versions.last { $0.version == v } } ?? versions.last!
            let nextIds = g + 1 < groupOrder.count
                ? groups[groupOrder[g + 1]]!.sorted { ($0.version, $0.order, $0.id) < ($1.version, $1.order, $1.id) }
                    .map { "\(conversationId)/\($0.id)" }
                : []
            for r in versions {
                let nodeId = "\(conversationId)/\(r.id)"
                var hidden: [[String: String]] = []
                let segments = self.segments(r.parts, nodeId: nodeId, members: members, hidden: &hidden, stats: &stats)
                var visibility: String?
                if r.role != "user" && r.role != "assistant" {
                    visibility = "hidden"
                    stats.unknownRoles += 1
                } else if segments.isEmpty {
                    visibility = "hidden"
                } else {
                    visibleCount += 1
                }
                if r.role == "user", firstUserText == nil, case .text(let t)? = segments.first(where: { if case .text = $0 { return true }; return false }) {
                    firstUserText = t
                }
                if let time = r.time { times.append(time) }
                var meta = r.metadata
                meta["kelivo"] = ["id": r.id, "groupId": r.groupKey, "version": r.version, "order": r.order] as [String: Any]
                if !hidden.isEmpty { meta["hiddenParts"] = hidden }
                nodes.append(ImportedNodePayload(
                    id: nodeId, role: r.role, content: ClaudeImporter.flattenSegmentsForSearch(segments),
                    contentType: "segmented", createTime: r.time, parentId: parentId,
                    childrenIds: r.id == selected.id ? nextIds : [],
                    segmentsData: GeminiImportSupport.encodeSegments(segments),
                    sourceMetadata: KelivoBackup.jsonString(meta).data(using: .utf8),
                    sourceVisibility: visibility))
            }
            if versions.count > 1 { selection[parentId] = "\(conversationId)/\(selected.id)" }
            parentId = "\(conversationId)/\(selected.id)"
            current = parentId
        }
        guard visibleCount > 0 else { return nil }
        stats.conversations += 1

        let title = conv.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (firstUserText.map { GeminiImportSupport.titleSnippet($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Kelivo 对话")
            : conv.title
        let created = conv.createdAt ?? times.min() ?? .distantPast
        let firstIds = groups[groupOrder[0]]!.sorted { ($0.version, $0.order, $0.id) < ($1.version, $1.order, $1.id) }
            .map { "\(conversationId)/\($0.id)" }
        nodes.insert(ImportedNodePayload(id: rootId, role: "system", content: "", contentType: "text", createTime: created,
                                         parentId: nil, childrenIds: firstIds, isSyntheticRoot: true), at: 0)
        var meta = conv.metadata
        meta["source"] = "kelivo"
        meta["format"] = format
        meta["kelivoId"] = conv.id
        var payload = ImportedConversationPayload(
            id: conversationId, title: title, createTime: created, updateTime: conv.updatedAt ?? times.max() ?? created,
            currentNodeId: current, provider: KelivoBackup.provider, nodes: nodes)
        payload.sourceMetadata = KelivoBackup.jsonString(meta).data(using: .utf8)
        payload.branchSelectionData = BranchSelection.encode(selection)
        return payload
    }

    private static func segments(_ parts: [KelivoBackup.Part], nodeId: String, members: Set<String>,
                                 hidden: inout [[String: String]], stats: inout Stats) -> [MessageSegment] {
        var out: [MessageSegment] = []
        for (index, part) in parts.enumerated() {
            switch part {
            case .text(let text):
                guard !text.isEmpty else { continue }
                if case .text(let previous)? = out.last {
                    out[out.count - 1] = .text(previous + text)
                } else {
                    out.append(.text(text))
                }
            case .reasoning(let text):
                if !text.isEmpty { out.append(.thinking(text: text, signature: nil)) }
            case .tool(let id, let name, let arguments, let result):
                // 没 id 的用位置派生：再导一次要一模一样，叠加导入才不会误判「改过」
                let toolId = id.isEmpty ? "\(nodeId)#tool\(index)" : id
                out.append(.toolUse(id: toolId, name: name, inputJSON: arguments, integrationName: nil, iconName: nil))
                if let result { out.append(.toolResult(toolUseId: toolId, text: result, isError: false, integrationName: nil)) }
            case .image(let a):
                out.append(attachment(a, isImage: true, members: members, stats: &stats))
            case .file(let a):
                out.append(attachment(a, isImage: false, members: members, stats: &stats))
            case .hidden(let kind, let payload):
                hidden.append(["kind": kind, "payload": payload])
                stats.hiddenParts += 1
            }
        }
        return out
    }

    private static func attachment(_ a: KelivoBackup.Attachment, isImage: Bool, members: Set<String>,
                                   stats: inout Stats) -> MessageSegment {
        let fallbackName = a.name ?? lastComponent(a.uri) ?? (isImage ? "图片" : "文件")
        if !a.unavailable, let member = KelivoBackup.memberPath(for: a.uri), members.contains(member) {
            stats.packagedAttachments += 1
            return .file(name: a.name ?? (member as NSString).lastPathComponent, uuid: assetKey(member))
        }
        if a.uri.hasPrefix("data:"), let (mime, data) = decodeDataURI(a.uri), data.count <= maxInlineImageBytes,
           isImage || mime.hasPrefix("image/") {
            let ext = mime.split(separator: "/").last.map(String.init) ?? "png"
            return .image(name: a.name ?? "image.\(ext)", type: mime, data: data)
        }
        if let scheme = URL(string: a.uri)?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            stats.remoteAttachments += 1
        } else {
            stats.missingAttachments += 1
        }
        return .file(name: a.uri.hasPrefix("data:") ? (isImage ? "图片" : "文件") : fallbackName, uuid: "")
    }

    private static func lastComponent(_ uri: String) -> String? {
        guard !uri.hasPrefix("data:") else { return nil }
        let tail = uri.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        return tail.flatMap { $0.removingPercentEncoding ?? $0 }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `data:<mime>;base64,<…>`；先按长度估，超限不解
    private static func decodeDataURI(_ uri: String) -> (String, Data)? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let body = uri[uri.index(after: comma)...]
        guard body.utf8.count / 4 * 3 <= maxInlineImageBytes,
              let data = Data(base64Encoded: String(body), options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        let mime = header.dropLast(";base64".count)
        return (mime.isEmpty ? "application/octet-stream" : String(mime), data)
    }
}
