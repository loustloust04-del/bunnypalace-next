#if os(iOS)
// [Bunny] 大肥兔的待办（网关 /api/todos 为准，Caelum 的待办工具共用这份），自 7f2c6c4df 移植；与上游本地 TodoManager 分开、改名避免冲突。
import Foundation
import Observation

/// 控制台待办。网关后端（/api/todos）为准，本地 UserDefaults 作离线缓存 + 乐观更新。
/// CC/API 经 builtin todo_* 工具写入的待办也会在这里出现（双端共用）。
struct BunnyTodoItem: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var done: Bool = false
    var source: String? = nil     // 'bunny' / 'caelum' …
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey { case id, text, done, source, createdAt }
    init(id: String = UUID().uuidString, text: String, done: Bool = false, source: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.done = done; self.source = source; self.createdAt = createdAt
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        source = try? c.decodeIfPresent(String.self, forKey: .source) ?? nil
        // 网关发 ISO 字符串；本地缓存发 Date。两种都吃。
        if let s = try? c.decode(String.self, forKey: .createdAt) {
            createdAt = ISO8601DateFormatter().date(from: s) ?? Date()
        } else {
            createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        }
    }
}

@MainActor
@Observable
final class BunnyTodoManager {
    static let shared = BunnyTodoManager()
    private static let cacheKey = "bunny.consoleTodoItems_v2"

    private(set) var items: [BunnyTodoItem]

    private var baseURL: String { BunnyGateway.baseURL }
    private var token: String { BunnyGateway.token }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([BunnyTodoItem].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    var remaining: Int { items.filter { !$0.done }.count }
    var sorted: [BunnyTodoItem] {
        items.sorted { a, b in
            if a.done != b.done { return !a.done }
            return a.createdAt < b.createdAt
        }
    }

    // MARK: - 网关同步

    /// 拉网关最新（含 Caelum 写入的）。失败保留本地缓存。
    func refresh() async {
        guard let data = await get("/api/todos") else { return }
        struct Resp: Decodable { let items: [BunnyTodoItem] }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { return }
        items = r.items
        saveCache()
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // 乐观插入
        let temp = BunnyTodoItem(text: t, source: "bunny")
        items.append(temp); saveCache()
        Task {
            _ = await send("/api/todos", method: "POST", json: ["text": t, "source": "bunny"])
            await refresh()
        }
    }

    func toggle(_ id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].done.toggle(); saveCache() }
        Task {
            _ = await send("/api/todos/\(id)/toggle", method: "POST")
            await refresh()
        }
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id }; saveCache()
        Task {
            _ = await send("/api/todos/\(id)", method: "DELETE")
            await refresh()
        }
    }

    func clearDone() {
        items.removeAll { $0.done }; saveCache()
        Task {
            _ = await send("/api/todos/done", method: "DELETE")
            await refresh()
        }
    }

    // MARK: - HTTP

    private func saveCache() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: Self.cacheKey) }
    }
    private func get(_ path: String) async -> Data? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
    @discardableResult
    private func send(_ path: String, method: String, json: [String: Any]? = nil) async -> Bool {
        guard let url = URL(string: baseURL + path) else { return false }
        var req = URLRequest(url: url); req.httpMethod = method; req.timeoutInterval = 8
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
#endif
