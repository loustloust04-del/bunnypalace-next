import XCTest
import SwiftUI
import SwiftData
import UIKit
import Network
@testable import 记忆花园

@MainActor
final class BubbleInputRegressionTests: XCTestCase {
    #if DEBUG
    func testBubbleMultilineAndRealSend() async throws { try await inputRegression(bubble: true) }
    func testArticleMultilineAndRealSend() async throws { try await inputRegression(bubble: false) }

    private func inputRegression(bubble: Bool) async throws {
        try require(TestHostIsolation.active, "必须启用隔离 XCTest 宿主")
        let restoreAccessibility = try enableAccessibility()
        defer { restoreAccessibility() }
        let env = ProcessInfo.processInfo.environment
        try require(env["MP_TEST_HOST"] == "1" && env["MP_SPLASH"] == "0", "缺少隔离宿主环境")
        try require(CommandLine.arguments.contains("--kb-probe-seed"), "必须走生产 loadConversation 入口")
        let output = URL(fileURLWithPath: try XCTUnwrap(env["MP_BUBBLE_SNAPSHOT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let name = "\(env["MP_INPUT_REVISION"] ?? "current")-\(bubble ? "bubble" : "article")-page"
        let home = try XCTUnwrap(TestHostIsolation.home)
        let root = home.appendingPathComponent("InputRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let isolated = try XCTUnwrap(UserDefaults(suiteName: TestHostIsolation.defaultsSuiteName))
        let savedDomain = isolated.persistentDomain(forName: TestHostIsolation.defaultsSuiteName) ?? [:]
        defer { isolated.setPersistentDomain(savedDomain, forName: TestHostIsolation.defaultsSuiteName) }
        let defaults = UserDefaults.standard
        let marker = UUID().uuidString
        defaults.set(marker, forKey: "InputRegressionIsolation")
        try require(isolated.string(forKey: "InputRegressionIsolation") == marker, "standard defaults 未隔离")
        defaults.set(bubble, forKey: "chatBubbleMode")
        defaults.set("", forKey: "selectedFont")
        defaults.set(17.0 / 13.5, forKey: "fontScale")
        defaults.set(13.5, forKey: "inputFontBase")

        let server = try InputRegressionHTTPServer()
        try server.start()
        defer { server.stop() }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = container.mainContext
        let profile = Profile(id: "input-regression-profile", name: "Input regression", emoji: "",
                              description: "合成回归样本", userName: "You", assistantName: "Assistant")
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let presets = PresetManager(root: root, defaults: defaults)
        let providers = ProviderManager()
        let credentialID = "input-regression-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialID, modelId: "input-regression", name: "Input regression")
        providers.addCredential(APICredential(id: credentialID, name: "Loopback input regression", emoji: "",
                                              type: .openaiCompatible, baseURL: server.baseURL, models: [model]))
        providers.setApiKey("synthetic-test-key", for: credentialID)
        defer { providers.removeCredential(id: credentialID) }
        let conversation = Conversation(id: "probe-kb-conv-1", title: "Input regression",
                                        createTime: Date(), updateTime: Date(), currentNodeId: "input-regression-root",
                                        provider: "api", profileId: profile.id)
        conversation.memoryEnabled = false
        conversation.selectedModelId = model.id
        conversation.nodeCount = 1
        context.insert(conversation)
        context.insert(MessageNode(id: "input-regression-root", role: "assistant", content: "Ready.",
                                   contentType: "text", createTime: Date(), parentId: nil, childrenIds: [],
                                   conversationId: conversation.id, profileId: profile.id))
        try context.save()
        try await waitUntil("等待真实前台 key window") {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains {
                $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow)
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) })
        let window = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
        let theme = ThemeManager.shared
        let oldMode = theme.themeMode
        let oldTheme = theme.selectedThemeId
        let oldScheme = theme.systemColorScheme
        let oldStyle = window.overrideUserInterfaceStyle
        let oldContent = MemoryPalaceIOSTestScene.shared.content
        let oldContext = PerfHarness.modelContext
        let oldDismiss = KeyboardInsetBridge.shared.sendDismissUntil
        defer {
            window.endEditing(true)
            MemoryPalaceIOSTestScene.shared.content = oldContent
            PerfHarness.modelContext = oldContext
            KeyboardInsetBridge.shared.sendDismissUntil = oldDismiss
            window.overrideUserInterfaceStyle = oldStyle
            theme.themeMode = oldMode
            theme.selectTheme(id: oldTheme)
            theme.syncSystemColorScheme(oldScheme)
        }
        theme.themeMode = .light
        theme.selectTheme(id: AppThemeDefinition.defaultTheme.id)
        theme.syncSystemColorScheme(.light)
        window.overrideUserInterfaceStyle = .light
        let previousVM = PerfHarness.viewModel
        // 生产整页自己重挂真实 InputBarStack；不复制 Composer、Binding 或发送回调。
        MemoryPalaceIOSTestScene.shared.content = AnyView(ContentView()
            .modelContainer(container)
            .environment(profiles).environment(presets).environment(providers).environment(theme)
            .environment(\.colorScheme, .light).environment(\.accessibilityEnabled, true)
            .preferredColorScheme(.light).id(name))
        defer { _ = try? capture(window: window, output: output, name: "\(name)-final") }
        try await waitUntil("等待生产会话及真实 InputBarStack 挂载") {
            guard let vm = PerfHarness.viewModel, vm !== previousVM else { return false }
            return vm.selectedConversation?.id == conversation.id && !vm.isLoading
                && self.input(in: window)?.window === window && PerfHarness.paging?.view.window === window
        }
        let vm = try XCTUnwrap(PerfHarness.viewModel)
        defer { vm.cancelAssistantTurn(context: context) }
        let input = try XCTUnwrap(input(in: window))
        XCTAssertTrue(input.becomeFirstResponder(), "必须激活真实 UITextView")
        let empty = try await stableFrame(input, window: window)
        XCTAssertEqual(input.text, "")
        // 三次原生输入之间不让 runloop 先落盘，覆盖草稿镜像与换行布局同拍更新。
        input.insertText("第一行")
        XCTAssertEqual(input.text, "第一行")
        input.insertText("\n")
        XCTAssertEqual(input.text, "第一行\n", "独立 Return 不能消失或触发发送")
        input.insertText("第二行")
        let grown = try await stableFrame(input, window: window)
        let outgoing = "第一行\n第二行"
        XCTAssertEqual(input.text, outgoing)
        XCTAssertGreaterThan(grown.height, empty.height + 5, "必须是实际 UITextView frame 长高")
        XCTAssertTrue(window.bounds.contains(grown), "输入框两行必须留在屏内")
        try await waitUntil("真实 InputBarStack 必须落盘完整两行草稿") { conversation.draftText == outgoing }
        XCTAssertTrue(vm.pendingSends.isEmpty)
        XCTAssertFalse(vm.assistantTurnInFlight, "Return 不能提前发送")
        XCTAssertEqual(server.bodies.count, 0)
        let buttons = accessibilityNodes(window).filter { node in
            guard node.isAccessibilityElement, node.accessibilityTraits.contains(.button) else { return false }
            let frame = window.convert(node.accessibilityFrame, from: nil)
            return frame.minX > grown.midX && frame.midY >= grown.minY - 24 && frame.midY <= grown.maxY + 70
        }
        try require(buttons.count == 1, "输入框右侧应有唯一真实发送键，实际 \(buttons.count)；AX=\(accessibilitySummary(window))")
        let button = try XCTUnwrap(buttons.first)
        let frame = window.convert(button.accessibilityFrame, from: nil)
        XCTAssertTrue(window.bounds.contains(frame), "发送键必须完整在屏内：\(frame)")
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled), "发送键必须启用")
        let owner = try XCTUnwrap(accessibilityOwner(button))
        var ancestor: UIView? = owner
        var alpha: CGFloat = 1
        while let view = ancestor {
            XCTAssertFalse(view.isHidden, "发送键祖先不能隐藏")
            alpha *= view.alpha
            ancestor = view.superview
        }
        XCTAssertGreaterThan(alpha, 0, "发送键实际 alpha 必须大于零")
        let hit = try XCTUnwrap(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil))
        XCTAssertTrue(hit === owner || hit.isDescendant(of: owner) || owner.isDescendant(of: hit),
                      "发送键中心被 \(type(of: hit)) 遮挡")
        let shot = try capture(window: window, output: output, name: "\(name)-multiline")
        try assertSendArrow(in: shot, frame: frame, window: window)
        XCTAssertTrue(button.accessibilityActivate(), "必须激活真实 SwiftUI Button，不能直接调发送回调")
        try await waitUntil("真实按钮激活后 HTTP 服务必须收到请求，不接受仅排队或等待预热") { !server.bodies.isEmpty }
        let body = try JSONDecoder().decode(RequestBody.self, from: XCTUnwrap(server.bodies.first))
        XCTAssertTrue(body.messages.contains { $0.role == "user" && $0.content.contains(outgoing) },
                      "真实 HTTP 请求必须保留完整两行原文，允许生产 prompt 注入前后文")
        try await waitUntil("真实流式回复必须完成") {
            vm.currentPath.last?.role == "assistant" && vm.currentPath.last?.content == "Input delivered."
                && !vm.assistantTurnInFlight
        }
        XCTAssertEqual(vm.currentPath.filter { $0.role == "user" }.map(\.content), [outgoing])
        XCTAssertTrue(vm.pendingSends.isEmpty, "不能把排队受理冒充实发")
        XCTAssertEqual(input.text, "", "成功发送必须沿生产命令通道清空输入框")
        XCTAssertEqual(conversation.draftText, "")
        let evidence = Evidence(empty: empty, multiline: grown, sendButton: frame, outgoing: outgoing,
                                requestCount: server.bodies.count, assistant: vm.currentPath.last?.content ?? "")
        try JSONEncoder().encode(evidence).write(to: output.appendingPathComponent("\(name)-evidence.json"), options: .atomic)
        print("[INPUT-REGRESSION] \(name) empty=\(empty) multiline=\(grown) button=\(frame) requests=\(server.bodies.count) delivered=\(outgoing.debugDescription)")
    }

    private struct RequestBody: Decodable {
        struct Message: Decodable { let role: String; let content: String }
        let messages: [Message]
    }
    private struct Evidence: Encodable {
        let empty, multiline, sendButton: CGRect
        let outgoing: String
        let requestCount: Int
        let assistant: String
    }
    private func input(in view: UIView) -> ChatInputTextView? {
        if let input = view as? ChatInputTextView, input.accessibilityIdentifier == "chat-input-field" { return input }
        return view.subviews.lazy.compactMap { self.input(in: $0) }.first
    }
    private func stableFrame(_ input: UITextView, window: UIWindow) async throws -> CGRect {
        var previous: CGRect?
        var stable = 0
        try await waitUntil("等待真实输入框布局及草稿提交稳定") {
            window.layoutIfNeeded()
            let frame = input.convert(input.bounds, to: window)
            stable = frame == previous && !KeyboardInsetBridge.shared.kbTransitioning ? stable + 1 : 0
            previous = frame
            return stable >= 20 && frame.width > 0 && frame.height > 0
        }
        return try XCTUnwrap(previous)
    }
    private func enableAccessibility() throws -> () -> Void {
        // 与 AccessibilitySnapshot/KIF 同法，仅测试宿主启用 AX automation；退出恢复，不伪造按钮或回调。
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let handle = try XCTUnwrap(dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_LAZY))
        let get = unsafeBitCast(try XCTUnwrap(dlsym(handle, "_AXSAutomationEnabled")),
                                to: (@convention(c) () -> Int32).self)
        let set = unsafeBitCast(try XCTUnwrap(dlsym(handle, "_AXSSetAutomationEnabled")),
                                to: (@convention(c) (Int32) -> Void).self)
        let previous = get()
        set(1)
        return { set(previous); dlclose(handle) }
    }

    private func accessibilityNodes(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            result.append(node)
            if let view = node as? UIView { view.subviews.forEach(visit) }
            let count = node.accessibilityElementCount()
            guard count > 0 && count < 2000 else { return }
            for index in 0..<count {
                if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) }
            }
        }
        visit(root)
        return result
    }
    private func accessibilitySummary(_ window: UIWindow) -> String {
        accessibilityNodes(window).filter(\.isAccessibilityElement).map {
            "\(type(of: $0)): \($0.accessibilityLabel ?? "nil") \($0.accessibilityFrame)"
        }.joined(separator: "; ")
    }
    private func accessibilityOwner(_ node: NSObject) -> UIView? {
        if let view = node as? UIView { return view }
        let selector = NSSelectorFromString("accessibilityContainer")
        if node.responds(to: selector),
           let container = node.perform(selector)?.takeUnretainedValue() as? NSObject, container !== node {
            return accessibilityOwner(container)
        }
        return nil
    }
    @discardableResult
    private func capture(window: UIWindow, output: URL, name: String) throws -> URL {
        try require(window.isKeyWindow && window.windowScene?.activationState == .foregroundActive,
                    "截图必须来自真实前台 key window")
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try require(drawn, "真实窗口截图失败")
        let path = output.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: path, options: .atomic)
        let attachment = XCTAttachment(contentsOfFile: path)
        attachment.lifetime = .keepAlways
        add(attachment)
        return path
    }
    private func assertSendArrow(in url: URL, frame: CGRect, window: UIWindow) throws {
        let image = try XCTUnwrap(UIImage(data: Data(contentsOf: url))?.cgImage)
        let scale = CGFloat(image.width) / window.bounds.width
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                          width: frame.width * scale, height: frame.height * scale).integral
        let button = try XCTUnwrap(image.cropping(to: crop))
        let width = button.width, height = button.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(button, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let center = CGPoint(x: frame.midX * scale - crop.minX, y: frame.midY * scale - crop.minY)
        var whitePixels = 0
        var ringBrightness: Double = 0
        for y in max(0, Int(center.y - 8 * scale))..<min(height, Int(center.y + 8 * scale)) {
            for x in max(0, Int(center.x - 8 * scale))..<min(width, Int(center.x + 8 * scale)) {
                let i = (y * width + x) * 4
                if bytes[i] > 240 && bytes[i + 1] > 240 && bytes[i + 2] > 240 { whitePixels += 1 }
            }
        }
        // 发送圆内、箭头外的 12pt 环：必须是实心底，不得把灰波形周围的白玻璃当白箭头。
        for index in 0..<24 {
            let angle = Double(index) * .pi / 12
            let x = min(width - 1, max(0, Int(center.x + CGFloat(cos(angle)) * 12 * scale)))
            let y = min(height - 1, max(0, Int(center.y + CGFloat(sin(angle)) * 12 * scale)))
            let i = (y * width + x) * 4
            ringBrightness += (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1])
                + 0.0722 * Double(bytes[i + 2])) / 255 / 24
        }
        print("[INPUT-GLYPH] \(url.lastPathComponent) white=\(whitePixels) ring=\(ringBrightness)")
        XCTAssertGreaterThanOrEqual(whitePixels, 8, "实际 PNG 必须显示白色发送箭头")
        XCTAssertLessThan(ringBrightness, 0.94, "打字后必须显示实心发送圆，不能仍是语音波形")
    }

    private func waitUntil(_ reason: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try require(false, reason)
    }
    private func require(_ value: Bool, _ reason: String) throws {
        guard value else { XCTFail(reason); throw Failure.failed(reason) }
    }
    private enum Failure: Error { case failed(String) }
    #else
    func testRequiresDebugHost() { XCTFail("输入回归需要真实 Debug WindowGroup 宿主") }
    #endif
}

private final class InputRegressionHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BubbleInputRegressionTests.HTTP")
    private let lock = NSLock()
    private var received: [Data] = []
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)/v1" }
    var bodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.receive(connection, accumulated: Data())
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, listener.port != nil else { throw URLError(.cannotConnectToHost) }
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            if let range = request.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: request[..<range.lowerBound], as: UTF8.self)
                let length = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.count - range.upperBound >= length {
                    self.lock.lock()
                    self.received.append(request.subdata(in: range.upperBound..<(range.upperBound + length)))
                    self.lock.unlock()
                    let body = Data("data: {\"choices\":[{\"delta\":{\"content\":\"Input delivered.\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
                    var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(body)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if complete || error != nil { connection.cancel() }
            else { self.receive(connection, accumulated: request) }
        }
    }
}
