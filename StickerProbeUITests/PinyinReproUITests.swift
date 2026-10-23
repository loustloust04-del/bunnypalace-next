import XCTest

/// T7-R1 拼音回归复现（09-09 粟粟配方）：中文拼音**一次整句打完**→确认候选→已上屏文字变回拼音。
/// 取证型测试：不断言成败，把 field.value 时间线 print 出来；INPROBE 双写落盘由 app 侧记
/// （commit/extWrite/SKIP marked/ECHO/REPLAY 序列，kb-probe.log）。
///
/// 前置：模拟器 AppleKeyboards 拼音置首（zh_Hans-Pinyin）。XCUI typeText 在中文键盘下走组字
///（09-06「中文键盘污染」事故实证），空格 = 确认首选候选（系统标准行为）。
/// ⚠️ 全程不碰发送键（XCUI hello 事故教训：probe 对话连着 cc-bridge）。
final class PinyinReproUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat-input-field"].firstMatch
    }

    private func dump(_ app: XCUIApplication, _ tag: String) {
        let v = (field(app).value as? String) ?? "<nil>"
        print("[PYREPRO] \(tag) len=\(v.count) value=⟨\(v)⟩ kb=\(app.keyboards.count)")
    }

    /// 整句拼音（约 5-8s 连续组字，压 6b 最大间隔闸）→ 空格确认候选 → 观察回声窗口
    func testWholeSentencePinyinCandidateCommit() {
        let app = XCUIApplication()
        app.launchArguments = ["--kb-probe-seed"]
        app.launch()

        let f = field(app)
        XCTAssertTrue(f.waitForExistence(timeout: 15), "input field not found")
        f.tap()
        sleep(1)
        XCTAssertGreaterThan(app.keyboards.count, 0, "software keyboard not present")

        // 键盘语言探测：拼音键盘空格键 label=「空格」，英文=「space」。
        // XCUI 环境可能落英文——点地球键（Next keyboard）切到拼音（AppleKeyboards 拼音置首）
        var kbSwitches = 0
        while !app.keyboards.keys["空格"].exists, kbSwitches < 3 {
            let globe = app.keyboards.buttons["Next keyboard"].exists
                ? app.keyboards.buttons["Next keyboard"]
                : app.keyboards.keys["Next keyboard"]
            print("[PYREPRO] keyboard not pinyin (space=\(app.keyboards.keys["space"].exists ? 1 : 0)), tapping globe exists=\(globe.exists)")
            guard globe.exists else { break }
            globe.tap()
            usleep(600_000)
            kbSwitches += 1
        }
        print("[PYREPRO] pinyin keyboard = \(app.keyboards.keys["空格"].exists ? 1 : 0) after \(kbSwitches) switches")

        dump(app, "before")
        // 整句拼音逐键 tap key 元素（typeText 会强制切 ASCII 键盘，key.tap 走真按键路径；
        // 逐键 180ms ≈ 真人快打，26 键 ≈ 5s 组字期，保证 1.5s 闸在组字期触发 3 次以上）
        let pinyin = "zhegeyidiandoubuhuishuohua"
        for ch in pinyin {
            let key = app.keyboards.keys[String(ch)]
            if key.exists { key.tap() } else { f.typeText(String(ch)) }
            usleep(120_000)
        }
        dump(app, "composed")
        takeShot(app, name: "pyrepro-composed")

        // 空格 = 确认首选候选（她「在键盘里按」的标准路径之一）
        let spaceKey = app.keyboards.keys["空格"]
        if spaceKey.exists { spaceKey.tap() } else { f.typeText(" ") }
        usleep(300_000)
        dump(app, "committed+0.3s")
        takeShot(app, name: "pyrepro-committed")

        // 回声窗口观察：stale body 迟到通常在下一拍到几百 ms
        usleep(700_000)
        dump(app, "committed+1.0s")
        sleep(2)
        dump(app, "committed+3.0s")
        takeShot(app, name: "pyrepro-final")

        // 附加一段短句再确认一次（连续两次 commit 靠近的老 T7 形态叠加验证）
        for ch in "nihao" {
            let key = app.keyboards.keys[String(ch)]
            if key.exists { key.tap() } else { f.typeText(String(ch)) }
            usleep(120_000)
        }
        if spaceKey.exists { spaceKey.tap() } else { f.typeText(" ") }
        usleep(300_000)
        dump(app, "second+0.3s")
        sleep(2)
        dump(app, "second+2.3s")
        takeShot(app, name: "pyrepro-second")
    }

    private func takeShot(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
