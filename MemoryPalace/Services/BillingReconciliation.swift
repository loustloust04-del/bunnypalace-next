import Foundation

struct BillingDay: Identifiable, Equatable, Sendable {
    let date: Date
    let ledgerUSD: Double
    let supplierUSD: Double?
    var scopeVerified = true
    var id: Date { date }
    var differencePercent: Double? {
        guard scopeVerified, let supplierUSD else { return nil }
        if supplierUSD == 0 { return ledgerUSD == 0 ? 0 : .infinity }
        return (ledgerUSD - supplierUSD) / supplierUSD * 100
    }
    var mismatched: Bool { differencePercent.map { abs($0) > 1 } ?? false }
}

struct BillingReport: Sendable {
    var dailyUSD: [Date: Double] = [:]
    var note: String?
    var scopeVerified = true
    var reportDate: Date? = nil
    var dateUncertain = false
}

struct BillingReconciliation: Sendable {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    var fetch: @Sendable (URLRequest) async throws -> Data = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    var clock: @Sendable () -> Date = { Date() }

    func load(provider: BillingProvider, key: String, now: Date = Date()) async throws -> BillingReport {
        var started = now
        for _ in 0..<2 {
            var report = try await loadOnce(provider: provider, key: key, now: started)
            let finished = clock()
            if Self.calendar.startOfDay(for: started) == Self.calendar.startOfDay(for: finished) {
                report.reportDate = finished
                return report
            }
            started = finished
        }
        return BillingReport(note: "跨日，稍后再看", scopeVerified: false, reportDate: started, dateUncertain: true)
    }

    private func loadOnce(provider: BillingProvider, key: String, now: Date) async throws -> BillingReport {
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        if provider == .openRouter {
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!, timeoutInterval: 15)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let data = try await fetch(request)
            return try Self.parse(data, provider: provider, now: now).report
        }
        var report = BillingReport()
        var page: String?
        var seenPages = Set<String>()
        repeat {
            let anthropic = provider == .anthropic
            var url = URLComponents(string: anthropic ? "https://api.anthropic.com/v1/organizations/cost_report" : "https://api.openai.com/v1/organization/costs")!
            let iso = ISO8601DateFormatter()
            var query = anthropic
                ? [URLQueryItem(name: "starting_at", value: iso.string(from: start)), URLQueryItem(name: "ending_at", value: iso.string(from: end))]
                : [URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))), URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970)))]
            query.append(URLQueryItem(name: "limit", value: "7"))
            if !anthropic { query.append(URLQueryItem(name: "bucket_width", value: "1d")) }
            if let page { query.append(URLQueryItem(name: "page", value: page)) }
            url.queryItems = query
            var request = URLRequest(url: url.url!, timeoutInterval: 15)
            request.setValue(anthropic ? key : "Bearer \(key)", forHTTPHeaderField: anthropic ? "x-api-key" : "Authorization")
            if anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
            let data = try await fetch(request)
            let parsed = try Self.parse(data, provider: provider, now: now)
            for (day, cost) in parsed.report.dailyUSD { report.dailyUSD[day, default: 0] += cost }
            page = parsed.nextPage
            if let page, !seenPages.insert(page).inserted { throw URLError(.cannotParseResponse) }
        } while page != nil
        report.scopeVerified = false // Admin key 的组织与聊天卡片没有可验证映射，禁止按 host 猜组织。
        report.note = provider == .anthropic
            ? "UTC 日账；组织费用可能含其他设备 / workspace，Cost API 不含 Priority Tier。"
            : "UTC 日账；组织费用可能含其他应用 / project，不等同于本机账本范围。"
        return report
    }

    static func parse(_ data: Data, provider: BillingProvider, now: Date) throws -> (report: BillingReport, nextPage: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        func number(_ value: Any?) -> Double? {
            let value = (value as? Double) ?? (value as? String).flatMap(Double.init)
            return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        if provider == .openRouter {
            guard let key = root["data"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
            // /key 只有当前 UTC 日 / 周 / 月汇总，没有历史逐日序列；请求跨日由 load 重查。
            let daily = number(key["usage_daily"])
            let day = calendar.startOfDay(for: now)
            return (BillingReport(dailyUSD: daily.map { [day: $0] } ?? [:],
                                  note: daily == nil ? "接口未返回 usage_daily，保留本机账本；周 / 月汇总无法拆成逐日。" : "所选 key 的当前 UTC 日汇总；此前 6 天接口未提供，不能由周汇总摊算。"), nil)
        }
        guard let buckets = root["data"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        var daily: [Date: Double] = [:]
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for bucket in buckets {
            let date: Date?
            if provider == .anthropic, let start = bucket["starting_at"] as? String {
                date = iso.date(from: start) ?? fractional.date(from: start)
            } else { date = number(bucket["start_time"]).map(Date.init(timeIntervalSince1970:)) }
            guard let date, let results = bucket["results"] as? [[String: Any]] else { continue }
            var total = 0.0
            var valid = true
            for result in results {
                if provider == .anthropic {
                    guard let amount = number(result["amount"]), (result["currency"] as? String)?.lowercased() == "usd" else { valid = false; break }
                    total += amount / 100
                } else {
                    guard let amount = result["amount"] as? [String: Any], let value = number(amount["value"]),
                          (amount["currency"] as? String)?.lowercased() == "usd" else { valid = false; break }
                    total += value
                }
            }
            if valid { daily[calendar.startOfDay(for: date), default: 0] += total }
        }
        let more = root["has_more"] as? Bool ?? false
        let page = root["next_page"] as? String
        if more && page == nil { throw URLError(.cannotParseResponse) }
        return (BillingReport(dailyUSD: daily), more ? page : nil)
    }

    static func days(now: Date, records: [UsageRecord], report: BillingReport) -> [BillingDay] {
        let today = calendar.startOfDay(for: now)
        let records = UsageLedger.latestRecords(records)
        return (-6...0).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: day)!
            let total = records.filter { $0.time >= day && $0.time < end && !$0.subscription && !$0.tokensOnly }
                .reduce(0) { $0 + ($1.cost(price: { PricingCatalog.price(for: $0) }) ?? 0) }
            return BillingDay(date: day, ledgerUSD: total, supplierUSD: report.dailyUSD[day], scopeVerified: report.scopeVerified)
        }
    }
}
