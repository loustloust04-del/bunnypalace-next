import SwiftUI

// MARK: - 设置页两端共用的容器原语（plan-settings-merge §2.2）
//
// 原则「mac 给卡，iOS 给原样」：iOS 那侧渲染成合流前的样子，不新增一像素 padding；只有 mac 那侧统一进
// `MacSettingsForm` / `MacSettingsCard` / `MacSettingsSection`。这里是设置页里唯一允许出现 `#if os` 的容器层。

/// Section 树的宿主。iOS 保留各页原容器（`List` / `Form`），mac 收成分组卡。
struct SettingsSectionList<Content: View>: View {
    enum Flavor { case list, form }

    let flavor: Flavor
    let content: Content

    init(_ flavor: Flavor = .list, @ViewBuilder content: () -> Content) {
        self.flavor = flavor
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        MacSettingsForm { content }
        #else
        switch flavor {
        case .list: List { content }
        case .form: Form { content }
        }
        #endif
    }
}

/// 一张卡。只用在 iOS 原来就是「`.padding(12)` + `Theme.mainBg` 圆角 8」的地方。
struct SettingsCard<Content: View>: View {
    @Environment(\.settingsMetrics) private var m
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        MacSettingsCard { content }
        #else
        VStack(alignment: .leading, spacing: m.rowSpacing) { content }
            .padding(m.cardPadding)
            .background(RoundedRectangle(cornerRadius: m.cardCorner).fill(Theme.mainBg))
        #endif
    }
}

/// 组名 + 内容。iOS = 组名文字 + **裸内容**（等于原来的 `Text` + `VStack`，不加卡）；mac = `MacSettingsSection`。
/// `divider`：iOS 原来这组上方画了 `Divider().opacity(0.4)` 就传 true，mac 不画（卡之间靠留白）。
struct SettingsGroup<Content: View>: View {
    @Environment(\.settingsMetrics) private var m
    let title: String
    let divider: Bool
    /// 搜索锚点：iOS 挂在组名文字上（跟合流前一样），mac 挂在整组
    let anchor: String?
    let content: Content

    init(_ title: String, divider: Bool = false, anchor: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.divider = divider
        self.anchor = anchor
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        if let anchor {
            MacSettingsSection(title) { content }.searchAnchor(anchor)
        } else {
            MacSettingsSection(title) { content }
        }
        #else
        Group {
            if divider {
                Divider().opacity(0.4)
            }
            if let anchor {
                Text(title)
                    .font(m.sectionHeader)
                    .foregroundColor(m.sectionHeaderColor)
                    .searchAnchor(anchor)
            } else {
                Text(title)
                    .font(m.sectionHeader)
                    .foregroundColor(m.sectionHeaderColor)
            }
            content
        }
        #endif
    }
}

extension EnvironmentValues {
    /// 只有 `MacSettingsPage` 置 true：它注册了 `navigationDestination(for: SettingsRoute.self)`，值驱动 link 才有落点。
    /// 别的 mac 宿主（右栏面板等自带 NavigationStack 的地方）没注册，`SettingsNavRow` 退回 destination 式 link。
    @Entry var settingsRouteHost = false
    /// 页面注入后，页里的行用它登记「真离开时」的收尾
    @Entry var settingsPageExit: SettingsPageExit? = nil
}

/// 设置页真离开（返回 / 推进下一页 / mac 换页）时通知页里的行收尾。
/// Section 或行上的 `.onDisappear` 滚出屏幕就触发，不能当离开用；停录音、停任务登记在这里，页面在整页容器的 `.onDisappear` 里 `fire()`。
@MainActor final class SettingsPageExit {
    private var handlers: [String: () -> Void] = [:]
    func onExit(_ id: String, _ run: @escaping () -> Void) { handlers[id] = run }
    /// 跑完就清：闭包捕获的行又经环境持着本对象，不清会成环。回到页面时行的 `.task` 会重新登记
    func fire() {
        let runs = handlers.values
        handlers = [:]
        for run in runs { run() }
    }
}

/// 二级页入口行。iOS 走 destination（系统自带指示器）；mac 在设置窗里走 `SettingsRoute` 值驱动 path（页顶 ‹ › 靠它回退），
/// 在别的宿主里走 destination；两种 mac 分支都自画 chevron（label 里别再画）。
struct SettingsNavRow<Label: View, Destination: View>: View {
    let route: SettingsRoute
    let destination: () -> Destination
    let label: () -> Label
    #if os(macOS)
    @Environment(\.settingsRouteHost) private var routeHost
    #endif

    init(_ route: SettingsRoute,
         @ViewBuilder destination: @escaping () -> Destination,
         @ViewBuilder label: @escaping () -> Label) {
        self.route = route
        self.destination = destination
        self.label = label
    }

    var body: some View {
        #if os(macOS)
        Group {
            if routeHost {
                NavigationLink(value: route) { macLabel }
            } else {
                NavigationLink { destination() } label: { macLabel }
            }
        }
        .buttonStyle(.plain)
        #else
        NavigationLink { destination() } label: { label() }
        #endif
    }

    #if os(macOS)
    private var macLabel: some View {
        HStack {
            label()
            Spacer()
            Image(systemName: "chevron.right")
                .font(ShellStyle.secondaryFont)
                .foregroundStyle(ShellStyle.secondaryText)
        }
    }
    #endif
}

// MARK: - 动作按钮（导出 / 导入 / 新建 …）两端的皮

extension View {
    /// 按钮壳：mac 走 `MacSettingsButton` 灰底 chip（J2 口径——宿主故意不下发，逐颗显式挂）；iOS 保持 `.plain`，长相由标签自己画。
    func settingsActionButton() -> some View {
        #if os(macOS)
        buttonStyle(MacSettingsButton())
        #else
        buttonStyle(.plain)
        #endif
    }

    /// iOS 侧的胶囊标签（实心薄荷 + 白字 / 薄荷描边 + 薄荷字）；mac 不描边不垫底（chip 自己有底），
    /// 只保 J2 的两种字色：主动作 = 正文色、次动作 = 薄荷（`MacShellButton` 默认给次级灰，不能靠它兜）。
    /// `hPadding`：iOS 胶囊的左右内边距，各页原值不同（贴纸 14 / 通用「确认」16），照抄原值别归一。
    func settingsCapsuleLabel(filled: Bool, hPadding: CGFloat = 14) -> some View {
        #if os(macOS)
        foregroundColor(filled ? ShellStyle.text : Theme.branchIndicator)
        #else
        self
            .foregroundColor(filled ? .white : Theme.branchIndicator)
            .padding(.horizontal, hPadding)
            .padding(.vertical, 8)
            .background {
                if filled {
                    Capsule().fill(Theme.branchIndicator)
                } else {
                    Capsule().stroke(Theme.branchIndicator, lineWidth: 1)
                }
            }
        #endif
    }
}
