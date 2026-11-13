import MemoryCore
import SwiftUI

// MARK: - C 档案 wiki 给人看 / 改（plan-memory-c3-catalog todo 11 / 11b）
// 文件库和记忆 app「记忆」格共用：页编辑器（保存走 WikiStore.saveRaw 存历史 → 重建索引 → memoryDidChange）、历史（翻看 / 恢复）、一层层推入的分组页。

/// 要打开的一页（后台读好再弹）
struct WikiPageTarget: Identifiable, Sendable {
    let store: WikiStore
    let path: String
    let text: String
    let version: String
    let title: String
    let modifiedAt: Date?
    var id: String { store.root.path + "/" + path }

    var virtualPath: String { FileLibraryMemoryFolder.wikiFolder + "/" + path + ".md" }

    static func load(profileId: String, path: String) async -> WikiPageTarget? {
        await Task.detached(priority: .userInitiated) {
            WikiPageTarget.load(store: WikiStore(profileId: profileId), path: path)
        }.value
    }

    /// 同步，调用方放后台
    static func load(store: WikiStore, path: String) -> WikiPageTarget? {
        guard let page = store.readVersioned(path) else { return nil }
        return WikiPageTarget(store: store, path: path, text: page.text, version: page.version,
                              title: WikiPage.parse(page.text, path: path).title, modifiedAt: store.modifiedAt(path))
    }
}

enum WikiEditing {
    /// 编辑器这一页最近一次读到 / 写下的落盘原文（按页路径；没有 = 打开时那份）
    final class Baseline: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String: String] = [:]
        func text(_ path: String) -> String? { lock.withLock { texts[path] } }
        func set(_ path: String, _ text: String) { lock.withLock { texts[path] = text } }
    }

    /// 编辑器保存：冲突检查（盘上的不是打开时那版就不存）、历史快照、写入，在后台串行一起做
    /// 与审批共用楼层写锁；缺页拒绝重建。返回落盘版本，供后续历史恢复校验。
    @discardableResult
    static func save(_ text: String, baseline: String, store: WikiStore, path: String) async throws -> String {
        let version = try await WikiProposalReview.exclusive(wiki: store) {
            try await Task.detached(priority: .userInitiated) {
                guard let disk = store.readRaw(path) else {
                    throw NSError(domain: "Wiki", code: -9, userInfo: [NSLocalizedDescriptionKey: "这页已被删除，不能从旧窗口重建。"])
                }
                guard disk == baseline else {
                    throw NSError(domain: "Wiki", code: -9, userInfo: [NSLocalizedDescriptionKey: "这页已在别处改过，请关闭重开后再保存。"])
                }
                let version = try store.saveRaw(text, path: path)
                try? store.rebuildIndexes(affecting: [path])
                return version
            }.value
        }
        await didWrite()
        return version
    }

    /// 写完一页（保存 / 恢复）：索引已在锁内重建，回主线程发 memoryDidChange
    @MainActor
    static func didWrite() {
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
    }
}

/// 编辑器里「历史」要的东西
struct WikiHistoryTarget {
    let store: WikiStore
    let path: String
    let expectedVersion: String?
    /// 落盘原文 → 给人看的（本人那组显示成名字）；历史预览、恢复后换进编辑器的都过它
    var shown: (String) -> String = { $0 }
    /// 恢复已落盘（新内容，落盘原文）：更新编辑器和落盘基线，刷新文件库
    let onRestored: (String, String) -> Void
}

/// 一页 wiki 的编辑器：文件库同一个 FileEditorSheet；双链点了在这里换页（只认存在的 wiki 页，不在文件库里建文件）
struct WikiPageEditorSheet: View {
    let initial: WikiPageTarget
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var current: WikiPageTarget?
    /// 冲突检查的基线：落盘原文（编辑器里显示的是本人那组换成名字的）
    @State private var disk = WikiEditing.Baseline()
    @State private var versions: [String: String] = [:]
    @State private var openedProfileId: String?
    @State private var missingLink: String?
    @State private var canRestoreLink = false
    @State private var showDeleted = false

    private var user: String { profileManager?.currentProfile.userName ?? "" }

    var body: some View {
        let t = current ?? initial
        let user = user, disk = disk
        FileEditorSheet(
            path: t.virtualPath,
            initialContent: WikiStore.shown(t.text, user: user),
            initialModifiedAt: t.modifiedAt,
            currentModifiedAt: { t.store.modifiedAt(t.path) },
            reloadExternalContent: {
                guard let page = t.store.readVersioned(t.path) else { throw WikiStore.WikiError.notFound(t.path) }
                disk.set(t.path, page.text)
                versions[t.path] = page.version
                return ReloadedFileContent(content: WikiStore.shown(page.text, user: user), modifiedAt: t.store.modifiedAt(t.path))
            },
            onSaveAsync: { newContent, _ in
                // 没改的行照落盘原文，改过的行只还原双链 / 出处里的本人那组；基线用落盘原文
                let base = disk.text(t.path) ?? t.text
                let raw = WikiStore.storedEdit(newContent, original: base, user: user)
                let version: String
                do {
                    version = try await WikiEditing.save(raw, baseline: base, store: t.store, path: t.path)
                } catch {
                    guard isCurrent(t) else { return }
                    throw error
                }
                onChange()
                guard isCurrent(t) else { return }
                disk.set(t.path, raw)
                versions[t.path] = version
            },
            onCancel: { dismiss() },
            onOpenWikiLink: { open($0, from: t) },
            title: t.title,
            wikiHistory: WikiHistoryTarget(store: t.store, path: t.path, expectedVersion: versions[t.path] ?? t.version,
                                          shown: { WikiStore.shown($0, user: user) }, onRestored: { restored, version in
                onChange()
                guard isCurrent(t) else { return }
                disk.set(t.path, restored)
                versions[t.path] = version
            }),
            openedProfileId: openedProfileId ?? profileManager?.currentProfile.id
        )
        .id(t.id)
        .onAppear { if openedProfileId == nil { openedProfileId = profileManager?.currentProfile.id } }
        .alert("目标页已删除 / 不存在", isPresented: Binding(get: { missingLink != nil }, set: { if !$0 { missingLink = nil } })) {
            if canRestoreLink {
                Button("去已删除恢复") { showDeleted = true }
            }
            Button("好", role: .cancel) { missingLink = nil }
        } message: {
            Text(missingLink ?? "")
        }
        .sheet(isPresented: $showDeleted) {
            NavigationStack {
                WikiDeletedPage(profileId: openedProfileId ?? "", store: t.store)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showDeleted = false } } }
            }
            #if os(macOS)
            .frame(width: 640, height: 600)
            #endif
        }
    }

    private func isCurrent(_ t: WikiPageTarget) -> Bool {
        let target = current ?? initial
        return target.store.root == t.store.root && target.path == t.path
    }

    private func open(_ link: String, from t: WikiPageTarget) {
        let path = WikiStore.stored(link.trimmingCharacters(in: .whitespacesAndNewlines), user: user)
        guard WikiStore.isValidPagePath(path), path != t.path else { return }
        let store = t.store
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (WikiPageTarget?, Bool) in
                if let next = WikiPageTarget.load(store: store, path: path) { return (next, false) }
                return (nil, store.hasDeletionReceipt(for: path))
            }.value
            guard let next = result.0 else {
                guard isCurrent(t) else { return }
                missingLink = WikiStore.shown(path, user: user)
                canRestoreLink = result.1
                return
            }
            guard isCurrent(t) else { return }
            current = next
            disk.set(next.path, next.text)
            versions[next.path] = next.version
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
                            WikiHistoryVersionView(target: target, entry: entry, hasUnsavedEdits: hasUnsavedEdits) { text, version in
                                target.onRestored(text, version)
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
    let onRestored: (String, String) -> Void

    @State private var text: String?
    @State private var confirmRestore = false
    @State private var restoring = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            Text(target.shown(text ?? ""))
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
            do {
                let restored = try await WikiProposalReview.exclusive(wiki: t.store) {
                    try await Task.detached(priority: .userInitiated) {
                        try t.store.restore(t.path, entry: name, expectedVersion: t.expectedVersion)
                        guard let page = t.store.readVersioned(t.path) else { throw WikiStore.WikiError.notFound(t.path) }
                        try? t.store.rebuildIndexes(affecting: [t.path])
                        return page
                    }.value
                }
                WikiEditing.didWrite()
                restoring = false
                onRestored(restored.0, restored.1)
            } catch {
                restoring = false
                self.error = error.localizedDescription
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
    @State private var loadedStore: WikiStore?
    @State private var deleting: WikiDeletionTarget?

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    /// 本人那组落盘是 {{user}}，这里显示成名字
    private func shown(_ text: String) -> String { WikiStore.shown(text, user: profileManager?.currentProfile.userName ?? "") }

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
                            row(shown(entry.title), entry.hook, trailing: "\(count) 页")
                        }
                    case .page:
                        Button { open(entry.path) } label: {
                            row(entry.title, entry.hook, trailing: nil)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { deleteButton(entry) }
                        #if os(iOS)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteButton(entry) }
                        #endif
                    }
                }
            } header: {
                Text(shown(folder).replacingOccurrences(of: "/", with: " › "))
                    .textCase(nil)
            }
            .panelRowBackground()
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .memorySubpage(shown(String(folder.split(separator: "/").last ?? "")))
        .task(id: profileId) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reload() } }
        .sheet(item: $openPage) { WikiPageEditorSheet(initial: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            entries = nil
            loadedStore = nil
            deleting = nil
        }
        .modifier(WikiDeleteConfirmation(target: $deleting, hasUnsavedEdits: false) { _ in
            Task { await reload() }
        })
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
        let result = await Task.detached(priority: .userInitiated) {
            let store = WikiStore(profileId: pid)
            return (store.browse(folder), store)
        }.value
        guard pid == profileId else { return }
        entries = result.0
        loadedStore = result.1
    }

    private func deleteButton(_ entry: WikiBrowseEntry) -> some View {
        Button("删除页", role: .destructive) {
            guard let version = entry.version, let store = loadedStore else { return }
            deleting = WikiDeletionTarget(profileId: profileId, store: store,
                                          path: entry.path, title: entry.title, expectedVersion: version)
        }
    }

    private func open(_ path: String) {
        let pid = profileId
        Task {
            guard let target = await WikiPageTarget.load(profileId: pid, path: path), pid == profileId else { return }
            openPage = target
        }
    }
}

struct WikiDeletionTarget: Identifiable {
    let profileId: String
    let store: WikiStore
    let path: String
    let title: String
    let expectedVersion: String
    var id: String { store.root.path + "/" + path + "|" + expectedVersion }
}

@MainActor
enum WikiDeletionAction {
    enum Action: Sendable {
        case delete(path: String, version: String)
        case restore(id: String)
        case resume(id: String)
        case cancel(id: String)
    }

    static func perform(_ action: Action, store: WikiStore, profileId: String) async throws {
        let operation = await Task.detached(priority: .utility) {
            switch action {
            case .delete(let path, _): return "删页 \(path)"
            case .restore(let id): return "恢复已删页 \(store.deletion(id: id).path)"
            case .resume(let id): return "删页 \(store.deletion(id: id).path)"
            case .cancel(let id): return "丢弃删除收据 \(store.deletion(id: id).path)"
            }
        }.value
        var committed = false
        do {
            let warning = try await WikiProposalReview.exclusive(wiki: store) {
                try await Task.detached(priority: .userInitiated) { () -> String? in
                    switch action {
                    case .delete(let path, let version):
                        return try store.delete(path, expectedVersion: version, reason: "手动删除").warning
                    case .restore(let id):
                        try store.restoreDeleted(id: id)
                    case .resume(let id):
                        return try store.continueDeletion(id: id).warning
                    case .cancel(let id):
                        try store.cancelDeletion(id: id)
                    }
                    return nil
                }.value
            }
            committed = true
            try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: profileId)
            let note = warning.map { operation + " · " + $0 } ?? operation
            await Task.detached(priority: .utility) {
                MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: warning == nil, note: note, model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
            }.value
            WikiEditing.didWrite()
            if let warning { ToastCenter.shared.show(warning) }
        } catch {
            let failure = "\(operation)失败：\(committed ? "正文已提交，召回刷新失败：" : "")\(error.localizedDescription)"
            await Task.detached(priority: .utility) {
                MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: false, note: failure, model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
            }.value
            WikiEditing.didWrite()
            if committed {
                switch action {
                case .delete, .resume:
                    ToastCenter.shared.show(failure)
                    return
                case .restore, .cancel: break
                }
            }
            throw error
        }
    }
}

struct WikiDeleteConfirmation: ViewModifier {
    struct Confirmation {
        let target: WikiDeletionTarget
        let incoming: Int

        static func load(_ target: WikiDeletionTarget) async -> Self {
            let count = await Task.detached(priority: .utility) { target.store.incomingLinkCount(to: target.path) }.value
            return Self(target: target, incoming: count)
        }

        var incomingMessage: String {
            incoming > 0 ? "\n有 \(incoming) 页连到这页，原文保留。" : ""
        }
    }

    @Binding var target: WikiDeletionTarget?
    let hasUnsavedEdits: Bool
    let onDeleted: (WikiDeletionTarget) -> Void
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @State private var confirmation: Confirmation?
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .disabled(busy)
            .task(id: target?.id) {
                confirmation = nil
                guard let t = target else { return }
                guard profiles?.currentProfile.id == t.profileId else {
                    error = "已切换楼层，回原楼层再删"
                    target = nil
                    return
                }
                let prepared = await Confirmation.load(t)
                guard target?.id == t.id, profiles?.currentProfile.id == t.profileId else { return }
                confirmation = prepared
                confirming = true
            }
            .confirmationDialog("删除页「\(confirmation?.target.title ?? "")」？", isPresented: $confirming, titleVisibility: .visible, presenting: confirmation) { _ in
                Button("删除页", role: .destructive) { remove() }
                Button("取消", role: .cancel) { target = nil }
            } message: { prepared in
                Text("仅删这页，条目卡保留，可从 C 档案「已删除」恢复。"
                     + prepared.incomingMessage
                     + (hasUnsavedEdits ? "\n未保存的修改会丢。" : ""))
            }
            .onChange(of: confirming) { _, shown in
                if !shown && !busy { target = nil }
            }
            .alert("删除未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
                target = nil
                confirming = false
            }
    }

    private func remove() {
        guard let t = confirmation?.target, target?.id == t.id else { return }
        guard profiles?.currentProfile.id == t.profileId else {
            error = "已切换楼层，回原楼层再删"
            target = nil
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await WikiDeletionAction.perform(.delete(path: t.path, version: t.expectedVersion), store: t.store, profileId: t.profileId)
                guard profiles?.currentProfile.id == t.profileId else { return }
                target = nil
                onDeleted(t)
            } catch {
                guard profiles?.currentProfile.id == t.profileId else { return }
                self.error = error.localizedDescription
                target = nil
            }
        }
    }
}

struct WikiDeletedPage: View {
    let profileId: String
    let store: WikiStore
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @State private var receipts: [WikiStore.DeletionReceipt]?

    var body: some View {
        List {
            if let receipts {
                if receipts.isEmpty { Text("还没有已删除的页").foregroundColor(Theme.textMuted) }
                ForEach(receipts) { receipt in
                    WikiDeletedRow(profileId: profileId, store: store, receipt: receipt) { Task { await reload() } }
                }
            } else {
                ProgressView()
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .memorySubpage("已删除 C 档案")
        .task(id: profileId) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in Task { await reload() } }
    }

    private func reload() async {
        let list = await Task.detached(priority: .utility) {
            store.deletions().filter { $0.phase != .restored && $0.reason != "批准补偿" }
        }.value
        guard profiles?.currentProfile.id == profileId else { return }
        receipts = list
    }
}

private struct WikiDeletedRow: View {
    let profileId: String
    let store: WikiStore
    let receipt: WikiStore.DeletionReceipt
    let onChange: () -> Void
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink {
                WikiDeletedPreview(store: store, receipt: receipt)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(receipt.title).font(m.body).foregroundColor(Theme.textPrimary)
                    Text(receipt.path).font(m.caption).foregroundColor(Theme.textMuted)
                    if receipt.deletedAt != .distantPast {
                        Text(FileVersionHistory.timeText(receipt.deletedAt)).font(m.caption).foregroundColor(Theme.textMuted)
                    }
                    Text(receipt.reason ?? "未记录原因").font(m.caption).foregroundColor(Theme.textMuted)
                    if receipt.reason == "撤回新页" {
                        Text("只恢复正文，不恢复批准；对应条目仍待批").font(m.caption).foregroundColor(Theme.textMuted)
                    }
                }
            }
            if let problem = error ?? receipt.problem {
                Text(problem).font(m.caption).foregroundColor(Theme.textSecondary)
            }
            HStack {
                if receipt.incomplete {
                    Button("丢弃收据") { run(.cancel(id: receipt.id)) }
                } else if receipt.problem == nil {
                    Button("恢复") { run(.restore(id: receipt.id)) }
                }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private func run(_ action: WikiDeletionAction.Action) {
        guard profiles?.currentProfile.id == profileId else { return }
        busy = true
        Task {
            do {
                try await WikiDeletionAction.perform(action, store: store, profileId: profileId)
                guard profiles?.currentProfile.id == profileId else { return }
                onChange()
            } catch {
                guard profiles?.currentProfile.id == profileId else { return }
                self.error = error.localizedDescription
                onChange()
            }
            busy = false
        }
    }
}

private struct WikiDeletedPreview: View {
    let store: WikiStore
    let receipt: WikiStore.DeletionReceipt
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @State private var text: String?

    var body: some View {
        ScrollView {
            Text(WikiStore.shown(text ?? receipt.problem ?? "正在读取…", user: profiles?.currentProfile.userName ?? ""))
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.mainBg)
        .navigationTitle(receipt.title)
        .task {
            let pid = profiles?.currentProfile.id
            let preview = await Task.detached(priority: .utility) { store.historyText(receipt.path, entry: receipt.historyEntry) }.value
            guard pid == profiles?.currentProfile.id else { return }
            text = preview ?? receipt.problem ?? "历史副本缺失"
        }
    }
}
