import Foundation
import SwiftData

// MARK: - 交易模块 T0 数据层（标的关注）
// 刻意最小：笔记正文在文件库 trading/<symbol>.md（TradingNoteStore），
// 研究记录 = 文件库 trading/<symbol>/ 目录扫描，出处对话 = 打开档案时 predicate 现查——都不落库。
// T0 不进全局备份（拍板，docs/plan-trading-t0-ticker.md）：丢失可重建，文件库自有 iCloud。

/// 一只被关注的标的。symbol 恒大写（1-5 位美股正股，写入方保证）。
@Model
final class TickerEntry {
    @Attribute(.unique) var id: UUID = UUID()

    var profileId: String
    var symbol: String          // 恒大写，如 "NVDA"
    var displayName: String?    // 公司名，可空（研报 frontmatter 或用户补）
    var createdAt: Date = Date()

    init(profileId: String, symbol: String, displayName: String? = nil) {
        self.profileId = profileId
        self.symbol = symbol.uppercased()
        self.displayName = displayName
    }
}
