import Foundation
import Observation

/// atrium（楼层之上的总页面，plan-atrium P1）开没开。挂在 App 层根视图 `.id(currentProfile.id)` 之外：
/// 切楼层整树重建时它得活着
@Observable
final class AtriumPresenter {
    var isPresented = false
    /// 收起动画走完再做的事：导入 sheet 挂在 ContentView 上，atrium 没退干净时同一个根控制器弹不出第二层
    @ObservationIgnored private var afterDismiss: (() -> Void)?

    func present() { isPresented = true }

    func dismiss(then action: (() -> Void)? = nil) {
        afterDismiss = action
        isPresented = false
    }

    func didDismiss() {
        let action = afterDismiss
        afterDismiss = nil
        action?()
    }
}

extension Notification.Name {
    /// 「换人」行（`ProfileSwitcher` iOS，设置 › 通用 / 卡库设置页）：开着设置的那一处（ContentView / atrium 里的「我」）先收设置 sheet，收完再开 atrium
    static let atriumRequestedFromSettings = Notification.Name("MemoryPalaceAtriumRequestedFromSettings")
}
