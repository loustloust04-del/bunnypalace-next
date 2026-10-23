#if os(macOS)
import SwiftUI
import AppKit

/// 编程会话的动作菜单项：列表右键和标题卡共用（plan-mac-code-mode-gaps §2 / §3）。
/// 远程会话的路径不在本机：不给「在 Finder 中显示」，续跑换成现有的「复制 SSH 命令」
struct CodingSessionActionItems: View {
    let meta: CodingSessionMeta
    var onRename: (() -> Void)?
    var onError: (String) -> Void = { _ in }
    private var library: CodingSessionLibrary { .shared }

    var body: some View {
        if let onRename {
            Button("重命名…", action: onRename)
        }
        Button(library.state.isFavorite(meta.key) ? "取消收藏" : "收藏") { library.toggleFavorite(meta.key) }
        Button(library.state.isPinned(meta.key) ? "取消置顶" : "置顶") { library.togglePin(meta.key) }
        Divider()
        if !meta.projectPath.isEmpty {
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(meta.projectPath, forType: .string)
            }
            if meta.host.isEmpty {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: meta.projectPath)])
                }
            }
        }
        CodingSessionResumeItems(meta: meta, onError: onError)
    }
}

/// 续跑那一组：远程 = 复制 SSH 命令；本机正在跑 = 回到终端；否则「在终端继续 ›」，上次用的排第一
struct CodingSessionResumeItems: View {
    let meta: CodingSessionMeta
    var onError: (String) -> Void = { _ in }
    private var library: CodingSessionLibrary { .shared }

    var body: some View {
        if !meta.host.isEmpty {
            if CodingSessionResume.canResume(meta.agent) {
                Button("复制 SSH 命令") { report(library.copySSHCommand(meta)) }
            }
        } else if let live = LocalTerminalStore.shared.session(forKey: meta.key) {
            Button("回到终端") { LocalTerminalStore.shared.focus(live.id) }
        } else if let preferred = library.preferredTarget(for: meta.agent) {
            let others = CodingResumeTarget.installed(for: meta.agent).filter { $0 != preferred }
            Menu(CodingSessionResume.resumeLabel(meta.agent)) {
                Button("\(preferred.displayName)（上次用的）") { report(library.resume(meta, target: preferred)) }
                if !others.isEmpty { Divider() }
                ForEach(others, id: \.self) { target in
                    Button(target.displayName) { report(library.resume(meta, target: target)) }
                }
            }
        }
    }

    private func report(_ error: String?) {
        if let error { onError(error) }
    }
}
#endif
