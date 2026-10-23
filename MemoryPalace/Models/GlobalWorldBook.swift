import Foundation
import Observation

// MARK: - Global World Book (跨楼层，存 UserDefaults)
// ⑧c-4 起存 BlobStore（blobs/globalWorldBooks，首次读时从 UserDefaults 迁出）

struct GlobalWorldBook: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var entries: [WorldBookEntry] = []
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var rawJSONData: Data?

    var enabledEntryCount: Int {
        entries.filter(\.isEnabled).count
    }
}

// MARK: - Global World Book Manager

@Observable
final class GlobalWorldBookManager {
    private static let storageKey = "globalWorldBooks"

    var books: [GlobalWorldBook]
    @ObservationIgnored private let defaults: UserDefaults
    /// ⑧c-4：全局书存 BlobStore（root 可注入）
    @ObservationIgnored private let root: URL?

    /// 当前启用的全局世界书
    var enabledBooks: [GlobalWorldBook] {
        books.filter(\.isEnabled)
    }

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.root = BlobStore.resolvedRoot(root, defaults: defaults)
        self.books = Self.load(root: self.root, defaults)
    }

    /// 卡库 ③-4：发送 / 检查器解析身份绑的全局书（含关着的）拿不到 SwiftUI 环境，App 建的那份挂这里（弱引用，同 RegexPipeline.liveCards）
    static weak var live: GlobalWorldBookManager?

    static func makeLive() -> GlobalWorldBookManager {
        let manager = GlobalWorldBookManager()
        live = manager
        return manager
    }

    /// 整包导入（⑧c）：一次写入；原数据读不出时拒绝写，不拿空列表覆盖
    func add(contentsOf newBooks: [GlobalWorldBook]) throws {
        try checkReadable()
        let ids = Set(newBooks.map(\.id))
        try write(books.filter { !ids.contains($0.id) } + newBooks)
    }

    func remove(ids: Set<String>) throws {
        try checkReadable()
        try write(books.filter { !ids.contains($0.id) })
    }

    private func checkReadable() throws {
        if let data = try BlobStore.read(forKey: Self.storageKey, root: root, defaults: defaults) { _ = try JSONDecoder().decode([GlobalWorldBook].self, from: data) }
    }

    private func write(_ next: [GlobalWorldBook]) throws {
        try BlobStore.set(try JSONEncoder().encode(next), forKey: Self.storageKey, root: root)
        books = next
    }

    /// 新建空白全局世界书
    @discardableResult
    func create(name: String) -> GlobalWorldBook {
        let book = GlobalWorldBook(name: name)
        books.append(book)
        persist()
        return book
    }

    func delete(_ book: GlobalWorldBook) {
        books.removeAll { $0.id == book.id }
        persist()
    }

    func toggleEnabled(_ id: String) {
        guard let idx = books.firstIndex(where: { $0.id == id }) else { return }
        books[idx].isEnabled.toggle()
        persist()
    }

    func update(_ book: GlobalWorldBook) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx] = book
        books[idx].updatedAt = Date()
        persist()
    }

    /// 更新指定书的 entries
    func updateEntries(bookId: String, entries: [WorldBookEntry]) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].entries = entries
        books[idx].updatedAt = Date()
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(books) {
            do { try BlobStore.set(data, forKey: Self.storageKey, root: root) }
            catch { NSLog("全局世界书保存失败：%@", error.localizedDescription) }
        }
    }

    private static func load(root: URL?, _ defaults: UserDefaults) -> [GlobalWorldBook] {
        guard let data = try? BlobStore.read(forKey: storageKey, root: root, defaults: defaults),
              let saved = try? JSONDecoder().decode([GlobalWorldBook].self, from: data) else {
            return []
        }
        return saved
    }
}
