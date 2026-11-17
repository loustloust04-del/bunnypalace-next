#if os(iOS)
import MemoryCore
import SwiftUI

/// 设置 › Agent 里「自己醒来」那几段（plan-wake-heartbeat §5；旧的自主任务 / 楼层 / 预算 / 最近活动并到这里）
struct WakeSettingsSections: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var engine = WakeEngine.shared
    @State private var today: (runs: Int, usd: Double) = (0, 0)

    var body: some View {
        Section {
            Toggle("自己醒来", isOn: $engine.settings.enabled)
                .tint(Theme.branchIndicator)
        } footer: {
            Text("开了以后，AI 会按自己的任务到点醒来去做（早报、到点来找你），做完按任务的设定发到对话或只记在人页 heartbeat。任务在人页 › heartbeat 里看和改，也可以在聊天里让 TA 自己建。醒来只用你在权限里设成「自动允许」的工具。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }

        Section {
            Stepper("安静时段从 \(engine.settings.quietStart) 点", value: $engine.settings.quietStart, in: 0...23)
            Stepper("到 \(engine.settings.quietEnd) 点", value: $engine.settings.quietEnd, in: 0...23)
            Stepper("每天最多醒 \(engine.settings.dailyMax) 次", value: $engine.settings.dailyMax, in: 1...50)
            Stepper("每次最多 \(engine.settings.maxRounds) 轮", value: $engine.settings.maxRounds, in: 4...60, step: 2)
            Stepper(String(format: "每次最多花 $%.2f", engine.settings.maxUSD), value: $engine.settings.maxUSD, in: 0.1...5, step: 0.1)
        } header: {
            Text("护栏")
        } footer: {
            Text("安静时段里不醒，排在那时候的挪到安静时段结束；起止一样 = 不设。你 10 分钟内跟 TA 聊过就往后推 15 分钟。同一个任务连续失败 3 次会自动停。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }

        Section {
            HStack {
                Text("今天醒了")
                Spacer()
                Text("\(today.runs) 次 · \(String(format: "$%.3f", today.usd))")
                    .foregroundColor(Theme.textMuted)
            }
            if let next = engine.nextWakeDate {
                HStack {
                    Text("下次")
                    Spacer()
                    Text(WakeText.dateTime(next, tz: .current))
                        .foregroundColor(Theme.textMuted)
                }
            }
        } header: {
            Text("用量")
        }

        Section {
            if let profiles = profileManager?.profiles, !profiles.isEmpty {
                ForEach(profiles, id: \.id) { profile in
                    Toggle("\(profile.emoji) \(profile.name)", isOn: Binding(get: { engine.personEnabled(profile.id) },
                                                                             set: { engine.setPersonEnabled(profile.id, $0) }))
                        .tint(Theme.branchIndicator)
                }
            }
        } header: {
            Text("每个人")
        } footer: {
            Text("关掉的人到点也不醒；跟人页 heartbeat 顶上那个开关是同一个。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .task(id: engine.revision) { reloadToday() }
    }

    private func reloadToday() {
        let cal = Calendar.current
        var runs = 0
        var usd = 0.0
        for profile in profileManager?.profiles ?? [] {
            for run in engine.store(profileId: profile.id).runs(limit: 200) where cal.isDateInToday(run.startedAt) && run.status != .skipped {
                runs += 1
                usd += run.usd ?? 0
            }
        }
        today = (runs, usd)
    }
}
#endif
