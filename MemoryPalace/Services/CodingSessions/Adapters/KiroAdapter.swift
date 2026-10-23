#if os(macOS)
import Foundation

/// Kiro CLI：`~/.kiro/sessions/cli/<uuid>.{jsonl,json,history}` 三件套（Wake `adapters/kiro.rs`）。
/// `.json` 边车给 cwd / 标题 / 时间 / 模型；`.jsonl` 行 `{kind:Prompt|AssistantMessage, data:{content:[{kind:text,data}],
/// meta:{timestamp: unix 秒}}}`；`.history` 忽略（只枚举 .jsonl）
struct KiroAdapter: CodingSessionAdapter {
    let root: URL

    init(home: URL) {
        root = home.appendingPathComponent(".kiro/sessions/cli", isDirectory: true)
    }

    init(root: URL) {
        self.root = root
    }

    var agent: CodingAgent { .kiro }
    var dataRoots: [URL] { [root] }

    func listSessionFiles() -> [CodingSessionFileRef] {
        CodingParse.listJSONLRefs(root, .kiro, nativeId: { $0 })
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let (messages, unknown) = try Self.parseLines(URL(fileURLWithPath: ref.filePath))
        return CodingParsedSession(meta: meta(ref, messages), units: CodingParse.units(messages), unknownLines: unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let (messages, unknown) = try CodingImageBudget.decoding { try Self.parseLines(URL(fileURLWithPath: ref.filePath)) }
        return CodingParsedTranscript(meta: meta(ref, messages), mainline: messages, sidechains: [], unknownLines: unknown)
    }

    static func parseLines(_ url: URL) throws -> ([CodingMessage], Int) {
        var messages: [CodingMessage] = []
        var unknown = 0
        try CodingParse.forEachLine(url) { row in
            guard let row else {
                unknown += 1
                return
            }
            let role: CodingRole
            switch row["kind"] as? String {
            case "Prompt": role = .user
            case "AssistantMessage": role = .assistant
            default:
                unknown += 1
                return
            }
            guard let data = row["data"] as? CodingParse.JSON else {
                unknown += 1
                return
            }
            let parsed = CodingParse.contentParts(data["content"])
            if parsed.text.isEmpty && parsed.images.isEmpty { return }
            let seconds = CodingParse.int64((data["meta"] as? CodingParse.JSON)?["timestamp"])
            var message = CodingParse.textMessage(role, parsed.text, ts: seconds * 1000)
            message.images = parsed.images
            message.imageCount = parsed.imageCount
            messages.append(message)
        }
        CodingParse.assignSeq(&messages)
        return (messages, unknown)
    }

    struct Sidecar {
        var cwd = ""
        var title = ""
        var createdAt: Int64 = 0
        var updatedAt: Int64 = 0
        var model: String?
    }

    static func sidecar(_ jsonl: URL) -> Sidecar {
        var side = Sidecar()
        guard let data = try? Data(contentsOf: jsonl.deletingPathExtension().appendingPathExtension("json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? CodingParse.JSON else { return side }
        side.cwd = json["cwd"] as? String ?? ""
        side.title = json["title"] as? String ?? ""
        side.createdAt = (json["created_at"] as? String).map(CodingParse.isoMs) ?? 0
        side.updatedAt = (json["updated_at"] as? String).map(CodingParse.isoMs) ?? 0
        let info = ((json["session_state"] as? CodingParse.JSON)?["rts_model_state"] as? CodingParse.JSON)?["model_info"] as? CodingParse.JSON
        side.model = [info?["model_id"], info?["model_name"]].compactMap { $0 as? String }.first { !$0.isEmpty }
        return side
    }

    private func meta(_ ref: CodingSessionFileRef, _ messages: [CodingMessage]) -> CodingSessionMeta {
        let side = Self.sidecar(URL(fileURLWithPath: ref.filePath))
        let cleaned = CodingParse.cleanTitleCandidate(side.title)
        let newestMessage = messages.compactMap(\.timestamp).max() ?? 0
        let updated = max(side.updatedAt, newestMessage)
        return CodingSessionMeta(
            key: "kiro:\(ref.nativeId)", nativeId: ref.nativeId, agent: .kiro,
            title: !cleaned.isEmpty ? cleaned : (CodingParse.titleFromMessages(messages) ?? CodingLimits.untitled),
            projectPath: side.cwd, projectName: CodingParse.projectName(side.cwd), filePath: ref.filePath,
            createdAt: side.createdAt > 0 ? side.createdAt : ref.mtimeMs, updatedAt: updated > 0 ? updated : ref.mtimeMs,
            messageCount: messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: nil, model: side.model, tokensUsed: nil, archived: false, source: nil
        )
    }
}
extension KiroAdapter {
    /// `~/.kiro` / `~/.kiro/sessions` / `~/.kiro/sessions/cli` 三层都认
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let deep = dir.appendingPathComponent("sessions/cli", isDirectory: true)
        let cli = dir.appendingPathComponent("cli", isDirectory: true)
        return KiroAdapter(root: CodingLocations.isDirectory(deep) ? deep : (CodingLocations.isDirectory(cli) ? cli : dir))
    }
}
#endif
