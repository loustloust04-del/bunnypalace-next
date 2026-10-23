#if os(macOS)
import Foundation

/// Grok 会话归组（Wake `grok_group.rs`）：主会话登记的子代理关系优先，没有父会话时再用 worktree 登记表、git remote 与临时 worktree 名
/// 恢复真实项目。一轮扫描内共享一份快照（`GrokAdapter.beginScan`），免得每解析一个 updates.jsonl 都重扫目录 / SQLite
enum CodingGrokGroup {
    struct Context: Sendable {
        var worktrees: [WorktreeRow] = []
        /// 主会话目录登记的子代理：child id → 直接父 id 与父会话 cwd
        var parents: [String: ParentRef] = [:]
    }

    struct WorktreeRow: Sendable {
        var path: String
        var sourceRepo: String
        var repoName: String
    }

    struct ParentRef: Sendable {
        var parentId: String
        var parentCwd: String
    }

    static func load(sessionsRoot: URL, grokHome: URL) -> Context {
        Context(worktrees: worktreeRows(grokHome), parents: subagentParents(sessionsRoot))
    }

    /// 本数据根能确认的直接关系；扫描器合并全部 Grok 数据根后再扁平到根——局部快照提前压平会丢掉跨数据根的后半段父链
    static func parentLinks(_ ctx: Context) -> [(child: String, parent: String)] {
        ctx.parents.compactMap { child, parent in
            parent.parentId.isEmpty || parent.parentId == child ? nil : (child: "grok:\(child)", parent: "grok:\(parent.parentId)")
        }
    }

    static func canonicalProject(cwd: String, remotes: [String], grokHome: URL, childId: String, ctx: Context) -> (path: String, name: String) {
        if let parent = rootParent(childId, ctx.parents) { return (parent.parentCwd, CodingParse.projectName(parent.parentCwd)) }
        if cwd.isEmpty { return ("", CodingParse.projectName(cwd)) }
        let slug = worktreeSlug(cwd, grokHome: grokHome)
        if let pair = lookupSource(cwd, slug: slug, rows: ctx.worktrees) { return pair }
        if let slug {
            let path = grokHome.appendingPathComponent("worktrees").appendingPathComponent(slug).path
            let name = remotes.lazy.compactMap(repoName(fromRemote:)).first ?? (slug.hasPrefix("github-") ? String(slug.dropFirst(7)) : slug)
            return (path, name)
        }
        if isEphemeralWorktree(cwd) {
            if let remote = remotes.first(where: { !$0.isEmpty }) {
                if let local = localCheckout(fromRemote: remote) { return (local, CodingParse.projectName(local)) }
                if let name = repoName(fromRemote: remote) { return ("git-remote:\(name)", name) }
            }
            if let path = ephemeralPlanPath(cwd) { return (path, CodingParse.projectName(path)) }
        }
        return (cwd, CodingParse.projectName(cwd))
    }

    static func normalizePath(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p.hasPrefix("/private/var/") ? String(p.dropFirst("/private".count)) : p
    }

    /// `~/.grok/worktrees.db`：Grok 起的 worktree 与源仓库的登记表
    static func worktreeRows(_ grokHome: URL) -> [WorktreeRow] {
        guard let reader = CodingSQLiteReader.open(grokHome.appendingPathComponent("worktrees.db"), tag: "grok-worktrees") else { return [] }
        var rows: [WorktreeRow] = []
        reader.query("SELECT path, source_repo, repo_name FROM worktrees WHERE path != '' AND source_repo != ''") { r in
            guard let path = r.text(0), let source = r.text(1) else { return }
            rows.append(WorktreeRow(path: path, sourceRepo: source, repoName: r.text(2) ?? ""))
        }
        return rows
    }

    /// 严格的 %XX 解码（非法序列原样保留，非法 UTF-8 按替换字符）
    static func percentDecode(_ input: String) -> String {
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        let bytes = Array(input.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 37, i + 2 < bytes.count, let high = hex(bytes[i + 1]), let low = hex(bytes[i + 2]) {
                out.append(high << 4 | low)
                i += 3
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// cwd 组目录名优先读目录里的 `.cwd` 边车，没有才 percent-decode 目录名
    static func groupCwd(_ dir: URL) -> String {
        if let raw = try? String(contentsOf: dir.appendingPathComponent(".cwd"), encoding: .utf8) {
            let cwd = CodingParse.trimmed(raw)
            if !cwd.isEmpty { return cwd }
        }
        return percentDecode(dir.lastPathComponent)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func subagentParents(_ sessionsRoot: URL) -> [String: ParentRef] {
        let fm = FileManager.default
        var parents: [String: ParentRef] = [:]
        for group in (try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? [] where isDirectory(group) {
            let parentCwd = groupCwd(group)
            if parentCwd.isEmpty { continue }
            for session in (try? fm.contentsOfDirectory(at: group, includingPropertiesForKeys: nil)) ?? [] {
                let subagents = session.appendingPathComponent("subagents")
                guard isDirectory(subagents) else { continue }
                let folderId = session.lastPathComponent
                for child in (try? fm.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? [] {
                    guard let data = try? Data(contentsOf: child.appendingPathComponent("meta.json")),
                          let value = (try? JSONSerialization.jsonObject(with: data)) as? CodingParse.JSON else { continue }
                    let parentId = (value["parent_session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folderId
                    let parent = ParentRef(parentId: parentId, parentCwd: parentCwd)
                    for field in ["child_session_id", "subagent_id"] {
                        if let id = value[field] as? String, !id.isEmpty, parents[id] == nil { parents[id] = parent }
                    }
                }
            }
        }
        return parents
    }

    /// 沿登记的父链走到最上层（成环停在已走过的最后一层）
    static func rootParent(_ childId: String, _ parents: [String: ParentRef]) -> ParentRef? {
        guard !childId.isEmpty else { return nil }
        var current = childId
        var seen = Set<String>()
        var last: ParentRef?
        while seen.insert(current).inserted {
            guard let parent = parents[current] else { break }
            last = parent
            guard parents[parent.parentId] != nil else { break }
            current = parent.parentId
        }
        guard let last, !last.parentId.isEmpty, !last.parentCwd.isEmpty else { return nil }
        return last
    }

    static func worktreeSlug(_ cwd: String, grokHome: URL) -> String? {
        let base = grokHome.appendingPathComponent("worktrees").path
        guard cwd.hasPrefix(base + "/") else { return nil }
        let slug = cwd.dropFirst(base.count + 1).split(separator: "/").first.map(String.init) ?? ""
        return slug.isEmpty ? nil : slug
    }

    static func isEphemeralWorktree(_ cwd: String) -> Bool {
        let name = (cwd as NSString).lastPathComponent
        return name.hasPrefix("wt-") && (cwd.contains("/T/grok-") || cwd.contains("/var/folders/") || cwd.contains("/tmp/"))
    }

    static func localCheckout(fromRemote remote: String) -> String? {
        guard remote.hasPrefix("/") else { return nil }
        for suffix in [".origin.git", ".git"] where remote.hasSuffix(suffix) {
            let stem = String(remote.dropLast(suffix.count))
            if !stem.isEmpty { return stem }
        }
        var trimmed = remote
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    static func repoName(fromRemote remote: String) -> String? {
        if let local = localCheckout(fromRemote: remote) { return (local as NSString).lastPathComponent }
        var r = CodingParse.trimmed(remote)
        while r.hasSuffix("/") { r.removeLast() }
        while r.hasSuffix(".git") { r.removeLast(4) }
        let name = r.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return !name.isEmpty && !name.contains("@") ? name : nil
    }

    static func lookupSource(_ cwd: String, slug: String?, rows: [WorktreeRow]) -> (path: String, name: String)? {
        let cwd = normalizePath(cwd)
        func named(_ row: WorktreeRow) -> (path: String, name: String) {
            (row.sourceRepo, row.repoName.isEmpty ? CodingParse.projectName(row.sourceRepo) : row.repoName)
        }
        for row in rows {
            let worktree = normalizePath(row.path)
            if cwd == worktree || cwd.hasPrefix(worktree + "/") { return named(row) }
        }
        guard let slug else { return nil }
        let needle = "/worktrees/\(slug)"
        for row in rows {
            let worktree = normalizePath(row.path)
            if worktree.contains(needle + "/") || worktree.hasSuffix(needle) || row.repoName == slug { return named(row) }
        }
        return nil
    }

    /// 同一个计划的临时 worktree（`wt-<plan>-pr-<n>`）归到一起
    static func ephemeralPlanPath(_ cwd: String) -> String? {
        let name = (cwd as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        let plan = name.range(of: "-pr-", options: .backwards).map { String(name[..<$0.lowerBound]) } ?? name
        return ((cwd as NSString).deletingLastPathComponent as NSString).appendingPathComponent(plan)
    }
}
#endif
