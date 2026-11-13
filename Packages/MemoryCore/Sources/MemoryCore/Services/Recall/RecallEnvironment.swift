import Foundation

/// `RecallTool` 在包里；仍有三样只能由 app 提供（plan §1.2 的注入口）：
/// `Memory` 表 L1 检索（刀 3 才换 GRDB）、碎片出处定位（`Memory` 表）、wiki 当前源解析
/// （`CatalogSeedTaskStore` + `WikiProposalSources.current`）。memoryd / 测试不传时：
/// 碎片支按「找不到」回执，当前源按「不可用」处理。
public struct RecallEnvironment: Sendable {
    public typealias SearchL1 = @Sendable (String?, String, Bool, Date?, Date?) -> RecallTool.L1Result
    /// `(碎片标签, 本轮 cursor) -> Memory 命中`；只给定位，路径 / 原文锚由包内 `wikiFragment` 校。
    public typealias LocateFragment = @Sendable (String, RecallTool.Cursor) throws
        -> (memoryId: String, content: String, conversationId: String, nodeId: String)?
    /// `(卡, wiki, 楼层, 楼层根) -> 当前源`；nil = 当前源不可用。
    public typealias ResolveCurrent = @Sendable (SeedNoteCard, WikiStore, String, URL) -> RecallWikiCurrent?

    public var searchL1: SearchL1
    public var locateFragment: LocateFragment?
    public var resolveCurrent: ResolveCurrent?

    public init(searchL1: @escaping SearchL1,
                locateFragment: LocateFragment? = nil,
                resolveCurrent: ResolveCurrent? = nil) {
        self.searchL1 = searchL1
        self.locateFragment = locateFragment
        self.resolveCurrent = resolveCurrent
    }
}
