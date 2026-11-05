#if os(macOS)
import AppKit
import SwiftUI
import SwiftData
import Vision
import XCTest
@testable import 记忆花园

@MainActor
final class CodingNicknameRenderingTests: XCTestCase {
    func testLegacyHidePreferenceCannotHideAuthorsOrRepeatRunHeaders() async throws {
        XCTAssertTrue(TestHostIsolation.active)
        guard TestHostIsolation.active else { return }
        let defaults = UserDefaults.standard
        let oldHidden = defaults.object(forKey: "hideRoleName")
        let oldUser = defaults.object(forKey: "userName")
        let oldFont = defaults.object(forKey: "selectedFont")
        let oldScale = defaults.object(forKey: "fontScale")
        defaults.set(true, forKey: "hideRoleName")
        defaults.set("You", forKey: "userName")
        defaults.set("", forKey: "selectedFont")
        defaults.set(17.0 / 13.5, forKey: "fontScale")
        defer {
            defaults.set(oldHidden, forKey: "hideRoleName")
            defaults.set(oldUser, forKey: "userName")
            defaults.set(oldFont, forKey: "selectedFont")
            defaults.set(oldScale, forKey: "fontScale")
        }
        let theme = ThemeManager.shared
        let oldMode = theme.themeMode
        let oldTheme = theme.selectedThemeId
        theme.selectTheme(id: AppThemeDefinition.defaultTheme.id)
        theme.themeMode = .dark
        theme.syncSystemColorScheme(.dark)
        defer { theme.themeMode = oldMode; theme.selectTheme(id: oldTheme) }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        var mounted = false
        let content = VStack(alignment: .leading, spacing: 24) {
            CodingMessageRow(message: .make(.user, .text, "Which flavor do you want?", ts: 0, clip: false))
            CodingMessageRow(message: .make(.assistant, .text, "Thank you!", ts: 0, clip: false))
            CodingMessageRow(message: .make(.assistant, .text, "Come over at 12", ts: 0, clip: false), showsHeader: false)
        }
        .padding(16)
        .frame(width: 393, height: 500)
        .background(Theme.mainBg)
        .modelContainer(container)
        .environment(theme)
        .environment(\.colorScheme, .dark)
        .onAppear { mounted = true }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 393, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        let expected = ["Whichflavordoyouwant", "Thankyou", "Comeoverat12"]
        var texts: [String] = []
        var captured: NSBitmapImageRep?
        for _ in 0..<80 {
            host.layoutSubtreeIfNeeded()
            if mounted, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let pixels = bitmap.cgImage {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: pixels).perform([request])
                    texts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        .map { $0.filter { $0.isLetter || $0.isNumber } }
                    captured = bitmap
                    if expected.allSatisfy({ word in texts.contains { $0.contains(word) } }) { break }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        for text in expected { XCTAssertTrue(texts.contains { $0.contains(text) }, "Code真实截图缺少正文：\(text)") }
        XCTAssertEqual(texts.filter { $0.contains("You") }.count, 1)
        XCTAssertEqual(texts.filter { $0.contains("助手") }.count, 1, "旧隐藏偏好不能吞署名，连发后续行不能重复署名")
        let bitmap = try XCTUnwrap(captured)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "code-names-dark.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[Code署名截图] \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)，OCR：\(texts)")
        if let output = ProcessInfo.processInfo.environment["MP_BUBBLE_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: output).appendingPathComponent("code-names-dark.png")
            try await Task.detached { try data.write(to: url, options: .atomic) }.value
            print("[Code署名截图] 已写入：\(url.path)")
        }
    }
}
#endif
