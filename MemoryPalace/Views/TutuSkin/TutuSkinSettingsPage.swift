#if PERSONAL_APPS
#if os(iOS)
import SwiftUI

struct TutuSkinSettingsPage: View {
    @Bindable private var state = SkinState.shared
    @State private var showResetConfirmation = false

    var body: some View {
        List {
            Section {
                Toggle("兔兔皮肤", isOn: $state.enabled)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                Picker("时段", selection: $state.timeOfDay) {
                    ForEach(SkinState.TimeOfDay.allCases) { time in
                        Text(time.title).tag(time)
                    }
                }
                Picker("page0 列表", selection: $state.page0Style) {
                    ForEach(SkinState.Page0Style.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("声音", isOn: $state.sound)
                Toggle("摇晃会裂", isOn: $state.crackOnShake)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                Button("重看解锁动画") { TutuSkinUnlock.post() }
                Button("重置", role: .destructive) { showResetConfirmation = true }
            } footer: {
                Text("重置会合上丝绒并恢复时段、声音和冰裂纹设置，保留解锁、总开关和 page0 列表样式，不改变原主题。")
            }
            .listRowBackground(Theme.mainBg)

            Section {
                HStack {
                    Text("开屏")
                    Spacer()
                    Text("还没做")
                }
                .foregroundStyle(Theme.textMuted)
                .disabled(true)
            }
            .listRowBackground(Theme.mainBg)
        }
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("caelumbunny")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("重置兔兔皮肤设置？", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("重置", role: .destructive) { state.reset() }
            Button("取消", role: .cancel) { }
        }
    }
}
#endif
#endif
