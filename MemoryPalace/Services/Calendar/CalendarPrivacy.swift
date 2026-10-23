import Foundation

// MARK: - 日历隐私（plan-calendar §四，astra #5 #6 #7 #8）
// 按楼层的开关（不用全局 PermissionCenter）。三件事分开：
// 能不能读（日记闸）/ 会不会被注入（两个注入开关）/ 能不能写（AI 永远不能直接写 journal/ 与 calendar/）。
// 边界：只管记忆花园自己的文件工具；终端 / CC / MCP 是另一个更大的权限，首版不封（设置页写清楚）。

struct CalendarPrivacy {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func journalVisibleKey(_ pid: String) -> String { "calendar.journalAIVisible.\(pid)" }
    static func injectTodayJournalKey(_ pid: String) -> String { "calendar.injectTodayJournal.\(pid)" }
    static func anniversaryInjectKey(_ pid: String) -> String { "calendar.anniversaryInject.\(pid)" }

    /// 小克能用文件工具读到我的日记（默认关）
    func journalVisible(_ pid: String) -> Bool { defaults.bool(forKey: Self.journalVisibleKey(pid)) }
    func setJournalVisible(_ on: Bool, _ pid: String) { defaults.set(on, forKey: Self.journalVisibleKey(pid)) }

    /// 把今天的日记告诉小克（默认关）
    func injectTodayJournal(_ pid: String) -> Bool { defaults.bool(forKey: Self.injectTodayJournalKey(pid)) }
    func setInjectTodayJournal(_ on: Bool, _ pid: String) { defaults.set(on, forKey: Self.injectTodayJournalKey(pid)) }

    /// 快到的纪念日告诉小克（默认开；每条纪念日自己还有 remindDays）
    func anniversaryInject(_ pid: String) -> Bool {
        defaults.object(forKey: Self.anniversaryInjectKey(pid)) as? Bool ?? true
    }
    func setAnniversaryInject(_ on: Bool, _ pid: String) { defaults.set(on, forKey: Self.anniversaryInjectKey(pid)) }
}

/// 文件库「规范化后」的统一授权：工具 / 列表 / 搜索 / 全文回注都走这里。
enum FileLibraryAccess {
    enum Op { case read, write }

    enum Zone: String { case journal, calendar }

    /// 规范化 + 解符号链接之后，看它落在库根的哪个受保护文件夹里（第一段，不分大小写——APFS 默认不区分）。
    /// 和 FileLibraryStore.resolve 同一套解析（先解 symlink 再判 containment）。
    static func zone(of relPath: String, root: URL) -> Zone? {
        MainThreadIO.assertOffMain(.stat, "FileLibraryAccess.zone")
        let trimmed = relPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = canonical(base.appendingPathComponent(trimmed).standardizedFileURL)
        let rootPath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard target.path.hasPrefix(rootPath) else { return nil }
        let first = target.path.dropFirst(rootPath.count).split(separator: "/").first.map { $0.lowercased() }
        return first.flatMap(Zone.init(rawValue:))
    }

    /// 解符号链接：`resolvingSymlinksInPath` 对不存在的路径原样返回，中间的链接也不解——
    /// 那样「经链接往 journal/ 里新建文件」就绕过去了。所以先解最深的真实存在的上级，再拼回剩下的部分。
    static func canonical(_ url: URL) -> URL {
        MainThreadIO.assertOffMain(.stat, "FileLibraryAccess.canonical")
        var existing = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for c in tail { resolved.appendPathComponent(c) }
        return resolved.standardizedFileURL
    }

    /// nil = 放行；否则是给模型的拒绝文案。`root` 只给测试传临时目录。
    static func denial(_ op: Op, path: String, profileId: String, root: URL? = nil,
                       privacy: CalendarPrivacy = CalendarPrivacy()) -> String? {
        guard let zone = zone(of: path, root: root ?? FileLibraryStore.libraryRoot(profileId: profileId)) else { return nil }
        switch (zone, op) {
        case (.journal, .read):
            return privacy.journalVisible(profileId) ? nil : "找不到文件：\(path)"
        case (.journal, .write):
            return privacy.journalVisible(profileId)
                ? "journal/ 是用户自己写的日记，你只能读，不能改动或移动。"
                : "这个位置不能写入：\(path)"
        case (.calendar, .read):
            return nil
        case (.calendar, .write):
            return "calendar/ 是日历数据，只读。要记纪念日，用 anniversary 块（见说明）。"
        }
    }

    /// 文件库清单（`FileLibraryStore.list` 枚举出来的）专用：枚举不进符号链接目录、只收普通文件，路径已经是库根下的真实路径，
    /// 所以只看首段，不再逐个规范化 / 解链接。规则同 `denial(.read)`：journal/ 看日记闸，calendar/ 可读。
    /// 模型给的路径（工具参数、历史里的调用）不能用这个，走 `visible`。
    static func listedVisible(_ path: String, journalVisible: Bool) -> Bool {
        guard !journalVisible else { return true }
        let first = path.split(separator: "/", maxSplits: 1).first.map { $0.lowercased() }
        return first != Zone.journal.rawValue
    }

    /// 列表 / 搜索 / 回注用：这个路径 AI 能不能看到。
    static func visible(_ path: String, profileId: String, root: URL? = nil, privacy: CalendarPrivacy = CalendarPrivacy()) -> Bool {
        denial(.read, path: path, profileId: profileId, root: root, privacy: privacy) == nil
    }
}
