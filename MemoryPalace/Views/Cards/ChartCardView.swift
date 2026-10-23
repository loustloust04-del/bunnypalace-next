import SwiftUI
import SwiftStreamingMarkdown

/// 图表卡（research-chat-cards §10.1；v2 docs/plan-chart-cards-v2.md）。
/// v2：画法换成 lieflat-charts 的 Mono 语法（梯格柱 / 发丝折线 / 刻度环，PolyForm NC，只学规矩自己画），
/// 卡片四件套（结论标题 / 说明 / 图 / 来源），并且图表当控件用：开关系列、切范围、试算滑块、选中「问问这个」。
/// 手势只有轻点和滑块：拖动类手势在聊天 ScrollView 里会让手指落在卡上时滚不动（粟粟 09-26 真机）。
struct ChartCardView: View {
    let card: ChartCard
    let nodeId: String?
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var progress = 0.0
    @State private var entered = false
    @State private var selected: String?
    @State private var hidden: Set<Int> = []
    @State private var range: Int?
    @State private var values: [String: Double] = [:]

    init(card: ChartCard, nodeId: String?, drawn: Bool = false, selected: String? = nil) {
        self.card = card
        self.nodeId = nodeId
        // drawn：跳过入场直接画好（快照测试用；聊天里一律从 0 画起）
        _progress = State(initialValue: drawn ? 1 : 0)
        _entered = State(initialValue: drawn)
        _selected = State(initialValue: selected)
    }

    private var status: ChatCardStatus { viewModel?.cardStatus(.chart(card), nodeId: nodeId) ?? .readOnly }
    /// 入场画完才响应（终审 I2）
    private var interactive: Bool { status != .stale && entered }

    private var trialValues: [String: Double] { ChartTrial.defaults(card).merging(values) { $1 } }
    private var baseSeries: [ChartCard.Series] { card.isTrial ? ChartTrial.series(card, values: trialValues) : card.series }
    private var shownSeries: [ChartCard.Series] { ChartControls.applyRange(baseSeries, last: card.type.isOrdered ? range : nil) }
    private var input: ChartPlotInput { ChartPlotInput(series: shownSeries, hidden: hidden, selected: selected, unit: card.unit) }
    private var rangeOptions: [Int?] {
        guard card.type.isOrdered else { return [] }
        return ChartControls.rangeOptions(count: ChartPlotInput(series: baseSeries, hidden: [], selected: nil, unit: "").categories.count)
    }

    var body: some View {
        ChatCardShell(kindLabel: card.isTrial ? "图表 · 试算" : "图表", badge: status == .stale ? .stale : .none) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if !rangeOptions.isEmpty { rangeChips }
                plot
                    .frame(height: plotHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilitySummary)
                if card.type.usesSeries, baseSeries.count > 1, !card.type.isRing { legend }
                if let params = card.params, !params.isEmpty { sliders(params) }
                if let selected { selectionRow(selected) }
                if !card.source.isEmpty {
                    Text(card.source)
                        .font(ChartInk.sourceFont)
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(ChartInk.faint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard progress == 0 else { return }
            if reduceMotion {
                progress = 1                                       // 几何直接到位（R5 D2）
                entered = true
            } else {
                withAnimation(.linear(duration: 0.9), completionCriteria: .logicallyComplete) { progress = 1 } completion: { entered = true }
            }
        }
        .onChange(of: status) { _, new in if new == .stale { selected = nil } }   // 变旧版本：收起选中
    }

    // MARK: 四件套

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !card.title.isEmpty || !card.unit.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    if !card.title.isEmpty { Text(card.title).font(ChartInk.titleFont).foregroundStyle(ChartInk.ink) }
                    Spacer(minLength: 8)
                    if !card.unit.isEmpty { Text(card.unit).font(.caption).foregroundStyle(ChartInk.muted) }
                }
            }
            let sub = ChartGeometry.autoSubtitle(card, series: shownSeries)
            if !sub.isEmpty { Text(sub).font(ChartInk.subFont).foregroundStyle(ChartInk.muted) }
        }
    }

    @ViewBuilder
    private var plot: some View {
        let onTap: (String?) -> Void = { hit in
            guard interactive else { return }
            let next = ChartMath.reduceTap(current: selected, hit: hit)
            if next != selected { withAnimation(reduceMotion ? nil : ChatCardMotion.snappy) { selected = next } }
        }
        switch card.type {
        case .bar: RungBarsPlot(progress: progress, input: input, onTap: onTap)
        case .line: HairlineLinePlot(progress: progress, input: input, onTap: onTap)
        case .pie, .donut: TickRingPlot(progress: progress, input: input, onTap: onTap)
        default: ChartCanvasPlot(progress: progress, card: card, input: input, onTap: onTap)
        }
    }

    private var plotHeight: CGFloat {
        switch card.type {
        case .pie, .donut: return 170
        case .bar, .line: return 180
        default: return ChartCanvasPlot.height(card, input)
        }
    }

    /// 图例能开关的图（堆叠的段是一体的，只看不点）
    private var legendToggles: Bool { [.bar, .line, .area, .stream, .hbar].contains(card.type) }

    private func legendColor(_ i: Int, of n: Int) -> Color {
        card.type == .stack ? ChartInk.ladder[[0, 2, 4, 5][min(i, 3)]] : ChartInk.series(i, of: n)
    }

    // MARK: 控件

    private var rangeChips: some View {
        HStack(spacing: 6) {
            ForEach(Array(rangeOptions.enumerated()), id: \.offset) { _, option in
                let on = range == option
                Button {
                    guard interactive else { return }
                    range = option
                    let kept = ChartPlotInput(series: shownSeries, hidden: [], selected: nil, unit: "").categories
                    if let s = selected, !kept.contains(s) { selected = nil }
                } label: {
                    Text(option.map { "近 \($0)" } ?? "全部")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .foregroundStyle(on ? Color(hex: 0xFFFDF9) : ChartInk.muted)
                        .background(Capsule().fill(on ? ChartInk.ink : ChartInk.grid.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var legend: some View {
        let series = baseSeries
        return HStack(spacing: 8) {
            ForEach(Array(series.enumerated()), id: \.offset) { i, s in
                let off = hidden.contains(i)
                let name = s.name.isEmpty ? "系列 \(i + 1)" : s.name
                Button {
                    guard interactive, legendToggles else { return }
                    withAnimation(reduceMotion ? nil : ChatCardMotion.snappy) { hidden = ChartControls.toggle(hidden, series: i, total: series.count) }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(legendColor(i, of: series.count)).frame(width: 7, height: 7)
                        Text(name).font(.caption).strikethrough(off)
                    }
                    .foregroundStyle(ChartInk.muted)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(ChartInk.grid, lineWidth: 1))
                    .opacity(off ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name)，\(off ? "已隐藏" : "显示中")")
                .accessibilityHint(legendToggles ? "点一下开关这条" : "")
            }
        }
    }

    private func sliders(_ params: [ChartCard.Param]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(params, id: \.key) { p in
                let v = trialValues[p.key] ?? p.snapped(p.value)
                let shown = p.unit.map { "\(ChartMath.format(v)) \($0)" } ?? ChartMath.format(v)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(p.label).font(.caption).foregroundStyle(ChartInk.muted)
                        Spacer()
                        Text(shown).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(ChartInk.ink)
                    }
                    Slider(value: Binding(get: { v }, set: { values[p.key] = p.snapped($0) }), in: p.min...p.max, step: p.step)
                        .tint(ChartInk.focus)
                        .disabled(!interactive)
                        .accessibilityLabel(p.label)
                        .accessibilityValue(shown)
                }
            }
        }
    }

    private func selectionRow(_ label: String) -> some View {
        let rows = ChartReadings.rows(card, series: shownSeries, label: label, hidden: hidden)
        let text = rows.map { $0.name.isEmpty ? $0.text : "\($0.name) \($0.text)" }.joined(separator: " · ")
        return HStack(spacing: 10) {
            (Text(label + "  ").foregroundStyle(ChartInk.muted) + Text(text).fontWeight(.semibold).foregroundStyle(ChartInk.ink))
                .font(.caption)
                .monospacedDigit()
                .lineLimit(2)
            Spacer(minLength: 4)
            if let nodeId, let viewModel {
                Button {
                    let quote = ChartControls.quote(card: card, label: label, rows: rows,
                                                    params: card.isTrial ? ChartControls.paramSummary(card, values: trialValues) : [])
                    viewModel.quoteCardText(quote, nodeId: nodeId)
                } label: {
                    Text("问问这个")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(hex: 0xFFFDF9))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(ChartInk.focus))
                }
                .buttonStyle(.plain)
                .accessibilityHint("把这一项引用到输入框，接着问")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ChartInk.grid.opacity(0.35)))
        .transition(.opacity)
    }

    private var accessibilitySummary: String {
        let head = card.title.isEmpty ? "图表" : card.title
        let body = ChartReadings.labels(card, series: shownSeries).prefix(12).map { c in
            let rows = ChartReadings.rows(card, series: shownSeries, label: c, hidden: hidden)
            return "\(c) " + rows.map { $0.name.isEmpty ? $0.text : "\($0.name) \($0.text)" }.joined(separator: "，")
        }.joined(separator: "；")
        return "\(head)。\(body)"
    }
}
