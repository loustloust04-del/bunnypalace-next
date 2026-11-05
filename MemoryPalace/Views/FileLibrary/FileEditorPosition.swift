import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 编辑器再次打开回到上次位置（粟粟 10-15）：选区 + 视口顶上那行，都是 UTF-16 偏移——
/// CodeMirror 的文档位置和 UITextView / NSTextView 的 NSRange 同一单位，实时 / 源码两种模式共用一条。
/// key 同版本历史（文件 = 楼层 id + 相对路径；有 versionKey 的虚拟文本按它），不进 UserDefaults
/// （域膨胀卡过主线程），存 Application Support/MemoryPalace/editor-positions.json，最近用的 300 条。
@MainActor
final class FileEditorPositionStore {
    static let shared = FileEditorPositionStore()
    static let maxEntries = 300

    struct Position: Codable, Equatable {
        var anchor: Int
        var head: Int
        var top: Int
    }

    private struct Entry: Codable {
        let scope: String
        let name: String
        var position: Position
    }

    /// entries 旧→新，读写都挪到末尾
    private struct Table: Codable {
        var version = 1
        var entries: [Entry]
    }

    let url: URL
    private var entries: [Entry]?

    init(url: URL? = nil) {
        self.url = url ?? AppPaths.checked(AppPaths.applicationSupport
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("editor-positions.json"))
    }

    func position(for key: FileVersionStore.Key) -> Position? {
        loaded().first { $0.scope == key.scope && $0.name == key.name }?.position
    }

    func set(_ position: Position, for key: FileVersionStore.Key) {
        var list = loaded()
        if let index = list.firstIndex(where: { $0.scope == key.scope && $0.name == key.name }) {
            guard list[index].position != position || index != list.count - 1 else { return }
            list.remove(at: index)
        }
        list.append(Entry(scope: key.scope, name: key.name, position: position))
        if list.count > Self.maxEntries { list.removeFirst(list.count - Self.maxEntries) }
        save(list)
    }

    func remove(_ key: FileVersionStore.Key) {
        let list = loaded()
        let kept = list.filter { $0.scope != key.scope || $0.name != key.name }
        guard kept.count != list.count else { return }
        save(kept)
    }

    private func loaded() -> [Entry] {
        if let entries { return entries }
        let decoded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Table.self, from: $0) }
        entries = decoded?.entries ?? []
        return entries ?? []
    }

    private func save(_ list: [Entry]) {
        entries = list
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Table(entries: list)).write(to: url, options: .atomic)
        } catch {
            NSLog("存编辑位置失败：%@", error.localizedDescription)
        }
    }
}

/// 一个编辑器会话里最新的位置：网页报上来的、源码模式的文本视图读出来的。
/// 引用类型挂 @State，更新不触发重绘；关编辑器时落盘
@MainActor
final class FileEditorPositionTracker {
    var latest: FileEditorPositionStore.Position?
    #if os(macOS)
    weak var sourceTextView: NSTextView?
    #else
    weak var sourceTextView: UITextView?
    #endif

    /// 源码模式的文本视图还在就以它为准（切走源码 / 关编辑器时调）
    func captureSource() {
        guard let textView = sourceTextView, textView.window != nil else { return }
        latest = FileEditorSourcePosition.read(textView)
    }
}

/// 源码模式光标色 = 实时模式 CodeMirror 光标色（天空蓝，深色稍亮）
enum FileEditorCaret {
    static let lightHex = 0x3FA3E0
    static let darkHex = 0x7CC6F2

    static var hex: Int { Theme.activeScheme == .dark ? darkHex : lightHex }
    static var color: Color { Color(hex: UInt(hex)) }
    static var cssHex: String { String(format: "#%06X", hex) }
}

// MARK: - 源码模式（SwiftUI TextEditor 底下的 UITextView / NSTextView）

/// 挂在 TextEditor 的 background：找到同一位置的系统文本视图，交给 tracker；第一次找到时恢复位置、上光标色。
/// 只认 frame 盖住探针中心的那个文本视图，别摸到 sheet 底下页面里的
struct FileEditorSourceProbe {
    let tracker: FileEditorPositionTracker
    let restore: FileEditorPositionStore.Position?
}

enum FileEditorSourcePosition {
    #if os(macOS)
    static func read(_ textView: NSTextView) -> FileEditorPositionStore.Position {
        let selected = textView.selectedRange()
        let visible = textView.visibleRect
        let inset = textView.textContainerInset
        let top = textView.characterIndexForInsertion(at: NSPoint(x: inset.width + 1, y: visible.minY + inset.height + 1))
        return .init(anchor: selected.location, head: selected.location + selected.length, top: top)
    }

    static func apply(_ position: FileEditorPositionStore.Position, to textView: NSTextView) {
        let length = (textView.string as NSString).length
        let from = min(max(0, min(position.anchor, position.head)), length)
        let to = min(max(from, max(position.anchor, position.head)), length)
        textView.setSelectedRange(NSRange(location: from, length: to - from))
        let top = min(max(0, position.top), length)
        guard let window = textView.window else { return }
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: top, length: 0), actualRange: nil)
        let inView = textView.convert(window.convertFromScreen(screenRect), from: nil)
        textView.scroll(NSPoint(x: 0, y: max(0, inView.minY - textView.textContainerInset.height)))
    }
    #else
    static func read(_ textView: UITextView) -> FileEditorPositionStore.Position {
        let selected = textView.selectedRange
        let point = CGPoint(x: textView.textContainerInset.left + 1,
                            y: textView.contentOffset.y + textView.adjustedContentInset.top + textView.textContainerInset.top + 1)
        let topPosition = textView.closestPosition(to: point) ?? textView.beginningOfDocument
        let top = textView.offset(from: textView.beginningOfDocument, to: topPosition)
        return .init(anchor: selected.location, head: selected.location + selected.length, top: top)
    }

    static func apply(_ position: FileEditorPositionStore.Position, to textView: UITextView) {
        let length = (textView.text as NSString).length
        let from = min(max(0, min(position.anchor, position.head)), length)
        let to = min(max(from, max(position.anchor, position.head)), length)
        textView.selectedRange = NSRange(location: from, length: to - from)
        guard let target = textView.position(from: textView.beginningOfDocument, offset: min(max(0, position.top), length)) else { return }
        textView.layoutIfNeeded()
        let y = textView.caretRect(for: target).minY - textView.textContainerInset.top - textView.adjustedContentInset.top
        let maxY = max(-textView.adjustedContentInset.top,
                       textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: min(max(-textView.adjustedContentInset.top, y), maxY)), animated: false)
    }
    #endif
}

#if os(macOS)
extension FileEditorSourceProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onAttach = { [tracker, restore] probe in
            guard let textView = probe.findTextView() else { return false }
            textView.insertionPointColor = NSColor(FileEditorCaret.color)
            tracker.sourceTextView = textView
            if let position = tracker.latest ?? restore {
                FileEditorSourcePosition.apply(position, to: textView)
            }
            return true
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        /// 找到文本视图返回 true；TextEditor 可能比背景晚一拍上树，找不到隔一拍再找，最多 5 次
        var onAttach: ((ProbeView) -> Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            attach(attemptsLeft: 5)
        }

        private func attach(attemptsLeft: Int) {
            guard attemptsLeft > 0, let onAttach else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.window != nil else { return }
                if onAttach(self) { self.onAttach = nil } else { self.attach(attemptsLeft: attemptsLeft - 1) }
            }
        }

        func findTextView() -> NSTextView? {
            guard window != nil else { return nil }
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var ancestor = superview
            while let current = ancestor {
                if let hit = Self.textView(in: current, containing: center) { return hit }
                ancestor = current.superview
            }
            return nil
        }

        private static func textView(in view: NSView, containing point: NSPoint) -> NSTextView? {
            if let textView = view as? NSTextView, textView.isEditable,
               let scroll = textView.enclosingScrollView,
               scroll.convert(scroll.bounds, to: nil).contains(point) {
                return textView
            }
            for sub in view.subviews {
                if let hit = textView(in: sub, containing: point) { return hit }
            }
            return nil
        }
    }
}
#else
extension FileEditorSourceProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onAttach = { [tracker, restore] probe in
            guard let textView = probe.findTextView() else { return false }
            textView.tintColor = UIColor(FileEditorCaret.color)
            tracker.sourceTextView = textView
            if let position = tracker.latest ?? restore {
                FileEditorSourcePosition.apply(position, to: textView)
            }
            return true
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        /// 找到文本视图返回 true；TextEditor 可能比背景晚一拍上树，找不到隔一拍再找，最多 5 次
        var onAttach: ((ProbeView) -> Bool)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            attach(attemptsLeft: 5)
        }

        private func attach(attemptsLeft: Int) {
            guard attemptsLeft > 0, let onAttach else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.window != nil else { return }
                if onAttach(self) { self.onAttach = nil } else { self.attach(attemptsLeft: attemptsLeft - 1) }
            }
        }

        func findTextView() -> UITextView? {
            let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var ancestor = superview
            while let current = ancestor {
                if let hit = Self.textView(in: current, containing: center) { return hit }
                ancestor = current.superview
            }
            return nil
        }

        private static func textView(in view: UIView, containing point: CGPoint) -> UITextView? {
            if let textView = view as? UITextView, textView.isEditable,
               textView.convert(textView.bounds, to: nil).contains(point) {
                return textView
            }
            for sub in view.subviews {
                if let hit = textView(in: sub, containing: point) { return hit }
            }
            return nil
        }
    }
}
#endif
