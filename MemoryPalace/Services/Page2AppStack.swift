import Foundation

/// page2 打开过的应用（plan-page2-app-shell §2.1）。
/// `openApps` 是后台：最近用的在前，最多 `capacity` 个，满了踢最久没用的。
/// `history` 是返回路径：按打开的先后记，当前应用在末尾；导航钮「回上一个应用」只在这条路径上退一格，
/// 不拿「最近用过」的顺序代替——那样 A→B→C 退到 B 再退会跳回 C。
struct Page2AppStack: Equatable {
    /// 4 → 8（#085：右边竖条能上下滚，⧫ 粟粟 10-11「滚动」）
    static let capacity = 8
    static let historyLimit = 32

    private(set) var openApps: [String] = []
    private(set) var history: [String] = []

    init() {}

    /// 打开（或切回）一个应用，返回因此被踢出后台的应用
    @discardableResult
    mutating func open(_ id: String, recordsHistory: Bool = true) -> String? {
        var evicted: String?
        if !openApps.contains(id), openApps.count >= Self.capacity { evicted = openApps.removeLast() }
        openApps.removeAll { $0 == id }
        openApps.insert(id, at: 0)
        if recordsHistory, history.last != id {
            history.append(id)
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }
        return evicted
    }

    mutating func close(_ id: String) {
        openApps.removeAll { $0 == id }
        history = Self.collapsed(history.filter { $0 != id })
    }

    var canGoBack: Bool { history.count >= 2 }

    /// 返回路径退一格，把上一个应用切到前台并返回它
    @discardableResult
    mutating func back() -> String? {
        guard canGoBack else { return nil }
        history.removeLast()
        guard let previous = history.last else { return nil }
        open(previous, recordsHistory: false)
        return previous
    }

    /// 工具被关掉或在 Lite 下隐藏时，把它从后台和返回路径里拿掉
    mutating func retain(_ isAvailable: (String) -> Bool) {
        openApps = openApps.filter(isAvailable)
        history = Self.collapsed(history.filter(isAvailable))
    }

    // MARK: - 写盘（SceneStorage 只存简单类型）

    var encoded: String { openApps.joined(separator: ",") + "|" + history.joined(separator: ",") }

    init(encoded: String) {
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
        let ids = { (index: Int) -> [String] in
            guard parts.indices.contains(index) else { return [] }
            return parts[index].split(separator: ",").map(String.init)
        }
        var seen = Set<String>()
        openApps = Array(ids(0).filter { seen.insert($0).inserted }.prefix(Self.capacity))
        history = Array(Self.collapsed(ids(1)).suffix(Self.historyLimit))
    }

    private static func collapsed(_ ids: [String]) -> [String] {
        ids.reduce(into: []) { result, id in if result.last != id { result.append(id) } }
    }
}
