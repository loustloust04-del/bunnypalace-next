import Foundation
import CryptoKit

// MARK: - 她的每日日记（plan-calendar §3.1）
// filesystem/journal/yyyy-MM-dd.md。自带 frontmatter 读写：只动 mood 一行，其它键、正文（含首尾空白）原样保留；
// 允许只有 frontmatter 的空日记。读改写串行；保存前比对内容哈希，别处改过就报冲突，不静默覆盖。

enum JournalMood: String, CaseIterable, Sendable {
    case happy, calm, meh, tired, sad

    var label: String {
        switch self {
        case .happy: "开心"
        case .calm: "平静"
        case .meh: "一般"
        case .tired: "累"
        case .sad: "难过"
        }
    }
}

struct JournalDocument: Equatable, Sendable {
    /// frontmatter 原始行（不含 --- 分隔线），保持顺序
    var frontmatter: [String]
    var body: String
    /// 读盘时整份内容的哈希；新文件为 nil
    var diskHash: String?

    var mood: JournalMood? {
        for line in frontmatter {
            guard let (k, v) = Self.split(line), k == "mood" else { continue }
            return JournalMood(rawValue: v)
        }
        return nil
    }

    static func split(_ line: String) -> (String, String)? {
        guard let i = line.firstIndex(of: ":") else { return nil }
        let k = line[..<i].trimmingCharacters(in: .whitespaces)
        let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        return (k, v)
    }

    /// 解析：以 `---` 行开头、再遇到一行 `---` 结束的才算 frontmatter；否则整份都是正文。
    static func parse(_ text: String) -> JournalDocument {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            return JournalDocument(frontmatter: [], body: text, diskHash: nil)
        }
        let fm = Array(lines[1..<end])
        let body = lines[(end + 1)...].joined(separator: "\n")
        return JournalDocument(frontmatter: fm, body: body, diskHash: nil)
    }

    func render() -> String {
        guard !frontmatter.isEmpty else { return body }
        return (["---"] + frontmatter + ["---"]).joined(separator: "\n") + "\n" + body
    }

    mutating func setMood(_ mood: JournalMood?) {
        let idx = frontmatter.firstIndex { Self.split($0)?.0 == "mood" }
        let line = "mood: \(mood?.rawValue ?? "")"
        if let idx { frontmatter[idx] = line } else { frontmatter.append(line) }
    }
}

enum JournalStoreError: Error, Equatable {
    /// 保存时发现磁盘上的版本和打开时不一样（别处改过）
    case conflict(currentHash: String?)
}

final class JournalStore: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()

    init(root: URL) { self.root = root }

    static func forProfile(_ profileId: String) -> JournalStore {
        JournalStore(root: FileLibraryStore.libraryRoot(profileId: profileId).appendingPathComponent("journal", isDirectory: true))
    }

    func url(for date: String) -> URL { root.appendingPathComponent("\(date).md") }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func existingDates() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
    }

    func load(date: String) -> JournalDocument? {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked(date: date)
    }

    private func loadUnlocked(date: String) -> JournalDocument? {
        MainThreadIO.note(.read, "JournalStore.load")
        guard let data = try? Data(contentsOf: url(for: date)) else { return nil }
        var doc = JournalDocument.parse(String(decoding: data, as: UTF8.self))
        doc.diskHash = Self.hash(data)
        return doc
    }

    private func currentHashUnlocked(date: String) -> String? {
        (try? Data(contentsOf: url(for: date))).map(Self.hash)
    }

    private func writeUnlocked(_ doc: JournalDocument, date: String) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data(doc.render().utf8)
        try data.write(to: url(for: date), options: .atomic)
        return Self.hash(data)
    }

    /// 编辑器保存正文。`baseHash` = 打开时的哈希（新文件传 nil）。磁盘变了就抛冲突。
    /// frontmatter 取磁盘上最新的（心情可能在编辑期间被改过），只替换正文。
    @discardableResult
    func saveBody(_ body: String, date: String, baseHash: String?, newFileFrontmatter: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let current = currentHashUnlocked(date: date)
        guard current == baseHash else { throw JournalStoreError.conflict(currentHash: current) }
        var doc = loadUnlocked(date: date) ?? JournalDocument(frontmatter: newFileFrontmatter, body: "", diskHash: nil)
        doc.body = body
        return try writeUnlocked(doc, date: date)
    }

    /// 冲突时选「用我这份覆盖」：不比哈希，只换正文。
    @discardableResult
    func overwriteBody(_ body: String, date: String, newFileFrontmatter: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        var doc = loadUnlocked(date: date) ?? JournalDocument(frontmatter: newFileFrontmatter, body: "", diskHash: nil)
        doc.body = body
        return try writeUnlocked(doc, date: date)
    }

    /// 写心情：重新读盘再改，只动 mood 一行；没有文件就建一个只有 frontmatter 的。
    @discardableResult
    func setMood(_ mood: JournalMood?, date: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        var doc = loadUnlocked(date: date) ?? JournalDocument(frontmatter: ["date: \(date)"], body: "", diskHash: nil)
        if doc.frontmatter.isEmpty { doc.frontmatter = ["date: \(date)"] }
        doc.setMood(mood)
        return try writeUnlocked(doc, date: date)
    }

    // MARK: 模板（plan §3.1：只在第一次点开写的时候展开）

    static let defaultTemplate = """
    ## 今天

    ## 想记住的
    """

    /// 返回 (frontmatter 行, 正文)，展开日期和星期占位符。
    static func expandTemplate(_ template: String, date: String, weekday: String) -> (frontmatter: [String], body: String) {
        let body = "# \(date) \(weekday)\n\n" + template
            .replacingOccurrences(of: "{{date}}", with: date)
            .replacingOccurrences(of: "{{weekday}}", with: weekday)
        return (["date: \(date)", "mood:"], body)
    }
}
