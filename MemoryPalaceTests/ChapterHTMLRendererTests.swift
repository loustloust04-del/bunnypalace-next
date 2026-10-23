import XCTest
@testable import 记忆花园

final class ChapterHTMLRendererTests: XCTestCase {

    // MARK: - 段落切分

    func testSplitParagraphsByBlankLine() {
        let text = "第一段。\n\n第二段。\n\n\n第三段。"
        let paragraphs = ChapterHTMLRenderer.splitParagraphs(text)
        XCTAssertEqual(paragraphs, ["第一段。", "第二段。", "第三段。"])
    }

    func testSplitParagraphsFoldsSingleLineBreak() {
        // 同一段内的硬换行折叠成空格
        let text = "第一行\n第二行第二行\n第三行\n\n下一段"
        let paragraphs = ChapterHTMLRenderer.splitParagraphs(text)
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0], "第一行 第二行第二行 第三行")
    }

    func testSplitParagraphsHandlesCRLF() {
        let text = "段一\r\n\r\n段二"
        let paragraphs = ChapterHTMLRenderer.splitParagraphs(text)
        XCTAssertEqual(paragraphs, ["段一", "段二"])
    }

    // MARK: - HTML 转义

    func testEscapeXssCharacters() {
        XCTAssertEqual(ChapterHTMLRenderer.escape("<script>alert('xss')</script>"),
                       "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;")
        XCTAssertEqual(ChapterHTMLRenderer.escape("a & b"), "a &amp; b")
        XCTAssertEqual(ChapterHTMLRenderer.escape("\"双引号\""), "&quot;双引号&quot;")
    }

    // MARK: - 整体渲染

    func testRenderProducesValidHTML() {
        let html = ChapterHTMLRenderer.render(
            title: "第一章 测试",
            text: "段一。\n\n段二。",
            chapterNo: 1,
            totalChapters: 10
        )
        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains("<title>第一章 测试</title>"))
        XCTAssertTrue(html.contains("<h2>第一章 测试</h2>"))
        XCTAssertTrue(html.contains("data-pi=\"0\""))
        XCTAssertTrue(html.contains("data-pi=\"1\""))
        XCTAssertTrue(html.contains("段一。"))
        XCTAssertTrue(html.contains("段二。"))
        // bridge script 注入
        XCTAssertTrue(html.contains("window.webkit.messageHandlers.bookReader"))
        // 章节号透传
        XCTAssertTrue(html.contains("chapter: 1"))
        XCTAssertTrue(html.contains("total: 10"))
    }

    func testRenderEscapesUserContent() {
        let html = ChapterHTMLRenderer.render(
            title: "<script>",
            text: "正文 <img onerror=alert(1)>",
            chapterNo: 1,
            totalChapters: 1
        )
        XCTAssertFalse(html.contains("<script>正"), "title 必须被转义")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("&lt;img onerror=alert(1)&gt;"))
        XCTAssertFalse(html.range(of: "<img onerror")?.isEmpty == false, "正文里的 img 标签必须被转义")
    }

    // MARK: - 排版参数

    func testRenderRespectsFontSize() {
        for size in ChapterHTMLRenderer.FontSize.allCases {
            var style = ChapterHTMLRenderer.Style()
            style.fontSize = size
            let html = ChapterHTMLRenderer.render(title: "T", text: "p", style: style, chapterNo: 1, totalChapters: 1)
            XCTAssertTrue(html.contains("font-size: \(size.rawValue)px"), "size \(size) 必须出现在 CSS")
        }
    }

    // MARK: - 滚动恢复脚本

    func testScrollToRatioScriptClampsRange() {
        let s1 = ChapterHTMLRenderer.scrollToRatioScript(0.5)
        XCTAssertTrue(s1.contains("0.5"))
        // 越界值必须 clamp
        let s2 = ChapterHTMLRenderer.scrollToRatioScript(2.0)
        XCTAssertTrue(s2.contains("1.0") || s2.contains("1\n"))
        let s3 = ChapterHTMLRenderer.scrollToRatioScript(-0.3)
        XCTAssertTrue(s3.contains("0.0") || s3.contains("0\n"))
    }

    // MARK: - M3 标注渲染

    func testRenderWithHighlightWrapsSpan() {
        // title="标题"(2字), 文本="一二三四五。\n\n六七八九十。"
        // article.textContent = "标题" + "一二三四五。" + "六七八九十。"
        //                       chars 0-1   2-7         8-13
        // 高亮"三四五"，章节内 offset = 4..7
        let html = ChapterHTMLRenderer.render(
            title: "标题",
            text: "一二三四五。\n\n六七八九十。",
            chapterNo: 1,
            totalChapters: 1,
            annotations: [
                .init(id: "n1", kind: .highlight, start: 4, end: 7)
            ]
        )
        // R4：底色 span 带 data-ids（点击弹就地小窗）
        XCTAssertTrue(noStyle(html).contains("<span class=\"mk\" data-ids=\"n1\">三四五</span>"),
                      "高亮段必须被 <span class=\"mk\"> 包且带 note id")
    }

    func testRenderWithAiUnderline() {
        let html = ChapterHTMLRenderer.render(
            title: "T",
            text: "abcdefg",
            chapterNo: 1,
            totalChapters: 1,
            annotations: [.init(id: "ai1", kind: .aiUnderline, start: 2, end: 5)]
            // title="T"=1 字，正文 offset 在 [1, 8) → 高亮 abc 起点是 2 - 1 = 1
        )
        XCTAssertTrue(html.contains("<span class=\"ai-ul\" data-ids=\"ai1\">bcd</span>"))
    }

    func testAnnotationSpanningParagraphsIsClippedPerParagraph() {
        // title="T"(1), 段1="aaa"(3), 段2="bbb"(3)
        // 全章 offset：T=0, a=1..3, b=4..6
        // annotation 跨段 start=2 end=5 → 段1 部分(2..3 即"aa")，段2 部分(4..5 即"b")
        let html = ChapterHTMLRenderer.render(
            title: "T",
            text: "aaa\n\nbbb",
            chapterNo: 1,
            totalChapters: 1,
            annotations: [.init(id: "x", kind: .highlight, start: 2, end: 5)]
        )
        XCTAssertTrue(noStyle(html).contains("a<span class=\"mk\" data-ids=\"x\">aa</span>"), "段1 应有 `a` + span(aa)")
        XCTAssertTrue(noStyle(html).contains("<span class=\"mk\" data-ids=\"x\">b</span>bb"), "段2 应有 span(b) + bb")
    }

    func testRenderEscapesAnnotationIdToPreventBreakage() {
        // 点击链路的 data-ids，id 必须 HTML-escape
        let html = ChapterHTMLRenderer.render(
            title: "T",
            text: "abc",
            chapterNo: 1,
            totalChapters: 1,
            annotations: [.init(id: "<bad>", kind: .aiUnderline, start: 1, end: 2)]
        )
        XCTAssertTrue(html.contains("data-ids=\"&lt;bad&gt;\""), "id 必须 HTML-escape")
        XCTAssertFalse(html.contains("data-ids=\"<bad>\""))
    }

    // MARK: - CR-1 charMap 双色矩阵（段落域 offset 从 0 起，直接调段级函数）

    private func apply(_ text: String, _ anns: [ChapterHTMLRenderer.Annotation]) -> String {
        ChapterHTMLRenderer.applyAnnotationsToParagraph(
            text: text, paragraphStart: 0, paragraphEnd: text.count, annotations: anns
        )
    }

    /// 去掉 inline style，只比结构（切片 / class / 命中 id）
    private func noStyle(_ html: String) -> String {
        html.replacingOccurrences(of: #" style="[^"]*""#, with: "", options: .regularExpression)
    }

    /// 取第 n 个 span 的 style 值
    private func styles(_ html: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"style="([^"]*)""#)
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).map {
            String(html[Range($0.range(at: 1), in: html)!])
        }
    }

    func testSegmentsSplitAtEveryStrokeBoundary() {
        // user [0,4) + ai [2,6) → ab(u) cd(a,u) ef(a)；文字只一份，不加左右内边距
        let html = apply("abcdef", [
            .init(id: "u", kind: .highlight, start: 0, end: 4, author: .user),
            .init(id: "a", kind: .highlight, start: 2, end: 6, author: .ai),
        ])
        XCTAssertEqual(noStyle(html),
            "<span class=\"mk\" data-ids=\"u\">ab</span><span class=\"mk\" data-ids=\"a,u\">cd</span><span class=\"mk\" data-ids=\"a\">ef</span>")
        XCTAssertFalse(html.contains("padding: 0 2px"))
        let cd = styles(html)[1]
        // 两层底色都在；后划的（ai 玫瑰）排在前面 = 画在上面
        XCTAssertTrue(cd.contains("rgba(201,138,138,0.30)"))
        XCTAssertTrue(cd.contains("rgba(142,189,159,0.30)"))
        XCTAssertLessThan(cd.range(of: "201,138,138")!.lowerBound, cd.range(of: "142,189,159")!.lowerBound)
    }

    func testSameRangeTwiceStacksTwoLayers() {
        // 同一段划两次（叠一道）：一个 span，两层背景，两个 id
        let html = apply("abcd", [
            .init(id: "p1", kind: .highlight, start: 0, end: 4, colorHex: "#8EBD9F"),
            .init(id: "p2", kind: .highlight, start: 0, end: 4, colorHex: "#BDA8D8", style: .underline),
        ])
        XCTAssertEqual(noStyle(html), "<span class=\"mk\" data-ids=\"p1,p2\">abcd</span>")
        let st = styles(html)[0]
        XCTAssertTrue(st.contains("rgba(142,189,159,0.30)"))
        XCTAssertTrue(st.contains("rgba(189,168,216,0.9)"))
        XCTAssertTrue(st.contains("padding-bottom:4px"))
    }

    func testContainmentProducesThreeSegments() {
        let html = apply("abcdef", [
            .init(id: "u", kind: .highlight, start: 0, end: 6, author: .user),
            .init(id: "a", kind: .highlight, start: 2, end: 4, author: .ai),
        ])
        XCTAssertEqual(noStyle(html),
            "<span class=\"mk\" data-ids=\"u\">ab</span><span class=\"mk\" data-ids=\"a,u\">cd</span><span class=\"mk\" data-ids=\"u\">ef</span>")
    }

    func testAdjacentStrokesDoNotMerge() {
        let html = apply("abcd", [
            .init(id: "x", kind: .highlight, start: 0, end: 2),
            .init(id: "y", kind: .highlight, start: 2, end: 4),
        ])
        XCTAssertEqual(noStyle(html),
            "<span class=\"mk\" data-ids=\"x\">ab</span><span class=\"mk\" data-ids=\"y\">cd</span>")
    }

    func testAIUnderlineStacksOnHighlight() {
        let html = apply("abcd", [
            .init(id: "u", kind: .highlight, start: 0, end: 4, author: .user),
            .init(id: "bubble", kind: .aiUnderline, start: 1, end: 3, author: .ai),
        ])
        XCTAssertEqual(noStyle(html),
            "<span class=\"mk\" data-ids=\"u\">a</span><span class=\"mk ai-ul\" data-ids=\"bubble,u\">bc</span><span class=\"mk\" data-ids=\"u\">d</span>")
    }

    func testUnderlineLayersFollowTheStroke() {
        // u1 [0,6) u2 [3,9) 重叠 → 层 0 / 1；u3 [7,9) 和 u1 不重叠但和 u2 重叠 → 层 0
        let anns: [ChapterHTMLRenderer.Annotation] = [
            .init(id: "u1", kind: .highlight, start: 0, end: 6, style: .underline),
            .init(id: "u2", kind: .highlight, start: 3, end: 9, style: .underline),
            .init(id: "u3", kind: .highlight, start: 7, end: 9, style: .underline),
            .init(id: "f", kind: .highlight, start: 0, end: 9),
        ]
        XCTAssertEqual(ChapterHTMLRenderer.underlineLayers(anns), ["u1": 0, "u2": 1, "u3": 0])
        // 跨段：第二段里只剩 u2，它仍画在第 1 层（内边距按最大层 1 → 7px，线在 calc(100% - 1px)）
        let html = ChapterHTMLRenderer.render(title: "", text: "abcde\n\nfghi", chapterNo: 1, totalChapters: 1, annotations: anns)
        let p2 = html.components(separatedBy: "data-pi=\"1\"")[1]
        XCTAssertTrue(p2.contains("calc(100% - 1px)/100% 2px"), p2)
        XCTAssertTrue(p2.contains("padding-bottom:7px"))
    }

    func testPenStrokeIsDeterministicPerId() {
        let a = ChapterHTMLRenderer.penStroke(id: "n1", rgb: "1,2,3")
        XCTAssertEqual(a, ChapterHTMLRenderer.penStroke(id: "n1", rgb: "1,2,3"))
        XCTAssertNotEqual(a, ChapterHTMLRenderer.penStroke(id: "n2", rgb: "1,2,3"))
        XCTAssertTrue(a.hasPrefix("data:image/svg+xml,"))
        XCTAssertFalse(a.contains("\""), "进 style 属性，不能带双引号")
    }

    func testOffsetsCountGraphemesLikeSwift() {
        // emoji / 扩展区汉字在 Swift 里各算 1 个字：[2,3) 应只包住「𠀀」
        let html = apply("😀a𠀀b", [.init(id: "g", kind: .highlight, start: 2, end: 3)])
        XCTAssertEqual(noStyle(html), "😀a<span class=\"mk\" data-ids=\"g\">𠀀</span>b")
    }

    // MARK: - 高亮融合的 flowSlice

    func testFlowSliceMatchesAnnotationOffsetDomain() {
        // 流 = "T" + "abc" + "dde"（title=1, 段1=1..4, 段2=4..7）
        XCTAssertEqual(ChapterHTMLRenderer.flowSlice(title: "T", text: "abc\n\ndde", start: 2, end: 6), "bcdd")
        XCTAssertNil(ChapterHTMLRenderer.flowSlice(title: "T", text: "abc", start: 2, end: 99), "越界返回 nil")
    }

    // MARK: - CR-1 失锚检测

    func testBrokenAnchorDetectsTextDrift() {
        // 流 = "T"+"abcdef"；ok 锚正确，drifted 偏 1 位，outOfRange 越界
        let anns: [ChapterHTMLRenderer.Annotation] = [
            .init(id: "ok", kind: .highlight, start: 3, end: 6, author: .user, anchorText: "cde"),
            .init(id: "drifted", kind: .highlight, start: 2, end: 5, author: .user, anchorText: "cde"),
            .init(id: "outOfRange", kind: .highlight, start: 5, end: 99, author: .user, anchorText: "x"),
        ]
        let broken = ChapterHTMLRenderer.brokenAnchorIds(title: "T", text: "abcdef", annotations: anns)
        XCTAssertEqual(broken, ["drifted", "outOfRange"])
    }

    func testBrokenAnchorTolerantToWhitespaceDifference() {
        // 跨段 anchorText 带换行——归一化后不误判
        // 流 = "T"+"abc"+"dde" = "Tabcdde"，切片 2..7 = "bcdde"，anchor "bc\ndd e" 去空白同值
        let anns: [ChapterHTMLRenderer.Annotation] = [
            .init(id: "cross", kind: .highlight, start: 2, end: 7, author: .user, anchorText: "bc\ndd e"),
        ]
        let broken = ChapterHTMLRenderer.brokenAnchorIds(title: "T", text: "abc\n\ndde", annotations: anns)
        XCTAssertTrue(broken.isEmpty, "空白差异不算失锚")
    }
}
