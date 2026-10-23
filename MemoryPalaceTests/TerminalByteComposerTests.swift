import XCTest
@testable import 记忆花园

/// 字节合成表逐条上锁（plan §C4，物料表 §2.3/§10.3）+ 粘滞三态状态机（物料表 §2.1/§2.2）。
///
/// SwiftTerm 没有 Ghostty 编码器，这张表是**唯一**路径不是兜底，错一条就是「按了发不出去」，
/// 所以每一行公式都要有测试钉住。
final class TerminalByteComposerTests: XCTestCase {

    private func bytes(_ ch: Character, _ m: TerminalKeyModifiers) -> [UInt8] {
        TerminalByteComposer.bytes(forCharacter: ch, modifiers: m)
    }

    private func special(_ sp: TerminalKeyCombo.SpecialKey, _ m: TerminalKeyModifiers) -> [UInt8] {
        TerminalByteComposer.bytes(forSpecial: sp, modifiers: m)
    }

    // MARK: - Ctrl = ascii − 96

    func testControlPlusLetter() {
        XCTAssertEqual(bytes("a", [.control]), [0x01])
        XCTAssertEqual(bytes("c", [.control]), [0x03], "⌃C —— 退出 CC 的那一下")
        XCTAssertEqual(bytes("d", [.control]), [0x04])
        XCTAssertEqual(bytes("z", [.control]), [0x1A])
    }

    func testControlPlusUppercaseLetterSameAsLowercase() {
        // 软键盘开着大写时上屏的是 'C'（0x43），0x43 & 0x1F 照样是 0x03
        XCTAssertEqual(bytes("C", [.control]), [0x03])
        XCTAssertEqual(bytes("c", [.control, .shift]), [0x03])
    }

    func testControlPlusAtAndBracketRange() {
        XCTAssertEqual(bytes("@", [.control]), [0x00])
        XCTAssertEqual(bytes("[", [.control]), [0x1B])
        XCTAssertEqual(bytes("\\", [.control]), [0x1C])
        XCTAssertEqual(bytes("]", [.control]), [0x1D])
        XCTAssertEqual(bytes("^", [.control]), [0x1E])
        XCTAssertEqual(bytes("_", [.control]), [0x1F])
    }

    func testControlOnUnmappableCharFallsBackToPlainChar() {
        // 够不着控制码的字符按无 Ctrl 处理，不自己编一个终端不认识的字节
        XCTAssertEqual(bytes("~", [.control]), [0x7E])
    }

    func testControlSpaceIsNUL() {
        XCTAssertEqual(special(.space, [.control]), [0x00], "Ctrl+Space = NUL")
        XCTAssertEqual(bytes(" ", [.control]), [0x00])
    }

    func testControlBackspaceIs0x08NotMasked() {
        // 特例：0x7F & 0x1F 是 0x1F，不是 0x08 —— 物料表 §10.3 点名
        XCTAssertEqual(special(.backspace, [.control]), [0x08])
        XCTAssertEqual(special(.backspace, []), [0x7F])
    }

    // MARK: - Alt = ESC 前缀

    func testAltPrefixesEscape() {
        XCTAssertEqual(bytes("f", [.alt]), [0x1B, 0x66])
        XCTAssertEqual(special(.ret, [.alt]), [0x1B, 0x0D])
        XCTAssertEqual(special(.tab, [.alt]), [0x1B, 0x09])
        XCTAssertEqual(special(.escape, [.alt]), [0x1B, 0x1B])
        XCTAssertEqual(special(.space, [.alt]), [0x1B, 0x20])
        XCTAssertEqual(special(.backspace, [.alt]), [0x1B, 0x7F])
    }

    func testAltPlusControlStacks() {
        XCTAssertEqual(bytes("c", [.alt, .control]), [0x1B, 0x03])
    }

    // MARK: - Shift

    func testShiftUppercasesLettersOnly() {
        XCTAssertEqual(bytes("a", [.shift]), [0x41])
        XCTAssertEqual(bytes("z", [.shift]), [0x5A])
    }

    func testShiftDoesNotTurnDigitsIntoSymbols() {
        // rootshell 这条也没实现（物料表 §10.4 缺口）；我们在编辑器里禁选，运行时保持原样
        XCTAssertEqual(bytes("1", [.shift]), [0x31], "不该变成 !")
        XCTAssertEqual(bytes("7", [.shift]), [0x37], "不该变成 &")
    }

    func testShiftTabIsBacktab() {
        XCTAssertEqual(special(.tab, [.shift]), [0x1B, 0x5B, 0x5A], "ESC[Z")
        XCTAssertEqual(special(.tab, []), [0x09])
    }

    // MARK: - xterm CSI 修饰参数 1 + Shift(1) + Alt(2) + Ctrl(4)

    func testXtermModifierParamTable() {
        let p = TerminalByteComposer.xtermModifierParam
        XCTAssertEqual(p([]), 1)
        XCTAssertEqual(p([.shift]), 2)
        XCTAssertEqual(p([.alt]), 3)
        XCTAssertEqual(p([.shift, .alt]), 4)
        XCTAssertEqual(p([.control]), 5)
        XCTAssertEqual(p([.control, .shift]), 6)
        XCTAssertEqual(p([.control, .alt]), 7)
        XCTAssertEqual(p([.control, .alt, .shift]), 8)
    }

    func testPlainArrowSequences() {
        XCTAssertEqual(special(.up, []), [0x1B, 0x5B, 0x41])      // ESC[A
        XCTAssertEqual(special(.down, []), [0x1B, 0x5B, 0x42])    // ESC[B
        XCTAssertEqual(special(.left, []), [0x1B, 0x5B, 0x44])    // ESC[D
        XCTAssertEqual(special(.right, []), [0x1B, 0x5B, 0x43])   // ESC[C
    }

    func testModifiedArrowsUseCSIParam() {
        // 物料表 §2.3 点名的例子：Ctrl+Shift+↑ = ESC[1;6A
        XCTAssertEqual(String(decoding: special(.up, [.control, .shift]), as: UTF8.self),
                       "\u{1b}[1;6A")
        XCTAssertEqual(String(decoding: special(.left, [.alt]), as: UTF8.self), "\u{1b}[1;3D")
        XCTAssertEqual(String(decoding: special(.right, [.control]), as: UTF8.self), "\u{1b}[1;5C")
        XCTAssertEqual(String(decoding: special(.down, [.shift]), as: UTF8.self), "\u{1b}[1;2B")
    }

    func testHomeEndPlainAndModified() {
        XCTAssertEqual(String(decoding: special(.home, []), as: UTF8.self), "\u{1b}[H")
        XCTAssertEqual(String(decoding: special(.end, []), as: UTF8.self), "\u{1b}[F")
        XCTAssertEqual(String(decoding: special(.home, [.control]), as: UTF8.self), "\u{1b}[1;5H")
        XCTAssertEqual(String(decoding: special(.end, [.shift]), as: UTF8.self), "\u{1b}[1;2F")
    }

    func testTildeKeysPlainAndModified() {
        XCTAssertEqual(String(decoding: special(.delete, []), as: UTF8.self), "\u{1b}[3~")
        XCTAssertEqual(String(decoding: special(.pageUp, []), as: UTF8.self), "\u{1b}[5~")
        XCTAssertEqual(String(decoding: special(.pageDown, []), as: UTF8.self), "\u{1b}[6~")
        XCTAssertEqual(String(decoding: special(.delete, [.control]), as: UTF8.self), "\u{1b}[3;5~")
        XCTAssertEqual(String(decoding: special(.pageUp, [.alt, .shift]), as: UTF8.self), "\u{1b}[5;4~")
    }

    func testSimpleSpecialKeyBaseBytes() {
        XCTAssertEqual(special(.ret, []), [0x0D])
        XCTAssertEqual(special(.tab, []), [0x09])
        XCTAssertEqual(special(.escape, []), [0x1B])
        XCTAssertEqual(special(.space, []), [0x20])
        XCTAssertEqual(special(.backspace, []), [0x7F])
    }

    // MARK: - KeyID / Combo 入口

    func testKeyIDRoutesToTheRightTable() {
        XCTAssertEqual(TerminalByteComposer.bytes(forKey: .esc, modifiers: []), [0x1B])
        XCTAssertEqual(TerminalByteComposer.bytes(forKey: .tab, modifiers: [.shift]),
                       [0x1B, 0x5B, 0x5A])
        XCTAssertEqual(TerminalByteComposer.bytes(forKey: .arrowUp, modifiers: []),
                       [0x1B, 0x5B, 0x41])
        XCTAssertEqual(TerminalByteComposer.bytes(forKey: .dollar, modifiers: []), [0x24])
        XCTAssertEqual(TerminalByteComposer.bytes(forKey: .slash, modifiers: [.control]), [0x2F],
                       "Ctrl+/ 够不着控制码 → 按无 Ctrl 发")
        XCTAssertNil(TerminalByteComposer.bytes(forKey: .compose, modifiers: []),
                     "内部 action 没有字节")
        XCTAssertNil(TerminalByteComposer.bytes(forKey: .dismiss, modifiers: []))
    }

    /// 回归锚（13:05 真机闪退）：三个 `bytes` 重载原来外部标签都是 `for:modifiers:`，
    /// 而 `TerminalKeyID` 和 `SpecialKey` **都有 `.tab`**。产品代码里
    /// `bytes(for: .tab, modifiers:)` 的期望返回类型是 `[UInt8]?`，Swift 挑了返回 `[UInt8]?`
    /// 的 KeyID 重载 → **自己调自己 → 爆栈**（`detail(for:)` 一渲染主行就崩）。
    /// 而测试那边期望 `[UInt8]`，解析到 SpecialKey 重载，所以单测全绿也没抓到。
    /// 改成 `forCharacter:` / `forSpecial:` / `forKey:` / `forCombo:` 消除歧义后，
    /// 这条把**每个内建键**都过一遍：递归回来就直接爆栈失败。
    func testEveryKeyIDComposesWithoutRecursion() {
        for id in TerminalKeyID.allCases {
            let plain = TerminalByteComposer.bytes(forKey: id, modifiers: [])
            let modified = TerminalByteComposer.bytes(forKey: id, modifiers: [.control, .shift])
            switch id.kind {
            case .action, .toggle, .modifier:
                XCTAssertNil(plain, "\(id.rawValue) 是内部键，不该有字节")
            default:
                XCTAssertNotNil(plain, "\(id.rawValue) 应该给得出字节")
                XCTAssertFalse(plain!.isEmpty, "\(id.rawValue) 字节为空")
                XCTAssertNotNil(modified)
            }
        }
    }

    func testComboBytes() {
        XCTAssertEqual(TerminalByteComposer.bytes(
            forCombo: TerminalKeyCombo(modifiers: [.control], key: .letter("c"))), [0x03])
        XCTAssertEqual(TerminalByteComposer.bytes(
            forCombo: TerminalKeyCombo(modifiers: [.alt], key: .special(.ret))), [0x1B, 0x0D])
        XCTAssertEqual(TerminalByteComposer.bytes(
            forCombo: TerminalKeyCombo(modifiers: [.shift], key: .digit("1"))), [0x31])
        XCTAssertEqual(TerminalByteComposer.bytes(
            forCombo: TerminalKeyCombo(modifiers: [], key: .symbol("$"))), [0x24])
    }

    // MARK: - 粘滞三态状态机

    func testSingleTapGivesOneShot() {
        var s = TerminalModifierState()
        s.tap(.control, at: 0)
        XCTAssertEqual(s.phase(.control), .oneShot)
        XCTAssertEqual(s.active, [.control])
    }

    func testFastSecondTapLocks() {
        var s = TerminalModifierState()
        s.tap(.control, at: 0)
        s.tap(.control, at: 0.2)          // 0.5s 内
        XCTAssertEqual(s.phase(.control), .locked)
    }

    func testSlowSecondTapReturnsToInactive() {
        var s = TerminalModifierState()
        s.tap(.control, at: 0)
        s.tap(.control, at: 1.0)          // 超过 0.5s
        XCTAssertEqual(s.phase(.control), .inactive)
        XCTAssertEqual(s.active, [])
    }

    func testTapOnLockedUnlocks() {
        var s = TerminalModifierState()
        s.tap(.shift, at: 0)
        s.tap(.shift, at: 0.2)
        XCTAssertEqual(s.phase(.shift), .locked)
        s.tap(.shift, at: 5.0)
        XCTAssertEqual(s.phase(.shift), .inactive, "locked 状态下一击就回 inactive，不管间隔")
    }

    func testConsumedOneShotStillLocksIfTappedAgainQuickly() {
        // 物料表 §2.1 第 4 条：oneShot 被键消耗掉之后，0.5s 内再点 modifier 仍直接锁定
        var s = TerminalModifierState()
        s.tap(.control, at: 0)
        s.consumeOneShots()
        XCTAssertEqual(s.phase(.control), .inactive)
        s.tap(.control, at: 0.3)
        XCTAssertEqual(s.phase(.control), .locked)
    }

    func testConsumeClearsOneShotButKeepsLocked() {
        var s = TerminalModifierState()
        s.tap(.control, at: 0)            // oneShot
        s.tap(.shift, at: 0)
        s.tap(.shift, at: 0.1)            // locked
        XCTAssertEqual(s.active, [.control, .shift])
        s.consumeOneShots()
        XCTAssertEqual(s.phase(.control), .inactive)
        XCTAssertEqual(s.phase(.shift), .locked)
        XCTAssertEqual(s.active, [.shift], "locked 保留（物料表 §2.2）")
    }

    func testModifiersAreUnionNotOverride() {
        var s = TerminalModifierState()
        s.tap(.control, at: 0)
        s.tap(.shift, at: 0)
        XCTAssertEqual(s.active, [.control, .shift])
        // Ctrl+Shift+↑ 走 CSI 参数 6
        XCTAssertEqual(String(decoding: special(.up, s.active), as: UTF8.self), "\u{1b}[1;6A")
    }

    func testCtrlThenSoftKeyboardCGivesInterrupt() {
        // 走查要验的那条：按 ⌃ 再在软键盘上打 c → ^C
        var s = TerminalModifierState()
        s.tap(.control, at: 0)
        XCTAssertEqual(bytes("c", s.active), [0x03])
        s.consumeOneShots()
        XCTAssertEqual(bytes("c", s.active), [0x63], "oneShot 用掉之后就是普通的 c")
    }
}
