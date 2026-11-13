import Foundation

/// C 档案注入（plan-memory-c3-catalog 第六节）：根索引进稳定层；最近 4 条消息里逐字出现某页的标题 / 触发词，
/// 这页「钩子 + 现在」进动态层，一轮最多 3 页。组装路径只读 `WikiInjectionCache` 里的快照，读盘都在后台
public struct WikiInjectionSnapshot: Equatable, Sendable {
    public struct Page: Equatable, Sendable {
        public let path: String
        public let title: String
        public let triggers: [String]
        public let hook: String
        public let now: String
        /// 页上的 valid_until（「现在」该复核的日子）；旧页 nil
        public var validUntil: String? = nil
        /// Raw on-disk content hash, captured by the same safe read as the payload.
        public var version: String = ""
        /// Public corpus text retained unsegmented so floor tuning can retokenize safely.
        public var document: String? = nil
        public var factDomain: SeedFactDomain? = nil

        public var lexicalDocument: String {
            document ?? ([title, hook, now] + triggers).joined(separator: "\n")
        }

        public init(path: String, title: String, triggers: [String], hook: String, now: String, validUntil: String? = nil, version: String = "", document: String? = nil, factDomain: SeedFactDomain? = nil) {
            self.path = path
            self.title = title
            self.triggers = triggers
            self.hook = hook
            self.now = now
            self.validUntil = validUntil
            self.version = version
            self.document = document
            self.factDomain = factDomain
        }
    }

    public var indexLines: [String] = []
    public var pages: [Page] = []
    public var stopWords: [String] = []

    public init(indexLines: [String] = [], pages: [Page] = [], stopWords: [String] = []) {
        self.indexLines = indexLines
        self.pages = pages
        self.stopWords = stopWords
    }
}

public struct WikiPageHit: Equatable, Sendable {
    public let page: WikiInjectionSnapshot.Page
    /// 命中它的那个词（常驻页显示「小慧（“慧慧”）」）
    public let word: String

    public init(page: WikiInjectionSnapshot.Page, word: String) {
        self.page = page
        self.word = word
    }
}
