import XCTest

/// iu0901 Lane C · 输入框高度抖动的机械量化（**软键盘在场**）。
///
/// Lane B 的 idb 抽帧全程没升起软键盘（HID 通道），只拿到弱阴性。XCUITest 走真实
/// 输入系统：`typeText` 打在软键盘上，`app.keyboards.count > 0` 可断言键盘真在场。
///
/// 不变量（本测试机械断言的东西）：
///   1. 字符键之间 `chat-input-field` 高度**不变**（一行内打字不该动高度）
///   2. 每次换行**恰一次台阶**（严格增，幅度 ≈ 一个行高，不回摆）
///   3. 退格删掉换行后走迟滞回单行（不在中途来回跳）
///   4. 发送清空后回到单行高度
///   5. （iu0902 C2）稳态（已聚焦、非空、不换行、不跨 `/`）连打 30 键，`ChatInputBar.body` 增量 ≤ 2
///      —— 计数经 `InputPerfProbe` 挂在输入框 a11y label 上（`--kb-probe-seed` 才开）
///
/// 已知上限：逐键读 frame 的节拍 ≈ 50–150ms/键，抓不到 16ms 级单帧回摆；本测试的价值是
/// 「稳态高度只允许在换行/退格/发送时变」这条不变量可以进 CI 当回归闸。
/// 为了尽量摸到瞬态，每步读两次高度（h1/h2），两次不等 = 无输入却在动 = 抖动证据。
///
/// ⚠️ 用 `--kb-probe-seed` 种的本地 `api` 对话（KeyboardProbeSeed），**不接 CC / 不发生产 hub 流量**；
/// 发送必然失败（无 key），但输入框清空链路照走 = 高度回落面完整。
final class InputHeightJitterUITests: XCTestCase {

    private static let charCount = 30
    private static let newlineCount = 4
    /// 与 `ChatInputRepresentable.Coordinator.maxCommitGapSeconds` 同源（codex A1）：
    /// 连打不留空档时每 1.5s 强制提交一次，稳态预算要按连打时长把这些算进去
    private static let maxCommitGapSeconds = 1.5

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: 取证

    private struct Sample {
        let step: String
        let idx: Int
        let len: Int
        let h1: CGFloat
        let h2: CGFloat
        let minY: CGFloat
        let kb: Int
    }

    private var samples: [Sample] = []

    /// 每次都新建 element：XCUIElement 会缓存快照，复用同一个实例读不到新 frame
    private func field(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat-input-field"].firstMatch
    }

    @discardableResult
    private func record(_ app: XCUIApplication, _ step: String, _ idx: Int) -> Sample {
        let f1 = field(app).frame
        let f2 = field(app).frame      // 立刻二读：无输入还在动 = 抖
        let len = (field(app).value as? String)?.count ?? -1
        let s = Sample(step: step, idx: idx, len: len,
                       h1: f1.height, h2: f2.height, minY: f1.minY,
                       kb: app.keyboards.count)
        samples.append(s)
        NSLog("[LANEC] step=%@ idx=%d len=%d h1=%.2f h2=%.2f minY=%.2f kb=%d",
              step, idx, len, f1.height, f2.height, f1.minY, s.kb)
        return s
    }

    /// iu0902 C2：输入框的 a11y label 在 `--kb-probe-seed` 下挂着 body 计数
    /// （`InputPerfProbe`，`perf bar=N field=M`）。测试进程读不到 app 容器里的 kb-probe.log，
    /// 走 a11y 树是唯一不落盘的通道。返回 (bar, field)，读不到返回 nil。
    private func perfCounters(_ app: XCUIApplication) -> [String: Int]? {
        let label = field(app).label
        guard label.hasPrefix("perf ") else { return nil }
        var out: [String: Int] = [:]
        for token in label.dropFirst(5).split(separator: " ") {
            let kv = token.split(separator: "=")
            guard kv.count == 2, let v = Int(kv[1]) else { continue }
            out[String(kv[0])] = v
        }
        return out.isEmpty ? nil : out
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func dumpJSONL() {
        // 报告管道从 xcodebuild 输出里 grep 这些行拼 lane-c-heights.json
        for s in samples {
            NSLog("[LANEC-JSON] {\"step\":\"%@\",\"idx\":%d,\"len\":%d,\"h1\":%.2f,\"h2\":%.2f,\"minY\":%.2f,\"kb\":%d}",
                  s.step, s.idx, s.len, s.h1, s.h2, s.minY, s.kb)
        }
    }

    // MARK: 主用例

    func testInputHeightInvariantsWithSoftKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed"]
        app.launch()
        sleep(8)

        // 通知权限弹窗防御
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons["Don't Allow"]
        if dontAllow.waitForExistence(timeout: 3) { dontAllow.tap() }

        XCTAssertTrue(field(app).waitForExistence(timeout: 15), "输入框（chat-input-field）没出现")

        // ── 1. 升软键盘 ───────────────────────────────────────────────
        var kbUp = false
        for _ in 0..<4 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.93)).tap()
            sleep(2)
            let focused = (field(app).value(forKey: "hasKeyboardFocus") as? Bool) ?? false
            if app.keyboards.count > 0 { kbUp = true; break }
            if focused { continue }
        }
        NSLog("[LANEC] keyboards=%d after focus attempts", app.keyboards.count)
        snap(app, "lane-c-01-keyboard-up")
        // 软键盘在场是本 lane 的前提（Lane B 弱阴性的根因）——不在场直接红，别拿硬件键盘的
        // 结果冒充软键盘结论
        XCTAssertTrue(kbUp, "软键盘没起来（Connect Hardware Keyboard 还开着？）—— Lane C 前提不成立")

        let baseline = record(app, "focused-empty", 0)
        XCTAssertGreaterThan(baseline.h1, 1, "聚焦后输入框高度为 0")

        // ── 2. 逐键打字：高度必须一动不动 + 稳态不进 SwiftUI（iu0902 C2）───
        // 英文（模拟器中文键盘打不出，KeyboardB2Regression 的教训）
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

        // ── 2a. C2 稳态窗口（iu0902）：先种一个字符离开「空」态——空⇄非空是提交点 3，
        // 不属于稳态（kimi Y4）。**连打必须是一次 typeText 的连续击键**：逐键 record 的节拍
        // 是 ~1s/键 > 300ms 去抖窗，那样每键都会去抖提交一次，量到的是测试节拍不是实现。
        app.typeText("x")
        let seed = record(app, "seed", 0)
        XCTAssertEqual(seed.h1, baseline.h1, accuracy: 0.6,
                       "不变量1 破：第一个字符就改了高度（空→非空不该变高）")
        sleep(2)   // 让 300ms 去抖提交 + 600ms 打字空闲翻转都落定，别渗进测量窗口

        let steadyText = String((0..<Self.charCount).map { alphabet[$0 % alphabet.count] })
        let perfBefore = perfCounters(app)
        XCTAssertNotNil(perfBefore,
                        "读不到 body 计数（a11y label=\"\(field(app).label)\"）——InputPerfProbe 没挂上？")
        let burstT0 = Date()
        app.typeText(steadyText)
        let burstSeconds = Date().timeIntervalSince(burstT0)
        sleep(3)   // 收尾去抖 + 打字空闲翻转都算进窗口
        let perfAfter = perfCounters(app)
        XCTAssertNotNil(perfAfter, "读不到 body 计数（收尾）")
        snap(app, "lane-c-02a-c2-steady")

        if let a = perfBefore, let b = perfAfter {
            let dKeys = (b["keys"] ?? 0) - (a["keys"] ?? 0)
            let dBar = (b["bar"] ?? 0) - (a["bar"] ?? 0)
            let dField = (b["field"] ?? 0) - (a["field"] ?? 0)
            let dCommit = (b["commits"] ?? 0) - (a["commits"] ?? 0)
            // 预算随连打时长走（codex A1 之后）：收尾去抖 1 + 余量 1 + **最大间隔闸每 1.5s 一次**。
            // XCUITest 的 typeText 比真人慢，30 键要好几秒——写死 ≤2 会随机器快慢翻红。
            let maxGapHits = Int(burstSeconds / Self.maxCommitGapSeconds)
            let budget = 2 + maxGapHits
            NSLog("[LANEC] C2 steady: keys +%d, commits +%d, ChatInputBar.body +%d, InputFieldContainer.body +%d (burst %.2fs, budget %d)",
                  dKeys, dCommit, dBar, dField, burstSeconds, budget)
            NSLog("[LANEC-JSON] {\"step\":\"c2-steady\",\"keys\":%d,\"commits\":%d,\"barBodyDelta\":%d,\"fieldBodyDelta\":%d,\"burstSeconds\":%.2f,\"budget\":%d}",
                  dKeys, dCommit, dBar, dField, burstSeconds, budget)
            // 先证明真的打进去了 30 键（否则「body 没涨」是假绿）
            XCTAssertEqual(dKeys, Self.charCount,
                           "C2 前提破：稳态窗口只收到 \(dKeys) 次击键（应 \(Self.charCount)）")
            XCTAssertLessThanOrEqual(dCommit, budget,
                "C2 破：稳态 \(Self.charCount) 键提交了 \(dCommit) 次（预算 \(budget) = 收尾去抖 1 + 余量 1 + 最大间隔闸 \(maxGapHits) 次 / 连打 \(burstSeconds)s）")
            XCTAssertLessThanOrEqual(dBar, budget,
                "C2 破：稳态连打 \(Self.charCount) 键 ChatInputBar.body 涨了 \(dBar) 次（预算 \(budget)）。打字又在走 SwiftUI 状态更新了。")
            XCTAssertLessThanOrEqual(dField, budget * 2 + 4,
                "C2 警戒：稳态连打 \(Self.charCount) 键 InputFieldContainer.body 涨了 \(dField) 次（预算 \(budget * 2 + 4)：每次提交 1 + 打字空闲翻转 2 + 余量）")
        }

        // 清空，让后面的逐键高度不变量从空态重新开始（+1 是 seed 那个 x）
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: Self.charCount + 1))
        sleep(2)
        XCTAssertEqual((field(app).value as? String)?.count ?? -1, 0, "清空失败，后面的高度不变量测不了")

        // ── 2b. 逐键打 30 个字符：高度必须一动不动 ─────────────────────
        for i in 0..<Self.charCount {
            app.typeText(String(alphabet[i % alphabet.count]))
            record(app, "char", i + 1)
        }
        snap(app, "lane-c-02-after-30-chars")

        let charPhase = samples.filter { $0.step == "char" }
        let charHeights = Set(charPhase.map { round($0.h1 * 10) / 10 })
        NSLog("[LANEC] char-phase distinct heights = %@", "\(charHeights.sorted())")
        // 不变量 1：字符键之间高度不变
        XCTAssertEqual(charHeights.count, 1,
                       "不变量1 破：30 个字符键之间高度变了 \(charHeights.sorted())（应恒定；若是自然折行请缩短 charCount）")
        XCTAssertEqual(charPhase.first?.h1 ?? -1, seed.h1, accuracy: 0.6,
                       "不变量1 破：稳态第一键就改了高度")
        // 同步二读不等 = 无输入还在动
        for s in charPhase {
            XCTAssertEqual(s.h1, s.h2, accuracy: 0.6,
                           "不变量1 破：char#\(s.idx) 同一步两次读到不同高度 \(s.h1)/\(s.h2)（稳态回摆=抖）")
        }

        let singleLineH = charPhase.last?.h1 ?? baseline.h1

        // ── 3. 4 次换行：每次恰一次台阶 ───────────────────────────────
        var stepHeights: [CGFloat] = [singleLineH]
        for i in 0..<Self.newlineCount {
            app.typeText("\n")
            sleep(1)                       // 0.22s easeOut 动画 + 布局落定
            let s = record(app, "newline", i + 1)
            stepHeights.append(s.h1)
        }
        snap(app, "lane-c-03-after-4-newlines")

        var deltas: [CGFloat] = []
        for i in 1..<stepHeights.count { deltas.append(stepHeights[i] - stepHeights[i - 1]) }
        NSLog("[LANEC] newline deltas = %@", "\(deltas)")
        // 第 1 次换行同时翻 isMultiline（inset 10/10 → 15/2），台阶 = 行高 - 3；后续 = 整行高
        let lineH = deltas.count >= 2 ? deltas[1] : (deltas.first ?? 0)
        XCTAssertGreaterThan(lineH, 5, "换行台阶太小（<5pt），换行没生效？")
        for (i, d) in deltas.enumerated() {
            XCTAssertGreaterThan(d, 0, "不变量2 破：第 \(i + 1) 次换行高度没涨（d=\(d)）")
            XCTAssertLessThanOrEqual(d, lineH * 1.6 + 6,
                                     "不变量2 破：第 \(i + 1) 次换行涨了不止一个台阶（d=\(d), 行高≈\(lineH)）")
        }
        for s in samples.filter({ $0.step == "newline" }) {
            XCTAssertEqual(s.h1, s.h2, accuracy: 0.6,
                           "不变量2 破：newline#\(s.idx) 同一步两次读到不同高度 \(s.h1)/\(s.h2)")
        }

        // ── 4. 退格删回单行：单调下降 + 最后回单行高 ───────────────────
        for i in 0..<Self.newlineCount {
            app.typeText(XCUIKeyboardKey.delete.rawValue)
            sleep(1)
            record(app, "delete", i + 1)
        }
        snap(app, "lane-c-04-after-backspace")

        let delPhase = samples.filter { $0.step == "delete" }
        NSLog("[LANEC] delete heights = %@", "\(delPhase.map { $0.h1 })")
        var prev = stepHeights.last ?? singleLineH
        for s in delPhase {
            XCTAssertLessThanOrEqual(s.h1, prev + 0.6,
                                     "不变量3 破：退格 #\(s.idx) 高度反而涨了（\(prev)→\(s.h1)）")
            prev = s.h1
        }
        if let last = delPhase.last {
            XCTAssertEqual(last.h1, singleLineH, accuracy: 2.0,
                           "不变量3 破：删完换行没回到单行高度（\(last.h1) vs \(singleLineH)）")
        }

        // ── 5. 发送清空：回单行高度 ───────────────────────────────────
        let send = app.buttons["Up"]
        if send.waitForExistence(timeout: 5) {
            send.tap()
        } else {
            NSLog("[LANEC] ⚠️ 发送键（label=Up）没找到，退坐标点")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.615)).tap()
        }
        sleep(3)
        let afterSend = record(app, "send", 1)
        snap(app, "lane-c-05-after-send")
        XCTAssertEqual(afterSend.h1, baseline.h1, accuracy: 2.0,
                       "不变量4 破：发送后没回到单行高度（\(afterSend.h1) vs 空态 \(baseline.h1)）")

        dumpJSONL()
    }
}
