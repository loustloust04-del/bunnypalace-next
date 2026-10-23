#if PERSONAL_APPS
#if os(iOS)
import SwiftUI

/// 交易设置页（iOS-only 壳，区块双端共用 TradingGatesSections）。
struct TradingSettingsTab: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    var body: some View {
        List {
            TradingGatesSections(profileId: profileManager?.currentProfile.id ?? "")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("交易")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
#endif
