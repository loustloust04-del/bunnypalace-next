import MemoryCore
import XCTest
@testable import 记忆花园

final class SearchTextSegmenterTests: XCTestCase {

    func testVisibleTextMatchesInConvFindRule() {
        let raw = "[thinking]内心戏[/thinking]正文"
        XCTAssertEqual(ContentCleaner.visibleText(raw, isUser: false, cached: false), "正文")
        XCTAssertEqual(ContentCleaner.visibleText(raw, isUser: true, cached: false), raw)
    }
}
