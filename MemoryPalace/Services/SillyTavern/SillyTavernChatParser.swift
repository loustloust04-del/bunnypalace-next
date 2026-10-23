import Foundation

/// 酒馆 JSONL 聊天解析（卡库 ⑧b）：首行 header + 每行一条消息。纯值，不写库。
/// 坏行隔离继续并记行号；缺 header（单聊）/ 整文件坏不算成功。

/// 显示规则只看明确字段，不把 is_system 升级成模型指令（plan §6.1）
enum SillyTavernMessageVisibility: String, Codable {
    /// 普通消息
    case normal
    /// is_system=true 且无 extra.type：酒馆「隐藏」（/hide），聊天里还在但不进 prompt
    case hidden
    /// extra.type == narrator：旁白，显示，不当指令
    case narrator
    /// is_system=true 且 extra.type 是别的（help / welcome …）：酒馆界面提示，只归档
    case uiSystem

    static func classify(isSystem: Bool, extraType: String?) -> Self {
        if extraType == "narrator" { return .narrator }
        guard isSystem else { return .normal }
        return extraType == nil ? .hidden : .uiSystem
    }
}

struct SillyTavernChatHeader {
    let userName: String?
    /// 占位名，不用来认角色（关联按目录 stem）
    let characterName: String?
    let chatMetadata: Data?
    let personaRef: String?
    let worldRef: String?
    let attachmentCount: Int
    let rawLine: Data
}

struct SillyTavernChatMessage {
    let line: Int
    let name: String
    let isUser: Bool
    let isSystem: Bool
    let visibility: SillyTavernMessageVisibility
    let sendDateRaw: String?
    let sendDate: Date?
    let mes: String
    /// 源里没有 swipes 键 = nil
    let swipes: [String]?
    /// 源值原样（可能缺、越界、不是整数）
    let swipeId: Int?
    let swipeInfo: [Data]
    let extra: Data?
    /// 核心键之外的字段原样（variables / hash_sheets / tableEditMatches / 插件私有键）
    let preservedFields: [String: Data]
    let fileRefCount: Int
    let mediaRefCount: Int
    let rawLine: Data
}

struct SillyTavernBadLine: Equatable {
    let line: Int
    let reason: String
}

struct SillyTavernParsedChat {
    enum Status: Equatable {
        case ok
        case partial
        case failed(String)
    }

    let relativePath: String
    let header: SillyTavernChatHeader?
    let messages: [SillyTavernChatMessage]
    let badLines: [SillyTavernBadLine]
    let status: Status

    var isSuccess: Bool {
        if case .failed = status { return false }
        return true
    }
}

enum SillyTavernChatParser {
    static let coreKeys: Set<String> = ["name", "is_user", "is_system", "send_date", "mes", "extra", "swipe_id", "swipes", "swipe_info"]

    /// requireHeader：单聊要 header；群聊新旧格式有无 header 都认
    static func parse(_ data: Data, relativePath: String, requireHeader: Bool = true) -> SillyTavernParsedChat {
        var header: SillyTavernChatHeader?
        var messages: [SillyTavernChatMessage] = []
        var bad: [SillyTavernBadLine] = []
        var sawFirst = false

        for (index, slice) in lines(data).enumerated() {
            let lineNumber = index + 1
            let line = trimmed(slice)
            if line.isEmpty { continue }
            let object: [String: Any]
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    bad.append(.init(line: lineNumber, reason: "不是 JSON 对象"))
                    continue
                }
                object = parsed
            } catch {
                bad.append(.init(line: lineNumber, reason: "JSON 坏了"))
                continue
            }
            // header 认「第一个读得出来的对象」：第 1 行坏了不连累第 2 行的 header（#050）
            if !sawFirst {
                sawFirst = true
                if isHeader(object) {
                    header = makeHeader(object, raw: line)
                    continue
                }
            }
            if let message = makeMessage(object, raw: line, line: lineNumber) {
                messages.append(message)
            } else {
                bad.append(.init(line: lineNumber, reason: "缺 mes"))
            }
        }

        let status: SillyTavernParsedChat.Status
        if data.isEmpty || (header == nil && messages.isEmpty) {
            status = .failed(bad.isEmpty ? "空文件" : "整个文件读不出")
        } else if requireHeader && header == nil {
            status = .failed("缺 header")
        } else {
            status = bad.isEmpty ? .ok : .partial
        }
        return SillyTavernParsedChat(relativePath: relativePath, header: header, messages: messages, badLines: bad, status: status)
    }

    static func isHeader(_ object: [String: Any]) -> Bool {
        if object["chat_metadata"] != nil { return true }
        return object["mes"] == nil && (object["user_name"] != nil || object["character_name"] != nil)
    }

    // MARK: - 行

    private static func lines(_ data: Data) -> [Data] {
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        return body.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
    }

    private static func trimmed(_ line: Data) -> Data {
        var line = line
        while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 { line.removeLast() }
        return line
    }

    private static func fragment(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    private static func makeHeader(_ object: [String: Any], raw: Data) -> SillyTavernChatHeader {
        let metadata = object["chat_metadata"] as? [String: Any]
        let persona = (metadata?["persona"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let world = (metadata?["world_info"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SillyTavernChatHeader(
            userName: object["user_name"] as? String,
            characterName: object["character_name"] as? String,
            chatMetadata: metadata.flatMap(fragment),
            personaRef: persona,
            worldRef: world,
            attachmentCount: (metadata?["attachments"] as? [Any])?.count ?? 0,
            rawLine: raw
        )
    }

    private static func makeMessage(_ object: [String: Any], raw: Data, line: Int) -> SillyTavernChatMessage? {
        guard let mes = object["mes"] as? String else { return nil }
        let extra = object["extra"] as? [String: Any]
        let extraType = extra?["type"] as? String
        let isSystem = object["is_system"] as? Bool ?? false
        let sendRaw: String? = (object["send_date"] as? String) ?? (object["send_date"] as? NSNumber).map { $0.stringValue }
        let swipes: [String]? = (object["swipes"] as? [Any]).map { $0.map { $0 as? String ?? "" } }
        var preserved: [String: Data] = [:]
        for (key, value) in object where !coreKeys.contains(key) {
            preserved[key] = fragment(value)
        }
        var files = (extra?["files"] as? [Any])?.count ?? 0
        if extra?["file"] is [String: Any] { files += 1 }
        return SillyTavernChatMessage(
            line: line,
            name: object["name"] as? String ?? "",
            isUser: object["is_user"] as? Bool ?? false,
            isSystem: isSystem,
            visibility: .classify(isSystem: isSystem, extraType: extraType),
            sendDateRaw: sendRaw,
            sendDate: parseDate(object["send_date"]),
            mes: mes,
            swipes: swipes,
            swipeId: (object["swipe_id"] as? NSNumber).flatMap { CFNumberIsFloatType($0) ? nil : $0.intValue },
            swipeInfo: (object["swipe_info"] as? [Any])?.map { fragment($0) ?? Data("null".utf8) } ?? [],
            extra: extra.flatMap(fragment),
            preservedFields: preserved,
            fileRefCount: files,
            mediaRefCount: (extra?["media"] as? [Any])?.count ?? 0,
            rawLine: raw
        )
    }

    // MARK: - 时间

    /// 酒馆新版 ISO8601（带毫秒）、数字 / 纯数字字符串毫秒、旧版 "June 3, 2025 7:24am"、
    /// "2024-07-12@01h31m37s123ms"（酒馆自己按 UTC 解）
    static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is Bool) {
            let ms = number.doubleValue
            return ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
        }
        guard let string = value as? String, !string.isEmpty else { return nil }
        if string.allSatisfy(\.isASCII), string.allSatisfy(\.isNumber), let ms = Double(string) {
            return ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        let legacy = DateFormatter()
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'@'HH'h'mm'm'ss's'SSS'ms'", "yyyy-MM-dd'@'HH'h'mm'm'ss's'"] {
            legacy.dateFormat = format
            if let date = legacy.date(from: string) { return date }
        }
        // 英文月份没写时区：按设备时区（源文件本来就没说）；am / pm 小写也认
        legacy.timeZone = .current
        let normalized = string.hasSuffix("am") || string.hasSuffix("pm")
            ? String(string.dropLast(2)) + string.suffix(2).uppercased() : string
        for format in ["MMMM d, yyyy h:mma", "MMMM d, yyyy h:mm a"] {
            legacy.dateFormat = format
            if let date = legacy.date(from: normalized) { return date }
        }
        return nil
    }
}
