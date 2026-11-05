import Foundation

/// 「Prompt」虚拟根在文件库里的显示（第 5 段）：和「记忆」平级、紧挨在它后面；插槽保持 Prompt 页顺序，不跟文件名 / 时间排序。
/// 没有改动时间（modifiedAt = distantPast，列表不显示时间）
enum FileLibraryPromptFolder {
    static func metas(_ entries: [PromptFolder.Entry]) -> [FileLibraryStore.FileMeta] {
        entries.map { .init(path: $0.path, bytes: $0.content.utf8.count, modifiedAt: .distantPast) }
    }

    /// 库里早就有的真 `.prompt/` 文件（这段之前建的；之后物理写一律被拒）不遮住：并在虚拟条目后面照常列，点开只读
    static func merge(_ entries: [PromptFolder.Entry], into index: inout [String: FileLibraryDisplay.FolderContents]) {
        let all = metas(entries)
        let slots = all.filter { FileLibraryDisplay.parentFolder($0.path) == PromptFolder.root }
        let fields = all.filter { FileLibraryDisplay.parentFolder($0.path) == PromptFolder.fieldsFolder }
        let rootFolders = index[""]?.folders ?? []
        let physicalRoot = rootFolders.first { $0.path == PromptFolder.root }
        let physical = index[PromptFolder.root] ?? .init(folders: [], files: [])
        let physicalFields = index[PromptFolder.fieldsFolder] ?? .init(folders: [], files: [])
        let physicalFieldsFolder = physical.folders.first { $0.path == PromptFolder.fieldsFolder }
        index[""] = .init(folders: rootFolders.filter { $0.path != PromptFolder.root }
                            + [.init(path: PromptFolder.root, fileCount: all.count + (physicalRoot?.fileCount ?? 0),
                                     imageCount: physicalRoot?.imageCount ?? 0, latest: physicalRoot?.latest ?? .distantPast)],
                          files: index[""]?.files ?? [])
        let fieldsFolder = FileLibraryDisplay.Folder(path: PromptFolder.fieldsFolder,
                                                     fileCount: fields.count + (physicalFieldsFolder?.fileCount ?? 0),
                                                     imageCount: physicalFieldsFolder?.imageCount ?? 0,
                                                     latest: physicalFieldsFolder?.latest ?? .distantPast)
        // 一个字段都没填就不出「楼层字段」
        let shownFields = fieldsFolder.fileCount > 0 ? [fieldsFolder] : []
        index[PromptFolder.root] = .init(folders: shownFields + physical.folders.filter { $0.path != PromptFolder.fieldsFolder },
                                         files: slots + physical.files)
        index[PromptFolder.fieldsFolder] = fieldsFolder.fileCount > 0 || !physicalFields.folders.isEmpty
            ? .init(folders: physicalFields.folders, files: fields + physicalFields.files) : nil
    }

    /// Prompt 根里文件夹（楼层字段）排在所有插槽后面
    static func foldersAfterFiles(_ folder: String) -> Bool { folder == PromptFolder.root }

    /// 虚拟目录：不新建、不排序（顺序就是 Prompt 页的）
    static func isVirtualFolder(_ folder: String) -> Bool { folder == PromptFolder.root || folder == PromptFolder.fieldsFolder }

    /// 面包屑用显示名：「文件库 / Prompt / 楼层字段」
    static func breadcrumb(_ folder: String) -> [(name: String, path: String)] {
        FileLibraryDisplay.breadcrumb(folder).map { (PromptFolder.displayName($0.path) ?? $0.name, $0.path) }
    }

    /// 只读预览：自动填充槽空着时给一句说明，不留白页
    static func readOnlyText(_ entry: PromptFolder.Entry) -> String {
        entry.content.isEmpty && !entry.isEditable ? "这一段发送时由系统自动填充。" : entry.content
    }

    /// 文件夹排完序后再挪：紧挨在「记忆」后面
    static func pinAfterMemory(_ index: inout [String: FileLibraryDisplay.FolderContents]) {
        guard var folders = index[""]?.folders, let i = folders.firstIndex(where: { $0.path == PromptFolder.root }) else { return }
        let prompt = folders.remove(at: i)
        let at = folders.firstIndex(where: { $0.path == FileLibraryMemoryFolder.root }).map { $0 + 1 } ?? folders.count
        folders.insert(prompt, at: at)
        index[""]?.folders = folders
    }

    /// 标题 = 槽名原样；空名、关着、自动填充：列表写在副标题，卡片做成标签
    static func display(_ entry: PromptFolder.Entry) -> FileLibraryDisplay.Entry {
        let lines = entry.content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var tags: [String] = []
        if entry.name.isEmpty { tags.append("未命名") }
        if entry.isEnabled == false { tags.append("已关闭") }
        if !entry.isEditable { tags.append("自动填充") }
        return FileLibraryDisplay.Entry(title: entry.name, summary: (tags + [lines.first ?? "（空）"]).joined(separator: " · "),
                                        chips: tags, lines: Array(lines.prefix(FileLibraryDisplay.paperLineLimit)), searchText: "")
    }
}
