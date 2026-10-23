import Foundation

/// 横屏桌面格子里每个东西（小组件 / 缩成组件的窗口）放在哪一格。按排版各存一份。
/// **只加不删**（research-ipad-desktop-bugs §2.2）：新来的自动填位写一次、拖动落格写涉及的那几项；
/// 存过的项临时放不下（键盘 / Split View / 转屏把格子压少）只是暂时不显示，存档不动，尺寸回来它就回来。
@MainActor
@Observable
final class DesktopGridStore {
    static let shared = DesktopGridStore()
    private static let key = "ipad.desktop.placements.v1"

    struct Placement: Codable, Equatable {
        var side: GridFrame.Side
        var col: Int
        var row: Int
    }

    /// "a.w.pet" → 格位；"a.t.memory" → 缩成组件的记忆工具
    private(set) var placements: [String: Placement]
    private let defaults: UserDefaults

    /// 09-16 泳道解耦的一次性迁移标记（见 `migrateForLaneDecouple`）
    private static let laneMigrationKey = "ipad.desktop.placements.laneDecoupleMigrated"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let p = try? JSONDecoder().decode([String: Placement].self, from: data) {
            placements = p
        } else {
            placements = [:]
        }
    }

    /// 泳道解耦（09-16）的一次性存档迁移：工具侧从「dock 那边」变成「恒在右」。
    ///
    /// 排版 **b** 不用管——它只有一道 zone，`DesktopGridRules` 的换侧搬迁会自己把组件搬过去。
    /// 排版 **a** 才需要这一趟：两侧改前改后都存在，`grid.zone(p.side)` 恒非 nil ⇒ 搬迁路径一次都不触发，
    /// 旧 `dockSide == .left` 的人（= 粟粟）工具侧的组件会留在左边、被对话列表盖住（R-LD #3）。
    /// 所以按**旧的 dockSide** 把所有 `a.*` 的 side 翻一下，打标记，只跑一次。
    func migrateForLaneDecouple(oldDockSide: DockSide) {
        guard !defaults.bool(forKey: Self.laneMigrationKey) else { return }
        defaults.set(true, forKey: Self.laneMigrationKey)
        guard oldDockSide == .left, !placements.isEmpty else { return }
        var next = placements
        for (key, p) in placements where key.hasPrefix("\(DesktopArrangement.a.rawValue).") {
            next[key] = Placement(side: p.side == .left ? .right : .left, col: p.col, row: p.row)
        }
        guard next != placements else { return }
        placements = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func placement(of itemId: String, in arrangement: DesktopArrangement) -> Placement? {
        placements["\(arrangement.rawValue).\(itemId)"]
    }

    /// 只写给的这几项，别的不动；内容没变不落盘
    func merge(_ map: [String: Placement], in arrangement: DesktopArrangement) {
        var next = placements
        for (id, p) in map { next["\(arrangement.rawValue).\(id)"] = p }
        guard next != placements else { return }
        placements = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
