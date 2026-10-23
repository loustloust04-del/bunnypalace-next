import Foundation

/// 对话分支选择表（卡库 ③b，plan §3.8–3.9）：父节点 id → 选中的孩子 id，持久在 `Conversation.branchSelectionData`。
/// 父是合成根时键就是合成根 id。选择规则只有这一处：加载、主线计算、切支重建、后台追加都走 `pick`。
/// 纯值类型、不碰 SwiftData，后台线程和单测可直接用。
enum BranchSelection {
    struct Link: Equatable {
        let id: String
        let parentId: String?
        let childrenIds: [String]
    }

    struct Resolution: Equatable {
        /// 根 → 末端的完整路径（含 system / tool / 合成根这类不显示的节点）
        let pathIds: [String]
        let rootId: String?
        /// 有效孩子表（childrenIds 过滤掉不存在的 + 按 parentId 补回漏挂的）
        let children: [String: [String]]
        /// 修补后的选择表：失效记录已删，路径上的分叉点记下实际走的孩子
        let selection: [String: String]
        /// 修补后和入参不同 = 需要写回
        let changed: Bool
        var leafId: String? { pathIds.last }
    }

    // MARK: - 编解码

    static func decode(_ data: Data?) -> [String: String] {
        guard let data, let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    /// 空表存 nil：没有分叉的对话不写列
    static func encode(_ selection: [String: String]) -> Data? {
        guard !selection.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(selection)
    }

    /// 复制对话 / 导入副本：键值按同一映射换 id，映射不到的记录丢掉
    static func remap(_ data: Data?, _ idMap: (String) -> String?) -> Data? {
        var out: [String: String] = [:]
        for (parent, child) in decode(data) {
            if let p = idMap(parent), let c = idMap(child) { out[p] = c }
        }
        return encode(out)
    }

    // MARK: - 选择规则（唯一）

    /// 分叉点选哪个孩子：选择表里的有效记录 → 旧 currentNodeId 路径上的孩子 → 稳定序第一个
    ///（第一个 = 改造前 buildTreeInBackground / computeMainPathSet 的默认）
    static func pick(parent: String, children: [String], selection: [String: String], fallbackPath: Set<String>) -> String? {
        guard !children.isEmpty else { return nil }
        if let chosen = selection[parent], children.contains(chosen) { return chosen }
        return children.first(where: { fallbackPath.contains($0) }) ?? children[0]
    }

    /// 从 rootId 往下按 pick 走到末端
    static func walk(from rootId: String, children: [String: [String]], selection: [String: String], fallbackPath: Set<String>) -> [String] {
        var path: [String] = []
        var visited = Set<String>()
        var current: String? = rootId
        while let nid = current, visited.insert(nid).inserted {
            path.append(nid)
            current = pick(parent: nid, children: children[nid] ?? [], selection: selection, fallbackPath: fallbackPath)
        }
        return path
    }

    /// 把 nodeId 的祖先链写进选择表（只记有多个孩子的分叉点）：切支、新消息落点、临时浏览共用
    static func selecting(_ nodeId: String, in selection: [String: String],
                          parentOf: (String) -> String?, childCount: (String) -> Int) -> [String: String] {
        var out = selection
        var child = nodeId
        var seen: Set<String> = [nodeId]
        while let parent = parentOf(child), seen.insert(parent).inserted {
            if childCount(parent) > 1 { out[parent] = child }
            child = parent
        }
        return out
    }

    // MARK: - 解析

    /// 有效孩子表：childrenIds 过滤到存在的节点，再按 parentId 补回漏挂的（按 id 排序追加，保证稳定序）
    static func effectiveChildren(_ byId: [String: Link]) -> [String: [String]] {
        var children: [String: [String]] = [:]
        children.reserveCapacity(byId.count)
        for (id, link) in byId {
            children[id] = link.childrenIds.filter { byId[$0] != nil }
        }
        for id in byId.keys.sorted() {
            guard let pid = byId[id]?.parentId, byId[pid] != nil else { continue }
            if !(children[pid]?.contains(id) ?? false) { children[pid, default: []].append(id) }
        }
        return children
    }

    /// 从 anchor 往上追到最顶层可达祖先：返回沿途 id 集和根
    static func trace(from anchor: String, in byId: [String: Link]) -> (ids: Set<String>, rootId: String?) {
        var ids = Set<String>()
        var rootId: String?
        var current: String? = anchor
        while let nid = current, let link = byId[nid], ids.insert(nid).inserted {
            if link.parentId == nil || byId[link.parentId ?? ""] == nil { rootId = nid }
            current = link.parentId
        }
        return (ids, rootId)
    }

    /// 加载 / 主线计算的唯一入口：nodes + 选择表 + 旧 currentNodeId → 路径和修补后的选择表。
    /// 根沿用旧规则：currentNodeId 的顶层祖先；它失效时取无父节点里 id 最小的。
    static func resolve(links: [Link], selection: [String: String], legacyCurrentNodeId: String) -> Resolution {
        var byId: [String: Link] = [:]
        byId.reserveCapacity(links.count)
        for link in links { byId[link.id] = link }
        return resolve(byId: byId, selection: selection, legacyCurrentNodeId: legacyCurrentNodeId)
    }

    static func resolve(byId: [String: Link], selection: [String: String], legacyCurrentNodeId: String) -> Resolution {
        let children = effectiveChildren(byId)
        let legacy = trace(from: legacyCurrentNodeId, in: byId)
        let rootId = legacy.rootId ?? byId.values
            .filter { $0.parentId == nil || byId[$0.parentId ?? ""] == nil }
            .map(\.id).min()
        let path = rootId.map { walk(from: $0, children: children, selection: selection, fallbackPath: legacy.ids) } ?? []

        var patched = selection
        for (parent, child) in selection where !(children[parent]?.contains(child) ?? false) {
            patched[parent] = nil
        }
        for (i, nid) in path.enumerated() where i + 1 < path.count && (children[nid]?.count ?? 0) > 1 {
            patched[nid] = path[i + 1]
        }
        return Resolution(pathIds: path, rootId: rootId, children: children, selection: patched, changed: patched != selection)
    }
}
