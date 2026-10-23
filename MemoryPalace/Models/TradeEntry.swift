import Foundation
import SwiftData

/// 一个"仓位故事"：开仓理由、平仓、复盘挂同一条（粟粟拍：平仓就是一个 tag，不是流程）。
/// 盈亏不落库（closedPnLPercent 纯函数推导）；部分平仓不做（要拆记两条）。
/// 防丢镜像：每次写入同步 append 人话版进文件库 trading/journal.md（TradingJournalMirror）。
@Model
final class TradeEntry {
    @Attribute(.unique) var id: UUID = UUID()

    var profileId: String
    var symbol: String              // 恒大写
    var side: String                // "long" | "short"
    var quantity: Double
    var price: Double               // 开仓价
    var openedAt: Date
    var reason: String              // 开单理由——灵魂字段
    var status: String = "open"     // "open" | "closed"（平仓=翻 tag）
    var closePrice: Double? = nil
    var closedAt: Date? = nil
    var reviewNote: String? = nil   // 复盘结论（拷问对话的产出挂这）
    var reviewedAt: Date? = nil
    var createdAt: Date = Date()

    init(profileId: String, symbol: String, side: String, quantity: Double,
         price: Double, reason: String, openedAt: Date = Date()) {
        self.profileId = profileId
        self.symbol = symbol.uppercased()
        self.side = side == "short" ? "short" : "long"
        self.quantity = quantity
        self.price = price
        self.reason = reason
        self.openedAt = openedAt
    }
}

extension TradeEntry {
    /// 已平仓的盈亏百分比（多空方向修正）；未平/无平仓价 → nil。
    var closedPnLPercent: Double? {
        guard status == "closed", let close = closePrice, price > 0 else { return nil }
        let raw = (close - price) / price
        return (side == "short" ? -raw : raw) * 100
    }
}
