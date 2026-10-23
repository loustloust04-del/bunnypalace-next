#if os(iOS)
import SwiftUI
import UIKit

/// 群聊输入框（UIKit）：一整块 UIGlassEffect 圆角 28 玻璃，上面 UITextView（1–6 行自动长高），
/// 下面一行左「＋」菜单（现在只有「提及成员」，以后附件往这里加）、右发送。编辑中 / 回复中顶部一行提示；
/// @ 补全是玻璃上方一条横向小卡片。文字和 `AgoraViewModel.composerText` 双向同步由 VC 接。
final class GroupRoomComposerView: UIView, UITextViewDelegate {
    struct ReplyPreview: Equatable {
        var name: String
        var snippet: String
    }

    struct State: Equatable {
        var text: String
        var isEditing: Bool
        var reply: ReplyPreview?
        var isPosting: Bool
        var canPost: Bool
        var isEnabled: Bool
        var suggestions: [AgoraMember]
    }

    var onTextChange: ((String) -> Void)?
    var onSend: (() -> Void)?
    var onCancelEditing: (() -> Void)?
    var onCancelReply: (() -> Void)?
    var onPickMention: ((String) -> Void)?
    /// 自己长高 / 补全条出没：列表底部 inset 要跟着变
    var onLayout: (() -> Void)?

    let textView = UITextView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let placeholder = UILabel()
    private let editingBar = UIStackView()
    private let replyBar = UIStackView()
    private let replyLabel = UILabel()
    private let plusButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .custom)
    private let sendSpinner = UIActivityIndicatorView(style: .medium)
    private let suggestionScroll = UIScrollView()
    private let suggestionStack = UIStackView()
    private var textHeight: NSLayoutConstraint!
    private var state = State(text: "", isEditing: false, reply: nil, isPosting: false, canPost: false, isEnabled: true, suggestions: [])

    private static let textFont = UIFont.systemFont(ofSize: 16)
    private static let maxLines: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        let outer = UIStackView(arrangedSubviews: [suggestionScroll, glass])
        outer.axis = .vertical
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        // @ 补全条
        suggestionScroll.showsHorizontalScrollIndicator = false
        suggestionScroll.clipsToBounds = false
        suggestionScroll.isHidden = true
        suggestionStack.axis = .horizontal
        suggestionStack.spacing = 8
        suggestionStack.translatesAutoresizingMaskIntoConstraints = false
        suggestionScroll.addSubview(suggestionStack)

        // 玻璃块
        glass.cornerConfiguration = .corners(radius: .fixed(28))
        glass.clipsToBounds = true

        editingBar.axis = .horizontal
        editingBar.spacing = 6
        editingBar.alignment = .center
        let pencil = UIImageView(image: UIImage(systemName: "pencil"))
        pencil.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        let editingLabel = UILabel()
        editingLabel.text = "正在编辑消息"
        editingLabel.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .medium)
        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        cancel.addAction(UIAction { [weak self] _ in self?.onCancelEditing?() }, for: .touchUpInside)
        let muted = UIColor(Theme.textMuted)
        pencil.tintColor = muted
        editingLabel.textColor = muted
        cancel.tintColor = muted
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [pencil, editingLabel, spacer, cancel].forEach(editingBar.addArrangedSubview)
        editingBar.isHidden = true

        // 回复中：「回复 名字：原话前 40 字…  ×」
        replyBar.axis = .horizontal
        replyBar.spacing = 6
        replyBar.alignment = .center
        let replyIcon = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left"))
        replyIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        replyIcon.tintColor = muted
        replyIcon.setContentHuggingPriority(.required, for: .horizontal)
        replyLabel.lineBreakMode = .byTruncatingTail
        replyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let replyClose = UIButton(type: .system)
        replyClose.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)), for: .normal)
        replyClose.tintColor = muted
        replyClose.accessibilityLabel = "取消回复"
        replyClose.setContentHuggingPriority(.required, for: .horizontal)
        replyClose.addAction(UIAction { [weak self] _ in self?.onCancelReply?() }, for: .touchUpInside)
        [replyIcon, replyLabel, replyClose].forEach(replyBar.addArrangedSubview)
        replyBar.isHidden = true

        textView.font = Self.textFont
        textView.textColor = UIColor(Theme.textPrimary)
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = "中庭消息"
        placeholder.font = Self.textFont
        placeholder.textColor = UIColor(Theme.textMuted).withAlphaComponent(0.7)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)

        // 左下「＋」：点开菜单，先放「提及成员」
        plusButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        plusButton.tintColor = UIColor(Theme.textPrimary)
        plusButton.showsMenuAsPrimaryAction = true
        plusButton.menu = UIMenu(children: [
            UIAction(title: "提及成员", image: UIImage(systemName: "at")) { [weak self] _ in self?.insertMentionAtCursor() },
        ])
        plusButton.accessibilityLabel = "更多"

        // 右下发送
        sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)), for: .normal)
        sendButton.tintColor = .white
        sendButton.layer.cornerRadius = 18
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)
        sendSpinner.color = .white
        sendSpinner.hidesWhenStopped = true
        sendSpinner.isUserInteractionEnabled = false
        sendSpinner.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addSubview(sendSpinner)

        let bottomRow = UIStackView(arrangedSubviews: [plusButton, UIView(), sendButton])
        bottomRow.axis = .horizontal
        bottomRow.alignment = .center

        let inner = UIStackView(arrangedSubviews: [replyBar, editingBar, textView, bottomRow])
        inner.axis = .vertical
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(inner)

        textHeight = textView.heightAnchor.constraint(equalToConstant: ceil(Self.textFont.lineHeight))
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),

            suggestionStack.topAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.topAnchor, constant: 2),
            suggestionStack.bottomAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.bottomAnchor, constant: -2),
            suggestionStack.leadingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.leadingAnchor, constant: 4),
            suggestionStack.trailingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.trailingAnchor, constant: -4),
            suggestionScroll.frameLayoutGuide.heightAnchor.constraint(equalTo: suggestionStack.heightAnchor, constant: 4),

            inner.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 14),
            inner.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -16),
            inner.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -8),

            textHeight,
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: textView.frameLayoutGuide.leadingAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.frameLayoutGuide.trailingAnchor),

            replyClose.widthAnchor.constraint(equalToConstant: 24),
            replyClose.heightAnchor.constraint(equalToConstant: 24),
            plusButton.widthAnchor.constraint(equalToConstant: 34),
            plusButton.heightAnchor.constraint(equalToConstant: 34),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),
            sendSpinner.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            sendSpinner.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
        ])
        apply(state, force: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: 状态

    func apply(_ newState: State, force: Bool = false) {
        guard force || newState != state else { return }
        let old = state
        state = newState
        // 组字中（拼音未定稿）不回写，免得打断输入法
        if textView.text != newState.text, textView.markedTextRange == nil {
            textView.text = newState.text
            updateTextHeight()
        }
        placeholder.text = newState.isEditing ? "编辑消息" : "发消息，输入 @ 唤醒成员"
        placeholder.isHidden = !textView.text.isEmpty
        editingBar.isHidden = !newState.isEditing
        if force || old.reply != newState.reply { updateReplyBar(newState.reply) }
        textView.isEditable = newState.isEnabled
        sendButton.isEnabled = newState.canPost
        sendButton.backgroundColor = newState.canPost || newState.isPosting
            ? UIColor(Theme.branchIndicator)
            : UIColor(Theme.textMuted).withAlphaComponent(0.35)
        sendButton.imageView?.alpha = newState.isPosting ? 0 : 1
        if newState.isPosting { sendSpinner.startAnimating() } else { sendSpinner.stopAnimating() }
        sendButton.accessibilityLabel = newState.isPosting ? "正在提交" : (newState.isEditing ? "保存编辑" : "发送消息")
        if force || old.suggestions != newState.suggestions { rebuildSuggestions(newState.suggestions) }
    }

    private func updateReplyBar(_ reply: ReplyPreview?) {
        replyBar.isHidden = reply == nil
        guard let reply else { return }
        let size = UIFont.preferredFont(forTextStyle: .caption1).pointSize
        let muted = UIColor(Theme.textMuted)
        let text = NSMutableAttributedString(string: "回复 ", attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: muted])
        text.append(NSAttributedString(string: reply.name, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: UIColor(Theme.textPrimary),
        ]))
        text.append(NSAttributedString(string: "：\(reply.snippet)", attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: muted]))
        replyLabel.attributedText = text
        replyBar.accessibilityLabel = text.string
    }

    private func rebuildSuggestions(_ members: [AgoraMember]) {
        suggestionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for member in members {
            suggestionStack.addArrangedSubview(MentionChip(member: member) { [weak self] in self?.onPickMention?(member.handle) })
        }
        suggestionScroll.isHidden = members.isEmpty
    }

    // MARK: 文本

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        updateTextHeight()
        onTextChange?(textView.text)
    }

    /// 1–6 行自动长高，超过就内滚
    private func updateTextHeight() {
        let width = textView.bounds.width > 0 ? textView.bounds.width : 200
        let fitting = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let maxHeight = ceil(Self.textFont.lineHeight * Self.maxLines)
        let height = min(max(fitting, ceil(Self.textFont.lineHeight)), maxHeight)
        textView.isScrollEnabled = fitting > maxHeight
        if textHeight.constant != height { textHeight.constant = height }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTextHeight()
        onLayout?()
    }

    /// 「＋ › 提及成员」：在光标处插入 @ 并聚焦（前面不是空白就补一个空格）
    private func insertMentionAtCursor() {
        textView.becomeFirstResponder()
        let text = textView.text ?? ""
        let location = min(textView.selectedRange.location, (text as NSString).length)
        let before = (text as NSString).substring(to: location)
        let needsSpace = !(before.isEmpty || before.last?.isWhitespace == true)
        textView.insertText(needsSpace ? " @" : "@")
        textViewDidChange(textView)
    }

    func focus() { textView.becomeFirstResponder() }
}

/// @ 补全小卡片：头像 22 + 名字 + @handle，玻璃胶囊
private final class MentionChip: UIVisualEffectView {
    private let onTap: () -> Void

    init(member: AgoraMember, onTap: @escaping () -> Void) {
        self.onTap = onTap
        let effect = UIGlassEffect()
        effect.isInteractive = true
        super.init(effect: effect)
        cornerConfiguration = .capsule()

        let avatar = GroupMemberAvatarView()
        avatar.configure(actorId: member.actorId, name: member.displayName)
        let name = UILabel()
        name.text = member.displayName
        name.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold)
        name.textColor = UIColor(Theme.textPrimary)
        let handle = UILabel()
        handle.text = "@\(member.handle)"
        handle.font = .preferredFont(forTextStyle: .caption2)
        handle.textColor = UIColor(Theme.textMuted)
        let row = UIStackView(arrangedSubviews: [avatar, name, handle])
        row.spacing = 6
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 22),
            avatar.heightAnchor.constraint(equalToConstant: 22),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "插入 @\(member.handle)，\(member.displayName)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func tapped() { onTap() }
}
#endif
