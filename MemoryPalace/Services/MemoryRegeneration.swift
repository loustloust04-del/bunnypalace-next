import Foundation

/// v4-1 §九：按新规则重写写坏的上下文摘要 / 窗口总结 / 时间轴（只在 DEBUG 构建里、粟粟手动点了才跑，不在启动时跑）。
/// 先整份备份到 floors/<楼层>/记忆备份/v4-1-<时间>/（memory/ 旁边，fs 工具和文件库「记忆」都看不到），拷完校验、写完成清单才算数；
/// 全部写进暂存目录，都成功了才整体替换（替换中途失败把旧目录挪回来）。回滚 = 把备份拷回去（拷失败同样挪回来）
enum MemoryRegeneration {
    static let backupFolderName = "记忆备份"
    static let folders = [TimelineStore.folder, SessionSummaryStore.folder, WindowSummaryStore.folder]
    /// 备份的完成清单：拷完、比完大小才写，写了它的才是能恢复的备份
    static let manifestName = "manifest.json"

    /// 一个窗口的原料；source 返回 nil = 窗口已经删了（读不到消息）
    struct Source {
        let title: String
        let messages: [SessionSegmentWriter.Message]
        let isCC: Bool
    }

    struct Writers {
        let persona: String
        let speakers: SessionSegmentWriter.Speakers
        let caller: SessionSegmentWriter.Caller
    }

    struct Estimate: Equatable {
        var scopeStart: Date?
        var windows = 0
        var goneWindows = 0
        var calls = 0
    }

    struct Report: Equatable {
        var backup: URL
        var windows = 0
        /// 哪个窗口、哪样、哪天没写成
        var failures: [String] = []
    }

    /// 备份的完成清单：原来有哪几个文件夹（没列的 = 原本就不存在）
    struct Manifest: Codable, Equatable {
        var folders: [String]
        var createdAt: Date
    }

    enum RegenError: LocalizedError, Equatable {
        case backupMismatch(String)
        case incompleteBackup(String)
        var errorDescription: String? {
            switch self {
            case .backupMismatch(let path): return "备份和原件大小对不上（\(path)），什么都没改"
            case .incompleteBackup(let why): return "这份备份不完整（\(why)），不能恢复"
            }
        }
    }

    /// 文件搬动（测试换成会失败的，验证失败时会挪回来）
    typealias FileOp = (URL, URL) throws -> Void
    static let move: FileOp = { try FileManager.default.moveItem(at: $0, to: $1) }
    static let copy: FileOp = { try FileManager.default.copyItem(at: $0, to: $1) }

    // MARK: - 位置

    static func backupRoot(memoryRoot: URL) -> URL {
        memoryRoot.deletingLastPathComponent().appendingPathComponent(backupFolderName, isDirectory: true)
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// 能恢复的备份（新→旧）：v4-1-* 和回滚前-*，并且有完成清单。拷到一半的（`.partial-*`、没清单的）不列
    static func backups(memoryRoot: URL) -> [URL] {
        let root = backupRoot(memoryRoot: memoryRoot)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("v4-1-") || $0.hasPrefix("回滚前-") }.sorted(by: >)
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { manifest(of: $0) != nil }
    }

    static func manifest(of backup: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: backup.appendingPathComponent(manifestName)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Manifest.self, from: data)
    }

    // MARK: - 范围

    /// 从哪天起重写：「记忆从哪天开始」；没设时从第三刀写的第一段开始（最早一段非改造前的段）
    static func scopeStart(startDay: Date?, memoryRoot: URL) -> Date? {
        if let startDay { return startDay }
        return SessionSummaryStore.all(in: SessionSummaryStore.dir(root: memoryRoot))
            .flatMap(\.segments).filter { $0.kind != .legacy && $0.start > .distantPast }.map(\.start).min()
    }

    /// 要重写的窗口：时间轴里有起点以后的事的（老文件归错月的也算）+ 上下文摘要里有起点以后第三刀写的段的
    static func windowIds(scopeStart: Date, memoryRoot: URL) -> [String] {
        let tl = TimelineStore.dir(root: memoryRoot)
        var ids = Set(TimelineStore.months(in: tl).flatMap { TimelineStore.entries(month: $0, in: tl) }
            .filter { $0.end >= scopeStart }.map(\.conversationId))
        for s in SessionSummaryStore.all(in: SessionSummaryStore.dir(root: memoryRoot))
        where s.segments.contains(where: { $0.kind != .legacy && $0.end >= scopeStart }) {
            ids.insert(s.conversationId)
        }
        return ids.sorted()
    }

    // MARK: - 每个窗口要写的几截（重写和估算共用）

    struct WindowWork {
        /// 上下文摘要：保留的段（改造前的第 0 段 + 起点以前的压缩段）
        var keep: SessionSummary
        var contextParts: [Range<Int>]
        var notBefore: Int
        var timelineParts: [Range<Int>]
    }

    /// 纯函数：API 窗口重写到原来的锚点（旧压缩段写到的最后一条；锚点曾因老收尾段盖住窗外而只推不写的，
    /// 按 compressedCount 补到那里），CC 窗口写到「写完了的份」；旧收尾段拿掉。
    /// 不套首次补写的 150 条上限：原来盖到哪就重建到哪（astra #1）
    static func work(old: SessionSummary, source: Source, scopeStart: Date, now: Date) -> WindowWork {
        let ids = source.messages.map(\.id), dates = source.messages.map(\.date)
        let notBefore = MemoryStartDay.firstAllowedIndex(dates, startDay: scopeStart)
        var keep = old
        keep.segments = old.segments.filter { $0.kind == .legacy || ($0.kind == .rolling && $0.end < scopeStart) }
        var parts: [Range<Int>] = []
        if source.isCC {
            parts = SessionCloseout.ccCompressRanges(keep, pathIds: ids, dates: dates, notBefore: notBefore, now: now, capFirst: false)
        } else {
            let rollingEnd = old.segments.last(where: { $0.kind == .rolling && $0.end >= scopeStart }).map { anchor in
                anchor.lastNodeId.flatMap { ids.lastIndex(of: $0) }.map { $0 + 1 }
                    ?? (dates.firstIndex { ($0 ?? .distantPast) > anchor.end } ?? ids.count)
            } ?? 0
            let end = max(rollingEnd, min(old.compressedCount, ids.count))
            if end > 0 {
                parts = SessionCloseout.pendingRanges(keep, pathIds: ids, dates: dates, end: end, notBefore: notBefore, capFirst: false)
                    .flatMap { SessionCloseout.chunks($0) }
            }
        }
        let timeline = notBefore < ids.count ? SessionCloseout.timelineParts(notBefore..<ids.count, dates: dates) : []
        return WindowWork(keep: keep, contextParts: parts, notBefore: notBefore, timelineParts: timeline)
    }

    /// 确认框用：几个窗口、大概几次模型调用（不算格式不对的重写）
    static func estimate(startDay: Date?, memoryRoot: URL, now: Date, source: (String) -> Source?) -> Estimate {
        guard let scope = scopeStart(startDay: startDay, memoryRoot: memoryRoot) else { return Estimate() }
        var e = Estimate(scopeStart: scope)
        let sessions = SessionSummaryStore.dir(root: memoryRoot)
        for id in windowIds(scopeStart: scope, memoryRoot: memoryRoot) {
            guard let src = source(id) else { e.goneWindows += 1; continue }
            e.windows += 1
            let old = SessionSummaryStore.load(conversationId: id, in: sessions)
                ?? SessionSummary(conversationId: id, title: src.title, compressedCount: 0, segments: [], updatedAt: now)
            let w = work(old: old, source: src, scopeStart: scope, now: now)
            e.calls += w.contextParts.count + w.timelineParts.count + 1
        }
        return e
    }

    // MARK: - 备份

    /// 「/相对路径」→ 字节数（只算文件）
    static func fileSizes(_ dir: URL) -> [String: Int] {
        let fm = FileManager.default
        guard let subs = try? fm.subpathsOfDirectory(atPath: dir.path) else { return [:] }
        var out: [String: Int] = [:]
        for rel in subs {
            var isDir: ObjCBool = false
            let path = dir.appendingPathComponent(rel).path
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            out["/" + rel] = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
        }
        return out
    }

    /// 把三个文件夹（有的话）拷到 dest，逐个比大小；对不上就删掉这份拷贝并抛错。返回原来有的那几个
    @discardableResult
    static func copyFolders(from memoryRoot: URL, to dest: URL, copy: FileOp = MemoryRegeneration.copy) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var present: [String] = []
        do {
            for f in folders {
                let src = memoryRoot.appendingPathComponent(f, isDirectory: true)
                guard fm.fileExists(atPath: src.path) else { continue }
                let to = dest.appendingPathComponent(f, isDirectory: true)
                try copy(src, to)
                guard fileSizes(src) == fileSizes(to) else { throw RegenError.backupMismatch(f) }
                present.append(f)
            }
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        return present
    }

    /// 正式备份（astra #5）：先拷进 `.partial-<名字>`，拷完校验过才写完成清单、改成正式名字
    static func makeBackup(memoryRoot: URL, name: String, copy: FileOp = MemoryRegeneration.copy) throws -> URL {
        let root = backupRoot(memoryRoot: memoryRoot)
        let partial = root.appendingPathComponent(".partial-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: partial)
        let present = try copyFolders(from: memoryRoot, to: partial, copy: copy)
        try publish(partial, as: name, folders: present)
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// 写完成清单 + 改成正式名字
    private static func publish(_ partial: URL, as name: String, folders present: [String]) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(Manifest(folders: present, createdAt: Date())).write(to: partial.appendingPathComponent(manifestName), options: .atomic)
        try FileManager.default.moveItem(at: partial, to: partial.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true))
    }

    // MARK: - 重写

    /// 备份 → 暂存目录里重写 → 都成功才整体替换。
    /// - 上下文摘要按窗口整份换：这个窗口有一截没写成就整份保留原文件（astra #2）
    /// - 时间轴按天提交：哪天没写成，那天和后面的天都留旧条目，水位线停在最后写成的那天（astra #3）
    /// - 别的错（断网、被掐断、写盘失败）整个停下，原文件不动；替换中途失败把旧目录挪回来、暂存目录留着（astra #4）
    static func run(memoryRoot: URL, startDay: Date?, now: Date, writers: Writers,
                    legacySeed: (String) -> SessionSummary?, source: (String) async -> Source?,
                    move: FileOp = MemoryRegeneration.move) async throws -> Report {
        let fm = FileManager.default
        let backup = try makeBackup(memoryRoot: memoryRoot, name: "v4-1-\(stamp(now))")
        var report = Report(backup: backup)
        guard let scope = scopeStart(startDay: startDay, memoryRoot: memoryRoot) else { return report }

        let staging = backupRoot(memoryRoot: memoryRoot).appendingPathComponent("staging-\(stamp(now))", isDirectory: true)
        var swapping = false
        do {
            try copyFolders(from: memoryRoot, to: staging)
            let sessions = SessionSummaryStore.dir(root: staging), tl = TimelineStore.dir(root: staging)
            var gone: [String] = []
            for id in windowIds(scopeStart: scope, memoryRoot: memoryRoot) {
                try Task.checkCancellation()
                guard let src = await source(id) else { gone.append(id); continue }
                report.windows += 1
                let old = SessionSummaryStore.load(conversationId: id, in: sessions) ?? legacySeed(id)
                    ?? SessionSummary(conversationId: id, title: src.title, compressedCount: 0, segments: [], updatedAt: now)
                let w = work(old: old, source: src, scopeStart: scope, now: now)
                let name = "《\(src.title.isEmpty ? id.prefix(8) : Substring(src.title))》"

                // 上下文摘要：全写成才换，有一截没成就整份保留原文件（水位不会超过真写到的地方）
                var s = w.keep
                s.title = src.title
                var contextOK = true
                do {
                    let done = try await SessionCloseout.writeContextParts(w.contextParts, messages: src.messages, into: &s, title: src.title,
                                                                           persona: writers.persona, speakers: writers.speakers,
                                                                           caller: writers.caller, save: { _ in })
                    if !done {
                        contextOK = false
                        report.failures.append("\(name) 上下文摘要：写手跳过（预算闸 / 空输出），这个窗口的上下文摘要原样保留")
                    }
                } catch MemoryWriterError.format(let p) {
                    contextOK = false
                    report.failures.append("\(name) 上下文摘要：格式不对（\(p)），这个窗口的上下文摘要原样保留")
                }
                let context: SessionSummary
                if contextOK {
                    context = s
                    if s.segments.isEmpty && s.compressedCount == 0 {
                        // 只剩老收尾段的窗口：上下文摘要文件拿掉（收尾段在备份里留着，窗口总结在 windows/）
                        if let url = SessionSummaryStore.fileURL(conversationId: id, in: sessions) { try fm.removeItem(at: url) }
                    } else if s.segments != old.segments {
                        try SessionSummaryStore.save(s, in: sessions)
                    }
                } else {
                    context = old
                }

                // 窗口总结
                do {
                    if let ws = try await SessionCloseout.composeWindowSummary(context: context, messages: src.messages, title: src.title,
                                                                               notBefore: w.notBefore, persona: writers.persona,
                                                                               speakers: writers.speakers, caller: writers.caller),
                       !ws.segments.isEmpty {
                        try WindowSummaryStore.save(ws, in: staging)
                    }
                } catch MemoryWriterError.format(let p) {
                    report.failures.append("\(name) 窗口总结：格式不对（\(p)）")
                }

                try await rewriteTimeline(conversationId: id, source: src, parts: w.timelineParts, scope: scope, dir: tl,
                                          writers: writers, name: name, report: &report)
            }
            // 删掉的窗口：旧条目原样保留，按 05:00 规则放进对应的月文件
            if !gone.isEmpty { try refile(conversationIds: Set(gone), in: tl) }
            swapping = true
            try swap(staging: staging, into: memoryRoot, move: move)
        } catch {
            // 替换还没开始：暂存目录只是草稿，删掉；替换开始了：旧目录已经挪回去，暂存目录（含 old-*）留着备查
            if !swapping { try? fm.removeItem(at: staging) }
            throw error
        }
        try? fm.removeItem(at: staging)
        return report
    }

    /// 一个窗口的时间轴按天重写：先拿掉这个窗口起点以后的旧条目（归错月的也拿），一天一天写，一天里有一份没写成就撤掉这天新写的、
    /// 停下（后面的天不写）。写成的天不放回旧的；没写成的天和后面的天放回旧条目——放回的老 v2 条目改成老格式，
    /// 不让它的 last 把水位线顶过没写成的那天，日常收尾会从最后写成的那天接着补
    static func rewriteTimeline(conversationId id: String, source src: Source, parts: [Range<Int>], scope: Date, dir tl: URL,
                                writers: Writers, name: String, report: inout Report) async throws {
        let scopeKey = MemoryDay.key(scope)
        var removed: [TimelineEntry] = []
        func isOld(_ e: TimelineEntry) -> Bool { e.conversationId == id && (e.dayKey >= scopeKey || e.end >= scope) }
        for month in TimelineStore.months(in: tl) {
            try TimelineStore.mutate(month: month, in: tl) { list in
                removed += list.filter(isOld)
                return list.filter { !isOld($0) }
            }
        }
        var days: [(day: String, parts: [Range<Int>])] = []
        for part in parts {
            let day = src.messages[part].lazy.compactMap(\.date).first.map { MemoryDay.key($0) } ?? "?"
            if days.last?.day == day { days[days.count - 1].parts.append(part) } else { days.append((day, [part])) }
        }
        var written: Set<String> = []
        var failedFrom: String?
        dayLoop: for (day, dayParts) in days {
            for part in dayParts {
                var problem: String?
                do {
                    let n = try await SessionCloseout.writeTimeline(part, messages: src.messages, conversationId: id, title: src.title,
                                                                    persona: writers.persona, speakers: writers.speakers,
                                                                    caller: writers.caller, dir: tl)
                    if n == 0 { problem = "写手跳过（预算闸 / 空输出）" }
                } catch MemoryWriterError.format(let p) {
                    problem = "格式不对（\(p)）"
                }
                if let problem {
                    try TimelineStore.mutate(month: String(day.prefix(7)), in: tl) { $0.filter { !($0.conversationId == id && $0.day == day) } }
                    report.failures.append("\(name) 时间轴 \(day)：\(problem)，这天起留着旧的，日常收尾会从前一天接着补")
                    failedFrom = day
                    break dayLoop
                }
            }
            written.insert(day)
        }
        for var e in removed where !written.contains(e.dayKey) {
            if let f = failedFrom, e.dayKey >= f { e.day = nil; e.lastNodeId = nil }
            try TimelineStore.mutate(month: String(e.dayKey.prefix(7)), in: tl) { $0 + [e] }
        }
    }

    /// 这些窗口的条目，归错月文件的挪到 05:00 规则下的那个月
    static func refile(conversationIds: Set<String>, in tl: URL) throws {
        for month in TimelineStore.months(in: tl) {
            var move: [TimelineEntry] = []
            try TimelineStore.mutate(month: month, in: tl) { list in
                move = list.filter { conversationIds.contains($0.conversationId) && !$0.dayKey.hasPrefix(month) }
                return list.filter { e in !move.contains(e) }
            }
            for e in move { try TimelineStore.mutate(month: String(e.dayKey.prefix(7)), in: tl) { $0 + [e] } }
        }
    }

    /// 暂存目录里的三个文件夹整体换进 memory/（旧的先挪进暂存目录的 old-*）。中途哪一步失败：
    /// 已经装上的新目录挪回暂存目录，旧目录挪回 memory/，再把错抛出去（astra #4）
    static func swap(staging: URL, into memoryRoot: URL, move: FileOp = MemoryRegeneration.move) throws {
        let fm = FileManager.default
        var installed: [String] = []
        do {
            for f in folders {
                let staged = staging.appendingPathComponent(f, isDirectory: true)
                guard fm.fileExists(atPath: staged.path) else { continue }
                let live = memoryRoot.appendingPathComponent(f, isDirectory: true)
                if fm.fileExists(atPath: live.path) {
                    try move(live, staging.appendingPathComponent("old-\(f)", isDirectory: true))
                }
                try move(staged, live)
                installed.append(f)
            }
        } catch {
            for f in folders.reversed() {
                let live = memoryRoot.appendingPathComponent(f, isDirectory: true)
                let old = staging.appendingPathComponent("old-\(f)", isDirectory: true)
                if installed.contains(f) { try? fm.moveItem(at: live, to: staging.appendingPathComponent(f, isDirectory: true)) }
                if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: live.path) { try? fm.moveItem(at: old, to: live) }
            }
            throw error
        }
    }

    // MARK: - 回滚

    /// 先核对备份的完成清单（拷到一半的拒绝），把现在的三个文件夹挪到一边（记忆备份/回滚前-<时间>/），再把备份拷回去；
    /// 拷失败就删掉拷了一半的、把挪开的挪回来（astra #4 #5）。清单里没列的文件夹 = 备份时原本就没有，恢复后也没有
    static func restore(backup: URL, memoryRoot: URL, now: Date, copy: FileOp = MemoryRegeneration.copy) throws {
        let fm = FileManager.default
        guard let m = manifest(of: backup) else { throw RegenError.incompleteBackup("没有完成清单，可能拷到一半") }
        for f in m.folders where !fm.fileExists(atPath: backup.appendingPathComponent(f, isDirectory: true).path) {
            throw RegenError.incompleteBackup("清单里有 \(f)，备份里却没有")
        }
        let name = "回滚前-\(stamp(now))"
        let aside = backupRoot(memoryRoot: memoryRoot).appendingPathComponent(".partial-\(name)", isDirectory: true)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        let originallyPresent = Set(folders.filter { fm.fileExists(atPath: memoryRoot.appendingPathComponent($0, isDirectory: true).path) })
        var movedAside: [String] = []
        do {
            for f in folders {
                let live = memoryRoot.appendingPathComponent(f, isDirectory: true)
                guard fm.fileExists(atPath: live.path) else { continue }
                try fm.moveItem(at: live, to: aside.appendingPathComponent(f, isDirectory: true))
                movedAside.append(f)
            }
            for f in m.folders {
                try copy(backup.appendingPathComponent(f, isDirectory: true), memoryRoot.appendingPathComponent(f, isDirectory: true))
            }
        } catch {
            for f in folders {
                let live = memoryRoot.appendingPathComponent(f, isDirectory: true)
                // 现在 memory/ 里的这个文件夹是拷回来的（原来的已挪开，或原本就没有）→ 删掉；还没挪开的原件不碰
                if fm.fileExists(atPath: live.path), movedAside.contains(f) || !originallyPresent.contains(f) { try? fm.removeItem(at: live) }
                if movedAside.contains(f) { try? fm.moveItem(at: aside.appendingPathComponent(f, isDirectory: true), to: live) }
            }
            try? fm.removeItem(at: aside)
            throw error
        }
        try publish(aside, as: name, folders: movedAside)
    }
}
