import XCTest

/// XCUITest — 自动 inject 5 个测试场景的 touch 事件，配合 [PROBE 贴纸] log 看根因。
/// fixture 已让 app 启动后自动 select probe conv + 进编辑模式，UITest 只负责发 touch。
final class StickerProbeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testStickerEditModeGestures() {
        let app = XCUIApplication()
        app.launchArguments = ["--sticker-probe-seed"]
        app.launch()

        // 等 fixture: 0.3s onAppear + 5s contentHeight 测量 + 进编辑模式 + buffer
        sleep(8)

        // PlacedSticker 位置 (180, 300)：iPhone 17 Pro 屏幕 402×874
        // normalized: (180/402, 300/874) ≈ (0.448, 0.343)
        let stickerPos = app.coordinate(withNormalizedOffset: CGVector(dx: 0.448, dy: 0.343))

        // === 场景 1: tap 贴纸（首次浮起）===
        NSLog("[PROBE 贴纸 UITest] step1: tap sticker first time")
        stickerPos.tap()
        sleep(2)

        // === 场景 2: 单指 drag（核心 — 看 pan 是否触发）===
        NSLog("[PROBE 贴纸 UITest] step2: single-finger drag")
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        stickerPos.press(forDuration: 0.1, thenDragTo: dragEnd)
        sleep(2)

        // === 场景 3: 第二次 tap（看是否还浮起）===
        NSLog("[PROBE 贴纸 UITest] step3: tap second time")
        // 贴纸已被 drag 到 dragEnd，新位置 tap
        dragEnd.tap()
        sleep(2)

        // === 场景 4: 双指 pinch ===
        NSLog("[PROBE 贴纸 UITest] step4: pinch")
        app.pinch(withScale: 1.5, velocity: 1.0)
        sleep(2)

        NSLog("[PROBE 贴纸 UITest] DONE")
    }
}
