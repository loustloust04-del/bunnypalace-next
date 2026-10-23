import Foundation

// MARK: - Time Machine 备份 schema
//
// 设计: docs/plan-time-machine.md
// 备份目录结构: iCloud/Documents/backup/<yyyy-MM-dd>/<profileId>/conversations/<convId>.json
//   + backup/manifest.json (全局索引)
//   + backup/<yyyy-MM-dd>/.day-manifest.json (单日清单)
//
// 对话 JSON 复用 SyncStore.ConversationDocument schema, 这里只定义索引层结构。

/// 全局索引: backup/manifest.json. 列出所有 backup 时间点供 RestoreSheet 加载日历。
struct BackupManifest: Codable {
    var schemaVersion: Int = 1
    var entries: [BackupEntry] = []     // 按 date 倒序保存(write 时排序)
}

struct BackupEntry: Codable, Identifiable, Hashable {
    var date: String                    // "2026-06-17" (scheduled) 或 "pre-restore-2026-06-17T22-30-15Z"
    var createdAt: Date                 // 第一次写入时间
    var lastWriteAt: Date               // 最后一次增量写入(同日多次 background)
    var profileIds: [String]
    var totalConversations: Int
    var totalSizeBytes: Int
    var kind: Kind

    enum Kind: String, Codable {
        case scheduled                  // 定时备份(每天一份, 7/30 稀疏)
        case preRestore                 // 还原前自动快照(独立 30 天保留)
    }

    var id: String { date }
}

/// 单日清单: backup/<date>/.day-manifest.json. 还原时不用扫每个 conv JSON.
struct DayManifest: Codable {
    var schemaVersion: Int = 1
    var date: String
    var profiles: [ProfileBackup] = []
}

struct ProfileBackup: Codable, Hashable {
    var profileId: String
    var floorName: String               // 备份时楼层名(用户改名后还能在 RestoreSheet 里认出来)
    var floorEmoji: String
    var conversations: [ConversationRef] = []
}

struct ConversationRef: Codable, Hashable {
    var conversationId: String
    var title: String                   // 备份时标题(用户改标题后回忆原标题)
    var nodeCount: Int
    var updateTime: Date
    var sizeBytes: Int
    var sha256: String                  // 内容指纹: 没变直接跳过重写
}

// MARK: - 还原参数

/// 三档恢复粒度.
enum RestoreScope: Hashable {
    case everything                                    // 整库还原
    case profile(profileId: String)                    // 单楼层
    case conversation(profileId: String, convId: String) // 单对话
}

struct RestoreResult {
    var profilesRestored: Int = 0
    var conversationsRestored: Int = 0
    var nodesInserted: Int = 0
    var nodesUpdated: Int = 0
    var nodesDeleted: Int = 0           // 当前有但备份没的 → 删
    /// 洞 6: 同 id 已属于本次还原范围外的楼层 → 整份跳过(不做部分 insert), 计数露到 UI.
    var conversationsSkippedCrossProfile: Int = 0
    var preRestoreEntry: BackupEntry?   // 还原前自动写的快照, 失败时为 nil
}

struct SnapshotResult {
    var written: Int = 0                // 实际写入的 conv 数
    var skipped: Int = 0                // sha 命中, 没变跳过
    var totalSizeBytes: Int = 0         // 当天累计大小
    var error: String?                  // 容量不足/iCloud 没开等
}
