import XCTest
@testable import 记忆花园

/// #047：Gemini 回答 HTML → Markdown。全部合成片段。
final class GeminiHTMLToMarkdownTests: XCTestCase {

    private func md(_ html: String) -> String { GeminiHTMLToMarkdown.convert(html) }

    func testParagraphsAndInline() {
        XCTAssertEqual(md("<p>答案是 <strong>2</strong>。</p><p>第二段 <em>斜</em> <code>x+1</code></p>"),
                       "答案是 **2**。\n\n第二段 *斜* `x+1`")
    }

    func testLineBreakAndWhitespaceCollapse() {
        XCTAssertEqual(md("<p>一行\n   还是一行<br>第二行</p>"), "一行 还是一行\n第二行")
    }

    func testHeadingsAndRule() {
        XCTAssertEqual(md("<h2>标题</h2><p>正文</p><hr><h3>小节</h3>"), "## 标题\n\n正文\n\n---\n\n### 小节")
    }

    func testCodeBlockKeepsAngleBracketsAndLanguage() {
        let out = md("<pre><code class=\"language-swift\">if a &lt; b &amp;&amp; c &gt; d {\n    print(&quot;&lt;tag&gt;&quot;)\n}</code></pre>")
        XCTAssertEqual(out, "```swift\nif a < b && c > d {\n    print(\"<tag>\")\n}\n```")
    }

    func testInlineCodeWithBacktick() {
        XCTAssertEqual(md("<p><code>a`b</code></p>"), "``a`b``")
    }

    func testUnorderedAndOrderedNestedLists() {
        let out = md("<ul><li>一</li><li>二<ol><li>甲</li><li>乙</li></ol></li></ul>")
        XCTAssertEqual(out, "- 一\n- 二\n\n  1. 甲\n  2. 乙")
    }

    func testOrderedListStart() {
        XCTAssertEqual(md(#"<ol start="3"><li>c</li><li>d</li></ol>"#), "3. c\n4. d")
    }

    func testBlockquote() {
        XCTAssertEqual(md("<blockquote><p>引用一</p><p>引用二</p></blockquote>"), "> 引用一\n>\n> 引用二")
    }

    func testTable() {
        let out = md("<table><tr><th>名</th><th>值</th></tr><tr><td>a|b</td><td>1</td></tr><tr><td>c</td></tr></table>")
        XCTAssertEqual(out, "| 名 | 值 |\n| --- | --- |\n| a\\|b | 1 |\n| c |  |")
    }

    func testLinksOnlyHTTP() {
        XCTAssertEqual(md(#"<p><a href="https://example.com/a">站</a> <a href="javascript:alert(1)">坏</a> <a href="https://x.test/(1)"></a></p>"#),
                       "[站](https://example.com/a) 坏 [https://x.test/(1)](https://x.test/%281%29)")
    }

    func testScriptStyleIframeDropped() {
        XCTAssertEqual(md("<p>前</p><script>alert('x')</script><style>p{}</style><iframe src='https://x'></iframe><p onclick='evil()'>后</p>"),
                       "前\n\n后")
    }

    func testEscapedScriptTextStaysLiteralNotDoubleDecoded() {
        XCTAssertEqual(md("<p>写法是 &amp;lt;script&amp;gt; 和 &lt;b&gt;</p>"), "写法是 &lt;script&gt; 和 \\<b>")
    }

    func testMarkdownInTextIsEscaped() {
        XCTAssertEqual(md("<p>说明 [打开](file:///tmp/x) *星* _下_ snake_case ~~删~~ a~b `t` C:\\dir</p>"),
                       #"说明 \[打开\](file:///tmp/x) \*星\* \_下\_ snake_case \~\~删\~\~ a~b \`t\` C:\\dir"#)
        XCTAssertEqual(md(#"<p><img alt="x](javascript:alert(1))"></p>"#), #"[图片：x\](javascript:alert(1))]"#)
        XCTAssertEqual(md("<p><strong>粗*体</strong></p>"), #"**粗\*体**"#)
    }

    func testHugeOrderedListStartDoesNotOverflow() {
        XCTAssertEqual(md(#"<ol start="9223372036854775807"><li>x</li><li>y</li></ol>"#), "999999999. x\n1000000000. y")
        XCTAssertEqual(md(#"<ol start="-5"><li>x</li></ol>"#), "0. x")
    }

    func testImagesBecomePlaceholderText() {
        XCTAssertEqual(md(#"<p>看图 <img src="https://x/a.png" alt="猫"> <img src="b.png"></p>"#), "看图 [图片：猫] [图片]")
    }

    func testEmptyAndPlainText() {
        XCTAssertEqual(md(""), "")
        XCTAssertEqual(md("纯文本 1 < 2"), "纯文本 1 < 2")
    }
}
