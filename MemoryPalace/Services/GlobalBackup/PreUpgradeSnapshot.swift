import Foundation
import CoreData
import SwiftData
import MachO

// MARK: - PreUpgradeSnapshot（research-backup-while-open §3.3 / §6 拍板 3、4）
//
// 新包首启、开库之前把库四件套（store / -wal / -shm / .unified_SUPPORT）APFS 克隆到 pre-upgrade/<名字>/。
// 此刻没有任何进程持有库（扩展不碰库），四件套天然一致；克隆毫秒级。
// - Debug：每个新 build 都克隆，留 2 份；Release：只在「这次会迁移」时克隆，留 1 份。都最长 14 天。
// - 「新 build」= CFBundleVersion + 本段代码所在 Mach-O 的 LC_UUID（CFBundleVersion 是写死的，A0）。
// - 空间不够 / 克隆失败：放行启动，设置 › 数据与备份 顶上提示（noticeKey），不挡开库。
// - 恢复：Debug 菜单写 .restore.json，下次启动开库前把克隆换回主位，旧主位挪进 replaced-<时间>/ 不删。

enum PreUpgradeSnapshot {

    struct BuildStamp: Codable, Equatable, CustomStringConvertible {
        var bundleVersion: String
        var binaryUUID: String

        var description: String { "\(bundleVersion)-\(binaryUUID.prefix(8))" }

        static let current = BuildStamp(
            bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            binaryUUID: imageUUID() ?? "unknown"
        )
    }

    struct LastLaunched: Codable, Equatable {
        var build: BuildStamp
        var firstLaunchedAt: String
    }

    struct CloneManifest: Codable, Equatable {
        var createdAt: String
        var createdAtEpoch: Double
        var fromBuild: BuildStamp?
        var toBuild: BuildStamp
        var schemaChanged: Bool?
        var files: [String: Int64]
        var durationMs: Int
    }

    enum Policy: Equatable {
        case everyNewBuild(keep: Int)
        case onlyWhenMigrating(keep: Int)

        var keep: Int {
            switch self {
            case .everyNewBuild(let n), .onlyWhenMigrating(let n): return n
            }
        }
    }

    enum Outcome: Equatable {
        case noStore
        case sameBuild
        case notMigrating
        case cloned(String)
        case insufficientSpace(need: Int64, free: Int64)
        case failed(String)
    }

    enum RestoreOutcome: Equatable {
        case restored(from: String, replaced: String)
        case failed(String)
    }

    struct Paths {
        var store: URL
        var external: URL
        var root: URL
        var stamp: URL

        static var live: Paths {
            Paths(store: StagingPaths.primaryStoreURL,
                  external: StagingPaths.primaryStoreExternalURL,
                  root: StagingPaths.preUpgradeRoot,
                  stamp: StagingPaths.applicationSupportRoot.appendingPathComponent(stampName))
        }

        /// 主位四件套 →（主位 URL，克隆里的名字）
        var pieces: [(url: URL, name: String)] {
            [(store, "unified.store"),
             (URL(fileURLWithPath: store.path + "-wal"), "unified.store-wal"),
             (URL(fileURLWithPath: store.path + "-shm"), "unified.store-shm"),
             (external, ".unified_SUPPORT")]
        }
    }

    static var defaultPolicy: Policy {
        #if DEBUG
        return .everyNewBuild(keep: 2)
        #else
        return .onlyWhenMigrating(keep: 1)
        #endif
    }

    static let maxAge: TimeInterval = 14 * 24 * 3600
    static let spaceFactor: Int64 = 2
    static let noticeKey = "preUpgradeSnapshot.notice"
    static let stampName = "last-launched.json"
    static let manifestName = "manifest.json"
    static let restoreFlagName = ".restore.json"
    static let replacedPrefix = "replaced-"

    // MARK: - 启动入口

    /// App.init 里、makeUnifiedContainer 之前调（BFU 闸门已在更早处 exit）
    static func runAtLaunch() {
        let paths = Paths.live
        if let restore = restoreIfRequested(paths) {
            print("[pre-upgrade] restore: \(restore)")
            if case .failed(let why) = restore { setNotice("回到装包前没做成：\(why)") }
        }
        let outcome = run(paths, current: .current, policy: defaultPolicy,
                          schemaChanged: { schemaChanged(store: paths.store) })
        print("[pre-upgrade] \(outcome)")
        switch outcome {
        case .cloned:
            UserDefaults.standard.removeObject(forKey: noticeKey)
        case .insufficientSpace(let need, let free):
            setNotice("这次更新前没做成数据库快照：可用空间 \(byteText(free))，需要 \(byteText(need))。数据照常可用；腾出空间后，下次更新会再做。")
        case .failed(let why):
            setNotice("这次更新前没做成数据库快照：\(why)。数据照常可用。")
        case .noStore, .sameBuild, .notMigrating:
            break
        }
    }

    static func run(_ p: Paths, current: BuildStamp, policy: Policy, now: Date = Date(),
                    schemaChanged: () -> Bool?,
                    freeBytes: (URL) -> Int64? = StoreSnapshotter.volumeFreeBytes) -> Outcome {
        let fm = FileManager.default
        prune(root: p.root, keep: nil, now: now)
        let last = readStamp(p.stamp)
        guard last?.build != current else { return .sameBuild }
        // 新 build 只判一次：克隆成没成都记下，下次启动库已被新包动过，再克隆就不是「装包前」了
        defer { writeStamp(LastLaunched(build: current, firstLaunchedAt: StoreSnapshotter.isoString(now)), to: p.stamp) }
        guard fm.fileExists(atPath: p.store.path) else { return .noStore }
        let changed = schemaChanged()
        if case .onlyWhenMigrating = policy, changed == false { return .notMigrating }

        let total = p.pieces.reduce(Int64(0)) { $0 + treeSize($1.url) }
        if let free = freeBytes(p.store.deletingLastPathComponent()), free < total * spaceFactor {
            return .insufficientSpace(need: total * spaceFactor, free: free)
        }
        let started = Date()
        let name = timeStamp(now) + "-" + (last?.build.description ?? "unknown")
        let tmp = p.root.appendingPathComponent(".tmp-" + name, isDirectory: true)
        let final = p.root.appendingPathComponent(name, isDirectory: true)
        do {
            try? fm.removeItem(at: tmp)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            var files: [String: Int64] = [:]
            for piece in p.pieces where fm.fileExists(atPath: piece.url.path) {
                try fm.copyItem(at: piece.url, to: tmp.appendingPathComponent(piece.name))
                files[piece.name] = treeSize(piece.url)
            }
            let manifest = CloneManifest(
                createdAt: StoreSnapshotter.isoString(now), createdAtEpoch: now.timeIntervalSince1970,
                fromBuild: last?.build, toBuild: current, schemaChanged: changed, files: files,
                durationMs: Int(Date().timeIntervalSince(started) * 1000))
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(manifest).write(to: tmp.appendingPathComponent(manifestName), options: .atomic)
            excludeFromBackup(tmp)
            try fm.moveItem(at: tmp, to: final)
        } catch {
            try? fm.removeItem(at: tmp)
            return .failed(error.localizedDescription)
        }
        prune(root: p.root, keep: policy.keep, now: now)
        return .cloned(name)
    }

    /// 这次开库会不会迁移：nil = 判不了（没 metadata / 建不出模型）
    static func schemaChanged(store: URL, types: [any PersistentModel.Type] = ProfileManager.fullModelTypes) -> Bool? {
        guard let meta = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: store),
              let model = NSManagedObjectModel.makeManagedObjectModel(for: types) else { return nil }
        return !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: meta)
    }

    // MARK: - 列表 / 保留

    /// 完整的克隆（新到旧）
    static func clones(root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && !$0.hasPrefix(replacedPrefix) && isDir(root.appendingPathComponent($0)) }
            .sorted(by: >)
    }

    static func manifest(of name: String, root: URL) -> CloneManifest? {
        let url = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent(manifestName)
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CloneManifest.self, from: $0) }
    }

    /// 清残留的 .tmp- / .restoring-、超过 14 天的克隆和 replaced-；keep 非 nil 时克隆只留最新 keep 份
    static func prune(root: URL, keep: Int?, now: Date) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            let url = root.appendingPathComponent(name)
            if name.hasPrefix(".tmp-") || name.hasPrefix(".restoring-") {
                try? fm.removeItem(at: url)
            } else if !name.hasPrefix("."), let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(mtime) > maxAge {
                try? fm.removeItem(at: url)
            }
        }
        if let keep {
            for name in clones(root: root).dropFirst(keep) {
                try? fm.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    // MARK: - 恢复（Debug 菜单「回到装包前」）

    static func requestRestore(_ name: String, root: URL = StagingPaths.preUpgradeRoot) throws {
        let data = try JSONEncoder().encode(["name": name])
        try data.write(to: root.appendingPathComponent(restoreFlagName), options: .atomic)
    }

    static func pendingRestore(root: URL = StagingPaths.preUpgradeRoot) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(restoreFlagName)))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["name"]
    }

    /// 开库前调：有 flag 就把那份克隆换回主位（先克隆到 .restoring-，旧主位挪进 replaced-<时间>/，再挪进主位）
    static func restoreIfRequested(_ p: Paths, now: Date = Date()) -> RestoreOutcome? {
        let fm = FileManager.default
        guard let name = pendingRestore(root: p.root) else { return nil }
        try? fm.removeItem(at: p.root.appendingPathComponent(restoreFlagName))
        let src = p.root.appendingPathComponent(name, isDirectory: true)
        guard !name.contains("/"), clones(root: p.root).contains(name),
              fm.fileExists(atPath: src.appendingPathComponent("unified.store").path) else {
            return .failed("没有这份克隆：\(name)")
        }
        let stage = p.root.appendingPathComponent(".restoring-" + timeStamp(now), isDirectory: true)
        let replacedName = replacedPrefix + timeStamp(now)
        let replaced = p.root.appendingPathComponent(replacedName, isDirectory: true)
        var moved: [(from: URL, to: URL)] = []
        var placed: [URL] = []
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            for piece in p.pieces where fm.fileExists(atPath: src.appendingPathComponent(piece.name).path) {
                try fm.copyItem(at: src.appendingPathComponent(piece.name), to: stage.appendingPathComponent(piece.name))
            }
            try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
            for piece in p.pieces where fm.fileExists(atPath: piece.url.path) {
                let to = replaced.appendingPathComponent(piece.name)
                try fm.moveItem(at: piece.url, to: to)
                moved.append((piece.url, to))
            }
            for piece in p.pieces where fm.fileExists(atPath: stage.appendingPathComponent(piece.name).path) {
                try fm.moveItem(at: stage.appendingPathComponent(piece.name), to: piece.url)
                placed.append(piece.url)
            }
        } catch {
            // 回滚：主位上放了一半的克隆拿掉，旧主位挪回
            for url in placed { try? fm.removeItem(at: url) }
            for m in moved { try? fm.moveItem(at: m.to, to: m.from) }
            try? fm.removeItem(at: stage)
            if moved.isEmpty { try? fm.removeItem(at: replaced) }
            return .failed(error.localizedDescription)
        }
        try? fm.removeItem(at: stage)
        excludeFromBackup(replaced)
        return .restored(from: name, replaced: replacedName)
    }

    // MARK: - Helpers

    static func setNotice(_ text: String) {
        UserDefaults.standard.set(text, forKey: noticeKey)
    }

    static func readStamp(_ url: URL) -> LastLaunched? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(LastLaunched.self, from: $0) }
    }

    private static func writeStamp(_ stamp: LastLaunched, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(stamp) { try? data.write(to: url, options: .atomic) }
    }

    /// 克隆目录名前缀：UTC 秒级，字典序 = 时间序
    private static func timeStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    private static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    static func treeSize(_ url: URL) -> Int64 {
        guard isDir(url) else { return StoreSnapshotter.fileSize(url) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let item = walker?.nextObject() as? URL {
            let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    private static func byteText(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// 本段代码所在镜像（Debug = 记忆花园.debug.dylib，Release = 主二进制）的 LC_UUID：链接产物一变就变
    private static func imageUUID() -> String? {
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == UInt32(LC_UUID) {
                return UUID(uuid: cursor.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }
}
