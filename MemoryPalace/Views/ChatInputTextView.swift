#if os(iOS)
import SwiftUI
import UIKit

#if DEBUG
/// ime-residual 取证：INPROBE 双写（console + KBProbe 落盘）——真机脱管时靠文件定罪。
/// 09-05 粟粟真机复现「组字无触摸被定稿成拼音」，print 版真机拿不到是取证死穴。
@inline(__always) func INPROBE(_ msg: @autoclosure () -> String) {
    let m = "[INPROBE] " + msg()
    print(m)
    KBProbe.log(m)
}
#endif

// MARK: - ChatInputTextView（research-input-uikit 方案 B，plan T1）
//
// 聊天输入框的文本视图本体：自有 UITextView 替换 SwiftUI TextField(axis:.vertical)。
// 不变量（plan §一）：contentSize/contentOffset/滚动/光标只有 UIKit 原生行为和这里的
// delegate 写——没有任何「下一 runloop 纠正别人」的代码。永远可滚：封顶后内滚、
// 光标跟随、滚动指示条全是原生行为。

final class ChatInputTextView: UITextView {

    /// 单行 inset（对齐旧 TextField padding：leading 6 / vertical 10）
    static let singleInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 0)
    /// 多行 inset（粟粟批的 15/15、离按钮行 2、右侧放大钮位固定 36）
    static let multiInset = UIEdgeInsets(top: 15, left: 15, bottom: 2, right: 36)

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textContainer.lineFragmentPadding = 0
        textContainerInset = Self.singleInset
        isScrollEnabled = true
        showsVerticalScrollIndicator = true
        accessibilityIdentifier = "chat-input-field"
    }

    /// 6 行封顶高（⧫2 按行数封，从自家度量推导；到 6 行必已是多行 inset）
    static func capHeight(font: UIFont) -> CGFloat {
        font.lineHeight * 6 + multiInset.top + multiInset.bottom
    }

    /// ime-residual T3d：宽度变化（旋转/宿主变宽窄/单⇄多行换宽）没有 text/font/inset 事件，
    /// 这里是滚动开关重算的唯一挂点。静态测量器无 delegate，天然 no-op。
    private var lastSyncedWidth: CGFloat = 0
    #if (DEBUG || PERF_BENCH) && os(iOS)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { PerfHarness.inputField = self }
    }
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastSyncedWidth) > 0.5 {
            lastSyncedWidth = bounds.width
            (delegate as? ChatInputRepresentable.Coordinator)?.syncScrollEnabled(self)
        }
    }

    // MARK: 静态测量器（模式判定唯一入口，plan 不变量 2）
    //
    // 与显示 view 同款类、同字体、同 inset——量出来的就是显示出来的（Telegram 式：
    // 宽度是喂给测量的输入，不从布局读回）。显示 view 自己不做变宽 sizeThatFits。

    private static let measurer = ChatInputTextView()

    /// 给定宽度下的内容总高（含 inset）。input-jank C6：同一 (文本, 宽, inset, 字体) 在一轮布局里会被
    /// updateMultiline / showExpandButton / sizeThatFits 反复问（真机 trace 累计 ≈347ms/70s），缓存兜住。
    private static var heightCache: [String: CGFloat] = [:]
    static func contentHeight(text: String, font: UIFont, width: CGFloat, inset: UIEdgeInsets) -> CGFloat {
        let key = "\(width)|\(inset.top)|\(inset.left)|\(inset.right)|\(font.pointSize)|\(font.fontName)|\(text)"
        if let h = heightCache[key] { return h }
        measurer.font = font
        measurer.textContainerInset = inset
        measurer.text = text.isEmpty ? " " : text
        let h = measurer.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if heightCache.count > 64 { heightCache.removeAll(keepingCapacity: true) }
        heightCache[key] = h
        return h
    }

    /// 给定宽度下的行数（减 inset 再除行高——自家度量，非伪精确）
    static func lineCount(text: String, font: UIFont, width: CGFloat, inset: UIEdgeInsets) -> Int {
        guard !text.isEmpty, width > 30 else { return 1 }
        let h = contentHeight(text: text, font: font, width: width, inset: inset) - inset.top - inset.bottom
        return max(1, Int((h / font.lineHeight).rounded()))
    }
}

// MARK: - ChatInputHandle（input-jank C2）

/// SwiftUI 侧拿 UITextView 真相的把手。
///
/// C2 之后 `text` Binding 的语义是「**提交后**文本」——UITextView 里随时可能有一截还没
/// 提交的尾巴（最长 300ms 去抖窗）。规则一句话（kimi B1，提交点 8）：
/// **离开 UITextView 之前，先把它说的话记下来**——任何外部写入之前、任何上游读 binding
/// 之前，先 `commitNow()`。
///
/// 用共享实例而不是把把手一路穿参：调用方散在 InputFieldContainer / ChatInputBar /
/// InputBarStack 三层，其中 ChatInputBar 是 iOS+macOS 共用源码——穿参会把 macOS 也改了
/// （红线：macOS 零改动）。前提：同一时刻只有一个聊天输入框挂载（放大 sheet 用的是
/// TextEditor 不是 representable），makeUIView 里重挂即覆盖，weak 引用死了自动断。
/// 外部写显式命令（plan-input-command-channel）：gen 单调递增=新鲜度身份，不比对值。
/// 迟到的 SwiftUI body 不携带命令（命令走 handle 即时投递、不进 body），值推断整族
/// （回声环 / pendingExternal）随之废除——09-11 Air 日志 457 次误吞+漏放双向失效定罪。
struct InputCommand {
    let gen: Int
    let text: String
    let session: String?
}

final class ChatInputHandle {
    static let shared = ChatInputHandle()
    fileprivate weak var coordinator: ChatInputRepresentable.Coordinator?
    /// 当前输入框归属的会话 id（宿主在切会话时更新）。组字期间被跳过的外部写要按它守卫：
    /// 会话已换 → 那条重试属于旧会话，丢弃，别写进新会话（codex A2）
    var sessionKey: String?
    /// UITextView 里的真文本（representable 没挂载时 nil，调用方退回 binding）
    var liveText: String? { coordinator?.textView?.text }
    /// 立即把 UITextView 真相刷进 binding
    func commitNow() { coordinator?.commitNow() }
    /// 先把候选拼音**定稿成文本**再提交（codex A2）。
    ///
    /// 切会话 / 进后台这两个点必须用它：组字期间 `commitNow()` 会被 marked 冻住，旧会话的
    /// 组字文本和新会话的草稿谁都不是 owner——重试无论先后都丢一边。`unmarkText()` 把
    /// 候选定稿进 tv.text，组字状态随之结束，两边的所有权就都清楚了。
    func finalizeCompositionAndCommit() {
        coordinator?.textView?.unmarkText()
        coordinator?.commitNow()
    }

    /// 命令 gen 源：挂在 handle 上，跨 representable 重挂单调（新 coordinator 的
    /// lastAppliedGen 从 0 起，任何在世命令都比它新）。
    private var commandGen = 0
    /// 把文本写进输入框的唯一下行通道（发送清空 / 草稿装载 / 斜杠补全 / 引用合并 /
    /// 放大 sheet 回填）。representable 没挂载时丢弃——所有调用点都先写了 binding 镜像，
    /// makeUIView 挂载初始化从镜像取值，不会丢。
    func issueText(_ text: String, session: String? = nil) {
        commandGen += 1
        let cmd = InputCommand(gen: commandGen, text: text, session: session ?? sessionKey)
        #if DEBUG
        INPROBE("CMD issue gen=\(cmd.gen) len=\(text.count) sess=\(cmd.session.map { String($0.suffix(6)) } ?? "-") mounted=\(coordinator != nil ? 1 : 0)")
        #endif
        coordinator?.apply(cmd)
    }
}

#if DEBUG
/// iu0902 C2 验收通道：XCUITest 进程读不到 app 容器里的 kb-probe.log，把 body 计数挂到
/// 输入框的 a11y label 上（**只在 `--kb-probe-seed` 下开**，日常 DEBUG 不改 VoiceOver 行为），
/// 测试直接 `field.label` 读增量。
@MainActor enum InputPerfProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--kb-probe-seed")
    static weak var host: UITextView?
    private static var bar = 0
    private static var field = 0
    /// 击键数（textViewDidChange）与提交数——没有它们，「body 没涨」分不清是 C2 生效
    /// 还是测试根本没打进去字
    private static var keys = 0
    private static var commits = 0

    static func publish(bar: Int, field: Int) {
        guard enabled else { return }
        self.bar = bar
        self.field = field
        refresh()
    }
    static func countKey() {
        guard enabled else { return }
        keys += 1
        refresh()
    }
    static func countCommit() {
        guard enabled else { return }
        commits += 1
        refresh()
    }
    private static func refresh() {
        host?.accessibilityLabel = "perf bar=\(bar) field=\(field) keys=\(keys) commits=\(commits)"
    }
}
#endif

// MARK: - ChatInputRepresentable（plan T2）

struct ChatInputRepresentable: UIViewRepresentable {
    /// **提交后**文本（C2）：稳态打字期间它落后于 UITextView，只在提交点被写。
    @Binding var text: String
    /// 平 Binding 焦点通道（kimi B7 的 FocusState.Binding 路线已被 T5 实测证伪：iOS 侧无绑定
    /// 视图时 FocusState 写入被焦点系统丢弃）；宿主侧 iOS 用 @State 存，macOS 分支照旧 FocusState
    @Binding var focused: Bool
    /// input-jank C3：键入后 600ms 无新键入 = 空闲（驱动液态金属环暂停）。
    /// C2 后由 coordinator 只在**翻转时**写（每轮打字 2 次），不再每键 onChange。
    @Binding var typingIdle: Bool
    let font: UIFont
    let textColor: UIColor
    /// 决定 inset 组；模式判定本身在 InputFieldContainer（窄宽测量 + 迟滞）
    let isMultiline: Bool
    /// 宿主用来判 isMultiline 的那个宽度（单行=singleLineWidth，多行=singleLineWidth-40）。
    /// coordinator 拿它做提交点 1 的第二个分量：**模式要翻了**也得提交，否则退回单行会滞后到去抖。
    let modeProbeWidth: CGFloat
    /// 斜杠浮板是否活着（cc-bridge model）。真时 `/` 开头逐键提交（kimi B2：浮板 prefix 渐进过滤）
    let slashLive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ChatInputTextView {
        #if DEBUG
        HitchProbe.start()
        #endif
        let tv = ChatInputTextView()
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        ChatInputHandle.shared.coordinator = context.coordinator
        // 挂载初始化（plan-input-command-channel §A3）：binding=已提交镜像，永远不旧于
        // 任何已发命令（调用点先写镜像再 issueText）——重挂恢复从它取，无歧义、无推断。
        tv.text = text
        context.coordinator.lastCommittedText = text
        #if DEBUG
        if InputPerfProbe.enabled { InputPerfProbe.host = tv }
        #endif
        return tv
    }

    func updateUIView(_ tv: ChatInputTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        ChatInputHandle.shared.coordinator = c

        if tv.font != font {
            tv.font = font
            // ime-residual T3b：字号换 = content↔cap 关系换。签名基准原靠下一键自愈，这里补齐；
            // 滚动开关同拍重算（越顶瞬间恰逢字号变化时的卡死路，E2）
            c.resetLayoutSignature(tv)
            c.syncScrollEnabled(tv)
        }
        if tv.textColor != textColor {
            tv.textColor = textColor
        }
        let inset = isMultiline ? ChatInputTextView.multiInset : ChatInputTextView.singleInset
        if tv.textContainerInset != inset {
            #if DEBUG
            HitchProbe.mark(isMultiline ? "inset→multi" : "inset→single")
            #endif
            tv.textContainerInset = inset
            // inset 换组 = 同一文本的高度也换了，签名基准跟着换（否则下一键会误判成「高度变了」）
            c.resetLayoutSignature(tv)
            c.syncScrollEnabled(tv)   // ime-residual T3b：同上，inset 换组也动 content↔cap
        }

        // 外部写不再走 binding（plan-input-command-channel，09-11）：binding 只出不进——
        // 下行文本一律 ChatInputHandle.issueText 显式命令（gen 单调防迟到 body，Coordinator.apply）。
        // 原「binding≠lastCommitted 推断外部写」+ 回声环 + pendingExternal 整族已废除：
        // 值推断双向失效（误吞发送清空 / 漏放 stale 回灌）见 Air 日志定罪 research-input-command-channel。

        // 焦点桥（守卫：状态不同才动手——text 每键都进这里，无守卫 = 每键一轮 resign/become）。
        // responder 调用延一拍：updateUIView 在 SwiftUI 渲染事务里，同步 become/resign 会把
        // 焦点回写卷进同一次求值（AttributeGraph cycle）。
        // ime-residual T2：到点重读 c.parent.focused（@Binding 读 live storage 非快照）——
        // 排队期间意图已翻转的过期命令直接丢弃。误 resign 会把组字强制定稿成拼音原文，
        // 这条只管「丢弃过期桥命令」；三处全局 sendAction(resign) 天然绕桥，不归它管。
        if focused, !tv.isFirstResponder, tv.window != nil {
            DispatchQueue.main.async { [weak tv, weak c] in
                guard let tv, let c else { return }
                guard c.parent.focused, !tv.isFirstResponder, tv.window != nil else {
                    #if DEBUG
                    if !c.parent.focused { INPROBE("bridge become DROP stale") }
                    #endif
                    return
                }
                tv.becomeFirstResponder()
            }
        } else if !focused, tv.isFirstResponder {
            DispatchQueue.main.async { [weak tv, weak c] in
                guard let tv, let c else { return }
                guard !c.parent.focused, tv.isFirstResponder else {
                    #if DEBUG
                    if c.parent.focused { INPROBE("bridge resign DROP stale") }
                    #endif
                    return
                }
                #if DEBUG
                INPROBE("bridge resign marked=\(tv.markedTextRange != nil ? 1 : 0)")
                #endif
                tv.resignFirstResponder()
            }
        }
    }

    /// 高度经此报给 SwiftUI（IOSPromptTextView 同款，不另设 height Binding）。
    /// 不变量 2：**显示 view 不做变宽 sizeThatFits**——SwiftUI 每次布局用多种宽度探尺寸（09-01 Air 实测每键
    /// ∞/43/86/302/真宽 5 种），直接量 uiView 会让它的排版器每键按外来宽度重排 5 次再排回；改量静态测量器，
    /// 显示 view 只按自己的 frame 排一次。同一 (文本, 宽, 字体, inset) 在一轮布局里被问多次，缓存兜住。
    ///
    /// C2 后这里读的是 `uiView.text`（真相），不是 binding——提交点之间 SwiftUI 不重排，
    /// 一旦重排（任何原因）拿到的高度也是当前真文本的高度，不会闪回旧文本的高度。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatInputTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measureWidth = width.isFinite ? width : 10_000
        let content = ChatInputTextView.contentHeight(text: uiView.text ?? "", font: font, width: measureWidth, inset: uiView.textContainerInset)
        let h = min(content, ChatInputTextView.capHeight(font: font))
        return CGSize(width: width, height: h)
    }

    /// 打字不进 SwiftUI（input-jank C2）。
    ///
    /// UITextView 自己消化每键；只有**提交点**才把真相写回 `text` Binding：
    ///  1 布局签名变（本宽下的封顶高 或 宿主判模式那个窄宽下的行数）
    ///  2 焦点变（didBegin/didEnd）
    ///  3 空 ⇄ 非空翻转（发送键可用态）
    ///  4 首字符 `/` 翻转（荧光绿 + 浮板显隐）
    ///  5 发送（triggerSend 直接读 tv，见 InputFieldContainer）
    ///  6 去抖 300ms 无键入（草稿落盘；**读触发时刻的 tv.text**，kimi Y2）
    /// 6b 最大间隔 1.5s（codex A1）：连续输入无空档时去抖不到点，这条兜底
    ///  7 外部写照旧走 updateUIView（四类契约不变）
    ///  8 commitNow()（外部写/上游读 binding 之前，kimi B1）
    ///  9 斜杠模式逐键提交（kimi B2：浮板 prefix 渐进过滤）
    /// 10 末尾 @token 逐键提交（文件库候选，plan-input-file-mention）
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatInputRepresentable
        weak var textView: ChatInputTextView?
        /// 外部写入旗（IOSPromptTextView 同款）：防 tv.text = 外部值 触发 delegate 回环
        var isApplyingExternalText = false
        /// 上一次写进 binding 的文本（上行镜像基准；下行已走命令通道，不再作外部写判据）
        var lastCommittedText = ""
        /// 命令新鲜度水位（plan-input-command-channel）：gen 在 handle 上跨重挂单调，
        /// `cmd.gen > lastAppliedGen` 才收——迟到 body 不携带命令，值回声整类免疫。
        var lastAppliedGen = 0
        /// 组字期到达的非空命令挂起，didChange / endEditing 解除组字后重放；
        /// 重放校验 cmd.session == 当前 sessionKey（语义同 codex A2，但按命令身份不按值）
        var pendingCommand: InputCommand?

        /// 提交点 1 的比较基准：(本宽下封顶高, 宿主判模式那个窄宽下的行数)
        private var lastHeight: CGFloat = -1
        private var lastModeLines = -1
        /// 去抖（提交点 6）与打字空闲（C3）各一个
        private var debounce: DispatchWorkItem?
        private var idleWork: DispatchWorkItem?
        /// 上一次提交的时刻（提交点 6b 的最大间隔闸；CACurrentMediaTime 单调，不受改系统时间影响）
        private var lastCommitAt: CFTimeInterval = 0

        private static let debounceSeconds = 0.3
        /// 提交点 6b（codex A1）：光有尾随去抖不等于「至少每 300ms 落一次」——**连续输入没有
        /// 300ms 空档时去抖永远不到点**，进程被杀会把整段丢掉。这条是硬上限：自上次提交起
        /// 超过它且还有没提交的键入，下一键强制提交一次。
        private static let maxCommitGapSeconds: CFTimeInterval = 1.5
        private static let typingIdleSeconds = 0.6

        init(parent: ChatInputRepresentable) { self.parent = parent }

        deinit {
            debounce?.cancel()
            idleWork?.cancel()
        }

        // MARK: 提交

        /// 立即把 UITextView 真相刷进 binding（提交点 8 / 5 / 2 共用）
        func commitNow() {
            guard let tv = textView else { return }
            commit(tv, reason: "now")
        }

        private func commit(_ tv: UITextView, reason: String) {
            debounce?.cancel()
            debounce = nil
            let live = tv.text ?? ""
            resetLayoutSignature(tv)
            // ime-residual T3c：必须在下面的早退 **之前**——resign 定稿/commitNow 时 unmarkText
            // 只去标记不改字符串，正好命中 live == lastCommitted 早退，放尾部等于没修（双席阻断）
            syncScrollEnabled(tv)
            // 无论有没有真写 binding，都重置最大间隔闸的起点：live == lastCommitted 时
            // 本来就没有未提交的东西，闸没有理由继续走
            lastCommitAt = CACurrentMediaTime()
            guard live != lastCommittedText else { return }
            #if DEBUG
            INPROBE("commit(\(reason)) \(lastCommittedText.count)→\(live.count) marked=\(tv.markedTextRange != nil ? 1 : 0)")
            HitchProbe.mark("commit \(reason) len=\(live.count)")
            InputPerfProbe.countCommit()
            #endif
            lastCommittedText = live
            if reason == "layout" {
                // C-slide：高度变的这一笔带曲线——carrier 定高、根钉底，换行是纯 SwiftUI 内部重排，
                // 这里就是唯一的动画时钟（底边由构造固定，只有上边缘走）。
                withAnimation(.easeOut(duration: KeyboardInsetBridge.fieldHeightAnimation)) {
                    parent.text = live
                }
            } else {
                parent.text = live
            }
        }

        /// 命令入口（ChatInputHandle.issueText 即时投递）。gen 单调：迟到/重复命令直接丢。
        /// 空命令穿透 marked（发送清空不留幽灵拼音，原「空清穿透」契约原样保留）。
        func apply(_ cmd: InputCommand) {
            guard cmd.gen > lastAppliedGen else {
                #if DEBUG
                INPROBE("CMD stale gen=\(cmd.gen) applied=\(lastAppliedGen)")
                #endif
                return
            }
            lastAppliedGen = cmd.gen
            guard let tv = textView else { return }
            if tv.markedTextRange != nil, !cmd.text.isEmpty {
                #if DEBUG
                INPROBE("CMD pending gen=\(cmd.gen) len=\(cmd.text.count)")
                #endif
                pendingCommand = cmd   // 新命令覆盖旧 pending：只有最新的算数
                return
            }
            land(cmd, to: tv)
        }

        /// 命令落地（apply 与组字解除重放共用）——原 applyExternal 内容平移
        func land(_ cmd: InputCommand, to tv: ChatInputTextView) {
            #if DEBUG
            INPROBE("CMD land gen=\(cmd.gen) \(tv.text.count)→\(cmd.text.count)")
            #endif
            isApplyingExternalText = true
            tv.text = cmd.text
            tv.selectedRange = NSRange(location: (cmd.text as NSString).length, length: 0)
            isApplyingExternalText = false
            lastCommittedText = cmd.text
            pendingCommand = nil
            lastCommitAt = CACurrentMediaTime()
            if parent.text != cmd.text { parent.text = cmd.text }   // 镜像兜底（调用点一般已写）
            resetLayoutSignature(tv)
            syncScrollEnabled(tv)
        }

        // MARK: 提交点 1 的签名

        /// 当前文本在 (本宽 + 当前 inset) 下的封顶高，和在宿主判模式那个窄宽下的行数。
        /// 前者变 = SwiftUI 必须重问 sizeThatFits；后者变 = 宿主的 updateMultiline 该翻了。
        private func layoutSignature(_ tv: UITextView) -> (CGFloat, Int) {
            guard let font = tv.font else { return (-1, -1) }
            let text = tv.text ?? ""
            let w = tv.bounds.width
            let h: CGFloat = w > 1
                ? min(ChatInputTextView.contentHeight(text: text, font: font, width: w, inset: tv.textContainerInset),
                      ChatInputTextView.capHeight(font: font))
                : -1
            let probeW = parent.modeProbeWidth
            let lines = probeW > 30
                ? ChatInputTextView.lineCount(text: text, font: font, width: probeW, inset: ChatInputTextView.singleInset)
                : -1
            return (h, lines)
        }

        func resetLayoutSignature(_ tv: UITextView) {
            let sig = layoutSignature(tv)
            lastHeight = sig.0
            lastModeLines = sig.1
        }

        /// C9/A4（F5）：封顶以下关内滚。字段长高动画的 0.22s 里 frame 比内容矮，UITextView 会先把
        /// 首行滚上去露光标（抽帧：文字先跳 ~11pt 再回落）。封顶以下没有合法的非零 offset，关掉
        /// 让文字随上边缘走。带一行迟滞防边界抖动。
        /// ime-residual T3a：marked 护栏只挡「关」（组字期布局易变不做关）——**开滚不受组字阻挡**，
        /// 否则长拼音组字越顶时 didChange 全程早退、isScrollEnabled 卡 false 滚不动（E1）。
        func syncScrollEnabled(_ tv: UITextView) {
            guard let font = tv.font, tv.bounds.width > 1 else { return }
            let content = ChatInputTextView.contentHeight(text: tv.text ?? "", font: font,
                                                          width: tv.bounds.width, inset: tv.textContainerInset)
            let cap = ChatInputTextView.capHeight(font: font)
            if tv.isScrollEnabled {
                guard tv.markedTextRange == nil else { return }
                // 迟滞：低于封顶一行才关，贴着封顶来回打不翻转
                if content < cap - font.lineHeight + 1 {
                    let sel = tv.selectedRange
                    tv.isScrollEnabled = false
                    if tv.contentOffset != .zero { tv.contentOffset = .zero }
                    tv.selectedRange = sel
                    #if DEBUG
                    INPROBE("scroll OFF content=\(Int(content)) cap=\(Int(cap)) cs=\(Int(tv.contentSize.height)) b=\(Int(tv.bounds.height))")
                    #endif
                }
            } else if content >= cap - 0.5 {
                // T8x：达到六行即允许内滚，避免临界测量误差把最后一行锁在视口外。
                // 封顶以下仍关滚；关闭阈值沿用上面的一行迟滞。
                tv.isScrollEnabled = true
                #if DEBUG
                INPROBE("scroll ON content=\(Int(content)) cap=\(Int(cap)) cs=\(Int(tv.contentSize.height)) b=\(Int(tv.bounds.height))")
                #endif
            }
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ tv: UITextView) {
            guard !isApplyingExternalText else { return }
            syncScrollEnabled(tv)

            // 组字结束 → 重放组字期挂起的命令（契约不变：外部写赢，这一键的内容被覆盖）。
            // 会话守卫（codex A2 同义）：命令自带目标 session，换会话的旧命令丢弃。
            if let cmd = pendingCommand, tv.markedTextRange == nil,
               let chatTV = tv as? ChatInputTextView {
                if cmd.session == ChatInputHandle.shared.sessionKey {
                    #if DEBUG
                    INPROBE("CMD REPLAY after marked gen=\(cmd.gen) \(tv.text.count)→\(cmd.text.count)")
                    #endif
                    land(cmd, to: chatTV)
                    return
                }
                #if DEBUG
                INPROBE("CMD REPLAY DROP gen=\(cmd.gen) (session \(cmd.session ?? "-")→\(ChatInputHandle.shared.sessionKey ?? "-"))")
                #endif
                pendingCommand = nil
            }

            #if DEBUG
            INPROBE("didChange live=\(tv.text.count) committed=\(lastCommittedText.count) marked=\(tv.markedTextRange != nil ? 1 : 0) scroll=\(tv.isScrollEnabled ? 1 : 0) cs=\(Int(tv.contentSize.height)) b=\(Int(tv.bounds.height)) off=\(Int(tv.contentOffset.y)) tail=⟨\((tv.text ?? "").suffix(12))⟩")
            HitchProbe.mark("didChange len=\(tv.text.count)")
            InputPerfProbe.countKey()
            #endif

            markTyping()

            let live = tv.text ?? ""
            let old = lastCommittedText
            let sig = layoutSignature(tv)

            var reason: String? = nil
            if sig.0 != lastHeight || sig.1 != lastModeLines {
                reason = "layout"                                       // 提交点 1
            } else if old.isEmpty != live.isEmpty
                        || old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            != live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = "empty"                                        // 提交点 3
            } else if old.hasPrefix("/") != live.hasPrefix("/") {
                reason = "slash"                                        // 提交点 4
            } else if parent.slashLive && live.hasPrefix("/") {
                reason = "slashLive"                                    // 提交点 9
            } else if tv.markedTextRange == nil,
                      FileMention.query(in: live) != nil || FileMention.query(in: old) != nil {
                // 提交点 10：末尾 @token 逐键提交（文件候选渐进过滤 / 收起）。组字期不提交，字上屏才出候选
                reason = "mention"
            } else if tv.markedTextRange == nil,
                      CACurrentMediaTime() - lastCommitAt >= Self.maxCommitGapSeconds {
                // 提交点 6b（codex A1）：连续输入没空档，去抖永远不到点 → 最大间隔兜底。
                // 组字期间照旧跳过；组字结束后这条判定自然还成立，那时补上。
                reason = "maxGap"
            }

            if let reason {
                commit(tv, reason: reason)
            } else {
                // 这一支里 sig == (lastHeight, lastModeLines)，签名无需更新
                scheduleDebounce()                                      // 提交点 6
            }

            // ime-residual T8：越 cap 后逐键打字换行，UITextView 原生光标跟随失灵（off 卡旧行、
            // 新行整行在视口外，真机+模拟器双定罪 evidence §T8）。这里补的是系统没做的事，
            // 不是「纠正别人的写入」（C2 原则豁免见 plan §5）：光标真出视口才写 offset，
            // 幂等、光标可见时零写入（不打扰手动上翻）；contentOffset 不在键盘敏感集，组字期安全。
            if tv.isScrollEnabled {
                tv.layoutIfNeeded()
            }
            if tv.isScrollEnabled, let sel = tv.selectedTextRange {
                let caret = tv.caretRect(for: sel.end)
                let visBottom = tv.contentOffset.y + tv.bounds.height - tv.textContainerInset.bottom
                if caret.maxY.isFinite, caret.maxY > visBottom + 1 {
                    // T8x：contentSize 可能仍等于 cap，不能用它把已越界的 caret 目标钳回 0。
                    let target = max(0, caret.maxY + tv.textContainerInset.bottom - tv.bounds.height)
                    if abs(target - tv.contentOffset.y) > 0.5 {
                        tv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                        #if DEBUG
                        INPROBE("caret-follow off→\(target) actual=\(tv.contentOffset.y) caret=\(caret.maxY) cs=\(tv.contentSize.height) b=\(tv.bounds.height) marked=\(tv.markedTextRange != nil ? 1 : 0)")
                        #endif
                    }
                }
            }
        }

        #if DEBUG
        /// ime-residual 取证：组字死亡侦测。marked 从有到无而 didChange 没跑 = 组字被外力定稿
        ///（IME 自身/selection 变化/某个 UIKit 副作用）——正是粟粟 09-05 录屏 6.9s 无触摸变拼音
        /// 的现场。didChangeSelection 是 marked 生灭最细的观测点，只在翻转时打不刷屏。
        /// 09-05 二审：air-kb4.log 810317631.577 抓到「live 不变的 marked 死亡」（拼音原样定稿，
        /// 非选定）——死亡时打调用栈点名凶手（我们代码的某操作 vs IME/键盘进程自杀）。
        private var probeHadMarked = false
        func textViewDidChangeSelection(_ tv: UITextView) {
            let has = tv.markedTextRange != nil
            if has != probeHadMarked {
                INPROBE("marked \(probeHadMarked ? 1 : 0)→\(has ? 1 : 0) sel=\(tv.selectedRange.location),\(tv.selectedRange.length) live=\(tv.text.count) applying=\(isApplyingExternalText ? 1 : 0) tail=⟨\((tv.text ?? "").suffix(12))⟩")
                if probeHadMarked, !has {
                    // 09-06 二审：24 帧断在 performSingleTask 门口——入队者就在下一帧。40 帧终审。
                    KBProbe.log("[INPROBE] marked-death stack:\n" +
                        Thread.callStackSymbols.prefix(40).joined(separator: "\n"))
                }
                probeHadMarked = has
            }
        }

        /// ime-residual 取证（09-06 滚动复发）：拖动输入框瞬间打一发滚动现场。
        /// 有此行=isScrollEnabled 开着且手势活着；她报「滑不动」时若无此行=开关关死或手势被吞。
        func scrollViewWillBeginDragging(_ sv: UIScrollView) {
            guard sv is ChatInputTextView else { return }
            INPROBE("drag begin cs=\(Int(sv.contentSize.height)) b=\(Int(sv.bounds.height)) off=\(Int(sv.contentOffset.y))")
        }
        #endif

        func textViewDidBeginEditing(_ tv: UITextView) {
            resetLayoutSignature(tv)
            if !parent.focused {
                parent.focused = true                                   // 提交点 2
            }
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            // 组字被焦点切走也算结束：重放挂起命令，别把外部写吞了（会话守卫同 didChange）
            if let cmd = pendingCommand, let chatTV = tv as? ChatInputTextView {
                if cmd.session == ChatInputHandle.shared.sessionKey {
                    land(cmd, to: chatTV)
                } else {
                    pendingCommand = nil
                }
            }
            commit(tv, reason: "endEditing")                            // 提交点 2（离开前先记下来）
            if parent.focused {
                parent.focused = false
            }
        }

        // MARK: 去抖（提交点 6）与打字空闲（C3）

        /// ⚠️ kimi Y2：闭包到点时读**触发时刻**的 `tv.text`，禁止捕获调度时刻的文本——
        /// 否则「打字 → 300ms 内切对话 → loadDraft 写新草稿 → 去抖把旧尾巴提交进新对话」丢数据。
        private func scheduleDebounce() {
            debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.commit(tv, reason: "debounce")
            }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: work)
        }

        /// C3 的「打字期间环暂停」：每键重排 600ms 定时器，但只在**翻转**时写 SwiftUI
        ///（每轮打字 2 次 body，不是每键一次）
        private func markTyping() {
            if parent.typingIdle {
                parent.typingIdle = false
            }
            idleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if !self.parent.typingIdle { self.parent.typingIdle = true }
            }
            idleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingIdleSeconds, execute: work)
        }
    }
}
#endif
