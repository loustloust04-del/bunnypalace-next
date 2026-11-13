import MemoryCore
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

    // MARK: - 底栏四格（粟粟 10-24：记忆 / 窗口·时间轴 / wiki / 审计台）

    func testBottomBarHasFourTabsInOrder() {
        XCTAssertEqual(MemoryPanelTab.allCases.map(\.title), ["记忆", "窗口·时间轴", "wiki", "审计台"])
        XCTAssertEqual(Set(MemoryPanelTab.allCases.map(\.icon)).count, MemoryPanelTab.allCases.count, "四格图标不重样")
        XCTAssertEqual(MemoryWindowsSegment.allCases.map(\.title), ["窗口总结", "时间轴"], "窗口·时间轴格顶上两段")
    }

    /// 两段常驻（10-24 astra P2）：切段不重建视图、`.task` 不重跑，后台被 markStale 的那段要靠切段重读，另一段不动
    @MainActor
    func testSwitchingWindowsSegmentReloadsOnlyStaleTarget() throws {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let pid = "xctest-windows-segment"
        let timeline = MemoryTimelineModel(), sessions = MemorySessionsModel()
        timeline.reload(profileId: pid, container: container)
        sessions.reload(profileId: pid, container: container)
        timeline.markStale()
        sessions.markStale()

        MemoryWindowsSegment.timeline.activate(timeline: timeline, sessions: sessions, profileId: pid, container: container)
        XCTAssertFalse(timeline.stale, "切到时间轴：后台标脏的时间轴重读")
        XCTAssertTrue(sessions.stale, "窗口总结没上台，留着脏等切过去再读")

        MemoryWindowsSegment.sessions.activate(timeline: timeline, sessions: sessions, profileId: pid, container: container)
        XCTAssertFalse(sessions.stale)
    }

    /// 重写状态在父级 model（10-24 astra 二审 P2）：mac 切格拆掉时间轴视图再回来，在跑的那次还挡着，不会再提交一次
    @MainActor
    func testTimelineRegenerateRejectsResubmitWhileRunning() async throws {
        final class Calls { var n = 0 }
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let pid = "xctest-timeline-regenerate", day = "2026-10-23"
        let model = MemoryTimelineModel(), calls = Calls()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let report: TimelineDaily.Report = { var r = TimelineDaily.Report(); r.failed[day] = "模型没回"; return r }()
        let run: () async -> TimelineDaily.Report? = {
            calls.n += 1
            for await _ in gate { break }
            return report
        }

        XCTAssertTrue(model.regenerate(day, profileId: pid, container: container, run: run))
        XCTAssertEqual(model.regenerating, day)
        XCTAssertFalse(model.regenerate(day, profileId: pid, container: container, run: run), "同一天在跑：不再提交")
        XCTAssertFalse(model.regenerate("2026-10-22", profileId: pid, container: container, run: run), "别的天也等这次跑完")

        release.yield()
        release.finish()
        for _ in 0..<300 where model.regenerating != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.regenerating)
        XCTAssertEqual(calls.n, 1, "只调了一次模型")
        XCTAssertEqual(model.notice, "模型没回")
    }

    /// 隐藏段的提示攒着（10-24 astra 二审）：时间轴不在台上不弹，切回来再弹
    @MainActor
    func testTimelineNoticeWaitsUntilTimelineVisible() {
        XCTAssertTrue(MemoryWindowsSegment.timeline.isVisible(selected: .timeline, tab: .windows))
        XCTAssertFalse(MemoryWindowsSegment.timeline.isVisible(selected: .sessions, tab: .windows), "在看窗口总结")
        XCTAssertFalse(MemoryWindowsSegment.timeline.isVisible(selected: .timeline, tab: .wiki), "底栏在别的格")

        let model = MemoryTimelineModel()
        XCTAssertFalse(model.presentsNotice(active: true), "没提示不弹")
        model.notice = "这天没写"
        XCTAssertFalse(model.presentsNotice(active: false))
        XCTAssertEqual(model.notice, "这天没写", "不弹也不丢")
        XCTAssertTrue(model.presentsNotice(active: true))

        model.clear()
        XCTAssertNil(model.notice, "换楼层清掉旧提示")
        XCTAssertNil(MemoryTimelineModel.regenerateNotice(day: "d", report: nil, timelineEnabled: false), "时间轴关着不报")
        XCTAssertNil(MemoryTimelineModel.regenerateNotice(day: "d", report: { var r = TimelineDaily.Report(); r.written = ["d"]; return r }(),
                                                          timelineEnabled: true), "写成了不弹")
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

    /// 底栏胶囊画出来的是新四格（粟粟 10-24），老的「窗口总结」「时间轴」不再单独占格
    @MainActor
    func testBottomBarRendersFourTabTitles() async throws {
        try await assertRenderedMemoryPanel(
            expected: ["记忆", "窗口时间轴", "wiki", "审计台"],
            absent: ["窗口总结"]
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
