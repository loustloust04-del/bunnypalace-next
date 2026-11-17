import Foundation

/// 条目的「详细度」（plan-card-detail-slider）：她在条目详情页点「简略 / 详细」（找不回写手原来那句时也点「适中」），
/// 照这条当时附近的原文把正文重写一遍。这里是纯逻辑：提示词、材料怎么排、解码；取材料 / 调模型 / 存记录 / 落库在 app 的 `CardDetailRewrite`。
/// 放在包里，memoryd 能用同一份
public enum CardDetail {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case brief, medium, detailed

        /// 界面上那一格的字（写手写出来的算适中）
        public var label: String {
            switch self {
            case .brief: return "简略"
            case .medium: return "适中"
            case .detailed: return "详细"
            }
        }

        /// 提示词开头那半句：她想要什么样的
        var ask: String {
            switch self {
            case .brief: return "更短，一句话。"
            case .medium: return "照常的写法，不长不短。"
            case .detailed: return "更详细，把当时的具体细节留下来。"
            }
        }

        func rules(user u: String) -> String {
            switch self {
            case .brief:
                return """
                「简略」的写法：
                - 一句话，只留这件事最要紧的那一点。
                - 短不等于没头没尾：是什么事、和谁有关、（要紧的话）什么时候，仍要写得出来，三个月后不翻原文也看得懂。
                - 不用引号留原话。
                - 一定比「现在的正文」短。原文后来改了口、现在的正文已经过时的，用改口后的说法，但仍只留最要紧的那一点，不把新旧都写进去。
                """
            case .medium:
                return """
                「适中」的写法：
                - 短句，每句一个信息点；一个事实加上它直接的因果。
                - 一句话说得清就写一句，最多四句。
                - \(u) 的原话值得留的用引号。
                """
            case .detailed:
                return """
                「详细」的写法：
                - 可以写好几句，不受平时「一条最多四句」的限制。
                - 留住原文里和这件事有关的具体细节：时间、地点、人、东西、数字、起因、后来怎样。
                - \(u) 当时怎么说的，值得留的用引号照原话写（一字不改，只引 \(u) 自己说过的）。
                - 仍然只写这一件事和直接相关的细节；不写成对话经过，不按先后复述谁说了什么。
                - 不灌水：原文里没有更多细节就不加，宁可短一点。
                """
            }
        }
    }

    /// 送去重写的一份
    public struct Material: Equatable, Sendable {
        public var windowTitle: String
        public var names: MemoryExtractor.Names
        public var subject: String?
        /// 这条现在的正文
        public var content: String
        /// 这条当时附近的原文
        public var lines: [FragmentVerdict.Line]
        /// 紧挨在前面的原文（只供看懂）；没有 = 空
        public var before: [FragmentVerdict.Line]
        /// 这条主要出自原文第几条（从 1 数）；不知道 = nil
        public var anchor: Int?

        public init(windowTitle: String, names: MemoryExtractor.Names, subject: String?, content: String,
                    lines: [FragmentVerdict.Line], before: [FragmentVerdict.Line] = [], anchor: Int? = nil) {
            self.windowTitle = windowTitle
            self.names = names
            self.subject = subject
            self.content = content
            self.lines = lines
            self.before = before
            self.anchor = anchor
        }
    }

    // MARK: - 提示词

    /// 固定的那一段说明（按档位不同只差中间那一块）
    public static func system(names: MemoryExtractor.Names, level: Level) -> String {
        let u = names.user
        let c = names.char
        return """
        你在重写一条记忆条目的正文。这条是从 \(u) 和 \(c) 的一段对话里记下来的，以后别的对话里的 \(c) 会读到它。
        \(u) 想把这条改成「\(level.label)」的写法：\(level.ask)

        材料（在下面的消息里）：
        1. 原文：这条出自的那段对话，一条一行，#1、#2…。「出自 #几」是这条主要出自的那一条。
        2. 前文（不一定有）：原文之前紧挨着的几条，编号 #0、#-1…。只供看懂指代和前因，不要从这里取事。
        3. 这条条目现在的样子：「关于」是这条说的是谁或什么，后面是现在的正文。

        规矩：
        - 只重写正文。「关于」不改，也不要把它写进正文开头：显示的时候会自动放在正文前面。
        - 还是说这一件事。不换成别的事，不把原文里不相干的事加进来。
        - 只写原文里有的。原文里找不到的细节、原因、感受、评价，一个字也不要补；拿不准的宁可不写。
        - 原文后来改口了，以最后的说法为准。
        - \(c) 的看法、建议、承诺，\(u) 没有明确认可的，不能写成 \(u) 的事；要留就写明是 \(c) 说的。
        - 不写悬空的指代：「这个窗口」写窗口名；「今天」「昨天」「刚才」「现在」「最近」「上个月」换成日期；「他」「她」「那件事」写清是谁、是什么。三个月后的读者不翻原文也要看得懂。
        - 不写「用户」「AI」「助手」，提到人写名字。
        - 不写对话经过：不写「\(u) 问了什么，\(c) 回了什么」。

        \(level.rules(user: u))

        例子（人和事都是编的；「关于」是 \(u)）：
        原文 #4 2026-03-08 21:10 · \(u)：上个月开始每个周末去槐序巷皮影作坊帮忙，跟岚舟学刻皮影。手被刻刀划了两回，不过还是想在星砚生日前刻完一套送她。
        现在的正文：每周末去槐序巷皮影作坊帮忙，跟岚舟学刻皮影。
        - 简略：周末在槐序巷皮影作坊跟岚舟学刻皮影。
        - 适中：2026 年 2 月起每周末去槐序巷皮影作坊帮忙，跟岚舟学刻皮影；想在星砚生日前刻完一套送她。
        - 详细：2026 年 2 月起每周末去槐序巷皮影作坊帮忙，跟岚舟学刻皮影。手被刻刀划过两回，还是想接着刻：「还是想在星砚生日前刻完一套送她」。
        ✗ 「\(u) 每周末去槐序巷皮影作坊……」← 「关于」已经是 \(u)，不要拼进正文
        ✗ 「最近在学刻皮影」← 「最近」离开当时就读不懂，写日期
        ✗ 「\(u) 说在学皮影，\(c) 问累不累」← 对话经过
        ✗ 「从小就喜欢皮影戏」← 原文里没有
        这次要的是「\(level.label)」那一种。

        只输出一个 JSON 对象，前后不要别的字：
        {"content":"……"}
        content 只写重写好的正文。
        """
    }

    private static func line(_ number: Int, _ line: FragmentVerdict.Line, names: MemoryExtractor.Names) -> String {
        "#\(number) \(line.at.map { $0 + " " } ?? "")· \(line.role == "user" ? names.user : names.char)：\(line.text.replacingOccurrences(of: "\n", with: " ⏎ "))"
    }

    /// 每次调用会变的：窗口名、前文、原文、这条现在的样子
    public static func user(_ material: Material, level: Level) -> String {
        let names = material.names
        let before = material.before.isEmpty ? "" : "## 前文（只供看懂，不要从这里取事）\n\n"
            + material.before.enumerated().map { line($0.offset - material.before.count + 1, $0.element, names: names) }.joined(separator: "\n")
            + "\n\n"
        let lines = material.lines.enumerated().map { line($0.offset + 1, $0.element, names: names) }.joined(separator: "\n")
        let anchor = material.anchor.map { "\n出自：#\($0)" } ?? ""
        return """
        这段对话所在的窗口叫「\(material.windowTitle)」。

        \(before)## 原文（#1–#\(material.lines.count)）

        \(lines)

        ## 这条条目

        关于：\(material.subject ?? "（没写）")\(anchor)
        现在的正文：\(material.content.replacingOccurrences(of: "\n", with: " ⏎ "))

        按「\(level.label)」的写法重写正文。
        """
    }

    // MARK: - 解码 / 跑一次

    /// 拿出重写好的正文。不是带非空 content 的 JSON 对象 → 抛（调用方重问一次）
    public static func decoded(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>"), let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let content = (object["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw MemoryWriterError.format("必须只输出一个 JSON 对象 {\"content\":\"……\"}，content 不能是空的")
        }
        return content
    }

    public static let retryNote = "\n\n（上一次交的不合格：必须只输出一个 JSON 对象 {\"content\":\"……\"}，content 是重写好的正文。重交。）"

    public struct Outcome: Equatable, Sendable {
        public var text: String
        /// 第一次交的格式不对，重问过一次
        public var retried: Bool
    }

    /// 一次调用，不带工具。格式不对重问一次，还不对 → 抛。caller 回 nil（预算闸）= nil
    public static func run(_ material: Material, level: Level, caller: SessionSegmentWriter.Caller) async throws -> Outcome? {
        let system = system(names: material.names, level: level)
        let user = user(material, level: level)
        guard let raw = try await caller(system, user) else { return nil }
        if let text = try? decoded(raw) { return Outcome(text: text, retried: false) }
        guard let retry = try await caller(system, user + retryNote) else { return nil }
        return Outcome(text: try decoded(retry), retried: true)
    }
}
