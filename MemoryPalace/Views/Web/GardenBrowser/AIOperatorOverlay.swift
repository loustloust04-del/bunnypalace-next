#if os(iOS)
import SwiftUI

/// AI 在浏览器里动手时叠在网页上的一层（设计稿第 5 张；plan-ai-browser-operate §1.2）：
/// 整圈糊开的流光（不是一条光带，粟粟 11-10）、圆角「AI」箭头 + 波纹、输入框描边、顶上状态胶囊 +「我来接管」、写动作确认卡。
/// 碰网页 = 接管。
struct AIOperatorOverlay: View {
    let controller: MiniBrowserController
    @State private var op = BrowserOperator.shared
    @AppStorage(AIOperatorOverlay.cursorColorKey) private var cursorHex = ""

    static let cursorColorKey = "gardenBrowser.cursorColor"

    /// 箭头颜色：没自选 = 当前主题强调色（粟粟 11-11）
    static func cursorColor(_ hex: String) -> Color {
        guard let v = UInt(hex.dropFirst(), radix: 16), hex.hasPrefix("#") else { return Theme.branchIndicator }
        return Color(hex: v)
    }

    private var operating: Bool { op.isOperating(controller) }

    var body: some View {
        ZStack {
            if operating {
                // 碰网页 = 接管
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { op.takeOver() }
                    .ignoresSafeArea()
                EdgeGlow()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                if let rect = op.focusRect {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Self.cursorColor(cursorHex), lineWidth: 2.5)
                        .frame(width: rect.width + 8, height: rect.height + 8)
                        .position(x: rect.midX, y: rect.midY)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                if let point = op.cursor {
                    AICursor(color: Self.cursorColor(cursorHex), clicks: op.clickCount)
                        // 箭头尖在 60×60 框的左上角：框中心放在尖端右下 30
                        .position(x: point.x + 30, y: point.y + 30)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                VStack {
                    statusPill
                    Spacer()
                }
                .transition(.opacity)
            }
            if let confirm = op.confirm, op.controller === controller {
                confirmCard(confirm)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: operating)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: op.confirm?.id)
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.branchIndicator).frame(width: 8, height: 8)
            Text("AI 正在操作 · \(op.status)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            Button { op.takeOver() } label: {
                Text("我来接管")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Theme.mainBg))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .padding(.top, 8)
    }

    private func confirmCard(_ confirm: BrowserOperator.Confirm) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white)
                        .shadow(color: Theme.cardShadow, radius: Theme.cardShadowRadius, y: 1))
                Text(confirm.text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 8) {
                    Button { op.answer(.once) } label: {
                        Text("允许这一次")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.branchIndicator))
                    }
                    Button { op.answer(.conversation) } label: {
                        Text("这个对话里都允许")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.branchIndicator, lineWidth: 1))
                    }
                    Button { op.answer(.deny) } label: {
                        Text("不允许")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.mainBg)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }
}

/// 整圈糊开的柔光：两种灰调慢慢转（6 秒一圈）、轻轻呼吸（2.3 秒）。
/// 粟粟 11-11「颜色选太丑了不要这么多颜色，灰一点」：五色彩虹 → 灰薄荷 + 灰藕紫
private struct EdgeGlow: View {
    private static let colors: [Color] = [Color(hex: 0xA7B8AF), Color(hex: 0xB9B3C2), Color(hex: 0xA7B8AF)]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((t / 6).truncatingRemainder(dividingBy: 1) * 360)
            let breathe = 0.62 + 0.14 * sin(t * 2 * .pi / 2.3)
            let gradient = AngularGradient(colors: Self.colors, center: .center, angle: angle)
            ZStack {
                RoundedRectangle(cornerRadius: 54, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 22)
                    .blur(radius: 16)
                RoundedRectangle(cornerRadius: 54, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 5)
                    .blur(radius: 4)
            }
            .opacity(breathe)
        }
    }
}

/// 圆角胖箭头 + 白描边 + 同色「AI」小胶囊；每点一次放一圈波纹
private struct AICursor: View {
    let color: Color
    let clicks: Int
    @State private var ripple = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .strokeBorder(color, lineWidth: 2)
                .frame(width: 28, height: 28)
                .scaleEffect(ripple ? 1.8 : 0.4)
                .opacity(ripple ? 0 : 0.8)
                .offset(x: -14, y: -14)
            ArrowShape()
                .fill(color)
                .overlay(ArrowShape().stroke(Color.white, style: StrokeStyle(lineWidth: 2.6, lineJoin: .round)))
                .frame(width: 22, height: 26)
                .shadow(color: .black.opacity(0.22), radius: 4, y: 3)
            Text("AI")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(color))
                .overlay(Capsule().strokeBorder(Color.white, lineWidth: 2))
                .offset(x: 18, y: 22)
        }
        .frame(width: 60, height: 60, alignment: .topLeading)
        .onChange(of: clicks) { _, _ in
            ripple = false
            withAnimation(.easeOut(duration: 0.6)) { ripple = true }
        }
    }
}

/// 尖朝左上的圆角箭头（照设计稿那条路径）
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 20, sy = rect.height / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var path = Path()
        path.move(to: p(2.5, 1.5))
        path.addCurve(to: p(0.5, 3.4), control1: p(1.2, 0.6), control2: p(0.3, 1.8))
        path.addLine(to: p(2.6, 21.6))
        path.addCurve(to: p(5.8, 22.6), control1: p(2.8, 23.2), control2: p(4.7, 23.8))
        path.addLine(to: p(9.6, 18.3))
        path.addCurve(to: p(11, 17.7), control1: p(10, 17.9), control2: p(10.5, 17.7))
        path.addLine(to: p(17.4, 17.8))
        path.addCurve(to: p(18.6, 14.8), control1: p(19, 17.8), control2: p(19.8, 15.9))
        path.closeSubpath()
        return path
    }
}
#endif
