#if os(macOS)
import Foundation

/// OpenClaw（原 Clawdbot / Moltbot）：状态目录 `~/.openclaw`（`OPENCLAW_STATE_DIR` 可改道，老装机名 `~/.clawdbot`），会话按 agent 分桶
/// 在 `agents/<agentId>/` 下，**两代存储并存、同扫**（Wake `adapters/openclaw.rs`）：
/// - 现版：`agent/openclaw-agent.sqlite`——session_windows（每个 session_id 一行，reset / rollover 后旧窗口保留）+ session_nodes
///   （按 session_key 的活跃指针与 label）+ transcript_events（session_id, seq, event_json）。event_json 就是 Pi 系 SessionManager 的
///   一行（首行 `{type:"session",cwd}` header，其余带 id / parentId 的树形条目），`session_transcript_active_events` 按
///   active_position 给出当前可见分支，缺表 / 缺行时退回「最后一条为叶」回溯。
/// - 旧版：`sessions/<sessionId>.jsonl` 同格式明文，`sessions.json` 是按 session_key 的索引（label / model / totalTokens / spawnedBy）。
/// 同一会话被 `doctor --fix` 迁进库后旧 jsonl 仍在：同 native id 双副本由扫描器按 mtime 裁决，这里不二选一。消息形状即 pi-ai，
/// 渲染核心与 Pi 共用（`CodingPiRender`）；OpenClaw 独有 thinking 块、`runtimeContextCarrier` 归 Meta、compaction / branch_summary /
/// custom_message / session_info 四种条目。spawned_by 非空 = 子代理，不列。没有续跑形制
struct OpenClawAdapter: CodingSessionAdapter {
    /// `<状态目录>/agents`
    let root: URL
    private let caches = Caches()

    init(root: URL) {
        self.root = root
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// OPENCLAW_STATE_DIR 只是候选：里面真有 agents/ 才采信；默认 ~/.openclaw，只装过老版本的机器（没有 .openclaw、有 .clawdbot）
    /// 回落旧名——与上游 resolveStateDir 判序一致
    static func make(home: URL, environment: [String: String]) -> OpenClawAdapter {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let state: URL
        if let custom = environment["OPENCLAW_STATE_DIR"], !custom.isEmpty,
           fm.fileExists(atPath: URL(fileURLWithPath: custom).appendingPathComponent("agents").path, isDirectory: &isDir), isDir.boolValue {
            state = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let fresh = home.appendingPathComponent(".openclaw", isDirectory: true)
            let legacy = home.appendingPathComponent(".clawdbot", isDirectory: true)
            state = !fm.fileExists(atPath: fresh.path) && fm.fileExists(atPath: legacy.path) ? legacy : fresh
        }
        return OpenClawAdapter(root: state.appendingPathComponent("agents", isDirectory: true))
    }

    var agent: CodingAgent { .openclaw }
    var dataRoots: [URL] { [root] }

    static let dbName = "openclaw-agent.sqlite"
    /// 转录条目的已知非内容类型：静默跳过，表外计 unknown（格式漂移金丝雀）
    private static let knownSkip: Set<String> = ["session", "thinking_level_change", "label", "custom", "reset"]

    /// 库内一条会话窗口（session_windows ⋈ session_nodes）
    struct Row: Sendable {
        var sessionId: String
        var spawnedBy: String?
        var eventCount: Int64
        var contentLength: Int64
        var hint: Hint
    }

    /// 库行 / 旧版索引给解析结果补缺的元数据
    struct Hint: Sendable {
        var label: String?
        var model: String?
        var tokens: Int64?
        var channel: String?
        var createdMs: Int64 = 0
        var updatedMs: Int64 = 0
    }

    /// 窗口行按库（含 -wal）缓存戳、旧版 sessions.json 索引按文件 mtime，各缓存一份
    private final class Caches: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [String: (stamp: Int64, rows: [Row])] = [:]
        private var indexes: [String: (stamp: Int64, index: [String: CodingParse.JSON])] = [:]

        func rows(_ key: String, _ stamp: Int64) -> [Row]? {
            lock.lock()
            defer { lock.unlock() }
            return rows[key].flatMap { $0.stamp == stamp ? $0.rows : nil }
        }

        func setRows(_ key: String, _ stamp: Int64, _ value: [Row]) {
            lock.lock()
            rows[key] = (stamp, value)
            lock.unlock()
        }

        func index(_ key: String, _ stamp: Int64) -> [String: CodingParse.JSON]? {
            lock.lock()
            defer { lock.unlock() }
            return indexes[key].flatMap { $0.stamp == stamp ? $0.index : nil }
        }

        func setIndex(_ key: String, _ stamp: Int64, _ value: [String: CodingParse.JSON]) {
            lock.lock()
            indexes[key] = (stamp, value)
            lock.unlock()
        }
    }

    /// 上游全部 ms 整数；防御性兼容秒，阈值与 epochMs 同一条线
    static func normMs(_ value: Int64) -> Int64 {
        CodingParse.epochMs(NSNumber(value: value))
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }

    // MARK: - 枚举

    /// `agents/<agentId>/` 目录（按名排序、跳过隐藏；缺根降级为空）
    private func agentDirs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
    }

    /// 旧版转录文件名：归档 / 回滚快照 / 压缩检查点都不是活会话
    static func isLegacyTranscript(_ name: String) -> Bool {
        name.hasSuffix(".jsonl") && !name.hasPrefix(".") && !name.contains(".deleted.") && !name.contains(".reset.") && !name.contains(".checkpoint.")
    }

    func listSessionFiles() -> [CodingSessionFileRef] {
        var out: [CodingSessionFileRef] = []
        for dir in agentDirs() {
            let db = dir.appendingPathComponent("agent").appendingPathComponent(Self.dbName)
            if Self.isFile(db), let rows = rows(db) {
                let base = CodingParse.canonicalPath(db.path)
                out += rows.filter { $0.spawnedBy == nil && $0.eventCount > 0 }.map {
                    CodingSessionFileRef(agent: .openclaw, nativeId: $0.sessionId, filePath: CodingVirtualPath.make(db: base, id: $0.sessionId),
                                         mtimeMs: $0.hint.updatedMs, size: $0.contentLength)
                }
            }
            let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: CodingParse.refKeys) else { continue }
            let spawned = Set(legacyIndex(sessions).filter { ($0.value["spawnedBy"] as? String).map { !$0.isEmpty } ?? false }.keys)
            for entry in entries where Self.isLegacyTranscript(entry.lastPathComponent) {
                let stem = String(entry.lastPathComponent.dropLast(6))
                // topic 转录 `<sessionId>-topic-<id>.jsonl` 跟父会话走
                let base = stem.components(separatedBy: "-topic-").first ?? stem
                if spawned.contains(stem) || spawned.contains(base) { continue }
                if let ref = CodingParse.defaultFileRef(.openclaw, entry) { out.append(ref) }
            }
        }
        return out
    }

    /// 只认 agents/<id>/sessions/<name>.jsonl 这一层；归档 / 检查点同列举过滤
    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        guard Self.isLegacyTranscript(url.lastPathComponent) else { return nil }
        let sessions = url.deletingLastPathComponent()
        guard sessions.lastPathComponent == "sessions",
              CodingParse.canonicalPath(sessions.deletingLastPathComponent().deletingLastPathComponent().path) == CodingParse.canonicalPath(root.path)
        else { return nil }
        return CodingParse.defaultFileRef(.openclaw, url)
    }

    // 不给 quickMeta：库行给不出标题的可靠来源（名字在 session_info 条目里），走全解析

    private func rows(_ db: URL) -> [Row]? {
        let stamp = CodingSQLiteReader.cacheStamp(db)
        if let cached = caches.rows(db.path, stamp) { return cached }
        guard let reader = CodingSQLiteReader.open(db, tag: "openclaw"), let rows = Self.queryRows(reader) else { return nil }
        caches.setRows(db.path, stamp, rows)
        return rows
    }

    /// 任一行读坏整份作废；读不了 = nil
    static func queryRows(_ reader: CodingSQLiteReader) -> [Row]? {
        var rows: [Row] = []
        var broken = false
        let ok = reader.query("""
            SELECT w.session_id, w.spawned_by, w.created_at, w.updated_at,
                   w.transcript_updated_at, w.started_at, w.model, w.channel, w.display_name,
                   n.label, n.display_name, n.entry_json,
                   COUNT(e.seq), COALESCE(SUM(LENGTH(e.event_json)), 0),
                   COALESCE(MAX(e.created_at), 0)
            FROM session_windows w
            LEFT JOIN session_nodes n ON n.session_key = w.session_key
            LEFT JOIN transcript_events e ON e.session_id = w.session_id
            GROUP BY w.session_id
            """) { r in
            guard let sessionId = r.text(0), let eventCount = r.int64(12), let contentLength = r.int64(13) else {
                broken = true
                return
            }
            let entry = r.text(11).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? CodingParse.JSON
            let label = r.text(9) ?? r.text(10) ?? r.text(8) ?? (entry?["label"] as? String) ?? (entry?["displayName"] as? String)
            // 只有当前活跃窗口的 entry_json 归它：老窗口的 node 指向新窗口，计数不能张冠李戴
            let isCurrent = entry?["sessionId"] as? String == sessionId
            let started = normMs(r.int64(5) ?? 0)
            rows.append(Row(
                sessionId: sessionId, spawnedBy: r.text(1).flatMap { $0.isEmpty ? nil : $0 },
                eventCount: eventCount, contentLength: contentLength,
                hint: Hint(label: label.flatMap { CodingParse.isBlank($0) ? nil : $0 },
                           model: r.text(6) ?? (entry?["model"] as? String),
                           tokens: isCurrent ? integer(entry?["totalTokens"]) : nil,
                           channel: r.text(7),
                           createdMs: started > 0 ? started : normMs(r.int64(2) ?? 0),
                           updatedMs: max(normMs(r.int64(4) ?? 0), normMs(r.int64(14) ?? 0), normMs(r.int64(3) ?? 0)))
            ))
        }
        return ok && !broken ? rows : nil
    }

    /// 旧版 `sessions.json`：按 sessionId 重建索引（原文件按 session_key 键），按文件 mtime 缓存；读不了 = 空
    private func legacyIndex(_ sessionsDir: URL) -> [String: CodingParse.JSON] {
        let file = sessionsDir.appendingPathComponent("sessions.json")
        let stamp = CodingParse.mtimeMs((try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date)
        if let cached = caches.index(file.path, stamp) { return cached }
        guard let data = try? Data(contentsOf: file), let map = (try? JSONSerialization.jsonObject(with: data)) as? CodingParse.JSON else { return [:] }
        var index: [String: CodingParse.JSON] = [:]
        for case let value as CodingParse.JSON in map.values {
            if let id = value["sessionId"] as? String { index[id] = value }
        }
        caches.setIndex(file.path, stamp, index)
        return index
    }

    private func legacyHint(_ path: URL, _ nativeId: String) -> Hint {
        let index = legacyIndex(path.deletingLastPathComponent())
        let base = nativeId.components(separatedBy: "-topic-").first ?? nativeId
        guard let v = index[nativeId] ?? index[base] else { return Hint() }
        return Hint(label: (v["label"] as? String) ?? (v["displayName"] as? String), model: v["model"] as? String,
                    tokens: Self.integer(v["totalTokens"]), channel: nil, createdMs: 0,
                    updatedMs: Self.normMs(Self.integer(v["updatedAt"]) ?? 0))
    }

    // MARK: - 解析

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let (meta, p) = try parse(ref)
        return CodingParsedSession(meta: meta, units: CodingParse.units(p.messages), unknownLines: p.unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let (meta, p) = try CodingImageBudget.decoding { try parse(ref) }
        return CodingParsedTranscript(meta: meta, mainline: p.messages, sidechains: [], unknownLines: p.unknown)
    }

    private func parse(_ ref: CodingSessionFileRef) throws -> (CodingSessionMeta, Parse) {
        let url = URL(fileURLWithPath: ref.filePath)
        if Self.isFile(url) {
            // 旧版 jsonl：整文件即条目流，叶 = 最后一条
            var entries: [CodingParse.JSON] = []
            var bad = 0
            try CodingParse.forEachLine(url) { row in
                if let row { entries.append(row) } else { bad += 1 }
            }
            var p = Self.render(Self.linearize(entries, active: nil))
            p.unknown += bad
            return (Self.meta(ref, p, legacyHint(url, ref.nativeId)), p)
        }
        let db = URL(fileURLWithPath: CodingVirtualPath.strip(ref.filePath))
        guard let row = rows(db)?.first(where: { $0.sessionId == ref.nativeId }) else {
            throw CodingSessionError.unreadable("OpenClaw 库里没有会话 \(ref.nativeId)")
        }
        guard let reader = CodingSQLiteReader.open(db, tag: "openclaw") else { throw CodingSessionError.unreadable("打不开 OpenClaw 库") }
        var entries: [(seq: Int64, entry: CodingParse.JSON)] = []
        var unknown = 0
        let ok = reader.query("SELECT seq, event_json FROM transcript_events WHERE session_id = ? ORDER BY seq", [ref.nativeId]) { r in
            if let seq = r.int64(0), let json = r.text(1),
               let entry = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? CodingParse.JSON {
                entries.append((seq, entry))
            } else {
                unknown += 1
            }
        }
        guard ok else { throw CodingSessionError.unreadable("读不了 OpenClaw 会话 \(ref.nativeId) 的转录事件") }
        // 当前可见分支（按 active_position）；表缺失 / 为空时退回树回溯
        var active: [Int64] = []
        reader.query("SELECT event_seq FROM session_transcript_active_events WHERE session_id = ? ORDER BY active_position",
                     [ref.nativeId]) { r in
            if let seq = r.int64(0) { active.append(seq) }
        }
        let bySeq = Dictionary(entries.enumerated().map { ($0.element.seq, $0.offset) }, uniquingKeysWith: { _, last in last })
        var p = Self.render(Self.linearize(entries.map(\.entry), active: active.isEmpty ? nil : active.compactMap { bySeq[$0] }))
        p.unknown += unknown
        return (Self.meta(ref, p, row.hint), p)
    }

    /// 树形条目 → 当前分支的线性序列（header 在首位）。显式分支（下标）照单；否则以最后一条带 id 的条目为叶沿 parentId 回溯到根
    /// （Pi SessionManager 的默认叶语义，旧版 jsonl 只有这一种）
    static func linearize(_ entries: [CodingParse.JSON], active: [Int]?) -> [CodingParse.JSON] {
        let headerIndex = entries.firstIndex { $0["type"] as? String == "session" }
        let chain: [Int]
        if let active {
            chain = active
        } else {
            var byId: [String: Int] = [:]
            for (i, entry) in entries.enumerated() {
                if let id = entry["id"] as? String { byId[id] = i }
            }
            var path: [Int] = []
            var seen = Set<Int>()
            var cursor = entries.lastIndex { $0["id"] is String }
            while let i = cursor, seen.insert(i).inserted {
                path.append(i)
                cursor = (entries[i]["parentId"] as? String).flatMap { byId[$0] }
            }
            chain = path.reversed()
        }
        var out: [CodingParse.JSON] = []
        if let headerIndex { out.append(entries[headerIndex]) }
        for i in chain where i != headerIndex { out.append(entries[i]) }
        return out
    }

    struct Parse {
        var cwd = ""
        var createdAt: Int64 = 0
        var lastTs: Int64 = 0
        var messages: [CodingMessage] = []
        var model: String?
        var tokensUsed: Int64?
        /// session_info 的 name（用户 / 自动命名），标题首选
        var name: String?
        var unknown = 0
    }

    private static func entryTs(_ entry: CodingParse.JSON, _ message: CodingParse.JSON?) -> Int64 {
        if let text = entry["timestamp"] as? String {
            let ts = CodingParse.isoMs(text)
            if ts > 0 { return ts }
        }
        return CodingParse.epochMs(message?["timestamp"])
    }

    /// 非 message 条目（compaction 摘要等）要按位置插在消息流里，交给渲染器统一持有消息
    static func render(_ chain: [CodingParse.JSON]) -> Parse {
        var p = Parse()
        var render = CodingPiRender(.init(thinkingBlocks: true, metaCarrier: true, rawToolResults: true))
        for entry in chain {
            guard let type = entry["type"] as? String else {
                p.unknown += 1
                continue
            }
            switch type {
            case "session":
                if let cwd = entry["cwd"] as? String { p.cwd = cwd }
                if let text = entry["timestamp"] as? String { p.createdAt = CodingParse.isoMs(text) }
            case "message":
                guard let message = entry["message"] as? CodingParse.JSON else {
                    p.unknown += 1
                    continue
                }
                let ts = entryTs(entry, message)
                p.lastTs = max(p.lastTs, ts)
                if !render.push(message, ts: ts) { p.unknown += 1 }
            case "model_change":
                if let model = entry["modelId"] as? String { render.model = model }
            case "compaction", "branch_summary":
                let ts = entryTs(entry, nil)
                p.lastTs = max(p.lastTs, ts)
                if let summary = entry["summary"] as? String, !CodingParse.isBlank(summary) {
                    var message = CodingParse.textMessage(.system, summary, ts: ts)
                    message.kind = .compactSummary
                    render.append(message)
                }
            case "custom_message":
                // 扩展注入进上下文的消息：display=true 才是给人看的，折叠为 Meta；图片不解码（占位）
                if CodingParse.bool(entry["display"]) {
                    let parsed = CodingImageBudget.$current.withValue(nil) { CodingParse.contentParts(entry["content"]) }
                    if !parsed.text.isEmpty {
                        var message = CodingParse.textMessage(.system, parsed.text, ts: entryTs(entry, nil))
                        message.kind = .meta
                        render.append(message)
                    }
                }
            case "session_info":
                if let name = entry["name"] as? String {
                    let trimmed = CodingParse.trimmed(name)
                    p.name = trimmed.isEmpty ? nil : trimmed
                }
            default:
                if !knownSkip.contains(type) { p.unknown += 1 }
            }
        }
        p.messages = render.messages
        p.model = render.model
        p.tokensUsed = render.tokensUsed
        CodingParse.assignSeq(&p.messages)
        return p
    }

    private static func meta(_ ref: CodingSessionFileRef, _ p: Parse, _ hint: Hint) -> CodingSessionMeta {
        let named = (p.name ?? hint.label).map(CodingParse.cleanTitleCandidate).flatMap { $0.isEmpty ? nil : $0 }
        return CodingSessionMeta(
            key: "openclaw:\(ref.nativeId)", nativeId: ref.nativeId, agent: .openclaw,
            title: named ?? CodingParse.titleFromMessages(p.messages) ?? CodingLimits.untitled,
            projectPath: p.cwd, projectName: CodingParse.projectName(p.cwd), filePath: ref.filePath,
            createdAt: [p.createdAt, hint.createdMs, ref.mtimeMs].first { $0 > 0 } ?? 0,
            updatedAt: [p.lastTs, hint.updatedMs, ref.mtimeMs].first { $0 > 0 } ?? 0,
            messageCount: p.messages.filter { $0.kind == .text }.count, sizeBytes: ref.size, gitBranch: nil,
            model: (p.model ?? hint.model).flatMap { $0.isEmpty ? nil : $0 },
            tokensUsed: (p.tokensUsed ?? hint.tokens).flatMap { $0 > 0 ? $0 : nil }, archived: false,
            // 频道即启动面（telegram / discord / webchat …）；cli / 空不打徽章
            source: hint.channel.flatMap { $0.isEmpty || $0 == "cli" ? nil : $0 }
        )
    }
}
extension OpenClawAdapter {
    /// 选中状态目录（~/.openclaw）或 agents 目录本身都认；目录还不存在时按名字判：叫 agents 即是根，否则当状态目录
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let agents = dir.appendingPathComponent("agents", isDirectory: true)
        let isAgents = dir.lastPathComponent == "agents" || (!CodingLocations.isDirectory(agents) && Self.looksLikeAgents(dir))
        return OpenClawAdapter(root: isAgents ? dir : agents)
    }

    /// 目录里已经有 `<x>/sessions` 或 `<x>/agent/openclaw-agent.sqlite` 形态的子目录 → 它本身就是 agents 根（改名拷出来的情形）
    static func looksLikeAgents(_ dir: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).contains {
            CodingLocations.isDirectory($0.appendingPathComponent("sessions"))
                || CodingLocations.isFile($0.appendingPathComponent("agent").appendingPathComponent(dbName))
        }
    }
}
#endif
