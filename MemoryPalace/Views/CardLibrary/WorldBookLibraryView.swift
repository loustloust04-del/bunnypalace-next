import SwiftUI
import SwiftData

/// 卡库第二页签「世界书」（⑥，小样 04）：书目录按 全部 / 全局 / 这个楼层 / 这个对话 浏览，每本书写清具体楼层或对话，
/// 整本开关、搜索（书名 + 条目内容）、新建 / 导入；点书进 WorldBookDetailView。
/// 旧 WorldBookPanelView 保留给右栏「世界书」工具原入口，深链 `floor:` / `global:` 仍由它消费。
struct WorldBookLibraryView: View {
    var isActive = true
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(GlobalWorldBookManager.self) private var globalManager: GlobalWorldBookManager?
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    @Query(sort: \WorldBook.createdAt) private var floorBooks: [WorldBook]
    #if os(iOS)
    @Environment(\.page2AppShellTool) private var shellTool
    #endif

    @State private var scope: WorldBookScope = .all
    @State private var searchText = ""
    @State private var openBookId: String?
    @State private var revealEntryId: UUID?
    @State private var entryCache = FloorEntryCache()
    @State private var conversationTitles: [String: String] = [:]
    @State private var creating: WorldBookScope?
    @State private var newBookName = ""
    @State private var showImporter = false
    @State private var importSummary: String?
    @State private var errorMessage: String?

    private var currentProfileId: String { profileManager?.currentProfile.id ?? "" }
    private var selectedConversation: Conversation? {
        guard let conversation = viewModel?.selectedConversation, conversation.profileId == currentProfileId,
              !conversation.isTrashed else { return nil }
        return conversation
    }

    private var writer: WorldBookWriter { WorldBookWriter(context: modelContext, globals: globalManager) }

    private var items: [WorldBookListItem] {
        let order = Dictionary((profileManager?.profiles ?? []).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let globals = (globalManager?.books ?? []).map {
            WorldBookListItem(kind: .global, bookId: $0.id, name: $0.name, profileId: nil, conversationId: nil,
                              entries: $0.entries, isEnabled: $0.isEnabled)
        }
        // 当前楼层在前，其它楼层按楼层顺序；同楼层保持创建顺序
        let floors = floorBooks.enumerated().map { index, book in
            (index, WorldBookListItem(kind: .floor, bookId: book.id.uuidString, name: book.name, profileId: book.profileId,
                                      conversationId: book.scopeConversationId, entries: entryCache.entries(of: book),
                                      isEnabled: book.isEnabled))
        }
        func rank(_ item: WorldBookListItem) -> Int {
            item.profileId == currentProfileId ? -1 : (order[item.profileId ?? ""] ?? Int.max)
        }
        return globals + floors.sorted { rank($0.1) != rank($1.1) ? rank($0.1) < rank($1.1) : $0.0 < $1.0 }.map(\.1)
    }

    var body: some View {
        let all = items
        Group {
            if let openBookId, let item = all.first(where: { $0.id == openBookId }) {
                WorldBookDetailView(
                    item: item, scopeLabel: scopeLabel(item), ownerName: profileName(item.profileId),
                    isForeign: isForeign(item), selectedConversation: selectedConversation.map { ($0.id, $0.title) },
                    revealEntryId: $revealEntryId,
                    onBack: { self.openBookId = nil },
                    onSwitchFloor: { switchFloor(to: item) })
                .id(item.id)
            } else {
                directory(all)
            }
        }
        .onAppear {
            AssistantContext.shared.report(page: "worldBook")
            consume(navigator?.cardLibraryWorldBookTarget)
            peek(navigator?.pendingTarget)
        }
        .onDisappear { AssistantContext.shared.clear(page: "worldBook") }
        .onChange(of: navigator?.cardLibraryWorldBookTarget) { _, target in consume(target) }
        .onChange(of: navigator?.pendingTarget) { _, target in peek(target) }
        .onChange(of: selectedConversation?.id) { _, id in
            if id == nil && scope == .conversation { scope = .all }
        }
        .task(id: floorBooks.compactMap(\.scopeConversationId).sorted().joined(separator: ",")) { loadConversationTitles() }
        #if os(iOS)
        // 卡库在世界书页签时，page2 左上角轻点 = 退出书详情（同 CardLibraryWorkspaceView 的登记）
        .onChange(of: isActive ? openBookId != nil : nil, initial: true) { _, canGoBack in
            guard let shellTool, let canGoBack else { return }
            Page2AppBackRegistry.shared.update(shellTool, canGoBack: canGoBack) { openBookId = nil }
        }
        #endif
    }

    // MARK: - 书目录

    private func directory(_ all: [WorldBookListItem]) -> some View {
        let visible = WorldBookLibrary.search(
            WorldBookLibrary.filter(all, scope: scope, currentProfileId: currentProfileId,
                                    selectedConversationId: selectedConversation?.id),
            keyword: searchText.panelSearchKeyword)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header.padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 8) {
                    scopePicker
                    Text("当前楼层：\(profileManager?.currentProfile.name ?? "—") · 当前对话：\(selectedConversation?.title ?? "没有选中")")
                        .font(.system(size: 12)).foregroundColor(Theme.textMuted).lineLimit(2)
                    searchField
                }
                .padding(.horizontal, 16)
                CalendarTicket {
                    IOSSubLabel(text: "\(scope.rawValue) · \(visible.count) 本")
                    if visible.isEmpty {
                        Text(emptyText).font(.system(size: 14)).foregroundColor(Theme.textMuted)
                            .padding(.horizontal, IOSCal.pad).padding(.vertical, 12)
                    }
                    ForEach(visible) { item in bookRow(item) }
                    actions
                    Text("每本书单独启停。点书名进入条目，范围始终写清具体的楼层或对话。")
                        .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, IOSCal.pad).padding(.vertical, 12)
                }
            }
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.sidebarBg)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false, onCompletion: handleImport)
        .alert(creatingTitle, isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("书名", text: $newBookName)
            Button("创建") { createBook() }
            Button("取消", role: .cancel) { creating = nil }
        } message: { Text(creatingMessage) }
        .alert("导入完成", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("好的") { importSummary = nil }
        } message: { Text((importSummary ?? "") + "\n已放进这个楼层，范围可在书里改。") }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好的") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("世界书").font(.system(size: 30, weight: .bold)).foregroundColor(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("故事发生的地方，也有自己的规则").font(.system(size: 13)).foregroundColor(Theme.textMuted)
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            ForEach(WorldBookScope.allCases, id: \.self) { value in
                let on = scope == value
                let available = WorldBookLibrary.isAvailable(value, selectedConversationId: selectedConversation?.id)
                Button { scope = value } label: {
                    Text(value.rawValue)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundColor(on ? Theme.textPrimary : Theme.textMuted.opacity(available ? 1 : 0.45))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.mainBg) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .accessibilityAddTraits(on ? [.isSelected] : [])
                .accessibilityHint(available ? "" : "没有选中的对话")
            }
        }
        .padding(2)
        .background(Theme.textPrimary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.textMuted)
            TextField("搜索书名、条目", text: $searchText)
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
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyText: String {
        if searchText.panelSearchKeyword != nil { return "没有匹配的书" }
        switch scope {
        case .all: return "还没有世界书，点下面 ＋ 新建 或 导入"
        case .global: return "还没有全局世界书"
        case .floor: return "这个楼层还没有世界书"
        case .conversation: return "这个对话还没有专属的世界书"
        }
    }

    private func bookRow(_ item: WorldBookListItem) -> some View {
        let foreign = isForeign(item)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { open(item) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name.isEmpty ? "未命名" : item.name).font(.system(size: 16))
                            .foregroundColor(item.isEnabled ? Theme.textPrimary : Theme.textMuted).lineLimit(1)
                        Text(scopeLabel(item)).font(.system(size: 12)).foregroundColor(Theme.textMuted).lineLimit(1)
                        Text("\(item.entries.count) 条 · \(item.isEnabled ? "已启用" : "已停用")")
                            .font(.system(size: 11)).foregroundColor(item.isEnabled ? Theme.branchIndicator : Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开「\(item.name)」，\(scopeLabel(item))")
                Toggle("", isOn: Binding(get: { item.isEnabled }, set: { setEnabled($0, item) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.branchIndicator)
                    .disabled(foreign)
                    .accessibilityLabel("启用「\(item.name)」")
                    .accessibilityHint(foreign ? "这本书属于别的楼层，先切过去再改" : "")
                Button { open(item) } label: {
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
            IOSHairline()
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Menu {
                Button("全局世界书") { beginCreate(.global) }
                Button("这个楼层（\(profileManager?.currentProfile.name ?? "")）") { beginCreate(.floor) }
                Button(selectedConversation.map { "这个对话（\($0.title)）" } ?? "这个对话（没有选中对话）") { beginCreate(.conversation) }
                    .disabled(selectedConversation == nil)
            } label: {
                Text("＋ 新建").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.mainBg)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.branchIndicator, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("新建世界书")
            Button { showImporter = true } label: {
                Text("导入").font(.system(size: 15, weight: .medium)).foregroundColor(Theme.branchIndicator)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导入世界书 JSON")
        }
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 14)
    }

    // MARK: - 文案

    private func profileName(_ profileId: String?) -> String {
        profileManager?.profiles.first { $0.id == profileId }?.name ?? "已删除的楼层"
    }

    private func scopeLabel(_ item: WorldBookListItem) -> String {
        switch item.kind {
        case .global: return "全局 · 所有楼层"
        case .floor:
            if let conversationId = item.conversationId {
                return "对话 · " + (conversationTitles[conversationId] ?? "已不在的对话")
            }
            return "楼层 · " + profileName(item.profileId)
        }
    }

    private func isForeign(_ item: WorldBookListItem) -> Bool {
        item.kind == .floor && item.profileId != currentProfileId
    }

    private var creatingTitle: String {
        switch creating {
        case .global: "新建全局世界书"
        case .conversation: "新建对话世界书"
        default: "新建楼层世界书"
        }
    }

    private var creatingMessage: String {
        switch creating {
        case .global: "所有楼层都生效"
        case .conversation: "只在「\(selectedConversation?.title ?? "")」里生效"
        default: "只在楼层「\(profileManager?.currentProfile.name ?? "")」生效"
        }
    }

    // MARK: - 动作

    private func open(_ item: WorldBookListItem) {
        revealEntryId = nil
        openBookId = item.id
    }

    private func setEnabled(_ enabled: Bool, _ item: WorldBookListItem) {
        guard !isForeign(item) else { return }
        do { try writer.setEnabled(enabled, itemId: item.id) } catch { errorMessage = error.localizedDescription }
    }

    private func beginCreate(_ scope: WorldBookScope) {
        guard WorldBookLibrary.isAvailable(scope, selectedConversationId: selectedConversation?.id) else { return }
        newBookName = ""
        creating = scope
    }

    private func createBook() {
        let name = newBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = creating
        creating = nil
        guard !name.isEmpty, let target else { return }
        do {
            switch target {
            case .global:
                guard let book = globalManager?.create(name: name) else { return }
                openBookId = "global:\(book.id)"
            case .conversation:
                // 只用宿主真实选中的对话；没有就不建（不猜最近打开的）
                guard let conversationId = selectedConversation?.id else { return }
                openBookId = try insertFloorBook(name: name, conversationId: conversationId, entries: [], raw: nil)
            default:
                openBookId = try insertFloorBook(name: name, conversationId: nil, entries: [], raw: nil)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// 与旧面板同口径：进当前楼层，并挂到楼层的 linkedWorldBookIDs
    private func insertFloorBook(name: String, conversationId: String?, entries: [WorldBookEntry], raw: Data?) throws -> String {
        let book = WorldBook(name: name, profileId: currentProfileId, entries: entries)
        book.scopeConversationId = conversationId
        book.rawJSONData = raw
        modelContext.insert(book)
        if var profile = profileManager?.currentProfile {
            profile.linkedWorldBookIDs.append(book.id.uuidString)
            profileManager?.updateProfile(profile)
        }
        try modelContext.save()
        return "floor:\(book.id.uuidString)"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try WorldBookCodec.decodeImport(try Data(contentsOf: url))
                guard !report.entries.isEmpty else { errorMessage = "世界书没有条目"; return }
                let name = report.name ?? url.deletingPathExtension().lastPathComponent
                openBookId = try insertFloorBook(name: name, conversationId: nil, entries: report.entries, raw: report.rawJSONData)
                importSummary = report.summary
            } catch { errorMessage = error.localizedDescription }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// 跨楼层的书：先切到所属楼层（会重建 ContentView），重建后卡库凭 cardLibraryWorldBookTarget 回到这本书
    private func switchFloor(to item: WorldBookListItem) {
        guard let profile = profileManager?.profiles.first(where: { $0.id == item.profileId }) else {
            errorMessage = "这本书所属的楼层已经不在了"
            return
        }
        navigator?.cardLibraryWorldBookTarget = item.id
        navigator?.cardLibraryReturnProfileId = profile.id
        profileManager?.switchTo(profile)
    }

    private func consume(_ target: String?) {
        guard let target else { return }
        navigator?.cardLibraryWorldBookTarget = nil
        reveal(target)
    }

    /// 右栏深链（tool = "worldBook"）归旧世界书面板消费；这页正开着时只跟着打开，不置 nil
    private func peek(_ target: RightPanelNavigator.Target?) {
        guard isActive, let target, target.tool == "worldBook" else { return }
        reveal(target.id)
    }

    private func reveal(_ target: String) {
        guard let parsed = WorldBookLibrary.parseTarget(target) else { return }
        let bookId = parsed.kind == .floor ? (UUID(uuidString: parsed.bookId)?.uuidString ?? parsed.bookId) : parsed.bookId
        let itemId = (parsed.kind == .floor ? "floor:" : "global:") + bookId
        guard items.contains(where: { $0.id == itemId }) else { return }
        searchText = ""
        scope = .all
        openBookId = itemId
        revealEntryId = parsed.entryId
    }

    private func loadConversationTitles() {
        let ids = Array(Set(floorBooks.compactMap(\.scopeConversationId)))
        guard !ids.isEmpty else { conversationTitles = [:]; return }
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { ids.contains($0.id) })
        let conversations = (try? modelContext.fetch(descriptor)) ?? []
        conversationTitles = Dictionary(conversations.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    }
}

/// 按书目录行 id（`floor:<uuid>` / `global:<id>`）读写一本书；楼层书走 SwiftData，全局书走 GlobalWorldBookManager。
@MainActor
struct WorldBookWriter {
    let context: ModelContext
    let globals: GlobalWorldBookManager?

    enum Failure: LocalizedError {
        case bookMissing
        var errorDescription: String? { "这本书已经不在了" }
    }

    func floorBook(_ itemId: String) -> WorldBook? {
        guard let parsed = WorldBookLibrary.parseTarget(itemId), parsed.kind == .floor,
              let uuid = UUID(uuidString: parsed.bookId) else { return nil }
        var descriptor = FetchDescriptor<WorldBook>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func globalIndex(_ itemId: String) -> Int? {
        guard let parsed = WorldBookLibrary.parseTarget(itemId), parsed.kind == .global else { return nil }
        return globals?.books.firstIndex { $0.id == parsed.bookId }
    }

    /// nil = 书已经不在了
    func entries(of itemId: String) -> [WorldBookEntry]? {
        if let book = floorBook(itemId) { return book.entries }
        if let index = globalIndex(itemId) { return globals?.books[index].entries }
        return nil
    }

    func setEntries(_ entries: [WorldBookEntry], of itemId: String) throws {
        if let book = floorBook(itemId) {
            book.entries = entries
            try context.save()
        } else if let index = globalIndex(itemId), let globals {
            globals.updateEntries(bookId: globals.books[index].id, entries: entries)
        } else {
            throw Failure.bookMissing
        }
    }

    func setEnabled(_ enabled: Bool, itemId: String) throws {
        if let book = floorBook(itemId) {
            book.isEnabled = enabled
            book.updatedAt = Date()
            try context.save()
        } else if let index = globalIndex(itemId), let globals {
            if globals.books[index].isEnabled != enabled { globals.toggleEnabled(globals.books[index].id) }
        } else {
            throw Failure.bookMissing
        }
    }

    func rename(_ name: String, itemId: String) throws {
        if let book = floorBook(itemId) {
            book.name = name
            book.updatedAt = Date()
            try context.save()
        } else if let index = globalIndex(itemId), var book = globals?.books[index] {
            book.name = name
            globals?.update(book)
        } else {
            throw Failure.bookMissing
        }
    }

    /// 楼层书改范围：nil = 整个楼层；对话 id 只能来自宿主真实选中的对话
    func setConversation(_ conversationId: String?, itemId: String) throws {
        guard let book = floorBook(itemId) else { throw Failure.bookMissing }
        book.scopeConversationId = conversationId
        book.updatedAt = Date()
        try context.save()
    }

    func delete(itemId: String, profileManager: ProfileManager?) throws {
        if let book = floorBook(itemId) {
            let bookId = book.id.uuidString
            let ownerId = book.profileId
            context.delete(book)
            if var profile = profileManager?.profiles.first(where: { $0.id == ownerId }), profile.linkedWorldBookIDs.contains(bookId) {
                profile.linkedWorldBookIDs.removeAll { $0 == bookId }
                profileManager?.updateProfile(profile)
            }
            try context.save()
        } else if let index = globalIndex(itemId), let globals {
            globals.delete(globals.books[index])
        } else {
            throw Failure.bookMissing
        }
    }

    /// 导出用：书名 / 条目 / 原文
    func exportData(itemId: String) throws -> Data {
        if let book = floorBook(itemId) {
            return try WorldBookCodec.encodeExport(name: book.name, entries: book.entries, rawJSONData: book.rawJSONData)
        }
        if let index = globalIndex(itemId), let book = globals?.books[index] {
            return try WorldBookCodec.encodeExport(name: book.name, entries: book.entries, rawJSONData: book.rawJSONData)
        }
        throw Failure.bookMissing
    }
}
