import Foundation

/// 卡内 character_book 与独立 World Info 的字段不是同一种方言。
enum WorldBookCodec {
    struct Issue: Equatable {
        let entryIndex: Int
        let field: String
    }

    struct Report {
        let name: String?
        let entries: [WorldBookEntry]
        let rawJSONData: Data
        let issues: [Issue]

        var unsupportedEntryCount: Int { Set(issues.map(\.entryIndex)).count }
        var summary: String {
            unsupportedEntryCount == 0
                ? "导入 \(entries.count) 条"
                : "导入 \(entries.count) 条；\(unsupportedEntryCount) 条用了还不支持的设置（冷却、分组、递归等），这些设置已保留但不生效"
        }
    }

    enum DecodeError: LocalizedError {
        case invalidBook
        case negativeDepth(Int, String)
        case invalidProbability(Int)

        var errorDescription: String? {
            switch self {
            case .invalidBook: return "无效的世界书 JSON"
            case .negativeDepth(let index, let field): return "世界书第 \(index + 1) 条的 \(field) 不能为负数"
            case .invalidProbability(let index): return "世界书第 \(index + 1) 条的概率必须在 0…100 之间"
            }
        }
    }

    static func decodeCharacterBook(_ data: Data) throws -> Report {
        let root = try object(data)
        let inner = root["data"] as? [String: Any] ?? root
        if let book = inner["character_book"] as? [String: Any] ?? root["character_book"] as? [String: Any] {
            let bookData = try JSONSerialization.data(withJSONObject: book, options: [.sortedKeys])
            return try decode(book, raw: bookData, characterBook: true)
        }
        return try decode(root, raw: data, characterBook: true)
    }

    static func decodeWorldInfo(_ data: Data) throws -> Report {
        try decode(object(data), raw: data, characterBook: false)
    }

    /// 文件入口按结构分流；卡内调用方直接指定 decodeCharacterBook。
    static func decodeImport(_ data: Data) throws -> Report {
        let root = try object(data)
        let inner = root["data"] as? [String: Any] ?? root
        if inner["character_book"] != nil || root["character_book"] != nil {
            return try decodeCharacterBook(data)
        }
        let entries = try entryObjects(root)
        if entries.contains(where: { $0["key"] != nil || $0["uid"] != nil }) {
            return try decodeWorldInfo(data)
        }
        if entries.contains(where: { $0["keys"] != nil || $0["insertion_order"] != nil || $0["enabled"] != nil }) {
            return try decodeCharacterBook(data)
        }
        return try decodeWorldInfo(data)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.invalidBook
        }
        return result
    }

    private static func entryObjects(_ book: [String: Any]) throws -> [[String: Any]] {
        if let entries = book["entries"] as? [[String: Any]] { return entries }
        if let entries = book["entries"] as? [String: [String: Any]] {
            return entries.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map(\.value)
        }
        throw DecodeError.invalidBook
    }

    private static func decode(_ book: [String: Any], raw: Data, characterBook: Bool) throws -> Report {
        var issues: [Issue] = []
        let entries = try entryObjects(book).enumerated().map { index, dict -> WorldBookEntry in
            var entry = WorldBookEntry()
            entry.rawJSONData = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            let ext = dict["extensions"] as? [String: Any] ?? [:]
            let settings = characterBook ? ext : dict
            entry.keys = dict[characterBook ? "keys" : "key"] as? [String] ?? []
            entry.secondaryKeys = dict[characterBook ? "secondary_keys" : "keysecondary"] as? [String] ?? []
            entry.isEnabled = characterBook ? (dict["enabled"] as? Bool ?? true) : !(dict["disable"] as? Bool ?? false)
            entry.insertionOrder = dict[characterBook ? "insertion_order" : "order"] as? Int ?? 100
            entry.comment = dict["comment"] as? String ?? ""
            entry.content = dict["content"] as? String ?? ""
            entry.isConstant = dict["constant"] as? Bool ?? false
            entry.selectiveEnabled = dict["selective"] as? Bool
            entry.depth = settings["depth"] as? Int
            entry.scanDepth = settings[characterBook ? "scan_depth" : "scanDepth"] as? Int
            for (field, value) in [("depth", entry.depth), ("scanDepth", entry.scanDepth)] {
                if let value, value < 0 { throw DecodeError.negativeDepth(index, field) }
            }
            entry.probability = settings["probability"] as? Int ?? 100
            guard (0...100).contains(entry.probability) else { throw DecodeError.invalidProbability(index) }
            entry.useProbability = settings["useProbability"] as? Bool
            entry.matchWholeWords = settings[characterBook ? "match_whole_words" : "matchWholeWords"] as? Bool ?? false
            entry.caseSensitive = settings[characterBook ? "case_sensitive" : "caseSensitive"] as? Bool ?? false
            if let logic = settings["selectiveLogic"] as? Int {
                if let supported = WorldBookEntry.SelectiveLogic(rawValue: logic) { entry.selectiveLogic = supported }
                else { issues.append(Issue(entryIndex: index, field: "selectiveLogic")) }
            }

            // 有 extensions.position 就不回退，未知值也要保留并禁止注入。
            let position = characterBook ? (ext["position"] ?? dict["position"]) : dict["position"]
            if let position {
                if let number = position as? Int, let supported = WorldBookEntry.InsertionPosition(rawValue: number), supported != .unsupported {
                    entry.position = supported
                } else if characterBook, ext["position"] == nil, let string = position as? String,
                          string == "before_char" || string == "after_char" {
                    entry.position = string == "before_char" ? .beforeCharDef : .afterCharDef
                } else {
                    entry.position = .unsupported
                    issues.append(Issue(entryIndex: index, field: characterBook && ext["position"] != nil ? "extensions.position" : "position"))
                }
            }

            // 未实现的递归、组、冷却等只存原文；报告按条目去重计数。
            let common: Set<String> = ["id", "uid", "comment", "content", "constant", "selective", "position", "extensions", "displayIndex"]
            let mapped: Set<String> = characterBook
                ? ["keys", "secondary_keys", "enabled", "insertion_order"]
                : ["key", "keysecondary", "disable", "order", "depth", "scanDepth", "selectiveLogic", "probability", "useProbability", "matchWholeWords", "caseSensitive"]
            // 酒馆每条都带全套字段（cooldown / group / sticky…），多数是默认值：只有真用上了才算不支持
            for key in dict.keys.sorted() where !common.union(mapped).contains(key) && !uiOnly.contains(key) && isActive(dict[key], key: key) {
                issues.append(Issue(entryIndex: index, field: key))
            }
            // 独立世界书的 extensions 只是顶层字段的镜像，以顶层为准，不重复报
            let supportedExtensions: Set<String> = ["position", "depth", "scan_depth", "selectiveLogic", "probability", "useProbability",
                                                    "match_whole_words", "case_sensitive", "display_index"]
            for key in ext.keys.sorted() where characterBook && !supportedExtensions.contains(key) && !uiOnly.contains(key) && isActive(ext[key], key: key) {
                issues.append(Issue(entryIndex: index, field: "extensions.\(key)"))
            }
            return entry
        }
        return Report(name: book["name"] as? String, entries: entries, rawJSONData: raw, issues: issues)
    }

    // MARK: - 导出（⑥ 单书 JSON）

    /// 没改过（书名、条数、顺序、每条受支持字段都和原文一致）= 原字节；改过 = 在原文上只覆盖改过的受支持字段，
    /// 未知字段 / 子树原样留，删掉的条目不写、新条目按原方言补齐。没有原文的书按独立世界书（酒馆 World Info）写。
    static func encodeExport(name: String, entries: [WorldBookEntry], rawJSONData: Data?) throws -> Data {
        let rawBook = try rawJSONData.map { try object($0) }
        let characterBook = rawBook.map(isCharacterBookDialect) ?? false
        let rawEntries = rawBook.flatMap { try? entryObjects($0) }
        if let rawJSONData, let rawBook, let rawEntries,
           (rawBook["name"] as? String).map({ $0 == name }) ?? true,
           rawEntries.count == entries.count,
           zip(entries, rawEntries).allSatisfy({ entry, dict in
               entry.rawJSONData == canonical(dict) && !changed(entry, from: dict, characterBook: characterBook)
           }) {
            return rawJSONData
        }
        var book = rawBook ?? [:]
        book["name"] = name
        var nextUid = (rawEntries ?? []).compactMap { $0["uid"] as? Int }.max().map { $0 + 1 } ?? 0
        let objects = entries.enumerated().map { index, entry -> [String: Any] in
            var dict = entry.rawJSONData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            overlay(entry, onto: &dict, characterBook: characterBook)
            if characterBook, dict["id"] == nil { dict["id"] = index }
            if !characterBook, dict["uid"] == nil { dict["uid"] = nextUid; nextUid += 1 }
            return dict
        }
        book["entries"] = characterBook
            ? objects as Any
            : Dictionary(uniqueKeysWithValues: objects.enumerated().map { (String($0.offset), $0.element) }) as Any
        return try JSONSerialization.data(withJSONObject: book, options: [.prettyPrinted, .sortedKeys])
    }

    /// 与 decodeImport 同口径判方言：条目带 key / uid = 独立世界书；带 keys / insertion_order / enabled = 卡内书
    private static func isCharacterBookDialect(_ book: [String: Any]) -> Bool {
        guard let entries = book["entries"] as? [[String: Any]] else { return false }
        if entries.contains(where: { $0["key"] != nil || $0["uid"] != nil }) { return false }
        return entries.contains { $0["keys"] != nil || $0["insertion_order"] != nil || $0["enabled"] != nil }
    }

    private static func canonical(_ dict: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    private static func decodeEntry(_ dict: [String: Any], characterBook: Bool) -> WorldBookEntry? {
        try? decode(["entries": [dict]], raw: Data(), characterBook: characterBook).entries.first
    }

    private static func changed(_ entry: WorldBookEntry, from dict: [String: Any], characterBook: Bool) -> Bool {
        guard let base = decodeEntry(dict, characterBook: characterBook) else { return true }
        var a = entry, b = base
        a.id = b.id
        a.rawJSONData = nil
        b.rawJSONData = nil
        return a != b
    }

    /// 只写和原文解出来不一样的受支持字段；没有原文的条目全写
    private static func overlay(_ entry: WorldBookEntry, onto dict: inout [String: Any], characterBook: Bool) {
        let base = dict.isEmpty ? nil : decodeEntry(dict, characterBook: characterBook)
        func differs<T: Equatable>(_ path: KeyPath<WorldBookEntry, T>) -> Bool {
            base.map { $0[keyPath: path] != entry[keyPath: path] } ?? true
        }
        func put(_ key: String, _ value: Any?, into target: inout [String: Any]) {
            target[key] = value ?? NSNull()
        }
        var ext = dict["extensions"] as? [String: Any] ?? [:]
        let hadExtensions = dict["extensions"] != nil
        if differs(\.comment) { dict["comment"] = entry.comment }
        if differs(\.content) { dict["content"] = entry.content }
        if differs(\.isConstant) { dict["constant"] = entry.isConstant }
        if differs(\.selectiveEnabled) { put("selective", entry.selectiveEnabled, into: &dict) }
        if characterBook {
            if differs(\.keys) { dict["keys"] = entry.keys }
            if differs(\.secondaryKeys) { dict["secondary_keys"] = entry.secondaryKeys }
            if differs(\.isEnabled) { dict["enabled"] = entry.isEnabled }
            if differs(\.insertionOrder) { dict["insertion_order"] = entry.insertionOrder }
        } else {
            if differs(\.keys) { dict["key"] = entry.keys }
            if differs(\.secondaryKeys) { dict["keysecondary"] = entry.secondaryKeys }
            if differs(\.isEnabled) { dict["disable"] = !entry.isEnabled }
            if differs(\.insertionOrder) { dict["order"] = entry.insertionOrder }
        }
        // 卡内书这几项在 extensions 里，独立世界书在顶层
        var settings = characterBook ? ext : dict
        if differs(\.position), entry.position != .unsupported { settings["position"] = entry.position.rawValue }
        if differs(\.depth) { if let depth = entry.depth { settings["depth"] = depth } else { settings.removeValue(forKey: "depth") } }
        if differs(\.scanDepth) { put(characterBook ? "scan_depth" : "scanDepth", entry.scanDepth, into: &settings) }
        if differs(\.selectiveLogic) { settings["selectiveLogic"] = entry.selectiveLogic.rawValue }
        if differs(\.probability) { settings["probability"] = entry.probability }
        if differs(\.useProbability) { put("useProbability", entry.useProbability, into: &settings) }
        if differs(\.matchWholeWords) { settings[characterBook ? "match_whole_words" : "matchWholeWords"] = entry.matchWholeWords }
        if differs(\.caseSensitive) { settings[characterBook ? "case_sensitive" : "caseSensitive"] = entry.caseSensitive }
        if characterBook {
            ext = settings
            if hadExtensions || !ext.isEmpty { dict["extensions"] = ext }
        } else {
            dict = settings
        }
    }

    /// 不影响我们注入结果的：酒馆编辑器界面状态；「不参与递归」——我们本来就不递归，效果一样
    private static let uiOnly: Set<String> = ["addMemo", "automationId", "vectorized",
                                              "preventRecursion", "excludeRecursion", "prevent_recursion", "exclude_recursion"]

    /// 字段是不是真的开着（不是默认值）：true、非零数、非空字符串 / 数组、里面有开着的对象；分组权重默认 100
    private static func isActive(_ value: Any?, key: String) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let n as NSNumber where key == "groupWeight" || key == "group_weight": return n.intValue != 100
        case let b as Bool: return b
        case let n as NSNumber: return n.doubleValue != 0
        case let s as String: return !s.isEmpty
        case let a as [Any]: return !a.isEmpty
        case let d as [String: Any]: return d.contains { isActive($0.value, key: $0.key) }
        default: return true
        }
    }
}
