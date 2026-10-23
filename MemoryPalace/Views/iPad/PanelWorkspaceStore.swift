import Foundation

/// 命名工作区（PS 的 Window › Workspace，plan-panel-ps 阶段 1）：一份工作区 = 一份面板布局存档（`IPadPanelLayout.LayoutSnapshot`）。
///
/// - 切换 = 整份套上；之后再怎么改布局都不回写那一份，要留就「更新」——和 PS 一样，「重置」回到这一份存的样子
/// - 不含桌面格子里小组件的摆放（`DesktopGridStore`），那是桌面内容不是面板布局
/// - 存档是同一个类型，模型以后加字段（多组）旧工作区照读
@MainActor
@Observable
final class PanelWorkspaceStore {
    static let shared = PanelWorkspaceStore(layout: .shared)

    struct Workspace: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        var snapshot: IPadPanelLayout.LayoutSnapshot
    }

    private struct Archive: Codable {
        var workspaces: [Workspace]
        var activeId: String?
    }

    static let limit = 12
    private static let storageKey = "panel.workspaces.v1"

    private let layout: IPadPanelLayout
    private let defaults: UserDefaults
    private(set) var workspaces: [Workspace] = []
    private(set) var activeId: String?

    var active: Workspace? { workspaces.first { $0.id == activeId } }

    init(layout: IPadPanelLayout, defaults: UserDefaults = .standard) {
        self.layout = layout
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        workspaces = Array(archive.workspaces.prefix(Self.limit))
        activeId = workspaces.contains { $0.id == archive.activeId } ? archive.activeId : nil
    }

    /// 把此刻的布局存成一份并设为当前。同名覆盖；名字空 / 已满 12 份（且不是覆盖）返回 nil
    @discardableResult
    func saveCurrent(as name: String) -> Workspace? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let snapshot = layout.snapshot()
        if let i = workspaces.firstIndex(where: { $0.name == trimmed }) {
            workspaces[i].snapshot = snapshot
            activeId = workspaces[i].id
        } else {
            guard workspaces.count < Self.limit else { return nil }
            workspaces.append(Workspace(id: UUID().uuidString, name: trimmed, snapshot: snapshot))
            activeId = workspaces.last?.id
        }
        persist()
        return active
    }

    /// 用此刻的布局覆盖某一份
    func update(_ id: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].snapshot = layout.snapshot()
        persist()
    }

    func activate(_ id: String) {
        guard let w = workspaces.first(where: { $0.id == id }) else { return }
        activeId = id
        layout.apply(w.snapshot)
        persist()
    }

    /// 回到当前那份存的样子；没有当前的 = 恢复默认
    func resetActive() {
        if let active { layout.apply(active.snapshot) } else { restoreFactory() }
    }

    /// 恢复默认布局（开着的工具不关，全收回 tab 组）；不再属于任何一份
    func restoreFactory() {
        layout.apply(layout.factorySnapshot())
        activeId = nil
        persist()
    }

    func delete(_ id: String) {
        workspaces.removeAll { $0.id == id }
        if activeId == id { activeId = nil }
        persist()
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !workspaces.contains(where: { $0.name == trimmed && $0.id != id }),
              let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].name = trimmed
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Archive(workspaces: workspaces, activeId: activeId)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
