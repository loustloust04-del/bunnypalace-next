import Foundation

// MARK: - 小芽 · 马克笔概念词（plan-onboarding-xiaoya-impl §12-E；小样 design-onboarding-xiaoya-v3.html 3 / 5）
// 台词表里写 [[楼层]]：渲染成一笔黄色马克笔；点马克笔词 / 灯泡列表词典里点一行 = 弹同一张释义 sheet（page1 思考过程同款 DisclosureSheet，里面是 page1 便利贴的线圈本）。
// 讲过哪些词、各自第一次在哪句话，记在 AssistantChat/glossary.json（跟 history.json 同目录 → 全局备份自动带上），词典排序用。
// 本期只管剧本台词；小芽模型实时回复里的词不标。

enum XiaoyaGlossary {
    struct Term: Equatable, Hashable, Identifiable {
        var word: String
        var definition: String

        var id: String { word }
    }

    /// 词表（唯一一处）：释义照 plan §12-E / 小样 DEF
    static let terms: [Term] = [
        Term(word: "楼层", definition: "一层住一位 Ta：Ta 的名字、记忆、对话都在这一层，换一层就换一位。"),
        Term(word: "API key", definition: "去 AI 公司领的「钥匙」，有了它 Ta 才能说话；只存在你手机的钥匙串里。"),
        Term(word: "模型", definition: "Ta 用的那颗「脑子」，同一把钥匙下可以换。"),
        Term(word: "记忆", definition: "Ta 自己从聊天里记下的小事，你随时能看、能删。"),
        Term(word: "gardenOS", definition: "记忆花园里放小 app 的那一页：桌面、日历、记忆、我都住在这儿；在聊天页往左划就到。"),
    ]

    static func term(_ word: String) -> Term? { terms.first { $0.word == word } }

    private static let marker = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#)

    /// 一句话里标了哪些词（按出现顺序，去重；不在词表里的也算——照样画马克笔，只是没有解释）
    static func words(in text: String) -> [String] {
        guard text.contains("[[") else { return [] }
        var seen = Set<String>()
        return marker.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { seen.insert($0).inserted }
    }

    /// 给 Markdown 渲染：[[词]] → **词**（马克笔另外按词画在底下）
    static func markdown(_ text: String) -> String {
        replace(text, with: "**$1**")
    }

    /// 纯文字：[[词]] → 词
    static func plain(_ text: String) -> String {
        replace(text, with: "$1")
    }

    private static func replace(_ text: String, with template: String) -> String {
        guard text.contains("[[") else { return text }
        return marker.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// 一句话切成段：普通 Markdown / 马克笔词（SwiftUI Text 拼马克笔用）
    enum Piece: Equatable {
        case text(String)
        case mark(String)
    }

    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var cursor = text.startIndex
        for m in marker.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text), let word = Range(m.range(at: 1), in: text) else { continue }
            if cursor < whole.lowerBound { out.append(.text(String(text[cursor..<whole.lowerBound]))) }
            out.append(.mark(String(text[word])))
            cursor = whole.upperBound
        }
        if cursor < text.endIndex { out.append(.text(String(text[cursor...]))) }
        return out
    }
}

/// glossary.json：展开过的词 + 跟在哪条消息下面（同一个词只记第一次）
struct XiaoyaGlossaryLog: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var word: String
        var messageId: UUID?
        var at: Date

        private enum CodingKeys: String, CodingKey { case word, messageId, at }

        init(word: String, messageId: UUID?, at: Date) {
            self.word = word
            self.messageId = messageId
            self.at = at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            word = try c.decodeIfPresent(String.self, forKey: .word) ?? ""
            messageId = try? c.decodeIfPresent(UUID.self, forKey: .messageId)
            at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? Date()
        }
    }

    var entries: [Entry] = []

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = ((try? c.decodeIfPresent([Entry].self, forKey: .entries)) ?? []).filter { !$0.word.isEmpty }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// 一句话说出来了：词表里、还没展开过的词记下来（跟在这条消息下面）。返回新展开的词
    mutating func record(_ text: String, messageId: UUID?, at date: Date = Date()) -> [String] {
        let fresh = XiaoyaGlossary.words(in: text).filter { word in
            XiaoyaGlossary.term(word) != nil && !entries.contains { $0.word == word }
        }
        entries += fresh.map { Entry(word: $0, messageId: messageId, at: date) }
        return fresh
    }

    /// 这条消息下面要跟的解释
    func terms(for messageId: UUID) -> [XiaoyaGlossary.Term] {
        entries.filter { $0.messageId == messageId }.compactMap { XiaoyaGlossary.term($0.word) }
    }

    /// 展开过的词：按展开的先后
    var terms: [XiaoyaGlossary.Term] { entries.compactMap { XiaoyaGlossary.term($0.word) } }

    struct DictionaryEntry: Equatable {
        var term: XiaoyaGlossary.Term
        var spoken: Bool
    }

    /// 灯泡列表「词典」组：词表里的词一直全列；小芽讲过的按先后排前面
    var dictionary: [DictionaryEntry] {
        let spoken = terms
        return spoken.map { DictionaryEntry(term: $0, spoken: true) }
            + XiaoyaGlossary.terms.filter { !spoken.contains($0) }.map { DictionaryEntry(term: $0, spoken: false) }
    }
}

struct XiaoyaGlossaryStore: Sendable {
    let fileURL: URL

    /// 跟 history.json 放同一个目录
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("glossary.json")
    }

    func load() -> XiaoyaGlossaryLog {
        guard let data = try? Data(contentsOf: fileURL) else { return XiaoyaGlossaryLog() }
        do {
            return try JSONDecoder().decode(XiaoyaGlossaryLog.self, from: data)
        } catch {
            // 同 tips.json：解不开挪开留底（备份导出会跳过 corrupt），当没展开过
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json"))
            return XiaoyaGlossaryLog()
        }
    }

    func save(_ log: XiaoyaGlossaryLog) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
