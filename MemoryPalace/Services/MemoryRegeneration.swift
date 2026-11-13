import MemoryCore
import CryptoKit
import Foundation

/// 记忆的备份 / 恢复（只在 DEBUG 构建里、粟粟手动点了才跑）+ 三代搬迁复用的 A2 补写范围（`work` / `apiAnchor`）。
/// 备份放在 floors/<楼层>/记忆备份/<名字>/（memory/ 旁边，fs 工具和文件库「记忆」都看不到）：先查一遍（有符号链接 / 读不了就停下），
/// 拷完逐个文件比大小 + SHA256，写完成清单（含文件清单）才发布。恢复先按清单核备份，再把现在的挪开、发布成「回滚前」，最后拷回去
enum MemoryRegeneration {
    static let backupFolderName = "记忆备份"
    /// 老 v4-1 备份管的三个（老清单没有 covered 时按它）
    static let folders = [TimelineStore.folder, SessionSummaryStore.folder, WindowSummaryStore.folder]
    /// 备份的完成清单：拷完、核过才写，写了它的才是能恢复的备份
    static let manifestName = "manifest.json"

    /// 一个窗口的原料；source 返回 nil = 窗口已经删了（读不到消息）
    struct Source {
        let title: String
        let messages: [SessionSegmentWriter.Message]
        let isCC: Bool
    }

    /// 一个文件：大小 + 内容的 SHA256（astra #10）
    struct FileInfo: Codable, Equatable {
        var size: Int
        var sha256: String
    }

    /// 备份的完成清单：原来有哪几个文件夹（没列的 = 原本就不存在）。
    /// covered = 这份备份管哪几个文件夹（含原本不存在的，恢复只动它们）；老清单没有 = 老三个（plan-memory-migrate-3gen B1）。
    /// files = 「文件夹/相对路径」→ 大小 + SHA256；老清单没有 = 只核文件夹在不在
    struct Manifest: Codable, Equatable {
        var folders: [String]
        var createdAt: Date
        var covered: [String]? = nil
        var files: [String: FileInfo]? = nil

        var coveredFolders: [String] { covered ?? MemoryRegeneration.folders }
    }

    enum RegenError: LocalizedError, Equatable {
        case backupMismatch(String)
        case incompleteBackup(String)
        case symlink(String)
        case notRegularFile(String)
        case rollbackIncomplete(String)
        var errorDescription: String? {
            switch self {
            case .backupMismatch(let path): return "备份和原件对不上（\(path)），什么都没改"
            case .incompleteBackup(let why): return "这份备份不完整（\(why)），不能恢复"
            case .symlink(let path): return "发现符号链接（\(path)），停下了，什么都没改"
            case .notRegularFile(let path): return "发现不是普通文件的东西（\(path)），停下了，什么都没改"
            case .rollbackIncomplete(let path): return "恢复失败，把原件挪回去也没做完：恢复前的原件都留在 \(path)，什么都没删"
            }
        }
    }

    /// 文件拷贝（测试换成会失败的，验证失败时会挪回来）
    typealias FileOp = (URL, URL) throws -> Void
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

    /// 有完成清单才列出（含 A3 新格式重写前的 windows 备份）；半份 `.partial-*` 不列。
    static func backups(memoryRoot: URL) -> [URL] {
        let root = backupRoot(memoryRoot: memoryRoot)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let prefixes = ["v4-1-", MemoryMigration.backupPrefix, CatalogSeedCleanup.backupPrefix, TimelineDaily.backupPrefix,
                        WindowSummaryRewrite.backupPrefix, "回滚前-"]
        return names.filter { n in prefixes.contains { n.hasPrefix($0) } }.sorted(by: >)
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

    // MARK: - 一个窗口要写的几截（三代搬迁 a2Full 用）

    struct WindowWork {
        /// 上下文摘要：保留的段（改造前的第 0 段 + 起点以前开始的段）
        var keep: SessionSummary
        var contextParts: [Range<Int>]
        var notBefore: Int
    }

    /// 纯函数：API 窗口重写到原来的锚点（旧压缩段写到的最后一条；锚点曾因老收尾段盖住窗外而只推不写的，
    /// 按 compressedCount 补到那里），CC 窗口写到「写完了的份」。不套首次补写的 150 条上限：原来盖到哪就重建到哪（astra #1）。
    /// 起点以前开始的段整段留着（Q4 / 三代搬迁 astra #4：跨起点的也留，起点以前的消息不给写手，只有它记着那截），
    /// 只拿掉整段在起点以后的
    static func work(old: SessionSummary, source: Source, scopeStart: Date, now: Date) -> WindowWork {
        let ids = source.messages.map(\.id), dates = source.messages.map(\.date)
        let notBefore = MemoryStartDay.firstAllowedIndex(dates, startDay: scopeStart)
        var keep = old
        keep.segments = old.segments.filter {
            $0.kind == .legacy || ($0.kind == .rolling && $0.start < scopeStart)
                || ($0.kind == .closeout && !$0.isTail && $0.start < scopeStart)
        }
        var parts: [Range<Int>] = []
        if source.isCC {
            parts = SessionCloseout.ccCompressRanges(keep, pathIds: ids, dates: dates, notBefore: notBefore, now: now, capFirst: false)
        } else {
            let end = apiAnchor(old: old, ids: ids, dates: dates, scopeStart: scopeStart)
            if end > 0 {
                parts = SessionCloseout.pendingRanges(keep, pathIds: ids, dates: dates, end: end, notBefore: notBefore, capFirst: false)
                    .flatMap { SessionCloseout.chunks($0) }
            }
        }
        return WindowWork(keep: keep, contextParts: parts, notBefore: notBefore)
    }

    /// 纯函数：API 窗口的上下文摘要该写到哪（不含）——起点以后最后一段压缩段写到的那条之后，和 compressedCount 取大
    static func apiAnchor(old: SessionSummary, ids: [String], dates: [Date?], scopeStart: Date) -> Int {
        let rollingEnd = old.segments.last(where: { $0.kind == .rolling && $0.end >= scopeStart }).map { anchor in
            anchor.lastNodeId.flatMap { ids.lastIndex(of: $0) }.map { $0 + 1 }
                ?? (dates.firstIndex { ($0 ?? .distantPast) > anchor.end } ?? ids.count)
        } ?? 0
        return max(rollingEnd, min(old.compressedCount, ids.count))
    }

    // MARK: - 核对（astra #5 #10）

    /// 一个文件夹里的全部文件：「相对路径」→ 大小 + SHA256。列目录 / 读属性 / 读内容哪一步失败都抛；
    /// 碰到符号链接（文件夹本身也算）、不是普通文件的东西就抛，报路径
    static func inventory(_ dir: URL) throws -> [String: FileInfo] {
        var out: [String: FileInfo] = [:]
        try walk(dir, rel: "", into: &out)
        return out
    }

    private static let walkKeys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]

    private static func walk(_ url: URL, rel: String, into out: inout [String: FileInfo]) throws {
        let v = try url.resourceValues(forKeys: Set(walkKeys))
        if v.isSymbolicLink == true { throw RegenError.symlink(url.path) }
        if v.isDirectory == true {
            for item in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: walkKeys) {
                try walk(item, rel: rel.isEmpty ? item.lastPathComponent : rel + "/" + item.lastPathComponent, into: &out)
            }
        } else if v.isRegularFile == true {
            let data = try Data(contentsOf: url)
            out[rel] = FileInfo(size: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        } else {
            throw RegenError.notRegularFile(url.path)
        }
    }

    /// 有没有这个东西（符号链接本身也算有，不跟过去）
    static func itemExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    // MARK: - 备份

    /// 把这几个文件夹（有的话；默认老三个）拷到 dest：拷之前全查一遍（有符号链接 / 读不了就停下，什么都没建），
    /// 拷完逐个文件比大小 + SHA256；对不上就删掉这份拷贝并抛错。返回原来有的那几个
    @discardableResult
    static func copyFolders(from memoryRoot: URL, to dest: URL, folders: [String] = MemoryRegeneration.folders,
                            copy: FileOp = MemoryRegeneration.copy) throws -> [String] {
        let fm = FileManager.default
        let present = folders.filter { itemExists(memoryRoot.appendingPathComponent($0, isDirectory: true)) }
        var expected: [String: [String: FileInfo]] = [:]
        for f in present { expected[f] = try inventory(memoryRoot.appendingPathComponent(f, isDirectory: true)) }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            for f in present {
                let to = dest.appendingPathComponent(f, isDirectory: true)
                try copy(memoryRoot.appendingPathComponent(f, isDirectory: true), to)
                guard try inventory(to) == expected[f] else { throw RegenError.backupMismatch(f) }
            }
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        return present
    }

    /// 正式备份（astra #5）：先拷进 `.partial-<名字>`，拷完核过才写完成清单、改成正式名字。folders = 这份备份管哪几个
    static func makeBackup(memoryRoot: URL, name: String, folders: [String] = MemoryRegeneration.folders,
                           copy: FileOp = MemoryRegeneration.copy) throws -> URL {
        let root = backupRoot(memoryRoot: memoryRoot)
        let partial = root.appendingPathComponent(".partial-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: partial)
        let present = try copyFolders(from: memoryRoot, to: partial, folders: folders, copy: copy)
        try publish(partial, as: name, folders: present, covered: folders)
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// 写完成清单（含逐个文件的大小 + SHA256）+ 改成正式名字
    private static func publish(_ partial: URL, as name: String, folders present: [String], covered: [String]) throws {
        var files: [String: FileInfo] = [:]
        for f in present {
            for (rel, info) in try inventory(partial.appendingPathComponent(f, isDirectory: true)) { files[f + "/" + rel] = info }
        }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(Manifest(folders: present, createdAt: Date(), covered: covered, files: files))
            .write(to: partial.appendingPathComponent(manifestName), options: .atomic)
        try FileManager.default.moveItem(at: partial, to: partial.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true))
    }

    /// 按清单核备份（恢复前）：清单里的文件夹都在；有文件清单的逐个比大小 + SHA256，多了少了都不行；有符号链接也不行。
    /// 返回每个文件夹拷回去以后应该长什么样
    static func verify(_ backup: URL, _ m: Manifest) throws -> [String: [String: FileInfo]] {
        var actual: [String: [String: FileInfo]] = [:]
        for f in m.folders {
            let dir = backup.appendingPathComponent(f, isDirectory: true)
            guard itemExists(dir) else { throw RegenError.incompleteBackup("清单里有 \(f)，备份里却没有") }
            actual[f] = try inventory(dir)
        }
        if let files = m.files {
            var flat: [String: FileInfo] = [:]
            for (f, list) in actual { for (rel, info) in list { flat[f + "/" + rel] = info } }
            guard flat == files else { throw RegenError.incompleteBackup("备份里的文件和清单对不上") }
        }
        return actual
    }

    // MARK: - 恢复

    /// 含 wiki 的整目录恢复：wiki 楼层锁 → 月文件写锁 → 待续本子锁；同步换盘只在后台执行。
    @MainActor
    static func restoreExclusively(backup: URL, memoryRoot: URL, now: Date,
                                   copy: @escaping FileOp = MemoryRegeneration.copy, profileId: String? = nil,
                                   defaults: UserDefaults = .standard) async throws {
        let touchesWiki = await Task.detached(priority: .userInitiated) {
            profileId?.isEmpty == false && manifest(of: backup)?.coveredFolders.contains("wiki") == true
        }.value
        let restoreFiles = {
            try await Task.detached(priority: .userInitiated) {
                try restore(backup: backup, memoryRoot: memoryRoot, now: now, copy: copy, profileId: profileId, defaults: defaults)
            }.value
        }
        if touchesWiki {
            try await WikiProposalReview.exclusive(wiki: WikiStore(root: memoryRoot.appendingPathComponent("wiki", isDirectory: true)), restoreFiles)
        } else {
            try await restoreFiles()
        }
    }

    /// 先按完成清单核备份（拷到一半的、文件对不上的拒绝），把这份备份管的文件夹（covered；老清单 = 老三个）挪到一边，
    /// 挪好就发布成「回滚前-<时间>」（备份列表里看得到、能恢复，astra #11），再把备份拷回去、逐个核；
    /// 拷失败就删掉拷了一半的、把挪开的逐个挪回来——挪回有一样没成就整份留着、报路径，绝不清理（astra #1）。
    /// 不归这份备份管的文件夹一律不碰（B2）；清单里没列的文件夹 = 备份时原本就没有，恢复后也没有。
    /// profileId 非空：整段拿着待续本子的锁，出来时清缓存（astra #7）。恢复成了，三代搬迁没撤完的「正在搬」标记作废、删掉
    static func restore(backup: URL, memoryRoot: URL, now: Date, copy: FileOp = MemoryRegeneration.copy, profileId: String? = nil,
                        defaults: UserDefaults = .standard) throws {
        guard let m = manifest(of: backup) else { throw RegenError.incompleteBackup("没有完成清单，可能拷到一半") }
        let expected = try verify(backup, m)
        let timeline = TimelineStore.dir(root: memoryRoot)
        let touchesTimeline = m.coveredFolders.contains(TimelineStore.folder)
        var before = Set<String>()
        // 换文件夹拿着月文件写锁（c2c3-v2 第 7 段 astra #4）：A4 的提交和它不交错（锁序：月文件锁 → 待续本子锁，和 A4 提交同序）
        try TimelineStore.withWriteLock {
            if touchesTimeline { before = TimelineDaily.dayKeys(timelineDir: timeline) }
            if let profileId {
                try PendingStore.replacingFiles(profileId: profileId) {
                    try swapIn(backup: backup, manifest: m, expected: expected, memoryRoot: memoryRoot, now: now, copy: copy)
                }
            } else {
                try swapIn(backup: backup, manifest: m, expected: expected, memoryRoot: memoryRoot, now: now, copy: copy)
            }
        }
        MemoryMigration.clearMarkers(memoryRoot: memoryRoot)
        // 恢复了时间轴：恢复前后出现过的日子 + 恢复那天以前的全部日子，A4 自动调度以后不碰（手动「重写这天」照样能写）；空备份也记
        if let profileId, touchesTimeline {
            TimelineDaily.noteRestored(profileId: profileId, before: before, after: TimelineDaily.dayKeys(timelineDir: timeline), now: now,
                                       defaults: defaults)
        }
    }

    private static func swapIn(backup: URL, manifest m: Manifest, expected: [String: [String: FileInfo]], memoryRoot: URL,
                               now: Date, copy: FileOp) throws {
        let fm = FileManager.default
        let covered = m.coveredFolders
        let name = "回滚前-\(stamp(now))"
        let root = backupRoot(memoryRoot: memoryRoot)
        var aside = root.appendingPathComponent(".partial-\(name)", isDirectory: true)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        let originallyPresent = Set(covered.filter { itemExists(memoryRoot.appendingPathComponent($0, isDirectory: true)) })
        var moved: [String] = []
        do {
            for f in covered where originallyPresent.contains(f) {
                try fm.moveItem(at: memoryRoot.appendingPathComponent(f, isDirectory: true), to: aside.appendingPathComponent(f, isDirectory: true))
                moved.append(f)
            }
            try publish(aside, as: name, folders: moved, covered: covered)
            aside = root.appendingPathComponent(name, isDirectory: true)
            for f in m.folders where covered.contains(f) {
                let live = memoryRoot.appendingPathComponent(f, isDirectory: true)
                try copy(backup.appendingPathComponent(f, isDirectory: true), live)
                guard try inventory(live) == expected[f] else { throw RegenError.backupMismatch(f) }
            }
        } catch {
            try putBack(from: aside, moved: moved, covered: covered, originallyPresent: originallyPresent, memoryRoot: memoryRoot)
            throw error
        }
    }

    /// 恢复失败的回退：memory/ 里拷回来的（原来的已挪开，或原本就没有）删掉，挪开的逐个挪回来。
    /// 每一样都成了才删掉挪开的那个文件夹；有一样没成就整份留着、抛错报路径
    private static func putBack(from aside: URL, moved: [String], covered: [String], originallyPresent: Set<String>, memoryRoot: URL) throws {
        let fm = FileManager.default
        var ok = true
        for f in covered {
            let live = memoryRoot.appendingPathComponent(f, isDirectory: true)
            if itemExists(live), moved.contains(f) || !originallyPresent.contains(f) {
                do { try fm.removeItem(at: live) } catch { ok = false }
            }
            if moved.contains(f) {
                do { try fm.moveItem(at: aside.appendingPathComponent(f, isDirectory: true), to: live) } catch { ok = false }
            }
        }
        guard ok else { throw RegenError.rollbackIncomplete(aside.path) }
        try? fm.removeItem(at: aside)
    }
}
