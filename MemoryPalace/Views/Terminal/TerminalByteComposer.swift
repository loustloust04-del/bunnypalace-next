import Foundation

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 修饰键 → 终端字节的合成表（plan §C4，物料表 §2.3 / §10.3）。
///
/// SwiftTerm 没有 Ghostty 那套编码器，所以 **rootshell 的 fallback 公式在这里是唯一路径**，
/// 不是兜底。整表：
///
/// | 组合 | 字节 |
/// |---|---|
/// | Ctrl + 字母 | `ascii − 96`（`c` → `0x03`） |
/// | Ctrl + `@A-Z[\]^_` | `ascii & 0x1F` |
/// | Ctrl + Space | `NUL`(0x00) |
/// | Ctrl + Backspace | `0x08` |
/// | Alt + 任意 | 前面加 `ESC`(0x1B) |
/// | Shift + 字母 | 大写 |
/// | Shift + Tab | `ESC[Z` |
/// | 修饰 + 方向/Home/End/Del/PgUp/PgDn | xterm CSI 参数 `1 + Shift(1) + Alt(2) + Ctrl(4)` |
///
/// 跨平台无 UIKit 依赖 —— 单测 target 跑在 macOS 上。
enum TerminalByteComposer {

    /// xterm 的修饰参数：`1 + Shift(1) + Alt(2) + Ctrl(4)`。
    /// 例：Ctrl+Shift+↑ = 1+1+4 = 6 → `ESC[1;6A`（物料表 §2.3）
    static func xtermModifierParam(_ m: TerminalKeyModifiers) -> Int {
        1
        + (m.contains(.shift) ? 1 : 0)
        + (m.contains(.alt) ? 2 : 0)
        + (m.contains(.control) ? 4 : 0)
    }

    /// Ctrl + 某个字符 = 控制码。
    ///
    /// 物料表给的公式是 `ascii − 96`（只覆盖 a-z）；这里推广成 `& 0x1F` 覆盖 `@A-Z[\]^_`，
    /// 对小写字母两者同值（`c` = 99，99−96 = 3，99 & 0x1F = 3）。够不着的字符返回 nil，
    /// 由调用方按无 Ctrl 处理 —— 别自己编一个终端不认识的字节出来。
    static func controlByte(for ch: Character) -> UInt8? {
        guard let a = ch.asciiValue else { return nil }
        switch a {
        case 0x61...0x7A: return a - 96      // a-z
        case 0x40...0x5F: return a & 0x1F    // @ A-Z [ \ ] ^ _
        case 0x20:        return 0x00        // Space → NUL
        default:          return nil
        }
    }

    /// 一个可打印字符 + 修饰位。
    static func bytes(forCharacter character: Character, modifiers: TerminalKeyModifiers) -> [UInt8] {
        var out: [UInt8]
        if modifiers.contains(.control), let ctrl = controlByte(for: character) {
            out = [ctrl]
        } else {
            var ch = character
            // Shift 只把**字母**变大写。数字/符号原样 —— rootshell 的 Shift+数字转符号也没实现
            // （物料表 §10.4），我们在编辑器里直接禁选那种组合（plan §C6），运行时不瞎猜。
            if modifiers.contains(.shift), ch.isLetter { ch = Character(ch.uppercased()) }
            out = Array(String(ch).utf8)
        }
        if modifiers.contains(.alt) { out.insert(0x1B, at: 0) }
        return out
    }

    /// 特殊键 + 修饰位。字节表照物料表 §10.3。
    static func bytes(forSpecial special: TerminalKeyCombo.SpecialKey,
                      modifiers: TerminalKeyModifiers) -> [UInt8] {
        let param = xtermModifierParam(modifiers)
        let hasModifier = param > 1

        switch special {
        case .up, .down, .left, .right, .home, .end:
            let final: UInt8
            switch special {
            case .up: final = 0x41       // A
            case .down: final = 0x42     // B
            case .right: final = 0x43    // C
            case .left: final = 0x44     // D
            case .home: final = 0x48     // H
            default: final = 0x46        // F = End
            }
            return hasModifier ? csi("1;\(param)", final) : [0x1B, 0x5B, final]

        case .delete, .pageUp, .pageDown:
            let num: String
            switch special {
            case .delete: num = "3"
            case .pageUp: num = "5"
            default: num = "6"
            }
            return hasModifier ? csi("\(num);\(param)", 0x7E) : csi(num, 0x7E)

        case .tab:
            // Shift+Tab = backtab ESC[Z（物料表 §2.3）
            if modifiers.contains(.shift) { return altPrefixed([0x1B, 0x5B, 0x5A], modifiers) }
            return altPrefixed([0x09], modifiers)

        case .space:
            if modifiers.contains(.control) { return altPrefixed([0x00], modifiers) }
            return altPrefixed([0x20], modifiers)

        case .backspace:
            // Ctrl+Backspace 是 0x08，**不是** 0x7F & 0x1F —— 特例，物料表 §10.3 点名
            if modifiers.contains(.control) { return altPrefixed([0x08], modifiers) }
            return altPrefixed([0x7F], modifiers)

        case .ret:
            return altPrefixed([0x0D], modifiers)

        case .escape:
            return altPrefixed([0x1B], modifiers)
        }
    }

    /// 内建键 + 修饰位。内部 action 键没有字节，返回 nil。
    static func bytes(forKey id: TerminalKeyID, modifiers: TerminalKeyModifiers) -> [UInt8]? {
        switch id {
        case .esc:        return bytes(forSpecial: .escape, modifiers: modifiers)
        case .tab:        return bytes(forSpecial: .tab, modifiers: modifiers)
        case .arrowUp:    return bytes(forSpecial: .up, modifiers: modifiers)
        case .arrowDown:  return bytes(forSpecial: .down, modifiers: modifiers)
        case .arrowLeft:  return bytes(forSpecial: .left, modifiers: modifiers)
        case .arrowRight: return bytes(forSpecial: .right, modifiers: modifiers)
        default:
            guard let ch = id.symbolCharacter else { return nil }
            return bytes(forCharacter: ch, modifiers: modifiers)
        }
    }

    /// 自定义键的一个 combo step。
    static func bytes(forCombo combo: TerminalKeyCombo) -> [UInt8] {
        switch combo.key {
        case .letter(let s), .symbol(let s), .digit(let s):
            guard let ch = s.first else { return [] }
            return bytes(forCharacter: ch, modifiers: combo.modifiers)
        case .special(let sp):
            return bytes(forSpecial: sp, modifiers: combo.modifiers)
        }
    }

    // MARK: 内部

    private static func csi(_ params: String, _ final: UInt8) -> [UInt8] {
        [0x1B, 0x5B] + Array(params.utf8) + [final]
    }

    private static func altPrefixed(_ bytes: [UInt8], _ m: TerminalKeyModifiers) -> [UInt8] {
        m.contains(.alt) ? [0x1B] + bytes : bytes
    }
}

// MARK: - 粘滞三态

/// 修饰键的三态机（物料表 §2.1/§2.2）。
///
/// `inactive --单击--> oneShot --0.5s 内再击--> locked --再击--> inactive`；
/// 0.5s 内连击 inactive 直接进 locked。
///
/// `now` 由调用方传（`Date.timeIntervalSinceReferenceDate`），单测才好锁时序。
struct TerminalModifierState: Equatable {
    enum Phase: Equatable {
        case inactive
        case oneShot
        case locked
    }

    /// 双击窗口。rootshell 用 0.5s（物料表 §2.1）
    static let doubleTapWindow: TimeInterval = 0.5

    private var phases: [Int: Phase] = [:]
    /// 上一次点这个修饰键的时刻。**跟 phase 分开存** —— oneShot 被某个键消耗掉之后 phase
    /// 回 inactive，但时间戳还在，0.5s 内再点仍能直接锁定（物料表 §2.1 第 4 条）。
    private var lastTap: [Int: TimeInterval] = [:]

    func phase(_ m: TerminalKeyModifiers) -> Phase { phases[m.rawValue] ?? .inactive }

    /// 当前活跃的修饰位（oneShot + locked 的并集）。Ctrl+Shift 是两个 bit 共存，
    /// 不是覆盖关系（物料表 §2.2）。
    var active: TerminalKeyModifiers {
        var out: TerminalKeyModifiers = []
        for (raw, phase) in phases where phase != .inactive {
            out.insert(TerminalKeyModifiers(rawValue: raw))
        }
        return out
    }

    mutating func tap(_ m: TerminalKeyModifiers, at now: TimeInterval) {
        let fast = lastTap[m.rawValue].map { now - $0 < Self.doubleTapWindow } ?? false
        switch phase(m) {
        case .inactive: phases[m.rawValue] = fast ? .locked : .oneShot
        case .oneShot:  phases[m.rawValue] = fast ? .locked : .inactive
        case .locked:   phases[m.rawValue] = .inactive
        }
        lastTap[m.rawValue] = now
    }

    /// 真键发出去之后：清掉所有 oneShot，**locked 保留**（物料表 §2.2）。
    /// 内部 action（dismiss/抽屉/compose/设置）不调这个 —— 点了 Ctrl 再开抽屉，
    /// Ctrl 还留给下一个真键。
    mutating func consumeOneShots() {
        for (raw, phase) in phases where phase == .oneShot { phases[raw] = .inactive }
    }
}
