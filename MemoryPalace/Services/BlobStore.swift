import Foundation

/// 大 blob 不进 UserDefaults（09-18：偏好域 3.8MB 撑爆 cfprefsd，每写一个 key 主线程整本重解析 0.3–0.5s，
/// 见 docs/research-prefs-domain-bloat.md §3 B）。文件落 Application Support/MemoryPalace/blobs/<key>；
/// 第一次读时从 UserDefaults 迁出并删旧 key。GlobalBackup 的导出 / 导入 / 快照回滚按 `migratedKeys` 分流，备份格式不变。
/// root / defaults 可注入：测试和离线演练不访问真实偏好域。
enum BlobStore {
    /// 已搬出 UserDefaults 的 key（只搬存储位置，key 名和 JSON 形状都不变）
    /// 09-25 加 fileLibraryLocalDocumentsSlugMapV1：测试往真实偏好域漏了 5500 条假楼层（240KB），见 review-mac-hang-probe
    /// 10-01 加楼层 / 预设 / 全局书（卡库 ⑧c-4，docs/decision-card-library-storage.md A）：整包导入后三个 key 合计约 181MB
    static let migratedKeys: Set<String> = ["savedCharacterCards", "fileLibraryLocalDocumentsSlugMapV1",
                                            "savedProfiles", "savedPresets", "globalWorldBooks"]

    private static func directory(root: URL?) -> URL {
        root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
    }

    static func path(forKey key: String, root: URL? = nil) -> URL {
        directory(root: root).appendingPathComponent(key)
    }

    /// 注入了临时 defaults 却没给 root（测试 / 离线演练漏传）：落进程临时目录，绝不碰真实 blobs
    static func resolvedRoot(_ root: URL?, defaults: UserDefaults) -> URL? {
        guard root == nil, defaults !== UserDefaults.standard else { return root }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "BlobStore-unrooted-\(ProcessInfo.processInfo.processIdentifier)-\(UInt(bitPattern: ObjectIdentifier(defaults).hashValue))",
            isDirectory: true)
    }

    static func read(forKey key: String, root: URL? = nil, defaults: UserDefaults = .standard) throws -> Data? {
        let url = directory(root: root).appendingPathComponent(key)
        if let data = try readIfPresent(url) {
            // 文件是唯一写入目标：旧 key 还在（上次删没生效 / 迁移失败后又写成功）一定更旧，能读通才清；损坏的旧 key 留着备查
            if let legacy = defaults.data(forKey: key), (try? validate(legacy, forKey: key)) != nil {
                removeLegacy(key, defaults: defaults)
            }
            return data
        }
        guard let legacy = defaults.data(forKey: key) else { return nil }
        // 卡库先验证再迁移；失败时保留原偏好数据。
        // ⑧c-4：楼层 / 预设 / 全局书同样先验证；旧 key 损坏不写 blob、保留旧 key，抛给调用方（管理器拒绝覆盖）
        try validate(legacy, forKey: key)
        do {
            try set(legacy, forKey: key, root: root)
            guard try Data(contentsOf: url) == legacy else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            // 写 blob 失败 / 回读不一致：不留半截文件，旧 key 原样保留继续用，下次读再迁
            try? FileManager.default.removeItem(at: url)
            NSLog("BlobStore 迁移失败 [%@]，继续用偏好里的旧数据：%@", key, error.localizedDescription)
            return legacy
        }
        removeLegacy(key, defaults: defaults)
        return legacy
    }

    /// #037：只有确实不存在（ENOENT / 上级不是目录）返回 nil；查不了（权限 / 数据保护 / IO）一律抛，
    /// 不能像 fileExists 那样把 stat 失败当「没有」，调用方会拿 seed / 旧 key 覆盖真文件
    private static func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return nil }
            if let posix = error.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain,
               posix.code == Int(ENOENT) || posix.code == Int(ENOTDIR) { return nil }
            throw error
        }
    }

    /// 一次只删一个 key（CFPreferencesSetMultiple 删 ≥2 个会静默失效），删完回读确认
    private static func removeLegacy(_ key: String, defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
        if defaults.object(forKey: key) != nil { NSLog("BlobStore 旧 key 没删掉 [%@]，下次读再删", key) }
    }

    private static func validate(_ data: Data, forKey key: String) throws {
        let decoder = JSONDecoder()
        switch key {
        case "savedCharacterCards": _ = try decoder.decode([CharacterCard].self, from: data)
        case "savedProfiles": _ = try decoder.decode([Profile].self, from: data)
        case "savedPresets": _ = try decoder.decode([Preset].self, from: data)
        case "globalWorldBooks": _ = try decoder.decode([GlobalWorldBook].self, from: data)
        default: break
        }
    }

    static func data(forKey key: String) -> Data? {
        do { return try read(forKey: key) }
        catch {
            NSLog("BlobStore 读取失败 [%@]：%@", key, error.localizedDescription)
            return nil
        }
    }

    static func set(_ data: Data?, forKey key: String, root: URL? = nil) throws {
        let dir = directory(root: root)
        let url = dir.appendingPathComponent(key)
        if let data {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
