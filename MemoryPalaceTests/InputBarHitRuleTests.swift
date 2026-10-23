import XCTest
@testable import 记忆花园

/// ➕ 面板被透明输入条挡住（astra R6 C1）：输入条只是占位时整块放行
final class InputBarHitRuleTests: XCTestCase {
    func testPlaceholderPassesEverythingThrough() {
        // carrier 高 800、可见栈 320（贴纸网格占位）：以前 480 以下全被吃掉
        XCTAssertTrue(InputBarHitRule.passesThrough(pointY: 700, carrierHeight: 800, visibleHeight: 320, isPlaceholder: true))
        XCTAssertTrue(InputBarHitRule.passesThrough(pointY: 790, carrierHeight: 800, visibleHeight: 60, isPlaceholder: true))
    }

    func testRealInputBarKeepsItsArea() {
        XCTAssertFalse(InputBarHitRule.passesThrough(pointY: 760, carrierHeight: 800, visibleHeight: 74, isPlaceholder: false))
        XCTAssertTrue(InputBarHitRule.passesThrough(pointY: 700, carrierHeight: 800, visibleHeight: 74, isPlaceholder: false))   // 栈上方空白照旧放行
        XCTAssertFalse(InputBarHitRule.passesThrough(pointY: 724, carrierHeight: 800, visibleHeight: 74, isPlaceholder: false))  // 4pt 余量
    }

    /// 录语音锁定后，输入条上方的锁 + 大按钮那块不放行（plan-voice-note M5c）
    func testRecordingHitRectKeepsLockAndBigButton() {
        // carrier 800、可见栈 74 → 栈顶 726；锁 + 大按钮在栈坐标 (300, -170)…(410, 70)
        let rect = CGRect(x: 300, y: -170, width: 110, height: 240)
        // 锁（栈顶上方 ~144）：carrier y = 726 - 144 = 582
        XCTAssertFalse(InputBarHitRule.passesThrough(pointY: 582, carrierHeight: 800, visibleHeight: 74, isPlaceholder: false,
                                                     pointX: 350, recordingHitRect: rect))
        // 同一高度、横向在框外：照旧放行给列表
        XCTAssertTrue(InputBarHitRule.passesThrough(pointY: 582, carrierHeight: 800, visibleHeight: 74, isPlaceholder: false,
                                                    pointX: 100, recordingHitRect: rect))
        // 框上方：放行
        XCTAssertTrue(InputBarHitRule.passesThrough(pointY: 540, carrierHeight: 800, visibleHeight: 74, isPlaceholder: false,
                                                    pointX: 350, recordingHitRect: rect))
        // 没录音（nil）：同一点放行
        XCTAssertTrue(InputBarHitRule.passesThrough(pointY: 582, carrierHeight: 800, visibleHeight: 74, isPlaceholder: false,
                                                    pointX: 350, recordingHitRect: nil))
        // 栈内照旧不放行
        XCTAssertFalse(InputBarHitRule.passesThrough(pointY: 760, carrierHeight: 800, visibleHeight: 74, isPlaceholder: false,
                                                     pointX: 100, recordingHitRect: rect))
    }

    func testRecordingHitRectFollowsBarTopWhenKeyboardGrowsStack() {
        // 栈变高（多一行附件 166）：同一个栈坐标框跟着栈顶上移
        let rect = CGRect(x: 300, y: -170, width: 110, height: 240)
        let top = 800.0 - 166
        XCTAssertFalse(InputBarHitRule.passesThrough(pointY: top - 144, carrierHeight: 800, visibleHeight: 166, isPlaceholder: false,
                                                     pointX: 350, recordingHitRect: rect))
        XCTAssertTrue(InputBarHitRule.passesThrough(pointY: top - 200, carrierHeight: 800, visibleHeight: 166, isPlaceholder: false,
                                                    pointX: 350, recordingHitRect: rect))
    }

    func testPlaceholderStateFollowsPanel() {
        XCTAssertTrue(InputBarHitRule.isPlaceholder(searchActive: false, stickerPanel: true, editingStickers: false))
        XCTAssertTrue(InputBarHitRule.isPlaceholder(searchActive: false, stickerPanel: false, editingStickers: true))
        XCTAssertFalse(InputBarHitRule.isPlaceholder(searchActive: true, stickerPanel: true, editingStickers: true))   // 查找栏优先、可点
        XCTAssertFalse(InputBarHitRule.isPlaceholder(searchActive: false, stickerPanel: false, editingStickers: false))
    }
}
