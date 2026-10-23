#if os(macOS)
import SwiftUI

/// 右栏「运行」（plan-离线沙箱-phase1 §1.7，学 otty 右栏）：正在跑的 `run_command` 进程 + 监听端口。
/// 只做 Process / Ports 两段；Working Directory 与会话统计后排。
struct RunPanelView: View {
    private let monitor = RunCommandMonitor.shared
    @State private var procs: [RunPanelSnapshot.Proc] = []
    @State private var ports: [RunPanelSnapshot.Port] = []

    var body: some View {
        let running = monitor.running
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Process") {
                    if running.isEmpty {
                        muted("没有在跑的命令")
                    } else {
                        ForEach(running) { cmd in
                            commandRow(cmd)
                        }
                    }
                }
                section("Ports") {
                    if ports.isEmpty {
                        muted("没有在监听的端口")
                    } else {
                        ForEach(ports) { p in
                            HStack(spacing: 8) {
                                Text(String(p.port))
                                    .font(.system(size: Theme.F.body, design: .monospaced))
                                    .foregroundColor(Theme.textPrimary)
                                Text("\(p.comm)  \(p.pid)")
                                    .font(.system(size: Theme.F.caption, design: .monospaced))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                    }
                }
                muted("这里只显示 AI 替你跑的命令")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 有命令在跑才轮询；面板不可见时 task 自动取消
        .task(id: running.map(\.id)) {
            await poll(pgids: Set(running.map(\.id)))
        }
    }

    private func poll(pgids: Set<pid_t>) async {
        guard !pgids.isEmpty else { procs = []; ports = []; return }
        while !Task.isCancelled {
            let snap = await Task.detached(priority: .utility) { RunPanelSnapshot.take(pgids: pgids) }.value
            if Task.isCancelled { return }
            procs = snap.procs
            ports = snap.ports
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    @ViewBuilder
    private func commandRow(_ cmd: RunningCommand) -> some View {
        let mine = procs.filter { $0.pgid == cmd.id }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Theme.branchIndicator).frame(width: 7, height: 7)
                Text("$ " + cmd.firstLine)
                    .font(.system(size: Theme.F.body, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(elapsed(since: cmd.startedAt))
                    .font(.system(size: Theme.F.caption, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                Button("停止") { RunCommandTool.cancel(conversationId: cmd.conversationId) }
                    .font(.system(size: Theme.F.caption))
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
            }
            ForEach(mine) { p in
                HStack(spacing: 8) {
                    Text(p.comm)
                        .font(.system(size: Theme.F.caption, design: .monospaced))
                        .foregroundColor(p.pid == cmd.id ? Theme.textSecondary : Theme.textMuted)
                    Text(String(p.pid))
                        .font(.system(size: Theme.F.caption, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Text(p.etime)
                        .font(.system(size: Theme.F.caption, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
                .padding(.leading, p.pid == cmd.id ? 15 : 27)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)   // 小灰字微标签学 Claude 官端用英文（粟粟点名的味道）
                .font(.system(size: Theme.F.caption, weight: .semibold))
                .foregroundColor(Theme.textMuted)
            content()
        }
    }

    private func muted(_ s: String) -> some View {
        Text(s).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
    }

    private func elapsed(since d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        return s >= 3600 ? String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
             : String(format: "%d:%02d", s / 60, s % 60)
    }
}
#endif
