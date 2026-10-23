#if PERSONAL_APPS
import Foundation

/// 标的笔记：文件库 `trading/<symbol>.md` + 图片附件 `trading/img/<symbol>-*.<ext>`。
/// VocabNoteStore 同构薄封装（文件库面板可见可编辑，AI fs 工具现成可达）。
/// 研究记录（axismundi 研报）在 `trading/<symbol>/` 目录，见 TradingStore.reports。
enum TradingNoteStore {

    static func notePath(symbol: String) -> String {
        "trading/\(symbol).md"
    }

    /// 不存在 → nil（区分"没写过"与"空笔记"）。
    static func readNote(symbol: String, profileId: String) -> String? {
        let path = notePath(symbol: symbol)
        guard FileLibraryStore.exists(path, profileId: profileId) else { return nil }
        return try? FileLibraryStore.read(path, profileId: profileId)
    }

    static func writeNote(symbol: String, content: String, profileId: String) throws {
        try FileLibraryStore.write(notePath(symbol: symbol), content: content, profileId: profileId)
    }

    /// 缺则建骨架，已有内容不覆盖（幂等）。
    static func ensureNote(symbol: String, profileId: String) {
        guard readNote(symbol: symbol, profileId: profileId) == nil else { return }
        try? writeNote(symbol: symbol, content: "# $\(symbol)\n\n", profileId: profileId)
    }

    // MARK: - 图片附件

    static func imagePaths(symbol: String, profileId: String) -> [String] {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("TradingNoteStore.imagePaths") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        let prefix = "trading/img/\(symbol)-"
        return FileLibraryStore.cachedList(profileId: profileId)
            .map(\.path)
            .filter { $0.hasPrefix(prefix) }
    }

    static func addImage(symbol: String, data: Data, ext: String, profileId: String) throws {
        let suffix = UUID().uuidString.prefix(8)
        let path = "trading/img/\(symbol)-\(suffix).\(ext)"
        try FileLibraryStore.writeData(path, data: data, profileId: profileId)
    }

    static func imageData(path: String, profileId: String) -> Data? {
        try? FileLibraryStore.readData(path, profileId: profileId)
    }

    // MARK: - 双链

    /// `[[X]]` → `[X](tickernote://open/<encoded>)`。消费端按 X 形态分流：
    /// 全大写 1-5 位 → 标的档案；其他 → 词卡（交易笔记里也能连生词）。
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
            result += "[\(target)](tickernote://open/\(encoded))"
            last = full.upperBound
        }
        result += md[last...]
        return result
    }

    /// [[双链]] 目标是不是标的（全大写 1-5 位）。
    static func isTickerTarget(_ target: String) -> Bool {
        (1...5).contains(target.count) && target.allSatisfy { $0.isUppercase && $0.isLetter }
    }
}
#endif
