import SwiftUI

/// 文件头属性块（她 09-16：文件库预览里 frontmatter 原样当正文排着，「这个属性都没渲染」）。
/// 照 Obsidian 的 properties 摆：左键右值一行一条，键是小灰字、值可选中；整块一条细描边，不垫色块
/// （配色铁律：薄荷不套薄荷）。解析走 `MarkdownFrontmatter`，认不出的行不显示、也不吞正文。
struct FrontmatterCard: View {
    let fields: [MarkdownFrontmatter.Field]

    /// 键列宽度：按最长的键估，夹在 72...160 之间（太窄换行、太宽把值挤没）
    private var keyWidth: CGFloat {
        let longest = fields.map(\.key.count).max() ?? 0
        return min(160, max(72, CGFloat(longest) * 8 + 8))
    }

    var body: some View {
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.textMuted.opacity(0.16))
                            .frame(height: 0.5)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(field.key)
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: keyWidth, alignment: .leading)
                        Text(field.value)
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.textMuted.opacity(0.22), lineWidth: 0.5)
            )
        }
    }
}
