import XCTest

/// [PROBE] 「有时候点输入框最新消息不起来」复现器（research-keyboard-list-inset §7 追凶）：
/// --kb-probe-seed 种 22 条消息 api 对话（尾条 user=KBMARKER123），分场景弹键盘断言尾条浮上键盘顶。
/// 场景矩阵：①在底弹 ②收起再弹 ③离底(翻历史 500pt+)弹 ④回底再弹。
/// ⚠️ 不用机器人真发消息：CC 对话会打生产 hub（隔离铁律）+ 预算闸弹窗拦发送。
final class KeyboardLatestVisibleUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func kbTop(_ app: XCUIApplication) -> CGFloat {
        app.keyboards.count > 0 ? app.keyboards.firstMatch.frame.minY : .greatestFiniteMagnitude
    }

    private func tapInputBar(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        sleep(3)
    }

    /// 场景取证：键盘起着时标记气泡是否可见（maxY <= 键盘顶）
    @discardableResult
    private func assertMarkerVisible(_ app: XCUIApplication, scene: String) -> Bool {
        let marker = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'KBMARKER123'")).firstMatch
        let kb = kbTop(app)
        let exists = marker.exists
        let frame = exists ? marker.frame : .zero
        let visible = exists && frame.height > 1 && frame.maxY <= kb + 1 && frame.minY >= 0
        NSLog("[KB-LATEST] \(scene): markerExists=\(exists) frame=\(frame) kbTop=\(kb) visible=\(visible)")
        snap(app, "scene-\(scene)")
        XCTAssertTrue(visible, "\(scene)：键盘起着但最新消息没浮上来（粟粟报的 bug）")
        return visible
    }

    func testLatestMessageRisesWithKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed"]
        app.launch()
        sleep(8)  // 启动 + seed 对话 auto-select + 列表渲染
        snap(app, "0-launch")
        let seeded = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'KBMARKER123'")).firstMatch
        NSLog("[KB-LATEST] seed check: marker exists=\(seeded.exists) frame=\(seeded.exists ? seeded.frame : .zero)")
        if !seeded.exists {
            let labels = app.staticTexts.allElementsBoundByIndex.prefix(40).map { String($0.label.prefix(24)) }
            NSLog("[KB-LATEST] staticTexts count=\(app.staticTexts.count) labels=\(labels)")
            let others = app.otherElements.matching(NSPredicate(format: "label CONTAINS 'KBMARKER123'")).count
            let anyEl = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'KBMARKER123'")).count
            NSLog("[KB-LATEST] otherElements-with-marker=\(others) anyType-with-marker=\(anyEl)")
        }
        XCTAssertTrue(seeded.exists, "seed 对话没被选中/尾条没渲染")

        // ── 场景① 在底弹
        tapInputBar(app)
        assertMarkerVisible(app, scene: "①在底弹")

        // ── 场景② 收起再弹（interactive dismiss：列表向下拖）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        sleep(2)
        NSLog("[KB-LATEST] after dismiss-drag: keyboards=\(app.keyboards.count)")
        tapInputBar(app)
        assertMarkerVisible(app, scene: "②收起再弹")

        // ── 场景③ 离底弹：收键盘 → 翻历史（向上滚两次）→ 弹
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        sleep(2)
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
            sleep(1)
        }
        let markerBefore3 = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'KBMARKER123'")).firstMatch
        NSLog("[KB-LATEST] ③离底后标记位置: exists=\(markerBefore3.exists) frame=\(markerBefore3.exists ? markerBefore3.frame : .zero)")
        tapInputBar(app)
        // ③升级断言：键盘冷弹回底（onChange extra）+ 垫块顶起 → 最新消息应可见
        assertMarkerVisible(app, scene: "③离底弹")

        // ── 场景④ 回底再弹：收键盘 → 点回底按钮（真回底，拖拽 flick 距离不可靠）→ 弹
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        sleep(2)
        let backToBottom = app.descendants(matching: .any).matching(identifier: "scroll-to-bottom").firstMatch
        NSLog("[KB-LATEST] ④回底按钮: exists=\(backToBottom.exists) hittable=\(backToBottom.exists && backToBottom.isHittable)")
        if backToBottom.exists && backToBottom.isHittable {
            backToBottom.tap()
        } else {
            for _ in 0..<4 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
                sleep(1)
            }
        }
        sleep(2)
        tapInputBar(app)
        assertMarkerVisible(app, scene: "④回底再弹")
    }
}
