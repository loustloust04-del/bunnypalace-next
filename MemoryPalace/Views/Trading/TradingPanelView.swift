#if PERSONAL_APPS
import SwiftUI
import SwiftData

/// page2「交易」工具：关注标的列表（$TICKER 词典的目录页）。
/// 数据最小主义：面板只有关注列表；研报/笔记/出处全在 TickerDetailSheet 里现取。
struct TradingPanelView: View {
    @Environment(RightPanelNavigator.self) private var desktopNavigator: RightPanelNavigator?
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    @Query private var tickers: [TickerEntry]
    @Query private var recentTrades: [TradeEntry]

    @State private var newSymbol = ""
    @State private var activeSymbol: ActiveSymbol? = nil
    @State private var showNewTrade = false
    @State private var editingTrade: TradeEntry?

    private struct ActiveSymbol: Identifiable {
        let symbol: String
        var id: String { symbol }
    }

    init(profileId: String) {
        self.profileId = profileId
        _tickers = Query(
            filter: #Predicate<TickerEntry> { $0.profileId == profileId },
            sort: \TickerEntry.createdAt
        )
        var tradeDesc = FetchDescriptor<TradeEntry>(
            predicate: #Predicate<TradeEntry> { $0.profileId == profileId },
            sortBy: [SortDescriptor(\TradeEntry.openedAt, order: .reverse)]
        )
        tradeDesc.fetchLimit = 5
        _recentTrades = Query(tradeDesc)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            PanelSectionList {
                watchSection
                recentTradesSection
                addSection
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
        }
        .toolPageBackground()
        .onAppear { consumeDesktopTarget() }
        .onChange(of: desktopNavigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
        .sheet(item: $activeSymbol) { a in
            TickerDetailSheet(symbol: a.symbol)
        }
        .sheet(isPresented: $showNewTrade) {
            TradeEditorSheet(profileId: profileId, entry: nil)
        }
        .sheet(item: $editingTrade) { trade in
            TradeEditorSheet(profileId: profileId, entry: trade)
        }
    }

    private func consumeDesktopTarget() {
        guard let target = desktopNavigator?.pendingTarget, target.tool == "trading" else { return }
        desktopNavigator?.pendingTarget = nil
        // 「trade:<uuid>」= 全局搜索点了某笔成交，直接开它的编辑页；没有前缀照旧是股票代码（小组件在发），不再要求在关注列表里
        if target.id.hasPrefix("trade:") {
            guard let id = UUID(uuidString: String(target.id.dropFirst("trade:".count))) else { return }
            let pid = profileId
            var query = FetchDescriptor<TradeEntry>(predicate: #Predicate { $0.id == id && $0.profileId == pid })
            query.fetchLimit = 1
            editingTrade = (try? modelContext.fetch(query))?.first
        } else {
            activeSymbol = ActiveSymbol(symbol: target.id)
        }
    }

    private var header: some View {
        HStack {
            Text("交易")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - 关注列表

    private var watchSection: some View {
        Section {
            if tickers.isEmpty {
                Text("还没有关注的标的。聊天里点 $NVDA 这样的代码，或在下面手动添加。")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(tickers) { entry in
                    tickerRow(entry)
                }
            }
        } header: {
            Text("关注")
        } footer: {
            Text("研报放进文件库 trading/<代码>/ 目录，档案页就能看。")
        }
        .listRowBackground(Theme.mainBg)
    }

    private func tickerRow(_ entry: TickerEntry) -> some View {
        Button {
            activeSymbol = ActiveSymbol(symbol: entry.symbol)
        } label: {
            HStack(spacing: 8) {
                Text("$\(entry.symbol)")
                    .font(.system(size: Theme.F.body, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                if let name = entry.displayName, !name.isEmpty {
                    Text(name)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if let r = TradingStore.latestReport(symbol: entry.symbol, profileId: profileId),
                   let rating = r.rating {
                    Text(rating)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ratingColor(rating))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(ratingColor(rating).opacity(0.13)))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) { removeWatchButton(entry) }
        // S1-3：mac 上横扫只有触控板能做、鼠标够不着，右键补同一条
        #if os(macOS)
        .contextMenu { removeWatchButton(entry) }
        #endif
    }

    /// 从自选移除。横扫和右键共用同一份（S1-3）
    @ViewBuilder
    private func removeWatchButton(_ entry: TickerEntry) -> some View {
        Button(role: .destructive) {
            modelContext.delete(entry)
            try? modelContext.save()
            TradingStore.reportWatchlist(context: modelContext, profileId: profileId)
        } label: {
            Label("移除", systemImage: "star.slash")
        }
    }

    private func ratingColor(_ rating: String) -> Color {
        switch rating {
        case "Buy", "Overweight": return Theme.branchIndicator
        case "Underweight", "Sell": return Color(red: 0.79, green: 0.54, blue: 0.54)  // 玫瑰，划线同源
        default: return Theme.textMuted
        }
    }

    // MARK: - 最近交易（跨标的近 5 笔，点行进该标的档案）

    private var recentTradesSection: some View {
        Section {
            if recentTrades.isEmpty {
                Text("还没记过交易。聊天里说一句「180 开了 100 股 NVDA，因为…」就会记下来。")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(recentTrades) { t in
                    Button {
                        activeSymbol = ActiveSymbol(symbol: t.symbol)
                    } label: {
                        HStack(spacing: 8) {
                            Text("$\(t.symbol)")
                                .font(.system(size: Theme.F.body, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                            Text("\(t.side == "short" ? "空" : "多") \(Int(t.quantity))")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textSecondary)
                            Spacer()
                            tradeStatusBadge(t)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Theme.textMuted.opacity(0.6))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text("最近交易")
                Spacer()
                Button { showNewTrade = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    @ViewBuilder
    private func tradeStatusBadge(_ t: TradeEntry) -> some View {
        if t.status == "open" {
            Text("持仓")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.branchIndicator)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Theme.branchIndicator.opacity(0.13)))
        } else if let pnl = t.closedPnLPercent {
            let color = pnl >= 0 ? Theme.branchIndicator : Color(red: 0.79, green: 0.54, blue: 0.54)
            Text(String(format: "%+.1f%%", pnl))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.13)))
        } else {
            Text("已平")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
        }
    }

    // MARK: - 添加

    private var addSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("输入代码，如 NVDA", text: $newSymbol)
                    .font(.system(size: Theme.F.body, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    #endif
                    .onSubmit { addTicker() }
                Button {
                    addTicker()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(canAdd ? Theme.branchIndicator : Theme.textMuted.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }
        } footer: {
            Text("美股正股代码，1-5 个大写字母。")
        }
        .listRowBackground(Theme.mainBg)
    }

    private var normalizedInput: String {
        newSymbol.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private var canAdd: Bool {
        let s = normalizedInput
        return (1...5).contains(s.count)
            && s.allSatisfy { $0.isLetter && $0.isASCII }
            && !tickers.contains { $0.symbol == s }
    }

    private func addTicker() {
        guard canAdd else { return }
        modelContext.insert(TickerEntry(profileId: profileId, symbol: normalizedInput))
        try? modelContext.save()
        TradingStore.reportWatchlist(context: modelContext, profileId: profileId)
        newSymbol = ""
    }
}
#endif
