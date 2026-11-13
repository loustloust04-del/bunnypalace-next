import Foundation

/// 按楼层记上次停在哪一页、哪条对话（plan-atrium P1）：从 atrium 切过去落回那里。
/// 全局 `resume.*` SceneStorage 管冷启动，这个只管切层；草稿对话记 ""。
struct ProfileResume {
    struct Spot: Codable, Equatable {
        var page: Int
        var conversationId: String
    }

    static let key = "resume.byProfile.v1"

    var defaults: UserDefaults = .standard

    func spot(for profileId: String) -> Spot? { all()[profileId] }

    func save(_ spot: Spot, for profileId: String) {
        var map = all()
        guard map[profileId] != spot else { return }
        map[profileId] = spot
        write(map)
    }

    func clear(_ profileId: String) {
        var map = all()
        guard map.removeValue(forKey: profileId) != nil else { return }
        write(map)
    }

    private func all() -> [String: Spot] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: Spot].self, from: data)) ?? [:]
    }

    private func write(_ map: [String: Spot]) {
        defaults.set(try? JSONEncoder().encode(map), forKey: Self.key)
    }
}
