import XCTest

/// [PROBE] 键盘吞输入框复现（research-keyboard-list-inset 追凶）：
/// 机器人点输入框唤键盘 → 断言输入区元素仍存在且在屏内。外部并行 simctl 截图对照。
final class KeyboardInputBarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testInputBarSurvivesKeyboard() {
        let app = XCUIApplication()
        app.launch()
        sleep(7)  // 启动 + 草稿态就位（外部在此窗口截 before 图）

        NSLog("[KB PROBE] === before tap === textViews=\(app.textViews.count) textFields=\(app.textFields.count) keyboards=\(app.keyboards.count)")

        // 点底部输入条（草稿态输入框 ~93% 高度处，参照冒烟截图）
        let inputPos = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93))
        inputPos.tap()
        sleep(4)  // 键盘动画 + 稳定（外部在此窗口截 after 图）

        let kbUp = app.keyboards.count > 0
        NSLog("[KB PROBE] === after tap === keyboards=\(app.keyboards.count) textViews=\(app.textViews.count) textFields=\(app.textFields.count)")

        // 输入区元素取证：存在性 + frame（消失=不存在 or frame 出屏/零尺寸）
        let tv = app.textViews.firstMatch
        let tf = app.textFields.firstMatch
        if tv.exists { NSLog("[KB PROBE] textView frame=\(tv.frame) hittable=\(tv.isHittable)") }
        if tf.exists { NSLog("[KB PROBE] textField frame=\(tf.frame) hittable=\(tf.isHittable)") }
        if !tv.exists && !tf.exists {
            NSLog("[KB PROBE] ❌ 输入框元素完全不在树里")
            // dump 屏幕底部元素概况
            NSLog("[KB PROBE] buttons=\(app.buttons.count) otherElements(前5)=\(app.otherElements.allElementsBoundByIndex.prefix(5).map { "\($0.identifier):\($0.frame)" })")
        }

        XCTAssertTrue(kbUp, "键盘没起来（tap 没点中输入框？）")
        // 判定=输入框底边在键盘顶之上（UIScreen.main 在 runner 进程不可靠，曾致误报）
        let kbTop = app.keyboards.firstMatch.frame.minY
        let inputAlive = (tv.exists && tv.frame.height > 1 && tv.frame.maxY <= kbTop + 1)
            || (tf.exists && tf.frame.height > 1 && tf.frame.maxY <= kbTop + 1)
        NSLog("[KB PROBE] verdict: inputAlive=\(inputAlive) kbTop=\(kbTop)")
        XCTAssertTrue(inputAlive, "键盘弹起后输入框消失/被键盘盖（粟粟报的 bug）")

        sleep(3)  // 尾窗口（外部补一张截图）
    }
}
