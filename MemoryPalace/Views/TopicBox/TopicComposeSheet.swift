#if PERSONAL_APPS
#if DEBUG
import SwiftUI

/// 「存成问题」统一请求载体（聊天浮条 / txt 浮条·右键 / PDF 坨坨·框选 → .sheet(item:)）。
struct TopicComposeRequest: Identifiable {
    let quote: String
    let source: String?
    let sourceLabel: String?
    let id = UUID()
}

/// 投题 sheet：手写投题（面板 +）/ 带引文投题（读书划线、聊天浮条「存成问题」，T6 传 prefill+source）。
struct TopicComposeSheet: View {
    let profileId: String
    var prefillQuote: String? = nil
    var source: String? = nil
    var sourceLabel: String? = nil
    var onSaved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("userName") private var userName = "你"

    @State private var question = ""
    @State private var detail = ""

    var body: some View {
        NavigationStack {
            List {
                Section("问题") {
                    TextField("一句问题", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section("说明（可选）") {
                    TextEditor(text: $detail)
                        .frame(minHeight: 100)
                        .font(.system(size: Theme.F.body))
                }
                if source != nil {
                    Section("出处") {
                        Label(sourceLabel ?? "选段出处", systemImage: "quote.opening")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("存进话题盒")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存进去") { save() }
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 400)
        #endif
        .onAppear {
            if detail.isEmpty, let quote = prefillQuote, !quote.isEmpty {
                detail = quote
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
            }
        }
    }

    private func save() {
        let title = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try TopicBoxStore.createCard(
                title: title,
                body: detail.trimmingCharacters(in: .whitespacesAndNewlines),
                author: userName,
                source: source,
                rootURL: FileLibraryStore.libraryRoot(profileId: profileId)
            )
            ToastCenter.shared.show("已存进话题盒 💡")
            onSaved?()
            dismiss()
        } catch {
            ToastCenter.shared.show("没存上：\(error.localizedDescription)")
        }
    }
}
#endif
#endif
