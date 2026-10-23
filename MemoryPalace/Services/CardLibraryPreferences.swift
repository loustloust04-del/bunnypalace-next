import Foundation

/// 卡库「设置」页签的偏好（⑥，小样 08）：每项一个 UserDefaults key，页面用 `@AppStorage` 直接读写；
/// 进设置导出 / 全局备份走 `ConfigSchema.appStorageKeys`。
enum CardLibraryPreferences {
    /// 点卡直接进最近的非回收站聊天（没有聊天仍进角色页）；默认关 = 进角色页
    static let autoResumeKey = "cardLibrary.autoResume"
    /// 允许卡里的网页运行脚本；默认关。本步只存，⑦ 才读
    static let allowWebScriptsKey = "cardLibrary.allowWebScripts"
    /// 世界书每次最多注入几条；0 = 不限（默认）
    static let worldBookMaxEntriesKey = "cardLibrary.worldBookMaxEntries"
    /// 世界书 token 预算：沿用 SC-B4 的旧 key，不另建；0 = 不限
    static let worldBookTokenBudgetKey = "wb_inject_budget"
    /// 第二批 B9：示例卡「白石」删过（删除 / 归档）就记下，之后不再补回
    static let sampleCardDismissedKey = "cardLibrary.sampleCardDismissed"
}
