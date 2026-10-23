#if os(iOS)
import SwiftUI
import UIKit

// MARK: - 群聊 UIKit cell（plan-group-room-uikit）
//
// 布局全部手算（`GroupMessageLayout`），flow layout 直接拿高度：加载更早 / 贴底要的 contentSize 是准的，
// 不靠估算高度再修正。气泡 = CAShapeLayer（`BubbleTailPath`，尾巴 0.8）+ UITextView 正文。

enum GroupRoomMetrics {
    static let leading: CGFloat = 10
    static let trailing: CGFloat = 14
    static let avatarSize: CGFloat = 30
    static let avatarGap: CGFloat = 6
    /// 头像底边比最后一个气泡底边再低一点
    static let avatarDrop: CGFloat = 4
    static let paddingH = CGFloat(BubbleModeRow.fixedPaddingH)
    static let paddingV = CGFloat(BubbleModeRow.fixedPaddingV)
    static let bubbleSpacing: CGFloat = 4
    /// 同一人连发挨紧，换人隔开（iMessage 群聊）
    static let runGap: CGFloat = 4
    static let speakerGap: CGFloat = 16
    /// 群聊尾巴比一对一小一点、字小一号（粟粟 09-30）
    static let tailScale: CGFloat = 0.8
    static let textScale: CGFloat = 0.9
    /// 另一侧至少留白（原 SwiftUI Spacer(minLength: 40)）
    static let sideReserve: CGFloat = 40
    static let nameFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
    static let handleFont = UIFont.systemFont(ofSize: 12)
    static let editedFont = UIFont.systemFont(ofSize: 9.5)
    /// 「edited」往下 4、从尾巴那侧往里缩 14，不和尾巴撞
    static let editedTop: CGFloat = 4
    static let editedInset: CGFloat = 14
    /// 回应角标：中线比气泡顶边低 2，最外侧那个圆的圆心压在气泡边上（探出去半个圆）
    static let reactionDrop: CGFloat = 2
    static let reactionOverhang: CGFloat = GroupReactionBadgeView.height / 2

    static var cornerRadius: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: "bubbleModeCornerRadius") as? Double ?? 23)
    }
    static var fontScale: CGFloat {
        let scale = UserDefaults.standard.double(forKey: "fontScale")
        return scale > 0 ? scale : 1.2
    }
    /// 字体来源同气泡模式（selectedFont / fontScale），群聊 ×0.9
    static var bodyFont: UIFont { FontManager.uiFont(size: 13.5 * textScale) }
    static func maxBubbleWidth(listWidth: CGFloat) -> CGFloat { min(listWidth * 0.76, 540) }

    /// 字体 / 圆角设置的指纹：变了布局缓存作废
    static var settingsKey: String {
        "\(UserDefaults.standard.string(forKey: "selectedFont") ?? "")|\(fontScale)|\(cornerRadius)"
    }
}

// MARK: - 消息行模型 + 手算布局

struct GroupMessageRowModel: Equatable {
    let message: AgoraMessage
    let displayName: String
    let handle: String?
    let isOwner: Bool
    /// 一串（同一人连发）的第一条：上面显示名字 + @handle
    let showsName: Bool
    /// 下一条还是他：不带尾巴、头像位置留空
    let continuesRun: Bool
    let topGap: CGFloat
    let memberHandles: Set<String>
    /// 本机表情回应（按点的先后）
    let reactions: [String]
    /// 气泡颜色（设置 / 编辑群聊里选的，nil = 默认）
    var colors = GroupBubbleColors()
}

/// 群聊气泡颜色：对方 / 我（hex，nil = 默认白 / 主题的「你」气泡色）
struct GroupBubbleColors: Equatable {
    var othersHex: String?
    var mineHex: String?
}

@MainActor
struct GroupMessageLayout {
    struct Bubble {
        let frame: CGRect
        let text: NSAttributedString
        let hasTail: Bool
    }

    let bubbles: [Bubble]
    let name: NSAttributedString?
    let nameFrame: CGRect
    let avatarFrame: CGRect?
    let editedFrame: CGRect?
    /// 回应角标（挂在第一个泡的上角）
    let reactionFrame: CGRect?
    let height: CGFloat

    /// UITextView 实测高度（和显示同一套 inset / padding），宽度用 boundingRect 收紧
    private static let sizer: UITextView = {
        let view = UITextView()
        GroupBubbleView.configureTextView(view)
        return view
    }()

    static func measure(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let rect = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let width = min(maxWidth, ceil(rect.width) + 1)
        sizer.attributedText = text
        let height = sizer.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }

    static func texts(for model: GroupMessageRowModel) -> [NSAttributedString] {
        let font = GroupRoomMetrics.bodyFont
        if model.message.isDeleted {
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor(Theme.textMuted)]
            attrs.merge(GroupMarkdownRenderer.italicAttributes(font)) { $1 }
            return [NSAttributedString(string: "此消息已删除", attributes: attrs)]
        }
        let content = model.message.content
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let accent = UIColor(Theme.branchIndicator)
        if model.isOwner {
            // 和气泡模式「你」的气泡同款：纯文本，只把 @handle 标出来
            let style = GroupMarkdownRenderer.Style(
                font: font, textColor: UIColor(Theme.userText), accentColor: accent,
                codeBackground: .clear,
                lineSpacing: 4 * GroupRoomMetrics.fontScale * CGFloat(BubbleModeRow.fixedLineSpacing),
                quoteColor: UIColor(Theme.userText).withAlphaComponent(0.65))
            return GroupMarkdownRenderer.mergingQuoteBlocks(BubbleModeRow.splitBlocks(content)).map {
                GroupMarkdownRenderer.plain($0, style: style, handles: model.memberHandles)
            }
        }
        // 行距 5 = 气泡模式 markdown 正文（fork iOS 段落行距）
        let style = GroupMarkdownRenderer.Style(
            font: font, textColor: UIColor(Theme.assistantText), accentColor: accent,
            codeBackground: UIColor(Theme.accent).withAlphaComponent(0.72), lineSpacing: 5,
            quoteColor: UIColor(Theme.textMuted))
        return GroupMarkdownRenderer.mergingQuoteBlocks(BubbleModeRow.splitBlocks(content))
            .filter { !BubbleMarkdownSimplifier.isRenderEmpty($0) }
            .map { GroupMarkdownRenderer.render(BubbleMarkdownSimplifier.simplify($0), style: style, handles: model.memberHandles) }
    }

    init(model: GroupMessageRowModel, width: CGFloat) {
        typealias M = GroupRoomMetrics
        let isOwner = model.isOwner
        let content = width - M.leading - M.trailing
        let bubbleMax = min(M.maxBubbleWidth(listWidth: width),
                            isOwner ? content - M.sideReserve : content - M.avatarSize - M.avatarGap - M.sideReserve)
        let textMax = max(40, bubbleMax - 2 * M.paddingH)
        let bubbleLeft = M.leading + M.avatarSize + M.avatarGap
        var y = model.topGap

        if model.showsName && !isOwner {
            let text = NSMutableAttributedString(string: model.displayName, attributes: [
                .font: M.nameFont, .foregroundColor: UIColor(Theme.textPrimary).withAlphaComponent(0.62),
            ])
            if let handle = model.handle {
                text.append(NSAttributedString(string: "  @\(handle)", attributes: [
                    .font: M.handleFont, .foregroundColor: UIColor(Theme.textMuted).withAlphaComponent(0.8),
                ]))
            }
            y += 2
            let lineHeight = ceil(M.nameFont.lineHeight)
            let nameWidth = min(ceil(text.size().width) + 1, content - M.avatarSize - M.avatarGap - M.paddingH)
            name = text
            nameFrame = CGRect(x: bubbleLeft + M.paddingH, y: y, width: nameWidth, height: lineHeight)
            y += lineHeight + 4
        } else {
            name = nil
            nameFrame = .zero
        }

        let texts = Self.texts(for: model)
        let sizes = texts.map { Self.measure($0, maxWidth: textMax) }

        // 回应角标：对方挂右上角、自己挂左上角，往上探出去；探出这截不能越过本行顶边、不能压住名字
        var reactionFrame: CGRect?
        if !model.reactions.isEmpty, let first = sizes.first {
            let badgeWidth = GroupReactionBadgeView.width(count: model.reactions.count)
            let bubbleWidth = first.width + 2 * M.paddingH
            let bubbleX = isOwner ? width - M.trailing - bubbleWidth : bubbleLeft
            let badgeX = isOwner
                ? max(4, bubbleX - M.reactionOverhang)
                : max(4, min(bubbleX + bubbleWidth + M.reactionOverhang, width - 4) - badgeWidth)
            let rise = GroupReactionBadgeView.height / 2 - M.reactionDrop
            y = max(y, rise)
            let badgeX0 = CGRect(x: badgeX, y: y - rise, width: badgeWidth, height: GroupReactionBadgeView.height)
            if name != nil, badgeX0.intersects(nameFrame) { y = nameFrame.maxY + 1 + rise }
            reactionFrame = CGRect(x: badgeX, y: y - rise, width: badgeWidth, height: GroupReactionBadgeView.height)
        }
        self.reactionFrame = reactionFrame

        var bubbles: [Bubble] = []
        for (index, text) in texts.enumerated() {
            let size = sizes[index]
            let bubbleWidth = size.width + 2 * M.paddingH
            let bubbleHeight = size.height + 2 * M.paddingV
            let x = isOwner ? width - M.trailing - bubbleWidth : bubbleLeft
            bubbles.append(Bubble(frame: CGRect(x: x, y: y, width: bubbleWidth, height: bubbleHeight),
                                  text: text,
                                  hasTail: !model.continuesRun && index == texts.count - 1))
            y += bubbleHeight + M.bubbleSpacing
        }
        self.bubbles = bubbles
        let bubbleBottom = bubbles.last?.frame.maxY ?? y
        var bottom = bubbleBottom

        if !isOwner && !model.continuesRun {
            let frame = CGRect(x: M.leading, y: bubbleBottom + M.avatarDrop - M.avatarSize,
                               width: M.avatarSize, height: M.avatarSize)
            avatarFrame = frame
            bottom = max(bottom, frame.maxY)
        } else {
            avatarFrame = nil
        }

        if model.message.editedAt != nil && !model.message.isDeleted {
            let size = ("edited" as NSString).size(withAttributes: [.font: M.editedFont])
            let labelWidth = ceil(size.width) + 1
            let x = isOwner ? width - M.trailing - M.editedInset - labelWidth : bubbleLeft + M.editedInset
            let frame = CGRect(x: x, y: bubbleBottom + M.editedTop, width: labelWidth, height: ceil(size.height))
            editedFrame = frame
            bottom = max(bottom, frame.maxY)
        } else {
            editedFrame = nil
        }
        height = ceil(bottom)
    }
}

// MARK: - 气泡

final class GroupBubbleView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    let textView = UITextView()
    private(set) var isUser = false
    private var hasTail = false
    /// `>` 引用段左侧的 2pt 竖线
    private var quoteBars: [CALayer] = []
    /// 长按浮层的手势：正文 UITextView 自带的长按（选字 / 放大镜）等它失败才开始，双击选字不受影响
    var longPress: UILongPressGestureRecognizer? {
        didSet { deferTextViewLongPresses() }
    }

    static func configureTextView(_ view: UITextView) {
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = .clear
        view.dataDetectorTypes = []
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        Self.configureTextView(textView)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(text: NSAttributedString, fill: UIColor, isUser: Bool, hasTail: Bool) {
        textView.attributedText = text
        textView.linkTextAttributes = [.foregroundColor: UIColor(Theme.branchIndicator)]
        shapeLayer.fillColor = fill.cgColor
        self.isUser = isUser
        self.hasTail = hasTail
        setNeedsLayout()
    }

    /// 长按预览的外形（和画出来的泡同一条路径）
    var bubblePath: CGPath {
        BubbleTailPath.cgPath(in: bounds, isUser: isUser, radius: GroupRoomMetrics.cornerRadius,
                              hasTail: hasTail, tailScale: GroupRoomMetrics.tailScale)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // UITextView 的文字交互手势可能进窗口后才装上，再挂一次
        deferTextViewLongPresses()
    }

    private func deferTextViewLongPresses() {
        guard let longPress else { return }
        for recognizer in textView.gestureRecognizers ?? [] where recognizer is UILongPressGestureRecognizer {
            recognizer.require(toFail: longPress)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.path = bubblePath
        textView.frame = bounds.insetBy(dx: GroupRoomMetrics.paddingH, dy: GroupRoomMetrics.paddingV)
        layoutQuoteBars()
    }

    /// 长按浮层里浮起来的那份（同样的字 / 底色 / 尾巴；快照会把画在 bounds 外的尾巴裁掉）
    func makeCopy() -> GroupBubbleView {
        let copy = GroupBubbleView(frame: frame)
        copy.configure(text: textView.attributedText ?? NSAttributedString(),
                       fill: shapeLayer.fillColor.map { UIColor(cgColor: $0) } ?? .white,
                       isUser: isUser, hasTail: hasTail)
        return copy
    }

    /// 按引用段的行框画竖线（相邻的引用行并成一根）
    private func layoutQuoteBars() {
        let text = textView.attributedText ?? NSAttributedString()
        var bars: [(rect: CGRect, color: UIColor)] = []
        text.enumerateAttribute(GroupMarkdownRenderer.quoteKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil, range.length > 0,
                  let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return }
            let rect = textView.selectionRects(for: textRange).map(\.rect)
                .filter { $0.height > 0 && $0.width > 0 }
                .reduce(CGRect.null) { $0.union($1) }
            guard !rect.isNull else { return }
            let color = (text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor) ?? .gray
            if let last = bars.last, rect.minY - last.rect.maxY < 8 {
                bars[bars.count - 1].rect = last.rect.union(rect)
            } else {
                bars.append((rect, color))
            }
        }
        while quoteBars.count < bars.count {
            let bar = CALayer()
            bar.cornerRadius = 1
            layer.addSublayer(bar)
            quoteBars.append(bar)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in quoteBars.enumerated() {
            guard index < bars.count else { bar.isHidden = true; continue }
            bar.isHidden = false
            bar.backgroundColor = bars[index].color.withAlphaComponent(0.5).cgColor
            bar.frame = CGRect(x: textView.frame.minX, y: textView.frame.minY + bars[index].rect.minY,
                               width: 2, height: bars[index].rect.height)
        }
        CATransaction.commit()
    }
}

/// 首字头像（`GroupAvatarView.memberColor/initial` 同一套颜色）
final class GroupMemberAvatarView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(actorId: String, name: String) {
        backgroundColor = UIColor(GroupAvatarView.memberColor(actorId))
        label.text = GroupAvatarView.initial(name)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        label.font = .systemFont(ofSize: bounds.width * 0.4, weight: .semibold)
        label.frame = bounds
    }
}

// MARK: - 回应角标

/// 气泡角上的表情回应（学 p3 录屏）：白胶囊横排表情（一个时是圆）+ 往外拖两颗递减的小圆点（想法泡），轻阴影。
/// 现在只有本机自己的回应，不显示计数。
final class GroupReactionBadgeView: UIView {
    static let height: CGFloat = 26
    private static let slotWidth: CGFloat = 20
    private static let padding: CGFloat = 3
    static func width(count: Int) -> CGFloat { 2 * padding + CGFloat(max(1, count)) * slotWidth }

    var onTapEmoji: ((String) -> Void)?
    private var emojis: [String] = []
    private var labels: [UILabel] = []
    private let capsule = UIView()
    private let dots = [UIView(), UIView()]
    private var trailsRight = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        for view in dots + [capsule] {
            view.backgroundColor = .white
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.12
            view.layer.shadowRadius = 2.5
            view.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(view)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// `trailsRight`：小圆点往右下拖（对方的泡，角标在右上角）；自己的泡往左下
    func configure(emojis: [String], trailsRight: Bool) {
        self.emojis = emojis
        self.trailsRight = trailsRight
        while labels.count < emojis.count {
            let label = UILabel()
            label.font = .systemFont(ofSize: 14)
            label.textAlignment = .center
            capsule.addSubview(label)
            labels.append(label)
        }
        for (index, label) in labels.enumerated() {
            label.isHidden = index >= emojis.count
            label.text = index < emojis.count ? emojis[index] : nil
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = Self.height
        capsule.frame = bounds
        capsule.layer.cornerRadius = height / 2
        capsule.layer.shadowPath = UIBezierPath(roundedRect: capsule.bounds, cornerRadius: height / 2).cgPath
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(x: Self.padding + CGFloat(index) * Self.slotWidth, y: 0, width: Self.slotWidth, height: height)
        }
        // 以最外侧那个圆为准：大点在圆的斜下方贴边，小点再往外一截
        let circleX = trailsRight ? bounds.maxX - height / 2 : bounds.minX + height / 2
        let direction: CGFloat = trailsRight ? 1 : -1
        let specs: [(dx: CGFloat, dy: CGFloat, size: CGFloat)] = [(6, 14, 5.5), (11, 20, 3.5)]
        for (dot, spec) in zip(dots, specs) {
            dot.frame = CGRect(x: circleX + direction * spec.dx - spec.size / 2, y: bounds.midY + spec.dy - spec.size / 2,
                               width: spec.size, height: spec.size)
            dot.layer.cornerRadius = spec.size / 2
            dot.layer.shadowPath = UIBezierPath(ovalIn: dot.bounds).cgPath
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard !emojis.isEmpty else { return }
        let x = gesture.location(in: self).x - Self.padding
        let index = min(max(0, Int(x / Self.slotWidth)), emojis.count - 1)
        onTapEmoji?(emojis[index])
    }
}

// MARK: - 消息 cell

final class GroupMessageCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    static let reuseID = "GroupMessageCell"

    private let nameLabel = UILabel()
    private let avatarView = GroupMemberAvatarView()
    private let editedLabel = UILabel()
    private let reactionView = GroupReactionBadgeView()
    private var bubbleViews: [GroupBubbleView] = []
    private var layout: GroupMessageLayout?
    private var message: AgoraMessage?
    /// 长按气泡：VC 弹浮层（表情条 + 菜单）
    var onLongPress: ((AgoraMessage, GroupBubbleView) -> Void)?
    /// 点角标上的表情：取消自己的回应
    var onToggleReaction: ((AgoraMessage, String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        editedLabel.text = "edited"
        editedLabel.font = GroupRoomMetrics.editedFont
        contentView.addSubview(nameLabel)
        contentView.addSubview(avatarView)
        contentView.addSubview(editedLabel)
        contentView.addSubview(reactionView)
        reactionView.onTapEmoji = { [weak self] emoji in
            guard let self, let message else { return }
            onToggleReaction?(message, emoji)
        }
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(model: GroupMessageRowModel, layout: GroupMessageLayout) {
        self.layout = layout
        message = model.message
        while bubbleViews.count < layout.bubbles.count {
            let bubble = GroupBubbleView()
            let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
            press.minimumPressDuration = 0.35
            press.delegate = self
            bubble.addGestureRecognizer(press)
            bubble.longPress = press
            contentView.insertSubview(bubble, belowSubview: reactionView)
            bubbleViews.append(bubble)
        }
        let fill = model.isOwner ? GroupRoomStyle.mineFill(model.colors.mineHex) : GroupRoomStyle.othersFill(model.colors.othersHex)
        for (index, bubble) in bubbleViews.enumerated() {
            guard index < layout.bubbles.count else { bubble.isHidden = true; continue }
            let item = layout.bubbles[index]
            bubble.isHidden = false
            bubble.configure(text: item.text, fill: fill, isUser: model.isOwner, hasTail: item.hasTail)
        }
        nameLabel.attributedText = layout.name
        nameLabel.isHidden = layout.name == nil
        avatarView.isHidden = layout.avatarFrame == nil
        avatarView.configure(actorId: model.message.actorId, name: model.displayName)
        editedLabel.isHidden = layout.editedFrame == nil
        editedLabel.textColor = UIColor(Theme.textMuted).withAlphaComponent(0.55)
        reactionView.isHidden = layout.reactionFrame == nil
        reactionView.configure(emojis: model.reactions, trailsRight: !model.isOwner)

        let time = model.message.createdAt.formatted(date: .omitted, time: .shortened)
        let content = model.message.isDeleted ? "此消息已删除" : model.message.content
        let reactions = model.reactions.isEmpty ? "" : "，回应 \(model.reactions.joined(separator: " "))"
        accessibilityLabel = "\(model.displayName)，\(content)，\(time)\(reactions)"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        for (index, item) in layout.bubbles.enumerated() where index < bubbleViews.count {
            bubbleViews[index].frame = item.frame
        }
        nameLabel.frame = layout.nameFrame
        if let frame = layout.avatarFrame { avatarView.frame = frame }
        if let frame = layout.editedFrame { editedLabel.frame = frame }
        if let frame = layout.reactionFrame { reactionView.frame = frame }
    }

    // MARK: 长按

    /// 已删除的不弹；正在拖选文字时不抢
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let bubble = gestureRecognizer.view as? GroupBubbleView else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return message?.isDeleted == false && bubble.textView.selectedRange.length == 0
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let message, let bubble = gesture.view as? GroupBubbleView else { return }
        onLongPress?(message, bubble)
    }
}

// MARK: - 日期分隔

final class GroupDateCell: UICollectionViewCell {
    static let reuseID = "GroupDateCell"
    static let topPadding: CGFloat = 14
    static let bottomPadding: CGFloat = 6
    private static let font = UIFont.preferredFont(forTextStyle: .caption2)
    static var height: CGFloat { topPadding + ceil(font.lineHeight) + bottomPadding }

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// 「今天 / 昨天 / 9/19」加粗 + 时间
    func configure(date: Date) {
        let calendar = Calendar.current
        let day: String = calendar.isDateInToday(date) ? "今天"
            : calendar.isDateInYesterday(date) ? "昨天"
            : date.formatted(.dateTime.month(.defaultDigits).day())
        let color = UIColor(Theme.textMuted)
        let bold = UIFont.systemFont(ofSize: Self.font.pointSize, weight: .semibold)
        let text = NSMutableAttributedString(string: day, attributes: [.font: bold, .foregroundColor: color])
        text.append(NSAttributedString(string: " " + date.formatted(.dateTime.hour().minute()),
                                       attributes: [.font: Self.font, .foregroundColor: color]))
        label.attributedText = text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 0, y: Self.topPadding, width: bounds.width, height: ceil(Self.font.lineHeight))
    }
}

// MARK: - 谁在输入

/// 三个点错峰小幅弹跳（同 `BouncingDotsView`，UIKit 自己画）
final class GroupTypingDotsView: UIView {
    static let size = CGSize(width: 23, height: 13)
    private var dots: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        for index in 0..<3 {
            let dot = UIView(frame: CGRect(x: CGFloat(index) * 9, y: 4, width: 5, height: 5))
            dot.layer.cornerRadius = 2.5
            addSubview(dot)
            dots.append(dot)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let now = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = UIColor(Theme.textMuted).withAlphaComponent(0.5)
            let bounce = CABasicAnimation(keyPath: "transform.translation.y")
            bounce.fromValue = 1
            bounce.toValue = -3
            bounce.duration = 0.45
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.beginTime = now + Double(index) * 0.15
            bounce.fillMode = .backwards
            dot.layer.add(bounce, forKey: "bounce")
        }
    }
}

final class GroupTypingCell: UICollectionViewCell {
    static let reuseID = "GroupTypingCell"
    private static let bubbleSize = CGSize(width: GroupTypingDotsView.size.width + 2 * GroupRoomMetrics.paddingH,
                                           height: GroupTypingDotsView.size.height + 2 * GroupRoomMetrics.paddingV)
    static var height: CGFloat { GroupRoomMetrics.speakerGap + bubbleSize.height + GroupRoomMetrics.avatarDrop }

    private let avatarView = GroupMemberAvatarView()
    private let bubble = GroupBubbleView()
    private let dots = GroupTypingDotsView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        bubble.textView.isHidden = true
        bubble.addSubview(dots)
        contentView.addSubview(avatarView)
        contentView.addSubview(bubble)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(presence: AgoraTypingPresence, member: AgoraMember?, othersHex: String?) {
        avatarView.configure(actorId: member?.actorId ?? presence.actorId, name: member?.displayName ?? presence.displayName)
        bubble.configure(text: NSAttributedString(), fill: GroupRoomStyle.othersFill(othersHex), isUser: false, hasTail: true)
        accessibilityLabel = "\(presence.displayName) 正在输入"
        isAccessibilityElement = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let m = GroupRoomMetrics.self
        let bubbleFrame = CGRect(x: m.leading + m.avatarSize + m.avatarGap, y: m.speakerGap,
                                 width: Self.bubbleSize.width, height: Self.bubbleSize.height)
        bubble.frame = bubbleFrame
        dots.frame = CGRect(origin: CGPoint(x: m.paddingH, y: m.paddingV), size: GroupTypingDotsView.size)
        avatarView.frame = CGRect(x: m.leading, y: bubbleFrame.maxY + m.avatarDrop - m.avatarSize,
                                  width: m.avatarSize, height: m.avatarSize)
    }
}

// MARK: - 加载更早 / 空房间

final class GroupLoadOlderCell: UICollectionViewCell {
    static let reuseID = "GroupLoadOlderCell"
    static let height: CGFloat = 44
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.hidesWhenStopped = false
        contentView.addSubview(spinner)
        accessibilityLabel = "加载更早消息"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(isLoading: Bool) {
        spinner.alpha = isLoading ? 1 : 0.4
        spinner.startAnimating()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

final class GroupEmptyCell: UICollectionViewCell {
    static let reuseID = "GroupEmptyCell"
    private let stack = UIStackView()
    private let icon = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        title.font = .systemFont(ofSize: 20, weight: .bold)
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center
        [spinner, icon, title, subtitle].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(12, after: icon)
        contentView.addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(isLoading: Bool) {
        let muted = UIColor(Theme.textMuted)
        spinner.isHidden = !isLoading
        if isLoading { spinner.startAnimating() }
        icon.isHidden = isLoading
        subtitle.isHidden = isLoading
        icon.image = UIImage(systemName: "bubble.left.and.bubble.right")
        icon.tintColor = muted
        title.text = isLoading ? "正在进入房间…" : "房间还没有消息"
        title.font = isLoading ? .preferredFont(forTextStyle: .subheadline) : .systemFont(ofSize: 20, weight: .bold)
        title.textColor = isLoading ? muted : UIColor(Theme.textPrimary)
        subtitle.text = "写下第一句话，或用 @handle 唤醒成员。"
        subtitle.textColor = muted
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = stack.systemLayoutSizeFitting(CGSize(width: bounds.width - 64, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        stack.frame = CGRect(x: 32, y: (bounds.height - size.height) / 2, width: bounds.width - 64, height: size.height)
    }
}
#endif
