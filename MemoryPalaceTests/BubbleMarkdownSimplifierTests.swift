import XCTest
@testable import 记忆花园

final class BubbleMarkdownSimplifierTests: XCTestCase {

    private func s(_ t: String) -> String { BubbleMarkdownSimplifier.simplify(t) }

    // MARK: - 标题 → 加粗正文

    func testHeadingBecomesBold() {
        XCTAssertEqual(s("# 大标题"), "**大标题**")
        XCTAssertEqual(s("### 三级标题"), "**三级标题**")
        XCTAssertEqual(s("###### 六级"), "**六级**")
    }

    func testHeadingWithExistingBoldStripsInnerMarks() {
        XCTAssertEqual(s("## 带**粗**的标题"), "**带粗的标题**")
    }

    func testClosingHashesStripped() {
        XCTAssertEqual(s("## 标题 ##"), "**标题**")
    }

    func testCSharpSuffixNotStripped() {
        XCTAssertEqual(s("# 关于 C#"), "**关于 C#**")
    }

    func testHashtagIsNotHeading() {
        XCTAssertEqual(s("#标签 不是标题"), "#标签 不是标题")
    }

    func testSevenHashesIsNotHeading() {
        XCTAssertEqual(s("####### 七个"), "####### 七个")
    }

    func testEmptyHeadingLineDropped() {
        XCTAssertEqual(s("上\n##\n下"), "上\n下")
    }

    // MARK: - 嵌套列表拍平

    func testNestedListFlattens() {
        XCTAssertEqual(s("- a\n  - b\n    1. c"), "- a\n- b\n1. c")
        XCTAssertEqual(s("1. a\n   2) b\n\t* c"), "1. a\n2) b\n* c")
    }

    func testTopLevelListUntouched() {
        XCTAssertEqual(s("- a\n- b"), "- a\n- b")
    }

    func testIndentedNonListLineUntouched() {
        XCTAssertEqual(s("  普通缩进行"), "  普通缩进行")
    }

    func testItalicNotTreatedAsList() {
        XCTAssertEqual(s("  *斜体*不是列表"), "  *斜体*不是列表")
    }

    // MARK: - 分隔线删除

    func testThematicBreakRemoved() {
        XCTAssertEqual(s("上文\n---\n下文"), "上文\n下文")
        XCTAssertEqual(s("***"), "")
        XCTAssertEqual(s("- - -"), "")
        XCTAssertEqual(s("___"), "")
    }

    func testTableDelimiterRowNotRemoved() {
        let table = "| a | b |\n|---|---|\n| **x** | *y* |"
        XCTAssertEqual(s(table), table)
    }

    func testIsRenderEmpty() {
        XCTAssertTrue(BubbleMarkdownSimplifier.isRenderEmpty("---"))
        XCTAssertTrue(BubbleMarkdownSimplifier.isRenderEmpty("- - -"))
        XCTAssertFalse(BubbleMarkdownSimplifier.isRenderEmpty("正文"))
        XCTAssertFalse(BubbleMarkdownSimplifier.isRenderEmpty("# 标题"))
    }

    // MARK: - 代码块 / 保留项原样

    func testCodeBlockInteriorUntouched() {
        let code = "```\n# 注释不是标题\n  - 缩进不拍平\n---\n```"
        XCTAssertEqual(s(code), code)
    }

    /// ```` 包 ``` 的嵌套：内层 ``` 不能被当成外层的结束，里面的「标题」也不能被拍成加粗
    func testNestedFenceInteriorUntouched() {
        let code = "````markdown\n```python\n# 注释\n```\n# 还在代码里\n````"
        XCTAssertEqual(s(code), code)
    }

    /// 分气泡：嵌套围栏整块留在同一个泡里，不被内层 ``` 切成三截
    func testSplitBlocksKeepsNestedFenceTogether() {
        let text = "前文\n\n````markdown\n```python\nx = 1\n\ny = 2\n```\n````\n\n后文"
        XCTAssertEqual(BubbleModeRow.splitBlocks(text),
                       ["前文", "````markdown\n```python\nx = 1\n\ny = 2\n```\n````", "后文"])
    }

    /// 三个反引号包三个反引号：推断嵌套，整块留在一个泡里
    func testSplitBlocksInfersSameLengthNesting() {
        let text = "前文\n\n```markdown\n# 外层\n\n```python\nx = 1\n```\n\n还在外层\n```\n\n后文"
        let blocks = BubbleModeRow.splitBlocks(text)
        XCTAssertEqual(blocks.count, 3, "\(blocks)")
        XCTAssertEqual(blocks.first, "前文")
        XCTAssertEqual(blocks.last, "后文")
        XCTAssertTrue(blocks[1].contains("还在外层"))
        XCTAssertEqual(s(blocks[1]), blocks[1])   // 代码里的 # 不被拍成加粗
    }

    func testInlineFormattingKept() {
        let text = "**加粗** 和 *斜体* 和 `行内代码` 和 [链接](https://a.b)"
        XCTAssertEqual(s(text), text)
    }

    func testBlockquoteKept() {
        XCTAssertEqual(s("> 引用一句"), "> 引用一句")
    }

    // MARK: - 混合

    func testMixedDocument() {
        let input = """
        ## 方案
        正文一段。
        - 第一点
          - 子点
        ---
        | 列 | 值 |
        |---|---|
        | a | 1 |
        """
        let expected = """
        **方案**
        正文一段。
        - 第一点
        - 子点
        | 列 | 值 |
        |---|---|
        | a | 1 |
        """
        XCTAssertEqual(s(input), expected)
    }
}
