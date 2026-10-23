import Foundation
import CryptoKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 用户可见的本机文件库。每楼层一库：
/// Documents/记忆宫殿/floors/{floorSlug}/filesystem/
/// 纯文件 IO，不依赖 SwiftData。路径一律相对（允许子目录），禁止逃出库根。
enum FileLibraryStore {
    struct FileMeta { let path: String; let bytes: Int; let modifiedAt: Date }

    private struct FloorManifest: Codable {
        var schemaVersion: Int
        var profileId: String
        var displayName: String
        var filesystemPath: String
        var createdAt: Date
    }

    private static let appFolderName = "记忆宫殿"
    private static let floorsFolderName = "floors"
    private static let filesystemFolderName = "filesystem"
    private static let metadataFolderName = ".memorypalace"
    private static let manifestFileName = "manifest.json"
    private static let slugMapKey = "fileLibraryLocalDocumentsSlugMapV1"
    private static let migrationKeyPrefix = "fileLibraryLocalDocumentsMigrationV1Done."

    // MARK: - Roots

    /// iCloud 同步开关（设置-文件库；默认关=本地库）。只影响 filesystem/，记忆树永远本地。
    static let iCloudEnabledKey = "fileLibraryICloudEnabled"
    static let iCloudContainerId = "iCloud.com.susu.MemoryPalace"

    static var iCloudEnabled: Bool {
        // XCTest 宿主 = 真 app + 真 UserDefaults：不钉死本地，测试楼层会生进真 iCloud 容器（实测污染过）
        if NSClassFromString("XCTestCase") != nil { return false }
        return UserDefaults.standard.bool(forKey: iCloudEnabledKey)
    }

    private static var cachedUbiquityDocuments: URL?

    /// iCloud 容器的 Documents。nil = 未登录 iCloud / 容器未就绪。
    /// macOS 走 Mobile Documents 裸路径（app 无沙箱，不挂 iCloud entitlement，零签名风险）；
    /// iOS 走 ubiquity API（容器由 entitlement 声明）。
    static func iCloudDocumentsRoot() -> URL? {
        #if os(macOS)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~susu~MemoryPalace/Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
        #else
        return cachedUbiquityDocuments
        #endif
    }

    /// iOS：url(forUbiquityContainerIdentifier:) 不能在主线程首调（会卡），app 启动/开关打开时预热。
    static func primeICloudContainer(completion: ((Bool) -> Void)? = nil) {
        #if os(iOS)
        DispatchQueue.global(qos: .userInitiated).async {
            let url = FileManager.default.url(forUbiquityContainerIdentifier: iCloudContainerId)?
                .appendingPathComponent("Documents", isDirectory: true)
            if let url {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            DispatchQueue.main.async {
                cachedUbiquityDocuments = url
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if AirPerfProbe.enabled, let url { AirProbeRuntime.shared.noteCloudRoot(url) }
                #endif
                completion?(url != nil)
            }
        }
        #else
        completion?(iCloudDocumentsRoot() != nil)
        #endif
    }

    /// 本地 floors 根（记忆树/迁移源永远用它）
    static func localDocumentsBaseRoot() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(floorsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// iCloud floors 根（开关开 + 容器可用时的活动根）
    static func iCloudFloorsRoot() -> URL? {
        guard let docs = iCloudDocumentsRoot() else { return nil }
        let dir = docs.appendingPathComponent(floorsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 活动 floors 根：filesystem/ 链路全走这里。开关开但容器不可用 → 回退本地（不静默丢数据）。
    static func documentsBaseRoot() -> URL {
        if iCloudEnabled, let cloud = iCloudFloorsRoot() {
            return cloud
        }
        return localDocumentsBaseRoot()
    }

    static func legacyRoot(profileId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("fileLibrary", isDirectory: true)
            .appendingPathComponent(profileId, isDirectory: true)
    }

    /// 测试用：文件库根换到临时目录（#050，导入测试验附件落盘，不碰真文件库）。nil = 正常路径
    nonisolated(unsafe) static var testRootOverride: URL?

    static func libraryRoot(profileId: String) -> URL {
        MainThreadIO.note(.mkdir, "FileLibraryStore.libraryRoot")
        let root = testRootOverride?.appendingPathComponent(profileId, isDirectory: true) ?? filesystemRoot(profileId: profileId)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func displayLocation(profileId: String) -> String {
        "文件 / \(appFolderName) / \(floorsFolderName) / \(floorSlug(profileId: profileId)) / \(filesystemFolderName)"
    }

    static func floorSlug(profileId: String) -> String {
        if let mapped = slugMap()[profileId], !mapped.isEmpty {
            return mapped
        }
        if let existing = findExistingFloorDirectory(profileId: profileId)?.lastPathComponent {
            setSlug(existing, for: profileId)
            return existing
        }
        // 兜底名要去重：shortId 是「前 8 个字母数字」，两个不同 profileId 完全可能撞
        // （T3a 探针的 probe-floor-a / probe-floor-b 就撞成同一个 probeflo，
        //   两个楼层落到同一个宿主目录）。真实 id 是 UUID 碰撞概率可忽略，
        //   但代码层这条路必须堵。**不做存量迁移**——slugMap 里已有的映射保持不动。
        let fallback = uniqueSlug(base: "楼层-\(shortId(profileId))", profileId: profileId)
        setSlug(fallback, for: profileId)
        return fallback
    }

    static func prepareProfiles(_ profiles: [Profile]) {
        for profile in profiles {
            prepareProfile(profile)
        }
    }

    static func prepareProfile(_ profile: Profile) {
        let floorURL = renameFloorDirectoryIfNeeded(profile: profile, current: floorDirectory(for: profile))
        try? FileManager.default.createDirectory(at: floorURL, withIntermediateDirectories: true)
        let filesystemURL = floorURL.appendingPathComponent(filesystemFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: filesystemURL, withIntermediateDirectories: true)
        writeManifest(profile: profile, floorURL: floorURL)
        migrateLegacyFilesIfNeeded(profile: profile, destinationRoot: filesystemURL)
    }

    /// 楼层改名/换 emoji → 文件夹名跟随（Finder 里好认；shortId 是稳定锚，rename 不丢内容）。
    /// updateProfile 和启动 prepareProfiles 都走这里：改名瞬间跟随，存量旧名启动时一次性修正。
    /// 目标名被占或 rename 失败 → 保持旧名继续用，不挡功能。
    private static func renameFloorDirectoryIfNeeded(profile: Profile, current: URL) -> URL {
        let desired = slug(for: profile)
        guard current.lastPathComponent != desired else { return current }
        let target = documentsBaseRoot().appendingPathComponent(desired, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { return current }
        if FileManager.default.fileExists(atPath: current.path) {
            do { try FileManager.default.moveItem(at: current, to: target) }
            catch { return current }
        }
        setSlug(desired, for: profile.id)
        return target
    }

    // MARK: - Basic Ops

    /// 把相对路径解析成库内绝对 URL，拒绝绝对路径、空路径与 ../ 越狱。返回 nil = 非法。
    static func resolve(_ relPath: String, profileId: String) -> URL? {
        MainThreadIO.assertOffMain(.stat, "FileLibraryStore.resolve")
        let trimmed = relPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !cleaned.isEmpty else { return nil }

        // R10：文件名按 **UTF-8 字节** clamp 到 255（APFS 单段上限也是字节数）。
        // 只 clamp 末段——中间目录段由各自的创建路径负责。
        let components = cleaned.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = components.last else { return nil }
        let clamped = (components.dropLast() + [clampComponent(last)]).joined(separator: "/")

        // R5：**先解 symlink 再判 containment**。只 standardize 的话，库根下一个
        // 指向根外的 symlink 能把路径带出去（T3b E5 在沙箱侧实证过同一个洞）。
        // 两边都解：macOS 上 /var → /private/var 这类系统 symlink 会让单边解析对不上。
        let root = libraryRoot(profileId: profileId).standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(clamped).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { return nil }
        return target
    }

    /// R10：把单个路径段 clamp 到 255 UTF-8 字节。
    /// - 在 **grapheme 边界**截断（不切碎 emoji / 组合字），
    /// - 尽量保留扩展名（`.md` 这类），扩展名本身超长就整体按字节截。
    static func clampComponent(_ name: String) -> String {
        let limit = 255
        guard name.utf8.count > limit else { return name }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        // 扩展名 + 点也算进预算；扩展名离谱长就放弃保扩展名
        let suffix = ext.isEmpty ? "" : "." + ext
        let budget = suffix.utf8.count < limit ? limit - suffix.utf8.count : limit

        var out = ""
        var used = 0
        for ch in (suffix.utf8.count < limit ? base : name) {   // 按 Character = grapheme 走
            let n = String(ch).utf8.count
            if used + n > budget { break }
            out.append(ch)
            used += n
        }
        let result = suffix.utf8.count < limit ? out + suffix : out
        return result.isEmpty ? String(name.prefix(1)) : result
    }

    /// R5/E5：末段是 symlink 就拒绝写。写入口都过它——不让「把 symlink 当普通文件覆盖」
    /// 变成一条写穿库根的通道，也不让 MP 自己在库里造 symlink。
    private static func validateNotSymlink(_ url: URL) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw err("目标是符号链接，拒绝写入：\(url.lastPathComponent)（请在 Files.app 里处理掉它）")
        }
    }

    /// R7：所有**写**操作过同一条进程级串行队列。读不排队（读多写少，且读本身是原子的）。
    /// guest 的 change consumer 触发的刷新是读，不会和宿主写交叉。
    /// ⚠️ 队列内不许再调用同样排队的函数（`sync` 嵌套会死锁）——所以 `edit` 走 `writeLocked`。
    private static let writeQueue = DispatchQueue(label: "com.susu.MemoryPalace.fileLibrary.write")

    /// `skippingTopLevelDirs`：不进这些顶层目录（如 `books`，章节文件是清单大头；input-jank C1：
    /// 发送路径在主线程枚举整库 546ms/次，跳过后只扫真正会进清单的文件）。
    ///
    /// 修全局卡顿（10-03，Warden 派修）：这里是**真枚举**，会碰盘，别在主线程调。
    /// 主线程一律走 `cachedList`（只读缓存，旧了后台刷新）或 `freshList`（后台算完再回来）。
    /// 相对路径按字符串裁掉根前缀，不再逐文件 `standardizedFileURL`（实测 `producesRelativePathURLs` 反而慢 8 倍，不用）。
    static func list(profileId: String, skippingTopLevelDirs: Set<String> = []) -> [FileMeta] {
        MainThreadIO.assertOffMain(.enumerate, "FileLibraryStore.list")
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("FileLibraryStore.list") : nil
        var airRoot: URL?
        var airReturnedCount = 0
        defer { if let airSpan { AirProbeRuntime.shared.finishedFileCall(airSpan, root: airRoot, count: airReturnedCount) } }
        #endif
        let root = libraryRoot(profileId: profileId)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if airSpan != nil { airRoot = root }
        #endif
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        ) else { return [] }

        let rootPrefix = RootPrefix(rootPath: root.path)
        var out: [FileMeta] = []
        for case let url as URL in en {
            if !skippingTopLevelDirs.isEmpty, url.hasDirectoryPath,
               skippingTopLevelDirs.contains(relativeToRoot(url, root: rootPrefix)) {
                en.skipDescendants()
                continue
            }
            guard isSupportedFile(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            out.append(.init(path: relativeToRoot(url, root: rootPrefix), bytes: values?.fileSize ?? 0,
                             modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if airSpan != nil { airReturnedCount = out.count }
        #endif
        let sorted = out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if skippingTopLevelDirs.isEmpty { ListCache.store(sorted, profileId: profileId) }
        return sorted
    }

    /// 根路径的两种写法，枚举前算一次：原样 + `/private` 别名（iOS 枚举器给 `/private/var/…`，根是 `/var/…`；反过来也认）。
    /// 别名只给系统固定的符号链接根（`/var` `/tmp` `/etc` ↔ `/private/…`），别的根（mac 沙盒等）不生成。
    /// 纯字符串，不碰盘——别用 `standardizedFileURL` 做前缀判断（它查盘、存在才剥 `/private`）。
    /// 和老算法逐字一致的前提：路径真实存在（枚举器给的都是）。
    struct RootPrefix {
        let rootPath: String
        private let primary: String
        private let alias: String?

        private static let systemLinks = [("/var/", "/private/var/"), ("/tmp/", "/private/tmp/"), ("/etc/", "/private/etc/")]

        init(rootPath: String) {
            self.rootPath = rootPath
            let primary = rootPath + "/"
            self.primary = primary
            alias = Self.systemLinks.lazy.compactMap { short, long -> String? in
                if primary.hasPrefix(long) { return short + primary.dropFirst(long.count) }
                if primary.hasPrefix(short) { return long + primary.dropFirst(short.count) }
                return nil
            }.first
        }

        /// 原样前缀命中：同老算法的快路，直接裁。别名命中：尾部要规整（`.` `..` `//` 尾斜杠）就不裁，交给老算法回退
        func relative(_ path: String) -> String? {
            if path.hasPrefix(primary) { return String(path.dropFirst(primary.count)) }
            guard let alias, path.hasPrefix(alias) else { return nil }
            let tail = path.dropFirst(alias.count)
            let slashed = "/" + tail
            if slashed.contains("/./") || slashed.contains("/../") || slashed.contains("//")
                || slashed.hasSuffix("/.") || slashed.hasSuffix("/..") || slashed.hasSuffix("/") { return nil }
            return String(tail)
        }
    }

    /// 快路裁不了（别的符号链接 / 尾部要规整）才退回规整路径的老办法
    static func relativeToRoot(_ url: URL, root: RootPrefix) -> String {
        if let rel = root.relative(url.path) { return rel }
        let std = URL(fileURLWithPath: root.rootPath).standardizedFileURL.path
        return String(url.standardizedFileURL.path.dropFirst(std.count + 1))
    }

    // MARK: - 清单缓存（修全局卡顿：主线程不再枚举整库）

    /// 楼层 → 上次枚举的全库清单。本仓写入口（write / append / edit / writeData / delete / rename）就地改缓存，保证「刚写完就列」准确；
    /// 绕开本仓直接写盘的（书房、附件、日记、shell…）靠：过期（`ttl`）、`.fileLibraryDidChange`、回前台 → 标脏，下次读时后台重扫。
    enum ListCache {
        static let ttl: TimeInterval = 20
        private static let lock = NSLock()
        private static var entries: [String: (files: [FileMeta], at: Date, dirty: Bool)] = [:]
        private static var refreshing: Set<String> = []
        private static var observing = false

        static func store(_ files: [FileMeta], profileId: String) {
            lock.lock(); defer { lock.unlock() }
            entries[profileId] = (files, Date(), false)
        }

        static func snapshot(profileId: String) -> (files: [FileMeta], stale: Bool)? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[profileId] else { return nil }
            return (e.files, e.dirty || Date().timeIntervalSince(e.at) > ttl)
        }

        /// 整个文件夹被直接删掉（删对话的附件夹、删一本书）：把这个前缀下的都从缓存拿掉
        static func removeFolder(_ folder: String, profileId: String) {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            lock.lock(); defer { lock.unlock() }
            entries[profileId]?.files.removeAll { $0.path.hasPrefix(prefix) }
        }

        /// 整层忘掉（楼层目录被整个删 / 测试夹具重建）：下次读时同步重扫，不再给旧清单
        static func forget(profileId: String) {
            lock.lock(); defer { lock.unlock() }
            entries[profileId] = nil
        }

        /// 某楼层（nil = 全部）标脏：下次读时后台重扫，先照旧给旧清单
        static func invalidate(profileId: String?) {
            lock.lock(); defer { lock.unlock() }
            if let profileId {
                entries[profileId]?.dirty = true
            } else {
                for k in entries.keys { entries[k]?.dirty = true }
            }
        }

        /// 本仓写入后就地改：path == nil 的项删除，否则插入 / 覆盖
        static func apply(profileId: String, remove: [String] = [], upsert: FileMeta? = nil) {
            lock.lock(); defer { lock.unlock() }
            guard var e = entries[profileId] else { return }
            let gone = Set(remove + (upsert.map { [$0.path] } ?? []))
            e.files.removeAll { gone.contains($0.path) }
            if let upsert {
                let i = e.files.firstIndex { $0.path.localizedStandardCompare(upsert.path) == .orderedDescending } ?? e.files.count
                e.files.insert(upsert, at: i)
            }
            entries[profileId] = e
        }

        static func beginRefresh(profileId: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return refreshing.insert(profileId).inserted
        }

        static func endRefresh(profileId: String) {
            lock.lock(); defer { lock.unlock() }
            refreshing.remove(profileId)
        }

        /// 外部变更信号：文件库变了的广播、回前台。只注册一次
        static func observeOnce() {
            lock.lock()
            let already = observing
            observing = true
            lock.unlock()
            guard !already else { return }
            let nc = NotificationCenter.default
            nc.addObserver(forName: .fileLibraryDidChange, object: nil, queue: nil) { _ in ListCache.invalidate(profileId: nil) }
            #if os(iOS)
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in ListCache.invalidate(profileId: nil) }
            #elseif os(macOS)
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in ListCache.invalidate(profileId: nil) }
            #endif
        }
    }

    /// 主线程用：有缓存立刻给（旧了 / 脏了顺手后台重扫）；这个楼层从没扫过才同步扫一次（启动时已 `warmList` 预热）。
    /// `skippingTopLevelDirs` 在缓存的全库清单上过滤，不再单独枚举。
    static func cachedList(profileId: String, skippingTopLevelDirs: Set<String> = []) -> [FileMeta] {
        ListCache.observeOnce()
        let files: [FileMeta]
        if let snap = ListCache.snapshot(profileId: profileId) {
            if snap.stale { warmList(profileId: profileId) }
            files = snap.files
        } else {
            files = MainThreadIO.tolerated("#033 cachedList 冷缓存同步枚举") { list(profileId: profileId) }
        }
        guard !skippingTopLevelDirs.isEmpty else { return files }
        return files.filter { meta in
            let top = meta.path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? meta.path
            return !skippingTopLevelDirs.contains(top)
        }
    }

    /// 后台重扫一次（同楼层同时只跑一个），结果进缓存。fire-and-forget
    static func warmList(profileId: String) {
        guard !profileId.isEmpty else { return }
        ListCache.observeOnce()
        guard ListCache.beginRefresh(profileId: profileId) else { return }
        Task.detached(priority: .utility) {
            _ = FileLibraryStore.list(profileId: profileId)
            FileLibraryStore.ListCache.endRefresh(profileId: profileId)
        }
    }

    /// 要最新的、又不想卡主线程：后台扫完再回来（面板刷新、AI 的 fs_list / fs_search 用）
    static func freshList(profileId: String) async -> [FileMeta] {
        ListCache.observeOnce()
        return await Task.detached(priority: .userInitiated) { FileLibraryStore.list(profileId: profileId) }.value
    }

    /// 本仓写入后：按实际落盘状态就地更新缓存（一个文件一次 stat）
    private static func noteWritten(_ url: URL, profileId: String) {
        guard isSupportedFile(url), let rel = relativePath(url, profileId: profileId) else { return }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        ListCache.apply(profileId: profileId, upsert: FileMeta(path: rel, bytes: values?.fileSize ?? 0,
                                                              modifiedAt: values?.contentModificationDate ?? Date()))
    }

    private static func noteRemoved(_ url: URL, profileId: String) {
        guard let rel = relativePath(url, profileId: profileId) else { return }
        ListCache.apply(profileId: profileId, remove: [rel])
    }

    /// 绕开写入口直接删了一个文件夹的地方调这个，缓存跟着拿掉
    static func noteFolderRemoved(_ url: URL, profileId: String) {
        guard let rel = relativePath(url, profileId: profileId) else { return }
        ListCache.removeFolder(rel, profileId: profileId)
    }

    /// resolve 出来的 URL 都以 libraryRoot 为前缀（同一个 root 拼出来的），直接裁前缀，不做 standardizedFileURL
    private static func relativePath(_ url: URL, profileId: String) -> String? {
        let rootPath = libraryRoot(profileId: profileId).path
        let path = url.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    static func read(_ relPath: String, profileId: String) throws -> String {
        MainThreadIO.assertOffMain(.read, "FileLibraryStore.read")
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try validateTextFile(url)
        try validateRegularFile(url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func exists(_ relPath: String, profileId: String) -> Bool {
        MainThreadIO.assertOffMain(.stat, "FileLibraryStore.exists")
        guard let url = resolve(relPath, profileId: profileId), isSupportedFile(url) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func readPreview(_ relPath: String, maxBytes: Int, profileId: String) throws -> String {
        MainThreadIO.assertOffMain(.read, "FileLibraryStore.readPreview")
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try validateTextFile(url)
        try validateRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ relPath: String, content: String, profileId: String) throws {
        MainThreadIO.assertOffMain(.write, "FileLibraryStore.write")
        try writeQueue.sync { try writeLocked(relPath, content: content, profileId: profileId) }
    }

    /// 已在 `writeQueue` 上时用这个（`edit` 的读-改-写要整体在队列里）
    private static func writeLocked(_ relPath: String, content: String, profileId: String) throws {
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try validateTextFile(url)
        try validateNotSymlink(url)
        if isDirectory(url) {
            throw err("路径是文件夹，不能写入：\(relPath)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try utf8Data(content).write(to: url, options: .atomic)
        noteWritten(url, profileId: profileId)
    }

    static func append(_ relPath: String, content: String, profileId: String) throws {
        MainThreadIO.assertOffMain(.write, "FileLibraryStore.append")
        try writeQueue.sync { try appendLocked(relPath, content: content, profileId: profileId) }
    }

    private static func appendLocked(_ relPath: String, content: String, profileId: String) throws {
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try validateTextFile(url)
        try validateNotSymlink(url)
        if isDirectory(url) {
            throw err("路径是文件夹，不能写入：\(relPath)")
        }
        let data = try utf8Data(content)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { noteWritten(url, profileId: profileId) }
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// R11：文件内容的 SHA256（CryptoKit，系统框架，不引新依赖）。
    /// 面板/编辑器的冲突检测用它取代 mtime——mtime 会在「同秒内两次写」时骗人，
    /// 也会在「碰了但没改内容」时误报冲突。文件不存在返回 nil。
    static func contentHash(_ relPath: String, profileId: String) -> String? {
        MainThreadIO.assertOffMain(.read, "FileLibraryStore.contentHash")
        guard let url = resolve(relPath, profileId: profileId),
              let data = try? Data(contentsOf: url) else { return nil }
        return sha256Hex(data)
    }

    /// R11：冲突判定。**按内容哈希，不看 mtime。**
    /// - 同 mtime 不同内容 → 判冲突（mtime 秒级精度，同秒两次写会骗人）
    /// - 不同 mtime 同内容 → 不判（碰过但没改，误报会逼用户白丢一次编辑）
    /// `baselineContent` = 编辑器打开/上次保存时它认得的内容。文件不存在 = 没冲突（当新建）。
    static func hasExternalConflict(_ relPath: String, profileId: String, baselineContent: String) -> Bool {
        MainThreadIO.assertOffMain(.read, "FileLibraryStore.hasExternalConflict")
        guard let current = contentHash(relPath, profileId: profileId) else { return false }
        return current != sha256Hex(Data(baselineContent.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func modifiedAt(_ relPath: String, profileId: String) -> Date? {
        MainThreadIO.assertOffMain(.stat, "FileLibraryStore.modifiedAt")
        guard let url = resolve(relPath, profileId: profileId) else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// old→new 局部替换；old 必须唯一命中，否则报错（仿 CC Edit 语义）。
    static func edit(_ relPath: String, oldString: String, newString: String, profileId: String) throws {
        MainThreadIO.assertOffMain(.write, "FileLibraryStore.edit")
        let body = try read(relPath, profileId: profileId)
        let occurrences = body.components(separatedBy: oldString).count - 1
        guard occurrences == 1 else { throw err(occurrences == 0 ? "未找到要替换的文本" : "要替换的文本命中 \(occurrences) 处，需更具体") }
        try writeQueue.sync {
            try writeLocked(relPath, content: body.replacingOccurrences(of: oldString, with: newString), profileId: profileId)
        }
    }

    static func delete(_ relPath: String, profileId: String) throws {
        MainThreadIO.assertOffMain(.write, "FileLibraryStore.delete")
        try writeQueue.sync {
            guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
            try validateSupported(url)
            try validateRegularFile(url)
            try FileManager.default.removeItem(at: url)
            noteRemoved(url, profileId: profileId)
        }
    }

    static func rename(_ oldPath: String, to newPath: String, profileId: String) throws {
        MainThreadIO.assertOffMain(.write, "FileLibraryStore.rename")
        try writeQueue.sync { try renameLocked(oldPath, to: newPath, profileId: profileId) }
    }

    private static func renameLocked(_ oldPath: String, to newPath: String, profileId: String) throws {
        guard let sourceURL = resolve(oldPath, profileId: profileId) else { throw err("非法路径: \(oldPath)") }
        guard let targetURL = resolve(newPath, profileId: profileId) else { throw err("非法路径: \(newPath)") }
        try validateSupported(sourceURL)
        try validateSupported(targetURL)
        try validateRegularFile(sourceURL)
        try validateNotSymlink(sourceURL)
        try validateNotSymlink(targetURL)
        if sourceURL == targetURL { return }
        guard !FileManager.default.fileExists(atPath: targetURL.path) else { throw err("文件已存在：\(newPath)") }
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
        noteRemoved(sourceURL, profileId: profileId)
        noteWritten(targetURL, profileId: profileId)
    }

    /// 不存在才建，绝不覆盖（#043 导出包写文件库）。判断和写在同一个写队列里。返回 false = 已存在。
    static func createIfAbsent(_ relPath: String, content: String, profileId: String) throws -> Bool {
        MainThreadIO.assertOffMain(.write, "FileLibraryStore.createIfAbsent")
        return try writeQueue.sync {
            guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
            try validateTextFile(url)
            try validateNotSymlink(url)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard try createFileExclusively(at: url, data: utf8Data(content)) else { return false }
            noteWritten(url, profileId: profileId)
            return true
        }
    }

    /// 独占创建：文件已在（含只差大小写的同名，mac 盘默认不分大小写）就返回 false，不碰它
    static func createFileExclusively(at url: URL, data: Data) throws -> Bool {
        do {
            try data.write(to: url, options: .withoutOverwriting)
            return true
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return false
        }
    }

    // MARK: - 二进制（附件一份存储）

    static func writeData(_ relPath: String, data: Data, profileId: String) throws {
        MainThreadIO.assertOffMain(.write, "FileLibraryStore.writeData")
        try writeQueue.sync { try writeDataLocked(relPath, data: data, profileId: profileId) }
    }

    private static func writeDataLocked(_ relPath: String, data: Data, profileId: String) throws {
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try validateSupported(url)
        try validateNotSymlink(url)
        if isDirectory(url) {
            throw err("路径是文件夹，不能写入：\(relPath)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        noteWritten(url, profileId: profileId)
    }

    static func readData(_ relPath: String, profileId: String) throws -> Data {
        MainThreadIO.assertOffMain(.read, "FileLibraryStore.readData")
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try validateSupported(url)
        try validateRegularFile(url)
        return try Data(contentsOf: url)
    }

    // MARK: - 记忆树（floors/{slug}/memory/，系统生成的文档态记忆，fs_* 工具只读可达）

    private static let memoryFolderName = "memory"
    /// fs_* 工具里记忆树的虚拟路径前缀（只读区）
    static let memoryVirtualPrefix = "memory/"

    /// 楼层记忆树根：floors/{slug}/memory/（对话摘要等，与 filesystem/ 平级）。
    /// ⚠️ 永远本地（方针#4：隐私敏感，不随 iCloud 开关迁移）。
    static func memoryRoot(profileId: String) -> URL {
        MainThreadIO.note(.mkdir, "FileLibraryStore.memoryRoot")
        let dir = localDocumentsBaseRoot()
            .appendingPathComponent(floorSlug(profileId: profileId), isDirectory: true)
            .appendingPathComponent(memoryFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// memory/ 虚拟路径 → 记忆树内绝对 URL。防护同 resolve：拒绝空路径与 ../ 越狱。
    static func resolveMemory(_ virtualPath: String, profileId: String) -> URL? {
        let trimmed = virtualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(memoryVirtualPrefix) else { return nil }
        let rel = String(trimmed.dropFirst(memoryVirtualPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !rel.isEmpty else { return nil }
        let root = memoryRoot(profileId: profileId).standardizedFileURL
        let target = root.appendingPathComponent(rel).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        return target
    }

    /// 记忆树文件清单（路径带 memory/ 前缀，与 fs_* 工具视角一致）
    static func memoryList(profileId: String) -> [FileMeta] {
        MainThreadIO.assertOffMain(.enumerate, "FileLibraryStore.memoryList")
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("FileLibraryStore.memoryList") : nil
        var airRoot: URL?
        var airReturnedCount = 0
        defer { if let airSpan { AirProbeRuntime.shared.finishedFileCall(airSpan, root: airRoot, count: airReturnedCount) } }
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let probeKey = AirPerfProbe.enabled ? (Thread.isMainThread ? "memoryListMain" : "memoryListBackground") : ""
        let probeStart = AirPerfProbe.enabled ? AirPerfProbe.beginTimed(probeKey) : nil
        defer { if let probeStart { AirPerfProbe.endTimed(probeKey, since: probeStart) } }
        #endif
        let root = memoryRoot(profileId: profileId)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if airSpan != nil { airRoot = root }
        #endif
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }
        let rootPrefix = RootPrefix(rootPath: root.path)
        var out: [FileMeta] = []
        for case let url as URL in en where isSupportedFile(url) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            out.append(.init(path: memoryVirtualPrefix + relativeToRoot(url, root: rootPrefix), bytes: values?.fileSize ?? 0,
                             modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if airSpan != nil { airReturnedCount = out.count }
        #endif
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func memoryRead(_ virtualPath: String, profileId: String) throws -> String {
        MainThreadIO.assertOffMain(.read, "FileLibraryStore.memoryRead")
        guard let url = resolveMemory(virtualPath, profileId: profileId) else { throw err("非法路径: \(virtualPath)") }
        try validateTextFile(url)
        try validateRegularFile(url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func memorySearch(_ keyword: String, profileId: String) -> [(path: String, line: String)] {
        MainThreadIO.assertOffMain(.enumerate, "FileLibraryStore.memorySearch")
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("FileLibraryStore.memorySearch") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        guard !keyword.isEmpty else { return [] }
        var hits: [(path: String, line: String)] = []
        for meta in memoryList(profileId: profileId) {
            guard let body = try? memoryRead(meta.path, profileId: profileId) else { continue }
            for line in body.split(separator: "\n", omittingEmptySubsequences: false)
                where line.range(of: keyword, options: .caseInsensitive) != nil {
                hits.append((meta.path, String(line)))
            }
        }
        return hits
    }

    // MARK: - 工具结果存档（floors/{slug}/tool-results/<conversationId>/，B4 工具结果外置，fs_* 只读可达）

    private static let toolResultsFolderName = "tool-results"
    /// fs_* 工具里工具结果存档的虚拟路径前缀（只读区）
    static let toolResultsVirtualPrefix = "tool-results/"
    /// 每个对话最多保留的存档数，超了删最旧（plan-B4 D8）
    static let toolResultsPerConversationCap = 50

    /// 存档根：floors/{slug}/tool-results/（与 memory/ 平级，**永远本地**，不随 iCloud 开关迁移，不进 list()/fs_list）
    static func toolResultsRoot(profileId: String) -> URL {
        MainThreadIO.note(.mkdir, "FileLibraryStore.toolResultsRoot")
        let dir = localDocumentsBaseRoot()
            .appendingPathComponent(floorSlug(profileId: profileId), isDirectory: true)
            .appendingPathComponent(toolResultsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// tool-results/ 虚拟路径 → 存档内绝对 URL。防护同 resolveMemory。
    static func resolveToolResult(_ virtualPath: String, profileId: String) -> URL? {
        let trimmed = virtualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(toolResultsVirtualPrefix) else { return nil }
        let rel = String(trimmed.dropFirst(toolResultsVirtualPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !rel.isEmpty else { return nil }
        let root = toolResultsRoot(profileId: profileId).standardizedFileURL
        let target = root.appendingPathComponent(rel).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        return target
    }

    /// 读存档；`maxBytes` 给显示侧封顶用（nil = 全文）
    static func toolResultRead(_ virtualPath: String, profileId: String, maxBytes: Int? = nil) throws -> String {
        MainThreadIO.assertOffMain(.read, "FileLibraryStore.toolResultRead")
        guard let url = resolveToolResult(virtualPath, profileId: profileId) else { throw err("非法路径: \(virtualPath)") }
        try validateTextFile(url)
        try validateRegularFile(url)
        guard let maxBytes else { return try String(contentsOf: url, encoding: .utf8) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return String(decoding: try handle.read(upToCount: maxBytes) ?? Data(), as: UTF8.self)
    }

    /// 全文落盘，返回虚拟路径 `tool-results/<conversationId>/<toolUseId>-<toolName>.txt`。
    /// 文件名唯一（toolUseId 每次调用不同），不扫目录取序号。
    static func toolResultWrite(conversationId: String, toolUseId: String, toolName: String, content: String, profileId: String) throws -> String {
        MainThreadIO.assertOffMain(.write, "FileLibraryStore.toolResultWrite")
        let conv = toolResultComponent(conversationId)
        let file = toolResultComponent(toolUseId) + "-" + toolResultComponent(toolName) + ".txt"
        let dir = toolResultsRoot(profileId: profileId).appendingPathComponent(conv, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try utf8Data(content).write(to: dir.appendingPathComponent(file), options: .atomic)
        pruneToolResults(in: dir)
        return toolResultsVirtualPrefix + conv + "/" + file
    }

    /// 存档的虚拟路径（纯算，不碰盘）：和 toolResultWrite 写到的同一个
    static func toolResultVirtualPath(conversationId: String, toolUseId: String, toolName: String) -> String {
        toolResultsVirtualPrefix + toolResultComponent(conversationId) + "/"
            + toolResultComponent(toolUseId) + "-" + toolResultComponent(toolName) + ".txt"
    }

    /// 只留 [A-Za-z0-9_-]，其余变 `_`，最长 80——路径进模型尾注和正则，字符集必须受控
    private static func toolResultComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" }
        let out = String(mapped.prefix(80))
        return out.isEmpty ? "x" : out
    }

    /// 超过 cap 删最旧（修改时间，同时间按文件名）
    private static func pruneToolResults(in dir: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              urls.count > toolResultsPerConversationCap else { return }
        let sorted = urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da == db ? a.lastPathComponent < b.lastPathComponent : da < db
        }
        for url in sorted.prefix(urls.count - toolResultsPerConversationCap) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 显示侧统一读（普通 / memory/ / tool-results/ 三种路径），封顶 `maxBytes`
    static func readAny(_ path: String, profileId: String, maxBytes: Int) throws -> (text: String, truncated: Bool) {
        MainThreadIO.assertOffMain(.read, "FileLibraryStore.readAny")
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if trimmed.hasPrefix(toolResultsVirtualPrefix) {
            text = try toolResultRead(trimmed, profileId: profileId, maxBytes: maxBytes + 1)
        } else if trimmed.hasPrefix(memoryVirtualPrefix) {
            text = try memoryRead(trimmed, profileId: profileId)
        } else {
            text = try readPreview(trimmed, maxBytes: maxBytes + 1, profileId: profileId)
        }
        guard text.utf8.count > maxBytes else { return (text, false) }
        var out = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return (out, true)
    }

    /// 跨文件关键词搜索，返回 [(path, 命中行)]。大小写不敏感。
    static func search(_ keyword: String, profileId: String) -> [(path: String, line: String)] {
        MainThreadIO.assertOffMain(.enumerate, "FileLibraryStore.search")
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("FileLibraryStore.search") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        guard !keyword.isEmpty else { return [] }
        var hits: [(path: String, line: String)] = []
        // 书的 source.txt 是全文备份（重新分章用），和章节文件内容重复——搜索跳过，免得每句都命中两次
        for meta in list(profileId: profileId) where !isBinaryPath(meta.path)
            && !(meta.path.hasPrefix("books/") && meta.path.hasSuffix("/source.txt")) {
            guard let body = try? read(meta.path, profileId: profileId) else { continue }
            for line in body.split(separator: "\n", omittingEmptySubsequences: false)
                where line.range(of: keyword, options: .caseInsensitive) != nil {
                hits.append((meta.path, String(line)))
            }
        }
        return hits
    }

    // MARK: - Profile Directories

    /// internal（原 private）：离线沙箱的 bind mount 要断言「挂载源就是这个函数的返回值」，
    /// 不给参数化（plan §1.5）。行为一字未改。
    static func filesystemRoot(profileId: String) -> URL {
        floorDirectory(profileId: profileId)
            .appendingPathComponent(filesystemFolderName, isDirectory: true)
    }

    /// 楼层 `.memorypalace/`（和 manifest 同目录，不在文件列表里）。不建目录，写的人自己建。
    static func metadataDirectory(profileId: String) -> URL {
        floorDirectory(profileId: profileId).appendingPathComponent(metadataFolderName, isDirectory: true)
    }

    private static func floorDirectory(profileId: String) -> URL {
        documentsBaseRoot().appendingPathComponent(floorSlug(profileId: profileId), isDirectory: true)
    }

    private static func floorDirectory(for profile: Profile) -> URL {
        if let existing = findExistingFloorDirectory(profileId: profile.id) {
            setSlug(existing.lastPathComponent, for: profile.id)
            return existing
        }

        let slug = uniqueSlug(base: slug(for: profile), profileId: profile.id)
        setSlug(slug, for: profile.id)
        return documentsBaseRoot().appendingPathComponent(slug, isDirectory: true)
    }

    private static func slug(for profile: Profile) -> String {
        // emoji 进文件夹名方便 Finder 定位（APFS 文件名安全；sanitize 会滤掉控制符/路径危险字符）
        let emoji = profile.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = sanitizeFloorName(emoji + profile.name)
        return "\(name)-\(shortId(profile.id))"
    }

    /// 目录名去重。已占用名单读一次、本楼层已有目录查一次——原来每试一个候选就把全部楼层的 manifest
    /// 扫一遍，N 个同前缀楼层是 O(N²)（RunCommandToolTests 泄到 617 个 `楼层-testrunc-*` 时一次 16s）。
    /// 名字比较用小写：APFS 默认大小写不敏感，`fileExists` 原本就是这么判的。
    private static func uniqueSlug(base: String, profileId: String) -> String {
        let root = documentsBaseRoot()
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).map { $0.lowercased() })
        let owned = findExistingFloorDirectory(profileId: profileId)?.lastPathComponent.lowercased()
        var candidate = base
        var index = 2
        while taken.contains(candidate.lowercased()), candidate.lowercased() != owned {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    private static func findExistingFloorDirectory(profileId: String) -> URL? {
        let root = documentsBaseRoot()
        if let mapped = slugMap()[profileId], !mapped.isEmpty {
            let url = root.appendingPathComponent(mapped, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let manifestURL = url
                .appendingPathComponent(metadataFolderName, isDirectory: true)
                .appendingPathComponent(manifestFileName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? manifestDecoder.decode(FloorManifest.self, from: data),
                  manifest.profileId == profileId else { continue }
            return url
        }
        return nil
    }

    private static func writeManifest(profile: Profile, floorURL: URL) {
        let manifest = FloorManifest(
            schemaVersion: 1,
            profileId: profile.id,
            displayName: profile.name,
            filesystemPath: filesystemFolderName,
            createdAt: profile.createdAt
        )
        let metadataURL = floorURL.appendingPathComponent(metadataFolderName, isDirectory: true)
        let fileURL = metadataURL.appendingPathComponent(manifestFileName)
        guard let data = try? manifestEncoder.encode(manifest) else { return }
        // perf-flash L3：启动时每个楼层都走这里；内容逐字节没变就不再 atomic 重写（缺文件 / 改名 / 损坏照旧写）
        if (try? Data(contentsOf: fileURL)) == data { return }
        try? FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func sanitizeFloorName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "楼层" : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let scalars = fallback.unicodeScalars.map {
            invalid.contains($0) || CharacterSet.controlCharacters.contains($0) ? "-" : Character($0)
        }
        let collapsed = String(scalars).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        let slug = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        return slug.isEmpty ? "楼层" : String(slug.prefix(40))
    }

    private static func shortId(_ profileId: String) -> String {
        let safe = profileId.filter { $0.isLetter || $0.isNumber }
        return String((safe.isEmpty ? "profile" : safe).prefix(8))
    }

    // MARK: - iCloud 迁移（开=本地→云，关=云→本地；保守 copy 不删源，冲突生成 .conflict 副本）

    struct FloorsMigrationResult {
        var floors = 0
        var filesCopied = 0
        var conflicts = 0
    }

    /// 把 from/floors 下每层楼的 filesystem/ + .memorypalace/ 复制到 to/floors（memory/ 永远不搬）。
    /// 同路径同字节跳过、同路径异字节生成 .conflict 副本（沿用 legacy migration 语义）。
    static func migrateFloors(from sourceRoot: URL, to destinationRoot: URL) -> FloorsMigrationResult {
        var result = FloorsMigrationResult()
        let fm = FileManager.default
        guard let floorNames = try? fm.contentsOfDirectory(atPath: sourceRoot.path) else { return result }

        for floorName in floorNames where !floorName.hasPrefix(".") {
            let sourceFloor = sourceRoot.appendingPathComponent(floorName, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sourceFloor.path, isDirectory: &isDir), isDir.boolValue else { continue }
            result.floors += 1

            for sub in [filesystemFolderName, metadataFolderName] {
                let sourceSub = sourceFloor.appendingPathComponent(sub, isDirectory: true)
                guard fm.fileExists(atPath: sourceSub.path),
                      let en = fm.enumerator(at: sourceSub, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                let destSub = destinationRoot
                    .appendingPathComponent(floorName, isDirectory: true)
                    .appendingPathComponent(sub, isDirectory: true)
                for case let fileURL as URL in en {
                    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    let rel = String(fileURL.standardizedFileURL.path.dropFirst(sourceSub.standardizedFileURL.path.count + 1))
                    let destURL = destSub.appendingPathComponent(rel)
                    do {
                        let hadConflict = fm.fileExists(atPath: destURL.path)
                            && (try? Data(contentsOf: destURL)) != (try? Data(contentsOf: fileURL))
                        try copyLegacyFile(fileURL, to: destURL)
                        result.filesCopied += 1
                        if hadConflict { result.conflicts += 1 }
                    } catch {
                        #if DEBUG
                        print("[FileLibraryStore] iCloud migration failed for \(floorName)/\(sub)/\(rel): \(error)")
                        #endif
                    }
                }
            }
        }
        return result
    }

    // MARK: - Migration

    private static func migrateLegacyFilesIfNeeded(profile: Profile, destinationRoot: URL) {
        let key = migrationKeyPrefix + profile.id
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let sourceRoot = legacyRoot(profileId: profile.id)
        guard FileManager.default.fileExists(atPath: sourceRoot.path) else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }

        guard let en = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }

        var copiedAny = false
        var failed = false
        try? FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for case let sourceURL as URL in en {
            let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let rel = String(sourceURL.standardizedFileURL.path.dropFirst(sourceRoot.standardizedFileURL.path.count + 1))
            let destinationURL = destinationRoot.appendingPathComponent(rel)
            do {
                try copyLegacyFile(sourceURL, to: destinationURL)
                copiedAny = true
            } catch {
                failed = true
                #if DEBUG
                print("[FileLibraryStore] legacy migration failed for \(rel): \(error)")
                #endif
            }
        }

        if !failed || !copiedAny {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    private static func copyLegacyFile(_ sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: destinationURL.path) {
            let sourceData = try Data(contentsOf: sourceURL)
            let destinationData = try Data(contentsOf: destinationURL)
            if sourceData == destinationData { return }
            let conflictURL = conflictURL(for: destinationURL)
            try sourceData.write(to: conflictURL, options: .atomic)
            return
        }

        try fm.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func conflictURL(for url: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(base).conflict-\(stamp)" : "\(base).conflict-\(stamp).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    // MARK: - UserDefaults + Helpers

    private static func slugMap() -> [String: String] {
        guard let data = BlobStore.data(forKey: slugMapKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func setSlug(_ slug: String, for profileId: String) {
        var map = slugMap()
        guard map[profileId] != slug else { return }
        map[profileId] = slug
        if let data = try? JSONEncoder().encode(map) {
            do { try BlobStore.set(data, forKey: slugMapKey) }
            catch { NSLog("文件库映射保存失败：%@", error.localizedDescription) }
        }
    }

    /// 启动时清掉不在楼层列表里的映射（plan-mac-hang-probe 偏好域臃肿：测试用假 profileId 调 floorSlug，
    /// 映射越积越多，09-25 攒到 5507 条只有 6 条是真楼层）。楼层目录本身不动
    static func pruneSlugMap(keeping profileIds: Set<String>) {
        guard !profileIds.isEmpty else { return }
        let map = slugMap()
        let kept = map.filter { profileIds.contains($0.key) }
        guard kept.count != map.count, let data = try? JSONEncoder().encode(kept) else { return }
        do { try BlobStore.set(data, forKey: slugMapKey) }
        catch { NSLog("文件库映射保存失败：%@", error.localizedDescription) }
    }

    /// 测试 tearDown 用：把自己造的假楼层映射删掉，别留在真实数据里
    static func forgetSlug(profileId: String) {
        var map = slugMap()
        guard map.removeValue(forKey: profileId) != nil, let data = try? JSONEncoder().encode(map) else { return }
        do { try BlobStore.set(data, forKey: slugMapKey) }
        catch { NSLog("文件库映射保存失败：%@", error.localizedDescription) }
    }

    private static var manifestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var manifestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "FileLibrary", code: -1, userInfo: [NSLocalizedDescriptionKey: m])
    }

    private static let textExtensions: Set<String> = ["md", "markdown", "html", "htm", "txt", "json", "css", "js"]
    /// 二进制白名单（附件一份存储）：文本工具（read/write/edit/search）一律拒，走 readData/writeData
    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "pdf",
        "zip", "docx", "xlsx", "pptx", "mp3", "m4a", "wav", "mp4", "mov", "bin"
    ]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    static func isBinaryPath(_ relPath: String) -> Bool {
        binaryExtensions.contains((relPath as NSString).pathExtension.lowercased())
    }

    static func isImagePath(_ relPath: String) -> Bool {
        imageExtensions.contains((relPath as NSString).pathExtension.lowercased())
    }

    /// 库内文件的绝对 URL（缩略图/QuickLook 用）。nil = 非法路径或不存在。
    static func absoluteURL(_ relPath: String, profileId: String) -> URL? {
        MainThreadIO.assertOffMain(.stat, "FileLibraryStore.absoluteURL")
        guard let url = resolve(relPath, profileId: profileId),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func isSupportedFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return textExtensions.contains(ext) || binaryExtensions.contains(ext)
    }

    private static func validateSupported(_ url: URL) throws {
        guard isSupportedFile(url) else {
            throw err("不支持的文件类型：.\(url.pathExtension)")
        }
    }

    private static func validateTextFile(_ url: URL) throws {
        try validateSupported(url)
        guard !binaryExtensions.contains(url.pathExtension.lowercased()) else {
            throw err("二进制文件，不支持文本读写：\(url.lastPathComponent)")
        }
    }

    private static func validateRegularFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw err("不是可读写的文本文件：\(url.lastPathComponent)")
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func utf8Data(_ content: String) throws -> Data {
        guard let data = content.data(using: .utf8) else {
            throw err("文本无法编码为 UTF-8")
        }
        return data
    }
}

#if DEBUG
extension FileLibraryStore {
    /// 手动验证 Documents root + path 防越狱 + edit 唯一命中 + search 大小写不敏感。
    /// 跑一次看 console 见 "selfCheck ✅" 且无 assert 崩溃。
    static func _selfCheck() {
        let profile = Profile(
            id: "selfcheck-\(UUID().uuidString)",
            name: "自检楼层",
            emoji: "T",
            description: "selfcheck",
            userName: "你",
            assistantName: "AI"
        )
        UserDefaults.standard.removeObject(forKey: migrationKeyPrefix + profile.id)

        let legacy = legacyRoot(profileId: profile.id)
        try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try? "legacy".data(using: .utf8)?.write(to: legacy.appendingPathComponent("legacy.md"), options: .atomic)
        try? "legacy-conflict".data(using: .utf8)?.write(to: legacy.appendingPathComponent("conflict.md"), options: .atomic)

        let plannedFloor = floorDirectory(for: profile)
        let plannedRoot = plannedFloor.appendingPathComponent(filesystemFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: plannedRoot, withIntermediateDirectories: true)
        try? "local-conflict".data(using: .utf8)?.write(to: plannedRoot.appendingPathComponent("conflict.md"), options: .atomic)

        prepareProfile(profile)
        let pid = profile.id
        assert(libraryRoot(profileId: pid).path.contains("/Documents/\(appFolderName)/\(floorsFolderName)/"), "root 未迁到 Documents")
        assert((try? read("legacy.md", profileId: pid)) == "legacy", "legacy 文件未迁移")
        assert(list(profileId: pid).contains { $0.path.hasPrefix("conflict.conflict-") }, "legacy 冲突未生成副本")
        assert(resolve("../escape.md", profileId: pid) == nil, "../ 越狱未拦截")
        assert(resolve("/etc/passwd", profileId: pid) == nil, "绝对路径未拦截")
        assert((try? write("hidden.bin", content: "nope", profileId: pid)) == nil, "不支持的扩展名未拦截")
        let folderURL = libraryRoot(profileId: pid).appendingPathComponent("folder.md", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        assert(!list(profileId: pid).contains { $0.path == "folder.md" }, "list 未过滤伪装成文件的目录")
        assert((try? read("folder.md", profileId: pid)) == nil, "read 未拦截目录")
        assert((try? write("folder.md", content: "nope", profileId: pid)) == nil, "write 未拦截目录")
        try? write("a.md", content: "hello\nworld", profileId: pid)
        try? append("a.md", content: "\nagain", profileId: pid)
        assert((try? read("a.md", profileId: pid)) == "hello\nworld\nagain", "append 失败")
        try? edit("a.md", oldString: "world", newString: "susu", profileId: pid)
        assert((try? read("a.md", profileId: pid)) == "hello\nsusu\nagain", "edit 替换失败")
        try? rename("a.md", to: "notes/a-renamed.md", profileId: pid)
        assert((try? read("notes/a-renamed.md", profileId: pid)) == "hello\nsusu\nagain", "rename 失败")
        assert((try? rename("notes/a-renamed.md", to: "notes/hidden.exe", profileId: pid)) == nil, "rename 未拦截不支持扩展名")
        assert(search("HELLO", profileId: pid).count == 1, "search 大小写不敏感失败")

        // 二进制（附件一份存储）
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try? writeData("attachments/test/pic.png", data: pngBytes, profileId: pid)
        assert((try? readData("attachments/test/pic.png", profileId: pid)) == pngBytes, "二进制读写 roundtrip 失败")
        assert((try? read("attachments/test/pic.png", profileId: pid)) == nil, "文本 read 未拦截二进制")
        assert((try? write("attachments/test/pic.png", content: "x", profileId: pid)) == nil, "文本 write 未拦截二进制")
        assert(isBinaryPath("a/b.PNG") && isImagePath("a/b.jpeg") && !isBinaryPath("a/b.md"), "扩展名判断失败")
        assert(list(profileId: pid).contains { $0.path == "attachments/test/pic.png" }, "list 未包含二进制")
        assert(search("PNG", profileId: pid).allSatisfy { $0.path != "attachments/test/pic.png" }, "search 未跳过二进制")
        assert((try? AttachmentStore.save(fileName: "pic.png", data: pngBytes, conversationId: "conv12345678", conversationTitle: "测试对话", profileId: pid)) == "attachments/conv1234-测试对话/pic.png", "AttachmentStore 落盘路径错误")
        assert((try? AttachmentStore.save(fileName: "pic.png", data: pngBytes, conversationId: "conv12345678", conversationTitle: "改名了", profileId: pid)) == "attachments/conv1234-测试对话/pic.png", "同名同字节应幂等复用 / 目录未按前缀复用")
        assert((try? AttachmentStore.save(fileName: "pic.png", data: pngBytes + Data([1]), conversationId: "conv12345678", conversationTitle: nil, profileId: pid)) == "attachments/conv1234-测试对话/pic-2.png", "同名异字节未加 -2")
        AttachmentStore.deleteConversationAttachments(conversationId: "conv12345678", profileId: pid)
        assert(!exists("attachments/conv1234-测试对话/pic.png", profileId: pid), "删除对话附件目录失败")

        try? delete("notes/a-renamed.md", profileId: pid)
        try? FileManager.default.removeItem(at: folderURL)
        try? FileManager.default.removeItem(at: floorDirectory(profileId: pid))
        try? FileManager.default.removeItem(at: legacy)
        print("[FileLibraryStore] selfCheck ✅")
    }
}
#endif
