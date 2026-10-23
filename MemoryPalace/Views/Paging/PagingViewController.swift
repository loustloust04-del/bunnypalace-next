#if os(iOS)
import UIKit
import SwiftUI
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins

/// UIKit 翻页容器：内嵌 `UIScrollView(.horizontal) + paging` + 3 个独立 `UIHostingController`。
///
/// 架构目的：解决 Phase 2 v1 里 SwiftUI `.ignoresSafeArea` extension 不跟 `.offset` 走的
/// 结构性 bug——每页一个独立 `UIHostingController`，每页的 `.ignoresSafeArea` scope 限在该 HC，
/// 翻页由 UIScrollView 的 contentOffset 驱动页面外壳，extension 作为 HC 内部 subview
/// 跟着走，相邻页的 safe area 区不会有 wallpaper 残影。
///
/// 设计要点：
/// - `isPagingEnabled = true` + `bouncesHorizontally = false`（iOS 17.4+），硬禁水平 bounce
/// - `contentInsetAdjustmentBehavior = .never`，不自动 adjust（防止 safe area insets 干扰 paging step）
/// - `decelerationRate = .fast`，paging snap 更利落
/// - 外壳按 i·pageW 排列，HC 在外壳内使用原点为零的固定 bounds；通过
///   `addChild + didMove(toParent:)` 建立 VC hierarchy（让每页 HC 的 safe area 继承正常工作)
///
/// Wallpaper：壁纸挂聊天页 UIKit 外壳底层，与聊天页一起覆盖/退回，不走
/// SwiftUI `.background` layer。原因：A10 实测 SwiftUI `.background { .ignoresSafeArea() }`
/// 的 content frame 响应 keyboard safeArea 等比放大 13%（484×1051 vs 427×929），虽然
/// UIKit `view.bounds` 不变但 SwiftUI layer frame 变 → 视觉"背景跟着键盘动"。UIKit
/// UIImageView 的 frame 由 `viewDidLayoutSubviews` 控制，键盘弹起时 `viewDidLayoutSubviews`
/// 不 fire（实测 log 印证），根治。参考 `docs/research-wallpaper-uikit-layer.md`。
@MainActor
final class PagingViewController: UIViewController, UIScrollViewDelegate {
    /// 暴露给 iOSTabBarGestureBlocker 用的 weak ref：sidebar tab 栏横滑时让水平 paging 的
    /// scrollView.panGestureRecognizer require(toFail: tab 栏 blockerPan)。整个 app 只有一个
    /// PagingViewController 实例（外层 SwiftUI iOSLayout 创建），用 static 单例最简洁。
    static weak var sharedScrollView: UIScrollView?

    private let scrollView = UIScrollView()
    private var requestedScrollEnabled = true
    private var page2DragLockOwners: Set<UUID> = []
    private var hostingControllers: [UIHostingController<AnyView>] = []
    private var pageContainers: [UIView] = []
    private var pageDimmers: [UIView] = []
    private let pageShadow = UIView()
    private var currentPage: Int {
        didSet {
            Page2SceneState.shared.isActive = currentPage == 2
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            applyPageInteraction()
            // 离开聊天页（任何途径：拖动 / 顶部箭头 / tab）：丢掉录到一半 / 预览中的语音（plan-voice-note sol P1-1）
            if currentPage != 1, oldValue == 1 { VoiceRecordController.shared.chatPageLeft() }
        }
    }
    /// 记录上次 layout 时的 bounds.width。每次 bounds 变化要 re-sync contentOffset，
    /// 避免 SwiftUI representable 首次 layout 给瞬时过渡 bounds 导致 initial offset 错位。
    private var lastLaidOutWidth: CGFloat = 0

    /// 手动翻页（用户拖动松手）稳定后回写 SwiftUI binding。
    var onPageChanged: ((Int) -> Void)?

    // MARK: - Wallpaper (Step 3)

    private let wallpaperContainer = UIView()
    private let wallpaperImageView = UIImageView()
    private let wallpaperGradientLayer = CAGradientLayer()
    private var lastImageURL: URL?
    private var lastSaturation: CGFloat = 1.0

    /// 上次完整 apply 过的 wallpaper config。同 config 时跳过整个 applyWallpaper（含
    /// backgroundColor / alpha / transform / gradient setter），减少 idle / 切对话路径
    /// CALayer 多余 commit。WallpaperConfig 7 字段 Equatable，gradientColors 用 cgColor
    /// 比较（UIColor == 是 ref-compare，cgColor 是值）。
    /// 见 docs/plan-perf-2026-04-25.md 线 a + Hermes Q3：Apple 不保证 alpha/transform/
    /// colors/bgColor 任何 setter idempotent，hot path 自己 guard 是合理。
    private var lastAppliedWallpaperConfig: WallpaperConfig?

    // MARK: - Home Indicator Hit Shield
    /// home indicator 区透明 hit shield。挂在 PagingViewController.view 顶层（z 高于 scrollView），
    /// frame 由 viewDidLayoutSubviews + viewSafeAreaInsetsDidChange 同步，高度 = min(window
    /// safeAreaInsets.bottom, 40)。挂 UIKit 层 + 用 window 的 safeAreaInsets（不取 chat HC 的
    /// 因为 chat HC additionalSafeAreaInsets 会被键盘改），命中链稳定不漂。
    /// 可见性：currentPage == 1 (chat 页) && !disableScroll (非 sticker 编辑模式)。
    /// V3 SwiftUI overlay 时灵时不灵 → V4 改 UIKit 层（codex 建议 + Apple docs hitTest D3 / safeAreaInsets D2）。
    private let homeIndicatorShield = HomeIndicatorHitShieldUIView()
    /// 宽屏悬浮面板形态（见 `setWidePanelMode`）
    private var widePanelMode = false

    // 页码点（perf-flash C1：原是 ContentView 的 @State + body overlay，每次翻页浮现 / 淡出各带一轮
    // ContentView.body + 三页 rootView 重赋；下沉到这里，规则照旧：翻页浮现 ~1s 后淡出，
    // 键盘弹起 / 宽屏 / page2 不显示）
    private let pageDots = UIStackView()
    private var pageDotsHide: DispatchWorkItem?
    /// 本轮浮现期限内（与「此刻能不能显示」分开管：键盘 / 宽屏遮挡不清期限，astra R2 C1）
    private var pageDotsShowing = false
    private var keyboardShownForDots = false
    private var pageDotsObservers: [NSObjectProtocol] = []
    private var shieldHiddenByCaller: Bool = false   // 外部（PagingContainerView）显式 hide

    /// CIFilter 创建 GPU context 有开销，共享一个全局实例。
    /// xcdoc: /documentation/CoreImage/CIFilter-swift.class/colorControls()
    private static let sharedCIContext = CIContext()

    // B2（plan-keyboard-layoutguide）：输入条独立 host——挂 chat HC.view 的 UIKit 子层，
    // 底边约束 keyboardLayoutGuide.topAnchor（系统逐帧驱动 = 弹起丝滑 + 拖拽跟手）。
    private var inputBarHost: UIHostingController<AnyView>?
    private var inputBarContainer: UIView?
    private var inputBarBoundsObs: NSKeyValueObservation?
    private var inputBarCenterObs: NSKeyValueObservation?
    private var barKickCancellable: AnyCancellable?
    /// kbTransitioning 卡死保险的代际号（didChangeFrame 丢失时 1.5s 后强制清，防按钮永久消失）
    private var kbTransitionGen = 0
    /// 正文平移动画代际（新动画替换旧动画时旧 completion 作废）
    private var slideGen = 0
    /// 正文平移是否在飞（弹起打断收起时不做绝对值钉位，让 .beginFromCurrentState 从表现层接着走）
    private var slideInFlight = false
    /// 最近一次 keyboardWillChangeFrame 的 userInfo 时长+曲线（willHide 的 userInfo 拿不到时长，探针实证 0.25 默认 vs 实际 0.42）
    private var lastKbAnim: (TimeInterval, UIView.AnimationOptions) = (0.25, UIView.AnimationOptions(rawValue: 7 << 16))
    /// 垫块 hold（§4b）：键盘可见期间 layout 算出 extra=0 不发布，收起流程结束才 release；1s 保险
    private var holdArmed = false
    private var holdSafetyGen = 0

    // perf-flash L4：非当前页延迟挂载（启动首帧只渲染当前页）。策略 drag = 手指开始拖 / 程序化翻页前才挂；
    // idle = 首帧后空闲自动挂；off = 原行为。试验期由测量开关 MP_PERF_L4 选，默认 off
    private static let deferPolicy: String = {
        #if DEBUG || PERF_BENCH
        return ProcessInfo.processInfo.environment["MP_PERF_L4"] ?? "off"
        #else
        return "off"
        #endif
    }()
    private var pendingPages: [Int: AnyView] = [:]
    let launchReadiness = LaunchReadiness()
    private var idleMountObserver: CFRunLoopObserver?
    private var idleMountWork: DispatchWorkItem?
    private var idleMountGeneration = 0
    private weak var launchInput: UITextView?
    #if (DEBUG || PERF_BENCH) && os(iOS)
    var perfListAction: ((Conversation) -> Void)?
    private var inputReportedToken: String?
    private var idleMountTraceID: String?
    #endif

    private func launchRoot(_ page: AnyView, index: Int) -> AnyView {
        guard launchReadiness.enabled else { return page }
        let signal = LaunchPageSignal(state: launchReadiness, epoch: launchReadiness.epoch, page: index, revision: launchReadiness.revision(index))
        let root = page.environment(\.launchPageSignal, signal)
        return AnyView(root)
    }

    func configureLaunch(profile: String, required: Bool, chatReady: @escaping () -> Bool) {
        let previousEpoch = launchReadiness.epoch
        launchReadiness.configure(profile: profile, required: required)
        if previousEpoch != launchReadiness.epoch { cancelIdleMount(); launchInput = nil }
        launchReadiness.chatCondition = { [weak self] in
            guard let self, chatReady(), let bar = self.inputBarHost?.viewIfLoaded else { return false }
            func findField(_ view: UIView) -> UITextView? {
                if let field = view as? UITextView, field.accessibilityIdentifier == "chat-input-field" { return field }
                for child in view.subviews { if let field = findField(child) { return field } }
                return nil
            }
            if self.launchInput?.isDescendant(of: bar) != true { self.launchInput = nil }
            let field = self.launchInput ?? findField(bar)
            self.launchInput = field
            guard let field, field.isDescendant(of: bar), field.isEditable, field.canBecomeFirstResponder,
                  field.bounds.width > 0, field.bounds.height > 0, let window = field.window,
                  window === self.viewIfLoaded?.window else { return false }
            let point = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: window)
            let hit = window.hitTest(point, with: nil)
            let usable = hit === field || hit?.isDescendant(of: field) == true
            #if (DEBUG || PERF_BENCH) && os(iOS)
            let token = "\(self.launchReadiness.epoch)/\(self.launchReadiness.layoutGeneration)/\(self.launchReadiness.revision(-1))"
            if usable, self.inputReportedToken != token {
                self.inputReportedToken = token
                LaunchTrace.event("inputUsable", state: self.launchReadiness, page: 1,
                                  fields: ["firstResponder": field.isFirstResponder, "inputRevision": self.launchReadiness.revision(-1)])
            }
            #endif
            return usable
        }
    }

    func launchContentChanged(_ page: Int) {
        guard hostingControllers.indices.contains(page) else { return }
        hostingControllers[page].viewIfLoaded?.setNeedsLayout()
    }

    private func assignLaunchRoot(_ page: AnyView, index: Int, reason: String) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.event("rootAssignBegin", state: launchReadiness, page: index, fields: ["reason": reason, "real": true])
        #endif
        // 实际根赋值处统一计数（R2-05）：update 按 updatePages 的内容键例外；L4 延迟挂载是精确例外 deferredMount
        PagingFlip.hit(.rootAssign, excepted: reason == "deferredMount" ? "deferredMount" : nil)
        launchReadiness.rootAssigned(index, real: true)
        if let host = hostingControllers[index] as? LaunchRootHost {
            host.launchEpoch = launchReadiness.epoch
            host.launchRevision = launchReadiness.revision(index)
        }
        hostingControllers[index].rootView = launchRoot(page, index: index)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.event("rootAssignEnd", state: launchReadiness, page: index, fields: ["reason": reason, "real": true])
        #endif
        launchReadiness.rootCommitted(index)
    }

    private func cancelIdleMount() {
        idleMountGeneration += 1
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if let id = idleMountTraceID {
            LaunchTrace.event("hybridObserverRemoved", state: launchReadiness, fields: ["observer": id, "reason": "cancelOrFire"])
            idleMountTraceID = nil
        }
        #endif
        idleMountWork?.cancel(); idleMountWork = nil
        if let observer = idleMountObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .defaultMode)
            CFRunLoopObserverInvalidate(observer)
            idleMountObserver = nil
        }
    }

    @objc private func cancelLaunchForNotification(_ notification: Notification) { cancelLaunchRegistration(reason: notification.name.rawValue) }

    func cancelLaunchRegistration(reason: String = "dismantle") {
        cancelIdleMount()
        #if (DEBUG || PERF_BENCH) && os(iOS)
        LaunchTrace.event("vcInvalidated", state: launchReadiness, fields: ["reason": reason])
        #endif
        launchReadiness.invalidate()
        #if (DEBUG || PERF_BENCH) && os(iOS)
        perfListAction = nil
        if PerfHarness.paging === self {
            PerfHarness.openFromList = nil; PerfHarness.listRegistration = nil
        }
        #endif
    }

    // perf-flash S1（舞台）：页容器不放进翻页 UIScrollView，放在不滚动的 stageView 上，位置全由 transform = pose.x 给；
    // scrollView 只当手势 + 惯性物理（它的 pan 挂到 stage）。原来 contentOffset 每帧变 = 所有页的祖先几何在变，
    // UIKit 通知每个托管视图、SwiftUI 逐帧重排（诊断：翻页每帧 p0/p1/p2/输入条全 layoutSubviews）；
    // 舞台上静止的页 transform 不变，就不再被通知。默认开（实测翻页动画期主线程 −30%、开对话 −20%）；
    // 测量包可用 MP_PERF_STAGE=0 切回原结构做 A/B
    private static let stageMode: Bool = {
        #if DEBUG || PERF_BENCH
        return ProcessInfo.processInfo.environment["MP_PERF_STAGE"] != "0"
        #else
        return true
        #endif
    }()
    private let stageView = UIView()
    /// 聊天页壁纸底色是否完全不透明（决定列表页能不能垫在它底下）
    private var chatPageOpaque = false
    /// 叠牌底板色 = 主题底色（壁纸 fill）的不透明版：三页停靠都在 x=0，任何一页内容透明时透出来的是它，
    /// 而不是下面那一页（粟粟 10-04 同意，plan §1.8 A-6）。随 applyWallpaper 同步
    private var deckBaseColor: UIColor?

    // perf-flash S2（快照替身，粟粟 09-27 选 2）：手指拖动翻页期间，要移动的那一页换成快照去滑，真页面原地隐藏不动
    // → 它的托管视图不再逐帧重排（舞台模式下剩余逐帧开销就是移动页自己）。落定 / 拖回原页撤快照、真页面一次摆好。
    // 只在手势拖动用；程序化翻页（点对话自动翻页等）不用——那时新页正在装内容，快照会是一张空卡片。
    // 取舍：翻页那 ~0.3s 页内动画定格。依赖舞台模式；试验期 MP_PERF_SNAPFLIP 开
    /// R6 实验（PERF 包 env）：MP_PERF_P2OFF=0 不写 Page2SceneState.pageOffset（全仓无读者；「判等读取被根宿主订阅」
    /// 的假设 😷 实测否决，动画期忙不变，留开关只为复现）
    private static let writesPage2Offset: Bool = {
        #if DEBUG || PERF_BENCH
        return ProcessInfo.processInfo.environment["MP_PERF_P2OFF"] != "0"
        #else
        return true
        #endif
    }()
    /// 翻页挪页面的方式（R6，默认 "3"）。页面用 UIView.transform 挪时，SwiftUI 托管视图每帧收到几何通知
    /// （updateTransform → invalidateTransform），整页图更新——舞台模式下 0↔1 动画期主线程 ~105ms 的来源。
    /// 直接写 backing layer 的仿射变换绕开该通知（0↔1 动画期忙 −80%，落定 / 到能用不变，😷 实测）。
    /// SwiftUI 因此不知道页面水平挪过：列表页 / 聊天页只读 `.global` 的 minY、气泡菜单用 UIKit 窗口坐标，不受影响。
    /// page2 仍走 UIView.transform：它走 layer 时落地要补算整页（落定 +25ms、到能用 +50ms），混合两头都要。
    /// SwiftUI 的窗口坐标缓存由 `scheduleLayerSync` 在每次落定后的下一帧经 UIView setter 刷成准值（astra R7 B1：
    /// 停在 page2 时聊天页被 layer 挪在 −W，这期间任何几何通知都会让 SwiftUI 记住 −W，翻回来 layer 不再通知）。
    /// 只在验证过的场景用 layer：舞台模式、非宽屏、未开减弱动态、未开 VoiceOver（R7 I1/I3），其余走 UIView。
    /// PERF 包 env：MP_PERF_LAYERXFORM="0" 全走 UIView（原行为）/ "2" page2 也走 layer / "3" 默认
    private static let layerTransformMode: String = {
        #if DEBUG || PERF_BENCH
        return ProcessInfo.processInfo.environment["MP_PERF_LAYERXFORM"] ?? "3"
        #else
        return "3"
        #endif
    }()
    private var layerSyncScheduled = false

    private func usesLayerTransform(for index: Int, enabled: Bool) -> Bool {
        Self.layerTransformMode != "0" && Self.stageMode && enabled && !UIAccessibility.isVoiceOverRunning
            && !(Self.layerTransformMode == "3" && index == 2)
    }

    /// 落定后下一帧：可见页经 UIView setter 写一遍当前变换（先偏 1pt 再写回，避开同值短路），SwiftUI 窗口坐标缓存对齐终态。
    /// 挪出落地帧（同 C5′），代价 ~25ms 落在落定后那一帧；又开始拖了就等下次落定
    private func scheduleLayerSync() {
        guard PagingSwitch.layerSync, Self.layerTransformMode != "0", !layerSyncScheduled else { return }
        layerSyncScheduled = true
        NextFrame.run { [weak self] in
            guard let self else { return }
            self.layerSyncScheduled = false
            guard !self.scrollView.isDragging, !self.scrollView.isDecelerating else { return }
            for container in self.pageContainers where !container.isHidden {
                PagingFlip.noteLayerSync()
                let t = container.layer.affineTransform()
                container.transform = t.translatedBy(x: 1, y: 0)
                container.transform = t
            }
        }
    }
    private static let snapshotFlip: Bool = {
        #if DEBUG || PERF_BENCH
        return stageMode && ProcessInfo.processInfo.environment["MP_PERF_SNAPFLIP"] == "1"
        #else
        return false
        #endif
    }()
    private var snapshotSession = false
    private var flipSnapshots: [Int: UIView] = [:]

    private func beginSnapshotSession() {
        guard Self.snapshotFlip else { return }
        snapshotSession = true
    }

    private func endSnapshotSession() {
        guard snapshotSession || !flipSnapshots.isEmpty else { return }
        snapshotSession = false
        for (index, snapshot) in flipSnapshots {
            snapshot.removeFromSuperview()
            pageContainers[index].isHidden = false
        }
        flipSnapshots.removeAll()
    }

    /// 这一页此刻要显示在哪个视图上：拖动会话里，**正完整显示在屏上、要滑走**的那张卡第一次移动时拍快照，之后一直用快照。
    /// 屏外 / 隐藏的页（被露出的底页、从屏外滑进来的页）一律用真页面——快照取的是渲染端已画好的画面，
    /// 没上过屏的页拍出来是空白（粟粟 09-27 实测：1→0 列表白屏 ~1s、进出 page2 空白圆角卡 + 白闪）
    private func pageView(for index: Int, movingTo x: CGFloat, hidden: Bool) -> UIView {
        let container = pageContainers[index]
        if let snapshot = flipSnapshots[index] { return snapshot }
        let onScreen = !container.isHidden && abs(container.frame.minX) < 0.5
        guard snapshotSession, !hidden, onScreen, abs(container.transform.tx - x) > 0.5,
              let snapshot = container.snapshotView(afterScreenUpdates: false) else { return container }
        snapshot.bounds = container.bounds
        snapshot.center = container.center
        snapshot.transform = container.transform
        // 快照继承当前角色的裁切：移动前景保留圆角，阴影下的底页全屏。
        snapshot.clipsToBounds = container.clipsToBounds
        snapshot.layer.cornerCurve = .continuous
        snapshot.layer.cornerRadius = container.layer.cornerRadius
        snapshot.layer.zPosition = container.layer.zPosition
        snapshot.isUserInteractionEnabled = false
        stageView.addSubview(snapshot)
        container.isHidden = true
        flipSnapshots[index] = snapshot
        return snapshot
    }

    init(pages: [AnyView], inputBar: AnyView?, initialPage: Int, launchProfile: String,
         launchRequired: Bool, launchChatReady: @escaping () -> Bool) {
        self.currentPage = initialPage
        super.init(nibName: nil, bundle: nil)
        launchReadiness.owner = self
        configureLaunch(profile: launchProfile, required: launchRequired, chatReady: launchChatReady)
        for (index, page) in pages.enumerated() {
            var deferred = Self.deferPolicy != "off" && index != initialPage
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if LaunchTrace.mountSequence != nil { deferred = index != initialPage }
            LaunchTrace.event("hcCreateBegin", state: launchReadiness, page: index, fields: ["real": !deferred, "reason": "init"])
            LaunchTrace.event("rootAssignBegin", state: launchReadiness, page: index, fields: ["real": !deferred, "reason": "init"])
            #endif
            if deferred { pendingPages[index] = page }
            launchReadiness.rootAssigned(index, real: !deferred)
            let root = deferred ? AnyView(Color.clear) : launchRoot(page, index: index)
            // 常用 LaunchRootHost：它的布局回报（根版本 + 已布局）是翻页命令「先挂上再滑」的就绪信号（B-4）
            let host: UIHostingController<AnyView> = LaunchRootHost(rootView: root, state: launchReadiness, page: index)
            hostingControllers.append(host)
            #if (DEBUG || PERF_BENCH) && os(iOS)
            LaunchTrace.event("rootAssignEnd", state: launchReadiness, page: index, fields: ["real": !deferred, "reason": "init"])
            LaunchTrace.event("hcCreateEnd", state: launchReadiness, page: index, fields: ["real": !deferred, "reason": "init"])
            #endif
            launchReadiness.rootCommitted(index)
        }
        if let inputBar {
            launchReadiness.inputAssigned()
            #if (DEBUG || PERF_BENCH) && os(iOS)
            let barSpan = LaunchTrace.begin("inputBarHC")
            defer { LaunchTrace.end("inputBarHC", barSpan) }
            #endif
            if launchReadiness.enabled { inputBarHost = LaunchRootHost(rootView: launchRoot(inputBar, index: 1), state: launchReadiness, page: -1) }
            else { inputBarHost = UIHostingController(rootView: inputBar) }
        }
        // 舞台模式：页面不再是翻页 UIScrollView 的子孙，SwiftUI 自带的键盘避让会生效，跟项目自己的
        // 键盘几何（keyboardLayoutGuide + KeyboardInsetBridge）叠两份 → 弹键盘时聊天内容「飞天」（粟粟 09-28 实测，
        // MP_PERF_STAGE=0 即好）。原结构下这些 HC 从来拿不到 keyboard 区（memory: 嵌套 HC 键盘避让失灵），这里显式声明回去
        if Self.stageMode {
            for hc in hostingControllers { hc.safeAreaRegions = .container }
            inputBarHost?.safeAreaRegions = .container
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfHarness.paging = self
        if LaunchTrace.enabled || UITestHooks.active {
            NotificationCenter.default.addObserver(self, selector: #selector(perfLaunchInputBegan(_:)), name: UITextView.textDidBeginEditingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(perfLaunchInputChanged(_:)), name: UITextView.textDidChangeNotification, object: nil)
        }
        perfInstallLayoutCounter()
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(cancelLaunchForNotification(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cancelLaunchForNotification(_:)), name: .profileWillSwitch, object: nil)
        PagingCommands.shared.register(self)
        NotificationCenter.default.addObserver(self, selector: #selector(pagingProfileWillSwitch), name: .profileWillSwitch, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pagingDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        #if DEBUG || PERF_BENCH
        PagingFlip.onWindowEnd = { [weak self] in self?.refreshPagingAXValue() }
        PagingFlip.context = { [weak self] in
            guard let self else { return nil }
            let apps = Page2AppShell.shared.contentViews.filter { $0.key != "home" && $0.value.view != nil }.count
            return PagingFlip.Context(owner: ObjectIdentifier(self), page: self.currentPage, streaming: self.contentStreaming, keyboard: KeyboardInsetBridge.shared.kbVisible,
                                      wide: self.widePanelMode, page2Apps: apps, deck: self.deckActive)
        }
        #endif
        setupPageDots()
        Self.statusBarController = self
        Page2SceneState.shared.isActive = currentPage == 2
        view.backgroundColor = .clear

        // UIKit 壁纸固定在聊天页外壳，避开 SwiftUI keyboard safe-area 缩放。
        wallpaperContainer.backgroundColor = .clear
        wallpaperContainer.clipsToBounds = true
        wallpaperContainer.isUserInteractionEnabled = false   // wallpaper 不拦截 hit test
        wallpaperImageView.contentMode = .scaleAspectFill
        wallpaperImageView.clipsToBounds = true
        wallpaperImageView.isUserInteractionEnabled = false
        wallpaperContainer.addSubview(wallpaperImageView)
        // Gradient 放在 wallpaperContainer.layer 的 sublayer 中，视觉叠在 imageView 之上
        wallpaperGradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        wallpaperGradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        wallpaperGradientLayer.locations = [0, 0.5, 1]
        wallpaperContainer.layer.addSublayer(wallpaperGradientLayer)

        scrollView.isPagingEnabled = true
        scrollView.bouncesHorizontally = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true
        scrollView.delegate = self
        view.addSubview(scrollView)
        let pageParent: UIView = Self.stageMode ? stageView : scrollView
        if Self.stageMode {
            stageView.backgroundColor = .clear
            stageView.clipsToBounds = true
            view.addSubview(stageView)
            stageView.addGestureRecognizer(scrollView.panGestureRecognizer)
        }

        for (index, hc) in hostingControllers.enumerated() {
            let container = UIView()
            // 停靠/底页全屏铺满；只有翻页前景按固定设备轮廓裁切。
            container.clipsToBounds = false
            container.layer.cornerCurve = .continuous
            container.layer.zPosition = CGFloat(index * 10)
            pageParent.addSubview(container)
            pageContainers.append(container)
            if index == 1 { container.addSubview(wallpaperContainer) }

            addChild(hc)
            hc.view.backgroundColor = .clear
            hc.view.clipsToBounds = true
            container.addSubview(hc.view)
            hc.didMove(toParent: self)

            let dimmer = UIView()
            dimmer.backgroundColor = .black
            dimmer.isUserInteractionEnabled = false
            dimmer.alpha = 0
            container.addSubview(dimmer)
            pageDimmers.append(dimmer)
        }
        pageShadow.isUserInteractionEnabled = false
        pageShadow.layer.shadowColor = UIColor(red: 0.24, green: 0.21, blue: 0.18, alpha: 1).cgColor
        pageShadow.layer.shadowRadius = 22
        pageShadow.layer.shadowOffset = CGSize(width: -3, height: 4)
        pageShadow.layer.shadowOpacity = 0.10
        pageParent.addSubview(pageShadow)
        NotificationCenter.default.addObserver(self, selector: #selector(pageMotionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pageMotionPreferenceChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)

        applyPageInteraction()
        applyDeckBase()
        Self.sharedScrollView = scrollView   // 给 iOSTabBarGestureBlocker 拿水平 paging pan 用
        // 深翻抑制解除回调：挂桥时一次装好（原在 publishKeyboardGeometry 早退 guard 之后装，L7 A5 跳过路径不经过 → 消费点拿 nil；R14-05）
        KeyboardInsetBridge.shared.liftPadSuppression = { [weak self] in self?.liftPadSuppression() }

        // B2 输入条挂载：chat 页（index 1）的 UIKit 子层，随聊天页外壳移动/遮挡。
        // 底边 = keyboardLayoutGuide.topAnchor：无键盘时 guide 顶边贴屏底 safe area，
        // 键盘弹起/拖拽时逐帧跟键盘顶——输入条动画交给系统约束，渲染层不再钉死瞬跳
        //（research-keyboard-anim §5 病根）。玻璃/内容仍是 SwiftUI（InputBarStack）。
        if let barHost = inputBarHost, hostingControllers.count > 1 {
            let chatHC = hostingControllers[1]
            chatHC.addChild(barHost)
            barHost.view.backgroundColor = .clear
            // C-slide：不再 intrinsic 自撑——carrier 定高（下方等高约束），root proposal=bounds，
            // SwiftUI 根钉底填满。换行不再改容器几何（F2 居中 / F7 迟一拍两个病根消失）。
            barHost.sizingOptions = []
            barHost.view.translatesAutoresizingMaskIntoConstraints = false
            // hit-test 透传容器：hosting view 默认拦截整个 bounds 内触摸——输入条栈上缘
            // 以下的空白区会把列表消息按钮行挡死（P1 复现器实锤），容器只放行真实内容命中
            let container = PassthroughContainerView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .clear
            chatHC.view.addSubview(container)
            container.addSubview(barHost.view)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: chatHC.view.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: chatHC.view.trailingAnchor),
                container.bottomAnchor.constraint(equalTo: chatHC.view.keyboardLayoutGuide.topAnchor),
                // C-slide：定高 carrier（=chat 页高，恒 ≥ 任何内容组合，非魔数）。键盘起落 = guide
                // 搬 carrier = 纯平移（今天丝滑路径原样）；键盘起时顶超出屏顶，透明 + hitTest 放行无碍。
                container.heightAnchor.constraint(equalTo: chatHC.view.heightAnchor),
                barHost.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                barHost.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                barHost.view.topAnchor.constraint(equalTo: container.topAnchor),
                barHost.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            barHost.didMove(toParent: chatHC)
            inputBarContainer = container
            // containerTop 发布（回底按钮锚点的容器分量，字段内偏移由 SwiftUI 白盒自报——
            // sol 终审 §1/§4：容器顶≠字段顶不能加常数凑，KVO 只管容器级位移真值）。
            // bounds KVO 无文档保证但项目有 contentSize KVO 先例；center 补容器整体搬动
            //（键盘起落改 guide 约束=位置变尺寸不变，bounds KVO 不响）；viewDidLayoutSubviews
            // 与 keyboardDidChangeFrame（键盘落稳）双兜底。
            inputBarBoundsObs = container.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishContainerTop() }
            }
            inputBarCenterObs = container.observe(\.center, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishContainerTop() }
            }
            // 多行生长补层（KB-P3 探针实锤）：嵌套 UIHostingView 下 intrinsicContentSize
            // 失效不驱动 Auto Layout re-solve（打字时 intrinsic 55→109 容器钉死 55=输入条
            // 不长高，文本内滚）。SwiftUI 侧在内容变化点 kick，这里 invalidate+layout 跟上。
            barKickCancellable = KeyboardInsetBridge.shared.barKick
                .sink { [weak self] _ in
                    // 延一 runloop（KB-P4：同步打进键盘收起动画的建立窗口会把动画掐死）。
                    // C-slide 后 kick 只剩发布职责：容器几何不随内容变，不再 invalidate/re-solve。
                    DispatchQueue.main.async { self?.resolveBarContainer(tag: "kick") }
                }
        }

        // Home indicator hit shield — 挂 PagingViewController.view 上方（z 高于 scrollView 及其
        // child HCs），UIKit 顶层命中。viewDidLayoutSubviews / viewSafeAreaInsetsDidChange 同步 frame。
        homeIndicatorShield.backgroundColor = .clear
        homeIndicatorShield.isUserInteractionEnabled = true
        homeIndicatorShield.isHidden = (currentPage != 1) || shieldHiddenByCaller
        view.addSubview(homeIndicatorShield)
        let shieldTap = UITapGestureRecognizer(target: homeIndicatorShield, action: #selector(HomeIndicatorHitShieldUIView.absorbGesture))
        homeIndicatorShield.addGestureRecognizer(shieldTap)
        let shieldLP = UILongPressGestureRecognizer(target: homeIndicatorShield, action: #selector(HomeIndicatorHitShieldUIView.absorbGesture))
        shieldLP.minimumPressDuration = 0.1
        homeIndicatorShield.addGestureRecognizer(shieldLP)

        // 键盘避让：嵌套 child HC 在 UIKit PagingViewController 下，SwiftUI 默认的
        // UIHostingController keyboard avoidance 机制失灵（实测 [PROBE kbd A/B] 无
        // changed to）——必须手动给 chat page child HC 注入 keyboard safe area inset。
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        // 键盘落稳（show/hide/frame 变更动画结束都发）：清过渡态 + 容器终点重采样。
        // 用 didChangeFrame 而非 didShow/didHide 对：interactive dismiss 中途放弃只回
        // didChangeFrame，didShow 不重发（sol 终审 §3 按钮过渡窗）。
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDidChangeFrame(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)

        // B22 渲染层根因：makeUIViewController 在 view 装载前已 applyWallpaper 一次，
        // 上面的 `wallpaperContainer.backgroundColor = .clear` 初始化把那次 fill 抹掉，
        // 而 applyWallpaper 的同 config 短路又挡住后续重涂 → 新建 VC（切楼层/冷启动）
        // 的聊天页透出 root hosting view 的 systemBackground 纯白。这里重涂一遍。
        // 取证：layer-dump 实录 wallpaperContainer bg=clear + 根视图 bg=白。
        if let pending = lastAppliedWallpaperConfig {
            lastAppliedWallpaperConfig = nil
            applyWallpaper(pending)
        }
    }

    deinit {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if let id = idleMountTraceID {
            Task { @MainActor in LaunchTrace.event("hybridObserverRemoved", fields: ["observer": id, "reason": "deinit"]) }
        }
        #endif
        idleMountWork?.cancel()
        if let observer = idleMountObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .defaultMode)
            CFRunLoopObserverInvalidate(observer)
        }
        NotificationCenter.default.removeObserver(self)
        for token in pageDotsObservers { NotificationCenter.default.removeObserver(token) }
    }

    /// 探针：chat 列表 scrollView 完整几何（fb 是派生值，inset 错了 fb 就假高——要看原始量）
    private func svState(_ tag: String) -> String {
        guard let sv = StreamScrollAnchor.AnchorView.chatScrollView else { return "\(tag) sv=nil" }
        return String(format: "%@ off=%.1f insetTop=%.1f adjTop=%.1f fb=%.1f cs=%.0f bounds=%.0f trk=%d drag=%d dec=%d",
                      tag, sv.contentOffset.y, sv.contentInset.top, sv.adjustedContentInset.top,
                      sv.contentOffset.y + sv.adjustedContentInset.top, sv.contentSize.height, sv.bounds.height,
                      sv.isTracking ? 1 : 0, sv.isDragging ? 1 : 0, sv.isDecelerating ? 1 : 0)
    }

    /// 探针：键盘/输入条一行状态
    private func kbState() -> String {
        let b = KeyboardInsetBridge.shared
        let insets = hostingControllers.map { String(format: "%.0f", $0.additionalSafeAreaInsets.bottom) }.joined(separator: "/")
        let sv = StreamScrollAnchor.AnchorView.chatScrollView
        let off = sv.map { String(format: "%.0f", $0.contentOffset.y + $0.adjustedContentInset.top) } ?? "-"
        return String(format: "page=%d extra=%.0f kbVis=%d trans=%d growth=%.0f cTop=%.0f insets=%@ container=%@ guide=%@ fb=%@ fr=%@",
                      currentPage, b.extra, b.kbVisible ? 1 : 0, b.kbTransitioning ? 1 : 0, b.barGrowth, b.containerTop, insets,
                      inputBarContainer.map { KBProbe.f($0.frame) } ?? "-", KBProbe.f(view.keyboardLayoutGuide.layoutFrame), off,
                      KBProbe.firstResponderName(in: view.window))
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard let frameEnd = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // 过滤 bogus keyboard frame（探针实测 kbEndY=0 / maxY≠屏底的过渡帧 → extra=878 把
        // CC 终端压成 34pt 卡几秒 → 「位置错乱」「键盘收了几秒才变回全屏」）。正常键盘要么
        // docked（底边贴屏幕底），要么 hidden（整体移出屏幕底）；其余是过渡/异常帧，忽略。
        let kbInView = view.convert(frameEnd, from: nil)
        let h = view.bounds.height
        let docked = abs(kbInView.maxY - h) < 1
        let hidden = kbInView.minY >= h - 1
        KBProbe.log("KB will docked=\(docked ? 1 : 0) hidden=\(hidden ? 1 : 0) kbMinY=\(Int(kbInView.minY)) \(kbState())")
        guard docked || hidden else { KBProbe.log("KB will BOGUS"); return }
        lastKbAnim = Self.keyboardAnimParams(notification.userInfo)
        // 键盘过渡窗开启（回底按钮压隐）；didChangeFrame 收窗。1.5s 代际保险防 did 通知
        // 丢失（app 切后台打断动画等）把按钮永久锁没。
        KeyboardInsetBridge.shared.kbTransitioning = true
        // 可拖滚动条抓着时先放手，再让下面的键盘写手动 offset（plan-chat-scrubber R2-I02）
        ChatScrubberModel.shared.cancelActive?()
        kbTransitionGen += 1
        let gen = kbTransitionGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.kbTransitionGen == gen else { return }
            KeyboardInsetBridge.shared.kbTransitioning = false
        }
        // 只给当前页做避让（非当前页不可见，避让只触发后台 resize churn）；其余页强制归零。
        for (i, hc) in hostingControllers.enumerated() {
            if i == currentPage {
                // 终端自管键盘（容器内 transform 滚动避让，不缩 bounds）→ 跳过 safe-area 避让，
                // 否则缩 bounds 触发 SwiftTerm reflow / tmux resize。
                if firstResponderSelfManagesKeyboard(in: hc.view) {
                    if hc.additionalSafeAreaInsets.bottom != 0 { hc.additionalSafeAreaInsets = .zero }
                } else if i == 1 {
                    // chat 页 inset 退役补刀（B2 T4 勾了账没退干净）：输入条=guide、列表=
                    // ignoresSafeArea+垫块、按钮=自算，inset 对 chat 页零消费者——却在每次
                    // 键盘起落打一次全树重排（KB-P4 实锤：setInset 时刻正嵌在弹起起步
                    // 129ms 掉帧窗中=「弹起卡一下」）。只发桥值，不再动 safe area。
                    handleChatKeyboardRise(for: hc, keyboardFrameEnd: frameEnd, userInfo: notification.userInfo)
                    if hc.additionalSafeAreaInsets.bottom != 0 { hc.additionalSafeAreaInsets = .zero }
                } else {
                    applyKeyboardAvoidance(to: hc, keyboardFrameEnd: frameEnd)
                }
            } else if hc.additionalSafeAreaInsets.bottom != 0 {
                hc.additionalSafeAreaInsets = .zero
            }
        }
    }

    /// chat 页键盘弹起/变频（docked 帧）：正文平移 = 跟随输入条容器的**表现层**（research-keyboard-follow-animation §4a）。
    /// 垫块在 layout 里长到 extra（P1 单一发布点），跟随器每帧 offset = -inset + (barBottom − barBottomFinal)：
    /// t=0 时 =+extra（旧画面），bar 到位时 =-inset（在底）。曲线/时长/中断全由系统键盘动画本身决定，不再从 userInfo 拿。
    private func handleChatKeyboardRise(for hc: UIHostingController<AnyView>, keyboardFrameEnd: CGRect, userInfo: [AnyHashable: Any]?) {
        let frameInHC = hc.view.convert(keyboardFrameEnd, from: nil)
        let overlap = max(0, hc.view.bounds.maxY - frameInHC.minY)
        let systemBottom = max(0, hc.view.safeAreaInsets.bottom - hc.additionalSafeAreaInsets.bottom)
        let extra = max(0, overlap - systemBottom)
        guard extra > 0 else { KBProbe.log("rise extra=0 skip"); return }   // hidden 帧交给 keyboardWillHide 路径
        if !KeyboardInsetBridge.shared.kbVisible { KeyboardInsetBridge.shared.kbVisible = true }
        cancelHoldSafety()   // 收到一半又弹起：垫块继续留着（hold 不需要 release）
        // 增量按 layout 里**已发布的垫块**算（深翻抑制时为 0 → 什么都不钉），不按键盘高度算
        let pad = KeyboardInsetBridge.shared.extra
        let deltaE = pad - appliedExtra
        appliedExtra = pad
        let sv = StreamScrollAnchor.AnchorView.chatScrollView
        let distFromBottom = sv.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? 0
        let atBottom = sv != nil && distFromBottom < 200
        // 深翻历史（>1.5 屏）：弹键盘内容原地不动、不回底（垫块变化焊帧吃掉；冷弹与否 CardFlowView 自判）
        let farAway = sv.map { distFromBottom > $0.bounds.height * KeyboardInsetBridge.returnToBottomScreens } ?? false
        let (dur, _) = Self.keyboardAnimParams(userInfo)
        KBProbe.log(String(format: "rise extra=%.0f pad=%.0f deltaE=%.0f atBottom=%d farAway=%d dist=%.0f dur=%.2f", extra, pad, deltaE, atBottom ? 1 : 0, farAway ? 1 : 0, distFromBottom, dur))
        KBProbe.log(svState("  rise sv"))
        if abs(deltaE) >= 1 {
            if atBottom, let sv, abs(deltaE) <= 45 {
                KBProbe.log("rise branch=small-step")
                // 候选栏出没级小变化（切中英文输入法/联想条，Telegram 44.1pt 过滤同款）：键盘本身是瞬变，一步到终态
                slideGen += 1; slideInFlight = false   // 在飞的滑动作废：小步瞬到终态
                UIView.performWithoutAnimation {
                    hc.view.layoutIfNeeded()
                    sv.contentOffset.y = -sv.adjustedContentInset.top
                }
            } else if atBottom, let sv {
                KBProbe.log("rise branch=pin+slide(CA)")
                // 垫块已在 layout 里长到 extra；同步落布局后把 offset 钉到「旧画面等价位」，再按键盘曲线 CA 滑回底。
                // 收起动画飞行中被打断（又弹起）：不钉（钉=模型直写会杀掉在飞的动画、表现层瞬跳），
                // 让 .beginFromCurrentState 从表现层当前位置接着滑——垫块同为 hold 高度，offset 空间连续。
                if !slideInFlight {
                    UIView.performWithoutAnimation {
                        hc.view.layoutIfNeeded()
                        sv.contentOffset.y = -sv.adjustedContentInset.top + pad
                    }
                }
                animateOffset(sv, to: -sv.adjustedContentInset.top, tag: "rise", onDone: nil)
            } else if farAway, let sv {
                KBProbe.log("rise branch=farAway")
                // 深翻原地：同步落布局后按增量钉回
                UIView.performWithoutAnimation {
                    let before = sv.contentOffset.y
                    hc.view.layoutIfNeeded()
                    sv.contentOffset.y = before + deltaE
                }
            } else {
                KBProbe.log("rise branch=layout-only(cold scroll takes over)")
                UIView.performWithoutAnimation { hc.view.layoutIfNeeded() }
            }
        } else if atBottom, let sv, sv.contentOffset.y > -sv.adjustedContentInset.top + 10 {
            KBProbe.log("rise branch=same-extra-halfway→slide")
            // extra 没变且 offset 停在半路（收起动画中途又弹回）：从当前表现层接着滑回底
            animateOffset(sv, to: -sv.adjustedContentInset.top, tag: "rise", onDone: nil)
        }
    }

    /// 正文平移 = CA 动画（render server 驱动，120Hz 与输入条同引擎同曲线）。研究过程中的逐帧跟随器
    ///（CADisplayLink 贴容器表现层）写出的值一帧不差（探针 FOREIGN=0），但主线程节拍只有 ~60Hz 且
    /// isAtBottom 翻转触发全表重排卡出 25ms 空档 —— 120Hz 屏上紧挨着 bar 就是"一顿一顿"。
    /// 时长/曲线取最近一次 willChangeFrame（willHide 的 userInfo 缺时长）。compensator/glide 在动画期 mute。
    private func animateOffset(_ sv: UIScrollView, to target: CGFloat, tag: String, onDone: (() -> Void)?) {
        slideGen += 1
        let gen = slideGen
        let (dur, opts) = lastKbAnim
        StreamScrollAnchor.muteCompensator(dur + 0.3)
        slideInFlight = true
        KBProbe.log(String(format: "slide[%@] %.0f→%.0f dur=%.2f", tag, sv.contentOffset.y, target, dur))
        UIView.animate(withDuration: dur, delay: 0,
                       options: opts.union([.beginFromCurrentState, .overrideInheritedDuration, .overrideInheritedCurve])) {
            sv.contentOffset.y = target
        } completion: { [weak self] finished in
            guard let self, self.slideGen == gen else { return }   // 已被新动画替换：不做收尾
            self.slideInFlight = false
            KBProbe.log(String(format: "slide[%@] done finished=%d off=%.0f", tag, finished ? 1 : 0, sv.contentOffset.y))
            onDone?()
        }
    }

    /// 深翻抑制解除（CardFlowView 在滚回 returnToBottomScreens 以内松手/到底时调）：重发几何让垫块长到真实 extra；
    /// 已在底 → 钉旧画面位 + CA 滑回底（同弹起在底）；1 屏内未到底 → CardFlowView onChange(0→extra) 冷弹回底接管
    private func liftPadSuppression() {
        let b = KeyboardInsetBridge.shared
        guard b.padSuppressed, currentPage == 1 else { return }
        b.padSuppressed = false
        publishKeyboardGeometry()
        let pad = b.extra
        appliedExtra = pad
        KBProbe.log(String(format: "pad suppression lifted → pad=%.0f", pad))
        guard pad > 0.5, hostingControllers.count > 1, let sv = StreamScrollAnchor.AnchorView.chatScrollView else { return }
        let dist = sv.contentOffset.y + sv.adjustedContentInset.top
        guard dist < 200 else { return }
        UIView.performWithoutAnimation {
            hostingControllers[1].view.layoutIfNeeded()
            sv.contentOffset.y = -sv.adjustedContentInset.top + pad
        }
        animateOffset(sv, to: -sv.adjustedContentInset.top, tag: "lift", onDone: nil)
    }

    private func cancelHoldSafety() {
        holdArmed = false
        holdSafetyGen += 1
    }

    /// 塌垫块（§4b release）：同一 runloop 里先放 CardFlowView 要同帧写的 offset，再把 extra 发成 0
    private func releaseExtra(offset: CGFloat?) {
        cancelHoldSafety()
        let b = KeyboardInsetBridge.shared
        guard b.extra > 0.5 else { b.hideReleaseOffset = nil; return }
        b.hideReleaseOffset = offset
        KBProbe.log(String(format: "release extra %.0f→0 off=%@", b.extra, offset.map { String(format: "%.0f", $0) } ?? "nil"))
        b.extra = 0
    }

    /// 键盘通知的 duration+curve → UIView.animate 参数（真键盘曲线，正文与输入条同源）
    private static func keyboardAnimParams(_ userInfo: [AnyHashable: Any]?) -> (TimeInterval, UIView.AnimationOptions) {
        let dur = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval).flatMap { $0 > 0 ? $0 : nil } ?? 0.25
        let curveRaw = (userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        return (dur, UIView.AnimationOptions(rawValue: curveRaw << 16))
    }

    /// 当前页内的 first responder 是否自管键盘避让（CC 终端的 ScrollableTerminalView、
    /// Page2 的 MPChatWebView）。
    ///
    /// ⚠️ 不能只看 first responder 本身：WKWebView 持有键盘焦点的是内部私有类
    /// WKContentView，够不着也没法让它 conform 协议（动态 subclass 加 objc protocol
    /// 对 Swift `is` 不可靠）。所以命中 first responder 后**沿 superview 链往上找**——
    /// WKContentView 的祖先里就是标了 KeyboardSelfManaging 的那个 WKWebView 子类。
    private func firstResponderSelfManagesKeyboard(in view: UIView) -> Bool {
        if view.isFirstResponder {
            var node: UIView? = view
            while let cur = node {
                if cur is KeyboardSelfManaging { return true }
                node = cur.superview
            }
            return false
        }
        for sub in view.subviews where firstResponderSelfManagesKeyboard(in: sub) { return true }
        return false
    }

    private func applyKeyboardAvoidance(to hc: UIHostingController<AnyView>, keyboardFrameEnd: CGRect) {
        let frameInHC = hc.view.convert(keyboardFrameEnd, from: nil)
        let overlap = max(0, hc.view.bounds.maxY - frameInHC.minY)
        // 扣掉系统 bottom safe area（home indicator 等），避免 double count。
        // view.safeAreaInsets.bottom = systemBottom + additionalSafeAreaInsets.bottom
        let currentBottom = hc.view.safeAreaInsets.bottom
        let systemBottom = max(0, currentBottom - hc.additionalSafeAreaInsets.bottom)
        let extra = max(0, overlap - systemBottom)
        // 去重：extra 没变就不重设，避免无谓 layout→sizeChanged→resize 往返（震荡 churn 源）。
        // 基线是本页自己的 inset（P2 前拿的是 chat 页桥值——非 chat 页不发布桥，永远对不上）
        if abs(extra - hc.additionalSafeAreaInsets.bottom) < 1 { return }
        // 同键盘曲线滑动（layoutIfNeeded 在动画块内 = safeAreaInset 输入框跟着曲线走）
        // ⚠️ research-keyboard-anim §5 二审：不要用 UIView.animate 包 layoutIfNeeded 给这里
        // 加动画——SwiftUI hosting 内容不吃 UIKit 动画事务（布局 3ms 到位但渲染层被钉在
        // 旧位 380-750ms 后瞬跳，两轮录屏+探针实证），输入框动画正解=方案 B keyboardLayoutGuide
        hc.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: extra, right: 0)
        // ⚠️ P1：不写桥。这里是非 chat 页（终端/中庭）的 safe-area 避让，chat 页的几何
        // 由 publishKeyboardGeometry 从 keyboardLayoutGuide 派生——旧实现在这里写 extra，
        // 终端页收键盘时把 chat 页的 containerTop 停在 786（正常 804）无人重发 = Bug1
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        KBProbe.log("KB hide \(kbState())")
        // 非 chat 页收键盘（终端/中庭自己的输入）：不碰 chat 页的列表与桥（同 publishKeyboardGeometry 的理由）
        guard currentPage == 1 else {
            for hc in hostingControllers where hc.additionalSafeAreaInsets.bottom != 0 { hc.additionalSafeAreaInsets = .zero }
            // ⚠️ 这里**绝不能**发任何会让终端 resign 的通知（08-26 真机崩溃 040818.ips）：
            // 终端 handler 里 resignFirstResponder → UIKit 再发 keyboardWillHide → 回到这里再 post
            // → 6 层递归到栈爆。收键盘由终端自己在手势里做（Coordinator.dismissTerminalKeyboard）。
            // 带着键盘翻离 chat 页（ContentView onChange(iOSPage) 收的键盘）：chat 页垫块还 hold 着，
            // 这里不 release 就只能等 1s 保险，而保险 release 无钉位 → 翻回来内容跳（探针 fb 3989→3829）。
            // chat 页此刻不可见，无需动画：在底归底、离底减 hold，同帧塌。
            KeyboardInsetBridge.shared.padSuppressed = false
            if appliedExtra > 0.5, let sv = StreamScrollAnchor.AnchorView.chatScrollView {
                let extra = appliedExtra
                appliedExtra = 0
                slideGen += 1; slideInFlight = false
                let inset = sv.adjustedContentInset.top
                let atBottom = sv.contentOffset.y < 200
                KBProbe.log(String(format: "hide branch=not-chat-page → release chat pad %.0f atBottom=%d", extra, atBottom ? 1 : 0))
                releaseExtra(offset: atBottom ? -inset : sv.contentOffset.y - extra)
                return
            }
            KBProbe.log("hide branch=not-chat-page skip")
            return
        }
        if KeyboardInsetBridge.shared.kbVisible { KeyboardInsetBridge.shared.kbVisible = false }
        KeyboardInsetBridge.shared.padSuppressed = false
        // L4 P1: reset 所有 child HC 的 additionalSafeAreaInsets，跟 keyboardFrameWillChange 对称。
        // 有值才清：setter 无幂等保证（记忆教训），chat 页退役后恒 0，白写=收键盘头帧白重排
        for hc in hostingControllers where hc.additionalSafeAreaInsets.bottom != 0 {
            hc.additionalSafeAreaInsets = .zero
        }
        // 垫块此刻仍是 hold 住的旧高度（publishKeyboardGeometry §4b），本函数是唯一的 release 调度者：
        //   发送瞬收 → 立即塌（终态天然正确，弹泡 transition 不被碾）
        //   在底     → 跟随器贴 bar 下移（垫块留着才有合法 offset），收敛后 release：同帧塌+归底
        //   离底     → 立即 release：同帧塌 + offset−hold（内容原地）
        let extra = appliedExtra
        appliedExtra = 0
        let sv = StreamScrollAnchor.AnchorView.chatScrollView
        let sendDismiss = CACurrentMediaTime() < KeyboardInsetBridge.shared.sendDismissUntil
        if sendDismiss { KeyboardInsetBridge.shared.sendDismissUntil = 0 }
        if sendDismiss {
            // send-scroll-policy（粟粟 09-07 规则 1/2）：发送时按离底距离分档——
            // 1.5 屏内=同帧塌+归底（钉死中间帧，修「发送整页上下滑行一下」）；
            // 1.5 屏外=内容锚定（offset−hold，同 away 分支算术），新回复靠回底钮徽章提示。
            // 旧 offset:nil「终态天然正确」在 6 行长文（growth 塌陷变大）下被实测证伪。
            slideGen += 1; slideInFlight = false
            if extra >= 1, let sv, hostingControllers.count > 1 {
                let inset = sv.adjustedContentInset.top
                let fromBottom = sv.contentOffset.y + inset
                if fromBottom > sv.bounds.height * KeyboardInsetBridge.sendReturnToBottomScreens {
                    KBProbe.log(String(format: "hide branch=sendDismiss far fb=%.0f → anchor", fromBottom))
                    releaseExtra(offset: sv.contentOffset.y - extra)
                } else {
                    KBProbe.log(String(format: "hide branch=sendDismiss near fb=%.0f → bottom", fromBottom))
                    releaseExtra(offset: -inset)
                }
            } else {
                KBProbe.log("hide branch=sendDismiss → release now")
                releaseExtra(offset: nil)
            }
        } else if extra >= 1, let sv, sv.contentOffset.y < 200 + extra, hostingControllers.count > 1 {
            // 在底（弹起动画飞行中被打断也算：模型已是 -inset，表现层在半路）：垫块 hold 住，
            // offset 按键盘曲线滑到 -inset+hold（内容随键盘下移），完成后 release 同帧塌垫块+归底
            KBProbe.log(String(format: "hide branch=slide-out(CA) hold=%.0f", extra))
            let inset = sv.adjustedContentInset.top
            animateOffset(sv, to: -inset + extra, tag: "hide") { [weak self] in
                self?.releaseExtra(offset: -inset)
            }
        } else if extra >= 1, let sv {
            KBProbe.log(String(format: "hide branch=away → release off−%.0f", extra))
            slideGen += 1; slideInFlight = false
            releaseExtra(offset: sv.contentOffset.y - extra)
        } else {
            KBProbe.log("hide branch=layout-only → release")
            slideGen += 1; slideInFlight = false
            releaseExtra(offset: nil)
        }
    }

    @objc private func keyboardDidChangeFrame(_ notification: Notification) {
        kbTransitionGen += 1
        KeyboardInsetBridge.shared.kbTransitioning = false
        publishKeyboardGeometry()
        KBProbe.log("KB did \(kbState())")
    }

    /// 输入条单行紧凑高度（容器只放输入字段时的高度）：容器超出它的部分 = 列表垫块要补的量
    private static let compactBarHeight: CGFloat = 74
    /// 滚动逻辑**已经补偿过**的 extra（08-26）。P1 后桥里的 extra 在 layout 里先发布、键盘通知后到，
    /// 拿桥当基线算增量永远是 0（探针：`rise extra=312 deltaE=0 farAway=1` → 深翻弹键盘垫块长 312
    /// 没人钉 = 内容推 1/3 屏）。增量只能相对「上次 rise/hide 处理到哪」算。
    private var appliedExtra: CGFloat = 0

    /// 键盘几何单一发布点（plan-keyboard-single-truth P1）。三值全是**同一帧布局**的派生量：
    /// - extra        = 键盘在 chat HC 里遮住的高度（真相 = keyboardLayoutGuide，输入条本来就绑它）
    /// - containerTop = 输入条容器顶边（回底按钮锚的容器分量）
    /// - barGrowth    = 容器超出单行的部分（chip 行/引用条/多行编辑器）——**容器高度本身就是真相**，
    ///   不再由 SwiftUI 侧自报（旧法数值对了但容器没 re-solve = 输入框上移不复位，Bug3）
    /// 三个手算副本各自更新是三 bug 同根（research-keyboard-single-truth），这里统一。
    private func publishKeyboardGeometry() {
        guard hostingControllers.count > 1 else { return }
        // ⚠️ 只在 chat 页是当前页时发布（08-26 Bug1 根因）：keyboardLayoutGuide 是 window 级的，
        // 终端页/中庭页弹收键盘时 chat HC 的 guide 也跟着动 → 把别人的键盘几何写进 chat 页的桥
        //（探针实证：终端收键盘留下 extra=18 / cTop=786，回 page1 后首次弹起容器落 563 而非 511，
        // 差 52pt = 输入框看着被键盘遮）。不在 chat 页时桥保持不动，翻回来的 layout pass 自然重发。
        guard currentPage == 1 else { return }
        let chatHC = hostingControllers[1]
        let b = KeyboardInsetBridge.shared
        let guideTop = chatHC.view.keyboardLayoutGuide.layoutFrame.minY
        let systemBottom = max(0, chatHC.view.safeAreaInsets.bottom - chatHC.additionalSafeAreaInsets.bottom)
        // 键盘高度只在 chat 页真的有输入焦点时才可能非零（08-26 Bug1 二审）：翻回 page1 的头几帧
        // guide 还停在终端页离开时的位置（探针实证 786/440/544 = 终端键盘几何残留，比正常低 52pt），
        // 而此时 chat 页根本没人在输入 —— 没有 first responder 就没有键盘，一律 0，不信 guide 的过渡帧
        let hasFocus = KBProbe.firstResponderName(in: chatHC.view) != "-"
        var extra = hasFocus ? max(0, chatHC.view.bounds.maxY - guideTop - systemBottom) : 0
        // §4b hold：键盘可见期间算出「降到 0」不发布（垫块留着），只有 keyboardWillHide 的 release 才把它发成 0——
        // 否则 SwiftUI commit 与键盘通知谁先谁后不定（36 次：25/11），钉位必错一帧。1s 保险防 willHide 丢失。
        if extra == 0, b.extra > 0.5 {
            if !holdArmed {
                holdArmed = true
                holdSafetyGen += 1
                let g = holdSafetyGen
                KBProbe.log(String(format: "hold extra %.0f (layout says 0)", b.extra))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.holdArmed, self.holdSafetyGen == g else { return }
                    KBProbe.log("hold safety → release")
                    self.slideGen += 1; self.slideInFlight = false
                    self.releaseExtra(offset: nil)
                }
            }
            extra = b.extra
        }
        // §4f 深翻抑制：垫块从 0 要长起来的那一刻列表离底超过 returnToBottomScreens → 不长（extra 发 0）
        if extra > 0.5, b.extra < 0.5, !b.padSuppressed, let sv = StreamScrollAnchor.AnchorView.chatScrollView {
            let dist = sv.contentOffset.y + sv.adjustedContentInset.top
            if dist > sv.bounds.height * KeyboardInsetBridge.returnToBottomScreens {
                b.padSuppressed = true
                KBProbe.log(String(format: "pad suppressed (far, dist=%.0f)", dist))
            }
        }
        if b.padSuppressed { extra = 0 }
        // C-slide：carrier 定高，容器 minY/height 不再是栈几何——真相 = carrier 底（平移分量，UIKit）
        // − 可见栈高（内容分量，SwiftUI 自报 barVisibleHeight）。
        let top = inputBarContainer.map { $0.frame.maxY - b.barVisibleHeight } ?? b.containerTop
        let growth = max(0, b.barVisibleHeight - Self.compactBarHeight)
        guard abs(extra - b.extra) > 0.5 || abs(top - b.containerTop) > 0.5 || abs(growth - b.barGrowth) > 0.5 else { return }
        KBProbe.log(String(format: "publish extra %.0f→%.0f cTop %.0f→%.0f growth %.0f→%.0f container=%@",
                           b.extra, extra, b.containerTop, top, b.barGrowth, growth,
                           inputBarContainer.map { KBProbe.f($0.frame) } ?? "-"))
        if abs(extra - b.extra) > 0.5 { b.extra = extra }
        if abs(top - b.containerTop) > 0.5 { b.containerTop = top }
        if abs(growth - b.barGrowth) > 0.5 { b.barGrowth = growth }
    }

    /// 兼容旧调用名（内部转发到单一发布点）
    private func publishContainerTop() { publishKeyboardGeometry() }

    /// kick 落地（C-slide 瘦身版）：容器定高不随内容变，KB-P3 一族（invalidate/re-solve）退役；
    /// 这里只统一发布几何——barVisibleHeight（SwiftUI 自报）驱动 containerTop/growth，键盘不在动时
    /// 包 easeOut 曲线（垫块与换行同曲线，今天 C7b 的 publish 行为原样）。
    private func resolveBarContainer(tag: String) {
        #if DEBUG
        let visH = KeyboardInsetBridge.shared.barVisibleHeight
        KBProbe.log(String(format: "[KICK] %@ visibleH=%.0f container=%@", tag, visH,
                           inputBarContainer.map { KBProbe.f($0.frame) } ?? "-"))
        HitchProbe.mark(String(format: "barKick vis→%.0f", visH))
        #endif
        if !KeyboardInsetBridge.shared.kbTransitioning {
            withAnimation(.easeOut(duration: KeyboardInsetBridge.fieldHeightAnimation)) { publishKeyboardGeometry() }
        } else {
            publishKeyboardGeometry()
        }
    }

    /// 翻页落地后补记一次（对比翻页瞬间：谁在这中间挪了 offset）
    func probeSettledAfterPaging() {
        KBProbe.log(svState("  page-settled sv page=\(currentPage)"))
    }

    /// 翻到 chat 页：等 guide 收敛（下一 runloop）后强制 layout 并重发几何，冲掉别页留下的过渡值
    private func resyncChatGeometryAfterPaging() {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        // A5（perf P0 §6.7）：触发源 + 请求 ID 在调度 async 块时捕获；块内 layoutIfNeeded 前到 publish 后 = inclusive 成本
        let perfTrigger = PerfHarness.strictMeasure ? PerfChatV1.takeResyncTrigger() : ""
        let perfReq = PerfHarness.strictMeasure ? PerfHarness.currentReqId : 0
        #endif
        guard currentPage == 1, hostingControllers.count > 1 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentPage == 1 else { return }
            #if (DEBUG || PERF_BENCH) && os(iOS)
            let perfBegin = PerfHarness.strictMeasure ? CACurrentMediaTime() : 0
            let perfBefore = PerfHarness.strictMeasure ? PerfChatV1.keyboardGeometry() : [:]
            #endif
            // L7 A5：几何已在无键盘位、桥值已对 = 这次强制布局 + 重发是空操作，整页布局留给下一次提交
            if ChatPerfSwitch.a5, self.resyncIsNoop() {
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure {
                    PerfChatV1.resyncDone(req: perfReq, trigger: perfTrigger + ":skip", begin: perfBegin, end: CACurrentMediaTime(),
                                          before: perfBefore, after: PerfChatV1.keyboardGeometry())
                }
                #endif
                KBProbe.log("resync after paging skipped (A5) → \(self.kbState())")
                return
            }
            self.hostingControllers[1].view.layoutIfNeeded()
            self.publishKeyboardGeometry()
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if PerfHarness.strictMeasure {
                PerfChatV1.resyncDone(req: perfReq, trigger: perfTrigger, begin: perfBegin, end: CACurrentMediaTime(),
                                      before: perfBefore, after: PerfChatV1.keyboardGeometry())
            }
            #endif
            KBProbe.log("resync after paging → \(self.kbState())")
        }
    }

    /// L7 A5（plan-chat-list-perf §3）：翻页后的强制布局 + 重发几何是否必然是空操作——无键盘、无过渡、无 hold；
    /// 整个 window 没有 first responder（别页键盘没留焦点）；chat 页 guide 与输入条容器已落在无键盘位；
    /// 按当前容器 frame 现算的 containerTop / barGrowth 与桥里已发布值相符（与 publishKeyboardGeometry 同式）
    private func resyncIsNoop() -> Bool {
        let b = KeyboardInsetBridge.shared
        guard !b.kbVisible, !b.kbTransitioning, b.extra < 0.5, !holdArmed,
              KBProbe.firstResponderName(in: view.window) == "-",
              let container = inputBarContainer else { return false }
        let chatHC = hostingControllers[1]
        guard chatHC.additionalSafeAreaInsets.bottom == 0 else { return false }
        let chatView = chatHC.view!
        let restTop = chatView.bounds.maxY - chatView.safeAreaInsets.bottom
        let f = container.frame
        guard abs(chatView.keyboardLayoutGuide.layoutFrame.minY - restTop) <= 0.5,
              abs(f.maxY - restTop) <= 0.5, abs(f.height - chatView.bounds.height) <= 0.5 else { return false }
        let top = f.maxY - b.barVisibleHeight
        let growth = max(0, b.barVisibleHeight - Self.compactBarHeight)
        return abs(top - b.containerTop) <= 0.5 && abs(growth - b.barGrowth) <= 0.5
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        publishKeyboardGeometry()
        // 原 overlay：VStack+Spacer 推到底、忽略底部安全区、padding.bottom 15
        pageDots.frame = CGRect(x: (view.bounds.width - 30) / 2, y: view.bounds.height - 15 - 6, width: 30, height: 6)
        scrollView.frame = view.bounds
        if Self.stageMode { stageView.frame = view.bounds }
        let w = view.bounds.width
        let h = view.bounds.height

        // Wallpaper 同步 frame（CAGradientLayer 动画默认有 implicit action，关掉避免
        // view.bounds 初始 layout 时 gradient 渐变动画闪一下）
        wallpaperContainer.frame = view.bounds
        wallpaperImageView.frame = wallpaperContainer.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperGradientLayer.frame = wallpaperContainer.bounds
        CATransaction.commit()

        guard w > 0, h > 0 else { return }
        launchReadiness.resize(view.bounds.size)

        let pageBounds = CGRect(x: 0, y: 0, width: w, height: h)
        // 固定设备轮廓只在布局时更新，不随翻页进度改变圆度。
        let displayRadius = Page2DisplayCorner.radius(for: view)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, hc) in hostingControllers.enumerated() {
            let container = pageContainers[i]
            let center = CGPoint(x: Self.stageMode ? w / 2 : (CGFloat(i) + 0.5) * w, y: h / 2)
            // 同值不写（setter 无幂等保证，也会给页内发几何通知）；宿主尺寸真变了才是 C 的精确例外
            if container.bounds != pageBounds || container.center != center {
                PagingFlip.hit(.containerSetter, excepted: container.bounds.size != pageBounds.size ? "sizeChanged" : nil)
                container.bounds = pageBounds
                container.center = center
            }
            if container.layer.cornerRadius != displayRadius { container.layer.cornerRadius = displayRadius }
            if let snapshot = flipSnapshots[i] { snapshot.layer.cornerRadius = displayRadius }
            if hc.view.frame != pageBounds { hc.view.frame = pageBounds }
            if pageDimmers[i].frame != pageBounds { pageDimmers[i].frame = pageBounds }
        }
        CATransaction.commit()
        scrollView.contentSize = CGSize(width: w * CGFloat(hostingControllers.count), height: h)

        layoutHomeIndicatorShield()

        #if DEBUG
        if hostingControllers.count > 1 {
            let chatHC = hostingControllers[1]
            PROBE("[PROBE shield] viewDidLayoutSubviews bounds=\(view.bounds) shield=\(homeIndicatorShield.frame) hidden=\(homeIndicatorShield.isHidden) currentPage=\(currentPage) view.safeAreaInsets.bottom=\(view.safeAreaInsets.bottom) window.safeAreaInsets.bottom=\(view.window?.safeAreaInsets.bottom ?? -1) chatHC.frame=\(chatHC.view.frame) chatHC.safeAreaInsets.bottom=\(chatHC.view.safeAreaInsets.bottom) chatHC.additional.bottom=\(chatHC.additionalSafeAreaInsets.bottom)")
        }
        #endif

        // bounds.width 变化时 re-sync contentOffset 到 currentPage：
        // SwiftUI representable 首次 layout 可能给一个瞬时过渡 width（比 final 小），
        // 不 re-sync 会让 offset 卡在旧值 × currentPage（错位，看见两页各半）。
        if abs(lastLaidOutWidth - w) > 0.5 {
            let oldWidth = lastLaidOutWidth
            lastLaidOutWidth = w
            handleHostWidthChange(oldWidth: oldWidth, newWidth: w)
        }
        applyPageTransition()
        PagingCommands.shared.controllerLaidOut(self)
    }

    /// 宿主宽度变了（转屏 / 改窗 / Split View / 宽窄切换）：拖动 / 减速中按旧宽度下的 q 就近完成
    ///（未过半回源页、已过半到目标页，§1.9 E1）；静止时照旧把 offset 对到当前页
    private func handleHostWidthChange(oldWidth: CGFloat, newWidth: CGFloat) {
        if oldWidth > 0, scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            let page = min(max(Int((scrollView.contentOffset.x / oldWidth).rounded()), 0), hostingControllers.count - 1)
            endTransition(.size, to: page)
        } else {
            scrollView.setContentOffset(CGPoint(x: CGFloat(currentPage) * newWidth, y: 0), animated: false)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        layoutHomeIndicatorShield()
        #if DEBUG
        PROBE("[PROBE shield] viewSafeAreaInsetsDidChange shield=\(homeIndicatorShield.frame) view.safeAreaInsets.bottom=\(view.safeAreaInsets.bottom) window.safeAreaInsets.bottom=\(view.window?.safeAreaInsets.bottom ?? -1)")
        #endif
    }

    /// shield frame：底部贴边、宽 = view.bounds.width、高 = min(window.safeAreaInsets.bottom, 40)。
    /// 用 window.safeAreaInsets.bottom 而非 view.safeAreaInsets.bottom，因为 chat HC 的
    /// additionalSafeAreaInsets 会被键盘改 → view.safeAreaInsets 跟着浮动。window 的
    /// safeAreaInsets 是设备本身的（home indicator），不被 keyboard inset 污染。
    /// (Apple xcdoc: /documentation/uikit/uiview/safeareainsets — "Custom view subclasses
    /// can use this property to determine which areas are safe to lay out content in.")
    private func layoutHomeIndicatorShield() {
        let windowBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        let shieldH = min(max(0, windowBottom), 40)
        let frame = CGRect(
            x: 0,
            y: view.bounds.maxY - shieldH,
            width: view.bounds.width,
            height: shieldH
        )
        homeIndicatorShield.frame = frame
        // 维持最高 z（每次 layout 后 bring 回来，updatePages / addSubview 等可能搅 z）
        view.bringSubviewToFront(homeIndicatorShield)
    }

    // MARK: - Public API

    /// 当前页缓存，给 representable 判断要不要触发 scrollToPage。
    var programmaticCurrentPage: Int { currentPage }
    /// 上一次 updatePages 时的内容键（PagingContainerView 比对，判这次重交是不是内容真变了）
    var lastContentKey: PagingContentKey?
    /// 流式进行中（PagingContainerView 交来的值；哨兵记录的 diagStreaming，不读 SwiftUI 状态）
    var contentStreaming = false

    // MARK: - 状态栏
    //
    // 每页是独立 UIHostingController，SwiftUI 侧的 `.statusBarHidden(_:)` 只会更新
    // **它自己那个 HC** 的偏好；不把决定权显式交下去，UIKit 容器（本类）会用自己的
    // 默认值（显示），SwiftUI 的声明等于石沉大海。
    // 交给当前可见页 → 页里的 `.statusBarHidden` 才生效，翻走自动恢复。
    // 第二页开着全屏应用时由本类统一藏；终端例外（`appShowsStatusBar`），显示且用浅色字（暗底）。

    private var hidesHomeStatusBar: Bool {
        let scene = Page2SceneState.shared
        return currentPage == 2 && (scene.isEditing || (scene.hidesStatusBarForApp && !scene.appShowsStatusBar))
    }
    override var childForStatusBarHidden: UIViewController? { hidesHomeStatusBar ? nil : visiblePageController }
    override var prefersStatusBarHidden: Bool { hidesHomeStatusBar || super.prefersStatusBarHidden }
    private static weak var statusBarController: PagingViewController?
    static var topSafeAreaInset: CGFloat { statusBarController?.viewIfLoaded?.window?.safeAreaInsets.top ?? statusBarController?.viewIfLoaded?.safeAreaInsets.top ?? 0 }
    static func refreshStatusBar() {
        statusBarController?.setNeedsStatusBarAppearanceUpdate()
        statusBarController?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        currentPage == 2 && Page2SceneState.shared.hidesStatusBarForApp ? .top : []
    }
    private var lightHomeStatusBar: Bool {
        (currentPage == 2 && (Page2SceneState.shared.prefersLightStatusBar || Page2SceneState.shared.appShowsStatusBar))
            || (currentPage == 0 && Page0Stage.shared.lightStatusBar)   // page0 液态金属底
    }
    override var childForStatusBarStyle: UIViewController? { lightHomeStatusBar ? nil : visiblePageController }
    override var preferredStatusBarStyle: UIStatusBarStyle { lightHomeStatusBar ? .lightContent : super.preferredStatusBarStyle }

    private var visiblePageController: UIViewController? {
        hostingControllers.indices.contains(currentPage) ? hostingControllers[currentPage] : nil
    }

    func scrollToPage(_ page: Int, animated requestedAnimation: Bool) {
        PagingFlip.begin("programmatic")
        // 新的定位请求：作废旧中断还没跑的延迟钉位（否则它会把这次的结果拉回旧终点，R2-01）
        endingGeneration += 1
        endingTarget = nil
        // §1.9：命令打断手势 / 惯性 → 取消翻页 pan，无动画完成到命令目标页（晚到的 finishPaging 看到的就是目标页）
        let interrupting = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        if interrupting, isViewLoaded, scrollView.bounds.width > 0 {
            if page != currentPage { dismissKeyboard() }
            mountPendingPages()
            endTransition(.command, to: page)
            return
        }
        let animated = requestedAnimation
        // 程序化翻页（点底部 tab bar）也要收键盘 —— 这条路径不经过任何 dragging delegate，
        // 漏了它就是「点 tab 切页，终端快捷键条跟着穿模到聊天页」（粟粟截图实证）。
        if page != currentPage { dismissKeyboard() }
        KBProbe.log("page(scrollToPage) \(currentPage)→\(page) \(kbState())")
        KBProbe.log(svState("  page-prog sv"))
        let changed = page != currentPage
        mountPendingPages()
        endSnapshotSession()
        currentPage = page
        if changed { flashPageDots() }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure {
            PerfChatV1.setResyncTrigger("scrollToPage")
            if changed { PerfChatV1.flipBegin(to: page, animated: animated && !UIAccessibility.isReduceMotionEnabled) }
        }
        #endif
        resyncChatGeometryAfterPaging()
        updateShieldVisibility()
        setNeedsStatusBarAppearanceUpdate()
        guard isViewLoaded, scrollView.bounds.width > 0 else {
            // 还没 layout 好，currentPage 已更新，viewDidLayoutSubviews 会用新值对齐 offset
            return
        }
        let x = CGFloat(page) * scrollView.bounds.width
        let alreadyThere = abs(scrollView.contentOffset.x - x) < 0.5
        scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated && !UIAccessibility.isReduceMotionEnabled)
        applyPageTransition()
        if !(animated && !UIAccessibility.isReduceMotionEnabled) { scheduleLayerSync() }
        // 无动画 / 已在目标位置（不会有 didEndScrollingAnimation）：此刻就算落定
        if !(animated && !UIAccessibility.isReduceMotionEnabled) { PagingFlip.noteNoAnimation() }
        if alreadyThere || !(animated && !UIAccessibility.isReduceMotionEnabled) { verifyEndState(); PagingFlip.settle() }
    }

    /// 翻页命令入口（PageSync → PagingCommands，plan §3.2）。翻到聊天页且带内容目标时，先等「新内容已应用并布局过一次」
    /// 再滑（§3.3）：选中对话加载完 → 让聊天 HC 再布局一次 → 版本对上就滑；上限 300ms，超时照常滑并记一次诊断。
    /// 期间又来新命令（代际变）就放弃这一条。翻页窗口从真正开始滑（scrollToPage）算：等待期是新内容在挂载
    ///（选中对话加载完 → ContentView 因 path 衍生量重算 → updatePages），是内容的活，不是翻页发的通知。
    func performCommand(_ page: Int, animated: Bool, contentReady: (() -> String?)?, generation: Int) {
        guard page == 1, animated, let contentReady, hostingControllers.count > 1 else {
            PagingCommands.shared.started(generation)
            scrollToPage(page, animated: animated)
            return
        }
        let start = CACurrentMediaTime()
        let deadline = start + 0.3
        var mark: Int?
        var markedToken: String?
        var markedAt = 0
        func check() {
            guard PagingCommands.shared.isCurrent(generation) else { return }
            let readiness = launchReadiness
            // 每次都重查当前内容（R2-02）：标记后换了对话 / 重新进加载（token 变或为 nil）就清标记，等新内容就绪再标
            let token = contentReady()
            if mark != nil, token != markedToken { mark = nil; markedToken = nil }
            if let mark, readiness.layoutCount(1) > mark, readiness.laidOutRevision(1) == readiness.revision(1) {
                go(); return
            }
            if mark == nil, let token {
                markedToken = token
                mark = readiness.layoutCount(1)
                markedAt = Int((CACurrentMediaTime() - start) * 1000)
                hostingControllers[1].viewIfLoaded?.setNeedsLayout()
            }
            if CACurrentMediaTime() >= deadline {
                PagingFlip.noteCommandTimeout(mark == nil ? "content"
                    : (readiness.layoutCount(1) <= mark! ? "layout" : "revision") + "@\(markedAt)ms")
                go(); return
            }
            NextFrame.run { check() }
        }
        func go() {
            PagingCommands.shared.started(generation)
            scrollToPage(page, animated: animated)
        }
        check()
    }

    /// 楼层切换：整树重建前就近对齐，命令注册随之失效（plan §1.9 / §3.2）
    @objc private func pagingProfileWillSwitch() {
        if midTransition { endTransition(.profile, to: nearestPage) }
        PagingCommands.shared.unregister(self)
    }

    @objc private func pagingDidEnterBackground() {
        if midTransition { endTransition(.background, to: currentPage) }
    }

    // MARK: - 中断后的完整终态（plan §1.9 A-4）

    enum TransitionEnd: String { case size, scrollDisabled, command, background, profile, a11y }

    /// 不在整页位置（拖着 / 减速中 / 停在半路）
    private var midTransition: Bool {
        let w = scrollView.bounds.width
        guard w > 0 else { return false }
        let q = scrollView.contentOffset.x / w
        return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || abs(q - q.rounded()) > 0.001
    }

    private var nearestPage: Int {
        let w = scrollView.bounds.width
        guard w > 0 else { return currentPage }
        return min(max(Int((scrollView.contentOffset.x / w).rounded()), 0), hostingControllers.count - 1)
    }

    /// 所有中断走这一个幂等入口：先终止旧滚动（取消翻页 pan + 无动画定位到选定页），再走普通落定协议（finishPaging）
    /// 把 contentOffset / z 序 / 交互位 / AX 当前页 / 页码五样一次对齐，最后核一遍。
    /// 晚到的 didEndDragging → finishPaging 看到的已是整页位置 = 当前页，是空操作
    private func endTransition(_ reason: TransitionEnd, to page: Int) {
        let w = scrollView.bounds.width
        guard w > 0, !pageContainers.isEmpty else { return }
        KBProbe.log("page(endTransition \(reason.rawValue)) \(currentPage)→\(page)")
        PagingFlip.noteInterrupt(reason.rawValue)
        endingTarget = page
        endingGeneration += 1
        let generation = endingGeneration
        cancelPagingPan()
        scrollView.setContentOffset(CGPoint(x: CGFloat(page) * w, y: 0), animated: false)
        finishPaging()
        // 取消 pan 后 UIScrollView 自己的收尾（willEndDragging / 吸附 / 减速）在下一轮才跑：那之后再把选定页钉一次、核终态
        DispatchQueue.main.async { [weak self] in
            // 期间有新的定位请求（scrollToPage / 宽屏归位 / 命令 / 又一次中断）：这次钉位作废（R2-01）
            guard let self, self.endingGeneration == generation, self.endingTarget == page else { return }
            self.endingTarget = nil
            let w = self.scrollView.bounds.width
            guard w > 0 else { return }
            if self.scrollView.isDecelerating || abs(self.scrollView.contentOffset.x - CGFloat(page) * w) > 0.5 || self.currentPage != page {
                self.scrollView.setContentOffset(CGPoint(x: CGFloat(page) * w, y: 0), animated: false)
                self.finishPaging()
            } else {
                self.verifyEndState()
            }
        }
    }

    /// endTransition 选定的终点页：到下一轮钉完之前，晚到的 willEndDragging 把吸附目标改成它
    private var endingTarget: Int?
    /// 中断收尾代际：任何新的定位请求都推进它，让还没跑的「下一轮再钉」作废
    private var endingGeneration = 0

    private func cancelPagingPan() {
        let pan = scrollView.panGestureRecognizer
        guard pan.state == .began || pan.state == .changed else { return }
        let was = pan.isEnabled
        pan.isEnabled = false
        pan.isEnabled = was
    }

    /// §1.9 五样：contentOffset、z 序、交互位、AX 当前页、页码（currentPage ↔ Page2SceneState.isActive）。
    /// 只在 DEBUG / PERF 核；不一致记一条 endState 违规（PagingFlip）
    private func verifyEndState() {
        #if DEBUG || PERF_BENCH
        let w = scrollView.bounds.width
        guard w > 0, !pageContainers.isEmpty, !scrollView.isDragging, !scrollView.isDecelerating, endingTarget == nil else { return }
        var bad: [String] = []
        if abs(scrollView.contentOffset.x - CGFloat(currentPage) * w) >= 0.5 { bad.append("offset") }
        if Page2SceneState.shared.isActive != (currentPage == 2) { bad.append("page") }
        let deck = deckActive
        let topZ = pageContainers.map(\.layer.zPosition).max() ?? 0
        for (index, container) in pageContainers.enumerated() {
            if container.accessibilityElementsHidden != (index != currentPage) { bad.append("ax\(index)") }
            if deck {
                if container.isUserInteractionEnabled != (index == currentPage) { bad.append("hit\(index)") }
                if (container.layer.zPosition == topZ) != (index == currentPage) { bad.append("z\(index)") }
                if container.layer.affineTransform() != .identity { bad.append("tx\(index)") }
            }
        }
        PagingFlip.noteEndState(bad.isEmpty, detail: bad.joined(separator: "+"))
        #endif
    }

    @objc private func unregisterCommands() { PagingCommands.shared.unregister(self) }

    func setScrollEnabled(_ enabled: Bool) {
        requestedScrollEnabled = enabled
        applyScrollEnabled()
    }

    @discardableResult
    static func setPage2DragLocked(_ locked: Bool, owner: UUID, scrollView: UIScrollView) -> Bool {
        guard let controller = scrollView.delegate as? PagingViewController,
              controller.scrollView === scrollView else { return false }
        if locked {
            controller.page2DragLockOwners.insert(owner)
        } else {
            controller.page2DragLockOwners.remove(owner)
        }
        controller.applyScrollEnabled()
        return true
    }

    private func applyScrollEnabled() {
        let enabled = requestedScrollEnabled && page2DragLockOwners.isEmpty
        // §1.9 E3：禁滑那一刻不在整页位置 → 先回源页再禁
        if !enabled, scrollView.isScrollEnabled, midTransition { endTransition(.scrollDisabled, to: currentPage) }
        if scrollView.isScrollEnabled != enabled { scrollView.isScrollEnabled = enabled }
    }

    /// 宽屏悬浮面板形态开关（iPad 横屏等可用宽度 ≥ `Theme.landscapePanelThreshold`）。
    /// 进入时把三页横滑收成「固定停在聊天页」——**三页结构本身不动**：输入条挂在
    /// `hostingControllers[1]` 且要求 `count > 1`，减页会让它整条挂载链失效。
    /// 列表/更多两页由 SwiftUI 侧改传 EmptyView，避免与浮层重复渲染。
    private func setupPageDots() {
        pageDots.axis = .horizontal
        pageDots.spacing = 6
        pageDots.isUserInteractionEnabled = false
        pageDots.alpha = 0
        pageDots.layer.zPosition = 1000
        for _ in 0..<3 {
            let dot = UIView()
            dot.layer.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            pageDots.addArrangedSubview(dot)
        }
        view.addSubview(pageDots)
        // 原 overlay 的键盘条件是非动画状态切换 → 这里即时显隐；浮现期限不受影响
        pageDotsObservers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardShownForDots = true
                self?.applyPageDotsVisibility(duration: 0)
            }
        })
        pageDotsObservers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardShownForDots = false
                self?.applyPageDotsVisibility(duration: 0)
            }
        })
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.refreshPageDotColors()
        }
    }

    private var dotsAllowed: Bool { !keyboardShownForDots && !widePanelMode && currentPage != 2 }

    private func refreshPageDotColors() {
        for (i, dot) in pageDots.arrangedSubviews.enumerated() {
            dot.backgroundColor = i == currentPage ? UIColor(Theme.branchIndicator) : UIColor(Theme.textMuted.opacity(0.3))
        }
    }

    /// 可见 = 浮现期限内 && 此刻允许显示
    private func applyPageDotsVisibility(duration: TimeInterval) {
        let target: CGFloat = pageDotsShowing && dotsAllowed ? 1 : 0
        if duration == 0 {
            pageDots.layer.removeAllAnimations()
            pageDots.alpha = target
            return
        }
        guard pageDots.alpha != target else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]) {
            self.pageDots.alpha = target
        }
    }

    private func flashPageDots() {
        pageDotsHide?.cancel()
        pageDotsShowing = true
        refreshPageDotColors()
        applyPageDotsVisibility(duration: 0.15)
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pageDotsHide = nil
            self.pageDotsShowing = false
            self.applyPageDotsVisibility(duration: 0.4)
        }
        pageDotsHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: hide)
    }

    func setWidePanelMode(_ wide: Bool) {
        guard widePanelMode != wide else { return }
        widePanelMode = wide
        endSnapshotSession()
        applyPageDotsVisibility(duration: 0.2)
        // 只在进入宽屏时归位；退出时留在聊天页，让用户自己滑回去（转屏已经够突兀了）。
        // 拖动 / 减速中进宽屏：直接按 page1 收尾，不先回源页（R2-01）
        if wide {
            if midTransition || endingTarget != nil { endTransition(.size, to: 1) } else { scrollToPage(1, animated: false) }
        }
        applyPageInteraction()
        applyDeckBase()
        if isViewLoaded { applyPageTransition() }
        scheduleLayerSync()
    }

    /// 由 PagingContainerView 在 sticker 编辑模式 / 其他需要让出 home indicator 区时调用。
    /// hidden=true 时 shield 被 force-hide（编辑贴纸时 StickerKeyboardPanel 会延伸到 home indicator）。
    func setShieldHiddenByCaller(_ hidden: Bool) {
        guard shieldHiddenByCaller != hidden else { return }
        shieldHiddenByCaller = hidden
        updateShieldVisibility()
    }

    private func updateShieldVisibility() {
        guard isViewLoaded else { return }
        // shield 仅在 chat 页（page 1）+ 非外部 hide 时可见
        homeIndicatorShield.isHidden = (currentPage != 1) || shieldHiddenByCaller
        view.bringSubviewToFront(homeIndicatorShield)
        #if DEBUG
        PROBE("[PROBE shield] updateShieldVisibility currentPage=\(currentPage) shieldHiddenByCaller=\(shieldHiddenByCaller) → isHidden=\(homeIndicatorShield.isHidden)")
        #endif
    }

    /// 替换各页 SwiftUI rootView，让 SwiftUI state 变化 propagate 进每页。
    func updatePages(_ pages: [AnyView]) {
        launchReadiness.beginRootUpdate(Array(pages.indices))
        PagingFlip.hit(.updatePages)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfCount.hit("updatePages")
        #endif
        #if DEBUG
        // plan-ipad-panel-v2 §2.2 探针：拖面板宽度期间这里不该打印。只在宽屏形态记，iPhone 不吵
        if widePanelMode {
            updatePagesProbeCount += 1
            print("[PROBE ipad] updatePages #\(updatePagesProbeCount)")
        }
        #endif
        for (i, page) in pages.enumerated() where i < hostingControllers.count {
            if pendingPages[i] != nil { pendingPages[i] = page } else { assignLaunchRoot(page, index: i, reason: "update") }
        }
    }

    /// L4：把还没挂的页挂上真内容（幂等）；only 给定时只挂这几页
    private func mountPendingPages(only: Set<Int>? = nil) {
        guard !pendingPages.isEmpty else { return }
        for i in pendingPages.keys.sorted() where only?.contains(i) ?? true {
            guard let page = pendingPages.removeValue(forKey: i) else { continue }
            assignLaunchRoot(page, index: i, reason: "deferredMount")
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfCount.hit("mountPendingPages")
        #endif
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        PagingFlip.begin("finger")
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if AirPerfProbe.enabled { AirPerfProbe.shared.endPaging(to: currentPage, reason: "interrupted") }
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfHarness.noteDragBegan(state: launchReadiness, from: currentPage)
        if LaunchTrace.mountSequence != nil {
            // 诊断入口只保证手势目标；不发页码通知，不让单页组偷挂另一页。
            let target = min(2, max(0, currentPage + (scrollView.panGestureRecognizer.velocity(in: view).x < 0 ? 1 : -1)))
            mountPendingPages(only: [target])
        } else { mountPendingPages() }
        #else
        mountPendingPages()
        #endif
        beginSnapshotSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        cancelIdleMount()
        if let scene = view.window?.windowScene { LaunchSplash.bind(launchReadiness, in: scene) }
        for page in [0, 1] { launchReadiness.note("gestureReady", page: page, epoch: launchReadiness.epoch) }
        launchReadiness.check()
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if LaunchTrace.mountSequence != nil { return }
        #endif
        if Self.deferPolicy == "idle", !pendingPages.isEmpty {
            let epoch = launchReadiness.epoch
            let generation = idleMountGeneration
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.launchReadiness.valid, self.launchReadiness.epoch == epoch,
                          self.idleMountGeneration == generation else { return }
                    self.mountPendingPages()
                }
            }
            idleMountWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        // hybrid：列表页（常去、较轻）在主线程第一次真正空闲时预建；page2（玻璃主屏、最重）等第一次拖动
        if Self.deferPolicy == "hybrid", pendingPages[0] != nil { mountWhenIdle(pages: [0]) }
    }

    /// 首帧 0.3s 后，主线程第一次要休眠（beforeWaiting = 手头没活）且没在拖动时挂
    private func mountWhenIdle(pages: Set<Int>) {
        cancelIdleMount()
        let epoch = launchReadiness.epoch
        let generation = idleMountGeneration
        let armedAt = CACurrentMediaTime() + 0.3
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let traceID = UUID().uuidString
        #endif
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] obs, _ in
            MainActor.assumeIsolated {
                guard let self else {
                    #if (DEBUG || PERF_BENCH) && os(iOS)
                    LaunchTrace.event("hybridObserverRemoved", fields: ["observer": traceID, "reason": "ownerReleased"])
                    #endif
                    CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .defaultMode)
                    CFRunLoopObserverInvalidate(obs)
                    return
                }
                guard self.launchReadiness.valid, self.launchReadiness.epoch == epoch,
                      self.idleMountGeneration == generation else {
                    CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .defaultMode)
                    CFRunLoopObserverInvalidate(obs)
                    return
                }
                guard CACurrentMediaTime() >= armedAt, !self.scrollView.isTracking else { return }
                self.cancelIdleMount()
                self.mountPendingPages(only: pages)
            }
        }
        idleMountObserver = observer
        #if (DEBUG || PERF_BENCH) && os(iOS)
        idleMountTraceID = traceID
        LaunchTrace.event("hybridObserverInstalled", state: launchReadiness, fields: ["observer": traceID])
        #endif
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if AirPerfProbe.enabled { AirPerfProbe.shared.endPaging(to: currentPage, reason: "viewDisappeared") }
        #endif
        cancelIdleMount()
    }
    #if DEBUG
    private var updatePagesProbeCount = 0
    #endif

    /// B2：输入条 rootView 刷新（与 updatePages 同节奏，环境/参数变化跟上）
    func updateInputBar(_ bar: AnyView) {
        PagingFlip.hit(.rootAssign)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfCount.hit("updateInputBar")
        #endif
        launchReadiness.inputAssigned()
        if let host = inputBarHost as? LaunchRootHost {
            host.launchEpoch = launchReadiness.epoch
            host.launchRevision = launchReadiness.revision(-1)
        }
        inputBarHost?.rootView = launchRoot(bar, index: 1)
        // rootView 换树后显式重采样：内部字段可能换位置而外层尺寸不变（两个 KVO 都不响，
        // sol 终审 §4）。字段内偏移由新树 onGeometryChange 自报，这里补容器分量。
        DispatchQueue.main.async { [weak self] in self?.publishContainerTop() }
    }

    /// 应用 wallpaper 配置。SwiftUI 侧每次 state 变化触发 `updateUIViewController` 调用。
    /// - 线 a (2026-04-25)：同 config 整体短路（避免 4 个 layer setter + CATransaction commit）。
    /// - 同 imageURL + 同 saturation 时跳过重 decode + filter（避免每次 binding tick 重算）
    /// - gradient / opacity / offset 每次更新（开销小）
    func applyWallpaper(_ config: WallpaperConfig) {
        // 线 a (2026-04-25)：同 config 短路。Apple 不保证 alpha/transform/colors/bgColor
        // 任何 setter idempotent（Hermes Q3 verified）。每次 ContentView.body re-eval 都
        // 走一遍 4 个 setter + CATransaction commit 是浪费；这里在最外层一次拦掉。
        // WallpaperConfig 7 字段 Equatable（PagingViewController.swift L362-381），
        // gradientColors 用 cgColor 比较（UIColor == 是 ref，cgColor 是值），覆盖完整。
        guard config != lastAppliedWallpaperConfig else {
            #if DEBUG
            print("[PERF] applyWallpaper skip (config unchanged) t=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent()))")
            #endif
            return
        }
        defer { lastAppliedWallpaperConfig = config }

        wallpaperContainer.backgroundColor = UIColor(config.fill)
        deckBaseColor = UIColor(config.fill).withAlphaComponent(1)
        applyDeckBase()
        let opaque = UIColor(config.fill).cgColor.alpha >= 0.999
        if opaque != chatPageOpaque {
            chatPageOpaque = opaque
            if isViewLoaded { applyPageTransition() }
        }

        let needsImageRefresh = (config.imageURL != lastImageURL) || (config.saturation != lastSaturation)
        if needsImageRefresh {
            lastImageURL = config.imageURL
            lastSaturation = config.saturation
            if let url = config.imageURL,
               let raw = UIImage(contentsOfFile: url.path) {
                wallpaperImageView.image = applySaturation(config.saturation, to: raw)
                wallpaperImageView.isHidden = false
            } else {
                wallpaperImageView.image = nil
                wallpaperImageView.isHidden = true
            }
        }

        wallpaperImageView.alpha = config.opacity
        wallpaperImageView.transform = CGAffineTransform(translationX: config.offsetX, y: config.offsetY)

        // Gradient 颜色更新（关动画 implicit action 避免重绘闪烁）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperGradientLayer.colors = config.gradientColors.map { $0.cgColor }
        CATransaction.commit()
    }

    /// CIFilter.colorControls 的 saturation 预处理。saturation == 1.0 时跳过返回原图。
    /// xcdoc: /documentation/CoreImage/CIFilter-swift.class/colorControls()
    private func applySaturation(_ saturation: CGFloat, to image: UIImage) -> UIImage {
        guard abs(saturation - 1.0) > 0.001,
              let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.saturation = Float(saturation)
        guard let output = filter.outputImage,
              let cg = Self.sharedCIContext.createCGImage(output, from: output.extent) else {
            return image
        }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    @objc private func pageMotionPreferenceChanged() {
        if midTransition { endTransition(.a11y, to: nearestPage) }
        applyPageInteraction()
        applyDeckBase()
        applyPageTransition()
        scheduleLayerSync()   // 减弱动态 / VoiceOver 启停会切换 layer ↔ UIView 路径，切换后刷一次 SwiftUI 缓存
    }

    private func applyPageTransition() {
        let width = scrollView.bounds.width
        guard width > 0, !pageContainers.isEmpty else { return }
        let position = scrollView.contentOffset.x / width
        let enabled = !widePanelMode && !UIAccessibility.isReduceMotionEnabled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if deckActive { applyDeckPoses(position: position, width: width) } else { applyClassicPoses(position: position, width: width, enabled: enabled) }
        CATransaction.commit()
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PagingScreenFitProbe.capture(root: view, stage: stageView, pages: pageContainers,
                                    hosts: hostingControllers.map { $0.view }, current: currentPage, position: position)
        if UITestHooks.active {
            let settled = !scrollView.isDragging && !scrollView.isDecelerating
                && abs(position - CGFloat(currentPage)) < 0.001
            // UI 回归 W1：moved = 落到当前页以来翻页位置偏离的最大值（pt）；drags = 翻页 pan 开始拖动的累计次数。
            // 测试比较拖手柄前后两值不变 = 翻页手势没被触发、容器没动（astra R2 M04）
            if axPage != currentPage { axPage = currentPage; axMaxDeviation = 0 }
            axMaxDeviation = max(axMaxDeviation, abs(position - CGFloat(currentPage)) * width)
            if scrollView.isDragging && !axWasDragging { axDrags += 1 }
            axWasDragging = scrollView.isDragging
            axSettled = settled
            refreshPagingAXValue()
        }
        #endif
    }

    /// 裁切跟随页面角色，而不是页号；背景和暗罩铺满，移动前景保留设备圆角。
    /// 在位移的同一个禁隐式动画事务里切换，不改变半径。
    private func applyPageClipping(_ index: Int, moving: Bool) {
        let layer = pageContainers[index].layer
        if layer.masksToBounds != moving { layer.masksToBounds = moving }
        if let snapshot = flipSnapshots[index], snapshot.layer.masksToBounds != moving {
            snapshot.layer.masksToBounds = moving
        }
    }
    /// 原停靠几何（宽屏、VoiceOver、`MP_PAGING_DECK=0`）：静止页在原生位置，隐藏页钉屏外，page2 走 UIView.transform
    private func applyClassicPoses(position: CGFloat, width: CGFloat, enabled: Bool) {
        for (index, container) in pageContainers.enumerated() {
            // 从叠牌切回（宽屏 / VoiceOver / 开关）：z 序还原成按页号叠
            let classicZ = CGFloat(index * 10)
            if container.layer.zPosition != classicZ { container.layer.zPosition = classicZ }
            let pose = PagingTransitionGeometry.presentation(page: index, position: position, width: width,
                pageCount: pageContainers.count, enabled: enabled)
            // 容器在滚动内容里的原生位置（舞台模式下容器原点固定 0，不随 contentOffset 动）
            let nativeX = Self.stageMode ? 0 : (CGFloat(index) - position) * width
            // perf-flash C3a：不参与这次翻页的页（隐藏）钉在屏外固定位置（右侧页 x=宽、左侧页 x=−宽）。
            // 原来它随 contentOffset 原生平移，全局坐标每帧都变，页内任何读 .global 的视图就让这张
            // 看不见的页逐帧整图更新；钉住后全局坐标不变。露出时（pose.hidden=false）照常按 pose.x 摆
            var x = pose.hidden ? (CGFloat(index) > position ? width : -width) : pose.x
            var hidden = pose.hidden
            // 舞台模式：停在聊天页时列表页不藏、原地（x=0）垫在聊天页底下，被不透明的聊天页盖住，画面不变。
            // 往回翻时它不用「出场」（隐藏→可见那一帧要把积攒的布局一次补完，实测 1→0 最差帧 42→67ms）。
            // 只垫在聊天页下（它的壁纸底色不透明才垫）；page2 背景是否全不透明没法保证，不垫
            if Self.stageMode, enabled, index == 0, position >= 1, position < 2, chatPageOpaque {
                x = 0
                hidden = false
            }
            applyPageClipping(index, moving: !hidden && x != 0)
            let shown = pageView(for: index, movingTo: x - nativeX, hidden: hidden)
            let xform = CGAffineTransform(translationX: x - nativeX, y: 0)
            if usesLayerTransform(for: index, enabled: enabled) { shown.layer.setAffineTransform(xform) } else {
                if shown === container { PagingFlip.hit(.containerSetter) }
                shown.transform = xform
            }
            if shown === container { container.isHidden = hidden } else { shown.isHidden = hidden }
            container.accessibilityElementsHidden = index != currentPage
            pageDimmers[index].alpha = pose.dimOpacity
            if index == 2, Self.writesPage2Offset {
                let offset: CGFloat? = pose.hidden || pose.x >= width ? nil : pose.x
                if Page2SceneState.shared.pageOffset != offset { Page2SceneState.shared.pageOffset = offset }
            }
        }
        let front = min(max(Int(floor(position)) + 1, 0), pageContainers.count - 1)
        let frontView = flipSnapshots[front] ?? pageContainers[front]
        pageShadow.frame = frontView.frame
        pageShadow.layer.zPosition = CGFloat(front * 10 - 1)
        pageShadow.layer.shadowPath = UIBezierPath(roundedRect: pageShadow.bounds,
            cornerRadius: frontView.layer.cornerRadius).cgPath
        pageShadow.alpha = PagingTransitionGeometry.shadowStrength(position: position,
            pageCount: pageContainers.count, enabled: enabled)
    }

    /// 叠牌（plan §1.2）：三页的 UIView 几何永远是 x=0（SwiftUI 以为的位置 = 真相），途中只写 layer 仿射变换和 zPosition，
    /// 不隐藏、不写任何 UIView setter——翻页对页面零几何通知。只逐帧更新平移、暗罩与阴影，设备圆角保持不变。
    /// 过整数 q 那一帧在同一个 CATransaction 里交换主角和 z（反向越过、0↔2 连续 q 同理）
    private func applyDeckPoses(position: CGFloat, width: CGFloat) {
        let count = pageContainers.count
        for (index, container) in pageContainers.enumerated() {
            let pose = PagingTransitionGeometry.deck(page: index, position: position, width: width, pageCount: count)
            applyPageClipping(index, moving: pose.rank == 2 && pose.tx != 0)
            let xform = CGAffineTransform(translationX: pose.tx, y: 0)
            if index == 2 && !PagingSwitch.deckPage2 {
                if container.transform != xform {
                    PagingFlip.hit(.containerSetter)
                    container.transform = xform
                }
            } else if container.layer.affineTransform() != xform {
                container.layer.setAffineTransform(xform)
            }
            let z = CGFloat(pose.rank * 10)
            if container.layer.zPosition != z { container.layer.zPosition = z }
            if container.isHidden { container.isHidden = false }
            container.accessibilityElementsHidden = index != currentPage
            if pageDimmers[index].alpha != pose.dimOpacity { pageDimmers[index].alpha = pose.dimOpacity }
            if index == 2, Self.writesPage2Offset {
                let offset: CGFloat? = pose.rank == 2 && pose.tx < width ? pose.tx : nil
                if Page2SceneState.shared.pageOffset != offset { Page2SceneState.shared.pageOffset = offset }
            }
        }
        // 阴影跟主角的 layer 位置（layer.frame 含仿射变换），叠在主角正下方
        if let actor = PagingTransitionGeometry.deckActor(position: position, pageCount: count) {
            let layer = pageContainers[actor].layer
            pageShadow.frame = layer.frame
            pageShadow.layer.zPosition = 2 * 10 - 1
            pageShadow.layer.shadowPath = UIBezierPath(roundedRect: pageShadow.bounds, cornerRadius: layer.cornerRadius).cgPath
            pageShadow.alpha = PagingTransitionGeometry.shadowStrength(position: position, pageCount: count, enabled: true)
        } else if pageShadow.alpha != 0 {
            pageShadow.alpha = 0
        }
    }

    /// 叠牌时每个页容器垫主题底色底板；非叠牌（宽屏 / VoiceOver / 开关关）撤掉，同原行为
    private func applyDeckBase() {
        let color = deckActive ? deckBaseColor : nil
        for container in pageContainers where container.backgroundColor != color { container.backgroundColor = color }
    }

    /// 交互契约（plan §1.5）：叠牌下三页 UIView 都在 x=0，UIKit 命中按子视图顺序走（不看 zPosition）——
    /// 只有当前页开交互、下层页关；输入条宿主挂在聊天 HC 上，随聊天页一起开关。手势进行中不改（pan 生效后页内触摸本来就被取消），
    /// 当前页一换（手势落定 / 程序化开始）同一 runloop 里切。非叠牌（宽屏 / VoiceOver / 开关关）三页都开，同原行为
    private func applyPageInteraction() {
        let deck = deckActive
        for (index, container) in pageContainers.enumerated() {
            let on = !deck || index == currentPage
            if container.isUserInteractionEnabled != on { container.isUserInteractionEnabled = on }
        }
    }

    /// 叠牌是否生效：舞台模式、非宽屏、VoiceOver 关（VoiceOver 维持 UIView 回退路径，plan §1.6）。减弱动态下照样叠牌（只是没有减速动画）
    private var deckActive: Bool {
        PagingSwitch.deck && Self.stageMode && !widePanelMode && !UIAccessibility.isVoiceOverRunning
    }

    #if (DEBUG || PERF_BENCH) && os(iOS)
    private var axSettled = false
    /// 分页壳入口计数（PagingFlip.axFields）排在 inputFocused 之前：perfInputAccessibility 按 ";inputFocused=" 切前缀重拼
    func refreshPagingAXValue() {
        guard UITestHooks.active else { return }
        scrollView.accessibilityIdentifier = "paging-scroll"
        scrollView.accessibilityValue = "page=\(currentPage);settled=\(axSettled ? 1 : 0);moved=\(String(format: "%.1f", axMaxDeviation));drags=\(axDrags);launchRequested=\(LaunchSplash.requestedPolicy);launchEffective=\(launchReadiness.effectivePolicy);launchFallback=\(launchReadiness.fallbackReason);splash=\(LaunchSplash.phase.rawValue);\(PagingFlip.axFields);inputFocused=\(launchInput?.isFirstResponder == true ? 1 : 0);typedLength=\(launchInput?.text.count ?? 0)"
    }
    #endif
    #if (DEBUG || PERF_BENCH) && os(iOS)
    private var axPage = -1
    private var axMaxDeviation: CGFloat = 0
    private var axWasDragging = false
    private var axDrags = 0
    #endif

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        applyPageTransition()
        #if (DEBUG || PERF_BENCH) && os(iOS)
        uiTestInterruptIfDue()
        #endif
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishPaging() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfChatV1.flipEnd() }
        #endif
        applyPageTransition()
        scheduleLayerSync()
        verifyEndState()
        PagingFlip.settle()
    }


    /// 翻页**确定要发生**时就收键盘（而不是等翻完）。
    ///
    /// 原来只有 ContentView 的 `onChange(of: iOSPage)` 在收，但 iOSPage 是
    /// `scrollViewDidEndDecelerating` 才更新的 —— 整个翻页动画期间键盘和它的
    /// `inputAccessoryView`（终端快捷键条）都还在，跟着页面飘过去 = 粟粟说的「穿模到别的页」，
    /// 等页面停稳才收。翻得慢就看得见，翻得快一闪而过，所以是「有时候」。
    ///
    /// 用 willEndDragging 而不是 willBeginDragging：读 targetContentOffset 能判断这一拖
    /// 到底会不会真的翻页，「拖一下又弹回来」不该收键盘。
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView.bounds.width > 0 else { return }
        if let ending = endingTarget { targetContentOffset.pointee.x = CGFloat(ending) * scrollView.bounds.width }
        let target = Int(round(targetContentOffset.pointee.x / scrollView.bounds.width))
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if AirPerfProbe.enabled, scrollView.isDragging {
            AirPerfProbe.shared.beginPaging(from: currentPage, to: target)
        }
        #endif
        guard target != currentPage else { return }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfHarness.noteFingerRelease(from: currentPage, to: target)
        PerfSignals.flipBegan(from: currentPage, to: target)
        #endif
        dismissKeyboard()
    }

    /// 翻页前收键盘 —— **只对右页（终端所在页）做**。
    ///
    /// 为什么只对它：终端页翻走了键盘还挂着没意义。而聊天页的输入条是 B2 那套挂在 page
    /// 内部子层的 `InputBarStack`，跟着页面走本来就是对的，根本不需要提前收。
    ///
    /// ⚠️ 更重要的是**不能对聊天页做**：从聊天页提前收键盘，键盘收起动画会跟翻页动画撞在
    /// 一起，把绑 `keyboardLayoutGuide` 的输入条拉移位（粟粟实测「page1 的输入框被弄移位了」，
    /// 换掉 endEditing 也没好 —— 问题在时机不在手段）。聊天页维持原行为：
    /// ContentView 的 `onChange(of: iOSPage)` 翻完再收。
    ///
    /// 同理也别用 `window.endEditing(true)`：那是强收整棵树，范围更大，撞得更狠。
    private func dismissKeyboard() {
        guard currentPage == 2 else { return }
        // 只 resign。老实现还要先发通知让终端摘掉 inputAccessoryView（那条 52pt 会赖在
        // keyboardLayoutGuide 里不回落 34，把聊天页输入条顶高 18pt）—— 工具条改成终端页
        // 常驻层后 guide 里已经没有 accessory，摘条这一步连同通知一起退役。
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishPaging()
    }

    private func finishPaging() {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        defer { if AirPerfProbe.enabled { AirPerfProbe.shared.endPaging(to: currentPage, reason: "settled") } }
        #endif
        // S2：拖动会话收尾（落定 / 拖回原页都走这里），先撤快照，下面的 applyPageTransition 把真页面摆到终点
        endSnapshotSession()
        defer { scheduleLayerSync(); verifyEndState(); PagingFlip.settle() }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfCount.hit("finishPaging")
        PerfSignals.flipSettled()
        #endif
        guard scrollView.bounds.width > 0 else { return }
        let page = min(max(Int(round(scrollView.contentOffset.x / scrollView.bounds.width)), 0), hostingControllers.count - 1)
        guard page != currentPage else { applyPageTransition(); return }
        KBProbe.log("page(swipe) \(currentPage)→\(page) \(kbState())")
        KBProbe.log(svState("  page-swipe sv"))
        currentPage = page
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfChatV1.setResyncTrigger("finishPaging") }
        #endif
        resyncChatGeometryAfterPaging()
        updateShieldVisibility()
        setNeedsStatusBarAppearanceUpdate()   // 换页 = 换了决定状态栏的那个 child
        onPageChanged?(page)
        applyPageTransition()
        flashPageDots()
    }
}

/// home indicator 区透明 hit shield 的 UIView 子类。
///
/// 关键：`point(inside:)` 让 UIView 在 frame 内永远成为 deepest hit-test target，
/// UIKit 不会向 chat HC 内部的气泡 UIView 派发该 touch，bubble 的 UIContextMenuInteraction
/// 永远观察不到。挂的 UITap + UILongPress recognizer 各一个空 absorb action 吃掉手势。
///
/// xcdoc: /documentation/uikit/uiview/hittest(_:with:) — "Returns the farthest descendant
///        of the receiver in the view hierarchy (including itself) that contains a specified
///        point."
/// xcdoc: /documentation/uikit/adding-context-menus-in-your-app
@MainActor
final class HomeIndicatorHitShieldUIView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let inside = self.bounds.contains(point)
        #if DEBUG
        PROBE("[PROBE shield] point(inside:) point=\(point) bounds=\(bounds) inside=\(inside) isHidden=\(isHidden) windowSafeBottom=\(window?.safeAreaInsets.bottom ?? -1)")
        #endif
        return inside
    }
    @objc func absorbGesture() { /* 吃掉手势，不做任何事 */ }
}

/// Wallpaper 显示配置。SwiftUI 侧构造，UIKit 侧应用。
/// Equatable 让 PagingContainerView 可以在 updateUIViewController 里 diff 避免多余 apply。
struct WallpaperConfig: Equatable {
    let fill: Color
    let imageURL: URL?
    let saturation: CGFloat
    let opacity: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let gradientColors: [UIColor]

    // UIColor Equatable 比较（cgColor 层面）
    static func == (lhs: WallpaperConfig, rhs: WallpaperConfig) -> Bool {
        lhs.fill == rhs.fill
            && lhs.imageURL == rhs.imageURL
            && lhs.saturation == rhs.saturation
            && lhs.opacity == rhs.opacity
            && lhs.offsetX == rhs.offsetX
            && lhs.offsetY == rhs.offsetY
            && lhs.gradientColors.map { $0.cgColor } == rhs.gradientColors.map { $0.cgColor }
    }
}

/// B2：输入条 host 的 hit-test 透传容器——子树（SwiftUI 内容）命中正常返回，
/// 命中自身/hosting view 空白区时返回 nil 放行给下层（聊天列表/消息按钮行）。
final class PassthroughContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // C-slide：carrier 定高罩大半屏——可见栈（barVisibleHeight，SwiftUI 自报）上方的空白
        // 必须放行给下层（聊天列表/消息按钮行，P1 复现器场景），否则重开「hosting 被拉大罩屏」旧坑。
        // 主线程同步读非 @Published 字段；4pt slack 容动画期边缘。栈内命中交给 super（SwiftUI 语义原样）。
        // ➕ 面板打开时输入条只是透明占位：整块放行，否则面板工具条 / 贴纸被吃掉（astra R6 C1）
        let bridge = KeyboardInsetBridge.shared
        // 录语音锁定态：上方的锁 / 大按钮那块不放行（plan-voice-note M5c）
        if InputBarHitRule.passesThrough(pointY: point.y, carrierHeight: bounds.height,
                                         visibleHeight: bridge.barVisibleHeight, isPlaceholder: bridge.barIsPlaceholder,
                                         pointX: point.x, recordingHitRect: bridge.recordingHitRect) {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}


#if DEBUG || PERF_BENCH
// perf-flash 合成翻页驱动（plan-perf-flash M2.7 S4，synthetic）：松手即走 willEndDragging 的收键盘判定，
// 再开环按时间写 contentOffset 当减速（scrollViewDidScroll / applyPageTransition 逐帧照跑），到位走
// didEndDecelerating → finishPaging。没有真 pan 的 isTracking/isDragging 状态，真手指另用 XCUITest 交叉验。
extension PagingViewController {
    @objc private func perfLaunchInputBegan(_ note: Notification) {
        guard let field = note.object as? UITextView, let bar = inputBarHost?.viewIfLoaded,
              field.isDescendant(of: bar) else { return }
        LaunchTrace.event("inputFirstResponder", state: launchReadiness, page: 1, fields: ["firstResponder": field.isFirstResponder])
        perfInputAccessibility(field)
    }
    @objc private func perfLaunchInputChanged(_ note: Notification) {
        guard let field = note.object as? UITextView, let bar = inputBarHost?.viewIfLoaded,
              field.isDescendant(of: bar), field.isFirstResponder else { return }
        if LaunchTrace.time("firstTyped") == nil {
            LaunchTrace.event("firstTyped", state: launchReadiness, page: 1, fields: ["length": field.text.count, "firstResponder": true])
        }
        perfInputAccessibility(field)
    }
    private func perfInputAccessibility(_ field: UITextView) {
        guard UITestHooks.active else { return }
        let prefix = (scrollView.accessibilityValue ?? "").components(separatedBy: ";inputFocused=")[0]
        scrollView.accessibilityValue = prefix + ";inputFocused=\(field.isFirstResponder ? 1 : 0);typedLength=\(field.text.count)"
    }

    /// UI 回归 I 系列（plan §1.9 A-4）：`MP_UITEST_PAGING_INTERRUPT=原因@阈值@起始页`——手指从起始页拖动、偏离超过阈值（页宽比例）
    /// 时触发一次中断，走产品里同一个处理函数（尺寸变化无法在测试里真改，走 handleHostWidthChange 同宽分支）
    private static let uiTestInterrupt: (reason: String, threshold: CGFloat, from: Int)? = {
        guard UITestHooks.active, let raw = ProcessInfo.processInfo.environment["MP_UITEST_PAGING_INTERRUPT"] else { return nil }
        let parts = raw.split(separator: "@").map(String.init)
        guard parts.count == 3, let t = Double(parts[1]), let from = Int(parts[2]) else { return nil }
        return (parts[0], CGFloat(t), from)
    }()
    private static var uiTestInterruptFired = false

    private func uiTestInterruptIfDue() {
        // 舞台模式下翻页 pan 挂在 stageView 上，触摸不经过 scrollView，isTracking 恒 false——看 isDragging
        guard let hook = Self.uiTestInterrupt, !Self.uiTestInterruptFired, scrollView.isDragging, currentPage == hook.from else { return }
        let w = scrollView.bounds.width
        guard w > 0, abs(scrollView.contentOffset.x / w - CGFloat(currentPage)) >= hook.threshold else { return }
        Self.uiTestInterruptFired = true
        // 出了 didScroll 回调栈再中断（别在回调里重入 setContentOffset）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch hook.reason {
            case "size": self.handleHostWidthChange(oldWidth: w, newWidth: w)
            case "scrollDisabled":
                self.setScrollEnabled(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.setScrollEnabled(true) }
            case "background": self.pagingDidEnterBackground()
            case "a11y": self.pageMotionPreferenceChanged()
            case "command": NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
            case "wide":
                // 宽屏归位的竞态（R2-01）：同一次 representable 更新里先禁滑（中断 → 回源页）、再进宽屏（归 page1）
                self.setScrollEnabled(false)
                self.setWidePanelMode(true)
            default: break
            }
        }
    }

    func perfMountOnly(_ page: Int) { mountPendingPages(only: [page]) }
    func perfPageHitReady(_ page: Int) -> Bool {
        guard hostingControllers.indices.contains(page), let root = hostingControllers[page].viewIfLoaded,
              let window = root.window, perfSettledPage == page else { return false }
        let point = root.convert(CGPoint(x: root.bounds.midX, y: root.bounds.midY), to: window)
        return window.hitTest(point, with: nil)?.isDescendant(of: root) == true
    }
    var perfPendingPages: [Int] { pendingPages.keys.sorted() }
    var perfLaunchPolicy: String { launchReadiness.effectivePolicy }

    /// 已停稳在哪页；滑动 / 程序化动画中返回 -1
    var perfSettledPage: Int {
        let w = scrollView.bounds.width
        guard w > 0, abs(scrollView.contentOffset.x - CGFloat(currentPage) * w) < 0.5 else { return -1 }
        return currentPage
    }

    /// 诊断（MP_PERF_LAYOUTCOUNT=1）：数每个托管视图的 layoutSubviews 次数（p0/p1/p2/bar），定位翻页逐帧重排的是哪一页
    /// 每进程只装一次（C-3）：swizzle 改的是托管视图类的实现，楼层切换新建 PagingViewController 再装一次会把计数块套两层
    private static var layoutCounterInstalled = false
    func perfInstallLayoutCounter() {
        guard ProcessInfo.processInfo.environment["MP_PERF_LAYOUTCOUNT"] == "1", !Self.layoutCounterInstalled else { return }
        Self.layoutCounterInstalled = true
        var views: [ObjectIdentifier: String] = [:]
        for (i, hc) in hostingControllers.enumerated() { views[ObjectIdentifier(hc.view)] = "p\(i)" }
        if let bar = inputBarHost?.view { views[ObjectIdentifier(bar)] = "bar" }
        guard let cls = object_getClass(hostingControllers[0].view) else { return }
        let sel = #selector(UIView.layoutSubviews)
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return }
        defer { free(list) }
        guard let method = (0..<Int(count)).map({ list[$0] }).first(where: { method_getName($0) == sel }) else { return }
        typealias Original = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        // 嵌套托管视图按「在哪页 / 根视图类型」分开数（1↔2 翻页 ~140ms/次的逐帧重排到底是谁）；
        // 装计数器时页容器还没建，运行时现取
        let where_: (UIView) -> String = { [weak self] v in
            if let name = views[ObjectIdentifier(v)] { return name }
            let containers = self?.pageContainers ?? []
            var p = v.superview
            while let cur = p {
                if let i = containers.firstIndex(where: { $0 === cur }) {
                    let t = String(describing: type(of: v))
                    let root = t.split(separator: "<", maxSplits: 1).dropFirst().first.map { String($0.prefix(48)) } ?? t
                    return "p\(i)/\(root)"
                }
                p = cur.superview
            }
            let t = String(describing: type(of: v))
            let root = t.split(separator: "<", maxSplits: 1).dropFirst().first.map { String($0.prefix(60)) } ?? t
            var top = v
            var chain: [String] = []
            while let sup = top.superview {
                top = sup
                let n = String(describing: type(of: sup))
                if n.contains("Hosting") || n.contains("Window") || n.contains("TransitionView") { chain.append(String(n.prefix(40))) }
            }
            return "other/\(root) @ \(chain.prefix(4).joined(separator: ">"))"
        }
        let block: @convention(block) (UIView) -> Void = { obj in
            PerfCount.hit("layout.\(where_(obj))")
            original(obj, sel)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        // 谁在逐帧给托管视图标脏：setNeedsLayout 的调用栈（去掉前 2 帧自身，取 8 帧符号名）
        let snlSel = #selector(UIView.setNeedsLayout)
        if let snlMethod = class_getInstanceMethod(cls, snlSel) {
            let snlOriginal = unsafeBitCast(method_getImplementation(snlMethod), to: Original.self)
            let snlBlock: @convention(block) (UIView) -> Void = { obj in
                let frames = Thread.callStackSymbols.dropFirst(2).prefix(8).map { line -> String in
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    return parts.count > 3 ? parts[3...].joined(separator: " ").components(separatedBy: " + ").first ?? "" : line
                }
                PerfCount.hit("snl.\(where_(obj)) <- \(frames.joined(separator: " < "))")
                snlOriginal(obj, snlSel)
            }
            method_setImplementation(snlMethod, imp_implementationWithBlock(snlBlock))
        }
        let saSel = #selector(UIView.safeAreaInsetsDidChange)
        if let saMethod = (0..<Int(count)).map({ list[$0] }).first(where: { method_getName($0) == saSel }) {
            let saOriginal = unsafeBitCast(method_getImplementation(saMethod), to: Original.self)
            let saBlock: @convention(block) (UIView) -> Void = { obj in
                PerfCount.hit("safeArea.\(where_(obj))")
                saOriginal(obj, saSel)
            }
            method_setImplementation(saMethod, imp_implementationWithBlock(saBlock))
        }
    }

    @MainActor func perfDrive(to page: Int, duration: Double) async {
        let w = scrollView.bounds.width
        guard w > 0 else { return }
        let from = scrollView.contentOffset.x
        let to = CGFloat(page) * w
        // 手指按下开拖（L4 在这挂未挂的页）→ 松手时刻 willEndDragging 的收键盘判定（目标页 ≠ 当前页才收）
        PagingFlip.synthetic = true
        defer { PagingFlip.synthetic = false }
        if LaunchTrace.mountSequence != nil {
            LaunchTrace.event("syntheticTouchDown", state: launchReadiness, fields: ["to": page])
            mountPendingPages(only: [page])
            beginSnapshotSession()
        } else { scrollViewWillBeginDragging(scrollView) }
        if page != currentPage { dismissKeyboard() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            PerfPageDriver(scrollView: scrollView, from: from, to: to, duration: duration) { c.resume() }.start()
        }
        scrollViewDidEndDecelerating(scrollView)
    }
}

private final class PerfPageDriver: NSObject {
    private let scrollView: UIScrollView
    private let from: CGFloat
    private let to: CGFloat
    private let duration: Double
    private let done: () -> Void
    private var start0: Double = 0
    private var link: CADisplayLink?
    private var retainSelf: PerfPageDriver?

    init(scrollView: UIScrollView, from: CGFloat, to: CGFloat, duration: Double, done: @escaping () -> Void) {
        self.scrollView = scrollView
        self.from = from
        self.to = to
        self.duration = duration
        self.done = done
    }

    func start() {
        retainSelf = self
        start0 = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        let p = min(1, (CACurrentMediaTime() - start0) / duration)
        let eased = 1 - pow(1 - p, 3)
        scrollView.contentOffset.x = from + (to - from) * CGFloat(eased)
        guard p >= 1 else { return }
        link?.invalidate()
        link = nil
        done()
        retainSelf = nil
    }
}
#endif

/// 延到下一次 display-link 回调再跑：把落定时堆在一起的活拆开（不保证某一帧已提交 / 已上屏）
final class NextFrame: NSObject {
    private let work: () -> Void
    private init(_ work: @escaping () -> Void) { self.work = work }

    static func run(_ work: @escaping () -> Void) {
        CADisplayLink(target: NextFrame(work), selector: #selector(tick(_:))).add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        link.invalidate()
        work()
    }
}
#endif
