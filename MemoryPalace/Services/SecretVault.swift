import Foundation
import Security

/// 加密值（docs/plan-secure-ask.md）：加密提问卡填的真值只进钥匙串，卡上 answer 是 `{{secret:s-xxxx}}` 占位。
/// 单开 service，不跟 API key 混（「API key 云同步」开关的 reencryptAllKeys 只扫 apikey service）。
/// 元数据（题面 / 范围 / 创建时间）放在条目属性里跟真值一起同步；列表只取属性不取 data（mac getAll -50 老坑）。
/// **真值不打印、不落任何别的地方。**
enum SecretVault {
    static let service = "com.susu.MemoryPalace.secret"

    /// 设置页列表的一行（不含真值）
    struct Entry: Identifiable, Equatable {
        let id: String
        let label: String
        /// nil = 所有对话都能用
        let conversationId: String?
        let created: Date
        /// true = iCloud 钥匙串；false = 仅本机（mac 没有钥匙串共享权限时写 iCloud 会失败退到这）
        let synced: Bool
    }

    /// 存在条目 kSecAttrComment 里的元数据
    private struct Meta: Codable {
        /// 对话 id，或 "*" = 所有对话
        var conv: String
        var created: TimeInterval
    }

    static let allConversations = "*"

    // MARK: - 存

    /// 存一个新值，返回 id（`s-` + 8 位十六进制）；钥匙串写不进返回 nil。
    /// 先按 iCloud 同步写，失败（mac 缺 keychain-access-groups 权限）退成只存本机。
    static func save(_ value: String, label: String, conversationId: String?) -> String? {
        let id = "s-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let meta = Meta(conv: conversationId ?? allConversations, created: Date().timeIntervalSince1970)
        guard let metaData = try? JSONEncoder().encode(meta), let metaText = String(data: metaData, encoding: .utf8) else { return nil }
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrLabel as String: label,
            kSecAttrComment as String: metaText,
            kSecValueData as String: Data(value.utf8),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        var status = SecItemAdd(TestHostIsolation.keychainQuery(attrs) as CFDictionary, nil)
        if status != errSecSuccess {
            print("[SecretVault] iCloud 钥匙串写入失败 status=\(status)，退成只存本机")
            attrs[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            status = SecItemAdd(TestHostIsolation.keychainQuery(attrs) as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            print("[SecretVault] 写入失败 status=\(status)")
            return nil
        }
        return id
    }

    // MARK: - 取

    enum Lookup: Equatable {
        case found(label: String, value: String)
        /// 范围是别的对话
        case wrongScope(label: String)
        /// 这台设备上没有（删了 / 别的设备填的没同步过来）
        case missing
    }

    /// 范围不符不给真值。
    static func resolve(_ id: String, conversationId: String) -> Lookup {
        guard let entry = entry(id) else { return .missing }
        if let conv = entry.conversationId, conv != conversationId { return .wrongScope(label: entry.label) }
        guard let value = KeychainStore.get(account: id, service: service) else { return .missing }
        return .found(label: entry.label, value: value)
    }

    /// 单条元数据（只取属性）
    static func entry(_ id: String) -> Entry? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: kCFBooleanTrue!,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(TestHostIsolation.keychainQuery(query) as CFDictionary, &out) == errSecSuccess,
              let item = out as? [String: Any] else { return nil }
        return makeEntry(item)
    }

    /// 全部条目（本机 + iCloud），新的在前。只取属性。
    static func list() -> [Entry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue!,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(TestHostIsolation.keychainQuery(query) as CFDictionary, &out)
        guard status == errSecSuccess, let items = out as? [[String: Any]] else {
            if status != errSecItemNotFound { print("[SecretVault] list failed status=\(status)") }
            return []
        }
        return items.compactMap(makeEntry).sorted { $0.created > $1.created }
    }

    private static func makeEntry(_ item: [String: Any]) -> Entry? {
        guard let id = item[kSecAttrAccount as String] as? String else { return nil }
        let meta = (item[kSecAttrComment as String] as? String)
            .flatMap { try? JSONDecoder().decode(Meta.self, from: Data($0.utf8)) }
        let created = meta.map { Date(timeIntervalSince1970: $0.created) }
            ?? (item[kSecAttrCreationDate as String] as? Date) ?? .distantPast
        let conv = meta?.conv ?? allConversations
        return Entry(
            id: id,
            label: item[kSecAttrLabel as String] as? String ?? "",
            conversationId: conv == allConversations ? nil : conv,
            created: created,
            synced: (item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
        )
    }

    // MARK: - 删

    static func delete(_ id: String) {
        KeychainStore.remove(account: id, service: service)
    }

    /// 删对话时调：只删范围是这个对话的（「所有对话」的留着）
    static func deleteAll(conversationId: String) {
        for entry in list() where entry.conversationId == conversationId {
            delete(entry.id)
        }
    }

    // MARK: - 占位

    static func placeholder(_ id: String) -> String { "{{secret:\(id)}}" }

    private static let placeholderPattern = #"\{\{secret:(s-[0-9a-z]+)\}\}"#

    /// 文本里出现的加密值 id（去重，按出现顺序）
    static func ids(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: placeholderPattern) else { return [] }
        var seen: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let id = String(text[r])
            if !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    static func isPlaceholder(_ text: String) -> Bool {
        text.range(of: "^" + placeholderPattern + "$", options: .regularExpression) != nil
    }

    // MARK: - 换 / 擦（工具执行前后）

    /// 这次执行用到的一个值。**只活在执行那一刻的局部变量里**
    struct Use {
        let id: String
        let label: String
        let value: String
    }

    struct Substitution {
        /// 换好真值的参数 JSON（只给执行器，不落盘、不进 segs）
        var json: String
        var used: [Use]
        /// 找不到 / 范围不符的原因；非空 = 不该执行
        var problems: [String]
    }

    /// 把参数 JSON 里的占位换成真值（JSON 字符串转义后再塞，引号 / 反斜杠不会弄坏 JSON）。
    /// 找不到 / 范围不符的占位原样留着，原因进 problems。
    static func substitute(_ argumentsJSON: String, conversationId: String) -> Substitution {
        substitute(argumentsJSON) { resolve($0, conversationId: conversationId) }
    }

    static func substitute(_ argumentsJSON: String, lookup: (String) -> Lookup) -> Substitution {
        var out = Substitution(json: argumentsJSON, used: [], problems: [])
        for id in ids(in: argumentsJSON) {
            switch lookup(id) {
            case .found(let label, let value):
                out.json = out.json.replacingOccurrences(of: placeholder(id), with: jsonEscaped(value))
                out.used.append(Use(id: id, label: label, value: value))
            case .wrongScope(let label):
                out.problems.append("加密值【\(label)】只能在填它的对话里用")
            case .missing:
                out.problems.append("这台设备上没有这个加密值 \(placeholder(id))（可能已删除，或是在别的设备上填的）")
            }
        }
        return out
    }

    /// 擦得最短长度：太短的值（<4 字）擦了会误伤正常文字，不擦
    static let minScrubLength = 4

    /// 工具结果回 AI 前：真值（含 JSON 转义后的样子，MCP 报错会回显参数）→ 占位。变形后的（base64 / 截半）擦不到。
    static func scrub(_ text: String, used: [Use]) -> String {
        var t = text
        for use in used.sorted(by: { $0.value.count > $1.value.count }) where use.value.count >= minScrubLength {
            let ph = placeholder(use.id)
            t = t.replacingOccurrences(of: use.value, with: ph)
            let escaped = jsonEscaped(use.value)
            if escaped != use.value { t = t.replacingOccurrences(of: escaped, with: ph) }
        }
        return t
    }

    /// 字符串在 JSON 字符串字面量里的样子（不含两边引号）
    static func jsonEscaped(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: data, encoding: .utf8), text.count >= 4 else { return s }
        return String(text.dropFirst(2).dropLast(2))
    }
}
