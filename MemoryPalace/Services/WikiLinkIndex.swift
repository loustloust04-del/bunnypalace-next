import Foundation

/// 文件库 wiki 链接索引：正向（文件 → 引用目标）+ 反向查询（谁链到我）。
/// backlinks / 改名自动更新链接的共享地基（research-obsidian-workflow.md）。
///
/// - 内存态，按楼层惰性全量构建；文件变化后调 noteLibraryChanged 失效重建
///   （当前规模几十个 md，全量重建 <100ms，不提前造持久化索引——fs_search 教训）
/// - 目标解析与 openWikiTarget 同规则：精确路径 → 文件名匹配（带/不带扩展名，不分大小写）
/// - 已知局限（spike 级）：正则扫描不排除代码块里的 [[]]
enum WikiLinkIndex {

    /// path → 该文件里出现的原始 [[目标]] 集合
    private static var forward: [String: [String: Set<String>]] = [:]   // profileId → path → targets
    private static var built: Set<String> = []                          // 已构建的 profileId

    private static let wikiPattern = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n]+)\\]\\]")

    // MARK: - 构建与失效

    static func noteLibraryChanged(profileId: String) {
        built.remove(profileId)
        forward[profileId] = nil
    }

    private static func ensureBuilt(profileId: String) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("WikiLinkIndex.ensureBuilt") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        guard !built.contains(profileId) else { return }
        var table: [String: Set<String>] = [:]
        for meta in FileLibraryStore.cachedList(profileId: profileId) where isIndexable(meta.path) {
            guard let body = try? FileLibraryStore.read(meta.path, profileId: profileId) else { continue }
            let targets = scan(body)
            if !targets.isEmpty { table[meta.path] = targets }
        }
        forward[profileId] = table
        built.insert(profileId)
    }

    private static func isIndexable(_ path: String) -> Bool {
        ["md", "markdown", "txt"].contains((path as NSString).pathExtension.lowercased())
    }

    static func scan(_ content: String) -> Set<String> {
        let ns = content as NSString
        var out: Set<String> = []
        wikiPattern.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty { out.insert(target) }
        }
        return out
    }

    // MARK: - 查询

    /// 这个文件写了哪些 [[目标]]（原始字符串）
    static func outgoingTargets(of path: String, profileId: String) -> Set<String> {
        ensureBuilt(profileId: profileId)
        return forward[profileId]?[path] ?? []
    }

    /// 谁链到这个文件（backlinks）。目标解析规则与 openWikiTarget 一致。
    static func backlinks(of path: String, profileId: String) -> [String] {
        ensureBuilt(profileId: profileId)
        guard let table = forward[profileId] else { return [] }
        let full = path.lowercased()
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()

        var sources: [String] = []
        for (source, targets) in table where source != path {
            let hit = targets.contains { raw in
                var t = raw.lowercased()
                if URL(fileURLWithPath: t).pathExtension.isEmpty { t += ".md" }
                let tName = URL(fileURLWithPath: t).lastPathComponent
                let tBase = URL(fileURLWithPath: raw.lowercased()).lastPathComponent
                return t == full || tName == name || tBase == base
            }
            if hit { sources.append(source) }
        }
        return sources.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
