import SwiftUI
import SwiftStreamingMarkdown

enum ChatCardBadge: Equatable {
    case none, stale, pending

    var text: String? {
        switch self {
        case .none: return nil
        case .stale: return "已更新"
        case .pending: return "待发送"
        }
    }
}

/// 所有卡片的外壳：左上棕灰类型名、右上角标、米白薄荷卡（与代码块同一套）。旧版本整体变淡且不可点。
struct ChatCardShell<Content: View>: View {
    let kindLabel: String
    var badge: ChatCardBadge = .none
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(kindLabel)
                Spacer()
                if let text = badge.text { Text(text) }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(CodeBlockStyle.label)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            MintHairline()
            content()
                .padding(14)
        }
        .mintCard()
        .environment(\.colorScheme, .light)      // 卡片底是固定米白：里面的字 / 图标也固定浅色配色，暗色模式下不糊（终审 I-2）
        .opacity(badge == .stale ? 0.55 : 1)
        .allowsHitTesting(badge != .stale)
    }
}

/// 流式中卡片还没写完（文章 / 分段模式；气泡模式沿用打字点）
struct ChatCardPlaceholder: View {
    var label = "卡片"
    var text = "卡片生成中…"

    var body: some View {
        ChatCardShell(kindLabel: label) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(CodeBlockStyle.label)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
