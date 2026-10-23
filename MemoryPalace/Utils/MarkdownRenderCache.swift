import SwiftUI
import SwiftStreamingMarkdown
#if os(iOS)
import UIKit.UIGestureRecognizerSubclass
#endif

/// L2-T3（roadmap-lody-adoptions）：Markdown 渲染缓存——深翻 26× 差（L1 基准 2.3fps vs lody 59.6fps）
/// 的直接病灶是库 MarkdownView 零缓存：LazyVStack 行每次进视口都全量 async parse，先渲 .empty
/// 再换真身（闪空+高度跳）。这里在 MP 包装层复刻库 MarkdownView 的 30 行逻辑并加全局缓存
/// （NSCache，countLimit 200；淘汰顺序由系统定、不保证 LRU）：
/// 命中在 init 同步取（首帧即真身，零闪空）；库零改动（lody ChatMarkdownStore 的等价物）。
///
/// key = 渲染维度摘要（字体/缩放/动画/菜单形状/划线摘要）+ 文本；Entry 存原文校验防 hash 碰撞。
/// 深翻场景绝大多数消息零划线且字体恒定 → key 实际退化为纯文本，命中率不受划线影响；
/// 她划一笔 → highlights 摘要变 → 自然失效重 parse，语义正确。
final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private final class Entry {
        let text: String
        let doc: RenderableDocument
        init(text: String, doc: RenderableDocument) { self.text = text; self.doc = doc }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.countLimit = 200
    }

    private func key(dims: String, text: String) -> NSString {
        "\(dims)#\(text.count)#\(text.hashValue)" as NSString
    }

    func lookup(dims: String, text: String) -> RenderableDocument? {
        guard let e = cache.object(forKey: key(dims: dims, text: text)), e.text == text else {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if PerfHarness.strictMeasure { PerfInlineCost.noteMdLookup(hit: false) }
            #endif
            return nil
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfInlineCost.noteMdLookup(hit: true) }
        #endif
        return e.doc
    }

    func store(_ doc: RenderableDocument, dims: String, text: String) {
        cache.setObject(Entry(text: text, doc: doc), forKey: key(dims: dims, text: text))
    }

    /// L1c（bug-long-message-async-blank 方案 A）：刚结束流式的助手节点。流式正文走 fork 增量渲染器、不进本缓存，
    /// 翻回静态分支那一刻 >3000 字必然未命中 → 空占位再长高；在这个窗口里静态行首见未命中也同步解析一次，以定稿维度存进缓存。
    /// 主线程读写（finishAssistantTurn / 视图 init）
    private var streamFinished: (nodeId: String, at: TimeInterval)?

    func noteStreamFinished(nodeId: String) {
        guard ChatL1Switch.prefill else { return }
        streamFinished = (nodeId, ProcessInfo.processInfo.systemUptime)
    }

    /// 流完 5 秒内的同一节点（定稿写回、静态分支首见都在这之内；之后的冷开照常走门槛）
    func isFreshlyStreamed(_ nodeId: String) -> Bool {
        guard let f = streamFinished, f.nodeId == nodeId else { return false }
        return ProcessInfo.processInfo.systemUptime - f.at < 5
    }

    /// kimi R14：同步解析过一次就清登记（之后走缓存命中，不再越门槛同步）
    func clearStreamFinished() {
        streamFinished = nil
    }
}

#if os(iOS)
/// perf L1 ①：启动 2 秒后空闲预热正文段落视图池（第一次打开对话就有池；池开关关时包里无事）。
/// R14-04 闲置门：流式 turn 在途、键盘过渡中、最近 500ms 有触摸都不建（包里另判 app 非 active）
enum ChatParagraphPrewarm {
    /// ConversationViewModel.assistantTurnInFlight 写
    nonisolated(unsafe) static var turnInFlight = false
    /// 窗口级被动手势记的最近一次触摸（systemUptime 秒）
    nonisolated(unsafe) static var lastTouchAt: TimeInterval = 0

    static func schedule() {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfTextKit.install()   // 测量角色：启动预热也记进 L1 计数（非测量角色 install 首句即返回）
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("ChatParagraphPrewarm.start") : nil
            defer { if let airSpan { AirProbeSections.leave(airSpan) } }
            #endif
            installTouchStamp()
            ParagraphViewPrewarm.idleGate = {   // 包在主 run loop 上调
                MainActor.assumeIsolated {
                    !turnInFlight && !KeyboardInsetBridge.shared.kbTransitioning
                        && ProcessInfo.processInfo.systemUptime - lastTouchAt > 0.5
                }
            }
            ParagraphViewPrewarm.start()
        }
    }

    private static func installTouchStamp() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchStampRecognizer }) else { return }
        window.addGestureRecognizer(TouchStampRecognizer())
    }

    /// 只记触摸时间、永不识别：不取消、不延迟别人的触摸
    private final class TouchStampRecognizer: UIGestureRecognizer {
        override init(target: Any? = nil, action: Selector? = nil) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { stamp() }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { stamp() }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { stamp(); state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { stamp(); state = .failed }
        private func stamp() { ChatParagraphPrewarm.lastTouchAt = ProcessInfo.processInfo.systemUptime }
    }
}
#endif

/// perf L1（plan-chat-list-perf §3）：长文首次渲染的 app 侧开关。DEBUG / PERF_BENCH 构建可用 env 置 "0"/"1" 改（同包 ABBA 对照），
/// 普通 Release 恒为默认值
enum ChatL1Switch {
    #if os(iOS)
    /// ③ 首见同步解析门槛 3000 → 6000 字（MP_PERF_L1_SYNC；R14-01 由 12000 收到 6000，默认开）
    static let syncLong = flag("MP_PERF_L1_SYNC", default: true)
    /// L1c 流完那一刻首见未命中也同步解析、以定稿维度存缓存，上限 = 门槛 ×2（MP_PERF_L1_PREFILL）。
    /// 默认关（10-02 l1c-7k-v9：7000 字终稿闪空 47ms → 0，但收尾最差间隔 273 → 449ms，用一次近半秒的卡换掉一下闪空，不划算；
    /// ③ 门槛 6000 以内的终稿本来就同步，L1c 只剩 6000–12000 这段在管）
    static let prefill = flag("MP_PERF_L1_PREFILL", default: false)
    #else
    /// R14-02：mac 没测过（滑杆拖动会让每行重进同步解析），固定原行为
    static let syncLong = false
    static let prefill = false
    #endif

    private static func flag(_ key: String, default on: Bool) -> Bool {
        #if DEBUG || PERF_BENCH
        if let v = ProcessInfo.processInfo.environment[key] { return v == "1" }   // kimi R14：只认 "1" 为开
        #endif
        return on
    }
}

/// 库 `MarkdownView` 的带缓存等价物（同款 task(id:) 语义）。listener 不进 key（交互层，不参与排版）。
struct CachedMarkdownView: View {
    let text: String
    let config: MarkdownRenderConfig
    let cacheDims: String
    /// L2-T3c：流式中间态（text 30Hz 变）——init 同步 parse 会白算（view identity 未变时
    /// State(initialValue:) 被丢弃），store 会用即死条目把 200 条缓存冲光（深翻缓存被流式打空）。
    /// transient 泡两者都跳过，只走异步 task（=T3b 前的流式行为）；定稿后 animated 翻 false 恢复缓存。
    var transient: Bool = false
    var listener: MarkdownListener? = nil
    /// L1c：刚流完的节点——首见未命中时不看长度门槛，同步解析一次（ChatMarkdownView 按 MarkdownRenderCache.isFreshlyStreamed 给）
    var syncOnMiss: Bool = false

    @State private var renderable: RenderableDocument?

    #if os(macOS)
    // R9b N1：单调请求代号——每次 task 启动 +1，只许比屏上更新的结果落地（旧晚到直接丢，
    // 新的还没到旧的照常显示，不饿死）。.task 换 id 时 SwiftUI 取消旧任务，但 parse 不检查取消
    // 仍会跑完，所以靠代号挡不靠取消。task 闭包在 MainActor 跑，代号比较无竞态。
    @State private var requestGen = 0
    @State private var shownGen = 0
    #endif

    /// 首见同步渲染的长度闸：3000 字符内 parse+convert 是纯 CPU 毫秒级，换掉「空占位→异步长高」
    /// 两段布局 + cellGrew 补偿（深翻基准 20s 内 412 次补偿的病灶）；超长消息仍走异步兜底。
    private static let syncParseLimit = 3000

    /// 实际门槛：③ 开 = 6000；测量钩子 MP_PERF_TEST_SYNC_LIMIT（L1c 验收：把 1969 字的流式终稿压过门槛，复现「流完闪空」）
    private static let effectiveSyncLimit: Int = {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure, let n = PerfHarness.env["MP_PERF_TEST_SYNC_LIMIT"].flatMap(Int.init) { return n }
        #endif
        return ChatL1Switch.syncLong ? 6_000 : syncParseLimit
    }()

    /// L1c 同步解析上限（R14-03）：门槛 ×2；更长的流完消息仍走异步（会闪一下空，换不掉主线程一次性卡太久）
    private static var syncOnMissLimit: Int { effectiveSyncLimit * 2 }

    #if (DEBUG || PERF_BENCH) && os(iOS)
    /// 渲染账本 markdown 回执（perf P0 §5.3）：构造时捕获请求 ID 与 fixture 标记节点（非 @State，body 重算只影响之后启动的 task）
    private let perfReq: Int
    private let perfNode: String?
    #endif

    init(text: String, config: MarkdownRenderConfig, cacheDims: String, transient: Bool = false, listener: MarkdownListener? = nil,
         syncOnMiss: Bool = false) {
        self.text = text
        self.config = config
        self.cacheDims = cacheDims
        self.transient = transient
        self.listener = listener
        self.syncOnMiss = syncOnMiss
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure {
            perfReq = PerfHarness.currentReqId
            // R5 C-03：fixture 标记优先；无标记的长文（会走异步）用 ChatMarkdownView 放下的本行 nodeId
            let bodyNode = PerfRenderLedger.takeBodyNode()
            perfNode = PerfRenderLedger.markerNode(text)
                ?? (!transient && text.utf8.count > min(Self.syncParseLimit, Self.effectiveSyncLimit)
                    && text.count > min(Self.syncParseLimit, Self.effectiveSyncLimit) ? bodyNode : nil)
                ?? (bodyNode != nil && bodyNode == PerfRenderLedger.testBlankNode ? bodyNode : nil)   // M3 反例钩子点名的行
        } else {
            perfReq = 0
            perfNode = nil
        }
        #endif
        // 命中同步带初值：首帧即真身，消灭「先 .empty 再跳高度」的振荡源
        if let hit = MarkdownRenderCache.shared.lookup(dims: cacheDims, text: text) {
            _renderable = State(initialValue: hit)
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if let perfNode { PerfRenderLedger.noteMarkdown(nodeId: perfNode, text: text, cacheDims: cacheDims, kind: "initHit", reqId: perfReq) }
            #endif
        } else if !transient, text.count <= (syncOnMiss ? Self.syncOnMissLimit : Self.effectiveSyncLimit) {
            // L2-T3b：首见行同步 parse——首帧即真高，行高不再两段跳
            let parsed = MarkdownParserImpl().parseSync(text: text, config: config)
            MarkdownRenderCache.shared.store(parsed, dims: cacheDims, text: text)
            if syncOnMiss { MarkdownRenderCache.shared.clearStreamFinished() }
            _renderable = State(initialValue: parsed)
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if let perfNode { PerfRenderLedger.noteMarkdown(nodeId: perfNode, text: text, cacheDims: cacheDims, kind: "initSync", reqId: perfReq) }
            #endif
        } else {
            _renderable = State(initialValue: nil)
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        // M3 反例钩子 MP_PERF_TEST_BLANK_NODE：点名的行首见强制空占位（本来同步出真身的短行也闪空），不闪空探针必须判出
        if PerfHarness.strictMeasure, let perfNode, perfNode == PerfRenderLedger.testBlankNode { _renderable = State(initialValue: nil) }
        #endif
    }

    var body: some View {
        DocumentView(renderableDocument: renderable ?? .empty, config: config, listener: listener)
            #if os(iOS)
            .task(id: text) {
                #if DEBUG || PERF_BENCH
                // M3 不闪空探针：以空占位上屏（renderable == nil → DocumentView(.empty)）记开头，真身落地的 taskHit / asyncEnd 回执收口
                if let perfNode, renderable == nil {
                    PerfRenderLedger.noteBlankBegin(nodeId: perfNode, reqId: perfReq)
                    if perfNode == PerfRenderLedger.testBlankNode {
                        if PerfRenderLedger.testBlankBusy {
                            // R12-03 主线程忙版反例：空占位先提交上屏，再在主线程空转 200ms（期间没有 display-link 回调）
                            try? await Task.sleep(nanoseconds: 20_000_000)
                            let spinEnd = ProcessInfo.processInfo.systemUptime + 0.2
                            while ProcessInfo.processInfo.systemUptime < spinEnd {}
                        } else {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                        }
                    }
                }
                #endif
                if let hit = MarkdownRenderCache.shared.lookup(dims: cacheDims, text: text) {
                    if renderable != hit { renderable = hit }
                    #if DEBUG || PERF_BENCH
                    if let perfNode { PerfRenderLedger.noteMarkdown(nodeId: perfNode, text: text, cacheDims: cacheDims, kind: "taskHit", reqId: perfReq) }
                    #endif
                    return
                }
                #if DEBUG || PERF_BENCH
                PerfHarness.markdownPending += 1
                defer { PerfHarness.markdownPending -= 1 }
                if let perfNode { PerfRenderLedger.noteMarkdown(nodeId: perfNode, text: text, cacheDims: cacheDims, kind: "asyncBegin", reqId: perfReq) }
                #endif
                let parsed = await MarkdownParserImpl().parse(text: text, config: config)
                if !transient {
                    MarkdownRenderCache.shared.store(parsed, dims: cacheDims, text: text)
                }
                renderable = parsed
                #if DEBUG || PERF_BENCH
                if let perfNode { PerfRenderLedger.noteMarkdown(nodeId: perfNode, text: text, cacheDims: cacheDims, kind: "asyncEnd", reqId: perfReq) }
                #endif
            }
            #else
            // R9b N1：mac 一个 task 管「文本 + 渲染维度」（主题/字号/排版滑杆都在 cacheDims 里——
            // 字体颜色是 parse 时写进 attributed string 的，L3 只吃 text 会留旧渲染）。
            // 取代 L3b 的 onChange 方案：onChange 与 task 双写 renderable 会「旧解析晚到盖新结果」。
            .task(id: text + "\u{1F}" + cacheDims) {
                requestGen += 1
                let gen = requestGen
                if let hit = MarkdownRenderCache.shared.lookup(dims: cacheDims, text: text) {
                    if gen > shownGen {
                        shownGen = gen
                        if renderable != hit { renderable = hit }
                    }
                    return
                }
                let parsed = await MarkdownParserImpl().parse(text: text, config: config)
                // 按键存：旧维度的结果存进它自己的键也是对的（拖滑杆来回时复用）
                if !transient {
                    MarkdownRenderCache.shared.store(parsed, dims: cacheDims, text: text)
                }
                guard gen > shownGen else { return }   // 旧请求晚到：丢，不盖屏
                shownGen = gen
                renderable = parsed
            }
            #endif
    }
}
