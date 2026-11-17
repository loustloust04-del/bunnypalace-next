import MemoryCore
import Foundation
import SwiftData

/// 文件库工具定义（API 下发）+ executor（tool_call → FileLibraryStore → 回灌文本）。
enum FileLibraryTools {
    /// system prompt 注入的默认模板（设置页可改）。占位符 {{files}} / {{fileContents}}，外层自动包 <文件库>。
    static let defaultInjectionTemplate = """
    你有一个持久的文本/Markdown/HTML 文件库，可用 fs_list / fs_read / fs_search / fs_write / fs_append / fs_edit 工具读写（改名、删文件用〔更多工具〕里的 fs_rename / fs_delete），用来放笔记、文档、草稿。文件内容不会自动注入——需要看内容时用 fs_read 读取（包括你自己之前写过的文件）。

    当前文件：
    {{files}}{{fileContents}}
    """

    /// 默认模板里那句工具清单的原文（全开、改名 / 删除收在〔更多工具〕时一字不差）
    static let defaultToolSentence = "可用 fs_list / fs_read / fs_search / fs_write / fs_append / fs_edit 工具读写（改名、删文件用〔更多工具〕里的 fs_rename / fs_delete）"

    /// 只提这一轮能调到的 fs 工具（粟粟 10-15：关了的不带说明）；tucked = 收在〔更多工具〕里的
    static func toolSentence(available: Set<String>, tucked: Set<String>) -> String {
        let main = [Name.list, .read, .search, .write, .append, .edit].map(\.rawValue).filter(available.contains)
        let extra = [Name.rename, .delete].map(\.rawValue).filter(available.contains)
        var s = main.isEmpty ? "可用" : "可用 \(main.joined(separator: " / ")) 工具读写"
        if !extra.isEmpty {
            let what = extra.count == 2 ? "改名、删文件" : (extra[0] == Name.rename.rawValue ? "改名" : "删文件")
            let place = extra.allSatisfy(tucked.contains) ? "〔更多工具〕里的 " : " "
            s += main.isEmpty ? " \(extra.joined(separator: " / ")) 工具\(what)" : "（\(what)用\(place)\(extra.joined(separator: " / "))）"
        }
        return s
    }

    /// 工具名（API 下发 + 回灌时匹配）
    enum Name: String, CaseIterable {
        case list = "fs_list", read = "fs_read", search = "fs_search"
        case write = "fs_write", append = "fs_append", edit = "fs_edit", rename = "fs_rename", delete = "fs_delete"
    }

    static let writeNames: Set<Name> = [.write, .append, .edit, .rename, .delete]

    /// 楼层字段的文件名和它是哪一段（进 fs_list 的说明）
    private static let promptFieldList = PromptFolder.Field.allCases.map { "\($0.rawValue) = \($0.label)" }.joined(separator: " / ")

    /// 每个工具的 (描述, JSON-schema properties, required)
    private static let specs: [(Name, String, [String: Any], [String])] = [
        (.list,   "列出文件库、楼层记忆（memory/）和这一层 Prompt（\(PromptFolder.root)/）里所有文本文件（路径+大小），不读内容。\(PromptFolder.fieldsFolder)/ 下是楼层字段：\(promptFieldList)；\(PromptFolder.root)/ 下其余的是当前预设的插槽，每行后面标着是哪一段", [:], []),
        (.read,   "读取文件内容。默认从第 1 行起，最多返回 \(ToolResultOffload.maxLines) 行 / \(ToolResultOffload.formatSize(ToolResultOffload.maxBytes))，超出会截断并告诉你续读位置；大文件用 offset/limit 分段读，要全文就用 offset 一直续读到完",
                  ["path": ["type": "string", "description": "相对路径，如 notes/todo.md。memory/ 下是记忆，\(PromptFolder.root)/ 下是这一层的 Prompt；tool-results/ 前缀是只读区"],
                   "offset": ["type": "integer", "description": "起始行号（1 起）"],
                   "limit": ["type": "integer", "description": "最多读多少行"]], ["path"]),
        (.search, "跨所有文件按关键词搜索，返回命中文件与行", ["keyword": ["type": "string"]], ["keyword"]),
        (.write,  "新建或整文件覆盖写入。memory/ 下写文件 = 写那种记忆：memory/cards/<说的是谁>/<名字>.md 是记忆条目（开头两行 --- 之间一行一项：about / from / tags / importance / confidence / pinned / state，下面是一句正文；没写的项不动；新建一份 = 加一条，文件名会换成它的编号）；memory/self/<短标题>.md 是你自己的记忆；memory/pending/待续.md 是待续，一条一行「- 内容」；memory/wiki/<组>/<页>.md 是 wiki 页。\(PromptFolder.root)/ 下是这一层的 Prompt，只能改已有的那几份，对方的下一条消息起生效。格式不对会被拒并说明哪一行；对方可能要先点允许，被拒绝了就照实说。memory/ 里别的文件只读", ["path": ["type": "string"], "content": ["type": "string"]], ["path", "content"]),
        (.append, "在文件末尾追加内容；文件不存在时创建。memory/、\(PromptFolder.root)/ 下同 fs_write 的规矩", ["path": ["type": "string"], "content": ["type": "string"]], ["path", "content"]),
        (.edit,   "把文件里唯一命中的 old_string 替换成 new_string。memory/、\(PromptFolder.root)/ 下同 fs_write 的规矩（改记忆条目的一项、待续的一行、Prompt 的一段用它最省事）", ["path": ["type": "string"], "old_string": ["type": "string"], "new_string": ["type": "string"]], ["path", "old_string", "new_string"]),
        (.rename, "重命名或移动某个文件；目标已存在时会失败。memory/ 下只有记忆条目能挪：挪到另一个「说的是谁」文件夹 = 改 about，挪进 memory/cards/\(MemoryCardFolder.deletedFolder)/ = 删（能放回）", ["old_path": ["type": "string"], "new_path": ["type": "string"]], ["old_path", "new_path"]),
        (.delete, "删除某个文件。memory/ 下：删记忆条目 = 进 \(MemoryCardFolder.deletedFolder)（能放回），删 memory/self/ 的一份 = 标成失效，删 wiki 页 = 进已删除（能恢复）；\(PromptFolder.root)/ 下不能删", ["path": ["type": "string"]], ["path"]),
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
    /// userName = 楼层用户名：wiki 本人那组落盘是 {{user}}，模型看到 / 写的是名字——路径参数先还原成落盘写法再做一切检查，
    /// 回执里只有 wiki 的路径和 wiki 文件正文显示成名字（别的文件里的 {{user}} 宏原样）
    /// container 给了，记忆条目（`memory/cards/`，不在盘上）才读得到 / 列得出 / 搜得到；没给（这场对话关了「记忆参与」）= 只有盘上的和两份日志。
    /// promptFiles = 这一层 Prompt 文件夹的条目（`PromptFolderTools.files`，主线程先取好传进来）。
    /// 写 memory/ 和 Prompt 文件夹不在这里：走 `run`（要主线程的库和审计留痕）
    static func execute(name: String, inputJSON: String, profileId: String, userName: String = "", container: ModelContainer? = nil,
                        promptFiles: [PromptFolderTools.File] = []) -> Result {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("FileLibraryTools.execute") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        var args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        let shownArgs = args
        for key in ["path", "old_path", "new_path"] {
            if let p = args[key] as? String { args[key] = storedWikiPath(p, user: userName) }
        }
        let r = run(name: name, args: args, shownArgs: shownArgs, profileId: profileId, user: userName, container: container, promptFiles: promptFiles)
        return Result(text: r.text, isError: r.isError)
    }

    /// 聊天里的工具循环和 CC 那头（`MemoryCCBridge`）共用的入口。读类在后台跑；写 memory/ = 写那种记忆（`MemoryFolderWrite`），
    /// 写 Prompt 文件夹 = 改那一段（`PromptFolderTools`）；写文件库别处照旧。`actor` / `via` 记进各自的留痕
    @MainActor
    static func run(name: String, inputJSON: String, profileId: String, userName: String, actor: String, conversation: Conversation,
                    via: String = MemoryAuditLog.viaChat, source: MemoryCardTool.Source? = nil, context: ModelContext) async -> Result {
        await run(name: name, inputJSON: inputJSON, profileId: profileId, userName: userName, actor: actor,
                  conversationId: conversation.id, memoryEnabled: conversation.memoryEnabled, via: via, source: source, context: context)
    }

    /// 同上，不挂在哪一场对话上也能跑（CC 在电脑上直接改记忆文件夹里的文件，`GardenFolderInbox`）：`conversationId` nil = 没有对话
    @MainActor
    static func run(name: String, inputJSON: String, profileId: String, userName: String, actor: String, conversationId: String?,
                    memoryEnabled: Bool, via: String, source: MemoryCardTool.Source? = nil, context: ModelContext) async -> Result {
        let container = memoryEnabled ? context.container : nil
        guard let tool = Name(rawValue: name), writeNames.contains(tool) else {
            let promptFiles = PromptFolderTools.files(profileId: profileId)
            return await Task.detached(priority: .userInitiated) {
                execute(name: name, inputJSON: inputJSON, profileId: profileId, userName: userName, container: container, promptFiles: promptFiles)
            }.value
        }
        var args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        let shown = args
        for key in pathKeys {
            if let p = args[key] as? String { args[key] = storedWikiPath(p, user: userName) }
        }
        let paths = pathKeys.compactMap { (args[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if paths.contains(where: PromptFolder.isPromptPath) {
            return await PromptFolderTools.write(tool: tool, args: args, profileId: profileId, actor: actor)
        }
        if paths.contains(where: { $0.hasPrefix(FileLibraryStore.memoryVirtualPrefix) }) {
            let writer = MemoryFolderWrite.Writer(actor: actor, via: via, conversationId: conversationId, memoryEnabled: memoryEnabled, source: source)
            return await MemoryFolderWrite.execute(tool: tool, args: args, shown: shown, profileId: profileId, userName: userName,
                                                   writer: writer, context: context)
        }
        // 改文件：改之前那份、改之后那份都进版本历史（plan-webapp-as-file §2.3），编辑器「版本历史」和桌面应用的历史都看得到
        let raw = [Name.write, .append, .edit].contains(tool) ? args["path"] as? String : nil
        let (edited, before) = MainThreadIO.tolerated("#033 AI 文件工具主线程执行") { () -> (String?, String?) in
            guard let path = raw.flatMap({ versionPath($0, profileId: profileId) }) else { return (nil, nil) }
            return (path, try? FileLibraryStore.read(path, profileId: profileId))
        }
        let result = MainThreadIO.tolerated("#033 AI 文件工具主线程执行") {
            execute(name: name, inputJSON: inputJSON, profileId: profileId, userName: userName, container: container)
        }
        if let edited, !result.isError {
            let key = FileVersionStore.Key.file(profileId: profileId, relativePath: edited)
            let after = await Task.detached { try? FileLibraryStore.read(edited, profileId: profileId) }.value
            if let before { _ = try? await FileVersionStore.shared.record(key: key, content: before, source: .external) }
            if let after { _ = try? await FileVersionStore.shared.record(key: key, content: after, source: .external, actor: actor) }
        }
        return result
    }

    /// 和文件库面板认的是同一个 key：库内相对路径（去掉 ./、a/../ 这种写法）
    static func versionPath(_ raw: String, profileId: String) -> String? {
        guard let url = FileLibraryStore.resolve(raw.trimmingCharacters(in: .whitespacesAndNewlines), profileId: profileId) else { return nil }
        let root = FileLibraryStore.libraryRoot(profileId: profileId).path + "/"
        guard url.path.hasPrefix(root) else { return nil }
        return String(url.path.dropFirst(root.count))
    }

    private static let pathKeys = ["path", "old_path", "new_path"]

    /// `memory/wiki/名字/…` → `memory/wiki/{{user}}/…`（别的路径原样）
    static func storedWikiPath(_ path: String, user: String) -> String {
        let t = path.trimmingCharacters(in: .whitespaces)
        let prefix = FileLibraryMemoryFolder.wikiFolder + "/"
        guard t.hasPrefix(prefix) else { return path }
        return prefix + WikiStore.stored(String(t.dropFirst(prefix.count)), user: user)
    }

    /// 一条文件库路径给模型看：wiki 里本人那组显示成名字
    static func shownPath(_ path: String, user: String) -> String {
        path.hasPrefix(FileLibraryMemoryFolder.wikiFolder + "/") ? WikiStore.shown(path, user: user) : path
    }

    /// 助手眼里 memory/ 下有哪些文件（落盘写法的路径）：盘上的 + 现排的（记忆条目、两份日志）+ wiki 的提案 / 要点卡 / 页历史
    /// （`MemoryRecordsFolder`，只读的投影），wiki 里点开头的不给。
    /// `fs_list` 和同步给 CC 的那棵树（`GardenTree`）列的是同一份
    static func memoryFiles(profileId: String, container: ModelContainer?) -> [FileLibraryStore.FileMeta] {
        (FileLibraryStore.memoryList(profileId: profileId) + MemoryVirtualFiles.list(profileId: profileId, container: container)
            + MemoryRecordsFolder.list(profileId: profileId))
            .filter { !FileLibraryMemoryFolder.isHiddenWikiPath($0.path) }
    }

    /// 助手读 memory/ 下一份读到的全文（落盘写法的路径；没截断）：`fs_read` 和 `GardenTree` 读的是同一份。
    /// nil = 没有这份 / 不给看；读盘出错照抛
    static func memoryText(_ path: String, profileId: String, user: String, container: ModelContainer?) throws -> String? {
        if hiddenFromAssistant(path) { return nil }
        if MemoryRecordsFolder.contains(path) { return MemoryRecordsFolder.read(path, profileId: profileId, user: user) }
        // 记忆条目、两份日志不在盘上，现排（`MemoryVirtualFiles`）
        if MemoryVirtualFiles.isVirtual(path) { return MemoryVirtualFiles.read(path, profileId: profileId, container: container) }
        let text = try FileLibraryStore.memoryRead(path, profileId: profileId)
        let isWiki = path.trimmingCharacters(in: .whitespaces).hasPrefix(FileLibraryMemoryFolder.wikiFolder + "/")
        return isWiki ? WikiStore.shown(text, user: user) : text
    }

    private static func run(name: String, args: [String: Any], shownArgs: [String: Any], profileId: String, user: String,
                            container: ModelContainer?, promptFiles: [PromptFolderTools.File]) -> Result {

        let memPrefix = FileLibraryStore.memoryVirtualPrefix
        let pathArgs = ["path", "old_path", "new_path"].compactMap { args[$0] as? String }
        // Prompt 文件夹（`.prompt/`，不在盘上）：读从传进来的那份取（没传 = 不经 `run` 的调用，照旧走下面受保护文件夹的拒绝）；写走上面那个 `run`
        if !promptFiles.isEmpty, Name(rawValue: name) == .read {
            let path = str(args, "path").trimmingCharacters(in: .whitespacesAndNewlines)
            if PromptFolder.isPromptPath(path) {
                guard let file = promptFiles.first(where: { $0.path == path }) else {
                    return Result(text: "工具执行失败: 没有这个文件: \(path)。先 fs_list 看 \(PromptFolder.root)/ 下有哪些", isError: true)
                }
                return readResult(file.content, args: shownArgs)
            }
        }
        // memory/ 记忆树：读在这里（映射 memoryRoot / 现排）；写 = 写那种记忆，走上面那个 `run` → `MemoryFolderWrite`
        if pathArgs.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(memPrefix) }) {
            switch Name(rawValue: name) {
            case .read:
                do {
                    guard let text = try memoryText(str(args, "path"), profileId: profileId, user: user, container: container) else {
                        return Result(text: "工具执行失败: 没有这个文件: \(str(shownArgs, "path"))", isError: true)
                    }
                    return readResult(text, args: shownArgs)
                } catch { return Result(text: "工具执行失败: \(WikiStore.shown(error.localizedDescription, user: user))", isError: true) }
            case .write, .append, .edit, .rename, .delete:
                // 不经 `run` 的调用（没有主线程的库和留痕可用）：这个入口对 memory/ 只读
                return Result(text: "这个入口对 memory/ 只读：写 memory/ 要走 FileLibraryTools.run。", isError: true)
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
                let items = (FileLibraryStore.list(profileId: profileId) + memoryFiles(profileId: profileId, container: container))
                    .filter { FileLibraryAccess.visible($0.path, profileId: profileId) && !FileLibraryMemoryFolder.isHiddenWikiPath($0.path) }
                // 桌面网页应用标出来（plan-webapp-as-file §2.7）：AI 改应用就改这个文件
                let apps = Dictionary(WebAppStore.storedApps(profileId: profileId).map { ($0.path, $0.title) }, uniquingKeysWith: { a, _ in a })
                let lines = items.map { item in
                    "\(shownPath(item.path, user: user))  (\(item.bytes)B)" + (apps[item.path].map { "（桌面应用：\($0)）" } ?? "")
                } + promptFiles.map(PromptFolderTools.listLine)
                return ok(lines.isEmpty ? "（空文件库）" : lines.joined(separator: "\n"))
            case .read:
                return readResult(try FileLibraryStore.read(str(args, "path"), profileId: profileId), args: args)
            case .search:
                let hits = (FileLibraryStore.search(str(args, "keyword"), profileId: profileId)
                    + FileLibraryStore.memorySearch(str(args, "keyword"), profileId: profileId)
                    + MemoryVirtualFiles.search(str(args, "keyword"), profileId: profileId, container: container))
                    .filter { FileLibraryAccess.visible($0.path, profileId: profileId) && !FileLibraryMemoryFolder.isHiddenWikiPath($0.path) }
                let keyword = str(args, "keyword")
                let promptHits = keyword.isEmpty ? [] : promptFiles.flatMap { file in
                    file.content.split(separator: "\n", omittingEmptySubsequences: false)
                        .filter { $0.range(of: keyword, options: .caseInsensitive) != nil }.map { "\(file.path): \($0)" }
                }
                let lines = hits.map { hit -> String in
                    let wiki = hit.path.hasPrefix(FileLibraryMemoryFolder.wikiFolder + "/")
                    return "\(shownPath(hit.path, user: user)): \(wiki ? WikiStore.shown(hit.line, user: user) : hit.line)"
                } + promptHits
                return ok(lines.isEmpty ? "无命中" : lines.joined(separator: "\n"))
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

    static func fileChangeResult(title: String, path: String, before: String?, after: String?) -> String {
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

    /// wiki 里点开头的（.history / .proposals 含原始输出 / .group.md）不给助手看：规范化后按文件库列表同一条规则判。
    /// 顶层 `exports/`（楼层快照，整楼层原文）整目录不给看：挡住 fs_read 直接给路径（fs_list / fs_search 靠列表，不枚举它）。
    static func hiddenFromAssistant(_ path: String) -> Bool {
        let prefix = FileLibraryStore.memoryVirtualPrefix
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return false }
        let rel = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var normalized: [String] = []
        for component in rel.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !normalized.isEmpty { normalized.removeLast() }
            default: normalized.append(String(component))
            }
        }
        guard let first = normalized.first else { return false }
        if FileLibraryStore.memoryUnlistedFolders.contains(first.lowercased()) { return true }
        return FileLibraryMemoryFolder.isHiddenWikiPath((prefix + normalized.joined(separator: "/")).lowercased())
    }

    /// fs_read 三种路径共用：范围读 + 头截 + 续读尾注（plan-B4 D3；实现在 ToolResultOffload.fileRead）
    private static func readResult(_ text: String, args: [String: Any]) -> Result {
        let r = ToolResultOffload.fileRead(text: text, path: str(args, "path"), offset: int(args, "offset"), limit: int(args, "limit"))
        return Result(text: r.text, isError: r.isError)
    }
}
