import SwiftUI
import SwiftData
import SwiftStreamingMarkdown

/// 生词卡的文字（research-chat-cards §14）
enum WordCardText {
    static func summary(status: VocabStatus?, inNotebook: Bool) -> String {
        let label: String? = status.map {
            switch $0 {
            case .known: return "认识"
            case .slow: return "不熟"
            case .unknown: return "不认识"
            }
        }
        switch (inNotebook, label) {
        case (true, let l?): return "在词库 · \(l)"
        case (true, nil): return "在词库"
        case (false, let l?): return "没收进词库 · \(l)"
        case (false, nil): return "还没收进词库"
        }
    }

    static func added(_ word: String) -> String { "把 \(word) 加进了词库" }
    static func markedKnown(_ word: String) -> String { "把 \(word) 标成了认识" }
}

/// 生词卡（research-chat-cards §14）：原形 + 音标 + 词典释义 + 生词本里的状态；
/// 加入词库 / 认识 / 打开词条，点了才写，写完捎带给模型。只读（nodeId 为 nil）时按钮不能点
struct WordCardView: View {
    let card: WordCard
    let nodeId: String?
    /// 归一后的原形（后台算：第一次要加载词典）；没算好先用原词
    @State private var canonical: String?
    @State private var entry: VocabDictStore.Entry?
    @State private var showDetail = false

    var body: some View {
        let word = canonical ?? card.word
        ChatCardShell(kindLabel: "生词") {
            WordCardContent(word: word, note: card.note, entry: entry, rawWord: card.word, nodeId: nodeId) { showDetail = true }
                .id(word)   // 原形算出来后换查询
        }
        // sheet 挂在卡壳外面：卡壳把配色钉成浅色，词条页要跟系统走
        .sheet(isPresented: $showDetail) {
            VocabWordDetailSheet(word: word)
        }
        .task(id: card.word) {
            let raw = card.word
            let result = await Task.detached(priority: .userInitiated) { () -> (String, VocabDictStore.Entry?) in
                let w = VocabCollector.canonicalize(raw)
                let key = w.isEmpty ? raw : w
                return (key, VocabDictStore.entry(for: key))
            }.value
            canonical = result.0
            entry = result.1
        }
    }
}

private struct WordCardContent: View {
    let word: String
    let note: String?
    let entry: VocabDictStore.Entry?
    let rawWord: String
    let nodeId: String?
    let openDetail: () -> Void

    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(\.modelContext) private var modelContext
    @Query private var progress: [VocabProgress]

    init(word: String, note: String?, entry: VocabDictStore.Entry?, rawWord: String, nodeId: String?, openDetail: @escaping () -> Void) {
        self.word = word
        self.note = note
        self.entry = entry
        self.rawWord = rawWord
        self.nodeId = nodeId
        self.openDetail = openDetail
        _progress = Query(filter: #Predicate<VocabProgress> { $0.word == word })
    }

    private var row: VocabProgress? { progress.first }
    private var inNotebook: Bool { row?.sourceBookRef != nil }
    private var isKnown: Bool { row?.status == .known }
    private var interactive: Bool { nodeId != nil && viewModel?.selectedConversation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(word).font(.title3.weight(.semibold))
                if let p = entry?.p, !p.isEmpty {
                    Text("/\(p)/").font(.subheadline).foregroundStyle(CodeBlockStyle.label)
                }
            }
            if let t = entry?.t, !t.isEmpty {
                Text(t)
                    .font(.subheadline)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(CodeBlockStyle.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(WordCardText.summary(status: row?.status, inNotebook: inNotebook))
                .font(.caption)
                .foregroundStyle(CodeBlockStyle.label)
            HStack(spacing: 16) {
                button(inNotebook ? "已在词库" : "加入词库", systemImage: "plus.square.on.square", enabled: interactive && !inNotebook) {
                    addToNotebook()
                }
                button(isKnown ? "已认识" : "认识", systemImage: "checkmark", enabled: interactive && !isKnown) {
                    markKnown()
                }
                button("打开词条", systemImage: "book", enabled: true) { openDetail() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(enabled ? Theme.branchIndicator : CodeBlockStyle.label)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 同划词收生词（ChatMarkdownView.collect）：生词本 + 开着自动复习就进牌堆
    private func addToNotebook() {
        guard let viewModel, let conversationId = viewModel.selectedConversation?.id,
              let collected = VocabCollector.collectManually(rawText: rawWord, anchor: note, chatNodeId: nodeId,
                                                             context: modelContext) else {
            ToastCenter.shared.show("这个词收不了")
            return
        }
        if VocabCollector.autoReviewEnabled {
            VocabCardStore.addIfAbsent(word: collected, source: "chat", dir: VocabCollector.reviewDeckDir)
        }
        viewModel.cardEventOutbox.add(WordCardText.added(collected), conversationId: conversationId, key: "word-add:\(collected)")
        ToastCenter.shared.show("已收「\(collected)」")
    }

    /// 标认识：只写状态，不动复习卡组（粟粟 10-01 拍板）
    private func markKnown() {
        guard let viewModel, let conversationId = viewModel.selectedConversation?.id else { return }
        VocabSessionStore.mark(word: word, status: .known, seconds: nil, note: nil, source: "chat", context: modelContext)
        viewModel.cardEventOutbox.add(WordCardText.markedKnown(word), conversationId: conversationId, key: "word-known:\(word)")
    }
}
