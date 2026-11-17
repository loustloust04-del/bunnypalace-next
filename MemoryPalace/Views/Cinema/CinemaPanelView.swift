#if os(iOS)
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// page2「影院」（docs/plan-cinema-app.md V1）：继续看 + 看过的；点一部全屏放，＋ 贴网址 / 选文件
struct CinemaPanelView: View {
    var viewModel: ConversationViewModel
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    @State private var log = WatchLog.shared
    @State private var playing: WatchLogEntry?
    @State private var choosingChat: WatchLogEntry?
    @State private var pasting = false
    @State private var pasteText = ""
    @State private var pickingFile = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Group {
                if log.entries.isEmpty {
                    ContentUnavailableView {
                        Label("还没看过视频", systemImage: "film")
                    } description: {
                        Text("在一起看小窗里看的会自动记到这里，也可以点右上角 ＋ 贴链接或选文件。")
                    }
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.mainBg)
            .navigationTitle("影院")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("贴网址", systemImage: "link") { pasteText = ""; pasting = true }
                        Button("从「文件」选", systemImage: "folder") { pickingFile = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .fullScreenCover(item: $playing) { entry in
            CinemaPlayerView(entry: entry) { latest in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    choosingChat = latest
                }
            }
        }
        .sheet(item: $choosingChat) { entry in
            CinemaChatPicker(profileId: profileId) { conversationId in
                choosingChat = nil
                watchTogether(entry, in: conversationId)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("贴网址", isPresented: $pasting) {
            TextField("B 站 / YouTube 链接，或 mp4 / m3u8 直链", text: $pasteText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("取消", role: .cancel) {}
            Button("放") { playPasted() }
        } message: {
            Text("记进片库并开始放")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") {}
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.movie, .video, .audiovisualContent]) { result in
            if case .success(let url) = result { importFile(url) }
        }
        .task {
            CinemaMeta.backfillOnce()
            await CinemaMeta.enrichMissing()
        }
    }

    private var list: some View {
        List {
            let continuing = log.continueWatching
            if !continuing.isEmpty {
                Section("继续看") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(continuing) { entry in
                                CinemaContinueCard(entry: entry)
                                    .contentShape(Rectangle())
                                    .onTapGesture { playing = entry }
                                    .contextMenu { menu(entry) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            Section("看过的") {
                ForEach(log.entries) { entry in
                    Button { playing = entry } label: { CinemaRow(entry: entry) }
                        .buttonStyle(.plain)
                        .contextMenu { menu(entry) }
                        .swipeActions { Button("删除", role: .destructive) { log.remove(entry.id) } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.mainBg)
    }

    @ViewBuilder
    private func menu(_ entry: WatchLogEntry) -> some View {
        if entry.source != .file {
            Button("一起看…", systemImage: "bubble.left.and.text.bubble.right") { choosingChat = entry }
            Button("复制链接", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.url }
        }
        Button("删除", systemImage: "trash", role: .destructive) { log.remove(entry.id) }
    }

    private func playPasted() {
        let text = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let item = WatchLog.item(for: url) else {
            notice = "认不出这个视频：支持 B 站 / YouTube 链接和 mp4 / mov / m3u8 直链"
            return
        }
        log.record(item, position: nil, duration: nil)
        playing = log.entry(item.key)
    }

    /// 拷进影院自己的目录（「文件」给的地址出了这次就不能再读）
    private func importFile(_ source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try? fm.createDirectory(at: log.filesDirectory, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var name = source.lastPathComponent
        var n = 2
        while fm.fileExists(atPath: log.filesDirectory.appendingPathComponent(name).path) {
            name = "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            n += 1
        }
        do {
            try fm.copyItem(at: source, to: log.filesDirectory.appendingPathComponent(name))
        } catch {
            notice = "没拷进来：\(error.localizedDescription)"
            return
        }
        let item = WatchLog.fileItem(name: name, title: base)
        log.record(item, position: nil, duration: nil)
        playing = log.entry(item.key)
    }

    /// 「一起看…」：在那个对话的一起看小窗里接着放
    private func watchTogether(_ entry: WatchLogEntry, in conversationId: String) {
        guard let url = URL(string: entry.url) else { return }
        let watch = ChatWatch.shared
        if watch.conversationId == conversationId {
            watch.play(url, from: entry.position)
        } else {
            let old = ChatWatchStore.load(conversationId)
            ChatWatchStore.save(ChatWatchState(open: true, url: url.absoluteString, height: old?.height ?? ChatWatchStore.defaultHeight,
                                               position: entry.position, updatedAt: Date()), for: conversationId)
        }
        if !MemoryConversationLink.open(conversationId, profileId: profileId, context: modelContext, viewModel: viewModel) {
            notice = "这个对话打不开了"
        }
    }
}

// MARK: - 片子的样子

private struct CinemaCover: View {
    let entry: WatchLogEntry

    var body: some View {
        // 先定 16:9 的框，图在框里居中裁（截下来的画面带黑边，不能让它把框撑开）
        Rectangle().fill(Theme.accent)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { image }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var image: some View {
        Group {
            if let cover = entry.cover {
                if cover.hasPrefix("http") {
                    AsyncImage(url: URL(string: cover)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { placeholder }
                } else if let image = UIImage(contentsOfFile: WatchLog.shared.coverDirectory.appendingPathComponent(cover).path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: entry.source == .file ? "doc.richtext" : "film").foregroundStyle(Theme.textMuted)
    }
}

private struct CinemaContinueCard: View {
    let entry: WatchLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CinemaCover(entry: entry)
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        Capsule().fill(Theme.branchIndicator)
                            .frame(width: geo.size.width * CinemaText.ratio(entry), height: 3)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 5)
                }
            Text(entry.title.isEmpty ? entry.url : entry.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Text(CinemaText.progress(entry))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
        }
        .frame(width: 180)
    }
}

private struct CinemaRow: View {
    let entry: WatchLogEntry

    var body: some View {
        HStack(spacing: 12) {
            CinemaCover(entry: entry).frame(width: 104)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title.isEmpty ? entry.url : entry.title)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text([entry.sourceLabel, CinemaText.day(entry.lastWatched), entry.inProgress ? CinemaText.progress(entry) : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 一起看…：选对话

private struct CinemaChatPicker: View {
    let profileId: String
    var onPick: (String) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [Conversation] = []

    var body: some View {
        NavigationStack {
            List(conversations, id: \.id) { conversation in
                Button { onPick(conversation.id) } label: {
                    HStack {
                        Text(conversation.title.isEmpty ? "新对话" : conversation.title)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if conversation.id == conversations.first?.id {
                            Text("最近").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
            .navigationTitle("在哪个对话里一起看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .task { load() }
    }

    private func load() {
        let pid = profileId
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == pid && $0.isTrashed == false },
            sortBy: [SortDescriptor(\.updateTime, order: .reverse)]
        )
        desc.fetchLimit = 40
        conversations = (try? modelContext.fetch(desc)) ?? []
    }
}
#endif
