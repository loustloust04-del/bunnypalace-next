#if os(macOS)
import AppKit
import SwiftUI

/// 面板 tab 组里这个工具是不是在最前（没被切到后面、没折叠、没在飞）。`TabbedToolPanel` 的 mac 分支注入；浮窗等其它宿主默认 true
private struct FrontmostToolKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isFrontmostTool: Bool {
        get { self[FrontmostToolKey.self] }
        set { self[FrontmostToolKey.self] = newValue }
    }
}

/// 面板工具「终端」（plan-mp-local-terminal A4）：本机登录 shell，多 tab；空态两个入口；从访达拖文件夹进来 = 在那儿开新 tab，拖文件 = 往当前 tab
/// 粘带引号的路径。渲染沿 CC 终端那套底色，传输是本机 PTY——与 cc 桥无关
struct LocalTerminalPanelView: View {
    @Environment(\.isFrontmostTool) private var frontmost
    @State private var dropTargeted = false

    private var store: LocalTerminalStore { .shared }

    var body: some View {
        VStack(spacing: 0) {
            if !store.sessions.isEmpty {
                tabBar
                Rectangle().fill(ShellStyle.hairline).frame(height: ShellStyle.hairlineWidth)
            }
            if let session = store.selected {
                LocalTerminalHost(session: session, frontmost: frontmost)
                if case .exited(let code) = session.state { exitBar(session, code: code) }
            } else {
                emptyState
            }
        }
        .toolPageBackground(ShellStyle.background)
        .overlay { ShellDropHighlight(active: dropTargeted, radius: ShellStyle.panelRadius) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in Self.dropped(url) }
            }
            return true
        }
        .confirmationDialog(closeConfirmation?.title ?? "", isPresented: closingBinding, titleVisibility: .visible) {
            Button("关掉", role: .destructive) { if let id = store.pendingCloseID { store.close(id) } }
            Button("取消", role: .cancel) { store.pendingCloseID = nil }
        } message: {
            Text(closeConfirmation?.body ?? "")
        }
    }

    /// 关 tab 确认（R-I8 S2：状态在 store 里，挂在根上）
    private var closeConfirmation: LocalTerminalQuitPrompt.Text? {
        guard let id = store.pendingCloseID, let session = store.sessions.first(where: { $0.id == id }) else { return nil }
        return LocalTerminalQuitPrompt.closeTab(session.quitItem)
    }

    private var closingBinding: Binding<Bool> {
        Binding(get: { closeConfirmation != nil }, set: { if !$0 { store.pendingCloseID = nil } })
    }

    /// 目录 = 在那儿开新 tab；文件 = 往当前 tab 粘带引号的路径（Terminal.app 惯例），没有 tab 就在它所在目录开一个
    @MainActor
    private static func dropped(_ url: URL) {
        let store = LocalTerminalStore.shared
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            store.open(directory: url.path)
        } else if let session = store.selected, session.state == .running {
            session.type(CodingShellQuote.posix(url.path) + " ")
        } else {
            store.open(directory: url.deletingLastPathComponent().path)
        }
    }

    // MARK: - tab 条

    private var tabBar: some View {
        HStack(spacing: ShellStyle.controlGap) {
            ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
                HStack(spacing: ShellStyle.controlGap) {
                    ForEach(store.sessions) { tab($0) }
                }
            }
            Button { newTerminal() } label: { MacShellLabel(symbol: "plus") }
                .buttonStyle(MacShellButton(compact: true, width: ShellStyle.headerButtonWidth))
                .help("新终端")
            Button { openFolder() } label: { MacShellLabel(symbol: "folder") }
                .buttonStyle(MacShellButton(compact: true, width: ShellStyle.headerButtonWidth))
                .help("打开文件夹…")
        }
        .padding(.horizontal, 8)
        .frame(height: ShellStyle.barHeight)
    }

    private func tab(_ session: LocalTerminalSession) -> some View {
        let selected = session.id == store.selected?.id
        return HStack(spacing: 2) {
            Button {
                store.selectedID = session.id
            } label: {
                HStack(spacing: 6) {
                    badge(session)
                    Text(session.agent?.displayName ?? session.title)
                        .font(ShellStyle.bodyFont)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160)
                }
            }
            .buttonStyle(MacShellButton(selected: selected, compact: true))
            .help(session.directory)
            .contextMenu {
                // 阶段 B：这个 tab 跑的是哪条编程会话（「继续」带进来的，或它自己 argv 里续的那条）
                if let key = session.sessionKey {
                    Button("在编程会话里看") {
                        CodingSessionLibrary.shared.activate()
                        CodingSessionLibrary.shared.select(key)
                    }
                }
                Button("关掉") { store.requestClose(session.id) }
            }
            Button { store.requestClose(session.id) } label: {
                Image(systemName: "xmark")
                    .font(ShellStyle.microFont)
                    .foregroundColor(ShellStyle.mutedText)
            }
            .buttonStyle(.borderless)
            .frame(width: ShellStyle.closeButtonWidth)
            .help("关闭（结束里面的进程）")
        }
    }

    /// 前台是编程 agent：该家颜色点（处理中实心、等你外加一圈环、空闲空心）；已结束：灰点；普通 shell：不显示
    @ViewBuilder
    private func badge(_ session: LocalTerminalSession) -> some View {
        if let agent = session.agent {
            let color = CodingSessionFormat.color(agent)
            ZStack {
                Circle()
                    .fill(session.activity == .busy ? color : .clear)
                    .overlay(Circle().stroke(color, lineWidth: 1.2))
                    .frame(width: 7, height: 7)
                if session.activity == .awaiting {
                    Circle().stroke(color, lineWidth: 1).frame(width: 11, height: 11)
                }
            }
            .frame(width: 11, height: 11)
            .help(session.activity == .awaiting ? "\(agent.displayName) 在等你" : agent.displayName)
        } else if case .exited = session.state {
            Circle().fill(ShellStyle.mutedText.opacity(0.5)).frame(width: 7, height: 7)
        }
    }

    private func exitBar(_ session: LocalTerminalSession, code: Int32?) -> some View {
        HStack(spacing: 10) {
            Text(code.map { "进程已结束（退出码 \($0)）" } ?? "进程已结束")
                .font(ShellStyle.secondaryFont)
                .foregroundColor(ShellStyle.secondaryText)
            Spacer()
            Button("在这里重新打开") {
                let directory = session.directory
                store.close(session.id)
                store.open(directory: directory)
            }
            .buttonStyle(MacShellButton(compact: true))
        }
        .padding(.horizontal, 12)
        .frame(height: ShellStyle.barHeight)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(ShellStyle.mutedText)
            Text("在这台 Mac 上开终端：新终端从家目录开始，也可以打开任意文件夹，或把文件夹拖进来。")
                .font(ShellStyle.secondaryFont)
                .foregroundColor(ShellStyle.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            HStack(spacing: 8) {
                Button { newTerminal() } label: { MacShellLabel(symbol: "plus", title: "新终端") }
                    .buttonStyle(MacShellButton(compact: true))
                Button { openFolder() } label: { MacShellLabel(symbol: "folder", title: "打开文件夹…") }
                    .buttonStyle(MacShellButton(compact: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    private func newTerminal() {
        store.open(directory: store.selected?.directory)
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in LocalTerminalStore.shared.open(directory: url.path) }
        }
    }
}

/// 把 session 持有的终端 view 挂进一个新容器（R-MT I3）：每个宿主自己的容器；不在就挂，拆除时只摘归自己的——过渡期两个宿主同时活着，
/// view 也只在最新挂上的那一处。容器裁切、终端最小 240×120（R-MT I5：折叠压高不缩 NSView，TUI 不被 SIGWINCH 成 1 行）。
/// 焦点只在「挂上 / 换了 tab / 回到最前」这些转折处抢，退到后面时让出（R-MT I4：opacity 隐藏的终端仍是 first responder，会盲打进 shell）
private struct LocalTerminalHost: NSViewRepresentable {
    let session: LocalTerminalSession
    let frontmost: Bool

    final class Coordinator {
        var session: LocalTerminalSession?
        var wasFrontmost = false
    }

    final class ClipContainer: NSView {
        static let minimum = NSSize(width: 240, height: 120)
        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            for sub in subviews {
                sub.frame = NSRect(x: 0, y: 0, width: max(bounds.width, Self.minimum.width), height: max(bounds.height, Self.minimum.height))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = ClipContainer()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = session.view
        let coordinator = context.coordinator
        let switched = coordinator.session !== session
        coordinator.session = session
        var attached = false
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view)
            container.needsLayout = true
            attached = true
        }
        if frontmost {
            if attached || switched || !coordinator.wasFrontmost {
                DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            }
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
        coordinator.wasFrontmost = frontmost
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        guard let view = coordinator.session?.view, view.superview === container else { return }
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        view.removeFromSuperview()
    }
}
#endif
