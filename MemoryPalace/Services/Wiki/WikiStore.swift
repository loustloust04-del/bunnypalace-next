import Foundation
import CryptoKit

/// C 档案 wiki 的一页（plan-memory-c3-catalog 2.1）：frontmatter（类 / 触发词 / 钩子）+ 标题 + 现在 / 记录 / 连到
struct WikiPage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case user = "用户", person = "人", thing = "物", place = "地点", time = "时间", event = "事", project = "项目", topic = "主题"
    }

    enum Relation: String, Codable, CaseIterable, Sendable {
        case supplement = "补充", contradiction = "矛盾", resonance = "共鸣", citation = "引用"
    }

    struct Link: Codable, Equatable, Sendable {
        var target: String
        var relation: Relation
        var why: String
    }

    /// 相对 wiki 根，不带 .md，第一段是「工程」或「楼层」
    var path: String
    var kind: Kind?
    var triggers: [String] = []
    var hook: String = ""
    var title: String
    var now: String = ""
    /// 「现在」段该复核的日子（YYYY-MM-DD）：写新「现在」时从正文里写明的「到 日子」推；旧页 nil，不猜、不回填
    var validUntil: String? = nil
    /// 一行一条，不带前面的「- 」
    var records: [String] = []
    var links: [Link] = []
    /// 认不出的原样留着，重写时放回：frontmatter 里别的键、第一段 `##` 前的正文、「连到」里别的行、别的 `## 段`
    var extra: Extra?

    struct Extra: Codable, Equatable, Sendable {
        struct Section: Codable, Equatable, Sendable {
            var heading: String
            var body: String
        }
        /// 原行（含挂在下面的 `- 项`）
        var meta: [String] = []
        var linkLines: [String] = []
        /// 原顺序，渲染时放在「连到」后面
        var sections: [Section] = []
        /// 标题、钩子以外，第一段 `##` 前的正文（备注、段落、代码围栏），渲染时放回标题和钩子后面
        var preamble: String? = nil

        var isEmpty: Bool { meta.isEmpty && linkLines.isEmpty && sections.isEmpty && (preamble ?? "").isEmpty }
    }
}

// MARK: - md

extension WikiPage {
    var markdown: String {
        var out = "---\n"
        if let kind { out += "类: \(kind.rawValue)\n" }
        out += "触发词: [\(triggers.joined(separator: ", "))]\n"
        out += "钩子: \(hook)\n"
        if let validUntil { out += "\(Self.validUntilKey): \(validUntil)\n" }
        out += (extra?.meta ?? []).map { line in
            // 有了生效的期限，手写的认不出的「有效到」改个键名留着，不再参与解析（不然后写的那个会盖掉生效的）
            guard validUntil != nil, Self.metaKey(line) == Self.validUntilKey, let sep = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return line + "\n" }
            return Self.replacedUntilKey + line[sep...] + "\n"
        }.joined()
        out += "---\n"
        out += "# \(title)\n"
        out += "> 钩子：\(hook)\n\n"
        if let preamble = extra?.preamble, !preamble.isEmpty { out += preamble + "\n\n" }
        out += "## 现在\n"
        if !now.isEmpty { out += now + "\n" }
        out += "\n## 记录\n"
        out += records.map { "- \($0)\n" }.joined()
        out += "\n## 连到\n"
        out += links.map { "- [[\($0.target)]] · \($0.relation.rawValue)" + ($0.why.isEmpty ? "" : " · \($0.why)") + "\n" }.joined()
        out += (extra?.linkLines ?? []).map { $0 + "\n" }.joined()
        for section in extra?.sections ?? [] {
            out += "\n## \(section.heading)\n"
            if !section.body.isEmpty { out += section.body + "\n" }
        }
        return out
    }

    static let knownMetaKeys: Set<String> = ["类", "触发词", "钩子"]
    static let knownSections: Set<String> = ["现在", "记录", "连到"]
    static let validUntilKey = "有效到"
    /// 被新期限替换掉的手写原文换成这个键名留着（不参与解析）
    static let replacedUntilKey = "有效到（原写法，已换）"

    private static let untilPattern = try! NSRegularExpression(pattern: #"到\s*(\d{4}-\d{2}-\d{2})"#)

    /// 「现在」里写明的到期日（「到 YYYY-MM-DD」）
    static func untilDates(in now: String) -> [String] {
        let ns = now as NSString
        return untilPattern.matches(in: now, range: NSRange(location: 0, length: ns.length))
            .compactMap { FragmentPool.validDay(ns.substring(with: $0.range(at: 1))) }
    }

    /// 页上的期限一律从「现在」推：preferred（写手给的 / 原来的）是正文里写着的到期日就用它，不然取正文里最早的到期日；正文没写到期日 = nil
    static func until(_ preferred: String?, in now: String) -> String? {
        let dates = untilDates(in: now)
        if let day = FragmentPool.validDay(preferred), dates.contains(day) { return day }
        return dates.min()
    }

    static func metaKey(_ line: String) -> String? {
        line.firstIndex(where: { $0 == ":" || $0 == "：" }).map { line[..<$0].trimmingCharacters(in: .whitespaces) }
    }

    /// 宽容读：缺 frontmatter / 缺段当空，标题缺了用文件名，钩子 frontmatter 没有就看「> 钩子：」那行；
    /// 认不出的（别的键 / 连到里别的行 / 别的段）进 `extra` 原样留着
    static func parse(_ text: String, path: String) -> WikiPage {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var extra = Extra(meta: unknownMetaLines(lines))
        let meta = frontmatter(&lines)

        var title: String?
        var bodyHook: String?
        var section: String?
        var sections: [String: [String]] = [:]
        var others: [(heading: String, lines: [String])] = []
        var preamble: [String] = []
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let fenceLine = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if inFence || fenceLine {
                if fenceLine { inFence.toggle() }
                if let section {
                    if knownSections.contains(section) { sections[section, default: []].append(line) } else { others[others.count - 1].lines.append(line) }
                } else {
                    preamble.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("## ") {
                let name = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                section = name
                if !knownSections.contains(name) { others.append((name, [])) }
                continue
            }
            if let section, !knownSections.contains(section) {
                others[others.count - 1].lines.append(line)
                continue
            }
            if section == nil {
                if title == nil, trimmed.hasPrefix("# ") {
                    title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if bodyHook == nil, trimmed.hasPrefix(">") {
                    let quote = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    if let prefix = ["钩子：", "钩子:"].first(where: { quote.hasPrefix($0) }) {
                        bodyHook = String(quote.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                        continue
                    }
                }
                preamble.append(line)
                continue
            }
            if let section { sections[section, default: []].append(line) }
        }

        let until = FragmentPool.validDay(meta[validUntilKey])
        if until != nil {
            extra.meta.removeAll { line in
                guard metaKey(line) == validUntilKey, let sep = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
                return FragmentPool.validDay(String(line[line.index(after: sep)...])) == until
            }
        }
        let kindToken = meta["类"]?.split(whereSeparator: { $0 == " " || $0 == "#" }).first.map(String.init)
        let metaHook = meta["钩子"] ?? ""
        let records = (sections["记录"] ?? []).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            for bullet in ["- ", "* "] where t.hasPrefix(bullet) {
                return String(t.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            }
            return t
        }
        var links: [Link] = []
        for line in sections["连到"] ?? [] {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let link = parseLink(t) { links.append(link) } else { extra.linkLines.append(t) }
        }
        extra.sections = others.map { Extra.Section(heading: $0.heading, body: $0.lines.joined(separator: "\n").trimmingCharacters(in: .newlines)) }
        let pre = preamble.joined(separator: "\n").trimmingCharacters(in: .newlines)
        extra.preamble = pre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pre
        return WikiPage(
            path: path,
            kind: kindToken.flatMap(Kind.init(rawValue:)),
            triggers: list(meta["触发词"] ?? ""),
            hook: metaHook.isEmpty ? (bodyHook ?? "") : metaHook,
            title: (title?.isEmpty == false ? title : nil) ?? String(path.split(separator: "/").last ?? ""),
            now: (sections["现在"] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            validUntil: until,
            records: records,
            links: links,
            extra: extra.isEmpty ? nil : extra
        )
    }

    /// frontmatter 里不是类 / 触发词 / 钩子的键：原行照抄，连同挂在它下面的行
    static func unknownMetaLines(_ lines: [String]) -> [String] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { return [] }
        var out: [String] = []
        var inUnknown = false
        for line in lines[1..<end] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.hasPrefix("- "), let sep = t.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                inUnknown = !knownMetaKeys.contains(t[..<sep].trimmingCharacters(in: .whitespaces))
                if inUnknown { out.append(line) }
            } else if inUnknown, !t.isEmpty {
                out.append(line)
            }
        }
        return out
    }

    /// 开头 `---` 到下一个 `---` 之间的 `键: 值`（全角冒号也认；`- 项` 接在空值的键后面当列表）；读完从 lines 里去掉
    static func frontmatter(_ lines: inout [String]) -> [String: String] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { return [:] }
        var meta: [String: String] = [:]
        var lastKey: String?
        var items: [String] = []
        func flushList() {
            if let lastKey, !items.isEmpty { meta[lastKey] = "[" + items.joined(separator: ", ") + "]" }
            items = []
        }
        for line in lines[1..<end] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- "), lastKey != nil, meta[lastKey!]?.isEmpty == true {
                items.append(String(t.dropFirst(2)))
                continue
            }
            guard let sep = t.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            flushList()
            let key = t[..<sep].trimmingCharacters(in: .whitespaces)
            meta[key] = t[t.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            lastKey = key
        }
        flushList()
        lines = Array(lines[(end + 1)...])
        return meta
    }

    static func list(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))) }
            .filter { !$0.isEmpty }
    }

    /// `- [[楼层/地点/五楼出租屋]] · 补充 · 一起住过`
    static func parseLink(_ line: String) -> Link? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }
        guard t.hasPrefix("[["), let close = t.range(of: "]]") else { return nil }
        let target = String(t[t.index(t.startIndex, offsetBy: 2)..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        let parts = t[close.upperBound...].components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .drop(while: \.isEmpty)
        guard !target.isEmpty, let first = parts.first, let relation = Relation(rawValue: first) else { return nil }
        return Link(target: target, relation: relation, why: parts.dropFirst().joined(separator: " · "))
    }
}

// MARK: - 存储

/// 楼层 `memory/wiki/`：页读写、「现在」历史快照 / 恢复、「记录」只追加、不触发的词。
/// 全是同步文件 IO，调用方放后台；写一律原子写（临时文件再替换）
struct WikiStore: Sendable {
    let root: URL

    static let branches = ["工程", "楼层"]
    static let indexFileName = "INDEX.md"
    static let groupFileName = ".group.md"
    static let historyFolder = ".history"
    static let proposalsFolder = ".proposals"
    static let stopWordsFileName = "不触发的词.txt"

    enum WikiError: Error, Equatable {
        case invalidPath(String)
        /// 新「记录」不是旧「记录」原样 + 往后加
        case recordsNotAppendOnly(String)
        case notFound(String)
    }

    struct HistoryEntry: Equatable, Sendable {
        /// 文件名（`yyyyMMdd-HHmmss.md`，同秒的 `-2` `-3`…）
        let name: String
        let date: Date?
    }

    init(root: URL) {
        self.root = root
    }

    init(profileId: String) {
        root = FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent("wiki", isDirectory: true)
    }

    // MARK: 路径

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    private static func validSegments(_ parts: [String]) -> Bool {
        parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && $0.trimmingCharacters(in: .whitespaces) == $0 }
            && branches.contains(parts[0])
    }

    static func isValidPagePath(_ path: String) -> Bool {
        let parts = components(path)
        guard parts.count >= 2, validSegments(parts), let last = parts.last else { return false }
        return last != "INDEX" && !last.lowercased().hasSuffix(".md")
    }

    /// 分组文件夹（含两支本身）
    static func isValidFolderPath(_ path: String) -> Bool {
        validSegments(components(path))
    }

    func pageURL(_ path: String) throws -> URL {
        guard Self.isValidPagePath(path) else { throw WikiError.invalidPath(path) }
        return root.appendingPathComponent(path + ".md")
    }

    func folderURL(_ path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
    }

    func historyURL(_ path: String) -> URL {
        root.appendingPathComponent(Self.historyFolder, isDirectory: true).appendingPathComponent(path, isDirectory: true)
    }

    func pageExists(_ path: String) -> Bool {
        guard let url = try? pageURL(path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func folderExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folderURL(path).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 全部页（或某个文件夹下的），相对路径不带 .md；隐藏的（.history / .proposals / .group.md）和 INDEX.md 不算
    func pagePaths(under folder: String = "") -> [String] {
        let base = folderURL(folder)
        guard let en = FileManager.default.enumerator(atPath: base.path) else { return [] }
        var out: [String] = []
        while let rel = en.nextObject() as? String {
            if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                if (en.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory { en.skipDescendants() }
                continue
            }
            guard rel.hasSuffix(".md"), (rel as NSString).lastPathComponent != Self.indexFileName else { continue }
            let path = (folder.isEmpty ? "" : folder + "/") + String(rel.dropLast(3))
            if Self.isValidPagePath(path) { out.append(path) }
        }
        return out.sorted()
    }

    // MARK: 读

    static func version(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 页版本 = 文件内容 sha256；页不存在 = nil
    func version(of path: String) -> String? {
        guard let url = try? pageURL(path), let data = try? Data(contentsOf: url) else { return nil }
        return Self.version(of: data)
    }

    func readRaw(_ path: String) -> String? {
        readVersioned(path)?.text
    }

    /// 原文和它的版本出自同一次读（C3 拿它当提案的基线）
    func readVersioned(_ path: String) -> (text: String, version: String)? {
        guard let url = try? pageURL(path), let data = try? Data(contentsOf: url) else { return nil }
        return (String(decoding: data, as: UTF8.self), Self.version(of: data))
    }

    /// 这一刻全部页的版本（C3 动笔前拍一次，没读全文的页提案用它当基线）
    func versionSnapshot() -> [String: String] {
        var out: [String: String] = [:]
        for path in pagePaths() { out[path] = version(of: path) }
        return out
    }

    func read(_ path: String) -> WikiPage? {
        readRaw(path).map { WikiPage.parse($0, path: path) }
    }

    // MARK: 写

    /// 提案落盘：「记录」只能在旧的后面追加。返回新版本
    @discardableResult
    func save(_ page: WikiPage, now: Date = Date()) throws -> String {
        if let old = read(page.path), !page.records.starts(with: old.records) {
            throw WikiError.recordsNotAppendOnly(page.path)
        }
        return try saveRaw(page.markdown, path: page.path, now: now)
    }

    /// 编辑器（她在文件库手改）：不校验「记录」；覆盖前照样存一版历史。返回新版本
    @discardableResult
    func saveRaw(_ text: String, path: String, now: Date = Date()) throws -> String {
        let url = try pageURL(path)
        let data = Data(text.utf8)
        if let old = try? Data(contentsOf: url) {
            if old == data { return Self.version(of: data) }
            try snapshot(old, path: path, now: now)
        }
        try Self.writeAtomic(data, to: url)
        return Self.version(of: data)
    }

    static func writeAtomic(_ data: Data, to url: URL) throws {
        let name = url.lastPathComponent
        let parts = url.standardizedFileURL.pathComponents
        let isInternal = parts.contains(historyFolder) || parts.contains(proposalsFolder) || name == groupFileName
        let isPage = parts.lastIndex(where: branches.contains).map {
            name.hasSuffix(".md") && isValidPagePath(String(parts[$0...].joined(separator: "/").dropLast(3)))
        } ?? false
        let affectsInjection = !isInternal && (name == indexFileName || name == stopWordsFileName || isPage)
        let changedInjection = affectsInjection && (try? Data(contentsOf: url)) != data
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if changedInjection { WikiInjectionCache.shared.invalidate() }
    }

    // MARK: 历史

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func snapshot(_ data: Data, path: String, now: Date) throws {
        let dir = historyURL(path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: now)
        var name = stamp + ".md"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(stamp)-\(n).md"
            n += 1
        }
        try Self.writeAtomic(data, to: dir.appendingPathComponent(name))
    }

    private static func sortKey(_ name: String) -> (String, Int) {
        let parts = name.dropLast(3).split(separator: "-")
        let stamp = parts.prefix(2).joined(separator: "-")
        return (stamp, parts.count > 2 ? Int(parts[2]) ?? 1 : 1)
    }

    /// 新→旧
    func history(_ path: String) -> [HistoryEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: historyURL(path).path)) ?? []
        return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .sorted { Self.sortKey($0) > Self.sortKey($1) }
            .map { HistoryEntry(name: $0, date: Self.stampFormatter.date(from: Self.sortKey($0).0)) }
    }

    func historyText(_ path: String, entry: String) -> String? {
        guard !entry.contains("/"), let data = try? Data(contentsOf: historyURL(path).appendingPathComponent(entry)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 按某一版恢复：恢复前当前版也存一版。返回新版本
    @discardableResult
    func restore(_ path: String, entry: String, now: Date = Date()) throws -> String {
        guard let text = historyText(path, entry: entry) else { throw WikiError.notFound(entry) }
        return try saveRaw(text, path: path, now: now)
    }

    // MARK: 不触发的词

    var stopWordsURL: URL { root.appendingPathComponent(Self.stopWordsFileName) }

    static func normalizedWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func stopWords() -> [String] {
        guard let data = try? Data(contentsOf: stopWordsURL) else { return [] }
        return Self.normalizedWords(String(decoding: data, as: UTF8.self).components(separatedBy: .newlines))
    }

    func setStopWords(_ words: [String]) throws {
        let list = Self.normalizedWords(words)
        try Self.writeAtomic(Data((list.isEmpty ? "" : list.joined(separator: "\n") + "\n").utf8), to: stopWordsURL)
    }
}
