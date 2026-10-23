import SwiftUI

// MARK: - Card Library Panel (右栏卡库 Tab)

struct CardLibraryPanelView: View {
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var importSummary: String?
    @State private var exportingCard: CharacterCard?
    @State private var expandedCardId: String?
    @State private var deletingCard: CharacterCard?
    @State private var editingCard: CharacterCard?
    @State private var highlightedId: String? = nil
    @State private var searchText = ""
    @State private var pendingScrollId: String? = nil

    private var cards: [CharacterCard] {
        cardManager?.cards.filter { $0.archivedAt == nil } ?? []
    }

    /// 口径同 `SearchService.searchCharacterCards` 的字段集（名字 / 简介 / 设定 / 开场 / 示例 / prompt / 备注 / 备选开场）
    private var visibleCards: [CharacterCard] {
        guard let kw = searchText.panelSearchKeyword else { return cards }
        return cards.filter { card in
            [card.name, card.description, card.personality, card.scenario, card.firstMes, card.mesExample,
             card.systemPrompt, card.postHistoryInstructions, card.creatorNotes]
                .contains { $0.localizedStandardContains(kw) }
                || card.alternateGreetings.contains { $0.localizedStandardContains(kw) }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
        if !cards.isEmpty {
            PanelSearchField(prompt: "搜索模板", text: $searchText)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        PanelSectionList {
            if cards.isEmpty {
                Section {
                    emptyState
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if visibleCards.isEmpty {
                Section {
                    PanelNoMatchView()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(visibleCards) { card in
                        cardRow(card)
                            .id(card.id)
                            #if os(macOS)
                            // mac 分组卡里 listRowBackground 不生效，跳转高亮直接垫在行底
                            .background(highlightFill(card.id).padding(-6))
                            #else
                            .listRowBackground(highlightFill(card.id))
                            #endif
                    }
                } header: {
                    HStack {
                        Text("自定义助手模板库")
                        Spacer()
                        Text(searchText.panelSearchKeyword == nil ? "\(cards.count) 张" : "\(visibleCards.count)/\(cards.count) 张")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                        Button { showFileImporter = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.branchIndicator)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Theme.branchIndicator.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowSeparator(.hidden)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.plain)
        #endif
        .scrollContentBackground(.hidden)
        .toolPageBackground()
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json, .png],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .modifier(CharacterCardJSONExporter(card: $exportingCard))
        .alert("导入完成", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("好的") { importSummary = nil }
        } message: { Text(importSummary ?? "") }
        .alert("操作失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好的") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog(
            deletingCard?.bindingState == .unbound ? "删除角色卡" : "归档角色卡",
            isPresented: Binding(
                get: { deletingCard != nil },
                set: { if !$0 { deletingCard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(deletingCard?.bindingState == .unbound ? "删除" : "归档", role: .destructive) {
                if let card = deletingCard {
                    do { try cardManager?.delete(card) }
                    catch { importError = error.localizedDescription }
                }
                deletingCard = nil
            }
            Button("取消", role: .cancel) { deletingCard = nil }
        } message: {
            if let card = deletingCard {
                Text(card.bindingState == .unbound ? "确定要从卡库删除「\(card.name)」吗？" : "归档「\(card.name)」后在卡墙隐藏，楼层和聊天保留。")
            }
        }
        .sheet(item: $editingCard) { card in
            CharacterCardEditor(card: card) { updated in
                try cardManager?.update(updated)
                editingCard = nil
            } onCancel: {
                editingCard = nil
            }
        }
        .onAppear { consumeTarget(navigator?.pendingTarget, proxy: proxy) }
        .onAppear { AssistantContext.shared.report(page: "cardLibrary") }
        .onDisappear { AssistantContext.shared.clear(page: "cardLibrary") }
        .onChange(of: navigator?.pendingTarget) { _, target in
            consumeTarget(target, proxy: proxy)
        }
        .onChange(of: searchText) { _, text in
            guard text.isEmpty, let id = pendingScrollId else { return }
            pendingScrollId = nil
            DispatchQueue.main.async { scrollToCard(id, proxy: proxy) }
        }
        } // end VStack
        } // end ScrollViewReader
    }

    private func consumeTarget(_ target: RightPanelNavigator.Target?, proxy: ScrollViewProxy) {
        guard let t = target, t.tool == "cardLibrary" else { return }
        if searchText.isEmpty {
            scrollToCard(t.id, proxy: proxy)
        } else {
            // 目标可能被搜索词滤掉：先清词，等 onChange(searchText) 那一轮列表重建完再滚
            pendingScrollId = t.id
            searchText = ""
        }
        highlightedId = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if highlightedId == t.id { highlightedId = nil }
        }
        navigator?.pendingTarget = nil
    }

    private func scrollToCard(_ id: String, proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func highlightFill(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(highlightedId == id ? Theme.branchIndicator.opacity(0.3) : Color.clear)
            .animation(.easeInOut(duration: 0.35), value: highlightedId)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 24))
                .foregroundColor(Theme.textMuted.opacity(0.4))
            Text("卡库是空的")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
            Button {
                showFileImporter = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10))
                    Text("导入自定义助手模板")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                }
                .foregroundColor(Theme.branchIndicator)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.branchIndicator.opacity(0.12)))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Card Row

    private func cardRow(_ card: CharacterCard) -> some View {
        let isExpanded = expandedCardId == card.id

        return VStack(alignment: .leading, spacing: 0) {
            // 主行
            HStack(spacing: 8) {
                if let imgData = card.coverImageData, let coverImage = platformImage(from: imgData) {
                    coverImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.branchIndicator.opacity(0.15))
                        .frame(width: 32, height: 32)
                        .overlay(Text("🎭").font(.system(size: 16)))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name)
                        .font(.system(size: Theme.F.body, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if card.hasWorldBook {
                            metaLabel("📖 \(card.worldBookEntryCount)条")
                        }
                        if !card.alternateGreetings.isEmpty {
                            metaLabel("💬 \(card.alternateGreetings.count + 1)")
                        }
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedCardId = isExpanded ? nil : card.id
                }
            }

            // 展开详情
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !card.description.isEmpty {
                        Text(String(card.description.prefix(200)) + (card.description.count > 200 ? "…" : ""))
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(5)
                    }

                    if !card.creatorNotes.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "text.quote")
                                .font(.system(size: 8))
                            Text(card.creatorNotes)
                                .font(.system(size: Theme.F.caption))
                                .lineLimit(3)
                        }
                        .foregroundColor(Theme.textMuted)
                    }

                    HStack(spacing: 8) {
                        Button {
                            enterFloor(from: card)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.square")
                                    .font(.system(size: 9))
                                Text("进入角色")
                                    .font(.system(size: Theme.F.secondary, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.branchIndicator))
                        }
                        .buttonStyle(.plain)

                        Button { editingCard = card } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "pencil").font(.system(size: 9))
                                Text("编辑").font(.system(size: Theme.F.secondary))
                            }
                            .foregroundColor(Theme.branchIndicator)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                        }
                        .buttonStyle(.plain)

                        Button { deletingCard = card } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "trash").font(.system(size: 9))
                                Text(card.bindingState == .unbound ? "删除" : "归档").font(.system(size: Theme.F.secondary))
                            }
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.red.opacity(0.08)))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .listRowBackground(Theme.mainBg)
        .contextMenu {
            Button("导出 JSON", systemImage: "square.and.arrow.up") { exportingCard = card }
        }
    }

    // MARK: - Helpers

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textMuted)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                if let card = try cardManager?.importFromFile(url: url), card.hasWorldBook {
                    importSummary = try card.decodeWorldBook().summary
                }
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func enterFloor(from card: CharacterCard) {
        guard let profileManager, let presetManager, let cardManager else { return }
        Task { @MainActor in
            do {
                let profile = try await cardManager.floors(profileManager: profileManager, presetManager: presetManager).enter(card: card)
                navigator?.openCharacterHome(profileId: profile.id, cardId: card.id)
            } catch { importError = error.localizedDescription }
        }
    }

    private func platformImage(from data: Data) -> Image? {
        #if os(macOS)
        guard let img = NSImage(data: data) else { return nil }
        return Image(nsImage: img)
        #else
        guard let img = UIImage(data: data) else { return nil }
        return Image(uiImage: img)
        #endif
    }
}
