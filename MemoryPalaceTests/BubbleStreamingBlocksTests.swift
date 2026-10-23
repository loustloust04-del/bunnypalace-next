import XCTest
@testable import 记忆花园

/// B6 A2' 弹泡模式：流式「已完成段落」判定特征测试。
/// 锁 streamingBlocks 语义：尾块=正在生长不出泡；代码围栏不切半。
final class BubbleStreamingBlocksTests: XCTestCase {

    func testCompletedParagraphsExcludeGrowingTail() {
        let text = "第一段完成了。\n\n第二段也完成了。\n\n第三段还在生"
        XCTAssertEqual(BubbleModeRow.streamingBlocks(text),
                       ["第一段完成了。", "第二段也完成了。"])
    }

    func testUnclosedCodeFenceStaysWholeInTail() {
        let text = "说明段。\n\n```swift\nlet a = 1\n\nlet b = 2\n"
        XCTAssertEqual(BubbleModeRow.streamingBlocks(text), ["说明段。"],
                       "未闭合围栏（含围栏内空行）整体算未完成，不得切半出泡")
    }

    func testEmptyTextYieldsNoBlocks() {
        XCTAssertEqual(BubbleModeRow.streamingBlocks(""), [])
    }

    func testSingleParagraphWithoutBoundaryStaysPending() {
        XCTAssertEqual(BubbleModeRow.streamingBlocks("整段都还没出现空行边界"), [],
                       "无边界=整段仍在生长，只显示 typing dots")
    }
}
