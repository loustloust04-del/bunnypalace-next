import MemoryCore
import Foundation
import SwiftData

/// 用文件工具写 `memory/`（粟粟 11-14「保留数据库…但是外在表现是文件夹」「写 / 改 / 删文件就是写 / 改 / 删记忆」）：
/// 路径决定落到哪种记忆上，每一种走它现成的写入路径和留痕——
/// 记忆条目 → `MemoryCardFolder`（`MemoryAudit` + `MemoryAuditLog`）；助手自己的记忆 → `SelfMemoryStore`；
/// 待续 → `PendingStore`；wiki 页 → `WikiEditing.save`（存历史）/ 删页收据；资料卡 → `ProfileCardStore`。
/// 后台照聊天原文重写的（段摘要 / 窗口总结 / 时间轴）、日志、同步来的保持只读，各给一句原因。
/// 聊天里的助手和 CC 里的助手是同一个入口（`FileLibraryTools.run`），权限闸按写的是哪一种分域（`PermissionDomain.forCall`）
enum MemoryFolderWrite {
    typealias Result = FileLibraryTools.Result

    /// 谁在写：记进各自的留痕。`via` = `MemoryAuditLog.viaChat` / `viaCC`
    struct Writer: Sendable {
        let actor: String
        let via: String
        let conversationId: String?
        /// 这场对话的「记忆参与」
        let memoryEnabled: Bool
        /// 新建记忆条目时的出处（聊天里 = 触发这一轮的那条用户消息；CC 那头没有）
        var source: MemoryCardTool.Source? = nil
    }

    enum Kind: Equatable {
        case card
        case selfMemory
        case pending
        /// wiki 相对路径（不带 .md）
        case wikiPage(String)
        case profileCard
        case readOnly(String)
        /// 对助手藏着的 / 跑出 memory/ 的
        case missing
    }

    static let pendingPath = FileLibraryMemoryFolder.root + "/" + PendingStore.folder + "/" + PendingStore.fileName
    static let selfIndexPath = FileLibraryMemoryFolder.selfFolder + "/" + SelfMemoryStore.indexFileName
    static let profileCardPath = FileLibraryMemoryFolder.root + "/profile-card.md"

    /// `memory/a/../b` → `memory/b`；跑出去了 → nil
    static func normalized(_ raw: String) -> String? {
        var parts: [String] = []
        for part in raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        let path = parts.joined(separator: "/")
        return FileLibraryMemoryFolder.isMemoryPath(path) ? path : nil
    }

    /// 只读的那几处各一句原因（按 memory/ 下第一层文件夹）
    private static let readOnlyFolders: [String: String] = [
        SessionSummaryStore.folder: "段摘要是后台照聊天原文写的，下次整理会整份重写，手改留不住。",
        WindowSummaryStore.folder: "窗口总结是后台照聊天原文写的，每次收尾整份重写，手改留不住。",
        "timeline": "时间轴是后台照每天的摘要拼的，那天的摘要一变就重拼，手改留不住。",
        "heartvoice": "心声是当时那一刻写下的，不改；要新写一条用 inner_voice。",
        MemoryWriteLog.folder: "日志只记不改。",
        "cc": "这是从 CC 那边同步过来的，下次同步会照 CC 那边的盖掉；要改去 CC 那边改。",
        "heartbeat": "自己醒来的任务用 heartbeat_task 建和改。",
        "daily": "这是改版前留下的旧记录，只留着看。",
        "summaries": "这是改版前留下的旧记录，只留着看。",
        PendingStore.folder: "待续只有 \(PendingStore.fileName) 这一份能改，别的是程序自己用的账。",
    ]

    /// 一条规范化过的 memory/ 路径是哪一种
    static func kind(_ path: String) -> Kind {
        guard FileLibraryMemoryFolder.isMemoryPath(path), !FileLibraryTools.hiddenFromAssistant(path) else { return .missing }
        if path == MemoryCardFolder.pinnedPath { return .readOnly("这份是钉住的记忆条目的清单，照条目自动排的；要钉 / 取消钉，改那一条的 pinned。") }
        if MemoryCardFolder.isCardPath(path) { return .card }
        if path == selfIndexPath { return .readOnly("这份目录是照 memory/self/ 里的文件自动排的，改那些文件它会跟着变。") }
        if FileLibraryMemoryFolder.isSelfMemoryFile(path) { return .selfMemory }
        if path == pendingPath { return .pending }
        if path == profileCardPath { return .profileCard }
        if let why = MemoryRecordsFolder.readOnlyReason(path) { return .readOnly(why) }
        if let page = FileLibraryMemoryFolder.wikiPagePath(path) { return .wikiPage(page) }
        if path.hasPrefix(FileLibraryMemoryFolder.wikiFolder + "/") {
            return .readOnly("wiki 里能改的是页（memory/wiki/<组>/…/<页>.md）；各层的 INDEX 是照页自动排的，别的是程序自己用的。")
        }
        let first = path.dropFirst(FileLibraryMemoryFolder.root.count + 1).split(separator: "/").first.map(String.init) ?? ""
        if let why = readOnlyFolders[first] { return .readOnly(why) }
        if first == "user-card.md" { return .readOnly("这是对方自己的资料卡，只有对方能改。") }
        return .readOnly("这份是程序自己生成的，不能改。")
    }

    /// 这一种写归哪个权限域（只读 / 不存在的照文件库走，执行时会被拒）
    static func domain(_ kind: Kind) -> PermissionDomain {
        switch kind {
        case .card: return .memoryCards
        // 待续是助手自己的备忘：和它自己的记忆同一档（默认自动允许；粟粟 11-14：日常记待续很频繁，默认弹卡太烦）
        case .selfMemory, .pending: return .memorySelf
        case .wikiPage: return .memoryFiles
        case .profileCard, .readOnly, .missing: return .fileLibrary
        }
    }

    static func label(_ kind: Kind) -> String {
        switch kind {
        case .card: return "记忆条目"
        case .selfMemory: return "自己的记忆"
        case .pending: return "待续"
        case .wikiPage: return "wiki 页"
        case .profileCard: return "资料卡"
        case .readOnly, .missing: return "记忆文件"
        }
    }

    // MARK: - 写 / 追加 / 改一段 → 新全文

    struct Rejected: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// 三个写工具算出写完后的全文。`current` = 现在的全文（没有这份 = nil）
    static func newText(tool: FileLibraryTools.Name, args: [String: String], current: String?, path: String) throws -> String {
        func str(_ key: String) -> String { args[key] ?? "" }
        switch tool {
        case .write:
            return str("content")
        case .append:
            guard let current, !current.isEmpty else { return str("content") }
            return current + (current.hasSuffix("\n") ? "" : "\n") + str("content")
        case .edit:
            guard let current else { throw Rejected(why: "没有这个文件: \(path)") }
            let old = str("old_string")
            guard !old.isEmpty else { throw Rejected(why: "old_string 不能是空的") }
            let hits = current.components(separatedBy: old).count - 1
            guard hits == 1 else { throw Rejected(why: hits == 0 ? "old_string 在 \(path) 里没找到（先 fs_read 看现在的原文）" : "old_string 在 \(path) 里出现了 \(hits) 次，要唯一") }
            return current.replacingOccurrences(of: old, with: str("new_string"))
        default:
            throw Rejected(why: "\(tool.rawValue) 在这里用不了")
        }
    }

    private static func fail(_ text: String) -> Result { Result(text: text, isError: true) }

    private static func changed(_ title: String, _ path: String, before: String?, after: String, note: String) -> Result {
        Result(text: FileLibraryTools.fileChangeResult(title: title, path: path, before: before, after: after) + "\n" + note, isError: false)
    }

    private static func record(_ writer: MemoryWriterID, _ who: Writer, _ what: String, profileId: String) {
        MemoryWriteLog.record(writer: writer, profileId: profileId, ok: true, note: "\(who.actor)（\(who.via)）用文件工具\(what)", model: "",
                              memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
    }

    // MARK: - 入口

    /// `args` 里的路径已经还原成落盘写法（wiki 本人那组）；`shown` = 模型给的原样（回话里用）
    @MainActor
    static func execute(tool: FileLibraryTools.Name, args: [String: Any], shown: [String: Any], profileId: String, userName: String,
                        writer: Writer, context: ModelContext, now: Date = Date()) async -> Result {
        let args = args.compactMapValues { $0 as? String }
        let key = tool == .rename ? "old_path" : "path"
        let shownPath = shown[key] as? String ?? ""
        guard let path = normalized(args[key] ?? "") else { return fail("非法路径: \(shownPath)") }
        let kind = kind(path)
        if case .missing = kind { return fail("没有这个文件: \(shownPath)") }
        if case .readOnly(let why) = kind { return fail("\(shownPath) 是只读的：\(why)") }
        guard MemoryFlags.masterEnabled else { return fail("记忆总开关关着，memory/ 下的东西现在改不了。") }
        guard writer.memoryEnabled else { return fail("这场对话关了记忆参与，不能改 memory/ 下的记忆。如实告诉对方，不要再试。") }
        if tool == .rename, kind != .card {
            return fail("\(label(kind))不能用 fs_rename 改名或挪位置（文件名是它的编号 / 标题定的）。记忆条目可以挪到另一个「说的是谁」文件夹或 \(MemoryCardFolder.deletedFolder)。")
        }
        switch kind {
        case .card:
            return card(tool: tool, args: args, path: path, shownPath: shownPath, profileId: profileId, writer: writer, context: context, now: now)
        case .selfMemory:
            guard SelfMemoryTool.enabled else { return fail("自己的记忆这一项在 设置 › 记忆 里关着，现在写不了。") }
            return await offMain { selfMemory(tool: tool, args: args, path: path, profileId: profileId, writer: writer, now: now) }
        case .pending:
            guard PendingNotesTool.enabled else { return fail("时间轴这一项在 设置 › 记忆 里关着，待续现在改不了。") }
            return await offMain { pending(tool: tool, args: args, path: path, profileId: profileId, writer: .assistant(writer), now: now) }
        case .profileCard:
            return await offMain { profileCard(tool: tool, args: args, path: path, profileId: profileId) }
        case .wikiPage(let page):
            return await wiki(tool: tool, args: args, page: page, path: path, shownPath: shownPath, profileId: profileId,
                              userName: userName, writer: writer)
        case .readOnly, .missing:
            return fail("没有这个文件: \(shownPath)")
        }
    }

    private static func offMain(_ body: @escaping @Sendable () -> Result) async -> Result {
        await Task.detached(priority: .userInitiated) { body() }.value
    }

    // MARK: - 记忆条目

    @MainActor
    private static func card(tool: FileLibraryTools.Name, args: [String: String], path: String, shownPath: String, profileId: String,
                             writer: Writer, context: ModelContext, now: Date) -> Result {
        guard path != MemoryCardFolder.root else { return fail("要给到具体哪一份：memory/cards/<说的是谁>/<名字>.md") }
        let all = SwiftDataMemoryStore().listAll(profileId: profileId, context: context)
        let found = MemoryCardTool.lookup(path, in: all.map(\.id))
        if case .ambiguous(let n) = found { return fail("「\(shownPath)」对上了 \(n) 条记忆条目，文件名给完整的编号") }
        let by = MemoryCardFolder.Writer.assistant(name: writer.actor, via: writer.via)
        func pathNow(_ id: UUID) -> String {
            MemoryCardFolder.entries(profileId: profileId, context: context).first { $0.card == id }?.path ?? path
        }
        guard case .found(let id) = found, let m = all.first(where: { $0.id == id }) else {
            guard tool == .write || tool == .append else { return fail("没有这个文件: \(shownPath)。先 fs_search / fs_list 在 memory/cards/ 里找") }
            let folder = path.split(separator: "/").dropFirst(2).dropLast().first.map(String.init)
            let r = MemoryCardFolder.create(text: args["content"] ?? "", folder: folder, profileId: profileId,
                                            conversationId: writer.conversationId, memoryEnabled: writer.memoryEnabled,
                                            actor: writer.actor, via: writer.via, source: writer.source, context: context, now: now)
            guard !r.isError else { return fail(r.text) }
            let body = (try? MemoryCardFolder.parse(args["content"] ?? ""))?.body
            let made = SwiftDataMemoryStore().listAll(profileId: profileId, context: context)
                .first { $0.supersededAt == nil && $0.content == body }
            return Result(text: r.text + (made.map { "\n这条记忆条目的文件：\(pathNow($0.id))" } ?? ""), isError: false)
        }
        let current = MemoryCardFolder.text(m)
        do {
            let text: String
            switch tool {
            case .delete:
                guard m.supersededAt == nil else { return Result(text: "这条已经在 \(MemoryCardFolder.deletedFolder) 里了", isError: false) }
                text = "---\nstate: \(MemoryCardFolder.states[2])\n---\n\n\(m.content)\n"
            case .rename:
                guard let target = normalized(args["new_path"] ?? ""), MemoryCardFolder.isCardPath(target),
                      target.split(separator: "/").count == 4, target.split(separator: "/").last == path.split(separator: "/").last else {
                    return fail("记忆条目只能挪文件夹：memory/cards/<说的是谁>/ 或 memory/cards/\(MemoryCardFolder.deletedFolder)/，文件名（这一条的编号）不能改")
                }
                let folder = String(target.split(separator: "/")[2])
                if folder == MemoryCardFolder.deletedFolder {
                    text = "---\nstate: \(MemoryCardFolder.states[2])\n---\n\n\(m.content)\n"
                } else {
                    let state = m.reviewedAt == nil ? MemoryCardFolder.states[0] : MemoryCardFolder.states[1]
                    let about = folder == MemoryCardFolder.noSubjectFolder ? "" : folder
                    text = "---\nstate: \(state)\nabout: \(about)\n---\n\n\(m.content)\n"
                }
            default:
                text = try newText(tool: tool, args: args, current: current, path: shownPath)
            }
            try MemoryCardFolder.save(card: id, text: text, baseline: current, stamp: m.updatedAt, by: by, profileId: profileId,
                                      context: context, now: now)
        } catch {
            return fail(error.localizedDescription)
        }
        let after = MemoryCardFolder.text(m)
        guard after != current else { return Result(text: "没有变化：写的和这条现在的一样", isError: false) }
        return changed(tool == .delete ? "已删除（进 \(MemoryCardFolder.deletedFolder)，能放回）" : "已修改", pathNow(id), before: current, after: after,
                       note: "对方能在记忆日志里撤回")
    }

    // MARK: - 助手自己的记忆

    private static let selfTopKeys: Set<String> = ["name", "description", "metadata"]
    private static let selfMetaKeys: Set<String> = ["type", "importance", "origin", "created", "source", "superseded"]

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 一份 memory/self/ 文件读成一条记忆。头里没写的项照 `existing`（新建的用默认）；`created / origin / source` 是来历，改了拒
    static func selfMemory(from text: String, slug: String, existing: SelfMemory?, conversationId: String?, now: Date) throws -> SelfMemory {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw Rejected(why: "开头要有两行 --- 包起来的头，里面至少有 name: 一行（照 memory/self/ 里别的文件的样子），再往下是正文。")
        }
        var top: [String: String] = [:], meta: [String: String] = [:]
        for line in lines[1..<end] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Rejected(why: "这一行认不出来：\(line)（要写成「名字: 值」）") }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
            guard (indented ? selfMetaKeys : selfTopKeys).contains(key) else {
                throw Rejected(why: "认不出「\(key)」这一项。顶格写的有 name / description / metadata，metadata 下面缩进两格写 type / importance / origin / created / source / superseded。")
            }
            if indented { meta[key] = value } else { top[key] = value }
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Rejected(why: "正文不能是空的。不要这条了就删这份文件（= 标成失效，对方能复活）。") }
        guard body.count <= MemoryFlags.selfBodyLimit else { throw Rejected(why: "正文 \(body.count) 字，超过上限 \(MemoryFlags.selfBodyLimit) 字，精简一下再写") }
        guard let name = MemoryAudit.cleaned(top["name"]) ?? existing?.name else { throw Rejected(why: "头里要有 name: 一行（这条记忆的短标题）。") }
        if let type = meta["type"], !SelfMemoryStore.types.contains(type) {
            throw Rejected(why: "type 只能写 \(SelfMemoryStore.types.joined(separator: " / "))。")
        }
        var importance = existing?.importance ?? 3
        if let raw = meta["importance"] {
            guard let v = Int(raw), (1...5).contains(v) else { throw Rejected(why: "importance 要写 1–5 的整数。") }
            importance = v
        }
        var superseded = existing?.superseded
        if let raw = meta["superseded"] {
            if raw.isEmpty { superseded = nil } else {
                guard let date = iso.date(from: raw) else { throw Rejected(why: "superseded 要写成 \(iso.string(from: now)) 这样的时间；留空 = 这条重新生效。") }
                superseded = date
            }
        }
        if let existing {
            let sameCreated = meta["created"].map { iso.date(from: $0).map { Int($0.timeIntervalSince1970) } == Int(existing.created.timeIntervalSince1970) } ?? true
            guard sameCreated, meta["origin"].map({ $0 == existing.origin }) ?? true,
                  meta["source"].map({ $0 == (existing.source ?? "") }) ?? true else {
                throw Rejected(why: "created / origin / source 是这条记忆的来历，只读。能改的有 name / description / type / importance / superseded 和正文。")
            }
        }
        let origin = existing?.origin ?? (meta["origin"] == "asked" ? "asked" : "self")
        return SelfMemory(slug: slug, name: name, description: top["description"] ?? existing?.description ?? "",
                          type: meta["type"] ?? existing?.type ?? "user", importance: importance, origin: origin,
                          created: existing?.created ?? now, source: existing?.source ?? conversationId, superseded: superseded, body: body)
    }

    private static func selfMemory(tool: FileLibraryTools.Name, args: [String: String], path: String, profileId: String, writer: Writer, now: Date) -> Result {
        guard let given = FileLibraryMemoryFolder.selfSlug(path), !given.isEmpty else {
            return fail("memory/self/ 里一条记忆一份 .md，直接放在这一层：memory/self/<短标题>.md")
        }
        let root = FileLibraryStore.memoryRoot(profileId: profileId)
        let list = SelfMemoryStore.list(memoryRoot: root, checkPath: AppPaths.checked)
        let existing = list.first { $0.slug == given }
        let slug = existing?.slug ?? SelfMemoryStore.slugify(given)
        let file = FileLibraryMemoryFolder.selfFolder + "/" + slug + ".md"
        if tool == .delete {
            guard var m = existing else { return fail("没有这个文件: \(path)") }
            guard m.isActive else { return Result(text: "这条已经失效了", isError: false) }
            m.superseded = now
            do { try SelfMemoryStore.save(m, memoryRoot: root, checkPath: AppPaths.checked) } catch { return fail("写入失败：\(error.localizedDescription)") }
            record(.b4, writer, "把 \(file) 标成了失效", profileId: profileId)
            return Result(text: "忘掉了：\(m.description.isEmpty ? m.name : m.description)（文件还在，标成了失效；对方能在「记忆」页里复活）", isError: false)
        }
        if existing == nil, list.contains(where: { $0.slug == slug }) { return fail("已经有 \(file) 了，要改就写那一份") }
        let current = existing.map(SelfMemoryStore.render)
        do {
            let text = try newText(tool: tool, args: args, current: current, path: path)
            let m = try selfMemory(from: text, slug: slug, existing: existing, conversationId: writer.conversationId, now: now)
            if existing == nil, m.origin == "self" {
                let limit = MemoryFlags.selfDailyLimit
                guard SelfMemoryStore.todaySelfCount(list, now: now) < limit else {
                    return fail("今天我自己已经记了 \(limit) 条，留到明天；对方让记的不受这个限制（头里 metadata 下写 origin: asked）")
                }
            }
            try SelfMemoryStore.save(m, memoryRoot: root, checkPath: AppPaths.checked)
            let after = SelfMemoryStore.render(m)
            guard after != current else { return Result(text: "没有变化：写的和现在的一样", isError: false) }
            record(.b4, writer, existing == nil ? "新记了 \(file)" : "改了 \(file)", profileId: profileId)
            return changed(existing == nil ? "已创建" : "已修改", file, before: current, after: after,
                           note: existing == nil ? "记住了（\(m.importance) 级）。目录 \(selfIndexPath) 跟着更新了" : "改好了")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: - 待续

    enum PendingWriter: Sendable {
        case assistant(Writer)
        /// 她在文件库里改（新加不了：一条待续要挂在一个窗口上）
        case you
    }

    /// 待续那份文件存回本子：一条一行。改字、改状态（注释里的 state）、删行都认；没带注释的新行 = 新加一条
    /// （聊天里加的挂在那场对话上；CC 在电脑上的记忆文件夹里加的没有窗口，记在 `PendingStore.ccWindow` 名下）。
    /// 注释里别的项（id / conv / day…）是来历，改了拒。返回存成后的全文
    @discardableResult
    static func savePending(text: String, profileId: String, writer: PendingWriter, now: Date = Date()) throws -> String {
        do { try TimelineDaily.preparePendingForEdit(profileId: profileId) } catch { throw Rejected(why: TimelineDaily.pendingProblem(error)) }
        let root = FileLibraryStore.memoryRoot(profileId: profileId)
        let current = PendingStore.load(profileId: profileId, floorMemoryRoot: root) ?? []
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }
        var kept: [PendingItem] = []
        var added: [String] = []
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let item = PendingStore.parse(PendingStore.render([]) + line).first {
                guard let old = current.first(where: { $0.id == item.id }) else {
                    throw Rejected(why: "没有 id=\(item.id) 这条待续：\(line)（新加的一条只写「- 内容」，不要带后面的注释）")
                }
                var same = item
                same.text = old.text
                same.state = old.state
                guard same == old else { throw Rejected(why: "这一行注释里只有 state 能改（open / done / faded），别的是这条的来历：\(line)") }
                guard !item.text.isEmpty, !kept.contains(where: { $0.id == item.id }) else { throw Rejected(why: "这一行不对（内容是空的，或者同一条写了两遍）：\(line)") }
                kept.append(item)
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- "), !t.contains("<"), !t.contains(">") else {
                throw Rejected(why: "这一行认不出来：\(line)（一条一行，写成「- 内容」；已有的行后面那段注释原样留着）")
            }
            let content = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, content.count <= PendingNotesTool.textCharLimit else {
                throw Rejected(why: "一条待续要有内容、最多 \(PendingNotesTool.textCharLimit) 字：\(line)")
            }
            added.append(content)
        }
        var conversationId = ""
        if !added.isEmpty {
            guard case .assistant(let who) = writer else {
                throw Rejected(why: "在这里新加不了待续（一条待续要挂在一个窗口上）。改字、改状态、删掉都可以。")
            }
            conversationId = who.conversationId.flatMap { $0.isEmpty ? nil : $0 } ?? PendingStore.ccWindow
        }
        let after = try PendingStore.mutate(profileId: profileId, floorMemoryRoot: root) { items in
            // 别的写手这会儿刚加进来的（不在她 / 助手看到的那份里）留着，接在后面
            let unseen = items.filter { item in !current.contains { $0.id == item.id } }
            var rest = kept.filter { item in items.contains { $0.id == item.id } }.map { item -> PendingItem in
                var live = items.first { $0.id == item.id } ?? item
                live.text = item.text
                live.state = item.state
                return live
            } + unseen
            _ = PendingStore.adding(added, conversationId: conversationId, day: MemoryDay.key(now), anchor: nil, to: &rest)
            items = rest
        }
        return PendingStore.render(after, legacyDone: PendingStore.isLegacyDone(profileId: profileId, floorMemoryRoot: root))
    }

    /// 待续那份文件现在的全文（还没有本子 = 只有头的空本子）
    static func pendingText(profileId: String) -> String {
        let root = FileLibraryStore.memoryRoot(profileId: profileId)
        return (try? String(contentsOf: PendingStore.fileURL(root: root), encoding: .utf8)) ?? PendingStore.render([])
    }

    private static func pending(tool: FileLibraryTools.Name, args: [String: String], path: String, profileId: String, writer: PendingWriter, now: Date) -> Result {
        guard tool != .delete else { return fail("待续这份本子不能整份删。不要哪一条，就把那一行删掉（或把 state 改成 done / faded）。") }
        let current = pendingText(profileId: profileId)
        do {
            let text = try newText(tool: tool, args: args, current: current, path: path)
            let after = try savePending(text: text, profileId: profileId, writer: writer, now: now)
            guard after != current else { return Result(text: "没有变化：写的和本子上现在的一样", isError: false) }
            if case .assistant(let who) = writer { record(.a4, who, "改了待续", profileId: profileId) }
            return changed("已修改", path, before: current, after: after, note: "待续改好了")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: - 资料卡

    /// memory/profile-card.md：头里的 status + 正文（自我介绍），同 `update_profile_card`
    private static func profileCard(tool: FileLibraryTools.Name, args: [String: String], path: String, profileId: String) -> Result {
        guard tool != .delete else { return fail("资料卡不能删。要清空自我介绍，把正文写成一个 -。") }
        let current = try? FileLibraryStore.memoryRead(path, profileId: profileId)
        do {
            let text = try newText(tool: tool, args: args, current: current, path: path)
            guard let (meta, body) = FrontmatterCodec.parse(text) else {
                throw Rejected(why: "资料卡要有两行 --- 包起来的头（里面一行 status: 当下状态），再往下是自我介绍；不要自我介绍就写一个 -。")
            }
            let was = ProfileCardStore.load(profileId: profileId)
            if let status = meta["status"], status != (was.status ?? "") { ProfileCardStore.saveStatus(status, profileId: profileId) }
            let bio = body == "-" ? "" : body
            if bio != (was.bio ?? "") { ProfileCardStore.saveBio(bio, profileId: profileId) }
            let after = (try? FileLibraryStore.memoryRead(path, profileId: profileId)) ?? ""
            return changed("已修改", path, before: current, after: after, note: "资料卡已更新（状态最多 \(ProfileCardStore.statusMaxLength) 字，超出的截掉了）")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: - wiki 页

    @MainActor
    private static func wiki(tool: FileLibraryTools.Name, args: [String: String], page: String, path: String, shownPath: String,
                             profileId: String, userName: String, writer: Writer) async -> Result {
        let store = WikiStore(profileId: profileId)
        let disk = await Task.detached(priority: .userInitiated) { store.readVersioned(page) }.value
        if tool == .delete {
            guard let disk else { return fail("没有这个文件: \(shownPath)") }
            do { try await WikiDeletionAction.perform(.delete(path: page, version: disk.version), store: store, profileId: profileId) } catch {
                return fail("没删成：\(WikiStore.shown(error.localizedDescription, user: userName))")
            }
            record(.c3, writer, "删了页 \(page)", profileId: profileId)
            return Result(text: "已删除 \(shownPath)（删之前存了一版，对方能在 wiki 的「已删除」里恢复）", isError: false)
        }
        do {
            let shownNow = disk.map { WikiStore.shown($0.text, user: userName) }
            let shownNew = try newText(tool: tool, args: args, current: shownNow, path: shownPath)
            // 没改的行照落盘原文，改过的行只把本人那组还原成落盘写法（同她在文件库里改）
            let raw = WikiStore.storedEdit(shownNew, original: disk?.text ?? "", user: userName)
            guard raw != disk?.text else { return Result(text: "没有变化：写的和这页现在的一样", isError: false) }
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Rejected(why: "页不能写成空的。不要这页就删这份文件（能恢复）。") }
            if let disk {
                try await WikiEditing.save(raw, baseline: disk.text, store: store, path: page)
            } else {
                guard raw.components(separatedBy: "\n").contains(where: { $0.hasPrefix("# ") }) else {
                    throw Rejected(why: "新的一页要有一行「# 标题」（照同组别的页的样子：头、标题、## 现在、## 记录）。")
                }
                try await WikiProposalReview.exclusive(wiki: store) {
                    try await Task.detached(priority: .userInitiated) {
                        guard !store.pageExists(page) else { throw Rejected(why: "这页刚在别处建好了，先 fs_read 看一眼再改。") }
                        try store.saveRaw(raw, path: page)
                        try? store.rebuildIndexes(affecting: [page])
                    }.value
                }
                WikiEditing.didWrite()
            }
            record(.c3, writer, disk == nil ? "新建了页 \(page)" : "改了页 \(page)", profileId: profileId)
            return changed(disk == nil ? "已创建" : "已修改", shownPath, before: shownNow, after: WikiStore.shown(raw, user: userName),
                           note: disk == nil ? "新页建好了，目录跟着更新了" : "改之前的那一版存进了这页的历史，对方能恢复")
        } catch {
            return fail(WikiStore.shown(error.localizedDescription, user: userName))
        }
    }

    // MARK: - 审批卡上多出的一行

    /// 文件工具写 memory/ 时卡上那一行：要动的是哪一种、现在写的是什么
    @MainActor
    static func permissionDetail(toolName: String, argumentsJSON: String, profileId: String, context: ModelContext) -> String? {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let raw = (args[toolName == FileLibraryTools.Name.rename.rawValue ? "old_path" : "path"] as? String) ?? ""
        guard let path = normalized(raw) else { return nil }
        let kind = kind(path)
        switch kind {
        case .card:
            let all = SwiftDataMemoryStore().listAll(profileId: profileId, context: context)
            guard case .found(let id) = MemoryCardTool.lookup(path, in: all.map(\.id)), let m = all.first(where: { $0.id == id }) else {
                return "新加一条记忆条目"
            }
            return "这条记忆条目现在写的是：「\(m.lineText)」"
        case .selfMemory, .pending, .wikiPage, .profileCard:
            return "要改的是\(label(kind))：\(raw.trimmingCharacters(in: .whitespaces))"
        case .readOnly, .missing:
            return nil
        }
    }
}

extension PermissionDomain {
    /// 这一次调用归哪个域：文件工具写 `memory/` 或 Prompt 文件夹里的东西，按写的是哪一种算（记忆条目 / 自己的记忆 / 别的记忆文件 / Prompt）；
    /// 其余同 `forTool(named:)`。一次调用碰到两种的（改名）取更要紧的那个
    static func forCall(named name: String, argumentsJSON: String) -> PermissionDomain {
        let fallback = forTool(named: name)
        // pending_notes：记一条、标做完 / 淡了是写待续（同用文件工具改待续，归「自己的记忆」那一档）；只是看（list）不过这一档
        if name == PendingNotesTool.toolName {
            let action = ((try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any])?["action"] as? String
            return action == "list" ? fallback : .memorySelf
        }
        guard let tool = FileLibraryTools.Name(rawValue: name), FileLibraryTools.writeNames.contains(tool) else { return fallback }
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        var found: Set<PermissionDomain> = []
        for key in ["path", "old_path", "new_path"] {
            guard let raw = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if PromptFolder.isPromptPath(raw) {
                found.insert(.promptEdit)
            } else if raw.hasPrefix(FileLibraryStore.memoryVirtualPrefix), let path = MemoryFolderWrite.normalized(raw) {
                found.insert(MemoryFolderWrite.domain(MemoryFolderWrite.kind(path)))
            }
        }
        return [PermissionDomain.promptEdit, .memoryFiles, .memoryCards, .memorySelf].first(where: found.contains) ?? fallback
    }
}
