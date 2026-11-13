import Foundation

/// 读 wiki 那一层的值类型（`RecallTool.Target` / `Cursor` 里嵌的就是这些）。
/// 实现是同目录 `RecallWikiReader`；app 只注入「当前源」解析（`RecallEnvironment.resolveCurrent`）。
public enum RecallWikiRead<Value: Sendable>: Sendable {
    case value(Value)
    case stale
    case unavailable
    case invalidTarget

    public var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

extension RecallWikiRead: Equatable where Value: Equatable {}

public struct RecallWikiPageTarget: Codable, Equatable, Sendable {
    public var profileId: String
    public var path: String
    public var version: String?
    public init(profileId: String, path: String, version: String? = nil) {
        self.profileId = profileId
        self.path = path
        self.version = version
    }
}

public struct RecallWikiRowTarget: Codable, Equatable, Sendable {
    public var page: RecallWikiPageTarget
    public var ordinal: Int
    public var lineHash: String
    public var id: String { "\(page.path)|\(page.version ?? "")|\(ordinal)|\(lineHash)" }
    public init(page: RecallWikiPageTarget, ordinal: Int, lineHash: String) {
        self.page = page
        self.ordinal = ordinal
        self.lineHash = lineHash
    }
}

public struct RecallWikiCardTarget: Codable, Equatable, Sendable {
    public var page: RecallWikiPageTarget
    public var path: String
    public var version: String
    public init(page: RecallWikiPageTarget, path: String, version: String) {
        self.page = page
        self.path = path
        self.version = version
    }
}

public enum RecallWikiSourceLocator: Codable, Equatable, Sendable {
    case seed(path: String)
    case legacy(label: String)
    /// 非卡来源；本批只返回定位标签，不读取其原文。
    case fragment(label: String)
}

public struct RecallWikiCursor: Codable, Equatable, Sendable {
    public var scope: String
    public var binding: String
    public var revision: String
    public var position: Int
    public var offset: Int
    public init(scope: String, binding: String, revision: String, position: Int, offset: Int) {
        self.scope = scope
        self.binding = binding
        self.revision = revision
        self.position = position
        self.offset = offset
    }
}

public struct RecallWikiFolderRow: Equatable, Sendable {
    public var path: String
    public var title: String
    public var hook: String
    public var pageCount: Int
    public init(path: String, title: String, hook: String, pageCount: Int) {
        self.path = path
        self.title = title
        self.hook = hook
        self.pageCount = pageCount
    }
}

public struct RecallWikiPageRow: Equatable, Sendable {
    public var path: String
    /// 原样消费 factDomainIndexTag，不另建事实域枚举。
    public var title: String
    public var hook: String
    public var target: RecallWikiPageTarget
    public init(path: String, title: String, hook: String, target: RecallWikiPageTarget) {
        self.path = path
        self.title = title
        self.hook = hook
        self.target = target
    }
}

public enum RecallWikiIndexRow: Equatable, Sendable {
    case folder(RecallWikiFolderRow)
    case page(RecallWikiPageRow)
}

public struct RecallWikiIndex: Equatable, Sendable {
    public var folder: String
    public var rows: [RecallWikiIndexRow]
    public var next: RecallWikiCursor?
    public init(folder: String, rows: [RecallWikiIndexRow], next: RecallWikiCursor?) {
        self.folder = folder
        self.rows = rows
        self.next = next
    }
}

public struct RecallWikiTextPart: Equatable, Sendable {
    public var text: String
    public var offset: Int
    public var complete: Bool
    public init(text: String, offset: Int, complete: Bool) {
        self.text = text
        self.offset = offset
        self.complete = complete
    }
}

public struct RecallWikiRecord: Equatable, Sendable {
    public var target: RecallWikiRowTarget
    public var body: RecallWikiTextPart
    public var sources: [RecallWikiSourceLocator]
    public init(target: RecallWikiRowTarget, body: RecallWikiTextPart, sources: [RecallWikiSourceLocator]) {
        self.target = target
        self.body = body
        self.sources = sources
    }
}

public struct RecallWikiPage: Equatable, Sendable {
    public var target: RecallWikiPageTarget
    public var title: String
    public var hook: RecallWikiTextPart?
    public var now: RecallWikiTextPart?
    public var records: [RecallWikiRecord]
    public var links: [RecallWikiPageTarget]
    public var next: RecallWikiCursor?
    public init(target: RecallWikiPageTarget, title: String, hook: RecallWikiTextPart? = nil,
                now: RecallWikiTextPart? = nil, records: [RecallWikiRecord], links: [RecallWikiPageTarget],
                next: RecallWikiCursor? = nil) {
        self.target = target
        self.title = title
        self.hook = hook
        self.now = now
        self.records = records
        self.links = links
        self.next = next
    }
}

public struct RecallWikiVersion: Equatable, Sendable {
    public var target: RecallWikiCardTarget
    public var title: String?
    public var madeAt: Date?
    public init(target: RecallWikiCardTarget, title: String?, madeAt: Date?) {
        self.target = target
        self.title = title
        self.madeAt = madeAt
    }
}

public struct RecallWikiL1: Equatable, Sendable {
    public var target: RecallWikiCardTarget
    public var title: String
    public var gist: String
    public var mentions: [SeedNoteCard.Mention]
    public var factDomain: SeedFactDomain?
    public var sourceContext: SeedSourceContext?
    public var next: RecallWikiCursor?
    public init(target: RecallWikiCardTarget, title: String, gist: String, mentions: [SeedNoteCard.Mention],
                factDomain: SeedFactDomain?, sourceContext: SeedSourceContext?, next: RecallWikiCursor?) {
        self.target = target
        self.title = title
        self.gist = gist
        self.mentions = mentions
        self.factDomain = factDomain
        self.sourceContext = sourceContext
        self.next = next
    }
}

public enum RecallWikiEntry: Equatable, Sendable {
    case sources([RecallWikiSourceLocator])
    case card(RecallWikiL1)
    /// 页级 entries 不能证明这一行用了哪一版。
    case versionUndetermined([RecallWikiVersion])
    case legacySource(RecallWikiSourceLocator?, approved: [RecallWikiVersion])
    case fragmentSource(RecallWikiSourceLocator)
    case missingCard(RecallWikiCardTarget)
}

public enum RecallWikiMissingOriginal: Equatable, Sendable {
    case currentSameVersion
    case changed
    case resegmented
    case slotDeleted
    case empty
    case fileMissing
    case contextChanged
    case legacySegmentation
    case currentUnavailable
    case unreadable(String)
}

public struct RecallWikiOriginal: Equatable, Sendable {
    public var target: RecallWikiCardTarget
    /// nil = 旁存 L2；非 nil 始终表示「原文当时没存」，text 只是明确标记的当前源。
    public var missingOriginal: RecallWikiMissingOriginal?
    public var currentVersion: String?
    public var text: RecallWikiTextPart?
    public var sourceContext: SeedSourceContext?
    public var next: RecallWikiCursor?
    public init(target: RecallWikiCardTarget, missingOriginal: RecallWikiMissingOriginal?,
                currentVersion: String?, text: RecallWikiTextPart?, sourceContext: SeedSourceContext?,
                next: RecallWikiCursor?) {
        self.target = target
        self.missingOriginal = missingOriginal
        self.currentVersion = currentVersion
        self.text = text
        self.sourceContext = sourceContext
        self.next = next
    }
}

/// 当前源解析结果（替代原 Reader 里 `WikiProposalSources.current` 的 switch 产物）。
/// `nil`（解析器不存在或没解析出来）= 当前源不可用。
public struct RecallWikiCurrent: Equatable, Sendable {
    public var text: String?
    public var currentVersion: String?
    public var missing: RecallWikiMissingOriginal?

    public init(text: String? = nil, currentVersion: String? = nil, missing: RecallWikiMissingOriginal? = nil) {
        self.text = text
        self.currentVersion = currentVersion
        self.missing = missing
    }
}
