import SwiftUI
import SwiftData
import Charts

// MARK: - 健康卡详情统计页（plan-health-card-details）
// 四卡整卡可点进各自 sheet：吃药热图/依从率、月经周日历条+周期历史、体重长时间轴、亲密月历点阵。
// 参考 docs/design-refs/health-details（ref2 周日历条=粟粟红圈拍板）。

private let healthRose = Color(red: 0xC9 / 255.0, green: 0x8A / 255.0, blue: 0x8A / 255.0)

enum HealthDetail: String, Identifiable {
    case meds, cycle, weight, intimacy
    var id: String { rawValue }
}

private func flowOpacity(_ f: CycleFlow) -> Double {
    switch f {
    case .spotting: return 0.35
    case .light: return 0.55
    case .medium: return 0.8
    case .heavy: return 1.0
    }
}

/// 周名（按系统 firstWeekday 旋转，中文单字）。
private func weekdaySymbols(_ calendar: Calendar) -> [String] {
    let base = ["日", "一", "二", "三", "四", "五", "六"]
    let shift = calendar.firstWeekday - 1
    return Array(base[shift...] + base[..<shift])
}

/// 四 sheet 共用壳。
private struct DetailShell<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List { content }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 560)
        #endif
    }
}

// MARK: - 吃药详情

struct MedDetailSheet: View {
    let profileId: String
    @Environment(\.modelContext) private var modelContext

    @Query private var meds: [Medication]
    @Query private var logs: [MedicationLog]
    @State private var monthOffset = 0

    init(profileId: String) {
        self.profileId = profileId
        _meds = Query(
            filter: #Predicate<Medication> { $0.profileId == profileId && !$0.isArchived },
            sort: \Medication.createdAt
        )
        _logs = Query(filter: #Predicate<MedicationLog> { $0.profileId == profileId })
    }

    private var month: Date {
        Calendar.current.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }

    var body: some View {
        DetailShell(title: "吃药") {
            Section {
                MonthGrid(month: month, monthOffset: $monthOffset) { day in
                    medDayCell(day)
                }
            } header: {
                Text("打卡热图")
            } footer: {
                Text("只算计划内的时刻，计划外补服不计。")
            }
            .listRowBackground(Theme.mainBg)

            adherenceSection
            missSection
        }
    }

    private var completion: [Date: Double] {
        HealthStatsStore.medMonthCompletion(meds: meds, logs: logs, month: month, now: Date())
    }

    @ViewBuilder
    private func medDayCell(_ day: Date) -> some View {
        let c = completion[day]
        RoundedRectangle(cornerRadius: 6)
            .fill(cellColor(c))
            .frame(height: 28)
            .overlay(
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 10))
                    .foregroundColor(c == nil ? Theme.textMuted : (c! >= 1.0 ? .white : Theme.textSecondary))
            )
    }

    private func cellColor(_ c: Double?) -> Color {
        guard let c else { return Theme.sidebarBg }
        if c >= 1.0 { return Theme.branchIndicator }
        if c > 0 { return Theme.branchIndicator.opacity(0.35) }
        return healthRose.opacity(0.3)
    }

    private var adherenceSection: some View {
        Section("近 30 天依从率") {
            if meds.isEmpty {
                Text("还没有药。")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(meds) { med in
                    let rate = HealthStatsStore.medAdherence(med: med, logs: logs, days: 30, now: Date())
                    HStack(spacing: 10) {
                        Text(med.name)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        ProgressView(value: rate ?? 0)
                            .tint(Theme.branchIndicator)
                        Text(rate == nil ? "—" : "\(Int((rate! * 100).rounded()))%")
                            .font(.system(size: Theme.F.secondary, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    private var missSection: some View {
        let missed = meds
            .map { (med: $0, count: HealthStatsStore.medMissCount(med: $0, logs: logs, days: 30, now: Date())) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
        return Group {
            if !missed.isEmpty {
                Section("近 30 天漏服") {
                    ForEach(missed, id: \.med.id) { item in
                        HStack {
                            Text(item.med.name)
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text("\(item.count) 次")
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(healthRose)
                        }
                    }
                }
                .listRowBackground(Theme.mainBg)
            }
        }
    }
}

// MARK: - 月经详情

struct CycleDetailSheet: View {
    let profileId: String
    @Environment(\.modelContext) private var modelContext

    @Query private var days: [CycleDay]
    @State private var weekOffset = 0
    @State private var editingDay: Date? = nil

    init(profileId: String) {
        self.profileId = profileId
        _days = Query(
            filter: #Predicate<CycleDay> { $0.profileId == profileId },
            sort: \CycleDay.date, order: .reverse
        )
    }

    private var periods: [CyclePeriod] { HealthCycleStore.periods(days: days) }
    private var flowByDay: [Date: CycleFlow] {
        Dictionary(uniqueKeysWithValues: days.compactMap { d in
            CycleFlow(rawValue: d.flow).map { (Calendar.current.startOfDay(for: d.date), $0) }
        })
    }

    var body: some View {
        DetailShell(title: "月经") {
            weekStripSection
            historySection
            lengthChartSection
            predictionSection
        }
    }

    // 周日历条（ref2 红圈形态：一行七天胶囊，可翻周，点某天改档/补记）
    private var weekStripSection: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.dateInterval(of: .weekOfYear, for: cal.date(byAdding: .weekOfYear, value: weekOffset, to: today) ?? today)?.start ?? today
        let weekDays = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        let symbols = weekdaySymbols(cal)
        let pred = HealthCycleStore.prediction(periods: periods)

        return Section {
            HStack(spacing: 6) {
                ForEach(Array(weekDays.enumerated()), id: \.element) { idx, day in
                    weekCapsule(day: day, symbol: symbols[idx], today: today, pred: pred)
                }
            }
            .padding(.vertical, 4)
            HStack {
                Button { weekOffset -= 1 } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(weekTitle(weekDays: weekDays))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button { weekOffset += 1 } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(weekOffset >= 0 ? Theme.textMuted.opacity(0.4) : Theme.textSecondary)
                .disabled(weekOffset >= 0)
            }
        } header: {
            Text("周历")
        } footer: {
            Text("点某天可以补记或改档。")
        }
        .listRowBackground(Theme.mainBg)
        .confirmationDialog("这天的经量", isPresented: Binding(get: { editingDay != nil }, set: { if !$0 { editingDay = nil } }), titleVisibility: .visible) {
            if let day = editingDay {
                ForEach(CycleFlow.allCases, id: \.self) { flow in
                    Button(flow.label) {
                        HealthCycleStore.upsertDay(context: modelContext, profileId: profileId, date: day, flow: flow)
                    }
                }
                if flowByDay[day] != nil {
                    Button("取消打点", role: .destructive) {
                        HealthCycleStore.removeDay(context: modelContext, profileId: profileId, date: day)
                    }
                }
                Button("关闭", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func weekCapsule(day: Date, symbol: String, today: Date, pred: CyclePrediction?) -> some View {
        let flow = flowByDay[day]
        let isFuture = day > today
        let isToday = day == today
        let predicted = flow == nil && pred.map { day >= $0.windowStart && day <= $0.windowEnd && day > today } ?? false

        VStack(spacing: 3) {
            Text(symbol)
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: Theme.F.secondary, weight: isToday ? .semibold : .regular))
                .foregroundColor(flow != nil ? .white : (isFuture ? Theme.textMuted.opacity(0.5) : Theme.textPrimary))
            Circle()
                .fill(predicted ? healthRose.opacity(0.45) : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(flow.map { healthRose.opacity(flowOpacity($0)) } ?? Theme.sidebarBg)
        )
        .overlay(
            Capsule().stroke(isToday ? Theme.branchIndicator : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Capsule())
        .onTapGesture {
            guard !isFuture else { return }
            editingDay = day
        }
    }

    private func weekTitle(weekDays: [Date]) -> String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日"
        return "\(f.string(from: first)) – \(f.string(from: last))"
    }

    private var historySection: some View {
        Section("周期历史") {
            if periods.isEmpty {
                Text("还没有记录。")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(Array(periods.reversed().prefix(12).enumerated()), id: \.offset) { _, period in
                    periodRow(period)
                }
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    private func periodRow(_ period: CyclePeriod) -> some View {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日"
        let dayDots: [CycleFlow?] = (0..<period.dayCount).map { offset in
            cal.date(byAdding: .day, value: offset, to: period.start).flatMap { flowByDay[cal.startOfDay(for: $0)] }
        }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(f.string(from: period.start)) – \(f.string(from: period.end))")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 3) {
                    ForEach(Array(dayDots.enumerated()), id: \.offset) { _, flow in
                        Circle()
                            .fill(flow.map { healthRose.opacity(flowOpacity($0)) } ?? Theme.sidebarBg)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            Spacer()
            Text("\(period.dayCount) 天")
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var lengthChartSection: some View {
        let lengths = HealthCycleStore.cycleLengths(periods: periods)
        return Group {
            if lengths.count >= 2 {
                Section("周期长度") {
                    let recent = Array(lengths.suffix(12))
                    let avg = Double(recent.reduce(0, +)) / Double(recent.count)
                    Chart {
                        ForEach(Array(recent.enumerated()), id: \.offset) { idx, len in
                            BarMark(x: .value("次", idx + 1), y: .value("天", len))
                                .foregroundStyle(healthRose.opacity(0.7))
                                .cornerRadius(3)
                        }
                        RuleMark(y: .value("平均", avg))
                            .foregroundStyle(Theme.branchIndicator)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 120)
                    .padding(.vertical, 4)
                    Text("平均 \(Int(avg.rounded())) 天")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textSecondary)
                }
                .listRowBackground(Theme.mainBg)
            }
        }
    }

    private var predictionSection: some View {
        Group {
            if let pred = HealthCycleStore.prediction(periods: periods) {
                Section {
                    Text("下次预计 \(Self.dayFormatter.string(from: pred.nextStart))（前后 2 天）")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                } footer: {
                    Text("预测仅供参考，不作为避孕或医疗依据。")
                }
                .listRowBackground(Theme.mainBg)
            }
        }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日"
        return f
    }()
}

// MARK: - 体重详情

struct WeightDetailSheet: View {
    let profileId: String

    @Query private var weights: [WeightEntry]
    @State private var rangeDays = 90   // 90 / 365 / 0=全部

    init(profileId: String) {
        self.profileId = profileId
        _weights = Query(
            filter: #Predicate<WeightEntry> { $0.profileId == profileId },
            sort: \WeightEntry.date, order: .reverse
        )
    }

    private var unit: WeightUnit { WeightUnit.current }

    private var rangeWeights: [WeightEntry] {
        guard rangeDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -rangeDays, to: Calendar.current.startOfDay(for: Date())) else {
            return weights.sorted { $0.date < $1.date }
        }
        return weights.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    var body: some View {
        DetailShell(title: "体重") {
            Section {
                Picker("", selection: $rangeDays) {
                    Text("90 天").tag(90)
                    Text("一年").tag(365)
                    Text("全部").tag(0)
                }
                .pickerStyle(.segmented)
                if rangeWeights.count >= 2 {
                    Chart(rangeWeights, id: \.id) { entry in
                        LineMark(x: .value("日期", entry.date), y: .value("体重", unit.fromKg(entry.weightKg)))
                            .foregroundStyle(Theme.branchIndicator)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 180)
                    .padding(.vertical, 4)
                } else {
                    Text("这个范围里记录不足两条。")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .listRowBackground(Theme.mainBg)

            statsSection
            monthlySection
        }
    }

    private var statsSection: some View {
        Group {
            if let maxE = rangeWeights.max(by: { $0.weightKg < $1.weightKg }),
               let minE = rangeWeights.min(by: { $0.weightKg < $1.weightKg }),
               let first = rangeWeights.first, let last = rangeWeights.last, rangeWeights.count >= 2 {
                Section("区间") {
                    statRow("最高", maxE.weightKg)
                    statRow("最低", minE.weightKg)
                    HStack {
                        Text("变化")
                            .font(.system(size: Theme.F.label))
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        let delta = unit.fromKg(last.weightKg) - unit.fromKg(first.weightKg)
                        Text("\(delta >= 0 ? "+" : "")\(String(format: "%.1f", delta)) \(unit.label)")
                            .font(.system(size: Theme.F.body, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                    }
                }
                .listRowBackground(Theme.mainBg)
            }
        }
    }

    private func statRow(_ label: String, _ kg: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: Theme.F.label))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text("\(String(format: "%.1f", unit.fromKg(kg))) \(unit.label)")
                .font(.system(size: Theme.F.body, weight: .medium))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private var monthlySection: some View {
        let monthly = HealthStatsStore.weightMonthlyAvg(entries: rangeWeights)
        return Group {
            if monthly.count >= 2 {
                Section("月均") {
                    Chart(monthly, id: \.month) { item in
                        BarMark(x: .value("月", item.month, unit: .month), y: .value("体重", unit.fromKg(item.avgKg)))
                            .foregroundStyle(Theme.branchIndicator.opacity(0.6))
                            .cornerRadius(3)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 100)
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.mainBg)
            }
        }
    }
}

// MARK: - 亲密详情

struct IntimacyDetailSheet: View {
    let profileId: String

    @Query private var entries: [IntimacyEntry]
    @State private var monthOffset = 0
    @State private var selectedDay: Date? = nil

    init(profileId: String) {
        self.profileId = profileId
        _entries = Query(
            filter: #Predicate<IntimacyEntry> { $0.profileId == profileId },
            sort: \IntimacyEntry.date, order: .reverse
        )
    }

    private var month: Date {
        Calendar.current.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }

    private var entryByDay: [Date: IntimacyEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { (Calendar.current.startOfDay(for: $0.date), $0) })
    }

    var body: some View {
        DetailShell(title: "亲密") {
            Section("月历") {
                MonthGrid(month: month, monthOffset: $monthOffset) { day in
                    intimacyDayCell(day)
                }
                if let day = selectedDay, let entry = entryByDay[day], !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            .listRowBackground(Theme.mainBg)

            frequencySection
        }
    }

    @ViewBuilder
    private func intimacyDayCell(_ day: Date) -> some View {
        let has = entryByDay[day] != nil
        RoundedRectangle(cornerRadius: 6)
            .fill(Theme.sidebarBg)
            .frame(height: 28)
            .overlay(
                Group {
                    if has {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11))
                            .foregroundColor(healthRose)
                    } else {
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedDay = has ? day : nil
            }
    }

    private var frequencySection: some View {
        let counts = HealthStatsStore.intimacyMonthlyCount(entries: entries, months: 12, now: Date())
        return Group {
            if counts.contains(where: { $0.count > 0 }) {
                Section("按月") {
                    Chart(counts, id: \.month) { item in
                        BarMark(x: .value("月", item.month, unit: .month), y: .value("次", item.count))
                            .foregroundStyle(healthRose.opacity(0.7))
                            .cornerRadius(3)
                    }
                    .frame(height: 110)
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.mainBg)
            }
        }
    }
}

// MARK: - 月历网格（吃药热图/亲密点阵共用）

private struct MonthGrid<Cell: View>: View {
    let month: Date
    @Binding var monthOffset: Int
    @ViewBuilder let cell: (Date) -> Cell

    var body: some View {
        let cal = Calendar.current
        let symbols = weekdaySymbols(cal)
        let days = monthDays(cal)

        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(symbols, id: \.self) { s in
                    Text(s)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        cell(day)
                    } else {
                        Color.clear.frame(height: 28)
                    }
                }
            }
            HStack {
                Button { monthOffset -= 1 } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(monthTitle)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button { monthOffset += 1 } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(monthOffset >= 0 ? Theme.textMuted.opacity(0.4) : Theme.textSecondary)
                .disabled(monthOffset >= 0)
            }
        }
        .padding(.vertical, 4)
    }

    /// 该月天序列，月首前置 nil 补齐到 firstWeekday 对齐。
    private func monthDays(_ cal: Calendar) -> [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let firstWeekday = cal.component(.weekday, from: interval.start)
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        var d = interval.start
        while d < interval.end {
            result.append(d)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return result
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy 年 M 月"
        return f.string(from: month)
    }
}
