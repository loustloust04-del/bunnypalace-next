import SwiftUI

/// 面板把手：竖向（拖左右改宽）/ 横向（拖上下改高，也当卡与卡之间的缝）。
///
/// 命中区 16pt，视觉 4×44 圆条——透明区不吃 hit test（上一刀图钉的教训），必须 `contentShape`。
/// 手势给的是**相对起点的累计位移**，调用方第一帧记起点、每帧 起点+位移 钳制后写回；
/// 不用增量累加，避免钳住之后位移跑偏。mac 悬停换左右 / 上下缩放光标（A2a-4）
struct PanelResizeHandle: View {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void = {}

    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        grip
            .opacity(dragging || hovering ? 0.95 : 0.4)
            .animation(ShellMotion.feedback(.easeOut(duration: 0.15)), value: dragging || hovering)
            .frame(width: axis == .vertical ? 16 : nil, height: axis == .horizontal ? 16 : nil)
            .frame(maxWidth: axis == .horizontal ? .infinity : nil,
                   maxHeight: axis == .vertical ? .infinity : nil)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .modifier(HandleCursor(vertical: axis == .vertical, hold: dragging))
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        dragging = true
                        onChanged(axis == .vertical ? v.translation.width : v.translation.height)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnded()
                    }
            )
    }

    private var grip: some View {
        Capsule()
            #if os(macOS)
            .fill(ShellStyle.secondaryText)
            .frame(width: axis == .vertical ? ShellStyle.gripThickness : ShellStyle.gripLength,
                   height: axis == .vertical ? ShellStyle.gripLength : ShellStyle.gripThickness)
            #else
            .fill(Theme.textMuted)
            .frame(width: axis == .vertical ? 4 : 44, height: axis == .vertical ? 44 : 4)
            #endif
    }
}

private struct HandleCursor: ViewModifier {
    let vertical: Bool
    let hold: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.hoverCursor(vertical ? .resizeLeftRight : .resizeUpDown, hold: hold)
        #else
        content
        #endif
    }
}

#if os(macOS)
/// 悬停换光标；离开 / 视图消失时配平 pop（照被删前 `ContentView` 分栏把手的范式：push 几次就 pop 几次）。
/// `hold` = 拖动中：指针拖出命中带也不换回去，松手（hold 变 false）且不在带上才 pop
struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    var hold = false
    @State private var pushed = false
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onHover { inside = $0; sync() }
            .onChange(of: hold) { _, _ in sync() }
            .onDisappear {
                if pushed { NSCursor.pop(); pushed = false }
            }
    }

    private func sync() {
        let want = inside || hold
        if want, !pushed { cursor.push(); pushed = true }
        if !want, pushed { NSCursor.pop(); pushed = false }
    }
}

extension View {
    func hoverCursor(_ cursor: NSCursor, hold: Bool = false) -> some View {
        modifier(HoverCursor(cursor: cursor, hold: hold))
    }
}
#endif
