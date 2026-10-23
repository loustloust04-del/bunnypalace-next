#if os(iOS)
import SwiftUI
import UIKit

/// 群聊长按浮层（plan-group-room-longpress，学 p3 录屏；背景 / 菜单 / 投影学 page1 的 BubbleMenuOverlayView）：
/// 盖在整个窗口上（含 SwiftUI 顶部），35% 强度轻模糊 + 12% 压暗（后面的字隐约可见）；
/// 被按的气泡原位浮起（放大 1.03），上面一条玻璃表情条，下面一张玻璃菜单卡。放不下时三者一起上下挪进可见区。
/// 点空白 / 点气泡收起；点表情 = 切换回应并收起；菜单项各自决定收不收（「显示时间」就地换字，再点才收）。
final class GroupMessageActionOverlay: UIView {
    struct MenuItem {
        let title: String
        let systemImage: String
        var isDestructive = false
        /// 点了不收起，这行就地换成这段字；再点收起
        var revealedTitle: String?
        /// 这行上面是组界（画一段短发丝线 + 上下呼吸位，组内行之间不画线——iOS 26 原生菜单 / page1 同款）
        var dividerBefore = false
        var action: (() -> Void)?
    }

    static let emojis = ["👍", "❤️", "😂", "👀", "🎉", "🔥", "😢", "🤔", "✅", "🙏", "💯", "❌"]
    private static let barHeight: CGFloat = 56
    private static let emojiSize: CGFloat = 44
    // 菜单按 page1 规格：宽 235 / 行高 40 / 字号 15 / 图标槽 24 / 左 24 右 20 / 上下 6 / 圆角 24
    private static let menuWidth: CGFloat = 235
    private static let rowHeight: CGFloat = 40
    private static let menuPadV: CGFloat = 6
    private static let dividerBand: CGFloat = 10
    private static let hintHeight: CGFloat = 40
    private static let menuCorner: CGFloat = 24
    private static let gap: CGFloat = 10
    private static let margin: CGFloat = 16
    private static let lift: CGFloat = 1.03

    var onReact: ((String) -> Void)?

    private let blur = UIVisualEffectView(effect: nil)
    /// 部分强度模糊：动画器停在 35%（page1 SoftBlurView 同一个技巧；系统材质全强度会把背景糊成一块奶灰）
    private var blurAnimator: UIViewPropertyAnimator?
    private let dim = UIView()
    private let preview: GroupBubbleView
    private let sourceFrame: CGRect
    private let bar = UIVisualEffectView(effect: nil)
    private let barScroll = UIScrollView()
    private let menu = UIVisualEffectView(effect: nil)
    /// 菜单外面再包一层只为投影（玻璃要 clipsToBounds，投影画不出来）
    private let menuWrap = UIView()
    private var rows: [(item: MenuItem, row: MenuRow)] = []
    private let hint = MenuRow(hintText: "双击文字可以选中一段复制。")
    private var revealed = Set<Int>()
    private var isDismissing = false

    /// `source` 是列表里被按的气泡；`selected` 是这条已有的回应
    init(source: GroupBubbleView, selected: Set<String>, items: [MenuItem]) {
        preview = source.makeCopy()
        sourceFrame = source.convert(source.bounds, to: nil)
        super.init(frame: .zero)
        accessibilityViewIsModal = true

        blur.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backgroundTapped)))
        addSubview(blur)
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [blur] in
            blur.effect = UIBlurEffect(style: .regular)
        }
        animator.fractionComplete = 0.35
        animator.pausesOnCompletion = true
        blurAnimator = animator
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        dim.isUserInteractionEnabled = false
        addSubview(dim)

        preview.isUserInteractionEnabled = false
        preview.isAccessibilityElement = true
        preview.accessibilityLabel = source.textView.attributedText?.string
        addSubview(preview)

        buildBar(selected: selected)
        buildMenu(items)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { blurAnimator?.stopAnimation(true) }

    // MARK: 搭建

    private func buildBar(selected: Set<String>) {
        bar.cornerConfiguration = .capsule()
        bar.clipsToBounds = true
        barScroll.showsHorizontalScrollIndicator = false
        barScroll.alwaysBounceHorizontal = true
        bar.contentView.addSubview(barScroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        barScroll.addSubview(stack)
        for emoji in Self.emojis {
            let button = UIButton(type: .custom)
            button.setTitle(emoji, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 28)
            button.layer.cornerRadius = Self.emojiSize / 2
            if selected.contains(emoji) {
                button.backgroundColor = UIColor(Theme.textPrimary).withAlphaComponent(0.1)
                button.accessibilityTraits.insert(.selected)
            }
            button.accessibilityLabel = emoji
            button.addAction(UIAction { [weak self] _ in self?.react(emoji) }, for: .touchUpInside)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.emojiSize),
                button.heightAnchor.constraint(equalToConstant: Self.emojiSize),
            ])
            stack.addArrangedSubview(button)
        }
        let inset = (Self.barHeight - Self.emojiSize) / 2
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: barScroll.contentLayoutGuide.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: barScroll.contentLayoutGuide.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: barScroll.contentLayoutGuide.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: barScroll.contentLayoutGuide.trailingAnchor, constant: -inset),
            stack.heightAnchor.constraint(equalTo: barScroll.frameLayoutGuide.heightAnchor, constant: -2 * inset),
        ])
        addSubview(bar)
    }

    private func buildMenu(_ items: [MenuItem]) {
        menu.cornerConfiguration = .corners(radius: .fixed(Self.menuCorner))
        menu.clipsToBounds = true
        for (index, item) in items.enumerated() {
            let row = MenuRow(title: item.title, systemImage: item.systemImage, isDestructive: item.isDestructive)
            row.addAction(UIAction { [weak self] _ in self?.tapRow(index) }, for: .touchUpInside)
            menu.contentView.addSubview(row)
            rows.append((item, row))
        }
        menu.contentView.addSubview(hint)
        // 投影立起来（page1：black 12%、半径 28、下移 10）
        menuWrap.layer.shadowColor = UIColor.black.cgColor
        menuWrap.layer.shadowOpacity = 0.12
        menuWrap.layer.shadowRadius = 14
        menuWrap.layer.shadowOffset = CGSize(width: 0, height: 10)
        menuWrap.addSubview(menu)
        addSubview(menuWrap)
    }

    private var menuHeight: CGFloat {
        let bands = rows.enumerated().filter { $0.offset > 0 && $0.element.item.dividerBefore }.count
        return Self.menuPadV * 2 + CGFloat(rows.count) * Self.rowHeight
            + CGFloat(bands + 1) * Self.dividerBand * 2 + Self.hintHeight
    }

    // MARK: 出现 / 收起

    /// `bottomLimit`：可见区下沿（窗口坐标，键盘弹着时是键盘上沿）
    func present(in window: UIWindow, bottomLimit: CGFloat) {
        frame = window.bounds
        window.addSubview(self)
        blur.frame = bounds
        dim.frame = bounds
        dim.alpha = 0
        preview.frame = sourceFrame
        preview.layoutIfNeeded()

        // 浮起后的外形（含画在 bounds 外的尾巴），按它排表情条 / 菜单
        let tail = max(0, preview.bubblePath.boundingBoxOfPath.maxY - preview.bounds.height)
        let lifted = sourceFrame.insetBy(dx: -sourceFrame.width * (Self.lift - 1) / 2,
                                         dy: -sourceFrame.height * (Self.lift - 1) / 2)
        let menuHeight = self.menuHeight
        let minY = window.safeAreaInsets.top + 8
        let maxY = min(bottomLimit, bounds.height - window.safeAreaInsets.bottom) - 8
        var barTop = lifted.minY - Self.gap - Self.barHeight
        let total = Self.barHeight + Self.gap + lifted.height + tail + Self.gap + menuHeight
        if barTop + total > maxY { barTop = maxY - total }
        if barTop < minY { barTop = minY }
        let shift = barTop + Self.barHeight + Self.gap - lifted.minY
        // 泡太高一屏放不下：菜单压在泡的下半截上
        let menuTop = min(lifted.maxY + shift + tail + Self.gap, maxY - menuHeight)

        bar.frame = CGRect(x: Self.margin, y: barTop, width: bounds.width - 2 * Self.margin, height: Self.barHeight)
        barScroll.frame = bar.bounds
        let menuX = preview.isUser
            ? min(bounds.width - Self.margin, sourceFrame.maxX) - Self.menuWidth
            : max(Self.margin, sourceFrame.minX)
        menuWrap.frame = CGRect(x: max(Self.margin, menuX), y: menuTop, width: Self.menuWidth, height: menuHeight)
        menu.frame = menuWrap.bounds
        menuWrap.layer.shadowPath = UIBezierPath(roundedRect: menuWrap.bounds, cornerRadius: Self.menuCorner).cgPath
        layoutRows()
        // 浮起的气泡也投影（page1：black 16%、半径 24、下移 8），跟背景分层
        preview.layer.shadowColor = UIColor.black.cgColor
        preview.layer.shadowOpacity = 0.16
        preview.layer.shadowRadius = 12
        preview.layer.shadowOffset = CGSize(width: 0, height: 8)
        preview.layer.shadowPath = preview.bubblePath

        let targetCenter = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY + shift)
        bar.contentView.alpha = 0
        menu.contentView.alpha = 0
        bar.transform = CGAffineTransform(translationX: 0, y: 16).scaledBy(x: 0.9, y: 0.9)
        menuWrap.transform = CGAffineTransform(translationX: 0, y: -16).scaledBy(x: 0.9, y: 0.9)
        menuWrap.alpha = 0
        blur.alpha = 0

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIView.animate(withDuration: 0.25) {
            self.blur.alpha = 1
            self.dim.alpha = 1
        }
        UIView.animate(springDuration: 0.42, bounce: 0.28) {
            self.preview.center = targetCenter
            self.preview.transform = CGAffineTransform(scaleX: Self.lift, y: Self.lift)
            self.bar.effect = UIGlassEffect()
            self.menu.effect = UIGlassEffect()
            self.bar.contentView.alpha = 1
            self.menu.contentView.alpha = 1
            self.bar.transform = .identity
            self.menuWrap.transform = .identity
            self.menuWrap.alpha = 1
        }
        UIAccessibility.post(notification: .screenChanged, argument: bar)
    }

    private func layoutRows() {
        var y = Self.menuPadV
        for (index, entry) in rows.enumerated() {
            if index > 0 && entry.item.dividerBefore { y = addDivider(at: y) }
            entry.row.frame = CGRect(x: 0, y: y, width: Self.menuWidth, height: Self.rowHeight)
            y += Self.rowHeight
        }
        // 底部提示行（page1 同款，非交互小字）
        y = addDivider(at: y)
        hint.frame = CGRect(x: 0, y: y, width: Self.menuWidth, height: Self.hintHeight)
    }

    /// 组界：两端缩进 20 的发丝线 + 上下各 10 呼吸位；返回下一行的 y
    private func addDivider(at y: CGFloat) -> CGFloat {
        let hairline = 1 / max(1, traitCollection.displayScale)
        let line = UIView(frame: CGRect(x: 20, y: y + Self.dividerBand - hairline / 2,
                                        width: Self.menuWidth - 40, height: hairline))
        line.backgroundColor = .separator
        menu.contentView.addSubview(line)
        return y + Self.dividerBand * 2
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        isUserInteractionEnabled = false
        let sourceCenter = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn]) {
            self.blur.alpha = 0
            self.dim.alpha = 0
            self.preview.center = sourceCenter
            self.preview.transform = .identity
            self.bar.effect = nil
            self.menu.effect = nil
            self.bar.contentView.alpha = 0
            self.menu.contentView.alpha = 0
            self.bar.transform = CGAffineTransform(translationX: 0, y: 12).scaledBy(x: 0.92, y: 0.92)
            self.menuWrap.transform = CGAffineTransform(translationX: 0, y: -12).scaledBy(x: 0.92, y: 0.92)
            self.menuWrap.alpha = 0
        } completion: { _ in
            self.blurAnimator?.stopAnimation(true)
            self.removeFromSuperview()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }

    // MARK: 交互

    @objc private func backgroundTapped() { dismiss() }

    private func react(_ emoji: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onReact?(emoji)
        dismiss()
    }

    private func tapRow(_ index: Int) {
        let item = rows[index].item
        if let revealedTitle = item.revealedTitle, !revealed.contains(index) {
            revealed.insert(index)
            rows[index].row.title = revealedTitle
            return
        }
        item.action?()
        dismiss()
    }
}
/// 菜单一行：图标固定 24 槽 + 15 号字，按住整行浅高亮；`hintText` 版是底部非交互提示（灯泡 + 12 号灰字）
private final class MenuRow: UIControl {
    private let icon = UIImageView()
    private let label = UILabel()
    private let isHint: Bool

    var title: String {
        get { label.text ?? "" }
        set { label.text = newValue; accessibilityLabel = newValue }
    }

    init(title: String, systemImage: String, isDestructive: Bool) {
        isHint = false
        super.init(frame: .zero)
        let color = isDestructive ? UIColor.systemRed : UIColor(Theme.textPrimary)
        icon.image = UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15))
        icon.tintColor = color
        label.font = .systemFont(ofSize: 15)
        label.textColor = color
        self.title = title
        isAccessibilityElement = true
        accessibilityTraits = .button
        setUp()
    }

    init(hintText: String) {
        isHint = true
        super.init(frame: .zero)
        let color = UIColor(Theme.textMuted)
        icon.image = UIImage(systemName: "lightbulb", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15))
        icon.tintColor = color
        label.font = .systemFont(ofSize: 12)
        label.textColor = color
        label.numberOfLines = 2
        label.text = hintText
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = hintText
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setUp() {
        icon.contentMode = .center
        addSubview(icon)
        addSubview(label)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 24, y: 0, width: 24, height: bounds.height)
        label.frame = CGRect(x: 24 + 24 + 14, y: 0, width: bounds.width - 62 - 20, height: bounds.height)
    }

    override var isHighlighted: Bool {
        didSet { if !isHint { backgroundColor = isHighlighted ? UIColor.label.withAlphaComponent(0.1) : .clear } }
    }
}
#endif
