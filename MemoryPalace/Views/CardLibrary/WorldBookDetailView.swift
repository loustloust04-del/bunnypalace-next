import SwiftUI
import UniformTypeIdentifiers

/// 书详情（⑥，小样 05）：书名 + 范围 + 条目数；＋ 新条目 / 更多（重命名 / 改范围 / 导出 JSON / 删除整本）；
/// 条目按注入顺序列出，单条开关，删条目立即保存并给 5 秒撤销。跨楼层的书只读，先切到所属楼层才能改。
struct WorldBookDetailView: View {
    let item: WorldBookListItem
    let scopeLabel: String
    let ownerName: String
    let isForeign: Bool
    /// 宿主真实选中的对话（id, 标题）；nil = 不能改成对话范围
    let selectedConversation: (id: String, title: String)?
    @Binding var revealEntryId: UUID?
    let onBack: () -> Void
    let onSwitchFloor: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(GlobalWorldBookManager.self) private var globalManager: GlobalWorldBookManager?

    @State private var searchText = ""
    @State private var editing: EditingEntry?
    @State private var lastDeletion: WorldBookLibrary.Deletion?
    @State private var highlightedId: String?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
    @State private var exportDocument: WorldBookJSONDocument?
    @State private var errorMessage: String?

    private struct EditingEntry: Identifiable {
        let entry: WorldBookEntry
        let isNew: Bool
        var id: UUID { entry.id }
    }

    private var writer: WorldBookWriter { WorldBookWriter(context: modelContext, globals: globalManager) }

    private var visibleEntries: [WorldBookEntry] {
        let ordered = WorldBookLibrary.displayOrder(item.entries)
        guard let keyword = searchText.panelSearchKeyword else { return ordered }
        return ordered.filter { WorldBookLibrary.matches($0, keyword: keyword) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        #if os(iOS)
                        GlassBackButton(action: onBack)
                        #else
                        Button(action: onBack) {
                            Label("世界书", systemImage: "chevron.left").frame(minHeight: 44)
                        }
                        .buttonStyle(.plain).foregroundColor(Theme.branchIndicator)
                        #endif
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    if isForeign { foreignBanner.padding(.horizontal, 8) }
                    CalendarTicket {
                        titleBlock
                        TicketNotch()
                        searchField
                        IOSSubLabel(text: "条目 · 按注入顺序")
                        if visibleEntries.isEmpty {
                            Text(item.entries.isEmpty ? "还没有条目" : "没有匹配的条目")
                                .font(.system(size: 14)).foregroundColor(Theme.textMuted)
                                .padding(.horizontal, IOSCal.pad).padding(.vertical, 12)
                        }
                        ForEach(visibleEntries) { entry in entryRow(entry).id(item.entryTargetId(entry.id)) }
                        Color.clear.frame(height: 12)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.sidebarBg)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let lastDeletion { undoBar(lastDeletion) }
            }
            .onAppear { reveal(proxy) }
            .onChange(of: revealEntryId) { _, _ in reveal(proxy) }
        }
        .task(id: lastDeletion?.token) {
            guard lastDeletion != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { lastDeletion = nil }
        }
        .sheet(item: $editing) { target in
            WorldBookEntryEditView(
                entry: target.entry, bookName: item.name, isNew: target.isNew, readOnly: isForeign,
                onSave: { entry in
                    try save(entry, isNew: target.isNew)
                    editing = nil
                },
                onDelete: target.isNew || isForeign ? nil : {
                    editing = nil
                    delete(target.entry)
                },
                onCancel: { editing = nil })
        }
        .alert("重命名", isPresented: $renaming) {
            TextField("书名", text: $renameText)
            Button("确定") { rename() }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除「\(item.name)」？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除整本", role: .destructive) { deleteBook() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包含 \(item.entries.count) 个条目，删除后不能恢复。")
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json, defaultFilename: item.name.isEmpty ? "世界书" : item.name) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            exportDocument = nil
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好的") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - 头部

    private var foreignBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这本书属于楼层「\(ownerName)」，编辑前先切过去")
                .font(.system(size: 13)).foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onSwitchFloor) {
                Text("切到这个楼层").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.mainBg)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(Theme.branchIndicator, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.name.isEmpty ? "未命名" : item.name)
                .font(.system(size: 25, weight: .bold)).foregroundColor(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("\(scopeLabel)　／　\(item.entries.count) 条\(item.isEnabled ? "" : " · 整本已停用")")
                .font(.system(size: 13)).foregroundColor(Theme.textMuted)
            HStack(spacing: 10) {
                Button { editing = EditingEntry(entry: WorldBookEntry(), isNew: true) } label: {
                    Text("＋ 新条目").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.mainBg)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(isForeign ? Theme.textMuted : Theme.branchIndicator, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isForeign)
                moreMenu
            }
        }
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 18)
    }

    private var moreMenu: some View {
        Menu {
            Button("重命名", systemImage: "pencil") { renameText = item.name; renaming = true }
                .disabled(isForeign)
            if item.kind == .floor {
                if item.conversationId != nil {
                    Button("改成整个楼层都生效", systemImage: "building.2") { setConversation(nil) }
                        .disabled(isForeign)
                } else {
                    Button(selectedConversation.map { "改成只在「\($0.title)」生效" } ?? "改成只在这个对话生效（没有选中对话）",
                           systemImage: "bubble.left") { setConversation(selectedConversation?.id) }
                        .disabled(isForeign || selectedConversation == nil)
                }
            }
            Button("导出 JSON", systemImage: "square.and.arrow.up") { export() }
            Button("删除整本", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                .disabled(isForeign)
        } label: {
            Text("更多").font(.system(size: 15, weight: .medium)).foregroundColor(Theme.branchIndicator)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("更多操作")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.textMuted)
            TextField("搜索备注、关键词", text: $searchText)
                .textFieldStyle(.plain).foregroundColor(Theme.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textMuted).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("清空搜索")
            }
        }
        .font(.system(size: 14))
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(minHeight: 44)
        .background(Theme.textPrimary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, IOSCal.pad)
    }

    // MARK: - 条目行

    private func entryRow(_ entry: WorldBookEntry) -> some View {
        let title = WorldBookLibrary.title(of: entry)
        let rowId = item.entryTargetId(entry.id)
        let on = entry.isEnabled
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { editing = EditingEntry(entry: entry, isNew: false) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 15, weight: .medium))
                            .foregroundColor(on ? Theme.textPrimary : Theme.textMuted).lineLimit(1)
                        keyChips(entry)
                        Text(WorldBookLibrary.summary(of: entry)).font(.system(size: 11)).foregroundColor(Theme.textMuted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isForeign ? "查看" : "编辑")「\(title)」")
                Toggle("", isOn: Binding(get: { on }, set: { setEnabled($0, entry: entry) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.branchIndicator)
                    .disabled(isForeign)
                    .accessibilityLabel("启用「\(title)」")
                Button { editing = EditingEntry(entry: entry, isNew: false) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, IOSCal.pad)
            .padding(.vertical, 4)
            .background(Theme.branchIndicator.opacity(highlightedId == rowId ? 0.25 : 0))
            IOSHairline()
        }
    }

    private func keyChips(_ entry: WorldBookEntry) -> some View {
        HStack(spacing: 4) {
            if entry.keys.isEmpty {
                chip(entry.isConstant ? "无需关键词" : "没有关键词", muted: true)
            } else {
                ForEach(Array(entry.keys.prefix(4).enumerated()), id: \.offset) { _, key in chip(key, muted: false) }
                if entry.keys.count > 4 {
                    Text("+\(entry.keys.count - 4)").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                }
            }
        }
    }

    private func chip(_ text: String, muted: Bool) -> some View {
        Text(text).font(.system(size: 11))
            .foregroundColor(muted ? Theme.textMuted : Theme.branchIndicator)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: 88)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(muted ? Theme.textPrimary.opacity(0.06) : Theme.accent, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }

    private func undoBar(_ deletion: WorldBookLibrary.Deletion) -> some View {
        HStack(spacing: 10) {
            Text("已删除「\(WorldBookLibrary.title(of: deletion.entry))」· 5 秒内可撤销")
                .font(.system(size: 13)).foregroundColor(Theme.mainBg).lineLimit(2)
            Spacer(minLength: 8)
            Button { undo(deletion) } label: {
                Text("撤销").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.branchIndicator)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(Theme.mainBg, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 4)
        .background(Theme.textPrimary.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }

    // MARK: - 动作

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let entryId = revealEntryId else { return }
        revealEntryId = nil
        searchText = ""
        let rowId = item.entryTargetId(entryId)
        guard item.entries.contains(where: { $0.id == entryId }) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                proxy.scrollTo(rowId, anchor: .center)
                highlightedId = rowId
            }
            try? await Task.sleep(for: .milliseconds(1500))
            if highlightedId == rowId {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { highlightedId = nil }
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    private func currentEntries() throws -> [WorldBookEntry] {
        guard let entries = writer.entries(of: item.id) else { throw WorldBookWriter.Failure.bookMissing }
        return entries
    }

    private func setEnabled(_ enabled: Bool, entry: WorldBookEntry) {
        guard !isForeign else { return }
        perform {
            var entries = try currentEntries()
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            entries[index].isEnabled = enabled
            try writer.setEntries(entries, of: item.id)
        }
    }

    private func save(_ entry: WorldBookEntry, isNew: Bool) throws {
        guard !isForeign else { return }
        var entries = try currentEntries()
        if isNew {
            entries.append(entry)
        } else {
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { throw WorldBookEntryEditView.Failure.entryMissing }
            entries[index] = entry
        }
        try writer.setEntries(entries, of: item.id)
    }

    private func delete(_ entry: WorldBookEntry) {
        guard !isForeign else { return }
        perform {
            guard let result = WorldBookLibrary.deleting(try currentEntries(), entryId: entry.id, bookItemId: item.id) else { return }
            try writer.setEntries(result.entries, of: item.id)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { lastDeletion = result.deletion }
        }
    }

    private func undo(_ deletion: WorldBookLibrary.Deletion) {
        lastDeletion = nil
        switch WorldBookLibrary.restoring(deletion, into: writer.entries(of: deletion.bookItemId)) {
        case .restored(let entries): perform { try writer.setEntries(entries, of: deletion.bookItemId) }
        case .conflict(let message): errorMessage = message
        }
    }

    private func rename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isForeign else { return }
        perform { try writer.rename(name, itemId: item.id) }
    }

    private func setConversation(_ conversationId: String?) {
        guard !isForeign else { return }
        perform { try writer.setConversation(conversationId, itemId: item.id) }
    }

    private func export() {
        perform { exportDocument = WorldBookJSONDocument(data: try writer.exportData(itemId: item.id)) }
    }

    private func deleteBook() {
        guard !isForeign else { return }
        perform {
            try writer.delete(itemId: item.id, profileManager: profileManager)
            onBack()
        }
    }
}

struct WorldBookJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw WorldBookCodec.DecodeError.invalidBook }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
