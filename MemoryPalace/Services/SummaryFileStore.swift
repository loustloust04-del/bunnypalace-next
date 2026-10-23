import Foundation
import SwiftData

/// 楼层记忆树 · 摘要文件存取
/// floors/{slug}/memory/summaries/{convId前8}-{标题slug}.md
/// YAML frontmatter 存元数据，正文=摘要。人可读可改，AI 经 fs_*（只读）可 grep。
/// convId 前 8 是稳定锚（load 按前缀 glob），标题 slug 是可读糖——标题改了 save 时自动 rename 跟随。
enum SummaryFileStore {

    // MARK: - 路径

    private static func summariesDir(profileId: String) -> URL {
        let dir = FileLibraryStore.memoryRoot(profileId: profileId)
            .appendingPathComponent("summaries", isDirectory: true)
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
    private static func existingFile(conversationId: String, profileId: String) -> URL? {
        let dir = summariesDir(profileId: profileId)
        let prefix = prefix8(conversationId) + "-"
        MainThreadIO.note(.enumerate, "SummaryFileStore.existingFile")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.first { $0.hasPrefix(prefix) && $0.hasSuffix(".md") }
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: - 存取

    static func load(conversationId: String, profileId: String) -> ContextSummary? {
        MainThreadIO.note(.read, "SummaryFileStore.load")
        guard let url = existingFile(conversationId: conversationId, profileId: profileId),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(raw)
    }

    static func save(_ summary: ContextSummary, conversationId: String, profileId: String, conversationTitle: String?) {
        let dir = summariesDir(profileId: profileId)
        let desired = dir.appendingPathComponent("\(prefix8(conversationId))-\(slugify(conversationTitle)).md")
        // 标题改了 → rename 跟随（失败不挡保存，继续写旧名）
        if let existing = existingFile(conversationId: conversationId, profileId: profileId),
           existing.lastPathComponent != desired.lastPathComponent {
            try? FileManager.default.moveItem(at: existing, to: desired)
        }
        let target = existingFile(conversationId: conversationId, profileId: profileId) ?? desired
        do {
            try Data(render(summary, conversationId: conversationId).utf8).write(to: target, options: .atomic)
        } catch {
            print("📝 SummaryFileStore: ❌ 写入失败 \(target.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    static func clear(conversationId: String, profileId: String) {
        guard let url = existingFile(conversationId: conversationId, profileId: profileId) else { return }
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

    // MARK: - UserDefaults → 文件 一次性迁移

    private static let migrationDoneKey = "memoryTreeMigrated_v1"
    private static let legacyKeyPrefix = "ctxSummary_"

    /// 旧摘要（UserDefaults）迁入记忆树。幂等：全部成功才落 done 标记；
    /// 写盘失败的 key 保留下次重试；无主（对话已删）和解不开的丢弃。
    static func migrateFromUserDefaultsIfNeeded(container: ModelContainer) {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: migrationDoneKey) else { return }
        let keys = ud.dictionaryRepresentation().keys.filter { $0.hasPrefix(legacyKeyPrefix) }
        guard !keys.isEmpty else { ud.set(true, forKey: migrationDoneKey); return }

        let context = ModelContext(container)
        var migrated = 0, dropped = 0, failed = 0
        for key in keys {
            let convId = String(key.dropFirst(legacyKeyPrefix.count))
            guard let data = ud.data(forKey: key),
                  let summary = try? JSONDecoder().decode(ContextSummary.self, from: data) else {
                ud.removeObject(forKey: key); dropped += 1; continue
            }
            var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == convId })
            descriptor.fetchLimit = 1
            guard let conv = (try? context.fetch(descriptor))?.first else {
                ud.removeObject(forKey: key); dropped += 1; continue
            }
            save(summary, conversationId: convId, profileId: conv.profileId, conversationTitle: conv.title)
            if load(conversationId: convId, profileId: conv.profileId) != nil {
                ud.removeObject(forKey: key); migrated += 1
            } else {
                failed += 1
            }
        }
        if failed == 0 { ud.set(true, forKey: migrationDoneKey) }
        print("📝 摘要迁移: \(migrated) 个入记忆树，\(dropped) 个无主/脏数据丢弃，\(failed) 个失败\(failed > 0 ? "（key 保留，下次重试）" : "")")
    }
}
