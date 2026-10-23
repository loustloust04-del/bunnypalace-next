import Foundation

/// 词条笔记：文件库 `vocab/<word>.md` + 图片附件 `vocab/img/<word>-*.<ext>`。
/// 全部薄封装 FileLibraryStore（路径防护/目录创建白拿）。笔记跟当前楼层文件库走——
/// 与 sourceBookRef 指楼层书籍同款边界；文件库面板可见可编辑，AI fs 工具现成可达。
enum VocabNoteStore {

    /// 词面里文件路径的危险字符换成 "-"（词组空格保留）。
    private static func safeName(_ word: String) -> String {
        word.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    static func notePath(word: String) -> String {
        "vocab/\(safeName(word)).md"
    }

    /// 不存在 → nil（区分"没写过"与"空笔记"）。
    static func readNote(word: String, profileId: String) -> String? {
        let path = notePath(word: word)
        guard FileLibraryStore.exists(path, profileId: profileId) else { return nil }
        return try? FileLibraryStore.read(path, profileId: profileId)
    }

    static func writeNote(word: String, content: String, profileId: String) throws {
        try FileLibraryStore.write(notePath(word: word), content: content, profileId: profileId)
    }

    /// 缺则建骨架，已有内容不覆盖（幂等）。
    /// seed：旧 VocabProgress.note 的 lazy 迁移入口（R2-2 笔记合并）——只在首次建档时写入。
    static func ensureNote(word: String, profileId: String, seed: String? = nil) {
        guard readNote(word: word, profileId: profileId) == nil else { return }
        var content = "# \(word)\n\n"
        if let seed = seed?.trimmingCharacters(in: .whitespacesAndNewlines), !seed.isEmpty {
            content += seed + "\n"
        }
        try? writeNote(word: word, content: content, profileId: profileId)
    }

    // MARK: - 图片附件

    static func imagePaths(word: String, profileId: String) -> [String] {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("VocabNoteStore.imagePaths") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        let prefix = "vocab/img/\(safeName(word))-"
        return FileLibraryStore.cachedList(profileId: profileId)
            .map(\.path)
            .filter { $0.hasPrefix(prefix) }
    }

    static func addImage(word: String, data: Data, ext: String, profileId: String) throws {
        let suffix = UUID().uuidString.prefix(8)
        let path = "vocab/img/\(safeName(word))-\(suffix).\(ext)"
        try FileLibraryStore.writeData(path, data: data, profileId: profileId)
    }

    static func imageData(path: String, profileId: String) -> Data? {
        try? FileLibraryStore.readData(path, profileId: profileId)
    }

    // MARK: - 双链

    /// `[[词]]` → `[词](vocabnote://open/<encoded>)`（渲染成链接，openURL 拦截跳词卡）。
    /// 纯函数（R2-3a 抽出可测）。
    static func linkifiedMarkdown(_ md: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#) else { return md }
        var result = ""
        var last = md.startIndex
        for m in regex.matches(in: md, range: NSRange(md.startIndex..., in: md)) {
            guard let full = Range(m.range, in: md),
                  let inner = Range(m.range(at: 1), in: md) else { continue }
            result += md[last..<full.lowerBound]
            let target = String(md[inner])
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            result += "[\(target)](vocabnote://open/\(encoded))"
            last = full.upperBound
        }
        result += md[last...]
        return result
    }
}
