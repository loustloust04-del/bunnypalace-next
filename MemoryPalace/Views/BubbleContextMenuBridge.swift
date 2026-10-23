import SwiftUI

// contextMenu × 反转列表（docs/plan-contextmenu-telegram-style.md）：
// iOS 不用系统 contextMenu（反转列表下 lift 快照颠倒，且系统 preview 不可交互——
// 不能滚动/选字，见 research doc 第三节判死）。改自定义浮层：长按由挂在反转列表
// UIScrollView 上的 UILongPressGestureRecognizer 识别，marker 登记命中区，命中后把
// "活副本 previewBuilder + 原位 frame + 菜单 spec"发给 BubbleMenuOverlayModel，
// CardFlowView 根部的 BubbleMenuOverlayView 弹 Telegram 式浮层（活渲染、可滚、可选字）。
// macOS 仍走 SwiftUI .contextMenu，菜单条目从同一份 spec 渲染。

// MARK: - 菜单动作模型（跨平台单一真相源）

struct MenuActionSpec {
    let title: String
    let systemImage: String
    var isDestructive: Bool = false
    var dividerAfter: Bool = false
    /// 有值 = iOS 浮层里进顶上那排图标（图标 + 棕灰英文小字，粟粟 10-01 定稿 B）；mac 菜单照旧按 title 一行一个
    var quickLabel: String? = nil
    /// 有值 = 二级菜单：iOS 浮层里点它在卡内原地换成这一页（带「返回」），mac 渲成子 Menu
    var children: [MenuActionSpec]? = nil
    let handler: () -> Void
}

extension MenuActionSpec {
    /// SwiftUI .contextMenu 渲染端（macOS 用）
    @ViewBuilder
    static func menuItems(from specs: [MenuActionSpec]) -> some View {
        ForEach(specs.indices, id: \.self) { i in
            if let children = specs[i].children {
                Menu(specs[i].title) {
                    ForEach(children.indices, id: \.self) { j in
                        Button(role: children[j].isDestructive ? .destructive : nil, action: children[j].handler) {
                            Label(children[j].title, systemImage: children[j].systemImage)
                        }
                    }
                }
            } else {
                Button(role: specs[i].isDestructive ? .destructive : nil, action: specs[i].handler) {
                    Label(specs[i].title, systemImage: specs[i].systemImage)
                }
            }
            if specs[i].dividerAfter {
                Divider()
            }
        }
    }
}

/// 气泡/block 级包装：iOS 登记 marker + 菜单期间隐藏原视图 + 活副本 previewBuilder
/// （content 渲两遍 = 列表里一遍、浮层里一遍，同一真实渲染路径，不写近似预览）。
/// macOS 原样透传（菜单走调用处的 .contextMenu），跨平台包裹不用 #if 劈表达式。
struct BubbleMenuLiftWrapper<Content: View>: View {
    let isUser: Bool
    let cornerRadius: CGFloat
    let tailBackdrop: Bool
    let actions: [MenuActionSpec]
    private let content: () -> Content
    private let previewContent: () -> AnyView
    @State private var lifted = false

    /// previewContent 不传 = 活副本原样渲 content；传了 = 浮层里渲变体
    /// （气泡模式 block 预览强制带尾巴用，列表原样不动）
    init(
        isUser: Bool,
        cornerRadius: Double,
        tailBackdrop: Bool = false,
        actions: [MenuActionSpec],
        @ViewBuilder content: @escaping () -> Content,
        previewContent: (() -> AnyView)? = nil
    ) {
        self.isUser = isUser
        self.cornerRadius = CGFloat(cornerRadius)
        self.tailBackdrop = tailBackdrop
        self.actions = actions
        self.content = content
        self.previewContent = previewContent ?? { AnyView(content()) }
    }

    var body: some View {
        #if os(iOS)
        content()
            .opacity(lifted ? 0 : 1)
            .background(BubbleMenuMarker(
                actions: actions,
                isUser: isUser,
                cornerRadius: cornerRadius,
                tailBackdrop: tailBackdrop,
                previewBuilder: previewContent,
                onMenuVisibleChanged: { lifted = $0 }
            ))
        #else
        content()
        #endif
    }
}

#if os(iOS)
import UIKit

// MARK: - 浮层会话模型

struct BubbleMenuSession {
    let preview: AnyView
    /// 触发时气泡在 window 坐标系的 frame（浮层侧用 WindowOriginReader 做 delta 校准，
    /// 别假设 SwiftUI .global == window——聊天页在分页器 child HC 里有偏移）
    let originFrameInWindow: CGRect
    /// 气泡圆角：预览白底卡和框内滚动裁剪贴合气泡圆度
    let cornerRadius: CGFloat
    /// 白底卡用带尾巴的气泡形状（气泡模式）——透明底气泡的尾巴靠白卡顶出来
    let tailBackdrop: Bool
    let specs: [MenuActionSpec]
    let isUser: Bool
    /// 这条消息的 id：有就在预览上方挂表情条（照群聊）
    var reactionTarget: ChatReactionTarget? = nil
    /// 菜单底部那行：时间 / token / 缓存命中（TASK page1-消息-20）
    var infoLine: String? = nil
    /// 恢复原气泡显示（浮层 dismiss 动画起始帧调用，像素重合防闪白）
    let onRestore: () -> Void
}

final class BubbleMenuOverlayModel: ObservableObject {
    @Published var session: BubbleMenuSession?
    /// 多选气泡期间不弹长按浮层（ChatSelectionLifecycle 写；只给 bridge 判断用，不发布）
    var selectionSuppressed = false
}

private struct BubbleMenuOverlayModelKey: EnvironmentKey {
    static let defaultValue: BubbleMenuOverlayModel? = nil
}

extension EnvironmentValues {
    var bubbleMenuOverlayModel: BubbleMenuOverlayModel? {
        get { self[BubbleMenuOverlayModelKey.self] }
        set { self[BubbleMenuOverlayModelKey.self] = newValue }
    }
}

// MARK: - marker：登记气泡命中区（isUserInteractionEnabled=false，不碰任何触摸）

final class BubbleMenuMarkerView: UIView {
    var actions: [MenuActionSpec] = []
    var isUser = false
    var cornerRadius: CGFloat = 12
    var tailBackdrop = false
    var previewBuilder: (() -> AnyView)?
    var onMenuVisibleChanged: ((Bool) -> Void)?
    var reactionTarget: ChatReactionTarget?
    weak var infoNode: MessageNode?
    weak var overlayModel: BubbleMenuOverlayModel?

    private weak var bridge: BubbleContextMenuBridge?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        bridge?.unregister(self)
        bridge = nil
        guard window != nil else { return }
        var node: UIView? = superview
        while let cur = node {
            if let scrollView = cur as? UIScrollView {
                let b = BubbleContextMenuBridge.install(on: scrollView)
                b.register(self)
                bridge = b
                break
            }
            node = cur.superview
        }
    }
}

struct BubbleMenuMarker: UIViewRepresentable {
    let actions: [MenuActionSpec]
    let isUser: Bool
    let cornerRadius: CGFloat
    var tailBackdrop = false
    let previewBuilder: () -> AnyView
    var onMenuVisibleChanged: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> BubbleMenuMarkerView {
        let v = BubbleMenuMarkerView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        apply(to: v, context: context)
        return v
    }

    func updateUIView(_ view: BubbleMenuMarkerView, context: Context) {
        apply(to: view, context: context)
    }

    private func apply(to view: BubbleMenuMarkerView, context: Context) {
        view.actions = actions
        view.isUser = isUser
        view.cornerRadius = cornerRadius
        view.tailBackdrop = tailBackdrop
        view.previewBuilder = previewBuilder
        view.onMenuVisibleChanged = onMenuVisibleChanged
        view.reactionTarget = context.environment.reactionTarget
        view.infoNode = context.environment.bubbleInfoNode
        view.overlayModel = context.environment.bubbleMenuOverlayModel
    }
}

// MARK: - bridge：per-scrollView 单例，长按按位置查 marker → 发浮层会话

final class BubbleContextMenuBridge: NSObject {
    private static var associatedKey: UInt8 = 0

    private let markers = NSHashTable<BubbleMenuMarkerView>.weakObjects()

    /// associated object 防重，per-scrollView 不是全局——切楼层 .id 重建出新
    /// scrollView 时，新树里的 marker 走 superview 链拿到新 bridge 自动重挂。
    static func install(on scrollView: UIScrollView) -> BubbleContextMenuBridge {
        if let existing = objc_getAssociatedObject(scrollView, &associatedKey) as? BubbleContextMenuBridge {
            return existing
        }
        let bridge = BubbleContextMenuBridge()
        let longPress = UILongPressGestureRecognizer(target: bridge, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        scrollView.addGestureRecognizer(longPress)
        objc_setAssociatedObject(scrollView, &associatedKey, bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return bridge
    }

    func register(_ marker: BubbleMenuMarkerView) { markers.add(marker) }
    func unregister(_ marker: BubbleMenuMarkerView) { markers.remove(marker) }

    private func marker(at location: CGPoint, in interactionView: UIView) -> BubbleMenuMarkerView? {
        for marker in markers.allObjects where marker.window != nil {
            if marker.convert(marker.bounds, to: interactionView).contains(location) {
                return marker
            }
        }
        return nil
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let view = gesture.view else { return }
        let location = gesture.location(in: view)
        guard let marker = marker(at: location, in: view),
              let window = marker.window,
              let model = marker.overlayModel, model.session == nil, !model.selectionSuppressed,
              let previewBuilder = marker.previewBuilder else { return }
        let frame = marker.convert(marker.bounds, to: window)
        guard frame.width > 1, frame.height > 1 else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        window.endEditing(true)
        marker.onMenuVisibleChanged?(true)
        let hide = marker.onMenuVisibleChanged
        model.session = BubbleMenuSession(
            preview: previewBuilder(),
            originFrameInWindow: frame,
            cornerRadius: marker.cornerRadius,
            tailBackdrop: marker.tailBackdrop,
            specs: marker.actions,
            isUser: marker.isUser,
            reactionTarget: marker.reactionTarget,
            infoLine: marker.infoNode.flatMap { ChatBubbleInfo.line(for: $0) },   // 长按那一刻现算，不随每次渲染格式化
            onRestore: { hide?(false) }
        )
        // window 层呈现：压住页级 chrome（顶部玻璃按钮），材质采样到真实内容层。
        // 手势回调必在主线程，assumeIsolated 只是给编译器背书
        MainActor.assumeIsolated {
            BubbleMenuOverlayPresenter.shared.present(model: model, in: window)
        }
    }
}
#endif
