#if os(iOS)
import SwiftUI
import Foundation

// MARK: - [Bunny] 大肥兔 DailyContext 的数据来源（替代原 SwiftData 表 + VitalsSyncService）
// 网关 /health-data 给多日的步数 / 饮水 / 屏幕时间；/api/vitals 给今天的饮水与进食。
// HealthKit 读到的步数 / 睡眠由 ConsoleView 原逻辑写进今天这条，再经 HealthBridgeClient 报给网关。

@MainActor
enum BunnyDailyContexts {
    private struct HealthDay: Decodable {
        let date: String
        let steps: Int?
        let water_count: Int?
        let screen_time_hours: Double?
    }
    private struct Payload: Decodable { let days: [HealthDay] }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func ensureToday(_ list: inout [DailyContext]) {
        let today = Calendar.current.startOfDay(for: Date())
        if !list.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) {
            list.insert(DailyContext(date: today), at: 0)
        }
    }

    /// 已有对象原样保留（HealthKit 填进去的步数 / 睡眠不丢），只补网关的数
    static func load(keeping old: [DailyContext]) async -> [DailyContext] {
        let cal = Calendar.current
        var byDay: [Date: DailyContext] = [:]
        for c in old { byDay[cal.startOfDay(for: c.date)] = c }
        if let data = try? await BunnyGateway.get("/health-data"),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            for d in payload.days {
                guard let raw = dayFmt.date(from: d.date) else { continue }
                let day = cal.startOfDay(for: raw)
                let c = byDay[day] ?? DailyContext(date: day)
                if let w = d.water_count { c.waterCount = max(c.waterCount, w) }
                if c.steps == nil, let s = d.steps { c.steps = s }
                if c.screenTime == nil, let h = d.screen_time_hours { c.screenTime = h }
                byDay[day] = c
            }
        }
        if let v = await VitalsClient.fetch() {
            let today = cal.startOfDay(for: Date())
            let c = byDay[today] ?? DailyContext(date: today)
            c.waterCount = max(c.waterCount, v.water.count)
            if !v.food.meals.isEmpty { c.meals = v.food.meals.map { MealEntry(description: $0) } }
            byDay[today] = c
        }
        return byDay.values.sorted { $0.date > $1.date }
    }
}

/// 还没搬过来的页面占位
struct BunnyMovingInView: View {
    let title: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text("这个房间还在搬家中，很快就到 🐰").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(40)
    }
}
#endif
