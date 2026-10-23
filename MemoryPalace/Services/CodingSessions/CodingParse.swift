#if os(macOS)
import Foundation

/// 各家 adapter 共用的解析工具（Wake `adapters/parse_utils.rs` + `adapters/mod.rs` 的 units / seq）。
enum CodingParse {
    typealias JSON = [String: Any]

    // MARK: - JSONL

    /// 逐行解析 JSONL：空白行跳过；解析不了 / 不是对象的行回调 nil（调用方计 unknown）
    static func forEachLine(_ url: URL, _ body: (JSON?) -> Void) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw CodingSessionError.unreadable("\(url.lastPathComponent)：\(error.localizedDescription)")
        }
        forEachLine(in: data, body)
    }

    /// 同上，对已在内存里的字节（dsh 解压后的日志）
    static func forEachLine(in data: Data, _ body: (JSON?) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = raw.count
            var start = 0
            while start < count {
                let end: Int
                if let hit = memchr(bytes + start, 0x0A, count - start) {
                    end = UnsafeRawPointer(hit).assumingMemoryBound(to: UInt8.self) - bytes
                } else {
                    end = count
                }
                var first = start
                while first < end, bytes[first] == 0x20 || bytes[first] == 0x09 || bytes[first] == 0x0D { first += 1 }
                if first < end {
                    let line = Data(bytes: bytes + start, count: end - start)
                    body((try? JSONSerialization.jsonObject(with: line)) as? JSON)
                }
                start = end + 1
            }
        }
    }

    // MARK: - 值

    static func int64(_ value: Any?) -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        return number.int64Value
    }

    static func bool(_ value: Any?) -> Bool {
        (value as? Bool) == true
    }

    /// ISO8601 字符串或 unix 秒 / 毫秒 → epoch ms；解析不了 = 0
    static func epochMs(_ value: Any?) -> Int64 {
        if let text = value as? String { return isoMs(text) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let f = number.doubleValue
            if f > 1e12 { return Int64(f) }
            if f > 0 { return Int64(f * 1000) }
        }
        return 0
    }

    /// RFC3339（任意位小数秒，Z 或 ±HH:MM）→ epoch ms；缺时区 / 格式不对 = 0
    static func isoMs(_ text: String) -> Int64 {
        let b = Array(text.utf8)
        func num(_ i: Int, _ n: Int) -> Int? {
            guard i >= 0, i + n <= b.count else { return nil }
            var v = 0
            for k in i..<(i + n) {
                let c = b[k]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard b.count >= 20,
              let y = num(0, 4), b[4] == 45, let mo = num(5, 2), b[7] == 45, let d = num(8, 2),
              b[10] == 84 || b[10] == 116 || b[10] == 32,
              let h = num(11, 2), b[13] == 58, let mi = num(14, 2), b[16] == 58, let se = num(17, 2) else { return 0 }
        var i = 19
        var fractionMs = 0.0
        if b[i] == 46 {
            i += 1
            var scale = 100.0
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                fractionMs += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        guard i < b.count else { return 0 }
        var offsetSeconds = 0
        if b[i] == 90 || b[i] == 122 {
            // Z
        } else if b[i] == 43 || b[i] == 45, let oh = num(i + 1, 2) {
            var om = 0
            if let m = num(i + 4, 2), i + 3 < b.count, b[i + 3] == 58 {
                om = m
            } else if let m = num(i + 3, 2) {
                om = m
            }
            offsetSeconds = (oh * 60 + om) * 60 * (b[i] == 45 ? -1 : 1)
        } else {
            return 0
        }
        let days = daysFromCivil(y, mo, d)
        let seconds = Int64(days) * 86_400 + Int64(h * 3600 + mi * 60 + se) - Int64(offsetSeconds)
        return seconds * 1000 + Int64(fractionMs)
    }

    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    // MARK: - 文本

    /// SQLite `datetime()` 文本（"2026-08-05 09:00:00"，无时区 = UTC）或 ISO8601 → epoch ms；解析不了 = 0（Wake `sqlite_dt_ms`）
    static func sqliteDateMs(_ s: String) -> Int64 {
        let ms = isoMs(s)
        if ms > 0 { return ms }
        let t = s.replacingOccurrences(of: " ", with: "T")
        return isoMs(t.hasSuffix("Z") ? t : t + "Z")
    }

    static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isBlank(_ s: String) -> Bool {
        s.allSatisfy(\.isWhitespace)
    }

    /// 按 UTF-8 字节截断到 max（落在字符边界），超出补「… (truncated)」
    static func clip(_ s: String, _ max: Int) -> (String, Bool) {
        let utf8 = s.utf8
        guard utf8.count > max else { return (s, false) }
        var end = utf8.index(utf8.startIndex, offsetBy: max)
        while end > utf8.startIndex, String(utf8[..<end]) == nil {
            end = utf8.index(before: end)
        }
        return ((String(utf8[..<end]) ?? "") + "\n… (truncated)", true)
    }

    static func capChars(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max)) + "…"
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// cwd → 项目显示名（路径末段）
    static func projectName(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "未知项目" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "未知项目" : name
    }

    static func compactJSON(_ value: Any?) -> String? {
        let object = value ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func prettyJSON(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 标题

    /// 清洗标题候选：剥 slash-command 壳与 system-reminder 等标签，压单行截断。空串 = 不可用
    static func cleanTitleCandidate(_ raw: String) -> String {
        var s = stripTagBlock(raw, "system-reminder")
        s = stripTagBlock(s, "local-command-caveat")
        s = stripTagBlock(s, "local-command-stdout")
        let args = extractTag(s, "command-args")
        let name = extractTag(s, "command-name")
        if args != nil || name != nil {
            if let args, !isBlank(args) {
                s = args
            } else {
                s = name ?? ""
            }
        }
        var out = ""
        var iterator = s.makeIterator()
        while let c = iterator.next() {
            if c == "<" {
                var tag = ""
                var closed = false
                while let c2 = iterator.next() {
                    if c2 == ">" { closed = true; break }
                    if c2 == "\n" || tag.utf8.count > 60 { break }
                    tag.append(c2)
                }
                if closed {
                    out.append(" ")
                } else {
                    out.append("<")
                    out.append(tag)
                }
            } else {
                out.append(c)
            }
        }
        let compact = collapseWhitespace(out.replacingOccurrences(of: CodingLimits.imagePlaceholder, with: " "))
        guard !compact.isEmpty else { return "" }
        return capChars(compact, CodingLimits.maxTitle)
    }

    static func stripTagBlock(_ s: String, _ tag: String) -> String {
        let open = "<\(tag)>", close = "</\(tag)>"
        var out = ""
        var rest = Substring(s)
        while true {
            guard let openRange = rest.range(of: open) else {
                out += rest
                return out
            }
            out += rest[..<openRange.lowerBound]
            out += " "
            guard let closeRange = rest[openRange.lowerBound...].range(of: close) else { return out }
            rest = rest[closeRange.upperBound...]
        }
    }

    static func extractTag(_ s: String, _ tag: String) -> String? {
        guard let open = s.range(of: "<\(tag)>"),
              let close = s[open.upperBound...].range(of: "</\(tag)>") else { return nil }
        return String(s[open.upperBound..<close.lowerBound])
    }

    /// IDE / CLI 注入型「用户」消息：详情里归 Meta 折叠，不参与标题推导
    static func isInjectedUserContent(_ text: String) -> Bool {
        let t = text.drop(while: \.isWhitespace)
        let prefixes = [
            "<recommended_plugins", "<environment_context", "<user_action", "<user_instructions",
            "<permissions", "<workspace", "<system-", "<context ", "<session_context",
            "IMPORTANT: Do NOT read", "Caveat: The messages below",
            "# Files pasted by the user", "# Files mentioned by the user",
            "## Referenced ChatGPT conversation", "# AGENTS.md instructions",
            "The following is the Codex agent history",
        ]
        if prefixes.contains(where: { t.hasPrefix($0) }) { return true }
        return t.contains("/.codex/plugins/") || t.contains(#"\.codex\plugins\"#)
            || ((t.contains("/plugins/cache/") || t.contains(#"\plugins\cache\"#)) && t.contains("SKILL.md"))
    }

    static func userKind(_ text: String) -> CodingMessageKind {
        isInjectedUserContent(text) ? .meta : .text
    }

    /// 纯文本消息（trim + clip + user 注入判定）
    static func textMessage(_ role: CodingRole, _ text: String, ts: Int64) -> CodingMessage {
        let (body, truncated) = clip(trimmed(text), CodingLimits.maxMessageText)
        let kind: CodingMessageKind = role == .user ? userKind(text) : .text
        return CodingMessage(seq: 0, role: role, kind: kind, text: body, truncated: truncated, timestamp: ts > 0 ? ts : nil)
    }

    static func titleFromMessages(_ messages: [CodingMessage]) -> String? {
        for message in messages where message.role == .user && message.kind == .text {
            let title = cleanTitleCandidate(message.text)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// seq 回填——索引 seq 与详情序号一致的唯一执行点
    static func assignSeq(_ messages: inout [CodingMessage]) {
        for i in messages.indices { messages[i].seq = i }
    }

    /// 只收 Text 消息；工具名 + 参数摘要并入正文
    static func units(_ messages: [CodingMessage]) -> [CodingIndexUnit] {
        messages.filter { $0.kind == .text }.compactMap { message in
            var parts = [message.text]
            for call in message.toolCalls { parts.append("\(call.name) \(call.inputPreview)") }
            let text = clip(parts.joined(separator: "\n"), CodingLimits.maxMessageText).0
            return isBlank(text) ? nil : CodingIndexUnit(seq: message.seq, role: message.role, timestamp: message.timestamp, text: text)
        }
    }

    // MARK: - 内容块

    struct Content {
        var text = ""
        var imageCount = 0
        var images: [CodingImage] = []

        mutating func push(_ value: String, separator: String = "\n\n") {
            let t = CodingParse.trimmed(value)
            guard !t.isEmpty else { return }
            if !text.isEmpty { text += separator }
            text += t
        }

        mutating func append(_ other: Content, separator: String = "\n\n") {
            if !other.text.isEmpty {
                if !text.isEmpty { text += separator }
                text += other.text
            }
            imageCount += other.imageCount
            images += other.images
        }
    }

    static func contentParts(_ value: Any?) -> Content {
        var content = Content()
        collect(value, depth: 0, into: &content)
        return content
    }

    private static func collect(_ value: Any?, depth: Int, into content: inout Content) {
        guard depth <= 4 else { return }
        if let text = value as? String {
            content.push(text)
            return
        }
        if let array = value as? [Any] {
            for part in array { collect(part, depth: depth + 1, into: &content) }
            return
        }
        guard let object = value as? JSON else { return }
        if isImagePart(object) {
            content.imageCount += 1
            // 只有详情路径（CodingImageBudget 范围内）解码；解不了或索引路径 → 正文占位
            if let budget = CodingImageBudget.current, let image = CodingImageDecoder.decode(object, depth: depth, budget: budget) {
                content.images.append(image)
            } else {
                content.push(CodingLimits.imagePlaceholder)
            }
            return
        }
        let kind = partKind(object)
        if let kind, kind == "text" || kind == "input_text" || kind == "output_text" {
            if let text = (object["text"] ?? object["data"]) as? String { content.push(text) }
            return
        }
        if kind == nil {
            if let text = object["text"] as? String {
                content.push(text)
                return
            }
            if let inner = object["content"] {
                collect(inner, depth: depth + 1, into: &content)
                return
            }
        }
        if kind == "content" || kind == "part", let inner = object["content"] ?? object["data"] {
            collect(inner, depth: depth + 1, into: &content)
        }
    }

    /// 工具结果：未知非图片对象以 JSON 原文显示（旧解析器兼容行为）
    static func toolResultParts(_ value: Any?) -> Content {
        let values: [Any?] = (value as? [Any]).map { $0.map { Optional($0) } } ?? [value]
        var result = Content()
        for item in values {
            let parsed = contentParts(item)
            if !parsed.text.isEmpty {
                result.append(parsed, separator: "\n")
            } else if parsed.imageCount == 0, let item, !(item is NSNull) {
                if let json = compactJSON(item) { result.push(json, separator: "\n") }
            } else {
                result.append(parsed, separator: "\n")
            }
        }
        return result
    }

    private static func partKind(_ object: JSON) -> String? {
        guard let kind = (object["type"] ?? object["kind"]) as? String else { return nil }
        return kind.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    static func imageMediaType(_ object: JSON) -> String? {
        for key in ["media_type", "mediaType", "mime_type", "mimeType", "mime"] {
            if let value = object[key] as? String, value.hasPrefix("image/") {
                return String(value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]).lowercased()
            }
        }
        return nil
    }

    static func isImagePart(_ object: JSON) -> Bool {
        if let kind = partKind(object), kind.contains("image") { return true }
        if imageMediaType(object) != nil { return true }
        if object["inlineData"] != nil || object["inline_data"] != nil || object["image_url"] != nil || object["imageUrl"] != nil { return true }
        if let source = object["source"] as? JSON, imageMediaType(source) != nil { return true }
        return false
    }

    // MARK: - 工具调用

    static func toolCall(id: String, name: String, input: Any?, output: String? = nil, isError: Bool = false) -> CodingToolCall {
        let isNull = input == nil || input is NSNull
        let inputText = isNull ? nil : prettyJSON(input!).flatMap { $0.isEmpty ? nil : clip($0, CodingLimits.maxToolIO).0 }
        return CodingToolCall(
            id: id,
            name: name.isEmpty ? "tool" : name,
            inputPreview: makePreview(input ?? NSNull()),
            input: inputText,
            output: output.map { clip($0, CodingLimits.maxToolIO).0 },
            isError: isError,
            sidechainRef: nil
        )
    }

    /// 工具输入的单行摘要
    static func makePreview(_ input: Any) -> String {
        var candidate: String?
        if let object = input as? JSON {
            for key in ["command", "file_path", "path", "pattern", "query", "url", "description"] {
                if let value = object[key] as? String, !isBlank(value) {
                    candidate = value
                    break
                }
            }
            if candidate == nil { candidate = compactJSON(object) }
        } else if let text = input as? String {
            candidate = text
        } else {
            candidate = compactJSON(input)
        }
        return capChars(collapseWhitespace(candidate ?? ""), 200)
    }

    // MARK: - Codex Desktop 包装

    static func unwrapFilePreamble(_ text: String) -> String? {
        let t = String(text.drop(while: \.isWhitespace))
        guard t.hasPrefix("# Files mentioned by the user") || t.hasPrefix("# Files pasted by the user") else { return nil }
        for marker in ["## My request for Codex:", "## My request:"] {
            if let range = t.range(of: marker) {
                return trimmed(String(t[range.upperBound...]))
            }
        }
        return ""
    }

    static func stripImageTags(_ text: String) -> String {
        let prefix = "<image name=[Image #"
        guard text.contains(prefix) else { return text }
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: prefix) {
            out += rest[..<start.lowerBound]
            let after = rest[start.lowerBound...]
            guard let gt = after.firstIndex(of: ">") else {
                out += after
                return out
            }
            let openEnd = after.index(after: gt)
            let openTag = after[..<openEnd]
            if !openTag.contains("] path=") {
                out += after[..<after.index(after.startIndex, offsetBy: prefix.count)]
                rest = after[after.index(after.startIndex, offsetBy: prefix.count)...]
                continue
            }
            if let close = after[openEnd...].range(of: "</image>") {
                rest = after[close.upperBound...]
            } else {
                rest = after[openEnd...]
            }
        }
        out += rest
        return trimmed(out)
    }

    // MARK: - 文件引用

    static func mtimeMs(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static let refKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

    /// /private/var|tmp|etc → /var|tmp|etc：macOS 这三处是指向 /private 的符号链接，FileManager 枚举有时给解析后的形态、
    /// 有时给原写法——统一成原写法，全量 / 增量 / 删除事件 / 根归属才是同一个字符串。纯字符串不查盘，删掉的文件也能归一
    static func canonicalPath(_ path: String) -> String {
        for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// 非空 .jsonl，stem = native id
    static func defaultFileRef(_ agent: CodingAgent, _ url: URL) -> CodingSessionFileRef? {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), name.hasSuffix(".jsonl") else { return nil }
        guard let values = try? url.resourceValues(forKeys: Set(refKeys)),
              values.isRegularFile == true, let size = values.fileSize, size > 0 else { return nil }
        return CodingSessionFileRef(agent: agent, nativeId: String(name.dropLast(6)), filePath: canonicalPath(url.path),
                                    mtimeMs: mtimeMs(values.contentModificationDate), size: Int64(size))
    }

    /// 递归枚举目录下非空 .jsonl
    static func listJSONLRefs(_ dir: URL, _ agent: CodingAgent, nativeId: (String) -> String) -> [CodingSessionFileRef] {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: refKeys) else { return [] }
        var refs: [CodingSessionFileRef] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if var ref = defaultFileRef(agent, url) {
                ref.nativeId = nativeId(ref.nativeId)
                refs.append(ref)
            }
        }
        return refs
    }
}
#endif
