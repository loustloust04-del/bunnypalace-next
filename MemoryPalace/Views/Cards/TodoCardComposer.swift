#if os(iOS)
import SwiftUI

/// ➕ →「待办」：填标题和几项（每行一项），确定后放进输入框（research-chat-cards §4.6）。
struct TodoCardComposer: View {
    /// 对话里已有的卡片 id：新卡片避开它们（终审 #2）
    var takenIds: Set<String> = []
    let onDone: (TodoCard) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var itemsText = ""

    private var card: TodoCard? {
        TodoCard.make(title: title, lines: itemsText.components(separatedBy: "\n"), avoiding: takenIds)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题（可空）", text: $title)
                Section("每行一项") {
                    TextEditor(text: $itemsText).frame(minHeight: 160)
                }
            }
            .navigationTitle("待办卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("放进输入框") {
                        if let card { onDone(card) }
                        dismiss()
                    }
                    .disabled(card == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
