#if os(macOS)
import AppKit
import SwiftUI

/// 菜单栏「工作区」的内容（plan-panel-ps 阶段 1）。放在 View 里而不是直接写在 `Commands`：
/// 菜单里的 View 会跟着 `PanelWorkspaceStore` 的观察刷新（勾选、禁用态）
struct PanelWorkspaceMenu: View {
    @State private var store = PanelWorkspaceStore.shared

    var body: some View {
        ForEach(store.workspaces) { w in
            Toggle(w.name, isOn: Binding(get: { store.activeId == w.id },
                                         set: { _ in PanelWorkspaceActions.activate(w.id) }))
        }
        if !store.workspaces.isEmpty { Divider() }
        Button("存为新工作区…") { PanelWorkspaceActions.saveAsNew() }
        Button(store.active.map { "更新「\($0.name)」" } ?? "更新当前工作区") {
            if let id = store.activeId { store.update(id) }
        }
        .disabled(store.active == nil)
        Button(store.active.map { "重置「\($0.name)」" } ?? "重置布局") { PanelWorkspaceActions.resetActive() }
        Button("恢复默认布局") { PanelWorkspaceActions.restoreFactory() }
        if let active = store.active {
            Divider()
            Button("重命名「\(active.name)」…") { PanelWorkspaceActions.rename(active.id) }
            Button("删除「\(active.name)」…") { PanelWorkspaceActions.delete(active.id) }
        }
    }
}

/// 菜单栏和 dock「面板布局」钮共用的动作：带动画地换布局 + 需要输入 / 确认的走 NSAlert
@MainActor
enum PanelWorkspaceActions {
    private static var store: PanelWorkspaceStore { .shared }

    static func activate(_ id: String) {
        withAnimation(ShellStyle.structure) { store.activate(id) }
    }

    static func resetActive() {
        withAnimation(ShellStyle.structure) { store.resetActive() }
    }

    static func restoreFactory() {
        withAnimation(ShellStyle.structure) { store.restoreFactory() }
    }

    static func saveAsNew() {
        guard let name = ask(title: "存为新工作区", message: "当前的面板布局会存成这个名字；同名的会被覆盖。",
                             confirm: "存储", initial: "") else { return }
        if store.saveCurrent(as: name) == nil {
            inform("没有存上", "名字不能为空；最多存 \(PanelWorkspaceStore.limit) 份，满了要先删掉一份。")
        }
    }

    static func rename(_ id: String) {
        guard let w = store.workspaces.first(where: { $0.id == id }),
              let name = ask(title: "重命名工作区", message: "", confirm: "重命名", initial: w.name) else { return }
        store.rename(id, to: name)
    }

    static func delete(_ id: String) {
        guard let w = store.workspaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "删除工作区「\(w.name)」？"
        alert.informativeText = "只删这份存档，当前的布局不变。"
        let cancel = alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        cancel.keyEquivalent = "\r"
        if alert.runModal() == .alertSecondButtonReturn { store.delete(id) }
    }

    private static func ask(title: String, message: String, confirm: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func inform(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
#endif
