import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 可注入自定义选段动作的纯文本视图（R2-4 气泡划词收词）。
/// 阅读器 MPReaderWebView 同款模式：iOS 走 UIMenuController.menuItems 注入原生浮条，
/// macOS 走 NSTextView menu(for:) 前插右键项。回调带（选中文本, 所在句子）。
#if os(iOS)

/// ⚠️ 教训（2026-07-09）：UIMenuController.menuItems 只在 WKWebView（阅读器）里还活着；
/// UITextView 的选段浮条 iOS 16+ 走 UIEditMenuInteraction，注入必须用
/// UITextViewDelegate.textView(_:editMenuForTextIn:suggestedActions:)。
struct SelectableActionTextView: UIViewRepresentable {
    let text: String
    var onCollectVocab: ((String, String) -> Void)?
    var onQuote: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 16)
        view.textColor = UIColor(Theme.textPrimary)
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableActionTextView

        init(_ parent: SelectableActionTextView) {
            self.parent = parent
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            #if DEBUG
            print("[PROBE] TextSelect editMenu fired, range.length=\(range.length)")
            #endif
            guard range.length > 0, let full = textView.text,
                  let r = Range(range, in: full) else {
                return UIMenu(children: suggestedActions)
            }
            let selected = String(full[r])

            var items: [UIMenuElement] = []
            if let onCollect = parent.onCollectVocab {
                let sentence = VocabCollector.sentence(containing: r, in: full)
                items.append(UIAction(title: "收生词") { _ in
                    onCollect(selected, sentence)
                })
            }
            if let onQuote = parent.onQuote {
                items.append(UIAction(title: "引用") { _ in
                    onQuote(selected)
                })
            }
            // 系统项只留标准编辑组（复制/全选），Look Up/Translate/Share 收敛掉（阅读器同款口径）
            let standard = suggestedActions.filter { ($0 as? UIMenu)?.identifier == .standardEdit }
            return UIMenu(children: items + standard)
        }
    }
}

#else

final class MPActionNSTextView: NSTextView {
    var onCollectVocab: ((String, String) -> Void)?
    var onQuote: ((String) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard selectedRange().length > 0 else { return menu }
        let quote = NSMenuItem(title: "引用", action: #selector(mp_quote(_:)), keyEquivalent: "")
        quote.target = self
        menu.insertItem(quote, at: 0)
        let collect = NSMenuItem(title: "收生词", action: #selector(mp_collectVocab(_:)), keyEquivalent: "")
        collect.target = self
        menu.insertItem(collect, at: 0)
        menu.insertItem(.separator(), at: 2)
        return menu
    }

    private var selectedText: String? {
        let range = selectedRange()
        guard range.length > 0, let r = Range(range, in: string) else { return nil }
        return String(string[r])
    }

    @objc func mp_collectVocab(_ sender: Any?) {
        guard let sel = selectedText, let r = Range(selectedRange(), in: string) else { return }
        onCollectVocab?(sel, VocabCollector.sentence(containing: r, in: string))
    }

    @objc func mp_quote(_ sender: Any?) {
        guard let sel = selectedText else { return }
        onQuote?(sel)
    }
}

struct SelectableActionTextView: NSViewRepresentable {
    let text: String
    var onCollectVocab: ((String, String) -> Void)?
    var onQuote: ((String) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MPActionNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = NSColor(Theme.textPrimary)
        textView.textContainerInset = NSSize(width: 12, height: 16)
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MPActionNSTextView else { return }
        if view.string != text { view.string = text }
        view.onCollectVocab = onCollectVocab
        view.onQuote = onQuote
    }
}

#endif
