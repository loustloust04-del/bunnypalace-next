import SwiftUI
import SwiftData

/// cc 对话标记同款荧光绿（= SidebarView.ccSessionBadgeColor），开场花园统一用它，鲜亮看得清。
private let sceneNeon = Color(red: 0.22, green: 0.94, blue: 0.49)

/// 新对话开场场景：底部按**本层记忆**长出高矮错落的花，天空散落手绘星点（* . -+- ' ⋆）。
/// 作为聊天区 background，currentPath 为空时显示，发出第一条消息后自动隐去。
struct GardenSceneView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var memories: [Memory] = []
    /// 热记忆（权重 ≥0.3）才轻摇；refresh 时算一次，不每帧算衰减
    @State private var hotIDs: Set<UUID> = []
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let store = SwiftDataMemoryStore()

    /// 停帧（#058）：repeatForever 挂着就逐帧提交、离屏也不停，空对话页曾让整个 app 常驻 ~58 帧。
    /// 现在星闪 / 云飘 / 花摇都由 TimelineView 的时间算，聊天页不在屏 / 减弱动态 / 低电量 / 退后台就停在当前帧。
    private var paused: Bool {
        #if os(iOS)
        // 聊天页不在屏 = page0 或 page2 在屏（两个都是翻页时写的 @Observable 单例，这里只读）
        let offScreen = Page0Stage.shared.isOnScreen || Page2SceneState.shared.isActive
        #else
        let offScreen = false
        #endif
        return offScreen || reduceMotion || lowPower || scenePhase != .active
    }

    var body: some View {
        GeometryReader { geo in
            // 动作都很慢（云 32pt/7s、花 6°/2s），15 帧看不出台阶
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack {
                    sky(in: geo.size, glow: Self.swing(t, period: 2.6))
                    SceneCloud()
                        .position(x: geo.size.width * 0.30 - 16 + 32 * Self.swing(t, period: 7),
                                  y: geo.size.height * 0.18)
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(memories.enumerated()), id: \.element.id) { i, m in
                            SceneFlower(memory: m)
                                .rotationEffect(.degrees(swayAngle(m, index: i, t: t)), anchor: .bottom)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 18)
                    .padding(.horizontal, 10)
                }
            }
        }
        .allowsHitTesting(false)   // 纯装饰，不挡输入/滚动
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func refresh() {
        let pid = profileManager?.currentProfile.id ?? ""
        guard !pid.isEmpty else { memories = []; hotIDs = []; return }
        memories = store.listHot(profileId: pid, context: modelContext)
        hotIDs = Set(memories.filter { DecayEngine.effectiveWeight($0) >= 0.3 }.map(\.id))
    }

    /// 0→1→0 往返，一个来回 = 2 × period；周期幅度同原 easeInOut(duration: period).repeatForever(autoreverses: true)，缓动是近似的正弦。
    /// 按各自完整来回取余（统一按 3600 取余会在边界跳一下）
    private static func swing(_ t: Double, period: Double) -> Double {
        (1 - cos(t.truncatingRemainder(dividingBy: 2 * period) * .pi / period)) / 2
    }

    /// 热记忆 ±3° 轻摇；其余静止在 -3°（原样）
    private func swayAngle(_ m: Memory, index i: Int, t: Double) -> Double {
        guard hotIDs.contains(m.id) else { return -3 }
        return -3 + 6 * Self.swing(t, period: 2.0 + Double(i % 5) * 0.3)
    }

    // MARK: - 天空：散落手绘星点，轻闪
    private func sky(in size: CGSize, glow: Double) -> some View {
        ZStack {
            ForEach(0..<starCount, id: \.self) { i in
                Text(Self.glyphs[i % Self.glyphs.count])
                    .font(.system(size: Self.sizes[i % Self.sizes.count], weight: .light, design: .monospaced))
                    .foregroundColor(sceneNeon)
                    .opacity(twinkleLo(i) + (twinkleHi(i) - twinkleLo(i)) * glow)
                    .position(
                        x: frac(i, 1.7) * size.width,
                        y: frac(i, 3.1) * size.height * 0.6 + 14
                    )
            }
        }
    }

    private let starCount = 16
    private static let glyphs = ["*", ".", "+", "·", "✦", "⋆", "-+-", "'", "˚"]
    private static let sizes: [CGFloat] = [13, 9, 12, 8, 11, 14, 12, 10, 9]
    private func twinkleHi(_ i: Int) -> Double { i % 2 == 0 ? 1.0 : 0.7 }
    private func twinkleLo(_ i: Int) -> Double { i % 2 == 0 ? 0.5 : 0.9 }
    /// sin 确定性伪随机 [0,1)，避免 Math.random（每帧不稳定会让星星乱跳）
    private func frac(_ i: Int, _ k: Double) -> CGFloat {
        let x = sin(Double(i + 1) * k * 12.9898) * 43758.5453
        return CGFloat(x - floor(x))
    }
}

// MARK: - 一朵 ASCII 云（缓慢横向飘）

private struct SceneCloud: View {
    private static let lines = ["   _____   ", " _(     )_ ", "(_________)"]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.lines.indices, id: \.self) { Text(Self.lines[$0]) }
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundColor(sceneNeon.opacity(0.5))
    }
}

// MARK: - 开场花（jgs 花头 + 可变茎，高矮错落；轻摇由 GardenSceneView 套 rotationEffect）

private struct SceneFlower: View {
    let memory: Memory

    private var weight: Double { min(1, max(0, DecayEngine.effectiveWeight(memory))) }
    private var stage: Int { weight >= 0.3 ? 2 : (weight >= 0.05 ? 1 : 0) }

    // 稳定 hash（String.hashValue 每次启动随机；用字符和保证同记忆每次同高度）
    private var stable: Int { memory.id.uuidString.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } }
    private var extraStem: Int { stable % 5 }   // 0...4 额外茎段 → 高矮错落

    // 花头 motif 中部插入额外 "|" 茎段，拉出不同高度
    private var rows: [String] {
        var g = FlowerSprite.grid(for: memory.category)
        guard !g.isEmpty else { return g }
        let root = g.removeLast()
        let w = g.map(\.count).max() ?? 5
        let bar = centeredBar(w)
        g.append(contentsOf: Array(repeating: bar, count: extraStem))
        g.append(root)
        return g
    }
    private func centeredBar(_ w: Int) -> String {
        let left = (w - 1) / 2
        return String(repeating: " ", count: left) + "|" + String(repeating: " ", count: max(0, w - 1 - left))
    }

    private var color: Color {
        switch stage {
        case 2:  return sceneNeon                  // 热：荧光绿满
        case 1:  return sceneNeon.opacity(0.7)     // 温
        default: return sceneNeon.opacity(0.45)    // 冷：淡荧光绿
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in Text(r) }
        }
        .font(.system(size: 13, weight: .bold, design: .monospaced))
        .foregroundColor(color)
        .fixedSize()
    }
}
