#if PERSONAL_APPS
#if DEBUG
import SwiftUI
import SwiftData

/// 有声书播放态。承接 AudiobookListView 选中的 bookId。
struct AudiobookPlayerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [AudiobookItem]

    private let player = AudiobookPlayer.shared
    let bookId: UUID
    let onBackRaw: () -> Void

    /// 用户按返回时调用：先 teardown player 再让外层切回列表
    private func onBack() {
        player.teardown()
        onBackRaw()
    }

    @State private var sliderValue: Double = 0
    @State private var isDragging: Bool = false
    @State private var renameDraft: String = ""
    @State private var showRename: Bool = false
    @State private var editingBookmark: AudiobookBookmark?
    @State private var loadError: String?

    init(bookId: UUID, onBack: @escaping () -> Void) {
        self.bookId = bookId
        self.onBackRaw = onBack
        let id = bookId
        let predicate = #Predicate<AudiobookItem> { $0.id == id }
        _books = Query(filter: predicate)
    }

    private var book: AudiobookItem? { books.first }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            Divider()
            if let book = book {
                ScrollView {
                    VStack(spacing: 18) {
                        playerObject(book: book)
                        bookmarksBlock(book: book)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .background(Theme.mainBg)
            } else {
                Text("找不到这本书")
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.mainBg)
            }
        }
        .background(Theme.mainBg)
        .onAppear {
            loadBookIfNeeded()
        }
        .onDisappear {
            // ⚠️ 不要在这里 teardown！iOS 后台/锁屏可能触发 onDisappear，会把正在后台播放的 player 杀掉。
            // teardown 只在 onBack（返回列表）/ profileWillSwitch / 删书 时显式触发。
        }
        .onChange(of: player.currentTime) { _, new in
            if !isDragging { sliderValue = new }
        }
        .alert("无法加载音频", isPresented: .constant(loadError != nil)) {
            Button("好") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .sheet(isPresented: $showRename) {
            renameSheet
        }
        .sheet(item: $editingBookmark) { bm in
            AudiobookBookmarkEditor(bookmark: bm) {
                try? modelContext.save()
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var chrome: some View {
        HStack(spacing: 12) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.accent.opacity(0.78)))
                    .overlay(Circle().stroke(Theme.textMuted.opacity(0.14), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(book?.title ?? "—")
                    .font(.system(size: Theme.F.label, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if let book = book {
                    Text(formatTime(book.totalDuration) + " 总时长")
                        .font(.system(size: Theme.F.caption, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer()
            Button {
                renameDraft = book?.title ?? ""
                showRename = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.sidebarBg.opacity(0.72)))
                    .overlay(Circle().stroke(Theme.textMuted.opacity(0.12), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.mainBg)
    }

    // MARK: - Player Object

    @ViewBuilder
    private func playerObject(book: AudiobookItem) -> some View {
        VStack(spacing: 18) {
            screenBlock(book: book)
            controlsBlock
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.sidebarBg.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.textMuted.opacity(0.12), lineWidth: 0.6)
        )
        .shadow(color: Theme.cardShadow, radius: 14, x: 0, y: 8)
        .shadow(color: Theme.mainBg.opacity(0.7), radius: 1, x: 0, y: -1)
    }

    @ViewBuilder
    private func screenBlock(book: AudiobookItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Now Playing")
                    .font(.system(size: Theme.F.badge, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .textCase(.uppercase)
                Spacer()
                Text(formatTime(book.totalDuration))
                    .font(.system(size: Theme.F.caption, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }

            Text(book.title)
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .lastTextBaseline) {
                    Text(formatTime(displayTime))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text(remainingText(for: book))
                        .font(.system(size: Theme.F.caption, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                sliderBlock(book: book)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.accent.opacity(0.54))
                .shadow(color: Theme.textPrimary.opacity(0.16), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.mainBg.opacity(0.85), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.textMuted.opacity(0.16), lineWidth: 0.7)
                .padding(1)
        )
    }

    @ViewBuilder
    private func sliderBlock(book: AudiobookItem) -> some View {
        Slider(
            value: $sliderValue,
            in: 0...max(1, player.duration > 0 ? player.duration : book.totalDuration),
            onEditingChanged: { editing in
                if editing {
                    isDragging = true
                } else {
                    isDragging = false
                    player.seek(to: sliderValue)
                }
            }
        )
        .tint(Theme.branchIndicator)
        .frame(height: 18)
    }

    @ViewBuilder
    private var controlsBlock: some View {
        HStack(spacing: 11) {
            wheelButton(icon: "gobackward.30", size: 44, iconSize: 19) { player.skip(by: -30) }
            wheelButton(icon: "gobackward.15", size: 48, iconSize: 20) { player.skip(by: -15) }
            Button {
                togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(Theme.mainBg)
                    .frame(width: 74, height: 74)
                    .background(Circle().fill(Theme.branchIndicator))
                    .overlay(Circle().stroke(Theme.mainBg.opacity(0.74), lineWidth: 1))
                    .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 5)
            }
            .buttonStyle(.plain)
            wheelButton(icon: "goforward.15", size: 48, iconSize: 20) { player.skip(by: 15) }
            wheelButton(icon: "goforward.30", size: 44, iconSize: 19) { player.skip(by: 30) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func wheelButton(icon: String, size: CGFloat, iconSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.mainBg.opacity(0.94)))
                .overlay(Circle().stroke(Theme.textMuted.opacity(0.14), lineWidth: 0.6))
                .shadow(color: Theme.cardShadow, radius: 5, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bookmarks

    @ViewBuilder
    private func bookmarksBlock(book: AudiobookItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("书签")
                    .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    addBookmark(book: book)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bookmark.fill")
                        Text("在此处加书签")
                    }
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.accent.opacity(0.84)))
                    .overlay(Capsule().stroke(Theme.textMuted.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            let sortedBookmarks = book.bookmarks.sorted { $0.timestamp < $1.timestamp }

            if sortedBookmarks.isEmpty {
                Text("还没有书签")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.sidebarBg.opacity(0.54))
                    )
            } else {
                ForEach(sortedBookmarks) { bm in
                    bookmarkRow(bm)
                }
            }
        }
    }

    @ViewBuilder
    private func bookmarkRow(_ bm: AudiobookBookmark) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.mainBg.opacity(0.9)))
            VStack(alignment: .leading, spacing: 4) {
                Text(formatTime(bm.timestamp))
                    .font(.system(size: Theme.F.secondary, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                if !bm.note.isEmpty {
                    Text(bm.note)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.accent.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.textMuted.opacity(0.10), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            player.seek(to: bm.timestamp)
            sliderValue = bm.timestamp
        }
        .contextMenu {
            Button("编辑笔记") { editingBookmark = bm }
            Button("删除", role: .destructive) {
                modelContext.delete(bm)
                try? modelContext.save()
            }
        }
    }

    // MARK: - Rename sheet

    @ViewBuilder
    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("重命名")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            TextField("书名", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
            HStack {
                Button("取消") { showRename = false }
                Spacer()
                Button("保存") {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let book = book {
                        book.title = trimmed
                        for bm in book.bookmarks {
                            bm.bookTitleSnapshot = trimmed
                        }
                        try? modelContext.save()
                    }
                    showRename = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 20)
        .background(Theme.mainBg)
        .frame(minWidth: 320)
    }

    // MARK: - Actions

    private func loadBookIfNeeded() {
        guard let book = book else { return }
        let identity = PlaybackIdentity(
            profileId: book.profileId,
            bookId: book.id,
            fileName: book.fileName,
            totalDuration: book.totalDuration
        )
        if player.identity == identity { return }
        do {
            try player.load(identity: identity, context: modelContext)
            sliderValue = player.currentTime
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func togglePlay() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private func addBookmark(book: AudiobookItem) {
        let t = floor(player.currentTime)
        let bm = AudiobookBookmark(
            profileId: book.profileId,
            bookId: book.id,
            timestamp: t,
            note: "",
            bookTitleSnapshot: book.title
        )
        bm.book = book
        modelContext.insert(bm)
        try? modelContext.save()
        editingBookmark = bm
    }

    // MARK: - Utils

    private var displayTime: Double {
        isDragging ? sliderValue : player.currentTime
    }

    private func remainingText(for book: AudiobookItem) -> String {
        let total = player.duration > 0 ? player.duration : book.totalDuration
        let remaining = max(0, total - displayTime)
        return "剩 " + formatTime(remaining)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}
#endif
#endif
