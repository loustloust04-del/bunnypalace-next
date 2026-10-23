import SwiftUI

/// 底部浮动页签的一格：标题 + SF Symbol（日历、记忆共用 `PanelFloatingTabBar`）
protocol PanelFloatingTab: Hashable, CaseIterable where AllCases: RandomAccessCollection {
    var title: String { get }
    var icon: String { get }
}

/// 底部浮动页签（mac 用；iOS 走系统 TabView）：玻璃胶囊，选中项垫一块会滑的亮胶囊。从日历的 `CalendarIOSTabBar` 原样泛型化
struct PanelFloatingTabBar<T: PanelFloatingTab>: View {
    @Binding var selection: T
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(T.allCases, id: \.self) { t in
                let on = t == selection
                Button {
                    if reduceMotion { selection = t } else { withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = t } }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.icon).font(.system(size: 17))
                        Text(t.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }
                    .foregroundColor(on ? Theme.branchIndicator : Theme.textPrimary)
                    .frame(maxWidth: 74)
                    .frame(height: 52)
                    .background {
                        if on { Capsule().fill(Theme.textPrimary.opacity(0.07)).matchedGeometryEffect(id: "pill", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background { glass }
        .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
        .padding(.horizontal, 24)
    }

    /// 玻璃只铺在底下，不挂在按钮上（iOS 26 `.glassEffect` + plain 按钮会吞点击）
    @ViewBuilder
    private var glass: some View {
        if #available(iOS 26, macOS 26, *) {
            Color.clear.glassEffect(.regular, in: .capsule).allowsHitTesting(false)
        } else {
            Capsule().fill(.ultraThinMaterial).allowsHitTesting(false)
        }
    }
}
