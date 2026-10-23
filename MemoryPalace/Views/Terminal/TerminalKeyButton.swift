#if canImport(UIKit)
import UIKit

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 工具条上的一个键。符号键画字符本身、其余画 SF Symbol（物料表 §1.3 首段）。
///
/// 用 `UIControl` 而不是 `UIButton`：C4 的粘滞三态要自己管背景/lock bar，
/// 长按连发也要自己接 touch 序列。
class TerminalKeyButton: UIControl {
    let slot: TerminalKeySlot
    private let label = UILabel()
    private let iconView = UIImageView()
    private let bg = UIView()

    var sizes: TerminalToolbarSizes { didSet { applySizes() } }
    /// 宽键（修饰键 / joystick / 方向键，物料表 §9.4）
    var isWide: Bool
    /// 长按连发（Tab 和方向键）。按下立即发 → 0.225s 后每 0.1s 一次（物料表 §3.3）
    var repeatsOnHold = false
    var onPress: ((TerminalKeySlot) -> Void)?

    private var repeatTimer: Timer?
    private static let repeatDelay: TimeInterval = 0.225
    private static let repeatInterval: TimeInterval = 0.1

    init(slot: TerminalKeySlot, sizes: TerminalToolbarSizes) {
        self.slot = slot
        self.sizes = sizes
        self.isWide = slot.builtInID?.isWide ?? false
        super.init(frame: .zero)

        bg.isUserInteractionEnabled = false
        bg.backgroundColor = .clear
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        label.textAlignment = .center
        label.textColor = .label
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .label
        iconView.isUserInteractionEnabled = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(iconView)

        NSLayoutConstraint.activate([
            bg.centerXAnchor.constraint(equalTo: centerXAnchor),
            bg.centerYAnchor.constraint(equalTo: centerYAnchor),
            bg.widthAnchor.constraint(equalTo: widthAnchor),
            bg.heightAnchor.constraint(equalTo: heightAnchor),
            label.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            iconView.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])

        applySizes()
        addTarget(self, action: #selector(handleUpInside), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { repeatTimer?.invalidate() }

    // MARK: 外观

    func setTitle(_ text: String) {
        label.text = text
        label.isHidden = false
        iconView.isHidden = true
    }

    func setIcon(_ systemName: String) {
        iconView.image = UIImage(systemName: systemName)
        iconView.isHidden = false
        label.isHidden = true
    }

    private func applySizes() {
        label.font = .systemFont(ofSize: sizes.fontSize, weight: .regular)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: sizes.symbolSize,
                                                                            weight: .regular)
        bg.layer.cornerRadius = sizes.buttonCorner
        bg.layer.cornerCurve = .continuous
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: isWide ? sizes.wideWidth : sizes.normalWidth, height: sizes.buttonHeight)
    }

    /// 手指按下时的临时高亮（跟 C4 的粘滞态背景分开，那个走 `stickyBackgroundColor`）
    var stickyBackgroundColor: UIColor? { didSet { refreshBackground() } }

    override var isHighlighted: Bool { didSet { refreshBackground() } }

    private func refreshBackground() {
        if let sticky = stickyBackgroundColor {
            bg.backgroundColor = isHighlighted ? sticky.withAlphaComponent(0.85) : sticky
        } else {
            bg.backgroundColor = isHighlighted ? UIColor.label.withAlphaComponent(0.16) : .clear
        }
    }

    // MARK: 触摸

    /// 普通键 **抬手才发**（跟系统键盘一致；抽屉是横滚的，按下就发会让每次滑动都误发一串符号）。
    /// 连发键例外：按下立即发，好让长按 Tab/方向键跟手。
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard repeatsOnHold else { return }
        fire()
        repeatTimer?.invalidate()
        let slot = self.slot
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval,
                                                    repeats: true) { [weak self] _ in
                self?.onPress?(slot)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopRepeat()
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopRepeat()
        super.touchesCancelled(touches, with: event)
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    /// joystick 用：原地点一下**不发键**，必须拖出死区才有方向（物料表 §3.1）
    var suppressesTapSend = false

    @objc private func handleUpInside() {
        // 连发键已经在 touchesBegan 发过第一下了，抬手不再补一次
        guard !repeatsOnHold, !suppressesTapSend else { return }
        fire()
    }

    func fire() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onPress?(slot)
    }
}
#endif
