import SwiftUI

/// 阅读 sheet 左侧抽屉——集中查看「我的批注」+「{assistantName} 的批注」。
///
/// 数据来源：`notes.json`（已有），按 chapter 分组：
/// - 当前章在最前
/// - 其他章按章号降序
/// - 章内按 createdAt 降序（最新优先）
///
/// 三种 kind：
/// - highlight（用户高亮，无 content）→ 🖍 高亮
/// - note      （用户笔记）             → 📝 我的笔记
/// - aiBubble  （AI 批注，role=ai）      → 💬 {assistantName}
///
/// 行为：
/// - 点卡片 → onJumpToChapter(chapter)，sheet 切章
/// - 小克卡片右上「跳对话」→ onShowChat(messageId)，弹 BookChatDrawer 并高亮
/// - 左滑（iOS）/ 右键（macOS）删除 → onDelete(note)
///
/// 互斥：跟「目录抽屉」同侧弹出，BookReaderSheet 用 enum activeDrawer 控制只开一个。
struct BookAnnotationDrawer: View {
    let allNotes: [BookStore.Note]
    let chapters: [BookStore.ChapterMeta]
    let assistantName: String
    let currentChapter: Int
    /// CR-1 失锚集合（原文已变的批注 id，卡片标签用）。
    var brokenNoteIds: Set<String> = []

    @Binding var isPresented: Bool

    /// 点卡片本体——sheet 按 kind 派发：note→编辑, highlight→升级成笔记, aiBubble→跳章
    var onTapNote: (BookStore.Note) -> Void
    var onJumpToChapter: (Int) -> Void
    var onShowChat: (String) -> Void
    var onDelete: (BookStore.Note) -> Void
    /// CR-1 批注成串：给某条批注写回复（parent, content）。
    var onReply: (BookStore.Note, String) -> Void = { _, _ in }
    /// 嵌在 iOS 阅读器底部 sheet 里：不画自己的标题栏 / 固定宽度 / 阴影（sheet 有页签和拖拽条）
    var embedded = false

    @State private var filterMode: FilterMode = .all

    /// 回复输入（alert + TextField）
    @State private var replyingTo: BookStore.Note? = nil
    @State private var replyText = ""

    enum FilterMode { case all, mine, ai }

    private var aiLabel: String { assistantName }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                header
                Divider()
            }
            filterBar
            Divider()
            if filteredNotes.isEmpty {
                emptyState
            } else {
                listBody
            }
        }
        .frame(width: embedded ? nil : 240)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil, alignment: .top)
        .background(Theme.sidebarBg)
        .shadow(color: .black.opacity(embedded ? 0 : 0.1), radius: 8, x: 2, y: 0)
        .alert("回复批注", isPresented: Binding(
            get: { replyingTo != nil },
            set: { if !$0 { replyingTo = nil } }
        )) {
            TextField("写点什么…", text: $replyText)
            Button("取消", role: .cancel) { replyingTo = nil }
            Button("回复") {
                let content = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let parent = replyingTo, !content.isEmpty {
                    onReply(parent, content)
                }
                replyingTo = nil
            }
        } message: {
            if let parent = replyingTo {
                Text("「\(parent.anchorText.prefix(30))\(parent.anchorText.count > 30 ? "…" : "")」")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("批注")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3)) { isPresented = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Filter bar（自画三档 segment 学 Theme 配色，不用系统 Picker 避免蓝色）

    private var filterBar: some View {
        HStack(spacing: 4) {
            filterChip("全部", mode: .all)
            filterChip("我的", mode: .mine)
            filterChip(aiLabel, mode: .ai)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func filterChip(_ title: String, mode: FilterMode) -> some View {
        let selected = filterMode == mode
        return Button {
            filterMode = mode
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? Theme.branchIndicator : Theme.accent.opacity(0.4))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分组排序

    /// 过滤后的**顶层** note（reply 不参与筛选，跟随父卡显示保串完整）
    private var filteredNotes: [BookStore.Note] {
        let topLevel = allNotes.filter { $0.replyTo == nil }
        switch filterMode {
        case .all:  return topLevel
        case .mine: return topLevel.filter { $0.role == "user" }
        case .ai:   return topLevel.filter { $0.role == "ai" }
        }
    }

    /// 父 id → replies（createdAt 升序，对话顺序）
    private var repliesByParent: [String: [BookStore.Note]] {
        Dictionary(grouping: allNotes.filter { $0.replyTo != nil }, by: { $0.replyTo! })
            .mapValues { $0.sorted { $0.createdAt < $1.createdAt } }
    }

    /// (chapter, [note] 按 createdAt 降序)，当前章在最前，其他按章号降序
    private var groupedNotes: [(chapter: Int, notes: [BookStore.Note])] {
        let dict = Dictionary(grouping: filteredNotes, by: \.chapter)
        let entries = dict.map { (chapter: $0.key, notes: $0.value.sorted(by: { $0.createdAt > $1.createdAt })) }
        return entries.sorted { lhs, rhs in
            // 当前章一律在前
            if lhs.chapter == currentChapter { return true }
            if rhs.chapter == currentChapter { return false }
            return lhs.chapter > rhs.chapter
        }
    }

    private func chapterTitle(_ no: Int) -> String {
        chapters.first(where: { $0.no == no })?.title ?? "第 \(no) 章"
    }

    // MARK: - 列表

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(groupedNotes, id: \.chapter) { group in
                    chapterHeader(group.chapter)
                    ForEach(group.notes, id: \.id) { note in
                        let replies = repliesByParent[note.id] ?? []
                        AnnotationCard(
                            note: note,
                            assistantName: assistantName,
                            isBroken: brokenNoteIds.contains(note.id),
                            hasAIReply: replies.contains { $0.role == "ai" },
                            onTap: { onTapNote(note) },
                            onJumpToChapter: { onJumpToChapter(group.chapter) },
                            onShowChat: {
                                if let mid = note.messageId, !mid.isEmpty {
                                    onShowChat(mid)
                                }
                            },
                            onDelete: { onDelete(note) },
                            onReply: {
                                replyText = ""
                                replyingTo = note
                            }
                        )
                        // reply 串：父卡下缩进（一层）
                        ForEach(replies, id: \.id) { reply in
                            ReplyCard(note: reply, assistantName: assistantName,
                                      onDelete: reply.role == "ai" ? nil : { onDelete(reply) })
                                .padding(.leading, 14)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }

    private func chapterHeader(_ chapter: Int) -> some View {
        HStack(spacing: 4) {
            Text("第 \(chapter) 章")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textMuted)
            Text("·")
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
            Text(chapterTitle(chapter))
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if chapter == currentChapter {
                Text("当前")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.branchIndicator)
                    .clipShape(Capsule())
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "highlighter")
                .font(.system(size: 24))
                .foregroundColor(Theme.textMuted.opacity(0.5))
            Text(emptyTitle)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            Text(emptySubtitle)
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch filterMode {
        case .all:  return "还没有批注"
        case .mine: return "你还没标过"
        case .ai:   return "\(assistantName)还没批过"
        }
    }

    private var emptySubtitle: String {
        switch filterMode {
        case .all:  return "长按选段试试「高亮 / 加笔记 / 问\(assistantName)」"
        case .mine: return "长按选段「高亮」或「加笔记」"
        case .ai:   return "长按选段「问\(assistantName)」"
        }
    }
}

// MARK: - 单条批注卡片

private struct AnnotationCard: View {
    let note: BookStore.Note
    let assistantName: String
    var isBroken: Bool = false
    /// 串里有 AI 回复 → 本卡不可删（不可删对方笔迹的级联保护）。
    var hasAIReply: Bool = false
    let onTap: () -> Void
    let onJumpToChapter: () -> Void
    let onShowChat: () -> Void
    let onDelete: () -> Void
    var onReply: () -> Void = {}

    @State private var showDeleteConfirm = false
    @State private var showProtectedAlert = false

    /// 不可删对方笔迹（粟粟已拍）：AI 的卡没有删除入口。
    private var isDeletable: Bool { note.role != "ai" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 顶部：类型标签 + 右上 chat 按钮（仅 aiBubble 有 messageId 时）
            HStack(spacing: 5) {
                Image(systemName: kindIcon)
                    .font(.system(size: 10))
                    .foregroundColor(HighlightPalette.color(note.strokeColorHex))
                Text(kindLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                Spacer(minLength: 0)
                if note.kind == "aiBubble", let mid = note.messageId, !mid.isEmpty {
                    Button {
                        onShowChat()
                    } label: {
                        Image(systemName: "bubble.right")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 选段（anchorText）
            if !note.anchorText.isEmpty {
                Text("「\(note.anchorText.prefix(80))\(note.anchorText.count > 80 ? "…" : "")」")
                    .font(.system(size: 11).italic())
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(3)
            }

            // content（高亮无 content）
            if note.kind != "highlight", !note.content.isEmpty {
                Divider().padding(.vertical, 1)
                Text(note.content)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(6)
            }

            // 时间 + 失锚标签
            HStack {
                if isBroken {
                    Text("⚠️ 原文已变")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
                Text(relativeTime(note.createdAt))
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(8)
        .background(Theme.mainBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isDeletable {
                Button(role: .destructive) { requestDelete() } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        #endif
        .contextMenu {
            Button { onJumpToChapter() } label: {
                Label("跳到这一段", systemImage: "arrow.up.right.square")
            }
            if note.kind == "aiBubble" && (note.messageId?.isEmpty == false) {
                Button { onShowChat() } label: {
                    Label("看完整对话", systemImage: "bubble.right")
                }
            }
            Button { onReply() } label: {
                Label("回复", systemImage: "arrowshape.turn.up.left")
            }
            if isDeletable {
                Button(role: .destructive) { requestDelete() } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .alert("删除这条批注？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { onDelete() }
        } message: {
            Text("「\(note.anchorText.prefix(30))\(note.anchorText.count > 30 ? "…" : "")」")
        }
        .alert("这串里有\(assistantName)的回复", isPresented: $showProtectedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("不能删对方的笔迹，先留着吧")
        }
    }

    private func requestDelete() {
        if hasAIReply {
            showProtectedAlert = true
        } else {
            showDeleteConfirm = true
        }
    }

    private var kindIcon: String {
        switch note.kind {
        case "highlight": return "highlighter"
        case "note":      return "note.text"
        case "aiBubble":  return "bubble.left.fill"
        default:          return "doc.text"
        }
    }

    private var kindLabel: String {
        switch note.kind {
        case "highlight": return "高亮"
        case "note":      return "我的笔记"
        case "aiBubble":  return assistantName
        default:          return note.kind
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let now = Date()
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
        if delta < 86400 { return "\(Int(delta / 3600)) 小时前" }
        if delta < 86400 * 7 { return "\(Int(delta / 86400)) 天前" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_Hans_CN")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}

// MARK: - reply 小卡（CR-1 批注成串，父卡下缩进一层）

private struct ReplyCard: View {
    let note: BookStore.Note
    let assistantName: String
    /// nil = 不可删（AI 的回复——不可删对方笔迹）。
    var onDelete: (() -> Void)? = nil

    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.system(size: 8))
                    .foregroundColor(Theme.textMuted)
                Text(note.role == "ai" ? assistantName : "你")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                Spacer(minLength: 0)
            }
            Text(note.content)
                .font(.system(size: 11))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(4)
        }
        .padding(7)
        .background(Theme.mainBg.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contextMenu {
            if onDelete != nil {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .alert("删除这条回复？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { onDelete?() }
        }
    }
}
