// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植；地址 / 口令改读 BunnyGateway（不再写死域名）。
import Foundation

/// 推特桥（P2-8）：拉取已同步进网关记忆库的推文（sync-twitter 每 30 分钟更新）。
/// GET {gatewayBaseURL}/api/tweets?limit=N。复用控制台约定的 baseURL / token。
enum TweetsClient {
    struct Tweet: Identifiable, Decodable {
        let id: Int
        let ts: String
        let text: String
        let url: String?
        let tags: [String]
        let imageDesc: String?
        enum CodingKeys: String, CodingKey { case id, ts, text, url, tags, imageDesc }
    }

    private static var baseURL: String {
        BunnyGateway.baseURL
    }
    private static var token: String {
        BunnyGateway.token
    }
    static var isConfigured: Bool { !token.isEmpty }

    static func fetch(limit: Int = 30) async -> [Tweet] {
        guard !token.isEmpty,
              var comps = URLComponents(string: baseURL + "/api/tweets") else { return [] }
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["tweets"],
              let arrData = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        return (try? JSONDecoder().decode([Tweet].self, from: arrData)) ?? []
    }
}
