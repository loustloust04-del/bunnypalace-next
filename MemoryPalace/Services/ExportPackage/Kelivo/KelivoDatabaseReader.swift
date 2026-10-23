import CryptoKit
import Foundation

/// 新版 Kelivo（archive formatVersion 2/3）备份：先按 `manifest.json` 核对 `database/kelivo.db` 的大小和 sha256，
/// 再只读打开 SQLite，逐段对话读 `conversation_rows` / `message_rows` / `message_part_rows` + `assistant_rows`（只取名字和
/// system prompt）。不碰 settings.json 和其余带凭证的表（plan D4）。schema 1/2/3 的列差异按 `PRAGMA table_info` 判断。
enum KelivoDatabaseReader {
    enum ReadError: LocalizedError, Equatable {
        case notManifest
        case unsupportedVersion(Int)
        case settingsOnly
        case databaseMissing
        case databaseMismatch
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notManifest: return "不是 Kelivo 备份清单"
            case .unsupportedVersion(let v): return "Kelivo 备份格式版本 \(v) 太新，读不了"
            case .settingsOnly: return "这个 Kelivo 备份没勾「聊天记录」，里面只有设置"
            case .databaseMissing: return "Kelivo 备份里缺聊天数据库"
            case .databaseMismatch: return "Kelivo 备份里的聊天数据库和清单对不上（大小或校验和），可能下载不完整"
            case .unreadable(let why): return "Kelivo 聊天数据库读不了：\(why)"
            }
        }
    }

    struct Manifest {
        var formatVersion: Int
        var appVersion: String?
        var databaseEntry: String
        var expectedBytes: Int64?
        var expectedSHA256: String?
        var conversationCount: Int?
        var messageCount: Int?
        var schemaVersion: Int?
    }

    /// 读清单。`settings-only` / 格式太新抛错（不是解析失败，结果页照实说）
    static func manifest(data: Data) throws -> Manifest {
        guard let root = KelivoBackup.jsonObject(String(decoding: data, as: UTF8.self)), KelivoBackup.isManifest(root),
              let dict = root as? [String: Any], let version = dict["formatVersion"] as? Int else { throw ReadError.notManifest }
        if version > 3 {
            let minimum = dict["minimumReadableFormatVersion"] as? Int ?? Int.max
            guard (1...3).contains(minimum) else { throw ReadError.unsupportedVersion(version) }
        } else if version < 2 {
            throw ReadError.unsupportedVersion(version)
        }
        if dict["payloadKind"] as? String == "settings-only" { throw ReadError.settingsOnly }
        let database = dict["database"] as? [String: Any] ?? [:]
        // 库位置写死，不信清单里的 `database.entry`（`../` 能指到别的包，sol #2）
        let entry = KelivoArchive.databaseEntry
        let expected = (dict["entries"] as? [String: Any])?[entry] as? [String: Any]
        return Manifest(formatVersion: version, appVersion: dict["appVersion"] as? String, databaseEntry: entry,
                        expectedBytes: (expected?["bytes"] as? NSNumber)?.int64Value,
                        expectedSHA256: (expected?["sha256"] as? String)?.lowercased(),
                        conversationCount: database["conversationCount"] as? Int, messageCount: database["messageCount"] as? Int,
                        schemaVersion: database["schemaVersion"] as? Int)
    }

    /// v3 必须有库的大小 + sha256（上游导出总写，sol #11）；v2 没写的不拦
    static func verify(database url: URL, against manifest: Manifest) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReadError.databaseMissing }
        if manifest.formatVersion >= 3, manifest.expectedBytes == nil || manifest.expectedSHA256 == nil {
            throw ReadError.databaseMismatch
        }
        if let bytes = manifest.expectedBytes {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            guard Int64(size) == bytes else { throw ReadError.databaseMismatch }
        }
        if let expected = manifest.expectedSHA256 {
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw ReadError.databaseMissing }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw ReadError.databaseMismatch }
        }
    }

    static let knownSchemaVersion = 3

    struct Summary {
        var schemaVersion: Int
        var conversationCount: Int
        /// 库里记着「从旧版存储迁移没做完」：可能缺对话（sol #12）
        var migrationIncomplete = false
        /// 库的 schema 比已知的新：按列名照读，可能有没读到的内容
        var newerThanKnown: Bool { schemaVersion > KelivoDatabaseReader.knownSchemaVersion }
    }

    /// 逐段对话回调（不把整库读进内存）。数据库只读打开
    static func read(database url: URL, each: (KelivoBackup.Conversation) throws -> Void) throws -> Summary {
        let db: SQLiteDB
        do { db = try SQLiteDB(url: url, readOnly: true) } catch { throw ReadError.unreadable(error.localizedDescription) }
        do {
            let schema = Int(try db.scalarInt("PRAGMA user_version"))
            var migrationIncomplete = false
            if try columns(db, "chat_storage_meta_rows").isSuperset(of: ["key", "value"]) {
                migrationIncomplete = try db.scalarText(
                    "SELECT value FROM chat_storage_meta_rows WHERE key = 'hive_migration_complete_v1'") != "true"
            }
            let assistants = try readAssistants(db)
            let convColumns = try columns(db, "conversation_rows")
            let msgColumns = try columns(db, "message_rows")
            guard convColumns.contains("id"), msgColumns.contains("conversation_id"),
                  try !columns(db, "message_part_rows").isEmpty else { throw ReadError.unreadable("缺聊天表") }

            let optionalConv = ["is_pinned", "assistant_id", "truncate_index", "version_selections_json", "summary",
                                "chat_model_provider", "chat_model_id", "extras_json"].filter(convColumns.contains)
            let convSQL = "SELECT id, title, created_at, updated_at" + optionalConv.map { ", " + $0 }.joined()
                + " FROM conversation_rows ORDER BY created_at, id"
            let optionalMsg = ["model_id", "provider_id", "total_tokens", "prompt_tokens", "completion_tokens", "cached_tokens",
                               "duration_ms", "translation", "is_streaming", "reasoning_segments_json", "reasoning_start_at",
                               "reasoning_finished_at", "updated_at", "sender_id", "extras_json"].filter(msgColumns.contains)
            let msgSQL = "SELECT id, role, timestamp, group_id, version, message_order" + optionalMsg.map { ", " + $0 }.joined()
                + " FROM message_rows WHERE conversation_id = ? ORDER BY message_order, id"
            let messageStatement = try db.prepare(msgSQL)
            let partStatement = try db.prepare(
                "SELECT revision_id, kind, payload FROM message_part_rows WHERE conversation_id = ? ORDER BY revision_id, ordinal")

            var count = 0
            let conversations = try db.prepare(convSQL)
            while try conversations.step() {
                guard let id = conversations.text(0) else { continue }
                var conv = KelivoBackup.Conversation(
                    id: id, title: conversations.text(1) ?? "",
                    createdAt: KelivoBackup.date(microseconds: conversations.optionalInt64(2)),
                    updatedAt: KelivoBackup.date(microseconds: conversations.optionalInt64(3)))
                for (i, column) in optionalConv.enumerated() {
                    let index = Int32(4 + i)
                    switch column {
                    case "version_selections_json":
                        for (key, value) in KelivoBackup.jsonObject(conversations.text(index)) as? [String: Any] ?? [:] {
                            if let v = (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) { conv.selections[key] = v }
                        }
                    case "assistant_id":
                        conv.assistantId = conversations.text(index)
                    case "is_pinned", "truncate_index":
                        if let v = conversations.optionalInt64(index) { conv.metadata[column] = v }
                    case "extras_json":
                        if let v = KelivoBackup.jsonObject(conversations.text(index)) { conv.metadata[column] = v }
                    default:
                        if let v = conversations.text(index) { conv.metadata[column] = v }
                    }
                }
                if let assistantId = conv.assistantId, let assistant = assistants[assistantId] {
                    var a: [String: Any] = [:]
                    if let name = assistant.name { a["name"] = name }
                    if let prompt = assistant.systemPrompt { a["systemPrompt"] = prompt }
                    conv.metadata["assistant"] = a
                }
                conv.revisions = try readRevisions(conversationId: id, messages: messageStatement, optional: optionalMsg,
                                                   parts: partStatement)
                // 回调（写库）的错原样往外抛，不当成「库读不了」
                do { try each(conv) } catch { throw CallbackError(underlying: error) }
                count += 1
            }
            return Summary(schemaVersion: schema, conversationCount: count, migrationIncomplete: migrationIncomplete)
        } catch let e as ReadError {
            throw e
        } catch let e as CallbackError {
            throw e.underlying
        } catch {
            throw ReadError.unreadable(error.localizedDescription)
        }
    }

    private struct CallbackError: Error { let underlying: Error }

    private static func readRevisions(conversationId: String, messages: SQLiteDB.Statement, optional: [String],
                                      parts: SQLiteDB.Statement) throws -> [KelivoBackup.Revision] {
        parts.reset()
        parts.bind(1, conversationId)
        var partsByRevision: [String: [KelivoBackup.Part]] = [:]
        while try parts.step() {
            guard let revision = parts.text(0), let kind = parts.text(1) else { continue }
            partsByRevision[revision, default: []].append(KelivoBackup.part(kind: kind, payload: parts.text(2) ?? ""))
        }

        messages.reset()
        messages.bind(1, conversationId)
        var out: [KelivoBackup.Revision] = []
        while try messages.step() {
            guard let id = messages.text(0) else { continue }
            let group = messages.text(3).flatMap { $0.isEmpty ? nil : $0 } ?? id
            var revision = KelivoBackup.Revision(
                id: id, role: messages.text(1).flatMap { $0.isEmpty ? nil : $0 } ?? "user", groupKey: group,
                version: Int(messages.optionalInt64(4) ?? 0), order: Int(messages.optionalInt64(5) ?? 0),
                time: KelivoBackup.date(microseconds: messages.optionalInt64(2)))
            revision.parts = partsByRevision[id] ?? []
            for (i, column) in optional.enumerated() {
                let index = Int32(6 + i)
                switch column {
                case "translation", "model_id", "provider_id", "sender_id", "reasoning_segments_json":
                    if let v = messages.text(index) { revision.metadata[column] = v }
                case "extras_json":
                    if let v = KelivoBackup.jsonObject(messages.text(index)) { revision.metadata[column] = v }
                default:
                    if let v = messages.optionalInt64(index) { revision.metadata[column] = v }
                }
            }
            out.append(revision)
        }
        return out
    }

    /// 助手只取显示名和 system prompt：在 SQLite 里取字段，payload 里 customHeaders 这类可能带凭证的不进 Swift（sol #3）
    private static func readAssistants(_ db: SQLiteDB) throws -> [String: KelivoBackup.Assistant] {
        guard try columns(db, "assistant_rows").isSuperset(of: ["id", "payload"]) else { return [:] }
        var out: [String: KelivoBackup.Assistant] = [:]
        let s = try db.prepare("SELECT id, json_extract(payload, '$.name'), json_extract(payload, '$.systemPrompt') "
            + "FROM assistant_rows WHERE json_valid(payload)")
        while try s.step() {
            guard let id = s.text(0) else { continue }
            out[id] = KelivoBackup.Assistant(name: s.text(1), systemPrompt: s.text(2))
        }
        return out
    }

    private static func columns(_ db: SQLiteDB, _ table: String) throws -> Set<String> {
        let s = try db.prepare("PRAGMA table_info(\(table))")
        var out = Set<String>()
        while try s.step() { if let name = s.text(1) { out.insert(name) } }
        return out
    }
}
