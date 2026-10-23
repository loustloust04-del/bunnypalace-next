#if os(iOS)
import SwiftUI

/// 应用内部的「上一层」（plan-page2-app-shell §2.5）：有内部层级的应用把能不能退、怎么退登记进来。
/// `canGoBack` 要可观察，导航钮才能跟着亮/灰；动作本身不参与观察。
@MainActor
@Observable
final class Page2AppBackRegistry {
    static let shared = Page2AppBackRegistry()
    private var backable: [String: Bool] = [:]
    @ObservationIgnored private var actions: [String: () -> Void] = [:]

    func update(_ id: String, canGoBack: Bool, goBack: @escaping () -> Void) {
        if backable[id] != canGoBack { backable[id] = canGoBack }
        actions[id] = goBack
    }

    func canGoBack(_ id: String) -> Bool { backable[id] ?? false }

    func goBack(_ id: String) {
        guard canGoBack(id) else { return }
        actions[id]?()
    }
}

#endif
