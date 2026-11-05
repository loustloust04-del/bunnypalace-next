import SwiftUI

/// B2：Prompt 页 / AI 性格页顶部「正在编辑：楼层 · 角色卡 X」——这些设定按楼层存，别让人以为是全局的
struct PromptEditingContextRow: View {
    let floorName: String
    let cardName: String?
    /// 能直接打开卡库时给；nil 只显示卡名
    var onOpenCard: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text("正在编辑：\(floorName)").foregroundColor(Theme.textSecondary)
            if let cardName {
                Text("·").foregroundColor(Theme.textMuted)
                if let onOpenCard {
                    Button(action: onOpenCard) {
                        Text("角色卡 \(cardName)").foregroundColor(Theme.branchIndicator)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("在卡库里打开这张卡")
                } else {
                    Text("角色卡 \(cardName)").foregroundColor(Theme.textSecondary)
                }
            }
        }
        .font(.system(size: Theme.F.caption))
        .lineLimit(1)
    }
}
