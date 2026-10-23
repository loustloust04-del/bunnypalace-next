#if os(macOS)
import SwiftUI

/// Hover belongs to this row, not SidebarView. Controls stay mounted in a fixed
/// trailing slot; pointer entry changes opacity/fill without animation or reflow.
struct MacConversationRow<MenuItems: View>: View {
    let conversation: Conversation
    let selected: Bool
    let canPin: Bool
    /// 收藏页里这条对话挂的收藏标签（10-02），标题下一行小字
    var favoriteTags: [String] = []
    let onSelect: () -> Void
    let onRename: () -> Void
    let onPin: () -> Void
    @ViewBuilder let menuItems: () -> MenuItems
    @State private var hovered = false

    private var showActions: Bool { hovered || selected }

    var body: some View {
        HStack(spacing: 6) {
            MacConversationTitle(conversation: conversation, favoriteTags: favoriteTags)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onRename)
                .onTapGesture(perform: onSelect)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, onSelect)
            ZStack(alignment: .trailing) {
                Text(ConversationRow.smartDate(conversation.updateTime))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .opacity(showActions ? 0 : 1)
                    .accessibilityHidden(showActions)
                MacConversationActions(pinned: conversation.isPinned, canPin: canPin,
                    onPin: onPin, menuItems: menuItems)
                    .opacity(showActions ? 1 : 0)
                    .allowsHitTesting(showActions)
                    .disabled(!showActions)
                    .accessibilityHidden(!showActions)
            }
            .frame(width: 54)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(selected ? ShellStyle.selection : (hovered ? ShellStyle.hover : .clear),
                    in: RoundedRectangle(cornerRadius: 9))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { active in
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { hovered = active }
        }
        .animation(nil, value: hovered)
        .contextMenu { menuItems() }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MacConversationTitle: View {
    let conversation: Conversation
    var favoriteTags: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(conversation.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if conversation.isFavorite {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.favorite)
                }
                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.branchIndicator)
                }
            }
            if let session = conversation.ccBridgeSessionName, !session.isEmpty {
                Text(session).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            }
            if !favoriteTags.isEmpty {
                FavoriteTagLine(tags: favoriteTags)
            }
        }
    }
}

private struct MacConversationActions<MenuItems: View>: View {
    let pinned: Bool
    let canPin: Bool
    let onPin: () -> Void
    @ViewBuilder let menuItems: () -> MenuItems
    var body: some View {
        HStack(spacing: 2) {
            Button(action: onPin) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .rotationEffect(.degrees(pinned ? 0 : 35))
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(pinned ? Theme.branchIndicator : Theme.textSecondary)
            .help(pinned ? "取消置顶" : "置顶对话")
            .accessibilityLabel(pinned ? "取消置顶" : "置顶对话")
            .opacity(canPin ? 1 : 0)
            .disabled(!canPin)
            .accessibilityHidden(!canPin)
            Menu { menuItems() } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作（与右键菜单相同）")
            .accessibilityLabel("更多对话操作")
        }
        .font(.system(size: 13))
    }
}
#endif
