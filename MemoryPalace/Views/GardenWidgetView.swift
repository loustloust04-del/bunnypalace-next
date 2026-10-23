import SwiftUI
import SwiftData

/// 记忆花园小组件 —— 一朵像素花对应一条记忆，只长**当前楼层**的记忆。
/// 横向一排展开，放不下左右滚动（像恐龙游戏那条地平线）。
/// 花型随 category，亮度/动感随记忆热度（DecayEngine.effectiveWeight）：
/// 热=鲜亮轻摇、温=半亮、冷=暗淡静止。越常被想起开得越精神，冷落了就黯淡等你回来。
struct GardenWidgetView: View {
    @Environment(\.isPage2Active) private var desktopActive
    @Environment(\.usesSystemDesktop) private var systemDesktop
    var size: WidgetSize = .large
    @Environment(\.pinnedOnDesktop) private var pinnedOnDesktop

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var memories: [Memory] = []
    @State private var selected: Memory?
    private let store = SwiftDataMemoryStore()

    private let rose = Color(red: 0.82, green: 0.54, blue: 0.55)

    private var shown: [Memory] {
        size == .small ? Array(memories.prefix(5)) : memories
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #if os(macOS)
            .modifier(MacShellWidgetSurface())
            #else
            .modifier(Page2LegacySurface())
            #endif
            .onAppear { refresh() }
            .onChange(of: profileManager?.currentProfile.id) { _, _ in refresh() }
            .onChange(of: desktopActive) { _, active in if active { refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in refresh() }
    }

    private func refresh() {
        guard desktopActive else { return }
        let pid = profileManager?.currentProfile.id ?? ""
        guard !pid.isEmpty else { memories = []; return }
        memories = store.listHot(profileId: pid, context: modelContext)
        if let sel = selected, !memories.contains(where: { $0.id == sel.id }) { selected = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch size {
        case .small:  smallBody
        case .medium: mediumBody
        case .large:  largeBody
        }
    }

    // 横排花田（核心）：横向滚动，花站在一条地平线上
    private func flowerRow(fontSize: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, m in
                    PixelFlower(memory: m, index: i, fontSize: fontSize)
                        .onTapGesture { select(m) }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.textMuted.opacity(0.25)).frame(height: 1)
        }
    }

    // 小方：横排几朵 + 计数（glance）
    private var smallBody: some View {
        VStack(spacing: 4) {
            if memories.isEmpty {
                Spacer(minLength: 0); seedlings
            } else {
                flowerRow(fontSize: 11)
            }
            Text(memories.isEmpty ? "待发芽" : "\(memories.count) 朵")
                .font(.system(size: Theme.F.caption, design: systemDesktop ? .default : .monospaced))
                .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
            if memories.isEmpty { Spacer(minLength: 0) }
        }
        .padding(.vertical, 10)
    }

    // 长条：标题 + 横排花
    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            if memories.isEmpty { emptyState }
            else { flowerRow(fontSize: 12).padding(.bottom, 8) }
        }
    }

    // 大方：标题 + 横排花 + 点花浮出记忆
    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            if memories.isEmpty {
                emptyState
            } else {
                flowerRow(fontSize: 14)
                footer
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
    }

    private var footer: some View {
        Group {
            if let m = selected {
                Text("「\(m.content)」")
                    .font(.system(size: Theme.F.caption, design: systemDesktop ? .default : .monospaced))
                    .foregroundColor(systemDesktop ? .primary.opacity(0.8) : Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .transition(.opacity)
            } else {
                Text("· 点一朵花，想起一件事 ·")
                    .font(.system(size: Theme.F.caption, design: systemDesktop ? .default : .monospaced))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ m: Memory) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selected = (selected?.id == m.id) ? nil : m
        }
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            if !systemDesktop {
            Circle().fill(rose).frame(width: 8, height: 8)
            Circle().fill(Theme.branchIndicator).frame(width: 8, height: 8)
            Circle().fill(Theme.textMuted.opacity(0.5)).frame(width: 8, height: 8)
            }
            Spacer()
            Text(systemDesktop ? "记忆花园" : "garden · 本层")
                .font(.system(size: Theme.F.caption, design: systemDesktop ? .default : .monospaced))
                .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(systemDesktop ? Color.clear : Theme.sidebarBg.opacity(0.7))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            seedlings
            Text("还没有记忆，聊聊就会发芽")
                .font(.system(size: Theme.F.caption, design: systemDesktop ? .default : .monospaced))
                .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var seedlings: some View {
        Text("‧ ‧ ‧")
            .font(.system(size: 18, weight: .medium, design: systemDesktop ? .default : .monospaced))
            .foregroundColor(Theme.branchIndicator.opacity(0.5))
    }
}

// MARK: - 像素花

/// 一朵 █ 像素花。花型按 category，亮度/摇曳按记忆热度。
private struct PixelFlower: View {
    @Environment(\.isPage2Active) private var desktopActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let memory: Memory
    let index: Int
    var fontSize: CGFloat = 12

    @State private var sway = false
    private let rose = Color(red: 0.82, green: 0.54, blue: 0.55)

    private var weight: Double { min(1, max(0, DecayEngine.effectiveWeight(memory))) }
    private var stage: Int { weight >= 0.3 ? 2 : (weight >= 0.05 ? 1 : 0) }

    // 花型：按 category 选 jgs 经典 ASCII 花之一
    private var grid: [String] { FlowerSprite.grid(for: memory.category) }

    private var color: Color {
        if stage == 0 { return Theme.textMuted.opacity(0.45) }   // 冷：暗淡
        let base: Color
        switch memory.category {
        case "preference", "fact": base = Theme.branchIndicator
        case "goal":               base = rose
        case "relationship":       base = rose
        default:                   base = Theme.branchIndicator
        }
        return base.opacity(stage == 2 ? 1.0 : 0.65)            // 热=鲜亮，温=半亮
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(grid.enumerated()), id: \.offset) { _, row in
                Text(row)
            }
        }
        .font(.system(size: fontSize, weight: .bold, design: .monospaced))
        .foregroundColor(color)
        .fixedSize()
        .rotationEffect(.degrees(shouldAnimate ? (sway ? swayAmt : -swayAmt) : 0), anchor: .bottom)
        .contentShape(Rectangle())
        .task(id: shouldAnimate) {
            guard shouldAnimate else { return }
            let duration = 2.0 + Double(index % 5) * 0.25
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: duration)) { sway.toggle() }
                do { try await Task.sleep(for: .seconds(duration)) }
                catch { return }
            }
        }
    }

    private var shouldAnimate: Bool { desktopActive && !reduceMotion && stage == 2 }
    private var swayAmt: Double { 3 }
}

// MARK: - 花型 sprite（jgs 经典 ASCII 花 motif，widget 与开场花园共用）

enum FlowerSprite {
    static let rose = [
        " @@@@ ",
        "@@()@@",
        " @@@@ ",
        "  |   ",
        " \\\\|//",
    ]
    static let bell = [
        "wWWWw",
        "(___)",
        "  |  ",
        " \\|/ ",
        "\\\\|//",
    ]
    static let star = [
        "vVVVv",
        " \\|/ ",
        "  |  ",
        "  |  ",
        "\\\\|//",
    ]
    static let sprout = [
        "\\\\|//",
        " \\|/ ",
        "  |  ",
        "  |  ",
        "\\\\|//",
    ]
    /// 按 category 选花型
    static func grid(for category: String) -> [String] {
        switch category {
        case "relationship": return rose
        case "goal":         return star
        case "preference":   return bell
        default:             return sprout
        }
    }
}
