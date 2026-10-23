import Foundation

/// 卡库世界书页的范围分段（⑥，小样 04）
enum WorldBookScope: String, CaseIterable {
    case all = "全部", global = "全局", floor = "这个楼层", conversation = "这个对话"
}

/// 书目录里的一本书：全局书（JSON）和楼层书（SwiftData）拍平成同一种行。
struct WorldBookListItem: Identifiable, Equatable {
    enum Kind: Equatable { case global, floor }

    let kind: Kind
    /// 全局书 = GlobalWorldBook.id；楼层书 = WorldBook.id.uuidString
    let bookId: String
    let name: String
    /// 楼层书所属楼层（全局书 nil）
    let profileId: String?
    /// 楼层书的对话范围（nil = 整个楼层）
    let conversationId: String?
    let entries: [WorldBookEntry]
    let isEnabled: Bool

    /// 与深链 / 小组件 / 旧面板行 id 同口径：`global:<id>` / `floor:<uuid>`，条目再接 `:<entryId>`
    var id: String { (kind == .global ? "global:" : "floor:") + bookId }

    func entryTargetId(_ entryId: UUID) -> String { "\(id):\(entryId.uuidString)" }
}

enum WorldBookLibrary {
    /// 没有真实选中的对话时「这个对话」不可选（新建也不能选对话范围）
    static func isAvailable(_ scope: WorldBookScope, selectedConversationId: String?) -> Bool {
        scope != .conversation || selectedConversationId != nil
    }

    /// 「全部」= 所有楼层 + 全局（跨楼层只浏览）；「这个楼层」= 当前楼层非对话范围；「这个对话」= 当前楼层里绑定选中对话的书
    static func filter(_ items: [WorldBookListItem], scope: WorldBookScope,
                       currentProfileId: String, selectedConversationId: String?) -> [WorldBookListItem] {
        switch scope {
        case .all:
            return items
        case .global:
            return items.filter { $0.kind == .global }
        case .floor:
            return items.filter { $0.kind == .floor && $0.profileId == currentProfileId && $0.conversationId == nil }
        case .conversation:
            guard let selectedConversationId else { return [] }
            return items.filter { $0.kind == .floor && $0.profileId == currentProfileId && $0.conversationId == selectedConversationId }
        }
    }

    /// 书名或任一条目（备注 / 正文 / 主次关键词）命中
    static func search(_ items: [WorldBookListItem], keyword: String?) -> [WorldBookListItem] {
        guard let keyword else { return items }
        return items.filter { $0.name.localizedStandardContains(keyword) || $0.entries.contains { matches($0, keyword: keyword) } }
    }

    static func matches(_ entry: WorldBookEntry, keyword: String) -> Bool {
        entry.comment.localizedStandardContains(keyword)
            || entry.content.localizedStandardContains(keyword)
            || entry.keys.contains { $0.localizedStandardContains(keyword) }
            || entry.secondaryKeys.contains { $0.localizedStandardContains(keyword) }
    }

    /// 条目目录「按注入顺序」：insertionOrder 升序，同序保持存储顺序（只影响显示，不改存储）
    static func displayOrder(_ entries: [WorldBookEntry]) -> [WorldBookEntry] {
        entries.enumerated()
            .sorted { $0.element.insertionOrder != $1.element.insertionOrder
                ? $0.element.insertionOrder < $1.element.insertionOrder : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: - 条目文案

    static func title(of entry: WorldBookEntry) -> String {
        if !entry.comment.isEmpty { return entry.comment }
        if !entry.keys.isEmpty { return entry.keys.joined(separator: "、") }
        let text = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "未命名条目" : String(text.prefix(30))
    }

    /// 编辑页位置选单里的 7 个支持位置（顺序照酒馆编辑器）
    static let supportedPositions: [WorldBookEntry.InsertionPosition] = [
        .beforeCharDef, .afterCharDef, .beforeExamples, .afterExamples, .authorNoteTop, .authorNoteBot, .atDepth
    ]

    static func positionName(_ position: WorldBookEntry.InsertionPosition) -> String {
        switch position {
        case .beforeCharDef: "角色定义前"
        case .afterCharDef: "角色定义后"
        case .beforeExamples: "示例对话前"
        case .afterExamples: "示例对话后"
        case .authorNoteTop: "作者注释前"
        case .authorNoteBot: "作者注释后"
        case .atDepth: "对话中（按深度）"
        case .unsupported: "不支持的位置"
        }
    }

    /// ② 标成不支持的位置在原文里的值（卡内书看 extensions.position，独立书看顶层 position）
    static func rawPosition(of entry: WorldBookEntry) -> String? {
        guard let data = entry.rawJSONData,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let value = (dict["extensions"] as? [String: Any])?["position"] ?? dict["position"] else { return nil }
        return "\(value)"
    }

    /// 条目行第三行：常驻 / 关键词触发 · 位置 · 顺序
    static func summary(of entry: WorldBookEntry) -> String {
        let trigger = entry.isConstant ? "常驻" : "关键词触发"
        let place: String
        switch entry.position {
        case .atDepth: place = "对话深度 \(entry.depth ?? 4)"
        case .unsupported: place = "不支持的位置（不注入）"
        default: place = positionName(entry.position)
        }
        return "\(trigger) · \(place) · 顺序 \(entry.insertionOrder)"
    }

    /// 解析 `floor:<bookId>[:<entryId>]` / `global:<bookId>[:<entryId>]`
    static func parseTarget(_ id: String) -> (kind: WorldBookListItem.Kind, bookId: String, entryId: UUID?)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, !parts[1].isEmpty else { return nil }
        let kind: WorldBookListItem.Kind
        switch parts[0] {
        case "floor": kind = .floor
        case "global": kind = .global
        default: return nil
        }
        return (kind, parts[1], parts.count == 3 ? UUID(uuidString: parts[2]) : nil)
    }

    // MARK: - 单条删除 + 5 秒撤销（只记最后一条，不做队列）

    struct Deletion: Equatable {
        let bookItemId: String
        let entry: WorldBookEntry
        /// 删除前在存储数组里的下标
        let index: Int
        let token = UUID()
    }

    enum RestoreResult: Equatable {
        case restored([WorldBookEntry])
        case conflict(String)
    }

    static func deleting(_ entries: [WorldBookEntry], entryId: UUID, bookItemId: String) -> (entries: [WorldBookEntry], deletion: Deletion)? {
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else { return nil }
        var next = entries
        let removed = next.remove(at: index)
        return (next, Deletion(bookItemId: bookItemId, entry: removed, index: index))
    }

    /// 按原位置插回（原开关随条目一起回来）；书没了（entries == nil）或同 id 已在就报冲突不插
    static func restoring(_ deletion: Deletion, into entries: [WorldBookEntry]?) -> RestoreResult {
        guard var entries else { return .conflict("这本书已经不在了，没法撤销") }
        guard !entries.contains(where: { $0.id == deletion.entry.id }) else { return .conflict("书里已经有这一条，没有重复插回") }
        entries.insert(deletion.entry, at: min(max(deletion.index, 0), entries.count))
        return .restored(entries)
    }
}
