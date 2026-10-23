#if os(macOS)
import XCTest
@testable import 记忆花园

/// 拖文件进 Code 输入框插的路径（plan-mac-code-mode-gaps §6）：跟终端拖文件同一种反斜杠转义
final class FileDropTests: XCTestCase {
    func testShellEscapedMatchesTerminalDrag() {
        XCTAssertEqual(FileDrop.shellEscaped("/Users/tester/Desktop/a.png"), "/Users/tester/Desktop/a.png")
        XCTAssertEqual(FileDrop.shellEscaped("/Users/tester/Desktop/Screenshot 2026-09-25 at 1.35.50 AM.png"),
                       "/Users/tester/Desktop/Screenshot\\ 2026-09-25\\ at\\ 1.35.50\\ AM.png")
        XCTAssertEqual(FileDrop.shellEscaped("/tmp/记忆(1)'s.png"), "/tmp/记忆\\(1\\)\\'s.png")
    }
}
#endif
