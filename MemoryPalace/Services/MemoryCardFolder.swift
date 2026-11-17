import MemoryCore
import Foundation
import SwiftData

/// 文件库 › 记忆 › 记忆条目（粟粟 11-14「花园记忆应该跟文件夹-记忆 1:1 映射」「那一堆 tag 之类的就是 md 的 metadata」）：
/// 每张卡一份 `.md`，卡上的各项是开头 `---` 之间的 frontmatter，正文就是卡的正文。没删的按「说的是谁」分文件夹，删了的在 `Deleted/`。
/// 不搬数据、不另存文件——条目就是 `Memory` 表里那张卡现排出来的字（照 `CatalogSeedDrafts`）。
/// 写：她在文件库里改了存（`save`，算她亲手改）、助手用文件工具写（`save(by: .assistant)` / `create`，聊天里和 CC 那头同一条）
/// 都落到卡上，每一笔进 `MemoryAuditLog`。读：文件库和助手的 `fs_list / fs_read / fs_search` 是同一份（`MemoryVirtualFiles`）
enum MemoryCardFolder {
    static let folderName = "cards"
    static let root = FileLibraryMemoryFolder.root + "/" + folderName
    /// 卡上没写「说的是谁」的归这一格
    static let noSubjectFolder = "没写是谁"
    /// 删了的卡（还能放回）都在这一格
    static let deletedFolder = "Deleted"
    /// 钉住的那几张的清单（现排，只读）
    static let pinnedPath = root + "/Pinned.md"

    struct Entry: Equatable, Identifiable, Sendable {
        var path: String
        var card: UUID
        /// 所在文件夹（`memory/cards/<说的是谁>`，删了的是 `memory/cards/Deleted`）
        var folder: String
        /// 条目全文（frontmatter + 正文）
        var content: String
        /// 列表标题用的那一行：说的是谁 · 正文（`Memory.lineText`；不是存回去的正文）
        var text: String
        /// 列表副标题：谁说的 · 置信度 · #标签
        var traits: String
        /// Draft / Archive / Deleted
        var state: String
        var pinned: Bool
        var modifiedAt: Date
        var id: String { path }
    }

    enum EditError: LocalizedError, Equatable {
        case conflict
        case gone
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .conflict: return "这条记忆条目在别处改过了（整理台、聊天里的助手），请关闭重开后再改。"
            case .gone: return "这条记忆条目已经不在了（被彻底删除了）。"
            case .invalid(let why): return why
            }
        }
    }

    static func isCardPath(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    // MARK: - 排成条目

    static let states = ["Draft", "Archive", "Deleted"]

    static func stateLabel(_ m: Memory) -> String {
        switch MemoryAudit.state(of: m) {
        case .unreviewed: return states[0]
        case .kept: return states[1]
        case .trashed: return states[2]
        }
    }

    /// 文件夹名：说的是谁（洗成能当路径的一段）；没写的归 `noSubjectFolder`
    static func group(_ subject: String?) -> String {
        guard let s = MemoryAudit.cleaned(subject) else { return noSubjectFolder }
        return GardenMemoryExport.fileStem(s)
    }

    static let fileExtension = ".md"

    /// 文件名：编号开头 8 位；这层楼里（含删了的）开头 8 位撞了的用完整编号
    static func fileNames(_ ids: [UUID]) -> [UUID: String] {
        var counts: [String: Int] = [:]
        for id in ids { counts[MemoryCardTool.short(id), default: 0] += 1 }
        var out: [UUID: String] = [:]
        for id in ids {
            let short = MemoryCardTool.short(id)
            out[id] = (counts[short] == 1 ? short : id.uuidString.lowercased()) + fileExtension
        }
        return out
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let tagSeparator = ", "

    /// 类别当标签显示（「事实」不出，其余出中文名），和整理台 Edit 页同一个规矩。那边的 `MemoryAuditTraits` 挂在界面上、
    /// 后台线程调不了，这里放同一份对照（`MemoryCardFolderTests` 锁两边一致）
    static let plainCategory = "fact"
    static let categoryTags = ["preference": "偏好", "relationship": "关系", "goal": "目标", "context": "近况"]

    static func shownTags(category: String, keywords: [String]) -> [String] {
        let cat = MemoryAudit.cleaned(category).flatMap { $0 == plainCategory ? nil : (categoryTags[$0] ?? $0) }
        return (cat.map { [$0] } ?? []) + MemoryAudit.cleanedTags(keywords).filter { $0 != cat }
    }

    static func categoryKey(forTag tag: String) -> String? {
        categoryTags.first { $0.value == tag }?.key
    }

    /// frontmatter 里的项。只读的六项是卡的来历（编号、哪天建的、事情发生在哪天、从哪个窗口记下的、出处那条消息的原话、整理进了哪一页），改了会被拒
    enum Key: String, CaseIterable {
        case id, state, created, day, about, from, tags, importance, confidence, pinned, source, quote, page

        var readOnly: Bool { [.id, .created, .day, .source, .quote, .page].contains(self) }
    }

    static let editableKeys = Key.allCases.filter { !$0.readOnly }.map(\.rawValue).joined(separator: " / ")
    static let readOnlyKeys = Key.allCases.filter(\.readOnly).map(\.rawValue).joined(separator: " / ")

    /// 一张卡排成的全文。空着的项只留名字（行尾不带空格）；`day / source / quote / page` 卡上有才出。
    /// 正文就是存的正文、不拼主语（说的是谁在 `about` 和文件夹名上；这样改了存回来不会把主语存进正文）
    static func text(_ m: Memory) -> String {
        var fields: [(Key, String)] = [
            (.id, m.id.uuidString.lowercased()),
            (.state, stateLabel(m)),
            (.created, dayFormatter.string(from: m.createdAt)),
        ]
        if let day = MemoryAudit.cleaned(m.occurredDay) { fields.append((.day, day)) }
        fields += [
            (.about, MemoryAudit.cleaned(m.subject) ?? ""),
            (.from, MemoryAudit.cleaned(m.speaker) ?? ""),
            (.tags, "[" + shownTags(category: m.category, keywords: m.keywords).joined(separator: tagSeparator) + "]"),
            (.importance, m.importance.map(String.init) ?? ""),
            (.confidence, m.confidence.map(String.init) ?? ""),
            (.pinned, m.isUserExplicit ? "yes" : "no"),
        ]
        if let source = MemoryAudit.cleaned(m.sourceConversationId) { fields.append((.source, source)) }
        if let quote = m.sourceQuote.flatMap(MemoryEntryLine.quote) { fields.append((.quote, quote)) }
        if let page = MemoryAudit.cleaned(m.organizedPage) { fields.append((.page, page)) }
        let head = fields.map { $1.isEmpty ? "\($0.rawValue):" : "\($0.rawValue): \($1)" }.joined(separator: "\n")
        return "---\n\(head)\n---\n\n\(m.content)\n"
    }

    /// 这层楼全部的卡，一张一个条目：没删的按「说的是谁」分文件夹，删了的在 `Deleted`；新的在前
    static func entries(_ all: [Memory]) -> [Entry] {
        let names = fileNames(all.map(\.id))
        return all
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
            .map { m in
                let folder = root + "/" + (m.supersededAt == nil ? group(m.subject) : deletedFolder)
                return Entry(path: folder + "/" + (names[m.id] ?? m.id.uuidString.lowercased() + fileExtension), card: m.id, folder: folder,
                             content: text(m), text: m.lineText,
                             traits: ([MemoryAudit.cleaned(m.speaker), m.confidence.map(String.init)].compactMap { $0 }
                                      + shownTags(category: m.category, keywords: m.keywords).map { "#" + $0 }).joined(separator: " · "),
                             state: stateLabel(m), pinned: m.isUserExplicit, modifiedAt: m.updatedAt)
            }
    }

    static func entries(profileId: String, context: ModelContext) -> [Entry] {
        entries(SwiftDataMemoryStore().listAll(profileId: profileId, context: context))
    }

    /// 后台读（文件库刷新、助手的 fs_*）：自己开一个只读用的 context
    nonisolated static func entries(profileId: String, container: ModelContainer) -> [Entry] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return entries(profileId: profileId, context: context)
    }

    /// 钉住的那几张的清单：一行一张，指到那张卡的文件。只读（钉 / 取消钉 = 改那张卡的 pinned）
    static func pinnedFile(_ entries: [Entry]) -> MemoryLogFolder.File {
        let pinned = entries.filter { $0.pinned && $0.state != states[2] }
        var out = "# 钉住的记忆条目\n\n每轮都带着的那几条。这份清单是照记忆条目自动排的，只读；要钉 / 取消钉，改那一条的 pinned。\n\n"
        if pinned.isEmpty { out += "还没有钉住的记忆条目。\n" }
        for e in pinned {
            let line = e.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            out += "- \(line)（\(e.path)）\n"
        }
        return .init(path: pinnedPath, title: "钉住的", content: out, modifiedAt: pinned.map(\.modifiedAt).max() ?? .distantPast)
    }

    // MARK: - 读回来

    struct Parsed: Equatable {
        /// frontmatter 里写了的项（值去了引号）；没写的不在里面 = 那一项不动
        var fields: [Key: String] = [:]
        /// 写了 tags 才有
        var tags: [String]? = nil
        var body = ""
        /// 开头有没有 `---` 包起来的头
        var hasHead = false

        subscript(_ key: Key) -> String? { fields[key] }
    }

    private static func unquoted(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespaces)
        for (open, close) in [("\"", "\""), ("'", "'"), ("“", "”")] where v.count >= 2 && v.hasPrefix(open) && v.hasSuffix(close) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    private static func tag(_ raw: String) -> String? {
        let t = unquoted(raw)
        let bare = t.hasPrefix("#") ? String(t.dropFirst()) : t
        return bare.isEmpty ? nil : bare
    }

    /// 开头两行 `---` 之间一行一项（`名字: 值`；tags 写成 `[a, b]`，或下面接几行 `- a`），再往下是正文。
    /// 没有头 = 整份都是正文。认不出的行、认不出的项照实报
    static func parse(_ text: String) throws -> Parsed {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var p = Parsed()
        guard let open = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[open].trimmingCharacters(in: .whitespaces) == "---" else {
            p.body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return p
        }
        guard let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw EditError.invalid("开头的 --- 没有收尾：各项写完要有单独一行 ---，再往下才是正文。")
        }
        p.hasHead = true
        var last: Key?
        for line in lines[(open + 1)..<close] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if last == .tags, t.hasPrefix("-") {
                if let item = tag(String(t.dropFirst())) { p.tags = (p.tags ?? []) + [item] }
                continue
            }
            guard let colon = t.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
                throw EditError.invalid("这一行认不出来：\(line)（要写成「名字: 值」）")
            }
            let name = t[..<colon].trimmingCharacters(in: .whitespaces)
            guard let key = Key(rawValue: name.lowercased()) else {
                throw EditError.invalid("认不出「\(name)」这一项。能改的有 \(editableKeys)；\(readOnlyKeys) 是只读的。")
            }
            let value = unquoted(String(t[t.index(after: colon)...]))
            p.fields[key] = value
            last = key
            if key == .tags {
                var inner = value
                if inner.hasPrefix("["), inner.hasSuffix("]") { inner = String(inner.dropFirst().dropLast()) }
                p.tags = inner.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" }).compactMap { tag(String($0)) }
            }
        }
        p.body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return p
    }

    private static func pinValue(_ s: String) throws -> Bool {
        switch s.lowercased() {
        case "yes", "true", "是": return true
        case "no", "false", "否", "": return false
        default: throw EditError.invalid("pinned 只能写 yes 或 no。")
        }
    }

    private static func stateValue(_ s: String) throws -> String {
        guard let state = states.first(where: { $0.lowercased() == s.lowercased() }) else {
            throw EditError.invalid("state 只能写 \(states.joined(separator: " / "))。")
        }
        return state
    }

    /// 空 = nil（不要这一项）
    private static func number(_ s: String, _ name: String, _ range: ClosedRange<Int>) throws -> Int? {
        guard !s.isEmpty else { return nil }
        guard let v = Int(s), range.contains(v) else {
            throw EditError.invalid("\(name) 要写 \(range.lowerBound)–\(range.upperBound) 的整数，不要就留空。")
        }
        return v
    }

    /// 助手写的 from 只认写手用的那几种（同 `memory_card` 的 speaker）；她亲手改的不限
    private static func speakerValue(_ s: String, _ writer: Writer) throws -> String {
        if case .assistant = writer, !s.isEmpty, !FragmentPool.speakers.contains(s) {
            throw EditError.invalid("from 只能写 \(FragmentPool.speakers.joined(separator: " / "))，不知道就留空。")
        }
        return s
    }

    // MARK: - 写回卡上

    /// 谁在改：她在文件库里（算她亲手改，同整理台 Edit 页），还是助手用文件工具（聊天里 / CC 那头；规矩同 `memory_card`）
    enum Writer: Equatable {
        case you
        case assistant(name: String, via: String)
    }

    /// 一份条目存回卡上。`baseline` = 改之前看到的全文：和它比，哪一项变了动哪一项，没写的、没碰的不动；
    /// `stamp` = 那时卡的 `updatedAt`，对不上 = 别处改过，拒存。state 能改（Draft / Archive / Deleted，从 Deleted 改回来 = 放回），
    /// pinned 能改；只读的几项改了拒存。只改 context 并存盘、记一笔；返回存成后卡的 `updatedAt`
    @MainActor
    @discardableResult
    static func save(card: UUID, text: String, baseline: String, stamp: Date, by writer: Writer = .you, profileId: String,
                     context: ModelContext, now: Date = Date()) throws -> Date {
        guard let m = SwiftDataMemoryStore().listAll(profileId: profileId, context: context).first(where: { $0.id == card }) else {
            throw EditError.gone
        }
        guard m.updatedAt == stamp else { throw EditError.conflict }
        let (new, old) = (try parse(text), try parse(baseline))
        guard new.hasHead else {
            throw EditError.invalid("开头两行 --- 和它们之间的各项要留着（可以只留要改的那几项）；只有新建一条时能只写正文。")
        }
        func changed(_ key: Key) -> String? {
            guard let value = new[key], value != (old[key] ?? "") else { return nil }
            return value
        }
        if let key = Key.allCases.first(where: { $0.readOnly && changed($0) != nil }) {
            throw EditError.invalid("\(key.rawValue) 是只读的（\(readOnlyKeys) 是这一条的来历，改不了）。能改的有 \(editableKeys) 和正文。")
        }
        guard !new.body.isEmpty else { throw EditError.invalid("正文不能是空的。不要这一条就把 state 改成 \(states[2])。") }

        // 先把每一项验一遍：有一项不对整份不动
        let state = try changed(.state).map(stateValue)
        let pin = try changed(.pinned).map(pinValue)
        let about = changed(.about)
        let speaker = try changed(.from).map { try speakerValue($0, writer) }
        let importance = try changed(.importance).map { try number($0, "importance", 1...5) }
        let confidence = try changed(.confidence).map { try number($0, "confidence", 0...100) }
        let tags = new.tags.flatMap { $0 != (old.tags ?? []) ? $0 : nil }
        let bodyChanged = new.body != old.body
        let deleted = states[2]
        let wasDeleted = m.supersededAt != nil
        let editsCard = bodyChanged || about != nil || speaker != nil || tags != nil || importance != nil || confidence != nil || pin != nil
        if wasDeleted, (state ?? deleted) == deleted, editsCard {
            throw EditError.invalid("这条已经删了。要改先把 state 改回 \(states[0]) 或 \(states[1])（= 放回来）。")
        }

        let before = MemoryAuditLog.CardState(m)
        if wasDeleted, let state, state != deleted {
            MemoryAudit.restore([m])
            m.updatedAt = now
        }
        switch writer {
        case .you:
            var edit = MemoryAudit.Edit(m)
            if bodyChanged { edit.text = new.body }
            if let about { edit.subject = about }
            if let speaker { edit.speaker = speaker }
            if let tags {
                // 类别当标签显示（同 Edit 页）：写了类别名的那个标签存回类别，没写的 = 「事实」
                edit.category = tags.compactMap(categoryKey(forTag:)).last ?? plainCategory
                edit.keywords = tags.filter { categoryKey(forTag: $0) == nil }
            }
            if let importance, let value = importance { edit.importance = value }
            if let confidence { edit.confidence = confidence }
            MemoryAudit.apply(edit, to: m, now: now)
        case .assistant:
            let live = MemoryAuditLog.CardState(m)
            if bodyChanged {
                m.content = new.body
                m.tokenCount = Memory.estimateTokens(new.body)
                m.embeddingData = nil
            }
            if let about { m.subject = MemoryAudit.cleaned(about) }
            if let speaker { m.speaker = MemoryAudit.cleaned(speaker) }
            if let tags {
                m.category = tags.compactMap(categoryKey(forTag:)).last ?? plainCategory
                m.keywords = MemoryAudit.cleanedTags(tags.filter { categoryKey(forTag: $0) == nil })
            }
            if let importance, let value = importance { m.importance = value }
            if let confidence { m.confidence = confidence }
            // 同 `memory_card` 的 edit：她允许过的改动 = 这张她看过了，算批过；不记「她亲手改过」，置信度不自动变
            if MemoryAuditLog.CardState(m) != live {
                m.updatedAt = now
                m.reviewedAt = now
            }
        }
        if let pin, m.isUserExplicit != pin {
            m.isUserExplicit = pin
            if pin { m.decayWeight = 1.0 }
            m.updatedAt = now
        }
        if let state {
            if state == deleted {
                MemoryAudit.trash([m], now: now)
            } else if (state == states[1]) != (m.reviewedAt != nil) {
                m.reviewedAt = state == states[1] ? now : nil
                m.updatedAt = now
            }
        }
        guard MemoryAuditLog.CardState(m) != before else { return m.updatedAt }
        do { try context.save() } catch {
            before.apply(to: m)
            throw error
        }
        let (actor, via): (String, String)
        switch writer {
        case .you: (actor, via) = (MemoryAuditLog.you, MemoryAuditLog.viaFileLibrary)
        case .assistant(let name, let from): (actor, via) = (name, from)
        }
        // 她在文件库里改的是一条一份的文件：逐条
        if let entry = MemoryAuditLog.entry([(m.id, before, MemoryAuditLog.CardState(m), nil)], actor: actor, via: via,
                                            bulk: writer == .you ? false : nil, now: now) {
            try? MemoryAuditLog.append(entry, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        return m.updatedAt
    }

    /// 助手用文件工具新建一份 = 加一张卡：把文件排成 `memory_card` 的 add 交给它（查重、默认值、留痕都是那一条路）。
    /// `folder` = 路径里文件夹那一段：frontmatter 没写 about 时拿它当「说的是谁」。新建的直接是 Archive；只读的几项写了不算
    @MainActor
    static func create(text: String, folder: String?, profileId: String, conversationId: String?, memoryEnabled: Bool,
                       actor: String, via: String, source: MemoryCardTool.Source? = nil, context: ModelContext,
                       now: Date = Date()) -> MemoryCardTool.Result {
        do {
            let p = try parse(text)
            guard !p.body.isEmpty else { throw EditError.invalid("正文不能是空的：--- 下面写这一条要记的那一句话。") }
            if let state = try p[.state].map(stateValue), state == states[2] {
                throw EditError.invalid("新建的记忆条目不能直接是 \(states[2])。")
            }
            var args: [String: Any] = ["action": MemoryCardTool.Action.add.rawValue, "content": p.body]
            let hint = folder.flatMap { [noSubjectFolder, deletedFolder].contains($0) ? nil : $0 }
            if let about = MemoryAudit.cleaned(p[.about] ?? hint) { args["subject"] = about }
            if let from = MemoryAudit.cleaned(try p[.from].map { try speakerValue($0, .assistant(name: actor, via: via)) }) { args["speaker"] = from }
            if let tags = p.tags, !tags.isEmpty { args["tags"] = tags }
            if let v = try p[.importance].flatMap({ try number($0, "importance", 1...5) }) { args["importance"] = v }
            if let v = try p[.confidence].flatMap({ try number($0, "confidence", 0...100) }) { args["confidence"] = v }
            if try p[.pinned].map(pinValue) == true { args["pin"] = true }
            let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "{}"
            return MemoryCardTool.execute(inputJSON: json, profileId: profileId, conversationId: conversationId, memoryEnabled: memoryEnabled,
                                          actor: actor, via: via, source: source, context: context, now: now)
        } catch {
            return .init(text: error.localizedDescription, isError: true)
        }
    }
}

/// 文件库 › 记忆 › 日志 里看得懂的两份（粟粟 11-14）：审计日志（`audit-log.jsonl`）和写入日志（`log/写入日志.jsonl`）
/// 文件库不认 `.jsonl`，所以各排成一份只读的 md；真文件原样不动。助手的 `fs_read` 也读这两份
enum MemoryLogFolder {
    static let folder = FileLibraryMemoryFolder.root + "/" + MemoryWriteLog.folder
    static let dreamFolder = folder + "/" + FragmentDreamRecord.folder
    static let auditPath = folder + "/审计日志.md"
    static let writePath = folder + "/写入日志.md"

    struct File: Equatable, Identifiable, Sendable {
        var path: String
        var title: String
        var content: String
        var modifiedAt: Date
        var id: String { path }
    }

    /// `memory/log/c2-dream/<编号>.json` → 编号（`notes.json` 不是一次记录）
    static func dreamRecordId(_ path: String) -> String? {
        guard path.hasPrefix(dreamFolder + "/"), path.hasSuffix(".json") else { return nil }
        let name = String(path.dropFirst(dreamFolder.count + 1).dropLast(5))
        return name.contains("/") || name + ".json" == FragmentDreamNotes.fileName || !FragmentDreamRecord.isValidId(name) ? nil : name
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// 后台读。两份都在（没记录的那份写一句「还没有记录」），这样文件夹里固定看得到
    static func files(memoryRoot: URL) -> [File] {
        let audit = MemoryAuditLog.load(memoryRoot: memoryRoot)
        let writes = MemoryWriteLog.entries(memoryRoot: memoryRoot).sorted { $0.time > $1.time }
        return [
            File(path: auditPath, title: "审计日志", content: auditText(audit), modifiedAt: modified(MemoryAuditLog.url(memoryRoot: memoryRoot))),
            File(path: writePath, title: "写入日志", content: writeText(writes), modifiedAt: modified(MemoryWriteLog.fileURL(memoryRoot: memoryRoot))),
        ]
    }

    static func auditText(_ entries: [MemoryAuditLog.Entry]) -> String {
        var out = "# 审计日志\n\n记忆条目的每一笔改动：谁、什么时候、动了哪一条、改前改后。新的在前。只读；要撤回去 设置 › 记忆 › 记忆日志 点 Undo。\n"
        if entries.isEmpty { return out + "\n还没有记录。\n" }
        let undone = MemoryAuditLog.undone(entries)
        for e in entries {
            let what = e.label ?? e.action.rawValue
            out += "\n## \(timeFormatter.string(from: e.at)) · \(e.actor) · \(what) \(e.items.count)"
            out += " · \(e.via ?? "整理台")" + (undone.contains(e.id) ? " · Undone" : "") + "\n"
            if let note = e.note { out += "理由：\(note)\n" }
            for item in e.items {
                out += "- \(oneLine(item.before.content))\n"
                if let after = item.after, after.content != item.before.content { out += "  → \(oneLine(after.content))\n" }
            }
        }
        return out
    }

    static func writeText(_ entries: [MemoryWriteLog.Entry]) -> String {
        var out = "# 写入日志\n\n后台每写一次记忆记一行：什么时候、哪一项、成没成、写了什么、用的模型、花了多少。新的在前。只读。\n"
        if entries.isEmpty { return out + "\n还没有记录。\n" }
        out += "\n"
        for e in entries {
            let name = MemoryWriterID(rawValue: e.writer.lowercased()).map { " " + $0.title(assistant: "") } ?? ""
            var parts = ["\(timeFormatter.string(from: e.time))", "\(e.writer)\(name)", e.ok ? "写好了" : "没写成"]
            parts += [oneLine(e.note), e.model].filter { !$0.isEmpty }
            if let c = e.costUSD { parts.append(String(format: "$%.3f", c)) }
            out += "- " + parts.joined(separator: " · ") + "\n"
        }
        return out
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

/// 助手的 `fs_*` 眼里那几份不在盘上的记忆文件：记忆条目（`memory/cards/`，含钉住的清单）+ 两份日志。
/// 这里只管读；写在 `MemoryFolderWrite`（卡能写，清单和日志只读）
enum MemoryVirtualFiles {
    static func isVirtual(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return MemoryCardFolder.isCardPath(p) || p == MemoryLogFolder.auditPath || p == MemoryLogFolder.writePath
    }

    /// 全部现排的那几份，带全文（同步给 CC 的那棵树一次要全部，`GardenTree`）
    static func all(profileId: String, container: ModelContainer?) -> [(path: String, content: String, modifiedAt: Date)] {
        let logs = MemoryLogFolder.files(memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId)).map { ($0.path, $0.content, $0.modifiedAt) }
        // 卡要记忆总开关开着才给（同 recall）；这场对话关了「记忆参与」时调用方不传 container
        guard MemoryFlags.masterEnabled, let container else { return logs }
        let entries = MemoryCardFolder.entries(profileId: profileId, container: container)
        let pinned = MemoryCardFolder.pinnedFile(entries)
        return entries.map { ($0.path, $0.content, $0.modifiedAt) } + [(pinned.path, pinned.content, pinned.modifiedAt)] + logs
    }

    static func list(profileId: String, container: ModelContainer?) -> [FileLibraryStore.FileMeta] {
        all(profileId: profileId, container: container).map { .init(path: $0.path, bytes: $0.content.utf8.count, modifiedAt: $0.modifiedAt) }
    }

    /// nil = 没有这份。卡的路径里文件夹那一段不对（改过「说的是谁」、删了 / 放回了）也认，按文件名找
    static func read(_ path: String, profileId: String, container: ModelContainer?) -> String? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = all(profileId: profileId, container: container)
        if let hit = files.first(where: { $0.path == p }) { return hit.content }
        guard MemoryCardFolder.isCardPath(p), let name = p.split(separator: "/").last else { return nil }
        return files.first { MemoryCardFolder.isCardPath($0.path) && $0.path.hasSuffix("/" + name) }?.content
    }

    /// 钉住的清单不搜（每一行都是别的卡里已有的字）
    static func search(_ keyword: String, profileId: String, container: ModelContainer?) -> [(path: String, line: String)] {
        guard !keyword.isEmpty else { return [] }
        var hits: [(path: String, line: String)] = []
        for file in all(profileId: profileId, container: container) where file.path != MemoryCardFolder.pinnedPath {
            for line in file.content.split(separator: "\n", omittingEmptySubsequences: false)
                where line.range(of: keyword, options: .caseInsensitive) != nil {
                hits.append((file.path, String(line)))
            }
        }
        return hits
    }
}
