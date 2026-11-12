#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import Foundation

/// 健康桥（P2-6）：把 HealthKit/控制台的今日摘要 POST 给网关 /health-data，
/// 网关存 14 天历史，Caelum（API/CC）经 get_health 工具读——它会知道你睡得好不好。
/// 复用控制台约定：UserDefaults "gatewayBaseURL" / "gatewayAuthToken"。30 分钟节流。
enum HealthBridgeClient {
    private static let throttleKey = "healthBridgeLastReport"
    private static let throttleSeconds: TimeInterval = 30 * 60

    private static var baseURL: String {
        BunnyGateway.baseURL
    }
    private static var token: String {
        BunnyGateway.token
    }

    /// 从今日 DailyContext 取摘要上报。force = true 跳过节流（调试用）。
    static func report(from ctx: DailyContext, force: Bool = false) async {
        guard !token.isEmpty else { return }
        if !force {
            let last = UserDefaults.standard.double(forKey: throttleKey)
            guard Date().timeIntervalSince1970 - last > throttleSeconds else { return }
        }
        guard let url = URL(string: baseURL + "/health-data") else { return }

        var body: [String: Any] = [:]
        if let s = ctx.steps { body["steps"] = s }
        let hm: (Date) -> String = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: $0)
        }
        if let start = ctx.sleepStart { body["sleep_start"] = hm(start) }
        if let end = ctx.sleepEnd { body["sleep_end"] = hm(end) }
        if let dur = ctx.sleepDuration { body["sleep_hours"] = dur }
        if let m = ctx.menstrualDay { body["menstrual_day"] = m }
        body["water_count"] = ctx.waterCount
        if let st = ctx.screenTime { body["screen_time_hours"] = st }
        guard body.count > 1 else { return } // 除了 water 全空就先不报

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: throttleKey)
        }
    }
}
#endif
