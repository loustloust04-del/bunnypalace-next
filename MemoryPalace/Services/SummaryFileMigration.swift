import Foundation
import SwiftData
import MemoryCore

extension SummaryFileStore {
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
            save(summary, conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: conv.profileId), conversationTitle: conv.title)
            if load(conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: conv.profileId)) != nil {
                ud.removeObject(forKey: key); migrated += 1
            } else {
                failed += 1
            }
        }
        if failed == 0 { ud.set(true, forKey: migrationDoneKey) }
        print("📝 摘要迁移: \(migrated) 个入记忆树，\(dropped) 个无主/脏数据丢弃，\(failed) 个失败\(failed > 0 ? "（key 保留，下次重试）" : "")")
    }
}
