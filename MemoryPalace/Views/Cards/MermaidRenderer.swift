import CryptoKit
import SwiftUI
import WebKit

/// Mermaid 渲染器（plan-mermaid §2）。与网页卡截图器不同：**常驻一个**离屏 WKWebView（5.5MB 脚本只解析一次），
/// 串行排队；每张图 mpRender 取 SVG → 按自然尺寸摆好截 PNG；PNG + SVG + 尺寸按「代码 + 主题」哈希缓存。
/// 每张 8 秒上限；WebContent 崩溃 → 丢掉 WebView、当前 job 失败、下次重建；内存警告 → 空闲时释放。
/// 只在 job 进行中挂进窗口，队列空了就摘下（WebView 本身留着，下次直接用）。
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()
    static let maxCodeBytes = 50_000
    static let deadline: TimeInterval = 8
    static let maxWidth: CGFloat = 1600
    static let maxHeight: CGFloat = 4000
    /// 甘特图等按父容器宽排版的图用这个宽
    static let layoutWidth: CGFloat = 720
    /// 渲染口径变了（mermaid 版本 / 宿主页 / 截图方式）就改它，旧缓存自动作废
    private static let revision = "mermaid-12.0.0-r2"
    private static let idleSize = CGSize(width: 320, height: 240)

    struct Rendered: Equatable {
        let png: URL
        let svg: URL
        /// SVG 自然尺寸（pt）
        let width: Double
        let height: Double
        /// SVG 根元素 aria-roledescription（flowchart-v2 / sequence / …）
        let type: String
    }

    enum Outcome: Equatable {
        case rendered(Rendered)
        /// mermaid 报的语法错误（带它的错误信息）
        case invalid(String)
        /// 我们这侧的失败：图表太大 / 超时 / 进程崩溃 / 截图失败…
        case failed(String)
    }

    /// 一次渲染请求：缓存键 + 送进页面的参数（主题在创建时定格）
    struct Request {
        let key: String
        let code: String
        let options: [String: Any]
        let background: String
    }

    private struct Meta: Codable {
        let width: Double
        let height: Double
        let type: String
    }

    private struct Job {
        let request: Request
        let prewarm: Bool
        var completions: [(Outcome) -> Void]
    }

    private var queue: [Job] = []
    private var current: Job?
    private var webView: WKWebView?
    private var pageReady = false
    private var loadedInitial = false
    private var loadStarted: CFAbsoluteTime = 0
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var token = 0
    private var currentBegin: CFAbsoluteTime = 0
    /// 语法错误只记在内存里（重启重试），超时 / 崩溃不记
    private var syntaxErrors: [String: String] = [:]
    /// 磁盘缓存命中过的结果（卡片 body 每次求值都查，别每次都碰磁盘）
    private var memo: [String: Rendered] = [:]

    override private init() {
        super.init()
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseIfIdle(reason: "内存警告") }
        }
        #endif
    }

    // MARK: - 缓存

    static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace/mermaid-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheKey(code: String, themeSignature: String) -> String {
        let data = Data((revision + "\n" + themeSignature + "\n" + code).utf8)
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func cached(key: String) -> Rendered? {
        let png = cacheDir.appendingPathComponent("\(key).png")
        let svg = cacheDir.appendingPathComponent("\(key).svg")
        let json = cacheDir.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: png.path), FileManager.default.fileExists(atPath: svg.path),
              let data = try? Data(contentsOf: json), let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        return Rendered(png: png, svg: svg, width: meta.width, height: meta.height, type: meta.type)
    }

    // MARK: - 请求

    /// 按当前主题建请求（读 ThemeManager：在视图 body 里调用会随换主题重算）
    static func request(code: String) -> Request {
        let tokens = ThemeManager.shared.currentTokenSet
        let dark = ThemeManager.shared.activeScheme == .dark
        var variables: [String: Any] = themeVariables(tokens: tokens)
        variables["darkMode"] = dark
        variables["fontFamily"] = fontFamily
        let options: [String: Any] = [
            "themeVariables": variables,
            "fontFamily": fontFamily,
            "background": tokens.mainBg.hexString,
            "maxWidth": Double(maxWidth),
            "maxHeight": Double(maxHeight),
            "layoutWidth": Double(layoutWidth),
        ]
        let signatureData = (try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])) ?? Data()
        let signature = String(decoding: signatureData, as: UTF8.self)
        return Request(key: cacheKey(code: code, themeSignature: signature), code: code, options: options,
                       background: tokens.mainBg.hexString)
    }

    /// 不排队就能给的结果：磁盘缓存 / 已知语法错误 / 源码超限
    func immediateOutcome(for request: Request) -> Outcome? {
        if request.code.utf8.count > Self.maxCodeBytes { return .failed("图表太大") }
        if let hit = memo[request.key] { return .rendered(hit) }
        if let hit = Self.cached(key: request.key) {
            memo[request.key] = hit
            KBProbe.log("[MERMAID] 缓存命中 key=\(request.key)")
            return .rendered(hit)
        }
        if let message = syntaxErrors[request.key] { return .invalid(message) }
        return nil
    }

    /// 缓存文件被系统清掉了：忘掉内存里的结果，下次重画
    func forget(key: String) {
        memo[key] = nil
    }

    func render(_ request: Request, completion: @escaping (Outcome) -> Void) {
        if let outcome = immediateOutcome(for: request) { completion(outcome); return }
        if current?.request.key == request.key, current?.prewarm == false {
            current?.completions.append(completion); return
        }
        if let i = queue.firstIndex(where: { $0.request.key == request.key && !$0.prewarm }) {
            queue[i].completions.append(completion); return
        }
        queue.append(Job(request: request, prewarm: false, completions: [completion]))
        startNext()
    }

    /// 冷启动就绪后调用：建 WebView + 载页面 + 空跑一张小图（不截图、不写缓存）
    func prewarm() {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("MermaidRenderer.prewarm") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        guard webView == nil || !pageReady, current == nil, queue.isEmpty else { return }
        let begin = CFAbsoluteTimeGetCurrent()
        let request = Self.request(code: "flowchart LR\n  a --> b")
        queue.append(Job(request: request, prewarm: true, completions: [{ outcome in
            let ms = Int((CFAbsoluteTimeGetCurrent() - begin) * 1000)
            switch outcome {
            case .rendered: KBProbe.log("[MERMAID] 预热完成 \(ms)ms")
            case .invalid(let reason), .failed(let reason): KBProbe.log("[MERMAID] 预热失败 \(ms)ms reason=\(reason)")
            }
        }]))
        startNext()
    }

    // MARK: - 队列

    private func startNext() {
        guard current == nil else { return }
        guard !queue.isEmpty else {
            webView?.removeFromSuperview()   // 空闲：摘下窗口，WebView 留着
            return
        }
        let job = queue.removeFirst()
        current = job
        token += 1
        let myToken = token
        currentBegin = CFAbsoluteTimeGetCurrent()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadline) { [weak self] in
            guard let self, self.token == myToken else { return }
            self.discardWebView()   // 卡住的页面不复用
            self.finish(.failed("渲染超时"), token: myToken)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.run(job, token: myToken)
            self.finish(outcome, token: myToken)
        }
    }

    private func finish(_ outcome: Outcome, token myToken: Int) {
        guard token == myToken, let job = current else { return }
        token += 1                                   // 作废本 job 的所有迟到回调
        current = nil
        let ms = Int((CFAbsoluteTimeGetCurrent() - currentBegin) * 1000)
        if !job.prewarm {
            switch outcome {
            case .rendered(let r):
                KBProbe.log("[MERMAID] 渲染 \(ms)ms key=\(job.request.key) type=\(r.type) size=\(Int(r.width))x\(Int(r.height))")
            case .invalid(let reason):
                KBProbe.log("[MERMAID] 语法错误 \(ms)ms key=\(job.request.key) reason=\(reason.prefix(120))")
            case .failed(let reason):
                KBProbe.log("[MERMAID] 失败 \(ms)ms key=\(job.request.key) reason=\(reason.prefix(120))")
            }
        }
        job.completions.forEach { $0(outcome) }
        startNext()
    }

    private func run(_ job: Job, token myToken: Int) async -> Outcome {
        guard let webView = await readyWebView(), token == myToken else { return .failed("渲染器没准备好") }
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript("return await window.mpRender(code, opts)",
                                                        arguments: ["code": job.request.code, "opts": job.request.options],
                                                        in: nil, contentWorld: .page)
        } catch {
            return .failed("渲染脚本出错")
        }
        guard token == myToken else { return .failed("已作废") }
        guard let dict = raw as? [String: Any] else { return .failed("渲染结果为空") }
        if let message = dict["error"] as? String {
            if dict["fatal"] as? Bool == true {
                discardWebView()
                return .failed(message)
            }
            if !job.prewarm { syntaxErrors[job.request.key] = message }
            return .invalid(message)
        }
        guard let svg = dict["svg"] as? String,
              let width = (dict["width"] as? NSNumber)?.doubleValue,
              let height = (dict["height"] as? NSNumber)?.doubleValue,
              let displayWidth = (dict["displayWidth"] as? NSNumber)?.doubleValue,
              let displayHeight = (dict["displayHeight"] as? NSNumber)?.doubleValue else { return .failed("渲染结果不完整") }
        let type = dict["type"] as? String ?? ""
        if job.prewarm {
            // 预热不截图不落盘：回给日志闭包的 Rendered 只带尺寸 / 类型，URL 无意义
            _ = try? await webView.callAsyncJavaScript("return window.mpClear()", arguments: [:], in: nil, contentWorld: .page)
            return .rendered(Rendered(png: Self.cacheDir, svg: Self.cacheDir, width: width, height: height, type: type))
        }

        // 按图的显示尺寸摆 WebView，等排版后截图
        let rect = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        webView.frame = rect
        _ = try? await webView.callAsyncJavaScript("return await window.mpSettle()", arguments: [:], in: nil, contentWorld: .page)
        guard token == myToken else { return .failed("已作废") }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.snapshotWidth = NSNumber(value: displayWidth * 2 / Self.screenScale(of: webView))   // 输出约 2× 像素
        let image: PlatformSnapshotImage
        do {
            image = try await webView.takeSnapshot(configuration: config)
        } catch {
            return .failed("截图失败")
        }
        _ = try? await webView.callAsyncJavaScript("return window.mpClear()", arguments: [:], in: nil, contentWorld: .page)
        webView.frame = CGRect(origin: .zero, size: Self.idleSize)
        guard token == myToken else { return .failed("已作废") }
        guard let png = Self.pngData(image) else { return .failed("截图失败") }

        let key = job.request.key
        let pngURL = Self.cacheDir.appendingPathComponent("\(key).png")
        let svgURL = Self.cacheDir.appendingPathComponent("\(key).svg")
        let jsonURL = Self.cacheDir.appendingPathComponent("\(key).json")
        do {
            try png.write(to: pngURL, options: .atomic)
            try Data(svg.utf8).write(to: svgURL, options: .atomic)
            try JSONEncoder().encode(Meta(width: width, height: height, type: type)).write(to: jsonURL, options: .atomic)
        } catch {
            return .failed("缓存写入失败")
        }
        let rendered = Rendered(png: pngURL, svg: svgURL, width: width, height: height, type: type)
        memo[key] = rendered
        return .rendered(rendered)
    }

    // MARK: - WebView 生命周期

    private func readyWebView() async -> WKWebView? {
        if webView == nil { createWebView() }
        guard let webView else { return nil }
        if webView.superview == nil { Self.attachOffscreen(webView) }
        if pageReady { return webView }
        let ok = await withCheckedContinuation { loadWaiters.append($0) }
        return ok ? self.webView : nil
    }

    private func createWebView() {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("MermaidRenderer.createWebView") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        guard let url = Self.pageURL else {
            KBProbe.log("[MERMAID] 找不到 mermaid.html")
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(origin: .zero, size: Self.idleSize), configuration: configuration)
        #if os(iOS)
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        webView.navigationDelegate = self
        self.webView = webView
        pageReady = false
        loadedInitial = false
        loadStarted = CFAbsoluteTimeGetCurrent()
        Self.attachOffscreen(webView)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func discardWebView() {
        guard let webView else { return }
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)    // 掐掉仍在跑的脚本，挂着的 JS 调用随之报错返回
        webView.removeFromSuperview()
        self.webView = nil
        pageReady = false
        resumeLoadWaiters(false)
    }

    private func releaseIfIdle(reason: String) {
        guard current == nil, queue.isEmpty, webView != nil else { return }
        discardWebView()
        KBProbe.log("[MERMAID] 释放 WebView reason=\(reason)")
    }

    private func resumeLoadWaiters(_ ok: Bool) {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume(returning: ok) }
    }

    static var pageURL: URL? {
        Bundle.main.url(forResource: "mermaid", withExtension: "html", subdirectory: "Web")
            ?? Bundle.main.url(forResource: "mermaid", withExtension: "html")
    }

    /// 只放行初次载入；页面发起的任何跳转 / 新窗口一律拦
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !loadedInitial, navigationAction.targetFrame?.isMainFrame == true {
            loadedInitial = true
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        pageReady = true
        KBProbe.log("[MERMAID] 页面载入 \(Int((CFAbsoluteTimeGetCurrent() - loadStarted) * 1000))ms")
        resumeLoadWaiters(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !pageReady else { return }
        KBProbe.log("[MERMAID] 页面载入失败 \(error.localizedDescription)")
        discardWebView()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !pageReady else { return }
        KBProbe.log("[MERMAID] 页面载入失败 \(error.localizedDescription)")
        discardWebView()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        KBProbe.log("[MERMAID] WebContent 进程退出，丢弃重建")
        discardWebView()
        if current != nil { finish(.failed("渲染进程崩溃"), token: token) }
    }

    // MARK: - 平台

    /// 照 ChatHTMLSnapshotter.attachOffscreen：iOS 挂 key window 最底层，mac 挂第一个窗口 contentView 最底层
    private static func attachOffscreen(_ webView: WKWebView) {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.first?.windows.first else { return }
        window.insertSubview(webView, at: 0)
        #else
        NSApp.windows.first?.contentView?.addSubview(webView, positioned: .below, relativeTo: nil)
        #endif
    }

    #if os(iOS)
    private typealias PlatformSnapshotImage = UIImage
    private static func screenScale(of webView: WKWebView) -> CGFloat {
        max(webView.window?.screen.scale ?? webView.traitCollection.displayScale, 1)
    }
    private static func pngData(_ image: UIImage) -> Data? { image.pngData() }
    #else
    private typealias PlatformSnapshotImage = NSImage
    private static func screenScale(of webView: WKWebView) -> CGFloat {
        max(webView.window?.backingScaleFactor ?? 2, 1)
    }
    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    #endif
}

// MARK: - 冷启动预热（plan-mermaid M8）

extension MermaidRenderer {
    private static var prewarmScheduled = false

    /// 冷启动就绪后后台预热一次（进程内只排一次；切楼层重跑根 task 不重复）。
    /// iOS 就绪 = 开屏罩走完（LaunchSplash.isFinished，最多等 15 秒）再等 2 秒；mac 没有开屏罩，根视图出现后 3 秒。
    /// perf 测量各角色不预热，免得污染冷启动口径。
    static func schedulePrewarm() {
        guard !prewarmScheduled else { return }
        prewarmScheduled = true
        #if (PERF_BENCH || DEBUG) && os(iOS)
        if PerfHarness.anyRole {
            KBProbe.log("[MERMAID] perf 角色，不预热")
            return
        }
        #endif
        Task { @MainActor in
            #if os(iOS)
            var waited: TimeInterval = 0
            while !LaunchSplash.isFinished && waited < 15 {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 0.25
            }
            try? await Task.sleep(for: .seconds(2))
            #else
            try? await Task.sleep(for: .seconds(3))
            #endif
            // 排到主队列末尾，让已排着的界面工作先走
            DispatchQueue.main.async { shared.prewarm() }
        }
    }
}

// MARK: - 配色（plan-mermaid §2 配色）

extension MermaidRenderer {
    /// WebContent 进程看不到 app 进程里注册的字体（霞鹜文楷等），只能用系统字体族
    static let fontFamily = "-apple-system, BlinkMacSystemFont, \"PingFang SC\", \"Helvetica Neue\", sans-serif"

    /// theme:'base' 的变量全由主题 token 生成：背景 mainBg、节点填充 accent、边 / 连线 branchIndicator、
    /// 文字 textPrimary、次要文字 textMuted。mermaid 默认会按色相旋转派生出蓝 / 黄，所以派生色一律显式给。
    static func themeVariables(tokens: ThemeTokenSet) -> [String: Any] {
        let bg = tokens.mainBg, fill = tokens.accent, line = tokens.branchIndicator
        let text = tokens.textPrimary, muted = tokens.textMuted, soft = tokens.sidebarBg
        let danger = tokens.danger
        // 分类色板（思维导图 cScale / 饼图 pie / git / 旅程图）：只用薄荷、奶白、中性灰三系，深浅交替。
        // 中性灰 = textMuted 去色（原色偏暖，混出来发棕）。粉色 / 棕色都不进色板
        let grayLevel = (muted.red + muted.green + muted.blue) / 3
        let gray = ThemeColorValue(red: grayLevel, green: grayLevel, blue: grayLevel)
        let swatches: [ThemeColorValue] = [
            line,
            mixValue(line, bg, 0.4),
            mixValue(gray, bg, 0.35),
            mixValue(line, text, 0.3),
            fill,
            mixValue(gray, line, 0.4),
            mixValue(line, bg, 0.65),
            mixValue(gray, bg, 0.15),
            mixValue(gray, bg, 0.6),
            mixValue(gray, line, 0.7),
            mixValue(line, bg, 0.25),
            mixValue(line, bg, 0.82),
        ]
        let palette = swatches.map(\.hexString)
        var v: [String: Any] = [
            "fontSize": "14px",
            "background": bg.hexString,
            "mainBkg": fill.hexString,
            "primaryColor": fill.hexString,
            "primaryBorderColor": line.hexString,
            "primaryTextColor": text.hexString,
            "secondaryColor": soft.hexString,
            "secondaryBorderColor": line.hexString,
            "secondaryTextColor": text.hexString,
            "tertiaryColor": bg.hexString,
            "tertiaryBorderColor": line.hexString,
            "tertiaryTextColor": text.hexString,
            "nodeBorder": line.hexString,
            "nodeTextColor": text.hexString,
            "lineColor": line.hexString,
            "textColor": text.hexString,
            "titleColor": text.hexString,
            "clusterBkg": soft.hexString,
            "clusterBorder": line.hexString,
            "edgeLabelBackground": bg.hexString,
            "labelBackground": bg.hexString,
            "labelBackgroundColor": bg.hexString,
            "altBackground": soft.hexString,
            "noteBkgColor": soft.hexString,
            "noteBorderColor": line.hexString,
            "noteTextColor": text.hexString,
            "errorBkgColor": mix(danger, bg, 0.7),
            "errorTextColor": text.hexString,
            // 时序图
            "actorBkg": fill.hexString,
            "actorBorder": line.hexString,
            "actorTextColor": text.hexString,
            "actorLineColor": muted.hexString,
            "signalColor": text.hexString,
            "signalTextColor": text.hexString,
            "labelBoxBkgColor": fill.hexString,
            "labelBoxBorderColor": line.hexString,
            "labelTextColor": text.hexString,
            "loopTextColor": text.hexString,
            "activationBkgColor": soft.hexString,
            "activationBorderColor": line.hexString,
            "sequenceNumberColor": bg.hexString,
            // 状态图 / 类图
            "stateBkg": fill.hexString,
            "stateLabelColor": text.hexString,
            "compositeBackground": soft.hexString,
            "compositeTitleBackground": fill.hexString,
            "compositeBorder": line.hexString,
            "innerEndBackground": line.hexString,
            "specialStateColor": line.hexString,
            "classText": text.hexString,
            // 甘特图
            "sectionBkgColor": fill.hexString,
            "altSectionBkgColor": bg.hexString,
            "sectionBkgColor2": soft.hexString,
            "taskBkgColor": fill.hexString,
            "taskBorderColor": line.hexString,
            "taskTextColor": text.hexString,
            "taskTextLightColor": text.hexString,
            "taskTextDarkColor": text.hexString,
            "taskTextOutsideColor": text.hexString,
            "taskTextClickableColor": text.hexString,
            "activeTaskBkgColor": mix(line, bg, 0.45),
            "activeTaskBorderColor": line.hexString,
            "doneTaskBkgColor": mix(muted, bg, 0.5),
            "doneTaskBorderColor": muted.hexString,
            "critBkgColor": mix(danger, bg, 0.45),
            "critBorderColor": danger.hexString,
            "todayLineColor": danger.hexString,
            "gridColor": muted.hexString,
            "excludeBkgColor": soft.hexString,
            // 饼图
            "pieTitleTextColor": text.hexString,
            "pieSectionTextColor": text.hexString,
            "pieLegendTextColor": text.hexString,
            "pieStrokeColor": bg.hexString,
            "pieOuterStrokeColor": line.hexString,
            "pieOpacity": "0.9",
        ]
        // 思维导图：根 = cScale0，第 i 个分支 = cScale(i+1)；节点底线 = cScaleInv（mermaid 默认取反色 → 粉紫），
        // 边框 = cScalePeer，字 = cScaleLabel。全部显式给：底线 / 边框取同色加深，字按对比度在正文色和底色里挑
        v["scaleLabelColor"] = text.hexString
        for (i, swatch) in swatches.enumerated() {
            let color = swatch.hexString
            let deeper = mix(swatch, text, 0.3)
            let label = readableLabel(on: swatch, text: text, bg: bg).hexString
            v["pie\(i + 1)"] = color
            v["cScale\(i)"] = color
            v["cScaleInv\(i)"] = deeper
            v["cScalePeer\(i)"] = deeper
            v["cScaleLabel\(i)"] = label
            v["fillType\(i)"] = color
            if i < 8 {
                v["git\(i)"] = color
                v["gitInv\(i)"] = deeper
                v["gitBranchLabel\(i)"] = label
            }
        }
        v["xyChart"] = [
            "plotColorPalette": palette.joined(separator: ","),
            "backgroundColor": bg.hexString, "titleColor": text.hexString,
            "xAxisLabelColor": text.hexString, "yAxisLabelColor": text.hexString,
            "xAxisTitleColor": text.hexString, "yAxisTitleColor": text.hexString,
            "xAxisLineColor": muted.hexString, "yAxisLineColor": muted.hexString,
            "xAxisTickColor": muted.hexString, "yAxisTickColor": muted.hexString,
        ]
        return v
    }

    /// a → b 线性混合 t（0 = a，1 = b），出 #RRGGBB
    static func mix(_ a: ThemeColorValue, _ b: ThemeColorValue, _ t: Double) -> String {
        mixValue(a, b, t).hexString
    }

    static func mixValue(_ a: ThemeColorValue, _ b: ThemeColorValue, _ t: Double) -> ThemeColorValue {
        ThemeColorValue(red: a.red + (b.red - a.red) * t,
                        green: a.green + (b.green - a.green) * t,
                        blue: a.blue + (b.blue - a.blue) * t)
    }

    /// 色块上的字：正文色和底色里对比度高的那个（深色主题正文色是浅的，照样成立）
    static func readableLabel(on fill: ThemeColorValue, text: ThemeColorValue, bg: ThemeColorValue) -> ThemeColorValue {
        func luminance(_ c: ThemeColorValue) -> Double {
            func channel(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
        }
        func contrast(_ a: ThemeColorValue, _ b: ThemeColorValue) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        return contrast(fill, text) >= contrast(fill, bg) ? text : bg
    }
}
