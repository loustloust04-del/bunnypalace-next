import SwiftUI

/// 长文本字段的行内预览（plan A2）：标题 + 前几行灰字 + 字数，点一下用 `FileEditorSheet.text` 全屏编辑，保存写回绑定。
/// 表单里不再塞 TextEditor——List 行里的 TextEditor 跟外层滚动打架，翻不动。
struct LongTextField: View {
    let title: String
    @Binding var text: String
    /// 编辑器顶栏标题，缺省用 title（角色卡传「角色卡 · 描述」这种）
    var editorTitle: String? = nil
    var placeholder: String = "还没写，点一下开始写"
    var format: FileEditorSheet.TextFormat = .markdown
    /// 外面已经有标签（世界书票据的 field、楼层编辑的分组标题）就不再重复显示
    var showsTitle: Bool = true
    /// 只读：原地显示全文，不能点开
    var readOnly: Bool = false
    /// A4-2 版本历史：给了就在打开 / 保存时记快照（稳定 id 由调用方定，如 card/<id>/description）
    var versionKey: FileVersionStore.Key? = nil
    /// 全屏编辑器点保存后直接落盘（卡库：整张卡 / 整个条目走表单原来的保存）；nil = 只写回表单，等表单自己保存
    var onCommit: ((String) throws -> Void)? = nil

    @State private var editing = false

    var body: some View {
        if readOnly {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: Theme.F.body))
                .foregroundColor(text.isEmpty ? Theme.textMuted : Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Button { editing = true } label: { preview }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(LongTextPreview.countLabel(text).isEmpty ? "空" : LongTextPreview.countLabel(text))
                .accessibilityHint("点开全屏编辑")
                .sheet(isPresented: $editing) {
                    FileEditorSheet.text(
                        title: editorTitle ?? title,
                        text: text,
                        format: format,
                        onSave: Self.saveHandler(text: $text, onCommit: onCommit),
                        onCancel: { editing = false },
                        versionKey: versionKey
                    )
                    // 下滑会把没保存的字一起带走；关只走「关闭」，有改动它会问
                    .interactiveDismissDisabled()
                }
        }
    }

    /// 先写回表单绑定再落盘：落盘读的是表单状态；落盘失败往上抛，编辑器弹「保存失败」、不当成已保存
    static func saveHandler(text: Binding<String>, onCommit: ((String) throws -> Void)?) -> (String) throws -> Void {
        { newValue in
            text.wrappedValue = newValue
            try onCommit?(newValue)
        }
    }

    private var preview: some View {
        let excerpt = LongTextPreview.excerpt(text)
        let count = LongTextPreview.countLabel(text)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if showsTitle {
                    Text(title)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 8)
                if !count.isEmpty {
                    Text(count)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
            }
            Text(excerpt.isEmpty ? placeholder : excerpt)
                .font(.system(size: Theme.F.body))
                .foregroundColor(excerpt.isEmpty ? Theme.textMuted.opacity(0.6) : Theme.textSecondary)
                .lineLimit(LongTextPreview.maxLines)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

enum LongTextPreview {
    static let maxLines = 4

    /// 跳过空行取前几行；只看开头一截，几万字的卡描述也不整篇扫
    static func excerpt(_ text: String, maxLines: Int = maxLines) -> String {
        text.prefix(2000)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(maxLines)
            .joined(separator: "\n")
    }

    /// 「1234 字」；空白不算有内容，返回空串
    static func countLabel(_ text: String) -> String {
        text.allSatisfy(\.isWhitespace) ? "" : "\(text.count) 字"
    }
}
