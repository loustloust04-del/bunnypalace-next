#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import Foundation

// MARK: - Supporting types

/// 一次进食记录（值类型，存储为 Codable 数组）
struct MealEntry: Codable, Hashable {
    var description: String   // "泡面" / "外卖炒饭"
    var time: Date

    init(description: String, time: Date = Date()) {
        self.description = description
        self.time = time
    }
}

/// 药物服用状态
enum MedicationStatus: String, Codable {
    case taken   = "taken"    // 已服用
    case skipped = "skipped"  // 跳过
    case pending = "pending"  // 未报告（默认）
}

// MARK: - DailyContext

/// 每天的健康/日常数据快照。
///
/// 写入路径：Bunny 在对话中报告 → Caelum 通过 tool call 写入 → 控制台刷新。
/// 控制台是只读的，不提供直接输入入口。
/// [Bunny] 不再是 SwiftData 模型：上游 schema 里没有这张表，按计划书「饮水/进食以网关为唯一数据源、App 只读」，
/// 由 BunnyDailyContexts 每次从网关组装（HealthKit 的步数 / 睡眠在本地补进当天这条，再报给网关）。
final class DailyContext: Identifiable {
    var id: Date { date }
    /// 哪一天（取 startOfDay，确保每天只有一条记录）
    var date: Date

    /// 饮水杯数（目标 6）
    var waterCount: Int

    /// 进食记录列表
    var meals: [MealEntry]

    /// 药物服用状态
    var medicationStatus: MedicationStatus

    /// 药物名称（如 "右佐匹克隆"）
    var medicationName: String

    /// 入睡时间（nil = 未记录）
    var sleepStart: Date?

    /// 起床时间（nil = 未记录）
    var sleepEnd: Date?

    /// 步数——优先从 HealthKit 读取，HealthKit 不可用时手动填写
    var steps: Int?

    /// 屏幕使用时间（小时，Screen Time API 暂不可用，占位）
    var screenTime: Double?

    /// 社交 APP 屏幕时间（小时）
    var socialScreenTime: Double?

    /// 月经周期第几天（nil = 不在周期内或未记录）
    var menstrualDay: Int?

    /// 预计下次来潮日
    var nextPeriodDate: Date?

    /// 今日推特发帖条数（Phase 2 由 Twitter MCP 填入）
    var tweetCount: Int?

    /// 最近一条推特摘要
    var latestTweetSummary: String?

    // MARK: - Derived helpers

    /// 睡眠时长（小时），两端都有记录时才计算
    var sleepDuration: Double? {
        guard let start = sleepStart, let end = sleepEnd else { return nil }
        return max(0, end.timeIntervalSince(start) / 3600)
    }

    /// 最近一餐（时间最晚的那条）
    var latestMeal: MealEntry? {
        meals.max(by: { $0.time < $1.time })
    }

    // MARK: - init

    init(
        date: Date = Calendar.current.startOfDay(for: Date()),
        waterCount: Int = 0,
        meals: [MealEntry] = [],
        medicationStatus: MedicationStatus = .pending,
        medicationName: String = "右佐匹克隆",
        sleepStart: Date? = nil,
        sleepEnd: Date? = nil,
        steps: Int? = nil,
        screenTime: Double? = nil,
        socialScreenTime: Double? = nil,
        menstrualDay: Int? = nil,
        nextPeriodDate: Date? = nil,
        tweetCount: Int? = nil,
        latestTweetSummary: String? = nil
    ) {
        self.date = date
        self.waterCount = waterCount
        self.meals = meals
        self.medicationStatus = medicationStatus
        self.medicationName = medicationName
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.steps = steps
        self.screenTime = screenTime
        self.socialScreenTime = socialScreenTime
        self.menstrualDay = menstrualDay
        self.nextPeriodDate = nextPeriodDate
        self.tweetCount = tweetCount
        self.latestTweetSummary = latestTweetSummary
    }
}
#endif
