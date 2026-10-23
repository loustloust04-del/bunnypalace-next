import SwiftUI

/// 右栏子应用的分组列表（plan-mac-subapp-appearance §2）：写法同 `List { Section { } header: { } footer: { } }`。
/// iOS = 原样 `List`（`.listStyle` / `.scrollContentBackground` / `.listRowBackground` 照旧由调用方给）；
/// mac = 实底大圆角分组卡（小样 A，`docs/design-mac-subapp-cards.html`），AppKit 平铺表格在 mac 上是一条条通栏白带。
/// mac 分支里 `.listRowBackground` / `.swipeActions` 这类 List 专属修饰不生效，要用的页自己在 mac 分支补。
struct PanelSectionList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        if !section.header.isEmpty {
                            HStack(spacing: 4) { section.header }
                                .font(.system(size: 11))
                                .foregroundStyle(ShellStyle.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 5)
                        }
                        if !section.content.isEmpty {
                            PanelCard { ForEach(section.content) { $0 } }
                        }
                        if !section.footer.isEmpty {
                            VStack(alignment: .leading, spacing: 4) { section.footer }
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 6)
                                .padding(.top, 6)
                        }
                    }
                }
            }
            .padding(12)
        }
        // 卡本身就是底：系统输入框的边框会在白卡里再套一层；mac 开关默认是勾选框，跟 iOS 分组卡的开关对不上。
        // 必须挂在 ForEach(sections:) 外面：行在这里就被拆出来了，挂到卡上传不进行里（09-24 世界书编辑页开关还是勾选框）
        .textFieldStyle(.plain)
        .toggleStyle(MacSettingsToggleStyle())   // 字左、开关靠右，跟设置页 / iOS 分组卡一致
        .controlSize(.small)
        #else
        List { content }
        #endif
    }
}

extension View {
    /// 离不开 `List` 的页（记忆：多选 / 删除 / editMode）的行底：iOS 照旧通栏；
    /// mac 的 `.plain` List 通栏白带像斑马纹，画成左右缩进的圆角卡，接近分组卡又不丢 List 的能力
    func panelRowBackground(_ color: Color = Theme.mainBg) -> some View {
        #if os(macOS)
        listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        )
        #else
        listRowBackground(color)
        #endif
    }

    /// 右栏弹出的 sheet 的标题：iOS 走系统导航栏；mac 的 sheet 里 navigationTitle 不画成标题行，
    /// 被顶到 sheet 上沿切掉半截（09-24 世界书编辑页），自己画一行
    @ViewBuilder
    func panelSheetTitle(_ title: String) -> some View {
        #if os(macOS)
        safeAreaInset(edge: .top, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShellStyle.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        #else
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if os(macOS)
/// 一张分组卡：行之间 0.5pt 分隔线（左缩 12，第一行上方不画），行高 ≥ 40
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { rows in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle().fill(ShellStyle.hairline)
                            .frame(height: ShellStyle.hairlineWidth)
                            .padding(.leading, 12)
                    }
                    row
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }
            }
        }
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 0.5, y: 0.5)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}
#endif
