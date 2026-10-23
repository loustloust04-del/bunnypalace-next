import SwiftUI
import SwiftData

// MARK: - World Book Panel (右栏世界书 Tab)

struct WorldBookPanelView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(GlobalWorldBookManager.self) private var globalWBManager: GlobalWorldBookManager?

    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    @State private var worldBooks: [WorldBook] = []
    @State private var expandedEntryIds: Set<UUID> = []
    @State private var highlightedEntryId: String? = nil
    @State private var searchText = ""
    @State private var pendingScrollId: String? = nil
    @State private var floorEntryCache = FloorEntryCache()

    // 编辑 sheet
    @State private var editingEntry: WorldBookEntry?
    @State private var editingBookId: UUID?
    @State private var isAddingNew = false
    @State private var editingGlobalBookId: String?  // 全局世界书编辑

    // 世界书操作
    @State private var renamingBook: WorldBook?
    @State private var renameText = ""
    @State private var deletingBook: WorldBook?
    @State private var showWBFileImporter = false
    @State private var wbImportError: String?
    @State private var importSummary: String?
    @State private var showNewBookAlert = false
    @State private var newBookName = ""
    @State private var newBookScope = 0  // 0=楼层, 1=全局, 2=当前对话
    @State private var deletingGlobalBook: GlobalWorldBook?
    @State private var renamingGlobalBook: GlobalWorldBook?

    private var globalBooks: [GlobalWorldBook] {
        globalWBManager?.books ?? []
    }

    private var hasAnyContent: Bool {
        !worldBooks.isEmpty || !globalBooks.isEmpty
    }

    private var searchKeyword: String? { searchText.panelSearchKeyword }

    private func visibleGlobalEntries(_ book: GlobalWorldBook) -> [WorldBookEntry] {
        WorldBookEntryEdits.visible(book.entries, keyword: searchKeyword, bookName: book.name)
    }

    private func visibleFloorEntries(_ book: WorldBook) -> [WorldBookEntry] {
        WorldBookEntryEdits.visible(floorEntryCache.entries(of: book), keyword: searchKeyword, bookName: book.name)
    }

    private var hasAnyMatch: Bool {
        globalBooks.contains { !visibleGlobalEntries($0).isEmpty } || worldBooks.contains { !visibleFloorEntries($0).isEmpty }
    }

    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
        actionBar
        PanelSectionList {
            if !hasAnyContent {
                Section {
                    emptyState
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if searchKeyword != nil && !hasAnyMatch {
                Section {
                    PanelNoMatchView()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            globalBookSections
            floorBookSections
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .toolPageBackground()
        // 旧 .toolbar 已删：mac 上会被提升进窗口统一标题栏错位（B-1/B-2 同族），
        // iOS 上无 NavigationStack 容器根本不渲染——新建/导入统一走面板内 actionBar
        .onAppear { loadWorldBooks() }
        .onAppear { AssistantContext.shared.report(page: "worldBook") }
        .onDisappear { AssistantContext.shared.clear(page: "worldBook") }
        .sheet(item: $editingEntry) { entry in
            WorldBookEntryEditor(
                entry: entry,
                isNew: isAddingNew,
                onSave: { updated in
                    saveEntry(updated)
                    editingEntry = nil
                },
                onCancel: { editingEntry = nil }
            )
        }
        .alert("重命名世界书", isPresented: Binding(
            get: { renamingBook != nil },
            set: { if !$0 { renamingBook = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("确定") { renameBook() }
            Button("取消", role: .cancel) { renamingBook = nil }
        }
        .alert("重命名全局世界书", isPresented: Binding(
            get: { renamingGlobalBook != nil },
            set: { if !$0 { renamingGlobalBook = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("确定") {
                if var book = renamingGlobalBook, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    book.name = renameText.trimmingCharacters(in: .whitespaces)
                    globalWBManager?.update(book)
                }
                renamingGlobalBook = nil
            }
            Button("取消", role: .cancel) { renamingGlobalBook = nil }
        }
        .confirmationDialog(
            "删除世界书",
            isPresented: Binding(
                get: { deletingBook != nil },
                set: { if !$0 { deletingBook = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteBook() }
            Button("取消", role: .cancel) { deletingBook = nil }
        } message: {
            if let book = deletingBook {
                Text("确定要删除「\(book.name)」吗？包含 \(book.entries.count) 个条目，不可恢复。")
            }
        }
        .fileImporter(
            isPresented: $showWBFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleWorldBookImport(result)
        }
        .alert("导入完成", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("好的") { importSummary = nil }
        } message: { Text(importSummary ?? "") }
        .alert("导入失败", isPresented: Binding(
            get: { wbImportError != nil },
            set: { if !$0 { wbImportError = nil } }
        )) {
            Button("好的") { wbImportError = nil }
        } message: {
            Text(wbImportError ?? "")
        }
        .alert("新建世界书", isPresented: $showNewBookAlert) {
            TextField("名称", text: $newBookName)
            Button("创建") { createNewBook() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(newBookScope == 0 ? "仅当前楼层生效" : newBookScope == 1 ? "所有楼层生效" : "仅当前对话生效")
        }
        .confirmationDialog(
            "删除全局世界书",
            isPresented: Binding(
                get: { deletingGlobalBook != nil },
                set: { if !$0 { deletingGlobalBook = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let book = deletingGlobalBook {
                    globalWBManager?.delete(book)
                }
                deletingGlobalBook = nil
            }
            Button("取消", role: .cancel) { deletingGlobalBook = nil }
        } message: {
            if let book = deletingGlobalBook {
                Text("确定要删除全局世界书「\(book.name)」吗？")
            }
        }
        .onAppear { consumeTarget(navigator?.pendingTarget, proxy: proxy) }
        .onChange(of: navigator?.pendingTarget) { _, target in
            consumeTarget(target, proxy: proxy)
        }
        .onChange(of: searchText) { _, text in
            guard text.isEmpty, let id = pendingScrollId else { return }
            pendingScrollId = nil
            DispatchQueue.main.async { scrollToEntry(id, proxy: proxy) }
        }
        } // end VStack
        } // end ScrollViewReader
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("楼层世界书") { newBookScope = 0; newBookName = ""; showNewBookAlert = true }
                Button("全局世界书") { newBookScope = 1; newBookName = ""; showNewBookAlert = true }
                Button("当前对话") { newBookScope = 2; newBookName = ""; showNewBookAlert = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("新建")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                }
                .foregroundColor(Theme.branchIndicator)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.branchIndicator.opacity(0.12)))
            }
            .buttonStyle(.plain)

            Button {
                showWBFileImporter = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10))
                    Text("导入")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                }
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.textMuted.opacity(0.08)))
            }
            .buttonStyle(.plain)

            PanelSearchField(prompt: "搜索条目", text: $searchText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func consumeTarget(_ target: RightPanelNavigator.Target?, proxy: ScrollViewProxy) {
        guard let t = target, t.tool == "worldBook" else { return }
        // 解析目标 id 提取 entryId 并 expand
        let parts = t.id.split(separator: ":")
        if parts.count == 3, let entryUUID = UUID(uuidString: String(parts[2])) {
            expandedEntryIds.insert(entryUUID)
        }
        if searchText.isEmpty {
            scrollToEntry(t.id, proxy: proxy)
        } else {
            // 目标可能被搜索词滤掉：先清词，等 onChange(searchText) 那一轮列表重建完再滚
            pendingScrollId = t.id
            searchText = ""
        }
        highlightedEntryId = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if highlightedEntryId == t.id { highlightedEntryId = nil }
        }
        navigator?.pendingTarget = nil
    }

    private func scrollToEntry(_ id: String, proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 24))
                .foregroundColor(Theme.textMuted.opacity(0.4))
            Text("此楼层没有世界书")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
            Text("导入助手模板时会自动导入，或手动新建")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted.opacity(0.6))
            HStack(spacing: 8) {
                Menu {
                    Button("楼层世界书") { newBookScope = 0; newBookName = ""; showNewBookAlert = true }
                    Button("全局世界书") { newBookScope = 1; newBookName = ""; showNewBookAlert = true }
                    Button("当前对话") { newBookScope = 2; newBookName = ""; showNewBookAlert = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("新建世界书")
                            .font(.system(size: Theme.F.secondary, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.branchIndicator))
                }
                .buttonStyle(.plain)

                Button {
                    showWBFileImporter = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10))
                        Text("导入 JSON")
                            .font(.system(size: Theme.F.secondary, weight: .medium))
                    }
                    .foregroundColor(Theme.branchIndicator)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.branchIndicator.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - World Book Content

    // MARK: - Global World Book Section

    @ViewBuilder
    private var globalBookSections: some View {
        ForEach(globalBooks) { book in
            let rows = visibleGlobalEntries(book)
            if searchKeyword == nil || !rows.isEmpty {
                Section {
                    ForEach(rows) { entry in
                        let rowId = "global:\(book.id):\(entry.id.uuidString)"
                        globalEntryRow(entry: entry, book: book)
                            .id(rowId)
                            #if os(macOS)
                            // mac 分组卡里 listRowBackground 不生效：跳转高亮垫在行底，停用条目整行淡一点
                            .opacity(entry.isEnabled ? 1 : 0.55)
                            .background(Theme.branchIndicator.opacity(highlightedEntryId == rowId ? 0.3 : 0).padding(-6)
                                .animation(.easeInOut(duration: 0.35), value: highlightedEntryId))
                            #else
                            .listRowBackground(
                                ZStack {
                                    Theme.mainBg.opacity(entry.isEnabled ? 1 : 0.5)
                                    if highlightedEntryId == rowId {
                                        Theme.branchIndicator.opacity(0.3)
                                    }
                                }
                                .animation(.easeInOut(duration: 0.35), value: highlightedEntryId)
                            )
                            #endif
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    globalBookHeader(book)
                }
            }
        }
    }

    @ViewBuilder
    private var floorBookSections: some View {
        ForEach(worldBooks, id: \.id) { book in
            let rows = visibleFloorEntries(book)
            if searchKeyword == nil || !rows.isEmpty {
                Section {
                    ForEach(rows) { entry in
                        let rowId = "floor:\(book.id.uuidString):\(entry.id.uuidString)"
                        entryRow(entry: entry, book: book)
                            .id(rowId)
                            #if os(macOS)
                            // mac 分组卡里 listRowBackground 不生效：跳转高亮垫在行底，停用条目整行淡一点
                            .opacity(entry.isEnabled ? 1 : 0.55)
                            .background(Theme.branchIndicator.opacity(highlightedEntryId == rowId ? 0.3 : 0).padding(-6)
                                .animation(.easeInOut(duration: 0.35), value: highlightedEntryId))
                            #else
                            .listRowBackground(
                                ZStack {
                                    Theme.mainBg.opacity(entry.isEnabled ? 1 : 0.5)
                                    if highlightedEntryId == rowId {
                                        Theme.branchIndicator.opacity(0.3)
                                    }
                                }
                                .animation(.easeInOut(duration: 0.35), value: highlightedEntryId)
                            )
                            #endif
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    floorBookHeader(book, entries: floorEntryCache.entries(of: book))
                }
            }
        }
    }

    private func globalBookHeader(_ book: GlobalWorldBook) -> some View {
        HStack {
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundColor(Theme.branchIndicator)
            Text(book.name)

            Spacer()

            Text("\(book.enabledEntryCount)/\(book.entries.count)")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)

            Toggle("", isOn: Binding(
                get: { book.isEnabled },
                set: { _ in globalWBManager?.toggleEnabled(book.id) }
            ))
            .toggleStyle(.switch)
            .scaleEffect(0.55)
            .frame(width: 36)

            Button {
                isAddingNew = true
                editingGlobalBookId = book.id
                editingBookId = nil
                editingEntry = WorldBookEntry()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.branchIndicator.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button { renameText = book.name; renamingGlobalBook = book } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) { deletingGlobalBook = book } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func globalEntryRow(entry: WorldBookEntry, book: GlobalWorldBook) -> some View {
        let isExpanded = expandedEntryIds.contains(entry.id)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { newValue in
                        guard let current = globalBooks.first(where: { $0.id == book.id }),
                              let entries = WorldBookEntryEdits.settingEnabled(current.entries, id: entry.id, newValue) else { return }
                        globalWBManager?.updateEntries(bookId: book.id, entries: entries)
                    }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.6)
                .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if entry.isConstant {
                            Text("常驻")
                                .font(.system(size: Theme.F.badge, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.branchIndicator.opacity(0.7)))
                        }
                        Text(entryTitle(entry))
                            .font(.system(size: Theme.F.label, weight: .medium))
                            .foregroundColor(entry.isEnabled ? Theme.textPrimary : Theme.textMuted)
                            .lineLimit(1)
                    }
                    if !entry.keys.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(entry.keys.prefix(4), id: \.self) { key in
                                Text(key)
                                    .font(.system(size: Theme.F.badge))
                                    .foregroundColor(Theme.branchIndicator)
                                    // 长关键词截断：任意长度用户输入会把整行推出窄右栏（A-6）
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 64)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                            }
                        }
                    }
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expandedEntryIds.remove(entry.id) }
                    else { expandedEntryIds.insert(entry.id) }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.content)
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        metaTag("位置", value: positionLabel(entry.position))
                        metaTag("排序", value: "\(entry.insertionOrder)")
                    }
                    HStack(spacing: 8) {
                        Button {
                            isAddingNew = false
                            editingGlobalBookId = book.id
                            editingBookId = nil
                            editingEntry = entry
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "pencil").font(.system(size: 9))
                                Text("编辑").font(.system(size: Theme.F.secondary))
                            }
                            .foregroundColor(Theme.branchIndicator)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                        }
                        .buttonStyle(.plain)

                        Button {
                            guard let current = globalBooks.first(where: { $0.id == book.id }),
                                  let entries = WorldBookEntryEdits.removing(current.entries, id: entry.id) else { return }
                            expandedEntryIds.remove(entry.id)
                            globalWBManager?.updateEntries(bookId: book.id, entries: entries)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "trash").font(.system(size: 9))
                                Text("删除").font(.system(size: Theme.F.secondary))
                            }
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.red.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Floor World Book Header

    private func floorBookHeader(_ book: WorldBook, entries: [WorldBookEntry]) -> some View {
        HStack {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 11))
                .foregroundColor(Theme.branchIndicator)
            Text(book.name)

            Spacer()

            Menu {
                Button { setScopeForBook(book, scope: .floor) } label: {
                    Label("楼层", systemImage: book.scopeConversationId == nil ? "checkmark" : "")
                }
                Button { setScopeForBook(book, scope: .conversation) } label: {
                    Label("当前对话", systemImage: book.scopeConversationId != nil ? "checkmark" : "")
                }
            } label: {
                Text(book.scopeConversationId != nil ? "对话" : "楼层")
                    .font(.system(size: Theme.F.badge, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
            }
            .buttonStyle(.plain)

            let enabledCount = entries.filter(\.isEnabled).count
            Text("\(enabledCount)/\(entries.count)")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)

            Button {
                isAddingNew = true
                editingGlobalBookId = nil
                editingBookId = book.id
                editingEntry = WorldBookEntry()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.branchIndicator.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button { renameText = book.name; renamingBook = book } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) { deletingBook = book } label: {
                Label("删除世界书", systemImage: "trash")
            }
        }
    }

    // MARK: - Entry Row

    private func entryRow(entry: WorldBookEntry, book: WorldBook) -> some View {
        let isExpanded = expandedEntryIds.contains(entry.id)

        return VStack(alignment: .leading, spacing: 0) {
            // 主行：开关 + 摘要
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { newValue in
                        toggleEntry(bookId: book.id, entryId: entry.id, enabled: newValue)
                    }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.6)
                .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if entry.isConstant {
                            Text("常驻")
                                .font(.system(size: Theme.F.badge, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.branchIndicator.opacity(0.7)))
                        }
                        Text(entryTitle(entry))
                            .font(.system(size: Theme.F.label, weight: .medium))
                            .foregroundColor(entry.isEnabled ? Theme.textPrimary : Theme.textMuted)
                            .lineLimit(1)
                    }

                    if !entry.keys.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(entry.keys.prefix(4), id: \.self) { key in
                                Text(key)
                                    .font(.system(size: Theme.F.badge))
                                    .foregroundColor(Theme.branchIndicator)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 64)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                            }
                            if entry.keys.count > 4 {
                                Text("+\(entry.keys.count - 4)")
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedEntryIds.remove(entry.id)
                    } else {
                        expandedEntryIds.insert(entry.id)
                    }
                }
            }

            // 展开内容
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.content)
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        metaTag("位置", value: positionLabel(entry.position))
                        metaTag("排序", value: "\(entry.insertionOrder)")
                        if entry.probability < 100 {
                            metaTag("概率", value: "\(entry.probability)%")
                        }
                    }

                    // 编辑 + 删除按钮
                    HStack(spacing: 8) {
                        Button {
                            isAddingNew = false
                            editingGlobalBookId = nil
                            editingBookId = book.id
                            editingEntry = entry
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                                Text("编辑")
                                    .font(.system(size: Theme.F.secondary))
                            }
                            .foregroundColor(Theme.branchIndicator)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                        }
                        .buttonStyle(.plain)

                        Button {
                            deleteEntry(bookId: book.id, entryId: entry.id)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "trash")
                                    .font(.system(size: 9))
                                Text("删除")
                                    .font(.system(size: Theme.F.secondary))
                            }
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.red.opacity(0.08)))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Helpers

    private func entryTitle(_ entry: WorldBookEntry) -> String {
        if !entry.comment.isEmpty { return entry.comment }
        if !entry.keys.isEmpty { return entry.keys.joined(separator: ", ") }
        return String(entry.content.prefix(30))
    }

    private func positionLabel(_ pos: WorldBookEntry.InsertionPosition) -> String {
        switch pos {
        case .beforeCharDef:  return "助手设定前"
        case .afterCharDef:   return "助手设定后"
        case .authorNoteTop:  return "作者注释前"
        case .authorNoteBot:  return "作者注释后"
        case .atDepth:        return "对话深度"
        case .beforeExamples: return "示例前"
        case .afterExamples:  return "示例后"
        case .unsupported:    return "不支持（不注入）"
        }
    }

    private func metaTag(_ label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            Text(value)
                .font(.system(size: Theme.F.secondary, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.3)))
    }

    // MARK: - Data Operations

    private func loadWorldBooks() {
        let profileId = profileManager?.currentProfile.id ?? ""
        let descriptor = FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == profileId })
        worldBooks = (try? modelContext.fetch(descriptor)) ?? []
        floorEntryCache = FloorEntryCache()
    }

    private func toggleEntry(bookId: UUID, entryId: UUID, enabled: Bool) {
        guard let bookIndex = worldBooks.firstIndex(where: { $0.id == bookId }),
              let entries = WorldBookEntryEdits.settingEnabled(worldBooks[bookIndex].entries, id: entryId, enabled) else { return }
        worldBooks[bookIndex].entries = entries
        try? modelContext.save()
    }

    private func saveEntry(_ entry: WorldBookEntry) {
        // 全局世界书
        if let globalId = editingGlobalBookId {
            guard let bookIndex = globalBooks.firstIndex(where: { $0.id == globalId }) else { return }
            var entries = globalBooks[bookIndex].entries
            if isAddingNew {
                entries.append(entry)
            } else {
                guard let replaced = WorldBookEntryEdits.replacing(entries, with: entry) else { return }
                entries = replaced
            }
            globalWBManager?.updateEntries(bookId: globalId, entries: entries)
            return
        }

        // 楼层世界书
        guard let bookId = editingBookId,
              let bookIndex = worldBooks.firstIndex(where: { $0.id == bookId }) else { return }
        var entries = worldBooks[bookIndex].entries

        if isAddingNew {
            entries.append(entry)
        } else {
            guard let replaced = WorldBookEntryEdits.replacing(entries, with: entry) else { return }
            entries = replaced
        }

        worldBooks[bookIndex].entries = entries
        try? modelContext.save()
    }

    private enum BookScope { case floor, conversation }

    private func setScopeForBook(_ book: WorldBook, scope: BookScope) {
        guard let idx = worldBooks.firstIndex(where: { $0.id == book.id }) else { return }
        switch scope {
        case .floor:
            worldBooks[idx].scopeConversationId = nil
        case .conversation:
            let pid = profileManager?.currentProfile.id ?? ""
            let convDescriptor = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == pid },
                sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
            )
            let currentConvId = (try? modelContext.fetch(convDescriptor))?.first?.id
            worldBooks[idx].scopeConversationId = currentConvId
        }
        try? modelContext.save()
    }

    private func createNewBook() {
        let name = newBookName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        switch newBookScope {
        case 1: // 全局
            globalWBManager?.create(name: name)

        case 2: // 当前对话
            let profileId = profileManager?.currentProfile.id ?? ""
            let worldBook = WorldBook(name: name, profileId: profileId, entries: [])
            // 找到当前选中的对话 ID
            let pid = profileManager?.currentProfile.id ?? ""
            let convDescriptor = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == pid },
                sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
            )
            let currentConvId = (try? modelContext.fetch(convDescriptor))?.first?.id
            worldBook.scopeConversationId = currentConvId
            modelContext.insert(worldBook)

            if var profile = profileManager?.currentProfile {
                profile.linkedWorldBookIDs.append(worldBook.id.uuidString)
                profileManager?.updateProfile(profile)
            }
            try? modelContext.save()
            loadWorldBooks()

        default: // 0 = 楼层
            let profileId = profileManager?.currentProfile.id ?? ""
            let worldBook = WorldBook(name: name, profileId: profileId, entries: [])
            modelContext.insert(worldBook)

            if var profile = profileManager?.currentProfile {
                profile.linkedWorldBookIDs.append(worldBook.id.uuidString)
                profileManager?.updateProfile(profile)
            }
            try? modelContext.save()
            loadWorldBooks()
        }
    }

    private func deleteEntry(bookId: UUID, entryId: UUID) {
        guard let bookIndex = worldBooks.firstIndex(where: { $0.id == bookId }),
              let entries = WorldBookEntryEdits.removing(worldBooks[bookIndex].entries, id: entryId) else { return }
        worldBooks[bookIndex].entries = entries
        expandedEntryIds.remove(entryId)
        try? modelContext.save()
    }

    private func renameBook() {
        guard let book = renamingBook,
              let idx = worldBooks.firstIndex(where: { $0.id == book.id }),
              !renameText.trimmingCharacters(in: .whitespaces).isEmpty else {
            renamingBook = nil
            return
        }
        worldBooks[idx].name = renameText.trimmingCharacters(in: .whitespaces)
        try? modelContext.save()
        renamingBook = nil
    }

    private func deleteBook() {
        guard let book = deletingBook,
              let idx = worldBooks.firstIndex(where: { $0.id == book.id }) else {
            deletingBook = nil
            return
        }
        modelContext.delete(worldBooks[idx])
        worldBooks.remove(at: idx)

        // 从 profile 移除绑定
        if var profile = profileManager?.currentProfile {
            profile.linkedWorldBookIDs.removeAll { $0 == book.id.uuidString }
            profileManager?.updateProfile(profile)
        }

        try? modelContext.save()
        deletingBook = nil
    }

    /// 独立导入世界书 JSON 文件
    private func handleWorldBookImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let report = try WorldBookCodec.decodeImport(data)
                guard !report.entries.isEmpty else {
                    wbImportError = "世界书没有条目"
                    return
                }
                let name = report.name ?? url.deletingPathExtension().lastPathComponent
                let worldBook = WorldBook(name: name, profileId: profileManager?.currentProfile.id ?? "", entries: report.entries)
                worldBook.rawJSONData = report.rawJSONData
                modelContext.insert(worldBook)

                // 绑定到当前楼层
                if var profile = profileManager?.currentProfile {
                    profile.linkedWorldBookIDs.append(worldBook.id.uuidString)
                    profileManager?.updateProfile(profile)
                }

                try modelContext.save()
                loadWorldBooks()
                importSummary = report.summary
            } catch {
                wbImportError = error.localizedDescription
            }
        case .failure(let error):
            wbImportError = error.localizedDescription
        }
    }
}

// MARK: - 过滤 + 按条目 id 回查（面板搜索后行序≠原下标，改 / 开关 / 删一律按 id 找原位置）

enum WorldBookEntryEdits {
    /// 口径同 `SearchService.matchWorldBookEntry`：备注 / 内容 / 主次关键词 / 书名
    static func matches(_ entry: WorldBookEntry, keyword: String, bookName: String) -> Bool {
        entry.comment.localizedStandardContains(keyword)
            || entry.content.localizedStandardContains(keyword)
            || entry.keys.contains { $0.localizedStandardContains(keyword) }
            || entry.secondaryKeys.contains { $0.localizedStandardContains(keyword) }
            || bookName.localizedStandardContains(keyword)
    }

    static func visible(_ entries: [WorldBookEntry], keyword: String?, bookName: String) -> [WorldBookEntry] {
        guard let keyword else { return entries }
        if bookName.localizedStandardContains(keyword) { return entries }
        return entries.filter { matches($0, keyword: keyword, bookName: bookName) }
    }

    static func settingEnabled(_ entries: [WorldBookEntry], id: UUID, _ enabled: Bool) -> [WorldBookEntry]? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var out = entries
        out[i].isEnabled = enabled
        return out
    }

    static func replacing(_ entries: [WorldBookEntry], with entry: WorldBookEntry) -> [WorldBookEntry]? {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        var out = entries
        out[i] = entry
        return out
    }

    static func removing(_ entries: [WorldBookEntry], id: UUID) -> [WorldBookEntry]? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var out = entries
        out.remove(at: i)
        return out
    }
}

/// 楼层世界书条目是 `entriesData` 里的 JSON，`book.entries` 每次访问都解码。按书缓存，`entriesData` 变了（任何来源的改动）就重解；
/// 引用类型挂 @State，body 里读写不触发刷新。换楼层走 `loadWorldBooks` 整个换新。
final class FloorEntryCache {
    private var store: [UUID: (data: Data, entries: [WorldBookEntry])] = [:]

    func entries(of book: WorldBook) -> [WorldBookEntry] {
        let data = book.entriesData
        if let hit = store[book.id], hit.data == data { return hit.entries }
        let decoded = book.entries
        store[book.id] = (data, decoded)
        return decoded
    }
}

// MARK: - Entry Editor Sheet

struct WorldBookEntryEditor: View {
    let entry: WorldBookEntry
    let isNew: Bool
    let onSave: (WorldBookEntry) -> Void
    let onCancel: () -> Void

    @State private var comment: String
    @State private var keysText: String
    @State private var secondaryKeysText: String
    @State private var content: String
    @State private var position: WorldBookEntry.InsertionPosition
    @State private var insertionOrder: String
    @State private var isConstant: Bool
    @State private var matchWholeWords: Bool
    @State private var caseSensitive: Bool

    init(entry: WorldBookEntry, isNew: Bool, onSave: @escaping (WorldBookEntry) -> Void, onCancel: @escaping () -> Void) {
        self.entry = entry
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _comment = State(initialValue: entry.comment)
        _keysText = State(initialValue: entry.keys.joined(separator: ", "))
        _secondaryKeysText = State(initialValue: entry.secondaryKeys.joined(separator: ", "))
        _content = State(initialValue: entry.content)
        _position = State(initialValue: entry.position)
        _insertionOrder = State(initialValue: "\(entry.insertionOrder)")
        _isConstant = State(initialValue: entry.isConstant)
        _matchWholeWords = State(initialValue: entry.matchWholeWords)
        _caseSensitive = State(initialValue: entry.caseSensitive)
    }

    var body: some View {
        NavigationStack {
            PanelSectionList {
                Section("基本") {
                    HStack {
                        Text("备注")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("条目名称/备注", text: $comment)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("主关键词")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("逗号分隔", text: $keysText)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("次关键词")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("可选", text: $secondaryKeysText)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .listRowBackground(Theme.mainBg)

                Section("注入内容") {
                    TextEditor(text: $content)
                        .font(.system(size: Theme.F.body))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                }
                .listRowBackground(Theme.mainBg)

                Section("设置") {
                    Picker("注入位置", selection: $position) {
                        if position == .unsupported {
                            Text("不支持（不注入）").tag(WorldBookEntry.InsertionPosition.unsupported)
                        }
                        Text("助手设定前").tag(WorldBookEntry.InsertionPosition.beforeCharDef)
                        Text("助手设定后").tag(WorldBookEntry.InsertionPosition.afterCharDef)
                        Text("示例前").tag(WorldBookEntry.InsertionPosition.beforeExamples)
                        Text("示例后").tag(WorldBookEntry.InsertionPosition.afterExamples)
                        Text("对话深度").tag(WorldBookEntry.InsertionPosition.atDepth)
                        Text("作者注释前").tag(WorldBookEntry.InsertionPosition.authorNoteTop)
                        Text("作者注释后").tag(WorldBookEntry.InsertionPosition.authorNoteBot)
                    }
                    .font(.system(size: Theme.F.body))

                    HStack {
                        Text("排序")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("100", text: $insertionOrder)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }

                    Toggle("常驻", isOn: $isConstant)
                        .font(.system(size: Theme.F.body))
                    Toggle("全词匹配", isOn: $matchWholeWords)
                        .font(.system(size: Theme.F.body))
                    Toggle("大小写敏感", isOn: $caseSensitive)
                        .font(.system(size: Theme.F.body))
                }
                .listRowBackground(Theme.mainBg)
                .tint(Theme.branchIndicator)
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .toolPageBackground()
            .panelSheetTitle(isNew ? "新建条目" : "编辑条目")
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 520)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 520)
        #endif
    }

    private func save() {
        var updated = entry
        updated.comment = comment
        updated.keys = keysText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        updated.secondaryKeys = secondaryKeysText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        updated.content = content
        updated.position = position
        updated.insertionOrder = Int(insertionOrder) ?? 100
        updated.isConstant = isConstant
        updated.matchWholeWords = matchWholeWords
        updated.caseSensitive = caseSensitive
        onSave(updated)
    }
}
