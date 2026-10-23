#if os(iOS)
import SwiftUI
import UIKit

/// 健康设置页（iOS-only）。连接苹果健康 + 全部健康开关（HealthGatesSections，粟粟 07-21 拍
/// "设置只留这一处"，面板 ⚙ 退役）+ 今日快照 + `{{health}}` 用法。
struct HealthSettingsTab: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var health = HealthService.shared
    @State private var isRequesting = false
    @State private var copied = false

    private let macroSnippet = "现在是 {{date}} {{time}}，{{health}}"

    var body: some View {
        List {
            connectSection
            HealthGatesSections(profileId: profileManager?.currentProfile.id ?? "")
            snapshotSection
            usageSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("健康")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await health.refreshToday() }
        .task { await health.refreshToday() }
    }

    // MARK: 连接

    private var connectSection: some View {
        Section {
            if !health.isAvailable {
                Text("此设备不支持健康数据")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                Button {
                    isRequesting = true
                    Task {
                        await health.requestAuthorization()
                        isRequesting = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "heart.text.square")
                            .foregroundColor(Theme.branchIndicator)
                        Text(health.authRequested ? "重新授权 / 刷新" : "连接苹果健康")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        if isRequesting { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)
            }
        } header: {
            Text("连接")
        } footer: {
            if health.isAvailable && health.authRequested {
                Text("在 系统设置 › 健康 › 数据访问 里可以随时改哪些数据允许读取。")
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: 今日快照

    private var snapshotSection: some View {
        Section {
            if let snap = health.snapshot, !snap.isEmpty {
                statRow("步数", snap.steps.map { "\($0)" })
                statRow("睡眠", snap.sleepHours.map { sleepText($0) })
                statRow("活动消耗", snap.activeEnergyKcal.map { "\($0) 千卡" })
                statRow("静息心率", snap.restingHeartRate.map { "\($0) 次/分" })
                if let w = snap.lastWorkout {
                    statRow("最近锻炼", "\(w.typeName) \(w.durationMinutes) 分钟")
                }
            } else {
                Text(health.isAvailable ? "暂无数据。授权后下拉刷新。" : "—")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            }
        } header: {
            Text("今日快照")
        }
        .listRowBackground(Theme.mainBg)
    }

    private func statRow(_ label: String, _ value: String?) -> some View {
        Group {
            if let value {
                HStack {
                    Text(label)
                        .font(.system(size: Theme.F.label))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Text(value)
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
            }
        }
    }

    private func sleepText(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return m > 0 ? "\(h) 小时 \(m) 分钟" : "\(h) 小时"
    }

    // MARK: 怎么用

    private var usageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("把下面的宏放进任意插槽（比如「用户描述」或「背景设定」），AI 就知道你此刻的状态：")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)

                HStack {
                    Text(macroSnippet)
                        .font(.system(size: Theme.F.body, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = macroSnippet
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: Theme.F.caption, weight: .medium))
                            .foregroundColor(Theme.branchIndicator)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))

                Text("`{{date}}` `{{time}}` 是当前日期时间，`{{health}}` 是今日健康摘要。可以单独用，也可以组合。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
        } header: {
            Text("怎么用")
        }
        .listRowBackground(Theme.mainBg)
    }
}
#endif
