import Foundation

/// 改外部 agent 配置文件（~/.claude/settings.json 这类 JSON / JSONC）的唯一入口（research-magpie 2.3）。
///
/// 为什么不用 `JSONSerialization` 整份重写：`.sortedKeys` 会打乱用户的 key 顺序、丢注释、改缩进，
/// 非原子写崩在半路会把用户配置写坏。这里在**文本层**按 key 路径定位值的字节区间，只替换/插入/删除那一段：
/// - 其余内容（key 顺序、缩进、注释、尾逗号）原样保留；
/// - 解析失败直接抛错，调用方不写文件；
/// - `update(fileAt:)`：内容没变不写；写走临时文件 + rename 的原子写，保留原权限、穿透软链。
///
/// 值的写法：`[String: Any]` 按 key 排序输出；要固定 key 顺序用 `OrderedObject`。
enum AgentConfigEditor {

    enum EditError: Error, Equatable {
        case notUTF8
        case invalidJSON
        case topLevelNotObject
        /// 路径上某一段已存在但类型不对（例如想往 `hooks.Stop` 追加，而 `hooks` 是个数字）——不硬改用户数据
        case pathConflict(String)
        case unsupportedValue
    }

    /// 保持 key 顺序的对象字面量。
    struct OrderedObject {
        var pairs: [(String, Any)]
        init(_ pairs: [(String, Any)]) { self.pairs = pairs }
    }

    // MARK: - 文本层 API

    /// 读 key 路径上的值（JSON null → `NSNull`，不存在 → nil）。
    static func value(at path: [String], in text: String) throws -> Any? {
        let doc = try Document(text)
        guard let node = doc.node(at: path) else { return nil }
        return try doc.decode(node)
    }

    /// 设置 key 路径上的值：已存在则只替换值那一段；不存在则追加到所在对象末尾（缺的父对象一并建）。
    static func setting(_ value: Any, at path: [String], in text: String) throws -> String {
        precondition(!path.isEmpty)
        let doc = try Document(text)
        var obj = doc.root
        for (i, key) in path.enumerated() {
            guard let member = obj.members.first(where: { $0.key == key }) else {
                return try doc.inserting(key: key, value: nest(Array(path[(i + 1)...]), value), into: obj)
            }
            if i == path.count - 1 {
                return try doc.replacing(member.value, with: value)
            }
            guard member.value.kind == .object else {
                throw EditError.pathConflict(path[...i].joined(separator: "."))
            }
            obj = member.value
        }
        return text // unreachable
    }

    /// 往 key 路径上的数组末尾追加一项；数组（及父对象）不存在就建。
    static func appending(_ item: Any, toArrayAt path: [String], in text: String) throws -> String {
        let doc = try Document(text)
        guard let node = try doc.resolve(path) else {
            return try setting([item], at: path, in: text)
        }
        guard node.kind == .array else { throw EditError.pathConflict(path.joined(separator: ".")) }
        return try doc.appending(item, to: node)
    }

    /// 删除 key 路径上的成员；不存在就原样返回。
    static func removing(at path: [String], in text: String) throws -> String {
        precondition(!path.isEmpty)
        let doc = try Document(text)
        guard let parent = try doc.resolve(Array(path.dropLast())), parent.kind == .object,
              let idx = parent.members.firstIndex(where: { $0.key == path.last! }) else { return text }
        let spans = parent.members.map { (start: $0.keyStart, end: $0.value.end) }
        return doc.removingElement(at: idx, spans: spans, in: parent)
    }

    /// 删除 key 路径上数组里满足条件的项；数组不存在就原样返回。
    static func removingItems(inArrayAt path: [String], in text: String, where match: (Any) throws -> Bool) throws -> String {
        var current = text
        while true {
            let doc = try Document(current)
            guard let node = try doc.resolve(path), node.kind == .array else { return current }
            var hit: Int?
            for (i, item) in node.items.enumerated().reversed() {
                if try match(doc.decode(item)) { hit = i; break }
            }
            guard let idx = hit else { return current }
            current = doc.removingElement(at: idx, spans: node.items.map { (start: $0.start, end: $0.end) }, in: node)
        }
    }

    // MARK: - 文件层

    /// 读 → 变换 → 有变化才原子写。文件不存在按 `{}` 起步（父目录一并建）。
    /// 解析/变换抛错时文件保持原样。返回是否真的写了。
    @discardableResult
    static func update(fileAt url: URL, _ transform: (String) throws -> String) throws -> Bool {
        let target = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        var original: String?
        if let data = fm.contents(atPath: target.path) {
            guard let s = String(data: data, encoding: .utf8) else { throw EditError.notUTF8 }
            original = s
        }
        let seed: String
        if let original, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            seed = original
        } else {
            seed = "{}\n"
        }
        let result = try transform(seed)
        if result == (original ?? seed) { return false }
        _ = try Document(result) // 写出去的必须仍是合法 JSON(C)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomic(Data(result.utf8), to: target)
        return true
    }

    /// 原子写（临时文件 + rename），保留目标已有的 POSIX 权限；新文件用 `newFilePermissions`。
    static func writeAtomic(_ data: Data, to url: URL, newFilePermissions: Int? = nil) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let perms = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int ?? newFilePermissions
        try data.write(to: target, options: .atomic)
        if let perms {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: target.path)
        }
    }

    // MARK: - 内部

    private static func nest(_ keys: [String], _ value: Any) -> Any {
        keys.reversed().reduce(value) { acc, key in OrderedObject([(key, acc)]) }
    }

    fileprivate static func render(_ value: Any, indent: String, unit: String, multiline: Bool) throws -> String {
        func pairsOf(_ v: Any) -> [(String, Any)]? {
            if let o = v as? OrderedObject { return o.pairs }
            if let d = v as? [String: Any] { return d.keys.sorted().map { ($0, d[$0]!) } }
            return nil
        }
        if let pairs = pairsOf(value) {
            if pairs.isEmpty { return "{}" }
            let inner = indent + unit
            let parts = try pairs.map { k, v in
                try scalar(k) + (multiline ? ": " : ":") + render(v, indent: inner, unit: unit, multiline: multiline)
            }
            return multiline
                ? "{\n" + parts.map { inner + $0 }.joined(separator: ",\n") + "\n" + indent + "}"
                : "{" + parts.joined(separator: ",") + "}"
        }
        if let arr = value as? [Any] {
            if arr.isEmpty { return "[]" }
            let inner = indent + unit
            let parts = try arr.map { try render($0, indent: inner, unit: unit, multiline: multiline) }
            return multiline
                ? "[\n" + parts.map { inner + $0 }.joined(separator: ",\n") + "\n" + indent + "]"
                : "[" + parts.joined(separator: ",") + "]"
        }
        return try scalar(value)
    }

    private static func scalar(_ value: Any) throws -> String {
        guard value is String || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { throw EditError.unsupportedValue }
        return s
    }
}

// MARK: - 文档模型：原文 + 去注释/尾逗号的等长副本 + 值的字节区间

private struct Node {
    enum Kind { case object, array, scalar }
    struct Member { let key: String; let keyStart: Int; let value: Node }
    let kind: Kind
    let start: Int
    let end: Int          // exclusive
    var members: [Member] = []
    var items: [Node] = []
}

private struct Document {
    let raw: [UInt8]
    /// 注释、尾逗号换成空格（换行保留）后的严格 JSON，与 raw 等长 → 下标一一对应
    let clean: [UInt8]
    let root: Node

    init(_ text: String) throws {
        raw = Array(text.utf8)
        clean = Document.blankJSONC(raw)
        guard (try? JSONSerialization.jsonObject(with: Data(clean), options: [.fragmentsAllowed])) != nil else {
            throw AgentConfigEditor.EditError.invalidJSON
        }
        var parser = SpanParser(b: clean)
        root = try parser.parseValue()
        guard root.kind == .object else { throw AgentConfigEditor.EditError.topLevelNotObject }
    }

    // MARK: 查找

    func node(at path: [String]) -> Node? {
        var cur = root
        for key in path {
            guard cur.kind == .object, let m = cur.members.first(where: { $0.key == key }) else { return nil }
            cur = m.value
        }
        return cur
    }

    /// 同 node(at:)，但中途遇到非对象时抛 pathConflict 而不是当作不存在。
    func resolve(_ path: [String]) throws -> Node? {
        var cur = root
        for (i, key) in path.enumerated() {
            guard cur.kind == .object else {
                throw AgentConfigEditor.EditError.pathConflict(path[..<i].joined(separator: "."))
            }
            guard let m = cur.members.first(where: { $0.key == key }) else { return nil }
            cur = m.value
        }
        return cur
    }

    func decode(_ node: Node) throws -> Any {
        let slice = Data(clean[node.start..<node.end])
        guard let v = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]) else {
            throw AgentConfigEditor.EditError.invalidJSON
        }
        return v
    }

    // MARK: 改写

    func replacing(_ node: Node, with value: Any) throws -> String {
        let rendered = try AgentConfigEditor.render(value, indent: lineIndent(node.start), unit: unit, multiline: multiline)
        return splice(node.start, node.end, rendered)
    }

    func inserting(key: String, value: Any, into obj: Node) throws -> String {
        let keyJSON = try AgentConfigEditor.render(key, indent: "", unit: unit, multiline: false)
        return try insertElement(into: obj, firstStart: obj.members.first?.keyStart, lastEnd: obj.members.last?.value.end) { indent, ml in
            keyJSON + (ml ? ": " : ":") + (try AgentConfigEditor.render(value, indent: indent, unit: unit, multiline: ml))
        }
    }

    func appending(_ item: Any, to arr: Node) throws -> String {
        try insertElement(into: arr, firstStart: arr.items.first?.start, lastEnd: arr.items.last?.end) { indent, ml in
            try AgentConfigEditor.render(item, indent: indent, unit: unit, multiline: ml)
        }
    }

    private func insertElement(into container: Node, firstStart: Int?, lastEnd: Int?,
                               make: (_ indent: String, _ multiline: Bool) throws -> String) throws -> String {
        let (open, close) = (container.start, container.end - 1)
        if let firstStart, let lastEnd {
            if isFirstOnLine(firstStart) {
                let child = lineIndent(firstStart)
                return splice(lastEnd, lastEnd, ",\n" + child + (try make(child, true)))
            }
            return splice(lastEnd, lastEnd, ", " + (try make(lineIndent(open), false)))
        }
        // 空容器：整段换掉（容器内若只有注释会随之丢弃）
        let openChar = String(UnicodeScalar(raw[open])), closeChar = String(UnicodeScalar(raw[close]))
        if multiline {
            let base = lineIndent(open), child = base + unit
            return splice(open, close + 1, openChar + "\n" + child + (try make(child, true)) + "\n" + base + closeChar)
        }
        return splice(open, close + 1, openChar + (try make("", false)) + closeChar)
    }

    /// 从容器里删掉第 idx 个元素（对象成员的 span 从 key 起算）。
    func removingElement(at idx: Int, spans: [(start: Int, end: Int)], in container: Node) -> String {
        let n = spans.count
        if n == 1 {
            return splice(container.start + 1, container.end - 1, "")
        }
        if idx < n - 1 {
            let s = spans[idx].start, next = spans[idx + 1].start
            if isFirstOnLine(s) && isFirstOnLine(next) {
                return splice(lineStart(s), lineStart(next), "")
            }
            return splice(s, next, "")
        }
        // 最后一个：连同前一项后面的逗号一起删
        return splice(spans[idx - 1].end, spans[idx].end, "")
    }

    // MARK: 排版推断

    /// 文件是否多行排版（决定空容器/整体替换时的写法）
    var multiline: Bool { raw.contains(0x0A) }

    /// 缩进单位：根对象第一个成员所在行的缩进；推不出来用两个空格
    var unit: String {
        if let first = root.members.first, isFirstOnLine(first.keyStart) {
            let ind = lineIndent(first.keyStart)
            let base = lineIndent(root.start)
            if ind.count > base.count, ind.hasPrefix(base) { return String(ind.dropFirst(base.count)) }
        }
        return "  "
    }

    func lineStart(_ pos: Int) -> Int {
        var i = pos
        while i > 0 && raw[i - 1] != 0x0A { i -= 1 }
        return i
    }

    func lineIndent(_ pos: Int) -> String {
        var i = lineStart(pos)
        var out = ""
        while i < raw.count, raw[i] == 0x20 || raw[i] == 0x09 {
            out.append(raw[i] == 0x20 ? " " : "\t")
            i += 1
        }
        return out
    }

    /// pos 之前本行只有空白（按 clean 判断，注释算空白）
    func isFirstOnLine(_ pos: Int) -> Bool {
        var i = pos
        while i > 0 && raw[i - 1] != 0x0A {
            let c = clean[i - 1]
            if c != 0x20 && c != 0x09 && c != 0x0D { return false }
            i -= 1
        }
        return true
    }

    func splice(_ from: Int, _ to: Int, _ with: String) -> String {
        var out = Array(raw[..<from])
        out.append(contentsOf: Array(with.utf8))
        out.append(contentsOf: raw[to...])
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: JSONC → 等长严格 JSON

    static func blankJSONC(_ b: [UInt8]) -> [UInt8] {
        var out = b
        var i = 0
        let n = b.count
        func blank(_ j: Int) { if out[j] != 0x0A && out[j] != 0x0D { out[j] = 0x20 } }
        while i < n {
            let c = b[i]
            if c == 0x22 { // 字符串
                i += 1
                while i < n && b[i] != 0x22 { i += b[i] == 0x5C ? 2 : 1 }
                i += 1
            } else if c == 0x2F, i + 1 < n, b[i + 1] == 0x2F { // //
                while i < n && b[i] != 0x0A { blank(i); i += 1 }
            } else if c == 0x2F, i + 1 < n, b[i + 1] == 0x2A { // /* */
                blank(i); blank(i + 1); i += 2
                while i < n && !(b[i] == 0x2A && i + 1 < n && b[i + 1] == 0x2F) { blank(i); i += 1 }
                if i < n { blank(i); blank(i + 1); i += 2 }
            } else {
                i += 1
            }
        }
        // 尾逗号：逗号后（跳过空白）紧跟 } 或 ]
        i = 0
        while i < n {
            let c = out[i]
            if c == 0x22 {
                i += 1
                while i < n && out[i] != 0x22 { i += out[i] == 0x5C ? 2 : 1 }
                i += 1
                continue
            }
            if c == 0x2C {
                var j = i + 1
                while j < n, out[j] == 0x20 || out[j] == 0x09 || out[j] == 0x0A || out[j] == 0x0D { j += 1 }
                if j < n, out[j] == 0x7D || out[j] == 0x5D { out[i] = 0x20 }
            }
            i += 1
        }
        return out
    }
}

/// 在（已验证合法的）严格 JSON 上记录每个值的字节区间。
private struct SpanParser {
    let b: [UInt8]
    var i = 0

    mutating func skipWS() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
    }

    mutating func expect(_ c: UInt8) throws {
        skipWS()
        guard i < b.count, b[i] == c else { throw AgentConfigEditor.EditError.invalidJSON }
        i += 1
    }

    mutating func skipString() throws {
        guard i < b.count, b[i] == 0x22 else { throw AgentConfigEditor.EditError.invalidJSON }
        i += 1
        while i < b.count && b[i] != 0x22 { i += b[i] == 0x5C ? 2 : 1 }
        guard i < b.count else { throw AgentConfigEditor.EditError.invalidJSON }
        i += 1
    }

    mutating func parseValue() throws -> Node {
        skipWS()
        guard i < b.count else { throw AgentConfigEditor.EditError.invalidJSON }
        let start = i
        switch b[i] {
        case 0x7B: // {
            i += 1
            var members: [Node.Member] = []
            skipWS()
            if i < b.count, b[i] == 0x7D { i += 1; return Node(kind: .object, start: start, end: i) }
            while true {
                skipWS()
                let keyStart = i
                try skipString()
                guard let key = (try? JSONSerialization.jsonObject(with: Data(b[keyStart..<i]), options: [.fragmentsAllowed])) as? String
                else { throw AgentConfigEditor.EditError.invalidJSON }
                try expect(0x3A)
                let value = try parseValue()
                members.append(.init(key: key, keyStart: keyStart, value: value))
                skipWS()
                guard i < b.count else { throw AgentConfigEditor.EditError.invalidJSON }
                if b[i] == 0x2C { i += 1; continue }
                try expect(0x7D)
                break
            }
            return Node(kind: .object, start: start, end: i, members: members)
        case 0x5B: // [
            i += 1
            var items: [Node] = []
            skipWS()
            if i < b.count, b[i] == 0x5D { i += 1; return Node(kind: .array, start: start, end: i) }
            while true {
                items.append(try parseValue())
                skipWS()
                guard i < b.count else { throw AgentConfigEditor.EditError.invalidJSON }
                if b[i] == 0x2C { i += 1; continue }
                try expect(0x5D)
                break
            }
            return Node(kind: .array, start: start, end: i, items: items)
        case 0x22:
            try skipString()
            return Node(kind: .scalar, start: start, end: i)
        default:
            while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
            return Node(kind: .scalar, start: start, end: i)
        }
    }
}
