import SwiftUI

/// 多选气泡的列表侧（research-multi-select-bubbles §1.3 / §6 / §7.1）。
/// 行修饰只读 `isActive`；选中与否只有 `ChatSelectionMark` / `ChatSelectionBand` 两个叶子读——点一下只重算可见的小圆和底色。
enum ChatSelectionStyle {
    static let markSize: CGFloat = 20

    /// 勾选圆左缘（行坐标；行本身离屏幕边 listInsetH）：iOS 落在屏幕 x 6，mac 同理落在列表左内距里
    static func markLeading(_ m: ChatMetrics) -> CGFloat { 6 - m.listInsetH }
    /// 气泡模式 AI 行整体右移让出勾选列（只平移不重排：吃进右侧 Spacer(minLength: 40)）
    static func aiShift(_ m: ChatMetrics) -> CGFloat { markLeading(m) + markSize + 14 }
    /// 文章模式你的消息卡左边让位（只有铺满整宽的长卡会真的重排）
    static func userCardInset(_ m: ChatMetrics) -> CGFloat { markLeading(m) + markSize + 8 }

    static func paper(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0x1a / 255, green: 0x1c / 255, blue: 0x19 / 255) : .white
    }
    static func ring(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 238 / 255, green: 231 / 255, blue: 223 / 255).opacity(0.30)
                   : Color(red: 61 / 255, green: 54 / 255, blue: 51 / 255).opacity(0.28)
    }
    static func band(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 196 / 255, green: 173 / 255, blue: 149 / 255).opacity(0.12)
                   : Color(red: 140 / 255, green: 122 / 255, blue: 105 / 255).opacity(0.10)
    }
}

/// 列表每行挂一个：多选态下内容让位（勾选列 / 长卡让位）、内容不接点击（划词 / 链接 / 网页卡 / 分支切换都让位），
/// 整行（含行间空隙、左右内距）点一下切换选中。mac 非多选态 ⌘ 点直接进多选
struct ChatSelectionRow: ViewModifier {
    let selection: ChatSelectionModel
    let nodeId: String
    let isUser: Bool
    let bubbleMode: Bool
    /// 流式中的那条不可选（内容还在变）
    let selectable: Bool
    let rowSpacing: CGFloat
    let onTap: () -> Void
    var onCommandTap: (() -> Void)? = nil
    @Environment(\.chatMetrics) private var metrics

    func body(content: Content) -> some View {
        let active = selection.isActive
        // 文章模式 AI 正文可能很长：勾选圆贴第一行；其余贴行中线
        let markTop = !bubbleMode && !isUser
        content
            #if os(macOS)
            .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                if !selection.isActive { onCommandTap?() }
            })
            #endif
            .padding(.leading, active && isUser && !bubbleMode ? ChatSelectionStyle.userCardInset(metrics) : 0)
            .offset(x: active && !isUser && bubbleMode ? ChatSelectionStyle.aiShift(metrics) : 0)
            .allowsHitTesting(!active)
            .background {
                if active {
                    ChatSelectionBand(selection: selection, nodeId: nodeId)
                        .padding(.horizontal, -metrics.listInsetH)
                        .padding(.vertical, -rowSpacing / 2)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: markTop ? .topLeading : .leading) {
                if active {
                    ChatSelectionMark(selection: selection, nodeId: nodeId, enabled: selectable)
                        .padding(.top, markTop ? 8 : 0)
                        .offset(x: ChatSelectionStyle.markLeading(metrics))
                        .transition(.opacity.combined(with: .offset(x: -26)))
                }
            }
            .overlay {
                if active {
                    Color.clear
                        .contentShape(Rectangle())
                        .padding(.horizontal, -metrics.listInsetH)
                        .padding(.vertical, -rowSpacing / 2)
                        .onTapGesture { if selectable { onTap() } }
                }
            }
    }
}

/// 勾选小圆（叶子）：未选 = 白底浅灰描边，已选 = 薄荷实心白勾，不可选 = 淡掉。不用玻璃（几十个玻璃圆滚动太贵）
struct ChatSelectionMark: View {
    let selection: ChatSelectionModel
    let nodeId: String
    let enabled: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let on = selection.selected.contains(nodeId)
        ZStack {
            // 已选 = 醒目薄荷（Theme.branchIndicator #8EBD9F；Theme.accent 是浅底色不是强调色）
            Circle().fill(on ? Theme.branchIndicator : ChatSelectionStyle.paper(scheme))
            Circle().strokeBorder(on ? Theme.branchIndicator : ChatSelectionStyle.ring(scheme), lineWidth: 1.5)
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: ChatSelectionStyle.markSize, height: ChatSelectionStyle.markSize)
        .shadow(color: Color(red: 61 / 255, green: 54 / 255, blue: 51 / 255).opacity(0.10), radius: 1, y: 1)
        .opacity(enabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.15), value: on)
        .allowsHitTesting(false)
    }
}

/// 选中行的整行暖色底（叶子）：相邻选中行连成一片
struct ChatSelectionBand: View {
    let selection: ChatSelectionModel
    let nodeId: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let on = selection.selected.contains(nodeId)
        Rectangle()
            .fill(ChatSelectionStyle.band(scheme))
            .opacity(on ? 1 : 0)
            .animation(.easeOut(duration: 0.18), value: on)
            .allowsHitTesting(false)
    }
}

/// 挂在 CardFlowView 正文上一处：路径变了过滤选中集合；进 / 出多选时锁翻页、关长按浮层（iOS）；正文退场就退出多选
struct ChatSelectionLifecycle: ViewModifier {
    let viewModel: ConversationViewModel
    #if os(iOS)
    let menuModel: BubbleMenuOverlayModel
    #endif

    func body(content: Content) -> some View {
        let selection = viewModel.messageSelection
        let active = selection.isActive
        content
            // 只在多选态才读路径（平时不订阅、不算 id 数组）
            .onChange(of: active ? viewModel.currentPath.map(\.id) : []) { _, ids in
                selection.prune(toIds: ids)
            }
            .onChange(of: active, initial: true) { _, on in apply(on) }
            .onDisappear {
                selection.end()
                apply(false)
            }
    }

    private func apply(_ on: Bool) {
        #if os(iOS)
        menuModel.selectionSuppressed = on
        // 翻页锁复用 owner 集合（不改 ContentView 传给翻页容器的 disableScroll）
        if let scrollView = PagingViewController.sharedScrollView {
            PagingViewController.setPage2DragLocked(on, owner: viewModel.messageSelection.pagingLockOwner, scrollView: scrollView)
        }
        #endif
    }
}
