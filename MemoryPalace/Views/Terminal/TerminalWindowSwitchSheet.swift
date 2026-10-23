#if os(iOS)
import SwiftUI

/// 窗口面板（tab 条的 [⧉] / 工具条的「切换窗口」键）：从底部升起，按三格分节（审计 T11 / T14 / T20）。
/// 点一行切过去；左滑收起 / 结束（结束二次确认）；长按改名；已收起的折叠成一组，点了恢复；最底一行账号用量。
///
/// 用原生 `.sheet` + detent：底部升起、grab handle、下滑关闭全是系统给的。
struct TerminalWindowSwitchSheet: View {
    let model: TerminalPanelModel
    let connected: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showClosed: Bool
    @State private var renaming: TerminalRenameRequest?
    @State private var ending: TerminalWindowInfo?
    @State private var endingLocal: String?
    @State private var showSandbox = false
    @State private var showConnect = false
    private var store: TerminalWindowStore { .shared }

    init(model: TerminalPanelModel, connected: Bool) {
        self.model = model
        self.connected = connected
        _showClosed = State(initialValue: model.panelExpandsClosed)
    }

    var body: some View {
        let items = model.tabItems
        VStack(spacing: 0) {
            header
            List {
                let agents = items.filter { $0.engine.cell == .agent }
                if !agents.isEmpty {
                    Section {
                        ForEach(agents) { agentRow($0) }
                    } header: { sectionHeader("Agent") }
                }
                Section {
                    ForEach(items.filter { $0.engine.cell == .computer }) { shellRow($0) }
                    closedGroup
                } header: { sectionHeader("我的电脑") }
                Section {
                    ForEach(items.filter { $0.engine.cell == .phone }) { localRow($0) }
                    row(selected: false) {
                        HStack(spacing: 8) {
                            TerminalCellChip(cell: .phone)
                            Text("新终端（离线）")
                            Spacer()
                        }
                    }
                    .onTapGesture { openLocal() }
                    row(selected: false) {
                        Text("小电脑状态…")
                            .foregroundColor(TerminalChrome.dim)
                    }
                    .onTapGesture { showSandbox = true }
                } header: { sectionHeader("手机里的小电脑") }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 40)
            usageFooter
        }
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationBackground(TerminalChrome.sheet)
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: Binding(get: { renaming?.text ?? "" }, set: { renaming?.text = $0 }))
            Button("取消", role: .cancel) {}
            Button("确定") { if let renaming { model.rename(renaming) } }
        }
        .confirmationDialog("结束这个窗口？", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                            titleVisibility: .visible, presenting: ending) { window in
            Button("结束", role: .destructive) { model.end(window) }
        } message: { _ in
            Text("里面跑的东西会被停掉，不能恢复。只想先放一边就用「收起」。")
        }
        .confirmationDialog("结束这个小电脑终端？", isPresented: Binding(get: { endingLocal != nil }, set: { if !$0 { endingLocal = nil } }),
                            titleVisibility: .visible, presenting: endingLocal) { id in
            Button("结束", role: .destructive) { model.endLocal(id) }
        } message: { _ in
            Text("里面跑的会停掉，文件还在。")
        }
        .sheet(isPresented: $showSandbox) {
            TerminalSandboxSheet {
                showSandbox = false
                openLocal()
            }
        }
        .sheet(isPresented: $showConnect) { TerminalConnectSheet() }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("窗口")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(TerminalChrome.ink)
            Spacer()
            TerminalNewWindowMenu(
                connected: connected,
                closedCount: store.closed.count,
                onOpen: { engine in
                    model.open(engine: engine)
                    dismiss()
                },
                onOpenLocal: openLocal,
                onSandbox: { showSandbox = true },
                onRestore: { showClosed = true },
                onConnect: { showConnect = true }
            ) {
                Image(systemName: "plus")
                    .font(.system(size: 17))
                    .foregroundColor(TerminalChrome.ink)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15))
                    .foregroundColor(TerminalChrome.ink)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.top, 14)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .kerning(0.5)
            .foregroundColor(TerminalChrome.dim)
    }

    // MARK: 行

    private func agentRow(_ item: TerminalTabItem) -> some View {
        let selected = model.current == item.target
        let usageLine = selected ? sessionUsageLine : nil
        return row(selected: selected) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    TerminalStatusDot(dot: item.dot)
                    Text(item.engine.displayName)
                    Spacer()
                    if let dot = item.dot {
                        Text(dot.statusText)
                            .fontWeight(dot == .waiting ? .semibold : .regular)
                            .foregroundColor(dot.color)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundColor(TerminalChrome.dim)
                Text(item.title)
                    .font(.system(size: 13.5))
                    .foregroundColor(TerminalChrome.ink)
                    .lineLimit(1)
                if let usageLine {
                    Text(usageLine)
                        .font(.system(size: 11.5))
                        .foregroundColor(TerminalChrome.dim)
                }
            }
            .padding(.vertical, 4)
        }
        .onTapGesture { choose(item.target) }
        .contextMenu { Button("改名…", systemImage: "pencil") { renaming = model.renameRequest(for: item) } }
        .modifier(WindowSwipeActions(window: item.window, onCollapse: { model.collapse($0.code) },
                                     onEnd: { ending = $0 }))
    }

    private func shellRow(_ item: TerminalTabItem) -> some View {
        row(selected: model.current == item.target) {
            HStack(spacing: 8) {
                TerminalStatusDot(dot: item.dot)
                Text(item.title)
                    .font(.system(size: 13.5))
                    .foregroundColor(TerminalChrome.ink)
                    .lineLimit(1)
                Spacer()
            }
        }
        .onTapGesture { choose(item.target) }
        .contextMenu { Button("改名…", systemImage: "pencil") { renaming = model.renameRequest(for: item) } }
        .modifier(WindowSwipeActions(window: item.window, onCollapse: { model.collapse($0.code) },
                                     onEnd: { ending = $0 }))
    }

    /// 小电脑的 shell：点切过去、左滑结束（没有收起，D1）、长按改名
    private func localRow(_ item: TerminalTabItem) -> some View {
        row(selected: model.current == item.target) {
            HStack(spacing: 8) {
                TerminalStatusDot(dot: item.dot)
                Text(item.title)
                    .font(.system(size: 13.5))
                    .foregroundColor(TerminalChrome.ink)
                    .lineLimit(1)
                Spacer()
                if item.dot == .dead {
                    Text("已退出")
                        .font(.system(size: 11.5))
                        .foregroundColor(TerminalChrome.dim)
                }
            }
        }
        .onTapGesture { choose(item.target) }
        .contextMenu { Button("改名…", systemImage: "pencil") { renaming = model.renameRequest(for: item) } }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if case .local(let id) = item.target {
                Button("结束") { endingLocal = id }
                    .tint(Palette.berry)
            }
        }
    }

    /// 开新的小电脑终端并收起面板，直接落到新 tab 上
    private func openLocal() {
        model.openLocal()
        dismiss()
    }

    @ViewBuilder
    private var closedGroup: some View {
        if !store.closed.isEmpty {
            DisclosureGroup(isExpanded: $showClosed) {
                ForEach(store.closed) { window in
                    row(selected: false) {
                        Text(closedLabel(window))
                            .font(.system(size: 13))
                            .foregroundColor(TerminalChrome.dim)
                            .lineLimit(1)
                    }
                    .onTapGesture {
                        model.restore(window.code)
                        dismiss()
                    }
                }
            } label: {
                Text("已收起 \(store.closed.count) 个")
                    .font(.system(size: 13.5))
                    .foregroundColor(TerminalChrome.faint)
            }
            .tint(TerminalChrome.dim)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func row<Content: View>(selected: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Palette.mint.opacity(0.12) : .clear)
                    .padding(.horizontal, 8)
            )
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 17, bottom: 0, trailing: 17))
    }

    // MARK: 底部用量

    /// 这一行是 Claude 账号的额度（rl.json），不是当前窗口自己的用量（审计 T23）：
    /// 只在当前停着的是 Claude 窗口时画，codex / shell / 首页不画
    @ViewBuilder
    private var usageFooter: some View {
        let usage = model.usage
        let currentEngine = model.tabItems.first { $0.target == model.current }?.engine
        if currentEngine == .claude, usage.fiveHour != nil || usage.sevenDay != nil {
            HStack(spacing: 8) {
                Text("Claude 额度")
                if let five = usage.fiveHour { meter(five) }
                if let seven = usage.sevenDay { meter(seven) }
                Spacer()
                Text([usage.fiveHour.map { "5h \($0)%" }, usage.sevenDay.map { "7d \($0)%" }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundColor(TerminalChrome.dim)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
        }
    }

    private func meter(_ percent: Int) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.09))
            .frame(width: 30, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Palette.usage(percent).opacity(0.7))
                    .frame(width: 30 * CGFloat(min(max(percent, 0), 100)) / 100)
            }
    }

    // MARK: 零件

    /// 当前 attach 的那个才有「模型 · ctx」（session 级用量只跟着当前窗口走）
    private var sessionUsageLine: String? {
        let parts = [model.usage.model, model.usage.ctx.map { "ctx \($0)%" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func closedLabel(_ window: TerminalWindowInfo) -> String {
        let engine = TerminalEngine.forWindow(reported: window.engine)
        let title = TerminalTitle.resolve(title: window.title, engine: engine.rawName, code: window.code)
        var parts = [title, engine.displayName]
        if let date = TerminalTimestamp.parse(window.closedAt) {
            parts.append("\(TerminalTimestamp.relative(date))收起的")
        }
        return parts.joined(separator: " · ")
    }

    private func choose(_ target: TerminalTarget) {
        model.select(target)
        dismiss()
    }

}

/// 左滑：收起 / 结束。只有全局窗口有（对话的 Agent 不是窗口，收不起来也不在这里结束）。
private struct WindowSwipeActions: ViewModifier {
    let window: TerminalWindowInfo?
    let onCollapse: (TerminalWindowInfo) -> Void
    let onEnd: (TerminalWindowInfo) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let window {
            content.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 不用 role: .destructive —— 那个会先把行动画删掉，取消确认时行就没了
                Button("结束") { onEnd(window) }
                    .tint(Palette.berry)
                Button("收起") { onCollapse(window) }
                    .tint(Palette.placeholder)
            }
        } else {
            content
        }
    }
}
#endif
