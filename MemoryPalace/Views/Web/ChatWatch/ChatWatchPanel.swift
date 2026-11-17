#if os(iOS)
import Combine
import SwiftData
import SwiftUI
import UIKit
import Vision
import WebKit

/// 一起看小窗的状态（docs/plan-chat-watch-together.md W1）：跟着当前对话走，网页只有一张（换对话就换网址），
/// 收起成胶囊时网页留在界面上（声音不停）。
@MainActor
@Observable
final class ChatWatch {
    static let shared = ChatWatch()

    static let minHeight: CGFloat = 110
    static let toolbarHeight: CGFloat = 38
    static let capsuleHeight: CGFloat = 40
    static let startBarHeight: CGFloat = 52
    static var maxHeight: CGFloat { (UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }.first ?? 800) * 0.55 }

    private(set) var conversationId: String?
    private(set) var isOpen = false
    /// nil = 还没开网页（显示「搜索或输入网址」）
    private(set) var url: URL?
    var height: CGFloat = CGFloat(ChatWatchStore.defaultHeight)
    /// 消息列表让位用的高：拖的时候不跟（每帧改列表留白 = 每帧重排整个消息列表，11-11 misc 量到列表重排卡死），松手才更新
    private(set) var settledHeight: CGFloat = CGFloat(ChatWatchStore.defaultHeight)
    var collapsed = false
    /// 网页里点到的当前页（工具条上的域名跟着它）
    private(set) var pageURL: URL?
    /// 只看视频：页面上有视频就铺满小窗（默认开，工具条上切；记在本机）
    var fillVideo = UserDefaults.standard.object(forKey: ChatWatch.fillVideoKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(fillVideo, forKey: Self.fillVideoKey)
            let js = ChatWatchPerception.fillJS(fillVideo)
            Task { _ = try? await webView?.evaluateJavaScript(js) }
            // 视频页 ↔ 嵌入播放器：「只看视频」= 站方嵌入页（接着现在的进度），「看整页」= 回原网页（v2 V2）
            if let current = controller.url, let ref = ChatWatchPerception.videoRef(current) {
                let embedded = ChatWatchPerception.isEmbed(current)
                if fillVideo, !embedded { controller.load(ref.embedURL(start: probe?.time)) }
                if !fillVideo, embedded { controller.load(ref.pageURL) }
            }
        }
    }
    static let fillVideoKey = "chatWatch.fillVideo"

    @ObservationIgnored let controller = MiniBrowserController()
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var urlWatch: AnyCancellable?

    // MARK: 观看记录（W2）——都不进观察：每秒更新，进了会每秒重画聊天页
    @ObservationIgnored private var probe: ChatWatchPerception.Probe?
    @ObservationIgnored private var captions: [ChatWatchPerception.CaptionLine] = []
    /// 上次发消息时字幕记到第几行（之后的是「上次说话到现在」）
    @ObservationIgnored private var captionsSent = 0
    /// 收下的画面（时间点 + jpeg + 指纹），最多 16 张（一张拼图）；发消息后清空（v2 V3/V4）
    @ObservationIgnored private var keyframes: [(time: Double, jpeg: Data, thumb: [UInt8])] = []
    @ObservationIgnored private var detector = ChatWatchPerception.SceneDetector()
    /// 切镜了、等画面稳住再收
    @ObservationIgnored private var pendingSwitch: Double?
    @ObservationIgnored private var lastCaptureAt: Double?
    /// 从画面读字幕（v2 V5）：网页里一直没读到字幕轨 / 字幕层才开；一次只读一张
    @ObservationIgnored private var ocr = ChatWatchPerception.OCRTracker()
    @ObservationIgnored private var ocrBusy = false
    @ObservationIgnored private var domCaptionSeen = false
    @ObservationIgnored private var ocrUsed = false

    // MARK: 陪看（v2 V7，默认关）：攒够画面就在旁边发一拍，AI 可以不说话；插话直接进这个对话
    /// 小窗里开着陪看
    var companionOn = false {
        didSet {
            guard companionOn != oldValue else { return }
            beatFrames = []
            beatCaptionCursor = captions.count
            lastBeatAt = Date()
        }
    }
    /// 这场陪看花了多少（每拍从账本那一行加）
    private(set) var companionUSD: Double = 0
    @ObservationIgnored private var beatFrames: [(time: Double, jpeg: Data)] = []
    @ObservationIgnored private var beatCaptionCursor = 0
    @ObservationIgnored private var lastBeatAt = Date()
    @ObservationIgnored private var beatIndex = 0
    @ObservationIgnored private var beatInFlight = false
    /// 最近一张画面（在播时每 6 秒、暂停那一下各截一张）
    @ObservationIgnored private var latestFrame: (time: Double, jpeg: Data)?
    @ObservationIgnored private var lastThumb: [UInt8]?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// 工具条上的播放条读这个（单独一个可观察对象：每秒变，只重画播放条，不碰聊天页）
    @ObservationIgnored let playback = ChatWatchPlayback()
    /// 在哪一页钉的「只看视频」（还在这页就不撤，她手动静音也不撤）
    @ObservationIgnored private var filledPage: URL?
    /// 换回对话 / 影院「一起看…」：这部片子接着从第几秒放（视频出来后跳一次）
    @ObservationIgnored private var resume: (key: String, time: Double)?

    /// 小窗在顶栏下面占掉的高度：消息列表的留白和渐隐跟着它让
    var occupiedHeight: CGFloat {
        guard isOpen else { return 0 }
        if collapsed { return Self.capsuleHeight + 6 }
        if url == nil { return Self.startBarHeight + 6 }
        return settledHeight + Self.toolbarHeight + 14
    }

    /// 小窗开着网页（`browser_video` 只在这时下发）
    var hasPage: Bool { isOpen && url != nil }

    var host: String {
        let h = (pageURL ?? url)?.host() ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    // MARK: 跟对话走

    func switchTo(_ id: String?) {
        guard id != conversationId else { return }
        logProgress()
        persist()
        conversationId = id
        let state = id.flatMap { ChatWatchStore.load($0) }
        collapsed = false
        height = CGFloat(state?.height ?? ChatWatchStore.defaultHeight)
        settledHeight = height
        isOpen = state?.open ?? false
        url = state?.url.flatMap(URL.init(string:))
        pageURL = url
        resetRecord()
        resume = Self.resumePoint(url: url, position: state?.position)
        if isOpen, let url { show(url) } else { blank() }
    }

    /// 影院「一起看…」：在当前对话的小窗里开这部片，从 position 接着放
    func play(_ target: URL, from position: Double?) {
        resume = Self.resumePoint(url: target, position: position)
        load(target)
    }

    private static func resumePoint(url: URL?, position: Double?) -> (key: String, time: Double)? {
        guard let url, let position, position > 5, let item = WatchLog.item(for: url, pageWithVideo: true) else { return nil }
        return (item.key, position)
    }

    func open() {
        guard conversationId != nil else { return }
        isOpen = true
        collapsed = false
        persist()
    }

    func load(_ target: URL) {
        url = target
        isOpen = true
        collapsed = false
        show(target)
        persist()
    }

    func close() {
        logProgress()
        isOpen = false
        url = nil
        pageURL = nil
        collapsed = false
        blank()
        persist()
    }

    func setHeight(_ h: CGFloat) {
        height = min(max(h, Self.minHeight), Self.maxHeight)
    }

    /// 拖完：列表让位跟上，记下来
    func settleHeight() {
        settledHeight = height
        persist()
    }

    func persist() {
        guard let conversationId else { return }
        let current = (pageURL ?? controller.url ?? url)?.absoluteString
        let position = probe.flatMap { $0.hasVideo && $0.time > 0 ? $0.time : nil }
        ChatWatchStore.save(isOpen ? ChatWatchState(open: true, url: current, height: Double(height), position: position, updatedAt: Date()) : nil,
                            for: conversationId)
    }

    /// 往影院片库记一笔进度（plan-cinema-app §2：在看时每 10 秒、暂停、切走、关窗）
    private func logProgress() {
        guard let now = probe, now.hasVideo, now.time > 0, let page = pageURL ?? url else { return }
        // B 站嵌入页的网页标题是站名，标题留给片库去 B 站接口补
        let embedded = controller.url.map(ChatWatchPerception.isEmbed) ?? false
        let title = embedded && ChatWatchPerception.videoRef(page)?.site == .bilibili ? "" : (now.title.isEmpty ? controller.title : now.title)
        guard let item = WatchLog.item(for: page, title: title, pageWithVideo: now.duration >= 60) else { return }
        WatchLog.shared.record(item, position: now.time, duration: now.duration, conversationId: conversationId, frame: latestFrame?.jpeg)
    }

    // MARK: 网页

    /// 「只看视频」开着、要开的是视频页：改开站方嵌入播放器（B 站手机网页满屏「打开 App」、画质低，粟粟 11-12）
    private func destination(_ target: URL) -> URL {
        guard fillVideo, !ChatWatchPerception.isEmbed(target), let ref = ChatWatchPerception.videoRef(target) else { return target }
        return ref.embedURL(start: resume?.key == ref.key ? resume?.time : nil)
    }

    private func show(_ target: URL) {
        // 挂到 AI 操作的栈上：小窗开着时 browser_* 落在小窗（W3）；不盖聊天，权限卡照旧出在聊天里
        BrowserOperator.shared.attach(controller, identity: BrowserIdentityStore.current(), covers: false)
        let target = destination(target)
        if let webView {
            if webView.url != target { controller.load(target) }
            return
        }
        webView = BrowserWebView(initialURL: target, controller: controller, identity: BrowserIdentityStore.current()).makeWebView()
        hideInputAccessory()
        startTicker()
        // 网页里点到别的页：网址跟着记（换对话回来接着这一页）
        // 在网页里点进一个视频（搜索结果、AI click、b23.tv 短链跳过来）：只看视频开着就换成嵌入页；记的网址一律是原视频页
        urlWatch = controller.$url.dropFirst().sink { [weak self] next in
            Task { @MainActor in
                guard let self else { return }
                if let next, let ref = ChatWatchPerception.videoRef(next) {
                    if self.fillVideo, !ChatWatchPerception.isEmbed(next) { self.controller.load(ref.embedURL()) }
                    self.pageURL = ref.pageURL
                } else {
                    self.pageURL = next
                }
                self.hideInputAccessory()
                self.persist()
            }
        }
    }

    /// 网页输入框弹键盘时不要 ⌃⌄✓ 那条（同花园浏览器；内容视图换页可能重建，换页再来一次）
    private func hideInputAccessory() {
        guard let webView else { return }
        webView.disableKeyboardInputAccessory()
        if let content = webView.scrollView.subviews.first(where: { String(describing: type(of: $0)).contains("WKContent") }) {
            content.inputAssistantItem.leadingBarButtonGroups = []
            content.inputAssistantItem.trailingBarButtonGroups = []
        }
    }

    /// 小窗网页里的输入框正拿着键盘（聊天输入条这时候别跟着键盘跳上来，粟粟 11-11）。
    /// 按 contains 认：去 ⌃⌄✓ 那步把内容视图的类换成了 `_MP_NoInputAccessory_WKContentView`
    var webViewHasFocus: Bool {
        webView?.scrollView.subviews.contains { String(describing: type(of: $0)).contains("WKContent") && $0.isFirstResponder } ?? false
    }

    private func blank() {
        BrowserOperator.shared.detach(controller)
        controller.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        resetRecord()
    }

    // MARK: 观看记录（plan §1.2：进度每秒、字幕跟着记、画面每 2 秒比一次，换场景留一张）

    private func resetRecord() {
        probe = nil
        playback.update(nil)
        captions = []
        captionsSent = 0
        keyframes = []
        latestFrame = nil
        lastThumb = nil
        detector = ChatWatchPerception.SceneDetector()
        pendingSwitch = nil
        lastCaptureAt = nil
        ocr = ChatWatchPerception.OCRTracker()
        domCaptionSeen = false
        ocrUsed = false
        companionOn = false
        companionUSD = 0
        beatIndex = 0
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                tick += 1
                await self.sample(tick: tick)
            }
        }
    }

    private func sample(tick: Int) async {
        guard isOpen, url != nil, let webView,
              let json = try? await webView.evaluateJavaScript(ChatWatchPerception.probeJS) as? String,
              let now = ChatWatchPerception.parseProbe(json) else { return }
        let wasPlaying = probe.map { $0.hasVideo && !$0.paused } ?? false
        probe = now
        playback.update(now)
        guard now.hasVideo else { return }
        // 接着上次放：B 站嵌入页不认起点参数、整页模式没有起点参数，视频出来后跳一次
        if let resume, now.duration > 0, let page = pageURL ?? url {
            if WatchLog.item(for: page, pageWithVideo: true)?.key == resume.key, abs(now.time - resume.time) > 5 {
                _ = await control(action: "seek", seconds: resume.time, rate: nil, byAI: false)
            }
            self.resume = nil
        }
        if now.isWatching, (wasPlaying && now.paused) || (!now.paused && tick % 10 == 0) { logProgress() }
        // 只看视频：新页 / YouTube 换了视频元素，每秒探针发现没钉上就钉
        let wantFill = fillVideo && now.isWatching
        if wantFill, !now.filled {
            _ = try? await webView.evaluateJavaScript(ChatWatchPerception.fillJS(true))
            filledPage = pageURL
        } else if !wantFill, now.filled, filledPage != pageURL {
            _ = try? await webView.evaluateJavaScript(ChatWatchPerception.fillJS(false))
        }
        ChatWatchPerception.appendCaption(now.cue, at: now.time, to: &captions)
        if !now.cue.isEmpty { domCaptionSeen = true }
        // 收起时网页只剩 1pt，截不到画面；视频太小（还没加载出来）也不截
        guard !collapsed, now.rect.width > 40, now.rect.height > 30 else { return }
        // 截图在主线程：滚动中截会掉帧（粟粟 11-11「上下拉不顺滑」）
        let scroll = webView.scrollView
        guard !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return }
        let justPaused = wasPlaying && now.paused
        if !now.paused { await compareFrame(now, in: webView) }
        if !now.paused, !domCaptionSeen, !ocrBusy { readFrameText(now, in: webView) }
        if companionOn, !now.paused, !beatInFlight,
           ChatWatchPerception.beatDue(newFrames: beatFrames.count, sinceLastBeat: Date().timeIntervalSince(lastBeatAt)) {
            sendBeat(now)
        }
        if justPaused || (!now.paused && tick % 6 == 0) {
            if let jpeg = await snapshot(now.rect, width: 512, in: webView) { latestFrame = (now.time, jpeg) }
        }
    }

    /// 每秒一张 32×18 灰度指纹（v2 V3，借 salle-obscure §7.3）：自适应阈值判切镜 → 等画面稳住（最多 3 秒）再收；
    /// 没切镜就隔 4 秒试一张；黑场 / 白闪不收；和最近收下的 4 张都差得够多才收（正反打对话不再全是两张脸）
    private func compareFrame(_ now: ChatWatchPerception.Probe, in webView: WKWebView) async {
        guard let image = await snapshotImage(now.rect, width: 32, in: webView),
              let thumb = await Task.detached(priority: .utility, operation: { Self.grayBytes(image) }).value else { return }
        let t = now.time
        let diff = lastThumb.map { ChatWatchPerception.frameDistance($0, thumb) } ?? 1
        lastThumb = thumb
        if detector.observe(diff, at: t) { pendingSwitch = t }
        var candidate = false
        if let since = pendingSwitch {
            if diff < detector.threshold * 0.5 || t - since >= 3 {
                candidate = true
                pendingSwitch = nil
            }
        } else if t - (lastCaptureAt ?? -.infinity) >= 4 {
            candidate = true
        }
        guard candidate, !ChatWatchPerception.isFlat(thumb),
              ChatWatchPerception.isNew(thumb, against: keyframes.suffix(4).map(\.thumb), threshold: detector.threshold),
              let jpeg = await snapshot(now.rect, width: 512, in: webView) else { return }
        keyframes.append((t, jpeg, thumb))
        if companionOn {
            beatFrames.append((t, jpeg))
            if beatFrames.count > 16 { beatFrames.removeFirst(beatFrames.count - 16) }
        }
        if keyframes.count > 16 { keyframes.removeFirst(keyframes.count - 16) }
        lastCaptureAt = t
        latestFrame = (t, jpeg)
    }

    /// 画面缩到 1280 宽交给系统文字识别（accurate，简中 + 英文），在后台读；读完按台词区 / 说话人 / 花字记进字幕
    private func readFrameText(_ now: ChatWatchPerception.Probe, in webView: WKWebView) {
        ocrBusy = true
        Task {
            defer { ocrBusy = false }
            guard let image = await snapshotImage(now.rect, width: 1280, in: webView), let cg = image.cgImage else { return }
            let boxes = await Task.detached(priority: .utility) { Self.recognize(cg) }.value
            let read = ocr.read(boxes, at: now.time)
            if let caption = read.caption {
                ChatWatchPerception.appendOCRCaption(caption, at: now.time, to: &captions)
                ocrUsed = true
            }
            for flower in read.flowers {
                ChatWatchPerception.appendOCRCaption("［花字］\(flower)", at: now.time, to: &captions)
                ocrUsed = true
            }
        }
    }

    nonisolated private static func recognize(_ image: CGImage) -> [ChatWatchPerception.OCRBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox
            return ChatWatchPerception.OCRBox(text: text, x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
    }

    private func snapshot(_ rect: CGRect, width: CGFloat, in webView: WKWebView) async -> Data? {
        guard let image = await snapshotImage(rect, width: width, in: webView) else { return nil }
        return await Task.detached(priority: .utility) { image.jpegData(compressionQuality: 0.6) }.value
    }

    private func snapshotImage(_ rect: CGRect, width: CGFloat, in webView: WKWebView) async -> UIImage? {
        let config = WKSnapshotConfiguration()
        // 网页视口原点在 webView 顶上内缩之下（同 BrowserOperator.moveCursor）
        config.rect = rect.offsetBy(dx: 0, dy: webView.scrollView.adjustedContentInset.top).intersection(webView.bounds)
        guard !config.rect.isEmpty else { return nil }
        config.snapshotWidth = NSNumber(value: Double(width))
        config.afterScreenUpdates = false
        return try? await webView.takeSnapshot(configuration: config)
    }

    /// 32×18 灰度像素
    nonisolated private static func grayBytes(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let w = 32, h = 18
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? bytes : nil
    }

    // MARK: AI 控制视频（W3 browser_video）

    /// 动的就是小窗里那个 <video>，她看得见；动完回现在播到哪
    /// byAI = false：她点工具条上的播放条，不亮「AI 正在操作」
    func control(action: String, seconds: Double?, rate: Double?, byAI: Bool = true) async -> (text: String, isError: Bool) {
        guard hasPage, let webView else { return ("一起看小窗没开网页", true) }
        guard let args = ChatWatchPerception.controlArgs(action: action, seconds: seconds, rate: rate) else {
            return (action == "seek" ? "seek 要带 seconds（跳到第几秒）" : action == "speed" ? "speed 要带 rate（0.25～4）" : "不认识的动作：\(action)", true)
        }
        let op = BrowserOperator.shared
        if byAI, op.controller === controller { op.begin(ChatWatchPerception.controlLabel(args)) }
        let r = try? await webView.callAsyncJavaScript(ChatWatchPerception.controlJS, arguments: args, contentWorld: .page) as? String
        switch r {
        case "ok": break
        case "novideo": return ("这页上没有视频", true)
        case "blocked": return ("网页不让自动播放，请她点一下播放", true)
        default: return ("没控制成", true)
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard let json = try? await webView.evaluateJavaScript(ChatWatchPerception.probeJS) as? String,
              let now = ChatWatchPerception.parseProbe(json), now.hasVideo else { return ("好了", false) }
        probe = now
        playback.update(now)
        let total = now.duration > 0 ? " / \(ChatWatchPerception.clock(now.duration))" : ""
        let speed = action == "speed" ? "，\((args["rate"] as? Double ?? 1).formatted()) 倍速" : ""
        return ("好了。现在播到 \(ChatWatchPerception.clock(now.time))\(total)，\(now.paused ? "暂停中" : "在播")\(speed)", false)
    }

    // MARK: 陪看节拍（v2 V7）

    /// 这一拍：画面拼一张 + 这段字幕 → 在旁边单独问这个人（人设 + 最近几轮聊天）；回 ⟂ 就不说话，说了就插进对话
    private func sendBeat(_ now: ChatWatchPerception.Probe) {
        guard let conversationId, let env = WakeEngine.shared.environment(conversationId: conversationId) else { return }
        let frames = beatFrames
        let lines = Array(captions.suffix(from: min(beatCaptionCursor, captions.count)))
        beatFrames = []
        beatCaptionCursor = captions.count
        lastBeatAt = Date()
        beatIndex += 1
        beatInFlight = true
        let index = beatIndex
        let title = now.title.isEmpty ? host : now.title

        let context = ModelContext(env.container)
        let model = env.providers.resolveModel(conversationModelId: env.conversation.selectedModelId,
                                               profileModelId: env.profile.preferredModel,
                                               globalFallbackId: UserDefaults.standard.string(forKey: "selectedChatModel"))
        let seesImages = VisionCapability.of(model, providerType: env.providers.provider(for: model)?.type) != .no
        let collage = seesImages ? ChatWatchCollage.render(frames) : nil
        let text = ChatWatchPerception.beatText(index: index, from: frames.first?.time ?? lines.first?.time ?? now.time, to: now.time,
                                                captions: lines, hasImage: collage != nil)
        let system = [WakePrompt.persona(profile: env.profile, preset: env.preset, conversation: env.conversation, context: context, tools: []),
                      ChatWatchPerception.companionRules(title: title)].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var messages = Self.recentTurns(conversationId: conversationId, context: context)
        messages.append((role: "user", content: text))
        var imageMap: [String: [PendingChatAttachment]] = [:]
        if let collage, let image = try? PendingChatAttachment.image(name: "陪看 第\(index)拍.jpg", typeDescription: "一起看画面",
                                                                     mimeType: "image/jpeg", data: collage) {
            imageMap[text] = [image]
        }
        let router = ProviderRouter(usageContext: UsageContext(kind: .watchAlong, conversationId: conversationId, profileId: env.profile.id))
        router.sendStreaming(
            model: model, messages: messages, systemPrompt: system, providerManager: env.providers, imageMap: imageMap,
            onToken: { _ in },
            onComplete: { [weak self] reply, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.beatInFlight = false
                    self.companionUSD += router.lastUsageRecord?.costUSD ?? 0
                    // 拍发出去以后她关了陪看 / 换了对话：不插话
                    guard self.companionOn, self.conversationId == conversationId, !ChatWatchPerception.isSilence(reply) else { return }
                    WakeEngine.shared.insertAssistantMessage(reply.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             conversationId: conversationId, origin: "watch:beat\(index)",
                                                             context: ModelContext(env.container))
                }
            },
            onError: { [weak self] _ in
                Task { @MainActor in self?.beatInFlight = false }
            })
    }

    /// 这个对话最近几轮（她和 TA 说的话，按时间顺序），给陪看接上上下文
    private static func recentTurns(conversationId id: String, context: ModelContext, limit: Int = 10) -> [(role: String, content: String)] {
        var desc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == id },
                                                sortBy: [SortDescriptor(\.createTime, order: .reverse)])
        desc.fetchLimit = limit * 2
        let nodes = (try? context.fetch(desc)) ?? []
        return nodes
            .filter { ($0.role == "user" || $0.role == "assistant") && $0.contentType == "text" && !$0.content.isEmpty }
            .prefix(limit)
            .reversed()
            .map { (role: $0.role, content: String($0.content.prefix(1500))) }
    }

    // MARK: 看这里（v2 V6）

    /// 截一张 3+1（往前 45 秒里的切镜帧 + 此刻一大张）放进输入框；新台词照旧随消息的「一起看」小包带
    @discardableResult
    func lookHere() async -> Bool {
        guard hasPage, let webView, let now = probe, now.hasVideo,
              let jpeg = await snapshot(now.rect, width: 960, in: webView) else { return false }
        let earlier = keyframes.filter { $0.time >= now.time - 45 && $0.time < now.time - 1 }.map { ($0.time, $0.jpeg) }
        guard let data = ChatWatchCollage.renderLookHere(earlier: earlier, now: (now.time, jpeg)),
              let attachment = try? PendingChatAttachment.image(name: "看这里 \(ChatWatchPerception.clock(now.time)).jpg",
                                                                 typeDescription: "一起看画面", mimeType: "image/jpeg", data: data),
              let attach = BrowserOperator.shared.attachToChat else { return false }
        attach(attachment)
        return true
    }

    // MARK: 发消息时跟着走的「一起看」小包（plan §1.2）

    /// 小窗开着、开了网页时才有：一段文字（标题 / 进度 / 上次说话到现在的字幕）+ 一张拼图（最多 16 格，看不了图的模型不带图）。
    /// 带完把「上次说话」挪到现在
    func attachmentsForSend(includeImages: Bool) -> [PendingChatAttachment] {
        guard isOpen, let url else { return [] }
        let pending = Array(captions.suffix(from: min(captionsSent, captions.count)))
        var frames: [(time: Double, jpeg: Data)] = []
        if includeImages {
            frames = keyframes.map { ($0.time, $0.jpeg) }
            if let latest = latestFrame, !frames.contains(where: { abs($0.time - latest.time) < 1 }) { frames.append(latest) }
            frames = Array(frames.suffix(16))
        }
        let title = probe?.title.isEmpty == false ? probe!.title : (controller.title.isEmpty ? host : controller.title)
        let note = ChatWatchPerception.note(title: title, url: (pageURL ?? url).absoluteString, probe: probe,
                                            captions: pending, imageTimes: frames.map(\.time), fromScreen: ocrUsed)
        let stamp = probe.map { $0.hasVideo ? " \(ChatWatchPerception.clock($0.time))" : "" } ?? ""
        var out = [PendingChatAttachment.text(name: "一起看\(stamp)", typeDescription: "一起看", extractedText: note, byteCount: note.utf8.count)]
        if let first = frames.first, let last = frames.last, let collage = ChatWatchCollage.render(frames),
           let image = try? PendingChatAttachment.image(
               name: "画面 \(ChatWatchPerception.clock(first.time))–\(ChatWatchPerception.clock(last.time)).jpg",
               typeDescription: "一起看画面", mimeType: "image/jpeg", data: collage) {
            out.append(image)
        }
        captionsSent = captions.count
        keyframes = []
        return out
    }
}

/// 顶栏下面那一块：起始输入框 / 网页 + 细工具条 + 拖把手 / 收起的胶囊
struct ChatWatchPanel: View {
    /// 收起 / 放大 / 只看视频 / ✕ 挪到聊天顶栏中间了（粟粟 11-11 圈图）：工具条只剩播放条，玻璃卡由顶栏那边连着画。
    /// 气泡模式 / 宽屏 / 搜索 / 多选时顶栏没地方，照旧放工具条上
    var controlsInTopBar = false
    @State private var watch = ChatWatch.shared
    @State private var op = BrowserOperator.shared
    @State private var query = ""
    @State private var dragStart: CGFloat?
    @FocusState private var queryFocused: Bool

    var body: some View {
        if watch.isOpen {
            VStack(spacing: 0) {
                if watch.url == nil {
                    startBar
                } else {
                    if watch.collapsed { capsule }
                    // 网页 + 工具条一张玻璃卡（工具条要有底，不然压在消息上看不清）；
                    // 收起时网页还挂着（1pt、透明），视频声音不停
                    VStack(spacing: 0) {
                        ChatWatchWebHost()
                            .overlay { ChatWatchPauseOverlay(watch: watch, playback: watch.playback) }
                            .overlay { AIOperatorOverlay(controller: watch.controller, compact: true) }
                            .frame(height: watch.collapsed ? 1 : watch.height)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
                        if !watch.collapsed { toolbar }
                    }
                    .padding(watch.collapsed ? 0 : 4)
                    .glassEffect(controlsInTopBar ? .identity : .regular, in: .rect(cornerRadius: 22))
                    .opacity(watch.collapsed ? 0.01 : 1)
                    .allowsHitTesting(!watch.collapsed)
                    // 写动作确认卡出在小窗下面（盖在消息上）
                    if let confirm = op.confirm, op.controller === watch.controller {
                        AIConfirmCard(confirm: confirm)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 12)
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: op.confirm?.id)
            // AI 动小窗时收着就展开，让她看得见
            .onChange(of: op.isOperating(watch.controller)) { _, operating in
                if operating, watch.collapsed {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { watch.collapsed = false }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var startBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textMuted)
            TextField("一起看：搜索或输入网址", text: $query)
                .font(.system(size: 16))
                .textFieldStyle(.plain)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($queryFocused)
                .onSubmit {
                    guard let target = AddressInput.url(for: query) else { return }
                    query = ""
                    watch.load(target)
                }
            closeButton
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: ChatWatch.startBarHeight - 6)
        .glassEffect(.regular, in: .capsule)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            queryFocused = true
        }
    }

    private var capsule: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.branchIndicator)
            Text("正在一起看 · \(watch.host.isEmpty ? "网页" : watch.host)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            closeButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: ChatWatch.capsuleHeight)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { watch.collapsed = false } }
        .accessibilityLabel("正在一起看 \(watch.host)，点开")
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            ChatWatchPlaybackBar(watch: watch, playback: watch.playback)
            if !controlsInTopBar {
                ChatWatchControls(watch: watch)
            }
        }
        .frame(height: ChatWatch.toolbarHeight)
        .overlay(alignment: .top) { dragHandle }
    }

    /// 底边拖把手：上下拖改小窗高度
    private var dragHandle: some View {
        Capsule()
            .fill(Theme.textMuted.opacity(0.45))
            .frame(width: 40, height: 5)
            .padding(.vertical, 6)
            .padding(.horizontal, 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragStart == nil { dragStart = watch.height }
                    watch.setHeight((dragStart ?? watch.height) + value.translation.height)
                }
                .onEnded { _ in
                    dragStart = nil
                    watch.settleHeight()
                })
            .accessibilityLabel("拖动改小窗高度")
    }

    private var closeButton: some View {
        toolIcon("xmark", label: "关掉一起看") {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { watch.close() }
        }
    }

    private func toolIcon(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 把小窗那一张常驻网页挂进来（换对话 / 收起都不重建，视频不断）
private struct ChatWatchWebHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) { attach(to: container) }

    private func attach(to container: UIView) {
        guard let webView = ChatWatch.shared.webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
#endif

#if os(iOS)
/// 播放条的状态：探针每秒填一次，值没变不写（写了就会重画）
@MainActor
@Observable
final class ChatWatchPlayback {
    private(set) var hasVideo = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = true
    /// 「只看视频」正钉着（暂停时的大圆按钮只在这时出，整页模式下不挡网页）
    private(set) var filled = false

    func update(_ probe: ChatWatchPerception.Probe?) {
        let has = probe?.hasVideo ?? false
        if hasVideo != has { hasVideo = has }
        guard let probe, has else { return }
        let t = probe.time.rounded(.down)
        if time != t { time = t }
        if duration != probe.duration { duration = probe.duration }
        if paused != probe.paused { paused = probe.paused }
        if filled != probe.filled { filled = probe.filled }
    }

    /// 点了暂停 / 拖了进度先改界面，不等下一秒探针
    func assume(paused: Bool? = nil, time: Double? = nil) {
        if let paused { self.paused = paused }
        if let time { self.time = time }
    }
}

/// 工具条左边：有视频 = 播放 / 暂停 + 进度条 + 时间（不挡画面，哪个网站都一样）；没有 = 域名
private struct ChatWatchPlaybackBar: View {
    let watch: ChatWatch
    let playback: ChatWatchPlayback
    @State private var scrub: Double?
    /// 「看这里」放进去了：图标闪一下对勾
    @State private var flashed = false
    /// 新对话里点陪看：闪一行「先聊一句再开陪看」
    @State private var companionHint = false

    var body: some View {
        if playback.hasVideo {
            HStack(spacing: 4) {
                Button {
                    let pausing = !playback.paused
                    playback.assume(paused: pausing)
                    Task { _ = await watch.control(action: pausing ? "pause" : "play", seconds: nil, rate: nil, byAI: false) }
                } label: {
                    Image(systemName: playback.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 34, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.paused ? "播放" : "暂停")
                if playback.duration > 0 {
                    ChatWatchScrubber(value: scrub ?? playback.time, total: playback.duration) { scrub = $0 } onCommit: { target in
                        playback.assume(time: target)
                        scrub = nil
                        Task { _ = await watch.control(action: "seek", seconds: target, rate: nil, byAI: false) }
                    }
                    Text("\(ChatWatchPerception.clock(scrub ?? playback.time)) / \(ChatWatchPerception.clock(playback.duration))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Spacer(minLength: 4)
                }
                // 陪看（v2 V7，默认关）：开了 TA 隔一阵自己看一眼，有感而发才插话；花费跟着显示
                Button {
                    // 还没聊过的新对话（草稿，库里还没有）：插不了话，先提示聊一句（11-12 实测：悄悄不发拍）
                    if !watch.companionOn, let id = watch.conversationId, WakeEngine.shared.environment(conversationId: id) == nil {
                        companionHint = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            companionHint = false
                        }
                        return
                    }
                    watch.companionOn.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: watch.companionOn ? "person.2.fill" : "person.2")
                            .font(.system(size: 13, weight: .medium))
                        if companionHint {
                            Text("先聊一句再开陪看")
                                .font(.system(size: 10))
                                .fixedSize()
                        } else if watch.companionOn, watch.companionUSD > 0 {
                            Text(watch.companionUSD < 0.01 ? "<1¢" : String(format: "$%.2f", watch.companionUSD))
                                .font(.system(size: 10).monospacedDigit())
                        }
                    }
                    .foregroundStyle(watch.companionOn ? Theme.branchIndicator : Theme.textSecondary)
                    .frame(minWidth: 30, minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(watch.companionOn ? "陪看开着，点了关掉" : "陪看：TA 隔一阵自己看一眼，有感而发才插话（大概每分钟一张图，费 token）")
                // 看这里（v2 V6）：此刻 + 往前几十秒的画面拼一张放进输入框
                Button {
                    Task {
                        if await watch.lookHere() { flashed = true }
                        try? await Task.sleep(for: .seconds(1.2))
                        flashed = false
                    }
                } label: {
                    Image(systemName: flashed ? "checkmark" : "viewfinder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(flashed ? Theme.branchIndicator : Theme.textSecondary)
                        .frame(width: 34, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("看这里：把这一刻的画面放进输入框")
            }
            .padding(.trailing, 4)
        } else {
            Text(watch.host.isEmpty ? "网页" : watch.host)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer(minLength: 4)
        }
    }
}

/// 细进度条：3pt 轨道 + 10pt 圆点（iOS 26 系统滑块的白胶囊太粗，粟粟 11-11）；整条 28pt 高都能拖
private struct ChatWatchScrubber: View {
    let value: Double
    let total: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = total > 0 ? min(max(value / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textMuted.opacity(0.3)).frame(height: 3)
                Capsule().fill(Theme.branchIndicator).frame(width: width * fraction, height: 3)
                Circle().fill(Theme.branchIndicator).frame(width: 10, height: 10).offset(x: width * fraction - 5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onScrub(seconds(at: $0.location.x, width: width)) }
                .onEnded { onCommit(seconds(at: $0.location.x, width: width)) })
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue(ChatWatchPerception.clock(value))
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(x / width, 0), 1)) * total
    }
}

/// 只看视频时暂停：画面压暗，中间三个大圆——退 15 秒 / 播放 / 进 15 秒（粟粟 11-11）
private struct ChatWatchPauseOverlay: View {
    let watch: ChatWatch
    let playback: ChatWatchPlayback

    var body: some View {
        if playback.hasVideo, playback.filled, playback.paused {
            ZStack {
                Color.black.opacity(0.4)
                HStack(spacing: 28) {
                    circle("gobackward.15", size: 46, label: "后退 15 秒") { jump("back") }
                    circle("play.fill", size: 64, label: "播放") {
                        playback.assume(paused: false)
                        Task { _ = await watch.control(action: "play", seconds: nil, rate: nil, byAI: false) }
                    }
                    circle("goforward.15", size: 46, label: "前进 15 秒") { jump("forward") }
                }
            }
            .transition(.opacity)
        }
    }

    private func jump(_ action: String) {
        playback.assume(time: max(0, playback.time + (action == "back" ? -15 : 15)))
        Task { _ = await watch.control(action: action, seconds: 15, rate: nil, byAI: false) }
    }

    private func circle(_ icon: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

/// ✕ / 收起 / 放大 / 只看视频↔看整页：在聊天顶栏中间（一个玻璃胶囊）或小窗工具条上
struct ChatWatchControls: View {
    let watch: ChatWatch

    var body: some View {
        HStack(spacing: 0) {
            icon("xmark", label: "关掉一起看") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { watch.close() }
            }
            icon("chevron.up", label: "收起") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { watch.collapsed = true }
            }
            icon("arrow.up.left.and.arrow.down.right", label: "放大") {
                // 放大开原视频页（不是嵌入播放器）
                if let current = watch.pageURL ?? watch.controller.url ?? watch.url { GardenBrowser.present(current) }
            }
            icon(watch.fillVideo ? "doc.text" : "play.rectangle", label: watch.fillVideo ? "看整页" : "只看视频") {
                watch.fillVideo.toggle()
            }
        }
    }

    private func icon(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
#endif
