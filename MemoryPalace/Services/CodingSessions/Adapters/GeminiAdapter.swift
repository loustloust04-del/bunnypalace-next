#if os(macOS)
import Foundation

/// Gemini CLI：`~/.gemini/tmp/<slug>/chats/session-*.jsonl`（Wake `adapters/gemini.rs`）。首行 header（sessionId / startTime /
/// lastUpdated），之后 `{$set:{messages:[…]}}` **覆盖式**快照——重放到最后一条为准，不能按行追加；
/// cwd 靠 `~/.gemini/projects.json` 的 路径→slug 映射反查；无原生标题；meta 的 id 取 header 的 sessionId（不是文件名）
struct GeminiAdapter: CodingSessionAdapter {
    let root: URL
    let projectsJSON: URL

    init(home: URL) {
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        root = gemini.appendingPathComponent("tmp", isDirectory: true)
        projectsJSON = gemini.appendingPathComponent("projects.json")
    }

    init(root: URL, projectsJSON: URL) {
        self.root = root
        self.projectsJSON = projectsJSON
    }

    var agent: CodingAgent { .gemini }
    var dataRoots: [URL] { [root] }

    func listSessionFiles() -> [CodingSessionFileRef] {
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var refs: [CodingSessionFileRef] = []
        for slug in slugs {
            let chats = slug.appendingPathComponent("chats", isDirectory: true)
            for file in (try? fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: CodingParse.refKeys)) ?? [] {
                if let ref = fileRef(file) { refs.append(ref) }
            }
        }
        return refs
    }

    /// 只认 chats/session-*.jsonl（tmp 下其他 jsonl 不是会话）
    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        guard url.lastPathComponent.hasPrefix("session-"), url.path.contains("/chats/") else { return nil }
        return CodingParse.defaultFileRef(.gemini, url)
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
        var messages: [CodingMessage] = []
        var createdAt: Int64 = 0
        var updatedAt: Int64 = 0
        var unknown = 0
    }

    static func parse(_ url: URL) throws -> Parse {
        var p = Parse()
        var lastSet: CodingParse.JSON?
        try CodingParse.forEachLine(url) { row in
            guard let row else {
                p.unknown += 1
                return
            }
            if let set = row["$set"] as? CodingParse.JSON {
                if set["messages"] is [Any] { lastSet = set }
                return
            }
            if let id = row["sessionId"] as? String {
                p.sessionId = id
                if let t = row["startTime"] as? String { p.createdAt = CodingParse.isoMs(t) }
                if let t = row["lastUpdated"] as? String { p.updatedAt = CodingParse.isoMs(t) }
                return
            }
            p.unknown += 1
        }
        for case let item as CodingParse.JSON in (lastSet?["messages"] as? [Any]) ?? [] {
            let role: CodingRole
            switch item["type"] as? String {
            case "user": role = .user
            case .some: role = .assistant
            case .none:
                p.unknown += 1
                continue
            }
            let parsed = CodingParse.contentParts(item["content"])
            if parsed.text.isEmpty && parsed.images.isEmpty { continue }
            let ts = (item["timestamp"] as? String).map(CodingParse.isoMs) ?? 0
            if ts > 0 {
                if p.createdAt == 0 { p.createdAt = ts }
                p.updatedAt = max(p.updatedAt, ts)
            }
            var message = CodingParse.textMessage(role, parsed.text, ts: ts)
            message.images = parsed.images
            message.imageCount = parsed.imageCount
            p.messages.append(message)
        }
        CodingParse.assignSeq(&p.messages)
        return p
    }

    /// …/tmp/<slug>/chats/session-*.jsonl → slug → projects.json 反查的项目路径
    private func cwd(for ref: CodingSessionFileRef) -> String {
        let slug = URL(fileURLWithPath: ref.filePath).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        guard let data = try? Data(contentsOf: projectsJSON),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? CodingParse.JSON,
              let projects = json["projects"] as? [String: Any] else { return "" }
        return projects.first { ($0.value as? String) == slug }?.key ?? ""
    }

    private func meta(_ ref: CodingSessionFileRef, _ p: Parse) -> CodingSessionMeta {
        let native = p.sessionId ?? ref.nativeId
        let cwd = cwd(for: ref)
        return CodingSessionMeta(
            key: "gemini:\(native)", nativeId: native, agent: .gemini,
            title: CodingParse.titleFromMessages(p.messages) ?? CodingLimits.untitled,
            projectPath: cwd, projectName: CodingParse.projectName(cwd), filePath: ref.filePath,
            createdAt: p.createdAt > 0 ? p.createdAt : ref.mtimeMs, updatedAt: p.updatedAt > 0 ? p.updatedAt : ref.mtimeMs,
            messageCount: p.messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: nil, model: nil, tokensUsed: nil, archived: false, source: nil
        )
    }
}
extension GeminiAdapter {
    /// `~/.gemini` 形态（含 tmp/）则 projects.json 在它顶层；直接选中 tmp 形态则去上一层找——侧档必须相对 dir 派生，落回默认家会拿错
    /// cwd 映射
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let tmp = dir.appendingPathComponent("tmp", isDirectory: true)
        if CodingLocations.isDirectory(tmp) { return GeminiAdapter(root: tmp, projectsJSON: dir.appendingPathComponent("projects.json")) }
        return GeminiAdapter(root: dir, projectsJSON: dir.deletingLastPathComponent().appendingPathComponent("projects.json"))
    }
}
#endif
