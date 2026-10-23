import SwiftUI
import SwiftData

/// 健康设置区块（AI 可见 / 亲密 / 单位 / 预览），设置-健康页双端共用。
/// 粟粟 07-21 拍"不要面板单独设置页"——原面板 ⚙ HealthGatesSheet 内容挪家至此，⚙ 退役。
/// 字号走 `settingsMetrics`（plan-settings-merge 刀 2）；剩下的 `#if` 是 HealthService 生命周期（第 3 类）、
/// 苹果健康行（第 2 类）、mac 自画右对齐 Picker（第 5 类）。
struct HealthGatesSections: View {
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    #if os(iOS)
    @State private var health = HealthService.shared
    #endif

    @State private var tick = 0

    private var intimacyShow: Binding<Bool> {
        Binding(
            get: { HealthLogStore.showIntimacyCard },
            set: { HealthLogStore.showIntimacyCard = $0; tick += 1 }
        )
    }

    /// 三档行（plan-权限管理 T7）：label 保留宏展开，右侧换档位下拉，写入走 PermissionCenter。
    @ViewBuilder private func permRow(_ label: String, domain: PermissionDomain) -> some View {
        HStack {
            Text(label.expandingMacros(profile: profileManager?.currentProfile))
                .font(m.body)
            Spacer(minLength: 8)
            PermissionLevelPicker(domain: domain)
        }
    }

    private var unitBinding: Binding<WeightUnit> {
        Binding(
            get: { WeightUnit.current },
            set: { UserDefaults.standard.set($0.rawValue, forKey: WeightUnit.storageKey); tick += 1 }
        )
    }

    var body: some View {
        #if os(iOS)
        @Bindable var health = health
        #endif

        Group {
            Section {
                #if os(iOS)
                permRow("聊天时让{{char}}知道我的健康", domain: .healthApple)
                #endif
                permRow("聊天时让{{char}}看到体重", domain: .healthWeight)
                permRow("聊天时让{{char}}看到吃药情况", domain: .healthMeds)
                permRow("聊天时让{{char}}看到月经周期", domain: .healthCycle)
            } header: {
                Text("AI 可见")
            } footer: {
                Text("开着的部分会并进 `{{health}}` 宏，随对话发送给你配置的 AI 服务。")
            }
            .listRowBackground(Theme.mainBg)

            Section {
                Toggle(isOn: intimacyShow) {
                    Text("显示亲密卡")
                        .font(m.body)
                }
                .tint(Theme.branchIndicator)
                if intimacyShow.wrappedValue {
                    permRow("聊天时让{{char}}看到亲密记录", domain: .healthIntimacy)
                }
            } header: {
                Text("亲密")
            } footer: {
                Text("亲密记录只出现在自己的卡里，日历和最近流水都不显示。")
            }
            .listRowBackground(Theme.mainBg)

            Section("单位") {
                #if os(macOS)
                // 行左标题、行右控件（J2b 第 5 条），跟同页 permRow 对齐
                HStack {
                    Text("体重单位")
                        .font(m.body)
                    Spacer(minLength: 8)
                    Picker("", selection: unitBinding) {
                        ForEach(WeightUnit.allCases, id: \.self) { u in
                            Text(u.label).tag(u)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                #else
                Picker("体重单位", selection: unitBinding) {
                    ForEach(WeightUnit.allCases, id: \.self) { u in
                        Text(u.label).tag(u)
                    }
                }
                .font(.system(size: Theme.F.body))
                .pickerStyle(.menu)
                #endif
            }
            .listRowBackground(Theme.mainBg)

            Section("AI 会看到") {
                let preview = previewText
                Text(preview.isEmpty ? "（现在是空的——没有数据或开关全关）" : preview)
                    .font(m.caption)
                    .foregroundColor(preview.isEmpty ? Theme.textMuted : Theme.textSecondary)
            }
            .listRowBackground(Theme.mainBg)
        }
    }

    /// 与实发同源（composedHealthSummary），不是另写的近似。
    private var previewText: String {
        _ = tick
        return HealthLogStore.composedHealthSummary(context: modelContext, profileId: profileId)
    }
}
