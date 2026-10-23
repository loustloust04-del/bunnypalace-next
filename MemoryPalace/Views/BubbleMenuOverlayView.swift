#if os(iOS)
import SwiftUI
import UIKit

// Telegram 式长按浮层（docs/plan-contextmenu-telegram-style.md M2）：
// 活副本预览（可选字）+ 菜单卡片包同一个 ScrollView 一起滚；超长消息打开时先滚到底
// （气泡尾+菜单可见，Telegram 行为）；矮内容钉在原位（clamp 进安全边距，Stream 式）。
// 入场 Stream 级原位浮现（scale 0.96→1 spring），不做飞行状态机。

/// 浮层左上角在 window 坐标系的位置（delta 校准用）。
/// 聊天页在分页器 child HC 里，SwiftUI .global ≠ window 坐标，不能直接用 originFrameInWindow。
private struct WindowOriginReader: UIViewRepresentable {
    let onChange: (CGPoint) -> Void

    final class ProbeView: UIView {
        var onChange: ((CGPoint) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }
        private func report() {
            guard let window else { return }
            onChange?(convert(CGPoint.zero, to: window))
        }
    }

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.onChange = onChange
        return v
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }
}

/// 部分强度模糊（UIViewPropertyAnimator 暂停在 fractionComplete 的经典技巧）：
/// 系统 Material 模糊半径固定且带白化，压在暖奶白聊天页上直接糊成一块奶灰，
/// 外面的字全没了（粟粟真机反馈）。小强度真模糊 = 字影隐约可见的 Telegram 档。
private struct SoftBlurView: UIViewRepresentable {
    var intensity: CGFloat

    final class Coordinator {
        var animator: UIViewPropertyAnimator?
        deinit {
            animator?.stopAnimation(true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
            view.effect = UIBlurEffect(style: .regular)
        }
        animator.fractionComplete = intensity
        context.coordinator.animator = animator
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        context.coordinator.animator?.fractionComplete = intensity
    }
}

/// window 层浮层宿主：浮层必须压住页级 chrome（顶部玻璃按钮等在 chatHC 之外），
/// 且材质要采样到真实内容层（壁纸/背景沉在 UIKit 层，chatHC 内的 SwiftUI 材质
/// 采不到 → 奶糊一片、菜单玻璃失效——粟粟真机三连报的共同根因）。
@MainActor
final class BubbleMenuOverlayPresenter {
    static let shared = BubbleMenuOverlayPresenter()
    private var host: UIHostingController<BubbleMenuOverlayView>?

    func present(model: BubbleMenuOverlayModel, in window: UIWindow) {
        guard host == nil else { return }
        let hc = UIHostingController(rootView: BubbleMenuOverlayView(model: model))
        hc.view.backgroundColor = .clear
        hc.view.clipsToBounds = true
        hc.view.frame = window.bounds
        hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(hc.view)
        host = hc
    }

    func dismissHost() {
        host?.view.removeFromSuperview()
        host = nil
    }
}

/// 裁剪区按方向外扩的矩形：水平/垂直各自留 bleed，让画在 frame 外的气泡尾巴不被剃
private struct BleedRect: Shape {
    var horizontal: CGFloat
    var vertical: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX - horizontal,
            y: rect.minY - vertical,
            width: rect.width + horizontal * 2,
            height: rect.height + vertical * 2
        ))
    }
}

/// 菜单行的按压态：按住时浅色胶囊高亮，左右离卡边留一截（iOS 26 原生菜单同款，粟粟 10-11）
private struct MenuRowButtonStyle: ButtonStyle {
    var insetH: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0))
                    .padding(.horizontal, insetH)
            )
    }
}

struct BubbleMenuOverlayView: View {
    @ObservedObject var model: BubbleMenuOverlayModel

    var body: some View {
        if let session = model.session {
            BubbleMenuOverlayContent(session: session, model: model)
                .ignoresSafeArea()
        }
    }
}


private struct BubbleMenuOverlayContent: View {
    let session: BubbleMenuSession
    let model: BubbleMenuOverlayModel

    @State private var appeared = false
    @State private var dismissing = false
    @State private var windowOrigin: CGPoint = .zero
    /// 活副本的自然高度（框内实测）
    @State private var previewNaturalHeight: CGFloat = 0
    /// 预览框下面还有没露出来的内容（框内滚动时底边渐隐用）
    @State private var previewMoreBelow = true
    /// 二级菜单：点带 children 的行，卡内原地换成这一页（顶上「返回」）
    @State private var submenu: MenuActionSpec?

    private let edgeMargin: CGFloat = 16
    private let topMargin: CGFloat = 70      // 状态栏下缘呼吸位
    private let bottomMargin: CGFloat = 44   // home indicator 带上缘
    private let columnSpacing: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let origin = CGRect(
                x: session.originFrameInWindow.minX - windowOrigin.x,
                y: session.originFrameInWindow.minY - windowOrigin.y,
                width: session.originFrameInWindow.width,
                height: session.originFrameInWindow.height
            )

            ZStack(alignment: .topLeading) {
                // 轻量真模糊 + 轻压暗：外面的字影隐约可见（Telegram 感），别糊死
                SoftBlurView(intensity: 0.35)
                    .overlay(Color.black.opacity(0.12))
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .opacity(appeared ? 1 : 0)

                column(origin: origin, in: geo)
                    .padding(.top, clampedTop(origin: origin, in: geo))
            }
            .background(WindowOriginReader { windowOrigin = $0 })
        }
    }

    // MARK: - 内容列（预览框 + 原生菜单锚点；长内容在框内滚，菜单永远完整可见）

    /// 图标排（有英文小字的项）/ 文字行（其余）——粟粟 10-01 定稿 B
    private var quickSpecs: [MenuActionSpec] { submenu == nil ? session.specs.filter { $0.quickLabel != nil } : [] }
    private var rowSpecs: [MenuActionSpec] { submenu?.children ?? session.specs.filter { $0.quickLabel == nil } }
    private var infoLine: String? { submenu == nil ? session.infoLine : nil }

    /// 菜单高度确定性推算（不实测）：图标排 56 + 分隔（10+线+10 ≈ 21）+ 行高 40 × 行数 + 卡上下 padding 12
    private var estimatedMenuHeight: CGFloat {
        let quick: CGFloat = quickSpecs.isEmpty ? 0 : 56 + (rowSpecs.isEmpty ? 0 : 21)
        let info: CGFloat = infoLine.map { 21 + CGFloat($0.split(separator: "\n").count) * 15 + 8 } ?? 0
        let back: CGFloat = submenu == nil ? 0 : 40
        return quick + back + CGFloat(rowSpecs.count) * 40 + 12 + info
    }

    /// 表情条（照群聊：56 高的玻璃胶囊）+ 它和预览之间的间距；没有回应目标就是 0
    private static let emojiBarHeight: CGFloat = 56
    private var emojiBarSpace: CGFloat { session.reactionTarget == nil ? 0 : Self.emojiBarHeight + columnSpacing }

    /// 预览框最大高度 = 屏幕可用区扣掉表情条、菜单和边距，短消息卡片式钉原位的体量
    private func maxPreviewHeight(in geo: GeometryProxy) -> CGFloat {
        max(geo.size.height - topMargin - bottomMargin - emojiBarSpace - estimatedMenuHeight - columnSpacing, 120)
    }

    private func displayedColumnHeight(in geo: GeometryProxy) -> CGFloat {
        emojiBarSpace + min(previewNaturalHeight, maxPreviewHeight(in: geo)) + columnSpacing + estimatedMenuHeight
    }

    private func column(origin: CGRect, in geo: GeometryProxy) -> some View {
        let leading = session.isUser ? edgeMargin : max(origin.minX, edgeMargin)
        let trailing = session.isUser ? max(geo.size.width - origin.maxX, edgeMargin) : edgeMargin
        return VStack(alignment: session.isUser ? .trailing : .leading, spacing: columnSpacing) {
            if let target = session.reactionTarget {
                // 条宽按列真实可用宽：列左缘跟着气泡（气泡模式带头像时 minX≈56），按屏宽减两边距会顶出右边
                emojiBar(target: target, maxWidth: geo.size.width - leading - trailing)
                    .scaleEffect(appeared ? 1 : 0.4, anchor: UnitPoint(x: session.isUser ? 0.85 : 0.15, y: 1))
            }
            previewBox(origin: origin, in: geo)
            // 自绘菜单按原生 UIMenu 规格逐项对齐（Telegram 路线：菜单归自己管才能和
            // 预览滚动/选字共存不打架——真原生 UIMenu 的"碰外面就收"没有开关，已实测判死）
            menuCard
                .scaleEffect(
                    appeared ? 1 : 0.4,
                    anchor: UnitPoint(x: session.isUser ? 0.85 : 0.15, y: 0)
                )
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(maxWidth: .infinity, alignment: session.isUser ? .trailing : .leading)
        .scaleEffect(appeared ? 1 : 0.96, anchor: session.isUser ? .topTrailing : .topLeading)
        .opacity(appeared ? 1 : 0)
    }

    /// 预览框：永远同一个 ScrollView 容器只变 frame 高度——fork MarkdownView 异步 parse，
    /// 若按高度切换 if/else 分支会换视图 identity → MarkdownView 重建回空壳 → 高度测量
    /// 50↔727 无限振荡（探针实录）。identity 稳定后：短内容框高=自然高（不滚），
    /// 长内容框高=上限，小滚动条在框内（粟粟原始需求：框里滚，不是整列滚）。
    private func previewBox(origin: CGRect, in geo: GeometryProxy) -> some View {
        let maxH = maxPreviewHeight(in: geo)
        let scrolls = previewNaturalHeight > maxH
        let boxHeight: CGFloat? = previewNaturalHeight > 0 ? min(previewNaturalHeight, maxH) : nil
        return ScrollView(.vertical, showsIndicators: true) {
            session.preview
                // 聚焦态才合并段落簇（跨段选择）；列表里一段一个视图（粟粟 10-03：Air 合并就卡）
                .environment(\.chatMergesTextRuns, true)
                .frame(width: origin.width)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    previewNaturalHeight = newHeight
                    if !appeared && !dismissing {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { appeared = true }
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height < geo.contentSize.height - 1
        } action: { _, moreBelow in
            previewMoreBelow = moreBelow
        }
        .frame(width: origin.width)
        .frame(height: boxHeight)
        // 无条件白底卡：AI 气泡透明底时活副本是裸文字，会和背景融掉（粟粟点名元凶）；
        // 气泡自身颜色照常渲染在白卡上。气泡模式白卡用带尾巴的气泡形状——
        // 透明底气泡的尾巴靠白卡顶出来（粟粟：透明气泡没有尾巴）
        .background(backdropShape.fill(Color.white))
        // 截断处底边渐隐成白卡（卡永远是白的，盖白渐变 = 正文淡出）；往下多盖一截尾巴区，
        // 滚到中段时尾巴那块不露半截字。滚到底才撤，尾巴和最后一行完整露出
        .overlay(alignment: .bottom) {
            LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                   .init(color: .white, location: Self.previewFade / (Self.previewFade + tailBleed)),
                                   .init(color: .white, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.previewFade + tailBleed)
                .offset(y: tailBleed)
                .opacity(scrolls && previewMoreBelow ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: previewMoreBelow)
                .allowsHitTesting(false)
        }
        // Telegram 从不裁尾巴（粟粟基准）：尾巴画在气泡 frame 外，任何按边界的裁剪都会剃掉它。
        // 不滚动 = 四向全放开（等于不裁）；滚动 = 严格裁进白卡形状（气泡模式的带尾形状本身含尾巴）——
        // 之前滚动时只裁矩形上下沿还给底部留 6pt，长消息截断处半行字漏出卡底、圆角外也露字（粟粟 10-02 截图）
        .scrollClipDisabled()
        .clipShape(scrolls ? AnyShape(backdropShape) : AnyShape(BleedRect(horizontal: 80, vertical: 80)))
        // clipShape 只裁画面不裁命中：scrollClipDisabled 下框外的正文仍吃触摸，收回卡形
        .contentShape(backdropShape)
        // 投影立起来：气泡底色和暖奶白背景太接近，不分层就融成一片（粟粟真机反馈）
        .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
    }

    /// 截断处渐隐高度
    private static let previewFade: CGFloat = 28
    /// 带尾形状在 frame 下方探出的深度（BubbleTailShape 尾巴最低点 ≈ maxY + 0.39r）；文章模式无尾 = 0
    private var tailBleed: CGFloat { session.tailBackdrop ? session.cornerRadius * 0.4 : 0 }

    /// 白底卡形状：气泡模式带尾巴（BubbleTailShape），文章模式圆角矩形
    private var backdropShape: AnyShape {
        if session.tailBackdrop {
            AnyShape(BubbleTailShape(isUser: session.isUser, radius: session.cornerRadius, hasTail: true))
        } else {
            AnyShape(RoundedRectangle(cornerRadius: session.cornerRadius, style: .continuous))
        }
    }

    /// 预览钉在原位 y（表情条在它上面），clamp 进 [topMargin, 底边距] 区间，表情条和菜单始终完整在屏内
    private func clampedTop(origin: CGRect, in geo: GeometryProxy) -> CGFloat {
        let maxTop = geo.size.height - bottomMargin - displayedColumnHeight(in: geo)
        return min(max(origin.minY - emojiBarSpace, topMargin), max(maxTop, topMargin))
    }

    // MARK: - 表情条（照抄群聊 GroupMessageActionOverlay：玻璃胶囊、44 的圆钮、28 号表情、横滑、已点的有底色）

    private func emojiBar(target: ChatReactionTarget, maxWidth: CGFloat) -> some View {
        let selected = Set(ChatReactionStore.shared.reactions(for: target.nodeId))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(ChatReactionStore.emojis, id: \.self) { emoji in
                    Button {
                        tapped { ChatReactionStore.shared.toggle(emoji, on: target) }
                    } label: {
                        Image(systemName: ChatReactionIcon.symbol(for: emoji))
                            .font(.system(size: 23))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(selected.contains(emoji) ? Theme.textPrimary.opacity(0.1) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ChatReactionIcon.title(for: emoji))
                    .accessibilityAddTraits(selected.contains(emoji) ? .isSelected : [])
                }
            }
            .padding(6)
        }
        // 横滑内容按附件条同款两端淡出、再裁进胶囊——之前没裁，最右那颗半截表情画在胶囊圆头外
        .horizontalScrollEdgeFade()
        .frame(width: min(maxWidth, CGFloat(ChatReactionStore.emojis.count) * 46 + 10), height: Self.emojiBarHeight)
        .clipShape(Capsule())
        .glassEffect(.regular, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 28, y: 10)
    }

    // MARK: - 菜单（自绘，按原生 UIMenu 规格：宽 250 / 行高 44 / 字号 17 / 边距 16 /
    // 发丝行分隔 / 8pt 组间带 / 圆角 13 连续曲率 / 按压高亮 / Liquid Glass）

    private var menuCard: some View {
        VStack(spacing: 0) {
            if !quickSpecs.isEmpty {
                HStack(spacing: 0) {
                    ForEach(quickSpecs.indices, id: \.self) { i in
                        quickButton(quickSpecs[i])
                    }
                }
                .padding(.horizontal, 8)
                if !rowSpecs.isEmpty {
                    Divider()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
            }
            if let submenu {
                backRow(submenu.title)
            }
            ForEach(rowSpecs.indices, id: \.self) { i in
                menuRow(rowSpecs[i])
            }
            // 底部那行：时间 / token / 缓存命中（TASK page1-消息-20，粟粟选 ①：菜单里同款棕灰小字）
            if let info = infoLine {
                Divider()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                Text(info)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineSpacing(2)
                    .foregroundStyle(Self.quickLabelColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .accessibilityLabel(info.replacingOccurrences(of: "\n", with: "，"))
            }
        }
        .padding(.vertical, 6)
        .frame(width: 235)
        // Liquid Glass 加在卡容器上——glassEffect 直接套 Button 会吞 hit test
        // （feedback_ios26_glass_button），行按钮用自定义 style 坐玻璃卡上
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 28, y: 10)
    }

    /// 图标排的一格：图标 + 棕灰英文小字（删除整格红）
    private func quickButton(_ spec: MenuActionSpec) -> some View {
        Button {
            tapped(then: spec.handler)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: spec.systemImage)
                    .font(.system(size: 18))
                    .frame(height: 22)
                    .foregroundStyle(spec.isDestructive ? Color.red : Theme.textPrimary)
                Text(spec.quickLabel ?? spec.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(spec.isDestructive ? Color.red : Self.quickLabelColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle(insetH: 2))
        .accessibilityLabel(spec.title)
    }

    /// 棕灰（粟粟 10-01）：亮暗玻璃上都读得出
    private static let quickLabelColor = Color(red: 0.55, green: 0.48, blue: 0.41)

    private func menuRow(_ spec: MenuActionSpec) -> some View {
        Button {
            if spec.children != nil {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) { submenu = spec }
            } else {
                tapped(then: spec.handler)
            }
        } label: {
            HStack(spacing: 14) {
                // iOS 26 原生菜单图标在前（粟粟并排图基准），固定槽宽让文字列对齐
                Image(systemName: spec.systemImage)
                    .font(.system(size: 15))
                    .frame(width: 24)
                Text(spec.title)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if spec.children != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Self.quickLabelColor)
                }
            }
            .foregroundStyle(spec.isDestructive ? Color.red : Theme.textPrimary)
            .padding(.leading, 24)
            .padding(.trailing, 20)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    /// 二级页顶上那行：‹ 父项标题，点回一级
    private func backRow(_ title: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) { submenu = nil }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, 24)
            .padding(.trailing, 20)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: - dismiss

    /// 点菜单项 / 表情：先轻震（同群聊表情条、气泡下操作行的 .light）再收浮层；点背景收起不震
    private func tapped(then handler: @escaping () -> Void) {
        guard !dismissing else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss(then: handler)
    }

    private func dismiss(then handler: (() -> Void)? = nil) {
        guard !dismissing else { return }
        dismissing = true
        // 动画起始帧即恢复原气泡：浮层预览与原位像素重合，无闪白空窗
        session.onRestore()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
            appeared = false
        } completion: {
            model.session = nil
            BubbleMenuOverlayPresenter.shared.dismissHost()
            handler?()
        }
    }
}
#endif
