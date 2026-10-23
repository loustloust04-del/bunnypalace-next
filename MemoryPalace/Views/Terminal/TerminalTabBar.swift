#if os(iOS)
import SwiftUI

/// 终端页顶部那条 44pt 的胶囊 tab 条（rootshell Pills，照 design-terminal-rootshell-style.html）。
/// 左边：⌂ 首页 → 这条对话的 Agent（只有 Agent 对话才有）→ 开着的窗口，横滑、选中自动居中。
/// 右边常驻：[+]（轻点出按三格分组的菜单）和 [⧉]（窗口面板）。
struct TerminalTabBar: View {
    let model: TerminalPanelModel
    let connected: Bool

    var body: some View {
        let items = model.tabItems
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        homeChip.id(TerminalTarget.home)
                        ForEach(items) { item in
                            tab(item).id(item.target)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .mask(
                    LinearGradient(stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .onAppear { proxy.scrollTo(model.current, anchor: .center) }
                .onChange(of: model.current) { _, target in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
                }
            }

            TerminalNewWindowMenu(
                connected: connected,
                closedCount: TerminalWindowStore.shared.closed.count,
                onOpen: { model.open(engine: $0) },
                onOpenLocal: { model.openLocal() },
                onSandbox: { model.showSandbox = true },
                onRestore: {
                    model.panelExpandsClosed = true
                    model.showWindowPanel = true
                },
                onConnect: { model.showConnect = true }
            ) {
                Image(systemName: "plus")
                    .font(.system(size: 16))
                    .foregroundColor(TerminalChrome.ink)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }

            Button {
                model.panelExpandsClosed = false
                model.showWindowPanel = true
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 15))
                    .foregroundColor(TerminalChrome.ink)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(height: 44)
    }

    private var homeChip: some View {
        let selected = model.current == .home
        return Image(systemName: "house")
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundColor(selected ? TerminalChrome.ink : TerminalChrome.dim)
            .frame(width: 38, height: 28)
            .background(Capsule().fill(selected ? TerminalChrome.selected : .clear))
            .contentShape(Capsule())
            // 横滚里用 Button 会被滚动手势吞，一律 onTapGesture
            .onTapGesture { model.select(.home) }
    }

    private func tab(_ item: TerminalTabItem) -> some View {
        let selected = model.current == item.target
        return HStack(spacing: 5) {
            if selected, let window = item.window {
                closeMark { model.collapse(window.code) }
            } else if selected, case .local(let id) = item.target {
                // 小电脑没有「收起」：✕ = 结束，二次确认（D1）
                closeMark { model.endingLocal = id }
            }
            TerminalStatusDot(dot: item.dot)
            TerminalCellChip(cell: item.engine.cell)
            Text(item.title)
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundColor(selected ? TerminalChrome.ink : TerminalChrome.dim)
        .padding(.horizontal, 10)
        .frame(width: 140, height: 28)
        .background(Capsule().fill(selected ? TerminalChrome.selected : .clear))
        .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0.12 : 0), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture { model.select(item.target) }
        .contextMenu {
            // builder 渲染时就会求值，只放便宜操作
            Button("改名…", systemImage: "pencil") { model.renaming = model.renameRequest(for: item) }
            Button("重新绘制画面", systemImage: "arrow.clockwise") { model.refresh(item.target) }
            if let window = item.window {
                Button("收起", systemImage: "chevron.down.square") { model.collapse(window.code) }
                Button("结束…", systemImage: "xmark.octagon", role: .destructive) { model.ending = window }
            } else if case .local(let id) = item.target {
                Button("结束…", systemImage: "xmark.octagon", role: .destructive) { model.endingLocal = id }
            }
        }
    }

    private func closeMark(_ action: @escaping () -> Void) -> some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(TerminalChrome.ink.opacity(0.75))
            .frame(width: 16, height: 28)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// `[+]` 菜单：按三格分组（plan-terminal-three-cells §3）。没连上电脑时 ②③ 两组置灰，底下给「连接我的电脑…」。
/// 电脑上没装 claude / codex（hello 帧明说 false）时那一项置灰 + 小字「电脑上还没装」（#046）；不知道（nil / 老 hub）不拦。
/// ⌘T 没法程序化弹出 SwiftUI Menu，所以快捷键直接开新 shell（plan 刀 1 注明）。
struct TerminalNewWindowMenu<Label: View>: View {
    let connected: Bool
    let closedCount: Int
    /// 当前连接这台电脑的工具探测（`currentHubInfo?.tools`）；nil = 不知道
    var tools: HubHello.Tools? = CCBridgeWebSocketClient.shared.currentHubInfo?.tools
    let onOpen: (String?) -> Void
    /// 新终端（离线）：手机里的小电脑（#045 T2）
    let onOpenLocal: () -> Void
    let onSandbox: () -> Void
    let onRestore: () -> Void
    let onConnect: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Section("手机里的小电脑") {
                Button("新终端（离线）", systemImage: "iphone") { onOpenLocal() }
                Button("小电脑状态…", systemImage: "info.circle") { onSandbox() }
            }
            Section("我的电脑") {
                Button("新 shell", systemImage: "terminal") { onOpen(nil) }
                    .disabled(!connected)
                Button("恢复收起的窗口…（\(closedCount)）", systemImage: "arrow.uturn.backward") { onRestore() }
                    .disabled(!connected || closedCount == 0)
            }
            Section("Agent") {
                agentButton("新 Claude Code", systemImage: "sparkle", engine: "claude", missing: tools?.claude == false)
                agentButton("新 Codex", systemImage: "chevron.left.forwardslash.chevron.right", engine: "codex",
                            missing: tools?.codex == false)
            }
            if !connected {
                Section {
                    Button("连接我的电脑…", systemImage: "link") { onConnect() }
                }
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)
    }

    @ViewBuilder
    private func agentButton(_ title: String, systemImage: String, engine: String, missing: Bool) -> some View {
        Button { onOpen(engine) } label: {
            SwiftUI.Label(title, systemImage: systemImage)
            if missing { Text("电脑上还没装") }
        }
        .disabled(!connected || missing)
    }
}

/// 「连接我的电脑」：进「我的电脑」页（配对 / 连接状态 / 干活目录，#046），不再塞整个 Claude Code 设置
struct TerminalConnectSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MyComputerSettingsPage()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}

/// 「小电脑状态…」：复用设置根那个 `SandboxSettingsTab`。从终端进来不露红色重置（T41），
/// 「打开终端」由调用方负责关掉自己这层（和外面的窗口面板）再开新终端
struct TerminalSandboxSheet: View {
    let onOpenTerminal: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SandboxSettingsTab(onOpenTerminal: onOpenTerminal, showsReset: false)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}
#endif
