import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 大段原文（请求体 / 工具结果 / 运行记录 / 预览 JSON）统一用这个看：原生 TextKit 2 只读文本视图，
/// 只排看得见的部分，自己会滚、能选能复制。
/// 别再用 SwiftUI `Text` 放整段——它一次排完全文，十几万字在 iPhone 14 上是十秒级主线程卡死（2026-11-11 窗口透视）。
/// 要有确定高度：整页 sheet 里 `.frame(maxHeight: .infinity)`；嵌在别的滚动页里用 `LongTextBox`。
#if os(iOS)
struct LongTextView: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 11
    var color: Color = Theme.textPrimary
    /// false = 正文字体（记忆文件这类散文）；默认等宽（请求体 / JSON / 日志）
    var monospaced = true

    private var font: UIFont { monospaced ? .monospacedSystemFont(ofSize: fontSize, weight: .regular) : .systemFont(ofSize: fontSize) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.font = font
        view.textColor = UIColor(color)
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 24, right: 0)
        view.alwaysBounceVertical = true
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.font != font { view.font = font }
        view.textColor = UIColor(color)
        if view.text != text {
            view.text = text
            view.setContentOffset(.zero, animated: false)
        }
    }
}
#else
struct LongTextView: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = 11
    var color: Color = Theme.textPrimary
    /// false = 正文字体（记忆文件这类散文）；默认等宽（请求体 / JSON / 日志）
    var monospaced = true

    private var font: NSFont { monospaced ? .monospacedSystemFont(ofSize: fontSize, weight: .regular) : .systemFont(ofSize: fontSize) }

    func makeNSView(context: Context) -> NSScrollView {
        // 系统工厂建的就是 TextKit 2；离屏实测上屏 12ms，自己拼的那套 50ms
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.font = font
            textView.textColor = NSColor(color)
            textView.textContainerInset = NSSize(width: 0, height: 4)
            textView.string = text
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let textView = view.documentView as? NSTextView else { return }
        if textView.font != font { textView.font = font }
        textView.textColor = NSColor(color)
        if textView.string != text {
            textView.string = text
            textView.scroll(.zero)
        }
    }
}
#endif

/// 嵌在滚动页里的原文框：短的按内容给高，长的封顶、在框里自己滚。
struct LongTextBox: View {
    let text: String
    var fontSize: CGFloat = 11
    var color: Color = Theme.textPrimary
    var maxHeight: CGFloat = 360

    var body: some View {
        LongTextView(text: text, fontSize: fontSize, color: color)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height(text, fontSize: fontSize, maxHeight: maxHeight))
    }

    /// 只为定框高的粗估（换行 + 每行约 44 个等宽字折行），够到封顶就停，不扫完全文。
    static func height(_ text: String, fontSize: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let lineHeight = fontSize * 1.3
        let limit = Int(maxHeight / lineHeight) + 1
        var lines = 1, run = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                lines += 1; run = 0
            } else {
                run += 1
                if run > 44 * 3 { lines += 1; run = 0 }   // 中文一个字 3 字节、占两格，按字节粗算偏保守
            }
            if lines >= limit { return maxHeight }
        }
        return min(maxHeight, CGFloat(lines) * lineHeight + 32)
    }
}
