import MemoryCore
import Foundation

/// CC 原料（种子读的 CC 记忆文件，private_ 的不打开）与种子完成记录；文件 IO 由调用方放后台。
enum CatalogSeed {
    struct Source: Equatable, Sendable {
        let name: String
        let type: String
        let title: String
        let body: String

        var path: String { "memory/cc/" + name }
    }

    enum Skip: String, Error {
        case privateFile = "private_"
        case empty = "正文为空"
        case unreadable = "不是可读的普通 Markdown 文件"
    }

    struct Scan: Sendable {
        var sources: [Source] = []
        var notes: [String] = []
        var skipped: [String] = []
    }

    static func read(name: String, text: String) throws -> Source {
        if CCMemorySync.isExcluded(name: name) { throw Skip.privateFile }
        let raw = CCMemorySync.unwrap(text).replacingOccurrences(of: "\r\n", with: "\n")
        var bodyLines = raw.components(separatedBy: "\n")[...]
        var header: ArraySlice<String> = []
        if bodyLines.first.map(isFrontmatterDelimiter) == true,
           let end = bodyLines.dropFirst().firstIndex(where: isFrontmatterDelimiter),
           isMetadataBlock(bodyLines[1..<end]) {
            header = bodyLines[1..<end]
            bodyLines = bodyLines[(end + 1)...]
        }
        let headings = bodyLines.compactMap(levelOneHeading)
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Skip.empty }
        var fields: [String: String] = [:]
        var inMetadata = false
        for line in header {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { continue }
            var key = String(trimmed[..<colon])
            let value = scalar(String(trimmed[trimmed.index(after: colon)...]))
            if line.first != " " && line.first != "\t" {
                inMetadata = key == "metadata" && value == nil
            } else if inMetadata, key == "type" {
                key = "metadata.type"
            } else {
                continue
            }
            if fields[key] == nil, let value { fields[key] = value }
        }
        let type = (fields["type"] ?? fields["metadata.type"])?.lowercased() ?? "未标注"
        let fallback = String(name.dropLast(3))
        return Source(name: name, type: type, title: fields["title"] ?? fields["name"] ?? headings.first ?? fallback, body: body)
    }

    private static func isFrontmatterDelimiter(_ line: String) -> Bool {
        line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 两条 --- 中间确实是元数据映射才当 frontmatter 剥；认不出就是正文。按结构核：
    /// 顶格 `key: value`；独立的 # 注释行照收；缩进行只能接在值空着或块标量（| >）的 key 后面，
    /// 顶格列表项只能接在值空着的 key 后面（属于那个 key 的块值 / 列表），不是见过一个 key 就全放过
    private static func isMetadataBlock(_ lines: ArraySlice<String>) -> Bool {
        var sawKey = false
        var nestedOK = false
        var listOK = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first == " " || line.first == "\t" {
                guard nestedOK else { return false }
                continue
            }
            if trimmed == "-" || trimmed.hasPrefix("- ") {
                guard listOK else { return false }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { return false }
            let key = trimmed[..<colon]
            let after = trimmed[trimmed.index(after: colon)...]
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }),
                  after.isEmpty || after.first == " " || after.first == "\t" else { return false }
            let value = after.trimmingCharacters(in: .whitespaces)
            listOK = value.isEmpty || value.hasPrefix("#")
            nestedOK = listOK || value.hasPrefix("|") || value.hasPrefix(">")
            sawKey = true
        }
        return sawKey
    }

    private static func levelOneHeading(_ line: String) -> String? {
        let spaces = line.prefix(while: { $0 == " " }).count
        guard spaces <= 3 else { return nil }
        let content = line.dropFirst(spaces)
        guard content.first == "#" else { return nil }
        let rest = content.dropFirst()
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = String(rest).trimmingCharacters(in: .whitespaces)
        if title.last == "#" {
            let hashes = title.reversed().prefix(while: { $0 == "#" }).count
            let prefix = title.dropLast(hashes)
            if prefix.isEmpty || prefix.last == " " || prefix.last == "\t" {
                title = String(prefix).trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    private static func scalar(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let first = value.first, first == "\"" || first == "'" {
            guard let end = value.dropFirst().firstIndex(of: first) else { return nil }
            let tail = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
            let text = String(value[value.index(after: value.startIndex)..<end])
            return text.isEmpty ? nil : text
        }
        let text = value.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !["|", ">", "{", "[", "&", "*", "!"].contains(where: text.hasPrefix) else { return nil }
        return text
    }

    static func load(memoryRoot: URL, readText: (URL) throws -> String = CCMemorySync.readNoFollow) throws -> Scan {
        let dir = memoryRoot.appendingPathComponent(CCMemorySync.subdir, isDirectory: true)
        var scan = Scan()
        func skip(_ name: String, reason: Skip, index: Int? = nil) {
            let safeName = name.components(separatedBy: .newlines).joined(separator: " ")
            scan.skipped.append("\(safeName) · \(reason.rawValue)")
            scan.notes.append("CC \(index.map { "第 \($0 + 1) 份" } ?? "目录")：跳过 · \(reason.rawValue)")
        }
        let directoryType: FileAttributeType?
        do {
            directoryType = try FileManager.default.attributesOfItem(atPath: dir.path)[.type] as? FileAttributeType
        } catch {
            let error = error as NSError
            if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
                skip(dir.lastPathComponent, reason: .unreadable)
            }
            return scan
        }
        let resolvedRoot = memoryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedDirectory = dir.resolvingSymlinksInPath().standardizedFileURL.path
        guard directoryType == .typeDirectory,
              resolvedDirectory.hasPrefix(resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/") else {
            skip(dir.lastPathComponent, reason: .unreadable)
            return scan
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            skip(dir.lastPathComponent, reason: .unreadable)
            return scan
        }
        var privateCount = 0
        for (index, file) in files.enumerated() where file.pathExtension.lowercased() == "md" {
            if CCMemorySync.isExcluded(name: file.lastPathComponent) {
                privateCount += 1
                continue
            }
            do {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Skip.unreadable }
                let text = try readText(file)
                let source = try read(name: file.lastPathComponent, text: text)
                scan.sources.append(source)
                scan.notes.append("CC 第 \(index + 1) 份：接收 \(source.type) 原料")
            } catch {
                skip(file.lastPathComponent, reason: error as? Skip ?? .unreadable, index: index)
            }
        }
        if privateCount > 0 {
            let summary = "跳过 \(privateCount) 份私人文件（private_）"
            scan.skipped.append(summary)
            scan.notes.append(summary)
        }
        return scan
    }

    /// 完成标记：新任务带 taskId；旧种子只有 completedAt（第 6 段一次性清掉）
    private struct State: Codable {
        var completedAt: Date
        var taskId: String?
    }

    static let stateFileName = ".seed-state.json"

    static func stateURL(_ wiki: WikiStore) -> URL {
        wiki.root.appendingPathComponent(WikiStore.proposalsFolder, isDirectory: true).appendingPathComponent(stateFileName)
    }

    /// 完成标记的读写恢复都走 `SafeWiki`：楼层目录 / wiki 根 / .proposals 是链接、标记文件是链接 = 读不到、写不进、不删
    private static let stateParts = [WikiStore.proposalsFolder]

    /// 新种子任务的完成（整份目录处理完、获批页都交了正文）；旧格式不算，界面不再被它拦住
    static func completion(wiki: WikiStore) -> (at: Date, taskId: String)? {
        guard let data = SafeWiki.read(stateFileName, in: stateParts, under: wiki.root), let state = try? JSONDecoder().decode(State.self, from: data),
              let taskId = state.taskId else { return nil }
        return (state.completedAt, taskId)
    }

    /// 有旧种子的完成标记（文件在、但不是新任务写的）
    static func isLegacyState(wiki: WikiStore) -> Bool {
        MemoryRegeneration.itemExists(stateURL(wiki)) && completion(wiki: wiki) == nil
    }

    /// 写完成标记前的原样（没有 = nil），点了停时用它恢复
    static func stateData(wiki: WikiStore) -> Data? {
        SafeWiki.read(stateFileName, in: stateParts, under: wiki.root)
    }

    static func restoreState(wiki: WikiStore, data: Data?) throws {
        if let data {
            try SafeWiki.write(data, name: stateFileName, in: stateParts, under: wiki.root)
        } else {
            try SafeWiki.remove(stateFileName, in: stateParts, under: wiki.root)
        }
    }

    static func finish(wiki: WikiStore, at date: Date, taskId: String) throws {
        try SafeWiki.write(JSONEncoder().encode(State(completedAt: date, taskId: taskId)), name: stateFileName, in: stateParts, under: wiki.root)
    }
}
