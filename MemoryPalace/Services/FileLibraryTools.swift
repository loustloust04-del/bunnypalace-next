import Foundation

/// 文件库工具定义（API 下发）+ executor（tool_call → FileLibraryStore → 回灌文本）。
enum FileLibraryTools {
    /// system prompt 注入的默认模板（设置页可改）。占位符 {{files}} / {{fileContents}}，外层自动包 <文件库>。
    static let defaultInjectionTemplate = """
    你有一个持久的文本/Markdown/HTML 文件库，可用 fs_list / fs_read / fs_search / fs_write / fs_append / fs_edit 工具读写（改名、删文件用〔更多工具〕里的 fs_rename / fs_delete），用来放笔记、文档、草稿。文件内容不会自动注入——需要看内容时用 fs_read 读取（包括你自己之前写过的文件）。

    当前文件：
    {{files}}{{fileContents}}
    """

    /// 工具名（API 下发 + 回灌时匹配）
    enum Name: String, CaseIterable {
        case list = "fs_list", read = "fs_read", search = "fs_search"
        case write = "fs_write", append = "fs_append", edit = "fs_edit", rename = "fs_rename", delete = "fs_delete"
    }

    /// 每个工具的 (描述, JSON-schema properties, required)
    private static let specs: [(Name, String, [String: Any], [String])] = [
        (.list,   "列出文件库与楼层记忆树（memory/ 前缀，只读）里所有文本文件（路径+大小），不读内容", [:], []),
        (.read,   "读取文件内容。默认从第 1 行起，最多返回 \(ToolResultOffload.maxLines) 行 / \(ToolResultOffload.formatSize(ToolResultOffload.maxBytes))，超出会截断并告诉你续读位置；大文件用 offset/limit 分段读，要全文就用 offset 一直续读到完",
                  ["path": ["type": "string", "description": "相对路径，如 notes/todo.md；memory/ 与 tool-results/ 前缀是只读区"],
                   "offset": ["type": "integer", "description": "起始行号（1 起）"],
                   "limit": ["type": "integer", "description": "最多读多少行"]], ["path"]),
        (.search, "跨所有文件按关键词搜索，返回命中文件与行", ["keyword": ["type": "string"]], ["keyword"]),
        (.write,  "新建或整文件覆盖写入", ["path": ["type": "string"], "content": ["type": "string"]], ["path", "content"]),
        (.append, "在文件末尾追加内容；文件不存在时创建", ["path": ["type": "string"], "content": ["type": "string"]], ["path", "content"]),
        (.edit,   "把文件里唯一命中的 old_string 替换成 new_string", ["path": ["type": "string"], "old_string": ["type": "string"], "new_string": ["type": "string"]], ["path", "old_string", "new_string"]),
        (.rename, "重命名或移动某个文件；目标已存在时会失败", ["old_path": ["type": "string"], "new_path": ["type": "string"]], ["old_path", "new_path"]),
        (.delete, "删除某个文件", ["path": ["type": "string"]], ["path"]),
    ]

    /// 统一定义（双家渲染走 ToolSchemaRenderer，注入走 ToolRegistry）
    static var definitions: [ToolDefinition] {
        specs.map { (name, desc, props, req) in
            ToolDefinition(name: name.rawValue, description: desc, properties: props, required: req)
        }
    }

    // MARK: - Executor

    struct Result { let text: String; let isError: Bool }

    /// name + inputJSON(字符串) → 执行 → 回灌文本。失败也返回文本+isError，让模型自愈。
    static func execute(name: String, inputJSON: String, profileId: String) -> Result {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("FileLibraryTools.execute") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]

        // memory/ 只读记忆树：读放行（映射 memoryRoot），写一律拒（plan-memory-tree-v1 刀2，v1 只读）
        let memPrefix = FileLibraryStore.memoryVirtualPrefix
        let pathArgs = ["path", "old_path", "new_path"].compactMap { args[$0] as? String }
        if pathArgs.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(memPrefix) }) {
            switch Name(rawValue: name) {
            case .read:
                do { return readResult(try FileLibraryStore.memoryRead(str(args, "path"), profileId: profileId), args: args) }
                catch { return Result(text: "工具执行失败: \(error.localizedDescription)", isError: true) }
            case .write, .append, .edit, .rename, .delete:
                return Result(text: SelfMemoryTool.enabled
                    ? "fs_* 工具对 memory/ 只读。改你自己的记忆（memory/self/）用 remember / edit_memory / forget_memory，资料卡用 update_profile_card；其它是系统生成的，不能改。"
                    : "fs_* 工具对 memory/ 只读。资料卡用 update_profile_card 改；其它是系统生成的，不能改。", isError: true)
            default:
                break
            }
        }
        // tool-results/ 只读存档（plan-B4 D2）：过长工具结果的全文，读放行、写一律拒
        let trPrefix = FileLibraryStore.toolResultsVirtualPrefix
        if pathArgs.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(trPrefix) }) {
            switch Name(rawValue: name) {
            case .read:
                do { return readResult(try FileLibraryStore.toolResultRead(str(args, "path"), profileId: profileId), args: args) }
                catch { return Result(text: "工具执行失败: \(error.localizedDescription)", isError: true) }
            case .write, .append, .edit, .rename, .delete:
                return Result(text: "tool-results/ 是过长工具结果的存档，只读。用 fs_read(path, offset, limit) 分段读。", isError: true)
            default:
                break
            }
        }

        // 日历受保护文件夹（plan-calendar §4.3）：journal/ 按楼层闸隐藏且只读，calendar/ 只读。
        // 在规范化后的真实路径上判定，./journal、JOURNAL、a/../journal、改名移进移出都挡得住
        let writes: Set<Name> = [.write, .append, .edit, .rename, .delete]
        let isWrite = Name(rawValue: name).map { writes.contains($0) } ?? false
        for p in pathArgs {
            if let msg = FileLibraryAccess.denial(isWrite ? .write : .read, path: p, profileId: profileId) {
                return Result(text: msg, isError: true)
            }
        }

        do {
            switch Name(rawValue: name) {
            case .list:
                let items = (FileLibraryStore.list(profileId: profileId) + FileLibraryStore.memoryList(profileId: profileId))
                    .filter { FileLibraryAccess.visible($0.path, profileId: profileId) }
                return ok(items.isEmpty ? "（空文件库）" : items.map { "\($0.path)  (\($0.bytes)B)" }.joined(separator: "\n"))
            case .read:
                return readResult(try FileLibraryStore.read(str(args, "path"), profileId: profileId), args: args)
            case .search:
                let hits = (FileLibraryStore.search(str(args, "keyword"), profileId: profileId)
                    + FileLibraryStore.memorySearch(str(args, "keyword"), profileId: profileId))
                    .filter { FileLibraryAccess.visible($0.path, profileId: profileId) }
                return ok(hits.isEmpty ? "无命中" : hits.map { "\($0.path): \($0.line)" }.joined(separator: "\n"))
            case .write:
                let path = str(args, "path")
                let before = try? FileLibraryStore.read(path, profileId: profileId)
                try FileLibraryStore.write(path, content: str(args, "content"), profileId: profileId)
                let after = try? FileLibraryStore.read(path, profileId: profileId)
                return ok(fileChangeResult(title: before == nil ? "已创建" : "已写入", path: path, before: before, after: after))
            case .append:
                let path = str(args, "path")
                let before = try? FileLibraryStore.read(path, profileId: profileId)
                try FileLibraryStore.append(path, content: str(args, "content"), profileId: profileId)
                let after = try? FileLibraryStore.read(path, profileId: profileId)
                return ok(fileChangeResult(title: "已追加", path: path, before: before, after: after))
            case .edit:
                let path = str(args, "path")
                let before = try? FileLibraryStore.read(path, profileId: profileId)
                try FileLibraryStore.edit(path, oldString: str(args, "old_string"), newString: str(args, "new_string"), profileId: profileId)
                let after = try? FileLibraryStore.read(path, profileId: profileId)
                return ok(fileChangeResult(title: "已修改", path: path, before: before, after: after))
            case .rename:
                let oldPath = str(args, "old_path")
                let newPath = str(args, "new_path")
                let before = try? FileLibraryStore.read(oldPath, profileId: profileId)
                try FileLibraryStore.rename(oldPath, to: newPath, profileId: profileId)
                return ok(renameSummary(oldPath: oldPath, newPath: newPath, before: before))
            case .delete:
                let path = str(args, "path")
                let before = try? FileLibraryStore.read(path, profileId: profileId)
                try FileLibraryStore.delete(path, profileId: profileId)
                return ok(deleteSummary(path: path, before: before))
            case .none:
                return Result(text: "未知工具: \(name)", isError: true)
            }
        } catch {
            return Result(text: "工具执行失败: \(error.localizedDescription)", isError: true)
        }
    }

    private static let diffContextLines = 2
    private static let diffMaxLines = 80
    private static let diffMaxLineLength = 240
    private static let diffMaxCharacters = 8000
    private static let deletePreviewMaxCharacters = 500

    private static func fileChangeResult(title: String, path: String, before: String?, after: String?) -> String {
        var lines = ["\(title) \(path)"]
        guard let after else {
            lines.append("（无法生成 diff：写入后未能读取文件）")
            return lines.joined(separator: "\n")
        }
        if let before {
            lines.append("")
            lines.append(compactLineDiff(before: before, after: after, path: path))
        } else {
            lines.append("")
            lines.append(compactLineDiff(before: "", after: after, path: path))
        }
        return lines.joined(separator: "\n")
    }

    private static func renameSummary(oldPath: String, newPath: String, before: String?) -> String {
        var lines = ["已重命名 \(oldPath) → \(newPath)"]
        if let before {
            lines.append("大小：\(before.utf8.count)B")
        }
        return lines.joined(separator: "\n")
    }

    private static func deleteSummary(path: String, before: String?) -> String {
        var lines = ["已删除 \(path)"]
        guard let before else { return lines.joined(separator: "\n") }
        lines.append("原大小：\(before.utf8.count)B")
        let preview = trimText(before, maxCharacters: deletePreviewMaxCharacters)
        if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("原预览：")
            lines.append(preview)
        }
        return lines.joined(separator: "\n")
    }

    private static func compactLineDiff(before: String, after: String, path: String) -> String {
        if before == after { return "（内容未变化）" }

        let beforeLines = before.isEmpty ? [] : before.components(separatedBy: .newlines)
        let afterLines = after.isEmpty ? [] : after.components(separatedBy: .newlines)
        var prefix = 0
        while prefix < beforeLines.count,
              prefix < afterLines.count,
              beforeLines[prefix] == afterLines[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < beforeLines.count - prefix,
              suffix < afterLines.count - prefix,
              beforeLines[beforeLines.count - 1 - suffix] == afterLines[afterLines.count - 1 - suffix] {
            suffix += 1
        }

        let beforeChangeEnd = beforeLines.count - suffix
        let afterChangeEnd = afterLines.count - suffix
        let contextStart = max(0, prefix - diffContextLines)
        let afterContextEnd = min(afterLines.count, afterChangeEnd + diffContextLines)

        var output: [String] = ["@@ \(path)"]
        for index in contextStart..<prefix {
            output.append("  " + trimDiffLine(beforeLines[index]))
        }
        if prefix < beforeChangeEnd {
            for index in prefix..<beforeChangeEnd {
                output.append("- " + trimDiffLine(beforeLines[index]))
            }
        }
        if prefix < afterChangeEnd {
            for index in prefix..<afterChangeEnd {
                output.append("+ " + trimDiffLine(afterLines[index]))
            }
        }
        if suffix > 0 {
            let afterTailStart = max(afterChangeEnd, afterContextEnd - diffContextLines)
            if afterTailStart < afterContextEnd {
                for index in afterTailStart..<afterContextEnd {
                    output.append("  " + trimDiffLine(afterLines[index]))
                }
            }
        }

        return limitedDiff(output)
    }

    private static func trimDiffLine(_ line: String) -> String {
        trimText(line, maxCharacters: diffMaxLineLength)
    }

    private static func trimText(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "…"
    }

    private static func limitedDiff(_ lines: [String]) -> String {
        var output: [String] = []
        var characterCount = 0
        var truncated = false
        for line in lines {
            if output.count >= diffMaxLines || characterCount + line.count > diffMaxCharacters {
                truncated = true
                break
            }
            output.append(line)
            characterCount += line.count + 1
        }
        if truncated { output.append("…（diff 已截断）") }
        return output.joined(separator: "\n")
    }

    private static func ok(_ t: String) -> Result { Result(text: t, isError: false) }
    private static func str(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
    /// JSON 数字可能是 Int / Double / NSNumber，统一取整
    private static func int(_ d: [String: Any], _ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }

    /// fs_read 三种路径共用：范围读 + 头截 + 续读尾注（plan-B4 D3；实现在 ToolResultOffload.fileRead）
    private static func readResult(_ text: String, args: [String: Any]) -> Result {
        let r = ToolResultOffload.fileRead(text: text, path: str(args, "path"), offset: int(args, "offset"), limit: int(args, "limit"))
        return Result(text: r.text, isError: r.isError)
    }
}
