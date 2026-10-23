import Foundation

/// 通话流式朗读闸（plan-voice-providers V4a）：吃 LLM 流式 delta，只放出「能念」的整句。
///
/// 三层，全部按 Character 走（emoji / 合字不会被切开）：
/// 1. 区域状态机：挡住 ``` 代码块（含 ```voice / ```book-note）、`<thinking>` / `<think>` / `[thinking]`；
///    标记被 delta 切开时，尾巴里可能是半个标记的那几个字先扣着。
/// 2. 构造扣留：没收口的链接 / 图片 / 裸网址 / 行首 markdown 前缀先扣着，收口了再清洗（清洗只吃完整构造，对半截安全）。
/// 3. 断句：放到最后一个句末（。！？…；换行，半角 !?;. 后面得跟空白）为止，句末后的收尾引号 / 括号跟着走；
///    超长无标点 > `hardLimit` 字硬切。
///
/// `flush()` 在工具边界 / 回复结束时吐尾巴（还在代码块、思考里的直接丢）并复位。
struct StreamSpeechGate {
    static let hardLimit = 220
    /// 硬切时优先在这个位置之后找逗号 / 空白
    static let softCutMin = 40
    /// 没收口的构造最多扣这么多字，超了当普通文字放
    static let holdLimit = 300

    private enum Zone: Equatable {
        case speech
        case fence
        case thinking(closer: String)
    }

    private static let openers: [(marker: String, zone: Zone)] = [
        ("```", .fence),
        ("<thinking>", .thinking(closer: "</thinking>")),
        ("<think>", .thinking(closer: "</think>")),
        ("[thinking]", .thinking(closer: "[/thinking]")),
    ]

    private var zone: Zone = .speech
    /// 还没判定区域的原文（尾巴可能是半个标记）
    private var raw = ""
    /// 安全区原文，等构造收口
    private var safe = ""
    /// 已清洗、等句末
    private var clean = ""
    /// `safe` 开头是否在行首（行首前缀清洗用）
    private var safeAtLineStart = true

    init() {}

    /// 喂一段 delta，返回这次能念的句子（可能为空）
    mutating func feed(_ delta: String) -> [String] {
        raw += delta
        scanZones(final: false)
        promoteSafe(final: false)
        return releaseSentences(final: false)
    }

    /// 段落结束：吐出剩下能念的，丢掉还在代码块 / 思考里的，复位
    mutating func flush() -> [String] {
        scanZones(final: true)
        promoteSafe(final: true)
        let out = releaseSentences(final: true)
        reset()
        return out
    }

    mutating func reset() {
        zone = .speech
        raw = ""
        safe = ""
        clean = ""
        safeAtLineStart = true
    }

    // MARK: - 1. 区域

    private mutating func scanZones(final: Bool) {
        while !raw.isEmpty {
            switch zone {
            case .speech:
                if let (range, next) = earliestOpener(in: raw) {
                    safe += raw[..<range.lowerBound]
                    safe += "\n"   // 隐藏区打断句子：前面的话可以先念
                    raw = String(raw[range.upperBound...])
                    zone = next
                    continue
                }
                if final {
                    safe += raw
                    raw = ""
                } else {
                    let hold = Self.partialMarkerSuffix(raw, markers: Self.openers.map(\.marker))
                    safe += raw.dropLast(hold)
                    raw = String(raw.suffix(hold))
                }
                return
            case .fence, .thinking:
                let closer: String
                if case .thinking(let c) = zone { closer = c } else { closer = "```" }
                if let range = raw.range(of: closer, options: .caseInsensitive) {
                    raw = String(raw[range.upperBound...])
                    zone = .speech
                    continue
                }
                if final {
                    raw = ""
                } else {
                    let hold = Self.partialMarkerSuffix(raw, markers: [closer])
                    raw = String(raw.suffix(hold))
                }
                return
            }
        }
    }

    private func earliestOpener(in text: String) -> (Range<String.Index>, Zone)? {
        var best: (Range<String.Index>, Zone)?
        for (marker, zone) in Self.openers {
            guard let r = text.range(of: marker, options: .caseInsensitive) else { continue }
            if best == nil || r.lowerBound < best!.0.lowerBound { best = (r, zone) }
        }
        return best
    }

    /// 尾巴最长有几个字是某个标记的真前缀（这几个字先扣着等下一段）
    static func partialMarkerSuffix(_ text: String, markers: [String]) -> Int {
        let tail = Array(text.suffix(12))
        var best = 0
        for marker in markers {
            let m = Array(marker.lowercased())
            let upper = min(m.count - 1, tail.count)
            guard upper > 0 else { continue }
            for k in stride(from: upper, through: 1, by: -1) where k > best {
                let suffix = String(tail.suffix(k)).lowercased()
                if suffix == String(m.prefix(k)) {
                    best = k
                    break
                }
            }
        }
        return best
    }

    // MARK: - 2. 构造扣留 + 清洗

    private mutating func promoteSafe(final: Bool) {
        guard !safe.isEmpty else { return }
        var stableEnd = safe.endIndex
        if !final, let holdFrom = Self.unclosedConstructStart(safe, atLineStart: safeAtLineStart),
           safe.distance(from: holdFrom, to: safe.endIndex) <= Self.holdLimit {
            stableEnd = holdFrom
        }
        guard stableEnd > safe.startIndex else { return }
        let stable = String(safe[..<stableEnd])
        clean += Self.cleanChunk(stable, atLineStart: safeAtLineStart)
        safeAtLineStart = stable.last == "\n"
        safe = String(safe[stableEnd...])
    }

    /// 没收口的构造从哪开始：`[` / `![` 链接图片、`](` 网址、裸 http(s) 网址、行首只有 markdown 前缀的半行
    static func unclosedConstructStart(_ text: String, atLineStart: Bool) -> String.Index? {
        var candidates: [String.Index] = []

        // 链接 / 图片：最后一个 `[` 之后没有完整的 `](…)`，或 `]` 后面还看不出是不是 `(`
        if let open = text.lastIndex(of: "[") {
            let after = text[open...]
            if let close = after.firstIndex(of: "]") {
                let rest = text[text.index(after: close)...]
                if rest.isEmpty {
                    candidates.append(open)
                } else if rest.first == "(", !rest.contains(")") {
                    candidates.append(open)
                }
            } else {
                candidates.append(open)
            }
            if open > text.startIndex, text[text.index(before: open)] == "!", let last = candidates.last, last == open {
                candidates[candidates.count - 1] = text.index(before: open)
            }
        }
        // 结尾的 `!` 可能是图片开头
        if text.last == "!" { candidates.append(text.index(before: text.endIndex)) }

        // 裸网址一直延到结尾（网址还没写完）
        if let r = text.range(of: #"https?://[A-Za-z0-9\-._~:/?#@!$&'*+,;=%]*$"#, options: .regularExpression) {
            candidates.append(r.lowerBound)
        } else if let r = text.range(of: #"(?:h|ht|htt|https?|https?:|https?:/)$"#, options: .regularExpression),
                  r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isASCIILetterOrDigit {
            candidates.append(r.lowerBound)
        }

        // 最后一行只有空白 / markdown 前缀（`#` `>` `-` `+` `*` 序号），等这行有正文再清洗
        let lineStart: String.Index? = {
            if let nl = text.lastIndex(of: "\n") { return text.index(after: nl) }
            return atLineStart ? text.startIndex : nil
        }()
        if let lineStart {
            let line = text[lineStart...]
            if line.allSatisfy({ " \t#>-+*.0123456789".contains($0) }) { candidates.append(lineStart) }
        }
        return candidates.min()
    }

    private static let cleanRules: [(String, String)] = [
        (#"!\[[^\]\n]*\]\([^)\n]*\)"#, ""),                      // 图片整个去
        (#"\[([^\]\n]+)\]\([^)\n]*\)"#, "$1"),                    // 链接留字
        (#"https?://[A-Za-z0-9\-._~:/?#@!$&'*+,;=%]+"#, ""), // 裸网址不念
        (#"(?m)^[ \t]*(?:#{1,6}|>+|[-+*])[ \t]+"#, ""),            // 行首标题 / 引用 / 列表符
        (#"(?m)^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#, ""),        // 分隔线
        (#"[`*_~#]"#, ""),                                        // 强调 / 行内代码符号
        (#"\|"#, " "),                                            // 表格竖线
        (#"[ \t\u{3000}]+"#, " "),                                // 压空白（换行留着当句末）
    ]

    /// 只吃完整构造。`atLineStart` 为 false 时第一行不当行首（它是上一段的续）
    static func cleanChunk(_ chunk: String, atLineStart: Bool) -> String {
        var head = ""
        var body = chunk
        if !atLineStart {
            if let nl = chunk.firstIndex(of: "\n") {
                head = String(chunk[..<nl])
                body = String(chunk[nl...])
            } else {
                head = chunk
                body = ""
            }
        }
        func apply(_ s: String, lineRules: Bool) -> String {
            var out = s
            for (i, (pattern, template)) in cleanRules.enumerated() {
                if !lineRules, i == 3 || i == 4 { continue }
                out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
            return out
        }
        return apply(head, lineRules: false) + apply(body, lineRules: true)
    }

    // MARK: - 3. 断句

    private static let fullTerminators: Set<Character> = ["。", "！", "？", "…", "；", "\n"]
    private static let asciiTerminators: Set<Character> = ["!", "?", ";", "."]
    private static let closers: Set<Character> = ["”", "’", "」", "』", "）", ")", "】", "\"", "'", "》", "~", "～"]

    private mutating func releaseSentences(final: Bool) -> [String] {
        var out: [String] = []
        let chars = Array(clean)
        var cut = 0
        var start = 0
        var i = 0
        while i < chars.count {
            if Self.isBoundary(chars, at: i) {
                var end = i + 1
                while end < chars.count, Self.fullTerminators.contains(chars[end]) || Self.closers.contains(chars[end])
                        || (Self.asciiTerminators.contains(chars[end]) && Self.isBoundary(chars, at: end)) {
                    end += 1
                }
                // 句末正好在缓冲结尾（且不是换行）：等下一个字，看后面是不是还跟着收尾引号 / 括号
                if !final, end == chars.count, chars[end - 1] != "\n" { break }
                Self.appendSentence(String(chars[start..<end]), to: &out)
                start = end
                cut = end
                i = end
                continue
            }
            i += 1
        }
        var rest = Array(chars[cut...])
        while rest.count > Self.hardLimit {
            let n = Self.hardCutLength(rest)
            Self.appendSentence(String(rest[..<n]), to: &out)
            rest = Array(rest[n...])
        }
        if final {
            Self.appendSentence(String(rest), to: &out)
            rest = []
        }
        clean = String(rest)
        return out
    }

    /// 句末：全角句末 / 换行立刻算；半角 `!?;.` 要后面跟空白才算（网址、小数、`e.g.` 不切），`.` 前面是数字也不算（序号）
    private static func isBoundary(_ chars: [Character], at i: Int) -> Bool {
        let c = chars[i]
        if fullTerminators.contains(c) { return true }
        guard asciiTerminators.contains(c) else { return false }
        guard i + 1 < chars.count, chars[i + 1].isWhitespace else { return false }
        if c == ".", i > 0, chars[i - 1].isNumber { return false }
        return true
    }

    private static func hardCutLength(_ chars: [Character]) -> Int {
        let window = chars[..<hardLimit]
        var length = hardLimit
        if let idx = window.lastIndex(where: { "，,、：: ".contains($0) }), idx + 1 >= softCutMin {
            length = idx + 1
        }
        // 本机控制标记不是台词，不能在冒号或 220 字边界从中切断。
        if let open = chars[..<length].lastIndex(of: "[") {
            let prefix = String(chars[open..<min(chars.count, open + 6)]).lowercased()
            if prefix.hasPrefix("[sfx:") || prefix.hasPrefix("[/sfx:"),
               let close = chars[open...].firstIndex(of: "]"), close >= length {
                return open > 0 ? open : close + 1
            }
        }
        return length
    }

    /// 压空白 + 去首尾；超过 `hardLimit` 的整句也切（整包回复一个 delta 带几千字一句号）；没有字 / 数字（纯标点、纯 emoji）的不念
    private static func appendSentence(_ text: String, to out: inout [String]) {
        var rest = Array(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        while !rest.isEmpty {
            let n = rest.count > hardLimit ? hardCutLength(rest) : rest.count
            let piece = String(rest[..<n]).trimmingCharacters(in: .whitespaces)
            if piece.contains(where: { $0.isLetter || $0.isNumber }) { out.append(piece) }
            rest = Array(rest[n...])
        }
    }
}

private extension Character {
    var isASCIILetterOrDigit: Bool { isASCII && (isLetter || isNumber) }
}
