import Foundation

/// 文件库列表层的显示用纯函数：标题 / 摘要 / 胶囊 / 时间 / 文件夹内容。输入只用已预读的 280 字，不加 IO。
enum FileLibraryDisplay {

    enum Kind: Equatable {
        case markdown, html, text, image, binary
    }

    static func ext(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    static func kind(of path: String) -> Kind {
        switch ext(path) {
        case "md", "markdown": .markdown
        case "html", "htm": .html
        case "png", "jpg", "jpeg", "gif", "webp", "heic": .image
        case "txt", "json", "css", "js": .text
        default: .binary
        }
    }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func parentFolder(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    /// 小方块 / 角标上的扩展名字样
    static func badge(_ path: String) -> String {
        switch kind(of: path) {
        case .markdown: "MD"
        case .html: "HTML"
        case .image: ext(path) == "jpeg" ? "JPG" : ext(path).uppercased()
        default: String(ext(path).uppercased().prefix(4))
        }
    }

    // MARK: - 缓存

    /// 列表层要的显示数据，reload 时按预读一次算好
    struct Entry: Equatable {
        let title: String
        let summary: String?
        let chips: [String]
        /// 纸卡上标题下面那几行
        let lines: [String]
        let searchText: String
    }

    static let paperLineLimit = 5
    static let previewLength = 280

    /// 预读原文 → 存进缓存的 280 字。HTML 先剥掉 style / script / 注释 / meta / link 再截，
    /// 不然开头一大段 CSS 把 280 字吃光、正文一个字都取不到；<title> 留着给标题用。
    static func previewText(path: String, raw: String) -> String {
        guard kind(of: path) == .html else { return String(raw.prefix(previewLength)) }
        var s = raw
        for pattern in [#"<!--[\s\S]*?(-->|$)"#, #"<style(\s[^>]*)?>[\s\S]*?(</style>|$)"#, #"<script(\s[^>]*)?>[\s\S]*?(</script>|$)"#, #"<(meta|link)\b[^>]*>"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return String(s.prefix(previewLength))
    }

    static func entry(path: String, preview: String?) -> Entry {
        var lines = bodyLines(path: path, preview: preview, limit: paperLineLimit)
        if lines.isEmpty, kind(of: path) == .text, let preview {
            lines = Array(preview.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(paperLineLimit))
        }
        return Entry(
            title: title(path: path, preview: preview),
            summary: summary(path: path, preview: preview),
            chips: chips(path: path, preview: preview),
            lines: lines,
            searchText: searchableText(path: path, preview: preview)
        )
    }

    /// 每个文件夹（"" = 根）下一层的内容，一遍扫完。`files` 的顺序原样留给直属文件；子文件夹按首次出现排。
    static func folderIndex(_ files: [FileLibraryStore.FileMeta]) -> [String: FolderContents] {
        var folders: [String: [String: Folder]] = [:]
        var order: [String: [String]] = [:]
        var direct: [String: [FileLibraryStore.FileMeta]] = [:]
        for meta in files {
            let parts = meta.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            let isImage = kind(of: meta.path) == .image
            var parent = ""
            for depth in 0..<(parts.count - 1) {
                let path = parent.isEmpty ? parts[depth] : parent + "/" + parts[depth]
                if var f = folders[parent, default: [:]][path] {
                    f.fileCount += 1
                    if isImage { f.imageCount += 1 }
                    if meta.modifiedAt > f.latest { f.latest = meta.modifiedAt }
                    folders[parent]?[path] = f
                } else {
                    folders[parent, default: [:]][path] = Folder(path: path, fileCount: 1, imageCount: isImage ? 1 : 0, latest: meta.modifiedAt)
                    order[parent, default: []].append(path)
                }
                parent = path
            }
            direct[parent, default: []].append(meta)
        }
        var out: [String: FolderContents] = [:]
        for key in Set(order.keys).union(direct.keys) {
            let byPath = folders[key] ?? [:]
            out[key] = FolderContents(folders: (order[key] ?? []).compactMap { byPath[$0] }, files: direct[key] ?? [])
        }
        return out
    }

    // MARK: - 文件夹

    struct Folder: Identifiable, Equatable {
        let path: String
        var fileCount: Int
        var imageCount: Int
        var latest: Date
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    struct FolderContents {
        var folders: [Folder]
        var files: [FileLibraryStore.FileMeta]
    }

    /// `folder` 下一层：子文件夹（递归计数 + 最近修改）和直属文件。`files` 的顺序原样保留给直属文件。
    static func contents(of folder: String, in files: [FileLibraryStore.FileMeta]) -> FolderContents {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var folders: [String: Folder] = [:]
        var order: [String] = []
        var direct: [FileLibraryStore.FileMeta] = []
        for meta in files where meta.path.hasPrefix(prefix) {
            let rest = meta.path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { direct.append(meta); continue }
            let path = prefix + rest[..<slash]
            let isImage = kind(of: meta.path) == .image
            if var f = folders[path] {
                f.fileCount += 1
                if isImage { f.imageCount += 1 }
                if meta.modifiedAt > f.latest { f.latest = meta.modifiedAt }
                folders[path] = f
            } else {
                folders[path] = Folder(path: path, fileCount: 1, imageCount: isImage ? 1 : 0, latest: meta.modifiedAt)
                order.append(path)
            }
        }
        return FolderContents(folders: order.compactMap { folders[$0] }, files: direct)
    }

    /// 面包屑：("文件库", "") + 每一层 (原名, 路径)
    static func breadcrumb(_ folder: String) -> [(name: String, path: String)] {
        var out: [(name: String, path: String)] = [("文件库", "")]
        var acc = ""
        for part in folder.split(separator: "/") {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            out.append((String(part), acc))
        }
        return out
    }

    // MARK: - 标题 / 摘要 / 胶囊

    static func title(path: String, preview: String?) -> String {
        let name = fileName(path)
        let stem = (name as NSString).deletingPathExtension
        switch kind(of: path) {
        case .markdown:
            if let heading = markdownLines(preview).first(where: { $0.hasPrefix("# ") }) {
                let t = stripInline(String(heading.dropFirst(2)))
                if !t.isEmpty { return t }
            }
            return stem
        case .html:
            // 学堂的笔记都叫「课堂笔记.html」，取不到标题时用课名（上一层目录）
            let fallback = name == StudyTemplate.noteFileName && !parentFolder(path).isEmpty
                ? (parentFolder(path) as NSString).lastPathComponent : stem
            guard let html = preview else { return fallback }
            for tag in ["title", "h1"] {
                if let inner = firstMatch(#"<\#(tag)[^>]*>([\s\S]*?)</\#(tag)>"#, in: html) {
                    let t = collapse(decodeEntities(stripTags(inner)))
                    if !t.isEmpty { return t }
                }
            }
            return fallback
        case .text:
            return name
        case .image, .binary:
            return name
        }
    }

    /// 第二行：正文第一句非空行（跳过标题 / 分隔线 / 代码围栏）；拿不到就 nil（调用方写大小）
    static func summary(path: String, preview: String?) -> String? {
        bodyLines(path: path, preview: preview, limit: 1).first
    }

    /// 纸卡上标题下面的几行正文
    static func bodyLines(path: String, preview: String?, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        switch kind(of: path) {
        case .markdown:
            var out: [String] = []
            var fallbackHeading: String?
            var inFence = false
            var skippedTitle = false
            for line in markdownLines(preview) {
                if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
                if inFence { continue }
                if line.hasPrefix("# "), !skippedTitle { skippedTitle = true; continue }
                if line.hasPrefix("#") {
                    if fallbackHeading == nil { fallbackHeading = stripInline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) }
                    continue
                }
                if isRule(line) || isTableSeparator(line) { continue }
                let t = stripInline(stripBlockPrefix(line))
                if t.isEmpty { continue }
                out.append(t)
                if out.count >= limit { break }
            }
            if out.isEmpty, let fallbackHeading, !fallbackHeading.isEmpty { return [fallbackHeading] }
            return out
        case .html:
            guard let html = preview else { return [] }
            return Array(htmlBodyText(html, dropping: ["title", "h1"]).components(separatedBy: .newlines).map(collapse).filter { !$0.isEmpty }.prefix(limit))
        case .text:
            guard ext(path) == "txt", let preview else { return [] }
            return Array(preview.components(separatedBy: .newlines).map(collapse).filter { !$0.isEmpty }.prefix(limit))
        case .image, .binary:
            return []
        }
    }

    /// frontmatter 里短字段（≤8 字）的值，按原文顺序取前 3 个；和标题重复的不要
    static func chips(path: String, preview: String?) -> [String] {
        guard kind(of: path) == .markdown, let preview else { return [] }
        let t = title(path: path, preview: preview)
        let values = MarkdownFrontmatter.split(preview).fields
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 8 && $0 != t }
        return Array(values.prefix(3))
    }

    // MARK: - 搜索

    /// 预读里命中那段：命中前留 `before` 个字，总长约 `length`，被截处加「…」
    static func searchSnippet(path: String, preview: String?, query: String, before: Int = 10, length: Int = 40) -> String? {
        snippet(in: searchableText(path: path, preview: preview), query: query, before: before, length: length)
    }

    /// 去掉标记后的纯文本（搜索命中段从这里切；reload 时算一次存缓存）
    static func searchableText(path: String, preview: String?) -> String {
        guard let preview else { return "" }
        switch kind(of: path) {
        case .markdown:
            return collapse(markdownLines(preview).map { stripInline(stripBlockPrefix($0.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression))) }.joined(separator: " "))
        case .html:
            return collapse(htmlBodyText(preview, dropping: []))
        case .text:
            return collapse(preview)
        case .image, .binary:
            return ""
        }
    }

    /// 命中段：只做字符串查找，不跑正则
    static func snippet(in text: String, query: String, before: Int = 10, length: Int = 40) -> String? {
        guard !query.isEmpty, let hit = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(hit.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        let body = String(text[start..<max(end, hit.upperBound)])
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    // MARK: - 时间

    /// <1 小时「N 分钟前」/ 今天「HH:mm」/ 昨天 / 今年「M月d日」/ 更早「yyyy年M月d日」
    static func timeText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let delta = now.timeIntervalSince(date)
        if delta >= 0, delta < 3600 {
            return "\(max(1, Int(delta / 60))) 分钟前"
        }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        if calendar.component(.year, from: now) == c.year {
            return "\(c.month ?? 0)月\(c.day ?? 0)日"
        }
        return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    // MARK: - markdown 小工具

    /// 去掉 frontmatter 后的非空行（trim 过）。头没收尾（被 280 字截断）就当全是头。
    private static func markdownLines(_ preview: String?) -> [String] {
        guard let preview else { return [] }
        let split = MarkdownFrontmatter.split(preview)
        let body = (split.fields.isEmpty && preview.hasPrefix("---\n")) ? "" : split.body
        return body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func isRule(_ line: String) -> Bool {
        let s = line.replacingOccurrences(of: " ", with: "")
        return s.count >= 3 && (Set(s) == ["-"] || Set(s) == ["*"] || Set(s) == ["_"])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.hasPrefix("|") && line.allSatisfy { "|-: ".contains($0) }
    }

    private static func stripBlockPrefix(_ line: String) -> String {
        line.replacingOccurrences(of: #"^(>\s*)+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^([-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#, with: "", options: .regularExpression)
    }

    private static func stripInline(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[\[([^\]|]+)(\|([^\]]+))?\]\]"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__|~~|`)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![\w*])[*_](?=\S)(.+?)(?<=\S)[*_](?![\w*])"#, with: "$1", options: .regularExpression)
        t = stripTags(t)
        return collapse(t)
    }

    /// 去掉 head / style / script（和 `dropping` 里的元素），块级结束处断行，剥标签解实体
    private static func htmlBodyText(_ html: String, dropping: [String]) -> String {
        var s = html
        for tag in ["head", "style", "script"] + dropping {
            s = s.replacingOccurrences(of: #"<\#(tag)(\s[^>]*)?>[\s\S]*?(</\#(tag)>|$)"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6])[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        return decodeEntities(stripTags(s))
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&middot;", with: "·")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
