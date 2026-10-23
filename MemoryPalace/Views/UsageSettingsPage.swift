import SwiftUI
import Charts

enum UsageFormat {
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func cost(_ usd: Double) -> String {
        if usd <= 0 { return "$0" }
        if usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    static func unpricedNote(_ n: Int) -> String? {
        n > 0 ? "\(n) 次未计价（查不到模型价格，未计入花费）" : nil
    }
}

/// 统一用量页（research-magpie 2.1 / 2.5）：范围切换、总花费、时间柱、按模型 / 按卡两张榜、「N 次未计价」。
/// 数据：对话侧来自 `UsageLedger`（逐次调用），Mac 上「Code」筛选并入 Code 会话索引的会话级 token（`CodeUsageSource`）。
///
/// 页顶 `quotaSlot` 留给「订阅额度卡」（`SubscriptionQuotaService` + 视图，另一条线做）：
/// Mac 设置里已接为 `UsageSettingsPage { SubscriptionQuotaCard() }`（额度卡仅 Mac）。
struct UsageSettingsPage<QuotaSlot: View>: View {
    private let quotaSlot: QuotaSlot

    init(@ViewBuilder quotaSlot: () -> QuotaSlot) {
        self.quotaSlot = quotaSlot()
    }

    @Environment(\.settingsMetrics) private var m
    @AppStorage("usagePage.period") private var period: UsagePeriod = .week
    @AppStorage("usagePage.scope") private var scope: UsageScope = .chat
    @AppStorage("usagePage.metric") private var metric: Metric = .cost
    @State private var records: [UsageRecord] = []
    @State private var summary: UsageSummary?
    @State private var loadGeneration = 0
    @State private var budget = GlobalBudgetStore.shared

    enum Metric: String, CaseIterable, Identifiable {
        case cost, tokens
        var id: String { rawValue }
        var label: String { self == .cost ? "花费" : "Token" }
    }

    /// Code 只有会话级 token，没法计价 → 花费度量对它没意义
    private var effectiveMetric: Metric { scope == .code ? .tokens : metric }

    var body: some View {
        // 搜索锚点（对账区）：命中时滚到那一行
        ScrollViewReader { anchorProxy in
        SettingsSectionList(.list) {
            if QuotaSlot.self != EmptyView.self {
                Section { quotaSlot }
                    .listRowBackground(Theme.mainBg)
            }

            Section {
                controls
                if let summary {
                    overview(summary)
                    chart(summary)
                }
            } footer: {
                Text(footerText)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            if let summary, !summary.models.isEmpty {
                board("按模型", rows: summary.models)
                board(scope == .code ? "按 Agent" : "按卡片", rows: summary.providers)
            }

            if scope != .code {
                budgetSection
                UsageReconciliationSection(records: records)
            }
        }
        .settingsAnchorScroll(anchorProxy)
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: UsageLedger.didAppend)) { _ in
            Task { await reload() }
        }
        .onChange(of: period) { _, _ in resummarize() }
        .onChange(of: scope) { _, _ in resummarize() }
    }

    private var footerText: String {
        var text = "每次模型调用记一行，只存在本机（Application Support/MemoryPalace/usage.jsonl）。新记录保存供应商金额或按当时用量与价格计算的金额；旧记录按当前价格估算。"
        #if os(macOS)
        if scope != .chat {
            text += "Code 来自编程会话索引，只有每个会话的总 token，按会话最后活动时间计，不计价。"
        }
        #endif
        return text
    }

    // MARK: - 控件

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("范围", selection: $period) {
                ForEach(UsagePeriod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 12) {
                #if os(macOS)
                Picker("来源", selection: $scope) {
                    ForEach(UsageScope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                #endif
                Spacer(minLength: 0)
                if scope != .code {
                    Picker("度量", selection: $metric) {
                        ForEach(Metric.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }
            }
        }
        .tint(Theme.textSecondary)
    }

    // MARK: - 概览

    private func overview(_ s: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                if scope != .code {
                    stat(UsageFormat.cost(s.totals.costUSD), "花费")
                }
                stat(UsageFormat.tokens(s.totals.tokens), "Token")
                stat("\(s.totals.calls)", scope == .code ? "会话" : "次调用")
                if s.totals.errors > 0 {
                    stat("\(s.totals.errors)", "次失败")
                }
                Spacer(minLength: 0)
            }
            if scope != .code {
                Text("输入 \(UsageFormat.tokens(s.totals.input)) · 输出 \(UsageFormat.tokens(s.totals.output)) · 缓存读 \(UsageFormat.tokens(s.totals.cacheRead)) · 缓存写 \(UsageFormat.tokens(s.totals.cacheWrite))"
                     + (s.totals.reasoning > 0 ? " · 推理 \(UsageFormat.tokens(s.totals.reasoning))" : ""))
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            if s.totals.partial > 0 {
                Text("部分计价 \(s.totals.partial) 次")
                    .font(m.caption)
                    .foregroundColor(Theme.textSecondary)
            }
            if s.totals.estimated > 0 {
                Text("估算（旧记录）\(s.totals.estimated) 次")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            if let note = UsageFormat.unpricedNote(s.totals.unpriced) {
                Label(note, systemImage: "questionmark.circle")
                    .font(m.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
    }

    // MARK: - 时间柱

    private func value(_ t: UsageTotals) -> Double {
        effectiveMetric == .cost ? t.costUSD : Double(t.tokens)
    }

    private func chart(_ s: UsageSummary) -> some View {
        Chart(s.series) { point in
            BarMark(
                x: .value("时间", point.label),
                y: .value(effectiveMetric.label, value(point.totals))
            )
            .foregroundStyle(Theme.branchIndicator)
            .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: axisLabels(s)) { _ in
                AxisValueLabel().font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Theme.textMuted.opacity(0.15))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(effectiveMetric == .cost ? UsageFormat.cost(d) : UsageFormat.tokens(Int(d)))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 150)
        .padding(.vertical, 4)
    }

    /// 柱多了标签挤：最多标 ~8 个
    private func axisLabels(_ s: UsageSummary) -> [String] {
        let step = max(1, Int((Double(s.series.count) / 8).rounded(.up)))
        return s.series.enumerated().compactMap { $0.offset % step == 0 ? $0.element.label : nil }
    }

    // MARK: - 榜单

    private func board(_ title: String, rows: [UsageGroup]) -> some View {
        Section {
            ForEach(rows.prefix(8)) { row in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.label)
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(row.totals.calls) \(scope == .code ? "会话" : "次") · \(UsageFormat.tokens(row.totals.tokens)) token"
                             + (row.totals.unpriced > 0 ? " · \(row.totals.unpriced) 次未计价" : ""))
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer(minLength: 8)
                    Text(effectiveMetric == .cost ? UsageFormat.cost(row.totals.costUSD) : UsageFormat.tokens(row.totals.tokens))
                        .font(m.body)
                        .monospacedDigit()
                        .foregroundColor(Theme.textSecondary)
                }
            }
            if rows.count > 8 {
                Text("…还有 \(rows.count - 8) 项")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        } header: {
            Text(title)
                .font(m.sectionHeader)
                .foregroundColor(m.sectionHeaderColor)
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: - 保险闸兼容

    private var budgetSection: some View {
        let ledgerSpent = GlobalBudgetStore.ledgerSpentUSD(records: records, since: budget.spentResetAt)
        return Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("保险闸已用 \(String(format: "$%.4f", budget.spentUSD))")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text("账本汇总 \(String(format: "$%.4f", ledgerSpent))（\(budget.spentResetAt.map { "自 " + $0.formatted(date: .abbreviated, time: .shortened) + " 重置起" } ?? "账本全部")）")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
                Button("按账本校准") { budget.calibrateSpent(fromLedger: records) }
                    .buttonStyle(.bordered)
                    .disabled(abs(ledgerSpent - budget.spentUSD) < 0.00005)
            }
        } header: {
            Text("预算")
                .font(m.sectionHeader)
                .foregroundColor(m.sectionHeaderColor)
        } footer: {
            Text("新调用的保险闸、脚注与用量页读取同一笔落盘金额；旧记录校准仍按当前价格估算。未计价新调用不猜金额，可能低估预算已用。账本上线前的花费不在账本里。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: - 数据

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let loaded = await Task.detached(priority: .userInitiated) { () -> [UsageRecord] in
            var all = UsageLedger.shared.load()
            #if os(macOS)
            all += CodeUsageSource.records(since: nil)
            all.sort { $0.time < $1.time }
            #endif
            return all
        }.value
        guard generation == loadGeneration else { return }
        records = loaded
        resummarize()
    }

    private func resummarize() {
        let (records, period, scope) = (records, period, scope)
        #if os(macOS)
        let effectiveScope = scope
        #else
        let effectiveScope: UsageScope = .all
        #endif
        Task {
            let s = await Task.detached(priority: .userInitiated) {
                UsageSummarizer.summarize(period, now: Date(), records: records, scope: effectiveScope)
            }.value
            if period == self.period, scope == self.scope { summary = s }
        }
    }
}

extension UsageSettingsPage where QuotaSlot == EmptyView {
    init() {
        self.init { EmptyView() }
    }
}
