#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI
import SwiftData

/// Care · 护理仪表盘（控制台 CARE 区点开）。
/// 今日饮水/进食/药物/睡眠环形进度 + 经期周期环 + 近 7 天饮水/睡眠趋势。
/// 只读汇总视图。药物/经期读本地 SwiftData（与主页 CARE 卡、健康面板同源）；饮水/进食本地优先、网关 vitals 只兜底目标值。
struct CareView: View {
    let contexts: [DailyContext]        // 倒序（最新在前）
    let vitals: VitalsResponse?
    let period: PeriodClient.Prediction?  // 已不用于渲染（经期改读本地预测）；留参免动调用方

    @Query private var localMeds: [Medication]
    @Query private var localMedLogs: [MedicationLog]
    @Query(sort: \CycleDay.date, order: .reverse) private var localCycleDays: [CycleDay]

    @Environment(\.dismiss) private var dismiss

    private var today: DailyContext? {
        contexts.first { Calendar.current.isDate($0.date, inSameDayAs: Date()) }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    ringsCard
                    if let c = localCycle { cycleCard(c) }
                    trendsCard
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("护理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
    }

    // MARK: - 今日环

    private var ringsCard: some View {
        let t = today
        let waterVal = Double(vitals?.water.count ?? t?.waterCount ?? 0)   // 网关唯一真相
        let waterGoal = Double(vitals?.water.goal ?? 6)
        let foodVal = Double(max(t?.meals.count ?? 0, vitals?.food.count ?? 0))   // max 创可贴，跟主页同口径（正解=双向同步，DEBT-MAP）
        let foodGoal = Double(vitals?.food.goal ?? 3)
        let (medsTakenCount, medsTotal) = localMedProgress                // 本地 SwiftData，跟主页/健康面板同源
        let sleepVal = t?.sleepDuration ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            Text("今日照顾")
                .font(.system(size: 13, weight: .semibold)).tracking(0.5)
                .foregroundColor(ConsoleView.textSub)
            HStack(spacing: 8) {
                ring("饮水", "\(Int(waterVal))/\(Int(waterGoal))", waterVal / max(waterGoal, 1), ConsoleView.green, "drop.fill")
                ring("进食", "\(Int(foodVal))/\(Int(foodGoal))", foodVal / max(foodGoal, 1), ConsoleView.green, "fork.knife")
                ring("药物",
                     medsTotal > 0 ? "\(medsTakenCount)/\(medsTotal)" : "未服",
                     medsTotal > 0 ? Double(medsTakenCount) / Double(medsTotal) : 0,
                     medsTotal > 0 && medsTakenCount == medsTotal ? ConsoleView.green : ConsoleView.gold,
                     "pills.fill")
                ring("睡眠", sleepText(sleepVal), min(sleepVal / 8, 1), ConsoleView.greenDeep, "moon.fill")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func ring(_ label: String, _ center: String, _ pct: Double, _ color: Color, _ icon: String) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(ConsoleView.sink, lineWidth: 6)
                Circle().trim(from: 0, to: max(0, min(1, pct)))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(color)
            }
            .frame(width: 54, height: 54)
            Text(center).font(.system(size: 11.5, weight: .semibold)).foregroundColor(ConsoleView.textPrimary)
            Text(label).font(.system(size: 10.5)).foregroundColor(ConsoleView.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 经期周期环

    /// 本地经期状态（HealthCycleStore，跟主页 LOG 卡、健康面板同源）
    private struct LocalCycleInfo {
        let day: Int?
        let line: String
        let avgCycle: Int?
    }

    private var localCycle: LocalCycleInfo? {
        let periods = HealthCycleStore.periods(days: localCycleDays)
        guard !periods.isEmpty else { return nil }
        let now = Date()
        let day = HealthCycleStore.currentCycleDay(periods: periods, now: now)
        let todayFlow = localCycleDays.first { Calendar.current.isDateInToday($0.date) }.flatMap { CycleFlow(rawValue: $0.flow) }
        let line = HealthCycleStore.statusLine(todayFlow: todayFlow, periods: periods, now: now)
        let pred = HealthCycleStore.prediction(periods: periods)
        return LocalCycleInfo(day: day, line: line, avgCycle: pred?.averageLength)
    }

    /// 本地药物今日进度：(已服, 总计)（跟主页 CARE 卡同款算法）
    private var localMedProgress: (Int, Int) {
        let now = Date()
        let todayLogs = localMedLogs.filter { Calendar.current.isDateInToday($0.takenAt) }
        var total = 0, taken = 0
        for med in localMeds where !med.isArchived {
            for slot in med.timesOfDay {
                total += 1
                if case .taken = HealthLogStore.medState(medication: med, minuteOfDay: slot, todayLogs: todayLogs, now: now) {
                    taken += 1
                }
            }
        }
        return (taken, total)
    }

    private func cycleCard(_ c: LocalCycleInfo) -> some View {
        let day = c.day ?? 0
        let avg = c.avgCycle ?? 0
        let pct = avg > 0 ? min(1, Double(day) / Double(avg)) : 0
        return HStack(spacing: 16) {
            ZStack {
                Circle().stroke(ConsoleView.sink, lineWidth: 7)
                Circle().trim(from: 0, to: pct)
                    .stroke(ConsoleView.gold, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(day)").font(.system(size: 21, weight: .semibold)).foregroundColor(ConsoleView.textPrimary)
                    Text("天").font(.system(size: 10)).foregroundColor(ConsoleView.textMuted)
                }
            }
            .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 5) {
                Text("经期周期").font(.system(size: 14, weight: .medium)).foregroundColor(ConsoleView.textPrimary)
                Text(c.line).font(.system(size: 12.5, weight: .medium)).foregroundColor(ConsoleView.greenDeep)
                if let avg = c.avgCycle {
                    Text("平均周期 \(avg) 天").font(.system(size: 11)).foregroundColor(ConsoleView.textFaint)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    // MARK: - 近 7 天趋势

    private var trendsCard: some View {
        let last7 = Array(contexts.prefix(7).reversed())
        return VStack(alignment: .leading, spacing: 16) {
            Text("近 7 天")
                .font(.system(size: 13, weight: .semibold)).tracking(0.5)
                .foregroundColor(ConsoleView.textSub)
            trendBars("饮水（杯）", last7.map { Double($0.waterCount) }, last7.map { dayLabel($0.date) },
                      ConsoleView.green, goal: Double(vitals?.water.goal ?? 6))
            trendBars("睡眠（小时）", last7.map { $0.sleepDuration ?? 0 }, last7.map { dayLabel($0.date) },
                      ConsoleView.greenDeep, goal: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func trendBars(_ title: String, _ values: [Double], _ labels: [String], _ color: Color, goal: Double) -> some View {
        let maxV = max(values.max() ?? 1, goal, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(ConsoleView.textSub)
            if values.isEmpty {
                Text("暂无历史").font(.system(size: 12)).foregroundColor(ConsoleView.textFaint).padding(.vertical, 12)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(values.indices, id: \.self) { i in
                        VStack(spacing: 4) {
                            Text(values[i] > 0 ? trimNum(values[i]) : " ")
                                .font(.system(size: 8.5)).foregroundColor(ConsoleView.textFaint)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color.opacity(values[i] > 0 ? 0.85 : 0.18))
                                .frame(height: CGFloat(values[i] / maxV) * 66 + 3)
                            Text(i < labels.count ? labels[i] : "").font(.system(size: 8.5)).foregroundColor(ConsoleView.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 96)
            }
        }
    }

    // MARK: - helpers

    private func sleepText(_ h: Double) -> String {
        guard h > 0 else { return "—" }
        let hh = Int(h), mm = Int((h - Double(hh)) * 60)
        return mm > 0 ? "\(hh)h\(mm)" : "\(hh)h"
    }
    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M.d"; return f.string(from: d)
    }
    private func trimNum(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
#endif
