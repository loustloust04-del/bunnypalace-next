import Foundation

/// 文件夹外观表：楼层 `.memorypalace/folder-styles.json`，按文件夹相对路径记。只在用户改外观时写。
enum FileLibraryFolderStyleStore {
    static let fileName = "folder-styles.json"

    struct Table: Codable, Equatable {
        var version = 1
        var folders: [String: FileLibraryFolderLook]
    }

    /// 磁盘上的表现在什么状态
    enum DiskState: Equatable {
        case missing
        case table([String: FileLibraryFolderLook])
        /// iCloud 还没下载下来（有 `.icloud` 占位或下载状态不是 current）
        case notDownloaded
        /// 坏 JSON（可能是另一台设备写到一半）
        case unreadable
    }

    enum UpdateOutcome: Equatable {
        /// 写好了（或内容没变不用写），附磁盘上的最新整表
        case saved([String: FileLibraryFolderLook])
        case notDownloaded
        case unreadable
    }

    static func fileURL(profileId: String) -> URL {
        FileLibraryStore.metadataDirectory(profileId: profileId).appendingPathComponent(fileName)
    }

    static func load(profileId: String) -> [String: FileLibraryFolderLook] {
        load(from: fileURL(profileId: profileId))
    }

    static func update(_ path: String, to look: FileLibraryFolderLook?, profileId: String) throws -> UpdateOutcome {
        try update(path, to: look, at: fileURL(profileId: profileId))
    }

    /// 读用：没下载 / 坏 JSON 都当空表显示，原文件不动
    static func load(from url: URL) -> [String: FileLibraryFolderLook] {
        if case .table(let folders) = diskState(at: url) { return folders }
        return [:]
    }

    static func diskState(at url: URL) -> DiskState {
        let fm = FileManager.default
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) { return .notDownloaded }
        guard fm.fileExists(atPath: url.path) else { return .missing }
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status != .current {
            return .notDownloaded
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        do {
            return .table(try JSONDecoder().decode(Table.self, from: data).folders)
        } catch {
            NSLog("文件夹外观表读不了：%@", error.localizedDescription)
            return .unreadable
        }
    }

    /// 改一条：现读磁盘最新的表、只改这一条再写回（read-merge-write）。nil = 删掉这条（恢复默认）。
    /// 表还没从 iCloud 下载下来 → 触发下载、这次不写；坏 JSON → 不写、不覆盖原文件。
    static func update(_ path: String, to look: FileLibraryFolderLook?, at url: URL) throws -> UpdateOutcome {
        var folders: [String: FileLibraryFolderLook]
        switch diskState(at: url) {
        case .missing:
            folders = [:]
        case .table(let current):
            folders = current
        case .notDownloaded:
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return .notDownloaded
        case .unreadable:
            return .unreadable
        }
        folders[path] = look
        try save(folders, to: url)
        return .saved(folders)
    }

    /// atomic 写；内容逐字节没变就不写
    static func save(_ folders: [String: FileLibraryFolderLook], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Table(folders: folders))
        if (try? Data(contentsOf: url)) == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
