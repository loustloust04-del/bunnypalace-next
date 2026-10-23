#if PERSONAL_APPS
import SwiftUI
import SwiftData

/// 交易设置区块（AI 可见闸 + 预览 + 用法），设置-交易页双端共用（HealthGatesSections 同构）。
/// 字号走 `settingsMetrics`（plan-settings-merge 刀 2）；只剩 mac 自画右对齐 Picker（§2.4 第 5 类）
/// 与剪贴板 API（第 4 类）两处 `#if`。
struct TradingGatesSections: View {
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m

    @State private var tick = 0
    @State private var copied = false

    private var nightlyEnabled: Binding<Bool> {
        Binding(
            get: { TradingStore.nightlyEnabled },
            set: { TradingStore.nightlyEnabled = $0; nightlyChanged() }
        )
    }
    private var nightlyFreshDays: Binding<Int> {
        Binding(
            get: { TradingStore.nightlyFreshDays },
            set: { TradingStore.nightlyFreshDays = $0; nightlyChanged() }
        )
    }
    private var nightlyMaxPerNight: Binding<Int> {
        Binding(
            get: { TradingStore.nightlyMaxPerNight },
            set: { TradingStore.nightlyMaxPerNight = $0; nightlyChanged() }
        )
    }

    /// 参数变化即上报 hub（app 是真相源）。
    private func nightlyChanged() {
        tick += 1
        TradingStore.reportWatchlist(context: modelContext, profileId: profileId)
    }

    var body: some View {
        Group {
            Section {
                HStack {
                    Text("聊天时让{{char}}看到关注自选".expandingMacros(profile: profileManager?.currentProfile))
                        .font(m.body)
                Spacer(minLength: 8)
                PermissionLevelPicker(domain: .trading)
            }
            } header: {
                Text("AI 可见")
            } footer: {
                Text("开着时关注列表和最新研报评级会并进 `{{trading}}` 宏，随对话发送给你配置的 AI 服务。")
            }
            .listRowBackground(Theme.mainBg)

            Section {
                Toggle(isOn: nightlyEnabled) {
                    Text("自动研究关注列表")
                        .font(m.body)
                }
                .tint(Theme.branchIndicator)
                if nightlyEnabled.wrappedValue {
                    #if os(macOS)
                    // 行左标题、行右控件（J2b 第 5 条），跟同页开关行对齐
                    HStack {
                        Text("同一标的间隔")
                            .font(m.body)
                        Spacer(minLength: 8)
                        Picker("", selection: nightlyFreshDays) {
                            Text("3 天").tag(3)
                            Text("7 天").tag(7)
                            Text("14 天").tag(14)
                            Text("30 天").tag(30)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .tint(Theme.branchIndicator)   // 配色铁律：不要系统蓝
                    }
                    HStack {
                        Text("每晚最多")
                            .font(m.body)
                        Spacer(minLength: 8)
                        Picker("", selection: nightlyMaxPerNight) {
                            Text("1 只").tag(1)
                            Text("2 只").tag(2)
                            Text("3 只").tag(3)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .tint(Theme.branchIndicator)
                    }
                    #else
                    Picker("同一标的间隔", selection: nightlyFreshDays) {
                        Text("3 天").tag(3)
                        Text("7 天").tag(7)
                        Text("14 天").tag(14)
                        Text("30 天").tag(30)
                    }
                    .font(.system(size: Theme.F.body))
                    .pickerStyle(.menu)
                    .tint(Theme.branchIndicator)   // 配色铁律：不要系统蓝
                    Picker("每晚最多", selection: nightlyMaxPerNight) {
                        Text("1 只").tag(1)
                        Text("2 只").tag(2)
                        Text("3 只").tag(3)
                    }
                    .font(.system(size: Theme.F.body))
                    .pickerStyle(.menu)
                    .tint(Theme.branchIndicator)
                    #endif
                }
            } header: {
                Text("夜跑")
            } footer: {
                Text("开着时每个交易日盘后自动研究关注列表里到期的标的：已有报告的做增量复核（论点没被新数据推翻就只出一份短更新），到点或被推翻才重跑全量。")
            }
            .listRowBackground(Theme.mainBg)

            Section("AI 会看到") {
                let preview = previewText
                Text(preview.isEmpty ? "（现在是空的——没有关注标的或开关关着）" : preview)
                    .font(m.caption)
                    .foregroundColor(preview.isEmpty ? Theme.textMuted : Theme.textSecondary)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                HStack {
                    Text("现在是 {{date}} {{time}}，{{trading}}")
                        .font(m.caption.monospaced())
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button {
                        copyMacroSnippet()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(copied ? Theme.branchIndicator : Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("怎么用")
            } footer: {
                Text("把 `{{trading}}` 写进任意预设插槽（比如主提示词），发送时替换成上面的内容。")
            }
            .listRowBackground(Theme.mainBg)
        }
    }

    /// 与实发同源（composedTradingSummary），不是另写的近似。
    private var previewText: String {
        _ = tick
        return TradingStore.composedTradingSummary(context: modelContext, profileId: profileId)
    }

    private func copyMacroSnippet() {
        let snippet = "现在是 {{date}} {{time}}，{{trading}}"
        #if os(iOS)
        UIPasteboard.general.string = snippet
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
#endif
