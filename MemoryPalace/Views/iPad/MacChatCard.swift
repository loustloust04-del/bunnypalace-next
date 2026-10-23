import SwiftUI

/// 正文此刻是不是装在「正文卡」里（mac 全屏模式）。
///
/// 卡自己已经画了底（还可能带壁纸），所以卡内那些**各自画 `Theme.mainBg` 的地方**
/// （聊天滚动区 / 输入条 / loading 态 / 编程会话详情）必须让开，否则就是盖在壁纸上的四块不透明补丁（R-FS S1.4）。
/// 默认 false ⇒ 浮窗模式、iOS、以及卡外的任何地方都保持原样。
private struct MacChatCardedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var macChatCarded: Bool {
        get { self[MacChatCardedKey.self] }
        set { self[MacChatCardedKey.self] = newValue }
    }
}

#if os(macOS)

/// 全屏（停靠）模式：正文 + 输入条装进**一张卡**，卡外留出桌布的边。
/// 她 09-16：「只有正文是卡」「输入框也归在正文卡里面」——输入条本来就在 `CardFlowView` 里，
/// 所以套在 `macChatContent` 外面它自动进卡，不用动聊天页的结构。
///
/// 壁纸也在卡里（她裁 R2=A：卡就是「对话」，壁纸是对话的皮肤），跟卡的圆角一起切——
/// 不 clip 的话壁纸会从四个切角漏到桌布上。
///
/// **浮窗模式一行不动**：走 else 支，还是原来那句「顶上给悬浮胶囊让 46pt」。
struct MacChatCard: ViewModifier {
    let layout: IPadPanelLayout
    let imageURL: URL?
    let scheme: ColorScheme
    var backgroundStyle: ThemeBackgroundStyle = ThemeBackgroundStyle()

    func body(content: Content) -> some View {
        // 在 body 里读才会跟着参数台即时重绘（MacShellMetrics 的纪律）
        let m = MacShellMetrics.shared
        // 窗口玻璃开：卡浮在玻璃上，至少一圈 1pt 边 + 一层阴影（照 Otty 的 container，plan-mac-glass-chrome §1.3）
        let glass = MacGlass.shared.enabled
        let border = glass ? max(m.cardBorder, 1) : m.cardBorder
        let shadow = glass ? max(m.cardShadow, 12) : m.cardShadow
        if layout.mode == .docked {
            let shape = RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
            GeometryReader { geometry in
            content
                .environment(\.macChatCarded, true)
                // Constrain the card before clipping. An oversized child's ideal
                // width must not move the rounded corners outside the assigned slot.
                .frame(width: max(0, geometry.size.width - 2 * m.cardGapX - 2 * m.cardPadX),
                       height: max(0, geometry.size.height - m.cardGapTop - m.cardGapBottom - 2 * m.cardPadY))
                .padding(.horizontal, m.cardPadX)
                .padding(.vertical, m.cardPadY)
                .background {
                    // fill 垫在壁纸下面：壁纸可能是半透明 PNG，没有这层会透出桌布
                    ThemeBackgroundView(fill: ShellStyle.card, imageURL: imageURL,
                                        scheme: scheme, backgroundStyle: backgroundStyle)
                }
                .clipShape(shape)
                .overlay {
                    if border > 0 {
                        shape.strokeBorder(ShellStyle.hairline, lineWidth: border)
                            .allowsHitTesting(false)
                    }
                }
                .shadow(color: ShellStyle.shadow, radius: shadow * 0.5, y: shadow * 0.25)
                .overlay {
                    // 留白可视化：参数台开着时才有，帮她看清各处留白（斜纹 = 桌布露出来的部分）
                    if m.showGuides {
                        shape.strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, m.cardGapX)
                // v2：标题行是 VStack 里真的一行，卡槽从它底下起——这里只留卡与标题行的缝，不再自己让 titleBarHeight
                .padding(.top, m.cardGapTop)
                .padding(.bottom, m.cardGapBottom)
                .background {
                    if m.showGuides { Color.mint.opacity(0.18) }
                }
            }
        } else {
            content
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 46) }
        }
    }
}

#endif
