#if os(macOS)
import SwiftUI

/// code 组「统计」整页（plan-wake-native-n2 §2.3，Wake Insights `workbench.rs:5691-7400`）：
/// 概览 → 最近 7 天 → 活动热力图 → 随时间变化 → 分布 → Agent / 项目 / 模型三榜。720 居中、区块 32 留白、不做卡片
struct CodingInsightsView: View {
    private var library: CodingSessionLibrary { .shared }

    @State private var range: CodingDistributionRange = .hour
    /// 三榜各自记忆的档位（Agent / 项目 / 模型）
    @State private var metrics: [CodingInsightsMetric] = [.sessions, .sessions, .sessions]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("统计")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(CodingInsightsFormat.subtitle(library.insights))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 88)
            .padding(.horizontal, 28)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.mainBg)
    }

    @ViewBuilder
    private var content: some View {
        if let data = library.insights, data.sessions > 0 {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    overview(data)
                    weekSection(data)
                    VStack(alignment: .leading, spacing: 12) {
                        CodingInsightsSectionHead(title: "活动", caption: "你逐日发出的提问")
                        CodingHeatmap(data: data)
                    }
                    trendSection(data)
                    distributionSection(data)
                    usageSection("Agent", rows: data.agents, slot: 0, limit: nil, nameWidth: 128, lead: .agent)
                    if !data.projects.isEmpty {
                        usageSection("项目", rows: data.projects, slot: 1, limit: 6, nameWidth: 128, lead: .folder)
                    }
                    if !data.models.isEmpty {
                        usageSection("模型", rows: data.models, slot: 2, limit: 6, nameWidth: 176, lead: .none)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        } else if library.insightsLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.textMuted)
                Text("还没有活动记录")
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text("刷新会话后这里会显示你的活动。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 概览 / 最近 7 天

    private static let statColumns = [GridItem(.adaptive(minimum: 84), spacing: 24, alignment: .leading)]

    private func overview(_ d: CodingInsightsData) -> some View {
        LazyVGrid(columns: Self.statColumns, alignment: .leading, spacing: 16) {
            stat(CodingInsightsFormat.thousands(d.sessions), "会话", size: 22)
            if d.tokens > 0 { stat(CodingInsightsFormat.tokens(d.tokens), "Token", size: 22) }
            stat(CodingInsightsFormat.thousands(d.prompts), "提问", size: 22)
            stat(CodingInsightsFormat.thousands(Int64(d.agents.count)), "Agent", size: 22)
            stat(CodingInsightsFormat.thousands(d.projectCount), "项目", size: 22)
            stat(CodingInsightsFormat.thousands(d.activeDays), "活跃天数", size: 22)
        }
    }

    private func weekSection(_ d: CodingInsightsData) -> some View {
        let (current, previous) = d.lastWeekPair
        return VStack(alignment: .leading, spacing: 12) {
            CodingInsightsSectionHead(title: "最近 7 天", caption: "与之前 7 天相比")
            LazyVGrid(columns: Self.statColumns, alignment: .leading, spacing: 16) {
                stat(CodingInsightsFormat.thousands(current.sessions), "会话", size: 16,
                     note: CodingInsightsFormat.change(now: current.sessions, before: previous.sessions))
                stat(CodingInsightsFormat.thousands(current.prompts), "提问", size: 16,
                     note: CodingInsightsFormat.change(now: current.prompts, before: previous.prompts))
                stat(CodingInsightsFormat.thousands(current.activeDays), "活跃天数", size: 16,
                     note: CodingInsightsFormat.change(now: current.activeDays, before: previous.activeDays))
            }
        }
    }

    private func stat(_ value: String, _ label: String, size: CGFloat, note: (text: String, emphasized: Bool)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
            if let note {
                Text(note.text)
                    .font(.system(size: 11))
                    .foregroundColor(note.emphasized ? Theme.branchIndicator : Theme.textMuted)
            }
        }
    }

    // MARK: - 随时间变化 / 分布

    private func trendSection(_ d: CodingInsightsData) -> some View {
        let layers = CodingInsightsFormat.trendLayers(d.trendAgents)
        return VStack(alignment: .leading, spacing: 12) {
            CodingInsightsSectionHead(title: "随时间变化", caption: CodingInsightsFormat.trendCaption(layers))
            CodingTrendChart(start: d.trendStart, layers: layers)
        }
    }

    private func distributionSection(_ d: CodingInsightsData) -> some View {
        let values = range.values(d)
        let peak = values.indices.max { values[$0] < values[$1] }
        let caption = values.reduce(0, +) > 0 ? peak.map { range.peakCaption($0) } ?? "" : "你与 agent 交流的时段"
        return VStack(alignment: .leading, spacing: 12) {
            CodingInsightsSectionHead(title: range.title, caption: caption, arrows: AnyView(
                CodingInsightsArrows(label: nil, previous: { range = range.stepped(-1) }, next: { range = range.stepped(1) })))
            CodingDistributionChart(range: range, values: values, peak: values.reduce(0, +) > 0 ? peak : nil)
        }
    }

    // MARK: - 三榜

    enum UsageLead { case agent, folder, none }

    private func usageSection(_ title: String, rows: [CodingUsageTally], slot: Int, limit: Int?,
                              nameWidth: CGFloat, lead: UsageLead) -> some View {
        let available = CodingInsightsMetric.available(for: rows)
        let metric = CodingInsightsMetric.resolved(metrics[slot], in: available)
        let ranked = CodingInsightsMetric.ranked(rows, by: metric, limit: limit)
        let peak = max(ranked.map { metric.value($0) }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            CodingInsightsSectionHead(title: title, arrows: AnyView(CodingInsightsArrows(
                label: metric.label,
                previous: { cycle(slot, available, by: -1) },
                next: { cycle(slot, available, by: 1) })))
            ForEach(Array(ranked.enumerated()), id: \.offset) { _, row in
                usageRow(row, metric: metric, peak: peak, nameWidth: nameWidth, lead: lead)
            }
        }
    }

    private func cycle(_ slot: Int, _ available: [CodingInsightsMetric], by step: Int) {
        let current = CodingInsightsMetric.resolved(metrics[slot], in: available)
        let i = available.firstIndex(of: current) ?? 0
        metrics[slot] = available[(i + step + available.count) % available.count]
    }

    private func usageRow(_ row: CodingUsageTally, metric: CodingInsightsMetric, peak: Int64,
                          nameWidth: CGFloat, lead: UsageLead) -> some View {
        let name = lead == .agent ? CodingInsightsFormat.agentLabel(row.name) : row.name
        return HStack(spacing: 8) {
            switch lead {
            case .agent:
                Circle()
                    .fill(CodingAgent(rawValue: row.name).map(CodingSessionFormat.color) ?? Theme.textMuted)
                    .frame(width: 7, height: 7)
                    .frame(width: 14)
            case .folder:
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 14)
            case .none:
                EmptyView()
            }
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: nameWidth, alignment: .leading)
                .help(name)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.accent)
                    Capsule()
                        .fill(Theme.branchIndicator)
                        .frame(width: max(6, geo.size.width * CGFloat(metric.value(row)) / CGFloat(peak)))
                }
            }
            .frame(height: 6)
            Text(metric.display(row))
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .frame(height: 24)
    }
}

// MARK: - 区块头 / 切换钮

struct CodingInsightsSectionHead: View {
    let title: String
    var caption: String?
    var arrows: AnyView?

    var body: some View {
        HStack(alignment: caption == nil ? .center : .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer(minLength: 8)
            if let arrows { arrows }
        }
    }
}

/// ‹ 档位名（定宽 64）›
struct CodingInsightsArrows: View {
    let label: String?
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("chevron.left", help: "上一个视图", action: previous)
            if let label {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 64)
            }
            button("chevron.right", help: "下一个视图", action: next)
        }
    }

    private func button(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 热力图

/// 53 周 × 7 天热力图（9 格 + 3 缝、左 26 星期列，总宽 662）；未来日期留白；格提示「N 次提问 · 日期」
struct CodingHeatmap: View {
    let data: CodingInsightsData

    static let cell: CGFloat = 9
    static let gap: CGFloat = 3
    static let step: CGFloat = cell + gap
    static let dowWidth: CGFloat = 26
    static var width: CGFloat { dowWidth + gap + CGFloat(CodingInsightsData.trendWeeks) * step - gap }

    var body: some View {
        let start = data.trendStart
        let todayIndex = data.asOf.days(since: start)
        let total = CodingInsightsData.trendWeeks * 7
        var window = [Int64](repeating: 0, count: total)
        var peak: Int64 = 1
        for entry in data.daily {
            let i = entry.day.days(since: start)
            if (0..<total).contains(i) {
                window[i] = entry.count
                peak = max(peak, entry.count)
            }
        }
        return ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
            VStack(alignment: .leading, spacing: 6) {
                CodingMonthTicks(start: start)
                HStack(alignment: .top, spacing: Self.gap) {
                    ZStack(alignment: .topLeading) {
                        ForEach([0, 2, 4], id: \.self) { row in
                            Text(["一", "二", "三", "四", "五", "六", "日"][row])
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textMuted)
                                .offset(y: CGFloat(row) * Self.step - 2)
                        }
                    }
                    .frame(width: Self.dowWidth, height: 7 * Self.step - Self.gap, alignment: .topLeading)
                    ForEach(0..<CodingInsightsData.trendWeeks, id: \.self) { column in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { row in
                                let i = column * 7 + row
                                if i > todayIndex {
                                    Color.clear.frame(width: Self.cell, height: Self.cell)
                                } else {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Self.color(level: CodingInsightsFormat.heatLevel(window[i], peak: peak)))
                                        .frame(width: Self.cell, height: Self.cell)
                                        .help("\(CodingInsightsFormat.promptsLabel(window[i])) · \(CodingInsightsFormat.dayLabel(start.adding(days: i)))")
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text(notes)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    HStack(spacing: Self.gap) {
                        Text("少")
                        ForEach(0..<5, id: \.self) { level in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Self.color(level: level))
                                .frame(width: Self.cell, height: Self.cell)
                        }
                        Text("多")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 4)
            }
            .frame(width: Self.width, alignment: .leading)
        }
    }

    private var notes: String {
        var parts: [String] = []
        if data.currentStreak > 0 { parts.append("连续 \(data.currentStreak) 天") }
        if data.longestStreak > 0 { parts.append("最长 \(data.longestStreak) 天") }
        if let busiest = data.busiestDay {
            parts.append("最忙 \(CodingInsightsFormat.dayLabel(busiest.day, withYear: false))(\(CodingInsightsFormat.promptsLabel(busiest.count)))")
        }
        return parts.joined(separator: " · ")
    }

    static func color(level: Int) -> Color {
        level == 0 ? Theme.accent : Theme.branchIndicator.opacity(CodingInsightsFormat.heatOpacity[min(level, 4) - 1])
    }
}

/// 月份刻度（该列周一与前一列不同月才标），与热力格同步距
struct CodingMonthTicks: View {
    let start: CodingDay

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(CodingInsightsFormat.monthTicks(start: start), id: \.column) { tick in
                Text("\(tick.month)月")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize()
                    .offset(x: CodingHeatmap.dowWidth + CodingHeatmap.gap + CGFloat(tick.column) * CodingHeatmap.step)
            }
        }
        .frame(width: CodingHeatmap.width, height: 14, alignment: .topLeading)
    }
}

// MARK: - 随时间变化

/// 53 周堆叠柱（与热力图同宽同步距、周列上下对齐）：前五 agent 自下而上 + 其他；按峰值周归一；零周 2 基线、非零至少 3
struct CodingTrendChart: View {
    let start: CodingDay
    let layers: [CodingTrendLayer]

    private static let height: CGFloat = 72

    var body: some View {
        let weeks = CodingInsightsData.trendWeeks
        let totals = (0..<weeks).map { w in layers.reduce(Int64(0)) { $0 + $1.weekly[w] } }
        let peak = max(totals.max() ?? 1, 1)
        return ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: CodingHeatmap.gap) {
                    Color.clear.frame(width: CodingHeatmap.dowWidth, height: 1)
                    ForEach(0..<weeks, id: \.self) { w in
                        bar(week: w, total: totals[w], peak: peak)
                    }
                }
                .frame(height: Self.height, alignment: .bottom)
                CodingMonthTicks(start: start)
                HStack(spacing: 12) {
                    ForEach(Array(layers.enumerated()), id: \.offset) { _, layer in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(layer))
                                .frame(width: CodingHeatmap.cell, height: CodingHeatmap.cell)
                            Text(layer.name)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textMuted)
                                .fixedSize()
                        }
                    }
                }
            }
            .frame(width: CodingHeatmap.width, alignment: .leading)
        }
    }

    @ViewBuilder
    private func bar(week: Int, total: Int64, peak: Int64) -> some View {
        if total == 0 {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.accent)
                .frame(width: CodingHeatmap.cell, height: 2)
        } else {
            let barHeight = max(3, Self.height * CGFloat(total) / CGFloat(peak))
            VStack(spacing: 0) {
                ForEach(Array(layers.enumerated().reversed()), id: \.offset) { _, layer in
                    let n = layer.weekly[week]
                    if n > 0 {
                        Rectangle()
                            .fill(color(layer))
                            .frame(width: CodingHeatmap.cell, height: barHeight * CGFloat(n) / CGFloat(total))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .help(tooltip(week: week, total: total))
        }
    }

    private func tooltip(week: Int, total: Int64) -> String {
        let monday = start.adding(days: week * 7)
        var lines = ["\(CodingInsightsFormat.dayLabel(monday, withYear: false)) 当周 · \(CodingInsightsFormat.promptsLabel(total))"]
        let top = layers.filter { $0.weekly[week] > 0 }.sorted { $0.weekly[week] > $1.weekly[week] }.prefix(3)
        for layer in top { lines.append("\(layer.name) · \(CodingInsightsFormat.thousands(layer.weekly[week]))") }
        return lines.joined(separator: "\n")
    }

    private func color(_ layer: CodingTrendLayer) -> Color {
        if layer.isOther { return Theme.textMuted.opacity(0.35) }
        return layer.agent.map(CodingSessionFormat.color) ?? Theme.textMuted
    }
}

// MARK: - 分布

enum CodingDistributionRange: CaseIterable {
    case hour, weekday, month

    var title: String {
        switch self {
        case .hour: return "时段"
        case .weekday: return "星期"
        case .month: return "月份"
        }
    }

    func values(_ d: CodingInsightsData) -> [Int64] {
        switch self {
        case .hour: return d.hourly
        case .weekday: return d.weekday
        case .month: return d.monthly
        }
    }

    func stepped(_ delta: Int) -> CodingDistributionRange {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + delta + all.count) % all.count]
    }

    var gap: CGFloat {
        switch self {
        case .hour: return 4
        case .weekday: return 8
        case .month: return 6
        }
    }

    func label(_ i: Int) -> String {
        switch self {
        case .hour: return CodingInsightsFormat.hourLabel(i)
        case .weekday: return CodingInsightsFormat.weekdayNames[i]
        case .month: return "\(i + 1)月"
        }
    }

    func peakCaption(_ i: Int) -> String {
        self == .weekday ? "最常在\(label(i))" : "最常在 \(label(i))"
    }

    func tooltip(_ i: Int, _ n: Int64) -> String {
        let when = self == .hour ? "\(label(i)) – \(label((i + 1) % 24))" : label(i)
        return "\(CodingInsightsFormat.promptsLabel(n)) · \(when)"
    }
}

/// 时段 / 星期 / 月份竖柱：峰值全饱和、其余 55%，零值 2 基线；时段只标 0 / 6 / 12 / 18 靠左，其余每柱居中标
struct CodingDistributionChart: View {
    let range: CodingDistributionRange
    let values: [Int64]
    let peak: Int?

    private static let height: CGFloat = 80

    var body: some View {
        let top = max(values.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: range.gap) {
                ForEach(values.indices, id: \.self) { i in
                    let n = values[i]
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(n == 0 ? Theme.accent : Theme.branchIndicator.opacity(i == peak ? 1 : 0.55))
                            .frame(height: n == 0 ? 2 : max(3, Self.height * CGFloat(n) / CGFloat(top)))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.height)
                    .contentShape(Rectangle())
                    .help(range.tooltip(i, n))
                }
            }
            HStack(spacing: range.gap) {
                ForEach(values.indices, id: \.self) { i in
                    Group {
                        if range != .hour || i % 6 == 0 {
                            Text(range == .hour ? CodingInsightsFormat.hourLabel(i) : range.label(i))
                                .fixedSize()
                        } else {
                            Color.clear
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: range == .hour ? .leading : .center)
                }
            }
            .frame(height: 14)
        }
    }
}
#endif
