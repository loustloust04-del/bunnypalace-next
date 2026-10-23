import Foundation
import SwiftData

// MARK: - Export Path Mode

enum ExportPathMode: String {
    case longest    // Auto-pick longest branch (lightweight default)
    case current    // Currently displayed path
    case mainPath   // Main path (currentNodeId → root)
    case fullTree   // All branches, non-longest wrapped in <details>
}

// MARK: - Markdown Exporter

enum MarkdownExporter {

    // MARK: - Single Export (ViewModel has data loaded)

    /// Export using pre-loaded conversation data from ViewModel
    static func export(
        nodeMap: [String: MessageNode],
        effectiveChildren: [String: [String]],
        rootId: String,
        mainPathIds: Set<String>,
        currentPath: [MessageNode],
        mode: ExportPathMode,
        userName: String,
        assistantName: String
    ) -> String {
        let nodes: [MessageNode]

        switch mode {
        case .longest:
            nodes = longestPath(from: rootId, nodeMap: nodeMap, effectiveChildren: effectiveChildren)
        case .current:
            nodes = currentPath
        case .mainPath:
            nodes = buildMainPath(from: rootId, nodeMap: nodeMap, effectiveChildren: effectiveChildren, mainPathIds: mainPathIds)
        case .fullTree:
            let lines = formatFullTree(
                from: rootId,
                nodeMap: nodeMap,
                effectiveChildren: effectiveChildren,
                userName: userName,
                assistantName: assistantName
            )
            return lines.joined(separator: "\n")
        }

        return formatPath(nodes, userName: userName, assistantName: assistantName)
            .joined(separator: "\n")
    }

    // MARK: - Batch Export (loads nodes from context)

    /// Export a single conversation by loading its nodes from ModelContext
    static func loadAndExport(
        conversation: Conversation,
        context: ModelContext,
        mode: ExportPathMode,
        userName: String,
        assistantName: String
    ) -> String {
        let convId = conversation.id
        let convProfileId = conversation.profileId

        // Fetch all nodes for this conversation
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in
                node.conversationId == convId && node.profileId == convProfileId
            }
        )
        guard let allNodes = try? context.fetch(descriptor) else { return "" }

        var nodeMap: [String: MessageNode] = [:]
        nodeMap.reserveCapacity(allNodes.count)
        for node in allNodes {
            nodeMap[node.id] = node
        }

        // Chase missing ancestors
        chaseMissingAncestors(nodeMap: &nodeMap, profileId: convProfileId, context: context)

        // Build effective children map
        let effectiveChildren = buildEffectiveChildrenMap(nodeMap: nodeMap)

        // Find root（确定性，与 ViewModel.findRootId 同款——dict 迭代序选 root 是"抽盲盒"bug 源）
        guard let rootId = deterministicRootId(nodeMap: nodeMap) else { return "" }

        // Build main path IDs
        var mainPathIds = Set<String>()
        var traceId: String? = conversation.currentNodeId
        while let nid = traceId, let node = nodeMap[nid] {
            mainPathIds.insert(nid)
            traceId = node.parentId
        }

        // For batch, current path = main path (conversation may not be displayed)
        let mainPath = buildMainPath(from: rootId, nodeMap: nodeMap, effectiveChildren: effectiveChildren, mainPathIds: mainPathIds)

        // Use longest for lightweight, or the requested mode
        let effectiveMode = mode == .current ? .mainPath : mode

        return export(
            nodeMap: nodeMap,
            effectiveChildren: effectiveChildren,
            rootId: rootId,
            mainPathIds: mainPathIds,
            currentPath: mainPath,
            mode: effectiveMode,
            userName: userName,
            assistantName: assistantName
        )
    }

    // MARK: - Root Selection

    /// 确定性 root：按 id 字典序选 parentId==nil（或 parent 不在 map）的最小者
    static func deterministicRootId(nodeMap: [String: MessageNode]) -> String? {
        let candidates = nodeMap.values.filter { $0.parentId == nil || nodeMap[$0.parentId ?? ""] == nil }
        return candidates.map(\.id).min()
    }

    // MARK: - Longest Path

    /// Find the longest path through the tree by always picking the deepest subtree
    private static func longestPath(
        from rootId: String,
        nodeMap: [String: MessageNode],
        effectiveChildren: [String: [String]]
    ) -> [MessageNode] {
        // Compute subtree depth iteratively (post-order) to avoid stack overflow
        var depthCache: [String: Int] = [:]
        var stack: [(nodeId: String, childIndex: Int)] = []

        for startId in nodeMap.keys where depthCache[startId] == nil {
            stack.append((startId, 0))
            while !stack.isEmpty {
                let (nid, ci) = stack.last!
                let children = effectiveChildren[nid] ?? []
                if ci < children.count {
                    stack[stack.count - 1].childIndex = ci + 1
                    let childId = children[ci]
                    if depthCache[childId] == nil {
                        stack.append((childId, 0))
                    }
                } else {
                    stack.removeLast()
                    let d = children.isEmpty ? 0 : (children.compactMap { depthCache[$0] }.max() ?? 0) + 1
                    depthCache[nid] = d
                }
            }
        }

        // Walk from root, always picking child with max depth
        var path: [MessageNode] = []
        var currentId: String? = rootId
        var visited = Set<String>()

        while let nid = currentId, let node = nodeMap[nid], !visited.contains(nid) {
            visited.insert(nid)

            if isDisplayable(node) {
                path.append(node)
            }

            let children = effectiveChildren[nid] ?? []
            if children.isEmpty {
                break
            } else if children.count == 1 {
                currentId = children[0]
            } else {
                currentId = children.max(by: { (depthCache[$0] ?? 0) < (depthCache[$1] ?? 0) })
            }
        }

        return path
    }

    // MARK: - Main Path

    /// Build path following mainPathIds at branch points
    private static func buildMainPath(
        from rootId: String,
        nodeMap: [String: MessageNode],
        effectiveChildren: [String: [String]],
        mainPathIds: Set<String>
    ) -> [MessageNode] {
        var path: [MessageNode] = []
        var currentId: String? = rootId
        var visited = Set<String>()

        while let nid = currentId, let node = nodeMap[nid], !visited.contains(nid) {
            visited.insert(nid)

            if isDisplayable(node) {
                path.append(node)
            }

            let children = effectiveChildren[nid] ?? []
            if children.isEmpty {
                break
            } else if children.count == 1 {
                currentId = children[0]
            } else {
                currentId = children.first(where: { mainPathIds.contains($0) }) ?? children[0]
            }
        }

        return path
    }

    // MARK: - Full Tree (with <details> folding)

    /// DFS the entire tree, outputting longest branch inline and others in <details>
    private static func formatFullTree(
        from rootId: String,
        nodeMap: [String: MessageNode],
        effectiveChildren: [String: [String]],
        userName: String,
        assistantName: String
    ) -> [String] {
        // Precompute subtree depths iteratively（对话是线性深链，递归会爆栈——longestPath 同款范本）
        var depthCache: [String: Int] = [:]
        var depthStack: [(nodeId: String, childIndex: Int)] = []
        for startId in nodeMap.keys where depthCache[startId] == nil {
            depthStack.append((startId, 0))
            while !depthStack.isEmpty {
                let (nid, ci) = depthStack.last!
                let children = effectiveChildren[nid] ?? []
                if ci < children.count {
                    depthStack[depthStack.count - 1].childIndex = ci + 1
                    let childId = children[ci]
                    if depthCache[childId] == nil {
                        depthStack.append((childId, 0))
                    }
                } else {
                    depthStack.removeLast()
                    let d = children.isEmpty ? 0 : (children.compactMap { depthCache[$0] }.max() ?? 0) + 1
                    depthCache[nid] = d
                }
            }
        }

        // 迭代 DFS（显式 work stack 替代递归 walk）：visit 展开节点，emit 输出结构行。
        // 原递归版分支处的 visited 快照+merge 是顺序处理，与共享单一集合等价。
        enum TreeWork {
            case visit(String)
            case emit(String)
        }

        var lines: [String] = []
        var visited = Set<String>()
        var work: [TreeWork] = [.visit(rootId)]

        while let item = work.popLast() {
            switch item {
            case .emit(let line):
                lines.append(line)

            case .visit(let nodeId):
                guard let node = nodeMap[nodeId], !visited.contains(nodeId) else { continue }
                visited.insert(nodeId)

                if isDisplayable(node) {
                    let name = node.role == "user" ? userName : assistantName
                    let time = formatTime(node.createTime)
                    lines.append("# \(name) · \(time)")
                    lines.append("")
                    let cleaned = ContentCleaner.clean(node.content, cacheKey: nil)
                    lines.append(shiftHeadings(cleaned))
                    lines.append("")
                }

                let children = effectiveChildren[nodeId] ?? []
                if children.count <= 1 {
                    if let child = children.first {
                        work.append(.visit(child))
                    }
                } else {
                    // 同深分支按 id tie-break——连续导出字节级一致（root 确定性的同族要求）
                    let sorted = children.sorted {
                        let d0 = depthCache[$0] ?? 0, d1 = depthCache[$1] ?? 0
                        return d0 != d1 ? d0 > d1 : $0 < $1
                    }
                    let otherChildren = Array(sorted.dropFirst())

                    var ops: [TreeWork] = [.visit(sorted[0])]
                    if !otherChildren.isEmpty {
                        ops.append(.emit("<details>"))
                        let count = otherChildren.count
                        ops.append(.emit("<summary>\(count == 1 ? "另外 1 条分支" : "另外 \(count) 条分支")</summary>"))
                        ops.append(.emit(""))
                        for (i, childId) in otherChildren.enumerated() {
                            ops.append(.visit(childId))
                            if i < otherChildren.count - 1 {
                                ops.append(.emit("---"))
                                ops.append(.emit(""))
                            }
                        }
                        ops.append(.emit("</details>"))
                        ops.append(.emit(""))
                    }
                    for op in ops.reversed() {
                        work.append(op)
                    }
                }
            }
        }
        return lines
    }

    // MARK: - Formatting Helpers

    /// Format a linear path of nodes into markdown lines
    private static func formatPath(_ path: [MessageNode], userName: String, assistantName: String) -> [String] {
        var lines: [String] = []
        for node in path {
            let name = node.role == "user" ? userName : assistantName
            let time = formatTime(node.createTime)
            lines.append("# \(name) · \(time)")
            lines.append("")
            let cleaned = ContentCleaner.clean(node.content, cacheKey: nil)
            lines.append(shiftHeadings(cleaned))
            lines.append("")
        }
        return lines
    }

    /// Shift all markdown headings down one level (# → ##, ## → ###, etc.)
    private static func shiftHeadings(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let s = String(line)
                if s.hasPrefix("#") {
                    return "#" + s
                }
                return s
            }
            .joined(separator: "\n")
    }

    /// Format timestamp as "2026-0224-09:40"
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MMdd-HH:mm"
        return formatter
    }()

    private static func formatTime(_ date: Date?) -> String {
        guard let date else { return "" }
        return timeFormatter.string(from: date)
    }

    /// Check if a node should be included in export
    private static func isDisplayable(_ node: MessageNode) -> Bool {
        (node.role == "user" || node.role == "assistant") && !node.content.isEmpty && !node.isTrashed
    }

    // MARK: - Node Loading Helpers (for batch export)

    /// Chase missing ancestor nodes — query only the specific missing IDs
    private static func chaseMissingAncestors(nodeMap: inout [String: MessageNode], profileId: String, context: ModelContext) {
        var missingIds = Set<String>()
        for node in nodeMap.values {
            if let pid = node.parentId, !pid.isEmpty, nodeMap[pid] == nil {
                missingIds.insert(pid)
            }
        }

        guard !missingIds.isEmpty else { return }

        var toChase = missingIds
        let targetProfileId = profileId
        while !toChase.isEmpty {
            var nextChase = Set<String>()
            for mid in toChase {
                let targetId = mid
                let desc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { node in node.id == targetId && node.profileId == targetProfileId }
                )
                if let found = try? context.fetch(desc).first {
                    nodeMap[found.id] = found
                    if let pid = found.parentId, !pid.isEmpty, nodeMap[pid] == nil {
                        nextChase.insert(pid)
                    }
                }
            }
            toChase = nextChase
        }
    }

    /// Build effective children map (same logic as ViewModel)
    private static func buildEffectiveChildrenMap(nodeMap: [String: MessageNode]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        map.reserveCapacity(nodeMap.count)

        for (nodeId, node) in nodeMap {
            map[nodeId] = node.childrenIds.filter { nodeMap[$0] != nil }
        }

        for (nodeId, node) in nodeMap {
            if let pid = node.parentId, nodeMap[pid] != nil {
                if !(map[pid]?.contains(nodeId) ?? false) {
                    map[pid, default: []].append(nodeId)
                }
            }
        }

        return map
    }

    // MARK: - File Name Helper

    /// Sanitize conversation title for use as filename
    static func sanitizedFileName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmed = String(cleaned.prefix(100))
        return trimmed.isEmpty ? "untitled" : trimmed
    }
}
