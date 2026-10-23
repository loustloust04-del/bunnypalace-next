import Foundation
import CryptoKit

/// ChatGPT 对话 → 导入 payload（#050 E4 / E7）。
///
/// - 内容按 content_type 转成跟 Claude 导入同一套分段：思考、代码解释器（工具调用 / 结果）、联网搜索、图片占位…
/// - **节点一个不删、id 不变**（叠加再导一次就能把旧代码导进来的对话升级成新内容）：
///   只有思考 / 工具、没有正文的中间节点标成隐藏，它们的分段复制进后面那条有正文的回复，一轮回复还是一个气泡。
/// - 纯文本节点不写分段，正文跟旧代码一模一样（不然叠加再导会把每条都当「改过」）。
/// - 缺 id / 缺时间 / 断开的树按 E7 兜底，并记进注意事项。
struct ChatGPTPayloadBuilder {
    var assets = ChatGPTAssetIndex()
    var warnings: ImportWarnings?
    var importDate = Date()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    /// nil = 没有消息（计「未导入」）
    func payload(from raw: RawConversation) -> ImportedConversationPayload? {
        guard let mapping = raw.mapping, !mapping.isEmpty else { return nil }
        let id = conversationId(raw, mapping: mapping)
        var tree = Tree(mapping: mapping)
        if tree.repair(syntheticRootId: "\(id)#root") {
            warnings?.add("对话树断了或成环，已接回根下", raw.title)
        }

        // 每个节点的分段
        var built: [String: Built] = [:]
        var pending: [String: ImportAssetRef] = [:]
        var unresolvedGenerated: [String] = []
        for nodeId in tree.order {
            built[nodeId] = build(tree.messages[nodeId] ?? nil, pending: &pending, unresolvedGenerated: &unresolvedGenerated)
        }
        // Dall-E 分卷按对话目录对：这段对话只有一张没对上的生成图、分卷里也只有一个文件，才算同一张（sol #5）
        if unresolvedGenerated.count == 1, let sole = assets.soleGeneration(conversationId: id) {
            pending[unresolvedGenerated[0]] = sole
        } else {
            for _ in unresolvedGenerated { warnings?.add("生成的图片包里没有，放了占位") }
        }

        let (merged, absorbed) = fold(tree: tree, built: built)

        var times: [Date] = []
        let nodes: [ImportedNodePayload] = tree.order.map { nodeId in
            let message = tree.messages[nodeId] ?? nil
            let b = built[nodeId] ?? Built()
            let time = message?.create_time.map { Date(timeIntervalSince1970: $0) }
            if let time { times.append(time) }
            var content = ""
            var segmentsData: Data?
            var visibility: String?
            let segments = merged[nodeId] ?? b.segments
            if b.kind == .hidden || (absorbed.contains(nodeId) && merged[nodeId] == nil) {
                visibility = "hidden"
                segmentsData = segments.isEmpty ? nil : try? Self.encoder.encode(segments)
            } else if let plain = b.plainText, merged[nodeId] == nil {
                content = plain
            } else if !segments.isEmpty {
                content = ClaudeImporter.flattenSegmentsForSearch(segments)
                segmentsData = try? Self.encoder.encode(segments)
            }
            var node = ImportedNodePayload(
                id: nodeId,
                role: message?.author?.role ?? "unknown",
                content: content,
                contentType: message?.content?.content_type ?? "text",
                createTime: time,
                parentId: tree.parent[nodeId] ?? nil,
                childrenIds: tree.children[nodeId] ?? []
            )
            node.segmentsData = segmentsData
            node.sourceVisibility = visibility
            node.isSyntheticRoot = nodeId == tree.syntheticRootId
            return node
        }

        let created = raw.create_time.map { Date(timeIntervalSince1970: $0) } ?? times.min()
        let updated = raw.update_time.map { Date(timeIntervalSince1970: $0) } ?? times.max() ?? created
        if created == nil { warnings?.add("对话没有时间，按导入时间记", raw.title) }
        var currentNode = raw.current_node ?? ""
        if tree.messages[currentNode] == nil {
            currentNode = tree.latestLeaf() ?? ""
            warnings?.add("对话缺当前分支，取了最新的一支", raw.title)
        }

        var payload = ImportedConversationPayload(
            id: id,
            title: raw.title ?? "无标题",
            createTime: created ?? importDate,
            updateTime: updated ?? importDate,
            currentNodeId: currentNode,
            provider: "chatgpt",
            nodes: nodes
        )
        payload.pendingAssets = pending
        return payload
    }

    /// `id` → `conversation_id` → 用内容算一个稳定的（再导不重复）
    private func conversationId(_ raw: RawConversation, mapping: [String: RawNode]) -> String {
        if let id = raw.id, !id.isEmpty { return id }
        if let id = raw.conversation_id, !id.isEmpty { return id }
        warnings?.add("对话缺 id，按内容算了一个", raw.title)
        // 标题 + 时间 + 每个节点（按 id 排）的角色和正文：结构、内容都一样才算同一段（sol #11）
        var seed = [raw.title ?? "", raw.create_time.map { String($0) } ?? ""]
        for key in mapping.keys.sorted() {
            let message = mapping[key]?.message
            seed += [key, message?.author?.role ?? "", message?.content?.joinedParts ?? "", message?.content?.text ?? ""]
        }
        let digest = SHA256.hash(data: Data(seed.joined(separator: "\u{1F}").utf8))
        // 哈希在前：附件目录按对话 id 前 8 位分，固定前缀会让这些对话挤进同一个目录
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined() + "@chatgpt"
    }

    // MARK: - 单条消息

    struct Built {
        enum Kind { case empty, display, internalOnly, hidden }
        var kind: Kind = .empty
        var segments: [MessageSegment] = []
        /// 只有纯文本时：跟旧代码一样的正文（parts 用 \n 连），不写分段
        var plainText: String?
    }

    private func build(_ message: RawMessage?, pending: inout [String: ImportAssetRef],
                       unresolvedGenerated: inout [String]) -> Built {
        guard let message, let content = message.content else { return Built() }
        let role = message.author?.role ?? "unknown"
        let type = content.content_type ?? "text"
        let meta = message.metadataObject
        let attachments = meta.attachments

        if role == "system" || meta.isHidden || type == "user_editable_context" {
            let text = type == "user_editable_context"
                ? [content.user_profile, content.user_instructions].compactMap { $0 }.joined(separator: "\n\n")
                : content.joinedParts
            return Built(kind: .hidden, segments: text.isEmpty ? [] : [.text(text)])
        }

        // 助手发给工具的（代码解释器、搜索、记忆…）：工具调用
        if role == "assistant", let recipient = message.recipient, recipient != "all" {
            let body = content.text ?? content.joinedParts
            let key = type == "code" ? "code" : "input"
            let json = (try? JSONSerialization.data(withJSONObject: [key: body], options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return Built(kind: .internalOnly, segments: [.toolUse(id: message.id ?? "", name: recipient, inputJSON: json,
                                                                  integrationName: nil, iconName: nil)])
        }

        var segs: [MessageSegment] = []
        var usedAttachmentIds: Set<String> = []
        switch type {
        case "text":
            let text = content.joinedParts
            if role == "assistant", message.channel == "analysis" {
                if !text.isEmpty { segs.append(.thinking(text: text, signature: nil)) }
            } else if role == "tool" {
                if !text.isEmpty { segs.append(.toolResult(toolUseId: "", text: text, isError: false, integrationName: message.author?.name)) }
            } else if role == "user", !attachments.isEmpty {
                if !text.isEmpty { segs.append(.text(text)) }
            } else if text.isEmpty {
                return Built(kind: role == "assistant" ? .internalOnly : .empty)
            } else {
                return Built(kind: .display, segments: [.text(text)], plainText: text)
            }
        case "multimodal_text":
            for part in content.parts ?? [] {
                switch part {
                case .string(let s):
                    if !s.isEmpty { segs.append(.text(s)) }
                case .object(let obj):
                    let partType = obj["content_type"]?.value as? String
                    if partType == "image_asset_pointer", let pointer = obj["asset_pointer"]?.value as? String {
                        let fileId = Self.fileId(pointer)
                        usedAttachmentIds.insert(fileId)
                        segs.append(asset(id: fileId, attachments: attachments, generated: role != "user",
                                          pending: &pending, unresolvedGenerated: &unresolvedGenerated))
                    } else if let text = obj["text"]?.value as? String, !text.isEmpty {
                        segs.append(.text(text))
                    }
                }
            }
        case "image_asset_pointer":
            // 内容本身就是一张图（不在 multimodal_text 里）（sol #2）
            if let pointer = content.asset_pointer {
                let fileId = Self.fileId(pointer)
                usedAttachmentIds.insert(fileId)
                segs.append(asset(id: fileId, attachments: attachments, generated: role != "user",
                                  pending: &pending, unresolvedGenerated: &unresolvedGenerated))
            }
        case "code":
            let lang = content.language.map { $0 == "unknown" ? "" : $0 } ?? ""
            if let text = content.text, !text.isEmpty { segs.append(.text("```\(lang)\n\(text)\n```")) }
        case "execution_output", "computer_output":
            segs.append(.toolResult(toolUseId: "", text: content.text ?? "", isError: false, integrationName: message.author?.name))
        case "tether_browsing_display":
            segs.append(.toolResult(toolUseId: "", text: content.result ?? content.summary ?? "", isError: false,
                                    integrationName: message.author?.name))
        case "tether_quote":
            let text = [content.title, content.url, content.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            segs.append(.toolResult(toolUseId: "", text: text, isError: false, integrationName: message.author?.name))
        case "thoughts":
            for t in content.thoughts ?? [] {
                let text = [t.summary, t.content].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !text.isEmpty { segs.append(.thinking(text: text, signature: nil)) }
            }
        case "reasoning_recap":
            break
        case "system_error":
            segs.append(.toolResult(toolUseId: "", text: content.text ?? content.joinedParts, isError: true,
                                    integrationName: message.author?.name))
        default:
            let text = content.text ?? content.joinedParts
            if !text.isEmpty {
                segs.append(role == "tool"
                    ? .toolResult(toolUseId: "", text: text, isError: false, integrationName: message.author?.name)
                    : .text(text))
            }
        }

        // 上传的文件（图片已经在正文里的不重复）
        if role == "user" {
            for att in attachments where !usedAttachmentIds.contains(att.id) {
                segs.append(asset(id: att.id, attachments: attachments, generated: false,
                                  pending: &pending, unresolvedGenerated: &unresolvedGenerated))
            }
        }

        if role == "tool" {
            segs = segs.map { seg -> MessageSegment in
                if case .text(let s) = seg { return .toolResult(toolUseId: "", text: s, isError: false, integrationName: message.author?.name) }
                return seg
            }
        }
        guard !segs.isEmpty else { return Built(kind: role == "tool" || role == "assistant" ? .internalOnly : .empty) }
        let shown = segs.contains {
            switch $0 {
            case .text, .file, .image, .imageRef, .fileData, .fileDataRef: return true
            default: return false
            }
        }
        return Built(kind: shown && role != "tool" ? .display : .internalOnly, segments: segs)
    }

    /// 图片 / 文件占位。包里有字节就记进 pending，写库时换成真图；生成图按 id 没对上的整段对话算完再按目录对
    private func asset(id: String, attachments: [RawMetadata.Attachment], generated: Bool,
                       pending: inout [String: ImportAssetRef], unresolvedGenerated: inout [String]) -> MessageSegment {
        let att = attachments.first { $0.id == id }
        let name = att?.name ?? (generated ? "生成的图片" : "图片")
        if let ref = assets.lookup(id: id, name: att?.name, size: att?.size) {
            pending[id] = ref
        } else if generated {
            if !unresolvedGenerated.contains(id) { unresolvedGenerated.append(id) }
        } else {
            warnings?.add("上传的图片 / 文件包里没有，放了占位")
        }
        return .file(name: name, uuid: id)
    }

    /// 中间节点（只有思考 / 工具、没有正文）并进一个气泡（sol #3 #4）：
    /// ① 后面接着有正文的**助手**回复 → 并进那条回复（用户节点从不当落点）；
    /// ② 没有这样的回复（被用户打断、停在工具结果）→ 落在这串里最下面的助手节点上，单独一个气泡。
    /// 返回：落点 → 合并后的分段；被并走的节点（标隐藏）
    private func fold(tree: Tree, built: [String: Built]) -> ([String: [MessageSegment]], Set<String>) {
        func isInternal(_ id: String) -> Bool { built[id]?.kind == .internalOnly }
        func role(_ id: String) -> String? { (tree.messages[id] ?? nil)?.author?.role }
        var merged: [String: [MessageSegment]] = [:]
        var absorbed: Set<String> = []

        for nodeId in tree.order where built[nodeId]?.kind == .display && role(nodeId) == "assistant" {
            var chain: [String] = []
            var cursor = tree.parent[nodeId] ?? nil
            while let p = cursor, isInternal(p) {
                chain.append(p)
                cursor = tree.parent[p] ?? nil
            }
            guard !chain.isEmpty else { continue }
            absorbed.formUnion(chain)
            merged[nodeId] = chain.reversed().flatMap { built[$0]?.segments ?? [] } + (built[nodeId]?.segments ?? [])
        }

        for nodeId in tree.order where isInternal(nodeId) && !absorbed.contains(nodeId)
            && !(tree.children[nodeId] ?? []).contains(where: { isInternal($0) && !absorbed.contains($0) }) {
            var chain = [nodeId]
            var cursor = tree.parent[nodeId] ?? nil
            while let p = cursor, isInternal(p), !absorbed.contains(p) {
                chain.append(p)
                cursor = tree.parent[p] ?? nil
            }
            absorbed.formUnion(chain)
            guard let landing = chain.first(where: { role($0) == "assistant" }) else { continue }
            absorbed.remove(landing)
            merged[landing] = chain.reversed().flatMap { built[$0]?.segments ?? [] }
        }
        return (merged, absorbed)
    }

    /// `file-service://file-abc` / `sediment://file_00ab` → `file-abc` / `file_00ab`
    static func fileId(_ pointer: String) -> String {
        guard let r = pointer.range(of: "://") else { return pointer }
        return String(pointer[r.upperBound...])
    }

    // MARK: - 树

    struct Tree {
        var messages: [String: RawMessage?] = [:]
        var parent: [String: String?] = [:]
        var children: [String: [String]] = [:]
        /// 稳定顺序：按 id
        var order: [String] = []
        var syntheticRootId: String?

        init(mapping: [String: RawNode]) {
            for (id, node) in mapping {
                messages[id] = node.message
                parent[id] = node.parent
                children[id] = node.children ?? []
            }
            order = mapping.keys.sorted()
        }

        /// 去掉指向不存在节点的边、断环、多个根时加一个合成根。返回是否动过结构
        mutating func repair(syntheticRootId: String) -> Bool {
            var changed = false
            for id in order {
                if let p = parent[id] ?? nil, messages[p] == nil {
                    parent[id] = .some(nil)
                    changed = true
                }
            }
            // 断环：沿父链往上走，回到这条链上走过的点就把当前点和父亲断开
            var settled: Set<String> = []
            for start in order where !settled.contains(start) {
                var path: [String] = []
                var onPath: Set<String> = []
                var cursor: String? = start
                while let c = cursor, !settled.contains(c) {
                    if onPath.contains(c) {
                        let last = path[path.count - 1]
                        parent[last] = .some(nil)
                        changed = true
                        break
                    }
                    path.append(c)
                    onPath.insert(c)
                    cursor = parent[c] ?? nil
                }
                settled.formUnion(path)
            }
            // children 以子节点的 parent 为准：去掉不认这个爹的，补上漏列的（保留原顺序）
            var claimed: [String: [String]] = [:]
            for id in order { if let p = parent[id] ?? nil { claimed[p, default: []].append(id) } }
            for id in order {
                let real = Set(claimed[id] ?? [])
                let listed = (children[id] ?? []).filter { real.contains($0) }
                let missing = (claimed[id] ?? []).filter { !listed.contains($0) }
                let fixed = Self.unique(listed + missing)
                if fixed != children[id] ?? [] {
                    children[id] = fixed
                    changed = true
                }
            }
            let roots = order.filter { (parent[$0] ?? nil) == nil }
            if roots.count > 1 {
                let rootId = syntheticRootId
                for r in roots { parent[r] = .some(rootId) }
                messages[rootId] = .some(nil)
                parent[rootId] = .some(nil)
                children[rootId] = roots
                order.insert(rootId, at: 0)
                self.syntheticRootId = rootId
                changed = true
            }
            return changed
        }

        /// 没有当前节点时：创建时间最晚的叶子
        func latestLeaf() -> String? {
            order.filter { (children[$0] ?? []).isEmpty && messages[$0] != nil }
                .max { ((messages[$0] ?? nil)?.create_time ?? 0, $0) < ((messages[$1] ?? nil)?.create_time ?? 0, $1) }
        }

        private static func unique(_ xs: [String]) -> [String] {
            var seen = Set<String>()
            return xs.filter { seen.insert($0).inserted }
        }
    }
}
