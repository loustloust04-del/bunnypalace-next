import Foundation

// MARK: - 健康卡详情统计（plan-health-card-details）
// 全部纯函数：热图/依从率/漏服/月均/月频次。口径拍板：只算计划内 slot（计划外补服不进），
// 每种药从 createdAt 当天起算（更早的天不欠账）。

enum HealthStatsStore {

    /// 一天的计划内完成度：taken 数 / 计划 slot 数。无计划（无药/都早于 createdAt/未来日）= nil。
    static func dayCompletion(meds: [Medication], logs: [MedicationLog], day: Date, now: Date, calendar: Calendar = .current) -> Double? {
        let dayStart = calendar.startOfDay(for: day)
        guard dayStart <= calendar.startOfDay(for: now) else { return nil }
        var planned = 0
        var taken = 0
        for med in meds {
            guard calendar.startOfDay(for: med.createdAt) <= dayStart else { continue }
            for minute in med.timesOfDay {
                let slot = HealthLogStore.scheduledDate(minuteOfDay: minute, on: dayStart, calendar: calendar)
                guard slot <= now else { continue }   // 今天未到点的 slot 不算欠
                planned += 1
                if logs.contains(where: { $0.medicationId == med.id && $0.scheduledAt == slot }) {
                    taken += 1
                }
            }
        }
        guard planned > 0 else { return nil }
        return Double(taken) / Double(planned)
    }

    /// 月历热图数据：该月每个 <= 今天的天 → 完成度（无计划的天不出现在字典里）。
    static func medMonthCompletion(meds: [Medication], logs: [MedicationLog], month: Date, now: Date, calendar: Calendar = .current) -> [Date: Double] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [:] }
        var result: [Date: Double] = [:]
        var d = interval.start
        while d < interval.end {
            if let c = dayCompletion(meds: meds, logs: logs, day: d, now: now, calendar: calendar) {
                result[d] = c
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return result
    }

    /// 单药近 N 天依从率（含今天）。无计划 slot = nil。
    static func medAdherence(med: Medication, logs: [MedicationLog], days: Int, now: Date, calendar: Calendar = .current) -> Double? {
        var planned = 0
        var taken = 0
        let today = calendar.startOfDay(for: now)
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            guard calendar.startOfDay(for: med.createdAt) <= day else { continue }
            for minute in med.timesOfDay {
                let slot = HealthLogStore.scheduledDate(minuteOfDay: minute, on: day, calendar: calendar)
                guard slot <= now else { continue }
                planned += 1
                if logs.contains(where: { $0.medicationId == med.id && $0.scheduledAt == slot }) {
                    taken += 1
                }
            }
        }
        guard planned > 0 else { return nil }
        return Double(taken) / Double(planned)
    }

    /// 单药近 N 天漏服 slot 数（计划内未打卡；今天只算已过点 2h 缓冲的）。
    static func medMissCount(med: Medication, logs: [MedicationLog], days: Int, now: Date, calendar: Calendar = .current) -> Int {
        var missed = 0
        let today = calendar.startOfDay(for: now)
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            guard calendar.startOfDay(for: med.createdAt) <= day else { continue }
            for minute in med.timesOfDay {
                let slot = HealthLogStore.scheduledDate(minuteOfDay: minute, on: day, calendar: calendar)
                guard now.timeIntervalSince(slot) > HealthLogStore.missedGrace else { continue }
                if !logs.contains(where: { $0.medicationId == med.id && $0.scheduledAt == slot }) {
                    missed += 1
                }
            }
        }
        return missed
    }

    /// 体重按月聚合平均（升序）。
    static func weightMonthlyAvg(entries: [WeightEntry], calendar: Calendar = .current) -> [(month: Date, avgKg: Double)] {
        var buckets: [Date: [Double]] = [:]
        for e in entries {
            guard let m = calendar.dateInterval(of: .month, for: e.date)?.start else { continue }
            buckets[m, default: []].append(e.weightKg)
        }
        return buckets
            .map { (month: $0.key, avgKg: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.month < $1.month }
    }

    /// 亲密近 N 个月每月次数（升序，含无记录月=0）。
    static func intimacyMonthlyCount(entries: [IntimacyEntry], months: Int, now: Date, calendar: Calendar = .current) -> [(month: Date, count: Int)] {
        guard months > 0, let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        var result: [(month: Date, count: Int)] = []
        for offset in stride(from: months - 1, through: 0, by: -1) {
            guard let m = calendar.date(byAdding: .month, value: -offset, to: thisMonth) else { continue }
            let count = entries.filter { calendar.dateInterval(of: .month, for: $0.date)?.start == m }.count
            result.append((month: m, count: count))
        }
        return result
    }
}
