#if os(iOS)
import SwiftUI
import UIKit

struct Page2SpotlightField: UIViewControllerRepresentable {
    @Binding var text: String
    let sourceFrame: CGRect
    let closing: Bool
    let dark: Bool
    let contentBottom: CGFloat
    let onDismiss: () -> Void
    let onTopChange: (CGFloat) -> Void
    let onSubmit: () -> Void
    let onClosed: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(text: text, sourceFrame: sourceFrame, closing: closing, dark: dark,
                   contentBottom: contentBottom, onChange: { text = $0 }, onDismiss: onDismiss, onTopChange: onTopChange, onSubmit: onSubmit, onClosed: onClosed)
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configure(text: text, sourceFrame: sourceFrame, closing: closing, dark: dark, contentBottom: contentBottom)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.stop() }

    final class Controller: UIViewController, UITextFieldDelegate {
        private let field = UISearchTextField()
        private let closeButton = UIButton(type: .custom)
        private var contentBottom: CGFloat
        private let onDismiss: () -> Void
        private var sourceFrame: CGRect
        private var closing: Bool
        private var started = false
        private var generation = UUID()
        private var sourceConstraints: [NSLayoutConstraint] = []
        private var fullConstraints: [NSLayoutConstraint] = []
        private var reportedTop: CGFloat = -1
        private let onChange: (String) -> Void
        private let onTopChange: (CGFloat) -> Void
        private let onSubmit: () -> Void
        private let onClosed: () -> Void

        init(text: String, sourceFrame: CGRect, closing: Bool, dark: Bool, contentBottom: CGFloat,
             onChange: @escaping (String) -> Void, onDismiss: @escaping () -> Void, onTopChange: @escaping (CGFloat) -> Void,
             onSubmit: @escaping () -> Void, onClosed: @escaping () -> Void) {
            self.sourceFrame = sourceFrame; self.closing = closing
            self.contentBottom = contentBottom; self.onDismiss = onDismiss
            self.onChange = onChange; self.onTopChange = onTopChange; self.onSubmit = onSubmit; self.onClosed = onClosed
            super.init(nibName: nil, bundle: nil)
            overrideUserInterfaceStyle = dark ? .dark : .light
            field.text = text
        }
        required init?(coder: NSCoder) { nil }
        override func loadView() { view = PassthroughView() }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            field.translatesAutoresizingMaskIntoConstraints = false
            field.placeholder = "搜索"
            field.accessibilityIdentifier = "page2.spotlight-field"
            field.font = .systemFont(ofSize: 17)
            field.returnKeyType = .search
            field.enablesReturnKeyAutomatically = true
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.inlinePredictionType = .no
            field.inputAssistantItem.leadingBarButtonGroups = []
            field.inputAssistantItem.trailingBarButtonGroups = []
            field.autocapitalizationType = .none
            field.layer.cornerRadius = 24
            field.clipsToBounds = true
            field.delegate = self
            field.addTarget(self, action: #selector(changed), for: .editingChanged)
            closeButton.accessibilityIdentifier = "page2.search-cancel"
            closeButton.accessibilityLabel = "关闭搜索"
            closeButton.isAccessibilityElement = true
            closeButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
            view.addSubview(closeButton)
            view.addSubview(field)
            sourceConstraints = [field.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                 field.topAnchor.constraint(equalTo: view.topAnchor),
                                 field.widthAnchor.constraint(equalToConstant: 76), field.heightAnchor.constraint(equalToConstant: 30)]
            fullConstraints = [field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                               field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                               field.heightAnchor.constraint(equalToConstant: 48),
                               field.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8)]
            NSLayoutConstraint.activate(sourceConstraints)
            field.alpha = 0.05
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if !started { updateSourceConstraints() }
            closeButton.frame = CGRect(x: 0, y: contentBottom, width: view.bounds.width, height: max(0, field.frame.minY - contentBottom - 8))
            closeButton.isEnabled = !closing
            if abs(field.frame.minY - reportedTop) > 0.5 {
                reportedTop = field.frame.minY
                let top = reportedTop
                DispatchQueue.main.async { [weak self] in self?.onTopChange(top) }
            }
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !started else { return }
            updateSourceConstraints(); view.layoutIfNeeded()
            started = true
            animate(closing: closing)
        }
        private func updateSourceConstraints() {
            let rect = view.window.map { view.convert(sourceFrame, from: $0) } ?? sourceFrame
            guard rect.width > 0 else { return }
            sourceConstraints[0].constant = rect.minX
            sourceConstraints[1].constant = rect.minY
            sourceConstraints[2].constant = rect.width
            sourceConstraints[3].constant = rect.height
        }
        func configure(text: String, sourceFrame: CGRect, closing: Bool, dark: Bool, contentBottom: CGFloat) {
            if self.contentBottom != contentBottom { self.contentBottom = contentBottom; view.setNeedsLayout() }
            if field.text != text { field.text = text }
            self.sourceFrame = sourceFrame
            overrideUserInterfaceStyle = dark ? .dark : .light
            guard self.closing != closing else { return }
            self.closing = closing
            if started { animate(closing: closing) }
        }
        private func animate(closing: Bool) {
            let request = UUID(); generation = request
            if closing {
                field.resignFirstResponder()
                updateSourceConstraints()
                NSLayoutConstraint.deactivate(fullConstraints); NSLayoutConstraint.activate(sourceConstraints)
            } else {
                NSLayoutConstraint.deactivate(sourceConstraints); NSLayoutConstraint.activate(fullConstraints)
                field.becomeFirstResponder()
            }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : (closing ? 0.28 : 0.32),
                           delay: 0, options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]) {
                self.view.layoutIfNeeded()
                self.field.alpha = closing ? 0 : 1
            } completion: { [weak self] _ in
                guard let self, self.generation == request, closing else { return }
                self.onClosed()
            }
        }
        @objc private func cancel() { onDismiss() }
        @objc private func changed() { onChange(field.text ?? "") }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { onSubmit(); return false }
        func stop() { generation = UUID(); field.resignFirstResponder() }
    }
    final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let result = super.hitTest(point, with: event)
            return result === self ? nil : result
        }
    }
}
#endif
