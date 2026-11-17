import XCTest
import SwiftUI
import SwiftData
import UIKit
import SwiftStreamingMarkdown
@testable import 记忆花园

// 像素对拍台（docs/plan-重构.md §4、R1）：同一批合成消息，旧对话页渲染一遍、新对话页渲染一遍，逐像素比。
// 这里是公共部分：夹具、把真实 ContentView 挂进测试宿主窗口、截图、比图。
// 做法照 BubblePageSnapshotTests：内存库 + TestHostIsolation，不读任何真实数据。

/// 一组合成消息。每组都短到一屏放得下，一张截图就是全部
struct ParityFixture {
    let name: String
    let messages: [(role: String, text: String)]

    /// 够滚好几屏的一段对话（每条都是一行，高度一致）。不进 `all`：旧页自比用不着它
    static let long = ParityFixture(name: "long", messages: (0..<40).map { index in
        (index % 2 == 0 ? "user" : "assistant", "第 \(index + 1) 条：\(["好", "知道了", "稍等一下", "没问题"][index % 4])。")
    })

    static let all: [ParityFixture] = [
        ParityFixture(name: "plain", messages: [
            ("user", "明天几点出发？"),
            ("assistant", "九点。路上大概四十分钟，到了先吃早饭。"),
            ("user", "好，那我定八点半的闹钟。"),
            ("assistant", "记得带伞，下午可能有雨。")
        ]),
        ParityFixture(name: "inline", messages: [
            ("user", "把重点标出来"),
            ("assistant", "这句里有**粗体**、*斜体*、`行内代码`、~~删除线~~，还有一个[链接](https://example.com)。\n\n第二段很长，用来看折行：春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。The quick brown fox jumps over the lazy dog, twice.")
        ]),
        ParityFixture(name: "blocks", messages: [
            ("user", "列个提纲"),
            ("assistant", "# 一级标题\n\n## 二级标题\n\n### 三级标题\n\n- 第一项\n- 第二项\n  - 嵌套一项\n- 第三项\n\n1. 先做这个\n2. 再做那个\n\n> 引用的一句话，稍微长一点，看看折行以后竖线怎么画。\n\n---\n\n最后一段。")
        ]),
        ParityFixture(name: "code", messages: [
            ("user", "写个函数"),
            ("assistant", "可以这样：\n\n```swift\nfunc greet(_ name: String) -> String {\n    let message = \"Hello, \\(name)! This line is long enough to need horizontal scrolling in a narrow column.\"\n    return message\n}\n```\n\n调用 `greet(\"粟粟\")` 就行。")
        ]),
        ParityFixture(name: "table", messages: [
            ("user", "对比一下"),
            ("assistant", "| 项目 | 甲 | 乙 |\n|---|---|---|\n| 速度 | 快 | 慢 |\n| 价格 | 贵 | 便宜 |\n| 备注 | 需要预约 | 随到随用 |\n\n表格下面的一句话。")
        ])
    ]
}

/// 一次截图里和对拍无关、每次都会变的东西要先排除掉；剩下的必须逐像素相同
struct ParityImage {
    let width: Int
    let height: Int
    private(set) var rgba: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ParityFailure.failed("位图上下文建不出来") }
    }

    struct Difference: CustomStringConvertible {
        var pixels = 0
        var maxChannelDelta = 0
        /// 有差异的像素的包围盒（像素坐标，原点左上）
        var box: CGRect?

        var description: String {
            guard pixels > 0, let box else { return "0 差异" }
            return "\(pixels) 个像素不同，单通道最大差 \(maxChannelDelta)，范围 x \(Int(box.minX))–\(Int(box.maxX)) y \(Int(box.minY))–\(Int(box.maxY))"
        }
    }

    /// 逐像素比。最上面 `noisyTopRows` 行（顶栏的玻璃和边缘模糊）和最下面 `noisyBottomRows` 行（输入条的玻璃）
    /// 每次挂载有 1–5 个色阶的噪声（11-11 旧页自比实测），单通道差不超过 `noiseTolerance` 的不算；其余区域必须完全相同。
    /// 消息真挪了一个像素，色差是几十上百，在哪一带都抓得到。
    /// 最下面 `ignoredBottomRows` 行完全不看（键盘弹着时输入条里有光标在闪，那一带没法比）。
    /// `tolerance`：噪声带以外的区域容忍的色阶差，默认 0。`ignored`：这些矩形（像素坐标）里不比。两个都只给个别说得清原因的组合用。
    func difference(from other: ParityImage, noisyTopRows: Int = 0, noisyBottomRows: Int = 0,
                    noiseTolerance: Int = 0, ignoredBottomRows: Int = 0, tolerance: Int = 0,
                    ignored: [CGRect] = []) throws -> Difference {
        guard width == other.width, height == other.height else {
            throw ParityFailure.failed("两张图尺寸不同：\(width)×\(height) vs \(other.width)×\(other.height)")
        }
        var result = Difference()
        var minX = width, minY = height, maxX = -1, maxY = -1
        let rowBytes = width * 4
        rgba.withUnsafeBufferPointer { mine in
            other.rgba.withUnsafeBufferPointer { theirs in
                guard let a = mine.baseAddress, let b = theirs.baseAddress else { return }
                for y in 0..<max(0, height - ignoredBottomRows) {
                    let row = y * rowBytes
                    // 绝大多数行完全相同：整行先比，不同的行才逐像素看
                    if memcmp(a + row, b + row, rowBytes) == 0 { continue }
                    let tolerance = y < noisyTopRows || y >= height - noisyBottomRows ? noiseTolerance : tolerance
                    for x in 0..<width {
                        let i = row + x * 4
                        var delta = 0
                        for channel in 0..<4 {
                            delta = max(delta, abs(Int(a[i + channel]) - Int(b[i + channel])))
                        }
                        guard delta > tolerance else { continue }
                        if !ignored.isEmpty, ignored.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { continue }
                        result.pixels += 1
                        result.maxChannelDelta = max(result.maxChannelDelta, delta)
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
        }
        if result.pixels > 0 {
            result.box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        return result
    }
}

enum ParityFailure: Error {
    case failed(String)
}

/// 把真实 ContentView 挂进测试宿主窗口，渲染一组夹具并截图
@MainActor
final class ParityHost {
    enum Mode: String, CaseIterable {
        case bubble, article
    }

    private static let conversationID = "probe-kb-conv-1"   // --kb-probe-seed 入口自动选中的那个 id
    /// 玻璃噪声带的高度（pt）和容忍的色阶差。11-11 回归机（874pt 高）实测：噪声全部落在最上面 200pt
    ///（顶栏玻璃 / 边缘模糊）和 740pt 以下（输入条玻璃），最大差 5
    static let noisyTopPoints: CGFloat = 200
    static let noisyBottomPoints: CGFloat = 140
    static let noiseTolerance = 6

    var noisyTopRows: Int { Int(Self.noisyTopPoints * window.traitCollection.displayScale) }

    /// 两张整页截图比出来的差异（两条噪声带按容忍算）。
    /// `noisyBottomPoints`：输入条被键盘顶上去时，玻璃噪声带跟着上移，由调用方给（见 `inputBarNoisePoints`）
    /// `ignoredBottomPoints`：最下面这么高完全不看（见 `inputBarZonePoints`）
    func difference(_ first: CGImage, _ second: CGImage, ignoredBottomPoints: CGFloat = 0,
                    tolerance: Int = 0, ignored: [CGRect] = []) throws -> ParityImage.Difference {
        let scale = window.traitCollection.displayScale
        return try ParityImage(first).difference(from: ParityImage(second), noisyTopRows: noisyTopRows,
                                                 noisyBottomRows: Int((Self.noisyBottomPoints + ignoredBottomPoints) * scale),
                                                 noiseTolerance: Self.noiseTolerance,
                                                 ignoredBottomRows: Int(ignoredBottomPoints * scale),
                                                 tolerance: tolerance,
                                                 ignored: ignored.map { $0.applying(CGAffineTransform(scaleX: scale, y: scale)) })
    }

    /// 此刻输入条那一带的高度：从输入条顶一直到屏幕底。键盘弹着时光标在闪、键盘本身不在这个窗口里，这一带不比
    var inputBarZonePoints: CGFloat {
        window.bounds.height - KeyboardInsetBridge.shared.containerTop
    }

    let window: UIWindow
    private let home: URL
    private let defaults = UserDefaults.standard

    init() async throws {
        // 必须先核对隔离，后面才允许触发管理器、SwiftData 或任何生产单例
        try Self.require(TestHostIsolation.active, "必须使用启用隔离的 iOS XCTest 宿主")
        guard let home = TestHostIsolation.home else { throw ParityFailure.failed("隔离家目录缺失") }
        self.home = home
        let env = ProcessInfo.processInfo.environment
        try Self.require(env["MP_TEST_HOST"] == "1", "缺少 MP_TEST_HOST=1")
        try Self.require(env["MP_SPLASH"] == "0", "不应被启动遮罩覆盖")
        try Self.require(CommandLine.arguments.contains("--kb-probe-seed"), "缺少真实 loadConversation 自动选中入口")
        try await Self.waitUntil("等待 XCTest 宿主的前台 UIWindowScene") {
            UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene && $0.activationState == .foregroundActive }
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow }) else {
            throw ParityFailure.failed("找不到宿主窗口")
        }
        self.window = window
    }

    /// 最近一次渲染新页时，截图那一刻列表和引擎的状态（对不上时打出来看）
    private(set) var lastNewPageState = ""

    /// 渲染一组夹具，等画面稳定后返回那张图。每次调用都是全新的库和全新的页面。
    /// `engine`：用哪套聊天页渲染。`minimal`：把时间戳和操作条在两页都关掉（新页还没做的部分），只比已经做了的
    func render(_ fixture: ParityFixture, mode: Mode, scheme: ColorScheme,
                engine: ChatPageEngine = .swiftui, minimal: Bool = false) async throws -> CGImage {
        try await mounted(fixture, mode: mode, scheme: scheme, engine: engine, minimal: minimal) {
            try await self.settledCapture(engine: engine)
        }
    }

    /// 把一组夹具挂上去，消息都到齐以后执行 `body`，执行完拆掉。要在同一次挂载里连拍几张（弹键盘前后）用它
    func mounted<T>(_ fixture: ParityFixture, mode: Mode, scheme: ColorScheme, engine: ChatPageEngine = .swiftui,
                    minimal: Bool = false, _ body: () async throws -> T) async throws -> T {
        ChatPageEngine.override = engine
        defer { ChatPageEngine.override = nil }
        let settings: [String: Any] = [
            "selectedFont": "", "fontScale": 17.0 / 13.5, "inputFontBase": 13.5,
            "showAvatar": true, "hideRoleName": mode == .bubble, "hideTimestamp": minimal,
            "hideActionBar": minimal,
            "userName": "You", "assistantName": "Jane Doe",
            BubblePopTuning.enabledKey: false
        ]
        let saved = settings.keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        defer {
            for key in settings.keys {
                if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        let root = home.appendingPathComponent("TranscriptParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = container.mainContext
        let profile = Profile(id: "parity-profile", name: "Jane Doe", emoji: "",
                              description: "合成对拍样本", userName: "You", assistantName: "Jane Doe")
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let presets = PresetManager(root: root, defaults: defaults)
        let providers = ProviderManager()
        let theme = ThemeManager.shared
        let oldMode = theme.themeMode
        let oldTheme = theme.selectedThemeId
        defer {
            theme.themeMode = oldMode
            theme.selectTheme(id: oldTheme)
        }

        guard let firstTime = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 15, hour: 12)) else {
            throw ParityFailure.failed("日期建不出来")
        }
        let nodeIDs = fixture.messages.indices.map { "parity-\(fixture.name)-\($0)" }
        let conversation = Conversation(id: Self.conversationID, title: "Parity \(fixture.name)",
                                        createTime: firstTime, updateTime: firstTime.addingTimeInterval(180),
                                        currentNodeId: nodeIDs[nodeIDs.count - 1], provider: "api", profileId: profile.id)
        conversation.nodeCount = fixture.messages.count
        conversation.memoryEnabled = false
        conversation.mode = mode == .bubble ? .bubble : .article
        context.insert(conversation)
        for (index, message) in fixture.messages.enumerated() {
            context.insert(MessageNode(id: nodeIDs[index], role: message.role, content: message.text,
                                       contentType: "text", createTime: firstTime.addingTimeInterval(Double(index) * 60),
                                       parentId: index == 0 ? nil : nodeIDs[index - 1],
                                       childrenIds: index + 1 == nodeIDs.count ? [] : [nodeIDs[index + 1]],
                                       conversationId: conversation.id, profileId: profile.id))
        }
        try context.save()

        theme.selectTheme(id: mode == .bubble ? AppThemeDefinition.iMessageTheme.id : AppThemeDefinition.defaultTheme.id)
        theme.themeMode = scheme == .light ? .light : .dark
        theme.syncSystemColorScheme(scheme)
        window.overrideUserInterfaceStyle = scheme == .light ? .light : .dark

        let testScene = MemoryPalaceIOSTestScene.shared
        defer {
            testScene.content = AnyView(Color.clear)
            PerfHarness.modelContext = nil
        }
        let previousViewModel = PerfHarness.viewModel
        let content = ContentView()
            .modelContainer(container)
            .environment(profiles)
            .environment(presets)
            .environment(providers)
            .environment(theme)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
        testScene.content = AnyView(content.id(UUID()))

        let window = window
        try await Self.waitUntil("等待真实会话和全部消息挂载（\(fixture.name)）") {
            window.layoutIfNeeded()
            guard let vm = PerfHarness.viewModel, vm !== previousViewModel,
                  vm.selectedConversation?.id == Self.conversationID,
                  vm.currentPath.map(\.id) == nodeIDs, !vm.isLoading else { return false }
            return PerfHarness.markdownPending == 0 && MarkdownHighlightProbe.pending == 0
        }
        return try await body()
    }

    /// 等画面稳定下来再截图。`ignoringBottom`：判断稳没稳的时候最下面这么高不看
    func settledCapture(engine: ChatPageEngine, ignoringBottom: CGFloat = 0) async throws -> CGImage {
        let ignoredRows = Int(ignoringBottom * window.traitCollection.displayScale)
        // 稳定 = 连续两次截图逐像素相同，且没有在途的异步排版和代码着色。
        // 只看「两次相同」不够：代码块着色前后各自都是静止画面（11-11 实测拍到过一张彩色一张没着色）
        // 两次截图之间必须让出主线程：新页收到「消息变了」以后隔一拍才重投影，
        // 连着拍两张会把还没更新的画面判成稳定（11-12 实测三组里两组拍到空白）
        var last = try ParityImage(capture())
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            let image = try capture()
            let current = try ParityImage(image)
            if try current.difference(from: last, ignoredBottomRows: ignoredRows).pixels == 0, PerfHarness.markdownPending == 0,
               MarkdownHighlightProbe.pending == 0 {
                if engine == .uikit { lastNewPageState = ChatPageAdapter.debugStates }
                lastLayerChains = probes.map { "(\(Int($0.x)), \(Int($0.y)))：\n" + layerChain(at: $0) }.joined(separator: "\n")
                if let probeRegion { lastLayerChains += "\n区域 \(probeRegion)：\n" + layerChain(at: .zero, within: probeRegion) }
                lastEdgeBlur = edgeBlurInputs()
                return image
            }
            last = current
        }
        throw ParityFailure.failed("画面 4 秒内没稳定下来")
    }

    func nodeID(_ fixture: ParityFixture, _ index: Int) -> String { "parity-\(fixture.name)-\(index)" }

    // MARK: 键盘

    private func inputField(in view: UIView) -> ChatInputTextView? {
        if let input = view as? ChatInputTextView, input.accessibilityIdentifier == "chat-input-field" { return input }
        for subview in view.subviews {
            if let found = inputField(in: subview) { return found }
        }
        return nil
    }

    /// 让真实输入框拿到焦点，等软键盘弹完。返回键盘在聊天页里遮住的高度；模拟器没弹软键盘时返回 nil
    func raiseKeyboard() async throws -> CGFloat? {
        guard let input = inputField(in: window) else { throw ParityFailure.failed("找不到输入框") }
        input.tintColor = .clear          // 光标会闪，截图里不能有
        guard input.becomeFirstResponder() else { throw ParityFailure.failed("输入框拿不到焦点") }
        let bridge = KeyboardInsetBridge.shared
        for _ in 0..<120 {
            if bridge.extra > 1, !bridge.kbTransitioning { return bridge.extra }
            try await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    func dismissKeyboard() async throws {
        inputField(in: window)?.resignFirstResponder()
        let bridge = KeyboardInsetBridge.shared
        try await Self.waitUntil("等键盘收完") { bridge.extra < 0.5 && !bridge.kbTransitioning && !bridge.kbVisible }
    }

    private(set) var lastEdgeBlur = ""

    /// 页面上那个边缘模糊拿到的参数，和它挂在哪
    private func edgeBlurInputs() -> String {
        var found: [String] = []
        func walk(_ view: UIView) {
            if let blur = view as? ChatContentEdgeBlur.AttachmentView {
                let bridge = KeyboardInsetBridge.shared
                found.append("半径 \(blur.radius) 输入条底 \(blur.inputBarBottom) 键盘 \(blur.keyboardVisible) 开 \(blur.enabled) 顶部渐隐 \(blur.topFadeEnd)"
                    + "｜桥：条顶 \(bridge.containerTop) 条高 \(bridge.barVisibleHeight) 键盘 \(bridge.kbVisible)")
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found.isEmpty ? "没有边缘模糊" : found.joined(separator: "；")
    }

    /// 要查图层的点（窗口坐标，pt）。设了以后每次渲染把这些点上叠着的图层记到 `lastLayerChains`
    var probes: [CGPoint] = []
    private(set) var lastLayerChains = ""

    /// 某个点上从下到上叠着哪些「会画东西或会改合成方式」的图层。两页差一两个色阶时用它找是哪一层
    /// 要查的一块区域（窗口坐标，pt）：把整个落在里面的图层全列出来。做一种新的行之前，先用它把旧页那一块的结构读清楚
    var probeRegion: CGRect?

    private func layerChain(at point: CGPoint, within region: CGRect? = nil) -> String {
        var lines: [String] = []
        func walk(_ layer: CALayer, depth: Int) {
            guard !layer.isHidden, lines.count < (region == nil ? 80 : 400) else { return }
            let local = layer.convert(point, from: window.layer)
            let hit = region.map { $0.contains(layer.convert(layer.bounds, to: window.layer)) } ?? layer.bounds.contains(local)
            if hit {
                var notes: [String] = []
                if let contents = layer.contents {
                    var note = "有内容 \(type(of: contents)) 倍率 \(layer.contentsScale) 摆法 \(layer.contentsGravity.rawValue) 本地 \(layer.bounds.size) 位置 \(layer.position) 锚 \(layer.anchorPoint)"
                    if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                        let image = contents as! CGImage
                        note += " 位图 \(image.width)×\(image.height)"
                    }
                    notes.append(note)
                }
                if let color = layer.backgroundColor { notes.append("底色 alpha \(color.alpha)") }
                if let shape = layer as? CAShapeLayer {
                    var elements: [String] = []
                    shape.path?.applyWithBlock { element in
                        let points = element.pointee.points
                        func p(_ index: Int) -> String { String(format: "(%.7f, %.7f)", points[index].x, points[index].y) }
                        switch element.pointee.type {
                        case .moveToPoint: elements.append("M\(p(0))")
                        case .addLineToPoint: elements.append("L\(p(0))")
                        case .addQuadCurveToPoint: elements.append("Q\(p(0))\(p(1))")
                        case .addCurveToPoint: elements.append("C\(p(0))\(p(1))\(p(2))")
                        case .closeSubpath: elements.append("Z")
                        @unknown default: elements.append("?")
                        }
                    }
                    notes.append("形状 填充 \(shape.fillColor?.components ?? []) 规则 \(shape.fillRule.rawValue) 倍率 \(shape.contentsScale) 抗锯齿 \(shape.allowsEdgeAntialiasing) 本地 \(shape.bounds) 路径 \(elements.prefix(400).joined(separator: " "))")
                }
                if layer.opacity < 1 { notes.append("不透明度 \(layer.opacity)") }
                if !CATransform3DIsIdentity(layer.transform) {
                    let t = layer.transform
                    notes.append(String(format: "变换 [%.3g %.3g; %.3g %.3g] z %.3g", t.m11, t.m12, t.m21, t.m22, t.m33))
                }
                if !CATransform3DIsIdentity(layer.sublayerTransform) { notes.append("子层变换") }
                if layer.isGeometryFlipped { notes.append("几何翻转") }
                if layer.shouldRasterize { notes.append("栅格化") }
                if layer.borderWidth > 0 { notes.append("描边 \(layer.borderWidth) \(layer.borderColor?.components ?? [])") }
                if layer.cornerRadius > 0 {
                    notes.append("圆角 \(layer.cornerRadius) \(layer.cornerCurve.rawValue) 角 \(layer.maskedCorners.rawValue) 倍率 \(layer.contentsScale) 边缘抗锯齿 \(layer.allowsEdgeAntialiasing) 裁切 \(layer.masksToBounds) 不透明 \(layer.isOpaque) 色 \(layer.backgroundColor?.components ?? []) \(layer.backgroundColor?.colorSpace?.name as String? ?? "-")")
                }
                if layer.mask != nil { notes.append("有蒙版") }
                if let filters = layer.filters, !filters.isEmpty { notes.append("滤镜 \(filters.count)") }
                if let filters = layer.backgroundFilters, !filters.isEmpty { notes.append("背景滤镜 \(filters.count)") }
                if layer.compositingFilter != nil { notes.append("合成滤镜") }
                if !layer.allowsGroupOpacity { notes.append("不成组") }
                if !notes.isEmpty {
                    let frame = layer.convert(layer.bounds, to: window.layer)
                    let owner = layer.delegate.map { "\(type(of: $0))" } ?? "-"
                    lines.append(String(repeating: " ", count: min(depth, 30)) + "\(type(of: layer))/\(owner) "
                        + String(format: "(%.2f, %.2f, %.2f, %.2f) ", frame.minX, frame.minY, frame.width, frame.height)
                        + notes.joined(separator: "，"))
                }
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer, depth: depth + 1) }
        }
        walk(window.layer, depth: 0)
        return lines.joined(separator: "\n")
    }

    func capture() throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        var drawn = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard drawn, let pixels = image.cgImage else { throw ParityFailure.failed("drawHierarchy 失败") }
        return pixels
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let data = UIImage(cgImage: image).pngData() else { throw ParityFailure.failed("PNG 编码失败") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func waitUntil(_ reason: String, timeout: TimeInterval = 15, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ParityFailure.failed(reason)
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw ParityFailure.failed(reason) }
    }
}
