import XCTest

/// 可拖滚动条验收（plan-chat-scrubber §4 V1 / V7）。细条只在手滚后出现，所以每次抓之前先轻拖一下列表；
/// `-chatScrubberHideDelay 30` 让它别在 XCUITest 等静止的空当里淡出。
/// 轨道：底 thumb 中心 = 输入字段顶 − 82（让回底钮 60 + 半条 22），顶 = 安全区顶 + 86；x = 屏宽 − 15。
/// 拖动按位移映射、到端点夹住，所以「拖到顶」直接把手指拖出轨道上方即可。
final class ChatScrubberUITests: XCTestCase {
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

    private func onScreen(_ e: XCUIElement, _ app: XCUIApplication) -> Bool {
        guard e.exists else { return false }
        let f = e.frame
        let w = app.windows.firstMatch.frame
        return f.height > 1 && f.maxY > 80 && f.minY < w.height - 120
    }

    private func point(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// 轻拖一下列表让细条出来（在底往上推一点 = 橡皮筋，内容不走）
    private func flash(_ app: XCUIApplication, towardOlder: Bool = false) {
        let w = app.windows.firstMatch.frame
        let from = point(app, w.width * 0.45, w.height * 0.5)
        let to = point(app, w.width * 0.45, w.height * (towardOlder ? 0.56 : 0.44))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    private func bottomThumb(_ app: XCUIApplication) -> XCUICoordinate {
        let w = app.windows.firstMatch.frame
        let field = app.descendants(matching: .any)["chat-input-field"].firstMatch
        let fieldTop = field.exists ? field.frame.minY : w.height - 108
        return point(app, w.width - 15, fieldTop - 82)
    }

    private func topThumb(_ app: XCUIApplication) -> XCUICoordinate {
        point(app, app.windows.firstMatch.frame.width - 15, 62 + 86)
    }

    private func launch(_ args: [String], env: [String: String] = [:], wait: UInt32) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args + ["-chatScrubberHideDelay", "30"]
        app.launchEnvironment = env
        app.launch()
        sleep(wait)
        return app
    }

    /// V1：按住不动不跳 → 拖到顶见第一条 → 松手 2s 不漂 → 拖回底见尾条
    func testScrubShortConversation() {
        let app = launch(["--kb-probe-seed"], wait: 8)
        let tail = el(app, "KBMARKER123")
        XCTAssertTrue(onScreen(tail, app), "seed 尾条不在屏内")
        snap(app, "S0-launch")

        // 按住不动 1.5s：内容不能动（首抓零跳）
        flash(app)
        let before = tail.frame
        let thumb = bottomThumb(app)
        thumb.press(forDuration: 1.5, thenDragTo: thumb)
        sleep(1)
        XCTAssertEqual(tail.frame.minY, before.minY, accuracy: 2, "按住不动时内容跳了")
        snap(app, "S1-hold-still")

        // 拖到顶（慢拖 + 末端停 1s 看提示）
        flash(app)
        let top = point(app, app.windows.firstMatch.frame.width - 15, 20)
        bottomThumb(app).press(forDuration: 0.3, thenDragTo: top, withVelocity: 400, thenHoldForDuration: 1.0)
        let first = el(app, "键盘取证填充消息 0：")
        XCTAssertTrue(onScreen(first, app), "拖到顶后第一条不在屏内")
        let landed = first.frame
        snap(app, "S2-at-top")
        sleep(2)
        XCTAssertEqual(first.frame.minY, landed.minY, accuracy: 2, "松手后 2s 内容漂了")

        // 拖回底
        flash(app, towardOlder: true)
        let bottom = point(app, app.windows.firstMatch.frame.width - 15, app.windows.firstMatch.frame.height - 20)
        topThumb(app).press(forDuration: 0.3, thenDragTo: bottom, withVelocity: 400, thenHoldForDuration: 0.5)
        sleep(1)
        XCTAssertTrue(onScreen(tail, app), "拖回底后尾条不在屏内")
        snap(app, "S3-back-bottom")
    }

    /// V7：3000 条（不带自动滚写手）最新 → 最旧 → 最新，记耗时
    func testScrubLongConversation() {
        let app = launch(["--perf-bench"], env: ["MP_PERF_NO_AUTOSCROLL": "1"], wait: 20)
        snap(app, "L0-launch")
        flash(app)
        let t0 = Date()
        let top = point(app, app.windows.firstMatch.frame.width - 15, 20)
        bottomThumb(app).press(forDuration: 0.3, thenDragTo: top, withVelocity: 600, thenHoldForDuration: 1.0)
        let first = el(app, "第 0 条。")
        let reached = first.waitForExistence(timeout: 5) && onScreen(first, app)
        NSLog("[SCRUB-UIT] long up: reached=\(reached) elapsed=\(Date().timeIntervalSince(t0))")
        XCTAssertTrue(reached, "3000 条拖到顶后第 0 条不在屏内")
        snap(app, "L1-at-top")
        sleep(2)
        snap(app, "L2-top-after-2s")

        flash(app, towardOlder: true)
        let t1 = Date()
        let bottom = point(app, app.windows.firstMatch.frame.width - 15, app.windows.firstMatch.frame.height - 20)
        topThumb(app).press(forDuration: 0.3, thenDragTo: bottom, withVelocity: 600, thenHoldForDuration: 1.0)
        let last = el(app, "基准填充消息 2999")
        let back = last.waitForExistence(timeout: 5) && onScreen(last, app)
        NSLog("[SCRUB-UIT] long down: reached=\(back) elapsed=\(Date().timeIntervalSince(t1))")
        XCTAssertTrue(back, "3000 条拖回底后尾条不在屏内")
        snap(app, "L3-back-bottom")
    }

    /// 状态栏点一下回最旧：3000 条（原 scrollTo 首条卡 8–9s）
    func testStatusBarTapToOldestLongConversation() {
        let app = launch(["--perf-bench"], env: ["MP_PERF_NO_AUTOSCROLL": "1"], wait: 20)
        let t0 = Date()
        // app 接「点顶部」的是 80pt 透明层：系统状态栏本身（y<安全区顶）的点击走 scrollsToTop（聊天列表关了），
        // 真正落到这层的是状态栏下沿到 80pt 那一条，避开左侧返回钮
        point(app, 130, 72).tap()
        let first = el(app, "第 0 条。")
        let reached = first.waitForExistence(timeout: 10) && onScreen(first, app)
        NSLog("[SCRUB-UIT] status-bar tap: reached=\(reached) elapsed=\(Date().timeIntervalSince(t0))")
        XCTAssertTrue(reached, "点状态栏后第 0 条不在屏内")
        snap(app, "T1-status-bar-top")
    }

    /// V2：生成中拖（宿主先起 `python3 scripts/stream-smoke-server.py --paragraphs 25 --interval 0.03`）。
    /// 冒烟对话先发 3 条攒出可翻的历史，第 4 条吐字时抓条拖到中段按住 2s，松手再看 2s：所看历史不被推走。
    /// ⚠️ 默认跳过：XCUITest 合成手势 / 查询时走 `_UIHostingView._renderForTest` 强制同步渲染，在生成中的长 Markdown
    /// 列表上会陷进 LazyVStack `measureEstimates` 出不来（lldb 栈取证），真人触摸不走这条路——
    /// 同场景 idb 注入不卡（`scripts/scrubber-stream-repro.sh`）。要跑：`TEST_RUNNER_SCRUB_STREAM_UIT=1`。
    func testScrubWhileStreaming() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCRUB_STREAM_UIT"] == "1", "XCUITest 渲染钩子在生成中长列表上假死，改用 idb 脚本验")
        let app = launch(["--stream-smoke"], wait: 8)
        let w = app.windows.firstMatch.frame
        let conv = el(app, "[SMOKE]")
        for _ in 0..<3 where !(conv.exists && conv.isHittable) {
            point(app, 38, 91).tap()                  // 顶栏左箭头 → 对话列表（启动停在哪页不固定）
            sleep(2)
        }
        XCTAssertTrue(conv.waitForExistence(timeout: 5), "冒烟对话不在列表里")
        conv.tap()
        sleep(3)
        func send(_ text: String) {
            app.descendants(matching: .any)["chat-input-field"].firstMatch.tap()
            sleep(1)
            app.typeText(text)
            sleep(1)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.615)).tap()
        }
        for i in 1...3 {
            send("smoke \(i)")
            sleep(12)
        }
        snap(app, "V0-history-ready")
        send("smoke 4")
        sleep(2)                                      // 在吐字
        if ProcessInfo.processInfo.environment["SCRUB_MODE"] == "swipe" {
            // 对照组：不碰滚动条，普通手势往旧翻两下（二分「卡死」是不是滚动条引起的）
            for _ in 0..<2 {
                point(app, w.width * 0.45, w.height * 0.3)
                    .press(forDuration: 0.05, thenDragTo: point(app, w.width * 0.45, w.height * 0.75))
            }
        } else {
            flash(app, towardOlder: true)
            let mid = point(app, w.width - 15, w.height * 0.45)
            bottomThumb(app).press(forDuration: 0.3, thenDragTo: mid, withVelocity: 300, thenHoldForDuration: 2.0)
        }
        let candidates = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '段：'")).allElementsBoundByIndex
        guard let anchor = candidates.first(where: { onScreen($0, app) }) else {
            XCTFail("拖到中段后屏内没有可当参照的段落"); snap(app, "V1-no-anchor"); return
        }
        let y0 = anchor.frame.minY
        snap(app, "V1-released")
        sleep(2)
        NSLog("[SCRUB-UIT] stream: anchor y \(y0) → \(anchor.frame.minY)")
        XCTAssertEqual(anchor.frame.minY, y0, accuracy: 3, "松手后生成中的历史被推走了")
        snap(app, "V2-after-2s")
    }
}
