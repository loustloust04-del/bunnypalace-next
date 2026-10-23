import Foundation

/// 一次锻炼的精简信息（不含 HealthKit 类型，两端可编译）。
struct WorkoutBrief: Equatable {
    var typeName: String
    var date: Date
    var durationMinutes: Int
    var energyKcal: Int?
}

/// 今日健康快照。纯数据，不 import HealthKit —— iOS 端由 HealthService 填充，
/// Mac 端永远为 nil。`summaryLine` 是 `{{health}}` 宏注入的文本。
struct HealthSnapshot: Equatable {
    var date: Date
    var steps: Int?
    var sleepHours: Double?
    var activeEnergyKcal: Int?
    var restingHeartRate: Int?
    var lastWorkout: WorkoutBrief?

    var isEmpty: Bool {
        steps == nil && sleepHours == nil && activeEnergyKcal == nil
            && restingHeartRate == nil && lastWorkout == nil
    }

    /// 拼成一句自然中文，只含有数据的项；全空返回 ""。
    var summaryLine: String {
        var parts: [String] = []

        if let steps {
            parts.append("今天走了 \(Self.grouped(steps)) 步")
        }
        if let sleepHours, sleepHours > 0 {
            let h = Int(sleepHours)
            let m = Int((sleepHours - Double(h)) * 60)
            parts.append(m > 0 ? "昨晚睡了 \(h) 小时 \(m) 分钟" : "昨晚睡了 \(h) 小时")
        }
        if let activeEnergyKcal {
            parts.append("活动消耗 \(Self.grouped(activeEnergyKcal)) 千卡")
        }
        if let restingHeartRate {
            parts.append("静息心率 \(restingHeartRate) 次/分")
        }
        if let lastWorkout {
            parts.append("最近一次锻炼是\(lastWorkout.typeName) \(lastWorkout.durationMinutes) 分钟")
        }

        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "，") + "。"
    }

    private static let groupingFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    private static func grouped(_ value: Int) -> String {
        groupingFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
