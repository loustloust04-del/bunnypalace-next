#if canImport(UIKit)
import UIKit
import SwiftUI

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// Compose 草稿编辑器（物料表 §4 全抄）。对着 CC 打长 prompt 是 MP 的高频场景，
/// 这键在这儿比在 rootshell 还有用。
///
/// 抄的四件事：monospaced `UITextView` 草稿编辑器 / 草稿保留（关掉不清，下次打开接着写）/
/// 自动更正默认关。外加 `xmark.circle.fill` 清草稿（有字才出现）。
/// 发送 = 当粘贴发（#053）：hub 确认送到才清草稿；老 hub 确认不了就关卡留草稿；没送到卡里写原因。
/// iPhone 竖屏布局：上文本、下三个按钮。
final class TerminalComposeOverlay: UIView, UITextViewDelegate {
    /// Send：整段草稿 + 回调
    var onSend: ((String, @escaping (TerminalPasteOutcome) -> Void) -> Void)?
    /// 每次变化写回 controller，关掉不丢
    var onDraftChange: ((String) -> Void)?
    var onClose: (() -> Void)?

    private static let autocorrectKey = "terminalComposeAutocorrectEnabled"

    private let card = UIView()
    private let textView = UITextView()
    private let clearButton = UIButton(type: .system)
    private let autocorrectButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    /// 没送到时的原因（空 = 不占高）
    private let statusLabel = UILabel()
    private var isSending = false

    init(draft: String) {
        super.init(frame: .zero)
        backgroundColor = .clear

        card.backgroundColor = UIColor(Theme.sidebarBg)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.textColor = UIColor(Theme.textPrimary)
        textView.backgroundColor = .clear
        textView.text = draft
        textView.delegate = self
        // 终端里打的是命令和 prompt：自动大写/智能引号/智能破折号一律关死，
        // 只有自动更正是可切的（物料表 §4.2）
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(textView)

        var clearCfg = UIButton.Configuration.plain()
        clearCfg.image = UIImage(systemName: "xmark.circle.fill")
        clearButton.configuration = clearCfg
        clearButton.tintColor = UIColor(Theme.textMuted)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.addAction(UIAction { [weak self] _ in self?.clearDraft() }, for: .touchUpInside)
        card.addSubview(clearButton)

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 15)
        cancelButton.tintColor = UIColor(Theme.textMuted)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        card.addSubview(cancelButton)

        autocorrectButton.titleLabel?.font = .systemFont(ofSize: 15)
        autocorrectButton.translatesAutoresizingMaskIntoConstraints = false
        autocorrectButton.addAction(UIAction { [weak self] _ in self?.toggleAutocorrect() },
                                    for: .touchUpInside)
        card.addSubview(autocorrectButton)

        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        sendButton.tintColor = UIColor(Theme.branchIndicator)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)
        card.addSubview(sendButton)

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .systemRed
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            textView.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),

            clearButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            clearButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            clearButton.widthAnchor.constraint(equalToConstant: 28),
            clearButton.heightAnchor.constraint(equalToConstant: 28),

            cancelButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            cancelButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            autocorrectButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            autocorrectButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            sendButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            sendButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -4),
            textView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
        ])

        applyAutocorrect()
        refreshState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 自动更正（默认关，记在 UserDefaults）

    private var autocorrectEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autocorrectKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autocorrectKey) }
    }

    private func toggleAutocorrect() {
        autocorrectEnabled.toggle()
        applyAutocorrect()
        // 改输入属性要 reload 才生效；此处**不在键盘通知 handler 里**，不触禁区
        textView.reloadInputViews()
    }

    private func applyAutocorrect() {
        let on = autocorrectEnabled
        textView.autocorrectionType = on ? .yes : .no
        textView.spellCheckingType = on ? .yes : .no
        textView.inlinePredictionType = on ? .default : .no
        autocorrectButton.setTitle(on ? "更正 开" : "更正 关", for: .normal)
        autocorrectButton.tintColor = on ? UIColor(Theme.branchIndicator) : UIColor(Theme.textMuted)
    }

    // MARK: 交互

    func focus() {
        // 下一个 main-queue turn 再抢焦点：键盘焦点从终端平滑转给编辑器（物料表 §4.2）
        DispatchQueue.main.async { [weak self] in _ = self?.textView.becomeFirstResponder() }
    }

    /// 工具条上的可打印键在草稿开着时插进草稿，不发给终端（物料表 §4.3）。
    /// 带 Ctrl/Alt 的键和 ESC 序列不进草稿 —— 那是给终端的控制流，由调用方先判好。
    func insert(_ text: String) {
        textView.insertText(text)
        refreshState()
        onDraftChange?(textView.text)
    }

    private func clearDraft() {
        textView.text = ""
        refreshState()
        onDraftChange?("")
    }

    private func send() {
        let text = textView.text ?? ""
        guard !text.isEmpty, !isSending, let onSend else { return }
        isSending = true
        statusLabel.text = nil
        refreshState()
        onSend(text) { [weak self] outcome in
            guard let self else { return }
            self.isSending = false
            switch outcome {
            case .failed(let reason):
                self.statusLabel.text = "\(reason)。草稿还在。"
                self.refreshState()
            case .submitted:
                self.close()
            case .delivered:
                // 等回包期间她可能又改了草稿 —— 只有原文没动才清
                if self.textView.text == text {
                    self.textView.text = ""
                    self.onDraftChange?("")
                }
                self.close()
            }
        }
    }

    /// 关闭时**先把焦点还给终端、后拆 overlay**，避免键盘 bounce（物料表 §4.2 末条）。
    /// 焦点交还由 host 在 `onClose` 里做。
    func close() {
        onDraftChange?(textView.text ?? "")
        onClose?()
    }

    private func refreshState() {
        let empty = (textView.text ?? "").isEmpty
        clearButton.isHidden = empty          // 有字才出现（物料表 §4.2）
        sendButton.isEnabled = !empty && !isSending   // 空草稿 / 正在等回包 Send 置灰
    }

    func textViewDidChange(_ textView: UITextView) {
        refreshState()
        onDraftChange?(textView.text)
    }
}
#endif
