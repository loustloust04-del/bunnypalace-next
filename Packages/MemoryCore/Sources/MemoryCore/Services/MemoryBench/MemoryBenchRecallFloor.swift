import Foundation

/// 内置试写台楼层（星砚虚构楼层）：app 资源与包测试夹具是同一份 JSON。
/// 同一份数据在 `load` 时一并解出 `FloorSnapshot`，`branch` / 重放都读它。
public struct MemoryBenchRecallFloor: Codable, Sendable {
    public struct Node: Codable, Sendable {
        public var id: String
        public var role: String
        public var text: String
        public var at: Date
        public var parent: String?
        public var hidden: Bool
        public var deleted: Bool
    }
    public struct Window: Codable, Sendable {
        public struct Segment: Codable, Sendable {
            public var from: Int
            public var to: Int
            public var story: String
        }
        public var id: String
        public var title: String
        public var current: String
        public var memoryEnabled: Bool
        public var trashed: Bool
        public var nodes: [Node]
        public var segments: [Segment]
        public var overview: String?
    }
    public struct Page: Codable, Sendable {
        public var path: String
        public var versions: [String]
        public var approved: Bool
    }
    public struct Fragment: Codable, Sendable {
        public var id: UUID
        public var text: String
        public var subject: String
        public var reviewed: Bool
        public var pinned: Bool
        public var superseded: Bool
        public var conversationId: String
        public var nodeId: String
    }
    public struct Card: Codable, Sendable {
        public var path: String
        public var version: String
        public var title: String
        public var gist: String
        public var original: String?
    }
    public struct Day: Codable, Sendable {
        public var day: String
        public var conversationId: String
        public var from: String
        public var to: String
        public var title: String
    }
    public struct Variant: Codable, Sendable {
        public var name: String
        public var currentConversationId: String?
        public var master: Bool
        public var budget: Int
    }
    public var name: String
    public var now: Date
    public var windows: [Window]
    public var pages: [Page]
    public var fragments: [Fragment]
    public var cards: [Card]
    public var days: [Day]
    public var daily: String
    public var variants: [Variant]

    /// 同一份 JSON 的快照形态（`load` 时解好，不重复解）
    private(set) var snapshot: FloorSnapshot
    /// 用快照建的一次性只读视图（`branch` 读窗口 / 节点用）
    private let source: SnapshotConversationSource

    private enum CodingKeys: String, CodingKey {
        case name, now, windows, pages, fragments, cards, days, daily, variants
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        now = try c.decode(Date.self, forKey: .now)
        windows = try c.decode([Window].self, forKey: .windows)
        pages = try c.decode([Page].self, forKey: .pages)
        fragments = try c.decode([Fragment].self, forKey: .fragments)
        cards = try c.decode([Card].self, forKey: .cards)
        days = try c.decode([Day].self, forKey: .days)
        daily = try c.decode(String.self, forKey: .daily)
        variants = try c.decode([Variant].self, forKey: .variants)
        let snapshot = try FloorSnapshot(from: decoder)
        self.snapshot = snapshot
        self.source = SnapshotConversationSource(floor: snapshot)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(now, forKey: .now)
        try c.encode(windows, forKey: .windows)
        try c.encode(pages, forKey: .pages)
        try c.encode(fragments, forKey: .fragments)
        try c.encode(cards, forKey: .cards)
        try c.encode(days, forKey: .days)
        try c.encode(daily, forKey: .daily)
        try c.encode(variants, forKey: .variants)
    }

    public static func load(_ name: String, in bundle: Bundle) throws -> (MemoryBenchRecallFloor, Variant) {
        let resource = "memory-bench-recall-floor-xingyan"
        let candidates = [
            bundle.url(forResource: resource, withExtension: "json", subdirectory: "MemoryBench"),
            bundle.url(forResource: resource, withExtension: "json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else { throw MemoryBenchLocalExecutor.Failure("内置快照文件缺失") }
        return try load(contentsOf: url, variant: name)
    }

    public static func load(contentsOf url: URL, variant name: String) throws -> (MemoryBenchRecallFloor, Variant) {
        let floor = try MemoryBench.decoder.decode(Self.self, from: Data(contentsOf: url))
        guard let variant = floor.variants.first(where: { $0.name == name }) else {
            throw MemoryBenchLocalExecutor.Failure("未知内置快照：\(name)")
        }
        return (floor, variant)
    }

    /// 楼层安装的「文件半边」：A2 / A3 段与总览、wiki 页（含历史 / 提案）、seed 卡与原卡存档、
    /// timeline、daily。`Memory` 行（X 半边）留在 app：那是 SwiftData，包不碰。
    /// 逐字搬自 app `MemoryBenchLocalExecutor.install`，段下标按 `branch`（可见主线）编。
    public func installFiles(root: URL, wiki: WikiStore) throws {
        for window in windows {
            let first = window.nodes.first?.at ?? now
            let path = branch(window)
            guard !path.isEmpty else { throw MemoryBenchLocalExecutor.Failure("窗口 \(window.id) 可见主线为空") }
            let segments = try window.segments.map { part in
                guard path.indices.contains(part.from), path.indices.contains(part.to - 1) else {
                    throw MemoryBenchLocalExecutor.Failure("快照段 \(part.from)-\(part.to) 超出主线 \(path.count)")
                }
                return SessionSegment(kind: .rolling, title: "云桥城段\(part.from)", start: path[part.from].at,
                    end: path[part.to - 1].at, from: part.from, to: part.to, lastNodeId: path[part.to - 1].id,
                    story: part.story, quotes: "", pending: "")
            }
            if !segments.isEmpty {
                try SessionSummaryStore.save(.init(conversationId: window.id, title: window.title,
                    compressedCount: segments.last?.to ?? 0, segments: segments, updatedAt: now), in: SessionSummaryStore.dir(root: root))
            }
            if let overview = window.overview, let last = path.last {
                let layers = SessionSummaryStore.splitLayers(overview)
                let part = SessionSegment(kind: .window, title: window.title, start: first, end: last.at,
                    from: 0, to: path.count, lastNodeId: last.id, story: layers.story, quotes: layers.quotes, pending: "",
                    keywords: layers.keywords, format: SessionSegment.currentFormat)
                // A3 水位抄 A2（生产 `SessionCloseout.recompressWindow` 同口径）；路径长度只进段级 `to`。
                try WindowSummaryStore.save(.init(conversationId: window.id, title: window.title, compressedCount: segments.last?.to ?? 0,
                    segments: [part], updatedAt: now, closedThrough: last.id), in: root)
            }
        }
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        for page in pages {
            guard WikiStore.isValidPagePath(page.path) else {
                throw MemoryBenchLocalExecutor.Failure("快照页路径无效")
            }
            if page.approved {
                for (i, raw) in page.versions.enumerated() {
                    if i + 1 == page.versions.count { try WikiStore.writeAtomic(Data(raw.utf8), to: wiki.pageURL(page.path)) }
                    else { try WikiStore.writeAtomic(Data(raw.utf8), to: wiki.historyURL(page.path).appendingPathComponent("2026-10-30-\(i).md")) }
                }
                try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: wiki.pageURL(page.path).path)
            } else if let raw = page.versions.last {
                try WikiStore.writeAtomic(Data(raw.utf8), to: wiki.root.appendingPathComponent(".proposals/fictional/\(page.path).md"))
            }
        }
        let store = SeedNoteStore(wiki: wiki)
        for source in cards {
            let card = SeedNoteCard(path: source.path, version: source.version, name: source.title, layer: "CC", title: source.title,
                gist: source.gist, mentions: [.init(name: source.title, group: "主题")], aboutUser: false, group: "主题", when: [],
                model: "fictional", madeAt: now, run: .init(path: ".runs/fictional.md"))
            if let original = source.original { try store.saveOriginal(path: source.path, version: source.version, text: original, sourceContext: nil) }
            try store.save(card)
        }
        let nodes = Dictionary(uniqueKeysWithValues: windows.flatMap(\.nodes).map { ($0.id, $0.at) })
        for (month, days) in Dictionary(grouping: days, by: { String($0.day.prefix(7)) }) {
            let records = Dictionary(grouping: days, by: \.day).sorted { $0.key < $1.key }.map { day, events in
                TimelineDayRecord(date: day, headline: "云桥城航图记忆日", items: events.map { event in
                    .init(kind: .segment, conversationId: event.conversationId, window: "云桥城航图", title: event.title,
                          start: nodes[event.from]!, end: nodes[event.to]!, from: event.from, to: event.to)
                })
            }
            try TimelineStore.save(.init(days: records), month: month, in: TimelineStore.dir(root: root))
        }
        let dailyText = FrontmatterCodec.render(meta: [("date", daily), ("sourceConversations", RecallTool.json([windows[0].id]))], body: "林栖的云桥城旧日航图")
        try WikiStore.writeAtomic(Data(dailyText.utf8), to: root.appendingPathComponent("daily/\(daily).md"))
    }

    /// 重放用的对话源：只有这个楼层，`profileId` 必须与 `install` 时一致
    public func conversationSource(profileId: String) -> SnapshotConversationSource {
        SnapshotConversationSource(floor: snapshot, profileId: profileId)
    }

    /// 可见主线（plan §2.2）：`visiblePath` 口径，按 id 映射回快照节点。
    /// 段下标 / 越界判定 / 可见节点都按它。
    func branch(_ window: Window) -> [Node] {
        guard let snap = snapshot.windows.first(where: { $0.id == window.id }) else { return [] }
        let profileId = snap.profileId ?? ""
        // 不走 `source.window`：回收站窗口也要能算主线（`branch` 旧实现不看 trashed）
        guard let conversation = try? source.windows(profileId: profileId, updatedSince: nil, includeTrashed: true)
                .first(where: { $0.id == window.id }),
              let nodes = try? source.nodes(profileId: profileId, conversationId: window.id) else { return [] }
        let byId = Dictionary(window.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return visiblePath(window: conversation, nodes: nodes).compactMap { byId[$0.id] }
    }
}
