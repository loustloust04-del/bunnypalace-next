import SwiftUI

/// 记忆 app 的空状态（记忆首屏 / 时间轴 / 已删除共用）：点点拼的一朵小花 + 一串珠子当茎，下面一句标题一句说明。
/// 花园视觉语言（开屏页）：小圆点拼图形、大小交替的珠串、大面积留白；只用主题的薄荷和灰，不铺色块。
/// 自己撑满父视图并居中——挂在 List 外（overlay / 替换 List），别塞进 Section 行。
struct MemoryEmptyState<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        VStack(spacing: 16) {
            MemoryDotFlower()
                .frame(width: 64, height: 86)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(m.body.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(message)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                actions()
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MemoryEmptyState where Actions == EmptyView {
    init(title: String, message: String) {
        self.init(title: title, message: message) { EmptyView() }
    }
}

/// 记忆 app 的文字按钮一个样：薄荷实心胶囊 + 白字（空状态、弹层主操作；返工 2 粟粟定的）。
/// 删除这类破坏性按钮不用它，保持 destructive 角色；导航栏图标、列表行里的跳转行也不用它。`fullWidth` 给弹层底部那种整行按钮
struct MemoryPrimaryButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(fullWidth: fullWidth, pressed: configuration.isPressed) { configuration.label }
    }

    private struct StyledLabel<Content: View>: View {
        let fullWidth: Bool
        let pressed: Bool
        @ViewBuilder let content: () -> Content
        @Environment(\.settingsMetrics) private var m
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            content()
                .font(m.body.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 44 : 36)
                .background(Capsule().fill(Theme.branchIndicator))
                .contentShape(Capsule())
                .opacity(pressed ? 0.7 : (isEnabled ? 1 : 0.4))
        }
    }
}

/// 点点花：花心一颗灰褐点，内圈 6 颗薄荷花瓣、外圈 6 颗更淡的小点错开半格；茎是大小交替的珠串，旁边两颗小叶
private struct MemoryDotFlower: View {
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy: CGFloat = 26
            func dot(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)), with: .color(color))
            }
            for i in 0..<6 {
                let a = Double(i) * .pi / 3 - .pi / 2
                dot(cx + 11 * CGFloat(cos(a)), cy + 11 * CGFloat(sin(a)), 8, Theme.branchIndicator.opacity(0.6))
                let b = a + .pi / 6
                dot(cx + 19 * CGFloat(cos(b)), cy + 19 * CGFloat(sin(b)), 4.5, Theme.branchIndicator.opacity(0.3))
            }
            dot(cx, cy, 7, Theme.textSecondary.opacity(0.75))

            var y: CGFloat = 50
            var big = true
            while y < size.height - 2 {
                dot(cx, y, big ? 4.5 : 3, Theme.textMuted.opacity(0.55))
                y += big ? 7 : 6
                big.toggle()
            }
            dot(cx + 7, 64, 4, Theme.branchIndicator.opacity(0.45))
            dot(cx + 12, 60, 3, Theme.branchIndicator.opacity(0.3))
        }
    }
}
