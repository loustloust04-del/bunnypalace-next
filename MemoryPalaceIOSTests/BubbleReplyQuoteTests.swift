import XCTest
import SwiftUI
import SwiftData
import UIKit
import Vision
import CoreImage
@testable import 记忆花园

/// r2：气泡模式里回复引用看得见（泡上方、同侧对齐、对比度够）；AI 回复里的 `>` 引用块在灰泡上看得清；
/// 气泡模式色只染聊天页（page0 列表仍是这套主题的普通色）。顺带出交付截图（MP_BUBBLE_SNAPSHOT_DIR）。
/// 运行：-only-testing:MemoryPalaceIOSTests/BubbleReplyQuoteTests（Debug 宿主、--kb-probe-seed、393×852@3x）
@MainActor
final class BubbleReplyQuoteTests: XCTestCase {
    #if DEBUG
    private static let conversationID = "probe-kb-conv-1"
    private static let quoted = "Come over at 12"
    private static let replyText = "Deal see you then"
    private static let blockQuote = "Bring something sweet"
    /// 经典米白卡底（SwiftStreamingMarkdown CodeBlockStyle.body #FFFDF9）
    private static let classicCardBody = ThemeColorValue(hex: 0xFFFDF9)
    private static let chartTitle = "Sleep this week"
    private static let chartBlock = "```card-chart\n"
        + #"{"id":"r2-chart","type":"bar","title":"Sleep this week","subtitle":"hours","unit":"h","series":[{"name":"sleep","points":[["Mon",7.5],["Tue",6],["Wed",5]]}]}"#
        + "\n```"

    private struct Variant {
        let name: String
        let scheme: ColorScheme
        let bubble: Bool
        let selectedTheme: String
        let liveTurn: Bool
        var chart = false
        /// 共存第一步：这套主题有没有设气泡模式色（只给「改过的默认」那套用）
        var bubbleColors = false
    }

    func testReplyQuoteBlockQuoteAndThemeScope() async throws {
        try require(TestHostIsolation.active, "必须使用启用隔离的 iOS XCTest 宿主")
        let home = try XCTUnwrap(TestHostIsolation.home)
        let env = ProcessInfo.processInfo.environment
        try require(env["MP_TEST_HOST"] == "1" && env["MP_SPLASH"] == "0", "缺少 MP_TEST_HOST=1 / MP_SPLASH=0")
        try require(CommandLine.arguments.contains("--kb-probe-seed"), "缺少真实 loadConversation 自动选中入口")
        let outputPath = try XCTUnwrap(env["MP_BUBBLE_SNAPSHOT_DIR"], "必须指定截图媒体目录")
        try require(outputPath.hasPrefix("/") && !outputPath.contains("$("), "截图目录必须是已展开的绝对路径")
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        let settings: [String: Any] = [
            "selectedFont": "", "fontScale": 17.0 / 13.5, "inputFontBase": 13.5,
            "hideTimestamp": false, "userName": "You", "assistantName": "Jane Doe",
            BubblePopTuning.enabledKey: false, "ttsEnabled": false,
            PermissionDomain.toolsMaster.storageKey: PermissionLevel.bypass.rawValue,
            PermissionDomain.fileLibrary.storageKey: PermissionLevel.notAllowed.rawValue,
            DisclosureKind.thinking.key: DisclosureMode.hidden.rawValue
        ]
        let restoreKeys = Array(settings.keys) + ["hideRoleName"]
        let saved = restoreKeys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        let budgetEnabled = GlobalBudgetStore.shared.enabled
        GlobalBudgetStore.shared.setEnabled(false)
        defer {
            for key in restoreKeys {
                if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            GlobalBudgetStore.shared.setEnabled(budgetEnabled)
        }

        // 她的默认主题自己改过颜色（改主题 = 复制一份再改，生产同路径）：暖色底，和 iMessage 一眼分得开
        let theme = ThemeManager.shared
        let savedMode = theme.themeMode
        let savedSelected = theme.selectedThemeId
        let customId = try XCTUnwrap(theme.saveThemeCopy(from: AppThemeDefinition.defaultTheme.id, name: "改过的默认", select: false))
        var light = ThemeTokenSet.palaceLightDefault
        light.mainBg = ThemeColorValue(hex: 0xF3E3D3)
        light.sidebarBg = ThemeColorValue(hex: 0xE6CDB4)
        light.userBubble = ThemeColorValue(hex: 0x8A2345)
        light.userText = ThemeColorValue(hex: 0xFFFFFF)
        light.assistantBubble = ThemeColorValue(hex: 0xEAD9C8)
        theme.replaceTokenSet(light, for: .light, themeId: customId)
        defer {
            theme.themeMode = savedMode
            theme.selectTheme(id: savedSelected)
            theme.deleteTheme(id: customId)
        }

        let scene = try await foregroundScene()
        XCTAssertEqual(scene.screen.bounds.size, CGSize(width: 393, height: 852))
        XCTAssertEqual(scene.screen.scale, 3)
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        defer {
            MemoryPalaceIOSTestScene.shared.content = AnyView(Color.clear)
            PerfHarness.modelContext = nil
        }

        let imessage = AppThemeDefinition.iMessageTheme.id
        let palace = AppThemeDefinition.defaultTheme.id
        let variants = [
            Variant(name: "imessage-light", scheme: .light, bubble: true, selectedTheme: imessage, liveTurn: true),
            Variant(name: "imessage-dark", scheme: .dark, bubble: true, selectedTheme: imessage, liveTurn: true),
            // 没设气泡模式色：泡跟随这套主题的普通色
            Variant(name: "custom-default-light", scheme: .light, bubble: true, selectedTheme: customId, liveTurn: false),
            Variant(name: "article-light", scheme: .light, bubble: false, selectedTheme: palace, liveTurn: false),
            // 同一套主题设了气泡模式色（iMessage 蓝）：聊天页泡变蓝，列表页仍是这套主题的暖色
            Variant(name: "scope-light", scheme: .light, bubble: true, selectedTheme: customId, liveTurn: false, bubbleColors: true),
            Variant(name: "chart-dark", scheme: .dark, bubble: true, selectedTheme: imessage, liveTurn: false, chart: true)
        ]
        for variant in variants {
            try await run(variant, window: window, home: home, output: output, theme: theme, customId: customId, customLight: light)
        }
    }

    private func run(_ v: Variant, window: UIWindow, home: URL, output: URL, theme: ThemeManager,
                     customId: String, customLight: ThemeTokenSet) async throws {
        let defaults = UserDefaults.standard
        defaults.set(!v.bubble, forKey: "hideRoleName")
        var themedLight = customLight
        if v.bubbleColors {
            // 普通色带渐变、气泡模式只换泡底不设渐变 → 气泡模式下应是单色蓝泡（返工③）
            themedLight.userBubbleGradient = ThemeColorValue(hex: 0xE8B4A8)
            themedLight.bubbleModeUserBubble = ThemeTokenSet.iMessageLight.userBubble
            themedLight.bubbleModeUserText = ThemeColorValue(hex: 0xFFFFFF)
            themedLight.bubbleModeAssistantBubble = ThemeTokenSet.iMessageLight.assistantBubble
            themedLight.bubbleModeAssistantText = ThemeColorValue(hex: 0x000000)
        }
        theme.replaceTokenSet(themedLight, for: .light, themeId: customId)
        theme.selectTheme(id: v.selectedTheme)
        theme.themeMode = v.scheme == .light ? .light : .dark
        theme.syncSystemColorScheme(v.scheme)
        window.overrideUserInterfaceStyle = v.scheme == .light ? .light : .dark

        // 每个变体一套新的内存库：上一轮真发出去的消息不串进下一张图
        let root = home.appendingPathComponent("BubbleReplyQuoteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = container.mainContext
        let profile = Profile(id: "bubble-reply-profile", name: "Jane Doe", emoji: "",
                              description: "合成截图样本", userName: "You", assistantName: "Jane Doe")
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let presets = PresetManager(root: root, defaults: defaults)
        let providers = ProviderManager()

        // 活轮次那两张：回复那条走真实「引用 → 发送」生产路径现发（Read 跟着它），屏幕放得下全部要素；
        // 其它变体直接落库三条（回复带 replyToId）。时间放在几分钟前：同屏只有一条时间分隔。
        let t0 = Date().addingTimeInterval(-300)
        let stored = v.liveTurn ? 2 : 3
        let ids = (0..<stored).map { "bubble-reply-\(v.name)-\($0)" }
        let contents: [(String, String)] = Array([
            ("assistant", Self.quoted),
            ("assistant", v.chart ? Self.chartBlock : "> \(Self.blockQuote)"),
            ("user", "Deal, see you then")
        ].prefix(stored))
        let conversation = Conversation(id: Self.conversationID, title: "Bubble reply", createTime: t0,
                                        updateTime: t0.addingTimeInterval(120), currentNodeId: ids[stored - 1],
                                        provider: "api", profileId: profile.id)
        conversation.nodeCount = stored
        conversation.memoryEnabled = false
        conversation.mode = v.bubble ? .bubble : .article
        context.insert(conversation)
        for (i, item) in contents.enumerated() {
            let node = MessageNode(id: ids[i], role: item.0, content: item.1, contentType: "text",
                                   createTime: t0.addingTimeInterval(Double(i) * 60),
                                   parentId: i == 0 ? nil : ids[i - 1], childrenIds: i == stored - 1 ? [] : [ids[i + 1]],
                                   conversationId: conversation.id, profileId: profile.id)
            if i == 2 { node.replyToId = ids[0] }
            context.insert(node)
        }
        try context.save()
        let reaction = "\(ids[0])#0"
        ChatReactionStore.shared.toggle("❤️", on: reaction)
        defer { ChatReactionStore.shared.toggle("❤️", on: reaction) }

        let previous = PerfHarness.viewModel
        MemoryPalaceIOSTestScene.shared.content = AnyView(ContentView()
            .modelContainer(container)
            .environment(profiles).environment(presets).environment(providers).environment(theme)
            .environment(\.colorScheme, v.scheme)
            .preferredColorScheme(v.scheme)
            .id(v.name))
        try await waitUntil("等待真实会话加载（\(v.name)）") {
            window.layoutIfNeeded()
            guard let vm = PerfHarness.viewModel, vm !== previous, !vm.isLoading,
                  vm.selectedConversation?.id == Self.conversationID, vm.currentPath.map(\.id) == ids,
                  PerfHarness.paging?.view.window === window else { return false }
            return PerfHarness.markdownPending == 0
        }
        let vm = try XCTUnwrap(PerfHarness.viewModel)
        XCTAssertEqual(vm.isBubbleMode, v.bubble)
        XCTAssertEqual(theme.isBubbleModeActive, v.bubble, "聊天页配色跟着对话自己的模式")
        try await settle(window)

        var server: ScriptedHTTPServer?
        var credential: String?
        let continuation = DispatchSemaphore(value: 0)
        defer {
            continuation.signal()
            server?.stop()
            if let credential { providers.removeCredential(id: credential) }
        }
        if v.liveTurn {
            // 第一轮只写状态（set_turn_status），第二轮请求挂起：轮次进行中、顶栏有状态、她那条下有 Read
            let first = try Self.statusOnlyReply("拉磨中")
            let s = try ScriptedHTTPServer { index, _ in
                if index == 0 { return (200, "text/event-stream", first) }
                _ = continuation.wait(timeout: .now() + 120)
                return (200, "text/event-stream", TurnStatusStreamFixture.finalReply)
            }
            try s.start()
            server = s
            let credentialId = "bubble-reply-\(UUID().uuidString)"
            let model = ProviderModel(credentialId: credentialId, modelId: "gpt-4o", name: "本地合成回包")
            providers.addCredential(APICredential(id: credentialId, name: "本地合成回包", emoji: "",
                                                  type: .openaiCompatible, baseURL: s.baseURL, models: [model]))
            providers.setApiKey("test-key", for: credentialId)
            credential = credentialId
            let target = try XCTUnwrap(vm.currentPath.first)
            vm.startQuotingText(Self.quoted, node: target)
            XCTAssertTrue(vm.sendMessage("Deal, see you then", model: model, profile: profile, preset: .balanced,
                                         providerManager: providers, context: context))
            try await waitUntil("等待真实SSE写出状态、续轮挂起") {
                s.requestBodies.count == 2 && vm.turnStatus(for: Self.conversationID) == "拉磨中"
            }
            XCTAssertEqual(vm.turnStatus(for: Self.conversationID), "拉磨中")
            try await settle(window)
        }
        defer { if v.liveTurn { vm.cancelAssistantTurn(context: context) } }

        let shot = try capture(window: window, to: output.appendingPathComponent("r2-\(v.name).png"))
        let text = try recognizedText(in: shot, size: window.bounds.size)
        try JSONEncoder().encode(text).write(to: output.appendingPathComponent("r2-\(v.name)-text.json"), options: .atomic)
        let pixels = try Pixels(shot)

        if v.chart {
            try assertChartPaper(text: text, pixels: pixels)
            return
        }
        if v.name == "scope-light" {
            try await assertScope(window: window, output: output, chat: pixels, customLight: customLight)
            return
        }
        guard v.bubble else {
            // 文章模式只出对照图：引用条 / 引用块样式不动（不在本轮范围）
            XCTAssertTrue(text.contains { $0.key.contains(Self.textKey(Self.quoted)) })
            return
        }
        // 回复引用：看得见、在她那条泡上方、同侧（右）对齐、字够清楚
        let reply = try XCTUnwrap(text.last { $0.key.contains(Self.textKey(Self.replyText)) }, "找不到回复那条泡")
        let quotes = text.filter { $0.key.contains(Self.textKey(Self.quoted)) && $0.frame.maxY <= reply.frame.minY + 2 }
        let quote = try XCTUnwrap(quotes.max { $0.frame.minY < $1.frame.minY }, "回复引用没画出来（\(v.name)）")
        XCTAssertGreaterThan(quote.frame.minY, reply.frame.minY - 90, "引用要紧贴在回复泡上方")
        XCTAssertGreaterThan(quote.frame.minX, window.bounds.midX - 40, "气泡模式引用要和她的泡一起靠右")
        XCTAssertEqual(quote.frame.maxX, reply.frame.maxX, accuracy: 40, "引用和泡右缘对齐")
        let quoteContrast = pixels.contrast(in: quote.frame)
        XCTAssertGreaterThanOrEqual(quoteContrast, 4.5, "回复引用字对比度不够（\(v.name)）：\(quoteContrast)")

        // AI 回复里的 `>` 引用块：灰泡上也看得清
        let block = try XCTUnwrap(text.first { $0.key.contains(Self.textKey(Self.blockQuote)) }, "引用块文字没识别出来")
        let blockContrast = pixels.contrast(in: block.frame)
        XCTAssertGreaterThanOrEqual(blockContrast, 4.5, "引用块对比度不够（\(v.name)）：\(blockContrast)")

        if v.liveTurn {
            XCTAssertTrue(text.contains { $0.frame.maxY < 180 && $0.text.contains("拉磨中") }, "顶栏状态行")
            // 深色下 11pt 灰字 Vision 偶尔漏认：漏了就在反色图上再认一遍（看的仍是同一张实拍）
            var readFound = text.contains { $0.key == "Read" }
            if !readFound {
                let again = try recognizedText(in: try inverted(shot), size: window.bounds.size)
                readFound = again.contains { $0.key == "Read" }
            }
            XCTAssertTrue(readFound, "Read 回执")
        }
        print("[r2 引用] \(v.name) 引用对比度 \(quoteContrast)，引用块对比度 \(blockContrast)")

        if v.liveTurn && v.scheme == .dark {
            // 返工 5：进度卡跟聊天主题，深色 iMessage 下不能再是米白卡
            XCTAssertLessThan(pixels.count(near: Self.classicCardBody), 1500, "深色气泡模式的进度卡还是米白底")
            // 返工 3：从聊天页打开的过程 sheet 整张（底 + 字 + 里面的卡）跟聊天主题
            let details = BubbleTurnDetails(conversationId: Self.conversationID, profileId: profile.id,
                                            turnID: vm.currentTurnID,
                                            content: .init(node: vm.currentTurnNode(for: Self.conversationID)),
                                            bridgePhase: nil)
            let sheet = UIHostingController(rootView: BubbleTurnSheet(viewModel: vm, details: details)
                .modelContainer(container).environment(profiles).environment(presets).environment(providers)
                .environment(theme).environment(\.colorScheme, .dark))
            sheet.overrideUserInterfaceStyle = .dark
            sheet.modalPresentationStyle = .pageSheet
            sheet.sheetPresentationController?.detents = [.large()]
            let presenter = try XCTUnwrap(window.rootViewController)
            presenter.present(sheet, animated: false)
            defer { sheet.dismiss(animated: false) }
            try await waitUntil("等待过程 sheet 挂上") { sheet.view.window === window && !sheet.isBeingPresented }
            try await settle(window)
            let sheetShot = try Pixels(try capture(window: window, to: output.appendingPathComponent("r2-sheet-dark.png")))
            let black = sheetShot.count(near: ThemeTokenSet.iMessageDark.mainBg)
            XCTAssertGreaterThan(black, sheetShot.total / 4, "过程 sheet 底应是 iMessage 深色底")
            XCTAssertLessThan(sheetShot.count(near: ThemeTokenSet.palaceLightDefault.mainBg), 1500, "过程 sheet 不能是全局浅色底")
            XCTAssertLessThan(sheetShot.count(near: Self.classicCardBody), 1500, "sheet 里的进度卡也跟聊天主题")
        }
    }

    /// 返工二：图表卡内部是固定纸墨（ChartInk），不在跟聊天主题的卡片名单里——深色 iMessage 下仍是米白纸壳，标题墨看得清
    private func assertChartPaper(text: [TextEvidence], pixels: Pixels) throws {
        let title = try XCTUnwrap(text.first { $0.key.contains(Self.textKey(Self.chartTitle)) }, "图表卡标题没识别出来")
        let around = title.frame.insetBy(dx: -12, dy: -10)
        XCTAssertGreaterThan(pixels.count(near: Self.classicCardBody, in: around), pixels.samples(in: around) / 3,
                             "深色气泡模式下图表卡壳应保持米白纸")
        let contrast = pixels.contrast(in: title.frame)
        XCTAssertGreaterThanOrEqual(contrast, 4.5, "图表卡标题墨对比度不够：\(contrast)")
        print("[r2 图表] 标题对比度 \(contrast)")
    }

    /// 只有聊天页用气泡模式色：同一时刻聊天页有 iMessage 蓝，page0 列表是她的暖色主题、没有 iMessage 灰白
    private func assertScope(window: UIWindow, output: URL, chat: Pixels, customLight: ThemeTokenSet) async throws {
        XCTAssertGreaterThan(chat.count(near: ThemeTokenSet.iMessageLight.userBubble), 400, "聊天页应是 iMessage 气泡色")
        XCTAssertLessThan(chat.count(near: ThemeColorValue(hex: 0xE8B4A8)), 30, "泡底换了没设气泡模式渐变：单色，不带普通渐变第二色")
        let paging = try XCTUnwrap(PerfHarness.paging)
        paging.scrollToPage(0, animated: false)
        try await settle(window)
        let list = try Pixels(try capture(window: window, to: output.appendingPathComponent("r2-nonchat-list-light.png")))
        let themed = list.count(near: customLight.sidebarBg) + list.count(near: customLight.mainBg)
        XCTAssertGreaterThan(themed, list.total / 3, "列表页应是全局主题（她的暖色）")
        XCTAssertLessThan(list.count(near: ThemeTokenSet.iMessageLight.sidebarBg), list.total / 20, "列表页不能被染成 iMessage 灰")
        XCTAssertLessThan(list.count(near: ThemeTokenSet.iMessageLight.userBubble), 50, "列表页不能出现 iMessage 蓝")
        paging.scrollToPage(1, animated: false)
    }

    // MARK: - helpers

    private static func statusOnlyReply(_ text: String) throws -> Data {
        let args = String(decoding: try JSONEncoder().encode(["status": text]), as: UTF8.self)
        let status = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        let event = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"status-call","type":"function","function":{"name":"set_turn_status","arguments":\#(status)}}]},"finish_reason":"tool_calls"}]}"#
        return Data((event + "\n\ndata: [DONE]\n\n").utf8)
    }

    private struct TextEvidence: Encodable {
        let text: String
        let key: String
        let frame: CGRect
    }

    private struct Pixels {
        let data: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat = 3

        init(_ image: CGImage) throws {
            let w = image.width, h = image.height
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            buffer.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            data = buffer
        }

        var total: Int { (width / 6) * (height / 6) }

        private func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * width + x) * 4
            return (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
        }

        private static func luminance(_ c: (Double, Double, Double)) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
        }

        /// 文字框里最深墨迹 vs 最浅底色的对比度（3x 像素全扫）
        func contrast(in frame: CGRect) -> Double {
            let x0 = max(0, Int(frame.minX * scale)), x1 = min(width - 1, Int(frame.maxX * scale))
            let y0 = max(0, Int(frame.minY * scale)), y1 = min(height - 1, Int(frame.maxY * scale))
            var lo = 1.0, hi = 0.0
            guard x0 < x1, y0 < y1 else { return 0 }
            for y in y0...y1 {
                for x in x0...x1 {
                    let l = Self.luminance(rgb(x, y))
                    lo = min(lo, l)
                    hi = max(hi, l)
                }
            }
            return (hi + 0.05) / (lo + 0.05)
        }

        /// 每 6px（2pt）采一点，离目标色 RGB 各分量都在 6/255 内的点数
        func samples(in frame: CGRect) -> Int {
            let r = pixelRect(frame)
            return ((r.maxX - r.minX) / 6 + 1) * ((r.maxY - r.minY) / 6 + 1)
        }

        private func pixelRect(_ frame: CGRect) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
            (max(0, Int(frame.minX * scale)), min(width - 1, Int(frame.maxX * scale)),
             max(0, Int(frame.minY * scale)), min(height - 1, Int(frame.maxY * scale)))
        }

        /// frame = nil 全屏
        func count(near color: ThemeColorValue, in frame: CGRect? = nil) -> Int {
            let r = frame.map(pixelRect) ?? (minX: 0, maxX: width - 1, minY: 0, maxY: height - 1)
            var n = 0
            for y in stride(from: r.minY, through: r.maxY, by: 6) {
                for x in stride(from: r.minX, through: r.maxX, by: 6) {
                    let c = rgb(x, y)
                    if abs(c.0 - color.red) < 0.025, abs(c.1 - color.green) < 0.025, abs(c.2 - color.blue) < 0.025 { n += 1 }
                }
            }
            return n
        }
    }

    private func foregroundScene() async throws -> UIWindowScene {
        try await waitUntil("等待 XCTest 宿主的前台 UIWindowScene") {
            UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene && $0.activationState == .foregroundActive }
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    /// 布局连续几拍不变才拍照（不是定时盲截）
    private func settle(_ window: UIWindow) async throws {
        var last: Data?
        var stable = 0
        try await waitUntil("等待页面稳定") {
            window.layoutIfNeeded()
            guard PerfHarness.markdownPending == 0 else { stable = 0; return false }
            let sig = Self.signature(window)
            stable = sig == last ? stable + 1 : 0
            last = sig
            return stable >= 8
        }
    }

    private static func signature(_ view: UIView) -> Data {
        var parts: [CGFloat] = []
        func walk(_ v: UIView, depth: Int) {
            guard depth < 40 else { return }
            let f = v.convert(v.bounds, to: nil)
            parts += [f.minX, f.minY, f.width, f.height]
            v.subviews.forEach { walk($0, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return parts.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func capture(window: UIWindow, to url: URL) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        var drawn = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try require(drawn, "真实窗口 drawHierarchy 失败")
        try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)
        let decoded = try XCTUnwrap(UIImage(data: Data(contentsOf: url))?.cgImage)
        XCTAssertEqual(decoded.width, 1179)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = url.lastPathComponent
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[r2 截图] \(url.path)")
        return decoded
    }

    private func inverted(_ image: CGImage) throws -> CGImage {
        let filter = try XCTUnwrap(CIFilter(name: "CIColorInvert"))
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        let output = try XCTUnwrap(filter.outputImage)
        return try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
    }

    private func recognizedText(in pixels: CGImage, size: CGSize) throws -> [TextEvidence] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: pixels).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return TextEvidence(text: text, key: Self.textKey(text),
                                frame: CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                              width: box.width * size.width, height: box.height * size.height))
        }
    }

    private static func textKey(_ text: String) -> String {
        text.filter { $0.isLetter || $0.isNumber }
    }

    private func waitUntil(_ reason: String, timeout: TimeInterval = 20, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail(reason)
        throw Failure.failed(reason)
    }

    private func require(_ condition: Bool, _ reason: String) throws {
        guard condition else {
            XCTFail(reason)
            throw Failure.failed(reason)
        }
    }

    private enum Failure: Error { case failed(String) }
    #else
    func testRequiresDebugHost() { XCTFail("回复引用整页测试依赖 Debug 宿主") }
    #endif
}
