import XCTest
@testable import 记忆花园

/// #045 T2：设置 › 手机里的小电脑 的状态句（审计 T38）和重置说明（T39）。
final class SandboxStatusTextTests: XCTestCase {

    func testLibraryLines() {
        XCTAssertEqual(SandboxStatusText.library(.mounted(guestPath: "/mnt/library/abc")), "在小电脑里的 /mnt/library/abc")
        XCTAssertEqual(SandboxStatusText.library(.notYet(guestPath: "/mnt/library/abc")), "打开终端或 AI 用到时，接到 /mnt/library/abc")
        XCTAssertTrue(SandboxStatusText.library(.iCloud).contains("iCloud"))
        XCTAssertEqual(SandboxStatusText.library(.problem("bind mount 失败")), "没接进来：bind mount 失败")
        XCTAssertTrue(SandboxStatusText.library(.resetPending).contains("重启"))
        XCTAssertTrue(SandboxStatusText.library(.notInstalled).contains("自动装"))
        // 不再出现「接进来 0 个楼层」这种说法
        XCTAssertFalse(SandboxStatusText.library(.notYet(guestPath: "/x")).contains("0 个"))
    }

    func testResetMessageSaysLibrarySafeAndMentionsOpenTerminals() {
        let none = SandboxStatusText.resetMessage(openTerminals: 0)
        XCTAssertTrue(none.contains("你的文件库不受影响"))
        XCTAssertFalse(none.contains("开着的小电脑终端"))
        let two = SandboxStatusText.resetMessage(openTerminals: 2)
        XCTAssertTrue(two.hasPrefix("会先结束 2 个开着的小电脑终端。"))
        XCTAssertTrue(two.contains("你的文件库不受影响"))
    }
}
