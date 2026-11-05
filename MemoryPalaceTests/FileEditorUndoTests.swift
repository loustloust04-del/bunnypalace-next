import AppKit
import SwiftUI
import XCTest
import WebKit
@testable import 记忆花园

/// A0：mac 源码模式 ⌘Z / ⇧⌘Z 走 FileEditorSheet 里 TextEditor 底下的 NSTextView。
/// 把真的 sheet 挂进窗口（.txt = 只有源码模式），确认文本视图开着撤销、撤销后绑定跟着回去
@MainActor
final class FileEditorUndoTests: XCTestCase {

    func testMacSourceEditorUndoRedo() throws {
        let sheet = FileEditorSheet(
            path: "notes/undo-probe.txt",
            initialContent: "原文",
            initialModifiedAt: nil,
            currentModifiedAt: { nil },
            reloadExternalContent: { ReloadedFileContent(content: "原文", modifiedAt: nil) },
            onSave: { _, _ in },
            onCancel: {}
        )
        let hosting = NSHostingView(rootView: sheet)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        spinRunLoop()

        let textView = try XCTUnwrap(findTextView(in: hosting), "源码模式应有 NSTextView")
        XCTAssertEqual(textView.string, "原文")
        XCTAssertTrue(textView.allowsUndo, "源码模式 NSTextView 必须开撤销，⌘Z 才有用")

        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("新加的字", replacementRange: textView.selectedRange())
        spinRunLoop()
        XCTAssertEqual(textView.string, "原文新加的字")

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        spinRunLoop()
        XCTAssertEqual(textView.string, "原文", "⌘Z 应撤回打的字")

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        spinRunLoop()
        XCTAssertEqual(textView.string, "原文新加的字", "⇧⌘Z 应重做")
    }

    func testLiveSnapshotAndConfigurationPreserveUndoRedo() async throws {
        let fixture = EditorFixture()
        let (window, webView) = try await hostEditor(FixtureEditor(fixture: fixture))
        defer { window.close() }
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ selection: { anchor: 2 } });
            view.dispatch({
              changes: { from: 2, insert: "新字" }, selection: { anchor: 4 }, userEvent: "input"
            });
            flushContentChanged();
            true;
            """)
        try await waitForNative { fixture.document.content == "原文新字" }
        fixture.showsLineNumbers = true
        fixture.findQuery = "新字"
        try await waitForJavaScript(
            "!document.documentElement.classList.contains('mp-hide-gutters') && currentFindQuery === '新字'",
            in: webView
        )
        try await assertLiveState(webView, equals: ["原文新字", "4", "1", "0"])
        _ = try await webView.evaluateJavaScript("MPCodeMirror.undo(view); flushContentChanged(); true;")
        try await waitForNative { fixture.document.content == "原文" }
        try await assertLiveState(webView, equals: ["原文", "2", "0", "1"])
        _ = try await webView.evaluateJavaScript("MPCodeMirror.redo(view); flushContentChanged(); true;")
        try await waitForNative { fixture.document.content == "原文新字" }
        try await assertLiveState(webView, equals: ["原文新字", "4", "1", "0"])
    }

    func testNativeReplacementsUndoWholeStepsAndIsolateFollowingInput() async throws {
        let fixture = EditorFixture()
        let (window, webView) = try await hostEditor(FixtureEditor(fixture: fixture))
        defer { window.close() }
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ changes: { from: 2, insert: "未回报" }, userEvent: "input" });
            true;
            """)
        for (index, text) in ["原文恢复", "原文未回报", ""].enumerated() {
            fixture.document.replace(with: text)
            try await waitForJavaScript("nativeRevision === \(index + 1)", in: webView)
            let actual = try await webView.evaluateJavaScript("currentContent()") as? String
            XCTAssertEqual(actual, text)
        }
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ changes: { from: 0, insert: "后输" }, userEvent: "input" });
            true;
            """)
        for text in ["", "原文未回报", "原文恢复", "原文未回报", "原文"] {
            let handled = try await webView.evaluateJavaScript("runMarkdownCommand('undo')") as? Bool
            XCTAssertEqual(handled, true)
            _ = try await webView.evaluateJavaScript("flushContentChanged(); true;")
            try await waitForNative { fixture.document.content == text }
            let actual = try await webView.evaluateJavaScript("currentContent()") as? String
            XCTAssertEqual(actual, text, "外部写入必须整步撤回，不能只映射旧历史留下拼接")
        }
        let exhausted = try await webView.evaluateJavaScript("runMarkdownCommand('undo')") as? Bool
        XCTAssertEqual(exhausted, false, "初始正文不能撤成空文件")
        for text in ["原文未回报", "原文恢复", "原文未回报", "", "后输"] {
            let handled = try await webView.evaluateJavaScript("runMarkdownCommand('redo')") as? Bool
            XCTAssertEqual(handled, true)
            _ = try await webView.evaluateJavaScript("flushContentChanged(); true;")
            try await waitForNative { fixture.document.content == text }
            let actual = try await webView.evaluateJavaScript("currentContent()") as? String
            XCTAssertEqual(actual, text)
        }
    }

    func testUnchangedNativeWriteKeepsRedoAndChangedWriteReplacesRedoBranch() async throws {
        let fixture = EditorFixture()
        let (window, webView) = try await hostEditor(FixtureEditor(fixture: fixture))
        defer { window.close() }
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ changes: { from: 2, insert: "尾" }, userEvent: "input" });
            runMarkdownCommand("undo");
            flushContentChanged();
            true;
            """)
        try await waitForNative { fixture.document.revision == 2 }
        fixture.document.replace(with: "原文")
        try await waitForJavaScript("nativeRevision === 1", in: webView)
        let redone = try await webView.evaluateJavaScript("runMarkdownCommand('redo')") as? Bool
        XCTAssertEqual(redone, true, "无净变化不能清掉重做或制造历史步")
        let typed = try await webView.evaluateJavaScript("currentContent()") as? String
        XCTAssertEqual(typed, "原文尾")
        _ = try await webView.evaluateJavaScript("runMarkdownCommand('undo'); true;")
        fixture.document.replace(with: "新正文")
        try await waitForJavaScript("nativeRevision === 2", in: webView)
        let obsoleteRedo = try await webView.evaluateJavaScript("runMarkdownCommand('redo')") as? Bool
        XCTAssertEqual(obsoleteRedo, false, "新外部写入应截断已撤回的旧重做分支")
        _ = try await webView.evaluateJavaScript("runMarkdownCommand('undo'); true;")
        let original = try await webView.evaluateJavaScript("currentContent()") as? String
        XCTAssertEqual(original, "原文")
        let exhausted = try await webView.evaluateJavaScript("runMarkdownCommand('undo')") as? Bool
        XCTAssertEqual(exhausted, false)
    }

    func testOpeningAnotherDocumentDoesNotInheritHistoryOrUndoToEmpty() async throws {
        let (firstWindow, firstWebView) = try await hostLiveEditor()
        _ = try await firstWebView.evaluateJavaScript("""
            view.dispatch({ changes: { from: 2, insert: "第一份编辑" }, userEvent: "input" });
            true;
            """)
        firstWindow.close()
        let (window, webView) = try await hostLiveEditor(content: "另一份正文")
        defer { window.close() }
        let handled = try await webView.evaluateJavaScript(
            "[runMarkdownCommand('undo'), runMarkdownCommand('redo')]"
        ) as? [Bool]
        XCTAssertEqual(handled, [false, false])
        let current = try await webView.evaluateJavaScript("currentContent()") as? String
        XCTAssertEqual(current, "另一份正文")
    }

    func testExplicitNativeWritesWinPendingInputAndRejectTwoLateSnapshots() async throws {
        let fixture = EditorFixture()
        let (window, webView) = try await hostEditor(FixtureEditor(fixture: fixture))
        defer { window.close() }
        _ = try await webView.evaluateJavaScript("""
            for (let i = 0; i < 3; i++) {
              view.dispatch({ changes: { from: view.state.doc.length, insert: "未回报" }, userEvent: "input" });
            }
            true;
            """)
        fixture.document.replace(with: "原文")
        try await waitForJavaScript("nativeRevision === 1 && currentContent() === '原文'", in: webView)
        fixture.document.replace(with: "第二次")
        try await waitForJavaScript("nativeRevision === 2 && currentContent() === '第二次'", in: webView)
        _ = try await webView.evaluateJavaScript("""
            memoryPalaceNative.receive({ type: "replaceDocument", content: "重复坏正文", nativeRevision: 2 });
            memoryPalaceNative.receive({ type: "replaceDocument", content: "更旧正文", nativeRevision: 1 });
            bridge.postMessage({ type: "contentChanged", content: "迟到一", nativeRevision: 0, revision: 500 });
            bridge.postMessage({ type: "contentChanged", content: "迟到二", nativeRevision: 1, revision: 501 });
            bridge.postMessage({ type: "requestSave", content: "旧保存", nativeRevision: 1, revision: 502 });
            requestSave();
            true;
            """)
        try await waitForNative { !fixture.saved.isEmpty }
        XCTAssertEqual(fixture.document.content, "第二次")
        XCTAssertEqual(fixture.saved, ["第二次"])
        let current = try await webView.evaluateJavaScript("currentContent()") as? String
        XCTAssertEqual(current, "第二次")
    }

    func testLargeDocumentConfigurationPreservesUnreportedTailAndSave() async throws {
        let fixture = EditorFixture()
        let (window, webView) = try await hostEditor(FixtureEditor(fixture: fixture))
        defer { window.close() }
        let large = String(repeating: "段落内容abcdefghij\n", count: 12000)
        fixture.document.replace(with: large)
        try await waitForJavaScript("nativeRevision === 1", in: webView)
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({
              changes: { from: view.state.doc.length, insert: "尾字" },
              selection: { anchor: view.state.doc.length + 2 }, userEvent: "input"
            });
            true;
            """)
        fixture.showsLineNumbers = true
        fixture.findQuery = "尾字"
        try await waitForJavaScript("currentFindQuery === '尾字'", in: webView)
        _ = try await webView.evaluateJavaScript("requestSave(); true;")
        try await waitForNative { !fixture.saved.isEmpty }
        XCTAssertTrue(fixture.saved == [large + "尾字"], "大文件配置重算不能覆盖未回报的末尾，立即保存必须完整")
    }

    func testIOSBeforeInputUsesDOMCaretAndEditsExactlyOnce() async throws {
        let (window, webView) = try await hostLiveEditor()
        defer { window.close() }
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ effects: MPCodeMirror.StateEffect.appendConfig.of(createIOSInputExtension()) });
            view.focus();
            const caret = view.domAtPos(1);
            document.getSelection().setBaseAndExtent(caret.node, caret.offset, caret.node, caret.offset);
            view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", {
              key: "Enter", keyCode: 13, bubbles: true, cancelable: true
            }));
            view.contentDOM.dispatchEvent(new InputEvent("beforeinput", {
              inputType: "insertParagraph", bubbles: true, cancelable: true
            }));
            true;
            """)
        try await assertLiveState(webView, equals: ["原\n文", "2", "1", "0"])
        _ = try await webView.evaluateJavaScript("MPCodeMirror.undo(view); true;")
        try await assertLiveState(webView, equals: ["原文", "1", "0", "1"])
    }

    func testIOSCrossLineDeleteFallbackSuppressesLateBeforeInput() async throws {
        let (window, webView) = try await hostLiveEditor(content: "甲\n乙")
        defer { window.close() }
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ effects: MPCodeMirror.StateEffect.appendConfig.of(createIOSInputExtension()) });
            view.focus();
            view.dispatch({ selection: { anchor: 2 } });
            view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", {
              key: "Backspace", keyCode: 8, bubbles: true, cancelable: true
            }));
            true;
            """)
        try await waitForJavaScript("currentContent() === '甲乙'", in: webView)
        _ = try await webView.evaluateJavaScript("""
            view.contentDOM.dispatchEvent(new InputEvent("beforeinput", {
              inputType: "deleteContentBackward", bubbles: true, cancelable: true
            }));
            true;
            """)
        try await assertLiveState(webView, equals: ["甲乙", "1", "1", "0"])
        _ = try await webView.evaluateJavaScript("MPCodeMirror.undo(view); true;")
        try await assertLiveState(webView, equals: ["甲\n乙", "2", "0", "1"])
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ selection: { anchor: 1 } });
            view.contentDOM.dispatchEvent(new InputEvent("beforeinput", {
              inputType: "deleteContentForward", bubbles: true, cancelable: true
            }));
            true;
            """)
        try await assertLiveState(webView, equals: ["甲乙", "1", "1", "0"])
    }

    func testUndoKeepsSourceRevealUntilActualCursorMove() async throws {
        let (window, webView) = try await hostLiveEditor()
        defer { window.close() }
        _ = try await webView.evaluateJavaScript("""
            replaceEditorDocument("[链](https://example.test/long-target)", 10);
            view.focus();
            view.dispatch({ selection: { anchor: view.state.doc.length } });
            view.dispatch({
              changes: { from: view.state.doc.length, insert: "\\n" },
              selection: { anchor: view.state.doc.length + 1 }, userEvent: "input"
            });
            view.dispatch({
              changes: { from: view.state.doc.length, insert: "尾" },
              selection: { anchor: view.state.doc.length + 1 }, userEvent: "input",
              annotations: MPCodeMirror.Transaction.time.of(Date.now() + 1000)
            });
            MPCodeMirror.undo(view);
            true;
            """)
        let revealed = try await webView.evaluateJavaScript("view.contentDOM.querySelector('.cm-line').textContent") as? String
        XCTAssertEqual(revealed, "[链](https://example.test/long-target)")
        _ = try await webView.evaluateJavaScript("""
            view.dispatch({ selection: { anchor: 0 } });
            view.dispatch({ selection: { anchor: view.state.doc.length } });
            true;
            """)
        let collapsed = try await webView.evaluateJavaScript("view.contentDOM.querySelector('.cm-line').textContent") as? String
        XCTAssertEqual(collapsed, "链", "真正移动光标后，离开的链接行才收回预览")
    }

    func testTableGestureDefersReflowUntilPointerRelease() async throws {
        let (window, webView) = try await hostLiveEditor()
        defer { window.close() }
        let stable = try await webView.evaluateJavaScript("""
            replaceEditorDocument("前\\n\\n| A | B |\\n| --- | --- |\\n| C | D |\\n\\n尾", 10);
            view.dispatch({ selection: { anchor: view.state.doc.length } });
            const tailBefore = view.coordsAtPos(view.state.doc.length).top;
            view.contentDOM.dispatchEvent(new PointerEvent("pointerdown", { pointerId: 1, bubbles: true }));
            view.dispatch({ selection: { anchor: 5 }, userEvent: "select.pointer" });
            const stable = !!document.querySelector(".mp-md-table-widget") &&
              view.coordsAtPos(view.state.doc.length).top === tailBefore;
            const nextFrame = [];
            const requestFrame = window.requestAnimationFrame;
            window.requestAnimationFrame = callback => { nextFrame.push(callback); return 0; };
            try {
              document.dispatchEvent(new PointerEvent("pointerup", { pointerId: 1, bubbles: true }));
            } finally {
              window.requestAnimationFrame = requestFrame;
            }
            for (const callback of nextFrame) callback(performance.now());
            stable;
            """) as? Bool
        XCTAssertEqual(stable, true, "手势中不能把表格换成源码而移动下面的正文")
        try await waitForJavaScript("document.querySelector('.mp-md-table-widget') === null", in: webView)
        let source = try await webView.evaluateJavaScript(
            "Array.from(view.contentDOM.querySelectorAll('.cm-line')).some(line => line.textContent === '| A | B |')"
        ) as? Bool
        XCTAssertEqual(source, true)
    }

    @MainActor
    private final class EditorFixture: ObservableObject {
        @Published var document = MarkdownWebEditorDocument(content: "原文")
        @Published var showsLineNumbers = false
        @Published var findQuery = ""
        var saved: [String] = []
    }

    private struct FixtureEditor: View {
        @ObservedObject var fixture: EditorFixture

        var body: some View {
            MarkdownWebEditorView(
                document: $fixture.document,
                findQuery: fixture.findQuery,
                showsLineNumbers: fixture.showsLineNumbers,
                onRequestSave: { fixture.saved.append(fixture.document.content) }
            )
        }
    }

    private func hostLiveEditor(content: String = "原文") async throws -> (NSWindow, WKWebView) {
        try await hostEditor(FileEditorSheet.text(
            title: "编辑器回归", text: content, format: .markdown,
            onSave: { _ in }, onCancel: {}
        ))
    }

    private func hostEditor<Editor: View>(_ editor: Editor) async throws -> (NSWindow, WKWebView) {
        let hosting = NSHostingView(rootView: editor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        spinRunLoop()
        do {
            let webView = try XCTUnwrap(findWebView(in: hosting))
            try await waitForJavaScript(
                "typeof view !== 'undefined' && view !== null && nativeRevision === 0 && positionRestored",
                in: webView
            )
            return (window, webView)
        } catch {
            window.close()
            throw error
        }
    }

    private func waitForNative(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待原生正文状态超时")
    }

    private func assertLiveState(_ webView: WKWebView, equals expected: [String]) async throws {
        let state = try await webView.evaluateJavaScript("""
            [currentContent(), String(view.state.selection.main.head),
             String(MPCodeMirror.undoDepth(view.state)), String(MPCodeMirror.redoDepth(view.state))]
            """) as? [String]
        XCTAssertEqual(state, expected)
    }

    private func waitForJavaScript(_ expression: String, in webView: WKWebView) async throws {
        for _ in 0..<500 {
            if !webView.isLoading,
               (try? await webView.evaluateJavaScript(expression)) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待编辑器状态超时：\(expression)")
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
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
