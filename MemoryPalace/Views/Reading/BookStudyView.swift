#if os(iOS)
import SwiftUI
import CoreMotion

/// page2「书房」（plan-reading-study §2.1）：墙 + 窗光 + 花园叶影（随陀螺仪）+ 木板书架上的 3D 书。
/// 只管书房这一屏的样子；导入 / 删除 / 打开阅读器 / 回到上次那本书都还在 `BookshelfView` 里。
struct BookStudyContent: View {
    let entries: [BookEntry]
    let profileId: String
    let isReading: Bool
    var onImport: () -> Void
    var onOpen: (BookEntry) -> Void
    var onDelete: (BookEntry) -> Void
    /// 长按「重新分章」（只 txt 书有）
    var onRechapter: (BookEntry) -> Void = { _ in }
    /// 书摘「翻到这一页」：打开那本书并跳到这句
    var onOpenQuote: (StudyQuote) -> Void = { _ in }

    @Environment(\.page2AppActive) private var appActive
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedId: String?
    @State private var tilt = StudyTilt()
    @State private var weekSeconds = 0
    /// 每本书的书签 / 划线（后台读 bookmarks.json / notes.json，不在 body 里读文件）
    @State private var marks: [String: StudyMarks] = [:]
    /// 所有书的书摘（新的在前），跟 marks 一起后台读
    @State private var quotes: [StudyQuote] = []
    @State private var showQuotes = false
    @State private var showSettings = false
    /// ⚙ 里的两个选择（⧫ 粟粟 09-25：三种布局都要，拟物只在书房；便签回形针 / 吊牌可选）
    @AppStorage("study.layout") private var layoutRaw = StudyLayout.study.rawValue
    @AppStorage("study.noteStyle") private var noteStyleRaw = StudyNoteStyle.clip.rawValue
    private var layout: StudyLayout { StudyLayout(rawValue: layoutRaw) ?? .study }

    static let flip = Animation.timingCurve(0.22, 0.8, 0.24, 1, duration: 0.82)

    /// 最近读过的那本（entries 已按 lastReadAt 倒序）
    private var recent: BookEntry? { entries.first { $0.lastReadAt != nil } }
    private var selected: BookEntry? { entries.first { $0.id == selectedId } ?? recent ?? entries.first }
    /// 陀螺仪只在书房在前台、没开着书时读（⧫ 粟粟 09-25：进去看书就关）
    private var motionWanted: Bool { layout == .study && appActive && !isReading && scenePhase == .active && !reduceMotion }

    var body: some View {
        ZStack {
            if layout == .study {
                // 墙色固定，不随选中的书变（⧫ 粟粟 09-25：换书整个背景色调都变了，不要这样）
                StudyPaper.wall.ignoresSafeArea()
                RadialGradient(colors: [Color(hex: 0xFFFAEB, alpha: 0.85), Color(hex: 0xFFFAEB, alpha: 0)],
                               center: UnitPoint(x: 0.72, y: 0.08), startRadius: 0, endRadius: 340)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                StudyLeafShadow(tilt: tilt, swaying: motionWanted)
            } else {
                Theme.mainBg.ignoresSafeArea()
            }
            VStack(spacing: 0) {
                header
                switch layout {
                case .study:
                    Spacer(minLength: 16)
                        .overlay(alignment: .topTrailing) {
                            if let latest = quotes.first {
                                StudyQuoteNote(style: StudyNoteStyle(rawValue: noteStyleRaw) ?? .clip,
                                               count: quotes.count, latest: latest.text, tilt: tilt)
                                    .padding(.trailing, 18)
                                    .padding(.top, 34)     // 09-26：回形针卡太靠上，往下挪
                                    .contentShape(Rectangle())
                                    .onTapGesture { showQuotes = true }
                                    .accessibilityElement()
                                    .accessibilityLabel("书摘，\(quotes.count) 条")
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                    shelf
                    // 固定高度：书名再长也只在这块里折行 / 截断，不把书架往上顶（⧫ 粟粟 09-25）
                    Group {
                        if let selected { info(selected) } else { emptyInfo }
                    }
                    .frame(height: 220, alignment: .top)
                    Spacer(minLength: 24)
                case .grid:
                    if entries.isEmpty { plainEmpty } else { gridLayout }
                case .list:
                    if entries.isEmpty { plainEmpty } else { listLayout }
                }
            }
        }
        .onAppear {
            weekSeconds = Self.weekSeconds(profileId: profileId)
            if motionWanted { tilt.start() }
        }
        .task(id: entries.map(\.id)) { await reloadMarks() }
        .onReceive(NotificationCenter.default.publisher(for: .bookNotesDidChange)) { _ in
            Task { await reloadMarks() }
        }
        .onDisappear { tilt.stop() }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await reloadMarks() } }) {
            NavigationStack {
                ReadingSettingsTab()
                    // 设置页本身是透明底（设置主页垫着底色）；单独弹出来要自己垫，否则是系统纯白（09-26 颜色错乱）
                    .background(Theme.sidebarBg.ignoresSafeArea())
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
            }
            .tint(Theme.branchIndicator)
            .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $showQuotes) {
            BookQuotesView(quotes: quotes, profileId: profileId) { q in
                showQuotes = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenQuote(q) }
            }
        }
        .onChange(of: motionWanted) { _, on in on ? tilt.start() : tilt.stop() }
        .onChange(of: isReading) { _, reading in
            // 读完回来刷新「本周读了多久」
            if !reading {
                weekSeconds = Self.weekSeconds(profileId: profileId)
                Task { await reloadMarks() }
            }
        }
    }

    // MARK: - 标题

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("书房")
                    .font(.custom("Songti SC", size: 30).bold())
                    .foregroundStyle(Theme.textPrimary)
                if !entries.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if layout != .study, !quotes.isEmpty {
                Button { showQuotes = true } label: {
                    Text("书摘 \(quotes.count)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                }
                .buttonStyle(.glass)
            }
            settingsMenu
            Button(action: onImport) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("导入书")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }

    /// ⚙ = 设置里「书房」那一页，弹 sheet（⧫ 粟粟 09-25：设置变成 sheet，和全局设置-读书合并）
    private var settingsMenu: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("书房设置")
    }

    private var subtitle: String {
        var parts = ["\(entries.count) 本"]
        if weekSeconds >= 60 {
            let m = weekSeconds / 60
            parts.append(m >= 60 ? "本周读了 \(m / 60) 小时\(m % 60 >= 30 ? "半" : "")" : "本周读了 \(m) 分钟")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 书架

    @ViewBuilder
    private func bookMenu(_ entry: BookEntry) -> some View {
        if entry.format == "txt" {
            Button("重新分章", systemImage: "scissors") { onRechapter(entry) }
        }
        Button("删除", systemImage: "trash", role: .destructive) { onDelete(entry) }
    }

    private var shelf: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                        StudyBook(entry: entry, selected: entry.id == selected?.id, marks: marks[entry.id])
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture { tap(entry, proxy: proxy) }
                            .contextMenu { bookMenu(entry) }
                        if i == min(2, entries.count - 1) {
                            StudyPlant().padding(.horizontal, 6)
                        }
                    }
                    if entries.isEmpty { StudyPlant() }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .frame(height: 230, alignment: .bottom)
            }
            .background(alignment: .bottom) { plank }
        }
    }

    private func tap(_ entry: BookEntry, proxy: ScrollViewProxy) {
        guard entry.id != selected?.id else { onOpen(entry); return }
        withAnimation(Self.flip) { selectedId = entry.id }
        // 转正后变宽可能被挤出屏幕：翻到一半再轻轻滚进来（anchor nil = 最少滚动，不强制居中）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(entry.id) }
        }
    }

    private var plank: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .offset(y: 16)
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(hex: 0xE8D8BE), Color(hex: 0xD9C3A0), Color(hex: 0xC8AE87)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 16)
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.5)).frame(height: 1) }
                .shadow(color: Color(hex: 0x50371A, alpha: 0.35), radius: 6, y: 5)
        }
        .frame(height: 40, alignment: .top)
        .padding(.horizontal, 6)
    }

    // MARK: - 下半

    private func info(_ entry: BookEntry) -> some View {
        let progress = StudyBook.progress(entry)
        return VStack(spacing: 4) {
            Text(entry.id == recent?.id ? "继续读" : "书架上")
                .font(.system(size: 11))
                .tracking(1)
                .foregroundStyle(Theme.textMuted)
            Text(entry.name)
                .font(.custom("Songti SC", size: 20).bold())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(detail(entry, progress: progress))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if let summary = marks[entry.id]?.summary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.08))
                    Capsule().fill(Theme.branchIndicator).frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
            Button { onOpen(entry) } label: {
                Text(progress > 0 ? "继续" : "开始读")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.mainBg)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .background(Theme.textPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
    }

    private func detail(_ entry: BookEntry, progress: Double) -> String {
        var parts: [String] = []
        if !entry.author.isEmpty { parts.append(entry.author) }
        if entry.format == "pdf" { parts.append("PDF") }
        if progress > 0 {
            parts.append(entry.totalChapters > 1 ? "第 \(entry.currentChapter) 章 · \(Int((progress * 100).rounded()))%"
                                                  : "\(Int((progress * 100).rounded()))%")
        } else {
            parts.append("还没开始")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 书格 / 书单（不拟物）

    private var gridLayout: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 20) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        StudyFlatCover(entry: entry)
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        Text(entry.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(plainMeta(entry))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(entry) }
                    .contextMenu { bookMenu(entry) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private var listLayout: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    let progress = StudyBook.progress(entry)
                    HStack(spacing: 14) {
                        StudyFlatCover(entry: entry, compact: true)
                            .frame(width: 44, height: 66)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name)
                                .font(.custom("Songti SC", size: 16).bold())
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(detail(entry, progress: progress))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                            if let summary = marks[entry.id]?.summary {
                                Text(summary)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            if progress > 0 {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.black.opacity(0.07))
                                        Capsule().fill(Theme.branchIndicator).frame(width: geo.size.width * progress)
                                    }
                                }
                                .frame(height: 2)
                                .padding(.top, 3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(entry) }
                    .contextMenu { bookMenu(entry) }
                    Divider().padding(.leading, 80)
                }
            }
            .padding(.top, 10)
        }
    }

    private func plainMeta(_ entry: BookEntry) -> String {
        let p = StudyBook.progress(entry)
        var parts = [p > 0 ? "\(Int((p * 100).rounded()))%" : "未读"]
        if let summary = marks[entry.id]?.summary { parts.append(summary) }
        return parts.joined(separator: " · ")
    }

    private var plainEmpty: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("书房还空着").font(.custom("Songti SC", size: 20).bold()).foregroundStyle(Theme.textPrimary)
            Text("点右上 ＋ 导入一本，txt 和 PDF 都行").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyInfo: some View {
        VStack(spacing: 10) {
            Text("书架还空着")
                .font(.custom("Songti SC", size: 20).bold())
                .foregroundStyle(Theme.textPrimary)
            Text("把第一本书放上来吧，txt 和 PDF 都行")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Button(action: onImport) {
                Text("导入书")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.mainBg)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .background(Theme.textPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.top, 26)
    }

    private func reloadMarks() async {
        let books = entries.map { (id: $0.id, name: $0.name, author: $0.author, total: max(1, $0.totalChapters)) }
        let pid = profileId
        let (loaded, allQuotes) = await Task.detached(priority: .utility) {
            let m = Dictionary(uniqueKeysWithValues: books.map { b in
                (b.id, StudyMarks.load(safeName: b.id, profileId: pid, totalChapters: b.total))
            })
            let q = books.flatMap { StudyQuote.load(bookId: $0.id, bookName: $0.name, author: $0.author, profileId: pid) }
                .sorted { $0.createdAt > $1.createdAt }
            return (m, q)
        }.value
        marks = loaded
        quotes = allQuotes
    }

    /// 最近 7 天（含今天）的阅读秒数，来自阅读器 60s 打点（ReadingSignals）
    private static func weekSeconds(profileId: String) -> Int {
        let days = ReadingSignals.loadLog(profileId: profileId).days
        return (0..<7).reduce(0) { sum, i in
            sum + (days[ReadingSignals.dayKey(Date().addingTimeInterval(-86_400 * Double(i)))]?.totalSeconds ?? 0)
        }
    }
}

// MARK: - 纸色

/// 书脊 / 封面底色、字色；墙色是固定的一种。按书名稳定挑——String.hashValue 每次启动都变，自己算。
struct StudyPaper {
    let cover: Color
    let ink: Color

    static let wall = Color(hex: 0xF4EFE6)
    private static let all: [StudyPaper] = [
        .init(cover: Color(hex: 0xE9DCC4), ink: Color(hex: 0x5B4A37)),
        .init(cover: Color(hex: 0xC9DCD1), ink: Color(hex: 0x2F4C42)),
        .init(cover: Color(hex: 0xEAD3D0), ink: Color(hex: 0x6A4545)),
        .init(cover: Color(hex: 0x2F3B36), ink: Color(hex: 0xE9E4D8)),
        .init(cover: Color(hex: 0xD6DAE3), ink: Color(hex: 0x3F4658)),
        .init(cover: Color(hex: 0xF0E6CF), ink: Color(hex: 0x6B5A3A)),
    ]

    static func stableHash(_ s: String) -> Int {
        s.unicodeScalars.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1.value) } & .max
    }

    static func `for`(_ name: String) -> StudyPaper { all[stableHash(name) % all.count] }
}

// MARK: - 布局 / 便签样式

enum StudyLayout: String, CaseIterable {
    case study, grid, list
    var title: String {
        switch self {
        case .study: "书房"
        case .grid: "书格"
        case .list: "书单"
        }
    }
}

enum StudyNoteStyle: String, CaseIterable {
    case clip, tag
    var title: String {
        switch self {
        case .clip: "回形针卡片"
        case .tag: "麻绳吊牌"
        }
    }
}

/// 书格 / 书单用的平面封面：有封面图用图，没有就纸色 + 宋体书名（不拟物）
private struct StudyFlatCover: View {
    let entry: BookEntry
    var compact = false

    var body: some View {
        let paper = StudyPaper.for(entry.name)
        ZStack(alignment: .topLeading) {
            if let data = entry.coverData, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                paper.cover
                Text(entry.name)
                    .font(.custom("Songti SC", size: compact ? 8 : 13).bold())
                    .foregroundStyle(paper.ink)
                    .lineLimit(compact ? 3 : 4)
                    .padding(compact ? 5 : 10)
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2,
                                          bottomTrailingRadius: 5, topTrailingRadius: 5, style: .continuous))
        .shadow(color: Color(hex: 0x3C3228, alpha: 0.12), radius: 5, y: 3)
    }
}

// MARK: - 书签 / 划线

/// 一本书上的标记：有没有书签、划线在全书的位置和颜色（⧫ 粟粟 09-25：只在书转正后才看得到）
struct StudyMarks: Sendable {
    struct Tab: Sendable {
        let position: Double      // 0 = 第一章开头，1 = 最后一章
        let colorHex: UInt
    }
    var bookmarkCount = 0
    var highlightCount = 0
    var tabs: [Tab] = []

    var summary: String? {
        var parts: [String] = []
        if bookmarkCount > 0 { parts.append("\(bookmarkCount) 个书签") }
        if highlightCount > 0 { parts.append("\(highlightCount) 处划线") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 颜色跟阅读器里的划线一致：每道笔画自己的颜色（老数据自己薄荷、AI 玫瑰）
    static func load(safeName: String, profileId: String, totalChapters: Int) -> StudyMarks {
        var m = StudyMarks()
        m.bookmarkCount = BookStore.loadBookmarks(safeName: safeName, profileId: profileId).count
        let notes = BookStore.loadNotes(safeName: safeName, profileId: profileId)
            .filter { $0.replyTo == nil && $0.kind != "aiBubble" }
        m.highlightCount = notes.count
        let raw = notes.map { note -> Tab in
            // 笔画自己的颜色；老数据按作者（和正文一致，不再把「写了笔记」单独画成杏色）
            let hex = HighlightPalette.hexValue(note.strokeColorHex) ?? 0x8EBD9F
            return Tab(position: min(1, max(0, Double(note.chapter - 1) / Double(max(1, totalChapters)))), colorHex: hex)
        }.sorted { $0.position < $1.position }
        // 挨得太近的合成一张，最多 6 张
        var merged: [Tab] = []
        for tab in raw where merged.last.map({ tab.position - $0.position >= 0.08 }) ?? true {
            merged.append(tab)
        }
        if merged.count > 6 {
            let step = Double(merged.count - 1) / 5
            merged = (0..<6).map { merged[Int((Double($0) * step).rounded())] }
        }
        m.tabs = merged
        return m
    }
}

// MARK: - 3D 书

struct StudyBook: View {
    let entry: BookEntry
    let selected: Bool
    var marks: StudyMarks? = nil

    static let coverWidth: CGFloat = 118

    static func progress(_ entry: BookEntry) -> Double {
        guard entry.totalChapters > 0 else { return 0 }
        return min(1, max(0, (Double(entry.currentChapter - 1) + entry.scrollRatio) / Double(entry.totalChapters)))
    }

    var body: some View {
        let paper = StudyPaper.for(entry.name)
        let hash = StudyPaper.stableHash(entry.name)
        // 书脊宽随书的长短（章节数），高度在 150–190 之间按书名错落
        let depth = min(34, max(14, 14 + CGFloat(entry.totalChapters) * 0.17))
        let height = 150 + CGFloat(hash % 41)
        StudyBookFlip(theta: selected ? 0 : 90, width: Self.coverWidth, depth: depth, height: height,
                      paper: paper, title: entry.name, author: entry.author, cover: entry.coverData,
                      marks: marks)
            .animation(BookStudyContent.flip, value: selected)
            .accessibilityElement()
            .accessibilityLabel(entry.name)
            .accessibilityHint(selected ? "再点一下打开" : "点一下拿出来看")
    }
}

/// 一本书 = 书脊（宽 depth）+ 封面（宽 width）两个面，绕竖轴一起转。
/// theta：90° = 书脊朝外，0° = 封面朝外。SwiftUI 没有 preserve-3d，所以两个面各自按 theta 摆：
/// 书脊绕右边沿转、封面绕左边沿转，两条边始终贴在同一根「书脊折线」上；
/// 投影宽度 = depth·sinθ + width·cosθ，直接当布局宽度，所以旁边的书跟着让位、不会被压。
private struct StudyBookFlip: View, Animatable {
    var theta: Double
    let width: CGFloat
    let depth: CGFloat
    let height: CGFloat
    let paper: StudyPaper
    let title: String
    let author: String
    let cover: Data?
    let marks: StudyMarks?

    /// 索引贴从书口探出的长度：书位宽度要多留这么多，别压到下一本
    private static let tabReach: CGFloat = 12

    var animatableData: Double {
        get { theta }
        set { theta = newValue }
    }

    var body: some View {
        let r = theta * .pi / 180
        let spineW = depth * sin(r)
        let frontW = width * cos(r)
        let facing = 1 - theta / 90          // 0 书脊 → 1 封面
        ZStack(alignment: .bottomLeading) {
            // 落在木板上的影子：朝外时更宽更实
            Ellipse()
                .fill(Color(hex: 0x462D14, alpha: 0.22 + 0.12 * facing))
                .frame(width: spineW + frontW + 8 * facing, height: 6)
                .blur(radius: 3 + 2 * facing)
                .offset(x: -4 * facing, y: 3)
            spineFace
                .frame(width: depth, height: height)
                .overlay(Color.black.opacity(0.28 * (1 - sin(r))))
                .rotation3DEffect(.degrees(theta - 90), axis: (0, 1, 0), anchor: .trailing, perspective: 0.35)
                .offset(x: spineW - depth)
                .opacity(theta > 0.5 ? 1 : 0)
            frontFace
                .frame(width: width, height: height)
                .overlay(Color.black.opacity(0.22 * sin(r)))
                .background(alignment: .topLeading) { markings }
                .rotation3DEffect(.degrees(theta), axis: (0, 1, 0), anchor: .leading, perspective: 0.35)
                .offset(x: spineW)
                .opacity(theta < 89.5 ? 1 : 0)
        }
        .frame(width: max(spineW + frontW + (marks?.tabs.isEmpty == false ? Self.tabReach * facing : 0), 1),
               height: height, alignment: .bottomLeading)
        // 朝外那本微微往前凸
        .scaleEffect(1 + 0.03 * facing, anchor: .bottom)
    }

    /// 书口（封面右侧露出的书页）+ 半透明索引贴 + 皮质书签。画在封面这一面的背后，跟着它转：
    /// 书脊朝外时整面侧着，自然看不见。
    @ViewBuilder
    private var markings: some View {
        ZStack(alignment: .topLeading) {
            // 书口
            LinearGradient(colors: [Color(hex: 0xFBF7EE), Color(hex: 0xE6DCCA)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 4, height: height - 6)
                .offset(x: width - 1, y: 3)
            if let marks {
                ForEach(Array(marks.tabs.enumerated()), id: \.offset) { i, tab in
                    StudyIndexTab(color: Color(hex: tab.colorHex))
                        .rotationEffect(.degrees([-2, 1.5, -1, 2, 0, -1.5][i % 6]))
                        .offset(x: width - 1, y: 14 + tab.position * (height - 40))
                }
                if marks.bookmarkCount > 0 {
                    StudyLeatherBookmark()
                        .offset(x: width - 34, y: -26)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private var spineFace: some View {
        ZStack {
            paper.cover
            VStack {
                Rectangle().fill(paper.ink.opacity(0.35)).frame(height: 1).padding(.top, 14)
                Spacer()
                Rectangle().fill(paper.ink.opacity(0.35)).frame(height: 1).padding(.bottom, 14)
            }
            StudySpineTitle(title: title, ink: paper.ink, maxHeight: height - 44)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 4)
        }
    }

    @ViewBuilder
    private var frontFace: some View {
        ZStack(alignment: .leading) {
            if let cover, let img = UIImage(data: cover) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                paper.cover
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(paper.ink.opacity(0.35)).frame(height: 1)
                    Text(title)
                        .font(.custom("Songti SC", size: 17).bold())
                        .foregroundStyle(paper.ink)
                        .lineLimit(4)
                        .padding(.top, 10)
                    Spacer(minLength: 4)
                    if !author.isEmpty {
                        Text(author)
                            .font(.system(size: 10))
                            .tracking(0.6)
                            .foregroundStyle(paper.ink.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            // 装订那一侧的压痕
            LinearGradient(colors: [.black.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 7)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 1,
                                          bottomTrailingRadius: 4, topTrailingRadius: 4, style: .continuous))
    }
}

/// 半透明索引贴：贴在书页上的那截半透明，探出书口的那截实色，上面一道高光
private struct StudyIndexTab: View {
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            color.opacity(0.4).frame(width: 6)
            color.frame(width: 8)
        }
        .frame(height: 12)
        .overlay(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 2, topTrailingRadius: 2))
        .shadow(color: .black.opacity(0.14), radius: 0.8, x: 1, y: 1)
    }
}

/// 皮质书签：焦糖色皮条从书顶探出一截，压线 + 底部小孔
private struct StudyLeatherBookmark: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 6,
                                   bottomTrailingRadius: 6, topTrailingRadius: 2)
                .fill(LinearGradient(colors: [Color(hex: 0x7A4A34), Color(hex: 0x9A6246), Color(hex: 0x7A4A34)],
                                     startPoint: .leading, endPoint: .trailing))
            RoundedRectangle(cornerRadius: 1)
                .strokeBorder(Color(hex: 0xFFE6C8, alpha: 0.35), style: StrokeStyle(lineWidth: 0.8, dash: [2, 1.5]))
                .padding(EdgeInsets(top: 3, leading: 2, bottom: 10, trailing: 2))
            Circle().fill(Color(hex: 0x4A2C1E)).frame(width: 4, height: 4).padding(.bottom, 4)
        }
        .frame(width: 12, height: 40)
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 2)
    }
}

/// 书脊上的竖排书名：中日文一字一行往下排；纯西文转 90°。
private struct StudySpineTitle: View {
    let title: String
    let ink: Color
    let maxHeight: CGFloat

    private var isLatin: Bool { title.unicodeScalars.allSatisfy { $0.isASCII } }

    var body: some View {
        if isLatin {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .serif))
                .foregroundStyle(ink)
                .lineLimit(1)
                .frame(width: maxHeight)
                .rotationEffect(.degrees(90))
                .frame(width: 14, height: maxHeight)
        } else {
            let fit = max(1, Int(maxHeight / 15))
            let chars = Array(title.filter { !$0.isWhitespace })
            let shown = chars.count > fit ? Array(chars.prefix(fit - 1)) + ["…"] : chars
            VStack(spacing: 1) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, c in
                    Text(String(c))
                        .font(.custom("Songti SC", size: 12).bold())
                        .foregroundStyle(ink)
                }
            }
            .frame(maxHeight: maxHeight)
        }
    }
}

// MARK: - 绿植

private struct StudyPlant: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 58
            func leaf(_ pts: [(CGFloat, CGFloat)], _ color: Color) {
                var p = Path()
                p.move(to: CGPoint(x: pts[0].0 * s, y: pts[0].1 * s))
                // 起点 + 每三个点一段三次贝塞尔（控制点 1、控制点 2、终点）
                var i = 1
                while i + 2 < pts.count {
                    p.addCurve(to: CGPoint(x: pts[i + 2].0 * s, y: pts[i + 2].1 * s),
                               control1: CGPoint(x: pts[i].0 * s, y: pts[i].1 * s),
                               control2: CGPoint(x: pts[i + 1].0 * s, y: pts[i + 1].1 * s))
                    i += 3
                }
                p.closeSubpath()
                ctx.fill(p, with: .color(color))
            }
            leaf([(29, 72), (20, 50), (8, 44), (4, 30), (16, 30), (26, 44), (29, 60)], Color(hex: 0x8EBD9F))
            leaf([(29, 70), (34, 44), (48, 34), (54, 22), (42, 22), (32, 38), (30, 56)], Color(hex: 0x7BAA8C))
            leaf([(29, 74), (26, 56), (30, 36), (26, 18), (36, 30), (34, 52), (31, 70)], Color(hex: 0xA5CDB2))
            var pot = Path()
            pot.move(to: CGPoint(x: 12 * s, y: 76 * s))
            pot.addLine(to: CGPoint(x: 46 * s, y: 76 * s))
            pot.addLine(to: CGPoint(x: 41 * s, y: 116 * s))
            pot.addLine(to: CGPoint(x: 17 * s, y: 116 * s))
            pot.closeSubpath()
            ctx.fill(pot, with: .color(Color(hex: 0xD9B8A0)))
            ctx.fill(Path(roundedRect: CGRect(x: 10 * s, y: 72 * s, width: 38 * s, height: 8 * s), cornerRadius: 2 * s),
                     with: .color(Color(hex: 0xE6C9B3)))
        }
        .frame(width: 58, height: 120)
        .accessibilityHidden(true)
    }
}

// MARK: - 叶影 + 陀螺仪

/// 墙上的花园影子：预栅格化的一张图（模糊已烘进图里，运行时不做 blur），
/// 按陀螺仪反向平移 ≤16pt + 轻转；没动时极慢地像被风吹。
/// 只有这一层读 tilt，书架不跟着每帧重算。
private struct StudyLeafShadow: View {
    let tilt: StudyTilt
    let swaying: Bool

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !swaying)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let x = tilt.x + (swaying ? sin(t * 0.72) * 0.25 : 0)
                let y = tilt.y + (swaying ? cos(t * 0.5) * 0.15 : 0)
                Image("StudyLeafShadow")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width + 120, height: geo.size.height + 120)
                    .rotationEffect(.degrees(x * 1.2))
                    .offset(x: -60 - x * 16, y: -60 - y * 16)
            }
        }
        .blendMode(.multiply)
        .opacity(0.34)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// CoreMotion 包一层：进书房开、离开 / 开书 / 退后台关。以开始那一刻的姿态为零点，输出做过低通。
@MainActor
@Observable
final class StudyTilt {
    var x = 0.0
    var y = 0.0
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var reference: CMAttitude?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        reference = nil
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.reference == nil { self.reference = motion.attitude.copy() as? CMAttitude }
                let attitude = motion.attitude
                if let reference = self.reference { attitude.multiply(byInverseOf: reference) }
                // 低通：每次只追目标的 8%（60Hz ≈ 0.3s 惯性），影子像挂着在晃，不贴着手机抖（⧫ 09-25 嫌生硬）
                let tx = max(-1, min(1, attitude.roll / 0.5))
                let ty = max(-1, min(1, attitude.pitch / 0.5))
                self.x += (tx - self.x) * 0.08
                self.y += (ty - self.y) * 0.08
            }
        }
        KBProbe.log("[STUDY] 陀螺仪开")
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        x = 0
        y = 0
        KBProbe.log("[STUDY] 陀螺仪关")
    }
}
#endif
