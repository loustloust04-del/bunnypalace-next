import CryptoKit
import Foundation

/// 同槽同名同层级的兄弟标题实例 context 相等、不可区分，靠整体比对兜底。
public struct SeedSourceContext: Codable, Equatable, Sendable {
    public var slotPath: String
    public var slotName: String
    public var headingPath: [String]

    public init(slotPath: String, slotName: String, headingPath: [String]) {
        self.slotPath = slotPath
        self.slotName = slotName
        self.headingPath = headingPath
    }
}

public enum SeedFactDomain: String, Codable, Sendable {
    case realWorld, inWorld, mixed, unspecified
}

/// 一份原料一张卡：`wiki/.cards/<sha256(path|version)>.json`，楼层级，同一份原料同版本只出一次
public struct SeedNoteCard: Codable, Equatable, Sendable {
    public struct Mention: Codable, Equatable, Sendable {
        public var name: String
        public var group: String
        public var aliases: [String]? = nil

        public init(name: String, group: String, aliases: [String]? = nil) {
            self.name = name
            self.group = group
            self.aliases = aliases
        }
    }

    public var path: String
    public var version: String
    public var name: String
    public var layer: String
    /// 这份讲了什么，一行，目标 ≤20 字；重写后仍超长原样保留并记软检查
    public var title: String
    /// 一句话要点：只拍片子（谁做了什么 / 说了什么 / 定了什么），画弯不列站
    public var gist: String
    /// 对应新 A3【关键词】：标志性的名字 / 物件 / 话题，每个带组，≤10 个
    public var mentions: [Mention]
    /// 这份主要在说本人
    public var aboutUser: Bool
    /// 整份建议归哪组（九组之一；本人那组落盘 {{user}}）
    public var group: String
    /// 卡上出现的时间锚原话（可空；只给聚合排序 / 审计看，不当事实日期）
    public var when: [String]
    public var model: String
    public var madeAt: Date
    public var run: CatalogRunLink
    public var sourceContext: SeedSourceContext? = nil
    public var factDomain: SeedFactDomain? = nil
    public var sourceContextIssue: ContextIssue? = nil

    public var effectiveFactDomain: SeedFactDomain? {
        sourceContextIssue == nil ? factDomain : nil
    }

    private enum CodingKeys: String, CodingKey {
        case path, version, name, layer, title, gist, mentions, aboutUser, group, when, model, madeAt, run
        case sourceContext, factDomain
    }

    public enum ContextIssue: String, Codable, Sendable {
        case missing, conflict

        public var note: String {
            switch self {
            case .missing: return "上下文缺失"
            case .conflict: return "上下文冲突"
            }
        }
    }

    public func contextIssue(for frozen: SeedSourceContext?) -> ContextIssue? {
        guard layer == "Prompt" || sourceContext != nil || frozen != nil else { return nil }
        guard let sourceContext, let frozen else { return .missing }
        return sourceContext == frozen ? nil : .conflict
    }

    public init(path: String, version: String, name: String, layer: String, title: String, gist: String, mentions: [Mention], aboutUser: Bool, group: String, when: [String], model: String, madeAt: Date, run: CatalogRunLink, sourceContext: SeedSourceContext? = nil, factDomain: SeedFactDomain? = nil, sourceContextIssue: ContextIssue? = nil) {
        self.path = path
        self.version = version
        self.name = name
        self.layer = layer
        self.title = title
        self.gist = gist
        self.mentions = mentions
        self.aboutUser = aboutUser
        self.group = group
        self.when = when
        self.model = model
        self.madeAt = madeAt
        self.run = run
        self.sourceContext = sourceContext
        self.factDomain = factDomain
        self.sourceContextIssue = sourceContextIssue
    }
}

/// 卡的存取：`wiki/.cards/`，隐藏夹，不随 `.runs` / `.proposals` 的 30 天清理（它们只扫自己的文件夹）
public struct SeedNoteStore: Sendable {
    public static let folderName = ".cards"

    public struct Original: Equatable, Sendable {
        public var text: String
        public var sourceContext: SeedSourceContext?

        public init(text: String, sourceContext: SeedSourceContext? = nil) {
            self.text = text
            self.sourceContext = sourceContext
        }
    }

    public enum OriginalError: LocalizedError, Equatable {
        case conflict(String)
        case contextConflict(String)

        public var errorDescription: String? {
            switch self {
            case .conflict(let path): return "\(path) 同 key 原文字节不同，未覆盖"
            case .contextConflict(let path): return "\(path) 同 key 原文的来源上下文不同，未发布卡"
            }
        }
    }

    private static let originalLock = NSLock()

    public let wiki: WikiStore

    public var folder: URL { wiki.root.appendingPathComponent(Self.folderName, isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static func key(path: String, version: String) -> String {
        SHA256.hash(data: Data("\(path)|\(version)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func url(path: String, version: String) -> URL {
        folder.appendingPathComponent(Self.key(path: path, version: version) + ".json")
    }

    /// `.cards` 是链接 / 不是文件夹、卡文件是链接 = 读不到（`SafeWiki`：从 wiki 根起逐级不跟链接）
    public func load(path: String, version: String) -> SeedNoteCard? {
        guard !version.isEmpty, let data = SafeWiki.read(Self.key(path: path, version: version) + ".json", in: [Self.folderName], under: wiki.root) else { return nil }
        return try? Self.decoder.decode(SeedNoteCard.self, from: data)
    }

    /// txt 只放冻结正文的 UTF-8 字节；上下文单独放同 key 的 .src（JSON）。txt 先落盘，卡 json 由调用方最后发布。
    public func saveOriginal(path: String, version: String, text: String, sourceContext: SeedSourceContext?) throws {
        try Self.originalLock.withLock {
            let key = Self.key(path: path, version: version)
            let dir = try SafeWiki.folder([Self.folderName], under: wiki.root, create: true)
            let url = try SafeWiki.file(key + ".txt", in: dir)
            let bytes = Data(text.utf8)
            if try SafeWiki.itemType(url) != nil {
                guard try Data(contentsOf: url) == bytes else { throw OriginalError.conflict(path) }
            } else {
                try SafeWiki.write(bytes, name: key + ".txt", in: [Self.folderName], under: wiki.root)
            }
            let sidecar = try SafeWiki.file(key + ".src", in: dir)
            if try SafeWiki.itemType(sidecar) != nil {
                guard try Self.decoder.decode(SeedSourceContext.self, from: Data(contentsOf: sidecar)) == sourceContext else {
                    throw OriginalError.contextConflict(path)
                }
            } else if let sourceContext {
                try SafeWiki.write(Self.encoder.encode(sourceContext), name: key + ".src", in: [Self.folderName], under: wiki.root)
            }
        }
    }

    public func original(path: String, version: String) -> Original? {
        let key = Self.key(path: path, version: version)
        guard !version.isEmpty, let bytes = SafeWiki.read(key + ".txt", in: [Self.folderName], under: wiki.root) else { return nil }
        var context: SeedSourceContext?
        do {
            let dir = try SafeWiki.folder([Self.folderName], under: wiki.root, create: false)
            let sidecar = try SafeWiki.file(key + ".src", in: dir)
            if try SafeWiki.itemType(sidecar) != nil {
                context = try Self.decoder.decode(SeedSourceContext.self, from: Data(contentsOf: sidecar))
            }
        } catch { return nil }
        return Original(text: String(decoding: bytes, as: UTF8.self), sourceContext: context)
    }

    /// 路径上有链接 / 出根就抛，这批记失败
    public func save(_ card: SeedNoteCard) throws {
        try SafeWiki.write(Self.encoder.encode(card), name: Self.key(path: card.path, version: card.version) + ".json", in: [Self.folderName], under: wiki.root)
    }

    public init(wiki: WikiStore) {
        self.wiki = wiki
    }
}

/// 任务里出卡 / 对齐 / 聚类的进度（第 2 段挂到 `task.notes`）：failed 批的原料仍是 uncarded，续跑重新切批只会再碰到它们
public struct SeedNoteProgress: Codable, Equatable, Sendable {
    public struct Batch: Codable, Equatable, Sendable {
        public var index: Int
        public var paths: [String]
        public var ok: Bool
        public var reason: String? = nil

        public init(index: Int, paths: [String], ok: Bool, reason: String? = nil) {
            self.index = index
            self.paths = paths
            self.ok = ok
            self.reason = reason
        }
    }

    public struct SplitBatch: Codable, Equatable, Sendable {
        public var index: Int
        public var recovered: Int

        public init(index: Int, recovered: Int) {
            self.index = index
            self.recovered = recovered
        }
    }

    public var batches: [Batch] = []
    public var splitBatches: [SplitBatch]? = nil
    public var aligned = false
    public var clustered = false
    public var sourceContextIssues: [String: SeedNoteCard.ContextIssue]? = nil

    public var failedPaths: Set<String> { Set(batches.filter { !$0.ok }.flatMap(\.paths)) }

    public init(batches: [Batch] = [], splitBatches: [SplitBatch]? = nil, aligned: Bool = false, clustered: Bool = false, sourceContextIssues: [String: SeedNoteCard.ContextIssue]? = nil) {
        self.batches = batches
        self.splitBatches = splitBatches
        self.aligned = aligned
        self.clustered = clustered
        self.sourceContextIssues = sourceContextIssues
    }
}
