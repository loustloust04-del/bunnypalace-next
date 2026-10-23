#if os(macOS)
import Foundation

/// Kimi Code：`~/.kimi-code/sessions/wd_<名>_<hash>/session_<uuid>/agents/main/wire.jsonl`（Wake `adapters/kimi.rs`）。
/// 事件溯源：turn.prompt 是用户输入，context.append_message 是落入上下文的消息；
/// `state.json` 边车给标题 / 时间（"New Session" 是占位）；cwd 靠根级 `session_index.jsonl` 反查。
struct KimiCodeAdapter: CodingSessionAdapter {
    let root: URL
    let indexPath: URL

    init(home: URL) {
        root = home.appendingPathComponent("sessions", isDirectory: true)
        indexPath = home.appendingPathComponent("session_index.jsonl")
    }

    init(root: URL, indexPath: URL) {
        self.root = root
        self.indexPath = indexPath
    }

    var agent: CodingAgent { .kimi }
    var dataRoots: [URL] { [root] }

    func listSessionFiles() -> [CodingSessionFileRef] {
        let fm = FileManager.default
        guard let workDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var refs: [CodingSessionFileRef] = []
        for workDir in workDirs {
            guard let sessions = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) else { continue }
            for session in sessions {
                let wire = session.appendingPathComponent("agents/main/wire.jsonl")
                if let ref = fileRef(wire) { refs.append(ref) }
            }
        }
        return refs
    }

    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        guard url.path.hasSuffix("/agents/main/wire.jsonl"), let native = Self.sessionDir(url)?.lastPathComponent,
              var ref = CodingParse.defaultFileRef(.kimi, url) else { return nil }
        ref.nativeId = native
        return ref
    }

    func sessionPaths(_ meta: CodingSessionMeta) -> [String] {
        Self.sessionDir(URL(fileURLWithPath: meta.filePath)).map { [$0.path] } ?? [meta.filePath]
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let url = URL(fileURLWithPath: ref.filePath)
        let (messages, unknown) = try Self.parseWire(url)
        let meta = buildMeta(ref, Self.readState(url), messages)
        return CodingParsedSession(meta: meta, units: CodingParse.units(messages), unknownLines: unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let url = URL(fileURLWithPath: ref.filePath)
        let (messages, unknown) = try CodingImageBudget.decoding { try Self.parseWire(url) }
        return CodingParsedTranscript(meta: buildMeta(ref, Self.readState(url), messages), mainline: messages,
                                      sidechains: [], unknownLines: unknown)
    }

    // MARK: -

    /// `…/session_<uuid>/agents/main/wire.jsonl` → 会话目录（上三级 + session_ 前缀）
    private static func sessionDir(_ wire: URL) -> URL? {
        let dir = wire.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return dir.lastPathComponent.hasPrefix("session_") ? dir : nil
    }

    private struct State {
        var title = ""
        var created: Int64 = 0
        var updated: Int64 = 0
    }

    private static func readState(_ wire: URL) -> State {
        var state = State()
        guard let dir = sessionDir(wire),
              let data = try? Data(contentsOf: dir.appendingPathComponent("state.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? CodingParse.JSON else { return state }
        if let title = json["title"] as? String, title != "New Session" { state.title = title }
        if let t = json["createdAt"] as? String { state.created = CodingParse.isoMs(t) }
        if let t = json["updatedAt"] as? String { state.updated = CodingParse.isoMs(t) }
        return state
    }

    private func cwd(for nativeId: String) -> String {
        workDirs.map(for: indexPath)[nativeId] ?? ""
    }

    private let workDirs = WorkDirCache()

    /// session_index.jsonl 的 sessionId → workDir，按文件 mtime 失效（N0-4：别每个会话读一遍整个文件）
    private final class WorkDirCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stamp: Date?
        private var cached: [String: String] = [:]

        func map(for url: URL) -> [String: String] {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            lock.lock()
            defer { lock.unlock() }
            if let stamp, stamp == mtime { return cached }
            var out: [String: String] = [:]
            if let data = try? Data(contentsOf: url), let raw = String(data: data, encoding: .utf8) {
                for line in raw.split(separator: "\n") {
                    guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? CodingParse.JSON,
                          let id = json["sessionId"] as? String, let workDir = json["workDir"] as? String else { continue }
                    out[id] = workDir
                }
            }
            cached = out
            stamp = mtime
            return out
        }
    }

    private static func parseWire(_ url: URL) throws -> ([CodingMessage], Int) {
        var messages: [CodingMessage] = []
        var unknown = 0
        try CodingParse.forEachLine(url) { row in
            guard let row else {
                unknown += 1
                return
            }
            let type = row["type"] as? String
            switch type {
            case "turn.prompt", "turn.steer":
                let parsed = CodingParse.contentParts(row["input"])
                if !parsed.text.isEmpty || parsed.imageCount > 0 {
                    var message = CodingParse.textMessage(.user, parsed.text, ts: 0)
                    message.imageCount = parsed.imageCount
                    message.images = parsed.images
                    messages.append(message)
                }
            case "context.append_message":
                guard let message = row["message"] as? CodingParse.JSON else {
                    unknown += 1
                    return
                }
                guard message["role"] as? String == "assistant" else { return }
                let parsed = CodingParse.contentParts(message["content"])
                if !parsed.text.isEmpty || parsed.imageCount > 0 {
                    var out = CodingParse.textMessage(.assistant, parsed.text, ts: 0)
                    out.imageCount = parsed.imageCount
                    out.images = parsed.images
                    messages.append(out)
                }
            case "metadata", "config.update", "tools.set_active_tools", "context.append_loop_event":
                break
            case let t? where t.hasPrefix("turn."):
                break
            default:
                unknown += 1
            }
        }
        CodingParse.assignSeq(&messages)
        return (messages, unknown)
    }

    private func buildMeta(_ ref: CodingSessionFileRef, _ state: State, _ messages: [CodingMessage]) -> CodingSessionMeta {
        let cleaned = CodingParse.cleanTitleCandidate(state.title)
        let title = !cleaned.isEmpty ? cleaned : (CodingParse.titleFromMessages(messages) ?? CodingLimits.untitled)
        let cwd = cwd(for: ref.nativeId)
        return CodingSessionMeta(
            key: "kimi:\(ref.nativeId)", nativeId: ref.nativeId, agent: .kimi, title: title,
            projectPath: cwd, projectName: CodingParse.projectName(cwd), filePath: ref.filePath,
            createdAt: state.created > 0 ? state.created : ref.mtimeMs, updatedAt: state.updated > 0 ? state.updated : ref.mtimeMs,
            messageCount: messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil
        )
    }
}
extension KimiCodeAdapter {
    /// `~/.kimi-code` 形态（含 sessions/）则 index 在它顶层；直接选中 sessions 则去上一层找——index 相对 dir 派生
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        if CodingLocations.isDirectory(sessions) {
            return KimiCodeAdapter(root: sessions, indexPath: dir.appendingPathComponent("session_index.jsonl"))
        }
        return KimiCodeAdapter(root: dir, indexPath: dir.deletingLastPathComponent().appendingPathComponent("session_index.jsonl"))
    }
}
#endif
