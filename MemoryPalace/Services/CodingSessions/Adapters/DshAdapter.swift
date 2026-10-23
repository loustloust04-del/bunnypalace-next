#if os(macOS)
import Foundation

/// DeepSeek Harness（dsh）：`~/.dsh/sessions/--<cwd 转义>--/<id 转义>/session.jsonl[.zstd]`，一目录一会话、文件名固定（Wake
/// `adapters/dsh.rs`）。默认落盘是 zstd **多帧连接**（首帧 header 行，之后每次 append 一帧），`compression: none` 配置则是纯文本，
/// 两种后缀都认。首行 `{type:"session",id,createdAt,cwd,…}` 给权威 id / cwd / created，不反推目录名；origin == "subagent" 或
/// delegationDepth > 0 是子代理会话，不进列表。事件行 `{type,seq,time,data}`：assistant/message 是流式 chunk 的最终合成体（chunk 与其
/// 打包行 *-chunks 直接跳过），tool/result 按 toolCallId 回填，session/title 事件 last-wins 给标题，model 在 assistant 消息的 source 里
struct DshAdapter: CodingSessionAdapter {
    let root: URL

    init(home: URL) {
        root = home.appendingPathComponent(".dsh/sessions", isDirectory: true)
    }

    init(root: URL) {
        self.root = root
    }

    var agent: CodingAgent { .dsh }
    var dataRoots: [URL] { [root] }

    struct Header {
        var id: String
        var cwd: String
        var createdAt: Int64
        var subagent: Bool
    }

    /// dsh 当前版本除内容事件外的完整事件词汇（源码 known-event-types.ts，2026-08）+ 三种 chunk 打包存储行；上游新增词汇计 unknown 提醒跟进
    private static let knownSkip: Set<String> = [
        "agent-preset/selected", "agent/inbox/spliced", "approval/asked", "approval/decided", "approval/policy", "assistant/chunk",
        "command/done", "command/run", "compaction/end", "compaction/prune", "compaction/start", "compaction/summary",
        "feedback/record", "goal/change", "hook/invoked", "hook/result", "llm/retry", "llm/retry-started", "permission/preset",
        "plan/mode", "request/header", "sandbox/mode", "schedule/change", "session/end-seed", "session/title-llm-request",
        "step/end", "step/start", "subagent/descriptor", "team/member", "team/message/delivered", "team/message/queued",
        "team/task", "todo/write", "tool-workflow/agent-end", "tool-workflow/agent-start", "tool-workflow/run-end",
        "tool-workflow/run-start", "tool/call", "tool/code-dispatch", "tool/code-dispatch-start", "turn/end", "turn/start",
        "web/deepseek-search-llm-request", "text-chunks", "reasoning-chunks", "tool-call-chunks",
    ]

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }

    static func header(_ row: CodingParse.JSON) -> Header? {
        guard row["type"] as? String == "session", let id = row["id"] as? String else { return nil }
        return Header(id: id, cwd: row["cwd"] as? String ?? "", createdAt: integer(row["createdAt"]) ?? 0,
                      subagent: row["origin"] as? String == "subagent" || (integer(row["delegationDepth"]) ?? 0) > 0)
    }

    // MARK: - 读日志

    /// 整份日志的明文字节；.zstd 透明解压（torn = 末帧半写 / 坏数据，已解出的部分照常给）
    static func load(_ url: URL, firstLineOnly: Bool = false) throws -> (data: Data, torn: Bool) {
        if url.pathExtension == "zstd" {
            guard let compressed = try? Data(contentsOf: url, options: .alwaysMapped) else {
                throw CodingSessionError.unreadable(url.lastPathComponent)
            }
            return CodingZstd.decompress(compressed, stopAtFirstLine: firstLineOnly)
        }
        guard firstLineOnly else {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { throw CodingSessionError.unreadable(url.lastPathComponent) }
            return (data, false)
        }
        // 只要首行：分块读到第一个换行，免得每次列举都读整个日志
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw CodingSessionError.unreadable(url.lastPathComponent) }
        defer { try? handle.close() }
        var data = Data()
        while let block = try? handle.read(upToCount: 8 << 10), !block.isEmpty {
            data.append(block)
            if block.contains(0x0A) || data.count > 1 << 20 { break }
        }
        return (data, false)
    }

    /// 只读首行拿 header（zstd 只解到首行；不是会话日志 = nil）
    static func readHeader(_ url: URL) -> Header? {
        guard let (data, torn) = try? load(url, firstLineOnly: true) else { return nil }
        let line: Data
        if let newline = data.firstIndex(of: 0x0A) {
            line = data[data.startIndex..<newline]
        } else if !torn {
            line = data
        } else {
            return nil
        }
        return ((try? JSONSerialization.jsonObject(with: line)) as? CodingParse.JSON).flatMap(header)
    }

    // MARK: - 枚举

    private static func fileInfo(_ url: URL) -> (isFile: Bool, size: Int64, mtimeMs: Int64)? {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
        return (values.isRegularFile == true, Int64(values.fileSize ?? 0), CodingParse.mtimeMs(values.contentModificationDate))
    }

    private static func directories(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// 固定两层 <project>/<session>/session.jsonl[.zstd]，不全递归（会话目录还会放别的产物）；两个候选名都过 fileRef，后缀并存时至多一个通过
    func listSessionFiles() -> [CodingSessionFileRef] {
        var refs: [CodingSessionFileRef] = []
        for project in Self.directories(root) {
            for session in Self.directories(project) {
                for name in ["session.jsonl.zstd", "session.jsonl"] {
                    if let ref = fileRef(session.appendingPathComponent(name)) {
                        refs.append(ref)
                        break
                    }
                }
            }
        }
        return refs
    }

    func fileRef(_ url: URL) -> CodingSessionFileRef? {
        let name = url.lastPathComponent
        guard name == "session.jsonl" || name == "session.jsonl.zstd", let own = Self.fileInfo(url), own.isFile, own.size > 0 else { return nil }
        // 压缩配置换挡会新旧后缀并存：陈旧的一份让位（mtime 平局 .zstd 赢，与写端当前默认一致）。裁决在这一处，列举与监听两条入口
        // 共用——只做在列举里，监听会把陈旧副本的事件当主文件解析
        let sibling = url.deletingLastPathComponent().appendingPathComponent(name == "session.jsonl" ? "session.jsonl.zstd" : "session.jsonl")
        if let other = Self.fileInfo(sibling), other.mtimeMs > own.mtimeMs || (other.mtimeMs == own.mtimeMs && name == "session.jsonl") {
            return nil
        }
        // 首行 header 给权威 id（目录名是转义过的 id）；子代理会话在这里滤掉
        guard let header = Self.readHeader(url), !header.subagent else { return nil }
        return CodingSessionFileRef(agent: .dsh, nativeId: header.id, filePath: CodingParse.canonicalPath(url.path),
                                    mtimeMs: own.mtimeMs, size: own.size)
    }

    /// 一目录一会话：删除时整个会话目录进废纸篓（日志与以后的产物一起）
    func sessionPaths(_ meta: CodingSessionMeta) -> [String] {
        [URL(fileURLWithPath: meta.filePath).deletingLastPathComponent().path]
    }

    // MARK: - 解析

    struct Parse {
        var header: Header?
        var title: String?
        var lastTs: Int64 = 0
        var messages: [CodingMessage] = []
        var model: String?
        var tokensUsed: Int64?
        var unknown = 0
    }

    func parseSession(_ ref: CodingSessionFileRef) throws -> CodingParsedSession {
        let parsed = try Self.parse(URL(fileURLWithPath: ref.filePath))
        return CodingParsedSession(meta: meta(ref, parsed), units: CodingParse.units(parsed.messages), unknownLines: parsed.unknown)
    }

    func parseTranscript(_ ref: CodingSessionFileRef) throws -> CodingParsedTranscript {
        let parsed = try CodingImageBudget.decoding { try Self.parse(URL(fileURLWithPath: ref.filePath)) }
        return CodingParsedTranscript(meta: meta(ref, parsed), mainline: parsed.messages, sidechains: [], unknownLines: parsed.unknown)
    }

    static func parse(_ url: URL) throws -> Parse {
        var (data, torn) = try load(url)
        // 末帧半写：解到断点为止，断点所在的半行丢掉并记一次 unknown，已解析的部分照常呈现
        if torn { data = data.lastIndex(of: 0x0A).map { data[data.startIndex...$0] } ?? Data() }
        var p = Parse()
        // toolCallId → (消息下标, 工具下标)，tool/result 事件回填用
        var toolIndex: [String: (Int, Int)] = [:]
        CodingParse.forEachLine(in: data) { row in
            guard let row else {
                p.unknown += 1
                return
            }
            let type = row["type"] as? String ?? ""
            // 信封顶层 surfaceOp 是联合类型 `'append' | {op:'replace',start,end}`——replace 是对象不是字符串。compaction 与工具结果裁剪
            // 用它把 start..end 的 surface 节点换成缩短版（喂模型的上下文）；这里要还原当时看到的原文，整条跳过（留下被它遮蔽的原始节点）
            if (row["surfaceOp"] as? CodingParse.JSON)?["op"] as? String == "replace" { return }
            let ts = integer(row["time"]) ?? 0
            p.lastTs = max(p.lastTs, ts)
            let data = row["data"] as? CodingParse.JSON ?? [:]
            switch type {
            case "session":
                if let header = header(row) { p.header = header }
            case "user/message":
                let parsed = CodingParse.contentParts(data["content"])
                if parsed.text.isEmpty && parsed.images.isEmpty { return }
                var message = CodingParse.textMessage(.user, parsed.text, ts: ts)
                message.images = parsed.images
                message.imageCount = parsed.imageCount
                // source.kind 权威区分真人输入与注入上下文（agent-instructions / plugin / skill-catalog …，后续还会长）：
                // 白名单 user，非真人一律归 Meta，缺失时当真人（宁可多显示）
                if let kind = (data["source"] as? CodingParse.JSON)?["kind"] as? String, kind != "user" { message.kind = .meta }
                p.messages.append(message)
            case "assistant/message":
                pushAssistant(data, ts, &p, &toolIndex)
            case "tool/result":
                // data.message.content = [tool-result 块]：toolCallId + 嵌套 content + isError
                guard let block = ((data["message"] as? CodingParse.JSON)?["content"] as? [Any])?.first as? CodingParse.JSON,
                      let callId = block["toolCallId"] as? String, let (mi, ti) = toolIndex[callId] else { return }
                let parsed = CodingParse.contentParts(block["content"])
                if !parsed.text.isEmpty { p.messages[mi].toolCalls[ti].output = CodingParse.clip(parsed.text, CodingLimits.maxToolIO).0 }
                if CodingParse.bool(block["isError"]) || (data["error"].map { !($0 is NSNull) } ?? false) {
                    p.messages[mi].toolCalls[ti].isError = true
                }
                p.messages[mi].images += parsed.images
                p.messages[mi].imageCount += parsed.imageCount
            case "session/title":
                if let title = data["title"] as? String, !CodingParse.isBlank(title) {
                    p.title = CodingParse.cleanTitleCandidate(CodingParse.trimmed(title))
                }
            case "request/context":
                // 路由元数据（只在变更时记）；assistant/message 的 source.model 会覆盖
                if p.model == nil, let model = data["model"] as? String { p.model = model }
            default:
                // 信封自带 ignorable = 写端声明的纯信息性记录；其余已知词汇显式列举，表外才计 unknown（schema 漂移金丝雀）
                if !CodingParse.bool(row["ignorable"]) && !knownSkip.contains(type) { p.unknown += 1 }
            }
        }
        if torn { p.unknown += 1 }
        CodingParse.assignSeq(&p.messages)
        return p
    }

    /// 单遍分桶：text 进正文、reasoning 进 thinking、tool-call 进工具；一个 turn 多个 step、每 step 一条 assistant/message，连续
    /// assistant（中间只隔 tool/result）合并成一条（合并与整体截断与 CodingPiRender 同构）
    private static func pushAssistant(_ data: CodingParse.JSON, _ ts: Int64, _ p: inout Parse, _ toolIndex: inout [String: (Int, Int)]) {
        let msg = data["message"] as? CodingParse.JSON ?? [:]
        var parsed = CodingParse.Content()
        var thinkingParts: [String] = []
        var tools: [CodingToolCall] = []
        for case let block as CodingParse.JSON in msg["content"] as? [Any] ?? [] {
            let text = (block["text"] as? String).map(CodingParse.trimmed).flatMap { $0.isEmpty ? nil : $0 }
            switch block["type"] as? String {
            case "text":
                if let text { parsed.push(text) }
            case "reasoning":
                if let text { thinkingParts.append(text) }
            case "tool-call":
                // arguments 是模型原样输出的 JSON 字符串，解析失败保留原文
                let raw = block["arguments"] as? String ?? ""
                let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) ?? raw
                tools.append(CodingParse.toolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", input: input))
            default:
                if CodingParse.isImagePart(block) { parsed.append(CodingParse.contentParts(block)) }
            }
        }
        // 元数据先收再判空：content 为空的 assistant/message 是 dsh 专门挂 usage 的载体（撞上 max-tokens 的调用），提前返回会把这次
        // 调用的 model 与 token 一起丢掉
        let model = (msg["source"] as? CodingParse.JSON)?["model"] as? String
        if let model { p.model = model }
        if let usage = data["usage"] as? CodingParse.JSON {
            // TokenUsage 是「一次模型调用」的账、三项 input 互斥（计费 = 各项之和）：按调用累加，不能 last-wins
            let sum = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"].compactMap { integer(usage[$0]) }.reduce(0, +)
            if sum > 0 { p.tokensUsed = (p.tokensUsed ?? 0) + sum }
        }
        if parsed.text.isEmpty && tools.isEmpty && thinkingParts.isEmpty && parsed.images.isEmpty { return }
        if p.messages.last?.role != .assistant { p.messages.append(CodingParse.textMessage(.assistant, "", ts: ts)) }
        let base = p.messages.count - 1
        if !parsed.text.isEmpty || !parsed.images.isEmpty {
            if p.messages[base].text.utf8.count < CodingLimits.maxMessageText, !parsed.text.isEmpty {
                p.messages[base].text += (p.messages[base].text.isEmpty ? "" : "\n\n") + parsed.text
            }
            p.messages[base].images += parsed.images
            p.messages[base].imageCount += parsed.imageCount
            if p.messages[base].text.utf8.count > CodingLimits.maxMessageText {
                p.messages[base].text = CodingParse.clip(p.messages[base].text, CodingLimits.maxMessageText).0
                p.messages[base].truncated = true
            }
        }
        // thinking 与全库同压 maxToolIO；已到上限就不再拼接
        if !thinkingParts.isEmpty, (p.messages[base].thinking?.utf8.count ?? 0) < CodingLimits.maxToolIO {
            let joined = thinkingParts.joined(separator: "\n\n")
            let merged = p.messages[base].thinking.map { $0 + "\n\n" + joined } ?? joined
            p.messages[base].thinking = CodingParse.clip(merged, CodingLimits.maxToolIO).0
        }
        if let model { p.messages[base].model = model }
        for call in tools {
            toolIndex[call.id] = (base, p.messages[base].toolCalls.count)
            p.messages[base].toolCalls.append(call)
        }
    }

    private func meta(_ ref: CodingSessionFileRef, _ p: Parse) -> CodingSessionMeta {
        let native = p.header?.id ?? ref.nativeId
        let cwd = p.header?.cwd ?? ""
        let created = p.header?.createdAt ?? 0
        return CodingSessionMeta(
            key: "dsh:\(native)", nativeId: native, agent: .dsh,
            title: p.title.flatMap { $0.isEmpty ? nil : $0 } ?? CodingParse.titleFromMessages(p.messages) ?? CodingLimits.untitled,
            projectPath: cwd, projectName: CodingParse.projectName(cwd), filePath: ref.filePath,
            createdAt: created > 0 ? created : ref.mtimeMs, updatedAt: p.lastTs > 0 ? p.lastTs : ref.mtimeMs,
            messageCount: p.messages.filter { $0.kind == .text }.count, sizeBytes: ref.size,
            gitBranch: nil, model: p.model, tokensUsed: p.tokensUsed, archived: false, source: nil
        )
    }
}
extension DshAdapter {
    /// 选中 `~/.dsh`（含 sessions/）或 sessions 目录本身都认
    func withCustomRoot(_ dir: URL) -> CodingSessionAdapter {
        let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
        return DshAdapter(root: CodingLocations.isDirectory(sessions) ? sessions : dir)
    }
}
#endif
