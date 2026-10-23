#if os(iOS)
import SwiftUI

// MARK: - 花园 lite/pro 开关（完全复刻 prototypes/toggle-spike/lite-pro-toggle.html）
// lite=发芽（米轨道+土里嫩芽），pro=开花（薄荷轨道+草+小花+蝴蝶，钮里开花）。
// 轨道 72×36，白钮 Ø30 滑 3→39，全部按 HTML 原值。

private extension Color {
    init(gardenHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// CSS 曲线对照
private let gardenEaseStd = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.5)       // 轨道/地面
private let gardenEaseThumb = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.4)     // 白钮滑动
private let gardenSpringy = Animation.timingCurve(0.34, 1.3, 0.64, 1, duration: 0.4)  // 带回弹（植物/花，过冲比 HTML 的 1.56 收小一点）
private let gardenSpringyFast = Animation.timingCurve(0.34, 1.3, 0.64, 1, duration: 0.3)

struct GardenModeToggle: View {
    @Binding var isPro: Bool
    /// 蝴蝶 flutter 的时钟：Timer 驱动（TimelineView 在 toolbar 里不tick，布尔翻转的 repeatForever 又会被隐式动画打断）
    @State private var flutterTime: TimeInterval = 0
    private let flutterTimer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    @Environment(\.colorScheme) private var colorScheme

    private var trackLite: Color { colorScheme == .dark ? Color(gardenHex: 0x3D3633) : Color(gardenHex: 0xE8E0D4) }
    private var trackPro: Color { colorScheme == .dark ? Color(gardenHex: 0x5A7D65) : Color(gardenHex: 0x8EBD9F) }
    private let soil = Color(gardenHex: 0xC4A882)
    private let soilPro = Color(gardenHex: 0x6B8F6B)
    private let sprout = Color(gardenHex: 0x7DB87D)
    private let sproutLight = Color(gardenHex: 0xA8D5A0)
    private let leaf = Color(gardenHex: 0x5A9E5A)
    private let flowerCenter = Color(gardenHex: 0xF5D76E)
    private let flowerPetal = Color(gardenHex: 0xE8A4B8)
    private let flowerPetalAlt = Color(gardenHex: 0xB8D4E8)
    private let butterflyBody = Color(gardenHex: 0x8B6F47)

    var body: some View {
        toggleArtwork(flutter: flutterPose(at: flutterTime))
            .onReceive(flutterTimer) { _ in
                if isPro { flutterTime += 1.0 / 30 }
            }
    }

    /// HTML @keyframes flutter：3s ease-in-out 无限循环
    /// 0% (0,0,0°) → 25% (2,-3,5°) → 50% (-1,-1,-3°) → 75% (3,-4,2°) → 100% (0,0,0°)
    private func flutterPose(at time: TimeInterval) -> (x: CGFloat, y: CGFloat, deg: Double) {
        let keys: [(p: Double, x: CGFloat, y: CGFloat, deg: Double)] = [
            (0.00, 0, 0, 0), (0.25, 2, -3, 5), (0.50, -1, -1, -3), (0.75, 3, -4, 2), (1.00, 0, 0, 0)
        ]
        let phase = time.truncatingRemainder(dividingBy: 3) / 3
        var i = 0
        while i < keys.count - 2 && phase > keys[i + 1].p { i += 1 }
        let a = keys[i], b = keys[i + 1]
        var s = (phase - a.p) / (b.p - a.p)
        s = s * s * (3 - 2 * s)  // ease-in-out
        return (
            a.x + (b.x - a.x) * CGFloat(s),
            a.y + (b.y - a.y) * CGFloat(s),
            a.deg + (b.deg - a.deg) * s
        )
    }

    private func toggleArtwork(flutter pose: (x: CGFloat, y: CGFloat, deg: Double)) -> some View {
        ZStack(alignment: .leading) {
            // ── 轨道 + 场景（胶囊裁剪；白钮在裁剪层外，投影不被切）
            ZStack {
                Capsule().fill(isPro ? trackPro : trackLite)
                    .animation(gardenEaseStd, value: isPro)

                // 地面土壤条
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(isPro ? soilPro : soil)
                        .frame(height: isPro ? 8 : 10)
                        .animation(gardenEaseStd, value: isPro)
                }

                grassCluster(blades: [(5, -15), (7, 5), (4, -8)], left: 6)
                grassCluster(blades: [(5, -15), (7, 5)], left: 48)

                miniFlower(petal: flowerPetal, petalD: 5, stemLen: 5, boxH: 8)
                    .position(x: 11, y: 22)
                    .scaleEffect(isPro ? 1 : 0)
                    .opacity(isPro ? 1 : 0)
                    .animation(gardenSpringy.delay(0.3), value: isPro)
                miniFlower(petal: flowerPetalAlt, petalD: 4, stemLen: 4, boxH: 7)
                    .position(x: 59, y: 20.5)
                    .scaleEffect(isPro ? 1 : 0)
                    .opacity(isPro ? 1 : 0)
                    .animation(gardenSpringy.delay(0.3), value: isPro)

                butterfly
                    .position(x: 20, y: 9)
                    .offset(x: pose.x, y: pose.y)
                    .rotationEffect(.degrees(pose.deg))
                    .opacity(isPro ? 1 : 0)
                    .animation(gardenEaseStd.delay(0.4), value: isPro)
            }
            .frame(width: 72, height: 36)
            .clipShape(Capsule())

            // ── 白钮（里面的植物：lite 嫩芽 → pro 开花）
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .overlay { thumbPlant }
                .frame(width: 30, height: 30)
                .offset(x: isPro ? 39 : 3)
                .animation(gardenEaseThumb, value: isPro)
        }
        .frame(width: 72, height: 36)
        .contentShape(Capsule())
        // 包一层 Button 而不是裸 onTapGesture：toolbar 里 SwiftUI 手势会被导航栏吞掉
        .overlay {
            Button(action: { isPro.toggle() }) {
                Color.clear.contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPro ? "Pro 模式" : "Lite 模式")
        }
    }

    // MARK: 场景小件

    private func grassCluster(blades: [(h: CGFloat, rot: Double)], left: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(blades.enumerated()), id: \.offset) { _, blade in
                UnevenRoundedRectangle(topLeadingRadius: 1, topTrailingRadius: 1)
                    .fill(sprout)
                    .frame(width: 2, height: blade.h)
                    .rotationEffect(.degrees(blade.rot), anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, left)
        .offset(y: isPro ? -9 : -8)
        .opacity(isPro ? 1 : 0)
        .animation(gardenSpringyFast.delay(0.2), value: isPro)
    }

    private func miniFlower(petal: Color, petalD: CGFloat, stemLen: CGFloat, boxH: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(leaf).frame(width: 1, height: stemLen)
                .position(x: 3, y: boxH - stemLen / 2)
            Circle().fill(petal).frame(width: petalD, height: petalD)
                .position(x: 3, y: 2.5)
            Circle().fill(flowerCenter).frame(width: petalD * 0.4, height: petalD * 0.4)
                .position(x: 3, y: 2.5)
        }
        .frame(width: 6, height: boxH)
    }

    private var butterfly: some View {
        ZStack {
            Ellipse().fill(flowerPetal.opacity(0.7)).frame(width: 4, height: 5)
                .position(x: 2, y: 3)
            Ellipse().fill(flowerPetal.opacity(0.7)).frame(width: 4, height: 5)
                .position(x: 6, y: 3)
            RoundedRectangle(cornerRadius: 0.5).fill(butterflyBody).frame(width: 1, height: 4)
                .position(x: 4, y: 3)
        }
        .frame(width: 8, height: 6)
    }

    // MARK: 白钮里的植物（20×20 坐标盒，按 HTML 原值换算成中心点）

    private var thumbPlant: some View {
        ZStack {
            // 茎：底 4，高 8→10
            RoundedRectangle(cornerRadius: 1)
                .fill(sprout)
                .frame(width: 2, height: isPro ? 10 : 8)
                .position(x: 10, y: isPro ? 11 : 12)
                .animation(gardenSpringy, value: isPro)

            // 左叶：6×4@(3,8) -30° → 7×5@(1,9) -40°，pro 换深绿
            Ellipse()
                .fill(isPro ? leaf : sprout)
                .frame(width: isPro ? 7 : 6, height: isPro ? 5 : 4)
                .rotationEffect(.degrees(isPro ? -40 : -30))
                .position(x: isPro ? 4.5 : 6, y: isPro ? 10.5 : 10)
                .animation(gardenSpringy, value: isPro)

            // 右叶
            Ellipse()
                .fill(isPro ? leaf : sprout)
                .frame(width: isPro ? 7 : 6, height: isPro ? 5 : 4)
                .rotationEffect(.degrees(isPro ? 40 : 30))
                .position(x: isPro ? 15.5 : 14, y: isPro ? 7.5 : 9)
                .animation(gardenSpringy, value: isPro)

            // 额外的浅绿小叶（pro 才长出来）
            Ellipse()
                .fill(sproutLight)
                .frame(width: 5, height: 3)
                .rotationEffect(.degrees(-25))
                .position(x: 4.5, y: 12.5)
                .scaleEffect(isPro ? 1 : 0)
                .opacity(isPro ? 1 : 0)
                .animation(gardenSpringyFast.delay(0.2), value: isPro)
            Ellipse()
                .fill(sproutLight)
                .frame(width: 5, height: 3)
                .rotationEffect(.degrees(25))
                .position(x: 15.5, y: 11.5)
                .scaleEffect(isPro ? 1 : 0)
                .opacity(isPro ? 1 : 0)
                .animation(gardenSpringyFast.delay(0.2), value: isPro)

            // 顶上开花（pro，跟钮一起动，无延迟）
            ZStack {
                Circle().fill(flowerPetal).frame(width: 4, height: 4).position(x: 4, y: 2)
                Circle().fill(flowerPetal).frame(width: 4, height: 4).position(x: 2, y: 4)
                Circle().fill(flowerPetal).frame(width: 4, height: 4).position(x: 6, y: 4)
                Circle().fill(flowerPetal).frame(width: 4, height: 4).position(x: 4, y: 6)
                Circle().fill(flowerCenter).frame(width: 3, height: 3).position(x: 4, y: 3.5)
            }
            .frame(width: 8, height: 8)
            .position(x: 10, y: 4)
            .scaleEffect(isPro ? 1 : 0)
            .opacity(isPro ? 1 : 0)
            .animation(gardenSpringy, value: isPro)
        }
        .frame(width: 20, height: 20)
    }
}
#endif
