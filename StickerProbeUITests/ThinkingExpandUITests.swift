import XCTest

/// [PROBE] 「点开 thinking 气泡弹到好远以前」复现器（research-keyboard-list-inset §8 追凶）：
/// --kb-probe-seed 消息 11/21 带 [thinking]（展开 ΔH≈800pt）。
/// T1 在底点最新条的思考 chip；T2 翻到历史中部点消息 11 的思考 chip。
/// 断言：点开后被点的消息不飞出视口（跳远古 bug 下 offset += ΔH，消息向视觉下方飞出）。
final class ThinkingExpandUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func el(_ app: XCUIApplication, _ contains: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
    }

    /// 屏内的「思考过程」chip（元素树含屏外实例化 cell，按 frame 过滤）
    private func visibleThinkingChip(_ app: XCUIApplication) -> XCUIElement? {
        let chips = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '思考过程'")).allElementsBoundByIndex
        return chips.first { $0.frame.minY > 60 && $0.frame.maxY < 820 && $0.frame.height > 1 }
    }

    func testThinkingExpandDoesNotJump() {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed"]
        app.launch()
        sleep(8)
        snap(app, "T0-launch")

        // ── T1 在底：点最新条（msg 21）的思考 chip
        let marker = el(app, "KBMARKER123")
        XCTAssertTrue(marker.exists, "seed 尾条没渲染")
        let markerBefore = marker.frame
        guard let chip1 = visibleThinkingChip(app) else {
            XCTFail("T1 屏内找不到思考 chip"); return
        }
        NSLog("[THINK] T1 before: marker=\(markerBefore) chip=\(chip1.frame)")
        chip1.tap()
        sleep(2)
        snap(app, "T1-expanded")
        let markerAfter = marker.exists ? marker.frame : .zero
        NSLog("[THINK] T1 after: markerExists=\(marker.exists) frame=\(markerAfter)")
        // 跳远古 bug：视口冲向历史，最新条飞出屏（或大幅位移）
        let t1OK = marker.exists && markerAfter.minY > 0 && markerAfter.maxY < 874
        XCTAssertTrue(t1OK, "T1 在底展开 thinking 后最新消息飞出视口（粟粟报的跳远古）")
        // 收回
        if let chipAgain = visibleThinkingChip(app) { chipAgain.tap(); sleep(1) }

        // ── T2 翻到历史中部（消息 11 附近）点它的思考 chip
        var anchor11 = el(app, "键盘取证填充消息 11")
        var scrolls = 0
        while (!anchor11.exists || anchor11.frame.minY < 60 || anchor11.frame.maxY > 800), scrolls < 8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)))
            sleep(1)
            scrolls += 1
            anchor11 = el(app, "键盘取证填充消息 11")
        }
        NSLog("[THINK] T2 scrolled \(scrolls)x, anchor11 exists=\(anchor11.exists) frame=\(anchor11.exists ? anchor11.frame : .zero)")
        guard anchor11.exists, anchor11.frame.height > 1 else {
            XCTFail("T2 翻不到消息 11"); return
        }
        snap(app, "T2-before")
        guard let chip2 = visibleThinkingChip(app) else {
            XCTFail("T2 屏内找不到思考 chip"); return
        }
        let a11Before = anchor11.frame
        NSLog("[THINK] T2 before: anchor11=\(a11Before) chip=\(chip2.frame)")
        chip2.tap()
        sleep(2)
        snap(app, "T2-expanded")
        let a11After = anchor11.exists ? anchor11.frame : .zero
        NSLog("[THINK] T2 after: anchorExists=\(anchor11.exists) frame=\(a11After) Δy=\(a11After.minY - a11Before.minY)")
        // 被点的消息不该飞走：仍在屏内且位移有限（展开在其内部/邻近，允许适度移动）
        let t2OK = anchor11.exists && a11After.height > 1 && a11After.minY > -200 && a11After.minY < 874 && abs(a11After.minY - a11Before.minY) < 400
        XCTAssertTrue(t2OK, "T2 历史中部展开 thinking 后视口跳走（粟粟报的跳远古）")
    }
}

/// [PROBE] 思考过程 sheet 模式（thinkingSheetMode 开关）：点 chip 应弹官端式 sheet 而非原地展开。
final class ThinkingSheetUITests: XCTestCase {
    func testThinkingChipOpensSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed", "-thinkingSheetMode", "YES"]
        app.launch()
        sleep(8)

        let chips = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '思考过程'")).allElementsBoundByIndex
        guard let chip = chips.first(where: { $0.frame.minY > 60 && $0.frame.maxY < 820 && $0.frame.height > 1 }) else {
            XCTFail("屏内找不到思考过程 chip"); return
        }
        chip.tap()
        sleep(2)
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "sheet-open"
        a.lifetime = .keepAlways
        add(a)
        // sheet 标题 + 正文进屏；原地展开则不会出现独立标题层
        let title = app.staticTexts.matching(NSPredicate(format: "label == '思考过程'")).allElementsBoundByIndex
        NSLog("[THINK-SHEET] 思考过程 elements=\(title.count) frames=\(title.map { $0.frame.minY })")
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '思考取证第 1 行'")).firstMatch
        NSLog("[THINK-SHEET] sheet body exists=\(body.exists)")
        XCTAssertTrue(body.exists, "点 chip 后 sheet 正文没出现（开关分流没生效？）")
    }
}

/// [PROBE] 气泡小按钮反馈 smoke：复制→「已复制」toast；删除→二次确认框（点取消不删）。
final class ActionBarFeedbackUITests: XCTestCase {
    func testCopyToastAndDeleteConfirm() {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed"]
        app.launch()
        sleep(8)

        // 屏内一条消息的按钮行：复制键（doc.on.doc）——按 identifier 不可得，用 image button 顺序：
        // 尾条 assistant 行按钮 = [↺ 复制 ⭐ 📌 🗑]。取屏内 trash/copy 用坐标兜底不稳，
        // 直接查 buttons 里的 SFSymbol accessibility label（Copy=拷贝/Duplicate? 系统 label 不稳）
        // → 改走 frame：尾条 KBMARKER123 下方一排小按钮，y ≈ marker.maxY+~24
        let marker = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'KBMARKER123'")).firstMatch
        XCTAssertTrue(marker.exists, "seed 尾条没渲染")
        let m = marker.frame
        // 按钮行（iOS 无 hover 常显）：从 marker 底下 26pt 开始，五键 spacing 12 size 13
        // 直接坐标点第 2 键（复制）：首键 x≈m.minX+? 不可靠——用 buttons 枚举 frame 在按钮行带内的
        let rowY = m.maxY + 20
        let btns = app.buttons.allElementsBoundByIndex.filter { abs($0.frame.midY - rowY) < 22 && $0.frame.width < 44 }
        NSLog("[ACTBAR] row buttons=\(btns.count) frames=\(btns.map { ($0.frame.minX, $0.frame.midY) })")
        guard btns.count >= 3 else { XCTFail("按钮行没找到（\(btns.count)）"); return }

        // 复制 = 第 2 个（↺ 复制 ⭐ 📌 🗑）
        btns[1].tap()
        sleep(1)
        let toast = app.staticTexts["已复制"]
        NSLog("[ACTBAR] copy toast exists=\(toast.exists)")
        XCTAssertTrue(toast.exists, "复制没弹「已复制」toast")
        sleep(2)

        // 删除 = 最后一个 → 确认框出现 → 点取消 → 消息还在
        btns[btns.count - 1].tap()
        sleep(1)
        let confirmBtn = app.buttons["删除"]
        NSLog("[ACTBAR] delete confirm exists=\(confirmBtn.exists)")
        XCTAssertTrue(confirmBtn.exists, "删除没弹二次确认")
        let cancel = app.buttons["Cancel"].exists ? app.buttons["Cancel"] : app.buttons["取消"]
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap() }
        sleep(1)
        XCTAssertTrue(marker.exists, "点取消后消息不该被删")
    }
}

/// [PROBE] B41 草稿随时同步 smoke：type → 回列表 → 重进 → 草稿还在（含键盘没收就退）。
final class DraftSyncUITests: XCTestCase {
    /// 输入框取证：fork 正文段落也是 textView，firstMatch 会抓到消息——取屏内最靠底的可编辑框
    private func inputFieldValue(_ app: XCUIApplication) -> String {
        let cands = (app.textViews.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex)
            .filter { $0.exists && $0.frame.height > 1 && $0.frame.minY > 600 && $0.frame.maxY < 900 }
        guard let field = cands.max(by: { $0.frame.minY < $1.frame.minY }) else { return "" }
        return field.value as? String ?? ""
    }

    func testDraftSurvivesExitAndReenter() {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed"]
        app.launch()
        sleep(8)

        // 打字（键盘保持弹起状态直接退——粟粟 bug1 场景）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        sleep(3)
        XCTAssertTrue(app.keyboards.count > 0, "键盘没起")
        app.typeText("DRAFTXY99")
        sleep(1)

        // 键盘还在就返回列表（左上玻璃返回钮）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.105)).tap()
        sleep(2)
        NSLog("[DRAFT] after back: keyboards=\(app.keyboards.count)")

        // 重进对话（列表行按标题找；三页常驻树里有同名屏外元素，必须过滤 hittable）
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '键盘避让测试对话'")).allElementsBoundByIndex
        NSLog("[DRAFT] title matches=\(rows.count) hittable=\(rows.map { $0.isHittable })")
        guard let row = rows.first(where: { $0.isHittable }) else {
            XCTFail("列表里找不到可点的 seed 对话行"); return
        }
        row.tap()
        sleep(3)

        // 草稿应还在输入框（bug2：xxxyyy 不回退 / bug1：不清空）——带草稿的输入框
        // 元素类型不定（TextField/TextView/其他），按 value 全树找
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "draft-reentered"; a.lifetime = .keepAlways; add(a)
        let value = inputFieldValue(app)
        NSLog("[DRAFT] reentered value=\(value)")
        XCTAssertTrue(value.contains("DRAFTXY99"), "退出重进后草稿丢了（B41）：\(value)")

        // ── 第二段：杀进程重启（@State 蒸发，纯靠库读回）
        app.terminate()
        app.launch()
        sleep(8)
        let value2 = inputFieldValue(app)
        NSLog("[DRAFT] relaunched value=\(value2)")
        let b = XCTAttachment(screenshot: app.screenshot())
        b.name = "draft-relaunched"; b.lifetime = .keepAlways; add(b)
        XCTAssertTrue(value2.contains("DRAFTXY99"), "杀进程重启后草稿丢了（持久化没落）：\(value2)")
    }
}

/// [PROBE] 浮条选段引用 smoke：双击正文出坨坨浮条 → 点「引用」→ 引用预览条出现；
/// 长按菜单不再有「引用」（已删，冗余）。
final class QuoteFromSelectionUITests: XCTestCase {
    func testQuoteViaFloatingMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed"]
        app.launch()
        sleep(8)

        let marker = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'KBMARKER123'")).firstMatch
        XCTAssertTrue(marker.exists, "seed 尾条没渲染")
        marker.doubleTap()
        sleep(2)
        let quoteItem = app.menuItems["引用"]
        let vocabItem = app.menuItems["收生词"]
        NSLog("[QUOTE] menuItems: 引用=\(quoteItem.exists) 收生词=\(vocabItem.exists) total=\(app.menuItems.count)")
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "quote-menu"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(quoteItem.exists, "浮条里没有「引用」")
        quoteItem.tap()
        sleep(2)
        // 引用预览条出现（预览文本=选中段，在输入区上方）
        let previews = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'KBMARKER123' OR value CONTAINS 'KBMARKER123'")).allElementsBoundByIndex
        let low = previews.filter { $0.frame.minY > 600 }
        NSLog("[QUOTE] preview candidates below 600: \(low.map { ($0.frame.minY, $0.elementType.rawValue) })")
        let b = XCTAttachment(screenshot: app.screenshot())
        b.name = "quote-applied"; b.lifetime = .keepAlways; add(b)
        XCTAssertTrue(!low.isEmpty, "点引用后输入区没出现引用预览")
    }
}
