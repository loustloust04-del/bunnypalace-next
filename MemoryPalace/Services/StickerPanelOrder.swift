import Foundation

/// ➕ 面板 / 贴纸库里贴纸的顺序：置顶的在最前，其余按最近用过排，没用过的保持原顺序（添加时间倒序）。
/// 每楼层一份，存在贴纸目录下的 panel-order.json，不进数据库。
struct StickerPanelOrder: Codable, Equatable {
    var pinned: [UUID] = []
    var recent: [UUID] = []
    /// 手动排过（iOS 面板长按拖动）：有它就只按它排，不再按置顶 / 最近自动挪；不在里面的（新加的）排最前
    var manual: [UUID]?

    static let recentLimit = 200

    func isPinned(_ id: UUID) -> Bool { pinned.contains(id) }

    func sorted<T>(_ items: [T], id: (T) -> UUID) -> [T] {
        if let manual, !manual.isEmpty {
            var position: [UUID: Int] = [:]
            for (index, value) in manual.enumerated() { position[value] = index }
            return items.enumerated()
                .sorted { lhs, rhs in
                    let l = position[id(lhs.element)].map { items.count + $0 } ?? lhs.offset
                    let r = position[id(rhs.element)].map { items.count + $0 } ?? rhs.offset
                    return l < r
                }
                .map(\.element)
        }
        var rank: [UUID: Int] = [:]
        for (index, value) in pinned.enumerated() { rank[value] = index }
        for (index, value) in recent.enumerated() where rank[value] == nil { rank[value] = pinned.count + index }
        let fallback = pinned.count + recent.count
        return items.enumerated()
            .sorted { lhs, rhs in
                let l = rank[id(lhs.element)] ?? fallback + lhs.offset
                let r = rank[id(rhs.element)] ?? fallback + rhs.offset
                return l < r
            }
            .map(\.element)
    }

    mutating func touch(_ id: UUID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    mutating func setManual(_ ids: [UUID]) {
        manual = ids
        pinned = []
    }

    /// 手动排过以后「置顶」= 挪到最前
    mutating func togglePin(_ id: UUID) {
        if var manual, !manual.isEmpty {
            manual.removeAll { $0 == id }
            manual.insert(id, at: 0)
            self.manual = manual
            return
        }
        if let index = pinned.firstIndex(of: id) {
            pinned.remove(at: index)
        } else {
            pinned.insert(id, at: 0)
        }
    }

    mutating func prune(keeping ids: Set<UUID>) {
        pinned.removeAll { !ids.contains($0) }
        recent.removeAll { !ids.contains($0) }
        manual?.removeAll { !ids.contains($0) }
    }

    static func load(from url: URL) -> StickerPanelOrder {
        guard let data = try? Data(contentsOf: url),
              let order = try? JSONDecoder().decode(StickerPanelOrder.self, from: data) else { return StickerPanelOrder() }
        return order
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
