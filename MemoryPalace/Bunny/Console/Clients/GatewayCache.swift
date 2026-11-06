// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植；地址 / 口令改读 BunnyGateway（不再写死域名）。
import Foundation

/// 网关数据的本地缓存：**先给旧的，再换新的**（stale-while-revalidate）。
///
/// 之前每个页面都是「打开 → 转圈 → 等网关 → 才显示」，弱网时甚至等不到。
/// 现在打开立刻拿到上次的内容（磁盘读，毫秒级），同时后台去要新的，回来了再无声替换。
/// 代价是可能看到几秒钟的旧数据——但对留言板/心愿单/纪念日这类东西，
/// 「立刻看到上次的」比「等三秒看到最新的」体验好得多。
enum GatewayCache {

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gateway", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func fileURL(_ key: String) -> URL {
        dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    /// 读缓存（没有就返回 nil）
    static func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let d = try? Data(contentsOf: fileURL(key)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func save<T: Encodable>(_ key: String, _ value: T) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        try? d.write(to: fileURL(key), options: .atomic)
    }

    /// 缓存有多旧（秒）；没有缓存返回 nil
    static func age(_ key: String) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(key).path),
              let m = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(m)
    }

    /// 标准取数流程：先回缓存（立刻），再取新的（回来时第二次回调）。
    /// - onValue 会被调用 1~2 次：先旧后新；新的和旧的一样时不重复回调。
    static func fetch<T: Codable & Equatable>(
        key: String,
        remote: @escaping () async -> T?,
        onValue: @MainActor @escaping (T, _ isFresh: Bool) -> Void
    ) async {
        let cached: T? = load(key, as: T.self)
        if let cached {
            await MainActor.run { onValue(cached, false) }
        }
        guard let fresh = await remote() else { return }
        save(key, fresh)
        if fresh != cached {
            await MainActor.run { onValue(fresh, true) }
        }
    }

    /// 清掉某个 key（数据结构变了的时候用）
    static func invalidate(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(key))
    }
}
