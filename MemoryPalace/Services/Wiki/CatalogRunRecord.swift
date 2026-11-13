import MemoryCore
import Foundation


final class CatalogRunRecord: @unchecked Sendable {
    static let folderName = ".runs"
    static let keepDays = 30
    static let expiredMessage = "这次整理的记录已经清掉了（只留 30 天）"

    let relativePath: String
    let url: URL
    private let queue = DispatchQueue(label: "memorypalace.catalog-run", qos: .utility)
    private let lock = NSLock()
    private var lastAnchor: String?

    var latestAnchor: String? { lock.withLock { lastAnchor } }

    private static func fileName(_ topic: String, _ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: now) + "-" + CatalogDrafts.safeName(topic) + "-" + UUID().uuidString + ".md"
    }

    init(wiki: WikiStore, topic: String, kind: String, now: Date = Date()) {
        relativePath = Self.folderName + "/" + Self.fileName(topic, now)
        url = wiki.root.appendingPathComponent(relativePath)
        let target = url
        let heading = "# C3 整理记录 · \(Self.heading(topic))\n\n方式：\(Self.heading(kind))\n\n时间：\(ISO8601DateFormatter().string(from: now))\n\n"
        queue.async {
            Self.prune(wiki: wiki, now: now)
            do { try WikiStore.writeAtomic(Data(heading.utf8), to: target) }
            catch { Self.report(error) }
        }
    }

    /// 种子任务批了 / 点了继续：接着写同一份记录、同一个轮号往下记。被 30 天清理删了就在原路径重建（头上注明），不另起一份
    init(wiki: WikiStore, continuing link: CatalogRunLink, topic: String, now: Date = Date()) {
        let parts = link.path.split(separator: "/", omittingEmptySubsequences: false)
        let valid = parts.count == 2 && parts[0] == Substring(Self.folderName) && parts[1].hasSuffix(".md")
            && !parts[1].hasPrefix(".") && !parts[1].contains("\\")
        relativePath = valid ? link.path : Self.folderName + "/" + Self.fileName(topic, now)
        url = wiki.root.appendingPathComponent(relativePath)
        let target = url
        let heading = "# C3 整理记录 · \(Self.heading(topic))\n\n（接着同一个任务记；前面的部分不在了，是过了 30 天被清掉的）\n\n"
        let resumed = "<a id=\"resume-\(UUID().uuidString)\"></a>\n\n## 接着同一个任务 · \(ISO8601DateFormatter().string(from: now))\n\n"
        queue.async {
            do {
                if !FileManager.default.fileExists(atPath: target.path) {
                    try WikiStore.writeAtomic(Data(heading.utf8), to: target)
                }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(resumed.utf8))
            } catch { Self.report(error) }
        }
    }

    func link(anchor: String? = nil) -> CatalogRunLink {
        CatalogRunLink(path: relativePath, anchor: anchor)
    }

    @discardableResult
    func section(_ title: String, body: String, anchor: String? = nil) -> String {
        let id = anchor ?? "step-" + UUID().uuidString
        lock.withLock { lastAnchor = id }
        let text = "<a id=\"\(id)\"></a>\n\n## \(Self.heading(title))\n\n\(body)\n\n"
        let target = url
        queue.async {
            do {
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
            } catch { Self.report(error) }
        }
        return id
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private static func heading(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        var escaped = ""
        escaped.reserveCapacity(singleLine.utf8.count)
        for character in singleLine {
            if "\\`*_{}[]<>()#+-.!|~&".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    static func code(_ text: String, language: String = "") -> String {
        var fence = "```"
        while text.contains(fence) { fence += "`" }
        return fence + language + "\n" + text + "\n" + fence
    }

    static let searchEvidencePrefix = "C3_SEARCH_EVIDENCE "

    func recordSearch(_ evidence: CatalogSearchEvidence) {
        guard let data = try? JSONEncoder().encode(evidence),
              let json = String(data: data, encoding: .utf8) else { return }
        section("检索正文统计", body: Self.searchEvidencePrefix + json)
    }

    static func searchEvidence(in text: String) -> [CatalogSearchEvidence] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix(searchEvidencePrefix) else { return nil }
            return try? JSONDecoder().decode(CatalogSearchEvidence.self, from: Data(line.dropFirst(searchEvidencePrefix.count).utf8))
        }
    }

    static func prune(wiki: WikiStore, now: Date) {
        let folder = wiki.root.appendingPathComponent(folderName, isDirectory: true)
        let cutoff = now.addingTimeInterval(-TimeInterval(keepDays) * 86_400)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? [] {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let date = values.contentModificationDate, date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func resolve(_ link: CatalogRunLink, wiki: WikiStore) -> URL? {
        let parts = link.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == Substring(folderName), !parts[1].isEmpty,
              parts[1] != ".", parts[1] != "..", parts[1].hasSuffix(".md") else { return nil }
        let candidate = wiki.root.appendingPathComponent(link.path)
        let resolvedRoot = wiki.root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard candidate.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return candidate
    }

    private static func report(_ error: Error) {
        CacheDiagLog.shared.log("📚 整理记录：写盘失败 — \(error.localizedDescription)")
    }
}
