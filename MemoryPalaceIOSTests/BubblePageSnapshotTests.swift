import XCTest
import SwiftUI
import SwiftData
import UIKit
import Vision
@testable import 记忆花园

/// 主对拍挂生产ContentView；同时验证文章署名和真实外观设置页。
/// 运行：-only-testing:MemoryPalaceIOSTests/BubblePageSnapshotTests
/// 需要 Debug 宿主、--kb-probe-seed、MP_TEST_HOST=1、MP_SPLASH=0，
/// MP_BUBBLE_SNAPSHOT_DIR 为已展开的媒体目录；设备必须是 393×852pt、3x。
@MainActor
final class BubblePageSnapshotTests: XCTestCase {
    #if DEBUG
    private static let conversationID = "probe-kb-conv-1"
    private static let messages: [(role: String, text: String)] = [
        ("assistant", "Come over at 12"),
        ("user", "Which flavor do you want?"),
        ("assistant", "I love chocolate chip!!! 🍪"),
        ("assistant", "Thank you!")
    ]

    func testLightAndDarkPreviews() async throws {
        // 必须先核对隔离，后面才允许触发管理器、SwiftData 或任何生产单例。
        try require(TestHostIsolation.active, "必须使用启用隔离的 iOS XCTest 宿主")
        let home = try XCTUnwrap(TestHostIsolation.home)
        try require(!TestHostIsolation.defaultsSuiteName.isEmpty, "隔离偏好 suite 缺失")
        let env = ProcessInfo.processInfo.environment
        try require(env["MP_TEST_HOST"] == "1", "缺少 MP_TEST_HOST=1")
        try require(env["MP_SPLASH"] == "0", "预览不应被启动遮罩覆盖")
        try require(CommandLine.arguments.contains("--kb-probe-seed"), "缺少真实 loadConversation 自动选中入口")
        let outputPath = try XCTUnwrap(env["MP_BUBBLE_SNAPSHOT_DIR"], "必须指定截图媒体目录")
        try require(outputPath.hasPrefix("/") && !outputPath.contains("$(") && !outputPath.contains("${"),
                    "截图目录必须是已展开的绝对路径：\(outputPath)")
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("[气泡整页截图] 输出目录：\(output.path)")

        let defaults = UserDefaults.standard
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: TestHostIsolation.defaultsSuiteName))
        let markerKey = "BubblePageSnapshotTests.isolation.\(UUID().uuidString)"
        defaults.set(TestHostIsolation.runTag, forKey: markerKey)
        defer { defaults.removeObject(forKey: markerKey) }
        try require(isolatedDefaults.string(forKey: markerKey) == TestHostIsolation.runTag,
                    "UserDefaults.standard 没有改道至宿主隔离 suite")

        // 刻意保留与新版相反的旧偏好：气泡要求显示头像/昵称，文章要求隐藏昵称。
        // 实图仍应固定为气泡无头像无昵称、文章署名常显。
        let settings: [String: Any] = [
            "selectedFont": "", "fontScale": 17.0 / 13.5, "inputFontBase": 13.5,
            "showAvatar": true, "hideRoleName": true,
            "hideTimestamp": false, "userName": "You", "assistantName": "Jane Doe",
            BubblePopTuning.enabledKey: false
        ]
        let savedSettings = settings.keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        defer {
            for key in settings.keys {
                if let value = savedSettings[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        XCTAssertEqual(FontManager.uiFont(size: 13.5).pointSize, 17, accuracy: 0.01)

        let root = home.appendingPathComponent("BubblePageSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = ProfileManager.makeFullSchema()
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        var profile = Profile(id: "bubble-preview-profile", name: "Jane Doe", emoji: "",
                              description: "合成截图样本", userName: "You", assistantName: "Jane Doe")
        profile.assistantAvatarData = try syntheticAvatar()
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let presets = PresetManager(root: root, defaults: defaults)
        let providers = ProviderManager()
        // Theme 的静态 token 读取 shared；注入同一个实例，避免环境深色、正文却仍浅色。
        // shared 只能在上面的宿主隔离检查之后首次访问，默认偏好已经是本 run 的 suite。
        let theme = ThemeManager.shared
        let oldMode = theme.themeMode
        let oldTheme = theme.selectedThemeId
        defer {
            theme.themeMode = oldMode
            theme.selectTheme(id: oldTheme)
        }

        let firstTime = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 15, hour: 12)))
        let nodeIDs = Self.messages.indices.map { "bubble-preview-node-\($0)" }
        let conversation = Conversation(id: Self.conversationID, title: "Bubble page preview",
                                        createTime: firstTime, updateTime: firstTime.addingTimeInterval(180),
                                        currentNodeId: try XCTUnwrap(nodeIDs.last), provider: "api", profileId: profile.id)
        conversation.nodeCount = Self.messages.count
        conversation.memoryEnabled = false
        context.insert(conversation)
        for (index, message) in Self.messages.enumerated() {
            context.insert(MessageNode(id: nodeIDs[index], role: message.role, content: message.text,
                                       contentType: "text", createTime: firstTime.addingTimeInterval(Double(index) * 60),
                                       parentId: index == 0 ? nil : nodeIDs[index - 1],
                                       childrenIds: index + 1 == nodeIDs.count ? [] : [nodeIDs[index + 1]],
                                       conversationId: conversation.id, profileId: profile.id))
        }
        try context.save()

        try await waitUntil("等待 XCTest 宿主的前台 UIWindowScene") {
            UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene && $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        // 不在别的尺寸设备上伪造 393pt 离屏窗口，也不覆盖 safeAreaInsets。
        XCTAssertEqual(scene.screen.bounds.size, CGSize(width: 393, height: 852))
        XCTAssertEqual(scene.screen.scale, 3)
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        let testScene = MemoryPalaceIOSTestScene.shared
        defer {
            testScene.content = AnyView(Color.clear)
            PerfHarness.modelContext = nil
        }

        var previews: [Data] = []
        var inputFrames: [String: CGRect] = [:]
        let variants: [(String, ColorScheme, Bool)] = [
            ("light", .light, true), ("dark", .dark, true),
            ("article-light", .light, false), ("article-dark", .dark, false)
        ]
        for (name, scheme, bubbleMode) in variants {
            // 模式是对话自己的：每轮改这条对话的 displayMode（同一个库，ContentView 每轮新建）
            conversation.mode = bubbleMode ? .bubble : .article
            try context.save()
            defaults.set(!bubbleMode, forKey: "hideRoleName")
            // 主题只有一套：气泡对拍用 iMessage 主题，文章对拍用宫殿默认（同 T7 时的观感）
            theme.selectTheme(id: bubbleMode ? AppThemeDefinition.iMessageTheme.id : AppThemeDefinition.defaultTheme.id)
            // 同一真实管理器 API + UIKit trait + SwiftUI 环境一同切换；不复制任何主题色。
            theme.themeMode = scheme == .light ? .light : .dark
            theme.syncSystemColorScheme(scheme)
            window.overrideUserInterfaceStyle = scheme == .light ? .light : .dark
            let content = ContentView()
                .modelContainer(container)
                .environment(profiles)
                .environment(presets)
                .environment(providers)
                .environment(theme)
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
            // 两种外观分别新建页面，不把切色过渡帧当成静态几何样本。
            let previousViewModel = PerfHarness.viewModel
            testScene.content = AnyView(content.id(name))

            // 由 ContentView.onAppear 的 probe 入口走真实 loadConversation；测试不直接塞 currentPath。
            try await waitUntil("等待真实会话、四条消息和输入栏挂载（\(name)）") {
                window.layoutIfNeeded()
                guard let vm = PerfHarness.viewModel, vm !== previousViewModel,
                      vm.selectedConversation?.id == Self.conversationID,
                      vm.currentPath.map(\.id) == nodeIDs, !vm.isLoading,
                      let input = self.inputField(in: window), input.window === window,
                      input.bounds.width > 0, input.bounds.height > 0,
                      let paging = PerfHarness.paging, paging.view.window === window else { return false }
                return !input.isFirstResponder && self.keyboardGuide(around: input) != nil
            }
            let vm = try XCTUnwrap(PerfHarness.viewModel)
            XCTAssertEqual(vm.isBubbleMode, bubbleMode)
            XCTAssertEqual(theme.isBubbleModeActive, bubbleMode, "聊天页配色跟着对话自己的模式")
            XCTAssertEqual(vm.currentPath.map(\.content), Self.messages.map(\.text))
            XCTAssertEqual(vm.currentPath.map(\.role), Self.messages.map(\.role))
            XCTAssertEqual(theme.activeScheme, scheme)
            XCTAssertEqual(window.traitCollection.userInterfaceStyle, scheme == .light ? .light : .dark)

            let requiredTexts = Self.messages.map(\.text) + ["Jane Doe",
                bubbleMode ? "Jan 15 12:00 PM" : ChatTimeDivider.label(firstTime)]
                + (bubbleMode ? [] : ["You"])
            var captured = false
            defer {
                if !captured {
                    _ = try? capture(window: window, to: output.appendingPathComponent("failure-\(name).png"))
                }
            }
            let inputFrame = try await stableInput(window: window, reason: "等待原生输入栏与正文布局稳定（\(name)）") {
                PerfHarness.markdownPending == 0
            }
            if bubbleMode {
                inputFrames[name] = inputFrame
            } else {
                let reference = try XCTUnwrap(inputFrames[String(name.dropFirst("article-".count))])
                XCTAssertEqual(inputFrame.minX, reference.minX, accuracy: 0.5, "两种模式输入框左边必须一致")
                XCTAssertEqual(inputFrame.minY, reference.minY, accuracy: 0.5, "两种模式输入框位置必须一致")
                XCTAssertEqual(inputFrame.width, reference.width, accuracy: 0.5, "两种模式输入框宽度必须一致")
                XCTAssertEqual(inputFrame.height, reference.height, accuracy: 0.5, "两种模式输入框高度必须一致")
            }
            let snapshot = try capture(window: window, to: output.appendingPathComponent("preview-\(name).png"))
            let evidence = try recognizedText(in: snapshot.pixels, size: window.bounds.size)
            print("[气泡整页截图] OCR：\(evidence.map(\.text))")
            try JSONEncoder().encode(evidence).write(to: output.appendingPathComponent("preview-\(name)-text.json"), options: .atomic)
            try assertPage(window: window, requiredTexts: requiredTexts, evidence: evidence, bubbleMode: bubbleMode)
            previews.append(snapshot.png)
            captured = true
            if name == "dark" {
                try await assertKeyboardFollow(window: window, output: output, beforeText: evidence)
                try await captureFadeAndSecondDivider(window: window, output: output, context: context,
                                                      original: conversation, viewModel: vm, time: firstTime)
            }
            if bubbleMode {
                try await assertTurnStatus(window: window, output: output, variant: name, container: container,
                                           original: conversation, viewModel: vm, profiles: profiles,
                                           presets: presets, providers: providers)
            }
            // 10-29 反馈截图（只在指定目录时跑；跑完挂起等外面用 mobai 点「+」/ 表情键盘 / 头像 zoom）
            if bubbleMode, name == "light", let dir = env["MP_FEEDBACK_SHOTS_DIR"], dir.hasPrefix("/") {
                try await captureFeedback1029(window: window, output: URL(fileURLWithPath: dir, isDirectory: true),
                                              container: container, original: conversation, viewModel: vm,
                                              profile: profile, providers: providers)
            }
        }
        XCTAssertNotEqual(previews[0], previews[1], "浅深主题不应输出同一张图")
        let router = SettingsSearchRouter.shared
        router.request(anchor: "leaf-appear-timestamp")
        testScene.content = AnyView(NavigationStack {
            AppearancePage()
                .environment(theme)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
        })
        defer { router.request(anchor: nil); router.clearFlash() }
        try await waitUntil("等待设置页沿生产搜索锚点滚到气泡对话") {
            router.flashingAnchor == "leaf-appear-timestamp"
        }
        // 生产锚点滚动动画为0.3s；等它结束后移除仅用于导航的闪光。
        try await Task.sleep(for: .milliseconds(350))
        router.clearFlash()
        let appearance = try capture(window: window, to: output.appendingPathComponent("appearance-chat-style-dark.png"))
        let appearanceText = try recognizedText(in: appearance.pixels, size: window.bounds.size)
        // 全局「显示方式」已删：外观页是「气泡对话」「文章对话」两块
        for text in ["气泡对话", "显示时间戳", "气泡圆角", "文章对话"] {
            XCTAssertTrue(appearanceText.contains { $0.key.contains(Self.textKey(text)) }, "外观实图缺少\(text)")
        }
        XCTAssertFalse(appearanceText.contains { $0.key.contains(Self.textKey("显示方式")) }, "全局显示方式开关还在")
        for text in ["显示头像", "显示昵称"] {
            XCTAssertFalse(appearanceText.contains { $0.key.contains(Self.textKey(text)) }, "退役开关仍出现在真实设置页")
        }
        try await assertPopControls(window: window, output: output, container: container,
                                    profileId: profile.id, conversationID: conversation.id)
        try await assertThemePages(window: window, output: output, theme: theme)
    }

    /// 共存第一步：主题库不再有「主题应用到」分段；颜色页有「气泡模式」一节，五行默认「跟随上面」
    private func assertThemePages(window: UIWindow, output: URL, theme: ThemeManager) async throws {
        let testScene = MemoryPalaceIOSTestScene.shared
        theme.themeMode = .light
        theme.syncSystemColorScheme(.light)
        window.overrideUserInterfaceStyle = .light
        testScene.content = AnyView(NavigationStack { ThemeLibraryPage().environment(theme) }
            .environment(\.colorScheme, .light))
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        let library = try capture(window: window, to: output.appendingPathComponent("theme-library-light.png"))
        let libraryText = try recognizedText(in: library.pixels, size: window.bounds.size)
        XCTAssertTrue(libraryText.contains { $0.key.contains("iMessage") }, "主题库里应列出 iMessage")
        for gone in ["主题应用到", "文章模式", "气泡模式"] {
            XCTAssertFalse(libraryText.contains { $0.key.contains(Self.textKey(gone)) }, "主题库还有分段：\(gone)")
        }

        // custom 是唯一不内置的种子主题，进页不弹「复制一份」
        testScene.content = AnyView(NavigationStack { ThemeColorsPage(themeId: AppThemeDefinition.customTheme.id).environment(theme) }
            .environment(\.colorScheme, .light))
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(Self.scrollViews(in: window).max { $0.contentSize.height < $1.contentSize.height },
                                   "颜色页找不到滚动视图")
        var found: [TextEvidence] = []
        var shot: Snapshot?
        var offset: CGFloat = 0
        while offset <= scroll.contentSize.height {
            scroll.setContentOffset(CGPoint(x: 0, y: min(offset, max(0, scroll.contentSize.height - scroll.bounds.height
                                                                        + scroll.adjustedContentInset.bottom))), animated: false)
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let candidate = try capture(window: window, to: output.appendingPathComponent("theme-colors-bubble-section-light.png"))
            let text = try recognizedText(in: candidate.pixels, size: window.bounds.size)
            if text.filter({ $0.key.contains(Self.textKey("跟随上面")) }).count >= 5,
               text.contains(where: { $0.key == Self.textKey("气泡模式") }) {
                found = text
                shot = candidate
                break
            }
            offset += 80
        }
        XCTAssertNotNil(shot, "颜色页没找到「气泡模式」一节（五行都显示跟随上面）")
        for row in ["你的气泡底", "你的气泡渐变", "你的文字"] {
            XCTAssertTrue(found.contains { $0.key.contains(Self.textKey(row)) }, "气泡模式一节缺少「\(row)」")
        }
        // Vision 常把「AI」认成「Al」：AI 两行只核汉字部分且不带「你的」
        for row in ["气泡底", "文字"] {
            XCTAssertTrue(found.contains { $0.key.hasSuffix(row) && $0.key.count > row.count && !$0.key.contains("你的") },
                          "气泡模式一节缺少「AI \(row)」")
        }
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func assertTurnStatus(window: UIWindow, output: URL, variant: String, container: ModelContainer,
                                  original: Conversation, viewModel: ConversationViewModel, profiles: ProfileManager,
                                  presets: PresetManager, providers: ProviderManager) async throws {
        let defaults = UserDefaults.standard
        let permissionKeys = [PermissionDomain.toolsMaster.storageKey, PermissionDomain.fileLibrary.storageKey]
        let savedPermissions = permissionKeys.map { defaults.object(forKey: $0) as? Int }
        defaults.set(PermissionLevel.bypass.rawValue, forKey: permissionKeys[0])
        defaults.set(PermissionLevel.notAllowed.rawValue, forKey: permissionKeys[1])
        let thinking = defaults.string(forKey: DisclosureKind.thinking.key)
        defaults.set(DisclosureMode.inline.rawValue, forKey: DisclosureKind.thinking.key)
        let tts = defaults.object(forKey: "ttsEnabled") as? Bool
        defaults.set(false, forKey: "ttsEnabled")
        let budgetEnabled = GlobalBudgetStore.shared.enabled
        GlobalBudgetStore.shared.setEnabled(false)
        defer {
            for (key, value) in zip(permissionKeys, savedPermissions) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            if let thinking { defaults.set(thinking, forKey: DisclosureKind.thinking.key) }
            else { defaults.removeObject(forKey: DisclosureKind.thinking.key) }
            if let tts { defaults.set(tts, forKey: "ttsEnabled") } else { defaults.removeObject(forKey: "ttsEnabled") }
            GlobalBudgetStore.shared.setEnabled(budgetEnabled)
        }
        let first = try TurnStatusStreamFixture.reply("拉磨中")
        let next = try TurnStatusStreamFixture.reply("新一轮开炉")
        let continuation = DispatchSemaphore(value: 0)
        defer { continuation.signal() }
        let server = try ScriptedHTTPServer { index, _ in
            if index == 0 { return (200, "text/event-stream", first) }
            if index == 1 {
                _ = continuation.wait(timeout: .now() + 120)
                return (200, "text/event-stream", TurnStatusStreamFixture.finalReply)
            }
            return (200, "text/event-stream", next)
        }
        try server.start()
        defer { server.stop() }
        let credentialId = "bubble-status-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "gpt-4o", name: "本地合成回包")
        providers.addCredential(APICredential(id: credentialId, name: "本地合成回包", emoji: "",
                                              type: .openaiCompatible, baseURL: server.baseURL, models: [model]))
        providers.setApiKey("test-key", for: credentialId)
        defer { providers.removeCredential(id: credentialId) }
        let savedProfile = profiles.currentProfile
        var profile = savedProfile
        profile.assistantName = "Muse"
        profiles.updateProfile(profile)
        defer { profiles.updateProfile(savedProfile) }
        let context = container.mainContext
        let cid = "bubble-status-\(variant)"
        let nodeID = "\(cid)-initial"
        let conversation = Conversation(id: cid, title: "饼干小计划", createTime: Date(), updateTime: Date(),
                                        currentNodeId: nodeID, provider: "api", profileId: profile.id)
        conversation.selectedModelId = model.id
        conversation.memoryEnabled = false
        conversation.nodeCount = 1
        conversation.mode = original.mode
        context.insert(conversation)
        context.insert(MessageNode(id: nodeID, role: "assistant", content: "下午一起做饼干吧，我来挑口味。",
                                   contentType: "text", createTime: Date(), parentId: nil, childrenIds: [],
                                   conversationId: cid, profileId: profile.id))
        try context.save()
        viewModel.loadConversation(conversation, context: context)
        try await waitUntil("等待状态样本真实加载") { !viewModel.isLoading && viewModel.selectedConversation?.id == cid }
        defer { viewModel.cancelAssistantTurn(context: context); viewModel.loadConversation(original, context: context) }
        XCTAssertTrue(viewModel.sendMessage("好呀，帮我选一种不太甜的。", model: model, profile: profile, preset: .balanced,
                                            providerManager: providers, context: context))
        try await waitUntil("等待真实SSE、临时状态和问问题工具") { viewModel.pendingUserQuestion != nil }
        XCTAssertEqual(viewModel.turnStatus(for: cid), "拉磨中")
        XCTAssertNil(PermissionPromptCenter.shared.pendingRequest)
        _ = try await stableInput(window: window, reason: "等待状态胶囊稳定") { PerfHarness.markdownPending == 0 }
        let header = try capture(window: window, to: output.appendingPathComponent("turn-status-\(variant).png"))
        let headerText = try recognizedText(in: header.pixels, size: window.bounds.size)
        XCTAssertTrue(headerText.contains { $0.frame.maxY < 180 && $0.text.contains("拉磨中") }, "顶栏必须显示模型本轮写出的短句")
        XCTAssertTrue(headerText.contains { $0.frame.maxY < 180 && $0.text.contains("问问题") }, "顶栏必须显示具体工具")
        try JSONEncoder().encode(headerText).write(to: output.appendingPathComponent("turn-status-\(variant)-text.json"), options: .atomic)

        // 先沿生产关闭入口收起问问题卡；续轮网络挂起，避免两个 sheet 抢同一个 presenter。
        viewModel.dismissActiveAskCard()
        try await waitUntil("等待问问题卡收起并进入续轮") {
            window.rootViewController?.presentedViewController == nil && server.requestBodies.count == 2
        }

        let details = BubbleTurnDetails(conversationId: cid, profileId: profile.id, turnID: viewModel.currentTurnID,
                                        content: .init(node: viewModel.currentTurnNode(for: cid)), bridgePhase: nil)
        let sheet = UIHostingController(rootView: BubbleTurnSheet(viewModel: viewModel, details: details)
            .modelContainer(container).environment(profiles).environment(presets).environment(providers).environment(ThemeManager.shared))
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        let presenter = try XCTUnwrap(window.rootViewController)
        presenter.present(sheet, animated: false)
        defer { sheet.dismiss(animated: false) }
        try await waitUntil("等待真实本轮过程page sheet") {
            sheet.view.window === window && !sheet.isBeingPresented && PerfHarness.markdownPending == 0
        }
        let process = try capture(window: window, to: output.appendingPathComponent("turn-sheet-\(variant).png"))
        let processText = try recognizedText(in: process.pixels, size: window.bounds.size)
        for text in ["本轮过程", "先确认口味", "本轮状态"] {
            XCTAssertTrue(processText.contains { $0.key.contains(Self.textKey(text)) }, "本轮过程实图缺少\(text)")
        }
        viewModel.cancelAssistantTurn(context: context)
        continuation.signal()
        XCTAssertNil(viewModel.turnStatus(for: cid))
        XCTAssertTrue(viewModel.sendMessage("再挑一次。", model: model, profile: profile, preset: .balanced,
                                            providerManager: providers, context: context))
        try await waitUntil("等待下一轮，验证旧sheet不串轮") { viewModel.pendingUserQuestion != nil }
        XCTAssertEqual(viewModel.turnStatus(for: cid), "新一轮开炉")
        try await waitUntil("等待已结束轮次的sheet稳定") {
            sheet.view.window === window && PerfHarness.markdownPending == 0
        }
        let retained = try capture(window: window, to: output.appendingPathComponent("turn-sheet-retained-\(variant).png"))
        let retainedText = try recognizedText(in: retained.pixels, size: window.bounds.size)
        XCTAssertTrue(retainedText.contains { $0.key.contains("先确认口味") }, "旧轮次结束后仍能查看其过程")
        XCTAssertFalse(retainedText.contains { $0.text.contains("新一轮开炉") }, "旧sheet不能显示新一轮状态")
        viewModel.cancelAssistantTurn(context: context)
        sheet.dismiss(animated: false)
        viewModel.loadConversation(original, context: context)
        try await waitUntil("恢复整屏对拍原始会话") {
            !viewModel.isLoading && viewModel.currentPath.map(\.content) == Self.messages.map(\.text)
        }
    }

    private func captureFeedback1029(window: UIWindow, output: URL, container: ModelContainer, original: Conversation,
                                     viewModel: ConversationViewModel, profile: Profile, providers: ProviderManager) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // 上一段（本轮过程 sheet + 问问题卡）可能还叠着没收干净：从最上层一层层收掉
        while let top = Self.topPresented(window.rootViewController) {
            top.dismiss(animated: false)
            try await Task.sleep(for: .milliseconds(200))
        }
        let defaults = UserDefaults.standard
        let thinking = defaults.string(forKey: DisclosureKind.thinking.key)
        defaults.set(DisclosureMode.inline.rawValue, forKey: DisclosureKind.thinking.key)
        let budgetEnabled = GlobalBudgetStore.shared.enabled
        GlobalBudgetStore.shared.setEnabled(false)
        defer {
            if let thinking { defaults.set(thinking, forKey: DisclosureKind.thinking.key) }
            else { defaults.removeObject(forKey: DisclosureKind.thinking.key) }
            GlobalBudgetStore.shared.setEnabled(budgetEnabled)
        }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reply = Data("data: {\"choices\":[{\"delta\":{\"content\":\"七点吧，天黑前回来。\"}}]}\n\ndata: [DONE]\n\n".utf8)
        let server = try ScriptedHTTPServer { _, _ in
            _ = release.wait(timeout: .now() + 120)
            return (200, "text/event-stream", reply)
        }
        try server.start()
        defer { server.stop() }
        let credentialId = "fb1029-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "gpt-4o", name: "本地合成回包")
        providers.addCredential(APICredential(id: credentialId, name: "本地合成回包", emoji: "", type: .openaiCompatible,
                                              baseURL: server.baseURL, models: [model], toolsSupported: false))
        providers.setApiKey("test-key", for: credentialId)
        defer { providers.removeCredential(id: credentialId) }

        let context = container.mainContext
        let cid = "fb1029-conv"
        let base = Date().addingTimeInterval(-600)
        let rows: [(String, String, String?)] = [("user", "晚上出去走走？", nil),
                                                 ("assistant", "去河边吧，近一点，也能躲一躲雨。", "想一条不赶时间的路线"),
                                                 ("user", "好呀，我先去换鞋", nil)]
        let ids = rows.indices.map { "\(cid)-\($0)" }
        let conversation = Conversation(id: cid, title: "散步", createTime: base, updateTime: base,
                                        currentNodeId: ids.last!, provider: "api", profileId: profile.id)
        conversation.selectedModelId = model.id
        conversation.memoryEnabled = false
        conversation.nodeCount = rows.count
        conversation.mode = .bubble
        context.insert(conversation)
        var nodes: [MessageNode] = []
        for (i, row) in rows.enumerated() {
            let node = MessageNode(id: ids[i], role: row.0, content: row.1, contentType: "text",
                                   createTime: base.addingTimeInterval(Double(i) * 30), parentId: i == 0 ? nil : ids[i - 1],
                                   childrenIds: i + 1 == ids.count ? [] : [ids[i + 1]], conversationId: cid, profileId: profile.id)
            node.ccThinking = row.2
            context.insert(node)
            nodes.append(node)
        }
        try context.save()
        // AI 贴在她第二条上（灰胶囊），她给 AI 那条点了 ❤️（白胶囊）
        let store = ChatReactionStore.shared
        store.addAIReaction("👍", on: ids[2])
        let suite = UserDefaults(suiteName: "fb1029-outbox-\(UUID().uuidString)")!
        store.toggle("❤️", on: ChatReactionTarget(node: nodes[1], blockIndex: 0, blockText: rows[1].1),
                     outbox: ChatCardEventOutbox(defaults: suite), trigger: nil)

        viewModel.loadConversation(conversation, context: context)
        try await waitUntil("等待 10-29 样本加载") { !viewModel.isLoading && viewModel.selectedConversation?.id == cid }
        defer { viewModel.cancelAssistantTurn(context: context); viewModel.loadConversation(original, context: context) }
        _ = try await stableInput(window: window, reason: "等待样本稳定") { PerfHarness.markdownPending == 0 }
        _ = try capture(window: window, to: output.appendingPathComponent("1-thinking-bubble-6-ai-reaction.png"))

        XCTAssertTrue(viewModel.sendMessage("那我们几点出发？", model: model, profile: profile, preset: .balanced,
                                            providerManager: providers, context: context))
        try await waitUntil("等待进入等待态") { viewModel.assistantTurnInFlight && server.requestBodies.count == 1 }
        try await Task.sleep(for: .milliseconds(1500))
        let waiting = try capture(window: window, to: output.appendingPathComponent("2-waiting.png"))
        let texts = try recognizedText(in: waiting.pixels, size: window.bounds.size)
        try JSONEncoder().encode(texts).write(to: output.appendingPathComponent("2-waiting-text.json"), options: .atomic)
        XCTAssertFalse(texts.contains { $0.text.contains("正在思考") }, "顶栏换成轮换文案，不再写死「正在思考…」")
        release.signal()
        try await waitUntil("等待回复落地") { !viewModel.assistantTurnInFlight }

        // 挂起：外面用 mobai 真点「+」菜单 / 长按出表情条点「+」/ 点头像看 zoom，写 .release 收工
        let hold = output.appendingPathComponent(".holding")
        let done = output.appendingPathComponent(".release")
        try? FileManager.default.removeItem(at: done)
        try Data().write(to: hold)
        let deadline = Date().addingTimeInterval(1200)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }
        try? FileManager.default.removeItem(at: hold)
        try? FileManager.default.removeItem(at: done)
    }

    private static func topPresented(_ root: UIViewController?) -> UIViewController? {
        var top = root?.presentedViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private func stableInput(window: UIWindow, reason: String, when ready: () -> Bool) async throws -> CGRect {
        var last: CGRect?
        var stablePasses = 0
        try await waitUntil(reason) {
            window.layoutIfNeeded()
            guard let input = self.inputField(in: window), ready() else {
                stablePasses = 0
                return false
            }
            let frame = input.convert(input.bounds, to: window)
            stablePasses = frame == last ? stablePasses + 1 : 0
            last = frame
            return stablePasses >= 3
        }
        return try XCTUnwrap(last)
    }

    private struct KeyboardEvidence: Encodable {
        let beforeInput, keyboardInput, multilineInput, restoredInput: CGRect
        let keyboardTop, extra, naturalLineHeight: CGFloat
        let beforeMessage, keyboardMessage, restoredMessage: CGRect
    }

    private func assertKeyboardFollow(window: UIWindow, output: URL, beforeText: [TextEvidence]) async throws {
        let input = try XCTUnwrap(inputField(in: window))
        let guide = try XCTUnwrap(keyboardGuide(around: input))
        let guideOwner = try XCTUnwrap(guide.owningView)
        let bridge = KeyboardInsetBridge.shared
        let before = input.convert(input.bounds, to: window)
        let beforeMessage = try XCTUnwrap(beforeText.first { $0.key == "Thankyou" }).frame
        let dismissDeadline = bridge.sendDismissUntil
        XCTAssertTrue(input.becomeFirstResponder())
        defer { input.resignFirstResponder() }
        let raised = try await stableInput(window: window, reason: "等待真实键盘与输入栏落稳") {
            input.isFirstResponder && bridge.kbVisible && bridge.extra > 0 && !bridge.kbTransitioning
        }
        let keyboardTop = guideOwner.convert(guide.layoutFrame, to: window).minY
        let extra = bridge.extra
        XCTAssertEqual(raised.height, before.height, accuracy: 1)
        XCTAssertLessThanOrEqual(raised.maxY, keyboardTop, "输入框不能压住真实键盘")
        let raisedShot = try capture(window: window, to: output.appendingPathComponent("keyboard-dark.png"))
        let raisedText = try recognizedText(in: raisedShot.pixels, size: window.bounds.size)
        let raisedMessage = try XCTUnwrap(raisedText.first { $0.key == "Thankyou" }).frame
        XCTAssertLessThan(raisedMessage.maxY, raised.minY, "末条消息不能被输入栏遮住")

        let lineHeight = try XCTUnwrap(input.font).lineHeight
        input.insertText("First line\nSecond line\nThird line")
        let grown = try await stableInput(window: window, reason: "等待三行原生输入与列表避让同步") {
            input.text == "First line\nSecond line\nThird line" && input.bounds.height > raised.height + lineHeight
        }
        let caret = input.caretRect(for: input.endOfDocument)
        XCTAssertTrue(input.bounds.contains(caret), "第三行光标不能被原生输入框裁切")
        let multilineShot = try capture(window: window, to: output.appendingPathComponent("keyboard-multiline-dark.png"))
        let multilineText = try recognizedText(in: multilineShot.pixels, size: window.bounds.size)
        for key in ["Firstline", "Secondline", "Thirdline"] {
            XCTAssertNotNil(multilineText.first { $0.key == key }, "多行输入必须完整显示：\(key)")
        }
        try JSONEncoder().encode(multilineText).write(to: output.appendingPathComponent("keyboard-multiline-dark-text.json"))
        input.selectedRange = NSRange(location: 0, length: input.text.utf16.count)
        input.insertText("")
        _ = try await stableInput(window: window, reason: "等待清空后恢复单行输入") {
            input.text.isEmpty && abs(input.bounds.height - raised.height) < 1
        }
        XCTAssertTrue(input.resignFirstResponder())
        let restored = try await stableInput(window: window, reason: "等待收键盘、列表释放与输入栏复位") {
            !input.isFirstResponder && !bridge.kbVisible && !bridge.kbTransitioning && bridge.extra == 0
        }
        XCTAssertEqual(restored.minY, before.minY, accuracy: 1)
        XCTAssertEqual(restored.height, before.height, accuracy: 1)
        XCTAssertEqual(bridge.sendDismissUntil, dismissDeadline, "普通焦点操作不能改发送收键盘握手")
        let restoredShot = try capture(window: window, to: output.appendingPathComponent("keyboard-restored-dark.png"))
        let restoredText = try recognizedText(in: restoredShot.pixels, size: window.bounds.size)
        let restoredMessage = try XCTUnwrap(restoredText.first { $0.key == "Thankyou" }).frame
        XCTAssertEqual(restoredMessage.minY, beforeMessage.minY, accuracy: 1, "收键盘不能遗留列表偏移")
        let evidence = KeyboardEvidence(beforeInput: before, keyboardInput: raised, multilineInput: grown,
                                        restoredInput: restored, keyboardTop: keyboardTop, extra: extra,
                                        naturalLineHeight: lineHeight, beforeMessage: beforeMessage,
                                        keyboardMessage: raisedMessage, restoredMessage: restoredMessage)
        try JSONEncoder().encode(evidence).write(to: output.appendingPathComponent("keyboard-evidence.json"), options: .atomic)
        print("[键盘实测] top=\(keyboardTop)，extra=\(extra)，输入 \(before) → \(raised) → \(grown) → \(restored)")
    }

    private func captureFadeAndSecondDivider(window: UIWindow, output: URL, context: ModelContext,
                                            original: Conversation, viewModel: ConversationViewModel, time: Date) async throws {
        let id = "bubble-fade-probe"
        let ids = (0..<20).map { "\(id)-\($0)" }
        let conversation = Conversation(id: id, title: "渐隐与时间分隔对拍", createTime: time, updateTime: time,
                                        currentNodeId: try XCTUnwrap(ids.last), provider: "api", profileId: original.profileId)
        conversation.memoryEnabled = false
        conversation.mode = original.mode
        context.insert(conversation)
        let probeText = "M" + String(repeating: "\u{00a0}", count: 40) + "M"
        for index in ids.indices {
            context.insert(MessageNode(id: ids[index], role: "assistant", content: probeText,
                                       contentType: "text", createTime: time.addingTimeInterval(Double(index * 60 + (index >= 14 ? 14400 : 0))),
                                       parentId: index == 0 ? nil : ids[index - 1],
                                       childrenIds: index + 1 == ids.count ? [] : [ids[index + 1]],
                                       conversationId: id, profileId: original.profileId))
        }
        try context.save()
        viewModel.loadConversation(conversation, context: context)
        _ = try await stableInput(window: window, reason: "等待真实长列表覆盖顶栏渐隐区") {
            !viewModel.isLoading && viewModel.currentPath.map(\.id) == ids && PerfHarness.markdownPending == 0
        }
        let shot = try capture(window: window, to: output.appendingPathComponent("fade-and-divider-dark.png"))
        let text = try recognizedText(in: shot.pixels, size: window.bounds.size)
        let label = Self.textKey("Jan 15 4:14 PM")
        XCTAssertTrue(text.contains { $0.key == label && $0.frame.minY > 180 && $0.frame.maxY < 700 },
                      "第二条时间分隔必须真实出现在两组消息之间")
        try JSONEncoder().encode(text).write(to: output.appendingPathComponent("fade-and-divider-dark-text.json"), options: .atomic)
        viewModel.loadConversation(original, context: context)
        try await waitUntil("恢复原始四句样本，避免干扰文章对拍") {
            !viewModel.isLoading && viewModel.currentPath.map(\.content) == Self.messages.map(\.text)
        }
    }

    private func assertPopControls(window: UIWindow, output: URL, container: ModelContainer,
                                   profileId: String, conversationID: String) async throws {
        let defaults = UserDefaults.standard
        let scene = MemoryPalaceIOSTestScene.shared
        let theme = ThemeManager.shared
        var mounted = false
        scene.content = AnyView(NavigationStack {
            BubblePopTunerPage().onAppear { mounted = true }
        }.environment(theme).preferredColorScheme(.dark))
        try await waitUntil("等待真实弹泡调音台挂载") { mounted }
        try await Task.sleep(for: .milliseconds(100))
        let tuner = try capture(window: window, to: output.appendingPathComponent("pop-tuner-disabled-dark.png"))
        let tunerText = try recognizedText(in: tuner.pixels, size: window.bounds.size)
        for text in ["启用弹泡", "我先弹一个", "然后我发的"] {
            XCTAssertTrue(tunerText.contains { $0.key.contains(Self.textKey(text)) }, "关闭弹泡的调音台实图缺少\(text)")
        }

        let labels = ["First completed block.", "Second completed block.", "Final completed block."]
        let node = MessageNode(id: "pop-reveal-smoke", role: "assistant",
                               content: labels.map { String(repeating: $0 + " ", count: 8) }.joined(separator: "\n\n"),
                               contentType: "text", createTime: nil, parentId: nil, childrenIds: [],
                               conversationId: conversationID, profileId: profileId)
        container.mainContext.insert(node)
        mounted = false
        var finished = false
        defaults.set(true, forKey: BubblePopTuning.enabledKey)
        scene.content = AnyView(
            BubbleModeRow(node: node, isUser: false, entrancePending: true,
                          onEntranceDone: { finished = true }, selectedFont: "", fontScale: 17.0 / 13.5,
                          lineSpacingScale: 0, paragraphSpacingScale: 1.65, regexScripts: [],
                          bubbleCornerRadius: 20, bubblePaddingH: 14, bubblePaddingV: 10,
                          userName: "You", assistantName: "Jane Doe")
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.mainBg)
                .environment(theme)
                .modelContainer(container)
                .preferredColorScheme(.dark)
                .onAppear { mounted = true }
        )
        try await waitUntil("等待真实气泡行进入CC reveal前奏") { mounted }
        try await Task.sleep(for: .milliseconds(50))
        let before = try capture(window: window, to: output.appendingPathComponent("pop-reveal-enabled-dark.png"))
        let beforeText = try recognizedText(in: before.pixels, size: window.bounds.size)
        XCTAssertFalse(beforeText.contains { $0.key.contains(Self.textKey(labels[0])) }, "启用时应先显示原有dots前奏")
        XCTAssertFalse(finished)
        let start = ContinuousClock.now
        defaults.set(false, forKey: BubblePopTuning.enabledKey)
        try await waitUntil("关闭总开关应取消队列并立即显示完整消息") { finished }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1), "不能等原来三段各0.7s的队列自然结束")
        let after = try capture(window: window, to: output.appendingPathComponent("pop-reveal-disabled-dark.png"))
        let afterText = try recognizedText(in: after.pixels, size: window.bounds.size)
        try JSONEncoder().encode(afterText).write(to: output.appendingPathComponent("pop-reveal-disabled-dark-text.json"), options: .atomic)
        for label in labels {
            XCTAssertTrue(afterText.contains { $0.key.contains(Self.textKey(label)) }, "关闭弹泡不能截断正文：\(label)")
        }
    }

    private func assertPage(window: UIWindow, requiredTexts: [String], evidence: [TextEvidence], bubbleMode: Bool) throws {
        try require(window.isKeyWindow, "截图对象必须是场景真实 key window")
        XCTAssertEqual(window.bounds.size, CGSize(width: 393, height: 852))
        XCTAssertEqual(window.traitCollection.displayScale, 3)
        XCTAssertEqual(window.safeAreaInsets.top, 59, accuracy: 0.01)
        XCTAssertEqual(window.safeAreaInsets.bottom, 34, accuracy: 0.01)
        let input = try XCTUnwrap(inputField(in: window))
        XCTAssertEqual(try XCTUnwrap(input.font).pointSize, 17, accuracy: 0.01)
        XCTAssertEqual(input.text, "")
        XCTAssertFalse(input.isFirstResponder)
        let inputFrame = input.convert(input.bounds, to: window)
        XCTAssertGreaterThan(inputFrame.minY, window.bounds.midY)
        XCTAssertNotNil(keyboardGuide(around: input), "必须是生产 keyboardLayoutGuide 挂载的输入栏")
        for text in requiredTexts {
            let key = Self.textKey(text)
            XCTAssertTrue(evidence.contains { $0.key.contains(key) }, "实际PNG缺少文字：\(text)")
        }
        if bubbleMode {
            // 气泡顶栏的昵称必须实际可见；文章顶栏沿用原来的无头像布局。
            XCTAssertTrue(evidence.contains { $0.key.contains("JaneDoe") && $0.frame.maxY < window.bounds.midY },
                          "顶栏昵称没有实际挂载到可见上半屏")
        }
        let rowNames = evidence.filter { $0.key.contains("JaneDoe") && $0.frame.minY > 180 }
        XCTAssertEqual(rowNames.count, bubbleMode ? 0 : 3, "气泡不显示行昵称；文章保留三条助手署名")
    }

    private struct Snapshot {
        let png: Data
        let pixels: CGImage
    }

    private func capture(window: UIWindow, to url: URL) throws -> Snapshot {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size, format: format)
        var drawn = false
        let image = renderer.image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try require(drawn, "真实窗口 drawHierarchy 失败")
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: url, options: .atomic)
        // 必须从磁盘重新解码 PNG；不能只断言 Data 非空或 UIImage 的逻辑尺寸。
        let decoded = try XCTUnwrap(UIImage(data: Data(contentsOf: url)))
        let pixels = try XCTUnwrap(decoded.cgImage)
        XCTAssertEqual(pixels.width, 1179)
        XCTAssertEqual(pixels.height, 2556)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = url.lastPathComponent
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[气泡整页截图] 已写入：\(url.path)，\(pixels.width)×\(pixels.height)")
        return Snapshot(png: data, pixels: pixels)
    }

    private func syntheticAvatar() throws -> Data {
        // 合成头像只在内存绘制；不是页面截图拼图，也不读取用户照片或文件。
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96))
        return try XCTUnwrap(renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 34, y: 17, width: 28, height: 28)).fill()
            UIBezierPath(ovalIn: CGRect(x: 18, y: 51, width: 60, height: 55)).fill()
        }.pngData())
    }

    private func inputField(in view: UIView) -> ChatInputTextView? {
        if let input = view as? ChatInputTextView, input.accessibilityIdentifier == "chat-input-field" { return input }
        for child in view.subviews {
            if let input = inputField(in: child) { return input }
        }
        return nil
    }

    private func keyboardGuide(around input: UIView) -> UIKeyboardLayoutGuide? {
        var ancestor: UIView? = input
        while let view = ancestor {
            for constraint in view.constraints where constraint.isActive
                && constraint.firstAttribute == .bottom && constraint.secondAttribute == .top {
                if let guide = constraint.secondItem as? UIKeyboardLayoutGuide { return guide }
            }
            ancestor = view.superview
        }
        return nil
    }

    private struct TextEvidence: Encodable {
        let text: String
        let key: String
        let frame: CGRect
    }

    // 普通 XCTest 不启用 SwiftUI AX 树；直接验证截图墨迹，按钮轮廓由S7像素脚本及实图验收。
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

    private func waitUntil(_ reason: String, timeout: TimeInterval = 15,
                           condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            // 让实际 UIKit/SwiftUI 布局及异步 loadConversation 推进；不是定时盲截。
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail(reason)
        throw SnapshotFailure.failed(reason)
    }

    private func require(_ condition: Bool, _ reason: String) throws {
        guard condition else {
            XCTFail(reason)
            throw SnapshotFailure.failed(reason)
        }
    }

    private enum SnapshotFailure: Error {
        case failed(String)
    }
    #else
    func testLightAndDarkPreviews() throws {
        XCTFail("整页快照依赖 Debug 的真实 loadConversation / PerfHarness 探针，请使用 Debug 测试配置")
    }
    #endif
}
