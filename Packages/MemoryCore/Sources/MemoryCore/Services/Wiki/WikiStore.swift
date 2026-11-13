import Foundation
import CryptoKit

/// C 档案 wiki 的一页（plan-memory-c3-catalog 2.1）：frontmatter（类 / 触发词 / 钩子）+ 标题 + 现在 / 记录 / 连到
public struct WikiPage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case user = "用户", person = "人", thing = "物", place = "地点", time = "时间", event = "事", project = "项目", topic = "主题"
    }

    public enum Relation: String, Codable, CaseIterable, Sendable {
        case supplement = "补充", contradiction = "矛盾", resonance = "共鸣", citation = "引用"
    }

    public struct Link: Codable, Equatable, Sendable {
        public var target: String
        public var relation: Relation
        public var why: String

        public init(target: String, relation: Relation, why: String) {
            self.target = target
            self.relation = relation
            self.why = why
        }
    }

    /// 相对 wiki 根，不带 .md，第一段是 9 个组之一（`WikiStore.branches`）
    public var path: String
    public var kind: Kind?
    public var triggers: [String] = []
    public var hook: String = ""
    public var title: String
    public var now: String = ""
    /// 「现在」段该复核的日子（YYYY-MM-DD）：写新「现在」时从正文里写明的「到 日子」推；旧页 nil，不猜、不回填
    public var validUntil: String? = nil
    /// 一行一条，不带前面的「- 」
    public var records: [String] = []
    /// 种子记录对应的条目库引用（path|version）；旧页没有此字段，不回填猜测版本。
    public var entries: [String]? = nil
    public var links: [Link] = []
    /// 认不出的原样留着，重写时放回：frontmatter 里别的键、第一段 `##` 前的正文、「连到」里别的行、别的 `## 段`
    public var extra: Extra?
    public var factDomain: SeedFactDomain? = nil

    public struct Extra: Codable, Equatable, Sendable {
        public struct Section: Codable, Equatable, Sendable {
            public var heading: String
            public var body: String

            public init(heading: String, body: String) {
                self.heading = heading
                self.body = body
            }
        }
        /// 原行（含挂在下面的 `- 项`）
        public var meta: [String] = []
        public var linkLines: [String] = []
        /// 原顺序，渲染时放在「连到」后面
        public var sections: [Section] = []
        /// 标题、钩子以外，第一段 `##` 前的正文（备注、段落、代码围栏），渲染时放回标题和钩子后面
        public var preamble: String? = nil

        public var isEmpty: Bool { meta.isEmpty && linkLines.isEmpty && sections.isEmpty && (preamble ?? "").isEmpty }

        public init(meta: [String] = [], linkLines: [String] = [], sections: [Section] = [], preamble: String? = nil) {
            self.meta = meta
            self.linkLines = linkLines
            self.sections = sections
            self.preamble = preamble
        }
    }

    public init(path: String, kind: Kind? = nil, triggers: [String] = [], hook: String = "", title: String, now: String = "", validUntil: String? = nil, records: [String] = [], entries: [String]? = nil, links: [Link] = [], extra: Extra? = nil, factDomain: SeedFactDomain? = nil) {
        self.path = path
        self.kind = kind
        self.triggers = triggers
        self.hook = hook
        self.title = title
        self.now = now
        self.validUntil = validUntil
        self.records = records
        self.entries = entries
        self.links = links
        self.extra = extra
        self.factDomain = factDomain
    }
}

// MARK: - md

extension WikiPage {
    public var factDomainIndexTag: String {
        switch factDomain {
        case .inWorld: return " [设定]"
        case .mixed, .unspecified: return " [待判域]"
        case .realWorld, nil: return ""
        }
    }

    public static func factDomainLabel(_ domain: SeedFactDomain?) -> String {
        switch domain {
        case .realWorld: return "现实"
        case .inWorld: return "设定"
        case .mixed: return "混合待判"
        case .unspecified: return "未判"
        case nil: return "未记录"
        }
    }

    public var markdown: String {
        var out = "---\n"
        if let kind { out += "类: \(kind.rawValue)\n" }
        if let factDomain { out += "事实域: \(factDomain.rawValue)\n" }
        out += "触发词: [\(triggers.joined(separator: ", "))]\n"
        out += "钩子: \(hook)\n"
        if let validUntil { out += "\(Self.validUntilKey): \(validUntil)\n" }
        if let entries, let data = try? JSONEncoder().encode(entries) {
            out += "条目: " + String(decoding: data, as: UTF8.self) + "\n"
        }
        out += (extra?.meta ?? []).map { line in
            // 有了生效的期限，手写的认不出的「有效到」改个键名留着，不再参与解析（不然后写的那个会盖掉生效的）
            guard let sep = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return line + "\n" }
            if validUntil != nil, Self.metaKey(line) == Self.validUntilKey { return Self.replacedUntilKey + line[sep...] + "\n" }
            if factDomain != nil, Self.metaKey(line) == "事实域" { return Self.replacedFactDomainKey + line[sep...] + "\n" }
            return line + "\n"
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

    public static let knownMetaKeys: Set<String> = ["类", "触发词", "钩子", "条目", "事实域"]
    public static let knownSections: Set<String> = ["现在", "记录", "连到"]
    public static let validUntilKey = "有效到"
    /// 被新期限替换掉的手写原文换成这个键名留着（不参与解析）
    public static let replacedUntilKey = "有效到（原写法，已换）"
    public static let replacedFactDomainKey = "事实域（原写法，已换）"

    private static let untilPattern = try! NSRegularExpression(pattern: #"到\s*(\d{4}-\d{2}-\d{2})"#)

    /// 「现在」里写明的到期日（「到 YYYY-MM-DD」）
    public static func untilDates(in now: String) -> [String] {
        let ns = now as NSString
        return untilPattern.matches(in: now, range: NSRange(location: 0, length: ns.length))
            .compactMap { FragmentPool.validDay(ns.substring(with: $0.range(at: 1))) }
    }

    /// 页上的期限一律从「现在」推：preferred（写手给的 / 原来的）是正文里写着的到期日就用它，不然取正文里最早的到期日；正文没写到期日 = nil
    public static func until(_ preferred: String?, in now: String) -> String? {
        let dates = untilDates(in: now)
        if let day = FragmentPool.validDay(preferred), dates.contains(day) { return day }
        return dates.min()
    }

    public static func metaKey(_ line: String) -> String? {
        line.firstIndex(where: { $0 == ":" || $0 == "：" }).map { line[..<$0].trimmingCharacters(in: .whitespaces) }
    }

    /// 宽容读：缺 frontmatter / 缺段当空，标题缺了用文件名，钩子 frontmatter 没有就看「> 钩子：」那行；
    /// 认不出的（别的键 / 连到里别的行 / 别的段）进 `extra` 原样留着
    public static func parse(_ text: String, path: String) -> WikiPage {
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
            entries: meta["条目"].map { raw in
                (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? list(raw)
            },
            links: links,
            extra: extra.isEmpty ? nil : extra,
            factDomain: meta["事实域"].flatMap(SeedFactDomain.init(rawValue:))
        )
    }

    /// frontmatter 里不是类 / 触发词 / 钩子的键：原行照抄，连同挂在它下面的行
    public static func unknownMetaLines(_ lines: [String]) -> [String] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { return [] }
        var out: [String] = []
        var inUnknown = false
        for line in lines[1..<end] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.hasPrefix("- "), let sep = t.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                inUnknown = !knownMetaKeys.contains(t[..<sep].trimmingCharacters(in: .whitespaces))
                if metaKey(t) == "事实域", SeedFactDomain(rawValue: String(t[t.index(after: sep)...]).trimmingCharacters(in: .whitespaces)) == nil {
                    inUnknown = true
                }
                if inUnknown { out.append(line) }
            } else if inUnknown, !t.isEmpty {
                out.append(line)
            }
        }
        return out
    }

    /// 开头 `---` 到下一个 `---` 之间的 `键: 值`（全角冒号也认；`- 项` 接在空值的键后面当列表）；读完从 lines 里去掉
    public static func frontmatter(_ lines: inout [String]) -> [String: String] {
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

    public static func list(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))) }
            .filter { !$0.isEmpty }
    }

    /// `- [[地点/五楼出租屋]] · 补充 · 一起住过`
    public static func parseLink(_ line: String) -> Link? {
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
public struct WikiStore: Sendable {
    public let root: URL
    public var beforeWrite: (@Sendable (String) throws -> Void)?
    public var beforeRebuildIndexes: (@Sendable () throws -> Void)?

    /// wiki 根下固定的 9 个组：本人（落盘是字面量 `{{user}}`，见 `shown` / `stored`）+ 另外七类各一组 + 工程（代码工程）；第二层往下的分组由模型提、她能改
    public static let branches = [userBranch] + WikiPage.Kind.allCases.filter { $0 != .user }.map(\.rawValue) + [projectBranch]
    public static let userBranch = "{{user}}"
    public static let projectBranch = "工程"
    /// 给模型 / 人看的九组（本人那组经 `shown` 显示成名字）
    public static let branchesText = branches.joined(separator: " / ")
    public static let indexFileName = "INDEX.md"
    public static let groupFileName = ".group.md"
    public static let historyFolder = ".history"
    public static let proposalsFolder = ".proposals"
    public static let stopWordsFileName = "不触发的词.txt"

    public enum WikiError: LocalizedError, Equatable {
        case invalidPath(String)
        /// 新「记录」不是旧「记录」原样 + 往后加
        case recordsNotAppendOnly(String)
        case notFound(String)
        case conflict(String, String)

        public var errorDescription: String? {
            if case .conflict(_, let reason) = self { return reason }
            return nil
        }
    }

    public struct HistoryEntry: Equatable, Sendable {
        /// 文件名（`yyyyMMdd-HHmmss.md`，同秒的 `-2` `-3`…）
        public let name: String
        public let date: Date?

        public init(name: String, date: Date?) {
            self.name = name
            self.date = date
        }
    }

    public init(root: URL) {
        self.root = root
    }

    // MARK: 本人那组：落盘用字面量 {{user}}，进出模型 / 界面换成当前名字（只在这里换）

    /// 本人那组给人 / 模型看的名字：当前用户名；空、带斜杠 / 反斜杠 / 引号（拼进提示词里的 JSON 行会坏）、点开头、和另外八组同名（比如叫「人」）→ 「用户」（不和任何组撞）
    public static func userLabel(_ user: String) -> String {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\""), !name.hasPrefix("."), !branches.contains(name), name != userBranch
        else { return WikiPage.Kind.user.rawValue }
        return name
    }

    /// 出：给模型 / 人看的文字（路径、索引、整段提示词、工具回执）里的 `{{user}}` 一律换成当前名字
    public static func shown(_ text: String, user: String) -> String {
        text.replacingOccurrences(of: userBranch, with: userLabel(user))
    }

    /// 进：模型 / 界面交来的一个路径（可带 `memory/wiki/` 前缀、`[[ ]]`）第一段是当前名字（或字面量 {{user}}）→ 换回 `{{user}}`
    public static func stored(_ path: String, user: String) -> String {
        let label = userLabel(user)
        for prefix in ["[[" + CatalogSeedMaterials.wikiPrefix, CatalogSeedMaterials.wikiPrefix, "[[", ""] where path.hasPrefix(prefix + label) {
            let rest = path.dropFirst(prefix.count + label.count)
            if rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("]]") { return prefix + userBranch + rest }
        }
        return path
    }

    /// 进：模型交来的一个 JSON 对象（解析器已按原规则从回复里恢复出来的正文 / 诊断那一段）里，按 `fields` 列的位置
    /// 把路径第一段的名字还原成 {{user}}；别的位置的字符串只还原明确的 [[名字/…]] 双链，不把长得像 JSON 的正文当结构解析。
    /// 解不出来的原样返回（校验照常拦，回执里列的组是当前名字）；没东西要换也原样返回（不重新编码）
    public static func storedJSON(_ body: String, fields: WikiPathFields, user: String) -> String {
        guard body.contains(userLabel(user)) else { return body }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8)))
                ?? (try? JSONSerialization.jsonObject(with: Data(CatalogJSON.repairQuotes(body).utf8))) else { return body }
        var changed = false
        let converted = storedValue(object, at: fields.paths, user: user, changed: &changed)
        guard changed, let data = try? JSONSerialization.data(withJSONObject: converted, options: [.sortedKeys, .withoutEscapingSlashes]) else { return body }
        return String(decoding: data, as: UTF8.self)
    }

    /// paths：从这一层往下还剩的路径段；有空的 = 这里就是路径字段（字符串或字符串数组）
    private static func storedValue(_ value: Any, at paths: [[String]], user: String, changed: inout Bool) -> Any {
        if paths.contains(where: \.isEmpty) {
            switch value {
            case let text as String:
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let new = stored(t, user: user)
                if new == t { return text }
                changed = true
                return new
            case let array as [Any]:
                return array.map { storedValue($0, at: [[]], user: user, changed: &changed) }
            default:
                return value
            }
        }
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (key, v) in dict {
                out[key] = storedValue(v, at: paths.compactMap { $0.first == key ? Array($0.dropFirst()) : nil }, user: user, changed: &changed)
            }
            return out
        case let array as [Any]:
            return array.map { storedValue($0, at: paths, user: user, changed: &changed) }
        case let text as String:
            // 结构位置上把数组 / 对象写成了字符串（CatalogJSON.Container 照收）：里面按同样的位置换，再编回字符串
            if !paths.isEmpty, let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first, first == "[" || first == "{",
               let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                var inner = false
                let converted = storedValue(nested, at: paths, user: user, changed: &inner)
                guard inner, let data = try? JSONSerialization.data(withJSONObject: converted, options: [.sortedKeys, .withoutEscapingSlashes]) else { return text }
                changed = true
                return String(decoding: data, as: UTF8.self)
            }
            let new = storedLinks(text, user: user)
            if new != text { changed = true }
            return new
        default:
            return value
        }
    }

    /// 进：一段正文里明确的 wiki 双链 `[[名字/…]]` / `[[名字]]` 还原成 `{{user}}`（别的字不动）
    public static func storedLinks(_ text: String, user: String) -> String {
        let label = userLabel(user)
        return text.replacingOccurrences(of: "[[" + label + "/", with: "[[" + userBranch + "/")
            .replacingOccurrences(of: "[[" + label + "]]", with: "[[" + userBranch + "]]")
    }

    /// 进：编辑器 / 草稿里交回的文字落回落盘写法。没改的行（和原文那一行的显示投影一样）照落盘原文；
    /// 改过的行按 `line` 还原（默认只还原 [[双链]] 和「（出处：wiki 名字/…）」），不全局替换名字
    public static func storedEdit(_ edited: String, original: String, user: String, line: ((String) -> String)? = nil) -> String {
        let rawLines = original.components(separatedBy: "\n")
        let shownLines = rawLines.map { shown($0, user: user) }
        let editedLines = edited.components(separatedBy: "\n")
        let convert = line ?? { storedLine($0, user: user) }
        // 按编辑差异逐行对上原文（不按显示文本当键）：显示一样的重复行各自保留自己的原文
        let diff = editedLines.difference(from: shownLines)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [String] = []
        var i = 0
        for (j, text) in editedLines.enumerated() {
            if inserted.contains(j) {
                out.append(convert(text))
                continue
            }
            while removed.contains(i) { i += 1 }
            out.append(i < rawLines.count && shownLines[i] == text ? rawLines[i] : convert(text))
            i += 1
        }
        return out.joined(separator: "\n")
    }

    /// 一行正文：[[双链]] + 行末「（出处：…；…）」里 wiki 出处的本人那组；行尾空白先拿开、还原后原样放回（同解析时去空白再认出处）
    public static func storedLine(_ line: String, user: String) -> String {
        let linked = storedLinks(line, user: user)
        let body = linked.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let tail = String(linked.dropFirst(body.count))
        guard body.hasSuffix("）"), let open = body.range(of: "（出处：", options: .backwards) else { return linked }
        let labels = body[open.upperBound..<body.index(before: body.endIndex)].components(separatedBy: "；").map { label -> String in
            let core = label.trimmingCharacters(in: .whitespaces)
            guard let r = label.range(of: core), !core.isEmpty else { return label }
            return String(label[..<r.lowerBound]) + storedCite(core, user: user) + String(label[r.upperBound...])
        }
        return String(body[..<open.upperBound]) + labels.joined(separator: "；") + "）" + tail
    }

    /// 一项出处：「wiki 名字/页」「wiki 名字 索引」「wiki 名字/组 索引」→ 本人那组还原成 {{user}}（同 CatalogSources.label 的写法）
    public static func storedCite(_ label: String, user: String) -> String {
        let prefix = "wiki ", name = userLabel(user)
        guard label.hasPrefix(prefix) else { return label }
        let rest = label.dropFirst(prefix.count)
        guard rest.hasPrefix(name) else { return label }
        let tail = rest.dropFirst(name.count)
        guard tail.isEmpty || tail.hasPrefix("/") || tail.hasPrefix(" ") else { return label }
        return prefix + userBranch + tail
    }

    /// 出：一份 JSON 值（工具定义）里所有字符串的 {{user}} 换成名字，在值上换、再统一编码（名字里有引号也不坏）
    public static func shownValue(_ value: Any, user: String) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues { shownValue($0, user: user) }
        case let array as [Any]: return array.map { shownValue($0, user: user) }
        case let text as String: return shown(text, user: user)
        default: return value
        }
    }

    // MARK: 路径

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    private static func validSegments(_ parts: [String]) -> Bool {
        parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && $0.trimmingCharacters(in: .whitespaces) == $0 }
            && branches.contains(parts[0])
    }

    public static func isValidPagePath(_ path: String) -> Bool {
        let parts = components(path)
        guard parts.count >= 2, validSegments(parts), let last = parts.last else { return false }
        return last != "INDEX" && !last.lowercased().hasSuffix(".md")
    }

    /// 分组文件夹（含 9 个组本身）
    public static func isValidFolderPath(_ path: String) -> Bool {
        validSegments(components(path))
    }

    public func pageURL(_ path: String) throws -> URL {
        guard Self.isValidPagePath(path) else { throw WikiError.invalidPath(path) }
        return root.appendingPathComponent(path + ".md")
    }

    public func folderURL(_ path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
    }

    public func historyURL(_ path: String) -> URL {
        root.appendingPathComponent(Self.historyFolder, isDirectory: true).appendingPathComponent(path, isDirectory: true)
    }

    public func pageExists(_ path: String) -> Bool {
        guard let url = try? pageURL(path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func folderExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folderURL(path).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 全部页（或某个文件夹下的），相对路径不带 .md；隐藏的（.history / .proposals / .group.md）和 INDEX.md 不算
    public func pagePaths(under folder: String = "") -> [String] {
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

    public static func version(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 页版本 = 文件内容 sha256；页不存在 = nil
    public func version(of path: String) -> String? {
        guard let url = try? pageURL(path), let data = try? Data(contentsOf: url) else { return nil }
        return Self.version(of: data)
    }

    public func readRaw(_ path: String) -> String? {
        readVersioned(path)?.text
    }

    /// 原文和它的版本出自同一次读（C3 拿它当提案的基线）
    public func readVersioned(_ path: String) -> (text: String, version: String)? {
        guard let url = try? pageURL(path), let data = try? Data(contentsOf: url) else { return nil }
        return (String(decoding: data, as: UTF8.self), Self.version(of: data))
    }

    /// 这一刻全部页的版本（C3 动笔前拍一次，没读全文的页提案用它当基线）
    public func versionSnapshot() -> [String: String] {
        var out: [String: String] = [:]
        for path in pagePaths() { out[path] = version(of: path) }
        return out
    }

    public func read(_ path: String) -> WikiPage? {
        readRaw(path).map { WikiPage.parse($0, path: path) }
    }

    // MARK: 写

    /// 提案落盘：「记录」只能在旧的后面追加。返回新版本
    @discardableResult
    public func save(_ page: WikiPage, now: Date = Date(), recordingHistory: Bool = true) throws -> String {
        if let old = read(page.path), !page.records.starts(with: old.records) {
            throw WikiError.recordsNotAppendOnly(page.path)
        }
        return try saveRaw(page.markdown, path: page.path, now: now, recordingHistory: recordingHistory)
    }

    /// 编辑器（她在文件库手改）：不校验「记录」；覆盖前照样存一版历史。返回新版本
    @discardableResult
    public func saveRaw(_ text: String, path: String, now: Date = Date(), recordingHistory: Bool = true) throws -> String {
        try beforeWrite?(path + ".md")
        let url = try pageURL(path)
        let data = Data(text.utf8)
        if let old = try? Data(contentsOf: url) {
            if old == data { return Self.version(of: data) }
            if recordingHistory { _ = try snapshot(old, path: path, now: now) }
        }
        try Self.writeAtomic(data, to: url)
        return Self.version(of: data)
    }

    public static func writeAtomic(_ data: Data, to url: URL) throws {
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
        if changedInjection { MemoryEvents.shared.emit(.wikiInjectionDidChange(page: isPage ? url : nil)) }
    }

    // MARK: 历史

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    public func snapshotName(_ path: String, now: Date, avoidingHistoryAt: String? = nil) throws -> String {
        guard Self.isValidPagePath(path) else { throw WikiError.invalidPath(path) }
        var occupied = Set<String>()
        for page in [path] + (avoidingHistoryAt.map { [$0] } ?? []) {
            let dir: URL
            do { dir = try SafeWiki.folder([Self.historyFolder] + page.split(separator: "/").map(String.init), under: root, create: false) }
            catch SafeWiki.PathError.missing { continue }
            occupied.formUnion(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        }
        let stamp = Self.stampFormatter.string(from: now)
        var name = stamp + ".md"
        var n = 2
        while occupied.contains(name) {
            name = "\(stamp)-\(n).md"
            n += 1
        }
        return name
    }

    private func snapshot(_ data: Data, path: String, now: Date, avoidingHistoryAt: String? = nil, plannedEntry: String? = nil) throws -> String {
        let name = try plannedEntry ?? snapshotName(path, now: now, avoidingHistoryAt: avoidingHistoryAt)
        let dir = try SafeWiki.folder([Self.historyFolder] + path.split(separator: "/").map(String.init), under: root, create: true)
        let url = try SafeWiki.file(name, in: dir)
        guard try SafeWiki.itemType(url) == nil else { throw WikiError.conflict(path, "历史目标已占用") }
        try Self.writeAtomic(data, to: url)
        return name
    }

    public func checkedPageURL(_ path: String, create: Bool = false) throws -> URL {
        guard Self.isValidPagePath(path),
              !path.split(separator: "/").contains(where: { CCMemorySync.isExcluded(name: String($0)) }) else {
            throw WikiError.invalidPath(path)
        }
        let parts = path.split(separator: "/").map(String.init)
        let dir = try SafeWiki.folder(Array(parts.dropLast()), under: root, create: create)
        return try SafeWiki.file(parts.last! + ".md", in: dir)
    }

    public func checkedRelativeURL(_ path: String, isFolder: Bool = false, createParents: Bool = false) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
            && !CCMemorySync.isExcluded(name: $0) }), let name = parts.last else { throw WikiError.invalidPath(path) }
        if isFolder {
            let parent = try SafeWiki.folder(Array(parts.dropLast()), under: root, create: createParents)
            let url = parent.appendingPathComponent(name, isDirectory: true)
            switch try SafeWiki.itemType(url) {
            case nil, .typeDirectory?: return url
            case .typeSymbolicLink?: throw SafeWiki.PathError.link(path)
            default: throw SafeWiki.PathError.notFolder(path)
            }
        }
        let parent = try SafeWiki.folder(Array(parts.dropLast()), under: root, create: createParents)
        return try SafeWiki.file(name, in: parent)
    }

    public func relativeData(_ path: String) throws -> Data? {
        let url: URL
        do { url = try checkedRelativeURL(path) }
        catch SafeWiki.PathError.missing { return nil }
        guard try SafeWiki.itemType(url) != nil else { return nil }
        return try Data(contentsOf: url)
    }

    public func relativeFiles(_ path: String, excludingIndexes: Bool = false, recursive: Bool = true) throws -> [String: String] {
        let folder: URL
        do { folder = try SafeWiki.folder(path.split(separator: "/").map(String.init), under: root, create: false) }
        catch SafeWiki.PathError.missing { return [:] }
        var files: [String: String] = [:]
        func walk(_ dir: URL, prefix: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
                if name.hasPrefix(".") || CCMemorySync.isExcluded(name: name) || (excludingIndexes && name == Self.indexFileName) { continue }
                let relative = prefix + name
                let url = dir.appendingPathComponent(name)
                if try SafeWiki.itemType(url) == .typeDirectory {
                    if !recursive { continue }
                    _ = try SafeWiki.folder(url, under: root)
                    try walk(url, prefix: relative + "/")
                } else {
                    files[relative] = Self.version(of: try Data(contentsOf: SafeWiki.file(name, in: dir)))
                }
            }
        }
        try walk(folder, prefix: "")
        return files
    }

    public func moveRelative(from: String, to: String, isFolder: Bool = false) throws {
        try beforeWrite?(from)
        let source = try checkedRelativeURL(from, isFolder: isFolder)
        let target = try checkedRelativeURL(to, isFolder: isFolder, createParents: true)
        guard try SafeWiki.itemType(source) != nil, try SafeWiki.itemType(target) == nil else {
            throw WikiError.conflict(to, "挪动源不存在 / 目标已存在")
        }
        try FileManager.default.moveItem(at: source, to: target)
        MemoryEvents.shared.emit(.wikiInjectionDidChange(page: nil))
    }

    public func snapshotCurrent(_ path: String, now: Date = Date(), avoidingHistoryAt: String? = nil, plannedEntry: String? = nil) throws -> String? {
        MainThreadIO.assertOffMain(.write, "WikiStore.snapshotCurrent")
        let url: URL
        do { url = try checkedPageURL(path) }
        catch SafeWiki.PathError.missing { return nil }
        guard try SafeWiki.itemType(url) != nil else { return nil }
        return try snapshot(Data(contentsOf: url), path: path, now: now, avoidingHistoryAt: avoidingHistoryAt, plannedEntry: plannedEntry)
    }

    private static func sortKey(_ name: String) -> (String, Int) {
        let parts = name.dropLast(3).split(separator: "-")
        let stamp = parts.prefix(2).joined(separator: "-")
        return (stamp, parts.count > 2 ? Int(parts[2]) ?? 1 : 1)
    }

    /// 新→旧
    public func history(_ path: String) -> [HistoryEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: historyURL(path).path)) ?? []
        return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .sorted { Self.sortKey($0) > Self.sortKey($1) }
            .map { HistoryEntry(name: $0, date: Self.stampFormatter.date(from: Self.sortKey($0).0)) }
    }

    public func historyText(_ path: String, entry: String) -> String? {
        guard Self.isValidPagePath(path),
              let data = SafeWiki.read(entry, in: [Self.historyFolder] + path.split(separator: "/").map(String.init), under: root) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 按某一版恢复：恢复前当前版也存一版。返回新版本
    /// 调用方须持同楼层写锁；expectedVersion 是打开时版本，nil 表示当时不存在。
    @discardableResult
    public func restore(_ path: String, entry: String, expectedVersion: String?, now: Date = Date(),
                 recordingHistory: Bool = true) throws -> String {
        let current = version(of: path)
        guard current == expectedVersion else {
            throw WikiError.conflict(path, current == nil ? "这页已被删除，先关闭重开。" : "这页已在别处改过，先关闭重开。")
        }
        guard let text = historyText(path, entry: entry) else { throw WikiError.notFound(entry) }
        return try saveRaw(text, path: path, now: now, recordingHistory: recordingHistory)
    }

    // MARK: 不触发的词

    public var stopWordsURL: URL { root.appendingPathComponent(Self.stopWordsFileName) }

    public static func normalizedWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func stopWords() -> [String] {
        guard let data = try? Data(contentsOf: stopWordsURL) else { return [] }
        return Self.normalizedWords(String(decoding: data, as: UTF8.self).components(separatedBy: .newlines))
    }

    public func setStopWords(_ words: [String]) throws {
        let list = Self.normalizedWords(words)
        try Self.writeAtomic(Data((list.isEmpty ? "" : list.joined(separator: "\n") + "\n").utf8), to: stopWordsURL)
    }
}

/// 各个解析器里路径字段的位置（点分，数组自动展开）：按工具 / 对象结构列，不按字段名全局猜（A 线出处的 layer 这类不是路径）
public struct WikiPathFields: Sendable {
    public let paths: [[String]]

    public init(_ dotted: [String]) { paths = dotted.map { $0.split(separator: ".").map(String.init) } }

    private static let diagnosticKeys = ["coverage.input", "coverage.at", "preservation.page"]
    /// 写手 / 手动 agent 的条目（submit_proposal 参数或写手回复的正文对象），诊断写在同一个对象里的也算
    public static let items = WikiPathFields(["items.path", "items.to", "items.links.to", "items.records.sources", "covered_page"] + diagnosticKeys)
    /// 写手另起一个对象交的诊断
    public static let diagnostics = WikiPathFields(diagnosticKeys)
    /// 种子写页工具参数：写页条目
    public static let seed = WikiPathFields(["items.path", "items.to", "items.links.to", "items.records.sources",
                                      "covered_page"] + diagnosticKeys)
    /// 手动 agent 的 list_wiki / read_wiki
    public static let tool = WikiPathFields(["path"])
    /// 模型分拣
    public static let sorter = WikiPathFields(["fragments.page", "fragments.new.path", "timeline_proposals.path"])
    /// 分组调整
    public static let regroup = WikiPathFields(["groups.members"])
    /// 种子要点卡：卡的组、聚类页路径、对齐的合并目标（本人那组 / 本人锚）
    public static let notes = WikiPathFields(["cards.group", "user_pages.path", "topics.path", "theatre.path", "pending.path", "merge.into"])
}
