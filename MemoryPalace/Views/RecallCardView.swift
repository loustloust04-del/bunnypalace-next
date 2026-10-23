import SwiftUI
import SwiftData

/// 召回可见性卡片：「💭 想起来了 N 件事」——本轮注入命中的记忆逐条可见，👍/👎 写回检索权重。
/// 折叠结构用 Button + @State（DisclosureGroup 在 LazyVStack + 自定义 bubble 里吃点击，thinking 卡踩过）。
/// 数据来自 node.recallHitsData（发送时组装链落库），渲染不回查记忆库。
/// 显示模式（隐藏 / 原地 / 弹出）见 plan-disclosure-modes。
struct RecallCardView: View {
    let node: MessageNode

    #if (DEBUG || PERF_BENCH) && os(iOS)
    init(node: MessageNode) {
        self.node = node
        if AirPerfProbe.enabled { PerfCount.hit("recallCardInit") }
    }
    #endif

    @AppStorage("fontScale") private var fontScale = 1.2
    private var labelSize: CGFloat { 13.5 * (fontScale > 0 ? fontScale : 1.2) * 0.95 }
    @AppStorage(DisclosureKind.recall.key) private var modeRaw = DisclosureKind.recall.migratedDefault.rawValue
    @State private var expanded = false
    @State private var showSheet = false

    private var mode: DisclosureMode { DisclosureMode(rawValue: modeRaw) ?? .inline }
    /// 检索路标签（PersonaSettingsTab 也在用）
    static let retrieverLabels = RecallHitList.retrieverLabels

    var body: some View {
        let hits = node.recallHits
        if mode != .hidden, !hits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if mode == .sheet { showSheet = true } else { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        RecallPalaceMark()
                            .stroke(Theme.textMuted, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                            .frame(width: labelSize * 0.9, height: labelSize * 0.9)
                            .accessibilityHidden(true)
                        Text("想起来了 \(hits.count) 件事" + (RecallPreview.text(hits).map { " · \($0)" } ?? ""))
                            .font(.system(size: labelSize))
                            .lineLimit(1)
                        Image(systemName: expanded && mode == .inline ? "chevron.down" : "chevron.right")
                            .font(.system(size: labelSize * 0.72, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded, mode == .inline {
                    RecallHitList(node: node, rowSpacing: 12, snippetSize: 14, metaSize: 11)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.accent.opacity(0.4)))
                }
            }
            .sheet(isPresented: $showSheet) {
                DisclosureSheet(title: "想起来了") {
                    RecallHitList(node: node, rowSpacing: 14, snippetSize: 15, metaSize: 11)
                }
            }
        }
    }
}

enum RecallPreview {
    static func text(_ hits: [InjectionHit]) -> String? {
        let relevant = hits.filter { $0.retrieverId != "fullFallback" && $0.score != nil }
        let hit = relevant.max { ($0.score ?? 0) < ($1.score ?? 0) } ?? hits.first
        return hit.flatMap { $0.snippet.isEmpty ? nil : $0.snippet }
    }
}

/// 召回行显示什么（记忆查看升级，粟粟 10-03）：按记忆库里现在的样子，不是发送那一刻的快照
enum RecallHitDisplay {
    enum State: Equatable { case active, disabled, deleted }

    static func state(exists: Bool, supersededAt: Date?) -> State {
        guard exists else { return .deleted }
        return supersededAt == nil ? .active : .disabled
    }

    /// 改过的显示新内容；删掉了就显示当时的
    static func text(live: String?, snapshot: String) -> String { live ?? snapshot }

    static func sourceLine(conversationTitle: String?, quote: String?) -> String {
        let q = quote.flatMap { $0.isEmpty ? nil : "“\($0)”" }
        switch (conversationTitle.flatMap { $0.isEmpty ? nil : $0 }, q) {
        case let (t?, q?): return "来自「\(t)」：\(q)"
        case let (t?, nil): return "来自「\(t)」"
        case let (nil, q?): return "原话：\(q)"
        default: return "手动添加 / 来源不明"
        }
    }
}

/// 卡上的操作：走记忆库同一套接口（同记忆面板），不另起一套
@MainActor
enum RecallActions {
    /// 改内容：去掉首尾空白，空的不存；关键词和出处原样留着
    @discardableResult
    static func saveEdit(_ memory: Memory, text: String, context: ModelContext) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }
        try? SwiftDataMemoryStore().update(id: memory.id, content: content, keywords: memory.keywords,
                                           sourceQuote: memory.sourceQuote, sourceNodeId: memory.sourceNodeId, context: context)
        try? context.save()
        return true
    }

    /// 停用 ↔ 恢复（软失效：出排名不出库，同记忆面板的删除第一步）
    static func toggleDisabled(_ memory: Memory, context: ModelContext) {
        memory.supersededAt = memory.supersededAt == nil ? Date() : nil
        memory.updatedAt = Date()
        try? context.save()
    }
}

/// 逐条命中行（原地展开和 sheet 共用）：现在的内容 + 检索路/相关度 + 👍👎；
/// 点一条展开：出处（哪段对话 + 原话）+ 改 · 停用 / 恢复 · 跳到来源（粟粟 10-03：卡上不放删除，删干净去记忆面板）
struct RecallHitList: View {
    let node: MessageNode
    var rowSpacing: CGFloat = 6
    /// 原地 11/9；sheet 里用正文号 15/11
    var snippetSize: CGFloat = 11
    var metaSize: CGFloat = 9

    @Environment(\.modelContext) private var modelContext
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @AppStorage("mem_recall_feedback") private var feedbackEnabled = true
    @Query private var live: [Memory]
    @State private var openIds: Set<UUID> = []
    @State private var editing: Memory?
    @State private var editText = ""

    init(node: MessageNode, rowSpacing: CGFloat = 6, snippetSize: CGFloat = 11, metaSize: CGFloat = 9) {
        self.node = node
        self.rowSpacing = rowSpacing
        self.snippetSize = snippetSize
        self.metaSize = metaSize
        let ids = node.recallHits.map(\.memoryId)
        _live = Query(filter: #Predicate<Memory> { ids.contains($0.id) })
    }

    static let retrieverLabels: [String: String] = [
        "vector": "语义", "keyword": "关键词", "graph": "关联", "fullFallback": "兜底",
    ]

    var body: some View {
        let hits = node.recallHits
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(Array(hits.enumerated()), id: \.element.memoryId) { i, hit in
                hitRow(hit, index: i, memory: byId[hit.memoryId])
            }
        }
        .sheet(item: $editing) { memory in
            NavigationStack {
                TextEditor(text: $editText)
                    .padding()
                    .navigationTitle("改这条记忆")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                if RecallActions.saveEdit(memory, text: editText, context: modelContext) { editing = nil }
                            }
                            .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
            .frame(minWidth: 320, minHeight: 220)
        }
    }

    @ViewBuilder
    private func hitRow(_ hit: InjectionHit, index: Int, memory: Memory?) -> some View {
        let state = RecallHitDisplay.state(exists: memory != nil, supersededAt: memory?.supersededAt)
        let open = openIds.contains(hit.memoryId)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RecallHitDisplay.text(live: memory?.content, snapshot: hit.snippet))
                        .font(.system(size: snippetSize))
                        .foregroundColor(Theme.textSecondary)
                        .strikethrough(state != .active)
                        .opacity(state == .active ? 1 : 0.6)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(metaLine(hit) + (state == .disabled ? " · 已停用" : state == .deleted ? " · 已删除" : ""))
                        .font(.system(size: metaSize))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard memory != nil else { return }
                    if open { openIds.remove(hit.memoryId) } else { openIds.insert(hit.memoryId) }
                }
                Spacer(minLength: 8)
                if feedbackEnabled {
                    HStack(spacing: 10) {
                        voteButton(hit, index: index, vote: 1, symbol: "hand.thumbsup", active: Theme.branchIndicator)
                        voteButton(hit, index: index, vote: -1, symbol: "hand.thumbsdown", active: Theme.danger.opacity(0.8))
                    }
                }
            }
            if open, let memory {
                VStack(alignment: .leading, spacing: 6) {
                    Text(RecallHitDisplay.sourceLine(conversationTitle: sourceTitle(memory), quote: memory.sourceQuote))
                        .font(.system(size: metaSize))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        action("改", "pencil") { editText = memory.content; editing = memory }
                        action(state == .disabled ? "恢复" : "停用", state == .disabled ? "arrow.uturn.backward" : "pause.circle") {
                            RecallActions.toggleDisabled(memory, context: modelContext)
                        }
                        if memory.sourceConversationId != nil, viewModel != nil {
                            action("跳到来源", "arrow.up.forward") { jumpToSource(memory) }
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).font(.system(size: metaSize + 1, weight: .medium))
                .foregroundColor(Theme.branchIndicator)
        }
        .buttonStyle(.plain)
    }

    /// 展开时才查来源对话的标题
    private func sourceTitle(_ memory: Memory) -> String? {
        guard let cid = memory.sourceConversationId else { return nil }
        let d = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == cid })
        return (try? modelContext.fetch(d).first)?.title
    }

    /// 同记忆面板的「跳转」：打开那段对话，定位到当时那条消息
    private func jumpToSource(_ memory: Memory) {
        guard let viewModel, let cid = memory.sourceConversationId else { return }
        let d = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == cid })
        guard let conv = try? modelContext.fetch(d).first else { return }
        if let nodeId = memory.sourceNodeId {
            viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conv, context: modelContext)
        } else {
            viewModel.loadConversation(conv, context: modelContext)
        }
    }

    /// 兜底路的分数是衰减权重不是相关度，措辞区分（不撒谎）
    private func metaLine(_ hit: InjectionHit) -> String {
        var parts: [String] = [Self.retrieverLabels[hit.retrieverId] ?? hit.retrieverId]
        if let s = hit.score {
            parts.append(String(format: hit.retrieverId == "fullFallback" ? "权重 %.2f" : "相关 %.2f", s))
        }
        return parts.joined(separator: " · ")
    }

    private func voteButton(_ hit: InjectionHit, index: Int, vote: Int, symbol: String, active: Color) -> some View {
        Button {
            applyVote(vote, at: index)
        } label: {
            Image(systemName: hit.vote == vote ? "\(symbol).fill" : symbol)
                .font(.system(size: 11))
                .foregroundColor(hit.vote == vote ? active : Theme.textMuted.opacity(0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 同票再点 = no-op；改投走 applyFeedback 的对称回滚
    private func applyVote(_ vote: Int, at index: Int) {
        var hits = node.recallHits
        guard index < hits.count, hits[index].vote != vote else { return }
        let prev = hits[index].vote
        try? SwiftDataMemoryStore().applyFeedback(
            id: hits[index].memoryId, vote: vote, previousVote: prev, context: modelContext)
        hits[index].vote = vote
        node.setRecallHits(hits)
        try? modelContext.save()
    }
}
