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
    /// 进不进「跟聊天主题」名单（见 Theme.chatCardStyle）。默认 false = 米白纸壳 + 原墨
    var themed = false
    @ViewBuilder let content: () -> Content
    @Environment(\.themeScope) private var themeScope

    var body: some View {
        // 名单卡 + 聊天作用域 + 气泡模式才换聊天主题色；其余（含文件库预览 / 编程会话）都是原来的米白卡。布局两边一样。
        let style = Theme.chatCardStyle(themed: themed, scope: themeScope)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(kindLabel)
                Spacer()
                if let text = badge.text { Text(text) }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(style?.label ?? CodeBlockStyle.label)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if let style { ChatCardHairline(color: style.stroke) } else { MintHairline() }
            content()
                .padding(14)
        }
        .modifier(ChatCardChrome(style: style))
        .opacity(badge == .stale ? 0.55 : 1)
        .allowsHitTesting(badge != .stale)
    }
}

/// 卡片外壳：没有聊天主题样式时 = 米白卡 + 固定浅色配色（终审 I-2）；有时 = 同圆角 / 同 1px 描边，只换取色，跟随当前深浅色
private struct ChatCardChrome: ViewModifier {
    let style: ChatCardStyle?
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        if let style {
            let shape = RoundedRectangle(cornerRadius: CodeBlockStyle.cornerRadius, style: .continuous)
            content
                .background(shape.fill(style.body))
                .clipShape(shape)
                .overlay(shape.strokeBorder(style.stroke, lineWidth: 1 / max(displayScale, 1)))
        } else {
            content
                .mintCard()
                .environment(\.colorScheme, .light)      // 卡片底是固定米白：里面的字 / 图标也固定浅色配色，暗色模式下不糊（终审 I-2）
        }
    }
}

private struct ChatCardHairline: View {
    let color: Color
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle().fill(color).frame(height: 1 / max(displayScale, 1))
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
