import Foundation

/// 「种子待批」虚拟文件夹在文件库里的显示（第 6 段）：记忆 › wiki 下一格，每个种子任务一个文件夹（目录 + 各页草稿）。
/// 文件不在盘上，数据就是待批提案本身
enum FileLibrarySeedFolder {
    static func metas(_ entries: [CatalogSeedDrafts.Entry]) -> [FileLibraryStore.FileMeta] {
        entries.map { .init(path: $0.path, bytes: $0.content.utf8.count, modifiedAt: .distantPast) }
    }

    static func merge(_ entries: [CatalogSeedDrafts.Entry], into index: inout [String: FileLibraryDisplay.FolderContents]) {
        guard !entries.isEmpty else { return }
        let all = metas(entries)
        var folders: [String] = []
        for e in entries where !folders.contains(e.folder) { folders.append(e.folder) }
        let taskFolders = folders.map { folder in
            FileLibraryDisplay.Folder(path: folder, fileCount: entries.filter { $0.folder == folder }.count, imageCount: 0, latest: .distantPast)
        }
        index[CatalogSeedDrafts.root] = .init(folders: taskFolders, files: [])
        for folder in folders {
            index[folder] = .init(folders: [], files: all.filter { FileLibraryDisplay.parentFolder($0.path) == folder })
        }
        let wiki = FileLibraryMemoryFolder.wikiFolder
        var contents = index[wiki] ?? .init(folders: [], files: [])
        contents.folders.removeAll { $0.path == CatalogSeedDrafts.root }
        contents.folders.insert(.init(path: CatalogSeedDrafts.root, fileCount: all.count, imageCount: 0, latest: .distantPast), at: 0)
        index[wiki] = contents
    }

    static func displayName(_ path: String, entries: [CatalogSeedDrafts.Entry]) -> String? {
        if path == CatalogSeedDrafts.root { return "种子待批" }
        return entries.first { $0.folder == path }?.folderName
    }

    static func display(_ entry: CatalogSeedDrafts.Entry) -> FileLibraryDisplay.Entry {
        let lines = entry.content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tags = entry.editable ? ["可改"] : ["只读"]
        return FileLibraryDisplay.Entry(title: entry.name, summary: (tags + [lines.first ?? "（空）"]).joined(separator: " · "),
                                        chips: tags, lines: Array(lines.prefix(FileLibraryDisplay.paperLineLimit)), searchText: "")
    }
}
