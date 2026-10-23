import Foundation
import Observation

@MainActor
@Observable
final class Page2HomeStore {
    static let shared: Page2HomeStore = {
        #if DEBUG || PERF_BENCH
        if ProcessInfo.processInfo.arguments.contains("page2-ui-test") {
            let defaults = UserDefaults(suiteName: "page2-ui-test")!
            defaults.set(Data("[]".utf8), forKey: "dashboardWidgets_v2")
            let requested = ProcessInfo.processInfo.environment["PAGE2_UI_LAYOUT_CASE"] ?? UUID().uuidString
            let caseID = requested.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let store = Page2HomeStore(defaults: defaults, fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("page2-ui-\(caseID).json"))
            guard !store.isInitialized else { return store }
            store.bootstrap(toolIDs: [], dockIDs: ["calendar", "memory", "vocab", "reading"])
            if let pair = ProcessInfo.processInfo.environment["PAGE2_UI_WIDGET_PAIR"]?.split(separator: "-").map(String.init), pair.count == 2 {
                func span(_ name: String) -> Page2Span { name == "large" ? .large : (name == "medium" ? .medium : .small) }
                let source = Page2Item.widget("todo", span: span(pair[0]))
                let target = Page2Item.widget("calendar", span: span(pair[1]))
                var candidate = store.layout
                candidate.items += [source, target]
                let page = candidate.boards[0].pages[0].id
                let sideBySide = source.span == .small && target.span == .small
                let sourcePage = source.span.rows + target.span.rows > 6 ? candidate.boards[0].appendPage() : page
                candidate.boards[0].placements = [.init(id: target.id, pageID: page, row: 0, column: 0),
                    .init(id: source.id, pageID: sourcePage, row: sideBySide || sourcePage != page ? 0 : target.span.rows, column: sideBySide ? 2 : 0)]
                _ = store.save(candidate, keepUndo: false)
                return store
            }
            _ = store.insert(.widget("todo", span: ProcessInfo.processInfo.environment["PAGE2_UI_LARGE_WIDGET"] == "1" ? .large : .small), capacity: "4x6")
            if ProcessInfo.processInfo.environment["PAGE2_UI_STACK"] == "1", let first = store.layout.rootItems.first {
                let second = Page2Item.widget("calendar", span: first.span)
                _ = store.insert(second, capacity: "4x6")
                _ = store.combine(second.id, with: first.id)
                if let stack = store.layout.rootItems.first(where: { $0.kind == "stack" }) {
                    store.configure(stack.id, values: ["smartRotate": "false", "widgetSuggestions": "false", "activeChild": first.id.uuidString])
                }
            }
            if ProcessInfo.processInfo.environment["PAGE2_UI_FOLDER_NINE"] == "1" {
                let apps = ["calendar", "memory", "worldBook", "cardLibrary", "vocab", "reading", "topicBox", "calendar", "memory"].map(Page2Item.app)
                for app in apps { _ = store.insert(app, capacity: "4x6") }
                _ = store.combine(apps[1].id, with: apps[0].id)
                if let folder = store.layout.rootItems.first(where: { $0.kind == "folder" }) {
                    for app in apps.dropFirst(2) { _ = store.combine(app.id, with: folder.id) }
                    store.rename(folder.id, title: "九个应用")
                }
                _ = store.insert(.app("health"), capacity: "4x6")
                return store
            }
            for tool in ["calendar", "memory", "worldBook", "cardLibrary", "vocab", "reading", "topicBox", "health"] {
                _ = store.insert(.app(tool), capacity: "4x6")
            }
            return store
        }
        #endif
        return Page2HomeStore()
    }()

    private(set) var layout = Page2Layout()
    private(set) var previousLayout: Page2Layout?
    private(set) var isInitialized = false
    var errorMessage: String?
    private(set) var recoveryRequired = false
    private let defaults: UserDefaults
    private let fileURL: URL
    private let writeData: (Data, URL) throws -> Void

    init(defaults: UserDefaults = .standard, fileURL: URL? = nil,
         writeData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.defaults = defaults
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace/Page2/home-layout-v1.json")
        self.writeData = writeData
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let data = try Data(contentsOf: self.fileURL)
                var saved = try JSONDecoder().decode(Page2Layout.self, from: data)
                saved.materializeDock()
                guard Page2GridEngine.validate(saved) else { throw Page2GridError.invalidLayout }
                layout = saved
                isInitialized = true
            } catch {
                recoveryRequired = true
                errorMessage = "主屏存档暂时无法读取，原文件已保留。可以重试读取，或备份后恢复旧桌面。"
            }
        }
    }

    func bootstrap(toolIDs: [String], dockIDs: [String]) {
        guard !isInitialized, !recoveryRequired else { return }
        var candidate = Page2Layout()
        candidate.dockIDs = dockIDs
        candidate.migrationSource = defaults.string(forKey: "page2DesktopStyle") ?? "classic"
        if candidate.migrationSource == "stitch" {
            candidate.items = [.widget("plan", span: .medium), .widget("todo"), .widget("vocab")]
            candidate.items += (defaults.stringArray(forKey: "page2DesktopApps_v1") ?? toolIDs).map(Page2Item.app)
        } else {
            candidate.items = legacyWidgets()
            if defaults.data(forKey: "dashboardWidgets_v2") == nil {
                candidate.items += toolIDs.map(Page2Item.app)
            }
        }
        candidate.boards[0] = packed(candidate.items)
        if save(candidate, keepUndo: false) { isInitialized = true }
    }

    func retryLoad() {
        do {
            var decoded = try JSONDecoder().decode(Page2Layout.self, from: Data(contentsOf: fileURL))
            decoded.materializeDock()
            guard Page2GridEngine.validate(decoded) else { throw Page2GridError.invalidLayout }
            layout = decoded
            isInitialized = true
            recoveryRequired = false
            errorMessage = nil
        } catch { errorMessage = "仍无法读取主屏存档：\(error.localizedDescription)" }
    }

    func recover(toolIDs: [String], dockIDs: [String]) {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = fileURL.deletingLastPathComponent().appendingPathComponent("home-layout-backup-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: fileURL, to: backup)
            }
            recoveryRequired = false
            isInitialized = false
            bootstrap(toolIDs: toolIDs, dockIDs: dockIDs)
        } catch { errorMessage = "备份失败，未覆盖原文件：\(error.localizedDescription)" }
    }

    func board(columns: Int, rows: Int) -> Page2Board {
        layout.boards.first { $0.columns == columns && $0.rows == rows } ?? layout.boards[0]
    }

    func ensureBoard(columns: Int, rows: Int) {
        guard isInitialized, !layout.boards.contains(where: { $0.columns == columns && $0.rows == rows }) else { return }
        var candidate = layout
        candidate.boards.append(Page2GridEngine.project(layout.boards[0], columns: columns, rows: rows, items: layout.rootItems))
        _ = save(candidate, keepUndo: false)
    }

    @discardableResult
    func commit(_ board: Page2Board, basedOn snapshot: Page2Layout) -> Bool {
        guard snapshot == layout, let i = layout.boards.firstIndex(where: { $0.capacityKey == board.capacityKey }) else {
            errorMessage = "主屏已更新，这次拖动已取消。"
            return false
        }
        var candidate = layout
        candidate.boards[i] = board
        return save(candidate)
    }

    @discardableResult
    func insert(_ item: Page2Item, capacity: String, pageID: UUID? = nil) -> Bool {
        var candidate = layout
        candidate.items.append(item)
        for i in candidate.boards.indices {
            var board = candidate.boards[i]
            let slot = Page2GridEngine.firstVacancy(for: item, in: &board, items: candidate.rootItems,
                                                   startingAt: board.capacityKey == capacity ? pageID : nil)
            board.placements.append(slot)
            candidate.boards[i] = board
        }
        return save(candidate)
    }

    @discardableResult
    func change(_ id: UUID, span: Page2Span, widgetKind: String? = nil) -> Bool {
        guard let item = layout.item(id), item.kind != "folder",
              item.kind != "stack" || Page2Span.widgetSizes.contains(span),
              span != .icon || item.toolID != nil else { return false }
        do {
            return save(try Page2GridEngine.resizing(id, to: span, in: layout, widgetKind: widgetKind))
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func receive(_ incoming: Page2IncomingItem, capacity: String, pageID: UUID?, row: Int, column: Int,
                 reserved: Set<UUID> = []) -> Bool {
        var candidate = layout
        let item: Page2Item
        switch incoming {
        case .library(let tool), .dock(let tool):
            if case .dock = incoming {
                item = candidate.dockItems.first(where: { $0.kind == "app" && $0.toolID == tool }) ?? .app(tool)
                candidate.dockItemIDs?.removeAll { $0 == item.id }
            } else { item = candidate.rootItems.first(where: { $0.kind == "app" && $0.toolID == tool }) ?? .app(tool) }
            if candidate.item(item.id) == nil { candidate.items.append(item) }
        case .folder(let containerID, let childID):
            guard let index = candidate.items.firstIndex(where: { $0.id == containerID }),
                  candidate.items[index].children.contains(childID), let child = candidate.item(childID) else { return false }
            item = child
            candidate.items[index].removeChildren([childID])
            collapseContainers(&candidate)
        }
        do {
            for i in candidate.boards.indices {
                var board = candidate.boards[i]
                if !board.placements.contains(where: { $0.id == item.id }) {
                    let slot = Page2GridEngine.firstVacancy(for: item, in: &board, items: candidate.rootItems)
                    board.placements.append(slot)
                }
                if board.capacityKey == capacity, let pageID {
                    board = try Page2GridEngine.place(item, on: pageID, row: row, column: column,
                                                     in: board, items: candidate.rootItems, reserved: reserved)
                }
                candidate.boards[i] = board
            }
            return save(candidate)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func configure(_ id: UUID, values: [String: String]) {
        var candidate = layout
        guard let i = candidate.items.firstIndex(where: { $0.id == id }) else { return }
        candidate.items[i].configuration = values
        _ = save(candidate)
    }

    func remove(_ id: UUID) {
        var candidate = layout
        let removed = Set([id] + (candidate.item(id)?.children ?? []))
        candidate.items.removeAll { removed.contains($0.id) }
        candidate.dockItemIDs?.removeAll { removed.contains($0) }
        for i in candidate.items.indices { candidate.items[i].removeChildren(removed) }
        for i in candidate.boards.indices { candidate.boards[i].placements.removeAll { removed.contains($0.id) } }
        collapseContainers(&candidate)
        _ = save(candidate)
    }

    func combine(_ source: UUID, with target: UUID, preview: Page2Board? = nil, insertionIndex: Int? = nil, folderPage: Int? = nil) -> Bool {
        guard source != target, let a = layout.item(source), let b = layout.item(target),
              layout.topLevelItems.contains(where: { $0.id == source }), layout.topLevelItems.contains(where: { $0.id == target }) else { return false }
        var candidate = layout
        candidate.dockItemIDs?.removeAll { $0 == source }
        if let preview {
            guard Page2GridEngine.validate(preview, items: candidate.rootItems),
                  let index = candidate.boards.firstIndex(where: { $0.capacityKey == preview.capacityKey }) else { return false }
            candidate.boards[index] = preview
        }
        let kind: String
        if a.kind == "app" && (b.kind == "app" || b.kind == "folder") { kind = "folder" }
        else if a.canStack(with: b) { kind = "stack" }
        else { return false }
        let incoming = a.kind == "stack" ? a.children : [source]
        let selectedIncoming = a.configuration["activeChild"].flatMap(UUID.init(uuidString:)).flatMap { incoming.contains($0) ? $0 : nil } ?? incoming.first
        if kind == "stack" {
            guard incoming.count + (b.kind == "stack" ? b.children.count : 1) <= 10 else { return false }
            if a.kind == "stack" { candidate.items.removeAll { $0.id == source } }
        }
        if b.kind == kind, let index = candidate.items.firstIndex(where: { $0.id == target }) {
            if kind == "folder" {
                let pages = b.childPages
                let page = folderPage ?? max(0, pages.count - 1)
                let slot = insertionIndex ?? (pages.indices.contains(page) ? pages[page].count : 0)
                candidate.items[index].setFolderPages(Page2FolderPages.inserting(source, page: page, slot: slot, into: pages))
            } else {
                candidate.items[index].children.insert(contentsOf: incoming, at: min(candidate.items[index].children.count, max(0, insertionIndex ?? candidate.items[index].children.count)))
                candidate.items[index].configuration["activeChild"] = selectedIncoming?.uuidString
                candidate.items[index].configuration["rotationTool"] = defaults.string(forKey: "page2RecentTool_v1") ?? ""
            }
            for i in candidate.boards.indices { candidate.boards[i].placements.removeAll { $0.id == source } }
        } else {
            var container = Page2Item(kind: kind, span: b.span, title: kind == "folder" ? "文件夹" : "组件堆叠", children: insertionIndex == 0 ? [source, target] : [target, source])
            if kind == "stack" {
                container.children = insertionIndex == 0 ? incoming + [target] : [target] + incoming
                container.configuration["activeChild"] = selectedIncoming?.uuidString
                container.configuration["rotationTool"] = defaults.string(forKey: "page2RecentTool_v1") ?? ""
            }
            if kind == "folder" {
                container.setFolderPages(Page2FolderPages.inserting(source, page: folderPage ?? 0, slot: insertionIndex ?? 1, into: [[target]]))
            }
            candidate.items.append(container)
            if let dockIndex = candidate.dockItemIDs?.firstIndex(of: target) { candidate.dockItemIDs?[dockIndex] = container.id }
            for i in candidate.boards.indices {
                candidate.boards[i].placements.removeAll { $0.id == source }
                if let p = candidate.boards[i].placements.firstIndex(where: { $0.id == target }) { candidate.boards[i].placements[p].id = container.id }
            }
        }
        return save(candidate)
    }

    @discardableResult
    func addWidget(_ widget: Page2Item, toStack id: UUID) -> Bool {
        guard widget.kind == "widget", layout.item(widget.id) == nil,
              let index = layout.items.firstIndex(where: { $0.id == id && $0.kind == "stack" }),
              layout.items[index].span == widget.span, layout.items[index].children.count < 10 else { return false }
        var candidate = layout
        candidate.items.append(widget)
        candidate.items[index].children.append(widget.id)
        candidate.items[index].configuration["activeChild"] = widget.id.uuidString
        candidate.items[index].configuration["rotationTool"] = defaults.string(forKey: "page2RecentTool_v1") ?? ""
        return save(candidate)
    }

    @discardableResult
    func commitStackOrder(_ id: UUID, children: [UUID], basedOn snapshot: Page2Layout) -> Bool {
        guard layout == snapshot, let index = layout.items.firstIndex(where: { $0.id == id && $0.kind == "stack" }),
              children.count == Set(children).count, Set(children) == Set(layout.items[index].children) else { return false }
        guard children != layout.items[index].children else { return true }
        var candidate = layout
        candidate.items[index].children = children
        return save(candidate)
    }

    func extractedLayout(_ childID: UUID, from containerID: UUID) -> Page2Layout? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("page2-ui-test"), ProcessInfo.processInfo.environment["PAGE2_UI_REJECT_EXTRACTION"] == "1" { return nil }
        #endif
        var candidate = layout
        guard let index = candidate.items.firstIndex(where: { $0.id == containerID }),
              candidate.items[index].children.contains(childID), let child = candidate.item(childID) else { return nil }
        candidate.items[index].removeChildren([childID])
        collapseContainers(&candidate)
        for i in candidate.boards.indices {
            var board = candidate.boards[i]
            let page = layout.boards[i].placements.first(where: { $0.id == containerID })?.pageID
            let slot = Page2GridEngine.firstVacancy(for: child, in: &board, items: candidate.rootItems, startingAt: page)
            board.placements.append(slot)
            candidate.boards[i] = board
        }
        return candidate
    }

    func extract(_ childID: UUID, from containerID: UUID) {
        if let candidate = extractedLayout(childID, from: containerID) { _ = save(candidate) }
    }

    @discardableResult
    func commitExtraction(_ childID: UUID, from containerID: UUID, board: Page2Board, basedOn snapshot: Page2Layout) -> Bool {
        guard snapshot == layout, var candidate = extractedLayout(childID, from: containerID),
              let index = candidate.boards.firstIndex(where: { $0.capacityKey == board.capacityKey }) else { return false }
        candidate.boards[index] = board
        return save(candidate)
    }

    func rename(_ id: UUID, title: String) {
        var candidate = layout
        guard let i = candidate.items.firstIndex(where: { $0.id == id }) else { return }
        candidate.items[i].title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        _ = save(candidate)
    }

    func reorderChildren(_ id: UUID, from: IndexSet, to: Int) {
        var candidate = layout
        guard let i = candidate.items.firstIndex(where: { $0.id == id }) else { return }
        var children = candidate.items[i].children
        guard from.allSatisfy(children.indices.contains), (0...children.count).contains(to) else { return }
        let counts = candidate.items[i].childPages.map(\.count)
        let moved = from.sorted().map { children[$0] }
        for index in from.sorted(by: >) { children.remove(at: index) }
        children.insert(contentsOf: moved, at: min(children.count, max(0, to - from.filter { $0 < to }.count)))
        candidate.items[i].children = children
        if candidate.items[i].kind == "folder" {
            var offset = 0
            candidate.items[i].setFolderPages(counts.map { count in
                defer { offset += count }
                return Array(children[offset..<(offset + count)])
            })
        }
        _ = save(candidate)
    }

    @discardableResult
    func commitFolderPages(_ id: UUID, pages: [[UUID]], basedOn snapshot: Page2Layout) -> Bool {
        guard layout == snapshot else { errorMessage = "主屏已更新，这次拖动已取消。"; return false }
        var candidate = layout
        guard let index = candidate.items.firstIndex(where: { $0.id == id && $0.kind == "folder" }) else { return false }
        let children = pages.flatMap { $0 }
        guard children.count == Set(children).count,
              Set(children) == Set(candidate.items[index].children), pages.allSatisfy({ $0.count <= 9 }) else { return false }
        candidate.items[index].setFolderPages(pages)
        return save(candidate)
    }

    func updatePages(_ pages: [Page2Page], capacity: String) {
        guard pages.contains(where: { !$0.isHidden }) else { return }
        var candidate = layout
        guard let i = candidate.boards.firstIndex(where: { $0.capacityKey == capacity }) else { return }
        candidate.boards[i].pages = pages
        _ = save(candidate)
    }

    func cleanEmptyPages(capacity: String) {
        var candidate = layout
        guard let i = candidate.boards.firstIndex(where: { $0.capacityKey == capacity }) else { return }
        let used = Set(candidate.boards[i].placements.map(\.pageID))
        let firstVisible = candidate.boards[i].pages.first(where: { !$0.isHidden })?.id
        candidate.boards[i].pages.removeAll { !used.contains($0.id) && $0.id != firstVisible && !$0.isHidden }
        if candidate != layout { _ = save(candidate, keepUndo: false) }
    }

    func importLegacy(capacity: String) {
        var candidate = layout
        let existing = Set(candidate.items.compactMap(\.widgetKind))
        for item in legacyWidgets() where !existing.contains(item.widgetKind ?? "") {
            candidate.items.append(item)
            for i in candidate.boards.indices {
                var board = candidate.boards[i]
                let slot = Page2GridEngine.firstVacancy(for: item, in: &board, items: candidate.rootItems)
                board.placements.append(slot)
                candidate.boards[i] = board
            }
        }
        _ = save(candidate)
    }

    @discardableResult
    func moveToDock(_ id: UUID, at position: Int) -> Bool {
        guard let item = layout.item(id), ["app", "folder"].contains(item.kind) else { return false }
        var candidate = layout
        let duplicates = Set(candidate.dockItems.filter { $0.id != id && item.kind == "app" && $0.kind == "app" && $0.toolID == item.toolID }.map(\.id))
        candidate.dockItemIDs?.removeAll { $0 == id || duplicates.contains($0) }
        guard (candidate.dockItemIDs?.count ?? 0) < 4 else { return false }
        candidate.items.removeAll { duplicates.contains($0.id) }
        let insertion = max(0, min(position, candidate.dockItemIDs?.count ?? 0))
        candidate.dockItemIDs?.insert(id, at: insertion)
        for i in candidate.items.indices { candidate.items[i].removeChildren([id]) }
        for i in candidate.boards.indices { candidate.boards[i].placements.removeAll { $0.id == id } }
        collapseContainers(&candidate)
        return save(candidate)
    }

    @discardableResult
    func commitDockExtraction(_ id: UUID, board: Page2Board, basedOn snapshot: Page2Layout) -> Bool {
        guard layout == snapshot, layout.dockItemIDs?.contains(id) == true, let item = layout.item(id) else { return false }
        var candidate = layout
        candidate.dockItemIDs?.removeAll { $0 == id }
        for i in candidate.boards.indices {
            if candidate.boards[i].capacityKey == board.capacityKey { candidate.boards[i] = board }
            else {
                let slot = Page2GridEngine.firstVacancy(for: item, in: &candidate.boards[i], items: candidate.rootItems)
                candidate.boards[i].placements.append(slot)
            }
        }
        return save(candidate)
    }

    func setDock(_ ids: [String]) {
        var candidate = layout
        let old = candidate.dockItems
        var selected = old.filter { $0.kind == "folder" }.map(\.id)
        var seen = Set<String>()
        for tool in ids where seen.insert(tool).inserted {
            let item = old.first { $0.kind == "app" && $0.toolID == tool } ?? .app(tool)
            if candidate.item(item.id) == nil { candidate.items.append(item) }
            selected.append(item.id)
        }
        let removed = Set(old.map(\.id)).subtracting(selected)
        candidate.items.removeAll { removed.contains($0.id) }
        candidate.dockItemIDs = selected
        _ = save(candidate)
    }

    func undo() {
        guard let previousLayout else { return }
        if save(previousLayout, keepUndo: false) { self.previousLayout = nil }
    }

    func reset(toolIDs: [String]) {
        var candidate = Page2Layout()
        let dockIDs = Set(layout.dockItems.flatMap { [$0.id] + $0.children })
        candidate.items = [.widget("todo")] + toolIDs.map(Page2Item.app) + layout.items.filter { dockIDs.contains($0.id) }
        candidate.dockItemIDs = layout.dockItemIDs
        candidate.boards[0] = packed(candidate.rootItems)
        candidate.dockIDs = layout.dockIDs
        candidate.migrationSource = "reset"
        _ = save(candidate)
    }

    @discardableResult
    private func save(_ proposed: Page2Layout, keepUndo: Bool = true) -> Bool {
        var candidate = proposed
        candidate.materializeDock()
        candidate.dockIDs = candidate.dockItems.compactMap(\.toolID)
        guard !recoveryRequired, Page2GridEngine.validate(candidate) else {
            errorMessage = Page2GridError.invalidLayout.localizedDescription
            return false
        }
        do {
            let data = try JSONEncoder().encode(candidate)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeData(data, fileURL)
            if keepUndo { previousLayout = layout }
            layout = candidate
            defaults.set(candidate.dockIDs, forKey: "page2DockTools_v1")
            if defaults === UserDefaults.standard { NotificationCenter.default.post(name: Notification.Name("page2DockLayoutChanged"), object: nil) }
            defaults.set(true, forKey: "page2HomeLayoutMigrated_v1")
            errorMessage = nil
            return true
        } catch { errorMessage = "没有保存这次修改：\(error.localizedDescription)"; return false }
    }

    private func packed(_ items: [Page2Item]) -> Page2Board {
        var board = Page2Board()
        for item in items {
            let slot = Page2GridEngine.firstVacancy(for: item, in: &board, items: items)
            board.placements.append(slot)
        }
        return board
    }

    private func legacyWidgets() -> [Page2Item] {
        struct LegacyWidget: Decodable { let kind: String; let size: String }
        guard let data = defaults.data(forKey: "dashboardWidgets_v2") else {
            return [.widget("pet", span: .medium), .widget("todo", span: .medium)]
        }
        guard let widgets = try? JSONDecoder().decode([LegacyWidget].self, from: data) else {
            errorMessage = "旧组件配置无法读取，原配置已保留。"
            return []
        }
        return widgets.map { .widget($0.kind, span: $0.size == "small" ? .small : ($0.size == "large" ? .large : .medium)) }
    }

    private func collapseContainers(_ candidate: inout Page2Layout) {
        let collapsed = candidate.items.filter { $0.kind == "folder" ? $0.children.isEmpty : ($0.kind == "stack" && $0.children.count < 2) }
        for container in collapsed {
            if let index = candidate.dockItemIDs?.firstIndex(of: container.id) {
                if let child = container.children.first { candidate.dockItemIDs?[index] = child }
                else { candidate.dockItemIDs?.remove(at: index) }
            }
            for i in candidate.boards.indices {
                if let child = container.children.first {
                    for p in candidate.boards[i].placements.indices where candidate.boards[i].placements[p].id == container.id {
                        candidate.boards[i].placements[p].id = child
                    }
                } else { candidate.boards[i].placements.removeAll { $0.id == container.id } }
            }
            candidate.items.removeAll { $0.id == container.id }
        }
    }
}
