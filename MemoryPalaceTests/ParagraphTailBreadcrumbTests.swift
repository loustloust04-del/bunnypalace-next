import XCTest
import SwiftStreamingMarkdown
@testable import 记忆花园

/// 段尾丢字探针 B 的面包屑文案：只有 id 前 8 位 / 泡序号 / 块序号 / 字数 / 尺寸，没有正文
final class ParagraphTailBreadcrumbTests: XCTestCase {

    func testTagIsNodePrefixPlusBubble() {
        XCTAssertEqual(ParagraphTailBreadcrumb.tag(nodeId: "3F2A9C1E-7B44-4D0A-9E21-ABCDEF012345", bubble: nil), "3F2A9C1E")
        XCTAssertEqual(ParagraphTailBreadcrumb.tag(nodeId: "3F2A9C1E-7B44-4D0A-9E21-ABCDEF012345", bubble: 2), "3F2A9C1E 泡2")
        XCTAssertNil(ParagraphTailBreadcrumb.tag(nodeId: nil, bubble: 1))
    }

    func testMessageCarriesOnlyIdsCountsAndSizes() {
        let report = ParagraphLayoutProbe.Report(tag: "3F2A9C1E 泡2", block: 0, missing: 6, length: 58,
                                                 width: 312, height: 88.67, needed: 110)
        XCTAssertEqual(ParagraphTailBreadcrumb.message(report),
                       "段尾没排进来：3F2A9C1E 泡2 第0块，少 6 字（共 58）· 宽 312.00 高 88.67 需 110.00")
        let noTag = ParagraphLayoutProbe.Report(tag: nil, block: nil, missing: 1, length: 3, width: 1, height: 1, needed: 2)
        XCTAssertEqual(ParagraphTailBreadcrumb.message(noTag), "段尾没排进来：无节点 第?块，少 1 字（共 3）· 宽 1.00 高 1.00 需 2.00")
    }
}
