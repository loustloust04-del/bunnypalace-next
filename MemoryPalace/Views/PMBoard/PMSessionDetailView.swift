#if PERSONAL_APPS
#if DEBUG
import SwiftUI

// MARK: - pmBoard session 详情（docs/plan-dev-subapp-v2.md §1 / §2.1，粟粟 10-03：只要三块）
// 头 + 进行中的（权限 / 问合 / 叫验，置顶）+ 滚动区：③ 想跟你说的话 · ② 恢复命令 · ① 最近 50 条消息；底部输入框永远都在。
// 发出去的话先交给 4793 收下排着，等它空了再打字；权限弹窗只显示、不代批，只有「在 Mac 上打开」。

struct PMSessionDetailView: View {
    let sid: String
    let back: () -> Void
    @State private var store = PMBoardStore.shared
    @State private var draft = ""
    @State private var attachment: String?
    @FocusState private var focused: Bool

    private var detail: PMDetail? { store.details[sid] }
    private var openLabel: String {
        #if os(macOS)
        "在 Otty 打开"
        #else
        "在 Mac 上打开"
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let live = detail?.asks.filter(\.live), !live.isEmpty { liveAsks(live) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let e = store.detailErrors[sid] { PMNotice(text: e) }
                    if let d = detail {
                        asks(d.asks.filter { !$0.live })
                        resume(d.resumeCmd)
                        PMConversationView(turns: d.turns, outbox: store.outbox(for: sid), seen: d.outbox.filter(\.seen), busy: d.person?.state == .busy)
                    } else if store.detailErrors[sid] == nil {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 40)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .refreshable { store.requestSession(sid) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .sheet(item: Binding(get: { attachment.map(PMAttachment.init) }, set: { attachment = $0?.name })) { a in
            VStack(spacing: 0) {
                HStack {
                    Text(a.title).font(.system(size: Theme.F.sectionHeader, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button("关闭") { attachment = nil }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                }
                .padding(14)
                PMDocView(name: a.name)
            }
            .background(Theme.mainBg)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
            #endif
        }
    }

    // MARK: 头

    private var header: some View {
        let p = detail?.person
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: back) {
                    HStack(spacing: 2) { Image(systemName: "chevron.left"); Text("pmBoard") }
                        .font(.system(size: Theme.F.body)).foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button(openLabel, systemImage: "macwindow") { store.openOnMac(sid) }
                    if let p {
                        Button(store.isPinned(p) ? "取消置顶" : "置顶", systemImage: store.isPinned(p) ? "pin.slash" : "pin") { store.togglePin(p) }
                    }
                    if let rc = detail?.resumeCmd, !rc.isEmpty {
                        Button("复制恢复命令", systemImage: "doc.on.doc") { PMClipboard.copy(rc) }
                    }
                    ForEach(p?.attachments ?? [], id: \.self) { name in
                        Button(PMAttachment(name: name).title, systemImage: "doc.richtext") { attachment = name }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(Theme.textSecondary)
                }
                .menuIndicator(.hidden)
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .fixedSize()
            }
            HStack(spacing: 6) {
                Circle().fill(p?.state.color ?? PMState.idle.color).frame(width: 9, height: 9)
                Text(p?.displayName ?? detail?.name ?? String(sid.prefix(8)))
                    .font(.system(size: Theme.F.sectionHeader + 2, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let sub = p?.subtitle { Text(sub).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(1) }
                Spacer(minLength: 0)
            }
            Text(p.map { "\($0.stateText) · \(([$0.rawName] + $0.zones).joined(separator: " · "))" } ?? (detail != nil ? "它没在跑" : ""))
                .font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(1)
            if let m = store.openMessage[sid] {
                Text(m).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }

    // MARK: 进行中的（置顶，玫瑰底）

    private func liveAsks(_ list: [PMAsk]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(list) { a in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: a.icon)
                    Text(a.text).font(.system(size: Theme.F.secondary, weight: .semibold)).lineLimit(3)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(PMState.wait.color)
            }
            if list.contains(where: { $0.kind == "permission" }) {
                HStack(spacing: 8) {
                    Text("手机上不代批。可以先写，弹窗处理完自动送。").font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 0)
                    Button(openLabel) { store.openOnMac(sid) }
                        .font(.system(size: Theme.F.caption, weight: .semibold)).buttonStyle(.bordered).tint(PMState.wait.color)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(PMState.wait.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14).padding(.bottom, 6)
    }

    // MARK: ③ 想跟你说的话

    @ViewBuilder
    private func asks(_ list: [PMAsk]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PMSectionTitle(text: "想跟你说的话", count: list.filter { !$0.answered }.count)
            if list.isEmpty {
                Text("最近 7 天没找你").font(.system(size: Theme.F.secondary)).foregroundStyle(Theme.textMuted)
            }
            ForEach(list) { a in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: a.icon).font(.system(size: Theme.F.caption))
                    Text(a.text).font(.system(size: Theme.F.secondary)).lineLimit(3).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Text(a.answered ? "已回" : PMTime.ago(a.at)).font(.system(size: Theme.F.badge, design: .serif)).fixedSize()
                }
                .foregroundStyle(a.answered ? Theme.textMuted : Theme.textPrimary)
                .opacity(a.answered ? 0.7 : 1)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: ② 恢复命令

    private func resume(_ cmd: String) -> some View {
        HStack(spacing: 8) {
            Text(cmd.isEmpty ? "—" : cmd).font(.system(size: Theme.F.caption, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .lineLimit(2).truncationMode(.head).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("复制") { PMClipboard.copy(cmd) }
                .font(.system(size: Theme.F.caption, weight: .semibold)).buttonStyle(.bordered).tint(PMState.busy.color)
                .disabled(cmd.isEmpty)
        }
        .padding(10)
        .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 输入框（永远都在；canSend 只决定提示）

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(hint, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.F.body))
                .focused($focused)
                .tint(Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 18))
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                    .foregroundStyle(canSubmit ? PMState.busy.color : Theme.textMuted.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.mainBg)
    }

    private var hint: String {
        guard let cs = detail?.canSend else { return "跟它说…" }
        if cs.ok { return cs.busy == true ? "它在忙，发了排在这一轮后面" : "跟它说…" }
        return "可以先写：\(cs.why)（收下后等它空了自动送）"
    }

    private var canSubmit: Bool {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= 4000
    }

    private func submit() {
        guard canSubmit else { return }
        store.send(draft, to: sid)
        draft = ""
    }
}

/// 角色挂的文档（roles.json attachments，Herald → plan-open-source）：详情 ⋯ 里打开
struct PMAttachment: Identifiable {
    let name: String
    var id: String { name }
    var title: String { name == "plan-open-source" ? "开源路线图" : name }
}

// MARK: - ① 最近 50 条（只有文字）+ 还没进对话的手机消息

struct PMConversationView: View {
    let turns: [PMTurn]
    let outbox: [PMOutItem]
    let seen: [PMOutItem]
    let busy: Bool
    @State private var store = PMBoardStore.shared
    @AppStorage("userName") private var userName = "你"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PMSectionTitle(text: "最近 50 条", count: nil)
            if turns.isEmpty && outbox.isEmpty {
                Text("还没有对话").font(.system(size: Theme.F.secondary)).foregroundStyle(Theme.textMuted)
            }
            ForEach(Array(turns.enumerated()), id: \.offset) { _, t in bubble(t) }
            ForEach(outbox) { item in pending(item) }
            if busy {
                HStack { TypingDotsView(); Spacer(minLength: 60) }
            }
        }
    }

    private static func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    @ViewBuilder
    private func bubble(_ t: PMTurn) -> some View {
        if t.who == "susu" {
            let mine = t.via == "phone" && seen.contains { Self.squash($0.text) == Self.squash(t.text) }
            userBubble(t.text, label: t.via == "phone" ? "\(userName) · 手机" : nil, status: mine ? "✓ 已送 · 它看到了" : nil)
        } else {
            let upper = t.who == "upper"
            VStack(alignment: .leading, spacing: 2) {
                if upper { Text(t.name ?? "上级").font(.system(size: Theme.F.badge, weight: .semibold)).foregroundStyle(PMState.external.color) }
                Text(t.text).font(.system(size: Theme.F.body)).foregroundStyle(Theme.assistantText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(BubbleTailShape(isUser: false, radius: 14).fill(upper ? PMState.external.color.opacity(0.12) : Theme.assistantBubble))
                    .textSelection(.enabled)
            }
            .padding(.trailing, 40)
        }
    }

    private func userBubble(_ text: String, label: String?, status: String?, statusColor: Color = Theme.textMuted) -> some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 2) {
                if let label { Text(label).font(.system(size: Theme.F.badge)).foregroundStyle(Theme.textMuted) }
                Text(text).font(.system(size: Theme.F.body)).foregroundStyle(Theme.userText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(BubbleTailShape(isUser: true, radius: 14).fill(Theme.userBubble))
                    .textSelection(.enabled)
                if let status { Text(status).font(.system(size: Theme.F.badge)).foregroundStyle(statusColor).multilineTextAlignment(.trailing) }
            }
        }
    }

    /// 还没在对话里出现的那条：气泡下面一行状态 + 能做的动作
    private func pending(_ item: PMOutItem) -> some View {
        let (status, color) = Self.status(item)
        return VStack(alignment: .trailing, spacing: 4) {
            userBubble(item.text, label: item.prefix.map { "pmBoard 替你送 · \($0)" } ?? "\(userName) · 手机", status: status, statusColor: color)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                switch item.state {
                case "queued", "queued-busy":
                    Button("撤回") { store.cancel(item) }
                case "stuck":
                    Button("补按回车") { store.retry(item, how: "enter") }
                    Button("清掉重发") { store.retry(item, how: "redo") }
                case "failed":
                    Button("重发") { store.resend(item) }
                    Button("不发了") { store.dropLocal(item) }
                default:
                    EmptyView()
                }
            }
            .font(.system(size: Theme.F.caption, weight: .semibold))
            .buttonStyle(.bordered)
            .tint(Theme.textSecondary)
        }
    }

    private static func status(_ i: PMOutItem) -> (String, Color) {
        let why = i.why.isEmpty ? "" : " · \(i.why)"
        switch i.state {
        case "sending": return ("… 正在交给 Mac", Theme.textMuted)
        case "typing": return ("… 正在打进去", Theme.textMuted)
        case "sent": return ("✓ 已送\(why)", PMState.busy.color)
        case "queued", "queued-busy": return ("⏳ 排着\(why)\(i.stale ? " · 已经排了很久" : "")", i.stale ? PMState.wait.color : Theme.textMuted)
        case "stuck": return ("⚠ 字在它输入框里没提交\(why)", PMState.wait.color)
        case "expired": return ("过期了，没送出去\(why)", PMState.wait.color)
        case "failed": return ("没交到 Mac\(why)", PMState.wait.color)
        default: return (i.state, Theme.textMuted)
        }
    }
}
#endif
#endif
