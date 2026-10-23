#if PERSONAL_APPS
#if DEBUG
import SwiftUI

// MARK: - pmBoard 首页：对话列表（docs/plan-dev-subapp-v2.md §1 / P0-d-4）
// 一 session 一行。三段：待我回（喊了我、我还没回，按最近一次喊的时间排）· 置顶 · 最近。状态变了不换段，只有「待我回」往上浮。
// 搜索只在本机过滤（显示名 / 原名 / 头衔 / 工位 / 项目 / 预览）。

struct PMChatListView: View {
    enum Filter: Hashable { case all, unanswered, garden, other }

    let open: (String) -> Void
    let showOccupancy: () -> Void
    @State private var store = PMBoardStore.shared
    @State private var query = ""
    @State private var filter: Filter = .all

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let home = store.home {
                    strip(home)
                    if let e = store.homeError { PMNotice(text: e) }
                    searchField
                    filters(home)
                    sections(home)
                    if !home.errors.isEmpty { PMNotice(text: home.errors.joined(separator: "\n")) }
                    Text("Mac 上 \(home.generatedText) 的数据")
                        .font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                } else if let e = store.homeError {
                    PMEmpty(icon: "wifi.exclamationmark", text: e)
                } else if !store.bridgeConnected {
                    PMEmpty(icon: "wifi.slash", text: "桥没连上（记忆花园没连到 Mac 上的 hub）")
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 16)
        }
        .refreshable { store.requestHome() }
    }

    // MARK: 顶部状态条：编译 · 设备 · 合并 · 冻结 / 暂停 · 最近一条叮咚；点了去「占用」

    private func strip(_ h: PMHome) -> some View {
        let st = h.strip
        var items: [(String, Color)] = []
        if let b = st.build { items.append(("🔨 " + b.text, b.color)) }
        if let d = st.device { items.append(("📱 " + d.text, d.color)) }
        if let m = st.merge { items.append(("🔀 " + m.text, m.color)) }
        if st.frozen { items.append(("⏸ 编译冻结", PMState.wait.color)) }
        if st.zonePaused { items.append(("⏸ 工位暂停编译", PMState.idle.color)) }
        if let d = st.lastDing { items.append(("🔔 \(PMTime.ago(d.at)) · \(d.text)", PMState.idle.color)) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(spacing: 5) {
                        Circle().fill(it.1).frame(width: 6, height: 6)
                        Text(it.0).lineLimit(1)
                    }
                    .font(.system(size: Theme.F.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.sidebarBg, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture(perform: showOccupancy)   // 横向 ScrollView 里 Button 会被滚动手势吞
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
            TextField("搜名字 / 工位 / 项目 / 说了啥", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.F.body))
                .tint(Theme.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 10))
    }

    private func filters(_ h: PMHome) -> some View {
        let n = h.people.filter { $0.unanswered != nil }.count
        let opts: [(Filter, String)] = [(.all, "全部"), (.unanswered, n > 0 ? "待我回 \(n)" : "待我回"), (.garden, "花园"), (.other, "其他项目")]
        return HStack(spacing: 6) {
            ForEach(Array(opts.enumerated()), id: \.offset) { _, opt in
                let (f, title) = opt
                Button { filter = f } label: {
                    Text(title).font(.system(size: Theme.F.caption, weight: filter == f ? .semibold : .regular))
                        .foregroundStyle(filter == f ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(filter == f ? Theme.textMuted.opacity(0.18) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 三段

    @ViewBuilder
    private func sections(_ h: PMHome) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = h.people.filter { p in
            switch filter {
            case .all: true
            case .unanswered: p.unanswered != nil
            case .garden: p.scope == "garden"
            case .other: p.scope == "other"
            }
        }.filter { q.isEmpty || $0.searchText.lowercased().contains(q) }
        let waiting = shown.filter { $0.unanswered != nil }.sorted { ($0.unanswered?.lastAt ?? 0) > ($1.unanswered?.lastAt ?? 0) }
        let pinned = shown.filter { $0.unanswered == nil && store.isPinned($0) }
        let rest = shown.filter { $0.unanswered == nil && !store.isPinned($0) }
        if shown.isEmpty {
            Text(q.isEmpty ? "这里没人" : "搜不到「\(query)」").font(.system(size: Theme.F.secondary)).foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity).padding(.top, 30)
        }
        section("待我回", waiting, count: waiting.count)
        section("置顶", pinned, count: nil)
        section("最近", rest, count: nil)
    }

    @ViewBuilder
    private func section(_ title: String, _ people: [PMPerson], count: Int?) -> some View {
        if !people.isEmpty {
            PMSectionTitle(text: title, count: count).padding(.top, 6)
            ForEach(people) { p in
                Button { open(p.sid) } label: { PMPersonRow(p: p) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(store.isPinned(p) ? "取消置顶" : "置顶", systemImage: store.isPinned(p) ? "pin.slash" : "pin") { store.togglePin(p) }
                    }
            }
        }
    }
}

// MARK: - 一行

struct PMPersonRow: View {
    let p: PMPerson

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PMAvatar(p: p)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(p.displayName).font(.system(size: Theme.F.label, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let sub = p.subtitle {
                        Text(sub).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(PMTime.ago(p.lastAt)).font(.system(size: Theme.F.caption, design: .serif)).foregroundStyle(Theme.textMuted).fixedSize()
                }
                HStack(spacing: 6) {
                    Text(previewText).font(.system(size: Theme.F.secondary)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 4)
                    badges
                    if let u = p.unanswered {
                        Text("\(u.n)").font(.system(size: Theme.F.badge, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(PMState.wait.color, in: Capsule())
                    }
                }
                Text(([p.rawName] + p.zones + (p.scope == "other" ? [p.project] : [])).joined(separator: " · "))
                    .font(.system(size: Theme.F.badge)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.unanswered != nil ? PMState.wait.color.opacity(0.10) : Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private var previewText: String {
        if let u = p.unanswered { return u.lastText }
        guard let pv = p.preview else { return p.stateText }
        return pv.who == "self" ? pv.text : "\(pv.who)：\(pv.text)"
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if p.badges.merges > 0 || p.badges.mergeAsk { Text("🔀") }
            if let b = p.badges.build { Text(b == "building" ? "🔨" : "🔨…") }
            if !p.badges.devices.isEmpty { Text("📱") }
        }
        .font(.system(size: Theme.F.caption))
        .fixedSize()
    }
}

/// 首字头像，按角色上色；右下角状态点
struct PMAvatar: View {
    let p: PMPerson
    var size: CGFloat = 38

    var body: some View {
        Text(String(p.displayName.first ?? "?"))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: size, height: size)
            .background(tint.opacity(0.22), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(p.state.color).frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().stroke(Theme.mainBg, lineWidth: 1.5))
            }
    }

    private var tint: Color {
        switch p.kind {
        case "steward": PMState.external.color
        case "planner": PMState.wait.color
        default: p.scope == "other" ? PMState.idle.color : PMState.busy.color
        }
    }
}
#endif
#endif
