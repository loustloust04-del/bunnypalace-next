import XCTest
import SwiftUI
import UIKit
@testable import 记忆花园

/// 共存返工①②：真实窗口里挂着的正文跟主题走。
/// ① 聊天页 AI 正文已挂载、正文不变、只换主题 → 字色跟着变（不靠 `.id()` 重建视图）；
/// ② 小芽面板（非聊天页）流式和定稿两支在气泡模式下字色一致，都是普通 AI 字色、不吃气泡模式色。
/// 运行：-only-testing:MemoryPalaceIOSTests/ThemeRerenderTests（Debug 宿主、MP_TEST_HOST=1）
@MainActor
final class ThemeRerenderTests: XCTestCase {
    private static let red = ThemeColorValue(hex: 0xD00000)
    private static let blue = ThemeColorValue(hex: 0x0000D0)
    private static let green = ThemeColorValue(hex: 0x00A000)
    private static let sample = "Theme rerender sample text that is long enough to paint plenty of pixels"

    private var theme: ThemeManager { ThemeManager.shared }

    /// 选一套复制出来的主题：白底、AI 泡透明、普通 AI 字色 = `normal`，气泡模式 AI 字色 = `bubble`；开气泡模式
    /// 返回主题 id 和收尾闭包（测试里 defer 调）
    private func prepareTheme(normal: ThemeColorValue, bubble: ThemeColorValue?) throws -> (String, () -> Void) {
        try require(TestHostIsolation.active, "必须使用启用隔离的 iOS XCTest 宿主")
        let saved = (theme.themeMode, theme.selectedThemeId, theme.isBubbleModeActive)
        let id = try XCTUnwrap(theme.saveThemeCopy(from: AppThemeDefinition.defaultTheme.id, name: "返工取色", select: true))
        let cleanup: () -> Void = { [theme] in
            MemoryPalaceIOSTestScene.shared.content = AnyView(Color.clear)
            theme.themeMode = saved.0
            theme.selectTheme(id: saved.1)
            theme.isBubbleModeActive = saved.2
            theme.deleteTheme(id: id)
        }
        var light = ThemeTokenSet.palaceLightDefault
        light.mainBg = ThemeColorValue(hex: 0xFFFFFF)
        light.assistantText = normal
        light.bubbleModeAssistantText = bubble
        theme.replaceTokenSet(light, for: .light, themeId: id)
        theme.themeMode = .light
        theme.syncSystemColorScheme(.light)
        theme.isBubbleModeActive = true
        return (id, cleanup)
    }

    private func mount<V: View>(_ view: V) async throws -> UIWindow {
        let scene = try await foregroundScene()
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        window.overrideUserInterfaceStyle = .light
        MemoryPalaceIOSTestScene.shared.content = AnyView(
            view
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white)
                .environment(theme)
                .environment(\.colorScheme, .light)
        )
        return window
    }

    // MARK: - ① 聊天页正文换主题重解析

    func testMountedAssistantBodyRecolorsOnThemeChangeWithoutRebuild() async throws {
        let (id, cleanup) = try prepareTheme(normal: Self.red, bubble: Self.blue)
        defer { cleanup() }
        let window = try await mount(
            ChatMarkdownView(text: Self.sample, fontName: "", scale: 2.0, linkifyTickers: false, role: .assistant)
        )
        try await waitUntil("气泡模式下 AI 正文先是气泡模式蓝") {
            let px = try? Pixels(window)
            return (px?.count(Self.blue) ?? 0) > 150
        }

        // 同一套主题只改气泡模式 AI 字色：正文不变、视图不重建
        var light = try XCTUnwrap(theme.themeDefinition(id: id)).light
        light.bubbleModeAssistantText = Self.green
        theme.replaceTokenSet(light, for: .light, themeId: id)

        try await waitUntil("换主题后已挂载的 AI 正文要重解析成绿色") {
            guard let px = try? Pixels(window) else { return false }
            return px.count(Self.green) > 150 && px.count(Self.blue) < 20
        }
    }

    // MARK: - ② 小芽面板流式 / 定稿同色

    func testXiaoyaStreamingAndFinalUseGlobalAssistantColor() async throws {
        let (_, cleanup) = try prepareTheme(normal: Self.red, bubble: Self.blue)
        defer { cleanup() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ThemeRerenderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "ThemeRerenderTests.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let engine = AssistantEngine(store: AssistantChatStore(fileURL: dir.appendingPathComponent("history.json")),
                                     ledger: AssistantLedger(fileURL: dir.appendingPathComponent("ledger.json")),
                                     packDefaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        engine.streamingText = Self.sample

        let window = try await mount(XiaoyaLineText(text: Self.sample, engine: engine, streaming: true, scale: 2.0))
        try await waitUntil("小芽流式正文是普通 AI 字色（红），不是气泡模式蓝") {
            guard let px = try? Pixels(window) else { return false }
            return px.count(Self.red) > 150 && px.count(Self.blue) < 20
        }
        let streamingRed = try Pixels(window).count(Self.red)

        _ = try await mount(XiaoyaLineText(text: Self.sample, engine: engine, streaming: false, scale: 2.0))
        try await waitUntil("小芽定稿正文同样是普通 AI 字色") {
            guard let px = try? Pixels(window) else { return false }
            return px.count(Self.red) > 150 && px.count(Self.blue) < 20
        }
        let finalRed = try Pixels(window).count(Self.red)
        print("[返工②] 小芽流式红点 \(streamingRed)，定稿红点 \(finalRed)")
    }

    // MARK: - helpers

    /// 整窗实拍（drawHierarchy），每 2px 采一点，按「离目标色每分量 ≤ 40/255」计数（抗锯齿边缘不算）
    private struct Pixels {
        let data: [UInt8]
        let width: Int
        let height: Int

        init(_ window: UIWindow) throws {
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cg = try XCTUnwrap(image.cgImage)
            let w = cg.width, h = cg.height
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            buffer.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            data = buffer
            width = w
            height = h
        }

        func count(_ color: ThemeColorValue) -> Int {
            let target = [color.red * 255, color.green * 255, color.blue * 255]
            var n = 0
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    let i = (y * width + x) * 4
                    if abs(Double(data[i]) - target[0]) <= 40, abs(Double(data[i + 1]) - target[1]) <= 40,
                       abs(Double(data[i + 2]) - target[2]) <= 40 { n += 1 }
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

    private func waitUntil(_ reason: String, timeout: TimeInterval = 15, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
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
}
