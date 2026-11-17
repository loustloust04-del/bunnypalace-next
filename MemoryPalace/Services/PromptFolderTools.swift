import Foundation

/// 助手用文件工具读写文件库的「Prompt」文件夹（粟粟 11-14「现在 api/cc 还不能写助手设定」）：
/// 和她在 文件库 › Prompt 里看到的是同一份（`PromptFolder`：这一层当前预设的插槽 + 楼层字段），路径也是同一个，写回走 `PromptFolder.save`
/// （别处改过 / 槽不在了 / 系统自动填充的槽 三种拒绝照用）。只给改已有条目的正文：新建、删除、改名、开关插槽在 Prompt 页。
/// 每次写入在这一段的版本历史里落两版——写之前的样子、写之后的样子（标着是谁写的），她在编辑页的历史里能回到上一版。
/// 权限 = 「Prompt」域三档（`PermissionDomain.promptEdit`，默认每次询问、一笔一问）
enum PromptFolderTools {
    /// app 根建好两个 manager 时接上（`MemoryPalaceApp.init`）；没接上 = 读不到条目、写会回「没准备好」
    @MainActor static weak var profiles: ProfileManager?
    @MainActor static weak var presets: PresetManager?
    /// 版本历史落哪（测试换成临时目录的）
    @MainActor static var versionStore: FileVersionStore = .shared

    struct File: Equatable, Sendable {
        var path: String
        var content: String
        /// 列表里跟在路径后面的说明：这是哪一段、开没开、能不能改
        var note: String
        /// 系统自动填充的插槽是 false
        var editable = true
    }

    /// 给助手的清单：插槽全列（同 Prompt 页顺序）+ 七个楼层字段全列——空着的字段也在，能往里写
    @MainActor
    static func files(profileId: String) -> [File] {
        guard let profile = profiles?.profiles.first(where: { $0.id == profileId }) else { return [] }
        let entries = PromptFolder.entries(profile: profile, presets: presets?.presets ?? [])
        var out = entries.filter { if case .slot = $0.source { return true } else { return false } }.map { e in
            File(path: e.path, content: e.content,
                 note: "插槽「\(e.name.isEmpty ? "未命名插槽" : e.name)」· \(e.isEnabled == false ? "关着" : "开着")\(e.isEditable ? "" : " · 系统自动填充，只读")",
                 editable: e.isEditable)
        }
        for field in PromptFolder.Field.allCases {
            out.append(File(path: PromptFolder.path(for: .field(field)), content: profile[keyPath: field.keyPath], note: "楼层字段「\(field.label)」"))
        }
        return out
    }

    static func listLine(_ file: File) -> String {
        "\(file.path)  (\(file.content.utf8.count)B)  \(file.note)"
    }

    /// 这一段的版本历史：插槽和 Prompt 页插槽编辑页同一个 key；楼层字段按属性名（系统指令那一个和楼层编辑页同一个 key）
    static func versionKey(_ source: PromptFolder.Source, profileId: String) -> FileVersionStore.Key {
        switch source {
        case .slot(let presetId, let slotId): return PromptSlotEditing.key(profileId: profileId, presetId: presetId, slotId: slotId)
        case .field(let field): return .virtual("floor/\(profileId)/\(field.rawValue)", profileId: profileId)
        }
    }

    static func versionKey(path: String, profileId: String) -> FileVersionStore.Key? {
        PromptFolder.source(of: path).map { versionKey($0, profileId: profileId) }
    }

    private static func fail(_ text: String) -> FileLibraryTools.Result { .init(text: text, isError: true) }

    /// fs_write / fs_append / fs_edit 写一段。`actor` = 记进版本历史的名字（助手名 /「CC 里的助手名」）
    @MainActor
    static func write(tool: FileLibraryTools.Name, args: [String: Any], profileId: String, actor: String) async -> FileLibraryTools.Result {
        let strings = args.compactMapValues { $0 as? String }
        let path = (strings[tool == .rename ? "old_path" : "path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard [.write, .append, .edit].contains(tool) else {
            return fail("Prompt 文件夹里的条目不能用文件工具删、改名或挪位置：新建 / 删除 / 开关插槽要对方在 Prompt 页做。能做的是改一段的正文（fs_write / fs_edit / fs_append）。")
        }
        guard let profiles, let presets else { return fail("花园还没准备好（Prompt 读不到），这次没改成。") }
        guard let source = PromptFolder.source(of: path), let file = files(profileId: profileId).first(where: { $0.path == path }) else {
            return fail("没有这个文件: \(path)。Prompt 文件夹里只能改已有的条目，先 fs_list 看 \(PromptFolder.root)/ 下有哪些。")
        }
        do {
            let text = try MemoryFolderWrite.newText(tool: tool, args: strings, current: file.content, path: path)
            guard text != file.content else { return .init(text: "没有变化：写的和这一段现在的一样", isError: false) }
            try PromptFolder.save(path, text: text, baseline: file.content, profileId: profileId, profiles: profiles, presets: presets)
            let key = versionKey(source, profileId: profileId)
            _ = try? await versionStore.record(key: key, content: file.content, source: .external)
            _ = try? await versionStore.record(key: key, content: text, source: .external, actor: actor)
            NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
            return .init(text: FileLibraryTools.fileChangeResult(title: "已修改", path: path, before: file.content, after: text)
                + "\n\(file.note) 改好了。从对方的下一条消息起生效（这一轮你带着的还是改之前的那份）。改之前的样子存进了这一段的版本历史，对方能回到上一版。", isError: false)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static let detailLength = 60

    private static func head(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return line.isEmpty ? "（空）" : (line.count > detailLength ? String(line.prefix(detailLength)) + "…" : line)
    }

    /// 审批卡上多出的一行：改的是哪一段、现在的开头、要写成的开头
    @MainActor
    static func permissionDetail(toolName: String, argumentsJSON: String, profileId: String) -> String? {
        guard let tool = FileLibraryTools.Name(rawValue: toolName) else { return nil }
        let args = ((try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let path = (args[tool == .rename ? "old_path" : "path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let file = files(profileId: profileId).first(where: { $0.path == path }) else { return "Prompt 文件夹里没有这一份：\(path)" }
        guard let text = try? MemoryFolderWrite.newText(tool: tool, args: args, current: file.content, path: path) else { return "要改的是\(file.note)" }
        return "要改的是\(file.note)。现在：「\(head(file.content))」→ 写成：「\(head(text))」"
    }
}
