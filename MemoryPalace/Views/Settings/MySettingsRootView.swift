#if os(iOS)
import SwiftUI

/// atrium「我」（plan-atrium P2）：App 自己的设置。iOS 所有开设置的入口（atrium「我」、宽屏悬浮条 ⚙、SettingsJump）都开它。
/// 11-13 起和 page0 ⚙ 一样开完整设置（atrium 前的 pro / lite 根列表）
struct MySettingsRootView: View {
    var viewModel: ConversationViewModel? = nil

    var body: some View {
        SettingsView(viewModel: viewModel)
    }
}
#endif
