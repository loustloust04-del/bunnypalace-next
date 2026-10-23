import XCTest
@testable import 记忆花园

/// 文件头属性块的解析（她 09-16：文件库预览里 frontmatter 原样当正文排着）。
/// 口径：保序、认不出的行忽略、**绝不吞正文**。
final class MarkdownFrontmatterTests: XCTestCase {

    func testNoFrontmatterKeepsBodyIntact() {
        let md = "# 标题\n\n正文"
        let split = MarkdownFrontmatter.split(md)
        XCTAssertTrue(split.fields.isEmpty)
        XCTAssertEqual(split.body, md)
    }

    /// 保序：显示要按原文顺序，不能像字典那样乱
    func testFieldsKeepSourceOrder() {
        let md = "---\nticker: NVDA\ndate: 2026-08-06\nrating: Overweight\n---\n# 正文"
        let split = MarkdownFrontmatter.split(md)
        XCTAssertEqual(split.fields.map(\.key), ["ticker", "date", "rating"])
        XCTAssertEqual(split.fields.map(\.value), ["NVDA", "2026-08-06", "Overweight"])
        XCTAssertEqual(split.body, "# 正文")
    }

    /// 行内数组摊成顿号分隔
    func testInlineArrayFlattens() {
        let split = MarkdownFrontmatter.split("---\nanalysts: [fundamentals, technical, sentiment]\n---\n正文")
        XCTAssertEqual(split.fields.first?.value, "fundamentals、technical、sentiment")
    }

    /// 缩进的 `- item` 并进上一个字段
    func testIndentedListJoinsPreviousField() {
        let split = MarkdownFrontmatter.split("---\ntags:\n  - 研报\n  - 科技股\ndate: 2026-08-06\n---\n正文")
        XCTAssertEqual(split.fields.map(\.key), ["tags", "date"])
        XCTAssertEqual(split.fields.first?.value, "研报、科技股")
    }

    /// 引号剥掉（含中文引号——她的研报里 data_coverage 就是中文引号包的）
    func testQuotesStripped() {
        let split = MarkdownFrontmatter.split("---\na: \"x y\"\nb: 'z'\nc: “中文”\n---\n正文")
        XCTAssertEqual(split.fields.map(\.value), ["x y", "z", "中文"])
    }

    /// 正文里的分隔线不能被当成收尾——否则正文会被吞掉半截
    func testThematicBreakInBodyIsNotClosingFence() {
        let md = "# 标题\n\n---\n\n下半段"
        XCTAssertEqual(MarkdownFrontmatter.split(md).body, md, "开头不是 --- 就整份原样")

        let withHead = "---\nkey: v\n---\n# 标题\n\n---\n\n下半段"
        let split = MarkdownFrontmatter.split(withHead)
        XCTAssertEqual(split.fields, [MarkdownFrontmatter.Field(key: "key", value: "v")])
        XCTAssertEqual(split.body, "# 标题\n\n---\n\n下半段", "正文里那条分隔线要留着")
    }

    /// 没有收尾的 `---` = 不是 frontmatter，整份当正文（别把文件吃没了）
    func testUnterminatedHeadIsNotFrontmatter() {
        let md = "---\nkey: value\n还没收尾"
        let split = MarkdownFrontmatter.split(md)
        XCTAssertTrue(split.fields.isEmpty)
        XCTAssertEqual(split.body, md)
    }

    /// `----` / `--- foo` 不是收尾行
    func testLongerDashRunIsNotClosingFence() {
        let md = "---\nkey: value\n----\n正文"
        XCTAssertTrue(MarkdownFrontmatter.split(md).fields.isEmpty)
    }

    /// 认不出的行忽略，不影响其它字段
    func testJunkLinesIgnored() {
        let split = MarkdownFrontmatter.split("---\n没有冒号的一行\n: 没有键\nok: 1\n---\n正文")
        XCTAssertEqual(split.fields, [MarkdownFrontmatter.Field(key: "ok", value: "1")])
    }
}
