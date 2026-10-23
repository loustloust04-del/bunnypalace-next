#if PERSONAL_APPS
#if DEBUG
import SwiftUI

// MARK: - 「开发」组织 / 指标两个 tab（docs/plan-pm-board-app.md §1④）

struct PMOrgView: View {
    let open: (String) -> Void
    @State private var store = PMBoardStore.shared

    private struct Row: Identifiable { let id: String; let depth: Int; let node: PMNode }

    var body: some View {
        ScrollView {
            if let b = store.board {
                let sessions = Dictionary(b.sessions.map { ($0.sid, $0) }, uniquingKeysWith: { a, _ in a })
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows(b)) { r in line(r, sessions: sessions) }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            } else {
                PMEmpty(icon: "person.3", text: store.boardError ?? "还没拿到数据")
            }
        }
    }

    private func rows(_ b: PMBoard) -> [Row] {
        var out: [Row] = []
        func walk(_ n: PMNode, _ d: Int, _ path: String) {
            let id = "\(path)/\(n.id)"
            out.append(Row(id: id, depth: d, node: n))
            for c in n.children { walk(c, d + 1, id) }
        }
        walk(b.tree, 0, "")
        if !b.unassigned.isEmpty {
            out.append(Row(id: "unassigned", depth: 0, node: PMNode(kind: "group", sid: nil, name: "没挂上的", aid: nil, label: nil, children: [])))
            for n in b.unassigned { walk(n, 1, "unassigned") }
        }
        return out
    }

    @ViewBuilder
    private func line(_ r: Row, sessions: [String: PMSession]) -> some View {
        let n = r.node
        let s = n.sid.flatMap { sessions[$0] }
        Button { if let sid = s?.sid { open(sid) } } label: {
            HStack(spacing: 6) {
                switch n.kind {
                case "human":
                    Image(systemName: "person.fill").foregroundStyle(PMState.wait.color)
                    Text(n.name ?? "粟粟").font(.system(size: Theme.F.label, weight: .semibold))
                case "session":
                    Circle().fill(s?.state.color ?? PMState.idle.color).frame(width: 8, height: 8)
                    Text(s?.name ?? n.sid?.prefix(8).description ?? "?").font(.system(size: Theme.F.body, weight: s?.role != nil ? .semibold : .regular))
                    if let role = s?.role { PMTag(text: role) }
                    if let z = s?.zone { Text(z).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted) }
                case "role-missing":
                    Circle().stroke(PMState.idle.color, lineWidth: 1).frame(width: 8, height: 8)
                    Text("\(n.name ?? "?")（没在跑）").font(.system(size: Theme.F.body)).foregroundStyle(Theme.textMuted)
                case "agent":
                    Image(systemName: "gearshape").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    Text(n.label ?? "subagent").font(.system(size: Theme.F.secondary)).foregroundStyle(Theme.textSecondary)
                default:
                    Text(n.name ?? "").font(.system(size: Theme.F.caption, weight: .semibold)).foregroundStyle(Theme.textMuted).padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .foregroundStyle(Theme.textPrimary)
            .padding(.leading, CGFloat(r.depth) * 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(s == nil)
    }
}

struct PMKpiView: View {
    @State private var store = PMBoardStore.shared

    var body: some View {
        ScrollView {
            if let k = store.board?.kpi {
                VStack(alignment: .leading, spacing: 10) {
                    if let e = k.error { PMNotice(text: e) }
                    if !k.windowText.isEmpty { Text("近 7 天 · \(k.windowText)").font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted) }
                    ForEach(k.alerts, id: \.self) { PMNotice(text: $0) }
                    if let main = k.tiles.first(where: \.main) { tile(main, big: true) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(k.tiles.filter { !$0.main }) { tile($0, big: false) }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 24)
            } else {
                PMEmpty(icon: "chart.bar", text: store.boardError ?? "还没拿到指标")
            }
        }
    }

    private func fmt(_ v: Double?, _ f: String) -> String {
        guard let v else { return "—" }
        switch f {
        case "pct": return "\(Int((v * 100).rounded()))%"
        case "secs": return v >= 90 ? "\(Int((v / 60).rounded()))m" : "\(Int(v.rounded()))s"
        default: return v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
        }
    }

    private func tile(_ t: PMTile, big: Bool) -> some View {
        let arrow: (String, Color)? = {
            guard let c = t.cur, let p = t.prev, c != p else { return nil }
            let better = t.better == "low" ? c < p : c > p
            return (c > p ? "↑" : "↓", better ? PMState.busy.color : PMState.wait.color)
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(t.label).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(fmt(t.cur, t.fmt)).font(.system(size: big ? 30 : 20, weight: .semibold, design: .serif)).foregroundStyle(Theme.textPrimary)
                if let arrow { Text(arrow.0).font(.system(size: Theme.F.body, weight: .semibold)).foregroundStyle(arrow.1) }
                Text("上期 \(fmt(t.prev, t.fmt))").font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted)
            }
            if !t.sub.isEmpty { Text(t.sub).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(1) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif
#endif
