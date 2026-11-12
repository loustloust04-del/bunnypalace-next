#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import Foundation
import HealthKit

// MARK: - HealthKit result types

struct HealthSleepRecord {
    var startDate: Date
    var endDate: Date
    var durationHours: Double { max(0, endDate.timeIntervalSince(startDate) / 3600) }
}

struct HealthStepsRecord {
    var count: Int
    var date: Date
}

// MARK: - HealthKitService

/// 封装 HealthKit 数据读取。
///
/// ⚠️  ESign 签名可能不支持 HealthKit entitlement。
/// 所有方法在 HealthKit 不可用 / 授权被拒时静默返回 nil，
/// 不影响其他功能。
@Observable
final class HealthKitService {

    // MARK: State

    enum AuthState {
        case unknown
        case authorized
        case denied
        case unavailable   // HealthKit 不在此设备上（模拟器 / 非 iPhone）
    }

    var authState: AuthState = .unknown

    private let store = HKHealthStore()

    // MARK: - Read types

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            types.insert(steps)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        if let heart = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            types.insert(heart)
        }
        if let spo2 = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            types.insert(spo2)
        }
        if let flow = HKObjectType.categoryType(forIdentifier: .menstrualFlow) {
            types.insert(flow)
        }
        return types
    }

    // MARK: - Authorization

    /// 向用户请求 HealthKit 授权。
    /// 调用时机：ConsoleView 首次出现时。
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            authState = .unavailable
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            authState = .authorized
        } catch {
            authState = .denied
        }
    }

    // MARK: - Steps (今日)

    /// 读取今日步数。返回 nil 表示未授权或无数据。
    func fetchTodaySteps() async -> Int? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return nil
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: Date(),
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                let count = stats?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: Int(count))
            }
            store.execute(query)
        }
    }

    // MARK: - Sleep (最近一次)

    /// 读取最近一次完整睡眠记录（asleep 阶段）。
    func fetchLatestSleep() async -> HealthSleepRecord? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return nil
        }

        // 只取 asleep 状态，忽略 inBed
        let asleepValues: [HKCategoryValueSleepAnalysis] = [
            .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM
        ]
        let valuePredicate = NSCompoundPredicate(orPredicateWithSubpredicates:
            asleepValues.map {
                HKQuery.predicateForCategorySamples(
                    with: .equalTo,
                    value: $0.rawValue
                )
            }
        )

        // 过去 24 小时
        let yesterday = Date().addingTimeInterval(-86400)
        let timePredicate = HKQuery.predicateForSamples(
            withStart: yesterday,
            end: Date(),
            options: .strictStartDate
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            timePredicate, valuePredicate
        ])

        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: 20,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                // 合并连续片段：取最早 start — 最晚 end
                let start = samples.map(\.startDate).min() ?? samples[0].startDate
                let end   = samples.map(\.endDate).max()   ?? samples[0].endDate
                continuation.resume(returning: HealthSleepRecord(startDate: start, endDate: end))
            }
            self.store.execute(query)
        }
    }

    // MARK: - Menstrual flow (最近记录)

    /// 读取最近一次月经记录，返回当前周期第几天（粗估）。
    /// 月经周期精确追踪需要用 HKCategoryTypeIdentifierMenstrualFlow 的完整历史，
    /// Phase 1 只做简单"最近来潮日距今多少天"。
    func fetchMenstrualDay() async -> Int? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        guard let flowType = HKObjectType.categoryType(forIdentifier: .menstrualFlow) else {
            return nil
        }

        // 只取有血流量的样本（排除 none）
        let predicate = HKQuery.predicateForCategorySamples(
            with: .greaterThan,
            value: HKCategoryValueMenstrualFlow.none.rawValue
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: flowType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let sample = (samples as? [HKCategorySample])?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let days = Calendar.current.dateComponents(
                    [.day],
                    from: sample.startDate,
                    to: Date()
                ).day ?? 0
                // "周期第几天"从 1 开始计
                continuation.resume(returning: max(1, days + 1))
            }
            self.store.execute(query)
        }
    }

    /// 读取最近约 12 个月的月经流量样本，聚类成「每次来潮」，返回每次来潮的首日（YYYY-MM-DD）。
    /// 相邻样本间隔 ≥2 天视为新一次来潮。用于同步到网关做周期预测。
    func fetchMenstrualStarts(monthsBack: Int = 12) async -> [String] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        guard let flowType = HKObjectType.categoryType(forIdentifier: .menstrualFlow) else { return [] }
        let cal = Calendar.current
        let startDate = cal.date(byAdding: .month, value: -monthsBack, to: Date())
        // 只按日期范围查——不再按 flow>none 筛（那会漏掉「只标经期、没填流量」的记录）。
        // 经期起始靠 HKMetadataKeyMenstrualCycleStart 元数据判断，退回用间隔。
        let datePred = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: flowType, predicate: datePred,
                limit: HKObjectQueryNoLimit, sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                // 1) 优先：Apple 健康给每次经期第一天打的「周期开始」元数据
                var startSet = Set<String>()
                for sample in samples {
                    if (sample.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool) == true {
                        startSet.insert(fmt.string(from: cal.startOfDay(for: sample.startDate)))
                    }
                }
                // 2) 没有元数据标记时，退回「相邻记录间隔 ≥2 天 = 新一次来潮」
                if startSet.isEmpty {
                    var prevDay: Date?
                    for sample in samples {
                        let day = cal.startOfDay(for: sample.startDate)
                        if let prev = prevDay {
                            if (cal.dateComponents([.day], from: prev, to: day).day ?? 0) >= 2 {
                                startSet.insert(fmt.string(from: day))
                            }
                        } else {
                            startSet.insert(fmt.string(from: day))
                        }
                        prevDay = day
                    }
                }
                continuation.resume(returning: startSet.sorted())
            }
            self.store.execute(query)
        }
    }

    // MARK: - Populate DailyContext

    /// 读取所有 HealthKit 数据并写入 DailyContext。
    /// 如果某项数据无法获取则跳过，不覆盖已有手动数据。
    func populate(context: DailyContext) async {
        async let steps = fetchTodaySteps()
        async let sleep = fetchLatestSleep()
        async let menstrual = fetchMenstrualDay()

        let (stepsResult, sleepResult, menstrualResult) =
            await (steps, sleep, menstrual)

        if let s = stepsResult {
            context.steps = s
        }
        if let sl = sleepResult {
            context.sleepStart = sl.startDate
            context.sleepEnd   = sl.endDate
        }
        if let m = menstrualResult, context.menstrualDay == nil {
            // 只在手动记录缺失时才写 HealthKit 值
            context.menstrualDay = m
        }
    }

    // MARK: - Heart Rate (Watch placeholder)

    /// 读取最近一次心率。有 Apple Watch 时自动有数据，没有则返回 nil。
    func fetchHeartRate() async -> Int? {
        guard let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.date(byAdding: .hour, value: -1, to: Date()), end: Date())
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: heartType, predicate: predicate)], sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 1)
        guard let result = try? await descriptor.result(for: store).first else { return nil }
        return Int(result.quantity.doubleValue(for: HKUnit(from: "count/min")))
    }

    // MARK: - Blood Oxygen (Watch placeholder)

    /// 读取最近一次血氧。有 Apple Watch 时自动有数据，没有则返回 nil。
    func fetchBloodOxygen() async -> Double? {
        guard let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.date(byAdding: .hour, value: -2, to: Date()), end: Date())
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: spo2Type, predicate: predicate)], sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 1)
        guard let result = try? await descriptor.result(for: store).first else { return nil }
        return result.quantity.doubleValue(for: HKUnit.percent()) * 100
    }
}
#endif
