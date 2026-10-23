#if canImport(UIKit)
import UIKit

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 粘滞修饰键（Ctrl / Alt / Shift）。三态视觉照物料表 §2.4：
/// - `inactive`：透明底，Shift 用空心 `shift`
/// - `oneShot`：active 底，Shift 换 `shift.fill`，无锁定条
/// - `locked`：同 oneShot 的底，再加底部居中 **2pt 高、60% 键宽**的 lock bar，alpha 0.15s 动画
///
/// Esc 不走这里 —— 它虽然跟 Ctrl/Alt/Shift 同属修饰组，但点击直接发 `0x1B`，从不进三态
/// （物料表 §2.1 末条）。
final class TerminalModifierButton: TerminalKeyButton {
    let modifier: TerminalKeyModifiers
    private let lockBar = UIView()

    var phase: TerminalModifierState.Phase = .inactive {
        didSet { guard phase != oldValue else { return }; applyPhase() }
    }

    init(slot: TerminalKeySlot, sizes: TerminalToolbarSizes, modifier: TerminalKeyModifiers) {
        self.modifier = modifier
        super.init(slot: slot, sizes: sizes)

        lockBar.backgroundColor = .label
        lockBar.layer.cornerRadius = 1
        lockBar.alpha = 0
        lockBar.isUserInteractionEnabled = false
        lockBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lockBar)
        NSLayoutConstraint.activate([
            lockBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            lockBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            lockBar.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.6),
            lockBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        applyPhase()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyPhase() {
        let activeBackground = UIColor.label.withAlphaComponent(0.16)
        switch phase {
        case .inactive:
            stickyBackgroundColor = nil
            if modifier == .shift { setIcon("shift") }
            accessibilityValue = nil
            accessibilityTraits.remove(.selected)
        case .oneShot:
            stickyBackgroundColor = activeBackground
            if modifier == .shift { setIcon("shift.fill") }
            accessibilityValue = "单次"
            accessibilityTraits.insert(.selected)
        case .locked:
            stickyBackgroundColor = activeBackground
            if modifier == .shift { setIcon("shift.fill") }
            accessibilityValue = "锁定"
            accessibilityTraits.insert(.selected)
        }
        UIView.animate(withDuration: 0.15) {
            self.lockBar.alpha = self.phase == .locked ? 1 : 0
        }
    }
}
#endif
