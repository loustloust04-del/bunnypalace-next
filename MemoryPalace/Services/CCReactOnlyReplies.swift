import Foundation

/// 只贴了表情、没建节点（或建了又撤掉）的 CC 回复 id（plan-cc-reactions-1105 2b）：之后同 id 的回放 / thinking / edit 帧都丢。
/// 存 UserDefaults（app 重启后 hub 回放迟到的帧时还要认得），最多 200 条、先进先出
final class CCReactOnlyReplies {
    static let limit = 200

    private let defaults: UserDefaults
    private let key: String
    private var ids: [String]

    init(defaults: UserDefaults = .standard, key: String = "ccReactOnlyReplyIds") {
        self.defaults = defaults
        self.key = key
        ids = defaults.stringArray(forKey: key) ?? []
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func insert(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
        defaults.set(ids, forKey: key)
    }
}
