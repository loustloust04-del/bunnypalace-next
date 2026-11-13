import Foundation

/// 楼层记忆树 · 摘要文件存取
/// floors/{slug}/memory/summaries/{convId前8}-{标题slug}.md
/// YAML frontmatter 存元数据，正文=摘要。人可读可改，AI 经 fs_*（只读）可 grep。
/// convId 前 8 是稳定锚（load 按前缀 glob），标题 slug 是可读糖——标题改了 save 时自动 rename 跟随。
public enum SummaryFileStore {}

public extension SummaryFileStore {
    static let folder = "summaries"

    // MARK: - 路径

    private static func summariesDir(memoryRoot: URL) -> URL {
        let dir = memoryRoot
            .appendingPathComponent(folder, isDirectory: true)
        MainThreadIO.note(.mkdir, "SummaryFileStore.summariesDir")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func prefix8(_ conversationId: String) -> String {
        String(conversationId.prefix(8))
    }

    /// 标题 → 文件名安全 slug（保留中文，清洗文件系统危险字符，截 24 字，空回退 untitled）
    private static func slugify(_ title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return "untitled" }
        var out = ""
        for ch in title {
            if "/\\:*?\"<>|#".contains(ch) || ch.isNewline || ch.isWhitespace { out.append("-") }
            else { out.append(ch) }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        if out.count > 24 { out = String(out.prefix(24)) }
        return out.isEmpty ? "untitled" : out
    }

    /// 按 convId 前缀找现有文件（文件名里的标题部分可能已过时，前缀是唯一可信锚）
    private static func existingFile(conversationId: String, memoryRoot: URL) -> URL? {
        let dir = summariesDir(memoryRoot: memoryRoot)
        let prefix = prefix8(conversationId) + "-"
        MainThreadIO.note(.enumerate, "SummaryFileStore.existingFile")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.first { $0.hasPrefix(prefix) && $0.hasSuffix(".md") }
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: - 存取

    static func load(conversationId: String, memoryRoot: URL) -> ContextSummary? {
        MainThreadIO.note(.read, "SummaryFileStore.load")
        guard let url = existingFile(conversationId: conversationId, memoryRoot: memoryRoot),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(raw)
    }

    /// 严格读（三代搬迁 astra #9）：nil = 没有；读不了 / 格式坏了抛。不建目录
    static func loadStrict(conversationId: String, memoryRoot: URL) throws -> ContextSummary? {
        let dir = memoryRoot.appendingPathComponent(folder, isDirectory: true)
        guard let url = try MemoryReadError.existingFile(prefix: prefix8(conversationId) + "-", in: dir) else { return nil }
        guard let s = parse(try MemoryReadError.read(url)) else { throw MemoryReadError.corrupt(url.path) }
        return s
    }

    static func save(_ summary: ContextSummary, conversationId: String, memoryRoot: URL, conversationTitle: String?) {
        let dir = summariesDir(memoryRoot: memoryRoot)
        let desired = dir.appendingPathComponent("\(prefix8(conversationId))-\(slugify(conversationTitle)).md")
        // 标题改了 → rename 跟随（失败不挡保存，继续写旧名）
        if let existing = existingFile(conversationId: conversationId, memoryRoot: memoryRoot),
           existing.lastPathComponent != desired.lastPathComponent {
            try? FileManager.default.moveItem(at: existing, to: desired)
        }
        let target = existingFile(conversationId: conversationId, memoryRoot: memoryRoot) ?? desired
        do {
            try Data(render(summary, conversationId: conversationId).utf8).write(to: target, options: .atomic)
        } catch {
            print("📝 SummaryFileStore: ❌ 写入失败 \(target.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// 这一层第一代老摘要都是哪几个窗口的（三代搬迁用；读 frontmatter 里的完整编号，不建目录）
    static func conversationIds(in memoryRoot: URL) -> [String] {
        let dir = memoryRoot.appendingPathComponent(folder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.compactMap { name in
            guard let raw = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return FrontmatterCodec.parse(raw)?.meta["conversationId"]
        }
    }

    static func clear(conversationId: String, memoryRoot: URL) {
        guard let url = existingFile(conversationId: conversationId, memoryRoot: memoryRoot) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - frontmatter 编解码（FrontmatterCodec，三店共用）

    private static func render(_ summary: ContextSummary, conversationId: String) -> String {
        FrontmatterCodec.render(meta: [
            ("conversationId", conversationId),
            ("coveredCount", String(summary.coveredCount)),
            ("updatedAt", FrontmatterCodec.dateFormatter.string(from: summary.updatedAt)),
        ], body: summary.summary)
    }

    private static func parse(_ raw: String) -> ContextSummary? {
        guard let (meta, body) = FrontmatterCodec.parse(raw),
              let covered = meta["coveredCount"].flatMap({ Int($0) }) else { return nil }
        let updated = meta["updatedAt"].flatMap { FrontmatterCodec.dateFormatter.date(from: $0) } ?? .distantPast
        return ContextSummary(summary: body, coveredCount: covered, updatedAt: updated)
    }

}
