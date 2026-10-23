#if os(iOS)
import SwiftUI
import UIKit

struct IOSPromptTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 44
    var maxHeight: CGFloat = 180
    var onBeganEditing: () -> Void = {}
    var onEndedEditing: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PromptTextViewContainer {
        let view = PromptTextViewContainer()
        view.textView.delegate = context.coordinator
        view.onHeightDidChange = { [weak coordinator = context.coordinator] height in
            coordinator?.notifyHeightChange(height)
        }
        return view
    }

    func updateUIView(_ uiView: PromptTextViewContainer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.container = uiView

        uiView.minHeight = minHeight
        uiView.maxHeight = maxHeight
        uiView.updatePlaceholder(placeholder)

        if uiView.textView.text != text {
            context.coordinator.isApplyingExternalText = true
            uiView.updateText(text)
            context.coordinator.isApplyingExternalText = false
        } else {
            uiView.refreshUI(ensureCaretVisible: uiView.textView.isFirstResponder)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PromptTextViewContainer, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        uiView.minHeight = minHeight
        uiView.maxHeight = maxHeight
        return CGSize(width: width, height: uiView.preferredHeight(for: width))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSPromptTextView
        weak var container: PromptTextViewContainer?
        var isApplyingExternalText = false
        private var lastDeliveredHeight: CGFloat = 0

        init(parent: IOSPromptTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalText else { return }
            parent.text = textView.text
            container?.refreshUI(ensureCaretVisible: true)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onBeganEditing()
            container?.refreshUI(ensureCaretVisible: true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onEndedEditing()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingExternalText else { return }
            container?.ensureCaretVisibleIfNeeded()
        }

        func notifyHeightChange(_ height: CGFloat) {
            guard abs(lastDeliveredHeight - height) > 0.5 else { return }
            lastDeliveredHeight = height

            let callback = parent.onHeightChange
            DispatchQueue.main.async {
                callback(height)
            }
        }
    }
}

final class PromptTextViewContainer: UIView {
    let textView = UITextView()
    private let placeholderLabel = UILabel()

    var minHeight: CGFloat = 44
    var maxHeight: CGFloat = 180
    var onHeightDidChange: ((CGFloat) -> Void)?

    private var lastReportedHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        layoutPlaceholder()

        let width = bounds.width
        guard width > 0 else { return }

        updateScrollState(for: width)
        reportHeightIfNeeded(for: width)
    }

    func updateText(_ text: String) {
        textView.text = text
        refreshUI(ensureCaretVisible: textView.isFirstResponder)
    }

    func updatePlaceholder(_ placeholder: String) {
        placeholderLabel.text = placeholder
        setNeedsLayout()
    }

    func refreshUI(ensureCaretVisible: Bool = false) {
        placeholderLabel.isHidden = !textView.text.isEmpty

        let width = bounds.width
        if width > 0 {
            updateScrollState(for: width)
            reportHeightIfNeeded(for: width)
        }

        if ensureCaretVisible {
            ensureCaretVisibleIfNeeded()
        }
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard width > 0 else { return minHeight }
        let contentHeight = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)

        // placeholder 可能比空 textView 更高（如多行 hint），也要算进去
        let insets = textView.textContainerInset
        let padding = textView.textContainer.lineFragmentPadding
        let placeholderWidth = max(width - insets.left - insets.right - 2 * padding, 0)
        let phSize = placeholderLabel.sizeThatFits(CGSize(width: placeholderWidth, height: .greatestFiniteMagnitude))
        let placeholderHeight = ceil(phSize.height) + insets.top + insets.bottom

        return min(max(contentHeight, placeholderHeight, minHeight), maxHeight)
    }

    func ensureCaretVisibleIfNeeded() {
        guard textView.isScrollEnabled,
              textView.isFirstResponder,
              let selectedTextRange = textView.selectedTextRange else { return }

        let caretRect = textView.caretRect(for: selectedTextRange.end).insetBy(dx: 0, dy: -12)
        textView.scrollRectToVisible(caretRect, animated: false)
    }

    private func setup() {
        backgroundColor = UIColor(Theme.sidebarBg)
        layer.cornerRadius = 10
        layer.masksToBounds = true

        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: Theme.F.body)
        textView.textColor = UIColor(Theme.textPrimary)
        textView.isScrollEnabled = false
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = true
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        textView.textContainer.lineFragmentPadding = 0

        placeholderLabel.font = textView.font
        placeholderLabel.textColor = UIColor(Theme.textMuted.opacity(0.7))
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false

        addSubview(textView)
        addSubview(placeholderLabel)
    }

    private func layoutPlaceholder() {
        let insets = textView.textContainerInset
        let padding = textView.textContainer.lineFragmentPadding
        let x = insets.left + padding
        let width = max(bounds.width - insets.left - insets.right - 2 * padding, 0)
        let size = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(
            x: x,
            y: insets.top,
            width: width,
            height: size.height
        )
    }

    private func updateScrollState(for width: CGFloat) {
        let contentHeight = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let shouldScroll = contentHeight > maxHeight + 0.5

        if textView.isScrollEnabled != shouldScroll {
            textView.isScrollEnabled = shouldScroll
            if !shouldScroll {
                textView.setContentOffset(.zero, animated: false)
            }
        }
    }

    private func reportHeightIfNeeded(for width: CGFloat) {
        let height = preferredHeight(for: width)
        guard abs(lastReportedHeight - height) > 0.5 else { return }
        lastReportedHeight = height
        onHeightDidChange?(height)
    }
}
#endif
