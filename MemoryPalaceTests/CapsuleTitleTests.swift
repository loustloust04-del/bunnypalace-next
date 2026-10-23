#if os(macOS)
import XCTest
@testable import 记忆花园

/// 顶部悬浮条那颗的标题截断（09-16 她实拍：一条 `<channel source=…>` 当标题的编程会话
/// 把整条胶囊连同「工具」和齿轮一起顶出了窗口）。`.frame(maxWidth:)` 压不住固有宽度超标的 Text，
/// 所以必须在字符串层面先截断——按显示宽度算，一个汉字顶两个字母
final class CapsuleTitleTests: XCTestCase {

    private func width<S: StringProtocol>(_ s: S) -> Int {
        s.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    }

    func testShortTitlesUntouched() {
        XCTAssertEqual(ContentView.capsuleTitle("mac1"), "mac1")
        XCTAssertEqual(ContentView.capsuleTitle("新对话"), "新对话")
        XCTAssertEqual(ContentView.capsuleTitle(""), "")
    }

    func testLongASCIITitleIsClipped() {
        let raw = "<channel source=\"memorypalace\" chat_id=\"32A99134-248D-4B48-B1F-1A49A9A558BD\" mes"
        let out = ContentView.capsuleTitle(raw)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertLessThanOrEqual(width(out.dropLast()), 24)
        XCTAssertTrue(raw.hasPrefix(String(out.dropLast())), "截断只截尾巴，不改原文")
    }

    /// 汉字按两倍宽算：24 的预算下最多 12 个字，不能按「字数 ≤ 24」放行
    func testCJKCountsDouble() {
        let out = ContentView.capsuleTitle(String(repeating: "记", count: 40))
        XCTAssertEqual(out.count, 13, "12 个字 + 省略号")
        XCTAssertLessThanOrEqual(width(out.dropLast()), 24)
    }

    /// 刚好卡在预算边界上不该多截一个字
    func testExactBudgetKeepsEverything() {
        let raw = String(repeating: "a", count: 24)
        XCTAssertEqual(ContentView.capsuleTitle(raw), raw)
        XCTAssertEqual(ContentView.capsuleTitle(raw + "b"), raw + "…")
    }
}
#endif
