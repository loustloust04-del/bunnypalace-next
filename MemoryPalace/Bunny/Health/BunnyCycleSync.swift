import Foundation
import SwiftData

// MARK: - [Bunny] 经期双向同步：上游 CycleDay（按天、带流量） ↔ 网关 /api/period（按次：来潮日 + 结束日）
//
// 网关这份也是 Caelum period_* 工具与 Console「距下次预计」的数据源。粒度不同，只同步「这一次从哪天到哪天」：
//   本地 → 网关：本地经期日（不算「点滴」）按连续日聚成一次次（间隔 ≤1 天算同一次），
//                网关没有的来潮日用 /api/period/sync 补上（网关按日期去重），有结束日的用 /api/period/end 写结束日。
//   网关 → 本地：本地没有任何经期日落在那次范围里的，按 来潮日…结束日 补本地记录（没结束日只补来潮日），
//                流量记「中等」、备注「网关同步」——流量是占位，她可以在健康里改。
// 不同步删除。来潮日差 2 天以内视为同一次（App 与 Caelum 记的日子可能差一点）。

@MainActor
enum BunnyCycleSync {
    static var lastRunAt: Date? { UserDefaults.standard.object(forKey: "bunny.cycle.lastRunAt") as? Date }

    static func runIfDue(context: ModelContext, profileId: String, minInterval: TimeInterval = 10 * 60) async {
        guard BunnyGateway.isConfigured, !profileId.isEmpty else { return }
        if let last = lastRunAt, Date().timeIntervalSince(last) < minInterval { return }
        _ = await run(context: context, profileId: profileId)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @discardableResult
    static func run(context: ModelContext, profileId pid: String) async -> String {
        guard let snap = await PeriodClient.fetch() else { return "❌ 拿不到网关经期数据" }
        UserDefaults.standard.set(Date(), forKey: "bunny.cycle.lastRunAt")
        let cal = Calendar.current
        let days = ((try? context.fetch(FetchDescriptor<CycleDay>(predicate: #Predicate { $0.profileId == pid }))) ?? [])
            .filter { $0.flow != "spotting" }
            .map { cal.startOfDay(for: $0.date) }
        let uniqueDays = Array(Set(days)).sorted()

        // 本地聚成一次次
        var runs: [(start: Date, end: Date)] = []
        for d in uniqueDays {
            if let last = runs.last, let gap = cal.dateComponents([.day], from: last.end, to: d).day, gap <= 2 {
                runs[runs.count - 1].end = d
            } else {
                runs.append((d, d))
            }
        }

        func date(_ s: String?) -> Date? { s.flatMap { dayFmt.date(from: $0) }.map { cal.startOfDay(for: $0) } }
        let remote: [(start: Date, end: Date?, raw: String)] = snap.events.compactMap { e in
            guard let s = date(e.date) else { return nil }
            return (s, date(e.end), e.date)
        }
        func near(_ a: Date, _ b: Date) -> Bool { abs(cal.dateComponents([.day], from: a, to: b).day ?? 99) <= 2 }

        // 本地 → 网关
        var newStarts: [String] = []
        var ends: [(start: String, end: String)] = []
        for r in runs {
            if let m = remote.first(where: { near($0.start, r.start) }) {
                if r.end > r.start, m.end.map({ !cal.isDate($0, inSameDayAs: r.end) }) ?? true {
                    ends.append((m.raw, dayFmt.string(from: r.end)))
                }
            } else {
                newStarts.append(dayFmt.string(from: r.start))
                if r.end > r.start { ends.append((dayFmt.string(from: r.start), dayFmt.string(from: r.end))) }
            }
        }
        var pushed = 0
        if !newStarts.isEmpty { pushed = await PeriodClient.sync(dates: newStarts, source: "app") }
        var endsSet = 0
        for e in ends {
            if (try? await BunnyGateway.post("/api/period/end", json: ["start": e.start, "end": e.end])) != nil { endsSet += 1 }
        }

        // 网关 → 本地
        var added = 0
        for e in remote {
            let end = e.end ?? e.start
            guard !runs.contains(where: { $0.start <= end && $0.end >= e.start || near($0.start, e.start) }) else { continue }
            var d = e.start
            var guardCount = 0
            while d <= end && guardCount < 14 {
                let c = CycleDay(profileId: pid, date: d, flow: "medium")
                c.note = "网关同步"
                context.insert(c)
                added += 1
                guardCount += 1
                guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
        }
        if added > 0 { try? context.save() }
        return "✅ 本地 \(runs.count) 次、网关 \(remote.count) 次；推上来潮日 \(pushed)、结束日 \(endsSet)；补到本地 \(added) 天"
    }
}
