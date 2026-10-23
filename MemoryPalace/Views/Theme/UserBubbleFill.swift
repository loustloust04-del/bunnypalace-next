import SwiftUI

/// 你的气泡底（plan-bubble-gradient，粟粟拍板 A）：没设第二色 = `shape.fill(base)` 一模一样；
/// 设了 = 「base → gradient」自上而下、**锚在容器上**的渐变——整屏一条渐变，泡是开在上面的窗口（TG / Ins 式），
/// 滚动时同一条消息的颜色跟着它在屏幕上的位置走，短泡只露一小段。
///
/// 做法：`visualEffect` 在渲染期拿泡在锚定坐标系里的 frame（不触发布局，也不走 LazyVStack 里那些不可靠的几何 API），
/// 把泡那么大的渐变沿 y 拉成容器那么高、再反向偏移到容器顶，最后裁成泡形。
/// 容器高度：`proxy.bounds(of: .scrollView)` 在 visualEffect 里拿不到（实测 nil，09-16 探针），
/// 聊天列表由 `CardFlowView` 量好视口高放进 `chatViewportHeight` environment；预览用 `.named` 坐标系。
/// 都拿不到（iOS 长按浮层里的气泡副本这种脱离列表的宿主）就退成每泡各画一条。
struct UserBubbleFill<S: Shape>: View {
    enum Anchor {
        /// 聊天列表：最近的 ScrollView 视口 + `chatViewportHeight`。`flipped` = 反转列表（`flippedUpsideDown`：布局坐标顶 = 视觉底）要镜像
        case scrollView(flipped: Bool)
        /// 主题预览这类不滚动的容器：按 `.coordinateSpace(name:)` 锚
        case named(String)
    }

    @Environment(\.chatViewportHeight) private var chatViewportHeight
    let shape: S
    let base: Color
    var gradient: Color? = nil
    var anchor: Anchor = .scrollView(flipped: false)

    var body: some View {
        if let gradient {
            let anchor = anchor
            let viewportHeight = chatViewportHeight
            LinearGradient(colors: [base, gradient], startPoint: .top, endPoint: .bottom)
                .visualEffect { content, proxy in
                    let p = Self.placement(proxy: proxy, anchor: anchor, viewportHeight: viewportHeight)
                    return content
                        .scaleEffect(x: 1, y: p.scaleY, anchor: .top)
                        .offset(y: p.offsetY)
                }
                .clipShape(shape)
                // clipShape 只裁画面不裁命中：放大到整屏高的渐变层会给每个泡拖一块整屏高的隐形命中区，
                // 反转列表里盖住视觉下方消息的纯 SwiftUI 元素（思考行）。命中收回泡形，与单色分支一致。
                .contentShape(shape)
        } else {
            shape.fill(base)
        }
    }

    /// 渐变沿 y 拉多少（容器高 / 泡高）、往上挪多少（泡在容器里的视觉顶取负）。锚不到就 (1, 0) = 每泡独立。
    nonisolated private static func placement(
        proxy: GeometryProxy,
        anchor: Anchor,
        viewportHeight: CGFloat?
    ) -> (scaleY: CGFloat, offsetY: CGFloat) {
        let containerHeight: CGFloat
        let visualTop: CGFloat
        switch anchor {
        case .scrollView(let flipped):
            guard let height = viewportHeight, height > 0 else { return (1, 0) }
            let frame = proxy.frame(in: .scrollView)
            containerHeight = height
            // 反转列表：cell 翻回正后局部 y 仍是屏幕向下，但 cell 的屏幕顶 = 视口高 − 布局 maxY
            visualTop = flipped ? (height - frame.maxY) : frame.minY
        case .named(let name):
            // bounds(of:) 回来的 rect 是「那个坐标系换算到本视图局部」（origin 为负 = 容器顶在我上方），只取 height；
            // 泡在容器里的顶用 frame(in:)（09-16 探针：bounds=(-13.7,-4,64,38) frame=(13.7,4,…)）
            guard let b = proxy.bounds(of: .named(name)) else { return (1, 0) }
            containerHeight = b.height
            visualTop = proxy.frame(in: .named(name)).minY
        }
        return (containerHeight / max(proxy.size.height, 1), -visualTop)
    }
}

/// 聊天列表视口高（`CardFlowView` 量 ScrollView 自己的尺寸后写入），气泡渐变按它铺整屏。nil = 不在聊天列表里。
private struct ChatViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var chatViewportHeight: CGFloat? {
        get { self[ChatViewportHeightKey.self] }
        set { self[ChatViewportHeightKey.self] = newValue }
    }
}
