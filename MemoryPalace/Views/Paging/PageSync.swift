#if os(iOS)
import SwiftUI
import UIKit

/// 翻页解耦开关（plan-paging-decouple §1 / §3）。DEBUG / PERF 包进程启动读一次 env，精确设 `0` 回退；上架 Release 恒开。
enum PagingSwitch {
    /// B-core：iOSPage 只由 PageSync 读，翻页走命令通道；0 = 原 binding 链（ContentView.body 读 iOSPage → updatePages）
    static let pageSync = flag("MP_PAGING_PAGESYNC")
    /// A-deck：三页停靠都在 x=0 叠放、只写 layer 仿射变换 + zPosition；0 = 原停靠几何（page2 走 UIView.transform）
    static let deck = flag("MP_PAGING_DECK")
    /// A-deck 子开关：0 = page2 回 UIView.transform 路径（0↔1 照旧叠牌），1↔2 落定段变重时先关它取证（plan §1.3）
    static let deckPage2 = flag("MP_PAGING_DECK_PAGE2")
    /// 落定后下一帧的 scheduleLayerSync（UIView setter 刷 SwiftUI 窗口坐标缓存）。叠牌下先留着（R1 s11），
    /// 0 = 不刷；默认改 0 要等 §1.4 的合后证据清单全过（A-9）
    static let layerSync = flag("MP_PAGING_LAYERSYNC")

    static func flag(_ key: String) -> Bool {
        #if DEBUG || PERF_BENCH
        return ProcessInfo.processInfo.environment[key] != "0"
        #else
        return true
        #endif
    }
}

/// ContentView 交给分页壳的「内容键」：这几样变了，三页 rootView 重交是正当的（C 的精确例外，plan §4.1）。
/// 全是 ContentView.body 本来就读的值，不新增订阅。
struct PagingContentKey: Equatable {
    var conversation: String?
    var destination: String
    var profile: String
    var wide: Bool
    var theme: String
    var stickers: Bool

    /// 和上一次比，变了的第一个键名；没变返回 nil
    func changedName(from old: PagingContentKey?) -> String? {
        guard let old else { return "initial" }
        if conversation != old.conversation { return "conversation" }
        if destination != old.destination { return "destination" }
        if profile != old.profile { return "profile" }
        if wide != old.wide { return "wide" }
        if theme != old.theme { return "theme" }
        if stickers != old.stickers { return "stickers" }
        return nil
    }
}

/// 翻页命令通道（plan §3.2）：PageSync 把 iOSPage 的变化翻成命令，分页壳在 viewDidLoad 注册。
/// 弱引用当前分页壳；楼层切换 / dismantle 注销，旧注册上的在途命令随之作废。
@MainActor
final class PagingCommands {
    static let shared = PagingCommands()
    private var logic = PagingCommandLogic()
    private weak var controller: PagingViewController?
    /// 注册且第一次布局宽度 > 0 之后才执行命令；之前到的只留最新目标
    private var ready = false

    func register(_ vc: PagingViewController) {
        if let old = controller, old !== vc { PagingFlip.ownerGone(ObjectIdentifier(old)) }
        controller = vc
        ready = false
        logic.invalidate()
    }

    func unregister(_ vc: PagingViewController) {
        PagingFlip.ownerGone(ObjectIdentifier(vc))
        guard controller === vc else { return }
        controller = nil
        ready = false
        logic.invalidate()
    }

    func controllerLaidOut(_ vc: PagingViewController) {
        guard controller === vc, !ready else { return }
        ready = true
        // 冷启动 / 注册前到的命令：第一次布局后无动画对齐（同原 binding 链在布局前到达时的效果）
        if let page = logic.takePending() { scrollTo(page, animated: false, contentReady: nil) }
    }

    func scrollTo(_ page: Int, animated: Bool, contentReady: (() -> String?)?) {
        let current = ready ? controller?.programmaticCurrentPage : nil
        switch logic.receive(target: page, currentPage: current) {
        case .stored:
            break
        case .alreadyThere:
            PagingFlip.settleIfIdle()
        case .run(let generation):
            controller?.performCommand(page, animated: animated, contentReady: contentReady, generation: generation)
        }
    }

    func isCurrent(_ generation: Int) -> Bool { logic.isCurrent(generation) }
    func started(_ generation: Int) { logic.started(generation) }
}

/// iOSPage 的唯一读者（plan §3.2）：翻页副作用（原 ContentView `onChange(of: iOSPage)` 原样）+ 触感 + 全局音乐胶囊 + 发翻页命令。
/// 它是 ContentView 的一个子视图：iOSPage 变只让它自己重算，ContentView.body 不再因翻页重算、三页 rootView 不再重交。
struct PageSync: View {
    @Binding var page: Int
    @Binding var suppressEffects: Bool
    let isChatDestination: Bool
    let isWidePanelMode: Bool
    let musicCapsuleEnabled: Bool
    let viewModel: ConversationViewModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(width: 0, height: 0)
            // 音乐全局挂着（粟粟 09-28：除了 sheet 去哪都在）。聊天页（窄屏）由顶栏的岛 / 气泡模式那一行负责，这里不重复
            if musicCapsuleEnabled, !(page == 1 && isChatDestination && !isWidePanelMode) {
                MusicNowPlayingCapsule(viewModel: viewModel, alwaysShow: true) {
                    withAnimation { page = 1 }
                }
                .padding(.top, 4)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: page) { _, _ in !suppressEffects }
        .onAppear {
            PagingFlip.noteSwiftUIPage(page)
            // 楼层切换 .id(profileId) 重建时 page 回到初值，单例要跟着重置（#058：不然花园冻在聊天页、液态金属离屏照跑）
            Page0Stage.shared.isOnScreen = page == 0
            if PagingSwitch.pageSync { PagingCommands.shared.scrollTo(page, animated: false, contentReady: nil) }
        }
        .onChange(of: page) { oldPage, newPage in
            PagingFlip.noteSwiftUIPage(newPage)
            if PagingSwitch.pageSync {
                PagingCommands.shared.scrollTo(newPage, animated: true, contentReady: contentReady(for: newPage))
            }
            Page0Stage.shared.isOnScreen = newPage == 0   // page0 网点背景只在屏上时跑
            guard !suppressEffects else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            let pageNames = ["列表", "聊天", "更多"]
            BreadcrumbLog.shared.add("📱", "切到\(pageNames[min(max(newPage, 0), 2)])页")
            // 从聊天页切回 sidebar 时立刻 flush 挂起的重排 → 用户几乎看不到 3s 等待。
            // 每次都刷（聊天页里删除 / 收藏 / 移文件夹 / 起标题等写入口不通知列表，靠这里兜底——astra R4）；
            // perf-flash C5′：延到下一次 display-link 回调再刷，把重查 100 行 + 整表比对从落定那一段主线程里分摊出去
            if oldPage == 1 && newPage == 0 {
                NextFrame.run { viewModel.flushPendingRefresh() }
            }
            // 焦点上报：只有对话页(1)算「在看该会话」，列表/终端页都算没在看 → hub 据此决定推不推
            CCBridgeWebSocketClient.shared.updateFocus(
                newPage == 1 && isChatDestination ? viewModel.selectedConversation?.id : nil
            )
        }
    }

    /// 翻到聊天页时「新内容先挂上再滑」（plan §3.3）：选中的对话已加载完；分页壳再等聊天页布局过一次，上限 300ms。
    /// 返回当前内容的身份（对话 id + 加载代次），没就绪返回 nil——分页壳每帧重查，身份变了就重新等布局（R2-02）
    private func contentReady(for page: Int) -> (() -> String?)? {
        guard page == 1, isChatDestination else { return nil }
        return { [weak viewModel] in
            guard let viewModel else { return "gone" }
            guard let id = viewModel.selectedConversation?.id, !viewModel.isLoading else { return nil }
            return "\(id)#\(viewModel.loadGeneration)"
        }
    }
}

/// 分页壳入口计数（plan §4.1–4.2，C-1）：翻页窗口 = 手指按下 / 命令进入 → 落定后第 2 个 display-link 回调。
/// 窗口内分页壳主动发出的入口（updatePages、页 rootView 赋值、page2 隐藏应用 rootView 赋值、页容器 UIView 几何 setter）
/// 必须为 0，除非按事件精确例外（内容键变了 / 宿主尺寸变了 / 该应用自己的输入变了）。只在 DEBUG / PERF 包计数，上架包是空函数。
@MainActor
enum PagingFlip {
    enum Entrance: String {
        case updatePages, rootAssign, hiddenAppRootAssign, containerSetter, endState
    }

    /// 窗口开始时分页壳交来的上下文（页码 + 环境）：全部从 UIKit / 分页壳自己持有的状态非观察地读，不读 SwiftUI 状态（plan §4.3）
    struct Context {
        /// 窗口所属的分页壳（楼层重建会换一个；结束页码只认同一宿主）
        var owner: ObjectIdentifier
        var page: Int
        var streaming: Bool
        var keyboard: Bool
        var wide: Bool
        var page2Apps: Int
        var deck: Bool
    }

    #if DEBUG || PERF_BENCH
    /// 一个翻页窗口的账（C-4 写进 #032 哨兵的 `paging` 记录，字段语义见 plan §4.3）
    private struct Window {
        var id: Int
        var start: Double
        var settleAt: Double?
        var trigger: String
        var from: Int
        var context: Context
        /// 开窗时那个分页壳的上下文来源（楼层重建后全局 context 换人，这个不换，R2-04）
        var provider: () -> Context?
        /// 落定那一刻的页码（宿主没了时的结束页码）
        var settlePage: Int?
        var counts: [Entrance: Int] = [:]
        var layerSync = 0
        var excepted = 0
        var causes: [String] = []
        var violations = 0
        var violationEntrance = ""
        var violationAddrs = ""
        var interrupt: String?
        var endStateOK = true
    }

    private static var window: Window?
    private static var endToken = 0
    private static var safetyToken = 0
    private static var cause: String?
    /// 每个入口每进程只取一次违规返回地址（离线用存档 dSYM 符号化，主线程不取符号，R1 s20）
    private static var addrsTaken: Set<Entrance> = []
    private(set) static var windows = 0
    /// 已关闭（落定后第 2 帧收尾完、记录已交）的窗口数和最后关闭的 windowId（R2-06：测试按它等收尾段）
    private(set) static var closedWindows = 0
    private(set) static var swiftUIPage = -1
    private(set) static var lastClosedId = 0
    private(set) static var entrances = 0
    private(set) static var violations = 0
    private(set) static var firstViolation = ""
    private(set) static var layerSyncWrites = 0
    /// 窗口内 page2 不可见应用宿主的 rootView 赋值次数（含例外，B-6 验收看它）
    private(set) static var hiddenAppAssigns = 0
    private(set) static var commandTimeouts = 0
    /// 最近一次超时缺的是哪样（诊断）：content = 选中对话还没加载完；layout = 标记后聊天页没再布局；revision = 最新根版本没布局过
    private(set) static var lastTimeoutReason = ""
    private(set) static var endStateChecks = 0
    private(set) static var endStateBad = 0
    /// 最近一次终态不一致的是哪几样（offset / page / axN / hitN / zN / txN）
    private(set) static var lastEndStateBad = ""
    /// 最近一次中断收尾的原因（§1.9；哨兵记录里是 endReason=interrupted:<原因>）
    private(set) static var lastInterrupt = ""
    /// 交给哨兵的 paging 记录条数（哨兵关着时 append 是空操作，这里照样数——它只证明「每个窗口都交了」）
    private(set) static var sentinelRecords = 0
    static var onWindowEnd: (() -> Void)?
    /// 分页壳在 viewDidLoad 装：窗口开始 / 结束时取页码和环境
    static var context: (() -> Context?)?
    /// 测量台合成驱动（perfDrive）进行中：窗口 trigger 记 synthetic
    static var synthetic = false
    #endif

    /// 新一次翻页开始：上一窗口（还在两帧收尾、或被这次打断）先按实际结束，再开新窗口（R2-04）
    static func begin(_ trigger: String) {
        #if DEBUG || PERF_BENCH
        endToken += 1
        if window != nil { end() }
        if let provider = context, let ctx = provider() {
            windows += 1
            window = Window(id: windows, start: CACurrentMediaTime(), trigger: synthetic ? "synthetic" : trigger, from: ctx.page,
                            context: ctx, provider: provider)
        }
        armSafety()
        #endif
    }

    /// 分页壳注销 / 楼层切换 / 换了新宿主：它的窗口就地结束，页码取它自己的
    static func ownerGone(_ owner: ObjectIdentifier) {
        #if DEBUG || PERF_BENCH
        guard let w = window, w.context.owner == owner else { return }
        endToken += 1
        end()
        #endif
    }

    /// 窗口里这次翻页其实不动画（减弱动态 / 宽屏 / 无动画命令）
    static func noteNoAnimation() {
        #if DEBUG || PERF_BENCH
        if window != nil, !synthetic { window?.trigger = "noAnimation" }
        #endif
    }

    /// 落定 / 程序化动画结束：再过两个 display-link 回调收窗口
    static func settle() {
        #if DEBUG || PERF_BENCH
        guard let w = window else { return }
        window?.settleAt = CACurrentMediaTime()
        window?.settlePage = w.provider()?.page
        endToken += 1
        let token = endToken
        NextFrame.run {
            NextFrame.run {
                guard token == endToken else { return }
                end()
            }
        }
        #endif
    }

    /// 命令落空（目标就是当前页）：没有在拖 / 在滚时收窗口
    static func settleIfIdle() {
        #if DEBUG || PERF_BENCH
        guard window != nil, let sv = PagingViewController.sharedScrollView, !sv.isDragging, !sv.isDecelerating else { return }
        settle()
        #endif
    }

    /// 精确例外的原因（同一次调用里有效）：PagingContainerView 在 updatePages 前按内容键签名设
    static func withCause(_ value: String?, _ body: () -> Void) {
        #if DEBUG || PERF_BENCH
        let saved = cause
        cause = value
        body()
        cause = saved
        #else
        body()
        #endif
    }

    static func hit(_ entrance: Entrance, excepted: String? = nil) {
        #if DEBUG || PERF_BENCH
        guard window != nil else { return }
        entrances += 1
        window?.counts[entrance, default: 0] += 1
        if entrance == .hiddenAppRootAssign { hiddenAppAssigns += 1 }
        if let reason = excepted ?? cause {
            window?.excepted += 1
            if window?.causes.contains(reason) == false { window?.causes.append(reason) }
            return
        }
        violations += 1
        window?.violations += 1
        if firstViolation.isEmpty { firstViolation = entrance.rawValue }
        if window?.violationEntrance.isEmpty == true {
            window?.violationEntrance = entrance.rawValue
            if addrsTaken.insert(entrance).inserted {
                window?.violationAddrs = Thread.callStackReturnAddresses.dropFirst().prefix(12)
                    .map { String(format: "0x%lx", $0.uintValue) }.joined(separator: ",")
            }
        }
        #endif
    }

    static func noteLayerSync() {
        #if DEBUG || PERF_BENCH
        guard window != nil else { return }
        layerSyncWrites += 1
        window?.layerSync += 1
        #endif
    }

    /// §1.9 五样终态核对一次（不一致同时记一条 endState 入口违规，无例外）
    static func noteEndState(_ ok: Bool, detail: String = "") {
        #if DEBUG || PERF_BENCH
        endStateChecks += 1
        if !ok { endStateBad += 1; lastEndStateBad = detail; window?.endStateOK = false; hit(.endState) }
        #endif
    }

    /// SwiftUI 侧（iOSPage）最后一次看到的页码：PageSync 在 onAppear / onChange 里记，不订阅任何东西（R2-07）。
    /// 手势落定后它要等下一轮回写才跟上分页壳；UI 测试拿它独立核「SwiftUI 页码 == 分页壳页码」
    static func noteSwiftUIPage(_ page: Int) {
        #if DEBUG || PERF_BENCH
        swiftUIPage = page
        onWindowEnd?()
        #endif
    }

    static func noteInterrupt(_ reason: String) {
        #if DEBUG || PERF_BENCH
        lastInterrupt = reason
        window?.interrupt = reason
        #endif
    }

    static func noteCommandTimeout(_ reason: String) {
        #if DEBUG || PERF_BENCH
        lastTimeoutReason = reason
        commandTimeouts += 1
        #endif
    }

    #if DEBUG || PERF_BENCH
    static var axFields: String {
        "flipWindows=\(windows);flipClosed=\(closedWindows);flipLastClosed=\(lastClosedId);flipEntrances=\(entrances);flipViolations=\(violations);flipViolationEntrance=\(firstViolation);flipLayerSync=\(layerSyncWrites);flipHiddenAssigns=\(hiddenAppAssigns);cmdWaitTimeouts=\(commandTimeouts);cmdWaitLast=\(lastTimeoutReason);endStateChecks=\(endStateChecks);endStateBad=\(endStateBad);endStateLastBad=\(lastEndStateBad);lastInterrupt=\(lastInterrupt);swiftUIPage=\(swiftUIPage);sentinelPaging=\(sentinelRecords)"
    }

    private static func end() {
        guard let w = window else { return }
        window = nil
        record(w, end: CACurrentMediaTime())
        closedWindows += 1
        lastClosedId = w.id
        onWindowEnd?()
    }

    /// C-4：每个窗口一条 `paging` 记录交 #032 哨兵（零违规也写，plan §4.3）。哨兵只收 String / Bool / Int / 有限 Double，
    /// 有一个字段不合格整条丢——这里全部显式换成 Int / Double / String / Bool，时间先核有限
    private static func record(_ w: Window, end: Double) {
        let to = w.provider()?.page ?? w.settlePage ?? w.from
        let settle = w.settleAt ?? end
        guard w.start.isFinite, end.isFinite, settle.isFinite else { return }
        let reason: String
        if let interrupt = w.interrupt { reason = "interrupted:\(interrupt)" }
        else if w.settleAt == nil { reason = "interrupted:superseded" }
        else if to == w.from { reason = "returned" }
        else { reason = "settled" }
        let fields: [String: Any] = [
            "schema": 1,
            "windowId": w.id,
            "start": w.start,
            "end": end,
            "settleAt": settle,
            "trigger": w.trigger,
            "endReason": reason,
            "from": w.from,
            "to": to,
            "swDeck": PagingSwitch.deck && w.context.deck,
            "swLayerSync": PagingSwitch.layerSync,
            "swPageSync": PagingSwitch.pageSync,
            "swDeckPage2": PagingSwitch.deckPage2,
            "nUpdatePages": w.counts[.updatePages, default: 0],
            "nRootAssign": w.counts[.rootAssign, default: 0],
            "nHiddenAppRootAssign": w.counts[.hiddenAppRootAssign, default: 0],
            "nContainerSetter": w.counts[.containerSetter, default: 0],
            "nLayerSync": w.layerSync,
            "nExcepted": w.excepted,
            "exceptCauses": w.causes.joined(separator: ","),
            "violations": w.violations,
            "violationEntrance": w.violationEntrance,
            "violationAddrs": w.violationAddrs,
            "endStateOK": w.endStateOK,
            "diagStreaming": w.context.streaming,
            "diagKeyboard": w.context.keyboard,
            "diagReduceMotion": UIAccessibility.isReduceMotionEnabled,
            "diagVoiceOver": UIAccessibility.isVoiceOverRunning,
            "diagWide": w.context.wide,
            "diagLowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "diagPage2Apps": w.context.page2Apps,
            "diagPageBodies": -1,
        ]
        sentinelRecords += 1
        AirStallSentinel.append(type: "paging", fields: fields)
    }

    /// 保险：没落定信号（同位置无动画 setContentOffset 不回调）也别让窗口一直开着
    private static func armSafety() {
        safetyToken += 1
        let token = safetyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard token == safetyToken, window != nil else { return }
            if let sv = PagingViewController.sharedScrollView, sv.isDragging || sv.isDecelerating { armSafety(); return }
            settle()
        }
    }
    #endif
}
#endif
