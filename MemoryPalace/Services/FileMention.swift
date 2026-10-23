import Foundation

/// 输入框「@ 文件库文件」+ 附件面板「最近文件」的数据口径（plan-input-file-mention）。
/// 清单同 system prompt 文件清单：跳过 books/，日记闸关时不出 journal/；只比名字不比正文。
enum FileMention {
    typealias FileMeta = FileLibraryStore.FileMeta

    static let maxQueryLength = 40
    static let suggestionLimit = 5
    static let recentLimit = 12
    private static let skippedTopLevelDirs: Set<String> = ["books"]

    // MARK: - 纯函数

    /// 文字**末尾**的 @token（不含 @）。单打 `@`、token 里有空白、`a@b` 这种邮箱写法都返回 nil。
    /// 只往回扫 token 长度那么远，长文每键调也不贵（iOS 提交点 10 每键都问）。
    static func query(in text: String) -> String? {
        var i = text.endIndex
        var count = 0
        while i > text.startIndex {
            let j = text.index(before: i)
            let c = text[j]
            if c == "@" {
                guard count > 0 else { return nil }
                if j > text.startIndex, isEmailLocalChar(text[text.index(before: j)]) { return nil }
                return String(text[i...])
            }
            if c.isWhitespace { return nil }
            count += 1
            if count > maxQueryLength { return nil }
            i = j
        }
        return nil
    }

    /// 选中候选后：把末尾的「@token」删掉（没有就原样）
    static func removingQuery(from text: String) -> String {
        guard let q = query(in: text) else { return text }
        return String(text.dropLast(q.count + 1))
    }

    /// 名字开头 > 名字含 > 文件夹名含；同档新的在前，再按路径定序。`limit` nil = 全要（选择 sheet 用）
    static func rank(_ files: [FileMeta], query: String, limit: Int? = suggestionLimit) -> [FileMeta] {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        let hits = files.compactMap { f -> (tier: Int, file: FileMeta)? in
            let name = fold((f.path as NSString).lastPathComponent)
            if name.hasPrefix(q) { return (0, f) }
            if name.contains(q) { return (1, f) }
            if fold((f.path as NSString).deletingLastPathComponent).contains(q) { return (2, f) }
            return nil
        }
        let sorted = hits.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            return newerFirst(a.file, b.file)
        }.map(\.file)
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    static func recent(_ files: [FileMeta], limit: Int? = recentLimit) -> [FileMeta] {
        let sorted = files.sorted(by: newerFirst)
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    private static func newerFirst(_ a: FileMeta, _ b: FileMeta) -> Bool {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
        return a.path < b.path
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isEmailLocalChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "._%+-".contains(c))
    }

    // MARK: - 后台

    /// @ 候选：取清单 + 排名都在后台（缓存冷时会真枚举，不能在主线程）
    static func suggestions(for query: String, profileId: String) async -> [FileMeta] {
        await background(profileId) { rank($0, query: query) }
    }

    /// 选择 sheet 用：全部可 @ 的文件，新的在前
    static func allFiles(profileId: String) async -> [FileMeta] {
        await background(profileId) { recent($0, limit: nil) }
    }

    static func recentFiles(profileId: String) async -> [FileMeta] {
        await background(profileId) { recent($0) }
    }

    private static func background(_ profileId: String, _ body: @escaping @Sendable ([FileMeta]) -> [FileMeta]) async -> [FileMeta] {
        guard !profileId.isEmpty else { return [] }
        let journalVisible = CalendarPrivacy().journalVisible(profileId)
        return await Task.detached(priority: .userInitiated) {
            body(FileLibraryStore.cachedList(profileId: profileId, skippingTopLevelDirs: skippedTopLevelDirs)
                .filter { FileLibraryAccess.listedVisible($0.path, journalVisible: journalVisible) })
        }.value
    }

    /// 附件条身份：对话 + 编辑中那条。后台抽取回来前它变了（切对话 / 进出编辑），结果不往新附件条里塞
    @MainActor
    static func composerKey(_ viewModel: ConversationViewModel) -> String {
        "\(viewModel.selectedConversation.map { String(describing: $0.id) } ?? "-")|\(viewModel.editingMessage?.token.uuidString ?? "-")"
    }

    /// 文件库文件 → 附件：和📎同一条 `AttachmentTextExtractor`，发那一刻的快照。失败按「文件名：原因」汇总
    static func attach(paths: [String], profileId: String) async -> (attachments: [PendingChatAttachment], failures: [String]) {
        await Task.detached(priority: .userInitiated) {
            var out: [PendingChatAttachment] = []
            var failures: [String] = []
            for path in paths {
                let name = (path as NSString).lastPathComponent
                guard let url = FileLibraryStore.absoluteURL(path, profileId: profileId) else {
                    failures.append("\(name)：文件不在了")
                    continue
                }
                do {
                    out.append(try AttachmentTextExtractor.extract(from: url))
                } catch {
                    failures.append("\(name)：\(error.localizedDescription)")
                }
            }
            return (out, failures)
        }.value
    }
}
