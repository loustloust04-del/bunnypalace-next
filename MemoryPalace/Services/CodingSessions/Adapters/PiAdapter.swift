#if os(macOS)
import Foundation

/// Pi / Oh My Pi（omp 是 pi 的 fork，会话格式同构、只有数据根不同，Wake `adapters/pi.rs`）：
/// `~/.pi/agent/sessions/<有损编码目录>/<timestamp>_<uuid>.jsonl`。首行 `{type:session,id,timestamp,cwd}`——cwd 直接在首行，
/// 不反推目录名；`{type:message,message:{…}}` 交 `CodingPiRender`；model_change / thinking_level_change 静默跳过，其余计 unknown
struct PiAdapter: CodingSessionAdapter {
    let agent: CodingAgent
    let root: URL

    init(agent: CodingAgent, root: URL) {
        self.agent = agent
        self.root = root
    }

    /// 默认根：pi → `~/.pi/agent/sessions`，omp → `~/.omp/agent/sessions`
    static func make(home: URL, agent: CodingAgent) -> PiAdapter {
        PiAdapter(agent: agent, root: home.appendingPathComponent(agent == .omp ? ".omp" : ".pi", isDirectory: true)
            .appendingPathComponent("agent/sessions", isDirectory: true))
    }

    var dataRoots: [URL] { [root] }

    /// 文件名 stem `<timestamp>_<uuid>` → uuid；无 `_` 时整个 stem 兜底
    static func nativeId(_ stem: String) -> String {
        stem.split(separator: "_", omittingEmptySubsequences: false).last.map(String.init) ?? stem
    }

    func listSessionFiles() -> [CodingSessionFileRef] {
        CodingParse.listJSONLRefs(root, agent, nativeId: Self.nativeId)
    }

    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        guard var ref = CodingParse.defaultFileRef(agent, url) else { return nil }
        ref.nativeId = Self.nativeId(ref.nativeId)
        return ref
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let parsed = try Self.parse(URL(fileURLWithPath: ref.filePath))
        return CodingParsedSession(meta: meta(ref, parsed), units: CodingParse.units(parsed.messages), unknownLines: parsed.unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let parsed = try CodingImageBudget.decoding { try Self.parse(URL(fileURLWithPath: ref.filePath)) }
        return CodingParsedTranscript(meta: meta(ref, parsed), mainline: parsed.messages, sidechains: [], unknownLines: parsed.unknown)
    }

    struct Parse {
        var sessionId: String?
        var cwd = ""
        var createdAt: Int64 = 0
        /// 最后一行消息的时间（合并后的消息保留回合首行时间，updated 单独追踪）
        var lastTs: Int64 = 0
        var messages: [CodingMessage] = []
        var model: String?
        var tokensUsed: Int64?
        var unknown = 0
    }

    static func parse(_ url: URL) throws -> Parse {
        var p = Parse()
        var render = CodingPiRender()
        try CodingParse.forEachLine(url) { row in
            guard let row else {
                p.unknown += 1
                return
            }
            switch row["type"] as? String {
            case "session":
                if let id = row["id"] as? String { p.sessionId = id }
                if let cwd = row["cwd"] as? String { p.cwd = cwd }
                if let ts = row["timestamp"] as? String { p.createdAt = CodingParse.isoMs(ts) }
            case "message":
                guard let message = row["message"] as? CodingParse.JSON else {
                    p.unknown += 1
                    return
                }
                let ts = (row["timestamp"] as? String).map(CodingParse.isoMs) ?? 0
                p.lastTs = max(p.lastTs, ts)
                if !render.push(message, ts: ts) { p.unknown += 1 }
            case "model_change", "thinking_level_change":
                break
            default:
                p.unknown += 1
            }
        }
        p.messages = render.messages
        p.model = render.model
        p.tokensUsed = render.tokensUsed
        CodingParse.assignSeq(&p.messages)
        return p
    }

    private func meta(_ ref: CodingSessionFileRef, _ p: Parse) -> CodingSessionMeta {
        let native = p.sessionId ?? ref.nativeId
        return CodingSessionMeta(
            key: "\(agent.rawValue):\(native)", nativeId: native, agent: agent,
            title: CodingParse.titleFromMessages(p.messages) ?? CodingLimits.untitled,
            projectPath: p.cwd, projectName: CodingParse.projectName(p.cwd), filePath: ref.filePath,
            createdAt: p.createdAt > 0 ? p.createdAt : ref.mtimeMs, updatedAt: p.lastTs > 0 ? p.lastTs : ref.mtimeMs,
            messageCount: p.messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: nil, model: p.model, tokensUsed: p.tokensUsed, archived: false, source: nil
        )
    }
}
extension PiAdapter {
    /// `~/.pi` / `~/.omp` 家目录形态或 sessions 目录本身都认；实例保持自己的家（两家布局全同，装的是哪个她自己知道）
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let nested = dir.appendingPathComponent("agent/sessions", isDirectory: true)
        return PiAdapter(agent: agent, root: CodingLocations.isDirectory(nested) ? nested : dir)
    }
}
#endif
