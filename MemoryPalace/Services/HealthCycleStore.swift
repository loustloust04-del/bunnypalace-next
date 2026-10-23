import Foundation
import SwiftData

// MARK: - 月经追踪（plan-health-cycle）
// per-day flow 打点，经期/周期/预测全是纯函数推导不落库。

enum CycleFlow: String, CaseIterable {
    case spotting, light, medium, heavy

    var label: String {
        switch self {
        case .spotting: return "点滴"
        case .light: return "少"
        case .medium: return "中"
        case .heavy: return "多"
        }
    }

    /// 宽容解析：英文 raw 或中文档名（writer 用）。
    static func parse(_ s: String) -> CycleFlow? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let f = CycleFlow(rawValue: t) { return f }
        return allCases.first { $0.label == t }
    }
}

/// 一次经期（连续打点聚合段）。
struct CyclePeriod: Equatable {
    let start: Date       // startOfDay
    let end: Date
    let dayCount: Int
}

struct CyclePrediction: Equatable {
    let averageLength: Int    // 天
    let nextStart: Date       // startOfDay
    let windowStart: Date     // ±2 天窗
    let windowEnd: Date
}

enum HealthCycleStore {

    /// 相邻打点日期差 ≤ 这个天数算同一段经期（漏记一天不断周期）。
    static let sameSpellMaxGap = 2
    /// 周期长度合理域：域外脏值不进预测。
    static let sanityLengths = 15...90
    /// 预测取最近这么多个周期长度平均。
    static let predictionWindow = 6

    // MARK: - 打点（同 WeightEntry 手写 upsert）

    static func upsertDay(context: ModelContext, profileId: String, date: Date, flow: CycleFlow) {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<CycleDay>(
            predicate: #Predicate { $0.profileId == profileId && $0.date == day }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.flow = flow.rawValue
        } else {
            context.insert(CycleDay(profileId: profileId, date: day, flow: flow.rawValue))
        }
        try? context.save()
    }

    static func removeDay(context: ModelContext, profileId: String, date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        let descriptor = FetchDescriptor<CycleDay>(
            predicate: #Predicate { $0.profileId == profileId && $0.date == day }
        )
        for d in (try? context.fetch(descriptor)) ?? [] {
            context.delete(d)
        }
        try? context.save()
    }

    /// 面板四档点选语义：点同档=取消今天，点别档=改档/新记。返回操作后今天的档（nil=取消了）。
    @discardableResult
    static func toggleToday(context: ModelContext, profileId: String, flow: CycleFlow, now: Date = Date()) -> CycleFlow? {
        let today = fetchDay(context: context, profileId: profileId, date: now)
        if today?.flow == flow.rawValue {
            removeDay(context: context, profileId: profileId, date: now)
            return nil
        }
        upsertDay(context: context, profileId: profileId, date: now, flow: flow)
        return flow
    }

    static func fetchDay(context: ModelContext, profileId: String, date: Date) -> CycleDay? {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<CycleDay>(
            predicate: #Predicate { $0.profileId == profileId && $0.date == day }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// 全量打点（预测/聚合用）。量级 = 使用年数 × 每月 ~5 条，limit 兜底。
    static func fetchDays(context: ModelContext, profileId: String, limit: Int = 800) -> [CycleDay] {
        var descriptor = FetchDescriptor<CycleDay>(
            predicate: #Predicate { $0.profileId == profileId },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 聚合 / 预测（纯函数）

    static func periods(days: [CycleDay], calendar: Calendar = .current) -> [CyclePeriod] {
        let sorted = days.map(\.date).sorted()
        guard !sorted.isEmpty else { return [] }
        var result: [CyclePeriod] = []
        var start = sorted[0]
        var prev = sorted[0]
        var count = 1
        for date in sorted.dropFirst() {
            let gap = calendar.dateComponents([.day], from: prev, to: date).day ?? 0
            if gap <= sameSpellMaxGap {
                count += 1
            } else {
                result.append(CyclePeriod(start: start, end: prev, dayCount: count))
                start = date
                count = 1
            }
            prev = date
        }
        result.append(CyclePeriod(start: start, end: prev, dayCount: count))
        return result
    }

    /// 相邻两段 start 差（天），域外脏值过滤。
    static func cycleLengths(periods: [CyclePeriod], calendar: Calendar = .current) -> [Int] {
        zip(periods, periods.dropFirst())
            .compactMap { calendar.dateComponents([.day], from: $0.start, to: $1.start).day }
            .filter { sanityLengths.contains($0) }
    }

    static func prediction(periods: [CyclePeriod], calendar: Calendar = .current) -> CyclePrediction? {
        guard let last = periods.last else { return nil }
        let lengths = cycleLengths(periods: periods, calendar: calendar)
        guard !lengths.isEmpty else { return nil }   // <2 段（或全脏值）= 数据不足
        let recent = lengths.suffix(predictionWindow)
        let avg = Int((Double(recent.reduce(0, +)) / Double(recent.count)).rounded())
        guard let next = calendar.date(byAdding: .day, value: avg, to: last.start),
              let ws = calendar.date(byAdding: .day, value: -2, to: next),
              let we = calendar.date(byAdding: .day, value: 2, to: next) else { return nil }
        return CyclePrediction(averageLength: avg, nextStart: next, windowStart: ws, windowEnd: we)
    }

    /// 周期第 N 天（从最近一段经期首日起算）。无记录 = nil。
    static func currentCycleDay(periods: [CyclePeriod], now: Date, calendar: Calendar = .current) -> Int? {
        guard let last = periods.last else { return nil }
        guard let days = calendar.dateComponents([.day], from: last.start, to: calendar.startOfDay(for: now)).day,
              days >= 0 else { return nil }
        return days + 1
    }

    // MARK: - 文案（卡片与注入共用底料，无人称）

    /// 卡片状态行。
    static func statusLine(todayFlow: CycleFlow?, periods: [CyclePeriod], now: Date, calendar: Calendar = .current) -> String {
        if let todayFlow, let day = currentCycleDay(periods: periods, now: now, calendar: calendar) {
            return "经期第 \(day) 天 · 经量\(todayFlow.label)"
        }
        guard let pred = prediction(periods: periods, calendar: calendar),
              let until = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: pred.nextStart).day else {
            return "记录不足，暂无预测"
        }
        if until > 1 { return "距下次预计还有 \(until) 天" }
        if until >= -2 { return "预计这两天会来" }
        return "比预计晚了 \(-until) 天"
    }

    /// AI 注入段（闸在 HealthLogStore.composedHealthSummary 收口）。无数据 = ""。
    static func injectionLine(todayFlow: CycleFlow?, periods: [CyclePeriod], now: Date, calendar: Calendar = .current) -> String {
        if let todayFlow, let day = currentCycleDay(periods: periods, now: now, calendar: calendar) {
            return "月经周期第 \(day) 天（经量\(todayFlow.label)）。"
        }
        guard let pred = prediction(periods: periods, calendar: calendar),
              let until = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: pred.nextStart).day else {
            return ""
        }
        if until > 1 { return "预计 \(until) 天后来月经。" }
        if until >= -2 { return "预计这两天来月经。" }
        return "月经比预计晚了 \(-until) 天。"
    }
}
