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
            "chatBubbleMode": true, "showAvatar": true, "hideRoleName": true,
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
        theme.selectTheme(id: AppThemeDefinition.defaultTheme.id)

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
            defaults.set(bubbleMode, forKey: "chatBubbleMode")
            defaults.set(!bubbleMode, forKey: "hideRoleName")
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
            XCTAssertEqual(vm.currentPath.map(\.content), Self.messages.map(\.text))
            XCTAssertEqual(vm.currentPath.map(\.role), Self.messages.map(\.role))
            XCTAssertEqual(theme.activeScheme, scheme)
            XCTAssertEqual(window.traitCollection.userInterfaceStyle, scheme == .light ? .light : .dark)

            let requiredTexts = Self.messages.map(\.text) + ["Jane Doe", ChatTimeDivider.label(firstTime)]
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
        }
        XCTAssertNotEqual(previews[0], previews[1], "浅深主题不应输出同一张图")
        defaults.set(true, forKey: "chatBubbleMode")
        let router = SettingsSearchRouter.shared
        router.request(anchor: "leaf-appear-bubblemode")
        testScene.content = AnyView(NavigationStack {
            AppearancePage()
                .environment(theme)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
        })
        defer { router.request(anchor: nil); router.clearFlash() }
        try await waitUntil("等待设置页沿生产搜索锚点滚到聊天样式") {
            router.flashingAnchor == "leaf-appear-bubblemode"
        }
        // 生产锚点滚动动画为0.3s；等它结束后移除仅用于导航的闪光。
        try await Task.sleep(for: .milliseconds(350))
        router.clearFlash()
        let appearance = try capture(window: window, to: output.appendingPathComponent("appearance-chat-style-dark.png"))
        let appearanceText = try recognizedText(in: appearance.pixels, size: window.bounds.size)
        for text in ["文章", "气泡", "显示时间戳"] {
            XCTAssertTrue(appearanceText.contains { $0.key.contains(Self.textKey(text)) }, "聊天样式实图缺少\(text)")
        }
        for text in ["显示头像", "显示昵称"] {
            XCTAssertFalse(appearanceText.contains { $0.key.contains(Self.textKey(text)) }, "退役开关仍出现在真实设置页")
        }
        try await assertPopControls(window: window, output: output, container: container,
                                    profileId: profile.id, conversationID: conversation.id)
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
        let label = Self.textKey(ChatTimeDivider.label(time.addingTimeInterval(14 * 60 + 14400)))
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
