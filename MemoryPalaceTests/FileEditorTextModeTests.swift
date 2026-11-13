import MemoryCore
import AppKit
import SwiftUI
import SwiftData
import XCTest
import WebKit
import Vision
@testable import 记忆花园

/// A1：`FileEditorSheet.text(...)` 编辑一段不是文件的文本——顶栏显示 title、保存回调拿到改后的文本、.plain 只有源码模式
@MainActor
final class FileEditorTextModeTests: XCTestCase {

    func testPlainTextShowsTitleSourceOnlyAndSavesEditedText() throws {
        var saved: [String] = []
        let sheet = FileEditorSheet.text(
            title: "角色卡 · 描述",
            text: "原文",
            format: .plain,
            onSave: { saved.append($0) },
            onCancel: {}
        )
        XCTAssertEqual(sheet.displayTitle, "角色卡 · 描述")
        XCTAssertEqual(sheet.availableModes, [.source])

        let (window, hosting) = host(sheet)
        defer { window.close() }
        XCTAssertEqual(window.title, "角色卡 · 描述", "顶栏显示 title，不露虚拟 path")

        let textView = try XCTUnwrap(findTextView(in: hosting), ".plain 应是源码模式 NSTextView")
        XCTAssertEqual(textView.string, "原文")
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("改过", replacementRange: textView.selectedRange())
        spinRunLoop()

        // ⌘S = 顶栏「保存」
        let cmdS = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
        ))
        XCTAssertTrue(window.performKeyEquivalent(with: cmdS))
        spinRunLoop()
        XCTAssertEqual(saved, ["原文改过"])
    }

    func testMarkdownTextKeepsAllMarkdownModes() {
        let sheet = FileEditorSheet.text(title: "系统提示词", text: "# 你好", format: .markdown, onSave: { _ in }, onCancel: {})
        XCTAssertEqual(sheet.displayTitle, "系统提示词")
        XCTAssertEqual(sheet.availableModes, [.live, .preview, .source])
    }

    func testFileLibrarySheetStillShowsPath() {
        let sheet = FileEditorSheet(
            path: "notes/a.md",
            initialContent: "",
            initialModifiedAt: nil,
            currentModifiedAt: { nil },
            reloadExternalContent: { ReloadedFileContent(content: "", modifiedAt: nil) },
            onSave: { _, _ in },
            onCancel: {}
        )
        XCTAssertEqual(sheet.displayTitle, "notes/a.md")
    }

    func testReadOnlyRunPreviewScrollsToStructuredAnchorAndRetainsBothEnds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let run = CatalogRunRecord(wiki: wiki, topic: "定位回归", kind: "合成测试")
        let before = (0..<160).map { "前文第 \($0) 段，完整保留的材料，不应因为定位到后面就裁掉。" }.joined(separator: "\n\n")
        let after = (0..<160).map { "后文第 \($0) 段，完整保留的工具结果，不应因为定位而截断。" }.joined(separator: "\n\n")
        run.section("首部完整", body: before)
        let anchor = run.section("第 3 轮 · 定位目标", body: after)
        run.section("末尾完整", body: "最后的输出也应存在")
        await run.flush()
        let entry = MemoryWriteLog.Entry(time: Date(), writer: "C3", ok: true, note: "正文不参与定位", model: "", run: run.link(anchor: anchor))
        guard case .loaded(let record) = await MemoryWriteLogRunReader.load(entry, wiki: wiki) else {
            return XCTFail("临时运行记录应能读出")
        }
        let sheet = FileEditorSheet(
            path: record.link.path, initialContent: record.content, initialModifiedAt: nil,
            readOnly: true, initialAnchor: record.link.anchor,
            currentModifiedAt: { XCTFail("只读不查外部改动"); return nil },
            reloadExternalContent: { XCTFail("只读不重载"); return ReloadedFileContent(content: "", modifiedAt: nil) },
            onSave: { _, _ in XCTFail("只读不能保存") }, onCancel: {},
            versionKey: .file(profileId: "test", relativePath: "run.md"),
            wikiHistory: WikiHistoryTarget(store: wiki, path: "主题/测试", expectedVersion: nil,
                                           onRestored: { _, _ in XCTFail("只读不能恢复历史") })
        )
        XCTAssertEqual(sheet.availableModes, [.preview])
        XCTAssertNil(sheet.versionKey)
        XCTAssertNil(sheet.wikiHistory)
        XCTAssertEqual(sheet.initialContent, record.content)
        XCTAssertNil(sheet.initialPreviewLocation, "整理记录的整份分节在后台做，init 里不扫")
        XCTAssertEqual(try RunRecordDocument.parse(content: record.content, anchor: record.link.anchor).sectionStarts.count, 4, "标题段 + 三节都在")

        let (window, hosting) = host(sheet, fixedSize: true)
        defer { window.close() }
        window.orderFront(nil)
        try await waitForState(onTimeout: { self.attachPreviewSnapshot(hosting, stage: "anchor") }) {
            hosting.layoutSubtreeIfNeeded()
            return (self.previewScrollView(in: hosting)?.contentView.bounds.minY ?? 0) > 500
        }
        let scroll = try XCTUnwrap(previewScrollView(in: hosting))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500, "不能只存在锚点，实际滚动偏移也必须改变")
        XCTAssertNil(findTextView(in: hosting), "只读不能创建可编辑文本视图")
        XCTAssertNil(findWebView(in: hosting), "只读不能创建实时编辑器")
        let visible = try await waitForVisiblePreviewText("第3轮定位目标", in: hosting, stage: "anchor", nearTop: true)
        XCTAssertFalse(visible.contains("保存"))
        XCTAssertFalse(visible.contains("历史"))

        for _ in 0..<10 {
            try await FileEditorPreviewTestDriver.scroll(scroll, end: false)
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await waitForVisiblePreviewText("首部完整", in: hosting, stage: "start")
        for _ in 0..<10 {
            try await FileEditorPreviewTestDriver.scroll(scroll, end: true)
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await waitForVisiblePreviewText("末尾完整", in: hosting, stage: "end")
        XCTAssertNil(findModePicker(in: hosting))
    }

    private func waitForVisiblePreviewText(
        _ text: String, in view: NSView, stage: String, nearTop: Bool = false
    ) async throws -> [String] {
        var lines: [(String, CGRect)] = []
        for _ in 0..<80 {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let pixels = bitmap.cgImage {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: pixels).perform([request])
                    lines = (request.results ?? []).compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        return (candidate.string.filter { $0.isLetter || $0.isNumber }, observation.boundingBox)
                    }
                    // Vision 的 bbox 原点在左下：maxY > .72 = 标题在截图顶部 180pt 内。
                    if lines.contains(where: { $0.0.contains(text) && (!nearTop || $0.1.maxY > 0.72) }) {
                        attachPreviewSnapshot(view, stage: stage)
                        print("C3只读预览OCR[\(stage)]：\(lines)")
                        return lines.map(\.0)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        attachPreviewSnapshot(view, stage: stage)
        XCTFail("C3只读预览截图未显示\(nearTop ? "顶部" : "")标题 \(text)，OCR：\(lines)")
        return lines.map(\.0)
    }

    private func previewScrollView(in view: NSView) -> NSScrollView? {
        var candidates: [NSScrollView] = []
        if let scroll = view as? NSScrollView { candidates.append(scroll) }
        for subview in view.subviews {
            if let scroll = previewScrollView(in: subview) { candidates.append(scroll) }
        }
        return candidates.filter(\.hasVerticalScroller).max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
    }

    private func attachPreviewSnapshot(_ view: NSView, stage: String) {
        print("C3只读预览截图[\(stage)] window=\(String(describing: view.window?.frame)) host=\(view.frame) scroll=\(String(describing: previewScrollView(in: view)?.contentView.bounds))")
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let name = "c3-log-preview-\(stage).png"
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWikiLinkRoundTripRefreshesSavedBaseline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-round-trip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root)
        let path = "主题/回页A", other = "主题/回页B"
        try wiki.saveRaw("# 打开时A\n\n[[\(other)]]", path: path)
        try wiki.saveRaw("# 另一页B\n\n[[\(path)]]", path: other)
        let target = try XCTUnwrap(WikiPageTarget.load(store: wiki, path: path))
        let (window, hosting) = host(WikiPageEditorSheet(initial: target))
        defer { window.close() }
        window.orderFront(nil)

        func editor(showing title: String) async throws -> WKWebView {
            try await waitForState {
                guard let web = self.findWebView(in: hosting) else { return false }
                return (try? await web.evaluateJavaScript(
                    "typeof view !== 'undefined' && view !== null && currentContent().includes('\(title)')"
                )) as? Bool == true
            }
            return try XCTUnwrap(findWebView(in: hosting))
        }

        let first = try await editor(showing: "打开时A")
        let saved = "# 人工初存A\n\n[[\(other)]]"
        _ = try await first.evaluateJavaScript("""
            view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "# 人工初存A\\n\\n[[主题/回页B]]" }, userEvent: "input" });
            requestSave(); true;
            """)
        try await waitForState { wiki.readRaw(path) == saved }
        let changed = "# 别处改版A\n\n[[\(other)]]"
        try await WikiEditing.save(changed, baseline: saved, store: wiki, path: path)

        _ = try await first.evaluateJavaScript("post({ type: 'openWikiLink', target: '主题/回页B' }); true;")
        let second = try await editor(showing: "另一页B")
        _ = try await second.evaluateJavaScript("post({ type: 'openWikiLink', target: '主题/回页A' }); true;")
        let reopened = try await editor(showing: "别处改版A")
        _ = try await reopened.evaluateJavaScript("""
            view.dispatch({ changes: { from: view.state.doc.length, insert: "\\n人工续写" }, userEvent: "input" });
            requestSave(); true;
            """)
        try await waitForState { wiki.readRaw(path) == changed + "\n人工续写" }
        XCTAssertEqual(wiki.readRaw(path), changed + "\n人工续写", "回页后用新基线保存，不能误报冲突或覆盖别处改版")
    }

    func testWikiEditorKeepsDraftAndSavedBaselineAcrossProfileSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-switch-\(UUID().uuidString)")
        let suite = "wiki-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let first = Profile(name: "原楼层", emoji: "", description: "", userName: "小舟", assistantName: "砚")
        let second = Profile(name: "另一层", emoji: "", description: "", userName: "小舟", assistantName: "砚")
        let profiles = ProfileManager(container: container, profiles: [first, second], currentProfile: first,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let path = "主题/虚构航线"
        let target = try await Task.detached {
            try wiki.saveRaw("# 航线", path: path)
            return try XCTUnwrap(WikiPageTarget.load(store: wiki, path: path))
        }.value
        var dismissed = false
        struct Presenter: View {
            let target: WikiPageTarget
            let onDismiss: () -> Void
            @State private var presented = false

            var body: some View {
                Color.clear
                    .sheet(isPresented: $presented, onDismiss: onDismiss) { WikiPageEditorSheet(initial: target) }
                    .onAppear { presented = true }
            }
        }
        let (window, _) = host(Presenter(target: target, onDismiss: { dismissed = true }).environment(profiles), fixedSize: true)
        defer { window.close() }
        window.orderFront(nil)
        var editorWindow: NSWindow?
        var editorWeb: WKWebView?
        try await waitForState {
            for candidate in NSApp.windows {
                guard let content = candidate.contentView, let web = self.findWebView(in: content) else { continue }
                if (try? await web.evaluateJavaScript("typeof view !== 'undefined' && view !== null && currentContent() === '# 航线'")) as? Bool == true {
                    editorWindow = candidate
                    editorWeb = web
                    return true
                }
            }
            return false
        }
        let sheet = try XCTUnwrap(editorWindow)
        let web = try XCTUnwrap(editorWeb)
        defer { sheet.close() }
        sheet.makeKeyAndOrderFront(nil)
        _ = try await web.evaluateJavaScript("""
            view.dispatch({ changes: { from: view.state.doc.length, insert: "\\n未存草稿" }, userEvent: "input" }); true;
            """)
        NotificationCenter.default.post(name: .profileWillSwitch, object: nil)
        profiles.switchTo(second)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(dismissed)
        XCTAssertTrue(sheet.isVisible)
        let draft = try await web.evaluateJavaScript("currentContent()") as? String
        XCTAssertEqual(draft, "# 航线\n未存草稿")
        _ = try await web.evaluateJavaScript("requestSave(); true;")
        try await waitForState { wiki.readRaw(path) == "# 航线\n未存草稿" }
        _ = try await web.evaluateJavaScript("""
            view.dispatch({ changes: { from: view.state.doc.length, insert: "\\n再次保存" }, userEvent: "input" });
            requestSave(); true;
            """)
        try await waitForState { wiki.readRaw(path) == "# 航线\n未存草稿\n再次保存" }
        print("A4 UI smoke: 原生编辑器切楼层保留草稿，原页连续保存两次")
    }

    func testWikiDeleteFromAnotherProfileShowsAlertWithoutDeleting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-delete-switch-\(UUID().uuidString)")
        let suite = "wiki-delete-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let first = Profile(name: "原楼层", emoji: "", description: "", userName: "小舟", assistantName: "砚")
        let second = Profile(name: "另一层", emoji: "", description: "", userName: "小舟", assistantName: "砚")
        let profiles = ProfileManager(container: container, profiles: [first, second], currentProfile: second,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let path = "主题/虚构航线"
        let version = try await Task.detached { try wiki.saveRaw("# 航线", path: path) }.value
        var target: WikiDeletionTarget? = .init(profileId: first.id, store: wiki, path: path, title: "航线", expectedVersion: version)
        let presenter = Color.clear.modifier(WikiDeleteConfirmation(
            target: Binding(get: { target }, set: { target = $0 }), hasUnsavedEdits: false,
            onDeleted: { _ in XCTFail("楼层不符不能删除") })).environment(profiles)
        let (window, _) = host(presenter)
        defer { window.close() }
        window.orderFront(nil)
        try await waitForState { window.attachedSheet != nil }
        XCTAssertNil(target)
        XCTAssertEqual(wiki.readRaw(path), "# 航线")
        let alert = try XCTUnwrap(window.attachedSheet?.contentView)
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        XCTAssertTrue(fields(alert).contains { $0.stringValue == "已切换楼层，回原楼层再删" })
        print("A4 UI smoke: 原生删除提示已显示「已切换楼层，回原楼层再删」，正文未删")
    }

    func testTypingFormattingAndSourceCommitUndoAsSeparateStepsAndSaveTail() async throws {
        var saved: [String] = []
        let sheet = FileEditorSheet.text(
            title: "模式回归", text: "原文", format: .markdown,
            onSave: { saved.append($0) }, onCancel: {}
        )
        let (window, hosting) = host(sheet)
        defer { window.close() }
        window.orderFront(nil)
        let webView = try XCTUnwrap(findWebView(in: hosting))
        try await waitForState {
            (try? await webView.evaluateJavaScript(
                "typeof view !== 'undefined' && view !== null && currentContent() === '原文' && nativeRevision === 0"
            )) as? Bool == true
        }
        let picker = try XCTUnwrap(findModePicker(in: hosting))
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ changes: { from: 2, insert: "末尾" }, selection: { anchor: 4 }, userEvent: "input" });
            view.dispatch({ selection: { anchor: 2, head: 4 } });
            runMarkdownCommand("bold");
            true;
            """)
        picker.selectedSegment = 2
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        try await waitForState { self.findTextView(in: hosting)?.string == "原文**末尾**" }
        let source = try XCTUnwrap(findTextView(in: hosting))
        XCTAssertTrue(window.makeFirstResponder(source))
        source.setSelectedRange(NSRange(location: (source.string as NSString).length, length: 0))
        source.insertText("源码", replacementRange: source.selectedRange())
        source.insertText("再改", replacementRange: source.selectedRange())
        spinRunLoop()
        let staged = try await webView.evaluateJavaScript("currentContent()") as? String
        XCTAssertEqual(staged, "原文**末尾**", "源码逐键编辑不能推给隐藏 CM")
        picker.selectedSegment = 0
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        try await waitForState {
            (try? await webView.evaluateJavaScript(
                "currentContent() === '原文**末尾**源码再改' && nativeRevision === 1"
            )) as? Bool == true
        }
        for text in ["原文**末尾**", "原文末尾", "原文"] {
            let handled = try await webView.evaluateJavaScript("runMarkdownCommand('undo')") as? Bool
            XCTAssertEqual(handled, true)
            let current = try await webView.evaluateJavaScript("currentContent()") as? String
            XCTAssertEqual(current, text, "源码切回应合成一步，旧输入和格式步骤仍精确可撤")
        }
        let exhausted = try await webView.evaluateJavaScript("runMarkdownCommand('undo')") as? Bool
        XCTAssertEqual(exhausted, false)
        for text in ["原文末尾", "原文**末尾**", "原文**末尾**源码再改"] {
            let handled = try await webView.evaluateJavaScript("runMarkdownCommand('redo')") as? Bool
            XCTAssertEqual(handled, true)
            let current = try await webView.evaluateJavaScript("currentContent()") as? String
            XCTAssertEqual(current, text)
        }
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({
              changes: { from: view.state.doc.length, insert: "快存" },
              selection: { anchor: view.state.doc.length + 2 }, userEvent: "input"
            });
            requestSave();
            true;
            """)
        try await waitForState { !saved.isEmpty }
        XCTAssertEqual(saved, ["原文**末尾**源码再改快存"])
    }

    func testSourceEditsUndoneBeforeReturningKeepLiveRedo() async throws {
        let sheet = FileEditorSheet.text(
            title: "源码无净变化", text: "原文", format: .markdown,
            onSave: { _ in }, onCancel: {}
        )
        let (window, hosting) = host(sheet)
        defer { window.close() }
        window.orderFront(nil)
        let webView = try XCTUnwrap(findWebView(in: hosting))
        try await waitForState {
            (try? await webView.evaluateJavaScript(
                "typeof view !== 'undefined' && view !== null && nativeRevision === 0"
            )) as? Bool == true
        }
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ changes: { from: 2, insert: "末尾" }, userEvent: "input" });
            runMarkdownCommand("undo");
            true;
            """)
        let picker = try XCTUnwrap(findModePicker(in: hosting))
        picker.selectedSegment = 2
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        try await waitForState { self.findTextView(in: hosting)?.string == "原文" }
        let source = try XCTUnwrap(findTextView(in: hosting))
        XCTAssertTrue(window.makeFirstResponder(source))
        source.setSelectedRange(NSRange(location: 2, length: 0))
        source.insertText("临时", replacementRange: source.selectedRange())
        spinRunLoop()
        try XCTUnwrap(source.undoManager).undo()
        // 直接驱动 AppKit UndoManager 后补完整的文本编辑通知，不替 SwiftUI 写 Binding。
        source.didChangeText()
        spinRunLoop()
        XCTAssertEqual(findTextView(in: hosting)?.string, "原文")
        picker.selectedSegment = 0
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        try await waitForState {
            (try? await webView.evaluateJavaScript("editorActive")) as? Bool == true
        }
        let redone = try await webView.evaluateJavaScript("runMarkdownCommand('redo')") as? Bool
        XCTAssertEqual(redone, true, "源码无净修改，不能制造提交或截断实时模式重做")
        let current = try await webView.evaluateJavaScript("currentContent()") as? String
        XCTAssertEqual(current, "原文末尾")
        _ = try await webView.evaluateJavaScript("runMarkdownCommand('undo'); true;")
        let exhausted = try await webView.evaluateJavaScript("runMarkdownCommand('undo')") as? Bool
        XCTAssertEqual(exhausted, false)
    }

    private func waitForState(onTimeout: (() -> Void)? = nil, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        onTimeout?()
        XCTFail("等待模式 / 正文状态超时")
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }

    private func findModePicker(in view: NSView) -> NSSegmentedControl? {
        if let picker = view as? NSSegmentedControl { return picker }
        for subview in view.subviews {
            if let found = findModePicker(in: subview) { return found }
        }
        return nil
    }

    private func host<Content: View>(_ sheet: Content, fixedSize: Bool = false) -> (NSWindow, NSHostingView<Content>) {
        let hosting = NSHostingView(rootView: sheet)
        if fixedSize {
            hosting.sizingOptions = []
            hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
            hosting.autoresizingMask = [.width, .height]
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        spinRunLoop()
        return (window, hosting)
    }

    private func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isEditable { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }
}
