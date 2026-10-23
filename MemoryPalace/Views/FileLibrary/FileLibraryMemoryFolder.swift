import Foundation

/// 记忆树（memory/，虚拟路径）在文件库里当一个普通文件夹显示（第二刀验收返工，粟粟 10-10）：
/// 首页「文件夹」里一行「记忆」，进去每个子文件夹一行；AI 自己的记忆（memory/self/）永远在、排第一、可编辑，其余只读。
enum FileLibraryMemoryFolder {
    static let root = "memory"
    static let selfFolder = root + "/" + SelfMemoryStore.folder

    static func isMemoryPath(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    static func isSelfMemoryFile(_ path: String) -> Bool { path.hasPrefix(selfFolder + "/") }

    /// 自己的记忆的 slug（文件名去掉 .md）；不是 self 里的 .md → nil
    static func selfSlug(_ path: String) -> String? {
        guard isSelfMemoryFile(path), path.hasSuffix(".md") else { return nil }
        let name = String(path.dropFirst(selfFolder.count + 1))
        guard !name.contains("/") else { return nil }
        return String(name.dropLast(3))
    }

    /// 列表里不显示的：self/INDEX.md（三个记忆工具派生出来的目录，不是一条记忆）
    static func visible(_ list: [FileLibraryStore.FileMeta]) -> [FileLibraryStore.FileMeta] {
        list.filter { $0.path != selfFolder + "/" + SelfMemoryStore.indexFileName }
    }

    /// memory/ 和它下一层子文件夹的中文名；别的路径 nil（走 FileLibraryFolderStyle）
    static func displayName(_ path: String, assistantName: String) -> String? {
        if path == root { return "记忆" }
        if path == selfFolder { return "\(assistantName)的记忆" }
        guard path.hasPrefix(root + "/") else { return nil }
        let sub = String(path.dropFirst(root.count + 1))
        guard !sub.contains("/") else { return nil }
        return MemoryTreeGroup.titles[sub]
    }

    /// 把记忆树的文件夹索引并进文件库的：根下多一个「记忆」文件夹（有记忆文件才有）；
    /// 进去后 self 永远在（空也在）。排序交给调用方，排完再调 `pinSelfFirst`
    static func merge(_ memoryIndex: [String: FileLibraryDisplay.FolderContents],
                      into index: inout [String: FileLibraryDisplay.FolderContents]) {
        guard let rootFolder = memoryIndex[""]?.folders.first(where: { $0.path == root }) else { return }
        index["", default: .init(folders: [], files: [])].folders.append(rootFolder)
        for (key, contents) in memoryIndex where !key.isEmpty {
            index[key] = contents
        }
        if index[root]?.folders.contains(where: { $0.path == selfFolder }) != true {
            index[root, default: .init(folders: [], files: [])].folders
                .append(.init(path: selfFolder, fileCount: 0, imageCount: 0, latest: .distantPast))
        }
        if index[selfFolder] == nil { index[selfFolder] = .init(folders: [], files: []) }
    }

    static func pinSelfFirst(_ index: inout [String: FileLibraryDisplay.FolderContents]) {
        guard var folders = index[root]?.folders, let i = folders.firstIndex(where: { $0.path == selfFolder }) else { return }
        folders.insert(folders.remove(at: i), at: 0)
        index[root]?.folders = folders
    }
}
