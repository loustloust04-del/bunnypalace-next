import SwiftUI

// MARK: - C 档案 wiki 给人看 / 改（plan-memory-c3-catalog todo 11 / 11b）
// 文件库和记忆 app「记忆」格共用：页编辑器（保存走 WikiStore.saveRaw 存历史 → 重建索引 → memoryDidChange）、历史（翻看 / 恢复）、一层层推入的分组页。

/// 要打开的一页（后台读好再弹）
struct WikiPageTarget: Identifiable, Sendable {
    let store: WikiStore
    let path: String
    let text: String
    let title: String
    let modifiedAt: Date?
    var id: String { path }

    var virtualPath: String { FileLibraryMemoryFolder.wikiFolder + "/" + path + ".md" }

    static func load(profileId: String, path: String) async -> WikiPageTarget? {
        await Task.detached(priority: .userInitiated) {
            WikiPageTarget.load(store: WikiStore(profileId: profileId), path: path)
        }.value
    }

    /// 同步，调用方放后台
    static func load(store: WikiStore, path: String) -> WikiPageTarget? {
        guard let text = store.readRaw(path) else { return nil }
        return WikiPageTarget(store: store, path: path, text: text, title: WikiPage.parse(text, path: path).title,
                              modifiedAt: store.modifiedAt(path))
    }
}

enum WikiEditing {
    private static let queue = DispatchQueue(label: "wiki.editor.save", qos: .userInitiated)

    /// 编辑器保存：冲突检查（盘上的不是打开时那版就不存）、历史快照、写入，在后台串行一起做
    static func save(_ text: String, baseline: String, store: WikiStore, path: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                cont.resume(with: Result {
                    if let disk = store.readRaw(path), disk != baseline {
                        throw NSError(domain: "Wiki", code: -9, userInfo: [NSLocalizedDescriptionKey: "这页已在别处改过，请关闭重开后再保存。"])
                    }
                    try store.saveRaw(text, path: path)
                })
            }
        }
    }

    /// 写完一页（保存 / 恢复）：后台重建索引，回主线程发 memoryDidChange
    static func didWrite(_ store: WikiStore, path: String) {
        Task.detached(priority: .utility) {
            try? store.rebuildIndexes(affecting: [path])
            await MainActor.run { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
        }
    }
}

/// 编辑器里「历史」要的东西
struct WikiHistoryTarget {
    let store: WikiStore
    let path: String
    /// 恢复已落盘（新内容）：编辑器换成它之后调（重建索引、发通知）
    let onRestored: (String) -> Void
}

/// 一页 wiki 的编辑器：文件库同一个 FileEditorSheet；双链点了在这里换页（只认存在的 wiki 页，不在文件库里建文件）
struct WikiPageEditorSheet: View {
    let initial: WikiPageTarget
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var current: WikiPageTarget?

    var body: some View {
        let t = current ?? initial
        FileEditorSheet(
            path: t.virtualPath,
            initialContent: t.text,
            initialModifiedAt: t.modifiedAt,
            currentModifiedAt: { t.store.modifiedAt(t.path) },
            reloadExternalContent: {
                guard let text = t.store.readRaw(t.path) else { throw WikiStore.WikiError.notFound(t.path) }
                return ReloadedFileContent(content: text, modifiedAt: t.store.modifiedAt(t.path))
            },
            onSaveAsync: { newContent, baseline in
                try await WikiEditing.save(newContent, baseline: baseline, store: t.store, path: t.path)
                written(t)
            },
            onCancel: { dismiss() },
            onOpenWikiLink: { open($0, from: t) },
            title: t.title,
            wikiHistory: WikiHistoryTarget(store: t.store, path: t.path, onRestored: { _ in written(t) })
        )
        .id(t.path)
    }

    private func written(_ t: WikiPageTarget) {
        WikiEditing.didWrite(t.store, path: t.path)
        onChange()
    }

    private func open(_ link: String, from t: WikiPageTarget) {
        let path = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WikiStore.isValidPagePath(path), path != t.path else { return }
        let store = t.store
        Task {
            guard let next = await Task.detached(priority: .userInitiated, operation: { WikiPageTarget.load(store: store, path: path) }).value
            else { return }
            current = next
        }
    }
}

/// 一页的历史（新→旧）：点一版看全文，能恢复（恢复前当前版也存一版），恢复后重建索引
struct WikiHistoryView: View {
    let target: WikiHistoryTarget
    /// 编辑器里有没保存的修改：恢复会把它们换掉，确认里说一声
    let hasUnsavedEdits: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [WikiStore.HistoryEntry]?

    var body: some View {
        NavigationStack {
            Group {
                if let entries, !entries.isEmpty {
                    List(entries, id: \.name) { entry in
                        NavigationLink {
                            WikiHistoryVersionView(target: target, entry: entry, hasUnsavedEdits: hasUnsavedEdits) { text in
                                target.onRestored(text)
                                dismiss()
                            }
                        } label: {
                            Text(Self.timeText(entry))
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.vertical, 3)
                        }
                        .listRowBackground(Theme.mainBg)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                } else {
                    VStack {
                        if entries == nil {
                            ProgressView()
                        } else {
                            Text("还没有旧版本，改过一次以后才有")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.mainBg)
            .navigationTitle("历史")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.mainBg, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 600)
        #else
        .presentationBackground(Theme.mainBg)
        #endif
        .task {
            let t = target
            entries = await Task.detached(priority: .userInitiated) { t.store.history(t.path) }.value
        }
    }

    static func timeText(_ entry: WikiStore.HistoryEntry) -> String {
        entry.date.map { FileVersionHistory.timeText($0) } ?? entry.name
    }
}

private struct WikiHistoryVersionView: View {
    let target: WikiHistoryTarget
    let entry: WikiStore.HistoryEntry
    let hasUnsavedEdits: Bool
    let onRestored: (String) -> Void

    @State private var text: String?
    @State private var confirmRestore = false
    @State private var restoring = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            Text(text ?? "")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.mainBg)
        .navigationTitle(WikiHistoryView.timeText(entry))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("恢复这一版") { confirmRestore = true }
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(text == nil || restoring)
            }
        }
        .confirmationDialog("恢复这一版？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复") { restore() }
            Button("取消", role: .cancel) { }
        } message: {
            Text(hasUnsavedEdits ? "现在这版会先存进历史；编辑器里没保存的修改会丢掉。" : "现在这版会先存进历史，随时能再换回来。")
        }
        .alert("恢复失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .task {
            let t = target, name = entry.name
            text = await Task.detached(priority: .userInitiated) { t.store.historyText(t.path, entry: name) }.value
        }
    }

    private func restore() {
        let t = target, name = entry.name
        restoring = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    try t.store.restore(t.path, entry: name)
                    return .success(t.store.readRaw(t.path) ?? "")
                } catch {
                    return .failure(error)
                }
            }.value
            restoring = false
            switch result {
            case .success(let restored): onRestored(restored)
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
}

// MARK: - 记忆 app「记忆」格：一层一层往下推（11b）

/// 一层：分组行带 › 和页数，页行「标题 — 钩子」；点页弹编辑器。后台读，记忆有变就重读
struct WikiFolderPage: View {
    let folder: String

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var entries: [WikiBrowseEntry]?
    @State private var openPage: WikiPageTarget?

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        List {
            Section {
                if let entries, entries.isEmpty {
                    Text("这里还没有页")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                ForEach(entries ?? []) { entry in
                    switch entry.kind {
                    case .folder(let count):
                        NavigationLink {
                            WikiFolderPage(folder: entry.path)
                        } label: {
                            row(entry.title, entry.hook, trailing: "\(count) 页")
                        }
                    case .page:
                        Button { open(entry.path) } label: {
                            row(entry.title, entry.hook, trailing: nil)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(folder.replacingOccurrences(of: "/", with: " › "))
                    .textCase(nil)
            }
            .panelRowBackground()
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .memorySubpage(String(folder.split(separator: "/").last ?? ""))
        .task(id: profileId) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reload() } }
        .sheet(item: $openPage) { WikiPageEditorSheet(initial: $0) }
    }

    private func row(_ title: String, _ hook: String, trailing: String?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                if !hook.isEmpty {
                    Text(hook)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .contentShape(Rectangle())
    }

    private func reload() async {
        let pid = profileId, folder = folder
        guard !pid.isEmpty else { return }
        let list = await Task.detached(priority: .userInitiated) { WikiStore(profileId: pid).browse(folder) }.value
        guard pid == profileId else { return }
        entries = list
    }

    private func open(_ path: String) {
        let pid = profileId
        Task {
            guard let target = await WikiPageTarget.load(profileId: pid, path: path), pid == profileId else { return }
            openPage = target
        }
    }
}
