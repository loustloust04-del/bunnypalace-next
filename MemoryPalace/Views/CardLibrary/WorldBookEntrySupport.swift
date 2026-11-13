import Foundation

/// 楼层世界书条目是 `entriesData` 里的 JSON，`book.entries` 每次访问都解码。按书缓存，`entriesData` 变了（任何来源的改动）就重解；
/// 引用类型挂 @State，body 里读写不触发刷新。（11-06 随旧 WorldBookPanelView 删除从那里挪来，`WorldBookLibraryView` 在用）
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

