import CryptoKit
import XCTest
@testable import 记忆花园

/// #049：Kelivo 两代备份解析 + 转 payload。全部合成样本（结构依据 docs/research-import-kelivo-format.md，没抄上游 fixture）：
/// 旧版在测试里写 `chats.json`，新版用 `SQLiteDB` 现建最小表。
final class KelivoImportTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kelivo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    // MARK: - 旧版样本

    private func legacy(_ conversations: [[String: Any]], _ messages: [[String: Any]], tools: [String: Any] = [:]) throws -> KelivoLegacyParser.Result {
        let root: [String: Any] = ["version": 1, "conversations": conversations, "messages": messages, "toolEvents": tools, "geminiThoughtSigs": [:]]
        return try KelivoLegacyParser.parse(data: JSONSerialization.data(withJSONObject: root), timeZone: shanghai)
    }

    private func msg(_ id: String, _ role: String, _ content: String, conv: String = "c1", group: String? = nil, version: Int = 0,
                     time: String = "2025-03-01T10:00:00.000", extra: [String: Any] = [:]) -> [String: Any] {
        var m: [String: Any] = ["id": id, "role": role, "content": content, "conversationId": conv, "timestamp": time,
                                "isStreaming": false, "version": version]
        if let group { m["groupId"] = group }
        for (k, v) in extra { m[k] = v }
        return m
    }

    private func conv(_ id: String, _ ids: [String], title: String = "旧对话", selections: [String: Int] = [:]) -> [String: Any] {
        ["id": id, "title": title, "createdAt": "2025-03-01T10:00:00.000Z", "updatedAt": "2025-03-01T11:00:00.000Z",
         "messageIds": ids, "isPinned": true, "mcpServerIds": [], "truncateIndex": -1, "versionSelections": selections,
         "lastSummarizedMessageCount": 0, "chatSuggestions": []]
    }

    private func build(_ c: KelivoBackup.Conversation, members: Set<String> = []) throws -> (ImportedConversationPayload, KelivoPayloadBuilder.Stats) {
        var stats = KelivoPayloadBuilder.Stats()
        let p = try XCTUnwrap(KelivoPayloadBuilder.payload(c, format: "test", members: members, stats: &stats))
        return (p, stats)
    }

    private func segments(_ node: ImportedNodePayload) throws -> [MessageSegment] {
        try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(node.segmentsData))
    }

    private func node(_ p: ImportedConversationPayload, _ kelivoId: String) throws -> ImportedNodePayload {
        try XCTUnwrap(p.nodes.first { $0.id == "\(p.id)/\(kelivoId)" })
    }

    // MARK: - 旧版

    func testLegacyBasicConversation() throws {
        let r = try legacy([conv("c1", ["u1", "a1"])], [msg("u1", "user", "你好"), msg("a1", "assistant", "你好呀", time: "2025-03-01T02:00:05Z")])
        XCTAssertEqual(r.conversations.count, 1)
        let (p, _) = try build(r.conversations[0])
        XCTAssertEqual(p.id, "c1@kelivo")
        XCTAssertEqual(p.provider, "kelivo")
        XCTAssertEqual(p.title, "旧对话")
        XCTAssertEqual(p.nodes.map(\.role), ["system", "user", "assistant"])
        XCTAssertTrue(p.nodes[0].isSyntheticRoot, "顶上一个合成根")
        XCTAssertEqual(p.nodes[0].childrenIds, ["c1@kelivo/u1"])
        XCTAssertEqual(try node(p, "u1").parentId, "c1@kelivo#root")
        XCTAssertNil(p.branchSelectionData, "没分叉不写选择表")
        XCTAssertEqual(try node(p, "a1").parentId, "c1@kelivo/u1")
        XCTAssertEqual(try node(p, "u1").childrenIds, ["c1@kelivo/a1"])
        XCTAssertEqual(p.currentNodeId, "c1@kelivo/a1")
        // 没时区的按指定时区（上海）：10:00 本地 = 02:00Z
        XCTAssertEqual(try node(p, "u1").createTime, ISO8601DateFormatter().date(from: "2025-03-01T02:00:00Z"))
        XCTAssertEqual(try node(p, "a1").createTime, ISO8601DateFormatter().date(from: "2025-03-01T02:00:05Z"))
        XCTAssertEqual(r.counts.noTimezoneTimes, 1)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(p.sourceMetadata)) as? [String: Any])
        XCTAssertEqual(meta["isPinned"] as? Bool, true, "置顶只记来源信息")
    }

    func testLegacyRegenerationOrdinalSelection() throws {
        // a1 三个版本（0/1/2），选中序号 1 → version 1；之后的 u2 挂在选中版本下
        let r = try legacy([conv("c1", ["u1", "a1", "a1b", "a1c", "u2", "a2"], selections: ["a1": 1])], [
            msg("u1", "user", "问"), msg("a1", "assistant", "答0", group: "a1", version: 0),
            msg("a1b", "assistant", "答1", group: "a1", version: 1), msg("a1c", "assistant", "答2", group: "a1", version: 2),
            msg("u2", "user", "再问"), msg("a2", "assistant", "再答"),
        ])
        let (p, stats) = try build(r.conversations[0])
        XCTAssertEqual(try node(p, "u1").childrenIds, ["c1@kelivo/a1", "c1@kelivo/a1b", "c1@kelivo/a1c"])
        XCTAssertEqual(try node(p, "a1b").childrenIds, ["c1@kelivo/u2"])
        XCTAssertEqual(try node(p, "a1").childrenIds, [], "没选中的版本是叶子")
        XCTAssertEqual(try node(p, "u2").parentId, "c1@kelivo/a1b")
        XCTAssertEqual(p.currentNodeId, "c1@kelivo/a2")
        XCTAssertEqual(stats.regeneratedGroups, 1)
        XCTAssertEqual(BranchSelection.decode(p.branchSelectionData), ["c1@kelivo/u1": "c1@kelivo/a1b"])
    }

    /// 第一条消息就有多个版本（改过开场白）：都挂在合成根下，不各自当根（sol #5）
    func testFirstSlotVersionsShareSyntheticRoot() throws {
        let r = try legacy([conv("c1", ["u1", "u1b", "a1"], selections: ["u1": 0])], [
            msg("u1", "user", "开场", group: "u1", version: 0), msg("u1b", "user", "改过的开场", group: "u1", version: 1),
            msg("a1", "assistant", "答"),
        ])
        let (p, _) = try build(r.conversations[0])
        XCTAssertEqual(p.nodes.filter { $0.parentId == nil }.map(\.id), ["c1@kelivo#root"])
        XCTAssertEqual(p.nodes[0].childrenIds, ["c1@kelivo/u1", "c1@kelivo/u1b"])
        XCTAssertEqual(try node(p, "u1b").parentId, "c1@kelivo#root")
        XCTAssertEqual(try node(p, "a1").parentId, "c1@kelivo/u1")
        XCTAssertEqual(BranchSelection.decode(p.branchSelectionData), ["c1@kelivo#root": "c1@kelivo/u1"])
    }

    func testLegacyOrdinalOutOfRangeTakesLast() throws {
        let r = try legacy([conv("c1", ["u1", "a1", "a1b"], selections: ["a1": 9])], [
            msg("u1", "user", "问"), msg("a1", "assistant", "旧", group: "a1", version: 0), msg("a1b", "assistant", "新", group: "a1", version: 1),
        ])
        XCTAssertEqual(r.conversations[0].selections["a1"], 1)
        XCTAssertEqual(try build(r.conversations[0]).0.currentNodeId, "c1@kelivo/a1b")
    }

    func testLegacyRepairs() throws {
        let r = try legacy([
            conv("c1", ["u1", "ghost", "a1", "a1", "v1"]),
            conv("c1", ["u1"], title: "重复会话"),
            conv("c2", ["u2", "a1"]),
        ], [
            msg("u1", "user", "一"), msg("a1", "assistant", "答"), msg("v1", "assistant", "撞版本", group: "a1", version: 0),
            msg("u2", "user", "二", conv: "c9"), msg("u1", "user", "重复 id"), msg("orphan", "user", "没人引用"),
        ])
        XCTAssertEqual(r.conversations.map(\.id), ["c1", "c2"])
        XCTAssertEqual(r.counts.danglingIds, 1)
        XCTAssertEqual(r.counts.duplicateReferences, 2, "c1 里 a1 第二次 + c2 里再引用 a1")
        XCTAssertEqual(r.counts.rehomedMessages, 1)
        XCTAssertEqual(r.counts.unreferencedMessages, 1)
        XCTAssertEqual(r.counts.duplicateIds, 2, "会话 c1 重复 + 消息 u1 重复")
        XCTAssertEqual(r.conversations[0].revisions.map(\.id), ["u1", "a1", "v1"])
        XCTAssertEqual(r.conversations[0].revisions.first { $0.id == "v1" }?.version, 1, "显式组里 version 撞了顺延")
        XCTAssertEqual(r.conversations[1].revisions.map(\.id), ["u2"])
        XCTAssertFalse(r.counts.notes.isEmpty)
    }

    func testLegacyAttachmentMarkers() throws {
        let content = """
        看图
        [image:/Users/x/Library/Application Support/com.psyche.kelivo/upload/a b.png]
        ```
        [image:/Users/x/upload/c.png]
        ```
        行内 [image:/u/upload/d.png] 不算
        [file:/var/mobile/Containers/Data/Application/AAA/Documents/upload/doc.pdf|报告.pdf|application/pdf]
        [image:https://example.com/e.png]
        [image:/Users/x/upload/gone.png]
        """
        let r = try legacy([conv("c1", ["u1"])], [msg("u1", "user", content)])
        let (p, stats) = try build(r.conversations[0], members: ["upload/a b.png", "upload/doc.pdf"])
        XCTAssertEqual(try segments(node(p, "u1")), [
            .text("看图"),
            .file(name: "a b.png", uuid: "kelivo-asset:upload/a b.png"),
            .text("```\n[image:/Users/x/upload/c.png]\n```\n行内 [image:/u/upload/d.png] 不算"),
            .file(name: "报告.pdf", uuid: "kelivo-asset:upload/doc.pdf"),
            .file(name: "e.png", uuid: ""),
            .file(name: "gone.png", uuid: ""),
        ])
        XCTAssertEqual(stats.packagedAttachments, 2)
        XCTAssertEqual(stats.remoteAttachments, 1)
        XCTAssertEqual(stats.missingAttachments, 1)
    }

    func testLegacyReasoningAndTools() throws {
        let segmentsJSON = #"{"v":2,"segments":[{"text":"分段一"},{"text":"分段二"}]}"#
        let r = try legacy([conv("c1", ["u1", "a1", "a2"])], [
            msg("u1", "user", "查天气"),
            msg("a1", "assistant", "晴", extra: ["reasoningText": "全文思考", "reasoningSegmentsJson": segmentsJSON]),
            msg("a2", "assistant", "好", extra: ["reasoningSegmentsJson": segmentsJSON]),
        ], tools: ["a1": [["id": "t1", "name": "weather", "arguments": ["city": "京都"], "content": "晴 25°"]]])
        let (p, _) = try build(r.conversations[0])
        XCTAssertEqual(try segments(node(p, "a1")), [
            .thinking(text: "全文思考", signature: nil),
            .text("晴"),
            .toolUse(id: "t1", name: "weather", inputJSON: #"{"city":"京都"}"#, integrationName: nil, iconName: nil),
            .toolResult(toolUseId: "t1", text: "晴 25°", isError: false, integrationName: nil),
        ], "全文和分段只取一份；工具排在正文后（同 Kelivo 1.3 迁移）")
        XCTAssertEqual(try segments(node(p, "a2")).first, .thinking(text: "分段一\n\n分段二", signature: nil))
    }

    func testLegacyNotRecognized() {
        XCTAssertThrowsError(try KelivoLegacyParser.parse(data: Data(#"[{"uuid":"x","chat_messages":[]}]"#.utf8)))
        XCTAssertThrowsError(try KelivoLegacyParser.parse(data: Data(#"{"version":2,"conversations":[],"messages":[]}"#.utf8)))
        XCTAssertTrue(KelivoBackup.isLegacyChats(["conversations": [], "messages": []]))
    }

    // MARK: - 新版样本（SQLite）

    private func makeDB(schema: Int, _ fill: (SQLiteDB) throws -> Void) throws -> URL {
        let url = work.appendingPathComponent("kelivo-\(schema)-\(UUID().uuidString).db")
        let db = try SQLiteDB(url: url)
        var conv = "id TEXT PRIMARY KEY, title TEXT, created_at INTEGER, updated_at INTEGER, is_pinned INTEGER, assistant_id TEXT, truncate_index INTEGER, version_selections_json TEXT, summary TEXT, last_summarized_message_count INTEGER, chat_suggestions_json TEXT"
        var message = "id TEXT PRIMARY KEY, conversation_id TEXT, role TEXT, timestamp INTEGER, model_id TEXT, provider_id TEXT, total_tokens INTEGER, is_streaming INTEGER, reasoning_start_at INTEGER, reasoning_finished_at INTEGER, translation TEXT, reasoning_segments_json TEXT, group_id TEXT, version INTEGER, prompt_tokens INTEGER, completion_tokens INTEGER, cached_tokens INTEGER, duration_ms INTEGER, message_order INTEGER"
        if schema >= 2 { conv += ", chat_model_provider TEXT, chat_model_id TEXT" }
        if schema >= 3 {
            conv += ", extras_json TEXT"
            message += ", updated_at INTEGER, sender_id TEXT, extras_json TEXT"
        }
        try db.exec("CREATE TABLE conversation_rows (\(conv))")
        try db.exec("CREATE TABLE message_rows (\(message))")
        try db.exec("CREATE TABLE message_part_rows (part_id INTEGER PRIMARY KEY, conversation_id TEXT, revision_id TEXT, ordinal INTEGER, kind TEXT, payload TEXT, created_at INTEGER, updated_at INTEGER)")
        try db.exec("CREATE TABLE assistant_rows (id TEXT PRIMARY KEY, payload TEXT, updated_at INTEGER, sort_order INTEGER)")
        try db.exec("CREATE TABLE provider_rows (id TEXT PRIMARY KEY, payload TEXT)")
        try db.exec("PRAGMA user_version = \(schema)")
        try fill(db)
        return url
    }

    private func insert(_ db: SQLiteDB, _ table: String, _ row: [String: Any?]) throws {
        let keys = row.keys.sorted()
        let s = try db.prepare("INSERT INTO \(table) (\(keys.joined(separator: ", "))) VALUES (\(keys.map { _ in "?" }.joined(separator: ", ")))")
        for (i, key) in keys.enumerated() {
            switch row[key] ?? nil {
            case let v as String: s.bind(Int32(i + 1), v)
            case let v as Int: s.bind(Int32(i + 1), Int64(v))
            case let v as Int64: s.bind(Int32(i + 1), v)
            default: s.bind(Int32(i + 1), nil as String?)
            }
        }
        try s.run()
    }

    private let t0: Int64 = 1_740_823_200_123_456 // 2025-03-01T10:00:00.123456Z（微秒）

    private func revision(_ db: SQLiteDB, _ id: String, _ role: String, order: Int, conv: String = "k1", group: String? = nil,
                          version: Int = 0, parts: [(String, String)]) throws {
        try insert(db, "message_rows", ["id": id, "conversation_id": conv, "role": role, "timestamp": t0 + Int64(order) * 1_000_000,
                                        "group_id": group, "version": version, "message_order": order, "is_streaming": 0,
                                        "model_id": role == "assistant" ? "claude-x" : nil, "duration_ms": role == "assistant" ? 1234 : nil])
        for (i, part) in parts.enumerated() {
            try insert(db, "message_part_rows", ["conversation_id": conv, "revision_id": id, "ordinal": i, "kind": part.0,
                                                 "payload": part.1, "created_at": t0])
        }
    }

    private func readAll(_ url: URL) throws -> ([KelivoBackup.Conversation], KelivoDatabaseReader.Summary) {
        var out: [KelivoBackup.Conversation] = []
        let summary = try KelivoDatabaseReader.read(database: url) { out.append($0) }
        return (out, summary)
    }

    // MARK: - 新版

    func testDatabaseSchema3InterleavedPartsAndSelection() throws {
        let url = try makeDB(schema: 3) { db in
            try insert(db, "assistant_rows", ["id": "as1", "payload": #"{"name":"小助手","systemPrompt":"你是猫","customHeaders":{"Authorization":"Bearer sk-secret"}}"#])
            try insert(db, "provider_rows", ["id": "p1", "payload": #"{"apiKey":"sk-secret"}"#])
            try insert(db, "conversation_rows", ["id": "k1", "title": "新对话", "created_at": t0, "updated_at": t0 + 60_000_000,
                                                 "is_pinned": 1, "assistant_id": "as1", "truncate_index": -1,
                                                 "version_selections_json": #"{"g1":0}"#, "extras_json": #"{"prompt.system":"会话级"}"#])
            try revision(db, "u1", "user", order: 0, parts: [("text", "看这张"), ("image", #"{"uri":"kelivo-file:///upload/my%20cat.png","mime":"image/png"}"#)])
            try revision(db, "a1", "assistant", order: 1, group: "g1", version: 0, parts: [
                ("reasoning", "先想"), ("tool_call", #"{"id":"t1","name":"search_web","arguments":{"q":"猫"},"content":"{\"items\":[]}"}"#),
                ("reasoning", "再想"), ("text", "是"), ("text", "猫"), ("assistant_round_end", "null"),
            ])
            try revision(db, "a1v1", "assistant", order: 3, group: "g1", version: 1, parts: [("text", "重新生成的")])
            try revision(db, "u2", "user", order: 2, parts: [("text", "谢谢")])
        }
        let (convs, summary) = try readAll(url)
        XCTAssertEqual(summary.schemaVersion, 3)
        XCTAssertEqual(convs.count, 1)
        let c = convs[0]
        XCTAssertEqual(c.createdAt?.timeIntervalSince1970 ?? 0, 1_740_823_200.123456, accuracy: 0.000_01, "微秒")
        XCTAssertEqual(c.selections, ["g1": 0])
        let assistant = try XCTUnwrap(c.metadata["assistant"] as? [String: Any])
        XCTAssertEqual(assistant["name"] as? String, "小助手")
        XCTAssertFalse(KelivoBackup.jsonString(c.metadata).contains("sk-secret"), "凭证不进元数据")

        let (p, stats) = try build(c, members: ["upload/my cat.png"])
        XCTAssertEqual(p.id, "k1@kelivo")
        // 选中 version 0（不是最大的 1），u2 挂在 a1 下；a1v1 是叶子
        XCTAssertEqual(try node(p, "a1").childrenIds, ["k1@kelivo/u2"])
        XCTAssertEqual(try node(p, "u1").childrenIds, ["k1@kelivo/a1", "k1@kelivo/a1v1"])
        XCTAssertEqual(p.currentNodeId, "k1@kelivo/u2")
        XCTAssertEqual(try segments(node(p, "u1")), [.text("看这张"), .file(name: "my cat.png", uuid: "kelivo-asset:upload/my cat.png")])
        XCTAssertEqual(try segments(node(p, "a1")), [
            .thinking(text: "先想", signature: nil),
            .toolUse(id: "t1", name: "search_web", inputJSON: #"{"q":"猫"}"#, integrationName: nil, iconName: nil),
            .toolResult(toolUseId: "t1", text: #"{"items":[]}"#, isError: false, integrationName: nil),
            .thinking(text: "再想", signature: nil),
            .text("是猫"),
        ], "part 交错顺序不变、相邻正文直接拼")
        XCTAssertEqual(stats.hiddenParts, 1)
        let a1Meta = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(node(p, "a1").sourceMetadata)) as? [String: Any])
        XCTAssertEqual(a1Meta["duration_ms"] as? Int, 1234)
        XCTAssertEqual(a1Meta["model_id"] as? String, "claude-x")
    }

    func testDatabaseSchema1AndDefaultSelection() throws {
        let url = try makeDB(schema: 1) { db in
            try insert(db, "conversation_rows", ["id": "k1", "title": "", "created_at": t0, "updated_at": t0, "version_selections_json": #"{"g1":7}"#])
            try revision(db, "u1", "user", order: 0, parts: [("text", "老库的第一句话")])
            try revision(db, "a1", "assistant", order: 1, group: "g1", version: 0, parts: [("text", "旧")])
            try revision(db, "a2", "assistant", order: 2, group: "g1", version: 1, parts: [("text", "新")])
        }
        let (convs, summary) = try readAll(url)
        XCTAssertEqual(summary.schemaVersion, 1)
        let (p, _) = try build(convs[0])
        XCTAssertEqual(p.currentNodeId, "k1@kelivo/a2", "选的版本不存在 → 最大 version")
        XCTAssertEqual(p.title, "老库的第一句话", "没标题用第一句")
    }

    func testDatabaseHiddenRolesAndAttachments() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let url = try makeDB(schema: 3) { db in
            try insert(db, "conversation_rows", ["id": "k1", "title": "t", "created_at": t0, "updated_at": t0])
            try revision(db, "u1", "user", order: 0, parts: [
                ("image", #"{"uri":"data:image/png;base64,\#(png.base64EncodedString())"}"#),
                ("image", #"{"uri":"https://x.test/a.jpg"}"#),
                ("image", #"{"uri":"kelivo-file:///upload/gone.png","unavailable":true}"#),
                ("file", #"{"uri":"kelivo-file:///upload/r.pdf","name":"报告.pdf","mime":"application/pdf"}"#),
                ("image", "不是 json"), ("mystery_kind", "x"),
            ])
            try revision(db, "t1", "tool", order: 1, parts: [("text", #"{"result":1}"#)])
            try revision(db, "a1", "assistant", order: 2, parts: [("provider_auth_error", #"{"providerId":"p"}"#)])
            try revision(db, "a2", "assistant", order: 3, parts: [("text", "好")])
        }
        let (convs, _) = try readAll(url)
        let (p, stats) = try build(convs[0], members: ["upload/r.pdf", "upload/gone.png"])
        XCTAssertEqual(try segments(node(p, "u1")), [
            .image(name: "image.png", type: "image/png", data: png),
            .file(name: "a.jpg", uuid: ""),
            .file(name: "gone.png", uuid: ""),
            .file(name: "报告.pdf", uuid: "kelivo-asset:upload/r.pdf"),
        ])
        XCTAssertEqual(stats.hiddenParts, 3)
        XCTAssertEqual(stats.remoteAttachments, 1)
        XCTAssertEqual(stats.missingAttachments, 1, "导出时就标了不可用的不当包里的")
        XCTAssertEqual(try node(p, "t1").sourceVisibility, "hidden")
        XCTAssertEqual(try node(p, "a1").sourceVisibility, "hidden", "只有隐藏内容的消息不显示")
        XCTAssertEqual(stats.unknownRoles, 1)
        XCTAssertEqual(countDisplayableNodes(p.nodes), 2)
    }

    func testDeterministicPayload() throws {
        let url = try makeDB(schema: 3) { db in
            try insert(db, "conversation_rows", ["id": "k1", "title": "t", "created_at": t0, "updated_at": t0])
            try revision(db, "a1", "assistant", order: 0, parts: [("tool_call", #"{"name":"x","arguments":{}}"#), ("text", "好")])
        }
        let a = try build(readAll(url).0[0]).0, b = try build(readAll(url).0[0]).0
        XCTAssertEqual(try a.nodes.filter { !$0.isSyntheticRoot }.map(segments),
                       try b.nodes.filter { !$0.isSyntheticRoot }.map(segments), "没 id 的工具调用也要每次一样")
        // 字节也要一样：写库引擎叠加导入按字节比 segmentsData（键序不稳会被误判成「改过」）
        for _ in 0..<20 {
            XCTAssertEqual(try build(readAll(url).0[0]).0.nodes.map(\.segmentsData), a.nodes.map(\.segmentsData))
        }
    }

    // MARK: - 清单

    private func manifest(_ extra: [String: Any] = [:], db: Data? = nil) throws -> Data {
        var m: [String: Any] = ["format": "kelivo-backup", "formatVersion": 3, "minimumReadableFormatVersion": 3, "payloadKind": "sqlite",
                                "createdAtUtc": "2026-10-10T06:00:00Z", "appVersion": "1.3.1+80", "includeChats": true, "includeFiles": true,
                                "secretsIncluded": true, "database": ["entry": "database/kelivo.db", "schemaVersion": 3, "conversationCount": 1]]
        if let db {
            let hash = SHA256.hash(data: db).map { String(format: "%02x", $0) }.joined()
            m["entries"] = ["database/kelivo.db": ["bytes": db.count, "sha256": hash], "settings.json": ["bytes": 2, "sha256": "x"]]
        }
        for (k, v) in extra { m[k] = v }
        return try JSONSerialization.data(withJSONObject: m)
    }

    func testManifestAndDatabaseVerification() throws {
        let dbURL = work.appendingPathComponent("kelivo.db")
        let bytes = Data("SQLite format 3\0 假的".utf8)
        try bytes.write(to: dbURL)
        let m = try KelivoDatabaseReader.manifest(data: manifest(db: bytes))
        XCTAssertEqual(m.formatVersion, 3)
        XCTAssertEqual(m.appVersion, "1.3.1+80")
        XCTAssertNoThrow(try KelivoDatabaseReader.verify(database: dbURL, against: m))

        try Data("SQLite format 3\0 被改过".utf8).write(to: dbURL)
        XCTAssertThrowsError(try KelivoDatabaseReader.verify(database: dbURL, against: m)) {
            XCTAssertEqual($0 as? KelivoDatabaseReader.ReadError, .databaseMismatch)
        }
        XCTAssertThrowsError(try KelivoDatabaseReader.manifest(data: manifest(["payloadKind": "settings-only"]))) {
            XCTAssertEqual($0 as? KelivoDatabaseReader.ReadError, .settingsOnly)
        }
        XCTAssertNoThrow(try KelivoDatabaseReader.manifest(data: manifest(["formatVersion": 4, "minimumReadableFormatVersion": 3])))
        XCTAssertThrowsError(try KelivoDatabaseReader.manifest(data: manifest(["formatVersion": 4, "minimumReadableFormatVersion": 4])))
        XCTAssertThrowsError(try KelivoDatabaseReader.manifest(data: Data(#"{"data_files":[]}"#.utf8)))
        // v2 老包可以没有 entries：不拦
        let v2 = try KelivoDatabaseReader.manifest(data: manifest(["formatVersion": 2]))
        XCTAssertNoThrow(try KelivoDatabaseReader.verify(database: dbURL, against: v2))
    }

    // MARK: - 小工具

    func testMemberPath() {
        XCTAssertEqual(KelivoBackup.memberPath(for: "kelivo-file:///upload/a%20b.png"), "upload/a b.png")
        XCTAssertEqual(KelivoBackup.memberPath(for: "kelivo-file:///images/sub/%E7%8C%AB.png"), "images/sub/猫.png")
        XCTAssertNil(KelivoBackup.memberPath(for: "kelivo-file:///upload/..%2Fx"))
        XCTAssertNil(KelivoBackup.memberPath(for: "kelivo-file:///upload/../x"))
        XCTAssertNil(KelivoBackup.memberPath(for: "kelivo-file:///etc/passwd"))
        XCTAssertNil(KelivoBackup.memberPath(for: "kelivo-file:///upload"))
        XCTAssertEqual(KelivoBackup.memberPath(for: "/Users/x/Library/Application Support/com.psyche.kelivo/upload/a.png"), "upload/a.png")
        XCTAssertEqual(KelivoBackup.memberPath(for: "file:///var/mobile/Containers/Data/Application/A/Documents/images/b%20c.png"), "images/b c.png")
        XCTAssertEqual(KelivoBackup.memberPath(for: #"C:\Users\x\AppData\Roaming\kelivo\upload\d.png"#), "upload/d.png")
        XCTAssertNil(KelivoBackup.memberPath(for: "https://example.com/upload/a.png"))
        XCTAssertNil(KelivoBackup.memberPath(for: "/Users/x/Desktop/a.png"))
        // 附件子目录里再出现的 images 不算根（sol #9）；认不出数据根时取第一个
        XCTAssertEqual(KelivoBackup.memberPath(for: "/Users/x/Library/Application Support/com.psyche.kelivo/upload/images/a.png"), "upload/images/a.png")
        XCTAssertEqual(KelivoBackup.memberPath(for: "/storage/x/upload/images/a.png"), "upload/images/a.png")
        XCTAssertEqual(KelivoBackup.memberPath(for: "/Users/images/Library/Containers/com.psyche.kelivo/Data/Documents/upload/a.png"), "upload/a.png")
    }

    /// 闭围栏后面带文字的不算闭（CommonMark），代码块里的标记照样是文本（sol #13）
    func testFenceCloseNeedsBareLine() {
        let parts = KelivoLegacyParser.contentParts("```swift\n```not-a-close\n[image:/Users/x/upload/c.png]\n```  \n[image:/Users/x/upload/d.png]")
        XCTAssertEqual(parts.count, 2)
        guard case .text(let code) = parts.first, case .image(let a) = parts.last else { return XCTFail("\(parts)") }
        XCTAssertTrue(code.contains("[image:/Users/x/upload/c.png]"))
        XCTAssertEqual(a.uri, "/Users/x/upload/d.png")
    }

    func testManifestIgnoresDatabaseEntryAndV3NeedsChecksum() throws {
        let m = try KelivoDatabaseReader.manifest(data: manifest(["database": ["entry": "../001/database/kelivo.db"]]))
        XCTAssertEqual(m.databaseEntry, "database/kelivo.db", "清单里的库路径不信（sol #2）")
        let dbURL = work.appendingPathComponent("kelivo.db")
        try Data("SQLite format 3\0".utf8).write(to: dbURL)
        XCTAssertThrowsError(try KelivoDatabaseReader.verify(database: dbURL, against: m), "v3 没写库的校验和 = 不完整（sol #11）") {
            XCTAssertEqual($0 as? KelivoDatabaseReader.ReadError, .databaseMismatch)
        }
    }

    func testMigrationFlagAndNewerSchema() throws {
        let url = try makeDB(schema: 3) { db in
            try db.exec("CREATE TABLE chat_storage_meta_rows (key TEXT PRIMARY KEY, value TEXT)")
            try db.exec("INSERT INTO chat_storage_meta_rows VALUES ('hive_migration_complete_v1', 'false')")
            try db.exec("PRAGMA user_version = 4")
            try insert(db, "conversation_rows", ["id": "k1", "title": "t", "created_at": t0, "updated_at": t0])
            try revision(db, "u1", "user", order: 0, parts: [("text", "在")])
        }
        let (convs, summary) = try readAll(url)
        XCTAssertEqual(convs.count, 1, "照读，不拒")
        XCTAssertTrue(summary.migrationIncomplete)
        XCTAssertTrue(summary.newerThanKnown)
    }

    func testISODates() {
        var counts = KelivoBackup.Counts()
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(KelivoBackup.date(iso: "2025-03-01T10:00:00.500Z", counts: &counts), iso.date(from: "2025-03-01T10:00:00Z")!.addingTimeInterval(0.5))
        XCTAssertEqual(KelivoBackup.date(iso: "2025-03-01T18:00:00+08:00", counts: &counts), iso.date(from: "2025-03-01T10:00:00Z"))
        XCTAssertEqual(KelivoBackup.date(iso: "2025-03-01T10:00:00.123456", timeZone: TimeZone(identifier: "UTC")!, counts: &counts)!
            .timeIntervalSince(iso.date(from: "2025-03-01T10:00:00Z")!), 0.123456, accuracy: 0.000_001)
        XCTAssertNil(KelivoBackup.date(iso: "yesterday", counts: &counts))
        XCTAssertEqual(counts.noTimezoneTimes, 1)
        XCTAssertEqual(counts.unreadableTimes, 1)
        XCTAssertEqual(KelivoBackup.date(microseconds: 1_000_000), Date(timeIntervalSince1970: 1))
    }
}
