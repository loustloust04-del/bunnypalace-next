import Foundation

extension RecallTool {
    public struct Message: Codable {
        public let id: String
        public let role: String
        public let text: String
        public let date: Date?
        public init(id: String, role: String, text: String, date: Date?) {
            self.id = id
            self.role = role
            self.text = text
            self.date = date
        }
    }
    public struct Path {
        public let title: String
        public let messages: [Message]
        public let branch: String
        public init(title: String, messages: [Message], branch: String) {
            self.title = title
            self.messages = messages
            self.branch = branch
        }
    }

    static func windows(_ state: Cursor, source: any ConversationSource, includingTrashed: Bool = false) throws -> [ConversationWindow] {
        try source.windows(profileId: state.profileId, updatedSince: nil, includeTrashed: includingTrashed)
    }
    static func conversationId(_ state: Cursor, source: any ConversationSource) throws -> String {
        guard let requested = state.input.conversationId ?? state.input.target?.conversationId else { throw RangeError(message: "从父层重新定位：缺 conversation_id。") }
        return try resolveConversation(idOrPrefix: requested, profileId: state.profileId, source: source)
    }
    public static func path(_ cid: String, state: Cursor, source: any ConversationSource) throws -> Path {
        let window: ConversationWindow?
        do {
            window = try source.window(profileId: state.profileId, idOrPrefix: cid)
        } catch ConversationSourceError.ambiguousIdPrefix {
            throw RangeError(message: "从父层重新定位：窗口已删除或不属于当前楼层。")
        }
        guard let window, window.id == cid else {
            throw RangeError(message: "从父层重新定位：窗口已删除或不属于当前楼层。")
        }
        let nodes = try source.nodes(profileId: state.profileId, conversationId: cid)
        let messages = visiblePath(window: window, nodes: nodes).map { node in
            Message(id: node.id, role: node.role, text: CatalogOriginalText.body(of: node), date: node.createTime)
        }
        return Path(title: window.title, messages: messages, branch: branchAnchor(messages, through: messages.count))
    }
    static func branchAnchor(_ messages: [Message], through end: Int) -> String {
        String(revision(json(messages.prefix(end).map(\.id))).prefix(16))
    }
    static func segmentRange(_ segment: CatalogALineReader.Segment, path: Path) -> Range<Int>? {
        guard let last = segment.segment.lastNodeId,
              let end = path.messages.firstIndex(where: { $0.id == last }) else { return nil }
        let count = segment.segment.to - segment.segment.from
        guard count > 0, end + 1 >= count else { return nil }
        return (end + 1 - count)..<(end + 1)
    }
    static func segmentRevision(_ segment: CatalogALineReader.Segment) -> String {
        String(revision(segment.text + "|" + (segment.segment.lastNodeId ?? "")).prefix(16))
    }
    static func directoryRevision(_ window: CatalogALineReader.Window) -> String {
        let summary = SessionSummary(conversationId: window.conversationId, title: window.title, compressedCount: 0,
                                     segments: window.segments.map(\.segment), updatedAt: .distantPast)
        return String(revision(SessionSummaryStore.render(summary)).prefix(16))
    }
    static func segmentTarget(_ segment: CatalogALineReader.Segment, window: CatalogALineReader.Window, state: Cursor, path: Path) -> Target {
        let range = segmentRange(segment, path: path)
        return Target(tree: "a", layer: "segment", conversationId: window.conversationId,
                      segment: segment.number, directoryRevision: segmentRevision(segment), lastNodeId: segment.segment.lastNodeId,
                      branchAnchor: range.map { branchAnchor(path.messages, through: $0.upperBound) })
    }
    public static func messageTarget(_ range: Range<Int>, cid: String, state: Cursor, path: Path) -> Target? {
        guard range.lowerBound >= 0, range.upperBound <= path.messages.count, !range.isEmpty else { return nil }
        return Target(tree: "a", layer: "messages", conversationId: cid,
                      lastNodeId: range.upperBound == path.messages.count ? path.messages[range.upperBound - 1].id : nil,
                      fromNodeId: path.messages[range.lowerBound].id,
                      toNodeIdExclusive: range.upperBound < path.messages.count ? path.messages[range.upperBound].id : nil,
                      branchAnchor: branchAnchor(path.messages, through: range.upperBound))
    }

    public static func readDate(_ requested: Cursor, source: any ConversationSource, root: URL) async throws -> ExecResult {
        var state = requested
        state.layer = "A4"
        let cal = calendar(state)
        let bounds = try resolveRange(date: state.input.date ?? state.input.target?.date, after: state.input.after, before: state.input.before, calendar: cal).get()
        guard let key = state.day ?? state.input.date ?? state.input.target?.date ?? state.input.after,
              var day = parseDay(key, calendar: cal),
              let after = bounds.after, let before = bounds.beforeExclusive, day >= after, day < before else {
            throw RangeError(message: "记忆日不在请求区间内，请从父层重新定位。")
        }
        state.day = key
        let target = Target(tree: "a", layer: "date", date: key)
        let all = try windows(state, source: source, includingTrashed: true)
        let visible = Set(all.filter { !$0.isTrashed && $0.memoryEnabled && $0.id != state.excludedConversationId }.map(\.id))
        var blocks: [Block] = []
        var boundaries: [(day: String, position: Int, revision: String)] = []
        var versions: [String] = []
        for _ in 0..<state.tuning.datePageDays {
            let dayKey = MemoryDay.key(day, calendar: cal)
            guard let end = cal.date(byAdding: .day, value: 1, to: day) else { break }
            let page = try await dateBlocks(state, key: dayKey, day: day, end: end, all: all, visible: visible,
                                            source: source, root: root)
            var dayBlocks = page.blocks
            if let error = page.error {
                if boundaries.isEmpty && (state.tuning.datePageDays == 1 || end >= before) { return error }
                dayBlocks = [Block(label: "\(dayKey) 旧时间轴（旧 daily）· 来源无法逐窗核验", text: "", counts: false)]
            }
            boundaries.append((dayKey, blocks.count, revision(json(dayBlocks))))
            blocks += dayBlocks
            versions.append(page.sourceVersion)
            day = end
            if day >= before { break }
        }
        var next: Cursor?
        if day < before {
            var following = state
            following.day = MemoryDay.key(day, calendar: cal)
            following.position = 0; following.offset = 0; following.revision = ""
            next = following
        }
        let lastDay = boundaries.last!.day
        let pageLabel = key == lastDay ? key : "\(key)…\(lastDay)"
        return deliver(blocks, state: state, revision: boundaries[0].revision, target: target,
                       maximumCount: state.tuning.datePageEvents, nextPage: next,
                       empty: "\(pageLabel) 没有可见的 A4 或旧时间轴。", nextStep: "用窗口/段/原文 target 下钻，或选择另一记忆日",
                       sourceVersion: revision(versions.joined(separator: "|")), dateBoundaries: boundaries)
    }

    private static func dateBlocks(_ state: Cursor, key: String, day: Date, end: Date,
                                   all: [ConversationWindow], visible: Set<String>, source: any ConversationSource, root: URL) async throws
        -> (blocks: [Block], sourceVersion: String, error: ExecResult?) {
        let cal = calendar(state)
        let target = Target(tree: "a", layer: "date", date: key)
        let monthKey = String(key.prefix(7))
        var month = TimelineStore.month(monthKey, in: TimelineStore.dir(root: root))
        var blocks: [Block] = []
        var sourceVersion = ""
        if let record = month.days.first(where: { $0.date == key }) {
            sourceVersion = revision(TimelineStore.render(.init(days: [record]), month: String(key.prefix(7))))
            let items = record.items.filter { visible.contains($0.conversationId) }.sorted { $0.start < $1.start }
            if items.count == record.items.count, !items.isEmpty {
                let headline = [record.headline, record.topics.isEmpty ? nil : "话题：" + record.topics.joined(separator: "、")].compactMap { $0 }.joined(separator: "\n")
                if !headline.isEmpty { blocks.append(Block(label: "\(key) 主调", text: headline, counts: false)) }
            }
            for item in items {
                let cid = item.conversationId
                let p = try path(cid, state: state, source: source)
                var targets = [Target(tree: "a", layer: "window", conversationId: cid)]
                if let from = item.from, let to = item.to,
                   let a = p.messages.firstIndex(where: { $0.id == from }), let b = p.messages.firstIndex(where: { $0.id == to }), a <= b {
                    if item.kind == .segment, let window = await CatalogALineReader.readWindow(cid, memoryRoot: root),
                       window.conversationId == cid,
                       let segment = window.segments.first(where: { segmentRange($0, path: p) == (a..<(b + 1)) }) {
                        targets.append(segmentTarget(segment, window: window, state: state, path: p))
                    } else if let original = messageTarget(a..<(b + 1), cid: cid, state: state, path: p) {
                        targets.append(original)
                    }
                }
                blocks.append(Block(label: "\(key) \(item.period(calendar: cal).label)",
                                    text: TimelineStore.itemText(item), targets: targets))
            }
        } else {
            let nextMonth = MemoryDay.month(end, calendar: cal)
            if nextMonth != monthKey {
                month.entries += TimelineStore.month(nextMonth, in: TimelineStore.dir(root: root)).entries
            }
            let entries = month.entries.filter {
                ($0.day ?? MemoryDay.key($0.start, calendar: cal)) == key && visible.contains($0.conversationId)
            }
            sourceVersion = revision(TimelineStore.render(entries, month: String(key.prefix(7))))
            for entry in entries {
                let text = CatalogALineReader.a4Lines(entry, book: nil).map { $0.map(\.text).joined() }.joined(separator: "\n")
                blocks.append(Block(label: "\(key) 旧时间轴 · \(entry.title)", text: text,
                                    targets: [Target(tree: "a", layer: "window", conversationId: entry.conversationId)]))
            }
            if entries.isEmpty && !month.entries.contains(where: { ($0.day ?? MemoryDay.key($0.start, calendar: cal)) == key }) {
                let calendarStart = cal.startOfDay(for: day)
                if let raw = try? String(contentsOf: root.appendingPathComponent("daily/\(key).md"), encoding: .utf8),
                   let (meta, body) = FrontmatterCodec.parse(raw) {
                    let safe: Bool
                    if let sources = meta["sourceConversations"] {
                        let ids = sources.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                        safe = ids.map { !$0.isEmpty && $0.allSatisfy(visible.contains) } ?? false
                    } else {
                        safe = all.filter { $0.createTime < end && $0.updateTime >= calendarStart }
                            .allSatisfy { visible.contains($0.id) }
                    }
                    guard safe else {
                        return ([], "", failure("A4", "\(key) 从父层重新定位：旧日记来源无法逐窗核验", target: target, status: "unavailable"))
                    }
                    sourceVersion = revision(raw)
                    blocks.append(Block(label: "\(key) 旧时间轴（旧 daily）", text: body))
                }
            }
        }
        return (blocks, sourceVersion, nil)
    }

    static func readWindow(_ requested: Cursor, source: any ConversationSource, root: URL) async throws -> ExecResult {
        var state = requested
        state.layer = "A3"
        let cid = try conversationId(state, source: source)
        guard try windows(state, source: source).first(where: { $0.id == cid })?.memoryEnabled == true else {
            return failure("A3", "从父层重新定位：来源窗口关闭记忆参与，不能读取派生记忆。", target: state.input.target, status: "unavailable")
        }
        let p = try path(cid, state: state, source: source)
        let target = Target(tree: "a", layer: "window", conversationId: cid, branchAnchor: p.branch)
        guard requested.input.target?.branchAnchor == nil || requested.input.target?.branchAnchor == p.branch else {
            return failure("A3", "选中分支已改变，请从窗口重新定位。", target: target, status: "stale")
        }
        guard let window = await CatalogALineReader.readWindow(cid, memoryRoot: root) else {
            return deliver([], state: state, revision: p.branch, target: target, maximumCount: state.tuning.windowPageSegments,
                           empty: "《\(p.title)》还没有窗口总结（A3 缺层），也没有 A2 段目录。", nextStep: "用 messages 指定原文锚")
        }
        guard window.conversationId == cid else {
            return failure("A3", "从父层重新定位：摘要文件的窗口身份不符，拒绝读取同前缀的另一个窗口。", target: target, status: "unavailable")
        }
        let directory = directoryRevision(window)
        func returnedRange(_ segment: SessionSegment) -> Target {
            var range = segmentRange(.init(number: 0, segment: segment), path: p)
                .flatMap { messageTarget($0, cid: cid, state: state, path: p) } ?? target
            range.lastNodeId = segment.lastNodeId
            return range
        }
        var blocks: [Block] = []
        if let a3 = window.a3 {
            blocks.append(Block(label: "《\(p.title)》A3", text: CatalogALineReader.segmentText(a3),
                                counts: false, returnedRange: returnedRange(a3)))
        } else if !window.oldA3.isEmpty {
            for old in window.oldA3 {
                blocks.append(Block(label: "旧窗口总结（还没搬）", text: CatalogALineReader.segmentText(old),
                                    counts: false, returnedRange: returnedRange(old)))
            }
        } else { blocks.append(Block(label: "A3 缺层", text: "还没有独立窗口总结；以下仅为 A2 段目录，不冒充 A3。", counts: false)) }
        for segment in window.segments {
            let old = segment.segment.kind == .legacy ? "改版前的累计摘要" : segment.old
            blocks.append(Block(label: "A2 目录\(old.map { " · " + $0 } ?? "")",
                                text: segment.segment.title + " · " + CatalogALineReader.gist(segment.segment),
                                targets: [segmentTarget(segment, window: window, state: state, path: p)],
                                returnedRange: returnedRange(segment.segment)))
        }
        let version = directory + "|" + revision(blocks.map(\.text).joined(separator: "\n\n")) + "|" + (window.segments.last?.segment.lastNodeId ?? "")
        return deliver(blocks, state: state, revision: revision(p.branch + json(blocks)), target: target,
                       maximumCount: state.tuning.windowPageSegments,
                       nextStep: window.segments.isEmpty ? "A2 缺层；用 messages 指定原文锚" : "用 segment target 读单段 A2",
                       sourceVersion: version)
    }

    static func readSegment(_ requested: Cursor, source: any ConversationSource, root: URL) async throws -> ExecResult {
        var state = requested
        state.layer = "A2"
        let cid = try conversationId(state, source: source)
        guard try windows(state, source: source).first(where: { $0.id == cid })?.memoryEnabled == true else {
            return failure("A2", "从父层重新定位：来源窗口关闭记忆参与，不能读取派生记忆。", target: state.input.target, status: "unavailable")
        }
        let number = state.input.segment ?? state.input.target!.segment!
        let p = try path(cid, state: state, source: source)
        guard let window = await CatalogALineReader.readWindow(cid, memoryRoot: root),
              window.conversationId == cid,
              let read = await CatalogALineReader.readSegment(cid, number: number, memoryRoot: root), read.conversationId == cid else {
            return failure("A2", "没有这段 A2，请从窗口目录重新定位。", target: state.input.target, status: "unavailable")
        }
        let segment = read.segment
        let target = segmentTarget(segment, window: window, state: state, path: p)
        if let old = state.input.target,
           old.directoryRevision != target.directoryRevision || old.lastNodeId != target.lastNodeId || (old.branchAnchor != nil && old.branchAnchor != target.branchAnchor) {
            return failure("A2", "段目录已改版，target 已过期，请从窗口重新定位。", target: target, status: "stale")
        }
        guard window.segments.first(where: { $0.number == number }) == segment else {
            return failure("A2", "读取期间段目录已改版，请重读窗口。", target: target, status: "stale")
        }
        var targets: [Target] = []
        if let range = segmentRange(segment, path: p),
           let original = messageTarget(range, cid: cid, state: state, path: p) { targets.append(original) }
        let bounds = "消息边界 [\(segment.segment.from),\(segment.segment.to)) · last_node_id=\(segment.segment.lastNodeId ?? "无")"
        let old = segment.segment.kind == .legacy ? "改版前的累计摘要" : segment.old
        let unresolved = segment.segment.lastNodeId == nil ? " · 旧段，原文范围不可精确定位" : ""
        let block = Block(label: "\(bounds)\(old.map { " · " + $0 } ?? "")\(unresolved)",
                          text: segment.text, targets: targets, returnedRange: targets.first.map { original in
                              var range = original
                              range.lastNodeId = segment.segment.lastNodeId
                              return range
                          })
        let version = segmentRevision(segment) + "|" + (segment.segment.lastNodeId ?? "")
        return deliver([block], state: state, revision: revision(version + (target.branchAnchor ?? "")), target: target, maximumCount: 1,
                       nextStep: targets.isEmpty ? "原消息边界不可定位；返回窗口目录" : "用 messages target 读原文半开范围",
                       sourceVersion: version)
    }

    public static func readMessages(_ requested: Cursor, source: any ConversationSource, userName: String, assistantName: String,
                             original: Target? = nil, layer: String = "原文") throws -> ExecResult {
        var state = requested
        state.layer = layer
        let cid = try original?.conversationId ?? conversationId(state, source: source)
        let p = try path(cid, state: state, source: source)
        let from = original?.fromNodeId ?? state.input.fromNodeId ?? state.input.target!.fromNodeId!
        let to = original?.toNodeIdExclusive ?? state.input.toNodeIdExclusive ?? state.input.target?.toNodeIdExclusive
        let startIndex = p.messages.firstIndex(where: { $0.id == from })
        let missingStatus = state.input.target?.branchAnchor != nil || !state.revision.isEmpty ? "stale" : "invalidTarget"
        var end = p.messages.count
        if to == nil, let last = state.lastNodeId ?? original?.lastNodeId ?? state.input.target?.lastNodeId {
            guard let index = p.messages.firstIndex(where: { $0.id == last }), let start = startIndex, index >= start else {
                return failure(layer, "从父层重新定位：原文范围的末节点已不可见，cursor 已过期。", target: state.input.target, status: "stale")
            }
            end = index + 1
        }
        guard let start = startIndex else {
            return failure(layer, "从父层重新定位：from_node_id 不在当前选中分支，或已隐藏/删除；不会回落整窗。", target: state.input.target, status: missingStatus)
        }
        if let to {
            guard let index = p.messages.firstIndex(where: { $0.id == to }), index > start else {
                return failure(layer, "从父层重新定位：to_node_id_exclusive 必须在同一选中分支且晚于 from；反向/跨分支/隐藏/删除锚拒绝。", target: state.input.target, status: missingStatus)
            }
            end = index
        }
        state.lastNodeId = p.messages[end - 1].id
        let branch = branchAnchor(p.messages, through: end)
        let target = state.input.op == .wiki ? state.input.target! : Target(
            tree: "a", layer: "messages", conversationId: cid, lastNodeId: to == nil ? state.lastNodeId : nil,
            fromNodeId: from, toNodeIdExclusive: to, branchAnchor: branch)
        if let expected = original?.branchAnchor ?? state.input.target?.branchAnchor, expected != branch {
            return failure(layer, "原文 target 的范围/分支与签发时不一致：请原样回灌段层返回的 messages target，不要自行补或改 from_node_id / to_node_id_exclusive；分支确实改了就从父段重新定位。", target: target, status: "stale")
        }
        let selected = Array(p.messages[start..<end])
        let blocks = selected.map { message in
            Block(label: "\(message.role == "user" ? userName : assistantName) · node=\(message.id) · \(message.date.map { FrontmatterCodec.dateFormatter.string(from: $0) } ?? "时间未记录")",
                  text: message.text, returnedRange: Target(tree: state.input.op == .wiki ? "c" : "a",
                      layer: target.layer, conversationId: cid, lastNodeId: message.id, fromNodeId: message.id,
                      page: target.page, row: target.row, card: target.card))
        }
        return deliver(blocks, state: state, revision: revision(branch + json(selected)), target: target,
                       maximumCount: state.tuning.originalPageMessages, nextStep: "本范围已读完；需要时从父段选另一个原文范围",
                       sourceVersion: branch)
    }

    public struct SearchPage {
        public init(layer: String = "原文", identities: [String] = [], blocks: [Block] = [], directory: Bool = false, indexBuilding: Bool = false) {
            self.layer = layer
            self.identities = identities
            self.blocks = blocks
            self.directory = directory
            self.indexBuilding = indexBuilding
        }
        public var layer = "原文"
        public var identities: [String] = []
        public var blocks: [Block] = []
        public var directory = false
        public var indexBuilding = false
    }
    static func search(_ requested: Cursor, source: any ConversationSource, root: URL, master: Bool,
                       environment: RecallEnvironment) async throws -> ExecResult {
        let input = requested.input
        let bounds = try resolveRange(date: input.date, after: input.after, before: input.before, calendar: calendar(requested)).get()
        let query = input.query!.trimmingCharacters(in: .whitespacesAndNewlines)
        let cid = input.conversationId == nil ? nil : try conversationId(requested, source: source)
        let visible = Set(try windows(requested, source: source).filter {
            $0.id != requested.excludedConversationId && (cid == nil || $0.id == cid) && $0.memoryEnabled
        }.map(\.id))
        var paths: [String: Path] = [:]
        func cachedPath(_ id: String) throws -> Path {
            if let path = paths[id] { return path }
            let value = try path(id, state: requested, source: source)
            paths[id] = value
            return value
        }
        var state = requested
        let selection = state.position..<(state.position + state.tuning.searchPageResults + 1)
        var page = SearchPage()
        if master && input.exact != true {
            if input.scope == "a" {
                let interval = bounds.after.map { DateInterval(start: $0, end: bounds.beforeExclusive ?? .distantFuture) }
                let result = searchALine(terms: [query], in: interval, memoryRoot: root, conversationIds: visible)
                let chosen = [CatalogALineReader.Layer.a4, .a3, .a2].first { layer in result.hits.contains { $0.layer == layer } }
                if let chosen {
                    page.layer = chosen.rawValue
                    var seen = Set<String>()
                    for hit in result.hits where hit.layer == chosen {
                        let identity = (hit.conversationId ?? "") + "|" + hit.day + "|" + String(hit.segment ?? -1)
                        guard seen.insert(identity).inserted else { continue }
                        let path = try hit.conversationId.map(cachedPath)
                        let index = page.identities.count
                        page.identities.append(identity + "|" + (path?.branch ?? "") + "|" + revision(hit.text + json(hit.keywords)))
                        guard selection.contains(index) else { continue }
                        var target = Target(tree: "a", layer: "date", date: hit.day)
                        if let conv = hit.conversationId, let path {
                            target = Target(tree: "a", layer: "window", conversationId: conv)
                            if let number = hit.segment {
                                guard let w = await CatalogALineReader.readWindow(conv, memoryRoot: root), w.conversationId == conv,
                                      let segment = w.segments.first(where: { $0.number == number }) else {
                                    throw RangeError(message: "摘要窗口/段身份已改变，请重新搜索。")
                                }
                                target = segmentTarget(segment, window: w, state: state, path: path)
                            }
                        }
                        page.blocks.append(Block(label: "\(hit.day) · \(hit.title)\(hit.old.map { " · " + $0 } ?? "")",
                                                 text: centeredSnippet(hit.bodyText, keyword: query, limit: snippetLimit), targets: [target]))
                    }
                }
            } else {
                page = try await searchCatalog(state, root: root, query: query, after: bounds.after, before: bounds.beforeExclusive)
                if page.layer == "L1" && !page.directory {
                    let memories = try legacyMemories(state, source: source, query: query, after: bounds.after,
                                                      before: bounds.beforeExclusive, visible: visible, environment: environment,
                                                      preceding: page.identities.count, path: cachedPath)
                    page.identities += memories.identities
                    page.blocks += memories.blocks
                }
            }
        }
        if page.identities.isEmpty {
            let building = page.indexBuilding
            page = try originalSearch(state, source: source, query: query, cid: cid, after: bounds.after,
                                      before: bounds.beforeExclusive, path: cachedPath)
            page.indexBuilding = building
        }
        state.layer = page.layer
        if !requested.revision.isEmpty {
            let count = requested.searchRevisionCount ?? page.identities.count
            guard requested.layer == state.layer, count <= page.identities.count,
                  requested.revision == revision(json(Array(page.identities.prefix(count)))) else {
                return failure(requested.layer, "从父层重新定位：原命中层或来源分支已改版，cursor 过期；不会切换到低层。", status: "stale")
            }
        }
        state.revision = ""
        state.searchRevisionCount = page.identities.count
        let target = Target(tree: input.scope!, layer: "search", conversationId: cid, query: query, scope: input.scope)
        var notices: [String] = []
        if !master && input.scope == "c" { notices.append("记忆总开关关闭，只搜原文") }
        if page.indexBuilding { notices.append("档案索引还在建") }
        return deliver(page.blocks, state: state, revision: revision(json(page.identities)), target: target,
                       maximumCount: state.tuning.searchPageResults, nextStep: "使用每项 target 的 op/layer 下钻，不把摘要当原文",
                       positionBase: state.position, notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
    }
    public static func originalSearch(_ state: Cursor, source: any ConversationSource, query: String, cid: String?, after: Date?, before: Date?,
                               path: (String) throws -> Path) throws -> SearchPage {
        var page = SearchPage()
        var seen = Set<String>(), counts: [String: Int] = [:]
        let selection = state.position..<(state.position + state.tuning.searchPageResults + 1)
        for hit in (try? source.search(profileId: state.profileId, text: query, conversationId: cid)) ?? [] {
            guard hit.conversationId != state.excludedConversationId,
                  (after == nil || inRange(hit.createTime, after: after, beforeExclusive: before)),
                  counts[hit.conversationId, default: 0] < state.tuning.searchPageResults,
                  seen.insert(hit.id).inserted else { continue }
            guard let p = try? path(hit.conversationId),
                  let i = p.messages.firstIndex(where: { $0.id == hit.id }), p.messages[i].text.localizedStandardContains(query) else { continue }
            counts[hit.conversationId, default: 0] += 1
            let index = page.identities.count
            page.identities.append(hit.id + "|" + branchAnchor(p.messages, through: i + 1))
            if selection.contains(index), let target = messageTarget(i..<(i + 1), cid: hit.conversationId, state: state, path: p) {
                page.blocks.append(Block(label: "\(MemoryDay.key(hit.createTime ?? .distantPast, calendar: calendar(state))) · \(p.title)",
                                         text: centeredSnippet(p.messages[i].text, keyword: query, limit: snippetLimit), targets: [target],
                                         returnedRange: Target(tree: "a", layer: "messages", conversationId: hit.conversationId,
                                                               lastNodeId: hit.id, fromNodeId: hit.id)))
            }
            if page.identities.count >= selection.upperBound { break }
        }
        return page
    }
    static func legacyMemories(_ state: Cursor, source: any ConversationSource, query: String, after: Date?, before: Date?,
                               visible: Set<String>, environment: RecallEnvironment, preceding: Int,
                               path: (String) throws -> Path) throws -> SearchPage {
        let hits = environment.searchL1(query, state.profileId, state.input.includeInvalid == true,
                            after, before)
        let selection = state.position..<(state.position + state.tuning.searchPageResults + 1)
        var seen = Set<String>(), page = SearchPage(layer: "L1")
        for hit in hits.hits {
            guard hit.sourceConversationId.map(visible.contains) != false else { continue }
            if state.input.conversationId != nil && hit.sourceConversationId == nil { continue }
            let sourcePath = hit.sourceConversationId.flatMap { try? path($0) }
            var original: Target?
            if let cid = hit.sourceConversationId, let node = hit.sourceNodeId {
                guard let p = sourcePath, let i = p.messages.firstIndex(where: { $0.id == node }) else { continue }
                original = messageTarget(i..<(i + 1), cid: cid, state: state, path: p)
            }
            let source = hit.sourceNodeId.map { (hit.sourceConversationId ?? "") + "|" + $0 } ?? hit.id.uuidString
            guard seen.insert(source).inserted else { continue }
            let index = preceding + page.identities.count
            page.identities.append(hit.id.uuidString + "|" + (original?.branchAnchor ?? sourcePath?.branch ?? ""))
            guard selection.contains(index) else { continue }
            page.blocks.append(Block(label: "\(hit.isFragment ? "碎片" : "旧档案") · \(hit.category)\(hit.invalid ? " · 已失效" : "") · memory_id=\(hit.id.uuidString)\(original == nil ? " · 无可验证原文锚" : "")",
                                     text: centeredSnippet(hit.content, keyword: query, limit: snippetLimit),
                                     targets: original.map { [$0] } ?? [], memoryId: hit.invalid ? nil : hit.id))
        }
        return page
    }
}
