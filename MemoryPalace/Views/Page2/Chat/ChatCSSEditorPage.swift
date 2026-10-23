#if os(iOS)
import SwiftUI
import UIKit

/// 设置 → 子应用 → 聊天（css自定义）→ CSS：直接编辑当前生效的那份皮肤 CSS（像 Prompt 一样）。
/// 底座 `chat-base.css` 不给改（结构层管键盘避让），这里写的注入在它之后，同名规则 / 变量都盖得住。
struct ChatCSSEditorPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var initial = ""
    @State private var saveError: String?
    @State private var showBase = false

    private var isDirty: Bool { text != initial }

    var body: some View {
        CSSTextView(text: $text)
            .background(Theme.mainBg)
            .navigationTitle("CSS")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isDirty)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                            .foregroundColor(Theme.textMuted)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + Self.template } label: {
                            Label("插入常用变量", systemImage: "text.badge.plus")
                        }
                        Button { showBase = true } label: {
                            Label("看默认皮肤的 CSS", systemImage: "doc.text.magnifyingglass")
                        }
                        Divider()
                        Button(role: .destructive) { text = "" } label: {
                            Label("清空", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .foregroundColor(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .foregroundColor(isDirty ? Theme.branchIndicator : Theme.textMuted)
                        .disabled(!isDirty)
                }
            }
            .onAppear {
                let css = ChatSkinStore.activeSkinCSS() ?? ""
                text = css
                initial = css
            }
            .alert("保存失败", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) { Button("好") { saveError = nil } } message: { Text(saveError ?? "") }
            .sheet(isPresented: $showBase) {
                NavigationStack {
                    CSSTextView(text: .constant(Self.baseCSS), editable: false)
                        .navigationTitle("默认皮肤（只读）")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("关闭") { showBase = false } } }
                }
            }
    }

    private func save() {
        do {
            try ChatSkinStore.saveUserCSS(text)
            initial = text
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static var baseCSS: String {
        guard let url = Bundle.main.url(forResource: "chat-base", withExtension: "css", subdirectory: "Web")
                ?? Bundle.main.url(forResource: "chat-base", withExtension: "css"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "（没找到 chat-base.css）" }
        return s
    }

    /// 最常改的几个变量，值 = 默认皮肤的值；全部变量见「看默认皮肤的 CSS」
    private static let template = """
    :root {
      --mp-page-bg: #FAF7F2;
      --mp-user-bg: #D9EDE4;
      --mp-user-ink: #2C2A28;
      --mp-ai-bg: #FFFFFF;
      --mp-ai-ink: #2C2A28;
      --mp-bubble-radius: 16px;
      --mp-avatar-size: 0px;
      --mp-accent: #7FB69B;
      --mp-input-bg: #FFFDFA;
    }

    """
}

/// 写代码用的 UITextView：关掉智能引号 / 破折号 / 自动纠错——SwiftUI TextEditor 关不掉智能标点，
/// 一个 `"` 被换成 `“` CSS 就整条失效。
private struct CSSTextView: UIViewRepresentable {
    @Binding var text: String
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.isEditable = editable
        v.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        v.textColor = UIColor(Theme.textPrimary)
        v.tintColor = UIColor(Theme.branchIndicator)
        v.backgroundColor = .clear
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.spellCheckingType = .no
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.smartInsertDeleteType = .no
        v.keyboardDismissMode = .interactive
        v.alwaysBounceVertical = true
        v.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ v: UITextView) { text.wrappedValue = v.text }
    }
}
#endif
