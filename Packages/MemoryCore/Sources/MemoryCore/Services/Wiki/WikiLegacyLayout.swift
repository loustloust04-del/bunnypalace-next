import Foundation

/// 旧摆法搬家：10-23 根压平（2dffe30f7）之前页放在 `楼层/<组>/…/<页>.md`，那一单没迁移，现在第一段只认 `branches`，
/// 留在旧位置的页谁都不认（聊天带不进、整理看不到、索引是空的）。这里把它们搬到现在的位置，一次性、可重跑。
/// 同步文件 IO，调用方放后台、持同楼层写锁
extension WikiStore {
    /// 2dffe30f7 之前 wiki 根下的两支之一（另一支「工程」现在还是组）
    public static let legacyFloorFolder = "楼层"

    public struct LegacyRelocation: Equatable, Sendable {
        /// 没搬的原因（rawValue 就是写进记忆日志的类别）
        public enum Skip: String, CaseIterable, Sendable {
            case targetExists = "现在的位置已有同名页"
            case unknownGroup = "认不出该放哪一组"
            case invalidPath = "名字不合现在的规矩"
            case failed = "读写出错"
        }

        public var moved = 0
        public var skipped: [Skip: Int] = [:]
        public var removedFolders = 0
        public var indexFailed = false

        public init() {}

        /// 记忆日志那一行：只写数量和原因类别，不带页名；什么都没搬 = nil（不记）
        public var logNote: String? {
            guard moved > 0 else { return nil }
            var note = "wiki 旧位置的 \(moved) 页搬到了现在的位置"
            let left = Skip.allCases.compactMap { reason in skipped[reason].map { "\(reason.rawValue) \($0)" } }
            if !left.isEmpty { note += "；\(skipped.values.reduce(0, +)) 页没搬（\(left.joined(separator: "、"))）" }
            if indexFailed { note += "；索引没重建成" }
            return note
        }
    }

    /// 旧摆法 `楼层/<group>/…` 的那一段对到现在哪一组：本来就是 9 组之一 → 它自己；当前用户名 / 「用户」→ 本人那组；别的不猜
    public static func legacyBranch(_ group: String, user: String) -> String? {
        if branches.contains(group) { return group }
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return group == WikiPage.Kind.user.rawValue || (!name.isEmpty && group == name) ? userBranch : nil
    }

    /// 页里的旧连线 `[[楼层/<组>/…]]` 按 `legacyBranch` 换成现在的路径；对不上组的原样留着
    public static func relocatingLegacyLinks(_ text: String, user: String) -> String {
        let lead = "[[" + legacyFloorFolder + "/"
        var out = ""
        var rest = text[...]
        while let hit = rest.range(of: lead) {
            let after = rest[hit.upperBound...]
            let end = after.firstIndex(where: { "/]|#\n".contains($0) }) ?? after.endIndex
            out += rest[..<hit.lowerBound]
            if let branch = legacyBranch(String(after[..<end]), user: user) { out += "[[" + branch } else { out += rest[hit.lowerBound..<end] }
            rest = after[end...]
        }
        return out + rest
    }

    public var hasLegacyLayout: Bool {
        (try? SafeWiki.folder([Self.legacyFloorFolder], under: root, create: false)) != nil
    }

    /// 没有旧文件夹（或它是链接）= 什么都不做、不写。隐藏的（`.history` / `.proposals` / 点开头的）一律不碰
    @discardableResult
    public func relocateLegacyLayout(user: String) -> LegacyRelocation {
        MainThreadIO.assertOffMain(.write, "WikiStore.relocateLegacyLayout")
        var result = LegacyRelocation()
        guard let legacy = try? SafeWiki.folder([Self.legacyFloorFolder], under: root, create: false) else { return result }
        var pages: [[String]] = []
        var folders: [[String]] = []
        legacyTree(legacy, [], pages: &pages, folders: &folders)

        var movedFrom = Set<[String]>()
        for parts in pages {
            switch relocateLegacyPage(parts, user: user) {
            case nil:
                result.moved += 1
                for depth in 1..<parts.count { movedFrom.insert(Array(parts[..<depth])) }
            case let reason?:
                result.skipped[reason, default: 0] += 1
            }
        }
        // 分组钩子跟着页走：新位置那个分组还没有钩子才带过去
        for parts in folders where movedFrom.contains(parts) {
            guard let branch = Self.legacyBranch(parts[0], user: user) else { continue }
            let old = folderURL(([Self.legacyFloorFolder] + parts).joined(separator: "/")).appendingPathComponent(Self.groupFileName)
            let new = ([branch] + parts.dropFirst()).joined(separator: "/")
            guard SafeWiki.isPlainFile(old), let hook = groupHook(([Self.legacyFloorFolder] + parts).joined(separator: "/")),
                  folderExists(new), groupHook(new) == nil else { continue }
            try? setGroupHook(new, hook: hook)
        }
        // 从深到浅：只剩代码生成的（INDEX.md / .group.md）的文件夹连它们一起删；还有没搬的页 / 别的东西就整个留着
        let generated = [Self.indexFileName, Self.groupFileName]
        for parts in folders.reversed() {
            let dir = parts.reduce(legacy) { $0.appendingPathComponent($1, isDirectory: true) }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                  names.allSatisfy({ generated.contains($0) && SafeWiki.isPlainFile(dir.appendingPathComponent($0)) }) else { continue }
            for name in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
            if rmdir(dir.path) == 0 { result.removedFolders += 1 }
        }
        if result.moved > 0 || result.removedFolders > 0 {
            do { try rebuildAllIndexes() } catch { result.indexFailed = true }
        }
        return result
    }

    /// 旧文件夹里真实的页和文件夹（lstat，不跟链接；点开头的不看）。`parts` 相对「楼层」，页的最后一段带 .md；文件夹浅的在前
    private func legacyTree(_ dir: URL, _ parts: [String], pages: inout [[String]], folders: inout [[String]]) {
        folders.append(parts)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            switch try? SafeWiki.itemType(url) {
            case .typeDirectory?: legacyTree(url, parts + [name], pages: &pages, folders: &folders)
            case .typeRegular? where name.hasSuffix(".md") && name != Self.indexFileName: pages.append(parts + [name])
            default: continue
            }
        }
    }

    /// 搬一页：读原文 → 换旧连线 → 写到新位置（已有同名页不覆盖）→ 写成了才删旧的。nil = 搬了
    private func relocateLegacyPage(_ parts: [String], user: String) -> LegacyRelocation.Skip? {
        guard parts.count >= 2, let branch = Self.legacyBranch(parts[0], user: user) else { return .unknownGroup }
        let path = String(([branch] + parts.dropFirst()).joined(separator: "/").dropLast(3))
        guard Self.isValidPagePath(path) else { return .invalidPath }
        do {
            let old = try SafeWiki.file(parts[parts.count - 1], in: SafeWiki.folder([Self.legacyFloorFolder] + parts.dropLast(), under: root, create: false))
            guard let text = String(data: try Data(contentsOf: old), encoding: .utf8) else { return .failed }
            let moved = Self.relocatingLegacyLinks(text, user: user)
            let new = path.split(separator: "/").map(String.init)
            let target = try SafeWiki.file(new[new.count - 1] + ".md", in: SafeWiki.folder(Array(new.dropLast()), under: root, create: true))
            if try SafeWiki.itemType(target) != nil {
                // 上次写好了新的、没来得及删旧的：内容一样只补删
                guard (try? Data(contentsOf: target)) == Data(moved.utf8) else { return .targetExists }
            } else {
                try saveRaw(moved, path: path, recordingHistory: false)
            }
            try FileManager.default.removeItem(at: old)
            return nil
        } catch {
            return .failed
        }
    }
}
