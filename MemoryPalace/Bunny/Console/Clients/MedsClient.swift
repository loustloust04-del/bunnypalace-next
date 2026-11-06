// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植；地址 / 口令改读 BunnyGateway（不再写死域名）。
import Foundation

/// 药箱 — 网关同一份数据（Caelum 的 meds_* 工具管的就是它）。
/// GET /api/meds · POST /api/meds · POST /:id/take · POST /:id/restock · PATCH /:id · DELETE /:id
enum MedsClient {
    struct Med: Codable, Identifiable, Hashable, Equatable {
        let id: String
        let name: String
        let remaining: Double
        let unit: String
        let perDose: Double
        let note: String?
    }
    struct Intake: Codable, Identifiable, Hashable, Equatable {
        let date: String
        let medId: String
        let name: String
        let amount: Double
        let ts: String
        var id: String { ts + medId }
    }
    struct Snapshot: Codable, Equatable {
        let meds: [Med]
        let today: [Intake]
    }

    private static var baseURL: String {
        BunnyGateway.baseURL
    }
    private static var token: String {
        BunnyGateway.token
    }

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard !token.isEmpty, let url = URL(string: baseURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private static let cacheKey = "meds"

    /// 有缓存先给缓存（秒开），同时后台取新的
    static func fetch() async -> Snapshot? {
        if let fresh = await fetchRemote() { GatewayCache.save(cacheKey, fresh); return fresh }
        return GatewayCache.load(cacheKey, as: Snapshot.self)
    }

    /// 先旧后新：onValue 可能被调两次
    static func fetchCached(_ onValue: @MainActor @escaping (Snapshot, Bool) -> Void) async {
        await GatewayCache.fetch(key: cacheKey, remote: { await fetchRemote() }, onValue: onValue)
    }

    private static func fetchRemote() async -> Snapshot? {
        guard let req = request("/api/meds") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    @discardableResult
    static func add(name: String, count: Double, unit: String, perDose: Double) async -> Bool {
        guard let req = request("/api/meds", method: "POST",
                                body: ["name": name, "count": count, "unit": unit, "perDose": perDose]) else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// 新增药物并返回 Gateway 侧 id（同步用）
    static func addReturningId(name: String, count: Double, unit: String, perDose: Double, note: String? = nil) async -> String? {
        var body: [String: Any] = ["name": name, "count": count, "unit": unit, "perDose": perDose]
        if let note, !note.isEmpty { body["note"] = note }
        guard let req = request("/api/meds", method: "POST", body: body) else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let med = obj["med"] as? [String: Any],
              let id = med["id"] as? String else { return nil }
        return id
    }

    @discardableResult
    static func take(id: String, amount: Double? = nil) async -> Bool {
        var body: [String: Any] = [:]
        if let amount { body["amount"] = amount }
        guard let req = request("/api/meds/\(id)/take", method: "POST", body: body) else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    @discardableResult
    static func restock(id: String, count: Double) async -> Bool {
        guard let req = request("/api/meds/\(id)/restock", method: "POST", body: ["count": count]) else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    @discardableResult
    static func update(id: String, patch: [String: Any]) async -> Bool {
        guard let req = request("/api/meds/\(id)", method: "PATCH", body: patch) else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    @discardableResult
    /// 直接设定库存（本地手动改完推上去，覆盖服务器）
    static func setRemaining(id: String, count: Double) async -> Bool {
        guard var req = request("/api/meds/\(id)", method: "PATCH") else { return false }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["remaining": count])
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    static func remove(id: String) async -> Bool {
        guard let req = request("/api/meds/\(id)", method: "DELETE") else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// 数量显示：去掉多余小数（19.0 → "19"）。
    static func numText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
