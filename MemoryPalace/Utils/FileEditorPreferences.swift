import Foundation

/// md 编辑 sheet 的偏好键（plan-file-editor-sheet）。只新增键，不动旧键。
enum FileEditorPreferences {
    static let keyboardBarStyleKey = "fileEditorKeyboardBarStyle"
    static let formatBarExpandedKey = "fileEditorFormatBarExpanded"
    static let showLineNumbersKey = "fileEditorShowLineNumbers"

    /// 键盘浮条默认收着（只露 Aa + 收键盘）
    static let formatBarExpandedDefault = false
    /// 行号默认关（纸 + 字）
    static let showLineNumbersDefault = false
}

/// iPhone 键盘浮条样式，设置 › 文件库里切
enum FileEditorKeyboardBarStyle: String, CaseIterable, Identifiable {
    case glass
    case keycap

    static let defaultStyle: FileEditorKeyboardBarStyle = .glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: "玻璃"
        case .keycap: "键帽"
        }
    }

    /// 认不出的存值按默认（玻璃）
    init(stored: String) {
        self = FileEditorKeyboardBarStyle(rawValue: stored) ?? .defaultStyle
    }
}

/// 哪种模式出哪些工具（纯规则，两端共用）
enum FileEditorTools {
    /// iPhone 排布底部浮着的那一条
    enum BottomBar: Equatable {
        case none
        case find
        case format
        case dismissOnly
    }

    /// 自写查找条（CodeMirror 高亮跳转 / 替换）只在 md 实时模式能用
    static func ownFindAvailable(kind: FileEditorKind, mode: FileEditorMode) -> Bool {
        kind == .markdown && mode == .live
    }

    /// 「…」里的查找 / 查找并替换：实时模式走自写查找条；iPhone 源码模式走系统 findNavigator；
    /// mac / iPad 宽屏的源码模式和所有预览模式不出
    static func findMenuAvailable(kind: FileEditorKind, mode: FileEditorMode, usesTopChrome: Bool) -> Bool {
        ownFindAvailable(kind: kind, mode: mode) || (!usesTopChrome && mode == .source)
    }

    /// 查找开着优先（和格式浮条同位互斥）；否则键盘起时实时模式出格式条、源码模式只出收键盘
    static func bottomBar(mode: FileEditorMode, keyboardVisible: Bool, findActive: Bool) -> BottomBar {
        if findActive { return .find }
        guard keyboardVisible else { return .none }
        switch mode {
        case .live: return .format
        case .source: return .dismissOnly
        case .preview, .split: return .none
        }
    }
}
