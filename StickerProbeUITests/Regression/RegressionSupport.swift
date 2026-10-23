import XCTest

/// UI 回归套件支架（plan-perf-watch §1.1）。失败信息以 [setup] / [env] / [anchor] / [product] 开头，
/// ui-regress.sh 按前缀给失败分类；V1「挂」只认 [product]。
@MainActor
class RegressionTestCase: XCTestCase {
    let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: 启动

    func launch(_ args: [String], env: [String: String] = [:]) {
        app.launchArguments = args + ["-onboardingCompletedV1", "YES"]
        // 参数来自 runner 的 xctestrun EnvironmentVariables；host 的 export 不代表已传到 runner。
        let runner = ProcessInfo.processInfo.environment
        var forwarded: [String: String] = [:]
        for key in ["MP_LAUNCH_PREWARM", "MP_SPLASH", "MP_PERF_SPLASH",
                    "MP_LAUNCH_FONT_DIRECT", "MP_LAUNCH_PUSH_PROJECTION",
                    "MP_LAUNCH_TRACE_TIME_CACHE", "MP_LAUNCH_TAIL_QUIET_PROBE",
                    // 聊天页局部刀开关（plan-chat-list-perf §3）：K1/K2 带开关跑（TEST_RUNNER_MP_PERF_A5=1 …）
                    "MP_PERF_A3", "MP_PERF_A5", "MP_PERF_A7",
                    "MP_PERF_L1_POOL", "MP_PERF_L1_WIDTH", "MP_PERF_L1_HTRACK", "MP_PERF_L1_SYNC", "MP_PERF_L1_PREFILL"] {
            if let value = runner[key] { forwarded[key] = value }
        }
        forwarded["MP_LAUNCH_PREWARM"] = forwarded["MP_LAUNCH_PREWARM"] ?? "eager"
        forwarded.merge(env) { _, explicit in explicit }
        app.launchEnvironment = forwarded
        // 局部刀 / L1 开关实际传给 AUT 的值（留证：哪一臂真开了）
        record("launch-perf-env", forwarded.filter { $0.key.hasPrefix("MP_PERF_") }.mapValues { $0 as Any })
        app.launch()
        waitFor(pager, "启动策略回报")
        let expected = forwarded["MP_LAUNCH_PREWARM"] ?? "eager"
        let received = launchState()
        record("launch-strategy", ["requested": expected, "AUT": received,
                                   "splashRequested": forwarded["MP_SPLASH"] ?? "default"])
        XCTAssertEqual(received["launchRequested"], expected, "[setup] AUT 未收到启动策略")
        if expected == "covered", forwarded["MP_SPLASH"] != "0", !args.contains("page2-ui-test") {
            XCTAssertEqual(received["launchEffective"], "covered", "[setup] AUT 未实际进入 covered 就绪门：\(received)")
        } else {
            XCTAssertEqual(received["launchEffective"], "eager", "[setup] eager 回退没有生效")
        }
    }

    func launchState() -> [String: String] {
        guard let value = pager.value as? String else { return [:] }
        return Dictionary(value.split(separator: ";").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }, uniquingKeysWith: { _, last in last })
    }

    func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: timeout) else {
            snap("setup-missing-\(what)")
            XCTFail("[setup] 等不到 \(what)", file: file, line: line)
            return
        }
    }

    func until(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    // MARK: 机型

    /// K1/K2 的几何带宽按 iPhone 17 Pro（iPhone18,1，402×874pt）标定；别的机型上出带不是产品回归，报 [env]
    static let geometryCalibratedModel = "iPhone18,1"

    func requireGeometryCalibratedDevice(file: StaticString = #filePath, line: UInt = #line) {
        let env = ProcessInfo.processInfo.environment
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let model = env["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        guard model != Self.geometryCalibratedModel else { return }
        let name = env["SIMULATOR_DEVICE_NAME"].map { "\($0)（\(model)）" } ?? model
        XCTFail("[env] 几何带宽按 iPhone 17 Pro（\(Self.geometryCalibratedModel)）标定，当前是 \(name)；K 系列只在回归机（scripts/devices.conf regress）上算数", file: file, line: line)
    }

    // MARK: 元素

    var field: XCUIElement { app.descendants(matching: .any)["chat-input-field"].firstMatch }
    var pager: XCUIElement { app.scrollViews["paging-scroll"] }
    var keyboard: XCUIElement { app.keyboards.firstMatch }
    var window: CGRect { app.windows.firstMatch.frame }

    /// 按正文文字找消息锚：label 恰好等于或包含 text 的元素里取面积最小的（叶子），并记录匹配数
    func anchor(_ text: String) -> (frame: CGRect, matches: Int)? {
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
        let frames = all.map(\.frame).filter { $0.width > 1 && $0.height > 1 }
        guard let best = frames.min(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return (best, frames.count)
    }

    // MARK: 页码（PagingViewController 的 a11y value：page=N;settled=1[;moved=x]）

    func pagerState() -> (page: Int, settled: Bool, moved: Double?, drags: Int?)? {
        guard pager.exists, let value = pager.value as? String else { return nil }
        var dict: [String: String] = [:]
        for part in value.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        guard let page = dict["page"].flatMap(Int.init) else { return nil }
        return (page, dict["settled"] == "1", dict["moved"].flatMap(Double.init), dict["drags"].flatMap(Int.init))
    }

    func expectPage(_ page: Int, _ why: String = "", timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let ok = until(timeout) { [self] in
            guard let s = pagerState() else { return false }
            return s.page == page && s.settled
        }
        if !ok {
            snap("page-expected-\(page)")
            let prefix = pager.exists ? "[product]" : "[setup]"
            XCTFail("\(prefix) 期望落在 page \(page)\(why.isEmpty ? "" : "（\(why)）")，实际 \(String(describing: pager.value))", file: file, line: line)
        }
    }

    // MARK: 手势

    func swipe(fromX: CGFloat, toX: CGFloat, y: CGFloat = 0.40) {
        app.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: y))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: y)),
                   withVelocity: .default, thenHoldForDuration: 0)
    }
    /// 手指从右往左：翻到下一页（1→2 / 0→1）
    func swipeToNext() { swipe(fromX: 0.82, toX: 0.18) }
    /// 手指从左往右：翻到上一页（1→0 / 2→1）
    func swipeToPrev() { swipe(fromX: 0.18, toX: 0.82) }

    // MARK: 键盘

    func waitKeyboardUp(file: StaticString = #filePath, line: UInt = #line) {
        let ok = until(20) { [self] in
            // 键盘 AX 元素不含底部地球 / 听写那一排，maxY 不贴窗口底（模拟器实测 583+233=816 < 874）；
            // 只要求真的在屏上且占了下半屏
            keyboard.exists && keyboard.isHittable && keyboard.frame.height > 100
                && keyboard.frame.minY < window.maxY - 150 && keyboard.frame.minY > window.midY - 100
        }
        if !ok {
            snap("env-no-soft-keyboard")
            XCTFail("[env] 软键盘没出来（模拟器可能连着硬件键盘）：keyboard=\(keyboard.exists ? keyboard.frame : .zero)", file: file, line: line)
        }
    }

    func waitKeyboardGone(_ category: String = "product", file: StaticString = #filePath, line: UInt = #line) {
        if !until(10, { [self] in !keyboard.exists || keyboard.frame.minY >= window.maxY - 1 }) {
            snap("keyboard-still-up")
            XCTFail("[\(category)] 键盘没收起", file: file, line: line)
        }
    }

    /// 产品规定：滑动不收键盘，点列表空白处收（CardFlowView `.scrollDismissesKeyboard(.never)` + onTapGesture）
    func tapListBlank() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()
    }

    // MARK: 稳定采样

    /// 同一轮读若干 frame，全部非空且连续 3 次（间隔 150ms）一致才采用；超时返回 nil（锚丢了不会被当成「稳定的零」）
    func settle(_ read: @escaping () -> [CGRect], timeout: TimeInterval = 8) -> [CGRect]? {
        var history: [[CGRect]] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frames = read()
            guard frames.allSatisfy({ $0.height > 1 && $0.width > 1 }) else { history.removeAll(); Thread.sleep(forTimeInterval: 0.15); continue }
            history.append(frames)
            if history.count >= 3 {
                let last3 = history.suffix(3)
                let first = last3.first!
                if last3.allSatisfy({ $0.count == first.count && zip($0, first).allSatisfy { a, b in abs(a.minY - b.minY) < 0.5 && abs(a.maxY - b.maxY) < 0.5 && abs(a.minX - b.minX) < 0.5 && abs(a.width - b.width) < 0.5 } }) {
                    return first
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }

    // MARK: 附件

    func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func record(_ name: String, _ values: [String: Any]) {
        let lines = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "\n")
        let a = XCTAttachment(string: lines)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        NSLog("[RG] \(name): \(lines.replacingOccurrences(of: "\n", with: " "))")
    }
}

/// 独立专项，不改变 K1/K2/O1/P1/V1/E2/W1/S1 的含义与分母。
@MainActor
final class LaunchInputReadinessUITests: RegressionTestCase {
    func testLaunchFirstTyped() {
        launch(["--ui-regression-seed"])
        waitFor(field, "输入框")
        field.tap()
        waitKeyboardUp()
        XCTAssertTrue(until(5) { self.launchState()["inputFocused"] == "1" }, "[product] AUT 没有报告输入框 firstResponder")
        let text = "launch-r1"
        field.typeText(text)
        XCTAssertTrue(until(5) { (self.field.value as? String)?.contains(text) == true }, "[product] 首次输入未回读")
        record("launch-firstTyped", ["readback": (field.value as? String)?.contains(text) == true,
                                    "keyboard": keyboard.exists, "AUT": launchState()])
    }
}
