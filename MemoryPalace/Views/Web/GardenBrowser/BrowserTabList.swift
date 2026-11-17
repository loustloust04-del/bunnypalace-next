import Foundation

/// 花园浏览器的一个标签页（docs/plan-browser-tabs.md）：存盘只记这些，网页本身点开才建
struct BrowserTabRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var identityID: UUID
    /// nil = 新标签页（显示浏览器主页）
    var url: String?
    var title: String
    var lastActive: Date
}

/// 标签页列表的纯逻辑（开 / 关 / 切 / 卸载哪个 / 上限），单测用；活网页在 `BrowserTabs`
struct BrowserTabList: Codable, Equatable {
    /// 同时留着的真网页，多了卸掉最久没看的（只留截图，切回去重新加载）
    static let liveLimit = 4
    /// 标签页总数上限，多了关掉最久没看的
    static let maxTabs = 100

    private(set) var records: [BrowserTabRecord] = []
    private(set) var activeID: UUID?

    var active: BrowserTabRecord? { activeID.flatMap { id in records.first { $0.id == id } } }

    func record(_ id: UUID) -> BrowserTabRecord? { records.first { $0.id == id } }

    /// 新开一页并切过去，接在当前页后面（Safari 同款）
    @discardableResult
    mutating func open(url: String?, title: String = "", identityID: UUID, id: UUID = UUID(), at now: Date = Date()) -> UUID {
        let record = BrowserTabRecord(id: id, identityID: identityID, url: url, title: title, lastActive: now)
        if let activeID, let i = records.firstIndex(where: { $0.id == activeID }) {
            records.insert(record, at: i + 1)
        } else {
            records.append(record)
        }
        activeID = id
        trim()
        return id
    }

    mutating func select(_ id: UUID, at now: Date = Date()) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].lastActive = now
        activeID = id
    }

    /// 关掉一页；关的是当前页就切到最近看过的那页
    mutating func close(_ id: UUID) {
        records.removeAll { $0.id == id }
        guard activeID == id else { return }
        activeID = records.max { $0.lastActive < $1.lastActive }?.id
    }

    mutating func closeOthers(keeping id: UUID) {
        records.removeAll { $0.id != id }
        activeID = records.first?.id
    }

    mutating func closeAll() {
        records = []
        activeID = nil
    }

    mutating func update(_ id: UUID, url: String? = nil, title: String? = nil, identityID: UUID? = nil) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        if let url { records[i].url = url }
        if let title { records[i].title = title }
        if let identityID { records[i].identityID = identityID }
    }

    /// 活着的网页里该卸掉的：除了当前页，按最久没看的先卸，直到不超过上限
    func toUnload(live: Set<UUID>, limit: Int = BrowserTabList.liveLimit) -> [UUID] {
        guard live.count > limit else { return [] }
        let candidates = records.filter { live.contains($0.id) && $0.id != activeID }.sorted { $0.lastActive < $1.lastActive }
        return Array(candidates.prefix(live.count - limit).map(\.id))
    }

    private mutating func trim() {
        while records.count > Self.maxTabs,
              let oldest = records.filter({ $0.id != activeID }).min(by: { $0.lastActive < $1.lastActive }) {
            records.removeAll { $0.id == oldest.id }
        }
    }
}
