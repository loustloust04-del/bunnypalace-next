#if os(iOS)
import SwiftUI

/// atrium「我」（plan-atrium P2）：App 自己的设置。iOS 所有开设置的入口（atrium「我」、宽屏悬浮条 ⚙、SettingsJump）都开它。
/// 行和路由复用 `SettingsView`：根列表只列 App 自己的，搜索 / 跳转照旧能到每一页
struct MySettingsRootView: View {
    var viewModel: ConversationViewModel? = nil

    var body: some View {
        SettingsView(viewModel: viewModel)
    }
}
#endif
