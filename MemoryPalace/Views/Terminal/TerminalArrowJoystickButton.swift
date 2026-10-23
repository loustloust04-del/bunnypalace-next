#if canImport(UIKit)
import UIKit

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 方向摇杆（物料表 §3）。按住往一个方向拖，出死区就开始发方向键，拖回死区停。
///
/// **只抄 joystick 模式**。rootshell 的这个键是双模式（原地长按 1.5s 在 joystick / 抽屉之间切），
/// 粟粟批注 §五-4 明确不抄 —— 双模式切换太隐蔽，还得专门写文档教。四个独立方向键照样提供，
/// 默认就放在抽屉里（`TerminalToolbarLayout.defaultDrawerRow`）。
final class TerminalArrowJoystickButton: TerminalKeyButton {
    /// 拖出方向就回调。粘滞修饰由上层 union 后合成字节（物料表 §3.2）
    var onDirection: ((TerminalKeyCombo.SpecialKey) -> Void)?

    /// 拖进一个方向后等多久开始连发
    static let repeatDelay: TimeInterval = 0.5
    /// 连发间隔
    static let repeatInterval: TimeInterval = 0.1

    /// 起点是 **touchesBegan 时的手指位置**，不是按钮中心（物料表 §3.2）
    private var origin: CGPoint?
    private var direction: TerminalKeyCombo.SpecialKey?
    private var delayTimer: Timer?
    private var repeater: Timer?

    override init(slot: TerminalKeySlot, sizes: TerminalToolbarSizes) {
        super.init(slot: slot, sizes: sizes)
        // 原地点一下不发键，必须拖出死区（物料表 §3.1）
        suppressesTapSend = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        delayTimer?.invalidate()
        repeater?.invalidate()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        origin = touches.first?.location(in: self)
        direction = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let origin, let p = touches.first?.location(in: self) else { return }
        let next = TerminalJoystickGeometry.direction(dx: p.x - origin.x, dy: p.y - origin.y)
        guard next != direction else { return }
        // 方向变了：停旧连发 → 立即发一次新方向 → 重新起 delay（物料表 §3.2/§3.3）
        stopRepeat()
        direction = next
        guard let next else { return }   // 拖回死区 = 停发
        emit(next)
        let delay = Self.repeatDelay
        delayTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let d = self.direction else { return }
            self.emit(d)                 // 0.5s 到点先补一发，之后才进 0.1s 节拍
            self.repeater = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval,
                                                 repeats: true) { [weak self] _ in
                guard let self, let d = self.direction else { return }
                self.emit(d)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish()
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish()
        super.touchesCancelled(touches, with: event)
    }

    private func finish() {
        stopRepeat()
        origin = nil
        direction = nil
    }

    private func stopRepeat() {
        delayTimer?.invalidate()
        delayTimer = nil
        repeater?.invalidate()
        repeater = nil
    }

    private func emit(_ d: TerminalKeyCombo.SpecialKey) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onDirection?(d)
    }
}
#endif
