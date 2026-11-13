import MemoryCore
import Foundation

/// 记忆树（memory/，虚拟路径）在文件库里当一个普通文件夹显示（第二刀验收返工，粟粟 10-10）：
/// 首页「文件夹」里一行「记忆」，进去每个子文件夹一行；AI 自己的记忆（memory/self/）永远在、排第一、可编辑，其余只读。
enum FileLibraryMemoryFolder {
    static let root = "memory"
    static let selfFolder = root + "/" + SelfMemoryStore.folder
    /// C 档案：页可编辑（存历史），索引与诊断记录只读。
    static let wikiFolder = root + "/wiki"
    static let runsFolder = wikiFolder + "/.runs"
    static let draftsFolder = wikiFolder + "/.drafts"
    static let draftsStorageFolder = wikiFolder + "/.proposals/drafts"
    static let diagnosticStorageFolders = [runsFolder, draftsStorageFolder]

    static func isMemoryPath(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    static func isSelfMemoryFile(_ path: String) -> Bool { path.hasPrefix(selfFolder + "/") }

    /// 自己的记忆的 slug（文件名去掉 .md）；不是 self 里的 .md → nil
    static func selfSlug(_ path: String) -> String? {
        guard isSelfMemoryFile(path), path.hasSuffix(".md") else { return nil }
        let name = String(path.dropFirst(selfFolder.count + 1))
        guard !name.contains("/") else { return nil }
        return String(name.dropLast(3))
    }

    /// UI 单独放行整理记录和原始输出；助手仍使用 isHiddenWikiPath，不走这个白名单。
    static func visible(_ list: [FileLibraryStore.FileMeta]) -> [FileLibraryStore.FileMeta] {
        list.filter {
            $0.path != selfFolder + "/" + SelfMemoryStore.indexFileName
                && (!isHiddenWikiPath($0.path) || diagnosticFolder(containing: $0.path) != nil)
        }
    }

    static func isDiagnosticFolder(_ path: String) -> Bool {
        path == runsFolder || path == draftsFolder
    }

    /// 文件保留真实虚拟路径供 resolveMemory 读取；只有文件夹分组把 drafts 提到 wiki 下。
    static func diagnosticFolder(containing path: String) -> String? {
        for storage in diagnosticStorageFolders where path.hasPrefix(storage + "/") {
            let name = String(path.dropFirst(storage.count + 1))
            guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return nil }
            let ext = (name as NSString).pathExtension.lowercased()
            if storage == runsFolder { return ext == "md" ? runsFolder : nil }
            return ["md", "txt"].contains(ext) ? draftsFolder : nil
        }
        return nil
    }

    static func parentFolder(_ path: String) -> String {
        diagnosticFolder(containing: path) ?? FileLibraryDisplay.parentFolder(path)
    }

    static func isHiddenWikiPath(_ path: String) -> Bool {
        guard path.hasPrefix(wikiFolder + "/") else { return false }
        return path.dropFirst(wikiFolder.count + 1).split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// `memory/wiki/人/小慧.md` → `人/小慧`；INDEX.md / 隐藏的 / 不是页 → nil
    static func wikiPagePath(_ path: String) -> String? {
        guard path.hasPrefix(wikiFolder + "/"), path.hasSuffix(".md") else { return nil }
        let page = String(path.dropFirst(wikiFolder.count + 1).dropLast(3))
        return WikiStore.isValidPagePath(page) ? page : nil
    }

    /// memory/ 和它下一层子文件夹的中文名、wiki 里本人那组（落盘 {{user}}）显示成用户名；别的路径 nil（走 FileLibraryFolderStyle）
    static func displayName(_ path: String, assistantName: String, userName: String = "") -> String? {
        if path == root { return "记忆" }
        if path == wikiFolder + "/" + WikiStore.userBranch { return WikiStore.userLabel(userName) }
        if path == selfFolder { return "\(assistantName)的记忆" }
        if path == runsFolder { return "整理记录" }
        if path == draftsFolder { return "模型原始输出" }
        guard path.hasPrefix(root + "/") else { return nil }
        let sub = String(path.dropFirst(root.count + 1))
        guard !sub.contains("/") else { return nil }
        return MemoryTreeGroup.titles[sub]
    }

    /// 即使记忆根或 wiki 尚不存在，入口也由索引虚拟出来，不触盘、不建目录。
    static func folderIndex(_ list: [FileLibraryStore.FileMeta]) -> [String: FileLibraryDisplay.FolderContents] {
        let memoryIndex = FileLibraryDisplay.folderIndex(visible(list))
        var index: [String: FileLibraryDisplay.FolderContents] = [:]
        let rootFolder = memoryIndex[""]?.folders.first { $0.path == root }
            ?? .init(path: root, fileCount: 0, imageCount: 0, latest: .distantPast)
        index["", default: .init(folders: [], files: [])].folders.append(rootFolder)
        for (key, contents) in memoryIndex where !key.isEmpty && !isHiddenWikiPath(key) {
            index[key] = .init(folders: contents.folders.filter { !isHiddenWikiPath($0.path) },
                               files: contents.files)
        }
        for path in [selfFolder, wikiFolder] {
            if index[root]?.folders.contains(where: { $0.path == path }) != true {
                index[root, default: .init(folders: [], files: [])].folders
                    .append(.init(path: path, fileCount: 0, imageCount: 0, latest: .distantPast))
            }
            if index[path] == nil { index[path] = .init(folders: [], files: []) }
        }
        for storage in diagnosticStorageFolders {
            let folder = storage == runsFolder ? runsFolder : draftsFolder
            let files = (memoryIndex[storage]?.files ?? []).filter { diagnosticFolder(containing: $0.path) == folder }
                .sorted(by: newestFirst)
            index[folder] = .init(folders: [], files: files)
            index[wikiFolder, default: .init(folders: [], files: [])].folders
                .append(.init(path: folder, fileCount: files.count, imageCount: 0,
                              latest: files.first?.modifiedAt ?? .distantPast))
        }
        return index
    }

    static func merge(_ memoryIndex: [String: FileLibraryDisplay.FolderContents],
                      into index: inout [String: FileLibraryDisplay.FolderContents]) {
        guard let rootFolder = memoryIndex[""]?.folders.first(where: { $0.path == root }) else { return }
        index["", default: .init(folders: [], files: [])].folders.append(rootFolder)
        for (key, contents) in memoryIndex where !key.isEmpty { index[key] = contents }
    }

    private static func newestFirst(_ lhs: FileLibraryStore.FileMeta, _ rhs: FileLibraryStore.FileMeta) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedDescending
    }

    static func pinSelfFirst(_ index: inout [String: FileLibraryDisplay.FolderContents]) {
        if var folders = index[root]?.folders, let i = folders.firstIndex(where: { $0.path == selfFolder }) {
            folders.insert(folders.remove(at: i), at: 0)
            index[root]?.folders = folders
        }
        for folder in [runsFolder, draftsFolder] { index[folder]?.files.sort(by: newestFirst) }
    }
}
