#if PERSONAL_APPS
#if DEBUG
import Foundation

// MARK: - 话题盒数据类型

/// 一张问题卡 = topics/ 下一个 md 文件。宽松解析是设计要求：
/// AI 用 fs_write 投的题格式大概率不标准，无 frontmatter / 无回应节 / 怪小节头都要兜住。
struct TopicCard: Identifiable, Equatable {
    var relPath: String          // "topics/什么是自我.md"
    var title: String            // 首个非空正文行（去 # 前缀）；空文件 = 文件名
    var body: String             // 问题正文（## 回应 之前，含 frontmatter 之外全部）
    var author: String?
    var created: String?
    var source: String?          // chat#<nodeId> / book:<bookId>#page=N / #chapter=N
    var responses: [TopicResponse]
    var isArchived: Bool
    var modifiedAt: Date?

    var id: String { relPath }
}

struct TopicResponse: Equatable {
    var date: String
    var author: String
    var text: String
}

/// 掉落账本：app 管理的可变状态，不进 md 文件（AI 的 fs 写入永远碰不到）。
struct TopicDropLedger: Codable, Equatable {
    var lastDropDate: String = ""
    var today: [String] = []
    var history: [String: String] = [:]   // relPath → 最后掉落日 "yyyy-MM-dd"
}

// MARK: - 话题盒 Store（纯静态函数，rootURL/ledgerURL/日期全注入——单测走临时目录零真库）

enum TopicBoxStore {
    static let topicsDirName = "topics"
    static let archivedDirName = "archived"
    static let responsesHeader = "## 回应"

    /// 跳卡交接位：.openTopicBoxTool 发出时面板可能还没挂载（切工具同一拍，onReceive 订阅不到），
    /// ContentView 停一份在这，面板 onAppear 消费。
    @MainActor static var pendingOpenRelPath: String? = nil

    // MARK: 路径

    static func topicsURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(topicsDirName, isDirectory: true)
    }

    static func archivedURL(rootURL: URL) -> URL {
        topicsURL(rootURL: rootURL).appendingPathComponent(archivedDirName, isDirectory: true)
    }

    /// 掉落账本默认位置：App Support/MemoryPalace/topicBox/{profileId}.json
    static func defaultLedgerURL(profileId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("topicBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(profileId).json")
    }

    static func todayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    // MARK: 解析（宽松容错）

    static func parse(markdown: String, relPath: String) -> TopicCard {
        var author: String?
        var created: String?
        var source: String?
        var rest = markdown

        // frontmatter：--- 开头才解析，否则整篇当正文
        if rest.hasPrefix("---") {
            let lines = rest.components(separatedBy: "\n")
            if let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                for line in lines[1..<closeIdx] {
                    let parts = line.split(separator: ":", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    guard parts.count == 2, !parts[1].isEmpty else { continue }
                    switch parts[0] {
                    case "author":  author = parts[1]
                    case "created": created = parts[1]
                    case "source":  source = parts[1]
                    default: break
                    }
                }
                rest = lines[(closeIdx + 1)...].joined(separator: "\n")
            }
        }

        // 切正文 / 回应区
        var bodyLines: [String] = []
        var responseLines: [String]? = nil
        for line in rest.components(separatedBy: "\n") {
            if responseLines == nil,
               line.trimmingCharacters(in: .whitespaces) == responsesHeader {
                responseLines = []
                continue
            }
            if responseLines != nil {
                responseLines?.append(line)
            } else {
                bodyLines.append(line)
            }
        }

        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (relPath as NSString).lastPathComponent
        let fallbackTitle = (fileName as NSString).deletingPathExtension
        let firstLine = body.components(separatedBy: "\n").first {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let title: String = {
            guard let firstLine else { return fallbackTitle }
            let t = firstLine.trimmingCharacters(in: .whitespaces)
                .drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? fallbackTitle : t
        }()

        let isArchived = relPath.hasPrefix("\(topicsDirName)/\(archivedDirName)/")
        return TopicCard(
            relPath: relPath, title: title, body: body,
            author: author, created: created, source: source,
            responses: parseResponses(responseLines ?? []),
            isArchived: isArchived, modifiedAt: nil
        )
    }

    /// `### 日期 · 作者` 分节；解析不出的小节头整段并入上一条（没有上一条就成匿名回应），不丢字。
    private static func parseResponses(_ lines: [String]) -> [TopicResponse] {
        var responses: [TopicResponse] = []
        var currentText: [String] = []

        func flushText() {
            let text = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            currentText = []
            guard !text.isEmpty else { return }
            if responses.isEmpty {
                responses.append(TopicResponse(date: "", author: "", text: text))
            } else {
                let joined = responses[responses.count - 1].text
                responses[responses.count - 1].text = joined.isEmpty ? text : joined + "\n" + text
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") {
                let header = trimmed.dropFirst(4)
                let parts = header.components(separatedBy: " · ")
                if parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty {
                    flushText()
                    responses.append(TopicResponse(
                        date: parts[0].trimmingCharacters(in: .whitespaces),
                        author: parts[1].trimmingCharacters(in: .whitespaces),
                        text: ""
                    ))
                    continue
                }
                // 怪小节头：整行并入当前文本流
            }
            currentText.append(line)
        }
        flushText()
        return responses.filter { !($0.date.isEmpty && $0.author.isEmpty && $0.text.isEmpty) }
    }

    // MARK: 序列化

    static func newCardMarkdown(title: String, body: String, author: String,
                                source: String?, created: String) -> String {
        var lines = ["---", "created: \(created)", "author: \(author)"]
        if let source, !source.isEmpty { lines.append("source: \(source)") }
        lines.append("---")
        let question = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(question)
        if !detail.isEmpty {
            lines.append("")
            lines.append(detail)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func appendResponseMarkdown(existing: String, date: String,
                                       author: String, text: String) -> String {
        var base = existing
        while base.hasSuffix("\n") || base.hasSuffix(" ") { base.removeLast() }
        let hasHeader = existing.components(separatedBy: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == responsesHeader
        }
        var out = base + "\n\n"
        if !hasHeader { out += responsesHeader + "\n\n" }
        out += "### \(date) · \(author)\n"
        out += text.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n"
        return out
    }

    /// 文件名 = 问题短句：去路径非法字符（含 #——relPath 进合成锚 topic:<path>#<小节>，
    /// 文件名带 # 会撞锚分隔符），截 40 字符；空了兜底「未命名话题」。
    static func sanitizeFileName(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|#\n\r\t")
        let cleaned = title.unicodeScalars
            .filter { !illegal.contains($0) }
            .map(Character.init)
        let name = String(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(40)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "未命名话题" : String(name)
    }

    /// 撞名追加 -2、-3……返回 "topics/<名>.md" 相对路径。
    static func uniqueRelPath(for title: String, rootURL: URL) -> String {
        let name = sanitizeFileName(title)
        let dir = topicsURL(rootURL: rootURL)
        var candidate = "\(name).md"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(name)-\(n).md"
            n += 1
        }
        return "\(topicsDirName)/\(candidate)"
    }

    // MARK: 文件 IO

    /// 顶层问题卡（不含 archived/），按需带 mtime。
    static func listTopLevelRelPaths(rootURL: URL) -> [String] {
        let dir = topicsURL(rootURL: rootURL)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { "\(topicsDirName)/\($0.lastPathComponent)" }
            .sorted()
    }

    static func listArchivedRelPaths(rootURL: URL) -> [String] {
        let dir = archivedURL(rootURL: rootURL)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { "\(topicsDirName)/\(archivedDirName)/\($0.lastPathComponent)" }
            .sorted()
    }

    static func loadCard(relPath: String, rootURL: URL) -> TopicCard? {
        let url = rootURL.appendingPathComponent(relPath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var card = parse(markdown: content, relPath: relPath)
        card.modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        return card
    }

    static func listCards(rootURL: URL, includeArchived: Bool = true) -> [TopicCard] {
        var paths = listTopLevelRelPaths(rootURL: rootURL)
        if includeArchived { paths += listArchivedRelPaths(rootURL: rootURL) }
        return paths.compactMap { loadCard(relPath: $0, rootURL: rootURL) }
    }

    /// 新卡落盘（原子写），返回 relPath。
    @discardableResult
    static func createCard(title: String, body: String, author: String,
                           source: String?, rootURL: URL,
                           created: String = todayString()) throws -> String {
        let relPath = uniqueRelPath(for: title, rootURL: rootURL)
        let md = newCardMarkdown(title: title, body: body, author: author,
                                 source: source, created: created)
        try writeCard(relPath: relPath, markdown: md, rootURL: rootURL)
        return relPath
    }

    static func writeCard(relPath: String, markdown: String, rootURL: URL) throws {
        let url = rootURL.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// 追加回应：读整文 → 补节头/追小节 → 原子覆盖。
    static func appendResponse(relPath: String, date: String, author: String,
                               text: String, rootURL: URL) throws {
        let url = rootURL.appendingPathComponent(relPath)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = appendResponseMarkdown(existing: existing, date: date,
                                             author: author, text: text)
        try updated.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// 归档：移到 topics/archived/，撞名加序号。返回新 relPath。
    @discardableResult
    static func archive(relPath: String, rootURL: URL) throws -> String {
        let src = rootURL.appendingPathComponent(relPath)
        let dir = archivedURL(rootURL: rootURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = (relPath as NSString).lastPathComponent
        let base = (fileName as NSString).deletingPathExtension
        var candidate = fileName
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n).md"
            n += 1
        }
        try FileManager.default.moveItem(at: src, to: dir.appendingPathComponent(candidate))
        return "\(topicsDirName)/\(archivedDirName)/\(candidate)"
    }

    // MARK: 账本

    static func loadLedger(ledgerURL: URL) -> TopicDropLedger {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(TopicDropLedger.self, from: data) else {
            return TopicDropLedger()
        }
        return ledger
    }

    static func saveLedger(_ ledger: TopicDropLedger, ledgerURL: URL) {
        try? FileManager.default.createDirectory(
            at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: ledgerURL, options: .atomic)
        }
    }

    /// 对账：账本里文件已不存在的路径剔除（用户删的 / AI fs_delete 的 / 已归档的）。
    static func reconcile(_ ledger: inout TopicDropLedger, rootURL: URL) {
        let existing = Set(listTopLevelRelPaths(rootURL: rootURL))
        ledger.today.removeAll { !existing.contains($0) }
        ledger.history = ledger.history.filter { existing.contains($0.key) }
    }

    // MARK: 掉落引擎

    /// 当天首次调用抽 1-2 个（没掉过优先 → 最久没掉；同组随机），同日幂等。
    /// 空池不盖日期戳——今天晚些时候投了第一题还能掉。
    @discardableResult
    static func ensureTodayDrops(
        rootURL: URL, ledgerURL: URL,
        today: String = todayString()
    ) -> [String] {
        var rng = SystemRandomNumberGenerator()
        return ensureTodayDrops(rootURL: rootURL, ledgerURL: ledgerURL, today: today, rng: &rng)
    }

    @discardableResult
    static func ensureTodayDrops<G: RandomNumberGenerator>(
        rootURL: URL, ledgerURL: URL,
        today: String, rng: inout G
    ) -> [String] {
        var ledger = loadLedger(ledgerURL: ledgerURL)
        let before = ledger
        reconcile(&ledger, rootURL: rootURL)

        if ledger.lastDropDate == today, !ledger.today.isEmpty {
            if ledger != before { saveLedger(ledger, ledgerURL: ledgerURL) }
            return ledger.today
        }

        let pool = listTopLevelRelPaths(rootURL: rootURL)
        guard !pool.isEmpty else {
            if ledger != before { saveLedger(ledger, ledgerURL: ledgerURL) }
            return []
        }

        let count = pool.count == 1 ? 1 : Int.random(in: 1...2, using: &rng)
        let never = pool.filter { ledger.history[$0] == nil }.shuffled(using: &rng)
        let dropped = pool.filter { ledger.history[$0] != nil }
            .shuffled(using: &rng)
            .sorted { (ledger.history[$0] ?? "") < (ledger.history[$1] ?? "") }
        let picks = Array((never + dropped).prefix(count))

        ledger.lastDropDate = today
        ledger.today = picks
        for p in picks { ledger.history[p] = today }
        saveLedger(ledger, ledgerURL: ledgerURL)
        return picks
    }
}
#endif
#endif
