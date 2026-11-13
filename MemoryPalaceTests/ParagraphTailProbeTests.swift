import MemoryCore
import XCTest
import AppKit
import SwiftStreamingMarkdown
@testable import 记忆花园

/// 段落末尾丢字探针（粟粟 10-31）：一次性渲染 / 流式渲染 / 原文三方比字。
/// 走真实显示管线：ContentCleaner → 剥思考 → 显示正则（空规则）→ markdownPromotingHTML → TickerLinkifier
/// → fork `MarkdownParserImpl`（静态 parseSync / 流式 parse），取 RenderableDocument 里的文字节点比对。
/// 入口对应：文章静态 CardFlowView.swift:4316-4320 + simpleStaticBody:3961-3967 + markdownBody:3932；
/// 文章流式 ArticleStreamingBody.renderableBody:44-55 → StreamedMarkdownController.start；
/// 气泡静态 ChatBubbleStyle.swift:629-647 + blockText:677-688；气泡流式 ChatBubbleStyle.swift:618-621 + streamingVisibleBlocks:759。
@MainActor
final class ParagraphTailProbeTests: XCTestCase {

    // MARK: - 语料

    static let synthetic: [(String, String)] = [
        ("普通段落", "今天天气很好，我们去公园散步了。\n\n走到湖边的时候，看见一只白鹭站在水里，一动不动地盯着水面。\n\n后来它飞走了"),
        ("段尾标点", "你说什么！\n\n真的吗？\n\n嗯……\n\n他沉默了——\n\n「好吧。」\n\n（小声）\n\n好的~\n\nThis is the end.\n\n混合 English 结尾abc"),
        ("段尾emoji", "抱抱你❤️\n\n晚安🌙✨\n\n一家人👨‍👩‍👧\n\n点个赞👍🏻"),
        ("段尾行内代码", "试试 `git status`\n\n然后运行 `swift test`。\n\n`整段都是代码`"),
        ("段尾粗斜体", "这句话**很重要**\n\n还有*斜体结尾*\n\n***粗斜体***\n\n**整段加粗。**\n\n_下划线斜体_\n\n__下划线加粗__"),
        ("段尾链接", "去看[这里](https://example.com)\n\n链接在末尾 https://example.com/a?b=1\n\n尖括号链接 <https://example.com/x>"),
        ("剧透注音", "剧透：||他其实是猫||\n\n注音{漂亮|piào liang}\n\n一个竖线 a | b 的段尾|\n\n两个竖线但不配对 a || b 结尾"),
        ("列表", "清单：\n\n- 苹果\n- 香蕉末尾\n\n1. 第一步\n2. 第二步结束\n\n列表后的段落"),
        ("引用", "> 引用里的话到这里\n> 第二行结尾\n\n引用后段落"),
        ("标题", "# 大标题\n\n标题后的正文\n\n## 小标题结尾\n\n正文最后"),
        ("代码块前后", "代码前的段落\n```swift\nlet a = 1\n```\n代码后的段落\n\n```\nplain\n```\n\n最后一段"),
        ("单双换行混用", "第一行\n第二行结尾\n\n第三段\n\n\n\n第四段之后多空行\n第五行"),
        ("CRLF", "第一段\r\n\r\n第二段末尾\r\n第三行\r\n\r\n第三段"),
        ("全角空格", "　　首行缩进的段落结尾。\n\n　　第二段也缩进　\n\n中间　有全角空格"),
        ("角色扮演", "（把你抱紧了一点，鼻子蹭着你的头发，蹭了好一会儿。）\n\n……猫猫亲回来了。\n\n*小声*：晚安~\n\n（在你嘴唇上笑了一下）"),
        ("美元", "价格是$5\n\n花了 $10 和 $20 两笔\n\n只有一个$"),
        ("尖括号", "我<3你\n\n<喵>结尾\n\n用 <br> 换行<br>末尾\n\n<b>加粗</b>结尾"),
        ("硬换行", "第一行\\\n第二行  \n第三行末尾"),
        ("删除线波浪", "~~删掉~~结尾\n\n好的~\n\n嗯~~\n\n~单个~"),
        ("等号", "a == b 的时候\n\n==高亮==结尾\n\n结尾=="),
        ("表格", "| 名字 | 说明 |\n|---|---|\n| 猫 | 会喵 |\n\n表格后段落"),
        ("思考标签", "[thinking]想一想[/thinking]\n\n正文第一段\n\n正文第二段"),
        ("长段落", String(repeating: "这是一个很长的段落，用来测试换行之后末尾的字会不会丢。", count: 12) + "最后几个字\n\n下一段也很长" + String(repeating: "，继续写", count: 30) + "。"),
        ("冒号行", "术语\n: 释义结尾\n\n后面的段落"),
        ("全角符号", "【重要】这是开头\n\n结尾是【括号】\n\n《书名》结尾\n\n“引号结尾”"),
    ]

    static func fixtures() -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Packages/SwiftStreamingMarkdown/Examples/SwiftStreamingMarkdownSample/SwiftStreamingMarkdownSample/Resources/Fixtures")
        return ["multi-paragraph.md", "roboto.md", "tables.md"].compactMap { name in
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
        }
    }

    // MARK: - 管线

    private static let names = EffectiveCharacterContext(charName: "克克", userName: "粟粟")

    private static func cleaned(_ raw: String) -> String {
        let display = ChatSystemMessage.split(raw, legacy: false).body
        let c = names.expand(ContentCleaner.clean(display, cached: false))
        return ContentCleaner.extractThinking(from: c).content
    }

    private static func finalMarkdown(_ text: String) -> String {
        let promoted = MessageHTMLSegments.markdownPromotingHTML(text)
        #if PERSONAL_APPS
        return TickerLinkifier.linkify(promoted)
        #else
        return promoted
        #endif
    }

    static let articleConfig = MarkdownRenderConfig.memoryPalace()
    static let bubbleConfig = MarkdownRenderConfig.memoryPalace(lineSpacingScale: BubbleModeRow.fixedLineSpacing)

    /// 文章静态：CardFlowView → simpleStaticBody → markdownBody → ChatMarkdownView → CachedMarkdownView.parseSync
    static func articleStatic(_ raw: String) -> [String] {
        let display = RegexPipeline.run([], text: cleaned(raw), phase: .display, placement: RegexPipeline.assistantPlacement)
        return texts(MarkdownParserImpl().parseSync(text: finalMarkdown(display), config: articleConfig))
    }

    /// 文章流式一帧：ArticleStreamingBody.renderableBody → StreamedMarkdownController（异步 parse）
    static func articleStreamFrame(_ rawPrefix: String) async -> [String] {
        let body = ContentCleaner.extractThinking(from: ContentCleaner.clean(rawPrefix, cached: false)).content
        return texts(await MarkdownParserImpl().parse(text: body, config: articleConfig))
    }

    /// 气泡单块：blockText 非 user 分支
    static func bubbleBlock(_ block: String) -> [String] {
        let regexed = RegexPipeline.run([], text: block, phase: .display, placement: RegexPipeline.assistantPlacement)
        let display = BubbleMarkdownSimplifier.simplify(regexed)
        return texts(MarkdownParserImpl().parseSync(text: finalMarkdown(display), config: bubbleConfig))
    }

    /// 气泡静态：parsedContent 非流式分支拆块
    static func bubbleStaticBlocks(_ raw: String) -> [String] {
        let body = cleaned(raw)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return BubbleModeRow.splitBlocks(MessageHTMLSegments.markdownPromotingHTML(body))
            .filter { !BubbleMarkdownSimplifier.isRenderEmpty($0) }
    }

    /// 气泡流式：parsedContent 流式分支
    static func bubbleStreamBlocks(_ rawPrefix: String) -> [String] {
        let body = ContentCleaner.extractThinking(from: ContentCleaner.clean(rawPrefix, cached: false)).content
        return BubbleModeRow.streamingVisibleBlocks(body)
    }

    // MARK: - 取渲染文字（RenderableDocument 内部是 internal，用 Mirror 取文字节点；剧透这类透明字单独算看不见）

    static func texts(_ doc: RenderableDocument) -> [String] {
        var out: [String] = []
        func walk(_ value: Any, label: String?) {
            if let s = value as? NSAttributedString { out.append(visible(s)); return }
            if let s = value as? String {
                if label == "code" || label == "text" { out.append(s) }
                return
            }
            if value is URL { return }
            for child in Mirror(reflecting: value).children { walk(child.value, label: child.label) }
        }
        walk(doc, label: nil)
        return out
    }

    private static func visible(_ s: NSAttributedString) -> String {
        var result = ""
        let ns = s.string as NSString
        s.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            if let c = value as? NSColor, (c.usingColorSpace(.sRGB)?.alphaComponent ?? 1) == 0 { return }
            result += ns.substring(with: range)
        }
        return result
    }

    // MARK: - 原文 oracle：去掉 markdown 语法后的可见字

    static func significant(_ ch: Character) -> Bool {
        if ch.isWhitespace { return false }
        if ch.isLetter || ch.isNumber { return true }
        guard let v = ch.unicodeScalars.first?.value else { return false }
        if (0x3001...0x303F).contains(v) || (0xFF01...0xFF5E).contains(v) || (0x2014...0x2026).contains(v) { return true }
        return ch.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }

    static func norm(_ s: String) -> String { String(s.filter(significant)) }

    private static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    /// 段落（围栏外按空行分）→ 每段去语法后的可见字
    static func oracleParagraphs(_ raw: String) -> [String] {
        let text = cleaned(raw).replacingOccurrences(of: "\r\n", with: "\n")
        var paragraphs: [String] = []
        var buf: [String] = []
        var inFence = false
        func flush() {
            let joined = buf.joined(separator: "\n")
            if !norm(joined).isEmpty { paragraphs.append(norm(joined)) }
            buf.removeAll()
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle(); flush(); continue }
            if inFence { buf.append(line); continue }
            if t.isEmpty { flush(); continue }
            var l = line
            l = sub(l, #"^\s*(?:[-*+]|\d+[.)])\s+"#, "")
            l = sub(l, #"!\[[^\]]*\]\([^)]*\)"#, "")
            l = sub(l, #"\]\([^)]*\)"#, "]")
            l = sub(l, #"<(https?://[^>]+)>"#, "$1")
            l = sub(l, #"</?[A-Za-z][A-Za-z0-9]*[^>]*>"#, "")
            l = sub(l, #"\{([^{}|\n]+)\|[^{}|\n]+\}"#, "$1")
            l = sub(l, #"\|\|(?=\S)(.+?)(?<=\S)\|\|"#, "")
            buf.append(l)
        }
        flush()
        return paragraphs
    }

    struct Diff: CustomStringConvertible {
        let name: String
        let scheme: String
        let paragraph: Int
        let expected: String
        let got: String
        var description: String { "[\(name)] \(scheme) 第 \(paragraph) 段：应为 …\(expected.suffix(12))  实际 …\(got.suffix(12))" }
    }

    /// 渲染文字 vs 原文逐段对齐：任何一段差字（尤其段尾）返回定位
    static func compare(_ name: String, scheme: String, paragraphs: [String], rendered: [String]) -> Diff? {
        let got = norm(rendered.joined())
        let expected = paragraphs.joined()
        guard got != expected else { return nil }
        let e = Array(expected), g = Array(got)
        var i = 0
        while i < e.count, i < g.count, e[i] == g[i] { i += 1 }
        var acc = 0
        for (index, p) in paragraphs.enumerated() {
            if i < acc + p.count {
                let start = acc
                let gotSlice = String(g[min(start, g.count)..<min(start + p.count, g.count)])
                return Diff(name: name, scheme: scheme, paragraph: index, expected: p, got: gotSlice)
            }
            acc += p.count
        }
        return Diff(name: name, scheme: scheme, paragraph: paragraphs.count, expected: "", got: String(g.dropFirst(min(i, g.count))))
    }

    // MARK: - 切块

    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    }

    /// 切点（字符偏移，最后一个总是全文）
    static func cutPoints(_ text: String, scheme: String, seed: UInt64) -> [Int] {
        let chars = Array(text)
        var cuts: [Int] = []
        switch scheme {
        case "1字":
            cuts = Array(1...chars.count)
        case "随机token":
            var rng = SplitMix64(state: seed)
            var p = 0
            while p < chars.count { p = min(chars.count, p + rng.int(1...8)); cuts.append(p) }
        case "段界±1":
            for i in 0..<chars.count where chars[i] == "\n" && i + 1 < chars.count && chars[i + 1] == "\n" {
                cuts += [i - 1, i, i + 1, i + 2, i + 3].filter { $0 > 0 && $0 <= chars.count }
            }
            cuts.append(chars.count)
        default:
            cuts = [chars.count]
        }
        return Array(Set(cuts)).sorted()
    }

    /// 标量级切（token 切在 emoji / ZWJ 中间）
    static func scalarPrefixes(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return (1...scalars.count).map { String(String.UnicodeScalarView(scalars[0..<$0])) }
    }

    // MARK: - 探针

    private func corpus(includeFixtures: Bool) -> [(String, String)] {
        Self.synthetic + (includeFixtures ? Self.fixtures() : [])
    }

    /// 探针自检：段尾少一个字 / 中间段少字都必须报出来，并定位到那一段
    func testProbeFlagsDroppedParagraphTail() {
        let raw = "第一段到这里\n\n第二段末尾两个字\n\n第三段"
        let paragraphs = Self.oracleParagraphs(raw)
        var rendered = Self.articleStatic(raw)
        XCTAssertNil(Self.compare("自检", scheme: "原样", paragraphs: paragraphs, rendered: rendered))
        rendered[1] = String(rendered[1].dropLast(2))
        let diff = Self.compare("自检", scheme: "段尾少两字", paragraphs: paragraphs, rendered: rendered)
        XCTAssertEqual(diff?.paragraph, 1)
        XCTAssertEqual(diff?.expected, "第二段末尾两个字")
    }

    /// A1 一次性渲染（文章 + 气泡）vs 原文
    func testStaticRenderKeepsEveryParagraphTail() {
        var diffs: [Diff] = []
        let all = corpus(includeFixtures: true)
        XCTAssertGreaterThanOrEqual(all.count, Self.synthetic.count + 3, "fixture 没读到")
        for (name, raw) in all {
            let paragraphs = Self.oracleParagraphs(raw)
            if let d = Self.compare(name, scheme: "文章静态", paragraphs: paragraphs, rendered: Self.articleStatic(raw)) { diffs.append(d) }
            let bubble = Self.bubbleStaticBlocks(raw).flatMap(Self.bubbleBlock)
            if let d = Self.compare(name, scheme: "气泡静态", paragraphs: paragraphs, rendered: bubble) { diffs.append(d) }
        }
        print("[TAIL PROBE] static cases=\(all.count) diffs=\(diffs.count)")
        diffs.forEach { print("[TAIL PROBE] \($0)") }
        XCTAssertTrue(diffs.isEmpty, diffs.map(\.description).joined(separator: "\n"))
    }

    /// A2 文章流式：各种切块喂流式路径，最后一帧 vs 一次性渲染 vs 原文；中途已写完的段落也不能少字
    func testArticleStreamingMatchesStaticAndSource() async {
        var diffs: [Diff] = []
        var frames = 0
        var schemesRun = 0
        for (name, raw) in corpus(includeFixtures: true) {
            let isFixture = !Self.synthetic.contains { $0.0 == name }
            let schemes = isFixture ? ["随机token", "段界±1"] : ["1字", "随机token", "段界±1"]
            let staticTexts = Self.articleStatic(raw)
            let chars = Array(raw)
            for (s, scheme) in schemes.enumerated() {
                schemesRun += 1
                var last: [String] = []
                for cut in Self.cutPoints(raw, scheme: scheme, seed: 0x5EED_0000 + UInt64(s)) {
                    let prefix = String(chars[0..<cut])
                    last = await Self.articleStreamFrame(prefix)
                    frames += 1
                    // 已写完的段落（后面跟着空行且不在围栏里）：渲染出的字必须以它们开头
                    if let doneEnd = prefix.range(of: "\n\n", options: .backwards), !prefix.contains("```") {
                        let done = Self.oracleParagraphs(String(prefix[..<doneEnd.lowerBound])).joined()
                        let got = Self.norm(last.joined())
                        if !got.hasPrefix(done) {
                            if let d = Self.compare(name, scheme: "文章流式中途/\(scheme)@\(cut)",
                                                    paragraphs: Self.oracleParagraphs(String(prefix[..<doneEnd.lowerBound])),
                                                    rendered: [String(got.prefix(done.count))]) { diffs.append(d) }
                        }
                    }
                }
                if last != staticTexts {
                    diffs.append(Diff(name: name, scheme: "文章流式末帧≠静态/\(scheme)", paragraph: -1,
                                      expected: staticTexts.joined(separator: "¶"), got: last.joined(separator: "¶")))
                }
                if let d = Self.compare(name, scheme: "文章流式末帧/\(scheme)", paragraphs: Self.oracleParagraphs(raw), rendered: last) { diffs.append(d) }
            }
        }
        // 标量级切（emoji / ZWJ 被切开）
        for (name, raw) in Self.synthetic where raw.unicodeScalars.count < 600 {
            schemesRun += 1
            var last: [String] = []
            for prefix in Self.scalarPrefixes(raw) { last = await Self.articleStreamFrame(prefix); frames += 1 }
            if last != Self.articleStatic(raw) {
                diffs.append(Diff(name: name, scheme: "文章流式末帧≠静态/标量", paragraph: -1, expected: "", got: last.joined(separator: "¶")))
            }
        }
        print("[TAIL PROBE] article streaming frames=\(frames) schemes=\(schemesRun) diffs=\(diffs.count)")
        diffs.forEach { print("[TAIL PROBE] \($0)") }
        XCTAssertTrue(diffs.isEmpty, diffs.map(\.description).joined(separator: "\n"))
    }

    /// A3 气泡流式：各帧出泡的块必须是定稿块的前缀，且每块渲染文字和定稿同块逐字相同
    func testBubbleStreamingBlocksMatchStatic() {
        var diffs: [Diff] = []
        var frames = 0
        var schemesRun = 0
        for (name, raw) in corpus(includeFixtures: true) {
            let staticBlocks = Self.bubbleStaticBlocks(raw)
            let staticRendered = staticBlocks.map(Self.bubbleBlock)
            let chars = Array(raw)
            for (s, scheme) in ["1字", "随机token", "段界±1"].enumerated() {
                schemesRun += 1
                for cut in Self.cutPoints(raw, scheme: scheme, seed: 0xB0B_0000 + UInt64(s)) {
                    let blocks = Self.bubbleStreamBlocks(String(chars[0..<cut]))
                    frames += 1
                    for (i, block) in blocks.enumerated() {
                        guard i < staticBlocks.count else {
                            diffs.append(Diff(name: name, scheme: "气泡流式多出块/\(scheme)@\(cut)", paragraph: i, expected: "", got: block))
                            break
                        }
                        if block != staticBlocks[i] {
                            diffs.append(Diff(name: name, scheme: "气泡流式块≠定稿块/\(scheme)@\(cut)", paragraph: i, expected: staticBlocks[i], got: block))
                            break
                        }
                    }
                }
                let finalBlocks = Self.bubbleStreamBlocks(raw).map(Self.bubbleBlock)
                if Array(staticRendered.prefix(finalBlocks.count)) != finalBlocks {
                    diffs.append(Diff(name: name, scheme: "气泡流式末帧≠静态/\(scheme)", paragraph: -1, expected: "", got: ""))
                }
            }
        }
        print("[TAIL PROBE] bubble streaming frames=\(frames) schemes=\(schemesRun) diffs=\(diffs.count)")
        diffs.forEach { print("[TAIL PROBE] \($0)") }
        XCTAssertTrue(diffs.isEmpty, diffs.map(\.description).joined(separator: "\n"))
    }
}
