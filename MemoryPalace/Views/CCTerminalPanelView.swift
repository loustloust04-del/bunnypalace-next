import SwiftUI
import SwiftTerm
import Combine

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// cc-bridge L4：右页 "CC 终端" tool 的主 view。
///
/// 用 SwiftTerm.TerminalView（iOS UIView / macOS NSView）嵌入到 SwiftUI，
/// 通过 CCBridgeWebSocketClient 的 terminal API 跟 hub 双向 stream tmux pane 字节流：
/// - attach 时 hub 发 terminal_init（capture-pane snapshot，含 ANSI）→ feed 给 SwiftTerm
/// - 之后 terminal_chunk 增量 → feed
/// - 用户键盘 / 工具栏按钮 → delegate send(data:) → wsClient.sendTerminalInput
/// - viewport 变化 → delegate sizeChanged → wsClient.sendTerminalResize → tmux resize-window
///
/// 切 conversation 或 conversation 的 ccBridgeSessionName 改变时，CCTerminalPanelView 用
/// `.id(sessionName)` 强制 re-init controller + 重新 attach。

/// 顶卡用量。hub 每 30s（以及 attach 时立刻）经 `terminal_usage` 帧下发。
/// 全 nil = 还没收到 / 读不到 → 顶卡显示灰 `--`，不是 0。
/// 跨平台声明（macOS 不显示顶卡但 WS client 是共用的）。
struct TerminalUsage: Equatable {
    var model: String?
    var ctx: Int?
    var fiveHour: Int?
    var sevenDay: Int?

    static let empty = TerminalUsage()
}

/// 终端页的滚动/点击语义。**判据是「窗口里的程序开没开鼠标上报」，不是「这个 session 叫什么」**。
///
/// 为什么要换轨（plan §A1 顺手条）：老判据按 `mp-win-` 前缀分「CC 会话 / 裸 shell」，
/// 一旦在裸 shell 里 `ssh` 进另一台机器的 CC、或者开 vim，前缀还是 mp-win- 但对面已经开了
/// 鼠标上报 —— 滚动被判成「本地滚」，SGR 序列不发，对面翻不动。反过来 CC 窗口里退出 CC 回到
/// shell，前缀说该转发，`65;1;1M` 就打进命令行了（滚炸案）。tmux 的 `#{mouse_any_flag}` 是
/// 这件事唯一诚实的真相源，hub 在 `terminal_init` 里带下来。
enum TerminalMouseMode: Equatable {
    /// 开了鼠标上报（CC / codex / vim…）：垂直拖动转 SGR 滚轮发给对面；点击只有底部输入区才弹键盘
    case forwarding
    /// 没开鼠标上报（裸 shell）：SwiftTerm 本地滚 scrollback，一个字节都不发；整块都可点
    case local

    /// `mouseAny` 三态：true/false = hub 说了算；**nil = 老 hub 没发这个字段**，退回按 session
    /// 前缀判的老规则。
    ///
    /// ⚠️ nil 分支是滚炸案（`65;1;1M` 刷屏）的唯一防线，hub 升级前一个字都不能省。
    /// 何时可删：cc-bridge hub 全量发 `terminal_init.mouse_any` 之后（本批 A1 落地 + 粟粟机器上
    /// 的 hub 实际升级过），这个 fallback 连同 `hasPrefix("mp-win-")` 一起删掉。
    static func resolve(mouseAny: Bool?, sessionName: String) -> TerminalMouseMode {
        if let mouseAny { return mouseAny ? .forwarding : .local }
        return sessionName.hasPrefix("mp-win-") ? .local : .forwarding
    }
}

@MainActor
final class CCTerminalController: ObservableObject {
    let sessionName: String
    /// I/O 走谁：电脑上的 hub（缺省）或手机里的小电脑（plan-terminal-t2 §2.1）
    let backend: any TerminalBackend
    @Published var error: String?
    /// nil 时顶卡对应格子不画（排 2 全空整排收起）
    @Published var usage: TerminalUsage = .empty
    /// hub 在 `terminal_init` 里报的 tmux `#{mouse_any_flag}`。nil = 还没 attach 成功 / 老 hub 没发。
    @Published var mouseAny: Bool?
    /// 收到过 `terminal_init` = 画面真出来了。之后的重 attach / 重订阅不再翻它
    @Published private(set) var hasShownSnapshot = false
    /// makeUIView/makeNSView 后由 Coordinator 设置，attach 时拿来 feed bytes
    weak var terminalView: TerminalView?
    /// 断线时按了键：终端底部浮一行「没连上，打的字不会发出去」（审计 T08），3 秒后自己收
    @Published private(set) var showsOfflineInputHint = false
    /// SwiftTerm 首次 layout 完成 + 首次 sizeChanged fire 后才 attach
    /// （否则 hub 用默认 80x24 capture，跟 iPhone 真实 viewport 不匹配 → 字符叠字符）
    /// 只在 attach 真交给 WS 后才锁（T06）：没连上那次发不出去，2s 兜底 / 下一次 sizeChanged 还能再发
    private var hasAttached = false
    /// attach 已发、还没回执（交没交给 WS）。期间来的尺寸记进 pendingSize，锁上后补一次 resize
    private var attachInFlight = false
    private var pendingSize: (cols: Int, rows: Int)?
    /// resize debounce：键盘弹起动画逐帧改 bounds → sizeChanged 连发 8+ 次（探针实测
    /// boundsH 722→412），每次都打一个 hub/tmux/CC resize 往返 = 「很卡」。合并成只发最后一次。
    private var resizeWork: DispatchWorkItem?
    /// 最近一次真实 viewport 尺寸。手动重连时用它重 attach（别退回 80x24 让 hub 拿错 pane size 截图）。
    private var lastSize: (cols: Int, rows: Int) = (80, 24)
    /// 她按 ⌄ 主动收过键盘。**session 级内存，不落盘**（rootshell 的 hide intent 同为 session 级，
    /// 报告 §8.5）。用途：自动重聚焦路径（如 Compose overlay 关闭把焦点还给终端）看到它就不弹键盘，
    /// 免得「刚收下去又自己弹回来」。点终端聚焦时清掉。
    var keyboardHideIntent = false
    /// Compose 草稿。**关掉不清**（物料表 §4.2），下次打开接着写；Send 之后才清。
    var composeDraft = ""

    /// 终端出字账本：这次「打开」的时刻，随下一次 attach 交给 WS client 计时，用一次就清。
    /// 首次 = controller 建出来（sizeChanged 可能早于 onAppear）；离开再进由 onAppear 重记
    private var openedAt: Date? = Date()

    init(sessionName: String, backend: (any TerminalBackend)? = nil) {
        self.sessionName = sessionName
        self.backend = backend ?? HubTerminalBackend(sessionName: sessionName)
    }

    func noteOpened() {
        guard !hasAttached else { return }
        openedAt = Date()
    }

    /// 由 Coordinator.sizeChanged 调用 — SwiftTerm 第一次给出真实 cols/rows 时 attach；
    /// 之后再次 fire 只 sendResize 同步 tmux pane size（debounce 合并连发）
    func attachOrResize(cols: Int, rows: Int) {
        lastSize = (cols, rows)
        if hasAttached {
            resizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.backend.resize(cols: cols, rows: rows)
            }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        if attachInFlight {
            pendingSize = (cols, rows)
            return
        }
        attachIfNotYet(cols: cols, rows: rows)
    }

    /// 仅在没 attach 过时执行 attach（onAppear 2s 兜底用，防 sizeChanged 没 fire 黑屏）
    func attachIfNotYet(cols: Int, rows: Int) {
        guard !hasAttached, !attachInFlight else { return }
        attachInFlight = true
        let openedAt = self.openedAt
        self.openedAt = nil
        let events = TerminalBackendEvents(
            onInit: { [weak self] data, mouseAny in
                self?.mouseAny = mouseAny
                if self?.hasShownSnapshot == false { self?.hasShownSnapshot = true }
                // 快照到了 = attach 已经活了（可能是 didOpen 补订阅发的那次），之后的尺寸变化走 resize
                self?.hasAttached = true
                // 快照到货 = attach 真的成活了 → 清掉上一次的 attach 错误，排 1 的 OFFLINE 才退场
                self?.error = nil
                guard let tv = self?.terminalView else { return }
                // API 级完整复位。曾用 feed(ESC c)——那走 parser 的 cmdReset，复位不彻底
                // （06-02「字符越叠越多」根因：反复 feed 快照层层叠加），resize 后的快照
                // 愈合因此被砍 → 键盘弹起窗口期的尺寸错位残留（字/光标飘出输入框）。
                // resetToInitialState 彻底复位后，hub 恢复 resize 后重发快照，错位自愈。
                tv.getTerminal().resetToInitialState()
                let arr = Array(data)
                tv.feed(byteArray: arr[...])
            },
            onChunk: { [weak self] data in
                guard let tv = self?.terminalView else { return }
                let arr = Array(data)
                tv.feed(byteArray: arr[...])
            },
            onError: { [weak self] reason in
                self?.error = reason
            },
            onUsage: { [weak self] usage in
                self?.usage = usage
            }
        )
        backend.attach(cols: cols, rows: rows, openedAt: openedAt, events: events) { [weak self] sent in
            guard let self else { return }
            self.attachInFlight = false
            // 没发出去也不用自己重试：handlers 已经登记，WS 连上时 didOpen 会补发这次 attach
            guard sent else { return }
            self.hasAttached = true
            if let size = self.pendingSize, size.cols != cols || size.rows != rows {
                self.backend.resize(cols: size.cols, rows: size.rows)
            }
            self.pendingSize = nil
        }
    }

    /// 排 1 点 OFFLINE 触发的手动重连：整条链重走一遍。
    ///
    /// detach 立刻接 attachIfNotYet（中间不能 await 任何东西）—— detach 会把 WS client 里这个
    /// session 的 handlers 和 cols/rows 一起清掉，而断线重连时的自动重订阅正是靠那份 cols/rows。
    /// 隔开了就会留下「桥回来了但这个终端永远黑屏」的洞。
    func reconnect() {
        error = nil
        detach()
        backend.prepareReconnect()
        attachIfNotYet(cols: lastSize.cols, rows: lastSize.rows)
    }

    func detach() {
        // 还没发出去的 150ms resize 一起作废：detach 之后才到 hub 会把这台设备重新算回尺寸表（astra 实现审 #2）
        resizeWork?.cancel()
        resizeWork = nil
        backend.detach()
        // 复位：view disappear→reappear 复用同一 controller 时能重新 attach（否则 hasAttached
        // latch 死 → reappear 只发 resize 不重注册 handlers → 黑屏）。
        hasAttached = false
        attachInFlight = false
        pendingSize = nil
    }

    func sendInput(_ bytes: Data) {
        guard backend.isReachable else {
            flashOfflineInputHint()
            return
        }
        backend.send(bytes) { [weak self] err in
            // 新输入发出去了 → 上一次粘着的错误（「刚才那下没发出去」之类）就过时了（T07）
            guard err == nil, let self, let error = self.error,
                  !TerminalErrorWording.notAnErrorLine.contains(error) else { return }
            self.error = nil
        }
    }

    /// 连按不重复弹：已经浮着就不动它，3 秒到了才收
    private func flashOfflineInputHint() {
        guard !showsOfflineInputHint else { return }
        showsOfflineInputHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.showsOfflineInputHint = false }
    }

    /// 粘贴一段文本（工具条粘贴键、长按菜单的系统粘贴、Compose 发送，#053）。
    /// 包不包 ESC[200~ 由 backend 定：hub 交给 tmux 按 pane 真实模式判（见 `HubTerminalBackend.paste`），
    /// 小电脑按本地 SwiftTerm 记的模式。
    func paste(_ text: String, completion: ((TerminalPasteOutcome) -> Void)? = nil) {
        let bracketed = terminalView?.getTerminal().bracketedPasteMode == true
        backend.paste(text, bracketed: bracketed) { completion?($0) }
    }

    /// 当前窗口的滚动/点击语义。见 `TerminalMouseMode`。
    var mouseMode: TerminalMouseMode {
        if backend.emulatorOwnsModes {
            // 字节全经过本地 SwiftTerm，它记的鼠标模式就是真话（vim 开了就转发，shell 就本地滚）
            return terminalView.map { $0.getTerminal().mouseMode != .off ? .forwarding : .local } ?? .local
        }
        return TerminalMouseMode.resolve(mouseAny: mouseAny, sessionName: sessionName)
    }

    /// 刷新重绘：重拉 tmux 快照（决策 C 选项1），治客户端渲染脏。
    func refresh() {
        backend.refresh()
    }

    /// 给 CC 发 SGR 滚轮事件（CC 在 alt-buffer，历史归它自己管；终端层无 scrollback 可滚）。
    /// up=true 发 button 64（往历史滚），up=false 发 button 65（往最新滚）。ticks=连发几格。
    /// 序列：ESC [ < 64|65 ; 1 ; 1 M（SGR 1006 press），col/row 用 1;1（CC 全屏任意位置都生效）。
    func sendScrollWheel(up: Bool, ticks: Int) {
        guard ticks > 0 else { return }
        // 第二道闸：没开鼠标上报的窗口收到 SGR 序列会当字面字符打进命令行。
        // 手势那层已经拦了一次，这里再拦一次 —— 将来若有别的调用方接进来不会重蹈覆辙。
        guard mouseMode == .forwarding else { return }
        let button = up ? "64" : "65"
        let one = "\u{1b}[<\(button);1;1M"
        let seq = String(repeating: one, count: min(ticks, 10))  // 防一拖发太多，封顶 10 格
        guard let data = seq.data(using: .utf8) else { return }
        sendInput(data)
    }
}

enum TerminalPasteOutcome {
    /// hub 确认贴进 pane 了
    case delivered
    /// 交给 WS 了，但老 hub 不回包，送没送到不知道
    case submitted
    /// 一句给她看的原因
    case failed(String)
}

/// 断线时按了键，终端底部浮的那一行（审计 T08）。不吃点击。
struct TerminalOfflineInputBanner: View {
    var body: some View {
        Text("没连上，打的字不会发出去")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .padding(.bottom, 16)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// 错误行长按「复制原因」：拷 hub 的原文（审计 T07），人话那句不拷
enum TerminalErrorClipboard {
    static func copy(_ raw: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = raw
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
        #endif
    }
}

// 老的 `TerminalKey` / `TerminalKeyStore`（`ccTerminalKeys` 那 8 个键）已退役，
// 换成 `Views/Terminal/` 下的 `TerminalToolbarStore` 一整套。粟粟改过的键由
// `TerminalToolbarStore.migrateLegacyKeys` 直接读老的 UserDefaults 迁成自定义键，
// 不依赖老 store 的实例（粟粟批注 §五-5 ✅迁移保留）。

// MARK: - Cross-platform TerminalView wrapper

#if canImport(UIKit)
/// 「翻不动」根因修复（探针证实：CC TUI 开鼠标模式 → SwiftTerm mouseModeChanged 自动
/// enableMousePanGesture 加一个 UIPanGestureRecognizer 抢占系统滚动 pan → 拖动被
/// panMouseHandler 转成鼠标事件发给 CC，终端不滚，scrollview pan 全程 track=false offY=0）。
/// override 掉这个 hook：不加 mouse pan，让触摸拖动始终走系统滚动 pan = 滚 scrollback。
/// 配合 allowMouseReporting=false（见 makeUIView），终端是纯读+键盘输入面，不转发触摸鼠标。
/// 标记：该 view 自己处理键盘避让（PagingViewController 见到 first responder 在它的
/// 祖先链上就跳过 safe-area 避让，避免双重避让 + safe-area 缩 bounds 触发 SwiftTerm reflow）。
///
/// 2026-09-09 从 `TerminalKeyboardSelfManaging` 改名为通用名：Page2 的
/// `MPChatWebView`（整页 WKWebView 聊天，用 visualViewport 自管键盘）也要走这个豁免口，
/// 否则外层 `applyKeyboardAvoidance` 会先把容器压矮一次 = 双重避让。
protocol KeyboardSelfManaging {}

final class ScrollableTerminalView: TerminalView, KeyboardSelfManaging {
    #if os(iOS)
    /// #070：外壳拉左上弧线时（卡片 / 回桌面动画进行中）不接焦点。动画头尾 SwiftUI 会给终端换父容器，
    /// UIKit 搬第一响应者会先撤再 promote 回来，键盘就收→弹→收地来回走（😷 实测起手一帧 100–230ms）。
    /// 起手时外壳已经 resign 过一次，这里挡住 promote，键盘只收这一次。
    override var canBecomeFirstResponder: Bool {
        if Self.focusGuard, Page2AppShell.shared.motion != nil { return false }
        return super.canBecomeFirstResponder
    }

    #if DEBUG || PERF_BENCH
    private static let focusGuard = ProcessInfo.processInfo.environment["MP_TERM_FOCUS_GUARD"] != "0"
    #else
    private static let focusGuard = true
    #endif
    #endif

    override func mouseModeChanged(source: Terminal) {
        // 故意空实现：不随 CC 鼠标模式启用 mouse pan gesture，保住触摸滚动。
    }

    /// 长按菜单的系统「粘贴」改走 `CCTerminalController.paste`（#053 T27）。
    var onPaste: ((String) -> Void)?
    /// super.paste 发出的字节在 Coordinator.send 里吞掉。
    private(set) var swallowsPasteSend = false

    /// 还调 super：要它收掉选区拖拽手势（`disableSelectionPanGesture` 是 internal，够不着）。
    /// 它按客户端的 2004 自己包的那几段字节同步经 delegate 发出，趁 flag 开着吞掉，再交给 onPaste。
    override func paste(_ sender: Any?) {
        guard let onPaste, let text = UIPasteboard.general.string, !text.isEmpty else {
            super.paste(sender)
            return
        }
        swallowsPasteSend = true
        super.paste(sender)
        swallowsPasteSend = false
        onPaste(text)
    }

    // MARK: - 键盘避让（容器内 transform 上移，只滚终端、外框不动）
    // self 被套在 makeUIView 的 clipping 容器里（SwiftUI 只管容器 frame，碰不到 self 的
    // transform → 不会被冲）。键盘弹起时把 self 上移 overlap：底部输入行抬到键盘上方，顶部
    // 溢出被容器裁掉，标题栏在容器外纹丝不动。不缩 bounds → SwiftTerm 不 reflow、不 resize。
    private var kbObserving = false

    /// 工具条（常驻层，底边绑 `keyboardLayoutGuide`）。条跟键盘一起显隐由这里驱动 ——
    /// 键盘通知是「条该不该在」唯一诚实的信号，条自己再订一份只会两边不同步。
    weak var toolbar: TerminalToolbarView?
    /// Compose 草稿编辑器开着时挂在这儿。工具条的可打印键要插进草稿而不是发给终端。
    weak var composeOverlay: TerminalComposeOverlay?
    /// 遮挡物 = 键盘 + 压在键盘顶上的条。避让量要把条高一起算进去，
    /// 否则 TUI 底部那行 `❯` 正好被条盖住（plan §C0 末条）。
    var toolbarHeight: CGFloat = 0
    /// 最近一次停靠的键盘 frame。抽屉展开让条变高时用它重算避让，不用等下一次键盘通知。
    private var lastDockedKeyboardFrame: CGRect?

    /// 条高变了（抽屉开合）→ 按上次的键盘位置重算一次避让。
    func reapplyKeyboardAvoidance() {
        guard isFirstResponder, let end = lastDockedKeyboardFrame, let win = window else { return }
        let showBar = TerminalHardwareKeyboard.shared
            .shouldShowToolbar(visibleKeyboardHeight: win.bounds.height - end.minY)
        let saved = transform
        transform = .identity
        let myMaxY = convert(bounds, to: nil).maxY
        transform = saved
        let overlap = max(0, myMaxY - (end.minY - (showBar ? toolbarHeight : 0)))
        let target: CGAffineTransform = overlap > 0.5
            ? CGAffineTransform(translationX: 0, y: -overlap) : .identity
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) {
            self.transform = target
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { addKeyboardObservers() } else { removeKeyboardObservers() }
    }

    private func addKeyboardObservers() {
        guard !kbObserving else { return }
        kbObserving = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(kbFrameWillChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(kbWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    private func removeKeyboardObservers() {
        guard kbObserving else { return }
        kbObserving = false
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func kbFrameWillChange(_ note: Notification) {
        guard isFirstResponder, let win = window,
              let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let h = win.bounds.height
        let docked = abs(end.maxY - h) < 1
        let hidden = end.minY >= h - 1
        guard docked || hidden else { return }
        let dur = Self.duration(note)
        if hidden {
            lastDockedKeyboardFrame = nil
            toolbar?.setVisible(false, duration: dur)
            animateShift(0, note: note)
            return
        }
        lastDockedKeyboardFrame = end
        // 外接键盘判定（物料表 §10.1）：接了外键**且**软键盘实际没露出来（可见高度 ≤120pt）
        // → 条收起来。那种场景所有键都能从实体键盘敲，屏幕上再压一条只是挡地方。
        let showBar = TerminalHardwareKeyboard.shared
            .shouldShowToolbar(visibleKeyboardHeight: h - end.minY)
        toolbar?.setVisible(showBar, duration: dur)
        let saved = transform
        transform = .identity
        let myMaxY = convert(bounds, to: nil).maxY
        transform = saved
        // 条压在键盘顶上 → 真正的遮挡上沿是「键盘顶 − 条高」；条不显示就不占这段
        let overlap = max(0, myMaxY - (end.minY - (showBar ? toolbarHeight : 0)))
        animateShift(overlap, note: note)
    }

    @objc private func kbWillHide(_ note: Notification) {
        lastDockedKeyboardFrame = nil
        toolbar?.setVisible(false, duration: Self.duration(note))
        animateShift(0, note: note)
    }

    private static func duration(_ note: Notification) -> Double {
        (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
    }

    private func animateShift(_ dy: CGFloat, note: Notification) {
        let target: CGAffineTransform = dy > 0.5 ? CGAffineTransform(translationX: 0, y: -dy) : .identity
        UIView.animate(withDuration: Self.duration(note), delay: 0, options: [.beginFromCurrentState]) {
            self.transform = target
        }
    }

    /// 「翻不上去/诡异」根因修复（探针证实：键盘弹起→resize→CC 全屏重绘爆发输出，
    /// SwiftTerm updateScroller 每次 scrolled 都把 contentOffset 无条件拽回底部 565，
    /// 把用户正在进行的上翻拖动 cancel 掉 → 拖动 began 后立刻 ended、offY 卡死底部）。
    /// 标准终端 scrollback 行为：用户正在拖动 / 已滚离底部时冻结「自动跟随到底部」，
    /// 回到底部才恢复跟随。cellDimension 是 SwiftTerm internal 取不到，用 20pt 阈值近似。
    override func scrolled(source terminal: Terminal, yDisp: Int) {
        let maxOff = max(0, contentSize.height - bounds.height)
        let atBottom = contentOffset.y >= maxOff - 20
        if isTracking || isDragging || isDecelerating || !atBottom {
            return   // 用户在看历史，别把它拽回底部
        }
        super.scrolled(source: terminal, yDisp: yDisp)
    }
}

/// 小电脑会话（#045）持有的视图宿主：同一个 SwiftTerm 容器 + coordinator 跨 tab 切换复用，
/// 摘下再挂回屏幕状态原样（不做字节回放，plan-terminal-t2 §2.3）。hub 终端不用它，照旧每次新建。
final class TerminalHostCache {
    fileprivate var coordinator: Coordinator?
    fileprivate var container: UIView?

    /// 会话结束：放掉界面回调（它们会捕获界面那一侧的对象），容器从视图树摘下
    func tearDown() {
        coordinator?.onOpenWindowSwitcher = {}
        coordinator?.onOpenSettings = {}
        container?.removeFromSuperview()
    }
}

struct TerminalRepresentable: UIViewRepresentable {
    let controller: CCTerminalController
    /// ⚙ / 窗口切换键要弹的是 SwiftUI sheet，UIKit 这层只负责喊一声
    var onOpenWindowSwitcher: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// 没连上电脑：工具条整条变灰（T08）
    var dimsToolbar = false
    /// 有就复用（小电脑会话），没有就每次新建（hub）
    var host: TerminalHostCache? = nil

    func makeUIView(context: Context) -> UIView {
        if let container = host?.container {
            context.coordinator.onOpenWindowSwitcher = onOpenWindowSwitcher
            context.coordinator.onOpenSettings = onOpenSettings
            context.coordinator.toolbar?.setDimmed(dimsToolbar)
            return container
        }
        let tv = ScrollableTerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.onPaste = { [weak coordinator = context.coordinator] text in coordinator?.pasteClipboardText(text) }
        // 不让 SwiftTerm 把触摸拖动/点击转发成鼠标事件给 CC（配合 mouseModeChanged override），
        // 触摸拖动 = 滚动；点击 = 聚焦。CC 交互靠键盘/打字，不靠触摸点 TUI。
        tv.allowMouseReporting = false
        // 滚动叠字根因修复（证据：SwiftTerm setupOptions iOSTerminalView.swift:1181
        // 默认 nativeBackgroundColor = .clear；draw(_:) 每帧 `nativeBackgroundColor.set();
        // context.fill([dirtyRect])` 用透明色填背景 = 不擦旧字形 → 滚动暴露区旧字累积。
        // 官方 sample TerminalHostViewController.swift:17-21 在 init 后覆盖成 opaque .black
        // 才不叠；我们之前从没设 → 保持透明 → 「只要滚动就一直叠加」。设 opaque 终端底色修复。
        let termBg = UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1.0)  // 暖调近黑，无蓝无黄
        tv.isOpaque = true
        tv.backgroundColor = termBg
        tv.nativeBackgroundColor = termBg
        // SwiftTerm 自带那条占半屏的 accessory bar 直接摘掉，**而且不换上我们自己的**：
        // 工具条改由终端页常驻层 `TerminalToolbarView` 提供（见下面 container 装配），
        // keyboardLayoutGuide 里从此没有 accessory → 08-26 Bug1 的病根（条赖在 guide 里
        // 不回落 34，把聊天页输入条顶高 18pt）连同摘条铁律一起消失。
        // 置 nil 安全：SwiftTerm 的 setupAccessoryView() 只在 init 调一次
        //（iOSTerminalView.swift:317 → :1162），之后不会自己长回来。
        tv.inputAccessoryView = nil
        // L4 P2: TerminalView 是 UIScrollView 子类。
        //
        // 粟粟要的规则：**点/滚 输入框和键盘之外的任何地方，都收键盘**。
        // 滚动这一半交给 .onDrag（.interactive 要求拖进键盘 frame，终端里判定几乎不触发，
        // 试过，就是「滑动收键盘没了」那次）；点击那一半见下面的 dismissTap。
        tv.keyboardDismissMode = .onDrag
        // CC 在 alt-buffer 无 scrollback（contentSize==bounds），开 bounce 会让垂直拖动橡皮筋
        // 回弹（探针实测 offY 负到 -194）= 「拖不动」手感。关掉；垂直滚动由 wheelPan 转发给 CC。
        tv.alwaysBounceVertical = false
        // 「弹键盘后滚不动」根因修复（证据：官方 sample TerminalHostViewController.swift:22
        // 设 .never；SwiftTerm 库内部不设、靠 host 配）。UIScrollView 默认 .automatic 会按
        // safeAreaInsets 自动加 contentInset；而 PagingViewController P1 在键盘弹起时给本
        // child HC 注入 additionalSafeAreaInsets.bottom=键盘高度 → 被自动转成
        // contentInset.bottom，跟 SwiftTerm 自管的 contentOffset/contentSize 打架 → 滚动崩。
        // 没键盘时不注入 safe area → contentInset=0 → 能滚（吻合实测差异）。设 .never 挡掉
        // 自动调整，让 SwiftTerm 全权管滚动；滚动恢复后 .onDrag 才有 drag 可触发去收键盘。
        tv.contentInsetAdjustmentBehavior = .never
        controller.terminalView = tv
        // CC 在 alt-buffer 无 scrollback：加垂直 pan → 转 SGR 滚轮发给 CC 滚它自己的历史。
        // delegate 放行同时识别，跟 scrollview 自带 pan / tap / 横向 paging 共存。
        let wheelPan = UIPanGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleWheelPan(_:)))
        wheelPan.delegate = context.coordinator
        tv.addGestureRecognizer(wheelPan)
        // 单击完全自己接管：收 / 弹 / 什么都不做，三种情况都在 handleTerminalTap 里判。
        //
        // ⚠️ 必须让 SwiftTerm 自带的 singleTap **失效**，否则它会跟我们同时识别同一次点击：
        // 我们刚 resign 收下去，它紧接着 becomeFirstResponder 又弹回来
        //（粟粟实测「刚落下去它又自己弹起来了」）。
        // 用 require(toFail:) 而不是 isEnabled=false —— 我们的手势万一没成立，它还能兜底。
        let terminalTap = UITapGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleTerminalTap(_:)))
        terminalTap.name = Coordinator.terminalTapName
        terminalTap.delegate = context.coordinator
        tv.addGestureRecognizer(terminalTap)
        tv.gestureRecognizers?
            .compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.name != Coordinator.terminalTapName && $0.numberOfTapsRequired == 1 }
            .forEach { $0.require(toFail: terminalTap) }
        // 套一个 clipping 容器：SwiftUI 只管容器 frame，碰不到 tv 的 transform（键盘避让靠
        // tv.transform 上移，不被 SwiftUI 冲）；容器裁掉 tv 上移后顶部的溢出，标题栏在容器外不动。
        // tv 用 Auto Layout 填满容器（约束管 frame，transform 是其上的视觉层，互不干扰）。
        let container = UIView(frame: .zero)
        container.clipsToBounds = true
        container.backgroundColor = termBg
        tv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // 工具条：tv 的兄弟层（加在后面 = 盖在上面）。tv 的 transform 影响不到它。
        // 底边绑 container 自己的 keyboardLayoutGuide —— 键盘起落由系统逐帧驱动约束，
        // 条跟键盘同步移动，不用我们手写动画（聊天页输入条同款，PagingViewController.swift:169）。
        // 终端页 HC 已被 PagingVC 判为「自管键盘」跳过 safe-area 避让
        //（PagingViewController.swift:298-301），guide 这条链上没有第二个消费者，不会重复计。
        let toolbar = TerminalToolbarView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.onSendBytes = { [weak controller, weak tv] bytes in
            // Compose 草稿开着时，可打印字节插进草稿而不是发给终端（物料表 §4.3）
            if let overlay = tv?.composeOverlay, let text = Self.printableText(bytes) {
                overlay.insert(text)
                return
            }
            controller?.sendInput(Data(bytes))
        }
        toolbar.onAction = { [weak tv] id in
            guard let tv else { return }
            context.coordinator.handleToolbarAction(id, tv: tv)
        }
        toolbar.onHeightChange = { [weak tv] height in
            guard let tv else { return }
            tv.toolbarHeight = height
            tv.reapplyKeyboardAvoidance()
        }
        container.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor),
        ])
        tv.toolbar = toolbar
        tv.toolbarHeight = toolbar.intrinsicContentSize.height
        toolbar.setDimmed(dimsToolbar)
        context.coordinator.container = container
        context.coordinator.toolbar = toolbar
        context.coordinator.onOpenWindowSwitcher = onOpenWindowSwitcher
        context.coordinator.onOpenSettings = onOpenSettings
        host?.container = container
        return container
    }

    /// 纯可打印 ASCII/UTF-8（没有 C0 控制码）才算「能进草稿的字」。
    /// ESC 序列、Ctrl 组合这类控制流一律直发终端。
    static func printableText(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 闭包每次 body 重算都是新的，存最新的那份，别让 Coordinator 抓着开页时的旧闭包
        context.coordinator.onOpenWindowSwitcher = onOpenWindowSwitcher
        context.coordinator.onOpenSettings = onOpenSettings
        context.coordinator.toolbar?.setDimmed(dimsToolbar)
    }

    func makeCoordinator() -> Coordinator {
        if let cached = host?.coordinator { return cached }
        let coordinator = Coordinator(controller: controller)
        host?.coordinator = coordinator
        return coordinator
    }
}
#else
struct TerminalRepresentable: NSViewRepresentable {
    let controller: CCTerminalController
    var onOpenWindowSwitcher: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        // 同 iOS：opaque 终端底色，避免 draw 用透明色填背景导致滚动叠字
        let termBg = NSColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1.0)
        tv.nativeBackgroundColor = termBg
        tv.layer?.backgroundColor = termBg.cgColor
        controller.terminalView = tv
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
}
#endif

final class Coordinator: NSObject, TerminalViewDelegate {
    let controller: CCTerminalController
    #if canImport(UIKit)
    /// 终端页那个 clipping 容器。Compose overlay 挂在它里面（工具条的兄弟层）
    weak var container: UIView?
    weak var toolbar: TerminalToolbarView?
    var onOpenWindowSwitcher: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    #endif

    init(controller: CCTerminalController) {
        self.controller = controller
    }

    #if canImport(UIKit)
    /// 工具条上的内部 action（不发 PTY 字节，也不消耗 oneShot 修饰键 —— 物料表 §2.2 边界）
    @MainActor func handleToolbarAction(_ id: TerminalKeyID, tv: ScrollableTerminalView) {
        switch id {
        case .dismiss:
            dismissTerminalKeyboard(tv)
        case .windowSwitcher:
            onOpenWindowSwitcher()
        case .terminalSettings:
            onOpenSettings()
        case .compose:
            toggleCompose(tv)
        case .paste:
            guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
            pasteClipboardText(text)
        default:
            break
        }
    }

    /// 工具条粘贴键 / 长按菜单粘贴。没送到给一下错误震动（剪贴板不动，可以再贴）；终端页没有提示条，
    /// 也不能借 controller.error —— 那会被画成 OFFLINE。
    @MainActor func pasteClipboardText(_ text: String) {
        controller.paste(text) { outcome in
            if case .failed = outcome { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
    }

    /// Compose 草稿编辑器：开着就关，没开就开（物料表 §4.1 第 4 步同款 toggle）。
    @MainActor private func toggleCompose(_ tv: ScrollableTerminalView) {
        if let overlay = tv.composeOverlay {
            closeCompose(overlay, tv: tv)
            return
        }
        guard let container, let toolbar = tv.toolbar else { return }
        let overlay = TerminalComposeOverlay(draft: controller.composeDraft)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onDraftChange = { [weak controller] draft in controller?.composeDraft = draft }
        overlay.onSend = { [weak controller] text, done in
            // 当粘贴发：多行不逐行执行、不受 4096 字节限（#053），不套工具条的修饰键（物料表 §4.3 末条）。
            // hub 确认送到才清草稿 —— overlay 可能已被关掉，所以这里清 controller 那份。
            guard let controller else { return done(.failed("终端已关闭")) }
            controller.paste(text) { [weak controller] outcome in
                if case .delivered = outcome, controller?.composeDraft == text { controller?.composeDraft = "" }
                done(outcome)
            }
        }
        overlay.onClose = { [weak self, weak tv] in
            guard let self, let tv, let o = tv.composeOverlay else { return }
            self.closeCompose(o, tv: tv)
        }
        container.insertSubview(overlay, belowSubview: toolbar)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            overlay.heightAnchor.constraint(equalToConstant: 190),
        ])
        tv.composeOverlay = overlay
        overlay.focus()
    }

    /// 关闭时**先把焦点还给终端、再拆 overlay**，避免键盘 bounce（物料表 §4.2 末条）。
    @MainActor private func closeCompose(_ overlay: TerminalComposeOverlay,
                                         tv: ScrollableTerminalView) {
        tv.composeOverlay = nil
        _ = tv.becomeFirstResponder()
        overlay.removeFromSuperview()
    }

    /// 终端收键盘的唯一入口：**只 resign**。
    ///
    /// 08-26 那套「摘条必须在 resign 之前」的铁律已随 `inputAccessoryView` 一起退役 ——
    /// 工具条现在是终端页常驻层（`TerminalToolbarView`），guide 里没有 accessory 可赖，
    /// 收键盘时 guide 自然回落到 34，聊天页输入条不会被顶高。条跟着键盘通知一起淡出
    /// （`ScrollableTerminalView.kbWillHide`），不留底 —— 粟粟 08-31 批注 §五-3。
    @MainActor func dismissTerminalKeyboard(_ tv: TerminalView) {
        guard tv.isFirstResponder else { return }
        // 记下「是她主动收的」，别让自动重聚焦路径把键盘弹回来（session 级内存，不落盘）
        controller.keyboardHideIntent = true
        tv.resignFirstResponder()
    }
    #endif

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        #if canImport(UIKit)
        // 长按粘贴时 super.paste 同步打过来的字节（见 ScrollableTerminalView.paste）
        if Thread.isMainThread,
           MainActor.assumeIsolated({ (source as? ScrollableTerminalView)?.swallowsPasteSend == true }) { return }
        #endif
        Task { @MainActor in
            #if canImport(UIKit)
            // 合成点插在这儿：**软键盘打的字也要过粘滞修饰状态机**（plan §C4）。
            // 按下 ⌃ 再在软键盘上打 c，发出去的是 ^C 而不是字母 c。
            let bytes = (source as? ScrollableTerminalView)?.toolbar?
                .applyModifiers(to: Array(data)) ?? Array(data)
            controller.sendInput(Data(bytes))
            #else
            controller.sendInput(Data(data))
            #endif
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            // 第一次 fire → attach with size；之后 fire → 只 resize 同步
            controller.attachOrResize(cols: newCols, rows: newRows)
        }
    }

    // TerminalViewDelegate 其他必填 stub
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    /// 终端里的链接（OSC 8 / 识别出来的网址）：只放 http / https，交给系统打开（审计 T32）
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor in
            #if canImport(UIKit)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }
    }
    func bell(source: TerminalView) {}
    /// OSC 52：终端里的程序要写剪贴板。只认写（SwiftTerm 不转读请求），写了说一声（#045 D6）
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
        Task { @MainActor in
            TerminalErrorClipboard.copy(text)
            ToastCenter.shared.show("终端里的程序把内容复制到了剪贴板")
        }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

#if canImport(UIKit)
extension Coordinator: UIGestureRecognizerDelegate {
    /// CC 在 alt-buffer 无 scrollback，触摸 pan → SGR 滚轮序列发给 CC，让它滚自己的对话。
    /// 跟随 iOS 自然方向：手指上滑(ty<0)=看更新内容→down 滚轮；手指下滑(ty>0)=看历史→up 滚轮。
    @MainActor @objc func handleWheelPan(_ g: UIPanGestureRecognizer) {
        // 转不转发 SGR 滚轮，判据是 hub 报的 tmux `#{mouse_any_flag}`（见 TerminalMouseMode）。
        //
        // ⚠️ 没开鼠标上报的窗口（裸 shell）一个字节都不能发：zsh 不认识 SGR 序列就当字面字符
        // 打进命令行，实测屏幕会被 `65;1;1M64;1;1M…` 刷满（粟粟一滚就炸）。它有自己的
        // scrollback，交给 SwiftTerm 本地滚即可。
        //
        // 不能改判 SwiftTerm 自己的 mouseMode：它对 CC 是「假 off」（被 onInit 的完整复位抹了、
        // 快照里也不含 DECSET 1003）、对 shell 是「真 off」，两者读数一样分不开。

        // 一开始拖就收键盘。**不能靠 scrollView 的 keyboardDismissMode = .onDrag**：
        // CC 在 alt-buffer 时 contentSize == bounds 且 alwaysBounceVertical=false，
        // scrollView 根本滚不动 → 自带 pan 不产生 drag → dismissMode 永不触发
        //（粟粟实测「滚动的时候没收」）。真正在接垂直拖动的是这条 wheelPan，收键盘只能挂这儿。
        // 放在 shell 的 guard **之前** —— 两种窗口滚动都该收键盘。
        if g.state == .began, let tv = g.view as? TerminalView { dismissTerminalKeyboard(tv) }

        guard controller.mouseMode == .forwarding else { return }
        guard g.state == .changed else { return }
        let t = g.translation(in: g.view)
        guard abs(t.y) > abs(t.x) else { return }   // 横向为主 → 让给 paging，不发滚轮
        let step: CGFloat = 16                        // 每拖 16pt 发一格滚轮（24→16 ≈ 加快 1.5×）
        guard abs(t.y) >= step else { return }
        let ticks = Int(t.y / step)
        controller.sendScrollWheel(up: ticks > 0, ticks: abs(ticks))
        g.setTranslation(CGPoint(x: t.x, y: t.y - CGFloat(ticks) * step), in: g.view)
    }

    static let terminalTapName = "cc-terminal-tap"

    /// CC/codex 的输入框在 TUI 底部（`❯` 那行 + 下面的提示行）。app 层看不到 TUI 布局，
    /// 按比例圈一块底部区域当「输入框区域」。
    private static let inputZoneRatio: CGFloat = 0.22

    /// 终端单击的唯一入口（SwiftTerm 自带的 singleTap 已被 require(toFail:) 让位）。
    ///
    /// 规则（粟粟定的）：
    /// - 键盘起着 → 点**任何地方**都收
    /// - 键盘没起 + 没开鼠标上报（裸 shell）→ 点**任何地方**都弹（整块都是交互区）
    /// - 键盘没起 + 开了鼠标上报（CC/codex/vim）→ 只有点**底部输入框区域**才弹；点上面的内容区
    ///   什么都不做（她在看输出，不该被键盘糊一脸）
    @MainActor @objc func handleTerminalTap(_ g: UITapGestureRecognizer) {
        guard let tv = g.view as? TerminalView else { return }
        if tv.isFirstResponder {
            dismissTerminalKeyboard(tv)
            return
        }
        // 点终端 = 键盘和条一起回来（粟粟 08-31 批注 §五-3），顺手清掉她刚才的隐藏意图
        let focus = { [weak self] in
            self?.controller.keyboardHideIntent = false
            tv.becomeFirstResponder()
        }
        if controller.mouseMode == .local {
            focus()
            return
        }
        let y = g.location(in: tv).y
        let inputZoneTop = tv.bounds.height * (1 - Self.inputZoneRatio)
        if y >= inputZoneTop { focus() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 单击那条要独占：跟 SwiftTerm 自带 singleTap 同时识别 = 我们收下去它又弹回来。
        // 其余（wheelPan / paging）照旧共存。
        if gestureRecognizer.name == Self.terminalTapName || other.name == Self.terminalTapName {
            return false
        }
        return true
    }
}
#endif

// MARK: - Main panel view

#if os(iOS)
/// iOS：tab 条 + 首页 + 每个 session 的终端，见 `Views/Terminal/TerminalPanelRoot.swift`
struct CCTerminalPanelView: View {
    @Bindable var viewModel: ConversationViewModel

    var body: some View {
        TerminalPanelRoot(viewModel: viewModel)
    }
}
#else
struct CCTerminalPanelView: View {
    @Bindable var viewModel: ConversationViewModel
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    /// 当前显示的全局窗口 code；nil = 显示对话绑定的终端（默认，也是改动前的唯一行为）。
    /// 是 @State 所以**切对话时不会重置** —— 全局窗口跟对话无关，切对话不该把它切走。
    @State private var selectedWindow: String?

    /// 当前对话绑定的 session，nil 时 fallback 默认 mp-cc（跟 hub 一致）
    private var conversationSession: String {
        viewModel.selectedConversation?.ccBridgeSessionName ?? "mp-cc"
    }

    private var requestedWindow: String? {
        guard let target = navigator?.pendingTarget, target.tool == "ccTerminal",
              TerminalWindowStore.shared.windows.contains(where: { $0.code == target.id && !$0.isClosed }) else { return nil }
        return target.id
    }
    private var displayedWindow: String? { requestedWindow ?? selectedWindow }

    /// 终端实际 attach 的那个
    private var displayedSession: String {
        displayedWindow.map { "mp-win-\($0)" } ?? conversationSession
    }

    var body: some View {
        // .id(displayedSession)：切对话或切窗口都强制重建 → 新 controller + 重 attach。
        // 旧 view 的 onDisappear 会 detach，attach/detach 成对。
        CCTerminalSessionView(sessionName: displayedSession,
                              onReopenWindow: displayedWindow.map { code in { reopen(code) } })
            .id(displayedSession)
        .onAppear { consumeDesktopTarget() }
        .onChange(of: navigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
    }

    /// 全局窗口的 tmux 没了：按它原来的引擎开一个新的切过去（同 iOS 断桥卡「重新开一个」）
    private func reopen(_ code: String) {
        let store = TerminalWindowStore.shared
        let engine = (store.windows + store.closed).first { $0.code == code }?.engine
        store.open(engine: engine == "shell" ? nil : engine) { result in
            switch result {
            case .success(let newCode): selectedWindow = newCode
            case .failure(let error):
                ToastCenter.shared.show(error.fromHub ? "开不了新窗口：\(error.reason)" : "开不了新窗口：电脑那边没开出来，等一下再试")
            }
        }
    }

    private func consumeDesktopTarget() {
        guard navigator?.pendingTarget?.tool == "ccTerminal" else { return }
        if let requestedWindow { selectedWindow = requestedWindow }
        navigator?.pendingTarget = nil
    }
}

private struct CCTerminalSessionView: View {
    /// 实际 attach 的 session（可能是对话终端，也可能是某个全局窗口）
    let sessionName: String
    /// 全局窗口才有：session 没了时「重新开一个」按原引擎开新窗口。对话 Agent 为 nil（走 controller.reconnect 重新 spawn）
    let onReopenWindow: (() -> Void)?

    @StateObject private var controller: CCTerminalController
    @State private var refreshTrigger = 0
    /// 按了「重新连接」还没连上（T55）：按钮显示「连接中…」，连上或 12 秒没连上都收
    @State private var reconnecting = false

    init(sessionName: String, onReopenWindow: (() -> Void)?) {
        self.sessionName = sessionName
        self.onReopenWindow = onReopenWindow
        _controller = StateObject(wrappedValue: CCTerminalController(sessionName: sessionName))
    }

    private var client: CCBridgeWebSocketClient { .shared }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏 session 标识
            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(Theme.textMuted)
                    .font(.system(size: 11))
                Text("Agent 终端")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                // 连接点（T55）：连上绿 / 断开灰
                Circle()
                    .fill(client.isConnected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .help(client.isConnected ? "已连上电脑上的 hub" : "没连上电脑上的 hub")
                Spacer()
                Text(sessionName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                if !client.isConnected {
                    Button(reconnecting ? "连接中…" : "重新连接") {
                        reconnecting = true
                        client.reconnectNow()
                    }
                    .buttonStyle(MacShellButton())
                    .disabled(reconnecting)
                    .help(BridgeDisconnectWording.humanize(client.lastError) ?? "立刻重连，不等自动重试")
                    .padding(.leading, 6)
                }
                // 刷新重绘：Mac 外壳统一的图标钮（T57），点击震动。
                Button {
                    refreshTrigger += 1
                    controller.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(MacShellButton(width: 26))
                .help("重新绘制画面")
                .padding(.leading, 6)
                .sensoryFeedback(.impact, trigger: refreshTrigger)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .toolPageBackground()

            if controller.error == "session_not_found" {
                // 同 iOS 断桥卡的说法（T55）
                HStack(spacing: 8) {
                    Text("这个窗口已经不在了 · 电脑上的这个窗口已经结束了")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Button("重新开一个") {
                        if let onReopenWindow { onReopenWindow() } else { controller.reconnect() }
                    }
                    .buttonStyle(MacShellButton())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = controller.error {
                // stream_session = 无终端模式的会话（hub 侧 stream 传输），不是故障
                let isStream = error == "stream_session"
                Text(isStream ? "这个会话是无终端模式：消息直接送达，权限和提问在对话里答，这里没有画面。" : "⚠️ \(TerminalErrorWording.humanize(error))")
                    .font(.system(size: 11))
                    .foregroundColor(isStream ? Theme.textMuted : .red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isStream ? Theme.mainBg : Color.red.opacity(0.08))
                    .contextMenu {
                        if !isStream {
                            Button("复制原因") { TerminalErrorClipboard.copy(error) }
                        }
                    }
            }

            // SwiftTerm 视图。圆角 + 底部留白，跟左页/兄弟面板（22 .continuous）一致的卡片观感。
            // 左右外边距由 iOSDashboardPage 的 .padding(.horizontal,10) 提供，这里只加圆角 + 底距。
            TerminalRepresentable(controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(alignment: .bottom) {
                    if controller.showsOfflineInputHint { TerminalOfflineInputBanner() }
                }
                .animation(.easeInOut(duration: 0.2), value: controller.showsOfflineInputHint)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolPageBackground()   // L4 P3: 填满 right panel 区域，防对话页内容透过来
        .onAppear {
            controller.noteOpened()
            // C1：打开终端页时幂等 spawn 专属 session（已存在 hub 返回 session_exists，忽略）
            // → 确保终端有得 attach + 预热 claude，避免新会话终端黑屏。
            // 全局窗口不走这条（它由 hub 的 open_window 起裸 shell，这条会 spawn claude），
            // 但下面的 attach 兜底两者都要。
            if !sessionName.hasPrefix("mp-win-") {
                CCBridgeWebSocketClient.shared.spawnSession(sessionName) { _ in }
            }
            // L4 P0b: 不再立即 attach with 40x20 fallback——之前会导致 hub 用错的
            // pane size capture，跟 SwiftTerm 真实 viewport 不一致触发乱码。
            // 让 sizeChanged delegate（拿到真实 cols/rows）唯一负责 attach。
            // 仅 2s 兜底防 layout 异常 sizeChanged 没 fire：用 80x24 标准 size attach。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak controller] in
                controller?.attachIfNotYet(cols: 80, rows: 24)
            }
        }
        .onDisappear {
            controller.detach()
        }
        .onChange(of: client.isConnected) { _, connected in
            if connected { reconnecting = false }
        }
        .task(id: reconnecting) {
            guard reconnecting else { return }
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { reconnecting = false }
        }
    }
}
#endif
