import Foundation

struct Page2Span: Codable, Equatable, Hashable {
    var columns: Int
    var rows: Int

    static let icon = Page2Span(columns: 1, rows: 1)
    static let small = Page2Span(columns: 2, rows: 2)
    static let medium = Page2Span(columns: 4, rows: 2)
    static let large = Page2Span(columns: 4, rows: 4)
    static let widgetSizes: [Page2Span] = [.small, .medium, .large]

    var title: String {
        switch self {
        case .icon: return "图标"
        case .small: return "小"
        case .large: return "大"
        default: return "中"
        }
    }
}

struct Page2Item: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: String
    var toolID: String?
    var widgetKind: String?
    var span: Page2Span = .icon
    var title: String = ""
    var children: [UUID] = []
    var folderPages: [[UUID]]?
    var configuration: [String: String] = [:]

    static func app(_ toolID: String) -> Page2Item {
        Page2Item(kind: "app", toolID: toolID)
    }

    static func widget(_ kind: String, span: Page2Span = .small) -> Page2Item {
        let independent = ["pet", "todo", "contacts", "plan"]
        return Page2Item(kind: "widget", toolID: kind == "garden" ? "memory" :
                            (independent.contains(kind) ? nil : kind), widgetKind: kind, span: span)
    }

    var childPages: [[UUID]] {
        folderPages ?? stride(from: 0, to: children.count, by: 9).map { Array(children[$0..<min(children.count, $0 + 9)]) }
    }
    mutating func setFolderPages(_ pages: [[UUID]]) {
        folderPages = pages.filter { !$0.isEmpty }
        children = folderPages?.flatMap { $0 } ?? []
    }
    mutating func removeChildren(_ ids: Set<UUID>) {
        guard children.contains(where: ids.contains) else { return }
        let pages = kind == "folder" ? childPages : nil
        children.removeAll(where: ids.contains)
        if let pages { setFolderPages(pages.map { $0.filter { !ids.contains($0) } }) }
    }

    func canStack(with other: Page2Item) -> Bool {
        ["widget", "stack"].contains(kind) && ["widget", "stack"].contains(other.kind) && span == other.span &&
            (kind == "stack" ? children.count : 1) + (other.kind == "stack" ? other.children.count : 1) <= 10
    }

    var isContainer: Bool { kind == "folder" || kind == "stack" }
}

struct Page2Page: Codable, Equatable, Identifiable {
    var id: UUID
    var isHidden = false
}

struct Page2Placement: Codable, Equatable, Identifiable {
    var id: UUID
    var pageID: UUID
    var row: Int
    var column: Int
}

struct Page2Board: Codable, Equatable, Identifiable {
    var id = UUID()
    var columns: Int
    var rows: Int
    var pages: [Page2Page] = []
    var placements: [Page2Placement] = []
    var nextPageNumber = 0

    var capacityKey: String { "\(columns)x\(rows)" }

    init(columns: Int = 4, rows: Int = 6) {
        self.columns = columns
        self.rows = rows
        _ = appendPage()
    }

    @discardableResult
    mutating func appendPage() -> UUID {
        let suffix = String(format: "%012llX", Int64(nextPageNumber))
        let pageID = UUID(uuidString: String(id.uuidString.prefix(24)) + suffix)!
        nextPageNumber += 1
        pages.append(Page2Page(id: pageID))
        return pageID
    }
}

struct Page2Layout: Codable, Equatable {
    var version = 1
    var items: [Page2Item] = []
    var boards: [Page2Board] = [Page2Board()]
    var dockIDs: [String] = []
    var dockItemIDs: [UUID]?
    var migrationSource: String = ""

    var topLevelItems: [Page2Item] {
        let children = Set(items.flatMap(\.children))
        return items.filter { !children.contains($0.id) }
    }
    var rootItems: [Page2Item] {
        let dock = Set(dockItemIDs ?? [])
        return topLevelItems.filter { !dock.contains($0.id) }
    }
    var dockItems: [Page2Item] { (dockItemIDs ?? []).compactMap(item) }

    mutating func materializeDock() {
        guard dockItemIDs == nil else { return }
        var seen = Set<String>()
        let dock = dockIDs.filter { seen.insert($0).inserted }.map(Page2Item.app)
        items.append(contentsOf: dock)
        dockItemIDs = dock.map(\.id)
    }

    func item(_ id: UUID) -> Page2Item? { items.first { $0.id == id } }
}

enum Page2IncomingItem {
    case library(String)
    case dock(String)
    case folder(container: UUID, child: UUID)
}
