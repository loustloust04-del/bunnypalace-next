import Foundation

/// 「记忆条目」和「日志」里那两份看得懂的日志在文件库里的显示（粟粟 11-14：记忆和 文件库 › 记忆 1:1）。
/// 都不在盘上：卡 = `Memory` 表里现排的条目（`MemoryCardFolder`），日志 = 两个 `.jsonl` 现排的只读页（`MemoryLogFolder`）
enum FileLibraryCardFolder {
    static func metas(_ entries: [MemoryCardFolder.Entry]) -> [FileLibraryStore.FileMeta] {
        entries.map { .init(path: $0.path, bytes: $0.content.utf8.count, modifiedAt: $0.modifiedAt) }
    }

    static func metas(_ logs: [MemoryLogFolder.File]) -> [FileLibraryStore.FileMeta] {
        logs.map { .init(path: $0.path, bytes: $0.content.utf8.count, modifiedAt: $0.modifiedAt) }
    }

    /// 记忆 › 记忆条目 永远在（一张卡都没有也有这一格）；下面每个「说的是谁」一个文件夹（新的在前），删了的那一格 `Deleted` 排最后，
    /// 这一层直接放着「钉住的」那份清单。记忆 › 日志：两份现排的日志放在最前面，盘上原有的（C2 整理记录那个文件夹）照旧。
    /// `logs` = 现排的只读页（两份日志 + 钉住的清单），各放进自己路径所在的文件夹
    static func merge(_ entries: [MemoryCardFolder.Entry], logs allLogs: [MemoryLogFolder.File],
                      into index: inout [String: FileLibraryDisplay.FolderContents]) {
        let memoryRoot = FileLibraryMemoryFolder.root
        guard var memory = index[memoryRoot] else { return }

        let all = metas(entries)
        let deletedFolder = MemoryCardFolder.root + "/" + MemoryCardFolder.deletedFolder
        var order: [String] = []
        var grouped: [String: [FileLibraryStore.FileMeta]] = [:]
        for (entry, meta) in zip(entries, all) {
            if grouped[entry.folder] == nil { order.append(entry.folder) }
            grouped[entry.folder, default: []].append(meta)
        }
        if let i = order.firstIndex(of: deletedFolder) { order.append(order.remove(at: i)) }
        let cardLists = metas(allLogs.filter { FileLibraryDisplay.parentFolder($0.path) == MemoryCardFolder.root })
        index[MemoryCardFolder.root] = .init(folders: order.map { folder in
            .init(path: folder, fileCount: grouped[folder]?.count ?? 0, imageCount: 0,
                  latest: grouped[folder]?.map(\.modifiedAt).max() ?? .distantPast)
        }, files: cardLists)
        for folder in order { index[folder] = .init(folders: [], files: grouped[folder] ?? []) }
        let live = zip(entries, all).filter { $0.0.folder != deletedFolder }.map(\.1)
        memory.folders.removeAll { $0.path == MemoryCardFolder.root }
        memory.folders.append(.init(path: MemoryCardFolder.root, fileCount: live.count, imageCount: 0,
                                    latest: live.map(\.modifiedAt).max() ?? .distantPast))

        let logs = allLogs.filter { FileLibraryDisplay.parentFolder($0.path) == MemoryLogFolder.folder }
        if !logs.isEmpty {
            let logMetas = metas(logs)
            var log = index[MemoryLogFolder.folder] ?? .init(folders: [], files: [])
            log.files = logMetas + log.files.filter { meta in !logMetas.contains { $0.path == meta.path } }
            index[MemoryLogFolder.folder] = log
            let latest = logMetas.map(\.modifiedAt).max() ?? .distantPast
            if let i = memory.folders.firstIndex(where: { $0.path == MemoryLogFolder.folder }) {
                memory.folders[i].fileCount += logMetas.count
                memory.folders[i].latest = max(memory.folders[i].latest, latest)
            } else {
                memory.folders.append(.init(path: MemoryLogFolder.folder, fileCount: logMetas.count, imageCount: 0, latest: latest))
            }
        }
        index[memoryRoot] = memory
    }

    /// 标题 = 卡的正文；副标题 = Draft / Archive / Deleted、钉没钉、谁说的 · 置信度 · #标签
    static func display(_ entry: MemoryCardFolder.Entry) -> FileLibraryDisplay.Entry {
        let lines = entry.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tags = [entry.state] + (entry.pinned ? ["Pinned"] : [])
        return FileLibraryDisplay.Entry(title: lines.first ?? "（空）",
                                        summary: (tags + [entry.traits]).filter { !$0.isEmpty }.joined(separator: " · "),
                                        chips: tags, lines: Array(lines.prefix(FileLibraryDisplay.paperLineLimit)), searchText: "")
    }

    static func display(_ log: MemoryLogFolder.File) -> FileLibraryDisplay.Entry {
        let lines = log.content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("# ") }
        return FileLibraryDisplay.Entry(title: log.title, summary: "只读 · " + (lines.first ?? ""), chips: ["只读"],
                                        lines: Array(lines.prefix(FileLibraryDisplay.paperLineLimit)), searchText: "")
    }
}
