import SwiftUI

#if os(iOS)
/// 输入框「放大」全屏编辑（research-input-field §二③，GPT 同位右上角钮进来）。
/// 同一份草稿绑定；底部发送 = 容器的 triggerSend（发完关 sheet）。
/// 头部 chrome 复刻 DisclosureSheet（它内部套 ScrollView 放文本区会打架，所以不共用壳）。
struct InputExpandSheet: View {
    @Binding var text: String
    let uiFont: UIFont
    let canSend: Bool
    let onSend: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Compose")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                HStack {
                    GlassBackButton(systemImage: "xmark") { dismiss() }
                    Spacer()
                    // 粟粟（09-03）：与胶囊放大钮**同位置**（右上角）的缩小钮——点开在哪、点收也在哪（GPT 官端式）
                    Button { dismiss() } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)

            // T7-R2（09-09 定罪）：原 TextEditor 是 IME 竞态裸奔位——SwiftUI 黑盒每键写 binding、
            // 收到 stale binding 回写会打断组字/盖掉刚选的候选（粟粟「整句打完选字变回拼音」的真凶；
            // 主框 T7 防线全在 ChatInputTextView 的 Coordinator 里，这里一行没吃到）。
            // 换自持 UITextView + 主框同款写入契约（sheet 简化版，见 ExpandInputTextView）。
            ExpandInputTextView(text: $text, uiFont: uiFont)
                .padding(.horizontal, 14)

            HStack {
                Spacer()
                Button {
                    onSend()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? Theme.branchIndicator : Theme.textMuted.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.trailing, 16)
                .padding(.vertical, 8)
            }
        }
        .background(Theme.mainBg)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// 全屏编辑的文本区：自持 UITextView，写入契约对齐 ChatInputTextView（T7 防线家族）的
/// sheet 简化版——sheet 是独占编辑位，外部 binding 变化只有三种合法形态：
///   1. 空清穿透（发送清空），组字与否都落地
///   2. 自写回声（stale body 带旧值迟到）→ 环里认出，忽略
///   3. 其余非空外部写：非组字期落地；**组字期一律当 stale 丢弃**（不留 pending——
///      独占编辑下组字期不可能有合法外部写，重放反而是回盖风险）
/// 出方向：组字中间态不进 binding（含拼音的 marked 文本不出门，比主框更严——
/// 候选确认 marked 消失的那次 didChange 才提交终值），非组字每键提交（=原 TextEditor 节奏，
/// 保 triggerSend(fromBinding:) 读到最新值）。
private struct ExpandInputTextView: UIViewRepresentable {
    @Binding var text: String
    let uiFont: UIFont

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = uiFont
        tv.backgroundColor = .clear
        tv.textColor = UIColor(Theme.textPrimary)
        tv.delegate = context.coordinator
        tv.text = text
        context.coordinator.lastCommittedText = text
        context.coordinator.textView = tv
        // 原 FocusState+onAppear 的等价物：出现即聚焦
        DispatchQueue.main.async { [weak tv] in tv?.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parentText = $text
        if tv.font != uiFont { tv.font = uiFont }
        guard text != c.lastCommittedText else { return }
        if c.isSelfEcho(text) {
            #if DEBUG
            INPROBE("[EXPAND] extWrite ECHO ignored \(text.count)")
            #endif
        } else if tv.markedTextRange == nil || text.isEmpty {
            #if DEBUG
            INPROBE("[EXPAND] extWrite \(tv.text.count)→\(text.count)")
            #endif
            c.applyExternal(text, to: tv)
        } else {
            #if DEBUG
            INPROBE("[EXPAND] extWrite DROP marked tv=\(tv.text.count) binding=\(text.count)")
            #endif
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parentText: Binding<String>
        weak var textView: UITextView?
        var lastCommittedText = ""
        private var isApplyingExternalText = false
        private var recentSelfWrites: [String] = []
        func isSelfEcho(_ s: String) -> Bool { recentSelfWrites.contains(s) }

        init(text: Binding<String>) {
            self.parentText = text
        }

        func textViewDidChange(_ tv: UITextView) {
            guard !isApplyingExternalText else { return }
            // 组字中间态不出门：marked 期间 binding 一个含拼音值都不进
            guard tv.markedTextRange == nil else { return }
            let live = tv.text ?? ""
            guard live != lastCommittedText else { return }
            lastCommittedText = live
            recentSelfWrites.append(live)
            if recentSelfWrites.count > 64 { recentSelfWrites.removeFirst() }
            parentText.wrappedValue = live
        }

        func applyExternal(_ value: String, to tv: UITextView) {
            isApplyingExternalText = true
            tv.text = value
            tv.selectedRange = NSRange(location: (value as NSString).length, length: 0)
            isApplyingExternalText = false
            lastCommittedText = value
            recentSelfWrites.removeAll()   // 外部写=新基准（主框同款语义）
        }
    }
}
#endif
