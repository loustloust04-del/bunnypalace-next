import Foundation

/// 楼层快照（schema 2 = 现有 bench 快照的 windows / nodes 扩字段，向后兼容 schema 1）。
/// 节点补 `contentType / segments / isSyntheticRoot / sourceVisibility / ccMessageId / childrenIds`，
/// 窗口补 `updateTime / branchSelection / isCC / lastRealChatAt / provider / importBatchId / archiveKind`，全部可选。
public struct FloorSnapshot: Codable, Sendable, Equatable {
    public struct Node: Codable, Sendable, Equatable {
        public var id: String
        public var role: String
        public var text: String
        /// nil = 原始消息没有时间（导出端照实写 nil，读回也是 nil）
        public var at: Date?
        public var parent: String?
        public var hidden: Bool
        public var deleted: Bool
        // schema 2（旧快照缺省按 app 默认）
        public var contentType: String?
        public var segments: [ConversationSegment]?
        public var isSyntheticRoot: Bool?
        public var sourceVisibility: String?
        public var ccMessageId: String?
        public var childrenIds: [String]?
        public var cardEditedAt: Date?
        public var ccEdited: Bool?

        public init(id: String, role: String, text: String, at: Date?, parent: String? = nil,
                    hidden: Bool = false, deleted: Bool = false, contentType: String? = nil,
                    segments: [ConversationSegment]? = nil, isSyntheticRoot: Bool? = nil,
                    sourceVisibility: String? = nil, ccMessageId: String? = nil, childrenIds: [String]? = nil,
                    cardEditedAt: Date? = nil, ccEdited: Bool? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.at = at
            self.parent = parent
            self.hidden = hidden
            self.deleted = deleted
            self.contentType = contentType
            self.segments = segments
            self.isSyntheticRoot = isSyntheticRoot
            self.sourceVisibility = sourceVisibility
            self.ccMessageId = ccMessageId
            self.childrenIds = childrenIds
            self.cardEditedAt = cardEditedAt
            self.ccEdited = ccEdited
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            role = try c.decode(String.self, forKey: .role)
            text = try c.decode(String.self, forKey: .text)
            at = try c.decodeIfPresent(SnapshotDate.self, forKey: .at)?.value
            parent = try c.decodeIfPresent(String.self, forKey: .parent)
            hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
            contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
            segments = try c.decodeIfPresent([ConversationSegment].self, forKey: .segments)
            isSyntheticRoot = try c.decodeIfPresent(Bool.self, forKey: .isSyntheticRoot)
            sourceVisibility = try c.decodeIfPresent(String.self, forKey: .sourceVisibility)
            ccMessageId = try c.decodeIfPresent(String.self, forKey: .ccMessageId)
            childrenIds = try c.decodeIfPresent([String].self, forKey: .childrenIds)
            cardEditedAt = try c.decodeIfPresent(SnapshotDate.self, forKey: .cardEditedAt)?.value
            ccEdited = try c.decodeIfPresent(Bool.self, forKey: .ccEdited)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(role, forKey: .role)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(at.map { SnapshotDate($0) }, forKey: .at)
            try c.encodeIfPresent(parent, forKey: .parent)
            try c.encode(hidden, forKey: .hidden)
            try c.encode(deleted, forKey: .deleted)
            try c.encodeIfPresent(contentType, forKey: .contentType)
            try c.encodeIfPresent(segments, forKey: .segments)
            try c.encodeIfPresent(isSyntheticRoot, forKey: .isSyntheticRoot)
            try c.encodeIfPresent(sourceVisibility, forKey: .sourceVisibility)
            try c.encodeIfPresent(ccMessageId, forKey: .ccMessageId)
            try c.encodeIfPresent(childrenIds, forKey: .childrenIds)
            try c.encodeIfPresent(cardEditedAt.map { SnapshotDate($0) }, forKey: .cardEditedAt)
            try c.encodeIfPresent(ccEdited, forKey: .ccEdited)
        }

        private enum CodingKeys: String, CodingKey {
            case id, role, text, at, parent, hidden, deleted
            case contentType, segments, isSyntheticRoot, sourceVisibility, ccMessageId, childrenIds
            case cardEditedAt, ccEdited
        }
    }

    public struct Window: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var current: String
        public var memoryEnabled: Bool
        public var trashed: Bool
        public var nodes: [Node]
        // schema 2
        public var profileId: String?
        public var createTime: Date?
        public var updateTime: Date?
        public var branchSelection: [String: String]?
        public var isCC: Bool?
        public var lastRealChatAt: Date?
        public var provider: String?
        public var importBatchId: String?
        public var archiveKind: String?

        public init(id: String, title: String, current: String, memoryEnabled: Bool, trashed: Bool,
                    nodes: [Node], profileId: String? = nil, createTime: Date? = nil, updateTime: Date? = nil,
                    branchSelection: [String: String]? = nil, isCC: Bool? = nil,
                    lastRealChatAt: Date? = nil, provider: String? = nil,
                    importBatchId: String? = nil, archiveKind: String? = nil) {
            self.id = id
            self.title = title
            self.current = current
            self.memoryEnabled = memoryEnabled
            self.trashed = trashed
            self.nodes = nodes
            self.profileId = profileId
            self.createTime = createTime
            self.updateTime = updateTime
            self.branchSelection = branchSelection
            self.isCC = isCC
            self.lastRealChatAt = lastRealChatAt
            self.provider = provider
            self.importBatchId = importBatchId
            self.archiveKind = archiveKind
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            current = try c.decode(String.self, forKey: .current)
            memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
            trashed = try c.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
            nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
            profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
            createTime = try c.decodeIfPresent(SnapshotDate.self, forKey: .createTime)?.value
            updateTime = try c.decodeIfPresent(SnapshotDate.self, forKey: .updateTime)?.value
            branchSelection = try c.decodeIfPresent([String: String].self, forKey: .branchSelection)
            isCC = try c.decodeIfPresent(Bool.self, forKey: .isCC)
            lastRealChatAt = try c.decodeIfPresent(SnapshotDate.self, forKey: .lastRealChatAt)?.value
            provider = try c.decodeIfPresent(String.self, forKey: .provider)
            importBatchId = try c.decodeIfPresent(String.self, forKey: .importBatchId)
            archiveKind = try c.decodeIfPresent(String.self, forKey: .archiveKind)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(current, forKey: .current)
            try c.encode(memoryEnabled, forKey: .memoryEnabled)
            try c.encode(trashed, forKey: .trashed)
            try c.encode(nodes, forKey: .nodes)
            try c.encodeIfPresent(profileId, forKey: .profileId)
            try c.encodeIfPresent(createTime.map { SnapshotDate($0) }, forKey: .createTime)
            try c.encodeIfPresent(updateTime.map { SnapshotDate($0) }, forKey: .updateTime)
            try c.encodeIfPresent(branchSelection, forKey: .branchSelection)
            try c.encodeIfPresent(isCC, forKey: .isCC)
            try c.encodeIfPresent(lastRealChatAt.map { SnapshotDate($0) }, forKey: .lastRealChatAt)
            try c.encodeIfPresent(provider, forKey: .provider)
            try c.encodeIfPresent(importBatchId, forKey: .importBatchId)
            try c.encodeIfPresent(archiveKind, forKey: .archiveKind)
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, current, memoryEnabled, trashed, nodes
            case profileId, createTime, updateTime, branchSelection, isCC, lastRealChatAt, provider, importBatchId, archiveKind
        }
    }

    // 顶层元数据（E2-6 起导出时写；旧快照没有照读）
    public var schema: Int?
    public var exportedAt: Date?
    public var profileId: String?

    /// 导出写的版本号：节点 / 窗口扩字段的自描述（读取端不靠它分支，兼容 1 与缺省）
    public static let currentSchema = 2

    public var windows: [Window]

    public init(windows: [Window], schema: Int? = nil, exportedAt: Date? = nil, profileId: String? = nil) {
        self.windows = windows
        self.schema = schema
        self.exportedAt = exportedAt
        self.profileId = profileId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = try c.decode([Window].self, forKey: .windows)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema)
        exportedAt = try c.decodeIfPresent(SnapshotDate.self, forKey: .exportedAt)?.value
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windows, forKey: .windows)
        try c.encodeIfPresent(schema, forKey: .schema)
        try c.encodeIfPresent(exportedAt.map { SnapshotDate($0) }, forKey: .exportedAt)
        try c.encodeIfPresent(profileId, forKey: .profileId)
    }

    private enum CodingKeys: String, CodingKey {
        case windows, schema, exportedAt, profileId
    }
}

/// 楼层快照的落盘位置（app 导出、memoryd 识别共用一套字面量）：`<楼层 memory>/exports/floor-snapshot-<ts>.json`
public enum FloorSnapshotExportFolder {
    public static let name = "exports"
    public static let filePrefix = "floor-snapshot-"
    /// 严格的文件名：`floor-snapshot-<UTC yyyyMMdd-HHmmss>Z.json`（导出端清理、memoryd 加载共用）
    public static let fileNamePattern = #"^floor-snapshot-\d{8}-\d{6}Z\.json$"#

    public static func isSnapshotFileName(_ name: String) -> Bool {
        name.range(of: fileNamePattern, options: .regularExpression) != nil
    }
}

/// 快照里的时间沿用 bench 夹具的毫秒整数；也接受 ISO8601 字符串。
struct SnapshotDate: Codable, Sendable {
    let value: Date

    init(_ date: Date) { value = date }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let ms = try? c.decode(Int64.self) {
            value = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else if let text = try? c.decode(String.self),
                  let date = ISO8601DateFormatter().date(from: text) {
            value = date
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "快照时间必须是毫秒整数或 ISO8601 字符串")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        let ms = (value.timeIntervalSince1970 * 1000).rounded()
        guard let exact = Int64(exactly: ms) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: encoder.codingPath, debugDescription: "快照时间越界，不能写成毫秒整数"))
        }
        try c.encode(exact)
    }
}

/// 只读快照实现：读楼层快照 JSON（bench 夹具 / `floor-snapshot.json`）。
/// 生产只读；`insert` / `update` 只服务测试（`@testable`）。
public final class SnapshotConversationSource: ConversationSource, @unchecked Sendable {
    private var windows: [ConversationWindow]
    private var messages: [ConversationMessage]
    /// 窗口 → 楼层；`ConversationMessage` 不带 profileId，归属靠它查
    private var profileByConversation: [String: String]

    public init(floor: FloorSnapshot, profileId: String = "") {
        var windows: [ConversationWindow] = []
        var messages: [ConversationMessage] = []
        var profileByConversation: [String: String] = [:]
        for window in floor.windows {
            let derivedChildren = Self.childrenIndex(window.nodes)
            let times = window.nodes.compactMap(\.at)
            let createTime = window.createTime ?? times.min() ?? Date(timeIntervalSince1970: 0)
            let updateTime = window.updateTime ?? times.max() ?? createTime
            let profile = window.profileId ?? profileId
            profileByConversation[window.id] = profile
            windows.append(ConversationWindow(
                id: window.id, profileId: profile, title: window.title,
                createTime: createTime, updateTime: updateTime,
                isTrashed: window.trashed, memoryEnabled: window.memoryEnabled,
                currentNodeId: window.current,
                branchSelection: window.branchSelection.flatMap(BranchSelection.encode),
                isCC: window.isCC ?? false, lastRealChatAt: window.lastRealChatAt,
                provider: window.provider ?? "chatgpt",
                importBatchId: window.importBatchId, archiveKind: window.archiveKind))
            for node in window.nodes {
                messages.append(ConversationMessage(
                    id: node.id, conversationId: window.id, role: node.role, content: node.text,
                    segments: node.segments, contentType: node.contentType ?? "text",
                    createTime: node.at, parentId: node.parent,
                    childrenIds: node.childrenIds ?? derivedChildren[node.id] ?? [],
                    isTrashed: node.deleted, isSyntheticRoot: node.isSyntheticRoot ?? false,
                    sourceVisibility: node.sourceVisibility ?? (node.hidden ? "hidden" : nil),
                    ccMessageId: node.ccMessageId, cardEditedAt: node.cardEditedAt,
                    ccEdited: node.ccEdited ?? false))
            }
        }
        self.windows = windows
        self.messages = messages
        self.profileByConversation = profileByConversation
    }

    /// 缺省 childrenIds 按 parent 反推并按 `at` 排序（plan §1）
    private static func childrenIndex(_ nodes: [FloorSnapshot.Node]) -> [String: [String]] {
        var byParent: [String: [FloorSnapshot.Node]] = [:]
        for node in nodes {
            guard let parent = node.parent else { continue }
            byParent[parent, default: []].append(node)
        }
        return byParent.mapValues { children in
            children.sorted { ($0.at ?? .distantPast, $0.id) < ($1.at ?? .distantPast, $1.id) }.map(\.id)
        }
    }

    // MARK: - 测试可变（生产只读）

    func insert(_ window: ConversationWindow) {
        windows.removeAll { $0.id == window.id }
        windows.append(window)
        profileByConversation[window.id] = window.profileId
    }

    func update(_ window: ConversationWindow) {
        guard let index = windows.firstIndex(where: { $0.id == window.id }) else { return }
        windows[index] = window
        profileByConversation[window.id] = window.profileId
    }

    func insert(_ message: ConversationMessage) {
        messages.removeAll { $0.id == message.id }
        messages.append(message)
    }

    func update(_ message: ConversationMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index] = message
    }

    // MARK: - ConversationSource

    public func windows(profileId: String, updatedSince: Date?, includeTrashed: Bool) throws -> [ConversationWindow] {
        windows.filter { window in
            window.profileId == profileId
                && (includeTrashed || !window.isTrashed)
                && (updatedSince.map { window.updateTime >= $0 } ?? true)
        }
    }

    public func window(profileId: String, idOrPrefix: String) throws -> ConversationWindow? {
        let candidates = windows.filter { $0.profileId == profileId && !$0.isTrashed }
        if let exact = candidates.first(where: { $0.id == idOrPrefix }) { return exact }
        guard idOrPrefix.count >= 8 else { return nil }
        let matches = candidates.filter { $0.id.hasPrefix(idOrPrefix) }
        if matches.count > 1 { throw ConversationSourceError.ambiguousIdPrefix(idOrPrefix) }
        return matches.first
    }

    public func nodes(profileId: String, conversationId: String) throws -> [ConversationMessage] {
        guard profileByConversation[conversationId] == profileId else { return [] }
        return messages.filter { $0.conversationId == conversationId }
    }

    public func messages(profileId: String, ids: [String]) throws -> [ConversationMessage] {
        let wanted = Set(ids)
        return messages.filter { message in
            wanted.contains(message.id) && profileByConversation[message.conversationId] == profileId
        }
    }

    public func search(profileId: String, text: String, conversationId: String?) throws -> [ConversationMessage] {
        messages
            .filter { message in
                profileByConversation[message.conversationId] == profileId
                    && (conversationId.map { message.conversationId == $0 } ?? true)
                    && !message.isTrashed
                    && message.content.localizedStandardContains(text)
                    && (message.role == "user" || message.role == "assistant")
                    && !message.isSourceHidden && !message.isSyntheticRoot
            }
            .sorted { lhs, rhs in
                let l = lhs.createTime ?? .distantPast, r = rhs.createTime ?? .distantPast
                return l != r ? l > r : lhs.id < rhs.id
            }
    }

    public func titles(profileId: String, ids: [String]) throws -> [String: String] {
        let wanted = Set(ids)
        var out: [String: String] = [:]
        for window in windows where window.profileId == profileId && wanted.contains(window.id) {
            out[window.id] = window.title
        }
        return out
    }
}
