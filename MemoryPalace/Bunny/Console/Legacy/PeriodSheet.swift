#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI

/// 经期管理页 — 控制台经期卡点开进入。
/// 数据直连网关 /api/period（与 Caelum 的 period 工具 / 每日关心同一份）。
/// 打卡：来潮 / 结束 / 补录；显示周期预测（还有几天、所处阶段、排卵窗）。
struct PeriodSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snap: PeriodClient.Snapshot?
    @State private var loading = true
    @State private var busy = false
    @State private var backfillDate = Date()
    @State private var showBackfill = false
    @State private var healthKit = HealthKitService()
    @State private var syncMsg: String? = nil

    private var ymd: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }
    private var todayYMD: String { ymd.string(from: Date()) }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    if loading {
                        ProgressView().padding(.vertical, 44)
                    } else {
                        predictionCard
                        actionCard
                        historyCard
                    }
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("经期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        await PeriodClient.fetchCached { s, _ in snap = s }
        loading = false
    }

    // MARK: - 预测卡

    private var predictionCard: some View {
        let p = snap?.prediction
        return VStack(alignment: .leading, spacing: 12) {
            if let p, p.hasData {
                let head = headline(p)
                Text(head.0)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(head.1)
                if let next = p.nextDate {
                    infoRow("下次预计", next)
                }
                infoRow("当前阶段", p.phase)
                infoRow("平均周期", "\(p.avgCycle) 天")
                if let ov = p.ovulationDate {
                    let win = (p.fertileStart != nil && p.fertileEnd != nil) ? "（易孕 \(p.fertileStart!)~\(p.fertileEnd!)）" : ""
                    infoRow("排卵日", ov + win)
                }
                if let last = p.lastStart {
                    infoRow("上次来潮", last)
                }
            } else {
                Text("还没有经期记录")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(ConsoleView.textPrimary)
                Text("点下面「记录来潮」开始；\n如果你在 Apple 健康里记了经期，回到控制台会自动同步。")
                    .font(.system(size: 13))
                    .foregroundColor(ConsoleView.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func headline(_ p: PeriodClient.Prediction) -> (String, Color) {
        if p.onPeriod, let d = p.currentCycleDay {
            return ("经期中 · 第 \(d) 天", ConsoleView.gold)
        }
        if let du = p.daysUntil {
            if du < 0 { return ("已推迟 \(-du) 天", ConsoleView.gold) }
            if du == 0 { return ("预计今天来潮", ConsoleView.gold) }
            return ("预计还有 \(du) 天", ConsoleView.greenDeep)
        }
        return (p.phase, ConsoleView.greenDeep)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundColor(ConsoleView.textMuted)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium)).foregroundColor(ConsoleView.textSub)
        }
    }

    // MARK: - 打卡

    private var actionCard: some View {
        VStack(spacing: 10) {
            actionButton(title: "从 Apple 健康同步", icon: "heart.text.square.fill", filled: false) {
                Task { await syncHealthKit() }
            }
            if let msg = syncMsg {
                Text(msg)
                    .font(.system(size: 12)).foregroundColor(ConsoleView.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionButton(title: "记录来潮 · 今天", icon: "drop.fill", filled: true) {
                Task { await act { _ = await PeriodClient.logStart() } }
            }
            actionButton(title: "经期结束 · 今天", icon: "checkmark.circle", filled: false) {
                Task { await act { _ = await PeriodClient.logEnd(end: todayYMD) } }
            }
            Button { withAnimation { showBackfill.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus").font(.system(size: 13))
                    Text("补录其他日期的来潮").font(.system(size: 13.5))
                    Spacer()
                    Image(systemName: showBackfill ? "chevron.up" : "chevron.down").font(.system(size: 11))
                }
                .foregroundColor(ConsoleView.textSub)
            }
            .buttonStyle(.plain)
            if showBackfill {
                DatePicker("来潮日", selection: $backfillDate, in: ...Date(), displayedComponents: .date)
                    .font(.system(size: 14)).tint(ConsoleView.greenDeep)
                actionButton(title: "补录这一天", icon: "plus", filled: true) {
                    Task { await act { _ = await PeriodClient.logStart(date: ymd.string(from: backfillDate)) }; showBackfill = false }
                }
            }
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func actionButton(title: String, icon: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Spacer()
                if busy { ProgressView().tint(filled ? .white : ConsoleView.greenDeep) }
                else { Image(systemName: icon).font(.system(size: 14)) }
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.vertical, 12)
            .foregroundColor(filled ? .white : ConsoleView.greenDeep)
            .background(RoundedRectangle(cornerRadius: 12).fill(filled ? ConsoleView.greenDeep : ConsoleView.sink))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func syncHealthKit() async {
        busy = true
        await healthKit.requestAuthorization()
        let starts = await healthKit.fetchMenstrualStarts()
        if starts.isEmpty {
            syncMsg = "Apple 健康里没读到经期记录——去「设置→隐私与安全性→健康→Lost in Blossom」确认「经期」读取是开的"
        } else {
            let added = await PeriodClient.sync(dates: starts)
            syncMsg = added > 0 ? "从 Apple 健康同步了 \(added) 次来潮 🩸" : "已是最新（Apple 健康里 \(starts.count) 次都同步过了）"
        }
        await reload()
        busy = false
    }

    private func act(_ op: @escaping () async -> Void) async {
        busy = true
        await op()
        await reload()
        busy = false
    }

    // MARK: - 历史

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("历史记录")
                .font(.system(size: 11.5, weight: .medium)).tracking(0.5)
                .foregroundColor(ConsoleView.textSub)
            let events = (snap?.events ?? []).reversed()
            if events.isEmpty {
                Text("暂无记录")
                    .font(.system(size: 13)).foregroundColor(ConsoleView.textFaint)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(events)) { ev in
                    HStack(spacing: 10) {
                        Image(systemName: "drop.fill").font(.system(size: 12)).foregroundColor(ConsoleView.gold).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ev.date).font(.system(size: 14, weight: .medium)).foregroundColor(ConsoleView.textPrimary)
                            if let end = ev.end {
                                Text("至 \(end)").font(.system(size: 11)).foregroundColor(ConsoleView.textMuted)
                            }
                        }
                        Spacer()
                        if let src = ev.source {
                            Text(sourceLabel(src)).font(.system(size: 10.5)).foregroundColor(ConsoleView.textFaint)
                        }
                        Button {
                            Task { _ = await PeriodClient.remove(date: ev.date); await reload() }
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundColor(ConsoleView.textFaint)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "healthkit": return "Apple 健康"
        case "caelum":    return "Caelum"
        case "bunny":     return "手动"
        default:          return s
        }
    }
}
#endif
