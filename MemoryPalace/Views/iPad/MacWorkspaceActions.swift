import SwiftUI

#if os(macOS)
/// One stable owner per main scene. Focused values carry this reference, never
/// a freshly captured ContentView closure on each render pass.
@Observable
@MainActor
final class MacWorkspaceActions {
    var isSearchPresented = false
    /// 已经开着时再按 ⌘K：面板据此重新聚焦并全选输入框（原型 openGlobalSearch 的行为）
    private(set) var searchFocusToken = 0
    /// 这次打开要预选的类型（code 组里按 ⌘K = `type:coding`）；空 = 不动面板现有筛选
    private(set) var searchPresetKinds: [MacSearchKind] = []
    func search(kinds: [MacSearchKind] = []) {
        searchPresetKinds = kinds
        isSearchPresented = true
        searchFocusToken += 1
    }
    func closeSearch() { isSearchPresented = false }
}
private struct MacWorkspaceActionsKey: FocusedValueKey {
    typealias Value = MacWorkspaceActions
}
extension FocusedValues {
    var macWorkspaceActions: MacWorkspaceActions? {
        get { self[MacWorkspaceActionsKey.self] }
        set { self[MacWorkspaceActionsKey.self] = newValue }
    }
}
#endif
