// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植；地址 / 口令改读 BunnyGateway（不再写死域名）。
import Foundation

/// 经期记录 + 预测 — 网关同一份数据（Caelum 的 period 工具/每日提示读的就是它）。
/// GET /api/period · POST /start · POST /end · POST /sync · DELETE /:date
/// 复用控制台约定：UserDefaults "gatewayBaseURL" / "gatewayAuthToken"。
enum PeriodClient {
    struct Event: Codable, Equatable, Identifiable {
        let date: String          // 来潮日 YYYY-MM-DD
        let end: String?
        let source: String?
        var id: String { date }
    }

    struct Prediction: Codable, Equatable {
        let hasData: Bool
        let avgCycle: Int
        let avgPeriodLen: Int
        let lastStart: String?
        let currentCycleDay: Int?
        let onPeriod: Bool
        let nextDate: String?
        let daysUntil: Int?       // 负 = 已推迟
        let ovulationDate: String?
        let fertileStart: String?
        let fertileEnd: String?
        let phase: String
    }

    struct Snapshot: Codable, Equatable {
        let events: [Event]
        let prediction: Prediction
    }

    private static var baseURL: String {
        BunnyGateway.baseURL
    }
    private static var token: String {
        BunnyGateway.token
    }
    static var isConfigured: Bool { !token.isEmpty }

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

    /// 拉当前记录 + 预测。
    private static let cacheKey = "period"

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
        guard let req = request("/api/period") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// 记一次来潮（默认今天）。
    @discardableResult
    static func logStart(date: String? = nil, source: String = "bunny") async -> Bool {
        var body: [String: Any] = ["source": source]
        if let date { body["date"] = date }
        guard let req = request("/api/period/start", method: "POST", body: body) else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// 给最近/指定来潮补结束日。
    @discardableResult
    static func logEnd(end: String, start: String? = nil) async -> Bool {
        var body: [String: Any] = ["end": end]
        if let start { body["start"] = start }
        guard let req = request("/api/period/end", method: "POST", body: body) else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// 从 Apple 健康批量同步来潮日（已存在的自动跳过）。
    @discardableResult
    static func sync(dates: [String], source: String = "healthkit") async -> Int {
        guard !dates.isEmpty, let req = request("/api/period/sync", method: "POST",
                                                body: ["dates": dates, "source": source]) else { return 0 }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let added = json["added"] as? Int else { return 0 }
        return added
    }

    @discardableResult
    static func remove(date: String) async -> Bool {
        guard let req = request("/api/period/\(date)", method: "DELETE") else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
