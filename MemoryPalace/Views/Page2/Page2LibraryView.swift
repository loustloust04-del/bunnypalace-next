#if os(iOS)
import SwiftUI

struct Page2LibraryView: View {
    var addingToHome = false
    var isActive = true
    var onOpen: (String) -> Void
    var onAdd: (RightPanelTool) -> Void
    var onBeginDrag: () -> Void = {}
    @Environment(RightPanelToolManager.self) private var manager: RightPanelToolManager?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.page2Date) private var date
    @State private var appearance = Page2AppearanceStore.shared
    @State private var search = ""
    @State private var listsApps = false
    @State private var expanded: Category?
    @FocusState private var searching: Bool
    @Namespace private var categoryZoom
    private struct Category: Identifiable {
        let title: String
        let ids: [String]
        var id: String { title }
    }
    private let categories = [
        Category(title: "生活", ids: ["calendar", "health"] + Self.debugAppIds(["topicBox"]) + ["sticker"]),
        Category(title: "阅读与学习", ids: ["vocab", "reading"] + Self.debugAppIds(["audiobook"]) + ["study", "memory"]),
        Category(title: "创作与资料", ids: ["worldBook", "cardLibrary", "prompt", "fileLibrary"]),
        Category(title: "工具", ids: Self.toolIds)
    ]
    private static var toolIds: [String] { ["browser", "ccTerminal", "cssChat"] }
    /// 话题盒 / 有声书只进粟粟的 Debug 包（#096）
    private static func debugAppIds(_ ids: [String]) -> [String] {
        return []
    }
    private var tools: [RightPanelTool] { manager?.pinnedTools ?? [] }
    private var shownCategories: [Category] {
        let known = Set(categories.flatMap(\.ids))
        let others = tools.filter { !known.contains($0.id) }.map(\.id)
        return (categories + (others.isEmpty ? [] : [Category(title: "其他", ids: others)]))
            .filter { !members($0).isEmpty }
    }
    private func ordered(_ tools: [RightPanelTool]) -> [RightPanelTool] {
        let keyed: [(tool: RightPanelTool, key: Page2LibraryNameKey)] = tools.map { ($0, Page2LibraryNameKey($0.name)) }
        let sorted = keyed.sorted { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return lhs.tool.id < rhs.tool.id
        }
        return sorted.map { $0.tool }
    }
    private var results: [RightPanelTool] {
        let query = Page2LibraryNameKey(search).latin
        return ordered(tools).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || Page2LibraryNameKey($0.name).latin.contains(query)
        }
    }
    private func members(_ category: Category) -> [RightPanelTool] { tools.filter { category.ids.contains($0.id) } }
    private var animation: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9) }
    private var scheme: ColorScheme { appearance.displayed.isLightBackdrop ? .light : .dark }

    var body: some View {
        GeometryReader { geometry in
            let metrics = Page2SystemMetrics(width: geometry.size.width, height: geometry.size.height)
            let margin = max(24, (geometry.size.width - metrics.contentWidth) / 2)
            ZStack {
                if let expanded {
                    expandedCategory(expanded, metrics: metrics, height: geometry.size.height)
                } else {
                    VStack(spacing: listsApps ? 24 : 32) {
                        searchBar
                        if listsApps {
                            Page2LibraryResults(tools: results, showIndex: search.isEmpty, margin: margin, date: date, scheme: scheme,
                                                onOpen: activate, onAdd: onAdd, onBeginDrag: onBeginDrag)
                                .padding(.horizontal, -margin)
                        } else {
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: metrics.horizontalGap), GridItem(.flexible())], spacing: 24) {
                                    ForEach(shownCategories) { category in
                                        categoryTile(category, side: metrics.small, iconSide: metrics.iconSide)
                                    }
                                }.padding(.bottom, 24)
                            }.scrollIndicators(.hidden)
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.top, addingToHome ? 12 : 32)
                    .transition(.opacity)
                }
            }
            .foregroundStyle(scheme == .dark ? Color.white : Color.black.opacity(0.8))
            .environment(\.colorScheme, scheme)
            .animation(animation, value: listsApps)
            .animation(animation, value: expanded?.id)
            .onChange(of: searching) { _, active in if active { listsApps = true } }
            .onChange(of: isActive) { _, active in
                if !active { searching = false; search = ""; listsApps = false; expanded = nil }
            }
            .onChange(of: tools.map(\.id)) { _, _ in
                if let expanded, members(expanded).isEmpty { self.expanded = nil }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                if !listsApps { Spacer(minLength: 0) }
                Image(systemName: "magnifyingglass").font(.system(size: 19))
                TextField("App 资源库", text: $search, prompt: Text("App 资源库").foregroundColor(scheme == .dark ? .white.opacity(0.8) : .black.opacity(0.55)))
                    .focused($searching).submitLabel(.search).font(.system(size: 19))
                    .frame(maxWidth: listsApps ? .infinity : 115)
                    .autocorrectionDisabled()
                if !listsApps { Spacer(minLength: 0) }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background { Color.clear.glassEffect(.clear, in: .capsule).allowsHitTesting(false) }
            if listsApps {
                Button("取消") { searching = false; search = ""; listsApps = false }.font(.system(size: 17))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }.buttonStyle(.plain)
    }

    private func categoryTile(_ category: Category, side: CGFloat, iconSide: CGFloat) -> some View {
        let entries = members(category)
        let gap = max(0, side - iconSide * 2 - 28)
        return VStack(spacing: 7) {
            Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                GridRow { librarySlot(entries, index: 0, side: iconSide); librarySlot(entries, index: 1, side: iconSide) }
                GridRow {
                    librarySlot(entries, index: 2, side: iconSide)
                    Button { searching = false; expanded = category } label: {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(iconSide * 0.4), spacing: iconSide * 0.1), count: 2), spacing: iconSide * 0.1) {
                            ForEach(entries.dropFirst(3).prefix(4)) { tool in
                                Page2AppIcon(tool: tool, side: iconSide * 0.4, label: false, followsIconSize: false, interactive: false, decorative: true)
                                    .matchedGeometryEffect(id: tool.id, in: categoryZoom)
                            }
                        }.frame(width: iconSide, height: iconSide, alignment: .top)
                            .padding(.top, iconSide * 0.05)
                            .frame(width: iconSide, height: iconSide)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("打开\(category.title)")
                    .accessibilityIdentifier("page2.library-category.\(category.id)")
                }
            }
            .frame(width: side, height: side)
            .background { Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 30)).allowsHitTesting(false) }
            Text(category.title).font(.system(size: 12)).modifier(Page2DesktopLabel())
        }
    }
    @ViewBuilder private func librarySlot(_ entries: [RightPanelTool], index: Int, side: CGFloat) -> some View {
        if entries.indices.contains(index) { icon(entries[index], side: side) }
        else { Color.clear.frame(width: side, height: side) }
    }
    private func expandedCategory(_ category: Category, metrics: Page2SystemMetrics, height: CGFloat) -> some View {
        let entries = ordered(members(category))
        let rows = max(1, (entries.count + 3) / 4)
        let rowHeight: CGFloat = 92
        let contentHeight = rowHeight + CGFloat(rows - 1) * metrics.rowPitch
        return ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { expanded = nil }
            VStack(alignment: .leading, spacing: 44) {
                Text(category.title).font(.system(size: 32, weight: .bold)).modifier(Page2DesktopLabel())
                    .frame(height: 38, alignment: .leading).padding(.horizontal, 4)
                    .accessibilityIdentifier("page2.library-title")
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: metrics.horizontalGap), count: 4), spacing: metrics.rowPitch - rowHeight) {
                        ForEach(entries) { tool in
                            Button { activate(tool) } label: {
                                VStack(spacing: 3) {
                                    Page2AppIcon(tool: tool, side: metrics.iconSide, label: false, followsIconSize: false, interactive: false, decorative: true)
                                        .matchedGeometryEffect(id: tool.id, in: categoryZoom)
                                    Text(tool.name).font(.system(size: 12)).lineLimit(1).modifier(Page2DesktopLabel())
                                        .frame(width: metrics.columnPitch + 8, height: 20)
                                }.frame(width: metrics.columnWidth, height: rowHeight, alignment: .top).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tool.name).accessibilityIdentifier("page2.app.\(tool.id)")
                            .contextMenu { Button("添加到主屏", systemImage: "plus.app") { onAdd(tool) } }
                            .onDrag { onBeginDrag(); return NSItemProvider(object: "library:\(tool.id)" as NSString) }
                        }
                    }
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { expanded = nil } }
                }
                .scrollIndicators(.hidden)
                .frame(height: min(contentHeight, max(92, height - 178)))
                .accessibilityIdentifier("page2.library-expanded-grid")
            }
            .frame(width: metrics.contentWidth)
            .offset(y: 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page2.library-expanded")
        .accessibilityAction(.escape) { expanded = nil }
        .transition(.opacity)
    }
    private func activate(_ tool: RightPanelTool) {
        searching = false
        if addingToHome { onAdd(tool) } else { onOpen(tool.id) }
    }
    private func icon(_ tool: RightPanelTool, side: CGFloat) -> some View {
        Page2AppIcon(tool: tool, side: side, label: false, followsIconSize: false) { activate(tool) }
            .matchedGeometryEffect(id: tool.id, in: categoryZoom)
            .onDrag { onBeginDrag(); return NSItemProvider(object: "library:\(tool.id)" as NSString) }
            .contextMenu { Button("添加到主屏", systemImage: "plus.app") { onAdd(tool) } }
            .accessibilityAction(named: "添加到主屏") { onAdd(tool) }
    }
}

enum Page2WidgetCatalog {
    static let independent = ["pet", "todo", "garden", "contacts", "plan"]
    static func name(_ kind: String) -> String {
        switch kind {
        case "pet": return "宠物"
        case "todo": return "待办"
        case "garden": return "记忆花园"
        case "contacts": return "通讯录"
        case "plan": return "今日安排"
        default: return RightPanelToolManager.builtInTools.first { $0.id == kind }?.name ?? "未识别组件"
        }
    }
    static func sample(_ kind: String) -> String {
        switch kind {
        case "pet": return "今天也在这里陪你"
        case "todo", "plan": return "读完这一章\n整理今天的摘录"
        case "memory", "garden": return "记住生活里的小事"
        case "contacts": return "你和助手的资料卡"
        case "vocab": return "serendipity\n意外发现的美好"
        case "reading": return "从上次停下的地方，继续阅读"
        default: return "\(name(kind))的最新内容与快捷入口"
        }
    }
}

struct Page2WidgetGallery: View {
    var requiredSpan: Page2Span? = nil
    var onAdd: (Page2Item) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(RightPanelToolManager.self) private var manager: RightPanelToolManager?
    @State private var search = ""
    @State private var size = Page2Span.small
    private var kinds: [String] {
        (Page2WidgetCatalog.independent + (manager?.pinnedTools.map(\.id) ?? []))
            .filter { search.isEmpty || Page2WidgetCatalog.name($0).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if requiredSpan == nil {
                        Picker("尺寸", selection: $size) {
                            ForEach(Page2Span.widgetSizes, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                    ForEach(kinds, id: \.self) { kind in
                        Button { onAdd(.widget(kind, span: requiredSpan ?? size)) } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(Page2WidgetCatalog.name(kind)).font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(Page2VisualStyle.sage)
                            }
                            Text(Page2WidgetCatalog.sample(kind)).font(.body).multilineTextAlignment(.leading)
                            Text("示例预览 · 添加后显示你的内容").font(.caption2).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: 24))
                        .foregroundStyle(.primary)
                        .accessibilityLabel("添加\(Page2WidgetCatalog.name(kind))\((requiredSpan ?? size).title)组件")
                        .accessibilityIdentifier("page2.widget-add.\(kind)")
                    }
                }.padding(20)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page2.widget-gallery")
            .navigationTitle("小组件").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索小组件")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct Page2ContainerEditor: View {
    let containerID: UUID
    var onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @State private var home = Page2HomeStore.shared
    @State private var name = ""
    private var item: Page2Item? { home.layout.item(containerID) }
    var body: some View {
        NavigationStack {
            List {
                Section("名称") {
                    TextField("名称", text: $name).onSubmit { home.rename(containerID, title: name) }
                }
                Section("内容") {
                    ForEach(item?.children ?? [], id: \.self) { id in
                        if let child = home.layout.item(id) {
                            HStack {
                                Button {
                                    if let tool = child.toolID { dismiss(); onOpen(tool) }
                                } label: { Text(tools?.tool(byId: child.toolID ?? "")?.name ?? Page2WidgetCatalog.name(child.widgetKind ?? "")) }
                                Spacer()
                                Button("移到主屏") { home.extract(id, from: containerID) }.font(.caption)
                            }
                        }
                    }
                    .onMove { home.reorderChildren(containerID, from: $0, to: $1) }
                    .onDelete { indices in
                        let ids = indices.compactMap { item?.children[$0] }
                        ids.forEach { home.remove($0) }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(item?.title ?? "主屏内容").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { home.rename(containerID, title: name); dismiss() } } }
            .onAppear { name = item?.title ?? "" }
            .onChange(of: item == nil) { _, gone in if gone { dismiss() } }
        }
    }
}

struct Page2PagesEditor: View {
    let capacity: String
    let currentID: UUID
    var onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @State private var home = Page2HomeStore.shared
    @State private var appearance = Page2AppearanceStore.shared
    private var board: Page2Board? { home.layout.boards.first { $0.capacityKey == capacity } }

    var body: some View {
        VStack(spacing: 20) {
            HStack { Spacer(); Button("完成") { dismiss() }.buttonStyle(.glass) }.padding(.horizontal, 24)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 26) {
                    ForEach(Array((board?.pages ?? []).enumerated()), id: \.element.id) { index, page in
                        VStack(spacing: 12) {
                            thumbnail(page)
                                .aspectRatio(0.49, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(page.id == currentID ? 0.9 : 0.25), lineWidth: page.id == currentID ? 2 : 0.5))
                                .onTapGesture { if !page.isHidden { onSelect(page.id); dismiss() } }
                                .draggable(page.id.uuidString)
                                .dropDestination(for: String.self) { ids, _ in
                                    guard let value = ids.first, let source = UUID(uuidString: value),
                                          var pages = board?.pages,
                                          let from = pages.firstIndex(where: { $0.id == source }),
                                          let to = pages.firstIndex(where: { $0.id == page.id }) else { return false }
                                    pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                                    home.updatePages(pages, capacity: capacity)
                                    return true
                                }
                            Button { toggle(page) } label: {
                                Image(systemName: page.isHidden ? "circle" : "checkmark.circle.fill").font(.system(size: 24))
                                    .symbolRenderingMode(.hierarchical).frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel("第\(index + 1)页，\(page.isHidden ? "隐藏" : "显示")")
                        }
                        .accessibilityAction(named: "前移页面") { move(page, by: -1) }
                        .accessibilityAction(named: "后移页面") { move(page, by: 1) }
                    }
                }.padding(.horizontal, 44).padding(.vertical, 20)
            }
        }
        .padding(.top, 12)
        .background(.ultraThinMaterial)
        .presentationBackground(.clear)
    }
    private func thumbnail(_ page: Page2Page) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Page2WallpaperView(appearance: appearance.displayed)
                if let board {
                    let x = geometry.size.width / CGFloat(board.columns)
                    let y = geometry.size.height * 0.8 / CGFloat(board.rows)
                    ForEach(board.placements.filter { $0.pageID == page.id }) { position in
                        if let item = home.layout.item(position.id) {
                            ZStack {
                                RoundedRectangle(cornerRadius: item.kind == "app" ? 5 : 9).fill(.white.opacity(0.3))
                                if let tool = tools?.tool(byId: item.toolID ?? "") { AppIconView(name: tool.icon, size: 9, tint: .white, toolID: tool.id) }
                            }
                            .frame(width: CGFloat(item.span.columns) * x - 6, height: CGFloat(item.span.rows) * y - 8)
                            .position(x: (CGFloat(position.column) + CGFloat(item.span.columns) / 2) * x,
                                      y: 10 + (CGFloat(position.row) + CGFloat(item.span.rows) / 2) * y)
                        }
                    }
                }
            }
        }
    }
    private func toggle(_ page: Page2Page) {
        guard var pages = board?.pages, let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[index].isHidden.toggle()
        home.updatePages(pages, capacity: capacity)
    }
    private func move(_ page: Page2Page, by offset: Int) {
        guard var pages = board?.pages, let from = pages.firstIndex(where: { $0.id == page.id }), pages.indices.contains(from + offset) else { return }
        pages.swapAt(from, from + offset)
        home.updatePages(pages, capacity: capacity)
    }
}

#endif
