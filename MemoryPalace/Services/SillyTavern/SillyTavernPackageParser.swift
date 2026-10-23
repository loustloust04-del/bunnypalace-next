import Foundation
import CryptoKit
import ZIPFoundation

/// 酒馆整包盘点（卡库 ⑧a，plan §6.1）：ZIP 或文件夹 → 归一到 `default-user` 相对路径 → 复制只读快照到 staging → 清单。
/// 只读源、不访问 live managers、不执行脚本、不联网；`secrets.json` 只记大小，内容不读不复制。

enum SillyTavernFileCategory: String, CaseIterable, Codable {
    case card, cardAsset, chat, groupChat, group, world, preset, quickReply, personaAvatar
    case userFile, userImage, backup, extensionFile, settings, credentials, unknown
}

struct SillyTavernManifestEntry: Equatable {
    let relativePath: String
    let size: Int64
    /// 凭据文件不读，没有 hash
    let sha256: String?
    let category: SillyTavernFileCategory
}

/// 限额按粟粟本机样本定（2026-09-30 盘点 `sillytavern_git/data/default-user`）：
/// 2,711 个文件、721,217,280 字节（≈688 MiB）、最大单文件 82,914,014 字节（扩展自带的 .git pack）；
/// 样本里 ≥1 MiB 的文件 deflate 压缩比最高 6.7。
struct SillyTavernPackageLimits {
    /// ≈ 样本总量 × 6
    var maxTotalBytes: Int64 = 4 << 30
    /// ≈ 样本最大单文件 × 6.5
    var maxFileBytes: Int64 = 512 << 20
    /// ≈ 样本文件数 × 7
    var maxFileCount = 20_000
    /// ≈ 样本最高压缩比 × 15；只查解压后 ≥ ratioCheckMinBytes 的条目（小文件比值没意义）
    var maxCompressionRatio: Double = 100
    var ratioCheckMinBytes: Int64 = 1 << 20
    /// staging 写完还要给系统留的余量
    var diskMarginBytes: Int64 = 256 << 20

    static let standard = SillyTavernPackageLimits()
}

enum SillyTavernPackageError: LocalizedError, Equatable {
    case sourceMissing
    case notAPackage
    case ambiguousRoot([String])
    case unsafePath(String)
    case unsafeSymlink(String)
    case pathCollision(String, String)
    case tooManyFiles(Int)
    case tooLarge(Int64)
    case fileTooLarge(String, Int64)
    case suspiciousCompression(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case corruptArchive(String)
    case sourceChanged(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "找不到选中的文件或文件夹"
        case .notAPackage: return "没认出酒馆数据：需要「下载全部数据」的压缩包或 data/default-user 文件夹"
        case .ambiguousRoot(let roots): return "包里有多个用户目录（\(roots.joined(separator: "、"))），请只选一个"
        case .unsafePath(let path): return "包里有越界路径：\(path)"
        case .unsafeSymlink(let path): return "包里有指向包外的链接：\(path)"
        case .pathCollision(let a, let b): return "包里有大小写或写法冲突的同名路径：\(a) / \(b)"
        case .tooManyFiles(let count): return "文件太多（\(count) 个）"
        case .tooLarge(let bytes): return "解压后太大（\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))）"
        case .fileTooLarge(let path, let bytes): return "单个文件太大：\(path)（\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))）"
        case .suspiciousCompression(let path): return "压缩比异常，疑似压缩炸弹：\(path)"
        case .insufficientDiskSpace(let needed, let available):
            return "磁盘空间不够：需要 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))，剩 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
        case .corruptArchive(let detail): return "压缩包损坏：\(detail)"
        case .sourceChanged(let path): return "复制时源文件变了：\(path)，请让酒馆停下后重新盘点"
        }
    }
}

struct SillyTavernSnapshot {
    enum SourceKind: String { case zip, directory }

    struct Issue: Equatable {
        let relativePath: String
        let reason: String
    }

    let sourceKind: SourceKind
    /// 包里用户目录相对选中位置的前缀（"" = 选中的就是用户目录；"default-user/" = 外面包了一层）
    let rootPrefix: String
    /// staging 里的用户目录（只读快照）
    let root: URL
    /// staging 容器目录，清理时整个删
    let stagingDirectory: URL
    let entries: [SillyTavernManifestEntry]
    /// 没进快照的：包内链接（不跟随）、特殊文件、用户目录外的条目
    let skipped: [Issue]

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }

    func url(for relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    func entries(in category: SillyTavernFileCategory) -> [SillyTavernManifestEntry] {
        entries.filter { $0.category == category }
    }

    func removeStaging() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
}

enum SillyTavernPackageParser {
    static let credentialsPath = "secrets.json"

    // MARK: - 类别

    static func category(for relativePath: String) -> SillyTavernFileCategory {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let top = parts.first, let name = parts.last else { return .unknown }
        let ext = (name as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "avif"]
        switch (top, parts.count) {
        case ("settings.json", 1): return .settings
        case (credentialsPath, 1): return .credentials
        case ("characters", 2): return ext == "png" || ext == "json" ? .card : .unknown
        case ("characters", _): return parts.count > 2 ? .cardAsset : .unknown
        case ("chats", 3): return ext == "jsonl" ? .chat : .unknown
        case ("group chats", 2): return ext == "jsonl" ? .groupChat : .unknown
        case ("groups", 2): return ext == "json" ? .group : .unknown
        case ("worlds", 2): return ext == "json" ? .world : .unknown
        case ("OpenAI Settings", 2): return ext == "json" ? .preset : .unknown
        case ("QuickReplies", 2): return ext == "json" ? .quickReply : .unknown
        case ("User Avatars", 2): return imageExts.contains(ext) ? .personaAvatar : .unknown
        case ("user", 3...) where parts[1] == "files": return .userFile
        case ("user", 3...) where parts[1] == "images": return .userImage
        case ("backups", 2...): return .backup
        case ("extensions", 2...): return .extensionFile
        default: return .unknown
        }
    }

    // MARK: - 快照

    /// source 是 .zip 文件或文件夹；stagingParent 下新建一个 staging 目录放快照（调用方用完 `removeStaging`）。
    static func snapshot(source: URL, stagingParent: URL, limits: SillyTavernPackageLimits = .standard) throws -> SillyTavernSnapshot {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { throw SillyTavernPackageError.sourceMissing }
        if isDir.boolValue {
            return try snapshotDirectory(source, stagingParent: stagingParent, limits: limits)
        }
        return try snapshotZip(source, stagingParent: stagingParent, limits: limits)
    }

    // MARK: - 通用流程

    private enum RawKind: Equatable {
        case file
        /// 目标归一到「相对选中位置」的路径；nil = 指到选中位置外面或绝对路径
        case symlink(target: String?)
        case other
    }

    private struct RawEntry {
        let path: String
        let kind: RawKind
        let size: Int64
        let compressedSize: Int64?
    }

    private struct Plan {
        let prefix: String
        let files: [RawEntry]
        let skipped: [SillyTavernSnapshot.Issue]
    }

    /// 找用户目录、过链接、查限额与碰撞——ZIP 和文件夹共用
    private static func plan(_ raw: [RawEntry], limits: SillyTavernPackageLimits) throws -> Plan {
        let prefix = try locateUserRoot(filePaths: raw.filter { $0.kind == .file }.map(\.path))
        var files: [RawEntry] = []
        var skipped: [SillyTavernSnapshot.Issue] = []
        var outside = 0
        for entry in raw {
            guard entry.path.hasPrefix(prefix) else { outside += 1; continue }
            let rel = String(entry.path.dropFirst(prefix.count))
            switch entry.kind {
            case .file:
                files.append(RawEntry(path: rel, kind: .file, size: entry.size, compressedSize: entry.compressedSize))
            case .symlink(let target):
                guard let target, target.hasPrefix(prefix), target.count > prefix.count else { throw SillyTavernPackageError.unsafeSymlink(rel) }
                skipped.append(.init(relativePath: rel, reason: "包内链接，不跟随"))
            case .other:
                skipped.append(.init(relativePath: rel, reason: "不是普通文件"))
            }
        }
        if outside > 0 { skipped.append(.init(relativePath: "", reason: "用户目录外 \(outside) 项，未盘点")) }

        guard files.count <= limits.maxFileCount else { throw SillyTavernPackageError.tooManyFiles(files.count) }
        var total: Int64 = 0
        var seen: [String: String] = [:]
        var dirs: [String: String] = [:]
        for file in files {
            guard file.size <= limits.maxFileBytes else { throw SillyTavernPackageError.fileTooLarge(file.path, file.size) }
            if let compressed = file.compressedSize, file.size >= limits.ratioCheckMinBytes,
               Double(file.size) / Double(max(compressed, 1)) > limits.maxCompressionRatio {
                throw SillyTavernPackageError.suspiciousCompression(file.path)
            }
            total += file.size
            guard total <= limits.maxTotalBytes else { throw SillyTavernPackageError.tooLarge(total) }
            let key = collisionKey(file.path)
            if let other = seen[key] ?? dirs[key] { throw SillyTavernPackageError.pathCollision(other, file.path) }
            seen[key] = file.path
            let parts = file.path.split(separator: "/")
            for depth in 1..<max(parts.count, 1) {
                let dir = parts.prefix(depth).joined(separator: "/")
                let dirKey = collisionKey(dir)
                if let other = seen[dirKey] { throw SillyTavernPackageError.pathCollision(other, file.path) }
                if let existing = dirs[dirKey], existing != dir { throw SillyTavernPackageError.pathCollision(existing, dir) }
                dirs[dirKey] = dir
            }
        }
        return Plan(prefix: prefix, files: files, skipped: skipped)
    }

    /// APFS 默认大小写不敏感、Unicode 归一不敏感：按同一规则比
    static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// 最浅一层同时认得出酒馆用户目录的位置：根、外包一层、外包两层（data/default-user）
    static func locateUserRoot(filePaths: [String]) throws -> String {
        let files = Set(filePaths)
        var prefixes: [[String]] = [[""], [], []]
        var seen = Set<String>()
        for path in filePaths {
            let parts = path.split(separator: "/").map(String.init)
            for depth in 1...2 where parts.count > depth {
                let prefix = parts.prefix(depth).joined(separator: "/") + "/"
                if seen.insert(prefix).inserted { prefixes[depth].append(prefix) }
            }
        }
        func isRoot(_ prefix: String) -> Bool {
            if files.contains(prefix + "settings.json") { return true }
            let hasCharacters = filePaths.contains { $0.hasPrefix(prefix + "characters/") }
            return hasCharacters && filePaths.contains { $0.hasPrefix(prefix + "chats/") }
        }
        for level in prefixes {
            let hits = level.filter(isRoot).sorted()
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { throw SillyTavernPackageError.ambiguousRoot(hits) }
        }
        throw SillyTavernPackageError.notAPackage
    }

    private static func checkDiskSpace(_ plan: Plan, stagingParent: URL, limits: SillyTavernPackageLimits) throws {
        let needed = plan.files.filter { category(for: $0.path) != .credentials }.reduce(0) { $0 + $1.size } + limits.diskMarginBytes
        let values = try? stagingParent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        if let available, available < needed {
            throw SillyTavernPackageError.insufficientDiskSpace(needed: needed, available: available)
        }
    }

    private static func makeStaging(_ stagingParent: URL) throws -> (container: URL, root: URL) {
        let container = stagingParent.appendingPathComponent("st-staging-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("default-user", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (container, root)
    }

    /// 边写边算 hash；写完设只读
    private final class HashingWriter {
        private let handle: FileHandle
        private var hasher = SHA256()
        private(set) var written: Int64 = 0
        let url: URL

        init(url: URL) throws {
            self.url = url
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: url)
        }

        func write(_ data: Data) throws {
            hasher.update(data: data)
            try handle.write(contentsOf: data)
            written += Int64(data.count)
        }

        func finish() throws -> String {
            try handle.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - 文件夹

    private static func snapshotDirectory(_ source: URL, stagingParent: URL, limits: SillyTavernPackageLimits) throws -> SillyTavernSnapshot {
        let base = source.resolvingSymlinksInPath().standardized
        var raw: [RawEntry] = []
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        // 自己递归：不跟随任何链接，相对路径从名字拼，不靠 URL 前缀比较
        func walk(_ dir: URL, _ rel: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let path = rel + child.lastPathComponent
                let values = try child.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    let target = child.resolvingSymlinksInPath().standardized.path
                    let inside = target.hasPrefix(base.path + "/") ? String(target.dropFirst(base.path.count + 1)) : nil
                    raw.append(RawEntry(path: path, kind: .symlink(target: inside), size: 0, compressedSize: nil))
                } else if values.isDirectory == true {
                    try walk(child, path + "/")
                } else if values.isRegularFile == true {
                    raw.append(RawEntry(path: path, kind: .file, size: Int64(values.fileSize ?? 0), compressedSize: nil))
                    if raw.count > limits.maxFileCount * 2 { throw SillyTavernPackageError.tooManyFiles(raw.count) }
                } else {
                    raw.append(RawEntry(path: path, kind: .other, size: 0, compressedSize: nil))
                }
            }
        }
        try walk(base, "")
        let plan = try plan(raw, limits: limits)
        try checkDiskSpace(plan, stagingParent: stagingParent, limits: limits)

        let staging = try makeStaging(stagingParent)
        do {
            var entries: [SillyTavernManifestEntry] = []
            for file in plan.files {
                let kind = category(for: file.path)
                if kind == .credentials {
                    entries.append(.init(relativePath: file.path, size: file.size, sha256: nil, category: kind))
                    continue
                }
                let src = (plan.prefix + file.path).split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
                let writer = try HashingWriter(url: file.path.split(separator: "/").reduce(staging.root) { $0.appendingPathComponent(String($1)) })
                let input = try FileHandle(forReadingFrom: src)
                defer { try? input.close() }
                while true {
                    let chunk = try autoreleasepool { try input.read(upToCount: 1 << 20) ?? Data() }
                    if chunk.isEmpty { break }
                    try writer.write(chunk)
                    if writer.written > file.size { throw SillyTavernPackageError.sourceChanged(file.path) }
                }
                let hash = try writer.finish()
                guard writer.written == file.size else { throw SillyTavernPackageError.sourceChanged(file.path) }
                entries.append(.init(relativePath: file.path, size: file.size, sha256: hash, category: kind))
            }
            return SillyTavernSnapshot(sourceKind: .directory, rootPrefix: plan.prefix, root: staging.root,
                                       stagingDirectory: staging.container, entries: entries, skipped: plan.skipped)
        } catch {
            try? FileManager.default.removeItem(at: staging.container)
            throw error
        }
    }

    // MARK: - ZIP

    static func isUnsafeArchivePath(_ path: String) -> Bool {
        if path.isEmpty || path.contains("\0") || path.hasPrefix("/") || path.hasPrefix("\\") { return true }
        if path.count >= 2, path.dropFirst().first == ":" { return true }
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    /// 链接目标按「相对整个包」归一；越出包根或绝对路径 → nil
    static func resolveArchiveLink(entryPath: String, target: String) -> String? {
        guard !target.hasPrefix("/"), !target.hasPrefix("\\") else { return nil }
        var parts = entryPath.split(separator: "/").dropLast().map(String.init)
        for part in target.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) {
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    private static func snapshotZip(_ source: URL, stagingParent: URL, limits: SillyTavernPackageLimits) throws -> SillyTavernSnapshot {
        let archive: Archive
        do { archive = try Archive(url: source, accessMode: .read) } catch { throw SillyTavernPackageError.corruptArchive("打不开") }

        var raw: [RawEntry] = []
        var byPath: [String: Entry] = [:]
        for entry in archive {
            // macOS 压缩 / ditto 中文名不设 UTF-8 标志位，ZIPFoundation 会按 CP437 解成乱码：名字是合法 UTF-8 就按 UTF-8
            let utf8Path = entry.path(using: .utf8)
            let path = utf8Path.isEmpty ? entry.path : utf8Path
            if isUnsafeArchivePath(path) { throw SillyTavernPackageError.unsafePath(path) }
            // Finder 压缩附带的资源叉目录，不是包内容
            if path.hasPrefix("__MACOSX/") { continue }
            switch entry.type {
            case .directory:
                continue
            case .symlink:
                var target = Data()
                do {
                    _ = try archive.extract(entry, skipCRC32: true) { chunk in
                        target.append(chunk)
                        if target.count > 4096 { throw SillyTavernPackageError.unsafeSymlink(path) }
                    }
                } catch let error as SillyTavernPackageError {
                    throw error
                } catch {
                    throw SillyTavernPackageError.corruptArchive(path)
                }
                let resolved = resolveArchiveLink(entryPath: path, target: String(decoding: target, as: UTF8.self))
                raw.append(RawEntry(path: path, kind: .symlink(target: resolved), size: 0, compressedSize: nil))
            case .file:
                guard byPath[path] == nil else { throw SillyTavernPackageError.pathCollision(path, path) }
                byPath[path] = entry
                raw.append(RawEntry(path: path, kind: .file, size: Int64(clamping: entry.uncompressedSize),
                                    compressedSize: Int64(clamping: entry.compressedSize)))
            }
            if raw.count > limits.maxFileCount * 2 { throw SillyTavernPackageError.tooManyFiles(raw.count) }
        }
        let plan = try plan(raw, limits: limits)
        try checkDiskSpace(plan, stagingParent: stagingParent, limits: limits)

        let staging = try makeStaging(stagingParent)
        do {
            var entries: [SillyTavernManifestEntry] = []
            for file in plan.files {
                let kind = category(for: file.path)
                if kind == .credentials {
                    entries.append(.init(relativePath: file.path, size: file.size, sha256: nil, category: kind))
                    continue
                }
                guard let entry = byPath[plan.prefix + file.path] else { throw SillyTavernPackageError.corruptArchive(file.path) }
                let writer = try HashingWriter(url: file.path.split(separator: "/").reduce(staging.root) { $0.appendingPathComponent(String($1)) })
                do {
                    _ = try archive.extract(entry) { chunk in
                        try writer.write(chunk)
                        // 头里声明的大小可能是假的：实际解出超过声明立刻停
                        if writer.written > file.size { throw SillyTavernPackageError.suspiciousCompression(file.path) }
                    }
                } catch let error as SillyTavernPackageError {
                    throw error
                } catch {
                    throw SillyTavernPackageError.corruptArchive(file.path)
                }
                let hash = try writer.finish()
                guard writer.written == file.size else { throw SillyTavernPackageError.corruptArchive(file.path) }
                entries.append(.init(relativePath: file.path, size: file.size, sha256: hash, category: kind))
            }
            return SillyTavernSnapshot(sourceKind: .zip, rootPrefix: plan.prefix, root: staging.root,
                                       stagingDirectory: staging.container, entries: entries, skipped: plan.skipped)
        } catch {
            try? FileManager.default.removeItem(at: staging.container)
            throw error
        }
    }
}
