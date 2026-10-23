import SwiftUI
import SwiftData
import PDFKit

/// CR-7 P1：PDF 阅读器（保真第二形态，与 BookReaderSheet 并列，书架按 format 分流）。
/// PDFView 原生渲染（翻页/缩放/滚动系统级）+ outline 目录抽屉 + 进度存续
/// （currentChapter 语义 = 当前页 1-based，totalChapters = 总页数——index.json 零 schema 改动）。
/// 批注/AI 共读归 P2/P3。
struct PDFReaderSheet: View {
    let bookSafeName: String
    let profileId: String
    /// 书摘「翻到这一页」：打开就跳到这一页（覆盖存下的阅读进度，astra #19）
    var initialPage: Int? = nil
    /// page2 外壳里阅读器改内嵌（plan-page2-app-shell §2.9），关闭交给书架；没传就照旧 dismiss
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    private func close() { if let onClose { onClose() } else { dismiss() } }
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ConversationViewModel.self) private var viewModel
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @AppStorage("assistantName") private var assistantName = "助手"

    @State private var index: BookStore.BookIndex?
    @State private var document: PDFDocument?
    @State private var currentPage: Int = 1        // 1-based
    @State private var showCatalog = false
    @State private var loadError: String?
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var contextTask: Task<Void, Never>? = nil

    // F1/F2 书签 + 搜索
    @State private var bookmarks: [BookStore.Bookmark] = []
    @State private var catalogQuery = ""
    @State private var searchResult: BookSearch.Result = .init(hits: [])
    @State private var searchTask: Task<Void, Never>? = nil

    // P2 框选批注
    @State private var allNotes: [BookStore.Note] = []
    @State private var showAnnotationList = false
    @State private var isBoxSelect = false
    @State private var pendingSelection: PDFSelectionResult? = nil
    #if PERSONAL_APPS
    #if DEBUG
    @State private var topicRequest: TopicComposeRequest? = nil
    #endif
    #endif
    @State private var showActionMenu = false
    @State private var showNoteEditor = false
    @State private var noteEditorText = ""
    @State private var quickLookNoteIds: [String]? = nil
    @State private var askToast: String? = nil
    @State private var renderedAnnotations: [PDFAnnotation] = []
    #if os(iOS)
    // 沉浸式外壳（P1-2）
    @State private var showChrome = false
    @State private var chromeHideTask: Task<Void, Never>? = nil
    @State private var scrubPage: Double? = nil
    @State private var showChatDrawer = false
    @State private var showQuotes = false
    /// 目录 / 书签 / 批注合成的底部面板（P1-3）
    @State private var showPanel = false
    @State private var panelTab: PDFPanelTab = .catalog
    /// 刚划的那道线：底部浮调色条（P2-4）
    @State private var paletteNoteId: String? = nil
    #endif
    @AppStorage(HighlightPalette.lastColorKey) private var lastHighlightColor = HighlightPalette.userDefault
    @AppStorage(HighlightPalette.lastStyleKey) private var lastHighlightStyle = HighlightStyle.fill.rawValue

    struct PDFSelectionResult: Identifiable {
        let id = UUID()
        let page: Int
        let quote: String
        let rects: [[Double]]
    }

    var body: some View {
        Group {
            if let err = loadError {
                errorView(err)
            } else if let document {
                readerBody(document)
            } else {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadBook() }
        // CR-2 阅读打点：sheet 活着 = 在读，60s 一跳（chapter 语义 = 当前页）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, index != nil else { continue }
                ReadingSignals.logTick(
                    bookSafeName: bookSafeName,
                    bookDisplayName: index?.name ?? bookSafeName,
                    chapter: currentPage,
                    profileId: profileId
                )
            }
        }
    }

    @ViewBuilder
    private func readerBody(_ document: PDFDocument) -> some View {
        #if os(iOS)
        // iOS：平时只有页面，单击出玻璃控件（plan-reading-marks P1-2，和 txt 阅读器同一套）
        attachInteractions(immersiveReader(document))
        #else
        NavigationStack {
            attachInteractions(readerChrome(document))
        }
        #endif
    }

    #if os(iOS)
    private var totalPages: Int { index?.totalChapters ?? document?.pageCount ?? 0 }

    private func immersiveReader(_ document: PDFDocument) -> some View {
        ZStack {
            Theme.mainBg.ignoresSafeArea()
            PDFKitView(document: document, initialPage: currentPage, safeName: bookSafeName, assistantName: assistantName, onPageChange: { page in
                guard page != currentPage else { return }
                currentPage = page
                scheduleSaveProgress()
                schedulePushContext()
            })
            .ignoresSafeArea(edges: .bottom)
            if isBoxSelect {
                BoxSelectOverlay { rect in
                    NotificationCenter.default.post(
                        name: .pdfBoxSelected, object: nil,
                        userInfo: ["rect": rect, "safeName": bookSafeName])
                }
            }
            if let toast = askToast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Theme.accent))
                        .padding(.bottom, 140)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            VStack(spacing: 0) {
                if isBoxSelect {
                    boxSelectBar.transition(.move(edge: .top).combined(with: .opacity))
                } else if showChrome {
                    pdfTopBar.transition(.move(edge: .top).combined(with: .opacity))
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
                if showChrome && !isBoxSelect {
                    pdfBottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !isBoxSelect {
                    pdfFooter.transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: showChrome)
        .animation(.easeOut(duration: 0.2), value: isBoxSelect)
        .animation(.easeOut(duration: 0.2), value: paletteNoteId)
        .onChange(of: currentPage) { _, _ in paletteNoteId = nil }
        .sheet(isPresented: $showPanel) { pdfPanel }
        .sheet(isPresented: $showChatDrawer) {
            BookChatDrawer(bookSafeName: bookSafeName, bookDisplayName: index?.name ?? bookSafeName,
                           currentChapter: currentPage, viewModel: viewModel, highlightMessageId: nil)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showQuotes) {
            BookQuotesView(quotes: StudyQuote.load(bookId: bookSafeName, bookName: index?.name ?? bookSafeName,
                                                   author: index?.author ?? "", profileId: profileId)
                                .sorted { $0.createdAt > $1.createdAt },
                           profileId: profileId,
                           initialBookId: bookSafeName) { q in
                showQuotes = false
                goToPage(q.chapter)
            }
        }
    }

    /// 页脚：书名 · 🍃 第 x / y 页（不挡页面点击）
    private var pdfFooter: some View {
        HStack(spacing: 4) {
            Text(index?.name ?? "").lineLimit(1)
            Spacer()
            Image(systemName: "leaf.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.branchIndicator)
                .rotationEffect(.degrees(-20))
            Text("第 \(currentPage) / \(totalPages) 页")
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 26)
        .frame(height: 22)
        .background(Theme.mainBg.opacity(0.9))
        .allowsHitTesting(false)
    }

    /// 左上 ‹ 回书房（page2 外壳里左上的轻点也会走外壳的「应用内退一层」，效果一样）；页码胶囊；书签
    private var pdfTopBar: some View {
        ZStack {
            Text("第 \(currentPage) / \(totalPages) 页")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 36)
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

    private var pdfBottomBar: some View {
        let total = totalPages
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { goToPage(currentPage - 1); bumpChrome() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(currentPage > 1 ? Theme.textPrimary : Theme.textMuted.opacity(0.4))
                .disabled(currentPage <= 1)
                .accessibilityLabel("上一页")
                if total > 1 {
                    Slider(value: Binding(get: { scrubPage ?? Double(currentPage) }, set: { scrubPage = $0 }),
                           in: 1...Double(total), step: 1) { editing in
                        if editing { chromeHideTask?.cancel(); return }
                        if let p = scrubPage { goToPage(Int(p)) }
                        scrubPage = nil
                        bumpChrome()
                    }
                    .tint(Theme.branchIndicator)
                } else {
                    Spacer()
                }
                Button { goToPage(currentPage + 1); bumpChrome() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(currentPage < total ? Theme.textPrimary : Theme.textMuted.opacity(0.4))
                .disabled(currentPage >= total)
                .accessibilityLabel("下一页")
                Text(scrubPage.map { "第 \(Int($0)) 页" } ?? "\(total > 0 ? Int((Double(currentPage) / Double(total) * 100).rounded()) : 0)%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            HStack(spacing: 0) {
                pdfTool("list.bullet", "目录") { panelTab = .catalog; showPanel = true }
                pdfTool("pencil.tip.crop.circle", "批注") { panelTab = .notes; showPanel = true }
                pdfTool("text.quote", "书摘") { showQuotes = true }
                pdfTool("bubble.left.and.bubble.right", "问\(assistantName)") { showChatDrawer = true }
                pdfTool("highlighter", "框选") {
                    chromeHideTask?.cancel()
                    isBoxSelect = true
                }
            }
            .frame(height: 58)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// 框选中：顶部一条提示 + 完成
    private var boxSelectBar: some View {
        HStack {
            Text("拖动框选文字")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("完成") { isBoxSelect = false; bumpChrome() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func pdfTool(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    enum PDFPanelTab: Hashable { case catalog, bookmarks, notes }

    /// 目录 / 书签 / 批注三页签（同 txt 阅读器；行和 mac 的两个旧 sheet 共用）
    private var pdfPanel: some View {
        let noteCount = allNotes.filter { $0.replyTo == nil && $0.rects != nil }.count
        return VStack(spacing: 0) {
            Picker("", selection: $panelTab) {
                Text("目录").tag(PDFPanelTab.catalog)
                Text(bookmarks.isEmpty ? "书签" : "书签 · \(bookmarks.count)").tag(PDFPanelTab.bookmarks)
                Text(noteCount == 0 ? "批注" : "批注 · \(noteCount)").tag(PDFPanelTab.notes)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)
            switch panelTab {
            case .catalog:
                ReaderSearchField(text: $catalogQuery)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .onChange(of: catalogQuery) { _, q in scheduleSearch(q) }
                List {
                    if !catalogQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        pdfSearchSection
                    } else {
                        pdfChapterSection
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            case .bookmarks:
                if bookmarks.isEmpty {
                    Spacer()
                    Text("还没有书签。读的时候点顶上的书签按钮加一个。")
                        .font(.system(size: 13)).foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 30)
                    Spacer()
                } else {
                    List { pdfBookmarkSection }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                }
            case .notes:
                pdfAnnotationContent
                    .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 单击没点中批注 → 出 / 收控件（框选中不响应）
    private func handleChromeTap() {
        guard !isBoxSelect else { return }
        if paletteNoteId != nil {
            paletteNoteId = nil
            return
        }
        showChrome.toggle()
        if showChrome { bumpChrome() } else { chromeHideTask?.cancel() }
    }

    /// 4 秒没操作自动收；开着面板 / 正在拖进度 / 框选时不收
    private func bumpChrome() {
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !showPanel, !showChatDrawer, !showQuotes,
                  scrubPage == nil, !isBoxSelect else { return }
            showChrome = false
        }
    }
    #endif

    /// ZStack + 顶栏 + 目录/批注列表 sheet（与 attachInteractions 拆开，
    /// 否则整条 modifier 链是单个表达式，type-check 超时——本文件实测炸过两次）
    private func readerChrome(_ document: PDFDocument) -> some View {
            ZStack {
                PDFKitView(document: document, initialPage: currentPage, safeName: bookSafeName, assistantName: assistantName, onPageChange: { page in
                    guard page != currentPage else { return }
                    currentPage = page
                    scheduleSaveProgress()
                    schedulePushContext()
                })
                if isBoxSelect {
                    BoxSelectOverlay { rect in
                        NotificationCenter.default.post(
                            name: .pdfBoxSelected, object: nil,
                            userInfo: ["rect": rect, "safeName": bookSafeName])
                    }
                    VStack {
                        Text("拖动框选文字")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.mainBg.opacity(0.92)))
                            .padding(.top, 8)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                if let toast = askToast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.accent))
                            .padding(.bottom, 40)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                boxSelectFAB
            }
            .ignoresSafeArea(edges: .bottom)
            .background(Theme.mainBg)
            .navigationTitle(index?.name ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // PDFView 是 UIKit scrollview，顶栏收不到滚动边缘信号会全透明，
            // 按钮叠在扫描页/封面图上看不见——强制实底
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Theme.mainBg, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: "chevron.down") }
                        .foregroundColor(Theme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("\(currentPage) / \(index?.totalChapters ?? document.pageCount)")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
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
                            showAnnotationList = true
                        } label: { Image(systemName: "pencil.tip.crop.circle") }
                        .foregroundColor(Theme.textSecondary)

                        Button {
                            showCatalog = true
                        } label: { Image(systemName: "list.bullet") }
                        .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .sheet(isPresented: $showCatalog) {
                catalogSheet
            }
            .sheet(isPresented: $showAnnotationList) {
                annotationListSheet
            }
    }

    /// 事件订阅 + 选段菜单/笔记编辑/就地小窗
    private func attachInteractions<V: View>(_ content: V) -> some View {
        content
            // 框选 → Coordinator 已换算成页坐标 → OCR 相交出 quote/rects → 菜单
            .onReceive(NotificationCenter.default.publisher(for: .pdfBoxResolved)) { notif in
                guard (notif.userInfo?["safeName"] as? String) == bookSafeName,
                      let page = notif.userInfo?["page"] as? Int,
                      let rect = notif.userInfo?["rect"] as? CGRect else { return }
                resolveSelection(page: page, box: rect)
            }
            // tap 命中已有批注 → 就地小窗
            .onReceive(NotificationCenter.default.publisher(for: .pdfPageTapped)) { notif in
                guard !isBoxSelect,
                      (notif.userInfo?["safeName"] as? String) == bookSafeName else { return }
                let page = notif.userInfo?["page"] as? Int
                let point = notif.userInfo?["point"] as? CGPoint
                handleTap(page: page, point: point)
            }
            // 原生选字菜单（坨坨浮条：文本层就绪的书 + 文字版 PDF）
            .onReceive(NotificationCenter.default.publisher(for: .pdfNativeSelectionAction)) { notif in
                guard (notif.userInfo?["safeName"] as? String) == bookSafeName,
                      let name = notif.userInfo?["name"] as? String,
                      let page = notif.userInfo?["page"] as? Int,
                      let quote = notif.userInfo?["quote"] as? String,
                      let rects = notif.userInfo?["rects"] as? [[Double]] else { return }
                let sel = PDFSelectionResult(page: page, quote: quote, rects: rects)
                switch name {
                case "highlight": addHighlight(sel)
                case "addNote":
                    pendingSelection = sel
                    noteEditorText = ""
                    showNoteEditor = true
                case "askAI": askAI(sel)
                case "crossPage": showToast("跨页了，分两页划")
                case "addVocab": addVocab(sel)
                #if PERSONAL_APPS
                #if DEBUG
                case "saveTopic": saveTopicFromSelection(sel)
                #endif
                #endif
                default: break
                }
            }
            // 批注变化（含 aiBubble 回填）→ 重渲染划线
            .onReceive(NotificationCenter.default.publisher(for: .bookNotesDidChange)) { notif in
                guard (notif.userInfo?["safeName"] as? String) == bookSafeName else { return }
                reloadNotes()
            }
            // 全书文本层就绪（后台索引完成）
            .onReceive(NotificationCenter.default.publisher(for: .bookTextLayerReady)) { notif in
                guard (notif.userInfo?["safeName"] as? String) == bookSafeName else { return }
                showToast("全书文字索引好了，重新打开本书就能直接选字")
            }
            .confirmationDialog(
                pendingSelection.map { sel in
                    let head = sel.quote.prefix(40)
                    return "「\(head)\(sel.quote.count > 40 ? "…" : "")」"
                } ?? "",
                isPresented: $showActionMenu,
                titleVisibility: .visible
            ) {
                Button("高亮") { if let s = pendingSelection { addHighlight(s) } }
                Button("写笔记") {
                    noteEditorText = ""
                    showNoteEditor = true
                }
                Button("问\(assistantName)") { if let s = pendingSelection { askAI(s) } }
                Button("收进生词本") { if let s = pendingSelection { addVocab(s) } }
                #if PERSONAL_APPS
                #if DEBUG
                Button("存成问题") { if let s = pendingSelection { saveTopicFromSelection(s) } }
                #endif
                #endif
                Button("取消", role: .cancel) { pendingSelection = nil }
            }
            .alert("写笔记", isPresented: $showNoteEditor) {
                TextField("想说点什么…", text: $noteEditorText)
                Button("存") { if let s = pendingSelection { addNote(s, content: noteEditorText) } }
                Button("取消", role: .cancel) { pendingSelection = nil }
            }
            #if PERSONAL_APPS
            #if DEBUG
            // 「存成问题」→ 投题 sheet
            .sheet(item: $topicRequest) { req in
                TopicComposeSheet(profileId: profileId, prefillQuote: req.quote,
                                  source: req.source, sourceLabel: req.sourceLabel)
            }
            #endif
            #endif
            .sheet(isPresented: Binding(get: { quickLookNoteIds != nil },
                                        set: { if !$0 { quickLookNoteIds = nil } })) {
                NoteQuickLookSheet(
                    noteIds: quickLookNoteIds ?? [],
                    allNotes: allNotes,
                    assistantName: assistantName,
                    onChange: { change in applyNotes(change) },
                    onShowChat: { _ in
                        quickLookNoteIds = nil
                        close()   // aiBubble → 回主对话看全文（对话就在主界面）
                    }
                )
            }
    }

    /// 框选 FAB（粟粟点的：右下角单独一个圆）
    private var boxSelectFAB: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isBoxSelect.toggle() }
                } label: {
                    Image(systemName: "highlighter")
                        .font(.system(size: 19))
                        .foregroundColor(isBoxSelect ? .white : Theme.textSecondary)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(isBoxSelect ? Theme.branchIndicator : Theme.mainBg))
                        .overlay(Circle().stroke(Theme.accent, lineWidth: isBoxSelect ? 0 : 1))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 18)
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: - 目录（outline 快照：ChapterMeta.no = 页码）

    @ViewBuilder
    private var pdfSearchSection: some View {
        Section {
            if searchResult.hits.isEmpty {
                Text("没搜到").font(.system(size: 13)).foregroundColor(Theme.textMuted)
            }
            ForEach(searchResult.hits) { hit in
                Button {
                    closePanels()
                    goToPage(hit.chapter)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(hit.title)
                                .font(.system(size: Theme.F.secondary, weight: .medium))
                                .foregroundColor(Theme.branchIndicator)
                                .lineLimit(1)
                            Spacer()
                            Text("\(hit.chapter)")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                        }
                        Text(hit.snippet)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            if let coverage = searchResult.coverage {
                Text("搜索结果 · \(coverage)")
            } else {
                Text("搜索结果")
            }
        }
    }

    @ViewBuilder
    private var pdfBookmarkSection: some View {
        Section("Bookmarks") {
            ForEach(bookmarks) { bm in
                Button {
                    closePanels()
                    goToPage(bm.chapter)
                } label: {
                    HStack {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.branchIndicator)
                        Text(bm.title).foregroundColor(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        Text("\(bm.chapter)")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                var bms = bookmarks
                bms.remove(atOffsets: offsets)
                try? BookStore.saveBookmarks(bms, safeName: bookSafeName, profileId: profileId)
                bookmarks = bms
            }
        }
    }

    private var pdfChapterSection: some View {
        Section {
            ForEach(index?.chapters ?? [], id: \.no) { ch in
                Button {
                    closePanels()
                    goToPage(ch.no)
                } label: {
                    HStack {
                        Text(ch.title)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(ch.no)")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var catalogSheet: some View {
        NavigationStack {
            List {
                if !catalogQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    pdfSearchSection
                } else {
                    if !bookmarks.isEmpty { pdfBookmarkSection }
                    pdfChapterSection
                }
            }
            .navigationTitle("目录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            #endif
            .searchable(text: $catalogQuery, prompt: "搜全书")
            .onChange(of: catalogQuery) { _, q in scheduleSearch(q) }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - F1/F2 动作

    /// 目录 / 书签 / 批注里点了一行 → 关掉所在的面板（mac 两个分开的 sheet，iOS 合成一个）
    private func closePanels() {
        showCatalog = false
        showAnnotationList = false
        #if os(iOS)
        showPanel = false
        #endif
    }

    private var hasBookmarkHere: Bool {
        bookmarks.contains { $0.chapter == currentPage }
    }

    private func toggleBookmarkHere() {
        let title = index?.chapters.last(where: { $0.no <= currentPage })
            .map { "\($0.title) · 第 \(currentPage) 页" } ?? "第 \(currentPage) 页"
        let added = BookStore.toggleBookmark(
            safeName: bookSafeName, profileId: profileId,
            chapter: currentPage, scrollRatio: 0, title: title)
        bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        showToast(added ? "已加书签" : "书签已取消")
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResult = .init(hits: []); return }
        guard let doc = document else { return }
        let hasText = index?.hasTextLayer == true
        let chapters = index?.chapters ?? []
        let safe = bookSafeName, pid = profileId
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                BookSearch.searchPDF(query: q, document: doc, hasTextLayer: hasText,
                                     safeName: safe, profileId: pid, chapters: chapters)
            }.value
            guard !Task.isCancelled else { return }
            searchResult = result
        }
    }

    private func goToPage(_ page: Int) {
        // currentPage 不预设——由 PDFViewPageChanged 回调驱动，页码指示器只报真跳转
        NotificationCenter.default.post(name: .pdfReaderGoToPage, object: nil, userInfo: ["page": page, "safeName": bookSafeName])
    }

    // MARK: - 批注列表（铅笔按钮：全书批注卡片，与 txt 阅读器抽屉同心智）

    private var annotationListSheet: some View {
        NavigationStack {
            pdfAnnotationContent
                .navigationTitle("批注")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        .presentationDetents([.medium, .large])
    }

    private var pdfAnnotationContent: some View {
        let topLevel = allNotes.filter { $0.replyTo == nil && $0.rects != nil }
            .sorted { ($0.chapter, $0.createdAt) < ($1.chapter, $1.createdAt) }
        let pages = Dictionary(grouping: topLevel, by: \.chapter).keys.sorted()
        return Group {
            if topLevel.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.system(size: 26)).foregroundColor(Theme.textMuted)
                    Text("还没有批注").font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                    Text("选字后点「高亮」，或用工具栏的框选").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(pages, id: \.self) { page in
                        Section {
                            ForEach(topLevel.filter { $0.chapter == page }) { note in
                                annotationCard(note)
                            }
                        } header: {
                            Text(pageHeader(page))
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
            }
        }
    }

    private func annotationCard(_ note: BookStore.Note) -> some View {
        let isAI = note.role == "ai"
        let replies = allNotes.filter { $0.replyTo == note.id }
        return Button {
            closePanels()
            if note.chapter != currentPage { goToPage(note.chapter) }
            quickLookNoteIds = [note.id]
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(HighlightPalette.color(note.strokeColorHex))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("「\(note.anchorText.replacingOccurrences(of: "\n", with: " "))」")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                    if !note.content.isEmpty {
                        Text(note.content)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(3)
                    }
                    HStack(spacing: 6) {
                        Text(isAI ? assistantName : "你")
                        Text(kindLabel(note.kind))
                        if !replies.isEmpty { Text("\(replies.count) 条回复") }
                    }
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func pageHeader(_ page: Int) -> String {
        if let title = index?.chapters.last(where: { $0.no <= page })?.title {
            return "第 \(page) 页 · \(title)"
        }
        return "第 \(page) 页"
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "highlight": return "高亮"
        case "note": return "笔记"
        case "aiBubble": return "回答"
        default: return kind
        }
    }

    // MARK: - 业务

    private func loadBook() {
        guard let idx = BookStore.loadIndex(safeName: bookSafeName, profileId: profileId) else {
            loadError = "找不到《\(bookSafeName)》"
            return
        }
        let url = BookStore.bookDir(safeName: bookSafeName, profileId: profileId).appendingPathComponent("book.pdf")
        guard let doc = PDFDocument(url: url) else {
            loadError = "无法打开 PDF 文件"
            return
        }
        index = idx
        currentPage = max(1, min(doc.pageCount, initialPage ?? idx.currentChapter))
        document = doc
        allNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        renderAnnotations(on: doc)
        schedulePushContext()   // 开书即推——她一打开，daemon 就有材料
        if idx.hasTextLayer == false {
            let safe = bookSafeName, pid = profileId
            Task.detached(priority: .utility) {
                await BookOCRIndexer.shared.indexIfNeeded(safeName: safe, profileId: pid)
            }
        }
    }

    // MARK: - P2 框选批注

    /// 框（页坐标）→ 该页 OCR 行相交 → quote + 贴行 rects → 弹菜单。
    /// 文字版 PDF 的 PDFSelection 原生选字路线后置（验收标的是扫描版）。
    private func resolveSelection(page: Int, box: CGRect) {
        guard let doc = document else { return }
        isBoxSelect = false
        Task { @MainActor in
            let lines = await OCRStore.shared.pageLines(
                safeName: bookSafeName, profileId: profileId, page: page, document: doc)
            guard let sel = OCRStore.selection(from: lines, in: box) else {
                showToast("框里没认出文字")
                return
            }
            pendingSelection = PDFSelectionResult(page: page, quote: sel.quote, rects: sel.rects)
            showActionMenu = true
        }
    }

    private func addHighlight(_ sel: PDFSelectionResult) {
        var note = fidelityNote(sel, kind: "highlight", content: "")
        note.color = lastHighlightColor
        note.style = lastHighlightStyle
        appendNote(note)
        #if os(iOS)
        paletteNoteId = note.id
        #endif
        pendingSelection = nil
        ReadingSignals.logEvent(type: "highlight", book: bookSafeName, chapter: sel.page, profileId: profileId)
    }

    private func addNote(_ sel: PDFSelectionResult, content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { pendingSelection = nil; return }
        if let place = NoteThreads.existingPlace(chapter: sel.page, start: 0, end: 0, rects: sel.rects, in: allNotes) {
            applyNotes { NoteThreads.addEntry(text, to: place, in: &$0) }
        } else {
            var note = fidelityNote(sel, kind: "note", content: text)
            note.color = lastHighlightColor
            note.style = lastHighlightStyle
            appendNote(note)
        }
        pendingSelection = nil
        ReadingSignals.logEvent(type: "note", book: bookSafeName, chapter: sel.page, profileId: profileId)
    }

    /// 与 BookReaderSheet.askXiaoke 同构：选段发进主对话（bookRef 双向锚）+ aiBubble 占位，
    /// 回复由 BookNoteBackfill 回填 → .bookNotesDidChange → 本页玫瑰划线即时可见。
    private func askAI(_ sel: PDFSelectionResult) {
        defer { pendingSelection = nil }
        guard let prof = profileManager?.currentProfile,
              let pm = providerManager,
              let psm = presetManager else {
            showToast("缺少 Profile/Provider/Preset，没法发")
            return
        }
        let title = index?.chapters.last(where: { $0.no <= sel.page })?.title ?? "第 \(sel.page) 页"
        let bookName = index?.name ?? bookSafeName
        let quote = """
        （在《\(bookName)》\(title) 读到）
        「\(sel.quote)」

        你怎么看？
        """
        if viewModel.selectedConversation == nil {
            viewModel.startDraftConversation(profileId: prof.id)
        }
        let model = pm.resolveModel(
            conversationModelId: viewModel.selectedConversation?.selectedModelId,
            globalFallbackId: nil)
        let preset = psm.preset(byId: prof.presetId) ?? .balanced
        let sent = viewModel.sendMessage(quote, model: model, profile: prof, preset: preset,
                                         providerManager: pm, context: modelContext)
        guard sent else { showToast("发送失败"); return }

        if let lastUser = viewModel.currentPath.last(where: { $0.role == "user" }) {
            lastUser.bookRef = "\(bookSafeName)#chapter\(sel.page)"
            try? lastUser.modelContext?.save()
        }
        var note = fidelityNote(sel, kind: "aiBubble", content: "（\(assistantName)正在回答…）")
        note.role = "ai"
        note.messageId = viewModel.currentPath.last(where: { $0.role == "user" })?.id
        appendNote(note)
        ReadingSignals.logEvent(type: "askAI", book: bookSafeName, chapter: sel.page, profileId: profileId)
        showToast("已发给\(assistantName)，回答会长在这条划线上")
    }

    private func addVocab(_ sel: PDFSelectionResult) {
        defer { pendingSelection = nil }
        let word = VocabCollector.collect(
            rawText: sel.quote, bookSafeName: bookSafeName,
            chapter: sel.page, anchorStart: 0, context: modelContext)
        guard let word else { showToast("选段不适合收词"); return }
        showToast("已收「\(word)」进生词本")
        ReadingSignals.logEvent(type: "vocab", book: bookSafeName, chapter: sel.page, word: word, profileId: profileId)
    }

    #if PERSONAL_APPS
    #if DEBUG
    /// 坨坨/框选「存成问题」：选段进引文投话题盒，source 带页锚（book:<safeName>#page=N）。
    private func saveTopicFromSelection(_ sel: PDFSelectionResult) {
        pendingSelection = nil
        topicRequest = TopicComposeRequest(
            quote: sel.quote,
            source: "book:\(bookSafeName)#page=\(sel.page)",
            sourceLabel: "《\(index?.name ?? bookSafeName)》· 第 \(sel.page) 页"
        )
    }
    #endif
    #endif

    private func fidelityNote(_ sel: PDFSelectionResult, kind: String, content: String) -> BookStore.Note {
        var note = BookStore.Note(
            id: UUID().uuidString, chapter: sel.page,
            anchorText: sel.quote, anchorStart: 0, anchorEnd: 0,
            kind: kind, content: content, role: "user",
            messageId: nil, createdAt: Date())
        note.rects = sel.rects
        return note
    }

    private func appendNote(_ note: BookStore.Note) {
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        all.append(note)
        try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
        reloadNotes()
    }

    /// 跑一段 NoteThreads 改动（P3 契约：删不级联、删根只清内容、删整处 AI 写的留下）→ 存盘 → 重画
    private func applyNotes(_ change: (inout [BookStore.Note]) -> Void) {
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        change(&all)
        try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
        reloadNotes()
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
        reloadNotes()
    }

    private func reloadNotes() {
        allNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        if let doc = document { renderAnnotations(on: doc) }
    }

    // MARK: - 划线渲染（P2-4：底色 = 高亮注释，下划线 = 细实线块按层往下错，彩笔 = 手绘笔道）

    private func renderAnnotations(on doc: PDFDocument) {
        for ann in renderedAnnotations { ann.page?.removeAnnotation(ann) }
        renderedAnnotations.removeAll()

        let strokes = allNotes.filter { $0.replyTo == nil && !($0.rects ?? []).isEmpty && $0.chapter >= 1 }
        // 下划线层号：同页里和它有框相交的更早下划线占了哪些层，就取剩下最小的
        var layers: [String: Int] = [:]
        var placed: [(note: BookStore.Note, layer: Int)] = []
        for note in strokes where note.strokeStyle == .underline {
            let busy = Set(placed.filter { $0.note.chapter == note.chapter && Self.rectsOverlap($0.note, note) }.map(\.layer))
            var k = 0
            while busy.contains(k) { k += 1 }
            placed.append((note, k))
            layers[note.id] = k
        }

        for note in strokes {
            guard let page = doc.page(at: note.chapter - 1) else { continue }
            let v = HighlightPalette.hexValue(note.strokeColorHex) ?? 0x8EBD9F
            func color(_ alpha: CGFloat) -> PlatformColor {
                PlatformColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                              blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
            }
            for (i, r) in (note.rects ?? []).enumerated() where r.count == 4 {
                let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
                let ann: PDFAnnotation
                switch note.strokeStyle {
                case .fill:
                    ann = PDFAnnotation(bounds: rect.insetBy(dx: -1.5, dy: -1.5), forType: .highlight, withProperties: nil)
                    ann.color = color(0.42)
                case .underline:
                    let k = CGFloat(layers[note.id] ?? 0)
                    let line = CGRect(x: rect.minX, y: rect.minY - 1.5 - k * 2.6, width: rect.width, height: 1.4)
                    let u = PDFAnnotation(bounds: line, forType: .square, withProperties: nil)
                    u.color = .clear
                    u.interiorColor = color(0.9)
                    let border = PDFBorder()
                    border.lineWidth = 0
                    u.border = border
                    ann = u
                case .pen:
                    let pen = PenStrokeAnnotation(bounds: rect.insetBy(dx: -3, dy: -2), forType: .ink, withProperties: nil)
                    pen.fill = color(0.45)
                    pen.seed = Self.seed(note.id, i)
                    ann = pen
                }
                ann.fieldName = note.id
                page.addAnnotation(ann)
                renderedAnnotations.append(ann)
            }
        }
    }

    private static func rectsOverlap(_ a: BookStore.Note, _ b: BookStore.Note) -> Bool {
        let ra = (a.rects ?? []).filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        let rb = (b.rects ?? []).filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        return ra.contains { x in rb.contains { $0.intersects(x) } }
    }

    private static func seed(_ id: String, _ index: Int) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return h &+ UInt64(index) &* 0x9E3779B97F4A7C15
    }

    /// tap（页坐标）命中批注 rects（扩 6pt 容错）→ 就地小窗
    private func handleTap(page: Int?, point: CGPoint?) {
        guard let page, let point else {
            #if os(iOS)
            handleChromeTap()
            #endif
            return
        }
        let hitIds = allNotes.filter { note in
            note.replyTo == nil && note.chapter == page &&
            (note.rects ?? []).contains { r in
                r.count == 4 &&
                CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).insetBy(dx: -6, dy: -6).contains(point)
            }
        }.map(\.id)
        guard !hitIds.isEmpty else {
            #if os(iOS)
            handleChromeTap()
            #endif
            return
        }
        quickLookNoteIds = hitIds
    }

    private func showToast(_ text: String) {
        withAnimation { askToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if askToast == text { withAnimation { askToast = nil } }
        }
    }

    private func scheduleSaveProgress() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, var idx = index else { return }
            idx.currentChapter = currentPage
            idx.updatedAt = Date()
            try? BookStore.saveIndex(idx, safeName: bookSafeName, profileId: profileId)
            index = idx

            let safe = bookSafeName
            let pid = profileId
            let desc = FetchDescriptor<BookEntry>(
                predicate: #Predicate<BookEntry> { $0.id == safe && $0.profileId == pid }
            )
            if let entry = (try? modelContext.fetch(desc))?.first {
                entry.currentChapter = currentPage
                entry.lastReadAt = Date()
                try? modelContext.save()
            }
        }
    }

    // MARK: - CR-4 上行（P1.5：「章」= 页窗口，扫描版文本来自 OCR 缓存）

    /// 翻页停稳 2s 才推（OCR ~5s/页是贵活，翻页中取消重排）。
    private func schedulePushContext() {
        contextTask?.cancel()
        contextTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let doc = document, let idx = index else { return }
            let page = currentPage
            let hasText = idx.hasTextLayer == true

            // 页窗口 = 当前页 ±1，给 daemon 足够的阅读语境
            var texts: [String] = []
            for p in max(1, page - 1)...min(doc.pageCount, page + 1) {
                if hasText {
                    texts.append(doc.page(at: p - 1)?.string ?? "")
                } else {
                    texts.append(await OCRStore.shared.pageText(
                        safeName: bookSafeName, profileId: profileId, page: p, document: doc))
                }
            }
            guard !Task.isCancelled, currentPage == page else { return }
            pushReadingContext(page: page, text: texts.joined(separator: "\n\n"))

            if !hasText {
                let safe = bookSafeName, pid = profileId
                Task.detached(priority: .utility) {
                    await OCRStore.shared.prefetch(safeName: safe, profileId: pid, around: page, document: doc)
                }
            }
        }
    }

    /// 与 BookReaderSheet.pushReadingContext 同构——chapter 语义 = 页码，
    /// chapterTitle = outline 里 ≤ 当前页的最近章名（页窗口的可读定位）。
    private func pushReadingContext(page: Int, text: String) {
        let title = index?.chapters.last(where: { $0.no <= page })?.title ?? "第 \(page) 页"
        let userNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
            .filter { $0.role == "user" && $0.chapter == page }
            .map {
                [
                    "id": $0.id,
                    "anchorText": String($0.anchorText.prefix(120)),
                    "content": String($0.content.prefix(200)),
                ]
            }
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
            "chapter": page,
            "totalChapters": index?.totalChapters ?? 0,
            "chapterTitle": title,
            "text": String(text.prefix(60_000)),
            "userNotes": userNotes,
            "persona": persona,
        ]) { _ in }
    }

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
}

extension Notification.Name {
    /// PDF 阅读器跳页请求（目录 tap → PDFKitView 桥接）。userInfo: page(Int)/safeName。
    static let pdfReaderGoToPage = Notification.Name("MemoryPalacePDFReaderGoToPage")
    /// 框选完成（overlay → Coordinator，rect 是 PDFView 视图坐标）。userInfo: rect(CGRect)/safeName。
    static let pdfBoxSelected = Notification.Name("MemoryPalacePDFBoxSelected")
    /// 框选已换算页坐标（Coordinator → sheet）。userInfo: page(Int)/rect(CGRect)/safeName。
    static let pdfBoxResolved = Notification.Name("MemoryPalacePDFBoxResolved")
    /// 单击页面（Coordinator → sheet，点已换算页坐标）。userInfo: page(Int)/point(CGPoint)/safeName。
    static let pdfPageTapped = Notification.Name("MemoryPalacePDFPageTapped")
}

#if os(iOS)
typealias PlatformColor = UIColor
#else
typealias PlatformColor = NSColor
#endif

// MARK: - 框选 overlay（虚线框，松手上报）

struct BoxSelectOverlay: View {
    let onDone: (CGRect) -> Void

    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil

    private var rect: CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)   // 吞手势（VStack 空白穿透教训）
            if let r = rect {
                ZStack {
                    Rectangle().fill(Theme.branchIndicator.opacity(0.12))
                    Rectangle().stroke(Theme.branchIndicator,
                                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if startPoint == nil { startPoint = v.startLocation }
                    currentPoint = v.location
                }
                .onEnded { _ in
                    if let r = rect, r.width > 12, r.height > 8 { onDone(r) }
                    startPoint = nil
                    currentPoint = nil
                }
        )
    }
}

// MARK: - PDFView 桥接（双端）

#if os(iOS)
private typealias PlatformViewRepresentable = UIViewRepresentable
#else
private typealias PlatformViewRepresentable = NSViewRepresentable
#endif

struct PDFKitView: PlatformViewRepresentable {
    let document: PDFDocument
    let initialPage: Int
    var safeName: String = ""
    var assistantName: String = "助手"
    let onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(onPageChange: onPageChange)
        c.tapSafeName = safeName
        return c
    }

    private func makePDFView(coordinator: Coordinator) -> PDFView {
        let view = MPPDFView()
        view.bookSafeName = safeName
        view.assistantName = assistantName
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        #if os(iOS)
        view.usePageViewController(false)
        #endif
        coordinator.observe(view)
        if initialPage > 1 {
            coordinator.jump(to: initialPage, initial: true)
        }
        return view
    }

    #if os(iOS)
    func makeUIView(context: Context) -> PDFView { makePDFView(coordinator: context.coordinator) }
    func updateUIView(_ view: PDFView, context: Context) {}
    #else
    func makeNSView(context: Context) -> PDFView { makePDFView(coordinator: context.coordinator) }
    func updateNSView(_ view: PDFView, context: Context) {}
    #endif

    final class Coordinator: NSObject {
        let onPageChange: (Int) -> Void
        private weak var pdfView: PDFView?
        private var observers: [NSObjectProtocol] = []
        /// 初始进度恢复的目标页：到达前抑制 onPageChange——恢复途中 PDFView 停在
        /// 第 1 页也会发 PageChanged，直接回调会把她的进度反写成 1（645 页书实测踩过）。
        private var initialTarget: Int? = nil

        init(onPageChange: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
        }

        func observe(_ view: PDFView) {
            pdfView = view
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                guard let self, let v = self.pdfView,
                      let page = v.currentPage,
                      let idx = v.document?.index(for: page) else { return }
                if let target = self.initialTarget {
                    guard idx + 1 == target else { return }
                    self.initialTarget = nil
                }
                self.onPageChange(idx + 1)
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .pdfReaderGoToPage, object: nil, queue: .main
            ) { [weak self] notif in
                guard let page = notif.userInfo?["page"] as? Int else { return }
                self?.jump(to: page)
            })
            // P2 框选：视图坐标 → 页坐标（框中心定页，rect clamp 该页）
            observers.append(NotificationCenter.default.addObserver(
                forName: .pdfBoxSelected, object: nil, queue: .main
            ) { [weak self] notif in
                guard let self, let v = self.pdfView, let doc = v.document,
                      let rect = notif.userInfo?["rect"] as? CGRect,
                      let safeName = notif.userInfo?["safeName"] as? String,
                      let page = v.page(for: CGPoint(x: rect.midX, y: rect.midY), nearest: true)
                else { return }
                let pageRect = v.convert(rect, to: page)
                NotificationCenter.default.post(name: .pdfBoxResolved, object: nil, userInfo: [
                    "page": doc.index(for: page) + 1,
                    "rect": pageRect,
                    "safeName": safeName,
                ])
            })
            // P2 tap 命中批注（与 PDFView 自带手势共存）
            #if os(iOS)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            #else
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            click.delaysPrimaryMouseButtonEvents = false
            view.addGestureRecognizer(click)
            #endif
        }

        var tapSafeName: String = ""

        #if os(iOS)
        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            postTap(at: g.location(in: pdfView))
        }
        #else
        @objc private func handleClick(_ g: NSClickGestureRecognizer) {
            postTap(at: g.location(in: pdfView))
        }
        #endif

        /// 单击：落在页上 → 带页码和页内坐标（点中批注开批注，否则出 / 收控件）；
        /// 落在页外空白（页边 / 页间隙）→ 不带页码，也用来出 / 收控件（astra #17：以前页外单击没反应）。
        /// 有选区时这一下是「取消选字」，不算单击。
        private func postTap(at point: CGPoint) {
            guard let v = pdfView, let doc = v.document else { return }
            if let sel = v.currentSelection, !(sel.string ?? "").isEmpty { return }
            var info: [String: Any] = ["safeName": tapSafeName]
            if let page = v.page(for: point, nearest: false) {
                info["page"] = doc.index(for: page) + 1
                info["point"] = v.convert(point, to: page)
            }
            NotificationCenter.default.post(name: .pdfPageTapped, object: nil, userInfo: info)
        }

        /// 大文档 singlePageContinuous 的目标区域是 lazy 布局，首跳会被后续
        /// layout 滚回去——跳后延迟校验，没到就补刀。initial=进度恢复模式
        /// （645 页首开布局慢，重试窗口更长 + 到达前抑制页码回调）。
        func jump(to pageNo: Int, retries: Int = 2, initial: Bool = false) {
            if initial { initialTarget = pageNo }
            guard let v = pdfView, let doc = v.document,
                  let target = doc.page(at: pageNo - 1) else { return }
            let top = CGPoint(x: 0, y: target.bounds(for: .cropBox).height)
            v.go(to: PDFDestination(page: target, at: top))
            let tries = initial ? 8 : retries
            guard tries > 0 else {
                if initialTarget == pageNo { initialTarget = nil }   // 放弃：解除抑制，不反写进度
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let v = self.pdfView,
                      let cur = v.currentPage, let doc = v.document else { return }
                if doc.index(for: cur) != pageNo - 1 {
                    self.jump(to: pageNo, retries: tries - 1)
                }
            }
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

#if os(iOS)
extension PDFKitView.Coordinator: UIGestureRecognizerDelegate {
    // PDFView 自带 pan/pinch/长按——tap 必须共存否则被内部手势吞
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// 单击要等双击失败：PDFView 的双击缩放是它自己动态建的，不写死名单，
    /// 用 delegate 按类型认（Apple 对框架内部手势推荐的做法，astra #17）
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer,
              let tap = other as? UITapGestureRecognizer else { return false }
        return tap.numberOfTapsRequired >= 2
    }
}
#endif

// MARK: - 原生选字菜单（「坨坨」出口：PDFSelection → 批注四项）
// 文本层就绪的书（含文字版 PDF）长按选字后，浮条里出现我们的条目。
// 与 MPReaderWebView（txt 侧）同款：UIMenuController.menuItems 注入 +
// didMoveToWindow 清理；action 读 currentSelection 组 quote + 分行 rects
// （bounds(for:) 是页空间坐标，与 OCR bbox 同系）→ 通知给 sheet 走 P2 动作。

extension Notification.Name {
    /// 原生选字菜单动作。userInfo: name/page(Int)/quote/rects([[Double]])/safeName。
    static let pdfNativeSelectionAction = Notification.Name("MemoryPalacePDFNativeSelectionAction")
}

final class MPPDFView: PDFView {
    var bookSafeName: String = ""
    var assistantName: String = "助手"

    #if os(iOS)
    /// 新式编辑菜单（buildMenu）一旦被调用过，就不再往旧的全局 UIMenuController 塞，免得同一项出现两次
    private static var editMenuBuilderWorks = false
    private var selectionObserver: NSObjectProtocol?

    /// 旧式：往全局共享菜单塞。iOS 16+ PDFView 的选字菜单多半已不读它（09-26 iOS 27 实机：选字菜单里没有我们的项），留作兜底
    func installCustomMenuItems() {
        guard !Self.editMenuBuilderWorks else { return }
        var menuItems = [
            UIMenuItem(title: "高亮", action: #selector(mp_highlight(_:))),
            UIMenuItem(title: "加笔记", action: #selector(mp_addNote(_:))),
            UIMenuItem(title: "问\(assistantName)", action: #selector(mp_askAI(_:))),
            UIMenuItem(title: "收生词", action: #selector(mp_addVocab(_:))),
        ]
        #if PERSONAL_APPS
        #if DEBUG
        menuItems.append(UIMenuItem(title: "存成问题", action: #selector(mp_saveTopic(_:))))
        #endif
        #endif
        UIMenuController.shared.menuItems = menuItems
    }

    /// 新式：系统拼选字菜单时插到最前面（iOS 16+ 编辑菜单走 UIMenuBuilder，context 系统）
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context,
              let text = currentSelection?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !Self.editMenuBuilderWorks {
            Self.editMenuBuilderWorks = true
            UIMenuController.shared.menuItems = nil
        }
        var items: [(String, String, String)] = [
            ("高亮", "highlighter", "highlight"),
            ("加笔记", "square.and.pencil", "addNote"),
            ("问\(assistantName)", "bubble.left.and.bubble.right", "askAI"),
            ("收生词", "character.book.closed", "addVocab"),
        ]
        #if PERSONAL_APPS
        #if DEBUG
        items.append(("存成问题", "questionmark.bubble", "saveTopic"))
        #endif
        #endif
        let actions = items.map { title, icon, name in
            UIAction(title: title, image: UIImage(systemName: icon)) { [weak self] _ in self?.postSelectionAction(name) }
        }
        builder.insertChild(UIMenu(options: .displayInline, children: actions), atStartOfMenu: .root)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            UIMenuController.shared.menuItems = nil
            selectionObserver.map(NotificationCenter.default.removeObserver)
            selectionObserver = nil
        } else {
            installCustomMenuItems()
            // 共享菜单谁都能清（比如刚关掉的 txt 阅读器离屏时置 nil）：每次选中文字都重新塞一遍
            if selectionObserver == nil {
                selectionObserver = NotificationCenter.default.addObserver(
                    forName: .PDFViewSelectionChanged, object: self, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !(self.currentSelection?.string ?? "").isEmpty else { return }
                        self.installCustomMenuItems()
                    }
                }
            }
        }
    }
    #else
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard currentSelection?.string?.isEmpty == false else { return menu }
        menu.addItem(.separator())
        var entries: [(String, Selector)] = [("高亮", #selector(mp_highlight(_:))),
                                             ("加笔记", #selector(mp_addNote(_:))),
                                             ("问\(assistantName)", #selector(mp_askAI(_:))),
                                             ("收生词", #selector(mp_addVocab(_:)))]
        #if PERSONAL_APPS
        #if DEBUG
        entries.append(("存成问题", #selector(mp_saveTopic(_:))))
        #endif
        #endif
        for (title, sel) in entries {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }
    #endif

    private func postSelectionAction(_ name: String) {
        guard let selection = currentSelection,
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let page = selection.pages.first,
              let doc = document else { return }
        // 首版划线只支持单页选区（跨页的框会只落在第一页）；其它动作只用文字，照常
        if name == "highlight" && selection.pages.count > 1 {
            NotificationCenter.default.post(name: .pdfNativeSelectionAction, object: nil, userInfo: [
                "name": "crossPage", "page": doc.index(for: page) + 1, "quote": text,
                "rects": [[Double]](), "safeName": bookSafeName,
            ])
            return
        }
        let rects: [[Double]] = selection.selectionsByLine().compactMap { line in
            guard let p = line.pages.first, p === page else { return nil }
            let b = line.bounds(for: p)
            guard b.width > 0, b.height > 0 else { return nil }
            return [b.origin.x, b.origin.y, b.width, b.height]
        }
        guard !rects.isEmpty else { return }
        NotificationCenter.default.post(name: .pdfNativeSelectionAction, object: nil, userInfo: [
            "name": name,
            "page": doc.index(for: page) + 1,
            "quote": text,
            "rects": rects,
            "safeName": bookSafeName,
        ])
        clearSelection()
    }

    @objc func mp_highlight(_ sender: Any?) { postSelectionAction("highlight") }
    @objc func mp_addNote(_ sender: Any?) { postSelectionAction("addNote") }
    @objc func mp_askAI(_ sender: Any?) { postSelectionAction("askAI") }
    @objc func mp_addVocab(_ sender: Any?) { postSelectionAction("addVocab") }
    @objc func mp_saveTopic(_ sender: Any?) { postSelectionAction("saveTopic") }
}

/// 彩笔划线：压在字下半截的马克笔笔道，上下边缘有点抖；形状由笔画 id + 第几行决定，重画不变。
final class PenStrokeAnnotation: PDFAnnotation {
    var seed: UInt64 = 0
    var fill: PlatformColor = .clear

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let b = bounds.insetBy(dx: 3, dy: 2)
        var h = seed
        func j(_ spread: CGFloat) -> CGFloat {
            h = h &* 6364136223846793005 &+ 1442695040888963407
            return (CGFloat(h >> 33) / CGFloat(1 << 31) - 0.5) * spread
        }
        let bottom = b.minY + b.height * 0.06, top = b.minY + b.height * 0.55
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.minX + j(2), y: bottom + j(b.height * 0.08)))
        p.addQuadCurve(to: CGPoint(x: b.maxX + j(2), y: bottom + j(b.height * 0.08)),
                       control: CGPoint(x: b.midX, y: bottom + j(b.height * 0.14)))
        p.addLine(to: CGPoint(x: b.maxX + j(2), y: top + j(b.height * 0.08)))
        p.addQuadCurve(to: CGPoint(x: b.minX + j(2), y: top + j(b.height * 0.08)),
                       control: CGPoint(x: b.midX, y: top + j(b.height * 0.14)))
        p.closeSubpath()
        context.saveGState()
        context.addPath(p)
        context.setFillColor(fill.cgColor)
        context.fillPath()
        context.restoreGState()
    }
}
