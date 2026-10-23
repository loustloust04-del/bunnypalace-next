import SwiftUI

// MARK: - 两类记忆共用的一行（#067 第 3 步）

/// 列表选择 / 行 id：档案按 UUID，{{char}}自己记下的按文件 slug
enum MemoryRowID: Hashable {
    case archive(UUID)
    case assistant(String)

    var archiveId: UUID? {
        if case .archive(let id) = self { return id }
        return nil
    }

    var slug: String? {
        if case .assistant(let s) = self { return s }
        return nil
    }
}

/// 行的数据：档案（`Memory`）和{{char}}自己记下的（`SelfMemory`）都折成这一份
struct MemoryRowItem: Identifiable, Equatable {
    let id: MemoryRowID
    let text: String
    let kind: String
    let created: Date
    let deletedAt: Date?
    /// 只有{{char}}自己记下的有重要度；档案没有这个字段，不画圆点
    let importance: Int?
    let pinned: Bool
    let hasSource: Bool

    var isDeleted: Bool { deletedAt != nil }

    init(_ m: Memory) {
        id = .archive(m.id)
        text = m.content
        kind = MemoryCardView.categoryLabels[m.category] ?? m.category
        created = m.createdAt
        deletedAt = m.supersededAt
        importance = nil
        pinned = m.isUserExplicit
        hasSource = m.sourceConversationId != nil
    }

    init(_ m: SelfMemory) {
        id = .assistant(m.slug)
        text = m.description.isEmpty ? m.name : m.description
        let type = SelfMemoryEditView.typeText(m.type)
        kind = m.origin == "asked" ? "\(type) · \(SelfMemoryEditView.originText(m.origin))" : type
        created = m.created
        deletedAt = m.superseded
        importance = m.importance
        pinned = false
        hasSource = false
    }

    /// 「类型 · 日期」；已删除的写「删于 哪天」
    var infoLine: String {
        if let d = deletedAt { return "\(kind) · 删于 \(MemoryDateText.short(d))" }
        return "\(kind) · \(MemoryDateText.short(created))"
    }
}

/// 一行：正文最多 2 行 + 信息行；行尾钉住小图钉 / 重要度圆点。没有色条、没有行内再套一层底。
/// mac 行尾「⋯」hover 时淡入（透明度，不用条件渲染），菜单内容由调用方给（和右键菜单同一份）。
struct MemoryRow<MenuItems: View>: View {
    let item: MemoryRowItem
    @ViewBuilder var menu: () -> MenuItems
    @Environment(\.settingsMetrics) private var m

    #if os(macOS)
    @State private var hovering = false
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(m.body)
                    .foregroundColor(item.isDeleted ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(2)
                Text(item.infoLine)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if item.pinned && !item.isDeleted {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.branchIndicator)
                }
                if let importance = item.importance {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= importance ? "circle.fill" : "circle")
                                .font(.system(size: 6))
                        }
                    }
                    .foregroundColor(item.isDeleted ? Theme.textMuted : Theme.branchIndicator)
                }
            }
            .padding(.top, 5)
            #if os(macOS)
            Menu { menu() } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            #endif
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
    }
}
