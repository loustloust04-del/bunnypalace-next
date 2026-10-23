import Foundation

/// 终端视图背后接的是谁（plan-terminal-t2 §2.1）：电脑上的 hub（tmux pane）还是手机里的小电脑（iSH guest PTY）。
/// `CCTerminalController` 只经这一层做 I/O，attach 状态机、resize 去抖、错误和草稿都留在 controller。
///
/// 回调契约：全部在主 actor；`onSent` 恰好一次；`events` 里的闭包可多次。
@MainActor
protocol TerminalBackend: AnyObject {
    /// 按键能不能送出去。hub = WS 连着；小电脑 = shell 在跑
    var isReachable: Bool { get }
    /// true = 字节流全经过本地 SwiftTerm，鼠标上报 / bracketed paste 以本地模拟器的状态为准
    var emulatorOwnsModes: Bool { get }

    func attach(cols: Int, rows: Int, openedAt: Date?, events: TerminalBackendEvents, onSent: @escaping (Bool) -> Void)
    func resize(cols: Int, rows: Int)
    func detach()
    func send(_ bytes: Data, completion: @escaping (Error?) -> Void)
    /// `bracketed`：本地 SwiftTerm 见到的 bracketed paste 模式（hub 只在老 hub 兜底时用它）
    func paste(_ text: String, bracketed: Bool, completion: @escaping (TerminalPasteOutcome) -> Void)
    /// 重拉画面
    func refresh()
    /// 手动重连前要做的事（hub：对话 Agent 幂等 spawn）
    func prepareReconnect()
}

struct TerminalBackendEvents {
    /// 一整屏快照（hub 的 terminal_init）。第二个参数是对面报的鼠标上报开没开，nil = 不知道
    var onInit: (Data, Bool?) -> Void
    var onChunk: (Data) -> Void
    var onError: (String) -> Void
    var onUsage: (TerminalUsage) -> Void
}

/// 电脑上的 hub：每个方法就是改造前 controller 里那一行 `CCBridgeWebSocketClient` 调用，不加逻辑。
@MainActor
final class HubTerminalBackend: TerminalBackend {
    let sessionName: String
    private var client: CCBridgeWebSocketClient { .shared }

    init(sessionName: String) {
        self.sessionName = sessionName
    }

    var isReachable: Bool { client.isConnected }
    var emulatorOwnsModes: Bool { false }

    func attach(cols: Int, rows: Int, openedAt: Date?, events: TerminalBackendEvents, onSent: @escaping (Bool) -> Void) {
        client.attachTerminal(
            session: sessionName,
            cols: cols,
            rows: rows,
            onInit: events.onInit,
            onChunk: events.onChunk,
            onError: events.onError,
            onUsage: events.onUsage,
            onSent: onSent,
            openedAt: openedAt
        )
    }

    func resize(cols: Int, rows: Int) {
        client.sendTerminalResize(session: sessionName, cols: cols, rows: rows)
    }

    func detach() {
        client.detachTerminal(session: sessionName)
    }

    func send(_ bytes: Data, completion: @escaping (Error?) -> Void) {
        client.sendTerminalInput(session: sessionName, bytes: bytes, completion: completion)
    }

    /// 包不包 ESC[200~ 交给 hub（tmux `paste-buffer -p` 按 pane 真实模式判）。客户端 SwiftTerm 的
    /// `bracketedPasteMode` 在 attach 后不可信：快照不带模式、init 时还 reset 过，Claude Code 只在
    /// 启动时开一次。还不知道 hub 认不认（nil）也先发 terminal_paste：老 hub 不认就超时报失败，
    /// 不会裸发逐行执行。init 明确说是老 hub → 按客户端见过的模式尽力包（zsh 每个提示符都重发
    /// 2004h，裸 shell 里是准的），再分片走 terminal_input；老 hub 不回包，只能算 `.submitted`。
    func paste(_ text: String, bracketed: Bool, completion: @escaping (TerminalPasteOutcome) -> Void) {
        switch Self.pasteRoute(hubSupportsPaste: client.hubSupportsTerminalPaste, bracketed: bracketed) {
        case .hubPaste:
            client.sendTerminalPaste(session: sessionName, text: text) {
                completion($0.map { TerminalPasteOutcome.failed($0) } ?? .delivered)
            }
        case .rawInput(let wrap):
            var data = Data(text.utf8)
            if wrap { data = Data("\u{1b}[200~".utf8) + data + Data("\u{1b}[201~".utf8) }
            client.sendTerminalInput(session: sessionName, bytes: data) {
                completion($0.map { TerminalPasteOutcome.failed("没发出去：\($0.localizedDescription)") } ?? .submitted)
            }
        }
    }

    enum PasteRoute: Equatable {
        case hubPaste
        case rawInput(wrap: Bool)
    }

    /// 只有 hub 明确说不认 terminal_paste（老 hub）才退回裸发
    nonisolated static func pasteRoute(hubSupportsPaste: Bool?, bracketed: Bool) -> PasteRoute {
        hubSupportsPaste != false ? .hubPaste : .rawInput(wrap: bracketed)
    }

    func refresh() {
        client.refreshTerminal(session: sessionName)
    }

    /// 幂等：session 已在 hub 会回 session_exists，忽略即可。全局窗口由 open_window 起，不走这条（这条会 spawn claude）
    func prepareReconnect() {
        if !sessionName.hasPrefix("mp-win-") {
            client.spawnSession(sessionName) { _ in }
        }
    }
}
