import Foundation

/// AI 自己的记忆（记忆修复第二刀 B，plan-memory-fix-2）：楼层记忆树 memory/self/<slug>.md，
/// 格式照 CC memory（顶层 name / description + 两格缩进的 metadata），旁边维护 INDEX.md。
/// 写入只走 remember / edit_memory / forget_memory 和设置里的编辑页；fs 写工具对 memory/ 一律拒绝。
struct SelfMemory: Equatable, Identifiable {
    var slug: String
    var name: String
    var description: String
    var type: String
    var importance: Int
    /// self = 自己想记的（计每日上限）/ asked = 她让记的 / edited = 她在页面里改过
    var origin: String
    var created: Date
    var source: String?
    var superseded: Date?
    var body: String

    var id: String { slug }
    var isActive: Bool { superseded == nil }
    var fileName: String { slug + ".md" }
}

enum SelfMemoryStore {
    static let folder = "self"
    static let indexFileName = "INDEX.md"
    static let types = ["user", "feedback", "project", "reference"]

    static func directory(profileId: String) -> URL {
        FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent(folder, isDirectory: true)
    }

    // MARK: - 格式

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func render(_ m: SelfMemory) -> String {
        var meta = [
            "  type: \(m.type)",
            "  importance: \(m.importance)",
            "  origin: \(m.origin)",
            "  created: \(iso.string(from: m.created))",
        ]
        if let s = m.source, !s.isEmpty { meta.append("  source: \(s)") }
        if let s = m.superseded { meta.append("  superseded: \(iso.string(from: s))") }
        return (["---", "name: \(oneLine(m.name))", "description: \(oneLine(m.description))", "metadata:"] + meta + ["---", "", m.body.trimmingCharacters(in: .whitespacesAndNewlines), ""])
            .joined(separator: "\n")
    }

    /// 解析；缺 name / 头不完整 = nil（这份文件不进注入，页面标「格式坏了」）
    static func parse(_ text: String, slug: String) -> SelfMemory? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var top: [String: String] = [:]
        var meta: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(" ") || line.hasPrefix("\t") { meta[key] = value } else { top[key] = value }
        }
        guard let name = top["name"], !name.isEmpty else { return nil }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return SelfMemory(
            slug: slug,
            name: name,
            description: top["description"] ?? "",
            type: meta["type"].flatMap { types.contains($0) ? $0 : nil } ?? "user",
            importance: clampImportance(Int(meta["importance"] ?? "") ?? 3),
            origin: meta["origin"] ?? "self",
            created: meta["created"].flatMap { iso.date(from: $0) } ?? .distantPast,
            source: meta["source"].flatMap { $0.isEmpty ? nil : $0 },
            superseded: meta["superseded"].flatMap { iso.date(from: $0) },
            body: body
        )
    }

    static func clampImportance(_ v: Int) -> Int { min(5, max(1, v)) }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// 文件名：只留字母、数字、中文、-，空格变 -；空了用时间戳
    static func slugify(_ name: String) -> String {
        let mapped = name.lowercased().map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" { return ch }
            return "-"
        }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = String(collapsed.prefix(60))
        return trimmed.isEmpty ? "memory-\(Int(Date().timeIntervalSince1970))" : trimmed
    }

    // MARK: - 读

    /// 全部（含已失效），新的在前；解析失败的跳过
    static func list(profileId: String) -> [SelfMemory] {
        let dir = directory(profileId: profileId)
        MainThreadIO.note(.enumerate, "SelfMemoryStore.list")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasSuffix(".md") && $0 != indexFileName && !$0.hasPrefix(".") }
            .compactMap { name -> SelfMemory? in
                MainThreadIO.note(.read, "SelfMemoryStore.list")
                guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return nil }
                return parse(text, slug: String(name.dropLast(3)))
            }
            .sorted { $0.created > $1.created }
    }

    /// 按 name 或 slug 找（工具里模型给哪个都认）
    static func find(_ key: String, in list: [SelfMemory]) -> SelfMemory? {
        let k = key.trimmingCharacters(in: .whitespaces)
        return list.first { $0.slug == k || $0.name == k } ?? list.first { $0.slug == slugify(k) }
    }

    /// 记忆面板那一组：有效的在前、已失效的在后（各自保持 list 的新→旧）；有搜索词时只留摘要 / 名字 / 正文里有的
    static func panelRows(_ list: [SelfMemory], keyword: String?) -> [SelfMemory] {
        let matched = keyword.map { kw in
            list.filter { $0.description.localizedStandardContains(kw) || $0.name.localizedStandardContains(kw) || $0.body.localizedStandardContains(kw) }
        } ?? list
        return matched.filter(\.isActive) + matched.filter { !$0.isActive }
    }

    /// 今天（本地日历日）自己主动写的条数——每日上限只数 origin=self
    static func todaySelfCount(_ list: [SelfMemory], now: Date = Date(), calendar: Calendar = .current) -> Int {
        list.filter { $0.origin == "self" && calendar.isDate($0.created, inSameDayAs: now) }.count
    }

    // MARK: - 写

    /// 新 slug 不撞名：已存在就加 -2、-3…
    static func uniqueSlug(for name: String, existing: [SelfMemory]) -> String {
        let base = slugify(name)
        let taken = Set(existing.map(\.slug))
        guard taken.contains(base) else { return base }
        var i = 2
        while taken.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    static func save(_ m: SelfMemory, profileId: String) throws {
        let dir = directory(profileId: profileId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(render(m).utf8).write(to: dir.appendingPathComponent(m.fileName), options: .atomic)
        rebuildIndex(profileId: profileId)
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    /// 彻底删除（只给「已删除」里确认过的那一步用）：删文件 + 重建索引
    static func delete(slug: String, profileId: String) throws {
        let url = directory(profileId: profileId).appendingPathComponent(slug + ".md")
        try FileManager.default.removeItem(at: url)
        rebuildIndex(profileId: profileId)
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    static func indexText(_ list: [SelfMemory]) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        let lines = list.filter(\.isActive).map { m in
            "- [\(m.description.isEmpty ? m.name : m.description)](\(m.fileName)) — \(m.importance) 级 · \(f.string(from: m.created))"
        }
        return (["# 我的记忆", ""] + lines).joined(separator: "\n") + "\n"
    }

    static func rebuildIndex(profileId: String) {
        let url = directory(profileId: profileId).appendingPathComponent(indexFileName)
        try? Data(indexText(list(profileId: profileId)).utf8).write(to: url, options: .atomic)
    }
}
