#if PERSONAL_APPS
import SwiftUI

// MARK: - page2 tool「军机处」（M5.2 任务导向布局）
// 组织原则：以「需求/EPIC」为根分组——你递的每个需求是一棵树，组头显示原文+进度+花费，
// 组内是子奏折链。无 epic 的散单归「零散奏折」。待御批永远浮顶。
// 数据源：hub WS warroom_board / warroom_board_result（tasks + requests + stats）。

struct WarroomTask: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let approval: String
    let targetRef: String
    let targetKind: String
    let engine: String
    let createdBy: String
    let parentTask: String?
    let epic: String?
    let resumeId: String?     // 完整 uuid：resume/tmux 单=目标会话；repo 单=它出生的新会话（干完可续聊）
    let createdAt: String
    let costUsd: Double
    let verdictText: String?
    let verdictKind: String?
    let reworkInstruction: String?
    let receiptSummary: String?

    static func from(_ obj: [String: Any]) -> WarroomTask? {
        guard let id = obj["task_id"] as? String else { return nil }
        var vKind: String? = nil, vText: String? = nil, vRework: String? = nil
        if let v = obj["verdict"] as? [String: Any] {
            vKind = v["verdict"] as? String
            vText = (v["reasons"] as? [String])?.joined(separator: "\n\n")
            vRework = v["rework_instruction"] as? String
        }
        return WarroomTask(
            id: id,
            title: obj["title"] as? String ?? "—",
            status: obj["status"] as? String ?? "?",
            approval: obj["approval"] as? String ?? "auto",
            targetRef: obj["target_ref"] as? String ?? "?",
            targetKind: obj["target_kind"] as? String ?? "resume",
            engine: obj["engine"] as? String ?? "claude",
            createdBy: obj["created_by"] as? String ?? "?",
            parentTask: obj["parent_task"] as? String,
            epic: obj["epic"] as? String,
            resumeId: obj["resume_id"] as? String,
            createdAt: obj["created_at"] as? String ?? "",
            costUsd: obj["cost_usd"] as? Double ?? 0,
            verdictText: vText, verdictKind: vKind, reworkInstruction: vRework,
            receiptSummary: obj["receipt_summary"] as? String
        )
    }

    var isActive: Bool { ["dispatched", "working", "evidence_in", "reviewing"].contains(status) }
    var needsSusu: Bool { (status == "draft" && approval == "ask_susu") || (status == "reviewing" && verdictKind == "unsure") }
    var isTerminal: Bool { ["approved", "rejected", "failed"].contains(status) }

    /// 目录/目标的可读短显示：/Users/susu/Desktop/susu-project/记忆宫殿/MemoryPalace → 记忆宫殿/MemoryPalace
    var targetDisplay: String {
        if targetRef.hasPrefix("/") {
            let parts = targetRef.split(separator: "/").map(String.init)
            return parts.suffix(2).joined(separator: "/")
        }
        return String(targetRef.prefix(12))
    }
}

struct WarroomRequest: Identifiable {
    let id: String        // request_id = epic 标签
    let text: String
    let status: String    // open | reviewing | closed
}

struct WarroomStats {
    var sessionsTotal = 0
    var sessionsAlive = 0
    var zombies = 0
    var totalCostUsd = 0.0
}

/// 一个显示分组：需求树 或 手工 epic 或 零散
private struct BoardGroup: Identifiable {
    let id: String
    let title: String          // 需求原文 / epic 名 / "零散奏折"
    let isRequest: Bool
    let tasks: [WarroomTask]
    var approved: Int { tasks.filter { $0.status == "approved" }.count }
    var terminal: Int { tasks.filter(\.isTerminal).count }
    var cost: Double { tasks.reduce(0) { $0 + $1.costUsd } }
    var tint: Color {
        if tasks.contains(where: \.isActive) { return .blue }
        if tasks.allSatisfy({ $0.status == "approved" }) && !tasks.isEmpty { return .green }
        if tasks.contains(where: { $0.status == "rejected" || $0.status == "failed" }) { return .orange }
        return .gray
    }
}

struct WarroomPanelView: View {
    @Environment(RightPanelNavigator.self) private var desktopNavigator: RightPanelNavigator?
    @State private var tasks: [WarroomTask] = []
    @State private var requests: [WarroomRequest] = []
    @State private var stats = WarroomStats()
    @State private var loading = true
    @State private var lastRefresh: Date? = nil
    @State private var expanded: String? = nil
    @State private var collapsedGroups: Set<String> = []
    @State private var showRequestSheet = false
    @State private var requestText = ""
    @State private var submittedRequestId: String? = nil
    @State private var sending = false
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statsBar
                    if loading && tasks.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 40)
                    } else if tasks.isEmpty {
                        VStack(spacing: 6) {
                            AppIconView(name: "ri-sword", size: 34, tint: Theme.textMuted)
                            Text("暂无奏折").font(.system(size: Theme.F.body)).foregroundColor(Theme.textMuted)
                        }.frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        needsSusuStrip
                        ForEach(groups) { g in groupCard(g) }
                    }
                }
                .padding(14)
                .padding(.bottom, 72)
            }
            requestFab
        }
        .toolPageBackground(Theme.mainBg)
        .refreshable { requestBoard() }
        .onAppear { requestBoard(); consumeDesktopTarget() }
        .onChange(of: desktopNavigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
        .onReceive(refreshTimer) { _ in requestBoard() }
        .onReceive(NotificationCenter.default.publisher(for: .warroomBoardUpdated)) { note in
            guard let obj = note.userInfo?["payload"] as? [String: Any] else { return }
            apply(obj)
        }
        .sheet(isPresented: $showRequestSheet) { requestSheet }
    }

    // MARK: - 分组（任务导向的核心）

    private var groups: [BoardGroup] {
        var out: [BoardGroup] = []
        var used = Set<String>()
        // 1. 需求树（她递的每句话是一棵树）
        for r in requests {
            let members = tasks.filter { $0.epic == r.id }
            guard !members.isEmpty else { continue }
            members.forEach { used.insert($0.id) }
            out.append(BoardGroup(id: r.id, title: r.text, isRequest: true, tasks: members.sorted { $0.id < $1.id }))
        }
        // 2. 手工 epic（我在终端派的带标签单）
        let manualEpics = Dictionary(grouping: tasks.filter { $0.epic != nil && !used.contains($0.id) }, by: { $0.epic! })
        for (epic, members) in manualEpics.sorted(by: { $0.key > $1.key }) {
            members.forEach { used.insert($0.id) }
            out.append(BoardGroup(id: "epic-\(epic)", title: epic, isRequest: false, tasks: members.sorted { $0.id < $1.id }))
        }
        // 3. 零散奏折
        let loose = tasks.filter { !used.contains($0.id) }
        if !loose.isEmpty {
            out.append(BoardGroup(id: "loose", title: "零散奏折", isRequest: false, tasks: loose.sorted { $0.id > $1.id }))
        }
        return out
    }

    /// 待御批浮顶条
    @ViewBuilder
    private var needsSusuStrip: some View {
        let pending = tasks.filter(\.needsSusu)
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.seal.fill").foregroundColor(.orange)
                    Text("待御批").font(.system(size: Theme.F.sectionHeader, weight: .bold)).foregroundColor(.orange)
                    Text("\(pending.count)").font(.system(size: Theme.F.badge, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule()).foregroundColor(.orange)
                }
                ForEach(pending) { t in taskRow(t) }
            }
            .padding(10)
            .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.6), lineWidth: 1))
        }
    }

    // MARK: - 组卡

    private func groupCard(_ g: BoardGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 组头：需求原文 + 进度 + 花费
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: g.isRequest ? "quote.opening" : (g.id == "loose" ? "tray" : "flag"))
                    .font(.system(size: Theme.F.body)).foregroundColor(g.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.title)
                        .font(.system(size: Theme.F.label, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(collapsedGroups.contains(g.id) ? 1 : 3)
                    HStack(spacing: 8) {
                        ProgressView(value: Double(g.approved), total: Double(max(g.tasks.count, 1)))
                            .tint(g.tint).frame(maxWidth: 90)
                        Text("\(g.approved)/\(g.tasks.count) 朱批")
                            .font(.system(size: Theme.F.caption)).foregroundColor(Theme.textSecondary)
                        if g.cost > 0 {
                            Text(String(format: "$%.2f", g.cost)).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                        Image(systemName: collapsedGroups.contains(g.id) ? "chevron.down" : "chevron.up")
                            .font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if collapsedGroups.contains(g.id) { collapsedGroups.remove(g.id) } else { collapsedGroups.insert(g.id) }
                }
            }
            if !collapsedGroups.contains(g.id) {
                ForEach(g.tasks.filter { !$0.needsSusu }) { t in taskRow(t) }
            }
        }
        .padding(10)
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(g.tint.opacity(0.45), lineWidth: 1))
    }

    // MARK: - 任务行（组内精简行，点开详情）

    private func taskRow(_ task: WarroomTask) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(task.id.replacingOccurrences(of: "zz-", with: ""))
                    .font(.system(size: Theme.F.caption, design: .monospaced)).foregroundColor(Theme.textMuted)
                if task.parentTask != nil {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: Theme.F.badge)).foregroundColor(.orange)
                }
                Text(task.title).font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary).lineLimit(1)
                Spacer()
                statusPill(task)
            }
            HStack(spacing: 8) {
                Label(task.targetDisplay, systemImage: task.targetKind == "repo" ? "folder" : (task.engine == "codex" ? "c.square" : "a.square"))
                    .font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted).lineLimit(1)
                if task.costUsd > 0 {
                    Text(String(format: "$%.2f", task.costUsd)).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                }
                if task.resumeId != nil {
                    Image(systemName: "terminal").font(.system(size: Theme.F.badge)).foregroundColor(Theme.textMuted)
                }
            }
            if expanded == task.id { detailBlock(task) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { expanded = expanded == task.id ? nil : task.id }
        }
        // 复制菜单：归档与否都能复制（repo 单复制它出生的新会话 id）
        .contextMenu {
            if let rid = task.resumeId {
                Button { Self.copyToClipboard(rid) } label: { Label("复制 session uuid", systemImage: "doc.on.doc") }
                Button { Self.copyToClipboard(task.engine == "codex" ? "codex resume \(rid)" : "claude --resume \(rid)") } label: {
                    Label("复制 resume 命令", systemImage: "terminal")
                }
            }
            Button { Self.copyToClipboard(task.targetRef) } label: { Label("复制目标（\(task.targetDisplay)）", systemImage: "folder") }
            Button { Self.copyToClipboard(task.id) } label: { Label("复制奏折号 \(task.id)", systemImage: "number") }
        }
    }

    @ViewBuilder
    private func detailBlock(_ task: WarroomTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                Text(task.targetRef).font(.system(size: Theme.F.caption, design: .monospaced))
                    .foregroundColor(Theme.textSecondary).textSelection(.enabled).lineLimit(2)
            }
            if let rid = task.resumeId {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                    Text(rid).font(.system(size: Theme.F.caption, design: .monospaced))
                        .foregroundColor(Theme.textSecondary).textSelection(.enabled).lineLimit(1)
                }
            }
            if let r = task.receiptSummary, !r.isEmpty {
                Text("执行者收据").font(.system(size: Theme.F.caption, weight: .semibold)).foregroundColor(Theme.textMuted)
                Text(r).font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textSecondary).textSelection(.enabled)
            }
            if let v = task.verdictText, !v.isEmpty {
                Text("验收官判决 · \(task.verdictKind ?? "")")
                    .font(.system(size: Theme.F.caption, weight: .semibold)).foregroundColor(Theme.textMuted)
                Text(v).font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textSecondary).textSelection(.enabled)
            }
            if let rw = task.reworkInstruction, !rw.isEmpty {
                Text("返工指令").font(.system(size: Theme.F.caption, weight: .semibold)).foregroundColor(.orange)
                Text(rw).font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textSecondary).textSelection(.enabled)
            }
        }
    }

    private func statusPill(_ task: WarroomTask) -> some View {
        let (label, color): (String, Color) = {
            if task.needsSusu { return ("待御批", .orange) }
            switch task.status {
            case "dispatched": return ("已派发", .blue)
            case "working": return ("施工中", .blue)
            case "evidence_in": return ("已交卷", .teal)
            case "reviewing": return ("验收中", .purple)
            case "approved": return ("已朱批", .green)
            case "rejected": return ("已驳回", .red)
            case "failed": return ("失败", Theme.danger)
            case "draft": return ("排队中", Theme.textMuted)
            default: return (task.status, Theme.textMuted)
            }
        }()
        return Text(label)
            .font(.system(size: Theme.F.badge, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundColor(color)
    }

    // MARK: - 统计条 / 数据

    private var statsBar: some View {
        // 右栏窄时胶囊会被一个字一行地压成竖排（09-24 mac 实拍）：放不下先去掉文字标签，再不行排两行
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                statChips(labels: true)
                Spacer(minLength: 0)
                if let t = lastRefresh {
                    Text(t, style: .time).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                }
            }
            HStack(spacing: 8) { statChips(labels: false) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                statChips(labels: false)
            }
        }
    }

    @ViewBuilder
    private func statChips(labels: Bool) -> some View {
        statChip("rectangle.stack", "\(stats.sessionsTotal)", labels ? "会话" : nil)
        statChip("bolt.fill", "\(stats.sessionsAlive)", labels ? "活着" : nil)
        statChip("moon.zzz", "\(stats.zombies)", labels ? "僵尸" : nil, warn: stats.zombies > 0)
        statChip("dollarsign.circle", String(format: "%.2f", stats.totalCostUsd), labels ? "总费" : nil)
    }

    private func statChip(_ icon: String, _ value: String, _ label: String?, warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: Theme.F.caption))
            Text(value).font(.system(size: Theme.F.secondary, weight: .semibold))
            if let label {
                Text(label).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundColor(warn ? .orange : Theme.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.sidebarBg, in: Capsule())
        .help(label ?? "")
    }

    private func requestBoard() {
        loading = tasks.isEmpty
        CCBridgeWebSocketClient.shared.send(["type": "warroom_board"]) { _ in }
    }

    private func consumeDesktopTarget() {
        guard let target = desktopNavigator?.pendingTarget, target.tool == "warroom" else { return }
        expanded = target.id
        if tasks.contains(where: { $0.id == target.id }) { desktopNavigator?.pendingTarget = nil }
    }

    private func apply(_ obj: [String: Any]) {
        loading = false
        lastRefresh = Date()
        if let arr = obj["tasks"] as? [[String: Any]] {
            tasks = arr.compactMap(WarroomTask.from)
            consumeDesktopTarget()
        }
        if let reqs = obj["requests"] as? [[String: Any]] {
            requests = reqs.compactMap { r in
                guard let id = r["request_id"] as? String, let text = r["text"] as? String else { return nil }
                return WarroomRequest(id: id, text: text, status: r["status"] as? String ?? "open")
            }
        }
        if let s = obj["stats"] as? [String: Any] {
            stats = WarroomStats(
                sessionsTotal: s["sessions_total"] as? Int ?? 0,
                sessionsAlive: s["sessions_alive"] as? Int ?? 0,
                zombies: s["zombies"] as? Int ?? 0,
                totalCostUsd: s["total_cost_usd"] as? Double ?? 0
            )
        }
    }

    // MARK: - M5 一句话派单

    private static let sage = Color(red: 0.61, green: 0.69, blue: 0.53)

    private var requestFab: some View {
        Button {
            requestText = ""; submittedRequestId = nil; showRequestSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 52, height: 52)
                .background(Self.sage, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 18).padding(.bottom, 18)
        .accessibilityLabel("递呈新需求")
    }

    private var requestSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("递呈需求").font(.system(size: Theme.F.sectionHeader, weight: .bold)).foregroundColor(Theme.textPrimary)
                Spacer()
                Button("关闭") { showRequestSheet = false }
                    .font(.system(size: Theme.F.body)).foregroundColor(Theme.textMuted)
            }
            if let rid = submittedRequestId {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundColor(Self.sage)
                    Text("已递呈 \(rid)").font(.system(size: Theme.F.label, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    Text("中枢正在拆解 roadmap，拆完会在聊天里回你。全部完工后有对账终审报告。")
                        .font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.top, 20)
            } else {
                Text("写下你要什么——中枢负责拆解、派发、验收、对账。")
                    .font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted)
                TextEditor(text: $requestText)
                    .font(.system(size: Theme.F.body))
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.sage.opacity(0.5), lineWidth: 1))
                Button {
                    submitRequest()
                } label: {
                    Text(sending ? "递呈中…" : "递呈军机处")
                        .font(.system(size: Theme.F.label, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Self.sage, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
            Spacer()
        }
        .padding(16)
        .toolPageBackground()
        .onReceive(NotificationCenter.default.publisher(for: .warroomRequestResult)) { note in
            sending = false
            guard let obj = note.userInfo?["payload"] as? [String: Any] else { return }
            if obj["ok"] as? Bool == true, let rid = obj["request_id"] as? String {
                submittedRequestId = rid
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func submitRequest() {
        let text = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        CCBridgeWebSocketClient.shared.send(["type": "warroom_request", "text": text]) { err in
            if err != nil { DispatchQueue.main.async { sending = false } }
        }
    }
}

extension Notification.Name {
    static let warroomBoardUpdated = Notification.Name("warroomBoardUpdated")
    static let warroomRequestResult = Notification.Name("warroomRequestResult")
}

extension WarroomPanelView {
    static func copyToClipboard(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}
#endif
