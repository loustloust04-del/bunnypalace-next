#if os(macOS)
import SwiftUI

/// mac 停靠壳的一列（plan-panel-ps 2b）：几个组上下叠（底列左右排），组间一条缝可拖分尺寸。
///
/// 尺寸全从 `PanelColumnLayout.extents` 拿；**这里是 `groupWeights` 的唯一读者**（热字段），
/// 组内容只拿冷数据 + 这里给的尺寸——拖缝时组内容的值不变（plan §5）。
/// 外边距整列扣一次（同 `MacWorkspacePane`），组是没有外边距的卡片（`MacPaneCard`）；只有一个组时和改造前逐像素一样
struct MacDockColumn<Group: View, Empty: View>: View {
    let layout: IPadPanelLayout
    let edge: PanelEdge
    /// 列的外尺寸在分配轴上的长度（左右列 = 工作区高；底列 = 卡槽宽）
    let length: CGFloat
    /// 列外边距；nil = 左右列的默认（同 `MacWorkspacePane`）。底列传卡的左右外边距 + 下外边距，跟正文卡对齐
    var insets: EdgeInsets? = nil
    @ViewBuilder let group: (String) -> Group
    @ViewBuilder let empty: () -> Empty

    @State private var dragStart: [CGFloat]?

    static var seam: CGFloat { 6 }
    static var minBody: CGFloat { 80 }
    private var horizontal: Bool { edge == .bottom }

    var body: some View {
        let metrics = MacShellMetrics.shared
        let pad = insets ?? EdgeInsets(top: metrics.cardGapTop, leading: ShellStyle.paneInset,
                                       bottom: metrics.cardGapBottom, trailing: ShellStyle.paneInset)
        let ids = layout.visibleGroups(edge)
        let collapsed = ids.map { $0 != IPadPanelLayout.convWindowId && layout.isCollapsed($0) }
        let inset = horizontal ? pad.leading + pad.trailing : pad.top + pad.bottom
        let weights = PanelColumnLayout.weights(ids.map { layout.groupWeights[$0] })
        let result = PanelColumnLayout.extents(
            total: length - inset,
            items: ids.indices.map { .init(weight: weights[$0], collapsed: collapsed[$0]) },
            bar: ShellStyle.barHeight, seam: Self.seam, minBody: horizontal ? 200 : Self.minBody,
            collapsedSize: horizontal ? 3 * ShellStyle.barHeight : nil)
        return stack {
            if ids.isEmpty {
                empty().modifier(MacPaneCard())
            } else {
                ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                    group(id)
                        .frame(width: horizontal ? result.sizes[safe: i] : nil, height: horizontal ? nil : result.sizes[safe: i])
                        .modifier(MacPaneCard())
                    if i < ids.count - 1 {
                        seam(after: i, ids: ids, collapsed: collapsed, sizes: result.sizes, width: result.seam)
                    }
                }
                if result.remainder > 0 { Spacer(minLength: 0) }
            }
        }
        .padding(pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func stack<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if horizontal {
            HStack(spacing: 0, content: content)
        } else {
            VStack(spacing: 0, content: content)
        }
    }

    /// 两个相邻组之间的缝：两边都展开才能拖（折成标题线的组没有高度可分）
    @ViewBuilder
    private func seam(after i: Int, ids: [String], collapsed: [Bool], sizes: [CGFloat], width: CGFloat) -> some View {
        let draggable = !collapsed[i] && !collapsed[i + 1]
        Color.clear
            .frame(width: horizontal ? width : nil, height: horizontal ? nil : width)
            .overlay {
                if draggable {
                    PanelResizeHandle(axis: horizontal ? .vertical : .horizontal) { delta in
                        let start = dragStart ?? sizes
                        if dragStart == nil { dragStart = sizes }
                        let next = PanelColumnLayout.dragSeam(sizes: start, at: i, delta: delta,
                                                              floor: ShellStyle.barHeight + (horizontal ? 200 : Self.minBody))
                        // 写成「均值 = 1」的比例：没拖过的新组缺省 1，跟拖过的组同一个量纲（09-24 实拍：点数当 weight，新组被挤成 120）
                        let expanded = ids.indices.filter { !collapsed[$0] }
                        let mean = expanded.reduce(0) { $0 + next[$1] } / CGFloat(max(1, expanded.count))
                        var weights = layout.groupWeights
                        for k in expanded where mean > 0 { weights[ids[k]] = next[k] / mean }
                        if weights != layout.groupWeights { layout.groupWeights = weights }
                    } onEnded: { dragStart = nil }
                }
            }
            .zIndex(1)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
