#if PERSONAL_APPS
import SwiftUI
import SwiftData

/// 跑研究 in-flight 全局态（VocabArcheologyTracker 同款：sheet 关了重开仍显示跑中 + 阶段）。
@MainActor
enum TradingResearchTracker {
    static var inFlight: Set<String> = []
    static var stageLabel: [String: String] = [:]
}

/// 标的档案页（纸页风，VocabWordDetailSheet 同构）：$SYMBOL 词典逻辑的落点。
/// 四块可缺拼装：头部关注星 / 研究记录（文件库 trading/<symbol>/ 研报）/ 笔记 / 出处对话（现查）。
struct TickerDetailSheet: View {
    let symbol: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var watched = false
    @State private var displayName: String? = nil
    @State private var reports: [TradingStore.ReportMeta] = []
    @State private var mentions: [Mention] = []
    @State private var researchRunning = false
    @State private var researchStage: String? = nil
    @State private var researchHint: String? = nil
    @State private var trades: [TradeEntry] = []
    @State private var editingTrade: TradeEntry? = nil
    @State private var showNewTrade = false

    /// 研报全文弹层（嵌套 sheet，String 非 Identifiable 的包装先例）。
    private struct ReportOpen: Identifiable {
        let path: String
        var id: String { path }
    }
    @State private var openReport: ReportOpen? = nil

    struct Mention: Identifiable {
        let nodeId: String
        let convTitle: String
        let date: Date?
        let snippet: String
        var id: String { nodeId }
    }

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        NavigationStack {
            // 纸页固定满屏，内容纸内滚动（07-10 纹理上限事故约束，词卡同款）
            ZStack {
                PixelLaceBackdrop(sparse: true).ignoresSafeArea()

                ZStack(alignment: .topLeading) {
                    CrumpledPaperPage(marginX: 42, showRules: false)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            headerBlock
                            reportsBlock
                            tradesBlock
                            TradingNoteSection(symbol: symbol)
                            mentionsBlock
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 30)
                        .padding(.leading, 58)
                        .padding(.trailing, 20)
                        .padding(.bottom, 34)
                        .background(alignment: .topLeading) {
                            ScrollingRuledBackdrop(marginX: 42, topOffset: 12)
                        }
                    }
                    .clipShape(TornPaperShape())
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .navigationTitle("$\(symbol)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                    }
                    .foregroundColor(JournalTheme.pencil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { toggleWatch() } label: {
                        Image(systemName: watched ? "star.fill" : "star")
                    }
                    .foregroundColor(JournalTheme.amber)
                }
            }
        }
        .sheet(item: $openReport) { r in
            reportSheet(path: r.path)
        }
        .sheet(item: $editingTrade, onDismiss: { load() }) { t in
            TradeEditorSheet(profileId: profileId, entry: t)
        }
        .sheet(isPresented: $showNewTrade, onDismiss: { load() }) {
            TradeEditorSheet(profileId: profileId, entry: nil, presetSymbol: symbol)
        }
        .task(id: symbol) {
            load()
            researchRunning = TradingResearchTracker.inFlight.contains(symbol)
            researchStage = TradingResearchTracker.stageLabel[symbol]
        }
        // 研报到货：清跑中态 + 重载列表（成功失败都解锁按钮）
        .onReceive(NotificationCenter.default.publisher(for: .tradingReportArrived)) { notif in
            guard notif.userInfo?["symbol"] as? String == symbol else { return }
            researchRunning = false
            researchStage = nil
            TradingResearchTracker.inFlight.remove(symbol)
            TradingResearchTracker.stageLabel[symbol] = nil
            if (notif.userInfo?["ok"] as? Bool) == true {
                researchHint = nil
                load()
            } else {
                let err = notif.userInfo?["error"] as? String ?? ""
                researchHint = err.isEmpty ? "研究失败了，稍后再试" : err
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tradingResearchProgress)) { notif in
            guard notif.userInfo?["symbol"] as? String == symbol else { return }
            let stage = notif.userInfo?["stage"] as? String ?? ""
            let label = notif.userInfo?["label"] as? String ?? ""
            let text = label.isEmpty ? stage : "\(label) \(stage)"
            researchStage = text
            TradingResearchTracker.stageLabel[symbol] = text
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    // MARK: - 头部

    private var headerBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let name = displayName, !name.isEmpty {
                Text(name)
                    .font(JournalTheme.serif(15))
                    .foregroundColor(JournalTheme.ink)
            } else {
                Text(watched ? "已关注" : "轻点右上角星星加入关注")
                    .font(JournalTheme.serifItalic(12.5))
                    .foregroundColor(JournalTheme.faint)
            }
            Spacer()
        }
    }

    // MARK: - 研究记录（axismundi 研报）

    private var reportsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("research")
                .font(JournalTheme.serifItalic(12))
                .tracking(1.2)
                .foregroundColor(JournalTheme.pencil)

            if reports.isEmpty && !researchRunning {
                Text("还没有研报。点下面「跑一份研究」，二十分钟后来看。")
                    .font(JournalTheme.serifItalic(12.5))
                    .foregroundColor(JournalTheme.faint)
            } else {
                ForEach(reports) { r in
                    Button {
                        openReport = ReportOpen(path: r.path)
                    } label: {
                        HStack(spacing: 8) {
                            Text(r.date)
                                .font(JournalTheme.mono(12))
                                .foregroundColor(JournalTheme.pencil)
                            if let kind = r.kind, kind == "update" || kind == "earnings" {
                                Text(kind)
                                    .font(JournalTheme.serifItalic(10.5))
                                    .foregroundColor(JournalTheme.faint)
                            }
                            if let rating = r.rating {
                                Text(rating + (r.confidence.map { " · C\($0)" } ?? ""))
                                    .font(JournalTheme.mono(11))
                                    .foregroundColor(ratingColor(rating))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(ratingColor(rating).opacity(0.13)))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(JournalTheme.faint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            researchButton
        }
    }

    /// 跑研究按钮：轻点=全量（现状不变）；长按弹三选（全量/增量复核/财报解读，粟粟拍的）。
    private var researchButton: some View {
        VStack(spacing: 6) {
            Menu {
                Button {
                    requestResearch(mode: "full")
                } label: {
                    Label("全量研究（约二十分钟）", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    requestResearch(mode: "update")
                } label: {
                    Label("增量复核（约十分钟）", systemImage: "checkmark.seal")
                }
                Button {
                    requestResearch(mode: "earnings")
                } label: {
                    Label("财报解读（收账）", systemImage: "doc.richtext")
                }
            } label: {
                HStack(spacing: 6) {
                    if researchRunning {
                        ProgressView().controlSize(.small)
                        Text(researchStage.map { "研究中 · \($0)" } ?? "研究中…")
                    } else {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text(reports.isEmpty ? "跑一份研究" : "再跑一份研究")
                    }
                }
                .font(JournalTheme.serifItalic(13.5))
                .foregroundColor(researchRunning ? JournalTheme.faint : JournalTheme.amber)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            } primaryAction: {
                requestResearch(mode: "full")
            }
            .buttonStyle(.plain)
            .disabled(researchRunning)

            if let hint = researchHint {
                Text(hint)
                    .font(JournalTheme.serifItalic(12))
                    .foregroundColor(JournalTheme.faint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 四道闸：本地态 / bridge 连接 / 全局 inFlight / 65min 客户端兜底（hub 崩了按钮不永久灰）。
    private func requestResearch(mode: String = "full") {
        guard !researchRunning else { return }
        guard CCBridgeWebSocketClient.shared.isConnected else {
            researchHint = "跑研究需要 Mac 在线（bridge 未连接）"
            return
        }
        guard !TradingResearchTracker.inFlight.contains(symbol) else { return }
        researchRunning = true
        researchHint = nil
        researchStage = nil
        TradingResearchTracker.inFlight.insert(symbol)
        let sym = symbol
        CCBridgeWebSocketClient.shared.send([
            "type": "ticker_research", "symbol": sym, "mode": mode,
            "request_id": UUID().uuidString,
        ]) { error in
            if error != nil {
                DispatchQueue.main.async {
                    researchRunning = false
                    TradingResearchTracker.inFlight.remove(sym)
                    researchHint = "发送失败，Mac 在线吗？"
                }
            }
        }
        // 客户端兜底：65min 无结果自动解锁（考古链"hub 崩=按钮永久灰"的缺口；盖过 hub 60min 硬顶让 hub 失败帧先到）
        DispatchQueue.main.asyncAfter(deadline: .now() + 65 * 60) {
            if TradingResearchTracker.inFlight.contains(sym) {
                TradingResearchTracker.inFlight.remove(sym)
                TradingResearchTracker.stageLabel[sym] = nil
                NotificationCenter.default.post(
                    name: .tradingReportArrived, object: nil,
                    userInfo: ["symbol": sym, "ok": false, "error": "超时没等到结果（hub 还活着吗？）"]
                )
            }
        }
    }

    private func ratingColor(_ rating: String) -> Color {
        switch rating {
        case "Buy", "Overweight": return JournalTheme.mint
        case "Underweight", "Sell": return JournalTheme.rose
        default: return JournalTheme.pencil
        }
    }

    /// 研报全文（纸页 + 聊天同款渲染：iOS 可划线收词，锚 ticker:<symbol>）。
    @ViewBuilder
    private func reportSheet(path: String) -> some View {
        NavigationStack {
            ZStack {
                PixelLaceBackdrop(sparse: true).ignoresSafeArea()
                ZStack(alignment: .topLeading) {
                    CrumpledPaperPage(marginX: 42, showRules: false)
                    ScrollView {
                        reportMarkdown(TradingStore.stripFrontmatter(
                            (try? FileLibraryStore.read(path, profileId: profileId)) ?? "（读不到这份研报）"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 26)
                            .padding(.leading, 58)
                            .padding(.trailing, 20)
                            .padding(.bottom, 34)
                    }
                    .clipShape(TornPaperShape())
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .navigationTitle("$\(symbol)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { openReport = nil } label: {
                        Image(systemName: "chevron.down")
                    }
                    .foregroundColor(JournalTheme.pencil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private func reportMarkdown(_ md: String) -> some View {
        ChatMarkdownView(text: md, scale: 1.0,
                         nodeId: "ticker:\(symbol)",
                         profileId: profileId)
    }

    // MARK: - 交易卡（仓位故事）

    private var tradesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("trades")
                    .font(JournalTheme.serifItalic(12))
                    .tracking(1.2)
                    .foregroundColor(JournalTheme.pencil)
                Spacer()
                Button { showNewTrade = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundColor(JournalTheme.faint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if trades.isEmpty {
                Text("还没记过 $\(symbol) 的交易。聊天里说一句「180 开了 100 股」就会记下来。")
                    .font(JournalTheme.serifItalic(12.5))
                    .foregroundColor(JournalTheme.faint)
            } else {
                ForEach(trades) { t in
                    tradeCard(t)
                }
            }
        }
    }

    private func tradeCard(_ t: TradeEntry) -> some View {
        Button {
            editingTrade = t
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(t.side == "short" ? "空" : "多") \(Int(t.quantity)) 股 @\(String(format: "%.2f", t.price))")
                        .font(JournalTheme.mono(12))
                        .foregroundColor(JournalTheme.ink)
                    tradeBadge(t)
                    Spacer()
                    Text(t.openedAt.formatted(.dateTime.month().day()))
                        .font(JournalTheme.mono(10.5))
                        .foregroundColor(JournalTheme.faint)
                }
                Text(t.reason)
                    .font(JournalTheme.serif(11.5))
                    .foregroundColor(JournalTheme.pencil)
                    .lineLimit(2)
                if let note = t.reviewNote, !note.isEmpty {
                    Text("复盘：\(note)")
                        .font(JournalTheme.serifItalic(11))
                        .foregroundColor(JournalTheme.faint)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tradeBadge(_ t: TradeEntry) -> some View {
        if t.status == "open" {
            badgeText("持仓", JournalTheme.mint)
        } else if let pnl = t.closedPnLPercent {
            badgeText(String(format: "%+.1f%%", pnl), pnl >= 0 ? JournalTheme.mint : JournalTheme.rose)
        } else {
            badgeText("已平", JournalTheme.pencil)
        }
        if t.status == "closed" && t.reviewNote == nil {
            badgeText("待复盘", JournalTheme.amber)
        }
    }

    private func badgeText(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(JournalTheme.mono(10))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.13)))
    }

    // MARK: - 出处对话（predicate 现查，不落库）

    private var mentionsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("mentions")
                .font(JournalTheme.serifItalic(12))
                .tracking(1.2)
                .foregroundColor(JournalTheme.pencil)

            if mentions.isEmpty {
                Text("聊天里还没提到过 $\(symbol)。")
                    .font(JournalTheme.serifItalic(12.5))
                    .foregroundColor(JournalTheme.faint)
            } else {
                ForEach(mentions) { m in
                    Button {
                        jump(to: m.nodeId)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(m.convTitle)
                                    .font(JournalTheme.serif(12.5))
                                    .foregroundColor(JournalTheme.ink)
                                    .lineLimit(1)
                                Spacer()
                                if let d = m.date {
                                    Text(d.formatted(.dateTime.month().day()))
                                        .font(JournalTheme.mono(10.5))
                                        .foregroundColor(JournalTheme.faint)
                                }
                            }
                            Text(m.snippet)
                                .font(JournalTheme.serif(11.5))
                                .foregroundColor(JournalTheme.pencil)
                                .lineLimit(2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// sheet 收起后再导航（叠层里直接跳会被自己盖住，词卡 0.35s 同款）→ B20 统一入口。
    private func jump(to nodeId: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(
                name: VocabCollector.sourceJumpNotification, object: nil,
                userInfo: ["nodeId": nodeId]
            )
        }
    }

    // MARK: - 数据

    private func load() {
        let pid = profileId
        guard !pid.isEmpty else { return }
        let sym = symbol

        // 关注态 + displayName
        var entryDesc = FetchDescriptor<TickerEntry>(
            predicate: #Predicate<TickerEntry> { $0.profileId == pid && $0.symbol == sym })
        entryDesc.fetchLimit = 1
        let entry = (try? modelContext.fetch(entryDesc))?.first
        watched = entry != nil
        displayName = entry?.displayName

        reports = TradingStore.reports(symbol: sym, profileId: pid)

        var tradeDesc = FetchDescriptor<TradeEntry>(
            predicate: #Predicate<TradeEntry> { $0.profileId == pid && $0.symbol == sym },
            sortBy: [SortDescriptor(\TradeEntry.openedAt, order: .reverse)])
        tradeDesc.fetchLimit = 20
        trades = (try? modelContext.fetch(tradeDesc)) ?? []
        if displayName == nil || displayName?.isEmpty == true {
            // 研报 frontmatter 顺手补公司名（有 ticker 字段的报告一般没有名字，留空即留空）
            displayName = nil
        }

        // 出处：SQLite 层 contains（swiftdata 规则：禁全量 fetch/内存 filter）
        let needle = "$" + sym
        var nodeDesc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> {
                $0.profileId == pid && $0.isTrashed == false && $0.content.contains(needle)
            },
            sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
        )
        nodeDesc.fetchLimit = 20
        let nodes = (try? modelContext.fetch(nodeDesc)) ?? []
        mentions = nodes.map { node in
            var title = "对话"
            let cid = node.conversationId
            var convDesc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.id == cid })
            convDesc.fetchLimit = 1
            if let conv = (try? modelContext.fetch(convDesc))?.first {
                title = conv.title
            }
            let snippet = snippetAround(needle: needle, in: node.content)
            return Mention(nodeId: node.id, convTitle: title, date: node.createTime, snippet: snippet)
        }
    }

    /// 取 $SYM 所在位置前后一小段做预览。
    private func snippetAround(needle: String, in content: String) -> String {
        guard let r = content.range(of: needle) else { return String(content.prefix(60)) }
        let start = content.index(r.lowerBound, offsetBy: -20, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(r.upperBound, offsetBy: 40, limitedBy: content.endIndex) ?? content.endIndex
        return String(content[start..<end]).replacingOccurrences(of: "\n", with: " ")
    }

    private func toggleWatch() {
        let pid = profileId
        guard !pid.isEmpty else { return }
        let sym = symbol
        var desc = FetchDescriptor<TickerEntry>(
            predicate: #Predicate<TickerEntry> { $0.profileId == pid && $0.symbol == sym })
        desc.fetchLimit = 1
        if let existing = (try? modelContext.fetch(desc))?.first {
            modelContext.delete(existing)
            watched = false
            ToastCenter.shared.show("已取消关注 $\(sym)")
        } else {
            modelContext.insert(TickerEntry(profileId: pid, symbol: sym))
            watched = true
            ToastCenter.shared.show("已关注 $\(sym) ⭐")
        }
        try? modelContext.save()   // 双 context 教训：显式 save
        TradingStore.reportWatchlist(context: modelContext, profileId: pid)
    }
}
#endif
