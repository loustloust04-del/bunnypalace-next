import SwiftUI
import Grape

/// M3 · Obsidian 式记忆星图（Grape 力模拟：碰撞/电荷/弹簧/向心，d3-force 同源）。
/// 节点色按分类（主题色，带图例）、大小按关联数；捏合缩放、拖节点、点选高亮邻域，标签只给选中的和它连着的。
struct MemoryGraphView: View {
    let memories: [Memory]
    @Environment(\.settingsMetrics) private var m

    /// 图例顺序；颜色全取主题 token，不用蓝 / 黄
    static let categories = ["relationship", "preference", "goal", "fact", "context"]

    static func categoryColor(_ category: String) -> Color {
        switch category {
        case "relationship": Theme.branchIndicator
        case "preference": Theme.danger
        case "goal": Theme.textPrimary
        case "fact": Theme.textSecondary
        case "context": Theme.textMuted
        default: Theme.textMuted.opacity(0.5)
        }
    }

    @State private var graphState = ForceDirectedGraphState(initialIsRunning: true)
    @State private var selected: UUID? = nil

    private struct Edge: Identifiable {
        let a: UUID, b: UUID
        var id: String { "\(a)-\(b)" }
    }

    private var validIds: Set<UUID> { Set(memories.map(\.id)) }

    private var edges: [Edge] {
        var seen = Set<String>()
        var out: [Edge] = []
        for m in memories {
            for rid in m.relatedIds where validIds.contains(rid) {
                let key = m.id.uuidString < rid.uuidString ? "\(m.id)-\(rid)" : "\(rid)-\(m.id)"
                if seen.insert(key).inserted {
                    out.append(Edge(a: m.id, b: rid))
                }
            }
        }
        return out
    }

    private var neighborIds: Set<UUID> {
        guard let sid = selected, let m = memories.first(where: { $0.id == sid }) else { return [] }
        return Set(m.relatedIds)
    }

    private func nodeColor(_ m: Memory) -> Color {
        let base = Self.categoryColor(m.category)
        if let sid = selected, sid != m.id, !neighborIds.contains(m.id) {
            return base.opacity(0.15)   // 聚焦：邻域外淡出
        }
        return base
    }

    private func labeled(_ m: Memory) -> Bool {
        guard let sid = selected else { return false }
        return sid == m.id || neighborIds.contains(m.id)
    }

    private var legend: some View {
        let present = Set(memories.map(\.category))
        return HStack(spacing: 10) {
            ForEach(Self.categories.filter { present.contains($0) }, id: \.self) { c in
                HStack(spacing: 4) {
                    Circle().fill(Self.categoryColor(c)).frame(width: 7, height: 7)
                    Text(MemoryCardView.categoryLabels[c] ?? c)
                        .font(m.caption)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func degree(_ m: Memory) -> Int { m.relatedIds.count }

    var body: some View {
        ZStack(alignment: .bottom) {
            if memories.isEmpty || edges.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "circle.hexagongrid")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.textMuted.opacity(0.4))
                    Text(memories.isEmpty ? "还没有记忆" : "记忆之间还没连起来\n打开「按意思找记忆」后，聊几天就会有")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ForceDirectedGraph(states: graphState) {
                Series(memories) { m in
                    NodeMark(id: m.id)
                        .symbol(.circle)
                        .symbolSize(radius: 3.0 + min(CGFloat(degree(m)) * 0.5, 4))
                        .foregroundStyle(nodeColor(m))
                        .stroke(.color(Theme.mainBg), StrokeStyle(lineWidth: 1))
                        .annotation(m.id.uuidString, offset: .zero) {
                            Text(m.content.prefix(8))
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textSecondary.opacity(labeled(m) ? 0.95 : 0))
                                .offset(y: 11)
                        }
                }
                Series(edges) { e in
                    LinkMark(from: e.a, to: e.b)
                        .stroke(
                            .color(edgeColor(e)),
                            StrokeStyle(lineWidth: edgeLit(e) ? 2 : 1)
                        )
                }
            } force: {
                .manyBody(strength: -16)
                .center(strength: 0.3)
                // Obsidian 的 X/Y force：把整团云往圆里收
                .position(direction: .x, targetOnDirection: .constant(0), strength: .constant(0.06))
                .position(direction: .y, targetOnDirection: .constant(0), strength: .constant(0.06))
                .link(originalLength: 30.0, stiffness: .weightedByDegree { _, _ in 0.6 })
                .collide(radius: .constant(9))
            }
            .graphOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .withGraphDragGesture(proxy, of: UUID.self)
                    .withGraphMagnifyGesture(proxy)
                    .withGraphTapGesture(proxy, of: UUID.self) { id in
                        selected = (selected == id) ? nil : id
                    }
            }

            // 选中内容卡
            if let sid = selected, let mem = memories.first(where: { $0.id == sid }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mem.content)
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(4)
                    Text("\(MemoryCardView.categoryLabels[mem.category] ?? mem.category) · 连着 \(mem.relatedIds.count) 条")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.assistantBubble))
                .padding(8)
                .onTapGesture { selected = nil }
            }
        }
        .overlay(alignment: .top) {
            if !edges.isEmpty { legend }
        }
    }

    private func edgeLit(_ e: Edge) -> Bool {
        guard let sid = selected else { return false }
        return e.a == sid || e.b == sid
    }

    private func edgeColor(_ e: Edge) -> Color {
        if edgeLit(e) { return Theme.branchIndicator }
        if selected != nil { return Theme.textMuted.opacity(0.08) }
        return Theme.textMuted.opacity(0.3)
    }
}
