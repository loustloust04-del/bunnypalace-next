import SwiftUI
import SwiftData
import Combine

struct CharacterWallView: View {
    var isActive = true
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    @AppStorage(CardLibraryPreferences.autoResumeKey) private var autoResume = false

    @State private var searchText = ""
    @State private var filter: WallFilter = .all
    @State private var showFileImporter = false
    @State private var showPackageImport = false
    @State private var importError: String?
    @State private var importSummary: String?
    @State private var exportingCard: CharacterCard?
    @State private var editingCard: CharacterCard?
    @State private var deletingCard: CharacterCard?
    @State private var statistics: [String: ChatSummary] = [:]
    @State private var statisticsFailed = false
    @State private var highlightedId: String?
    @State private var enteringIds: Set<String> = []
    @State private var scrollRequest: RightPanelNavigator.Target?

    private enum WallFilter: String, CaseIterable {
        // 「收藏」筛选已撤（#092 / 粟粟 10-14 拍 K5）：没有任何收藏角色卡的入口，点了永远是空的
        case all = "全部", recent = "最近"
    }

    private struct ChatSummary {
        let count: Int
        let lastOpenedAt: Date?

        var subtitle: String {
            guard let lastOpenedAt else { return "\(count) 个聊天" }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.unitsStyle = .short
            return "\(count) 个聊天 · \(formatter.localizedString(for: lastOpenedAt, relativeTo: Date()))"
        }
    }

    private typealias WallItem = CharacterWallItem

    private var profiles: [Profile] { profileManager?.profiles ?? [] }
    private var cards: [CharacterCard] { cardManager?.cards ?? [] }

    private var items: [WallItem] {
        WallItem.make(cards: cards, profiles: profiles)
    }

    private var visibleItems: [WallItem] {
        var result = items
        if let keyword = searchText.panelSearchKeyword {
            result = result.filter { item in
                if item.name.localizedStandardContains(keyword) { return true }
                guard let card = item.card else { return false }
                // 保留旧卡库搜索的正文口径；深链另外清空筛选。
                return [card.name, card.description, card.personality, card.scenario, card.firstMes,
                        card.mesExample, card.systemPrompt, card.postHistoryInstructions, card.creatorNotes]
                    .contains { $0.localizedStandardContains(keyword) }
                    || card.alternateGreetings.contains { $0.localizedStandardContains(keyword) }
            }
        }
        if filter == .recent {
            result = result.filter { lastOpenedAt($0) != nil }
                .sorted { (lastOpenedAt($0) ?? .distantPast) > (lastOpenedAt($1) ?? .distantPast) }
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    searchField
                    filters
                    if statisticsFailed {
                        Text("聊天统计暂时无法读取")
                            .font(.system(size: 12)).foregroundColor(Theme.textMuted)
                    }
                    if visibleItems.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top), GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top)], alignment: .leading, spacing: 18) {
                            ForEach(visibleItems) { item in
                                tile(item).id(item.id)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.sidebarBg)
            .onAppear {
                reloadStatistics()
                consumeTarget(navigator?.pendingTarget)
                AssistantContext.shared.report(page: "cardLibrary")
            }
            .onDisappear {
                highlightedId = nil
                AssistantContext.shared.clear(page: "cardLibrary")
            }
            .onChange(of: isActive) { _, active in
                if active {
                    reloadStatistics()
                    consumeTarget(navigator?.pendingTarget)
                }
            }
            .onChange(of: navigator?.pendingTarget) { _, target in consumeTarget(target) }
            .task(id: scrollRequest) {
                guard let request = scrollRequest else { return }
                // 先让清词／解除筛选后的网格落地，再滚动；离页时自动取消高亮任务。
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(request.id, anchor: .center)
                    highlightedId = request.id
                }
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                highlightedId = nil
                scrollRequest = nil
            }
        }
        .onChange(of: profiles.map(\.id)) { _, _ in reloadStatistics() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in reloadStatistics() }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .png], allowsMultipleSelection: false, onCompletion: handleImport)
        // 第二批收尾：长按「导出」进 B7 导出小票（同角色页入口）；只有没进楼层的卡有这个菜单，没有楼层
        .sheet(item: $exportingCard) { CardExportTicketView(card: $0, isLibraryCard: true, profile: nil) }
        .sheet(isPresented: $showPackageImport) { SillyTavernImportFlowView() }
        .alert("导入完成", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("好的") { importSummary = nil }
        } message: { Text(importSummary ?? "") }
        .alert("操作失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好的") { importError = nil }
        } message: { Text(importError ?? "") }
        .sheet(item: $editingCard) { card in
            CharacterCardEditor(card: card) { updated in
                try cardManager?.update(updated)
                editingCard = nil
            } onCancel: { editingCard = nil }
        }
        .confirmationDialog("删除角色卡", isPresented: Binding(get: { deletingCard != nil }, set: { if !$0 { deletingCard = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let card = deletingCard {
                    do { try cardManager?.delete(card) }
                    catch { importError = error.localizedDescription }
                }
                deletingCard = nil
            }
            Button("取消", role: .cancel) { deletingCard = nil }
        } message: {
            if let card = deletingCard { Text("确定要从卡库删除「\(card.name)」吗？已创建的楼层不受影响。") }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("角色").font(.system(size: 30, weight: .bold)).foregroundColor(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("你的故事，都在这里").font(.system(size: 13)).foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 8)
            Menu {
                Button("导入角色卡", systemImage: "square.and.arrow.down") { showFileImporter = true }
                Button("导入酒馆整包", systemImage: "archivebox") { showPackageImport = true }
                Button("新建空白角色（即将支持）", systemImage: "plus.rectangle") {}.disabled(true)
            } label: {
                Image(systemName: "plus").font(.system(size: 21))
                    .foregroundColor(Theme.branchIndicator)
                    .frame(width: 44, height: 44)
                    .background(Theme.mainBg, in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("添加角色")
        }
    }

    private var searchField: some View {
        // 沿用 PanelSearchField 的构成，底色改用主题纸色以适配深色。
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.textMuted)
            TextField("搜索角色", text: $searchText)
                .textFieldStyle(.plain).foregroundColor(Theme.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textMuted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("清空搜索")
            }
        }
        .font(.system(size: 14))
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(minHeight: 44)
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 12))
    }

    private var filters: some View {
        HStack(spacing: 8) {
            ForEach(WallFilter.allCases, id: \.self) { value in
                Button { filter = value } label: {
                    Text(value.rawValue).font(.system(size: 13, weight: filter == value ? .semibold : .regular))
                        .foregroundColor(filter == value ? Theme.branchIndicator : Theme.textMuted)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(filter == value ? Theme.accent : Theme.mainBg, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == value ? [.isSelected] : [])
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(searchText.panelSearchKeyword != nil ? "没有匹配的角色" : (filter == .recent ? "还没有最近打开的聊天" : "还没有角色"))
                .font(.system(size: 14)).foregroundColor(Theme.textMuted)
            if filter == .all && searchText.panelSearchKeyword == nil {
                Button("导入角色卡") { showFileImporter = true }
                    .tint(Theme.branchIndicator).frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func tile(_ item: WallItem) -> some View {
        Button {
            guard !enteringIds.contains(item.id) else { return }
            if let card = item.card, let cardManager, let profileManager, let presetManager {
                enteringIds.insert(item.id)
                Task { @MainActor in
                    defer { enteringIds.remove(item.id) }
                    do {
                        let profile = try await cardManager.floors(profileManager: profileManager, presetManager: presetManager).enter(card: card)
                        navigator?.openCharacterHome(profileId: profile.id, cardId: card.id, autoResume: autoResume)
                    } catch { importError = error.localizedDescription }
                }
            } else if let profile = item.profile {
                navigator?.openCharacterHome(profileId: profile.id, cardId: nil, autoResume: autoResume)
                profileManager?.switchTo(profile)
            }
        } label: {
            CharacterCoverTile(name: item.name, imageData: item.imageData,
                               subtitle: subtitle(item),
                               isCurrent: item.profile != nil && item.profile?.id == profileManager?.currentProfile.id,
                               hasWorldBook: item.hasWorldBook, hasRegex: item.hasRegex,
                               hasScripts: (item.card?.scriptCount ?? 0) > 0,
                               highlighted: highlightedId == item.id,
                               isSample: item.card?.id == CardSample.id)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let card = item.card {
                if card.bindingState == .unbound {
                    Button("编辑卡", systemImage: "pencil") { editingCard = card }
                    Button("导出", systemImage: "square.and.arrow.up") { exportingCard = card }
                    Button("删除", systemImage: "trash", role: .destructive) { deletingCard = card }
                } else {
                    Button("归档", systemImage: "archivebox") {
                        var archived = card
                        archived.archivedAt = Date()
                        do { try cardManager?.update(archived) }
                        catch { importError = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func subtitle(_ item: WallItem) -> String {
        if let card = item.card {
            if card.bindingState == .missing || (card.bindingState == .active && item.profile == nil) { return "楼层不见了" }
            if card.bindingState == .unbound { return "还没开始" }
        }
        return item.profile.flatMap { statistics[$0.id]?.subtitle } ?? "聊天统计待更新"
    }

    private func lastOpenedAt(_ item: WallItem) -> Date? {
        item.profile.flatMap { statistics[$0.id]?.lastOpenedAt }
    }

    private func reloadStatistics() {
        guard isActive else { return }
        var summaries: [String: ChatSummary] = [:]
        var failed = false
        for profile in profiles {
            let profileId = profile.id
            let predicate = #Predicate<Conversation> { $0.profileId == profileId && !$0.isTrashed }
            do {
                let count = try modelContext.fetchCount(FetchDescriptor<Conversation>(predicate: predicate))
                var latest = FetchDescriptor<Conversation>(predicate: predicate, sortBy: [SortDescriptor(\Conversation.lastOpenedAt, order: .reverse)])
                latest.fetchLimit = 1
                summaries[profileId] = ChatSummary(count: count, lastOpenedAt: try modelContext.fetch(latest).first?.lastOpenedAt)
            } catch { failed = true }
        }
        statistics = summaries
        statisticsFailed = failed
    }

    private func consumeTarget(_ target: RightPanelNavigator.Target?) {
        guard isActive, let target, target.tool == "cardLibrary",
              target.id != RightPanelNavigator.cardLibrarySettingsTargetId else { return }
        searchText = ""
        filter = .all
        // 定位只滚动高亮，不触发进入或物化。
        let item = items.first { $0.id == target.id }
        if let item { scrollRequest = .init(tool: target.tool, id: item.id) }
        navigator?.pendingTarget = nil
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                if let card = try cardManager?.importFromFile(url: url), card.hasWorldBook {
                    importSummary = try card.decodeWorldBook().summary
                }
            }
            catch { importError = error.localizedDescription }
        case .failure(let error): importError = error.localizedDescription
        }
    }
}
