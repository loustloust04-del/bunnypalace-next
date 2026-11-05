import XCTest
#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import SwiftData
import Vision
#endif
@testable import 记忆花园

/// #067 第一步：删除确认的分流、小克的记忆「完成」判脏、预览与实发同一个记忆分层函数。
final class MemoryPanelSafetyTests: XCTestCase {

    private func mem(_ content: String, superseded: Bool = false, pinned: Bool = false) -> Memory {
        let m = Memory(content: content, category: "fact", profileId: "xctest-panel-safety", isUserExplicit: pinned)
        m.supersededAt = superseded ? Date(timeIntervalSince1970: 100) : nil
        return m
    }

    // MARK: - 多选只留看得见的（10-16 astra #2）

    func testClipSelectionKeepsOnlyVisible() {
        let a = UUID(), b = UUID()
        let sel: Set<MemoryRowID> = [.archive(a), .archive(b), .assistant("x")]
        XCTAssertEqual(MemoryRowID.clip(sel, to: [.archive(a), .assistant("x"), .assistant("y")]), [.archive(a), .assistant("x")])
        XCTAssertEqual(MemoryRowID.clip(sel, to: []), [])
    }

    // MARK: - 删除分流

    func testActiveOnlyNoConfirm() {
        let a = mem("活1"), b = mem("活2")
        let plan = MemoryDeletePlan.plan([a, b])
        XCTAssertEqual(plan.supersede, [a.id, b.id])
        XCTAssertTrue(plan.purge.isEmpty)
        XCTAssertFalse(plan.needsConfirm)
    }

    func testSupersededOnlyNeedsConfirm() {
        let x = mem("失效1", superseded: true), y = mem("失效2", superseded: true)
        let plan = MemoryDeletePlan.plan([x, y])
        XCTAssertTrue(plan.supersede.isEmpty)
        XCTAssertEqual(plan.purge, [x.id, y.id])
        XCTAssertTrue(plan.needsConfirm)
        XCTAssertEqual(MemoryDeletePlan.confirmTitle(plan), "永久删除 2 条已失效的记忆？")
        XCTAssertEqual(MemoryDeletePlan.confirmButton(plan), "永久删除 2 条，不能恢复")
    }

    func testMixedSaysBothCounts() {
        let a = mem("活"), b = mem("活2"), x = mem("失效", superseded: true)
        let plan = MemoryDeletePlan.plan([a, x, b])
        XCTAssertEqual(plan.supersede, [a.id, b.id])
        XCTAssertEqual(plan.purge, [x.id])
        XCTAssertTrue(plan.needsConfirm)
        let title = MemoryDeletePlan.confirmTitle(plan)
        XCTAssertTrue(title.contains("2 条移到已失效"), title)
        XCTAssertTrue(title.contains("1 条已失效的永久删除"), title)
        XCTAssertEqual(MemoryDeletePlan.confirmButton(plan), "永久删除 1 条，不能恢复")
    }

    // MARK: - 小克的记忆编辑页判脏

    private func selfMemory() -> SelfMemory {
        SelfMemory(slug: "cat", name: "cat", description: "关于猫", type: "user", importance: 3, origin: "self",
                   created: Date(timeIntervalSince1970: 0), source: nil, superseded: nil, body: "正文")
    }

    func testUnchangedFormIsClean() {
        let m = selfMemory()
        XCTAssertFalse(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于猫", type: "user", importance: 3, body: "正文"))
    }

    func testAnyFieldChangeIsDirty() {
        let m = selfMemory()
        XCTAssertTrue(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于狗", type: "user", importance: 3, body: "正文"))
        XCTAssertTrue(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于猫", type: "project", importance: 3, body: "正文"))
        XCTAssertTrue(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于猫", type: "user", importance: 5, body: "正文"))
        XCTAssertTrue(SelfMemoryEditView.hasUnsavedEdits(m, description: "关于猫", type: "user", importance: 3, body: "改了"))
    }

    // MARK: - 预览与实发同一个分层函数

    private func profile(_ userName: String) -> Profile {
        Profile(name: "测试", emoji: "🧪", description: "", userName: userName, assistantName: "小克",
                systemPrompt: "系统指令", characterDescription: "")
    }

    func testLayersPutSelfMemoryBeforeArchive() {
        let layers = PromptAssembler.memoryLayers(profile: profile("猫"), selfMemory: "[我的记忆]\n记得喂猫",
                                                  memories: [mem("钉住的档案", pinned: true)], recentMessages: [], budget: nil)
        XCTAssertTrue(layers.stable.hasPrefix("[我的记忆]"), layers.stable)
        XCTAssertTrue(layers.stable.contains("[关于猫]"), layers.stable)
    }

    func testLayersSelfMemoryOnly() {
        let layers = PromptAssembler.memoryLayers(profile: profile("猫"), selfMemory: "[我的记忆]\n记得喂猫",
                                                  memories: [], recentMessages: [], budget: nil)
        XCTAssertEqual(layers.stable, "[我的记忆]\n记得喂猫")
        XCTAssertEqual(layers.volatile, "")
    }

    /// 实发 cacheFriendly 组装里的记忆常驻段 == memoryLayers 的常驻层（预览拿到的就是实发那段）
    func testAssembledStableSegmentMatchesLayers() {
        var preset = Preset(name: "t")
        preset.prompts = [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, injectionOrder: 0),
            PromptSlot(id: PromptSlot.memoryInjectionId, name: "记忆", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 40),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60),
        ]
        preset.sampling.cacheFriendly = true
        let archive = [mem("钉住的档案", pinned: true)]
        let selfText = "[我的记忆]\n记得喂猫"
        let segments = PromptAssembler.assembleTagged(preset: preset, profile: profile("猫"), memories: archive,
                                                      chatHistory: [("user", "你好")], selfMemory: selfText, memoryBudget: 5000).segments
        let layers = PromptAssembler.memoryLayers(profile: profile("猫"), selfMemory: selfText, memories: archive,
                                                  recentMessages: ["你好"], budget: 5000)
        XCTAssertTrue(segments.contains { $0.source == .memory && $0.content == layers.stable })
    }
}

#if os(macOS)
extension MemoryPanelSafetyTests {
    /// wiki 10-23 挪去审计台 wiki 台（plan-memory-audit-home-trial 第二节）：记忆格空页只剩空状态
    @MainActor
    func testEmptyMemoryRendersEmptyStateWithoutWiki() async throws {
        try await assertRenderedMemoryPanel(
            expected: ["还没有记忆", "和测试助手聊天时会自动记下重要的事", "加一条"],
            absent: ["常驻记忆", "还没有页", "去审计台"]
        )
    }

    @MainActor
    func testEmptyMemoryRetainsTrashAction() async throws {
        try await assertRenderedMemoryPanel(
            deletedMemory: true,
            expected: ["还没有记忆", "加一条", "已删除1"],
            absent: ["还没有页"]
        )
    }

    /// 只有 wiki 页、没有记忆：记忆格照样是空状态，wiki 不在这里出
    @MainActor
    func testWikiPagesNoLongerShowInMemoryGrid() async throws {
        try await assertRenderedMemoryPanel(
            wikiPage: WikiPage(path: "工程/测试档案", title: "测试档案", now: "可浏览的内容"),
            expected: ["还没有记忆", "加一条"],
            absent: ["常驻记忆", "1页"]
        )
    }

    @MainActor
    private func assertRenderedMemoryPanel(
        deletedMemory: Bool = false, wikiPage: WikiPage? = nil,
        expected: [String], absent: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertTrue(TestHostIsolation.active, file: file, line: line)
        guard TestHostIsolation.active, let home = TestHostIsolation.home else { return }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let profile = Profile(id: UUID().uuidString, name: "空页回归", emoji: "", description: "",
                              userName: "测试者", assistantName: "测试助手")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MemoryPanelSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfileManager(container: container, profiles: [profile], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let memoryRoot = FileLibraryStore.memoryRoot(profileId: profile.id)
        XCTAssertTrue(TestHostIsolation.contains(memoryRoot, home), file: file, line: line)
        guard TestHostIsolation.contains(memoryRoot, home) else { return }
        defer { try? FileManager.default.removeItem(at: memoryRoot.deletingLastPathComponent()) }
        if deletedMemory {
            let deleted = Memory(content: "已删除的测试记忆", category: "fact", profileId: profile.id)
            deleted.supersededAt = Date()
            container.mainContext.insert(deleted)
            try container.mainContext.save()
        }
        if let wikiPage {
            try await Task.detached {
                _ = try WikiStore(root: memoryRoot.appendingPathComponent("wiki")).save(wikiPage)
            }.value
        }
        var mounted = false
        let content = MemoryPanelView(viewModel: ConversationViewModel())
            .modelContainer(container)
            .environment(profiles)
            .environment(ThemeManager.shared)
            .onAppear { mounted = true }
        let controller = NSHostingController(rootView: content)
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 760)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }

        var visible: [String] = []
        var captured: NSBitmapImageRep?
        for _ in 0..<80 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            if mounted, let bitmap = panelLayerSnapshot(host) {
                if let pixels = bitmap.cgImage {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: pixels).perform([request])
                    visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        .map { $0.filter { $0.isLetter || $0.isNumber } }
                    captured = bitmap
                    if expected.allSatisfy({ text in visible.contains { $0.contains(text) } }) { break }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let data = captured?.representation(using: .png, properties: [:]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            let name = "memory-panel-\(wikiPage == nil ? "empty" : "wiki")\(deletedMemory ? "-trash" : "").png"
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let output = ProcessInfo.processInfo.environment["MP_BUBBLE_SNAPSHOT_DIR"] {
                let url = URL(fileURLWithPath: output).appendingPathComponent(name)
                try await Task.detached { try data.write(to: url, options: .atomic) }.value
                print("[记忆空页截图] \(url.path)，OCR：\(visible)")
            }
        }
        for text in expected {
            XCTAssertTrue(visible.contains { $0.contains(text) }, "真实记忆面板截图缺少 \(text)，OCR：\(visible)",
                          file: file, line: line)
        }
        for text in absent {
            XCTAssertFalse(visible.contains { $0.contains(text) }, "真实记忆面板不应显示 \(text)，OCR：\(visible)",
                           file: file, line: line)
        }
    }

    @MainActor
    private func panelLayerSnapshot(_ view: NSView) -> NSBitmapImageRep? {
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
        // List 的 AppKit 子视图是独立合成层，cacheDisplay 不会捕获它们。
        layer.render(in: context.cgContext)
        return bitmap
    }
}
#endif
