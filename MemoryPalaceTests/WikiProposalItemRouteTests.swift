import XCTest
#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import SwiftData
import Vision
#endif
@testable import 记忆花园

/// 目录项详情在 mac 设置窗里走 `SettingsRoute.memoryProposalItem`（astra 10-23 P2）：页顶 ‹ › 只认 `[SettingsRoute]`，
/// 目录项进了 path 才回得去、前进得回来
final class WikiProposalItemRouteTests: XCTestCase {
    #if os(macOS)
    @MainActor
    func testRouteTitleAndSelection() {
        XCTAssertEqual(SettingsRoute.memoryProposalItem.title, "目录项")
        XCTAssertEqual(SettingsRoute(rawValue: "memoryProposalItem"), .memoryProposalItem)
        let before = WikiProposalSelection.shared.item
        defer { WikiProposalSelection.shared.item = before }
        let target = Self.target()
        WikiProposalSelection.shared.item = target
        XCTAssertEqual(WikiProposalSelection.shared.item?.id, target.id)
    }

    private static func target() -> WikiProposalItemTarget {
        let d = WikiProposal.Direction(path: "楼层/人/阿青", title: "阿青", hook: "聊到阿青", action: .newPage, reason: "常提", mode: .daily)
        let fragment = WikiProposalItemTarget.fragment(id: UUID(), title: "阿青养猫", content: "阿青养了一只猫", quote: nil, day: nil)
        return WikiProposalItemTarget(proposalId: UUID().uuidString, item: .init(change: .direction(d), baseVersion: nil),
                                      seedTask: nil, fragments: [fragment])
    }

    @MainActor
    @Observable
    final class PathBox {
        var path: [SettingsRoute] = []
    }

    /// 同设置窗：值驱动 path + `navigationDestination(for: SettingsRoute.self)` 落到 `macDestination`
    private struct Host: View {
        @Bindable var box: PathBox

        var body: some View {
            NavigationStack(path: $box.path) {
                Text("根页面")
                    .font(.system(size: 28))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)   // 透明底上的黑字截图后 OCR 认不出
                    .navigationDestination(for: SettingsRoute.self) { $0.macDestination }
            }
            .environment(\.settingsRouteHost, true)
        }
    }

    /// 推进目录项 → ‹（removeLast）回到上一层 → ›（append）又回到目录项，页面内容都在
    @MainActor
    func testBackAndForwardRestoreItemPage() async throws {
        XCTAssertTrue(TestHostIsolation.active)
        guard TestHostIsolation.active, let home = TestHostIsolation.home else { return }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let profile = Profile(id: UUID().uuidString, name: "目录项路由", emoji: "", description: "",
                              userName: "测试者", assistantName: "测试助手")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "WikiProposalItemRouteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let memoryRoot = FileLibraryStore.memoryRoot(profileId: profile.id)
        XCTAssertTrue(TestHostIsolation.contains(memoryRoot, home))
        guard TestHostIsolation.contains(memoryRoot, home) else { return }
        defer { try? FileManager.default.removeItem(at: memoryRoot.deletingLastPathComponent()) }

        let before = WikiProposalSelection.shared.item
        defer { WikiProposalSelection.shared.item = before }
        WikiProposalSelection.shared.item = Self.target()

        let box = PathBox()
        let content = Host(box: box)
            .modelContainer(container)
            .environment(profiles)
            .environment(ThemeManager.shared)
        let controller = NSHostingController(rootView: content)
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }

        try await expect(["根页面"], absent: [], host: host, window: window)
        box.path = [.memoryProposalItem]
        try await expect(["阿青", "原料1份"], absent: ["根页面"], host: host, window: window)
        box.path.removeLast()
        try await expect(["根页面"], absent: ["原料1份"], host: host, window: window)
        box.path.append(.memoryProposalItem)
        try await expect(["阿青", "原料1份", "阿青养猫"], absent: ["根页面"], host: host, window: window)
    }

    @MainActor
    private func expect(_ expected: [String], absent: [String], host: NSView, window: NSWindow,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        var visible: [String] = []
        for _ in 0..<80 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            // NSTableView 等 AppKit 子视图要 layer.render 才抓得到；SwiftUI 文字有时只在 cacheDisplay 里，两种都认
            visible = []
            for bitmap in [snapshot(host), cached(host)] {
                guard let pixels = bitmap?.cgImage else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: pixels).perform([request])
                visible += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.filter { $0.isLetter || $0.isNumber } }
            }
            if expected.allSatisfy({ t in visible.contains { $0.contains(t) } }),
               !absent.contains(where: { t in visible.contains { $0.contains(t) } }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for t in expected {
            XCTAssertTrue(visible.contains { $0.contains(t) }, "缺 \(t)，OCR：\(visible)", file: file, line: line)
        }
        for t in absent {
            XCTAssertFalse(visible.contains { $0.contains(t) }, "不该有 \(t)，OCR：\(visible)", file: file, line: line)
        }
    }

    @MainActor
    private func cached(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @MainActor
    private func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 1
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = view.bounds.size
        context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: scale, y: -scale)
        layer.render(in: context.cgContext)
        return bitmap
    }
    #endif
}
