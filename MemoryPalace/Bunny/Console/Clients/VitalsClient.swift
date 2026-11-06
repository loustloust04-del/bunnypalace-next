// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植；地址 / 口令改读 BunnyGateway（不再写死域名）。
import Foundation
import SwiftData

/// 从网关 /api/vitals 读取生活数据（只读，兔兔不许造假）
struct VitalsResponse: Codable {
    struct Water: Codable { let count: Int; let goal: Int; let lastUpdated: String }
    struct Food: Codable { let count: Int; let goal: Int; let meals: [String]; let lastUpdated: String }
    struct Meds: Codable { let taken: Bool; let name: String; let lastUpdated: String }
    /// 控制台备注（Caelum 经 console_write 记的），可选=旧网关兼容
    struct Note: Codable, Hashable { let text: String; let by: String; let ts: String }
    let water: Water
    let food: Food
    let meds: Meds
    let notes: [Note]?
    let date: String
}

enum VitalsClient {
    static func fetch() async -> VitalsResponse? {
        let base = BunnyGateway.baseURL
        let token = BunnyGateway.token
        guard let url = URL(string: "\(base)/api/vitals") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(VitalsResponse.self, from: data)
    }

    /// 服务端历史归档里出现过的所有饭名（用来认出本地的「昨日残留」）
    static func archivedMealNames(days: Int = 3) async -> Set<String> {
        let base = BunnyGateway.baseURL
        let token = BunnyGateway.token
        guard let url = URL(string: "\(base)/api/vitals/history?days=\(days)") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var names: Set<String> = []
        for (_, day) in obj {
            if let d = day as? [String: Any], let food = d["food"] as? [String: Any],
               let meals = food["meals"] as? [String] {
                names.formUnion(meals)
            }
        }
        return names
    }

    /// 把 App 本地记的饮水/进食推给网关合并（取两边较大者，meals 追加未见过的）。
    /// 返回合并后的服务端状态，供调用方回写本地——一次往返完成双向同步。
    static func merge(waterCount: Int, foodCount: Int, meals: [String], date: String) async -> VitalsResponse? {
        let base = BunnyGateway.baseURL
        let token = BunnyGateway.token
        guard let url = URL(string: "\(base)/api/vitals/merge") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "water_count": waterCount, "food_count": foodCount, "meals": meals, "date": date,
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        // merge 返回 {ok, water, food}，补上 notes/date 后复用 VitalsResponse 解码
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let water = obj["water"], let food = obj["food"] else { return nil }
        // ⚠️ meds/notes/date 是**占位无效值**，只为凑 VitalsResponse 的解码结构。
        // merge 的唯一消费方（VitalsSyncService.sync）只读 water/food，不碰这几个字段。
        // 若将来有人读 merged.meds，请改成从 HealthSyncService 取真数据（审查报告 Services P0 #2）。
        let shaped: [String: Any] = [
            "water": water, "food": food,
            "meds": ["taken": false, "name": "", "lastUpdated": ""],
            "notes": [], "date": "",
        ]
        guard let d2 = try? JSONSerialization.data(withJSONObject: shaped) else { return nil }
        return try? JSONDecoder().decode(VitalsResponse.self, from: d2)
    }
}

// [Bunny] 大肥兔的 VitalsSyncService（写本地 DailyContext）未移植：计划书约定饮水/进食以网关为唯一数据源、App 只读。

struct ScreenTimeApp: Codable {
    let app: String
    let sessions: Int
    let minutes: Double
}

struct ScreenTimeResponse: Codable {
    let date: String
    let total_minutes: Double
    let social_minutes: Double
    let apps: [ScreenTimeApp]
}

enum ScreenTimeClient {
    static func fetch() async -> ScreenTimeResponse? {
        // 只走网关代理；token 用 App 统一的 gatewayAuthToken（gatewayToken 是历史空键）
        let base = BunnyGateway.baseURL
        let token = BunnyGateway.token
        guard let url = URL(string: "\(base)/api/screentime") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(ScreenTimeResponse.self, from: data)
    }
}
