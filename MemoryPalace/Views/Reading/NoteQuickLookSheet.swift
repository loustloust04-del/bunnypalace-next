import SwiftUI

/// 划线就地小窗 = 这一处的时间线（plan-reading-marks P3-2）。读书（BookStore.Note）和聊天等处（ChatHighlight）共用。
/// 点正文划线弹出；命中好几处先选一处。每条带「月-日 时:分」，AI 的回复按时间插在里面；
/// 默认动作是底部「再写一条」，每条你写的可以单独改 / 删；「删掉这处划线」单独放在右上菜单里。
/// 数据改动一律交给宿主（`onChange` 里跑 NoteThreads 的规则，宿主负责存盘和刷新正文）。
struct NoteQuickLookSheet<M: ThreadMark>: View {
    let noteIds: [String]
    let allNotes: [M]
    let assistantName: String
    /// 跑一段 NoteThreads 改动；宿主存盘 + 刷新
    var onChange: ((inout [M]) -> Void) -> Void
    var onShowChat: (String) -> Void
    /// 点在划线里的生词上：顶上给「查生词」入口
    var vocabWord: String? = nil
    var onOpenVocab: (String) -> Void = { _ in }

    @AppStorage("userName") private var userName = "你"
    @Environment(\.dismiss) private var dismiss
    @State private var chosenPlaceId: String? = nil
    @State private var draft = ""
    @State private var editingId: String? = nil
    @State private var editText = ""
    @State private var confirmRemovePlace = false
    /// 调色条改的是哪道：默认最新划的那道（调色条一直展开，免得不知道色块能点），点别的色块换
    @State private var editingStrokeId: String? = nil
    @AppStorage(HighlightPalette.lastColorKey) private var lastHighlightColor = HighlightPalette.userDefault
    @AppStorage(HighlightPalette.lastStyleKey) private var lastHighlightStyle = HighlightStyle.fill.rawValue
    @FocusState private var composerFocused: Bool

    private var places: [MarkPlace<M>] { NoteThreads.places(for: noteIds, in: allNotes) }

    private var place: MarkPlace<M>? {
        if let id = chosenPlaceId { return NoteThreads.place(of: id, in: allNotes) }
        return places.count == 1 ? places.first : nil
    }

    var body: some View {
        Group {
            if let place {
                timeline(place)
            } else if places.isEmpty {
                Color.clear.onAppear { dismiss() }
            } else {
                chooser
            }
        }
        .background(Theme.mainBg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: allNotes.map(\.id)) { _, _ in
            // 这一处被删光了 → 关
            if let id = chosenPlaceId, NoteThreads.place(of: id, in: allNotes) == nil { dismiss() }
            if chosenPlaceId == nil, places.isEmpty { dismiss() }
        }
    }

    // MARK: - 命中好几处：先选一处

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                vocabEntry
                Text("这里有 \(places.count) 处划线")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                ForEach(places) { p in
                    Button { chosenPlaceId = p.id } label: {
                        HStack(alignment: .top, spacing: 10) {
                            strokeChips(p, interactive: false)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("「\(p.primary.quoteText.prefix(60))\(p.primary.quoteText.count > 60 ? "…" : "")」")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                let n = NoteThreads.entries(of: p, in: allNotes).count
                                Text(n == 0 ? "只划了线" : "\(n) 条批注")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .padding(12)
                        .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    // MARK: - 时间线

    private func timeline(_ p: MarkPlace<M>) -> some View {
        let entries = NoteThreads.entries(of: p, in: allNotes)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    vocabEntry
                    header(p)
                    if entries.isEmpty {
                        Text("还没写批注。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.vertical, 6)
                    }
                    ForEach(entries, id: \.id) { entry in
                        entryRow(entry).id(entry.id)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { composer(p, proxy: proxy) }
            .onAppear {
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .confirmationDialog("删掉这处划线？", isPresented: $confirmRemovePlace, titleVisibility: .visible) {
            Button("删掉划线和你写的批注", role: .destructive) {
                onChange { NoteThreads.removePlace(p, in: &$0) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let mine = entries.filter { $0.role != "ai" }.count
            Text((mine > 0 ? "你写的 \(mine) 条批注会一起删掉。" : "这处的每道划线都会删掉。")
                 + (entries.contains { $0.role == "ai" } ? "\(assistantName)写的会留下。" : ""))
        }
    }

    private func header(_ p: MarkPlace<M>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if places.count > 1 {
                    Button { chosenPlaceId = nil } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到这里的几处划线")
                }
                strokeChips(p, interactive: true)
                Spacer()
                if p.strokes.contains(where: { $0.role == "user" }) {
                    Menu {
                        Button("删掉这处划线", systemImage: "trash", role: .destructive) { confirmRemovePlace = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多")
                }
            }
            if let s = paletteStroke(p) {
                let id = s.id
                HighlightPaletteBar(colorHex: s.strokeColorHex, style: s.strokeStyle) { hex, style in
                    lastHighlightColor = hex
                    lastHighlightStyle = style.rawValue
                    onChange { notes in
                        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
                        notes[i].color = hex
                        notes[i].style = style.rawValue
                    }
                } onDelete: {
                    deleteStroke(id, in: p)
                }
            }
            if !p.primary.quoteText.isEmpty {
                Text("「\(p.primary.quoteText.prefix(160))\(p.primary.quoteText.count > 160 ? "…" : "")」")
                    .font(.system(size: 14).italic())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(5)
            }
        }
    }

    /// 删一道划线。这处只剩这一道又写过批注：删它等于连时间线一起删 → 走「删掉这处划线」的确认
    private func deleteStroke(_ id: String, in p: MarkPlace<M>) {
        let others = p.strokes.filter { $0.id != id }
        if others.isEmpty, !NoteThreads.entries(of: p, in: allNotes).isEmpty {
            confirmRemovePlace = true
            return
        }
        editingStrokeId = nil
        onChange { NoteThreads.removeStroke(id, in: &$0) }
    }

    private func paletteStroke(_ p: MarkPlace<M>) -> M? {
        let mine = p.strokes.filter { $0.role == "user" }
        return mine.first { $0.id == editingStrokeId } ?? mine.last
    }

    /// 这处的每道笔画一个小色块；你的那几道长按能单独删
    private func strokeChips(_ p: MarkPlace<M>, interactive: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(p.strokes, id: \.id) { s in
                let chip = strokeChip(s)
                if interactive, s.role == "user" {
                    chip
                        .background(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Theme.textPrimary.opacity(p.strokes.count > 1 && paletteStroke(p)?.id == s.id ? 0.5 : 0),
                                          lineWidth: 1.2))
                        .contentShape(Rectangle())
                        .onTapGesture { editingStrokeId = s.id }
                        .accessibilityLabel("这道划线，点一下改颜色和样式")
                        .accessibilityAddTraits(.isButton)
                        .contextMenu {
                        Button("删掉这道", systemImage: "trash", role: .destructive) {
                            deleteStroke(s.id, in: p)
                        }
                    }
                } else {
                    chip
                }
            }
        }
    }

    private func strokeChip(_ s: M) -> some View {
        let c = HighlightPalette.color(s.strokeColorHex)
        return Group {
            if s.kind == "aiBubble" {
                Capsule().stroke(c, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 18, height: 8)
            } else {
                switch s.strokeStyle {
                case .fill: RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.55)).frame(width: 18, height: 12)
                case .underline: Capsule().fill(c).frame(width: 18, height: 3)
                case .pen: Capsule().fill(c.opacity(0.7)).frame(width: 18, height: 7).rotationEffect(.degrees(-4))
                }
            }
        }
        .frame(width: 22, height: 16)
    }

    // MARK: - 一条

    private func entryRow(_ e: M) -> some View {
        let mine = e.role != "ai"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(mine ? userName : assistantName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(Self.stamp(e.createdAt))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                if mine, editingId != e.id {
                    Menu {
                        Button("改", systemImage: "pencil") {
                            editText = e.content
                            editingId = e.id
                        }
                        Button("删这一条", systemImage: "trash", role: .destructive) {
                            onChange { NoteThreads.deleteEntry(e.id, in: &$0) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 28, height: 22)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("这一条的操作")
                }
            }
            if editingId == e.id {
                TextField("", text: $editText, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...8)
                    .padding(10)
                    .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 16) {
                    Spacer()
                    Button("取消") { editingId = nil }
                        .foregroundStyle(Theme.textSecondary)
                    Button("保存") {
                        let t = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { onChange { NoteThreads.editEntry(e.id, content: t, in: &$0) } }
                        editingId = nil
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                }
                .font(.system(size: 14))
                .buttonStyle(.plain)
            } else {
                Text(e.content)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let mid = e.chatMessageId {
                Button {
                    dismiss()
                    onShowChat(mid)
                } label: {
                    Label("看完整对话", systemImage: "bubble.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(mine ? Theme.sidebarBg : Theme.accent.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 再写一条

    private func composer(_ p: MarkPlace<M>, proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("再写一条…", text: $draft, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                var newId = ""
                onChange { newId = NoteThreads.addEntry(t, to: p, in: &$0) }
                draft = ""
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(newId, anchor: .bottom) } }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? Theme.textMuted.opacity(0.4) : Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("写上")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.mainBg)
    }

    @ViewBuilder private var vocabEntry: some View {
        if let word = vocabWord {
            Button { onOpenVocab(word) } label: {
                Label("查生词「\(word)」", systemImage: "character.book.closed")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    /// 「09-26 21:30」；不是今年的带年份
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
