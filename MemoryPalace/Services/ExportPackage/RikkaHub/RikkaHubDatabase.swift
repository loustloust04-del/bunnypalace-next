import Foundation

/// RikkaHub（安卓，AGPL——只参考格式）备份 zip 的容器约定，#048。格式见 docs/research-import-rikkahub.md §1。
enum RikkaHubArchive {
    static let databaseEntry = "rikka_hub.db"
    /// 2026-09 前的老包直接拷活库：WAL 名字对的是 `rikka_hub`，不是 `rikka_hub.db`
    static let walEntry = "rikka_hub-wal"
    static let shmEntry = "rikka_hub-shm"
    static let settingsEntry = "settings.json"
    /// 包里有、认得但不导的目录（D7 灰字）
    static let ignoredDirectories = ["skills": "技能包", "fonts": "字体"]

    /// 要解进 staging 的条目。**settings.json 不在里面**（带 API key，只用 readEntry 读进内存）；
    /// skills / fonts 用不上不解；-shm 由 SQLite 重建，不要。
    static func neededForImport(_ path: String) -> Bool {
        if path == databaseEntry || path == walEntry { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        switch parts[0] {
        case "upload": return parts.count == 2
        case "media_creation": return true
        default: return false
        }
    }
}

enum RikkaHubError: Error, LocalizedError, Equatable {
    case missingDatabase
    case notRikkaHub
    case walCheckpointFailed
    case integrityCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDatabase: return "这个 RikkaHub 备份没带聊天数据库（备份时没勾“数据库”）"
        case .notRikkaHub: return "数据库里没有 RikkaHub 的对话表"
        case .walCheckpointFailed: return "RikkaHub 数据库的日志文件没法合并"
        case .integrityCheckFailed(let detail): return "RikkaHub 数据库损坏：\(detail)"
        }
    }
}

struct RikkaHubConversationRow: Equatable {
    let id: String
    let assistantId: String
    let title: String
    let createAt: Int64?
    let updateAt: Int64?
    let isPinned: Bool
    let customSystemPrompt: String
    let folderId: String
    let workspaceCwd: String
}

/// 一个「位置」：几条候选消息 + 选中哪条。消息是原始 JSON 对象，解码在 mapper 里做
struct RikkaHubPosition {
    let messages: [[String: Any]]
    let selectIndex: Int
}

struct RikkaHubFolderRow: Equatable {
    let id: String
    let assistantId: String
    let name: String
}

struct RikkaHubMemoryRow: Equatable {
    let assistantId: String
    let content: String
}

/// 打开 staging 里解出来的 RikkaHub 库（只动这份拷贝，原包不碰）。
/// 三代存储：G1 对话表 `messages` 列平铺 / G2 对话表 `nodes` 列 / G3 `message_node` 表（research §3）。
/// 一个实例 = 一条连接，只在创建它的线程上用。
final class RikkaHubDatabase {
    enum Generation: Equatable {
        case flatMessages
        case nodesColumn
        case nodeTable
    }

    static let knownSchemaVersion: Int64 = 27

    let schemaVersion: Int64
    let generation: Generation
    private let db: SQLiteDB
    private let tables: Set<String>
    private let conversationColumns: Set<String>

    var isNewerThanKnown: Bool { schemaVersion > Self.knownSchemaVersion }

    /// staging 里的 `rikka_hub.db` 改名 `rikka_hub`（让 SQLite 认出旁边的老 WAL）→ 回放 WAL → 完整性检查 → 只读
    init(stagingDir: URL) throws {
        let fm = FileManager.default
        let archived = stagingDir.appendingPathComponent(RikkaHubArchive.databaseEntry)
        let live = stagingDir.appendingPathComponent("rikka_hub")
        if fm.fileExists(atPath: archived.path) {
            if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
            try fm.moveItem(at: archived, to: live)
        }
        guard fm.fileExists(atPath: live.path) else { throw RikkaHubError.missingDatabase }
        try? fm.removeItem(at: stagingDir.appendingPathComponent(RikkaHubArchive.shmEntry))

        db = try SQLiteDB(url: live, readOnly: false)
        let checkpoint = try db.prepare("PRAGMA wal_checkpoint(TRUNCATE)")
        if try checkpoint.step(), checkpoint.int64(0) != 0 { throw RikkaHubError.walCheckpointFailed }
        let integrity = try db.scalarText("PRAGMA integrity_check") ?? ""
        guard integrity == "ok" else { throw RikkaHubError.integrityCheckFailed(integrity) }
        try db.exec("PRAGMA query_only = 1")

        schemaVersion = try db.scalarInt("PRAGMA user_version")
        var names = Set<String>()
        let tableQuery = try db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        while try tableQuery.step() { if let name = tableQuery.text(0) { names.insert(name) } }
        tables = names
        guard names.contains("ConversationEntity") else { throw RikkaHubError.notRikkaHub }

        var columns = Set<String>()
        let info = try db.prepare("PRAGMA table_info(ConversationEntity)")
        while try info.step() { if let name = info.text(1) { columns.insert(name) } }
        conversationColumns = columns

        if names.contains("message_node") {
            generation = .nodeTable
        } else if columns.contains("nodes") {
            generation = .nodesColumn
        } else if columns.contains("messages") {
            generation = .flatMessages
        } else {
            throw RikkaHubError.notRikkaHub
        }
    }

    /// 有哪列读哪列（老版本少列）；按创建时间排，导入顺序稳定
    func conversations() throws -> [RikkaHubConversationRow] {
        let optional = ["assistant_id", "create_at", "update_at", "is_pinned", "custom_system_prompt", "folder_id", "workspace_cwd"]
        let present = optional.filter(conversationColumns.contains)
        let select = (["id", "title"] + present).map { "`\($0)`" }.joined(separator: ", ")
        let order = conversationColumns.contains("create_at") ? " ORDER BY `create_at`, `id`" : " ORDER BY `id`"
        let statement = try db.prepare("SELECT \(select) FROM ConversationEntity\(order)")
        func column(_ name: String) -> Int32? { present.firstIndex(of: name).map { Int32($0 + 2) } }

        var rows: [RikkaHubConversationRow] = []
        while try statement.step() {
            guard let id = statement.text(0) else { continue }
            rows.append(RikkaHubConversationRow(
                id: id,
                assistantId: column("assistant_id").flatMap(statement.text) ?? "",
                title: statement.text(1) ?? "",
                createAt: column("create_at").flatMap(statement.optionalInt64),
                updateAt: column("update_at").flatMap(statement.optionalInt64),
                isPinned: column("is_pinned").flatMap(statement.optionalInt64).map { $0 != 0 } ?? false,
                customSystemPrompt: column("custom_system_prompt").flatMap(statement.text) ?? "",
                folderId: column("folder_id").flatMap(statement.text) ?? "",
                workspaceCwd: column("workspace_cwd").flatMap(statement.text) ?? ""
            ))
        }
        return rows
    }

    /// 一段对话的位置列表。JSON 坏了的位置给空候选（builder 跳过并计数），整列坏了给空列表
    func positions(of conversationId: String) throws -> (positions: [RikkaHubPosition], brokenJSON: Int) {
        switch generation {
        case .nodeTable:
            let statement = try db.prepare(
                "SELECT messages, select_index FROM message_node WHERE conversation_id = ? ORDER BY node_index"
            )
            statement.bind(1, conversationId)
            var result: [RikkaHubPosition] = []
            var broken = 0
            while try statement.step() {
                let messages = Self.jsonObjects(statement.text(0))
                if messages == nil { broken += 1 }
                result.append(RikkaHubPosition(messages: messages ?? [], selectIndex: Int(statement.int64(1))))
            }
            return (result, broken)
        case .nodesColumn:
            guard let nodes = Self.jsonObjects(try column("nodes", of: conversationId)) else { return ([], 1) }
            let positions = nodes.map { node in
                RikkaHubPosition(
                    messages: node["messages"] as? [[String: Any]] ?? [],
                    selectIndex: (node["selectIndex"] as? NSNumber)?.intValue ?? 0
                )
            }
            return (positions, 0)
        case .flatMessages:
            guard let messages = Self.jsonObjects(try column("messages", of: conversationId)) else { return ([], 1) }
            return (messages.map { RikkaHubPosition(messages: [$0], selectIndex: 0) }, 0)
        }
    }

    func memories() throws -> [RikkaHubMemoryRow] {
        guard tables.contains("MemoryEntity") else { return [] }
        let statement = try db.prepare("SELECT assistant_id, content FROM MemoryEntity ORDER BY id")
        var rows: [RikkaHubMemoryRow] = []
        while try statement.step() {
            let content = statement.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { continue }
            rows.append(RikkaHubMemoryRow(assistantId: statement.text(0) ?? "", content: content))
        }
        return rows
    }

    func folders() throws -> [RikkaHubFolderRow] {
        guard tables.contains("conversation_folder") else { return [] }
        let statement = try db.prepare("SELECT id, assistant_id, name FROM conversation_folder ORDER BY sort_index, create_at")
        var rows: [RikkaHubFolderRow] = []
        while try statement.step() {
            guard let id = statement.text(0) else { continue }
            rows.append(RikkaHubFolderRow(id: id, assistantId: statement.text(1) ?? "", name: statement.text(2) ?? ""))
        }
        return rows
    }

    // MARK: - 预览用的数

    func conversationCount() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM ConversationEntity"))
    }

    /// 有几个版本（重新生成 / 编辑）的位置数。JSON 坏的跳过
    func multiVersionPositionCount() throws -> Int {
        switch generation {
        case .nodeTable:
            return Int(try db.scalarInt(
                "SELECT COUNT(*) FROM message_node WHERE json_valid(messages) AND json_array_length(messages) > 1"))
        case .nodesColumn:
            return Int(try db.scalarInt("""
                SELECT COUNT(*) FROM ConversationEntity, json_each(CASE WHEN json_valid(nodes) THEN nodes ELSE '[]' END) AS n
                WHERE json_array_length(n.value, '$.messages') > 1
                """))
        case .flatMessages:
            return 0
        }
    }

    /// 表存在且有数据（D7 灰字「包里有才列」）
    func hasRows(_ table: String) -> Bool {
        guard tables.contains(table) else { return false }
        return (try? db.scalarInt("SELECT EXISTS(SELECT 1 FROM `\(table)`)")) == 1
    }

    private func column(_ name: String, of conversationId: String) throws -> String? {
        let statement = try db.prepare("SELECT `\(name)` FROM ConversationEntity WHERE id = ?")
        statement.bind(1, conversationId)
        return try statement.step() ? statement.text(0) : nil
    }

    private static func jsonObjects(_ text: String?) -> [[String: Any]]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }
}
