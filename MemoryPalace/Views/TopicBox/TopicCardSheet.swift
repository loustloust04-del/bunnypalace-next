#if PERSONAL_APPS
#if DEBUG
import SwiftUI

/// 问题卡详情：问题正文 + 回应流（人机双色平行）+ 写回应 + 「听听 TA 怎么想」。
/// 正文/回应走聊天同款渲染（两端 ChatMarkdownView，划词收生词，合成锚 topic:<relPath>）。
struct TopicCardSheet: View {
    let relPath: String
    let profileId: String
    var onChanged: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    @State private var card: TopicCard? = nil
    @State private var draft = ""
    @State private var isThinking = false
    /// sheet 内轻提示——ToastCenter 挂主窗口根层会被本 sheet 盖住（读书 sheet 自带 toast 同因）
    @State private var hint: String? = nil
    /// 深写：复用文件库的 md 编辑器（live preview / 双链 / find），编辑卡片原文 .md
    @State private var showEditor = false
    @State private var wikiWordCard: WikiTarget? = nil

    private struct WikiTarget: Identifiable {
        let word: String
        var id: String { word }
    }

    private var rootURL: URL { FileLibraryStore.libraryRoot(profileId: profileId) }

    /// 人=薄荷 / AI=玫瑰（共读批注双色先例）/ 认不出的署名=铅笔灰。
    private func roleColor(_ author: String) -> Color {
        if author == userName { return Theme.branchIndicator }
        if author == assistantName { return Color(red: 0.79, green: 0.54, blue: 0.54) }
        return Theme.textMuted
    }

    var body: some View {
        NavigationStack {
            Group {
                if let card {
                    content(card)
                } else {
                    Text("这张卡不见了——可能文件被移走或删除了")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.mainBg)
            .navigationTitle("话题")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if let card, !card.isArchived {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                archiveCard()
                            } label: {
                                Label("归档", systemImage: "archivebox")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
        .onAppear { reload() }
        .sheet(isPresented: $showEditor, onDismiss: { reload() }) {
            editorSheet
                .sheet(item: $wikiWordCard) { target in
                    VocabWordDetailSheet(word: target.word)
                }
        }
    }

    /// 复用文件库 md 编辑器编辑卡片原文（frontmatter + 回应全在里面，宽松解析兜住任意结构）。
    private var editorSheet: some View {
        let raw = (try? String(contentsOf: rootURL.appendingPathComponent(relPath), encoding: .utf8)) ?? ""
        return FileEditorSheet(
            path: relPath,
            initialContent: raw,
            initialModifiedAt: FileLibraryStore.modifiedAt(relPath, profileId: profileId),
            currentModifiedAt: { FileLibraryStore.modifiedAt(relPath, profileId: profileId) },
            reloadExternalContent: {
                let latest = try FileLibraryStore.read(relPath, profileId: profileId)
                return ReloadedFileContent(content: latest,
                                           modifiedAt: FileLibraryStore.modifiedAt(relPath, profileId: profileId))
            },
            onSave: { newContent, baselineContent in
                // R11：同 FileLibraryPanelView，按内容哈希判冲突而不是 mtime
                if FileLibraryStore.hasExternalConflict(relPath, profileId: profileId, baselineContent: baselineContent) {
                    throw NSError(domain: "TopicBox", code: -9,
                                  userInfo: [NSLocalizedDescriptionKey: "文件已在外部修改，请关闭重开后再保存。"])
                }
                try FileLibraryStore.write(relPath, content: newContent, profileId: profileId)
                reload()
                onChanged?()
            },
            onCancel: { showEditor = false },
            onOpenWikiLink: { openWikiTarget($0) }
        )
    }

    /// [[双链]]：裸词 / vocab/ 路径 → 词卡（不建文件）；其它路径话题盒不管理，忽略。
    private func openWikiTarget(_ target: String) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !trimmed.contains("/") {
            wikiWordCard = WikiTarget(word: VocabCollector.normalize(trimmed))
        } else if trimmed.hasPrefix("vocab/") {
            let tail = trimmed.dropFirst("vocab/".count)
            let word = tail.hasSuffix(".md") ? String(tail.dropLast(3)) : String(tail)
            wikiWordCard = WikiTarget(word: word)
        }
    }

    private func reload() {
        card = TopicBoxStore.loadCard(relPath: relPath, rootURL: rootURL)
    }

    private func showHint(_ msg: String) {
        withAnimation(.easeInOut(duration: 0.18)) { hint = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.18)) {
                if hint == msg { hint = nil }
            }
        }
    }

    // MARK: - Content

    private func content(_ card: TopicCard) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(card)
                    bodyMarkdown(card.body, anchorSuffix: "body")

                    if !card.responses.isEmpty {
                        Divider().padding(.vertical, 2)
                        responsesFlow(card)
                    }
                }
                .padding(16)
            }

            if !card.isArchived {
                Divider()
                inputBar(card)
            }
        }
    }

    private func header(_ card: TopicCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PixelIcon(bitmap: PixelGlyph.lightbulb, size: 15, color: Theme.branchIndicator)
                if let author = card.author, !author.isEmpty {
                    Text("\(author) 存的")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
                if let created = card.created, !created.isEmpty {
                    Text(created)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
                Spacer()
            }
            if card.source != nil {
                TopicSourceChip(source: card.source!, profileId: profileId)
            }
        }
    }

    private func responsesFlow(_ card: TopicCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(card.responses.enumerated()), id: \.offset) { idx, response in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(roleColor(response.author).opacity(0.75))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(response.author.isEmpty ? "无名" : response.author)
                                .font(.system(size: Theme.F.caption, weight: .semibold))
                                .foregroundColor(roleColor(response.author))
                            if !response.date.isEmpty {
                                Text(response.date)
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted.opacity(0.7))
                            }
                        }
                        bodyMarkdown(response.text, anchorSuffix: "r\(idx)")
                    }
                }
            }
        }
    }

    /// 聊天同款渲染：划词收生词/划线（合成锚随小节区分），两端同一份。
    @ViewBuilder
    private func bodyMarkdown(_ text: String, anchorSuffix: String) -> some View {
        if text.isEmpty {
            EmptyView()
        } else {
            ChatMarkdownView(text: text, scale: 1.0,
                             nodeId: "topic:\(relPath)#\(anchorSuffix)",
                             profileId: profileId)
        }
    }

    // MARK: - Input

    private func inputBar(_ card: TopicCard) -> some View {
        VStack(spacing: 8) {
            if let hint {
                Text(hint)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.branchIndicator.opacity(0.14)))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("写下想法…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: Theme.F.body))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.sidebarBg.opacity(0.8))
                    )

                Button {
                    saveResponse()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Theme.textMuted.opacity(0.4) : Theme.branchIndicator
                        )
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                Button {
                    askAssistant(card)
                } label: {
                    HStack(spacing: 5) {
                        if isThinking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                        }
                        Text(isThinking ? "想着呢…" : "听听 TA 怎么想")
                            .font(.system(size: Theme.F.secondary, weight: .medium))
                    }
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .disabled(isThinking)

                Button {
                    showEditor = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12))
                        Text("在编辑器里写")
                            .font(.system(size: Theme.F.secondary, weight: .medium))
                    }
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent.opacity(0.6)))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.mainBg)
    }

    // MARK: - Actions

    private func saveResponse() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try TopicBoxStore.appendResponse(
                relPath: relPath, date: TopicBoxStore.todayString(),
                author: userName, text: text, rootURL: rootURL)
            draft = ""
            reload()
            onChanged?()
        } catch {
            showHint("没存上：\(error.localizedDescription)")
        }
    }

    private func askAssistant(_ card: TopicCard) {
        guard let providerManager else {
            showHint("先在设置里配好模型")
            return
        }
        guard TopicResponder.resolveChatModel(providerManager: providerManager) != nil else {
            showHint("先在设置里选一个聊天模型")
            return
        }
        isThinking = true
        Task { @MainActor in
            defer { isThinking = false }
            guard let text = await TopicResponder.respond(
                card: card, providerManager: providerManager,
                userName: userName, assistantName: assistantName
            ) else {
                showHint("TA 现在想不出来，过会儿再试")
                return
            }
            do {
                try TopicBoxStore.appendResponse(
                    relPath: relPath, date: TopicBoxStore.todayString(),
                    author: assistantName, text: text, rootURL: rootURL)
                reload()
                onChanged?()
            } catch {
                showHint("没存上：\(error.localizedDescription)")
            }
        }
    }

    private func archiveCard() {
        do {
            try TopicBoxStore.archive(relPath: relPath, rootURL: rootURL)
            ToastCenter.shared.show("已归档")
            onChanged?()
            dismiss()
        } catch {
            showHint("归档失败：\(error.localizedDescription)")
        }
    }
}

/// 出处 chip：chat#<nodeId> 可点跳回原对话（词详情出处同款：收卡→0.35s 后 post 跳转，
/// 叠层里直接跳会被自己盖住）；book:<safeName>#page/chapter 显示《书名》·位置（
/// 词详情书出处同款只展示——阅读器无带位开书通道，不新凿，记 review 债）。
struct TopicSourceChip: View {
    let source: String
    let profileId: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let nodeId = chatNodeId {
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(
                        name: VocabCollector.sourceJumpNotification, object: nil,
                        userInfo: ["nodeId": nodeId]
                    )
                }
            } label: {
                chipLabel.contentShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            chipLabel
        }
    }

    private var chipLabel: some View {
        Label(displayText, systemImage: iconName)
            .font(.system(size: Theme.F.caption))
            .foregroundColor(chatNodeId != nil ? Theme.textSecondary : Theme.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.sidebarBg.opacity(0.8)))
    }

    private var chatNodeId: String? {
        guard source.hasPrefix("chat#") else { return nil }
        let id = String(source.dropFirst("chat#".count))
        return id.isEmpty ? nil : id
    }

    private var iconName: String {
        source.hasPrefix("book:") ? "book.closed" : "bubble.left"
    }

    private var displayText: String {
        if source.hasPrefix("chat#") { return "来自对话" }
        if source.hasPrefix("book:") {
            let safeName = String(source.dropFirst("book:".count).prefix { $0 != "#" })
            let bookName = BookStore.loadIndex(safeName: safeName, profileId: profileId)?.name ?? "书"
            if let range = source.range(of: "#page=") {
                return "《\(bookName)》· 第 \(source[range.upperBound...]) 页"
            }
            if let range = source.range(of: "#chapter=") {
                return "《\(bookName)》· 第 \(source[range.upperBound...]) 章"
            }
            return "《\(bookName)》"
        }
        return source
    }
}
#endif
#endif
