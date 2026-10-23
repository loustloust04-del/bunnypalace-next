import Foundation
import SwiftUI
#if canImport(HealthKit)
import HealthKit
#endif

/// 苹果健康接入。iOS 真实现（读 5 项 → 今日快照），macOS 永远 stub（HealthKit 不存在）。
///
/// 注入路径：`injectedSummary` 经注入闸返回今日摘要，`{{health}}` 宏读它。
/// 真实发送（ConversationViewModel）和检查器预览（PersonaSettingsTab）共用同一个 `injectedSummary`。
@Observable
final class HealthService {
    static let shared = HealthService()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let injectionEnabled = "health.injectionEnabled"
        static let authRequested = "health.authRequested"
    }

    /// 今日快照。Mac 端永远 nil。
    private(set) var snapshot: HealthSnapshot?

    /// 聊天时是否注入健康（设置页 Toggle）。默认开。
    var injectionEnabled: Bool {
        didSet { defaults.set(injectionEnabled, forKey: Keys.injectionEnabled) }
    }

    /// 是否已请求过授权（决定设置页按钮文案）。
    private(set) var authRequested: Bool {
        didSet { defaults.set(authRequested, forKey: Keys.authRequested) }
    }

    private init() {
        injectionEnabled = defaults.object(forKey: Keys.injectionEnabled) as? Bool ?? false   // §4 默认收紧（老装机迁移写显式值）
        authRequested = defaults.bool(forKey: Keys.authRequested)
    }

    var isAvailable: Bool {
        #if canImport(HealthKit)
        HKHealthStore.isHealthDataAvailable()
        #else
        false
        #endif
    }

    var todaySummary: String { snapshot?.summaryLine ?? "" }

    /// 注入闸：可用 && 开关开。
    /// X5 本地模式落地后，在此 AND 上 `!LocalMode.shared.isOn` 即可（本轮不做 X5）。
    var shouldInject: Bool {
        isAvailable && injectionEnabled
        // && !LocalMode.shared.isOn   // TODO(X5): 本地模式下不注入健康
    }

    /// `{{health}}` 宏读这个。闸关 / 不可用 / 无数据 → ""（插槽自动跳过）。
    var injectedSummary: String { shouldInject ? todaySummary : "" }

    @MainActor private func setSnapshot(_ s: HealthSnapshot) { snapshot = s }
    @MainActor private func setAuthRequested(_ v: Bool) { authRequested = v }

    // MARK: - iOS 真实现

    #if canImport(HealthKit)
    private let store = HKHealthStore()
    private let heartRateUnit = HKUnit.count().unitDivided(by: .minute())

    private var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.restingHeartRate),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType()
        ]
    }

    func requestAuthorization() async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            await setAuthRequested(true)
            await refreshToday()
        } catch {
            // 拒绝授权或出错 → 保持空快照，不抛
        }
    }

    func refreshToday() async {
        guard isAvailable else { return }
        async let steps = todaySum(.stepCount, unit: .count())
        async let energy = todaySum(.activeEnergyBurned, unit: .kilocalorie())
        async let hr = latestToday(.restingHeartRate, unit: heartRateUnit)
        async let sleep = lastNightSleepHours()
        async let workout = lastWorkoutToday()

        let snap = HealthSnapshot(
            date: Date(),
            steps: (await steps).map { Int($0.rounded()) },
            sleepHours: await sleep,
            activeEnergyKcal: (await energy).map { Int($0.rounded()) },
            restingHeartRate: (await hr).map { Int($0.rounded()) },
            lastWorkout: await workout
        )
        await setSnapshot(snap)
    }

    private func todaySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let datePredicate = HKQuery.predicateForSamples(
            withStart: Calendar.current.startOfDay(for: Date()), end: Date(), options: .strictStartDate
        )
        let predicate = HKSamplePredicate.quantitySample(type: HKQuantityType(id), predicate: datePredicate)
        let descriptor = HKStatisticsQueryDescriptor(predicate: predicate, options: .cumulativeSum)
        do {
            let stats = try await descriptor.result(for: store)
            return stats?.sumQuantity()?.doubleValue(for: unit)
        } catch { return nil }
    }

    private func latestToday(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let datePredicate = HKQuery.predicateForSamples(
            withStart: Calendar.current.startOfDay(for: Date()), end: Date()
        )
        let predicate = HKSamplePredicate.quantitySample(type: HKQuantityType(id), predicate: datePredicate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [predicate],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        do {
            let samples = try await descriptor.result(for: store)
            return samples.first?.quantity.doubleValue(for: unit)
        } catch { return nil }
    }

    private func lastNightSleepHours() async -> Double? {
        // 昨晚窗口：往前 18 小时到现在，覆盖一夜睡眠
        guard let start = Calendar.current.date(byAdding: .hour, value: -18, to: Date()) else { return nil }
        let datePredicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let predicate = HKSamplePredicate.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: datePredicate)
        let descriptor = HKSampleQueryDescriptor(predicates: [predicate], sortDescriptors: [], limit: nil)
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]
        do {
            let samples = try await descriptor.result(for: store)
            let seconds = samples
                .filter { asleep.contains($0.value) }
                .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            return seconds > 0 ? seconds / 3600.0 : nil
        } catch { return nil }
    }

    private func lastWorkoutToday() async -> WorkoutBrief? {
        let datePredicate = HKQuery.predicateForSamples(
            withStart: Calendar.current.startOfDay(for: Date()), end: Date()
        )
        let predicate = HKSamplePredicate.workout(datePredicate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [predicate],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        do {
            guard let w = try await descriptor.result(for: store).first else { return nil }
            let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
            return WorkoutBrief(
                typeName: Self.name(for: w.workoutActivityType),
                date: w.endDate,
                durationMinutes: Int((w.duration / 60).rounded()),
                energyKcal: kcal.map { Int($0.rounded()) }
            )
        } catch { return nil }
    }

    private static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .yoga: return "瑜伽"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .coreTraining: return "核心训练"
        case .hiking: return "徒步"
        case .elliptical: return "椭圆机"
        case .rowing: return "划船"
        case .highIntensityIntervalTraining: return "高强度间歇"
        case .cooldown: return "拉伸放松"
        default: return "运动"
        }
    }
    #else

    // MARK: - macOS stub
    func requestAuthorization() async {}
    func refreshToday() async {}

    #endif
}
