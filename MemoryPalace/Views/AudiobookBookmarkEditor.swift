#if PERSONAL_APPS
#if DEBUG
import SwiftUI

/// 编辑书签笔记的 sheet。
/// 未来卡片化（插 md 编辑器）只读 bookmark 字段，不引用此 view 任何类型。
struct AudiobookBookmarkEditor: View {
    @Environment(\.dismiss) private var dismiss

    let bookmark: AudiobookBookmark
    let onSave: () -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "bookmark.fill")
                    .foregroundColor(Theme.branchIndicator)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.accent.opacity(0.52)))
                Text(formatTime(bookmark.timestamp))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(bookmark.bookTitleSnapshot)
                    .font(.system(size: Theme.F.caption, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }

            Divider()

            Text("笔记")
                .font(.system(size: Theme.F.secondary, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            TextEditor(text: $draft)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)
                .frame(minHeight: 120)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accent.opacity(0.34))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.textMuted.opacity(0.10), lineWidth: 0.5)
                )

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    bookmark.note = draft
                    bookmark.updatedAt = Date()
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .background(Theme.mainBg)
        .frame(minWidth: 360, minHeight: 280)
        .onAppear { draft = bookmark.note }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}
#endif
#endif
