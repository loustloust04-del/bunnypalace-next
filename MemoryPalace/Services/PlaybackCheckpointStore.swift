#if PERSONAL_APPS
#if DEBUG
import Foundation

/// 续播位置的高频 checkpoint 存储。
///
/// 设计意图（plan 第 5 步）：
/// - SwiftData save 走慢路径（5s 一次），UserDefaults 走快路径（1s 一次）
/// - UserDefaults 写入是同步原子的，能扛 SIGKILL / force quit
/// - 启动时取 max(checkpoint, db.currentTime) 作为续播位置
/// - 删除书时 caller 必须主动调 delete()，否则 key 残留
enum PlaybackCheckpointStore {

    struct Checkpoint: Codable, Equatable {
        let timestamp: Double  // 秒
        let savedAt: Date
    }

    private static let prefix = "audiobook.checkpoint."

    static func key(profileId: String, bookId: UUID) -> String {
        "\(prefix)\(profileId).\(bookId.uuidString)"
    }

    static func read(profileId: String, bookId: UUID) -> Checkpoint? {
        guard let data = UserDefaults.standard.data(forKey: key(profileId: profileId, bookId: bookId)) else {
            return nil
        }
        return try? JSONDecoder().decode(Checkpoint.self, from: data)
    }

    static func write(profileId: String, bookId: UUID, timestamp: Double) {
        let checkpoint = Checkpoint(timestamp: timestamp, savedAt: Date())
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        UserDefaults.standard.set(data, forKey: key(profileId: profileId, bookId: bookId))
    }

    static func delete(profileId: String, bookId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(profileId: profileId, bookId: bookId))
    }
}
#endif
#endif
