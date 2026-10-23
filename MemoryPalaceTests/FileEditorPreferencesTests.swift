import XCTest
@testable import 记忆花园

/// md 编辑 sheet 偏好默认值 + 工具出现规则（plan-file-editor-sheet）
final class FileEditorPreferencesTests: XCTestCase {

    func testDefaultsAreQuiet() {
        XCTAssertEqual(FileEditorKeyboardBarStyle.defaultStyle, .glass)
        XCTAssertFalse(FileEditorPreferences.formatBarExpandedDefault)
        XCTAssertFalse(FileEditorPreferences.showLineNumbersDefault)
    }

    func testKeysAreNewAndDistinct() {
        let keys = [FileEditorPreferences.keyboardBarStyleKey,
                    FileEditorPreferences.formatBarExpandedKey,
                    FileEditorPreferences.showLineNumbersKey]
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("fileEditor") })
    }

    func testStyleFromStoredValue() {
        XCTAssertEqual(FileEditorKeyboardBarStyle(stored: "glass"), .glass)
        XCTAssertEqual(FileEditorKeyboardBarStyle(stored: "keycap"), .keycap)
        XCTAssertEqual(FileEditorKeyboardBarStyle(stored: ""), .glass)
        XCTAssertEqual(FileEditorKeyboardBarStyle(stored: "rubbish"), .glass)
    }

    func testLineNumbersPreferencePersistsThroughDefaults() {
        let suite = "FileEditorPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.object(forKey: FileEditorPreferences.showLineNumbersKey))
        defaults.set(true, forKey: FileEditorPreferences.showLineNumbersKey)
        XCTAssertTrue(defaults.bool(forKey: FileEditorPreferences.showLineNumbersKey))
    }

    func testOwnFindOnlyInMarkdownLive() {
        XCTAssertTrue(FileEditorTools.ownFindAvailable(kind: .markdown, mode: .live))
        XCTAssertFalse(FileEditorTools.ownFindAvailable(kind: .markdown, mode: .preview))
        XCTAssertFalse(FileEditorTools.ownFindAvailable(kind: .markdown, mode: .source))
        XCTAssertFalse(FileEditorTools.ownFindAvailable(kind: .html, mode: .source))
    }

    func testFindMenuAvailability() {
        // iPhone：实时 + 源码（系统 findNavigator）
        XCTAssertTrue(FileEditorTools.findMenuAvailable(kind: .markdown, mode: .live, usesTopChrome: false))
        XCTAssertTrue(FileEditorTools.findMenuAvailable(kind: .text, mode: .source, usesTopChrome: false))
        XCTAssertFalse(FileEditorTools.findMenuAvailable(kind: .markdown, mode: .preview, usesTopChrome: false))
        // mac / iPad 宽屏：只有实时
        XCTAssertTrue(FileEditorTools.findMenuAvailable(kind: .markdown, mode: .live, usesTopChrome: true))
        XCTAssertFalse(FileEditorTools.findMenuAvailable(kind: .markdown, mode: .source, usesTopChrome: true))
        XCTAssertFalse(FileEditorTools.findMenuAvailable(kind: .html, mode: .split, usesTopChrome: true))
    }

    func testBottomBar() {
        XCTAssertEqual(FileEditorTools.bottomBar(mode: .live, keyboardVisible: false, findActive: false), .none)
        XCTAssertEqual(FileEditorTools.bottomBar(mode: .live, keyboardVisible: true, findActive: false), .format)
        XCTAssertEqual(FileEditorTools.bottomBar(mode: .source, keyboardVisible: true, findActive: false), .dismissOnly)
        XCTAssertEqual(FileEditorTools.bottomBar(mode: .preview, keyboardVisible: true, findActive: false), .none)
        // 查找优先，键盘收起时也在
        XCTAssertEqual(FileEditorTools.bottomBar(mode: .live, keyboardVisible: true, findActive: true), .find)
        XCTAssertEqual(FileEditorTools.bottomBar(mode: .live, keyboardVisible: false, findActive: true), .find)
    }
}
