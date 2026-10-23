import Foundation

/// Kelivo 备份（#049）两代共用的中间模型：旧版 `chats.json` 和新版 `database/kelivo.db` 都先读成这个，再统一转 payload。
/// 格式依据 docs/research-import-kelivo-format.md（只参考格式，Kelivo 是 AGPL，不抄实现）。
enum KelivoBackup {
    static let provider = "kelivo"

    struct Conversation {
        var id: String
        var title: String
        var createdAt: Date?
        var updatedAt: Date?
        /// 组键 → 选中的 version 值（旧版的序号已在解析时换算好）
        var selections: [String: Int] = [:]
        var assistantId: String?
        /// 原样留进对话 sourceMetadata（摘要、置顶、truncateIndex…），不生效
        var metadata: [String: Any] = [:]
        /// 已按会话内顺序排好（新：message_order；旧：修复后的 messageIds 顺序）
        var revisions: [Revision] = []
    }

    struct Revision {
        var id: String
        var role: String
        /// `groupId`，缺省用自身 id
        var groupKey: String
        var version: Int
        var order: Int
        var time: Date?
        var parts: [Part] = []
        var metadata: [String: Any] = [:]
    }

    enum Part {
        case text(String)
        case reasoning(String)
        case tool(id: String, name: String, argumentsJSON: String, result: String?)
        case image(Attachment)
        case file(Attachment)
        /// 不显示的内容（assistant_round_end、provider_auth_error、不认识的 kind…），原样进消息元数据
        case hidden(kind: String, payload: String)
    }

    struct Attachment {
        var uri: String
        var name: String?
        var mime: String?
        var unavailable = false
    }

    struct Assistant {
        var name: String?
        var systemPrompt: String?
    }

    /// 解析计数，进预览和结果卡说明
    struct Counts {
        var danglingIds = 0
        var duplicateReferences = 0
        var rehomedMessages = 0
        var unreferencedMessages = 0
        var duplicateIds = 0
        var noTimezoneTimes = 0
        var unreadableTimes = 0

        mutating func add(_ other: Counts) {
            danglingIds += other.danglingIds
            duplicateReferences += other.duplicateReferences
            rehomedMessages += other.rehomedMessages
            unreferencedMessages += other.unreferencedMessages
            duplicateIds += other.duplicateIds
            noTimezoneTimes += other.noTimezoneTimes
            unreadableTimes += other.unreadableTimes
        }

        var notes: [String] {
            var out: [String] = []
            let repaired = danglingIds + duplicateReferences + rehomedMessages + unreferencedMessages + duplicateIds
            if repaired > 0 { out.append("修复了旧版备份里 \(repaired) 处重复 / 悬空 / 归属不对的消息记录（Kelivo 自己升级时也这样修）") }
            if noTimezoneTimes > 0 { out.append("\(noTimezoneTimes) 个时间没带时区，按本机时区算") }
            if unreadableTimes > 0 { out.append("\(unreadableTimes) 个时间读不出") }
            return out
        }
    }

    // MARK: - 识别

    /// 新版 `manifest.json`
    static func isManifest(_ root: Any) -> Bool {
        guard let dict = root as? [String: Any] else { return false }
        return dict["format"] as? String == "kelivo-backup" && dict["formatVersion"] is Int
    }

    /// 旧版 `chats.json`：`version` 为空或 1，`conversations` / `messages` 都是数组
    static func isLegacyChats(_ root: Any) -> Bool {
        guard let dict = root as? [String: Any], dict["conversations"] is [Any], dict["messages"] is [Any] else { return false }
        if let version = dict["version"], !(version is NSNull) { return (version as? Int) == 1 }
        return true
    }

    // MARK: - part（新版 message_part_rows；新格式 JSON 的 `parts[]` 同一契约）

    /// text / reasoning 的 payload 是原字符串，其余是 JSON 字符串；解不出的、不认识的 kind 原样隐藏
    static func part(kind: String, payload: String) -> Part {
        switch kind {
        case "text":
            return .text(payload)
        case "reasoning":
            return .reasoning(payload)
        case "tool_call":
            guard let dict = jsonObject(payload) as? [String: Any] else { return .hidden(kind: kind, payload: payload) }
            let arguments = dict["arguments"].map { jsonString($0) } ?? "{}"
            let result = dict["content"] as? String
            return .tool(id: dict["id"] as? String ?? "", name: dict["name"] as? String ?? "tool", argumentsJSON: arguments,
                         result: result?.isEmpty == true ? nil : result)
        case "image", "file":
            guard let dict = jsonObject(payload) as? [String: Any], let uri = dict["uri"] as? String, !uri.isEmpty else {
                return .hidden(kind: kind, payload: payload)
            }
            let attachment = Attachment(uri: uri, name: dict["name"] as? String, mime: dict["mime"] as? String,
                                        unavailable: dict["unavailable"] as? Bool ?? false)
            return kind == "image" ? .image(attachment) : .file(attachment)
        default:
            return .hidden(kind: kind, payload: payload)
        }
    }

    // MARK: - 附件路径 → 包内成员

    private static let roots: Set<String> = ["upload", "images", "avatars", "fonts"]
    /// Kelivo 数据根的最后一段（各平台沙盒：`…/Documents/`、`…/com.psyche.kelivo/`、Windows `…/kelivo/`、安卓 `app_flutter` / `files`）
    private static let dataRootNames: Set<String> = ["Documents", "com.psyche.kelivo", "kelivo", "app_flutter", "files"]

    /// 附件引用在备份包里对应的成员路径（`upload/a b.png`）。新版 `kelivo-file:///<root>/<逐段编码>`；
    /// 旧版是导出那台机器的绝对路径 / `file://`：从 Kelivo 数据根之后的 `upload|images|avatars|fonts` 起截尾巴（认不出数据根就取第一个），
/// 附件子目录里再出现的同名目录不算（`upload/images/a.png` 是整条，sol #9）。远端 URL / data: / 对不上 → nil
    static func memberPath(for uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("kelivo-file:///") {
            let rest = trimmed.dropFirst("kelivo-file:///".count)
            guard !rest.contains("?"), !rest.contains("#") else { return nil }
            var segments: [String] = []
            for raw in rest.split(separator: "/", omittingEmptySubsequences: false) {
                guard let seg = String(raw).removingPercentEncoding, !seg.isEmpty, seg != ".", seg != "..",
                      !seg.contains("/"), !seg.contains("\\") else { return nil }
                segments.append(seg)
            }
            guard segments.count >= 2, roots.contains(segments[0]) else { return nil }
            return segments.joined(separator: "/")
        }
        var path = trimmed
        if path.lowercased().hasPrefix("file://") {
            guard let url = URL(string: path) else { return nil }
            path = url.path
        }
        guard path.hasPrefix("/") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil else { return nil }
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        let anchored = parts.indices.first { $0 > 0 && roots.contains(parts[$0]) && dataRootNames.contains(parts[$0 - 1]) }
        guard let i = anchored ?? parts.firstIndex(where: { roots.contains($0) }), i + 1 < parts.count else { return nil }
        let tail = Array(parts[i...])
        guard !tail.contains(".."), !tail.contains(".") else { return nil }
        return tail.joined(separator: "/")
    }

    // MARK: - 时间

    /// 新版日期列：epoch 微秒
    static func date(microseconds: Int64?) -> Date? {
        microseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
    }

    private static let isoParts = try! Regex(#"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$"#)

    /// 旧版 Dart `toIso8601String`：带 `Z` / 偏移的照原值；不带时区的按 `timeZone`（默认本机）算（plan D1）
    static func date(iso raw: String?, timeZone: TimeZone = .current, counts: inout Counts) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        guard let m = try? isoParts.wholeMatch(in: raw) else {
            counts.unreadableTimes += 1
            return nil
        }
        func int(_ i: Int) -> Int? { m.output[i].substring.flatMap { Int($0) } }
        var comps = DateComponents(year: int(1), month: int(2), day: int(3), hour: int(4), minute: int(5), second: int(6) ?? 0)
        if let zone = m.output[8].substring.map(String.init) {
            if zone == "Z" {
                comps.timeZone = TimeZone(secondsFromGMT: 0)
            } else {
                let digits = zone.dropFirst().filter(\.isNumber)
                let hours = Int(digits.prefix(2)) ?? 0, minutes = Int(digits.suffix(2)) ?? 0
                let seconds = (hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
                comps.timeZone = TimeZone(secondsFromGMT: seconds)
            }
        } else {
            comps.timeZone = timeZone
            counts.noTimezoneTimes += 1
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = comps.timeZone ?? timeZone
        guard let base = calendar.date(from: comps) else {
            counts.unreadableTimes += 1
            return nil
        }
        let fraction = m.output[7].substring.flatMap { Double("0" + $0) } ?? 0
        return base.addingTimeInterval(fraction)
    }

    // MARK: - JSON 小工具

    static func jsonObject(_ text: String?) -> Any? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
