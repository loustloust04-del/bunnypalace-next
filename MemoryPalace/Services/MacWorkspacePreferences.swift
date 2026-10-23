#if os(macOS)
import Foundation
import Observation

/// Mac-only workspace choices. Dock membership/order is separate from iPad's
/// desktop and from a tool's global enabled state. Editing never deletes tool data.
@Observable
@MainActor
final class MacWorkspacePreferences {
    static let shared = MacWorkspacePreferences()
    private static let key = "mac.workspace.preferences.v1"

    struct DockItem: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case tool, divider }
        let id: String
        let kind: Kind
        let toolID: String?

        static func tool(_ id: String) -> Self { .init(id: "tool:" + id, kind: .tool, toolID: id) }
        static func divider() -> Self { .init(id: "divider:" + UUID().uuidString, kind: .divider, toolID: nil) }
    }
    private struct Snapshot: Codable {
        var dockItems: [DockItem]?
        var showCodingSessions: Bool
        /// 左栏面板组上次选中的 tab（`MacLeftPanelTab.rawValue`）。存字符串：旧档没这个键、将来 tab 改名都不会把整份档解坏
        var leftPanelTab: String?
        /// 菜单栏快看（MenuBarExtra）；旧档没这个键 = 开
        var showMenuBarExtra: Bool?
    }

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var dockItems: [DockItem]?
    var showCodingSessions: Bool { didSet { if oldValue != showCodingSessions { persist() } } }
    /// 左栏面板组（「对话 | Code」）上次选中的 tab；启动时据此恢复。Code 关掉时读出来一律当「对话」
    var leftPanelTab: MacLeftPanelTab { didSet { if oldValue != leftPanelTab { persist() } } }
    /// 菜单栏快看（research-magpie §2.6）显不显示；默认开
    var showMenuBarExtra: Bool { didSet { if oldValue != showMenuBarExtra { persist() } } }
    /// One-shot settings navigation request; never persisted or delivered through focus preferences.
    var settingsRequested = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let snapshot = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        dockItems = snapshot?.dockItems.map(Self.unique)
        showCodingSessions = snapshot?.showCodingSessions ?? true
        leftPanelTab = snapshot?.leftPanelTab.flatMap(MacLeftPanelTab.init(rawValue:)) ?? .chats
        showMenuBarExtra = snapshot?.showMenuBarExtra ?? true
    }

    /// 左栏面板组此刻有哪几个 tab（PS 面板组 = tab 栏 + 内容）。Code 开关关掉 → 只剩「对话」
    var leftPanelTabs: [MacLeftPanelTab] { showCodingSessions ? MacLeftPanelTab.allCases : [.chats] }

    /// 启动该恢复到哪个 tab：存的是 Code 但开关关了 → 对话
    var restoredLeftPanelTab: MacLeftPanelTab { leftPanelTabs.contains(leftPanelTab) ? leftPanelTab : .chats }

    static let homeID = "home"
    static let modeID = "mac.workspace.mode"
    static let utilityDividerID = "divider:workspace-utilities"

    func items(seed: [String]) -> [DockItem] {
        if let dockItems { return dockItems }
        // Preserve the existing order; only add natural group boundaries.
        let groupStarts: Set<String> = ["ccTerminal", "sticker", "health"]
        var result: [DockItem] = []
        for id in seed {
            if !result.isEmpty, groupStarts.contains(id) {
                result.append(DockItem(id: "divider:group:" + id, kind: .divider, toolID: nil))
            }
            result.append(.tool(id))
        }
        if !result.isEmpty {
            result.append(DockItem(id: Self.utilityDividerID, kind: .divider, toolID: nil))
        }
        result += [.tool(Self.homeID), .tool(Self.modeID)]
        return Self.unique(result)
    }

    func addTool(_ id: String, seed: [String]) {
        var list = items(seed: seed)
        guard !list.contains(where: { $0.toolID == id }) else { return }
        list.append(.tool(id)); store(list)
    }

    func insertDivider(after id: String? = nil, seed: [String]) {
        var list = items(seed: seed)
        let index = id.flatMap { key in list.firstIndex { $0.id == key } }.map { $0 + 1 } ?? list.count
        list.insert(.divider(), at: index); store(list)
    }

    func remove(_ id: String, seed: [String]) { store(items(seed: seed).filter { $0.id != id }) }

    /// Commit once on drop. Both edges and the terminal slot are valid, so an item
    /// can move to the last position; cancelled drags never write preferences.
    func move(_ id: String, relativeTo target: String?, after: Bool = false, seed: [String]) {
        guard id != target else { return }
        var list = items(seed: seed)
        guard let source = list.firstIndex(where: { $0.id == id }) else { return }
        let item = list.remove(at: source)
        if let target, let index = list.firstIndex(where: { $0.id == target }) {
            list.insert(item, at: index + (after ? 1 : 0))
        } else {
            list.append(item)
        }
        store(list)
    }

    func move(from offsets: IndexSet, to destination: Int, seed: [String]) {
        let original = items(seed: seed)
        let moving = offsets.sorted().filter { original.indices.contains($0) }
        guard !moving.isEmpty else { return }
        let selected = Set(moving)
        var result = original.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
        let target = max(0, min(result.count, destination - moving.filter { $0 < destination }.count))
        result.insert(contentsOf: moving.map { original[$0] }, at: target)
        store(result)
    }

    func resetDock() { dockItems = nil; persist() }

    private func store(_ list: [DockItem]) {
        let next = Self.unique(list)
        guard next != dockItems else { return }
        dockItems = next; persist()
    }

    private static func unique(_ list: [DockItem]) -> [DockItem] {
        var seen = Set<String>()
        return list.filter {
            guard $0.kind == .divider || $0.toolID?.isEmpty == false else { return false }
            return seen.insert($0.id).inserted
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Snapshot(dockItems: dockItems, showCodingSessions: showCodingSessions,
                                                        leftPanelTab: leftPanelTab.rawValue,
                                                        showMenuBarExtra: showMenuBarExtra)) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// 左栏面板组里的面板（docs/design-panel-system-ps.md：面板组 = tab 栏 + 当前 tab 的内容）。
/// 「对话」是普通对话列表，「Code」是编程会话列表；Code 的激活态仍由 `CodingSessionLibrary.isActive` 表达
/// （主区域的编程会话详情也跟它走），面板 tab 只是它的入口与显示。
/// `panelID` 带 `conv.` 前缀，和右栏工具 id 同一个命名空间也不撞——以后要拖 tab 浮出 / 并组时直接当 payload。
enum MacLeftPanelTab: String, CaseIterable, Identifiable {
    case chats
    case code

    var id: String { panelID }
    var panelID: String { "conv." + rawValue }

    var title: String {
        switch self {
        case .chats: return "对话"
        case .code: return "Code"
        }
    }

    var symbol: String {
        switch self {
        case .chats: return "bubble.left"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    init?(panelID: String) {
        guard let tab = Self.allCases.first(where: { $0.panelID == panelID }) else { return nil }
        self = tab
    }

    var groupTab: PanelGroupTab { PanelGroupTab(id: panelID, title: title, symbol: symbol) }
}
#endif
