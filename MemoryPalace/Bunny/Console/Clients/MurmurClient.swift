// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植；地址 / 口令改读 BunnyGateway（不再写死域名）。
import Foundation

/// 他的心里话（murmur）——AI 每天 4:00/14:00 写的内心独白，网关 murmurs 表。
/// 2026-06-13 做了后端，注释写「前端展示后续做」——两个半月后（08-31）兔兔发现
/// App 里根本没有出口。本文件 + 控制台 murmurWidget 补上这个出口。
/// 复用控制台约定：UserDefaults "gatewayBaseURL" / "gatewayAuthToken"。
enum MurmurClient {
    struct Item: Identifiable, Codable, Equatable {
        var id: String { created_at }
        let thinking: String?
        let content: String
        let created_at: String

        var createdDate: Date? { ISO8601DateFormatter().date(from: created_at)
            ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: created_at) }() }
    }

    private static var baseURL: String {
        BunnyGateway.baseURL
    }
    private static var token: String {
        BunnyGateway.token
    }
    static var isConfigured: Bool { !token.isEmpty }

    static func fetch(limit: Int = 10) async -> [Item] {
        guard !token.isEmpty, let url = URL(string: "\(baseURL)/api/murmurs?limit=\(limit)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        return json.murmurs
    }

    private struct Envelope: Codable { let murmurs: [Item] }
}
