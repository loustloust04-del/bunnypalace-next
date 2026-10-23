import XCTest

/// K1 / K2：键盘起落几何（plan-perf-watch §1.1）。要抓的回归：舞台模式下页面 / 输入条 HC 被 SwiftUI
/// 再垫一次键盘避让 → 弹键盘时聊天内容飞天（修复 2fba1040）。只测终态几何，不测动画中途。
/// 判据：① 输入框底到键盘顶的间距落在带内（捕整体一起飞）；② 尾条底到输入框顶的间距与键盘收起时一致（捕只有内容飞）；
/// ③ 尾条在窗口内；④ 收起后复位；⑤ 输入框高度不变（变了 = 前提变化，不算几何通过）。
@MainActor
final class RegressionKeyboardUITests: RegressionTestCase {
    /// ① 的带。V0 实测（iPhone 17 Pro 模拟器 iOS 26.4，2026-09-28）：修复前 / 修复后 / 交付版都是 24.3pt——
    /// 这次的飞天不动输入条，① 管的是「输入条整体飞」那一类，带取实测 ±6
    static let barGapBand: ClosedRange<CGFloat> = 18...31
    /// ② 的带：尾条到输入框顶的间距，键盘弹起后减去收起时。V0 实测：修复后 / 交付版 +19.0pt（在底时垫块多抬的量，设计如此），
    /// 修复前（2fba1040^）+327.0pt（飞天）
    static let tailGapChangeBand: ClosedRange<CGFloat> = -4...30
    /// 「在底」前提：尾条底到输入框顶的间距
    static let atBottomGapBand: ClosedRange<CGFloat> = 0...160

    private func launchKeyboardConv() {
        requireGeometryCalibratedDevice()
        launch(["--ui-regression-seed"])
        waitFor(field, "输入框")
        expectPage(1, "启动落在聊天页")
        let ok = until(15) { [self] in anchor("RGTAIL") != nil }
        if !ok { snap("setup-no-tail"); XCTFail("[setup] 回归种子对话没打开（找不到 RGTAIL）") }
    }

    /// 在底状态下完整做一次 弹起 → 收起，四条几何断言
    private func keyboardCycle(_ tag: String) {
        guard let down = settle({ [self] in [field.frame, anchor("RGTAIL")?.frame ?? .zero] }) else {
            snap("\(tag)-setup-unstable"); return XCTFail("[setup] \(tag)：键盘收起态 frame 不稳定")
        }
        let (f0, m0) = (down[0], down[1])
        let g0 = f0.minY - m0.maxY
        guard m0.height > 1, Self.atBottomGapBand.contains(g0) else {
            snap("\(tag)-setup-not-at-bottom")
            return XCTFail("[setup] \(tag)：不在底（尾条底到输入框顶 \(g0)pt，带 \(Self.atBottomGapBand)）")
        }

        field.tap()
        waitKeyboardUp()
        guard let up = settle({ [self] in [field.frame, anchor("RGTAIL")?.frame ?? .zero, keyboard.frame] }) else {
            snap("\(tag)-up-unstable")
            let tail = anchor("RGTAIL")
            return XCTFail("[anchor] \(tag)：键盘弹起后几何不收敛（尾条锚 \(tail.map { "\($0.frame) ×\($0.matches)" } ?? "不在 AX 树")，不算 ①② 证据）")
        }
        let (f1, m1, k) = (up[0], up[1], up[2])
        snap("\(tag)-keyboard-up")
        let barGap = k.minY - f1.maxY
        let g1 = f1.minY - m1.maxY
        record("\(tag)-geometry", [
            "F0": f0, "M0": m0, "F1": f1, "M1": m1, "K": k, "window": window,
            "barGap": barGap, "tailGapDown": g0, "tailGapUp": g1,
            "dField": f0.minY - f1.minY, "dTail": m0.minY - m1.minY,
            "tailMatches": anchor("RGTAIL")?.matches ?? 0,
        ])
        XCTAssertEqual(f1.height, f0.height, accuracy: 1, "[setup] \(tag)：输入框高度变了（前提变化）")
        XCTAssertTrue(Self.barGapBand.contains(barGap), "[product] \(tag) ①：输入框底到键盘顶 \(barGap)pt，不在带 \(Self.barGapBand)（输入条没贴键盘 / 整体飞了）")
        XCTAssertTrue(Self.tailGapChangeBand.contains(g1 - g0), "[product] \(tag) ②：尾条到输入框的间距从 \(g0) 变成 \(g1)（变化 \(g1 - g0)pt，带 \(Self.tailGapChangeBand)；内容没跟输入条同步，飞了）")
        XCTAssertTrue(m1.minY >= window.minY && m1.maxY <= f1.minY + 1, "[product] \(tag) ③：尾条不在可视区 \(m1)")

        tapListBlank()
        waitKeyboardGone("setup")
        guard let after = settle({ [self] in [field.frame, anchor("RGTAIL")?.frame ?? .zero] }) else {
            snap("\(tag)-down-unstable"); return XCTFail("[product] \(tag)：收键盘后几何不收敛")
        }
        record("\(tag)-restored", ["F2": after[0], "M2": after[1]])
        XCTAssertEqual(after[0].minY, f0.minY, accuracy: 2, "[product] \(tag) ④：收起后输入框没复位")
        XCTAssertEqual(after[1].minY, m0.minY, accuracy: 4, "[product] \(tag) ④：收起后尾条没复位")
    }

    func testK1KeyboardAtBottom() {
        launchKeyboardConv()
        keyboardCycle("K1")
    }

    func testK2KeyboardAfterPaging() {
        launchKeyboardConv()
        let routes: [(String, () -> Void, () -> Void, Int)] = [
            ("1-2-1", { self.swipeToNext() }, { self.swipeToPrev() }, 2),
            ("1-0-1", { self.swipeToPrev() }, { self.swipeToNext() }, 0),
        ]
        for (label, away, back, target) in routes {
            field.tap()
            waitKeyboardUp()
            let draft = "rgdraft\(target)"
            field.typeText(draft)
            away()
            expectPage(target, "带键盘翻走")
            waitKeyboardGone()
            back()
            expectPage(1, "翻回聊天页")
            XCTAssertEqual(field.value as? String, draft, "[product] K2 \(label)：翻页回来草稿变了")
            // 点输入框右端让光标落在草稿末尾（点中间光标可能落在开头，删键删不掉——首轮实跑踩到）
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            waitKeyboardUp()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: draft.count + 2))
            let left = (field.value as? String) ?? ""
            XCTAssertFalse(left.contains("rgdraft"), "[setup] K2 \(label)：草稿没删干净（\(left)）")
            tapListBlank()
            waitKeyboardGone()
            keyboardCycle("K2-\(label)")
        }
    }
}
