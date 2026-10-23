#if PERSONAL_APPS
import Foundation
import SwiftData

/// 交易模块无状态函数层（HealthLogStore 同构：无 actor 隔离，CVM 组装路径非隔离也要调）。
/// 闸统一在 composedTradingSummary 收口；研报 = 文件库 `trading/<symbol>/` 目录扫描 + frontmatter 解析。
enum TradingStore {

    // MARK: - AI 可见闸（敏感类默认关，object(forKey:) 写法区分"没设过"与 false）

    static let watchlistGateKey = "trading.inject.watchlist"

    static var watchlistGateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: watchlistGateKey) as? Bool ?? false }
        set { PermissionCenter.setLevel(newValue ? .bypass : .notAllowed, for: .trading) }   // 委托：防失同步
    }

    // MARK: - 研报（axismundi 产物，md + frontmatter）

    struct ReportMeta: Identifiable, Hashable {
        var path: String
        var date: String        // frontmatter date，缺省取文件名前缀
        var rating: String?     // Buy/Overweight/Hold/Underweight/Sell/Abstain
        var confidence: String?
        var kind: String?       // frontmatter type：nil/initiate=全量，update=增量复核
        var id: String { path }
    }

    /// `trading/<symbol>/` 下全部 md，按 date 倒序（最新在前）。
    static func reports(symbol: String, profileId: String) -> [ReportMeta] {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("TradingStore.reports") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        let prefix = "trading/\(symbol)/"
        return reportMetas(paths: reportPaths(symbol: symbol, profileId: profileId), prefix: prefix, profileId: profileId)
            .sorted { $0.date > $1.date }
    }

    /// 修全局卡顿：组 prompt 每个自选股都要这条——清单走缓存，只读最新那一份（文件名以日期开头），不再把该股所有研报读一遍
    /// `files`：调用方一次取好的清单（composedTradingSummary 给所有自选股共用一份）；nil = 自己取缓存
    static func latestReport(symbol: String, profileId: String, files: [FileLibraryStore.FileMeta]? = nil) -> ReportMeta? {
        let prefix = "trading/\(symbol)/"
        guard let newest = reportPaths(symbol: symbol, profileId: profileId, files: files).max(by: { $0 < $1 }) else { return nil }
        return reportMetas(paths: [newest], prefix: prefix, profileId: profileId).first
    }

    private static func reportPaths(symbol: String, profileId: String, files: [FileLibraryStore.FileMeta]? = nil) -> [String] {
        let prefix = "trading/\(symbol)/"
        return (files ?? FileLibraryStore.cachedList(profileId: profileId))
            .map(\.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".md") }
    }

    private static func reportMetas(paths: [String], prefix: String, profileId: String) -> [ReportMeta] {
        paths.map { path -> ReportMeta in
            let fm = (try? FileLibraryStore.read(path, profileId: profileId))
                .map(parseFrontmatter) ?? [:]
            let fileBase = String(path.dropFirst(prefix.count).dropLast(3))
            return ReportMeta(path: path,
                              date: fm["date"] ?? String(fileBase.prefix(10)),
                              rating: fm["rating"],
                              confidence: fm["confidence"],
                              kind: fm["type"])
        }
    }

    /// 去掉 frontmatter 留正文（研报全文渲染用——字段已在列表行展示，正文里裸渲染很丑）。
    static func stripFrontmatter(_ md: String) -> String {
        guard md.hasPrefix("---\n"),
              let end = md.range(of: "\n---", range: md.index(md.startIndex, offsetBy: 4)..<md.endIndex) else { return md }
        let rest = md[end.upperBound...].drop { $0 == "-" }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 最小 frontmatter 解析（--- 包裹的 key: value 行）。非 yaml 全功能，够用即可。
    static func parseFrontmatter(_ md: String) -> [String: String] {
        guard md.hasPrefix("---\n"), let end = md.range(of: "\n---", range: md.index(md.startIndex, offsetBy: 4)..<md.endIndex) else { return [:] }
        var out: [String: String] = [:]
        for line in md[md.index(md.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    // MARK: - 夜跑参数（设置-交易可调；app 是真相源，随 watchlist 帧镜像给 hub）

    static let nightlyEnabledKey = "trading.nightly.enabled"
    static let nightlyFreshDaysKey = "trading.nightly.freshDays"
    static let nightlyMaxPerNightKey = "trading.nightly.maxPerNight"

    static var nightlyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: nightlyEnabledKey) as? Bool ?? false }   // §4 默认收紧（老装机迁移写显式 true）
        set { UserDefaults.standard.set(newValue, forKey: nightlyEnabledKey) }
    }
    static var nightlyFreshDays: Int {
        get { UserDefaults.standard.object(forKey: nightlyFreshDaysKey) as? Int ?? 7 }
        set { UserDefaults.standard.set(newValue, forKey: nightlyFreshDaysKey) }
    }
    static var nightlyMaxPerNight: Int {
        get { UserDefaults.standard.object(forKey: nightlyMaxPerNightKey) as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: nightlyMaxPerNightKey) }
    }

    // MARK: - 关注列表上报（夜跑自动档目标源；关注/参数变化 + 启动注册时全量发，断线静默下次再发）

    static func reportWatchlist(context: ModelContext, profileId: String) {
        guard !profileId.isEmpty, CCBridgeWebSocketClient.shared.isConnected else { return }
        var desc = FetchDescriptor<TickerEntry>(
            predicate: #Predicate<TickerEntry> { $0.profileId == profileId },
            sortBy: [SortDescriptor(\TickerEntry.createdAt)]
        )
        desc.fetchLimit = 50
        let symbols = ((try? context.fetch(desc)) ?? []).map(\.symbol)
        CCBridgeWebSocketClient.shared.send([
            "type": "trading_watchlist", "symbols": symbols,
            "nightly": ["enabled": nightlyEnabled, "freshDays": nightlyFreshDays, "maxPerNight": nightlyMaxPerNight],
        ]) { _ in }
    }

    // MARK: - 交易卡查询（T1）

    static func openTradeCount(context: ModelContext, profileId: String) -> Int {
        let desc = FetchDescriptor<TradeEntry>(
            predicate: #Predicate<TradeEntry> { $0.profileId == profileId && $0.status == "open" })
        return (try? context.fetchCount(desc)) ?? 0
    }

    // MARK: - {{trading}} 组合器（预览与实发同源；全空返回 ""）

    static func composedTradingSummary(context: ModelContext, profileId: String, now: Date = Date(), grants: PermissionGrants = .empty) -> String {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("TradingStore.composedTradingSummary") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        guard PermissionCenter.injectionAllowed(.trading, grants: grants) else { return "" }
        var parts: [String] = []

        var desc = FetchDescriptor<TickerEntry>(
            predicate: #Predicate<TickerEntry> { $0.profileId == profileId },
            sortBy: [SortDescriptor(\TickerEntry.createdAt)]
        )
        desc.fetchLimit = 50
        if let entries = try? context.fetch(desc), !entries.isEmpty {
            // 一次取清单，所有自选股共用（以前每只股票各取一次）
            let libraryFiles = FileLibraryStore.cachedList(profileId: profileId)
            let items = entries.map { entry -> String in
                if let r = latestReport(symbol: entry.symbol, profileId: profileId, files: libraryFiles), let rating = r.rating {
                    let conf = r.confidence.map { "，置信 \($0)" } ?? ""
                    return "$\(entry.symbol)（最新研报 \(r.date)：\(rating)\(conf)）"
                }
                return "$\(entry.symbol)"
            }
            parts.append("关注自选：" + items.joined(separator: "、") + "。")
        }

        // 未平仓位（含开仓理由——拷问复盘的弹药）
        var openDesc = FetchDescriptor<TradeEntry>(
            predicate: #Predicate<TradeEntry> { $0.profileId == profileId && $0.status == "open" },
            sortBy: [SortDescriptor(\TradeEntry.openedAt, order: .reverse)]
        )
        openDesc.fetchLimit = 10
        if let opens = try? context.fetch(openDesc), !opens.isEmpty {
            let items = opens.map { t -> String in
                let days = max(0, Int(now.timeIntervalSince(t.openedAt) / 86400))
                return "$\(t.symbol) \(t.side == "short" ? "空" : "多") \(Int(t.quantity)) 股 @\(String(format: "%.2f", t.price))，\(days) 天前开，理由：\(t.reason)"
            }
            parts.append("当前持仓：" + items.joined(separator: "；") + "。")
        }

        // 最近已平（盈亏 + 复盘状态）
        var closedDesc = FetchDescriptor<TradeEntry>(
            predicate: #Predicate<TradeEntry> { $0.profileId == profileId && $0.status == "closed" },
            sortBy: [SortDescriptor(\TradeEntry.openedAt, order: .reverse)]
        )
        closedDesc.fetchLimit = 3
        if let closed = try? context.fetch(closedDesc), !closed.isEmpty {
            let items = closed.map { t -> String in
                let pnl = t.closedPnLPercent.map { String(format: "%+.1f%%", $0) } ?? "盈亏未记"
                let reviewed = t.reviewNote != nil ? "已复盘" : "未复盘"
                return "$\(t.symbol)（\(pnl)，\(reviewed)）"
            }
            parts.append("最近平仓：" + items.joined(separator: "、") + "。")
        }

        return parts.joined(separator: "")
    }
}
#endif
