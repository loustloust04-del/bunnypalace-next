#if os(macOS)
import AppKit
import SwiftUI

/// 菜单栏快看（research-magpie §2.6，照 magpie 的菜单栏 panel）：运行中 / 等你回答的 Code 会话、各家额度条、「新建对话」。
/// 宽 340，高度随内容。点会话 / 新建都会先把主窗拉到前面。设置 › 工作区「在菜单栏显示」控制有没有它
struct MacMenuBarQuickLook: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recent: [CodingSessionMeta] = []

    private var terminal: LocalTerminalStore { .shared }

    var body: some View {
        let rows = MacMenuBarSessionRow.build(terminal: terminal.sessions, recent: recent)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Code 会话")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button("打开记忆花园") {
                    dismiss()
                    MacMainWindow.activate()
                }
                .buttonStyle(.link)
                .font(.system(size: Theme.F.caption))
            }
            if rows.isEmpty {
                Text("现在没有在跑的会话")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            } else {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        MacMenuBarSessionButton(row: row) {
                            dismiss()
                            open(row)
                        }
                    }
                }
            }
            Divider()
            Text("订阅额度")
                .font(.system(size: Theme.F.caption, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            SubscriptionQuotaCard(compact: true)
            Divider()
            Button {
                dismiss()
                newConversation()
            } label: {
                Label("新建对话", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.branchIndicator)
            .controlSize(.regular)
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // 面板开着时：终端徽章 1 Hz 自己刷；外部终端里跑的靠索引「最近 3 分钟有写入」，这里 5 s 看一眼
            while !Task.isCancelled {
                terminal.refreshBadges()
                recent = CodingSessionLibrary.shared.recentlyActive(now: Date(), within: 180)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func open(_ row: MacMenuBarSessionRow) {
        let reopened = MacMainWindow.activate()
        let go = {
            if let key = row.sessionKey, CodingSessionLibrary.shared.openSession(key: key) {
                if let terminalID = row.terminalID { LocalTerminalStore.shared.focus(terminalID) }
            } else if let terminalID = row.terminalID {
                LocalTerminalStore.shared.focus(terminalID)
            }
        }
        // 主窗刚被重新拉起时它的视图树还没挂上：等一拍再路由，别让通知落空
        if reopened { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: go) } else { go() }
    }

    /// 复用 ⌘N 的路由（`.newConversationRequested`）；停在 Code 组时先回对话组，不然新草稿被 Code 详情盖着
    private func newConversation() {
        let reopened = MacMainWindow.activate()
        let go = {
            CodingSessionLibrary.shared.deactivate()
            NotificationCenter.default.post(name: .newConversationRequested, object: nil)
        }
        if reopened { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: go) } else { go() }
    }
}

/// 快看里的一行会话：本 app 终端 tab 里跑着的（有活动状态）+ 索引里最近几分钟有写入的（外部终端里跑的）
struct MacMenuBarSessionRow: Identifiable, Equatable {
    enum Phase: Int, Comparable {
        case awaiting = 0
        case running = 1
        case idle = 2

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .awaiting: return "等你回答"
            case .running: return "运行中"
            case .idle: return "空闲"
            }
        }
    }

    var id: String
    var title: String
    var subtitle: String
    var agent: CodingAgent?
    var phase: Phase
    var sessionKey: String?
    var terminalID: UUID?

    @MainActor
    static func build(terminal: [LocalTerminalSession], recent: [CodingSessionMeta]) -> [MacMenuBarSessionRow] {
        var rows: [MacMenuBarSessionRow] = []
        var keys = Set<String>()
        for session in terminal where session.agent != nil && session.quitItem.isRunning {
            let phase: Phase = switch session.activity {
            case .awaiting: .awaiting
            case .busy: .running
            case .idle: .idle
            }
            let key = session.sessionKey
            if let key { keys.insert(key) }
            rows.append(.init(id: "term:" + session.id.uuidString, title: session.title,
                              subtitle: "终端 · " + (session.directory as NSString).lastPathComponent,
                              agent: session.agent, phase: phase, sessionKey: key, terminalID: session.id))
        }
        for meta in recent where !keys.contains(meta.key) {
            rows.append(.init(id: "meta:" + meta.key, title: meta.title.isEmpty ? meta.projectName : meta.title,
                              subtitle: meta.projectName, agent: meta.agent, phase: .running,
                              sessionKey: meta.key, terminalID: nil))
        }
        // 等你回答的排最前；同档保持原顺序（终端 tab 顺序 / 索引新到旧）
        return rows.enumerated().sorted { ($0.element.phase, $0.offset) < ($1.element.phase, $1.offset) }.map(\.element)
    }
}

private struct MacMenuBarSessionButton: View {
    let row: MacMenuBarSessionRow
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                let color = row.agent.map(CodingSessionFormat.color) ?? Theme.textMuted
                ZStack {
                    Circle()
                        .fill(row.phase == .idle ? .clear : color)
                        .overlay(Circle().stroke(color, lineWidth: 1.2))
                        .frame(width: 7, height: 7)
                    if row.phase == .awaiting {
                        Circle().stroke(color, lineWidth: 1).frame(width: 11, height: 11)
                    }
                }
                .frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.system(size: Theme.F.caption, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text([row.agent?.displayName, row.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: Theme.F.caption - 2))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(row.phase.label)
                    .font(.system(size: Theme.F.caption - 2, weight: row.phase == .awaiting ? .semibold : .regular))
                    .foregroundColor(row.phase == .awaiting ? .orange : Theme.textMuted)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.textPrimary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// 主窗（WindowGroup 那扇）。`WindowConfigurator` 配窗时登记；关掉后弱引用落空 → 发一次「重新打开」让 SwiftUI 新开一扇
@MainActor
enum MacMainWindow {
    private static weak var window: NSWindow?

    static func register(_ window: NSWindow) { self.window = window }

    /// 拉到前面。返回 true = 主窗原本不在、刚请求重开（调用方晚一拍再路由）
    @discardableResult
    static func activate() -> Bool {
        NSApp.activate()
        if let window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return false
        }
        // app 已在跑时 LaunchServices 发的是 reopen 事件：SwiftUI 的 WindowGroup 没窗时会新开一扇（等同点 Dock 图标）
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        return true
    }
}
#endif
