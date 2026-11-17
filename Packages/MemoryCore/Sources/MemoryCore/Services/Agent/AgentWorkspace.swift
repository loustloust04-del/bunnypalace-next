import Foundation

/// 后台 agent 的工作台（plan-agent-workspace §2.2）：一个根目录 + 列 / 读 / 写 / 改 / 搜 五个通用工具。
/// 看不到根目录以外的任何东西；只有 `writable` 列的目录能写，其余（材料）只读。没有 shell、没有网络
public struct AgentWorkspace: Sendable {
    public let root: URL
    /// 能写的顶层目录名（如 `out`、`notes`）
    public let writable: [String]
    public var readLines = 400
    public var readChars = 30_000
    public var searchHits = 60

    public init(root: URL, writable: [String]) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.writable = writable
    }

    public enum Refusal: Error, Equatable {
        case outside
        case readOnly
    }

    /// 相对路径 → 根目录里的真实位置。两边都解掉 symlink 再判前缀，出了根就拒
    public func resolve(_ path: String, forWriting: Bool = false) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let relative = trimmed.hasPrefix("/") ? String(trimmed.drop(while: { $0 == "/" })) : trimmed
        let url = (relative.isEmpty ? root : root.appendingPathComponent(relative)).standardizedFileURL
        // 文件还不存在时解它已存在的那截父目录
        var probe = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            tail.insert(probe.lastPathComponent, at: 0)
            probe.deleteLastPathComponent()
        }
        let real = tail.reduce(probe.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        guard real.path == root.path || real.path.hasPrefix(root.path + "/") else { throw Refusal.outside }
        if forWriting {
            let inside = String(real.path.dropFirst(root.path.count + 1))
            guard let top = inside.split(separator: "/").first.map(String.init), writable.contains(top), inside != top else { throw Refusal.readOnly }
        }
        return real
    }

    private func shown(_ url: URL) -> String {
        url.path == root.path ? "." : String(url.path.dropFirst(root.path.count + 1))
    }

    private static func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func lines(_ text: String) -> [Substring] {
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        if rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }

    // MARK: - 五个动作（返回给模型看的文字）

    public func list(_ path: String) -> AgentToolOutput {
        guard let dir = try? resolve(path) else { return .init("这个路径不在工作台里", isError: true) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .init("没有这个目录：\(path)", isError: true)
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        guard !names.isEmpty else { return .init("（空目录）") }
        let rows = names.map { name -> String in
            let url = dir.appendingPathComponent(name)
            var sub: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &sub)
            if sub.boolValue {
                let count = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).count
                return "\(shown(url))/  （目录，\(count) 项\(writable.contains(shown(url)) ? "，可写" : "")）"
            }
            let body = Self.text(url)
            return "\(shown(url))  （\(body.map { "\(Self.lines($0).count) 行，\($0.count) 字" } ?? "不是文本")）"
        }
        return .init(rows.joined(separator: "\n"))
    }

    public func read(_ path: String, from: Int?, count: Int?) -> AgentToolOutput {
        guard let url = try? resolve(path) else { return .init("这个路径不在工作台里", isError: true) }
        guard let body = Self.text(url) else { return .init("读不了：\(path)（不存在或不是文本）", isError: true) }
        let rows = Self.lines(body)
        guard !rows.isEmpty else { return .init("（空文件）") }
        let start = max(from ?? 1, 1)
        guard start <= rows.count else { return .init("这个文件只有 \(rows.count) 行。", isError: true) }
        var out: [String] = []
        var used = 0
        for row in rows.dropFirst(start - 1).prefix(min(max(count ?? readLines, 1), readLines)) {
            used += row.count + 1
            if used > readChars, !out.isEmpty { break }
            out.append(String(row))
        }
        let last = start + out.count - 1
        let tail = last < rows.count ? "下一页 from_line=\(last + 1)" : "已经到底"
        return .init(out.joined(separator: "\n") + "\n\n（\(shown(url)) 第 \(start)–\(last) 行，共 \(rows.count) 行，\(tail)）")
    }

    public func write(_ path: String, content: String) -> AgentToolOutput {
        do {
            let url = try resolve(path, forWriting: true)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            return .init("写好了：\(shown(url))（\(Self.lines(content).count) 行，\(content.count) 字）")
        } catch Refusal.readOnly {
            return .init("这里不能写。能写的目录：\(writable.map { $0 + "/" }.joined(separator: "、"))", isError: true)
        } catch Refusal.outside {
            return .init("这个路径不在工作台里", isError: true)
        } catch {
            return .init("没写上：\(error.localizedDescription)", isError: true)
        }
    }

    public func edit(_ path: String, old: String, new: String) -> AgentToolOutput {
        guard !old.isEmpty else { return .init("old 不能是空的", isError: true) }
        do {
            let url = try resolve(path, forWriting: true)
            guard let body = Self.text(url) else { return .init("读不了：\(path)", isError: true) }
            let hits = body.components(separatedBy: old).count - 1
            guard hits == 1 else {
                return .init(hits == 0 ? "文件里没找到 old 这一段（要和文件里的一字不差）" : "old 这一段在文件里出现了 \(hits) 次，多带些上下文让它只出现一次", isError: true)
            }
            try Data(body.replacingOccurrences(of: old, with: new).utf8).write(to: url, options: .atomic)
            return .init("改好了：\(shown(url))")
        } catch Refusal.readOnly {
            return .init("这里不能改。能写的目录：\(writable.map { $0 + "/" }.joined(separator: "、"))", isError: true)
        } catch Refusal.outside {
            return .init("这个路径不在工作台里", isError: true)
        } catch {
            return .init("没改上：\(error.localizedDescription)", isError: true)
        }
    }

    public func search(_ terms: String, in path: String?) -> AgentToolOutput {
        let needle = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .init("terms 不能是空的", isError: true) }
        guard let base = try? resolve(path ?? "") else { return .init("这个路径不在工作台里", isError: true) }
        var files: [URL] = []
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else { return .init("没有这个路径：\(path ?? "")", isError: true) }
        if isDirectory.boolValue {
            let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let url = walker?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
            }
            files.sort { $0.path < $1.path }
        } else {
            files = [base]
        }
        var out: [String] = []
        var total = 0
        for url in files {
            guard let body = Self.text(url) else { continue }
            for (index, row) in Self.lines(body).enumerated() where row.range(of: needle, options: .caseInsensitive) != nil {
                total += 1
                if out.count < searchHits { out.append("\(shown(url)):\(index + 1): \(row.count > 300 ? row.prefix(300) + "…" : row)") }
            }
        }
        guard total > 0 else { return .init("没搜到「\(needle)」。") }
        return .init(out.joined(separator: "\n") + (total > out.count ? "\n\n（一共 \(total) 处，只列了前 \(out.count) 处；缩小范围或换个词）" : ""))
    }

    // MARK: - 做成工具

    private struct PathArgs: Decodable { var path: String? }
    private struct ReadArgs: Decodable { var path: String; var from_line: Int?; var lines: Int? }
    private struct WriteArgs: Decodable { var path: String; var content: String }
    private struct EditArgs: Decodable { var path: String; var old: String; var new: String }
    private struct SearchArgs: Decodable { var terms: String; var path: String? }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? JSONDecoder().decode(type, from: Data((text.isEmpty ? "{}" : text).utf8))
    }

    public var tools: [AgentTool] {
        [
            AgentTool(name: "list", description: "列一个目录里有什么（名字、行数、字数）。不给 path 就是工作台的根。",
                      schema: #"{"type":"object","properties":{"path":{"type":"string"}}}"#) { [self] json in
                list(Self.decode(PathArgs.self, json)?.path ?? "")
            },
            AgentTool(name: "read", description: "读一个文本文件。长文件分页读：from_line 从第几行开始，lines 读几行。",
                      schema: #"{"type":"object","properties":{"path":{"type":"string"},"from_line":{"type":"integer","description":"默认 1"},"lines":{"type":"integer","description":"默认读到一页的上限"}},"required":["path"]}"#) { [self] json in
                guard let args = Self.decode(ReadArgs.self, json) else { return .init("参数要 {\"path\": \"…\"}", isError: true) }
                return read(args.path, from: args.from_line, count: args.lines)
            },
            AgentTool(name: "write", description: "整个写一个文件（已有就覆盖）。只能写在可写的目录里。",
                      schema: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#) { [self] json in
                guard let args = Self.decode(WriteArgs.self, json) else { return .init("参数要 {\"path\": \"…\", \"content\": \"…\"}，这次的 JSON 读不懂", isError: true) }
                return write(args.path, content: args.content)
            },
            AgentTool(name: "edit", description: "把文件里的一段换成另一段。old 要和文件里的一字不差，并且只出现一次。",
                      schema: #"{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"}},"required":["path","old","new"]}"#) { [self] json in
                guard let args = Self.decode(EditArgs.self, json) else { return .init("参数要 {\"path\", \"old\", \"new\"}，这次的 JSON 读不懂", isError: true) }
                return edit(args.path, old: args.old, new: args.new)
            },
            AgentTool(name: "search", description: "按词在文件里搜（不分大小写），返回 文件:行号: 那一行。不给 path 就搜整个工作台。",
                      schema: #"{"type":"object","properties":{"terms":{"type":"string"},"path":{"type":"string","description":"只搜这个文件或目录"}},"required":["terms"]}"#) { [self] json in
                guard let args = Self.decode(SearchArgs.self, json) else { return .init("参数要 {\"terms\": \"…\"}", isError: true) }
                return search(args.terms, in: args.path)
            },
        ]
    }
}
