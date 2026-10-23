import Foundation
import CoreGraphics

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 终端工具条的键模型（plan §C1，对齐 rootshell 分层，物料表 `reports/toolbar.md` §1.1）。
///
/// **跨平台无 UIKit 依赖** —— 单测 target 是 macOS 的（`project.yml:335-338`），
/// 模型层包进 `#if canImport(UIKit)` 就测不到了。UIKit 只出现在视图文件里。

// MARK: - KeyID

/// 内建键的持久化身份。**raw value 是稳定 ID，已发布的 case 不许改名/删除**
/// （改了等于把粟粟布局里的那个键弄丢）。
///
/// 相对 rootshell 的 54 个内建 ID，这里按粟粟 08-31 批注 §五-8 裁过：
/// - **Cmd 剔除**：tmux 终端没有 Cmd 字节可发，rootshell 自己的 Cmd 宏也是存而不发的死码（物料表 §10.4）
/// - **rootshell 专属 8 个 action 剔除**：voiceAgent / aiAgent / brightnessBoost / clipboardManager /
///   toggleFullScreen / toggleTabBar / newConnection / toggleMouseCapture —— MP 没有对应物
/// - **两个设置键并成一个**：rootshell 分 toolbarSettings（主行）和 appSettings（抽屉）两个去处，
///   MP 只有「终端设置页」一个去处，同一个动作放两个键是重复
enum TerminalKeyID: String, Codable, CaseIterable, Hashable, Sendable {
    // 修饰键（esc 归在这组但不进粘滞三态，见 isStickyModifier）
    case esc
    case ctrl
    case alt
    case shift

    case tab

    // 方向键（独立四键；跟主行的 joystick 不互斥，可共存 —— 物料表 §3.5）
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight

    // 符号 28 键（物料表 §1.3 全抄）
    case backtick
    case tilde
    case caret
    case underscore
    case backslash
    case pipe
    case leftBracket
    case rightBracket
    case leftBrace
    case rightBrace
    case lessThan
    case greaterThan
    case slash
    case questionMark
    case dash
    case equals
    case singleQuote
    case doubleQuote
    case semicolon
    case colon
    case leftParen
    case rightParen
    case atSign
    case hash
    case dollar
    case percent
    case ampersand
    case asterisk

    // 内部 action（不发 PTY 字节）
    case dismiss
    case windowSwitcher
    case compose
    case paste
    case terminalSettings

    // 开关类
    case arrowJoystick
    case drawerToggle
}

extension TerminalKeyID {
    enum Kind: Sendable {
        case modifier      // 粘滞三态参与者
        case escape        // esc：归在 modifier 组但直接发字节，不进三态
        case symbol        // 显示字符本身
        case navigation    // 方向键
        case action        // 内部动作
        case toggle        // 抽屉 / joystick
        case plain         // tab
    }

    var kind: Kind {
        switch self {
        case .ctrl, .alt, .shift: return .modifier
        case .esc: return .escape
        case .tab: return .plain
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight: return .navigation
        case .dismiss, .windowSwitcher, .compose, .paste, .terminalSettings: return .action
        case .arrowJoystick, .drawerToggle: return .toggle
        default: return .symbol
        }
    }

    /// 进粘滞三态的只有 Ctrl/Alt/Shift。Esc 虽然分类在修饰组，点击直接发 `0x1B`，从不进三态
    /// （物料表 §2.1 末条）。
    var isStickyModifier: Bool { kind == .modifier }

    /// 无修饰时发给终端的字节。nil = 内部 action，不发字节。
    var rawBytes: [UInt8]? {
        switch self {
        case .esc: return [0x1B]
        case .tab: return [0x09]
        case .arrowUp: return [0x1B, 0x5B, 0x41]      // ESC[A
        case .arrowDown: return [0x1B, 0x5B, 0x42]    // ESC[B
        case .arrowLeft: return [0x1B, 0x5B, 0x44]    // ESC[D
        case .arrowRight: return [0x1B, 0x5B, 0x43]   // ESC[C
        default:
            guard let ch = symbolCharacter, let a = ch.asciiValue else { return nil }
            return [a]
        }
    }

    /// 符号键显示的字符本身（符号键没有 SF Symbol，直接把字符画在键上 —— 物料表 §1.3 首段）。
    var symbolCharacter: Character? {
        switch self {
        case .backtick: return "`"
        case .tilde: return "~"
        case .caret: return "^"
        case .underscore: return "_"
        case .backslash: return "\\"
        case .pipe: return "|"
        case .leftBracket: return "["
        case .rightBracket: return "]"
        case .leftBrace: return "{"
        case .rightBrace: return "}"
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .slash: return "/"
        case .questionMark: return "?"
        case .dash: return "-"
        case .equals: return "="
        case .singleQuote: return "'"
        case .doubleQuote: return "\""
        case .semicolon: return ";"
        case .colon: return ":"
        case .leftParen: return "("
        case .rightParen: return ")"
        case .atSign: return "@"
        case .hash: return "#"
        case .dollar: return "$"
        case .percent: return "%"
        case .ampersand: return "&"
        case .asterisk: return "*"
        default: return nil
        }
    }

    /// SF Symbol 名。符号键返回 nil（画字符）。
    var iconName: String? {
        switch self {
        case .esc: return "escape"
        case .ctrl: return "control"
        case .alt: return "option"
        case .shift: return "shift"
        case .tab: return "arrow.right.to.line"
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        case .dismiss: return "chevron.down"
        case .windowSwitcher: return "rectangle.stack"
        case .compose: return "character.cursor.ibeam"
        case .paste: return "doc.on.clipboard"
        case .terminalSettings: return "gearshape"
        case .arrowJoystick: return "arrow.up.and.down.and.arrow.left.and.right"
        case .drawerToggle: return "ellipsis"
        default: return nil
        }
    }

    /// 设置页里的名字（界面全中文）。
    var settingsLabel: String {
        switch self {
        case .esc: return "Esc"
        case .ctrl: return "Control"
        case .alt: return "Option"
        case .shift: return "Shift"
        case .tab: return "Tab"
        case .arrowUp: return "上"
        case .arrowDown: return "下"
        case .arrowLeft: return "左"
        case .arrowRight: return "右"
        case .dismiss: return "收起键盘"
        case .windowSwitcher: return "切换窗口"
        case .compose: return "草稿编辑器"
        case .paste: return "粘贴"
        case .terminalSettings: return "终端设置"
        case .arrowJoystick: return "方向摇杆"
        case .drawerToggle: return "抽屉"
        default: return symbolCharacter.map { String($0) } ?? rawValue
        }
    }

    /// 宽键（修饰键、joystick 用宽键 —— 物料表 §9.4）
    var isWide: Bool {
        switch kind {
        case .modifier, .escape, .toggle, .navigation: return true
        default: return false
        }
    }
}

// MARK: - 摇杆几何

/// 方向摇杆的判向规则（物料表 §3.2）。纯几何，抽出来好上单测。
enum TerminalJoystickGeometry {
    /// 死区半径。位移不到它就没有方向。
    static let deadZone: CGFloat = 18

    /// 起点是 touchesBegan 时的手指位置（不是按钮中心），传进来的是相对起点的位移。
    /// `|dx| > |dy|` 选左右否则上下 —— **正好 45° 归垂直**（rootshell 用的是 `>` 不是 `>=`）。
    static func direction(dx: CGFloat, dy: CGFloat) -> TerminalKeyCombo.SpecialKey? {
        guard (dx * dx + dy * dy).squareRoot() >= deadZone else { return nil }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up      // iOS 的 y 往下增
    }
}

// MARK: - 修饰位

/// 活跃修饰键的并集位（物料表 §2.2：Ctrl+Shift 是同时存在的两个 bit，不是覆盖关系）。
/// rootshell 的 Command 位这里没有 —— Cmd 已剔。
struct TerminalKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = TerminalKeyModifiers(rawValue: 1 << 0)
    static let alt     = TerminalKeyModifiers(rawValue: 1 << 1)
    static let shift   = TerminalKeyModifiers(rawValue: 1 << 2)

    init?(keyID: TerminalKeyID) {
        switch keyID {
        case .ctrl: self = .control
        case .alt: self = .alt
        case .shift: self = .shift
        default: return nil
        }
    }
}

// MARK: - 槽位

/// 布局里的一个槽位。自定义键只存 UUID，定义本体另存（物料表 §1.1 末条）。
enum TerminalKeySlot: Codable, Hashable, Sendable {
    case builtIn(TerminalKeyID)
    case custom(UUID)

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let value = try c.decode(String.self, forKey: .value)
        switch type {
        case "builtin":
            guard let id = TerminalKeyID(rawValue: value) else {
                // 未知 raw value = 更新后被删掉的键 / 别人的配置。整条布局别因为一个槽位炸掉。
                throw DecodingError.dataCorruptedError(forKey: .value, in: c,
                                                       debugDescription: "unknown key id \(value)")
            }
            self = .builtIn(id)
        case "custom":
            guard let uuid = UUID(uuidString: value) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: c,
                                                       debugDescription: "bad uuid \(value)")
            }
            self = .custom(uuid)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "unknown slot type \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn(let id):
            try c.encode("builtin", forKey: .type)
            try c.encode(id.rawValue, forKey: .value)
        case .custom(let uuid):
            try c.encode("custom", forKey: .type)
            try c.encode(uuid.uuidString, forKey: .value)
        }
    }

    var builtInID: TerminalKeyID? {
        if case .builtIn(let id) = self { return id }
        return nil
    }

    var customID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }
}

// MARK: - 自定义键

/// 自定义键的一步。rootshell 只有 text / keyCombo 两种（物料表 §10.3），这里照抄。
enum TerminalSequenceStep: Codable, Hashable, Sendable {
    case text(String)
    case keyCombo(TerminalKeyCombo)

    private enum CodingKeys: String, CodingKey { case type, text, combo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "combo": self = .keyCombo(try c.decode(TerminalKeyCombo.self, forKey: .combo))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "unknown step type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .keyCombo(let combo):
            try c.encode("combo", forKey: .type)
            try c.encode(combo, forKey: .combo)
        }
    }
}

/// 一个组合键：修饰位 + 主键。
struct TerminalKeyCombo: Codable, Hashable, Sendable {
    var modifiers: TerminalKeyModifiers
    var key: ComboKey

    /// 主键。`Character` 不是 Codable，跟 rootshell 一样手写 `{type,value}`（物料表 §7.2）。
    enum ComboKey: Codable, Hashable, Sendable {
        case letter(String)     // 单个 a–z
        case digit(String)      // 单个 0–9
        case symbol(String)     // 单个符号
        case special(SpecialKey)

        private enum CodingKeys: String, CodingKey { case type, value }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let value = try c.decode(String.self, forKey: .value)
            switch try c.decode(String.self, forKey: .type) {
            case "letter": self = .letter(value)
            case "digit": self = .digit(value)
            case "symbol": self = .symbol(value)
            case "special":
                guard let s = SpecialKey(rawValue: value) else {
                    throw DecodingError.dataCorruptedError(forKey: .value, in: c,
                                                           debugDescription: "unknown special \(value)")
                }
                self = .special(s)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                       debugDescription: "unknown combo key type")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .letter(let v): try c.encode("letter", forKey: .type); try c.encode(v, forKey: .value)
            case .digit(let v): try c.encode("digit", forKey: .type); try c.encode(v, forKey: .value)
            case .symbol(let v): try c.encode("symbol", forKey: .type); try c.encode(v, forKey: .value)
            case .special(let v): try c.encode("special", forKey: .type); try c.encode(v.rawValue, forKey: .value)
            }
        }
    }

    /// 14 个特殊键，字节表照物料表 §10.3 搬。
    enum SpecialKey: String, Codable, CaseIterable, Sendable {
        case ret, tab, escape, space, backspace, delete
        case up, down, left, right
        case home, end, pageUp, pageDown

        var label: String {
            switch self {
            case .ret: return "Return"
            case .tab: return "Tab"
            case .escape: return "Escape"
            case .space: return "Space"
            case .backspace: return "Backspace"
            case .delete: return "Delete"
            case .up: return "↑"
            case .down: return "↓"
            case .left: return "←"
            case .right: return "→"
            case .home: return "Home"
            case .end: return "End"
            case .pageUp: return "Page Up"
            case .pageDown: return "Page Down"
            }
        }
    }
}

/// 自定义键。定义本体存在 `customKeys`，布局槽位只存它的 UUID。
struct TerminalCustomKey: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var label: String
    var iconName: String?
    var sequence: [TerminalSequenceStep]

    init(id: UUID = UUID(), label: String, iconName: String? = nil,
         sequence: [TerminalSequenceStep]) {
        self.id = id
        self.label = label
        self.iconName = iconName
        self.sequence = sequence
    }

    /// 没设图标时键面只显示 label 前 2 个字符（物料表 §10.3）。
    var displayText: String { String(label.prefix(2)) }
}

// MARK: - 布局

/// 工具条布局。持久化用自己的 schema（不做 rootshell 数据互通，物料表 ASK6 裁决）。
struct TerminalToolbarLayout: Codable, Hashable, Sendable {
    /// 当前 schema 版本。迁移逻辑看 `TerminalToolbarStore.migrate`。
    static let currentVersion = 1

    var version: Int
    var mainRow: [TerminalKeySlot]
    /// 至少一行（rootshell 同约束，物料表 §1.1）
    var drawerRows: [[TerminalKeySlot]]
    var hiddenKeys: Set<TerminalKeyID>

    init(version: Int = TerminalToolbarLayout.currentVersion,
         mainRow: [TerminalKeySlot],
         drawerRows: [[TerminalKeySlot]],
         hiddenKeys: Set<TerminalKeyID> = []) {
        self.version = version
        self.mainRow = mainRow
        self.drawerRows = drawerRows.isEmpty ? [[]] : drawerRows
        self.hiddenKeys = hiddenKeys
    }

    /// iPhone 主行默认 10 键，顺序照物料表 §1.2。
    /// rootshell 的 `toolbarSettings` 在 MP 里就是「终端设置」，跟抽屉那个 appSettings 并成一个键。
    static let defaultMainRow: [TerminalKeyID] = [
        .dismiss, .windowSwitcher, .esc, .ctrl, .compose,
        .shift, .tab, .arrowJoystick, .drawerToggle, .terminalSettings,
    ]

    /// iPhone 抽屉默认键，顺序照物料表 §1.3 的 40 键序裁剪而来：
    /// Alt（Cmd 剔）→ 符号 28 → Paste（rootshell 专属 8 action 剔、appSettings 已并入主行）
    /// → 四个独立方向键（任务书 C5「默认在抽屉」）。
    static let defaultDrawerRow: [TerminalKeyID] = [
        .alt,
        .backtick, .tilde, .caret, .underscore, .backslash, .pipe,
        .leftBracket, .rightBracket, .leftBrace, .rightBrace,
        .slash, .questionMark, .dash, .equals,
        .singleQuote, .doubleQuote, .leftParen, .rightParen,
        .atSign, .hash, .dollar, .percent,
        .semicolon, .colon, .lessThan, .greaterThan,
        .ampersand, .asterisk,
        .paste,
        .arrowLeft, .arrowDown, .arrowUp, .arrowRight,
    ]

    static var `default`: TerminalToolbarLayout {
        TerminalToolbarLayout(
            mainRow: defaultMainRow.map { .builtIn($0) },
            drawerRows: [defaultDrawerRow.map { .builtIn($0) }]
        )
    }

    /// 布局里出现过的所有内建键（判 hidden 区该列谁用）
    var placedBuiltInIDs: Set<TerminalKeyID> {
        var set = Set<TerminalKeyID>()
        for slot in mainRow + drawerRows.flatMap({ $0 }) {
            if let id = slot.builtInID { set.insert(id) }
        }
        return set
    }

    var placedCustomIDs: Set<UUID> {
        var set = Set<UUID>()
        for slot in mainRow + drawerRows.flatMap({ $0 }) {
            if let id = slot.customID { set.insert(id) }
        }
        return set
    }
}
