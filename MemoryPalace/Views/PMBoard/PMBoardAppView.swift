#if PERSONAL_APPS
#if DEBUG
import SwiftUI

// MARK: - page2 pmBoard 子应用（docs/plan-dev-subapp-v2.md §1）
// 底部四个 tab（Q18）：对话（首页，一 session 一行）· 占用 · 待验（TASK.md）· 看板（v1 的首页 / 组织 / 指标 / 路线图）；
// 点任一 session 进详情（原地换页，不套 NavigationStack——mac 右栏里嵌套推入会盖住整列）。

struct PMBoardAppView: View {
    enum Tab: String, CaseIterable {
        case chats = "对话", occupancy = "占用", verify = "待验", board = "看板"
        var icon: String {
            switch self {
            case .chats: "bubble.left.and.bubble.right"
            case .occupancy: "square.grid.2x2"
            case .verify: "checklist"
            case .board: "chart.bar"
            }
        }
    }

    @State private var store = PMBoardStore.shared
    @State private var tab: Tab = .chats
    @State private var selected: String?
    #if os(iOS)
    @Environment(\.page2AppActive) private var appActive
    #else
    private let appActive = true   // page2 外壳只在 iOS；mac 右栏挂着就算可见
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    private struct PollKey: Hashable { let active: Bool; let sid: String?; let tab: Tab }

    var body: some View {
        Group {
            if let sid = selected {
                PMSessionDetailView(sid: sid) { selected = nil }
            } else {
                VStack(spacing: 0) {
                    switch tab {
                    case .chats: PMChatListView(open: open) { tab = .occupancy }
                    case .occupancy: PMOccupancyView(open: open)
                    case .verify: PMTaskView(open: open)
                    case .board: PMBoardTabView(open: open)
                    }
                    tabBar
                }
            }
        }
        .toolPageBackground(Theme.mainBg)
        .task(id: PollKey(active: appActive && scenePhase == .active, sid: selected, tab: tab)) {
            guard appActive, scenePhase == .active else { return }
            while !Task.isCancelled {
                if let sid = selected { store.requestSession(sid) }
                else {
                    switch tab {
                    case .chats: store.requestHome()
                    case .occupancy: store.requestOccupancy()
                    case .verify: store.requestTask()
                    case .board: store.requestBoard()
                    }
                }
                try? await Task.sleep(for: .seconds(store.interval(detail: selected)))
            }
        }
        .onAppear(perform: consumeTarget)
        .onChange(of: navigator?.pendingTarget) { _, _ in consumeTarget() }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 17, weight: tab == t ? .semibold : .regular))
                        Text(t.rawValue).font(.system(size: Theme.F.badge))
                    }
                    .foregroundStyle(tab == t ? Theme.textPrimary : Theme.textMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4).padding(.bottom, 8)
        .background(Theme.mainBg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.textMuted.opacity(0.15)).frame(height: 0.5) }
    }

    private func open(_ sid: String) { selected = sid }

    private func consumeTarget() {
        guard let t = navigator?.pendingTarget, t.tool == "pmBoard" else { return }
        selected = t.id
        navigator?.pendingTarget = nil
    }
}

// MARK: - 看板 tab（v1 原首页 + 组织 + 指标 + 路线图）

struct PMBoardTabView: View {
    enum Seg: String, CaseIterable { case home = "大家", org = "组织", kpi = "指标", roadmap = "路线图" }
    let open: (String) -> Void
    @State private var seg: Seg = .home

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $seg) {
                ForEach(Seg.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            switch seg {
            case .home: PMBoardHomeView(open: open)
            case .org: PMOrgView(open: open)
            case .kpi: PMKpiView()
            case .roadmap: PMDocView(name: "plan-open-source")
            }
        }
    }
}

// MARK: - 首页

struct PMBoardHomeView: View {
    let open: (String) -> Void
    @State private var store = PMBoardStore.shared
    @State private var showAllCalls = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let board = store.board {
                    summary(board)
                    if let e = store.boardError { PMNotice(text: e) }
                    calls(board)
                    everyone(board)
                    if !board.errors.isEmpty { PMNotice(text: board.errors.joined(separator: "\n")) }
                    Text("Mac 上 \(board.generatedText) 的数据")
                        .font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                } else if let e = store.boardError {
                    PMEmpty(icon: "wifi.exclamationmark", text: e)
                } else if !store.bridgeConnected {
                    PMEmpty(icon: "wifi.slash", text: "桥没连上（记忆花园没连到 Mac 上的 hub）")
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 24)
        }
        .refreshable { store.requestBoard() }
    }

    // 一行汇总：只给最紧急的那段上色（rootshell 全局 rollup）
    private func summary(_ b: PMBoard) -> some View {
        let urgent = PMState.allCases.first { b.counts.count($0) > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array(PMState.allCases.enumerated()), id: \.element) { i, s in
                    if i > 0 { Text(" · ").foregroundStyle(Theme.textMuted) }
                    Text("\(s.title) ").foregroundStyle(s == urgent ? s.color : Theme.textSecondary)
                    Text("\(b.counts.count(s))")
                        .font(.system(size: Theme.F.body, weight: .semibold, design: .serif))
                        .foregroundStyle(s == urgent ? s.color : Theme.textPrimary)
                }
            }
            .font(.system(size: Theme.F.body))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(b.lights) { l in
                        HStack(spacing: 5) {
                            Circle().fill(l.color).frame(width: 7, height: 7)
                            Text(l.text).lineLimit(1)
                        }
                        .font(.system(size: Theme.F.caption))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.sidebarBg, in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func calls(_ b: PMBoard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PMSectionTitle(text: "谁喊了我", count: b.calls.filter(\.recent).count)
            if b.calls.isEmpty {
                Text("没人喊你").font(.system(size: Theme.F.secondary)).foregroundStyle(Theme.textMuted)
            }
            ForEach(showAllCalls ? b.calls : Array(b.calls.prefix(6))) { c in
                let state = c.sid.flatMap { sid in b.sessions.first { $0.sid == sid }?.state }
                Button { if let sid = c.sid { open(sid) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(state?.color ?? PMState.idle.color.opacity(0.5)).frame(width: 8, height: 8)
                            Text(c.who).font(.system(size: Theme.F.secondary, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            PMTag(text: c.srcText)
                            Spacer(minLength: 4)
                            Text(PMTime.ago(c.at)).font(.system(size: Theme.F.caption, design: .serif)).foregroundStyle(Theme.textMuted)
                        }
                        if !c.text.isEmpty {
                            Text(c.text).font(.system(size: Theme.F.secondary)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(c.recent ? PMState.wait.color.opacity(0.12) : Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(c.sid == nil)
            }
            if b.calls.count > 6 {
                Button(showAllCalls ? "收起" : "还有 \(b.calls.count - 6) 条") { showAllCalls.toggle() }
                    .font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textSecondary).buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func everyone(_ b: PMBoard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PMSectionTitle(text: "大家", count: nil)
            ForEach(PMState.allCases, id: \.self) { s in
                let group = b.sessions.filter { $0.state == s }
                if !group.isEmpty {
                    Text("\(s.title) \(group.count)").font(.system(size: Theme.F.caption, weight: .semibold)).foregroundStyle(s.color)
                    ForEach(group) { x in
                        Button { open(x.sid) } label: { PMSessionCard(s: x) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct PMSessionCard: View {
    let s: PMSession
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(s.state.color).frame(width: 8, height: 8)
                Text(s.name).font(.system(size: Theme.F.label, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let r = s.role { PMTag(text: r) }
                if let z = s.zone { Text(z).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(1) }
                Spacer(minLength: 4)
                Text(s.stateText).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(s.doing.isEmpty ? "—" : s.doing).font(.system(size: Theme.F.secondary)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                badges
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private var badges: some View {
        HStack(spacing: 5) {
            if s.badges.merges > 0 || s.badges.mergeAsk { Text("🔀\(s.badges.merges > 0 ? "\(s.badges.merges)" : "?")") }
            if !s.badges.devices.isEmpty { Text("📱\(s.badges.devices.joined(separator: ","))") }
            if let b = s.badges.build { Text(b == "building" ? "🔨" : "🔨…") }
            if s.badges.agents > 0 { Text("⚙︎\(s.badges.agents)") }
        }
        .font(.system(size: Theme.F.caption))
        .foregroundStyle(Theme.textMuted)
        .fixedSize()
    }
}

// MARK: - 路线图（主仓 docs/<name>.html，经 4793 /api/doc 现读；进 tab 拉一次 + 手动刷新；勾选 / 批注落盘在 4793，Herald 收摘要）

struct PMDocView: View {
    let name: String
    @State private var store = PMBoardStore.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(stamp)
                    .font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(1)
                Spacer(minLength: 4)
                if store.docLoading.contains(name) { ProgressView().controlSize(.small) }
                Button { store.requestDoc(name: name) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: Theme.F.secondary, weight: .medium))
                        .foregroundStyle(Theme.textSecondary).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.docLoading.contains(name))
            }
            .padding(.horizontal, 14)
            if let doc = store.docs[name] {
                if let e = store.docErrors[name] { PMNotice(text: e).padding(.horizontal, 14) }
                PMDocWebView(html: doc.html) { body in store.postDocState(name, body) }
            } else if let e = store.docErrors[name] {
                PMEmpty(icon: "wifi.exclamationmark", text: e)
                Spacer()
            } else if !store.bridgeConnected {
                PMEmpty(icon: "wifi.slash", text: "桥没连上（记忆花园没连到 Mac 上的 hub）")
                Spacer()
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                Spacer()
            }
        }
        .onAppear { store.requestDoc(name: name) }
    }

    private var stamp: String {
        guard let doc = store.docs[name] else { return "docs/\(name).html" }
        return "Mac 上 \(PMTime.ago(doc.mtime))改过"
    }
}

// MARK: - 小零件

struct PMSectionTitle: View {
    let text: String
    let count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: Theme.F.sectionHeader, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            if let count, count > 0 {
                Text("\(count)").font(.system(size: Theme.F.badge, weight: .semibold, design: .serif))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(PMState.wait.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(PMState.wait.color)
            }
        }
    }
}

struct PMTag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: Theme.F.badge)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Theme.textMuted.opacity(0.14), in: Capsule())
            .foregroundStyle(Theme.textSecondary)
    }
}

struct PMNotice: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textSecondary)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(PMState.wait.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PMEmpty: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Theme.textMuted)
            Text(text).font(.system(size: Theme.F.body)).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

enum PMClipboard {
    static func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}
#endif
#endif
