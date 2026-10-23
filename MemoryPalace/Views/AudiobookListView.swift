#if PERSONAL_APPS
#if DEBUG
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 有声书列表态。当前楼层下的书按"最近播放 > 最近导入"排序。
struct AudiobookListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [AudiobookItem]

    let profileId: String
    let onSelect: (UUID) -> Void

    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var renamingBook: AudiobookItem?
    @State private var renameDraft: String = ""

    init(profileId: String, onSelect: @escaping (UUID) -> Void) {
        self.profileId = profileId
        self.onSelect = onSelect

        let pid = profileId
        let predicate = #Predicate<AudiobookItem> { $0.profileId == pid }
        _books = Query(
            filter: predicate,
            sort: [
                SortDescriptor(\.lastPlayedAt, order: .reverse),
                SortDescriptor(\.importedAt, order: .reverse)
            ]
        )
    }

    var body: some View {
        ZStack {
            if books.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
        // 先撑满再铺底：反过来底只包住空态那一小块（09-24 mac 实拍：一块小方卡、「…wav」被截）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.mainBg)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: allowedAudioTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("导入失败", isPresented: .constant(importError != nil)) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(item: $renamingBook) { book in
            renameSheet(for: book)
        }
    }

    // MARK: - States

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones")
                .font(.system(size: 56))
                .foregroundColor(Theme.textMuted)
            Text("还没导入有声书")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
            Text("支持 mp3 / m4a / m4b / wav")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
            importButton
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("有声书")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                importButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            List {
                ForEach(books) { book in
                    AudiobookRow(book: book)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(book.id) }
                        .contextMenu {
                            Button("改名") {
                                renameDraft = book.title
                                renamingBook = book
                            }
                            Button("删除", role: .destructive) {
                                deleteBook(book)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.mainBg)
        }
    }

    @ViewBuilder
    private var importButton: some View {
        Button {
            showFileImporter = true
        } label: {
            HStack(spacing: 6) {
                if isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                }
                Text(isImporting ? "导入中…" : "导入音频")
                    .font(.callout)
            }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.84))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.textMuted.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
    }

    // MARK: - Rename

    @ViewBuilder
    private func renameSheet(for book: AudiobookItem) -> some View {
        VStack(spacing: 16) {
            Text("重命名")
                .font(.headline)
            TextField("书名", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
            HStack {
                Button("取消") { renamingBook = nil }
                Spacer()
                Button("保存") {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        renameBook(book, to: trimmed)
                    }
                    renamingBook = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 20)
        .frame(minWidth: 320)
    }

    // MARK: - Actions

    private var allowedAudioTypes: [UTType] {
        var types: [UTType] = [.mp3, .mpeg4Audio, .wav]
        if let m4b = UTType(filenameExtension: "m4b") { types.append(m4b) }
        if let aac = UTType("public.aac-audio") { types.append(aac) }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            importError = err.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            Task {
                do {
                    let imported = try await AudiobookFileManager.importAudio(from: url, profileId: profileId)
                    await MainActor.run {
                        let book = AudiobookItem(
                            profileId: profileId,
                            title: imported.suggestedTitle,
                            fileName: imported.fileName,
                            fileSizeBytes: imported.fileSizeBytes,
                            totalDuration: imported.totalDuration
                        )
                        modelContext.insert(book)
                        try? modelContext.save()
                        isImporting = false
                    }
                } catch {
                    await MainActor.run {
                        importError = error.localizedDescription
                        isImporting = false
                    }
                }
            }
        }
    }

    private func deleteBook(_ book: AudiobookItem) {
        // 1. 文件
        AudiobookFileManager.deleteAudio(fileName: book.fileName, profileId: book.profileId)
        // 2. checkpoint
        PlaybackCheckpointStore.delete(profileId: book.profileId, bookId: book.id)
        // 3. SwiftData（cascade 删 bookmarks）
        modelContext.delete(book)
        try? modelContext.save()
    }

    private func renameBook(_ book: AudiobookItem, to newTitle: String) {
        book.title = newTitle
        // 同步所有 bookmark 的快照
        for bm in book.bookmarks {
            bm.bookTitleSnapshot = newTitle
        }
        try? modelContext.save()
    }
}

// MARK: - Row

private struct AudiobookRow: View {
    let book: AudiobookItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones.circle.fill")
                .font(.system(size: 34))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Theme.mainBg.opacity(0.92)))
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: Theme.F.label, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                ProgressView(value: progress)
                    .tint(Theme.branchIndicator)
                HStack(spacing: 4) {
                    Text(formatTime(book.currentTime))
                    Text("/")
                    Text(formatTime(book.totalDuration))
                    if book.currentTime > 0 {
                        Spacer()
                        Text("剩 \(formatTime(book.totalDuration - book.currentTime))")
                    }
                }
                .font(.system(size: Theme.F.caption, design: .monospaced))
                .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.sidebarBg.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.textMuted.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: Theme.cardShadow, radius: 4, x: 0, y: 2)
    }

    private var progress: Double {
        guard book.totalDuration > 0 else { return 0 }
        return min(1, max(0, book.currentTime / book.totalDuration))
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
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
