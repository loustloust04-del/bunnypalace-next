import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 全屏阅读 sheet（fullScreenCover / macOS .sheet）。MVP：
/// - 顶部 toolbar：关闭 / 书名+章节 / 目录按钮
/// - 中部：BookReaderWebView 渲染当前章节
/// - 底部：上一章 / 进度 / 下一章
/// - 章节目录抽屉（侧滑）
/// - 阅读进度自动保存（scroll debounce 1s 写 index.json + BookEntry）
///
/// M3 会在这里加：选段菜单（复制/高亮/加笔记/问小克）+ 底部抽屉 mini 对话
struct BookReaderSheet: View {
    let bookSafeName: String
    let profileId: String
    /// CR-3：生词出处 chip 跳回用——指定则覆盖存储的阅读进度章节。
    var initialChapter: Int? = nil
    /// 章节内字符 offset（sourceBookRef 第三段），按字符比例近似滚动定位。
    var initialAnchorOffset: Int? = nil
    /// page2 外壳里阅读器改内嵌（plan-page2-app-shell §2.9），关闭交给书架；没传就照旧 dismiss
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    private func close() { if let onClose { onClose() } else { dismiss() } }
    @Environment(\.modelContext) private var modelContext

    // M3-B：问 AI → 楼层主对话需要的依赖
    @Environment(ConversationViewModel.self) private var viewModel
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    @AppStorage("assistantName") private var assistantName = "助手"

    // M3-B：问完后的反馈 toast
    @State private var askToast: String? = nil
    #if os(iOS)
    // 沉浸式阅读器的浮出控件
    @State private var showChrome = false
    /// 刚划的那道线：底部浮调色条改它的颜色 / 样式（iOS）
    @State private var paletteNoteId: String? = nil
    @State private var showFontPanel = false
    @State private var chromeHideTask: Task<Void, Never>? = nil
    @State private var scrubChapter: Double? = nil
    @State private var showQuotes = false
    @State private var readerSheetTab: ReaderSheetTab = .catalog
    #endif
    /// 书摘「翻到这一页」：章节内字符 offset，loadChapter 时换算成滚动比例
    @State private var pendingAnchorOffset: Int? = nil

    // M3-B-2：底部抽屉 mini 对话（学 page1 ModelPickerPopover 的 .sheet+presentationDetents）
    @State private var showChatDrawer = false

    // M3.5：点击 AI 划线后高亮抽屉里对应的消息（通过 note.messageId 关联到 user node）
    @State private var highlightedNoteId: String? = nil

    @State private var index: BookStore.BookIndex?
    @State private var currentChapter: Int = 1
    @State private var chapterText: String = ""
    @State private var initialScrollRatio: Double? = nil
    /// 每次要跳到某处 +1（传给 WebView：同一章内容没变也能滚过去）
    @State private var scrollToken = 0
    @State private var latestScrollRatio: Double = 0
    @State private var renderedHTML: String = ""
    @State private var loadError: String?

    /// 左侧抽屉互斥（目录 / 批注 只能开一个）
    enum ActiveDrawer { case catalog, annotations }
    @State private var activeDrawer: ActiveDrawer? = nil

    // F1-F3 阅读器体感包
    @AppStorage("readerFontSize") private var readerFontSize = ChapterHTMLRenderer.FontSize.md.rawValue
    @State private var bookmarks: [BookStore.Bookmark] = []
    @State private var bookmarkJumpRatio: Double? = nil
    @State private var catalogQuery = ""
    @State private var searchHits: [BookSearch.Hit] = []
    @State private var searchTask: Task<Void, Never>? = nil

    /// 进度持久化 debounce
    @State private var saveTask: Task<Void, Never>? = nil

    // M3：当前章节的所有笔记（含高亮/笔记/AI 批注 anchor），用于渲染时着色
    @State private var chapterNotes: [BookStore.Note] = []

    // 批注抽屉用：全书所有 notes（含其他章）
    @State private var allNotes: [BookStore.Note] = []

    // CR-1 失锚集合（打开批注抽屉时检测，卡片标「原文已变」）
    @State private var brokenNoteIds: Set<String> = []

    // R4 就地小窗：点正文划线命中的批注 id（非空 = 弹小窗）
    @State private var quickLookNoteIds: [String]? = nil
    @State private var quickLookVocabWord: String? = nil
    @AppStorage(HighlightPalette.lastColorKey) private var lastHighlightColor = HighlightPalette.userDefault
    @AppStorage(HighlightPalette.lastStyleKey) private var lastHighlightStyle = HighlightStyle.fill.rawValue

    // 从批注抽屉跳主对话用——绕过 highlightedNoteId 那条 noteId 路径，直接给 MessageNode.id
    @State private var directHighlightMessageId: String? = nil

    // M3：选段状态——JS 报上来后弹菜单/笔记/问小克
    @State private var selectedRange: SelectedRange?
    @State private var showNoteEditor = false
    #if PERSONAL_APPS
    #if DEBUG
    @State private var topicRequest: TopicComposeRequest? = nil
    #endif
    #endif
    @State private var noteEditorContent = ""
    /// 非空 = 编辑模式（改已有 note），空 = 新增模式（从选段加 note）

    struct SelectedRange: Equatable {
        let text: String
        let start: Int
        let end: Int
        let chapter: Int
    }

    var body: some View {
        Group {
            if let err = loadError {
                errorView(err)
            } else if index == nil {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                readerBody
            }
        }
        .onAppear { loadBook() }
        .onChange(of: currentChapter) { _, newValue in
            loadChapter(newValue, resetScroll: true)
        }
        // CR-2 阅读打点：sheet 活着 = 在读，60s 一跳（iOS 切后台 Task 挂起，天然不计后台）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, index != nil else { continue }
                ReadingSignals.logTick(
                    bookSafeName: bookSafeName,
                    bookDisplayName: index?.name ?? bookSafeName,
                    chapter: currentChapter,
                    profileId: profileId
                )
            }
        }
        // R4 批注就地小窗
        .sheet(isPresented: Binding(
            get: { quickLookNoteIds != nil },
            set: { if !$0 { quickLookNoteIds = nil } }
        )) {
            NoteQuickLookSheet(
                noteIds: quickLookNoteIds ?? [],
                allNotes: allNotes,
                assistantName: assistantName,
                onChange: { change in applyNotes(change) },
                onShowChat: { messageId in
                    directHighlightMessageId = messageId
                    highlightedNoteId = nil
                    showChatDrawer = true
                },
                vocabWord: quickLookVocabWord,
                onOpenVocab: { word in
                    quickLookNoteIds = nil
                    openVocab(word)
                }
            )
        }
        // CR-1：aiBubble 回填后即时刷新（占位卡→真回答，抽屉和正文虚线都更新）
        .onReceive(NotificationCenter.default.publisher(for: .bookNotesDidChange)) { notif in
            guard (notif.userInfo?["safeName"] as? String) == bookSafeName else { return }
            let all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
            allNotes = all
            chapterNotes = all.filter { $0.chapter == currentChapter }
            rerenderCurrentChapter()
        }
    }

    // MARK: - 主体

    private var readerBody: some View {
        readerCore
        #if os(macOS)
        .overlay(alignment: .leading) {
            switch activeDrawer {
            case .catalog:
                catalogDrawer.transition(.move(edge: .leading))
            case .annotations:
                annotationsDrawer.transition(.move(edge: .leading))
            case .none:
                EmptyView()
            }
        }
        #else
        // iOS：目录 / 书签 / 批注合成一个底部 sheet（⧫ 粟粟 09-25：不要侧边拉出）。
        // 开关就是 activeDrawer——各处「选完就 activeDrawer = nil」自动变成收 sheet。
        .sheet(isPresented: Binding(get: { activeDrawer != nil }, set: { if !$0 { activeDrawer = nil } })) {
            readerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #endif
        // M3-B：问小克后的反馈 toast（2.5s 自动消失）
        .overlay(alignment: .bottom) {
            if let msg = askToast {
                Text(msg)
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.branchIndicator.opacity(0.9))
                    .clipShape(Capsule())
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: askToast)
        // 选段菜单：
        // - iOS 走 WKWebView 原生 edit menu（MPReaderWebView 替换系统条目，贴选段浮条不挡正文）
        // - macOS 没有原生浮条概念，维持 confirmationDialog
        #if os(macOS)
        .confirmationDialog(
            "对这段做什么？",
            isPresented: Binding(
                get: { selectedRange != nil },
                set: { if !$0 { selectedRange = nil } }
            ),
            titleVisibility: .visible,
            presenting: selectedRange
        ) { range in
            Button("复制") { copySelection(range.text) }
            Button("高亮") { addHighlight(range) }
            Button("加笔记") { noteEditorContent = ""; showNoteEditor = true }
            Button("问\(assistantName)") { askXiaoke(range) }
            Button("收生词") { addToVocab(range) }
            #if PERSONAL_APPS
            #if DEBUG
            Button("存成问题") { saveTopicFromSelection(range) }
            #endif
            #endif
            Button("取消", role: .cancel) { selectedRange = nil }
        } message: { range in
            Text("「\(range.text.prefix(40))\(range.text.count > 40 ? "…" : "")」")
        }
        #endif
        // 笔记输入 sheet
        .sheet(isPresented: $showNoteEditor) {
            noteEditorSheet
        }
        #if PERSONAL_APPS
        #if DEBUG
        // 划线「存成问题」→ 投题 sheet
        .sheet(item: $topicRequest) { req in
            TopicComposeSheet(profileId: profileId, prefillQuote: req.quote,
                              source: req.source, sourceLabel: req.sourceLabel)
        }
        #endif
        #endif
        // M3-B-2 底部抽屉 mini 对话（学 page1 ModelPickerPopover 的 .sheet + detents 模式）
        .sheet(isPresented: $showChatDrawer, onDismiss: {
            highlightedNoteId = nil
            directHighlightMessageId = nil
        }) {
            BookChatDrawer(
                bookSafeName: bookSafeName,
                bookDisplayName: index?.name ?? bookSafeName,
                currentChapter: currentChapter,
                viewModel: viewModel,
                highlightMessageId: directHighlightMessageId ?? messageIdForHighlightedNote()
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
        }
    }

    /// iOS：平时只有字，单击正文浮出玻璃控件（plan-reading-study §2.3）；mac 保留导航栏 + 底栏。
    @ViewBuilder
    private var readerCore: some View {
        #if os(iOS)
        immersiveReader
        #else
        NavigationStack {
            VStack(spacing: 0) {
                BookReaderWebView(
                    html: renderedHTML,
                    chapterNo: currentChapter,
                    initialScrollRatio: initialScrollRatio,
                    scrollToken: scrollToken,
                    assistantName: assistantName,
                    onMessage: handleMessage
                )
                Divider()
                bottomBar
            }
            .background(Theme.mainBg)
            .navigationTitle(index?.name ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: {
                        Image(systemName: "chevron.down")
                    }
                    .foregroundColor(Theme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    if let ch = index?.chapters.first(where: { $0.no == currentChapter }) {
                        Text("第 \(currentChapter)/\(index?.totalChapters ?? 0) 章 · \(ch.title)")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 12) {
                        Button {
                            toggleBookmarkHere()
                        } label: {
                            Image(systemName: hasBookmarkHere ? "bookmark.fill" : "bookmark")
                        }
                        .foregroundColor(hasBookmarkHere ? Theme.branchIndicator : Theme.textSecondary)

                        Button {
                            if activeDrawer != .annotations { detectBrokenAnchors() }
                            withAnimation(.spring(response: 0.3)) {
                                activeDrawer = (activeDrawer == .annotations) ? nil : .annotations
                            }
                        } label: {
                            Image(systemName: "pencil.tip.crop.circle")
                        }
                        .foregroundColor(Theme.textSecondary)

                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                activeDrawer = (activeDrawer == .catalog) ? nil : .catalog
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
        #endif
    }

    #if os(iOS)
    private var immersiveReader: some View {
        ZStack {
            Theme.mainBg.ignoresSafeArea()
            BookReaderWebView(
                html: renderedHTML,
                chapterNo: currentChapter,
                initialScrollRatio: initialScrollRatio,
                scrollToken: scrollToken,
                assistantName: assistantName,
                onMessage: handleMessage
            )
            .padding(.bottom, 22)
            VStack(spacing: 0) {
                if showChrome {
                    chromeTopBar.transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if let id = paletteNoteId, let note = allNotes.first(where: { $0.id == id }) {
                    HighlightPaletteBar(colorHex: note.strokeColorHex, style: note.strokeStyle) { hex, style in
                        restyleStroke(id, color: hex, style: style)
                    } onDelete: {
                        paletteNoteId = nil
                        applyNotes { NoteThreads.removeStroke(note.id, in: &$0) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showChrome {
                    chromeBottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    readerFooter.transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: showChrome)
        .animation(.easeOut(duration: 0.2), value: showFontPanel)
        .animation(.easeOut(duration: 0.2), value: paletteNoteId)
        .fullScreenCover(isPresented: $showQuotes) {
            BookQuotesView(quotes: StudyQuote.load(bookId: bookSafeName, bookName: index?.name ?? bookSafeName,
                                                   author: index?.author ?? "", profileId: profileId)
                                .sorted { $0.createdAt > $1.createdAt },
                           profileId: profileId,
                           initialBookId: bookSafeName) { q in
                showQuotes = false
                jumpTo(chapter: q.chapter, offset: q.anchorStart)
            }
        }
        .onChange(of: currentChapter) { _, _ in
            paletteNoteId = nil
            if showChrome { bumpChrome() }
        }
    }

    /// 页脚：书名 · 一片小叶子 + 进度（⧫ 粟粟 09-25：阅读器加一点点植物）
    private var readerFooter: some View {
        HStack(spacing: 4) {
            Text(index?.name ?? "").lineLimit(1)
            Spacer()
            Image(systemName: "leaf.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.branchIndicator)
                .rotationEffect(.degrees(-20))
            Text(progressLabel)
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 26)
        .frame(height: 22)
        .allowsHitTesting(false)
    }

    private var chapterCapsuleTitle: String {
        let total = index?.totalChapters ?? 0
        guard let ch = index?.chapters.first(where: { $0.no == currentChapter }) else { return "第 \(currentChapter) 章" }
        return total > 1 ? "\(currentChapter) / \(total) · \(ch.title)" : ch.title
    }

    /// 左上「‹」回书房（⧫ 粟粟 09-25：返回应该在左上）。page2 外壳里左上 76pt 是手势区：
    /// 按钮压在手势区里的那部分由外壳的「轻点 = 应用内退一层」接住，露在外面的部分按钮自己接，效果一样。
    private var chromeTopBar: some View {
        ZStack {
            Text(chapterCapsuleTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .frame(maxWidth: 190)
                .glassEffect(.regular, in: .capsule)
            HStack(spacing: 10) {
                Button { close() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("回书房")
                Spacer()
                Button { toggleBookmarkHere(); bumpChrome() } label: {
                    Image(systemName: hasBookmarkHere ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(hasBookmarkHere ? Theme.branchIndicator : Theme.textPrimary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(hasBookmarkHere ? "取消书签" : "加书签")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var chromeBottomBar: some View {
        let total = index?.totalChapters ?? 0
        return VStack(spacing: 10) {
            if showFontPanel {
                fontSizeControl
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                Button { jumpChapter(-1); bumpChrome() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(currentChapter > 1 ? Theme.textPrimary : Theme.textMuted.opacity(0.4))
                .disabled(currentChapter <= 1)
                .accessibilityLabel("上一章")
                if total > 1 {
                    Slider(value: Binding(get: { scrubChapter ?? Double(currentChapter) },
                                          set: { scrubChapter = $0 }),
                           in: 1...Double(total), step: 1) { editing in
                        if editing { chromeHideTask?.cancel(); return }
                        if let v = scrubChapter { currentChapter = Int(v) }
                        scrubChapter = nil
                        bumpChrome()
                    }
                    .tint(Theme.branchIndicator)
                } else {
                    Spacer()
                }
                Button { jumpChapter(1); bumpChrome() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(currentChapter < total ? Theme.textPrimary : Theme.textMuted.opacity(0.4))
                .disabled(currentChapter >= total)
                .accessibilityLabel("下一章")
                Text(scrubChapter.map { "第 \(Int($0)) 章" } ?? progressLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            HStack(spacing: 0) {
                chromeTool("list.bullet", "目录") {
                    readerSheetTab = .catalog
                    activeDrawer = .catalog
                }
                chromeTool("pencil.tip.crop.circle", "批注") {
                    detectBrokenAnchors()
                    readerSheetTab = .notes
                    activeDrawer = .annotations
                }
                chromeTool("text.quote", "书摘") {
                    showQuotes = true
                }
                chromeTool("bubble.left.and.bubble.right", "问\(assistantName)", badge: bookMessageCount) {
                    showChatDrawer = true
                }
                chromeTool("textformat.size", "字号", active: showFontPanel) {
                    showFontPanel.toggle()
                    bumpChrome()
                }
            }
            .frame(height: 58)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func chromeTool(_ icon: String, _ title: String, badge: Int = 0, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon).font(.system(size: 17))
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.branchIndicator, in: Capsule())
                            .offset(x: 10, y: -6)
                    }
                }
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 控件浮出后 4 秒没操作就收起；开着抽屉 / 字号 / 正在拖进度时不收
    private func bumpChrome() {
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, activeDrawer == nil, !showChatDrawer, !showFontPanel, scrubChapter == nil else { return }
            showChrome = false
        }
    }

    enum ReaderSheetTab: Hashable { case catalog, bookmarks, notes }

    /// 目录 / 书签 / 批注三个页签；行里的动作沿用抽屉那套（跳章 / 跳书签 / 点批注都会把 activeDrawer 置空 → 收 sheet）
    private var readerSheet: some View {
        VStack(spacing: 0) {
            Picker("", selection: $readerSheetTab) {
                Text("目录").tag(ReaderSheetTab.catalog)
                Text(bookmarks.isEmpty ? "书签" : "书签 · \(bookmarks.count)").tag(ReaderSheetTab.bookmarks)
                let noteCount = allNotes.filter { $0.replyTo == nil }.count
                Text(noteCount == 0 ? "批注" : "批注 · \(noteCount)").tag(ReaderSheetTab.notes)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)
            switch readerSheetTab {
            case .catalog:
                ReaderSearchField(text: $catalogQuery) { searchHits = [] }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .onChange(of: catalogQuery) { _, q in scheduleSearch(q) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !catalogQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                                searchResultRows
                            } else {
                                chapterRows
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .onAppear { proxy.scrollTo(currentChapter, anchor: .center) }
                }
            case .bookmarks:
                if bookmarks.isEmpty {
                    Spacer()
                    Text("还没有书签。读的时候点顶上的书签按钮加一个。")
                        .font(.system(size: 13)).foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 30)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) { bookmarkRows }
                            .padding(.horizontal, 6)
                    }
                }
            case .notes:
                BookAnnotationDrawer(
                    allNotes: allNotes,
                    chapters: index?.chapters ?? [],
                    assistantName: assistantName,
                    currentChapter: currentChapter,
                    brokenNoteIds: brokenNoteIds,
                    isPresented: Binding(get: { activeDrawer != nil }, set: { if !$0 { activeDrawer = nil } }),
                    onTapNote: { note in handleTapNote(note) },
                    onJumpToChapter: { chapter in
                        activeDrawer = nil
                        if chapter != currentChapter { currentChapter = chapter }
                    },
                    onShowChat: { messageId in
                        activeDrawer = nil
                        directHighlightMessageId = messageId
                        highlightedNoteId = nil
                        showChatDrawer = true
                    },
                    onDelete: { note in deleteNote(note) },
                    onReply: { parent, content in
                        let reply = BookStore.Note(
                            id: UUID().uuidString, chapter: parent.chapter,
                            anchorText: parent.anchorText, anchorStart: parent.anchorStart,
                            anchorEnd: parent.anchorEnd, kind: "note", content: content,
                            role: "user", messageId: nil, createdAt: Date(), replyTo: parent.id
                        )
                        appendNote(reply)
                        ReadingSignals.logEvent(type: "reply", book: bookSafeName, chapter: parent.chapter, profileId: profileId)
                    },
                    embedded: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBg.ignoresSafeArea())
        .onAppear { bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId) }
        .onChange(of: readerSheetTab) { _, tab in if tab == .notes { detectBrokenAnchors() } }
    }

    private func handleReaderTap() {
        if paletteNoteId != nil {
            paletteNoteId = nil
            return
        }
        if activeDrawer != nil {
            withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
            return
        }
        showFontPanel = false
        showChrome.toggle()
        if showChrome { bumpChrome() } else { chromeHideTask?.cancel() }
    }
    #endif

    // MARK: - 笔记输入 sheet

    private var noteEditorSheet: some View {
        NavigationStack {
            List {
                if let r = selectedRange {
                    Section("选段") {
                        Text("「\(r.text.prefix(120))\(r.text.count > 120 ? "…" : "")」")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.mainBg)
                }
                Section("笔记") {
                    TextEditor(text: $noteEditorContent)
                        .font(.system(size: Theme.F.body))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                }
                .listRowBackground(Theme.mainBg)
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.plain)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle("加笔记")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showNoteEditor = false
                        selectedRange = nil
                    }
                    .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveNote() }
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(noteEditorContent.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 360)
        #endif
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button { jumpChapter(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 14))
                Text("上一章").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(currentChapter > 1 ? Theme.textPrimary : Theme.textMuted.opacity(0.4))
            .disabled(currentChapter <= 1)

            Spacer()

            if let total = index?.totalChapters, total > 0 {
                Text(progressLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }

            // M3-B-2：抽屉入口按钮（带消息数 badge）
            Button { showChatDrawer = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 14))
                    if bookMessageCount > 0 {
                        Text("\(bookMessageCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.branchIndicator)
                            .clipShape(Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.textSecondary)

            Spacer()

            Button { jumpChapter(1) } label: {
                Text("下一章").font(.system(size: 12))
                Image(systemName: "chevron.right").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundColor(currentChapter < (index?.totalChapters ?? 0) ? Theme.textPrimary : Theme.textMuted.opacity(0.4))
            .disabled(currentChapter >= (index?.totalChapters ?? 0))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// 当前书在主对话里出现过多少条相关 user 消息（用来在按钮上做 badge）
    private var bookMessageCount: Int {
        let prefix = "\(bookSafeName)#"
        return viewModel.currentPath.filter { $0.bookRef?.hasPrefix(prefix) == true }.count
    }

    /// M3.5：把点击的 ai-ul noteId 映射到对应主对话 MessageNode.id
    private func messageIdForHighlightedNote() -> String? {
        guard let noteId = highlightedNoteId else { return nil }
        let allNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        return allNotes.first(where: { $0.id == noteId })?.messageId
    }

    private var progressLabel: String {
        let total = index?.totalChapters ?? 0
        guard total > 0 else { return "" }
        let pct = (Double(currentChapter - 1) + latestScrollRatio) / Double(total) * 100
        return String(format: "%.1f%%", pct)
    }

    // MARK: - 目录抽屉

    private var catalogDrawer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("目录").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.textMuted)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            // F2 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                TextField("搜全书", text: $catalogQuery)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                if !catalogQuery.isEmpty {
                    Button { catalogQuery = ""; searchHits = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .onChange(of: catalogQuery) { _, q in scheduleSearch(q) }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !catalogQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResultRows
                    } else {
                        bookmarkRows
                        chapterRows
                    }
                }
            }
            Divider()
            fontSizeControl   // F3
        }
        .frame(width: 240)
        .background(Theme.sidebarBg)
        .shadow(color: .black.opacity(0.1), radius: 8, x: 2, y: 0)
        .onAppear { bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId) }
    }

    /// 目录抽屉：章节列表（无搜索词时）
    private var chapterRows: some View {
        ForEach(index?.chapters ?? []) { ch in
            Button {
                currentChapter = ch.no
                withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
            } label: {
                HStack(spacing: 6) {
                    Text("\(ch.no).")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 28, alignment: .trailing)
                    Text(ch.title)
                        .font(.system(size: 12))
                        .foregroundColor(ch.no == currentChapter ? Theme.branchIndicator : Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if ch.auto == true {
                        // 没认出标题、按段落分的：标题是那段第一句
                        Text("自动分段")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(ch.no == currentChapter ? Theme.accent : Color.clear)
            }
            .buttonStyle(.plain)
        }
    }

    /// F1 书签行（章节列表上方，有书签才出现）
    @ViewBuilder private var bookmarkRows: some View {
        if !bookmarks.isEmpty {
            HStack {
                Text("Bookmarks")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            ForEach(bookmarks) { bm in
                HStack(spacing: 6) {
                    Button {
                        jumpToBookmark(bm)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.branchIndicator)
                            Text(bm.title)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    Button {
                        removeBookmark(bm)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider().padding(.vertical, 4)
        }
    }

    /// F2 搜索结果行
    @ViewBuilder private var searchResultRows: some View {
        if searchHits.isEmpty {
            Text("没搜到")
                .font(.system(size: 12)).foregroundColor(Theme.textMuted)
                .padding(12)
        } else {
            ForEach(searchHits) { hit in
                Button {
                    currentChapter = hit.chapter
                    withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.branchIndicator)
                            .lineLimit(1)
                        Text(hit.snippet)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// F3 字号控件（Aa，六档步进）
    private var fontSizeControl: some View {
        let sizes = ChapterHTMLRenderer.FontSize.allCases
        let idx = sizes.firstIndex(of: ChapterHTMLRenderer.FontSize(rawValue: readerFontSize) ?? .md) ?? 2
        return HStack {
            Button {
                if idx > 0 { readerFontSize = sizes[idx - 1].rawValue; rerenderCurrentChapter() }
            } label: {
                Text("A").font(.system(size: 11)).foregroundColor(idx > 0 ? Theme.textSecondary : Theme.textMuted.opacity(0.4))
            }
            .buttonStyle(.plain)
            Spacer()
            Text("字号 · \(sizes[idx].label)")
                .font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
            Spacer()
            Button {
                if idx < sizes.count - 1 { readerFontSize = sizes[idx + 1].rawValue; rerenderCurrentChapter() }
            } label: {
                Text("A").font(.system(size: 16)).foregroundColor(idx < sizes.count - 1 ? Theme.textSecondary : Theme.textMuted.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - F1/F2 动作

    private func jumpToBookmark(_ bm: BookStore.Bookmark) {
        withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
        if bm.chapter == currentChapter {
            bookmarkJumpRatio = bm.scrollRatio
            loadChapter(currentChapter, resetScroll: true)
        } else {
            bookmarkJumpRatio = bm.scrollRatio
            currentChapter = bm.chapter   // onChange → loadChapter(resetScroll: true) 会消费 jumpRatio
        }
    }

    private func removeBookmark(_ bm: BookStore.Bookmark) {
        var bms = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        bms.removeAll { $0.id == bm.id }
        try? BookStore.saveBookmarks(bms, safeName: bookSafeName, profileId: profileId)
        bookmarks = bms
    }

    private func toggleBookmarkHere() {
        let title = index?.chapters.first(where: { $0.no == currentChapter })?.title ?? "第 \(currentChapter) 章"
        let added = BookStore.toggleBookmark(
            safeName: bookSafeName, profileId: profileId,
            chapter: currentChapter, scrollRatio: latestScrollRatio, title: title)
        bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        askToast = added ? "已加书签" : "书签已取消"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if askToast != nil { askToast = nil } }
    }

    private var hasBookmarkHere: Bool {
        bookmarks.contains { $0.chapter == currentChapter }
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchHits = []; return }
        let chapters = index?.chapters ?? []
        let safe = bookSafeName, pid = profileId
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                BookSearch.searchTxt(query: q, safeName: safe, profileId: pid, chapters: chapters)
            }.value
            guard !Task.isCancelled else { return }
            searchHits = result.hits
        }
    }

    // MARK: - 批注抽屉

    private var annotationsDrawer: some View {
        BookAnnotationDrawer(
            allNotes: allNotes,
            chapters: index?.chapters ?? [],
            assistantName: assistantName,
            currentChapter: currentChapter,
            brokenNoteIds: brokenNoteIds,
            isPresented: Binding(
                get: { activeDrawer == .annotations },
                set: { if !$0 { activeDrawer = nil } }
            ),
            onTapNote: { note in
                handleTapNote(note)
            },
            onJumpToChapter: { chapter in
                withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
                if chapter != currentChapter { currentChapter = chapter }
            },
            onShowChat: { messageId in
                withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
                directHighlightMessageId = messageId
                highlightedNoteId = nil
                showChatDrawer = true
            },
            onDelete: { note in
                deleteNote(note)
            },
            onReply: { parent, content in
                let reply = BookStore.Note(
                    id: UUID().uuidString,
                    chapter: parent.chapter,
                    anchorText: parent.anchorText,
                    anchorStart: parent.anchorStart,
                    anchorEnd: parent.anchorEnd,
                    kind: "note",
                    content: content,
                    role: "user",
                    messageId: nil,
                    createdAt: Date(),
                    replyTo: parent.id
                )
                appendNote(reply)
                ReadingSignals.logEvent(type: "reply", book: bookSafeName, chapter: parent.chapter, profileId: profileId)
            }
        )
    }

    /// 卡片点击派发：
    /// - note / highlight → 这一处的时间线（P3：默认再写一条，每条在时间线里单独改）
    /// - aiBubble  → 跳章（AI 内容不能改）
    private func handleTapNote(_ note: BookStore.Note) {
        switch note.kind {
        case "note", "highlight":
            withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
            quickLookVocabWord = nil
            quickLookNoteIds = [note.id]
        case "aiBubble":
            withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
            if note.chapter != currentChapter { currentChapter = note.chapter }
        default:
            break
        }
    }

    // MARK: - 错误态

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.textMuted)
            Text(msg).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            Button("关闭") { close() }.buttonStyle(.plain).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 业务

    private func loadBook() {
        guard let idx = BookStore.loadIndex(safeName: bookSafeName, profileId: profileId) else {
            loadError = "找不到《\(bookSafeName)》"
            return
        }
        index = idx
        currentChapter = max(1, min(idx.totalChapters, initialChapter ?? idx.currentChapter))
        initialScrollRatio = idx.scrollRatio
        allNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        loadChapter(currentChapter, resetScroll: false)
        if initialChapter != nil {
            // 存储的 scrollRatio 属于原进度章节，跳章后按 offset 字符比例近似定位
            let ratio = initialAnchorOffset.map { Double($0) / Double(max(1, chapterText.count)) } ?? 0
            let clamped = min(1, max(0, ratio))
            initialScrollRatio = clamped
            latestScrollRatio = clamped
        }
    }

    private func loadChapter(_ no: Int, resetScroll: Bool) {
        guard let idx = index,
              let meta = idx.chapters.first(where: { $0.no == no }) else { return }
        guard let text = BookStore.loadChapterText(safeName: bookSafeName, chapterNo: no, profileId: profileId) else {
            loadError = "找不到第 \(no) 章文件"
            return
        }
        chapterText = text
        // 刷新整书 notes（如果用户在其他章节有过改动）+ 切出本章用于着色
        let all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        allNotes = all
        chapterNotes = all.filter { $0.chapter == no }
        renderedHTML = ChapterHTMLRenderer.render(
            title: meta.title,
            text: text,
            style: readerStyle,
            chapterNo: no,
            totalChapters: idx.totalChapters,
            annotations: chapterNotes.compactMap(annotationFromNote),
            vocabWords: VocabCollector.collectedWords(context: modelContext)
        )
        if let off = pendingAnchorOffset {
            bookmarkJumpRatio = Double(off) / Double(max(1, text.count))
            pendingAnchorOffset = nil
        }
        if resetScroll {
            let target = bookmarkJumpRatio ?? 0
            bookmarkJumpRatio = nil
            initialScrollRatio = target
            scrollToken &+= 1
            latestScrollRatio = target
            scheduleSaveProgress()
        }
        pushReadingContext(chapterNo: no, chapterTitle: meta.title, text: text)
    }

    /// F3 字号：全局档位（FontSize 枚举早已进 CSS，这里只是接上持久化）
    private var readerStyle: ChapterHTMLRenderer.Style {
        var s = ChapterHTMLRenderer.Style()
        s.fontSize = ChapterHTMLRenderer.FontSize(rawValue: readerFontSize) ?? .md
        return s
    }

    /// CR-4 P1：她读到哪，章文本经 WS 缓存到 hub 哪（agent/reading-context.json，单章覆盖）。
    /// AI 自主读书只读「她最近读的那一章」——她没读书 = hub 无材料 = ReaderDaemon 不跑。
    /// userNotes 附本章她的批注（供 AI 回她的话，⧫ 回批注已拍开）。best-effort，断连不重试。
    private func pushReadingContext(chapterNo: Int, chapterTitle: String, text: String) {
        let userNotes = chapterNotes.filter { $0.role == "user" }.map {
            [
                "id": $0.id,
                "anchorText": String($0.anchorText.prefix(120)),
                "content": String($0.content.prefix(200)),
            ]
        }
        // R1：楼层人格+记忆随材料上行（同刻快照），daemon 带着用户的 AI 的人格读书
        var persona = ""
        var userName = "用户"
        if let profile = profileManager?.currentProfile {
            persona = ReadingSignals.buildPersonaPackage(profile: profile, context: modelContext)
            if !profile.userName.trimmingCharacters(in: .whitespaces).isEmpty {
                userName = profile.userName
            }
        }
        CCBridgeWebSocketClient.shared.send([
            "type": "reading_context",
            "floorId": profileId,
            "userName": userName,
            "safeName": bookSafeName,
            "bookName": index?.name ?? bookSafeName,
            "chapter": chapterNo,
            "totalChapters": index?.totalChapters ?? 0,
            "chapterTitle": chapterTitle,
            "text": String(text.prefix(60_000)),
            "userNotes": userNotes,
            "persona": persona,
        ]) { _ in }
    }

    /// 重绘当前章 HTML（保持 scroll 位置）——append/delete 笔记后复用
    private func rerenderCurrentChapter() {
        guard let idx = index,
              let meta = idx.chapters.first(where: { $0.no == currentChapter }) else { return }
        renderedHTML = ChapterHTMLRenderer.render(
            title: meta.title,
            text: chapterText,
            style: readerStyle,
            chapterNo: currentChapter,
            totalChapters: idx.totalChapters,
            annotations: chapterNotes.compactMap(annotationFromNote),
            vocabWords: VocabCollector.collectedWords(context: modelContext)
        )
        initialScrollRatio = latestScrollRatio  // 重渲染后回到当前位置
    }

    private func jumpTo(chapter: Int, offset: Int) {
        pendingAnchorOffset = offset
        if chapter == currentChapter {
            loadChapter(currentChapter, resetScroll: true)
        } else {
            currentChapter = chapter   // onChange → loadChapter(resetScroll: true) 消费 pendingAnchorOffset
        }
    }

    private func jumpChapter(_ delta: Int) {
        let target = currentChapter + delta
        guard let total = index?.totalChapters, target >= 1, target <= total else { return }
        currentChapter = target
    }

    private func handleMessage(_ msg: BookReaderMessage) {
        switch msg {
        case .ready: break
        case .scroll(let ratio, let chapter):
            guard chapter == currentChapter else { return }
            latestScrollRatio = ratio
            scheduleSaveProgress()
        case .select(let text, let start, let end, let chapter):
            guard chapter == currentChapter, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            // iOS 走原生 edit menu，不弹 confirmationDialog——select 只在 macOS 触发卡片
            #if os(macOS)
            selectedRange = SelectedRange(text: text, start: start, end: end, chapter: chapter)
            #else
            _ = (text, start, end)   // 静默，等 .action 路径
            #endif
        case .action(let name, let text, let start, let end, let chapter):
            // iOS 原生菜单点击后回来：name=copy/highlight/addNote/askAI
            guard chapter == currentChapter, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let range = SelectedRange(text: text, start: start, end: end, chapter: chapter)
            switch name {
            case "copy":
                copySelection(text)
            case "highlight":
                addHighlight(range)
            case "addNote":
                selectedRange = range
                noteEditorContent = ""
                showNoteEditor = true
            case "askAI":
                askXiaoke(range)
            case "addVocab":
                addToVocab(range)
            #if PERSONAL_APPS
            #if DEBUG
            case "saveTopic":
                saveTopicFromSelection(range)
            #endif
            #endif
            default:
                break
            }
        case .noteTap(let noteIds, let word, let chapter):
            // R4：点任何批注划线 → 就地小窗（批注内容/串/回复；aiBubble 从小窗再进对话抽屉）
            guard chapter == currentChapter, !noteIds.isEmpty else { return }
            let hit = allNotes.filter { noteIds.contains($0.id) }
            guard !hit.isEmpty else { return }
            #if os(iOS)
            paletteNoteId = nil
            #endif
            quickLookVocabWord = word
            quickLookNoteIds = noteIds
        case .vocabTap(let word, _):
            // CR-3：点击已收生词 → 打开单词工具定位到该词
            guard !word.isEmpty else { return }
            openVocab(word)
        case .tap:
            #if os(iOS)
            handleReaderTap()
            #endif
        case .error(let m):
            loadError = m
        }
    }

    // MARK: - 笔记/高亮写入

    private func copySelection(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        selectedRange = nil
    }

    /// CR-3：选段收进生词本（书词打通写入口）。收完 rerender 让虚线立现。
    private func addToVocab(_ range: SelectedRange) {
        let word = VocabCollector.collect(
            rawText: range.text,
            bookSafeName: bookSafeName,
            chapter: range.chapter,
            anchorStart: range.start,
            context: modelContext
        )
        selectedRange = nil
        guard let word else {
            askToast = "选段不适合收词"
            scheduleToastDismiss()
            return
        }
        rerenderCurrentChapter()
        askToast = "已收「\(word)」进生词本"
        scheduleToastDismiss()
        ReadingSignals.logEvent(type: "vocab", book: bookSafeName, chapter: range.chapter, word: word, profileId: profileId)
    }

    #if PERSONAL_APPS
    #if DEBUG
    /// 划线「存成问题」：选段进引文投话题盒，source 带书锚（book:<safeName>#chapter=N）。
    private func saveTopicFromSelection(_ range: SelectedRange) {
        selectedRange = nil
        topicRequest = TopicComposeRequest(
            quote: range.text,
            source: "book:\(bookSafeName)#chapter=\(range.chapter)",
            sourceLabel: "《\(index?.name ?? bookSafeName)》· 第 \(range.chapter) 章"
        )
    }
    #endif
    #endif

    private func scheduleToastDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if askToast != nil { askToast = nil }
        }
    }

    private func openVocab(_ word: String) {
        UserDefaults.standard.set(word, forKey: "pendingVocabJumpWord")
        NotificationCenter.default.post(name: .openVocabTool, object: nil)
        close()
    }

    /// P2：每次划线都是独立一道（同一段可以先划薄荷底、再叠一道玫瑰下划线），不再和旧划线合并。
    /// 颜色 / 样式用上次选的；iOS 划完底部浮调色条可以改。
    private func addHighlight(_ range: SelectedRange) {
        var note = BookStore.Note(
            id: UUID().uuidString,
            chapter: range.chapter,
            anchorText: range.text,
            anchorStart: range.start,
            anchorEnd: range.end,
            kind: "highlight",
            content: "",
            role: "user",
            messageId: nil,
            createdAt: Date()
        )
        note.color = lastHighlightColor
        note.style = lastHighlightStyle
        appendNote(note)
        #if os(iOS)
        paletteNoteId = note.id
        #else
        askToast = "已高亮"
        scheduleToastDismiss()
        #endif
        selectedRange = nil
        ReadingSignals.logEvent(type: "highlight", book: bookSafeName, chapter: range.chapter, profileId: profileId)
    }

    /// 调色条改一道线的颜色 / 样式，并记成下次的默认
    private func restyleStroke(_ id: String, color: String, style: HighlightStyle) {
        lastHighlightColor = color
        lastHighlightStyle = style.rawValue
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].color = color
        all[i].style = style.rawValue
        try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
        allNotes = all
        chapterNotes = all.filter { $0.chapter == currentChapter }
        rerenderCurrentChapter()
    }

    private func saveNote() {
        guard let range = selectedRange else { showNoteEditor = false; return }
        let content = noteEditorContent.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }

        if let place = NoteThreads.existingPlace(chapter: range.chapter, start: range.start, end: range.end, in: allNotes) {
            // 和已有某处一模一样 → 进它的时间线
            applyNotes { NoteThreads.addEntry(content, to: place, in: &$0) }
            ReadingSignals.logEvent(type: "note", book: bookSafeName, chapter: range.chapter, profileId: profileId)
        } else {
            // 新增一处（用上次的颜色 / 样式）
            var note = BookStore.Note(
                id: UUID().uuidString,
                chapter: range.chapter,
                anchorText: range.text,
                anchorStart: range.start,
                anchorEnd: range.end,
                kind: "note",
                content: content,
                role: "user",
                messageId: nil,
                createdAt: Date()
            )
            note.color = lastHighlightColor
            note.style = lastHighlightStyle
            appendNote(note)
            ReadingSignals.logEvent(type: "note", book: bookSafeName, chapter: range.chapter, profileId: profileId)
        }
        showNoteEditor = false
        selectedRange = nil
        noteEditorContent = ""
    }

    /// 追加一条笔记到 notes.json，刷新当前章节高亮渲染（保持 scroll 位置）。
    private func appendNote(_ note: BookStore.Note) {
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        all.append(note)
        try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
        allNotes = all
        chapterNotes = all.filter { $0.chapter == currentChapter }
        rerenderCurrentChapter()
    }

    /// 批注抽屉里删卡（P3 契约）：删的是根 = 删掉这处划线（AI 写的留下）；删的是回复 = 只删那一条
    /// 注意：aiBubble 删了**不删**主对话里的 MessageNode——只断书侧锚点，避免误删对话历史
    private func deleteNote(_ note: BookStore.Note) {
        applyNotes { all in
            if note.replyTo != nil {
                NoteThreads.deleteEntry(note.id, in: &all)
            } else if let place = NoteThreads.place(of: note.id, in: all) {
                NoteThreads.removePlace(place, in: &all)
            }
        }
    }

    /// 跑一段 NoteThreads 改动 → 存盘 → 刷新正文
    private func applyNotes(_ change: (inout [BookStore.Note]) -> Void) {
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        change(&all)
        try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
        allNotes = all
        chapterNotes = all.filter { $0.chapter == currentChapter }
        rerenderCurrentChapter()
    }

    // MARK: - M3-B 问小克 → 楼层主对话

    /// 把选段当作 quote 注入楼层主对话；小克回复时 vm 的 sendMessage 路径自然走流式。
    /// 用户消息的 MessageNode 上盖 bookRef，主对话里能看到 "📖 书名·第N章" tag。
    /// 同时 notes.json 写一条 kind=aiBubble 占位锚点（content 暂为空，等 vm 写回填）。
    private func askXiaoke(_ range: SelectedRange) {
        guard let prof = profileManager?.currentProfile,
              let pm = providerManager,
              let psm = presetManager else {
            askToast = "缺少 Profile/Provider/Preset，没法发"
            selectedRange = nil
            return
        }

        let chapterTitle = index?.chapters.first(where: { $0.no == range.chapter })?.title ?? "第 \(range.chapter) 章"
        let bookName = index?.name ?? bookSafeName
        let quote = """
        （在《\(bookName)》\(chapterTitle) 读到）
        「\(range.text)」

        你怎么看？
        """

        // 确保有活动对话
        if viewModel.selectedConversation == nil {
            viewModel.startDraftConversation(profileId: prof.id)
        }

        let model = pm.resolveModel(
            conversationModelId: viewModel.selectedConversation?.selectedModelId,
            globalFallbackId: nil
        )
        let preset = psm.preset(byId: prof.presetId) ?? .balanced
        let bookRef = "\(bookSafeName)#chapter\(range.chapter)"

        let sent = viewModel.sendMessage(
            quote,
            model: model,
            profile: prof,
            preset: preset,
            providerManager: pm,
            context: modelContext
        )

        if sent {
            // 给刚发的 user node 盖 bookRef（currentPath 最后一条 user role）
            if let lastUser = viewModel.currentPath.last(where: { $0.role == "user" }) {
                lastUser.bookRef = bookRef
                try? lastUser.modelContext?.save()
            }
            // 写 notes.json：anchor=选段，kind=aiBubble 占位（AI 回复回填 content）
            let note = BookStore.Note(
                id: UUID().uuidString,
                chapter: range.chapter,
                anchorText: range.text,
                anchorStart: range.start,
                anchorEnd: range.end,
                kind: "aiBubble",
                content: "（\(assistantName)正在回答…）",
                role: "ai",
                messageId: viewModel.currentPath.last(where: { $0.role == "user" })?.id,
                createdAt: Date()
            )
            appendNote(note)
            ReadingSignals.logEvent(type: "askAI", book: bookSafeName, chapter: range.chapter, profileId: profileId)
            // 自动弹底部抽屉看小克回复（流式回复路上）
            showChatDrawer = true
        } else {
            askToast = "发送失败"
        }
        selectedRange = nil
    }

    /// Note → ChapterHTMLRenderer.Annotation 映射
    private func annotationFromNote(_ n: BookStore.Note) -> ChapterHTMLRenderer.Annotation? {
        let kind: ChapterHTMLRenderer.Annotation.Kind
        guard n.replyTo == nil else { return nil }   // 回复不单独上色，点击归到它的根
        switch n.kind {
        case "highlight": kind = .highlight
        case "aiBubble": kind = .aiUnderline
        case "note": kind = .note
        default: return nil
        }
        return ChapterHTMLRenderer.Annotation(
            id: n.id, kind: kind, start: n.anchorStart, end: n.anchorEnd,
            author: n.role == "ai" ? .ai : .user,
            anchorText: n.anchorText,
            colorHex: n.strokeColorHex,
            style: n.strokeStyle
        )
    }

    /// CR-1 失锚检测：有注章节逐章比对 offset 切片 vs anchorText（宽容：去空白归一化）。
    /// 打开批注抽屉时算一次，结果给卡片标「原文已变」。
    private func detectBrokenAnchors() {
        var broken: Set<String> = []
        for ch in Set(allNotes.map(\.chapter)) {
            guard let meta = index?.chapters.first(where: { $0.no == ch }),
                  let text = BookStore.loadChapterText(safeName: bookSafeName, chapterNo: ch, profileId: profileId)
            else { continue }
            let anns = allNotes.filter { $0.chapter == ch }.compactMap(annotationFromNote)
            broken.formUnion(ChapterHTMLRenderer.brokenAnchorIds(title: meta.title, text: text, annotations: anns))
        }
        brokenNoteIds = broken
    }

    /// debounce 1s 写 index.json + 更新 BookEntry
    private func scheduleSaveProgress() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            saveProgress()
        }
    }

    private func saveProgress() {
        guard var idx = index else { return }
        idx.currentChapter = currentChapter
        idx.scrollRatio = latestScrollRatio
        idx.updatedAt = Date()
        try? BookStore.saveIndex(idx, safeName: bookSafeName, profileId: profileId)
        index = idx

        // 同步更新 SwiftData BookEntry（让书架反应式更新进度）
        let safe = bookSafeName
        let pid = profileId
        let desc = FetchDescriptor<BookEntry>(
            predicate: #Predicate<BookEntry> { $0.id == safe && $0.profileId == pid }
        )
        if let entry = try? modelContext.fetch(desc).first {
            entry.currentChapter = currentChapter
            entry.scrollRatio = latestScrollRatio
            entry.lastReadAt = Date()
            entry.updateTime = Date()
            try? entry.modelContext?.save()
        }
    }
}

#if os(iOS)
/// 阅读器面板里的「搜全书」：玻璃胶囊（⧫ 粟粟 09-26：原来那个圆角框「邪恶且不现代」）。txt / PDF 共用。
struct ReaderSearchField: View {
    @Binding var text: String
    var onClear: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField("搜全书", text: $text)
                .font(.system(size: 16))
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($focused)
            if !text.isEmpty {
                Button { text = ""; onClear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }
}
#endif
