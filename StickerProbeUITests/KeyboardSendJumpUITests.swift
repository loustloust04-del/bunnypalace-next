import XCTest

/// 发送大跳复现器（2026-08-16 粟粟报「发送时气泡跳到屏幕中间再复位」）：
/// 键盘起着 → 打字 → 点发送（插泡 + v7 自动收键盘 + 生成 armed 三事并发）。
/// 只做动作给外部录屏管道抽帧用，不做断言（api seed 对话无 key 发送必失败，
/// 但用户气泡插入 + 收键盘链照走 = 跳的复现面完整）。
final class KeyboardSendJumpUITests: XCTestCase {
    func testSendWhileKeyboardUp() {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed"]
        app.launch()
        sleep(8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        sleep(2)
        app.typeText("hello")
        sleep(2)
        // 发送键：键盘起时输入框右端（早前帧实测 ≈(0.91, 0.615)）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.615)).tap()
        sleep(4)
    }
}
