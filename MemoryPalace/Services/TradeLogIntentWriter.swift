#if PERSONAL_APPS
import Foundation
import SwiftData

// MARK: - 聊天内交易记录意向（plan-trading-t1-journal）
// ```trade 块 → 落卡 → 块变结果行。意向协议第四例（book-note/voice/health-log 之后）。
// 三种 type：open（开仓）/ close（平仓=翻 tag，挂最新一条 open 卡）/ review（复盘挂卡）。
// 每次落地同步 append 人话镜像进文件库 trading/journal.md（开单理由丢不起）。

enum TradeLogIntentWriter {

    private static let intentRegex = try! NSRegularExpression(
        pattern: "```trade\\s*\\n([\\s\\S]*?)```",
        options: []
    )

    /// 两挂点共用入口（ContentView 收口订阅 + CVM insertProactiveAssistantMessage）。
    /// 无块零成本；now 可注入供测试。
    static func processChatIntents(nodeId: String, context: ModelContext, now: Date = Date()) {
        let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        guard let node = (try? context.fetch(nodeDesc))?.first,
              node.role == "assistant",
              node.content.contains("```trade") else { return }

        let content = node.content
        let ns = content as NSString
        let matches = intentRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }

        var newContent = content
        for m in matches.reversed() {   // 倒序替换保 range 有效
            let jsonStr = ns.substring(with: m.range(at: 1))
            let replacement = applyIntent(jsonStr, profileId: node.profileId, context: context, now: now)
            newContent = (newContent as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        node.content = newContent
        // 双容器消费（voice 的坑）：segmented 消息正文副本里的残留块也要替换
        replaceInSegments(node: node)
        try? context.save()
    }

    /// segments 的 .text 段若含 trade 块（工具轮/segmented 消息），同步替换为与 content 一致的结果。
    /// 简化实现：segments 里的块直接删除（content 已带结果行，segmented 渲染以 content 段为准补齐）。
    private static func replaceInSegments(node: MessageNode) {
        guard let data = node.segmentsData,
              var raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var changed = false
        for i in raw.indices {
            if var text = raw[i]["text"] as? String, text.contains("```trade") {
                let ns = text as NSString
                let matches = intentRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                for m in matches.reversed() {
                    text = (text as NSString).replacingCharacters(in: m.range, with: "（交易记录已落卡）")
                }
                raw[i]["text"] = text
                changed = true
            }
        }
        if changed, let out = try? JSONSerialization.data(withJSONObject: raw) {
            node.segmentsData = out
        }
    }

    // MARK: - 单条意向落地

    private static func applyIntent(_ jsonStr: String, profileId: String, context: ModelContext, now: Date) -> String {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let symbol = normalizedSymbol(obj["symbol"]) else {
            return "📈 交易记录格式无效，未落地"
        }
        switch type {
        case "open":   return applyOpen(obj, symbol: symbol, profileId: profileId, context: context, now: now)
        case "close":  return applyClose(obj, symbol: symbol, profileId: profileId, context: context, now: now)
        case "review": return applyReview(obj, symbol: symbol, profileId: profileId, context: context, now: now)
        default:       return "📈 交易记录格式无效，未落地"
        }
    }

    private static func normalizedSymbol(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces).uppercased(),
              (1...5).contains(s.count), s.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        return s
    }

    private static func applyOpen(_ obj: [String: Any], symbol: String, profileId: String, context: ModelContext, now: Date) -> String {
        guard let qty = numeric(obj["qty"]), qty > 0,
              let price = numeric(obj["price"]), price > 0,
              let reason = (obj["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else {
            return "📈 开仓记录缺数量/价格/理由，未落地"
        }
        let side = (obj["side"] as? String) == "short" ? "short" : "long"
        let entry = TradeEntry(profileId: profileId, symbol: symbol, side: side,
                               quantity: qty, price: price, reason: reason, openedAt: now)
        context.insert(entry)
        try? context.save()
        TradingJournalMirror.append("开\(side == "short" ? "空" : "多") $\(symbol) \(qtyText(qty))股 @\(priceText(price))：\(reason)", profileId: profileId, now: now)
        return "📈 已记开仓：$\(symbol) \(side == "short" ? "空" : "多") \(qtyText(qty)) 股 @\(priceText(price))"
    }

    private static func applyClose(_ obj: [String: Any], symbol: String, profileId: String, context: ModelContext, now: Date) -> String {
        guard let entry = latestEntry(symbol: symbol, status: "open", profileId: profileId, context: context) else {
            return "📉 没找到 $\(symbol) 的持仓卡，没落地"
        }
        entry.status = "closed"
        entry.closedAt = now
        if let price = numeric(obj["price"]), price > 0 { entry.closePrice = price }
        if let reason = (obj["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            // 平仓理由并进复盘备注开头（单独字段不值得，粟粟拍的"别复杂"）
            entry.reviewNote = entry.reviewNote ?? reason
        }
        try? context.save()
        let pnl = entry.closedPnLPercent.map { String(format: "（%+.1f%%）", $0) } ?? ""
        let priceStr = entry.closePrice.map { " @\(priceText($0))" } ?? ""
        TradingJournalMirror.append("平 $\(symbol)\(priceStr)\(pnl)", profileId: profileId, now: now)
        return "📉 已平：$\(symbol)\(priceStr)\(pnl)"
    }

    private static func applyReview(_ obj: [String: Any], symbol: String, profileId: String, context: ModelContext, now: Date) -> String {
        guard let note = (obj["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return "📝 复盘内容是空的，没落地"
        }
        // 优先挂最新一条已平未复盘的；没有则挂最新一条（持仓中也可以复盘）
        let target = latestEntry(symbol: symbol, status: "closed", profileId: profileId, context: context, unreviewedFirst: true)
            ?? latestEntry(symbol: symbol, status: nil, profileId: profileId, context: context)
        guard let entry = target else {
            return "📝 没找到 $\(symbol) 的交易卡，没落地"
        }
        entry.reviewNote = note
        entry.reviewedAt = now
        try? context.save()
        TradingJournalMirror.append("复盘 $\(symbol)：\(note)", profileId: profileId, now: now)
        return "📝 复盘已挂卡：$\(symbol)"
    }

    // MARK: - 查卡（status nil = 不限）

    private static func latestEntry(symbol: String, status: String?, profileId: String,
                                    context: ModelContext, unreviewedFirst: Bool = false) -> TradeEntry? {
        var desc: FetchDescriptor<TradeEntry>
        if let status {
            desc = FetchDescriptor<TradeEntry>(
                predicate: #Predicate<TradeEntry> { $0.profileId == profileId && $0.symbol == symbol && $0.status == status },
                sortBy: [SortDescriptor(\TradeEntry.openedAt, order: .reverse)])
        } else {
            desc = FetchDescriptor<TradeEntry>(
                predicate: #Predicate<TradeEntry> { $0.profileId == profileId && $0.symbol == symbol },
                sortBy: [SortDescriptor(\TradeEntry.openedAt, order: .reverse)])
        }
        desc.fetchLimit = 10
        let entries = (try? context.fetch(desc)) ?? []
        if unreviewedFirst, let unreviewed = entries.first(where: { $0.reviewNote == nil }) { return unreviewed }
        return entries.first
    }

    private static func numeric(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static func qtyText(_ q: Double) -> String {
        q == q.rounded() ? String(Int(q)) : String(q)
    }
    private static func priceText(_ p: Double) -> String {
        p == p.rounded() ? String(Int(p)) : String(format: "%.2f", p)
    }
}

// MARK: - journal.md 镜像（防丢：开单理由丢不起；文件库自有 iCloud，AI fs 可读全史）

enum TradingJournalMirror {
    static func append(_ line: String, profileId: String, now: Date = Date()) {
        guard !profileId.isEmpty else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let entry = "- \(f.string(from: now)) \(line)\n"
        let path = "trading/journal.md"
        let existing = (try? FileLibraryStore.read(path, profileId: profileId)) ?? "# 交易流水\n\n"
        try? FileLibraryStore.write(path, content: existing + entry, profileId: profileId)
    }
}
#endif
