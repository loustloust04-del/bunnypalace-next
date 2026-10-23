import SwiftUI
import SwiftStreamingMarkdown

/// 掷骰节奏：点数闪动的间隔先快后慢，减速停下（约 0.9 秒）
enum DiceRollAnimation {
    static let delays: [TimeInterval] = [0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.11, 0.13, 0.15, 0.18]
}

/// 一颗骰子：六面骰画点，其他面数画数字；翻滚时绕斜轴转
struct DieFace: View {
    let value: Int?
    let sides: Int
    var tumble: Double = 0

    /// 六面骰点数在 3×3 格子里的位置（0…8）
    static func pips(for value: Int) -> [Int] {
        switch value {
        case 1: return [4]
        case 2: return [0, 8]
        case 3: return [0, 4, 8]
        case 4: return [0, 2, 6, 8]
        case 5: return [0, 2, 4, 6, 8]
        case 6: return [0, 2, 3, 5, 6, 8]
        default: return []
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(CodeBlockStyle.stroke, lineWidth: 1)
            if sides == 6, let value {
                pipsGrid(Self.pips(for: value))
            } else {
                Text(value.map(String.init) ?? "?")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
            }
        }
        .frame(width: 46, height: 46)
        .rotation3DEffect(.degrees(tumble), axis: (x: 1, y: 0.8, z: 0.25), perspective: 0.5)
    }

    private func pipsGrid(_ on: [Int]) -> some View {
        let dot: CGFloat = 8
        return VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { col in
                        Circle()
                            .fill(on.contains(row * 3 + col) ? Color.primary.opacity(0.85) : .clear)
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
    }
}

/// 骰子卡（research-chat-cards §8.1）：卡里一直有骰子；掷 → 三维翻滚、点数减速停下 → 带结果的同 id 新卡进输入框；流式中只读
struct DiceCardView: View {
    let card: DiceCard
    let nodeId: String?
    let streaming: Bool
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @State private var rollingRolls: [Int]?
    @State private var rollingPick: Int?
    @State private var tumble = 0.0

    private var chatCard: ChatCard { .dice(card) }
    private var isRolling: Bool { rollingRolls != nil || rollingPick != nil }

    private struct Snapshot {
        let status: ChatCardStatus
        let pending: DiceCard?
        var badge: ChatCardBadge {
            if status == .stale { return .stale }
            return pending == nil ? .none : .pending
        }
    }

    private func snapshot() -> Snapshot {
        guard !streaming, let viewModel else { return Snapshot(status: .readOnly, pending: nil) }
        let status = viewModel.cardStatus(chatCard, nodeId: nodeId)
        guard status == .live, let id = chatCard.id,
              case .dice(let d)? = viewModel.pendingCard(id: id),
              ChatCardIndex.showsPending(baseNodeId: viewModel.cardStagingBase[id], nodeId: nodeId) else {
            return Snapshot(status: status, pending: nil)
        }
        return Snapshot(status: status, pending: d)
    }

    var body: some View {
        let snap = snapshot()
        let shown = snap.pending ?? card
        ChatCardShell(kindLabel: "骰子", badge: snap.badge) {
            VStack(alignment: .leading, spacing: 12) {
                if !shown.title.isEmpty { Text(shown.title).font(.headline) }
                if let text = shown.dice {
                    diceRow(text: text, shown: shown)
                } else if let options = shown.options {
                    optionsList(options, shown: shown)
                }
                if let problem = DiceRoller.problem(shown) {
                    Text(problem).font(.caption).foregroundStyle(CodeBlockStyle.label)
                } else if snap.status == .live {
                    Button { roll(shown) } label: {
                        Label(shown.result == nil ? "掷" : "再掷一次", systemImage: "dice")
                            .font(.subheadline)
                            .foregroundStyle(CodeBlockStyle.label)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRolling)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func diceRow(text: String, shown: DiceCard) -> some View {
        let expr = DiceExpression.parse(text)
        let count = expr?.count ?? 1
        let sides = expr?.sides ?? 6
        let values: [Int?] = rollingRolls.map { $0.map(Optional.some) }
            ?? shown.result?.rolls.map { $0.map(Optional.some) }
            ?? Array(repeating: nil, count: count)
        Text(text).font(.system(size: 13, design: .monospaced)).foregroundStyle(CodeBlockStyle.label)
        HStack(spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                DieFace(value: v, sides: sides, tumble: tumble * (i.isMultiple(of: 2) ? 1 : -1))
            }
            if !isRolling, let total = shown.result?.total, shown.result?.rolls != nil {
                Text("= \(total)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func optionsList(_ options: [String], shown: DiceCard) -> some View {
        let highlighted = rollingPick ?? shown.validPick
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                let on = highlighted == i
                Text(option)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(on ? Theme.branchIndicator.opacity(0.25) : .clear))
                    .fontWeight(on ? .semibold : .regular)
                    .scaleEffect(on && !isRolling ? 1.06 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.65), value: on)
            }
            if !isRolling, shown.result?.pick != nil, shown.validPick == nil {
                Text("结果无效，可以再掷").font(.caption).foregroundStyle(CodeBlockStyle.label)
            }
        }
    }

    /// 先算好最终结果，再播翻滚：点数 / 高亮按先快后慢的节奏乱跳，最后落在结果上、结果卡进输入框
    private func roll(_ shown: DiceCard) {
        var rng = SystemRandomNumberGenerator()
        guard !isRolling, let rolled = DiceRoller.roll(shown, using: &rng) else { return }
        let expr = shown.dice.flatMap(DiceExpression.parse)
        let optionCount = shown.options?.count ?? 0
        withAnimation(.spring(response: 0.9, dampingFraction: 0.7)) { tumble += 720 }
        Task { @MainActor in
            for delay in DiceRollAnimation.delays {
                if let expr {
                    rollingRolls = (0..<expr.count).map { _ in Int.random(in: 1...expr.sides) }
                } else if optionCount > 0 {
                    rollingPick = ((rollingPick ?? -1) + 1) % optionCount
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            viewModel?.stageCard(.dice(rolled), baseNodeId: nodeId)     // 先落结果，再收动画（不闪回旧结果）
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                rollingRolls = nil
                rollingPick = nil
            }
        }
    }
}
