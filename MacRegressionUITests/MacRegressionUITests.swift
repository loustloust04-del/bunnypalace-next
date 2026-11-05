import AppKit
import Darwin
import QuartzCore
import XCTest

/// AUT 只由外部运行器持有。这里没有 launch / activate / terminate，也不处理系统授权弹框。
@MainActor
final class MacRegressionUITests: XCTestCase {
    private let bundleID = "com.susu.MemoryPalace.perfbench"
    private var pid: pid_t = 0
    private var app: XCUIApplication!
    private var root: URL!
    private var bundlePath = ""
    private var driver = ""
    private var session = ""
    private var windowID = 0
    private var results: [CaseResult] = []
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func testOwnedMacRegression() throws {
        continueAfterFailure = false
        do {
            let env = ProcessInfo.processInfo.environment
            bundlePath = try required(env, "MP_UI_BENCH_APP")
            driver = try required(env, "MP_CUA_DRIVER")
            session = try required(env, "MP_UI_SESSION")
            root = URL(fileURLWithPath: try required(env, "MP_UI_BENCH_ROOT"), isDirectory: true)
            guard let ownedPID = pid_t(try required(env, "MP_UI_BENCH_PID")), ownedPID > 1,
                  bundlePath.hasPrefix("/"), driver.hasPrefix("/"), root.path.hasPrefix("/private/tmp/mp-macperf-sol/bench-"),
                  root.resolvingSymlinksInPath().path == root.path, session == "sol-macperf-ui" else {
                throw Failure("setup", "运行器身份/绝对路径无效")
            }
            pid = ownedPID
            let fixtureURL = try inside(try required(env, "MP_UI_FIXTURE"))
            guard fixtureURL == root.appendingPathComponent("perf/fixture.json"),
                  FileManager.default.isExecutableFile(atPath: driver) else {
                throw Failure("setup", "fixture 或 cua-driver 不属于本次运行")
            }
            let fixture: Fixture = try decode(fixtureURL)
            guard fixture.revision == "macV1-r1-fixture", fixture.profiles == ["perf-bench-profile", "perf-bench-small"],
                  let conversation = fixture.chats.first(where: { $0.name == "A" }), conversation.orderedPath.count == 60,
                  let smallCode = fixture.code.first(where: { $0.name == "small" }),
                  let largeCode = fixture.code.first(where: { $0.name == "large" }) else {
                throw Failure("setup", "冻结的真实合成 fixture 契约不符")
            }
            for code in fixture.code { _ = try inside(code.path) }
            try attachOwnedApplication()
            try runCase("MK1") {
                try exerciseComposer()
                return ["composer": "S34 AXTextField 发消息…；输入一字并删除，未发送"]
            }
            try runCase("MO1") {
                try openChat(title: "Mac perf A — 60 messages")
                try wait("A 的最新消息不可见") { self.visibleText("[\(conversation.conversationID), turn 59]") != nil }
                try require(app.menuButtons.allElementsBoundByIndex.contains { $0.label == "Mac perf A — 60 messages" },
                            "assertion", "A 的标题没有落到当前对话菜单")
                try exerciseComposer()
                return ["conversationID": conversation.conversationID, "latest": conversation.orderedPath[59]]
            }
            try runCase("MP1") { try checkPanels() }
            try runCase("MC1") { try checkCodeScrolling(smallCode) }
            try runCase("MC-restart") {
                try openCode(largeCode)
                let oldPID = pid
                let response = try control("restart")
                try require(response.pid != oldPID, "setup", "重启没有产生新的自持 PID")
                pid = response.pid
                try attachOwnedApplication()
                try wait("R-tab 重启后聊天输入框未就绪", timeout: 30) { self.composer.exists && self.composer.isEnabled }
                try exerciseComposer()
                let checkpoint = try waitGuard { $0.observedThrough >= $0.startedAt + 10 }
                try checkGuard(checkpoint, from: checkpoint.startedAt, through: checkpoint.startedAt + 10)
                return ["previousPID": String(oldPID), "pid": String(pid), "guardSeconds": "10"]
            }
            try runCase("MC-live") { try checkCodeLive(largeCode) }
            try runCase("MS1") { try checkSettings() }
            try runCase("MF1") { try checkFullscreen() }
            try runCase("MF2") { try checkFloors() }
            try runCase("MT1") { try checkStream(fixture) }
        } catch {
            XCTFail(String(describing: error))
            throw error
        }
    }

    private var composer: XCUIElement {
        // S34 的实际控件是 SwiftUI.AppKitTextField；不把旧 TextView id 当见证。
        app.textFields.matching(NSPredicate(format: "label == %@ OR placeholderValue == %@", "发消息…", "发消息…")).firstMatch
    }

    private func attachOwnedApplication() throws {
        try identity()
        app = XCUIApplication(url: URL(fileURLWithPath: bundlePath))
        try require(app.state == .runningForeground || app.state == .runningBackground,
                    "environment", "XCUI 没有附着已运行的隔离包")
        try wait("自持主窗未就绪", timeout: 30) {
            guard let windows = try? self.windows() else { return false }
            guard let window = windows.first(where: { $0.bounds.width >= 980 && $0.is_on_screen }) else { return false }
            self.windowID = window.window_id
            return self.app.windows.allElementsBoundByIndex.contains { $0.exists && $0.frame.width >= 980 }
        }
    }

    private func identity() throws {
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
              running.bundleIdentifier == bundleID, running.bundleURL?.path == bundlePath,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier) == [pid] else {
            throw Failure("setup", "PID、绝对 bundle 路径、bundleID 或唯一进程不符；拒绝查询/操作 AUT")
        }
    }

    private func exerciseComposer() throws {
        try wait("实际 AXTextField 未就绪") { self.composer.exists && self.composer.isEnabled && self.composer.isHittable }
        let original = try fieldValue(composer)
        try require(original.isEmpty || original == "发消息…", "setup", "合成输入框已有非空草稿，拒绝覆盖")
        try tap(composer)
        try type("字", into: composer)
        try wait("输入一字未进入真实输入框") { (try? self.fieldValue(self.composer)) == "字" }
        try key("delete", at: composer)
        try wait("删除没有清空输入框") {
            guard let value = try? self.fieldValue(self.composer) else { return false }
            return value.isEmpty || value == "发消息…"
        }
        try require(!app.staticTexts["字"].exists, "assertion", "输入测试把字发送到了正文")
    }

    private func openChat(title: String) throws {
        try showSidebar()
        if app.buttons["对话"].exists { try tap(app.buttons["对话"]) }
        let search = app.textFields.matching(NSPredicate(format: "identifier == %@ OR label == %@", "mac-conversation-search", "搜索对话…")).firstMatch
        try wait("对话搜索框未就绪") { search.exists && search.isHittable }
        try replace(title, in: search)
        try key("return", at: search)
        try wait("真实合成会话搜索未命中：\(title)") {
            self.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title))
                .allElementsBoundByIndex.contains { $0.isHittable && $0.frame.minY > search.frame.maxY }
        }
        // 重新取节点，不复用搜索前的 AX 快照。
        let target = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title))
            .allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > search.frame.maxY }
        guard let target else { throw Failure("assertion", "命中的会话行消失") }
        try tap(target)
        try wait("会话加载后不能输入") { self.composer.exists && self.composer.isEnabled }
    }

    private func showSidebar() throws {
        if !app.textFields["搜索对话…"].isHittable && !app.textFields["筛选编程会话…"].isHittable {
            try tap(sidebarButton())
        }
        try wait("左栏没有展开") {
            self.app.textFields["搜索对话…"].isHittable || self.app.textFields["筛选编程会话…"].isHittable
        }
    }

    private func sidebarButton() throws -> XCUIElement {
        guard let button = app.buttons.allElementsBoundByIndex.first(where: {
            ["Toggle Sidebar", "sidebar.leading", "列表"].contains($0.label) && $0.isHittable
        }) else { throw Failure("setup", "实际 AX 树没有左栏开关") }
        return button
    }

    private func dockButton() throws -> XCUIElement {
        guard let button = app.buttons.allElementsBoundByIndex.first(where: {
            ["sidebar.trailing", "工具"].contains($0.label) && $0.isHittable
        }) else { throw Failure("setup", "实际 AX 树没有右栏开关") }
        return button
    }

    private func setPanelMode(_ label: String) throws {
        let control = app.descendants(matching: .any).allElementsBoundByIndex.first {
            $0.isHittable && ($0.label == "面板布局" || $0.label.hasPrefix("面板模式："))
        }
        guard let control else { throw Failure("setup", "实际 AX 树没有面板布局菜单") }
        try tap(control)
        let item = app.menuItems[label].firstMatch
        try wait("布局菜单没有\(label)") { item.exists }
        try tap(item)
    }

    private func checkPanels() throws -> [String: String] {
        try setPanelMode("全屏")
        try showSidebar()
        let expanded = try transcriptFrame()
        try tap(sidebarButton())
        try wait("收左栏后正文仍保留空槽") { ((try? self.transcriptFrame().width) ?? 0) > expanded.width + 100 }
        let leftClosed = try transcriptFrame()
        try require(leftClosed.minX < expanded.minX - 100, "assertion", "正文没有填左栏原位置")
        try tap(sidebarButton())
        try wait("开左栏正文没有复原") { self.near((try? self.transcriptFrame()) ?? .zero, expanded) }
        let calendar = app.buttons.matching(NSPredicate(format: "label == %@", "日历")).allElementsBoundByIndex.filter(\.isHittable).max { $0.frame.minX < $1.frame.minX }
        guard let calendar else { throw Failure("setup", "自有 Dock 没有日历入口") }
        try tap(calendar)
        try wait("日历工具没有真实打开") { self.app.buttons["关闭日历"].exists }
        let toolOpen = try transcriptFrame()
        try tap(dockButton())
        try wait("收右栏后正文没有扩展") { ((try? self.transcriptFrame().width) ?? 0) > toolOpen.width + 100 }
        try require(app.buttons.matching(NSPredicate(format: "label == %@", "日历")).allElementsBoundByIndex.contains(where: \.isHittable), "assertion", "停靠模式把常驻 Dock 一并隐藏")
        try tap(dockButton())
        try wait("开右栏正文没有复原") { self.near((try? self.transcriptFrame()) ?? .zero, toolOpen) }
        try setPanelMode("窗口")
        let floating = try transcriptFrame()
        try tap(dockButton())
        try wait("窗口模式 Dock 未收起") { !self.app.buttons.matching(NSPredicate(format: "label == %@", "日历")).allElementsBoundByIndex.contains(where: \.isHittable) }
        try require(near(try transcriptFrame(), floating), "assertion", "浮窗模式收 Dock 改变了正文 frame")
        try tap(dockButton())
        try wait("窗口模式 Dock 未展开") { self.app.buttons.matching(NSPredicate(format: "label == %@", "日历")).allElementsBoundByIndex.contains(where: \.isHittable) }
        try setPanelMode("全屏")
        return ["leftExpanded": describe(expanded), "leftClosed": describe(leftClosed), "toolOpen": describe(toolOpen), "floating": describe(floating)]
    }

    private func openCode(_ code: Fixture.Code) throws {
        try showSidebar()
        try tap(app.buttons["Code"].firstMatch)
        let field = app.textFields["筛选编程会话…"].firstMatch
        try wait("Code 筛选框未就绪") { field.exists && field.isHittable }
        let name = URL(fileURLWithPath: code.path).deletingPathExtension().lastPathComponent
        try replace(name, in: field)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "session \(name)")).firstMatch
        try wait("Code 原生 fixture 行未出现") { row.exists && row.isHittable }
        try tap(row)
        try wait("Code 真实正文未加载", timeout: 45) {
            guard let viewport = try? self.transcriptFrame() else { return false }
            return self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "session \(name)"))
                .allElementsBoundByIndex.contains { $0.isHittable && $0.frame.minX >= viewport.minX && $0.frame.intersects(viewport) }
        }
    }

    private func checkCodeScrolling(_ code: Fixture.Code) throws -> [String: String] {
        try openCode(code)
        let initial = "MP-UI-initial-\(UUID().uuidString)"
        try appendCode(code, text: initial)
        try wait("Code 初始尾部没有跟随真实追加", timeout: 30) { self.visibleText(initial) != nil }
        let scroller = try transcriptElement()
        try scroll("up", in: scroller, pages: 2)
        try wait("上翻没有离开最新回复") { self.visibleText(initial) == nil && self.app.buttons["scroll-to-bottom"].isHittable }
        let viewport = try transcriptFrame()
        guard let anchor = app.staticTexts.allElementsBoundByIndex.first(where: {
            $0.label.contains("Revision ") && $0.isHittable && viewport.contains($0.frame) && $0.frame.height > 10
        }) else { throw Failure("setup", "实际 Code AX 正文没有可钉住的一段原生文本") }
        let anchorLabel = anchor.label
        let anchorY = anchor.frame.minY
        let previousBar = try scrollbarValue(in: viewport)
        let appended = "MP-UI-off-bottom-\(UUID().uuidString)"
        try appendCode(code, text: appended)
        // 比较真实滚动条归一化位置：内容变长已被 UI 消费，不靠定时 sleep 假定刷新。
        try wait("Code 未消费离底追加的正文布局", timeout: 30) {
            guard let current = try? self.scrollbarValue(in: viewport) else { return false }
            return current < previousBar
        }
        let retained = app.staticTexts[anchorLabel].firstMatch
        try require(retained.exists && abs(retained.frame.minY - anchorY) <= 2 && visibleText(appended) == nil,
                    "assertion", "真实追加把上翻位置拉回尾部")
        try tap(app.buttons["scroll-to-bottom"].firstMatch)
        try wait("回底没有显示刚追加的回复") { self.visibleText(appended) != nil }
        let followed = "MP-UI-follow-\(UUID().uuidString)"
        try appendCode(code, text: followed)
        try wait("在底部时追加没有自动跟随", timeout: 30) { self.visibleText(followed) != nil }
        return ["codeKey": code.key, "anchorY": String(describing: anchorY), "maximumAnchorDrift": "2pt", "followed": followed]
    }

    private func checkCodeLive(_ code: Fixture.Code) throws -> [String: String] {
        try openCode(code)
        _ = try control("start-live")
        let current: Fixture = try decode(root.appendingPathComponent("perf/fixture.json"))
        guard let load = current.loads.first(where: { $0.level == "L1c" }), load.codeKey == code.key,
              load.pid > 1, load.files.contains(code.path) else { throw Failure("setup", "L1c 没有实际自持 writer/选中会话") }
        let heartbeatURL = try inside(load.heartbeatPath)
        let before: Heartbeat = try decode(heartbeatURL)
        try require(before.pid == load.pid, "setup", "writer 心跳 PID 不符")
        var previous = before.completedWorkUnits
        let start = CACurrentMediaTime()
        var responses = 0
        for checkpoint in 1...12 {
            try wait("writer 观测窗口未推进", timeout: 20) { CACurrentMediaTime() >= start + Double(checkpoint) * 15 }
            let heartbeat: Heartbeat = try decode(heartbeatURL)
            try require(heartbeat.pid == load.pid && heartbeat.completedWorkUnits > previous,
                        "assertion", "3 分钟中真实 jsonl writer 停滞")
            previous = heartbeat.completedWorkUnits
            try tap(sidebarButton())
            try wait("持续写入期间左栏点击无响应", timeout: 5) { !self.app.textFields["筛选编程会话…"].isHittable }
            try tap(sidebarButton())
            try wait("持续写入期间左栏无法重新展开", timeout: 5) { self.app.textFields["筛选编程会话…"].isHittable }
            responses += 1
        }
        let end = CACurrentMediaTime()
        let guardState = try waitGuard { $0.observedThrough >= end }
        try checkGuard(guardState, from: start, through: end)
        _ = try control("stop-live")
        let after: Heartbeat = try decode(heartbeatURL)
        try require(after.elapsed - before.elapsed >= 180 && after.completedWorkUnits > before.completedWorkUnits,
                    "assertion", "writer 的实际工作没有覆盖 180 秒")
        return ["codeKey": code.key, "writerPID": String(load.pid), "seconds": String(end - start), "responsiveClicks": String(responses * 2)]
    }

    private func openSettings() throws -> Int {
        try tap(app.buttons["设置"].firstMatch)
        var selected = 0
        try wait("自有设置窗未打开") {
            guard let window = try? self.windows().first(where: { $0.bounds.width >= 780 && $0.bounds.width < 980 }) else { return false }
            selected = window.window_id
            return true
        }
        windowID = selected
        return selected
    }

    private func selectSettings(_ title: String, subtitle: String) throws {
        let search = app.textFields["搜索设置"].firstMatch
        try wait("设置搜索框未就绪") { search.exists && search.isHittable }
        try replace(title, in: search)
        let row = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex.first { $0.frame.minX < search.frame.maxX && $0.isHittable }
        guard let row else { throw Failure("assertion", "设置目录没有\(title)") }
        try tap(row)
        try wait("设置\(title)没有呈现对应真实内容") {
            self.app.staticTexts.matching(NSPredicate(format: "label == %@", subtitle)).allElementsBoundByIndex.contains { $0.isHittable && $0.frame.minX > search.frame.maxX }
        }
    }

    private func closeSettings() throws {
        var request = CUARequest(pid: pid, session: session, window_id: windowID)
        request.keys = ["cmd", "w"]
        request.delivery_mode = "foreground"
        _ = try cua("hotkey", request)
        try attachOwnedApplication()
    }

    private func checkSettings() throws -> [String: String] {
        _ = try openSettings()
        for page in Self.settingsPages {
            if page.0 == "开发调试" { try appendHangSummaryFixture() }
            try selectSettings(page.0, subtitle: page.1)
            if page.0 == "开发调试" {
                try wait("真实设置页没有把前台两次心跳按上下文合并") {
                    self.app.descendants(matching: .any).matching(identifier: "mac-hang-group-heartbeat")
                        .allElementsBoundByIndex.contains {
                            $0.label.contains("bin=11111111") && $0.label.contains("active=1")
                                && $0.label.contains("2条") && $0.label.contains("最大1.25s")
                        }
                }
                try require(app.descendants(matching: .any).matching(identifier: "mac-hang-group-triggerLowerBound")
                    .allElementsBoundByIndex.contains { $0.label.contains("bin=11111111") && $0.label.contains("最大0.50s") },
                    "assertion", "采样下界被丢弃或和心跳真值混合")
            }
        }
        try closeSettings()
        return ["pages": Self.settingsPages.map { $0.0 }.joined(separator: ","), "count": String(Self.settingsPages.count)]
    }

    private func appendHangSummaryFixture() throws {
        let url = try inside(root.appendingPathComponent("home/Library/Application Support/MemoryPalace/perf/hangs.log").path)
        let prefix = "2026-10-21 10:00:00 pid=12 bin=11111111-1111-1111-1111-111111111111 build=ui-synthetic origin=fixture"
        let rows = [
            "\(prefix) hang 0.50s cpu=20% active=1 code=1 detailLoaded=1 tool=terminal",
            "\(prefix) hang 1.25s cpu=20% active=1 code=1 detailLoaded=1 tool=terminal",
            "\(prefix) hang 4.00s cpu=20% active=0 code=1 detailLoaded=1 tool=terminal",
            "\(prefix) hang 0.50s lowerBound=1 → sample-20261021-100000.txt"
        ]
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data((rows.joined(separator: "\n") + "\n").utf8))
    }

    private func checkFullscreen() throws -> [String: String] {
        try openChat(title: "Mac perf A — 60 messages")
        let before = try mainWindow().bounds
        var request = CUARequest(pid: pid, session: session, window_id: windowID)
        request.keys = ["ctrl", "cmd", "f"]
        request.delivery_mode = "foreground"
        _ = try cua("hotkey", request)
        try wait("原生全屏切换没有改变自持窗口尺寸", timeout: 20) {
            guard let current = try? self.mainWindow().bounds else { return false }
            return abs(current.width - before.width) > 10 || abs(current.height - before.height) > 10
        }
        let fullscreen = try mainWindow().bounds
        try exerciseComposer()
        _ = try cua("hotkey", request)
        try wait("退出全屏未恢复原生窗口尺寸", timeout: 20) {
            guard let current = try? self.mainWindow().bounds else { return false }
            return abs(current.width - before.width) <= 2 && abs(current.height - before.height) <= 2
        }
        try exerciseComposer()
        return ["before": "\(before.width)x\(before.height)", "fullscreen": "\(fullscreen.width)x\(fullscreen.height)"]
    }

    private func checkFloors() throws -> [String: String] {
        _ = try openSettings()
        try selectSettings("通用", subtitle: "管理楼层与消息标签。")
        guard let largeMenu = app.menuButtons.allElementsBoundByIndex.first(where: { $0.label.contains("[PERF]") && $0.isHittable }) else {
            throw Failure("setup", "通用页没有合成大楼层菜单")
        }
        try tap(largeMenu)
        try tap(app.menuItems.matching(NSPredicate(format: "label CONTAINS %@", "Mac perf small")).firstMatch)
        try wait("切小楼层没有落地") { self.app.staticTexts["100 conversations / 2000 messages"].exists }
        try closeSettings()
        try openChat(title: "Mac perf small 0: Reading notes")
        try wait("小楼层没有真实最新消息") { self.visibleText("[mac-perf-small-0, turn 19]") != nil }
        try exerciseComposer()
        _ = try openSettings()
        try selectSettings("通用", subtitle: "管理楼层与消息标签。")
        try tap(app.menuButtons.matching(NSPredicate(format: "label CONTAINS %@", "Mac perf small")).firstMatch)
        try tap(app.menuItems.matching(NSPredicate(format: "label CONTAINS %@", "[PERF]")).firstMatch)
        try closeSettings()
        try openChat(title: "Mac perf A — 60 messages")
        try wait("回大楼层后真实 A 不可见") { self.visibleText("[mac-perf-A, turn 59]") != nil }
        return ["small": "mac-perf-small-0/19", "restored": "mac-perf-A/59"]
    }

    private func checkStream(_ fixture: Fixture) throws -> [String: String] {
        try require(fixture.streamConversationID == "mac-perf-stream" && fixture.streamPresetID == "mac-perf-stream-preset",
                    "setup", "不是冻结的真实本地 provider fixture")
        try openChat(title: "Mac perf scripted stream")
        try type("[UI] 本地流式回归", into: composer)
        var request = CUARequest(pid: pid, session: session, window_id: windowID)
        request.keys = ["cmd", "return"]
        request.element_token = try token(for: composer)
        _ = try cua("hotkey", request)
        let expected = String(repeating: "测量本地流式文字", count: 375)
        try wait("真实本地 provider 没有开始流式", timeout: 20) {
            self.visibleText("测量本地流式文字") != nil && !self.app.staticTexts[expected].exists
        }
        let started = CACurrentMediaTime()
        try wait("流式正文没有长到可真实滚动的视口", timeout: 90) {
            guard let row = self.visibleText("测量本地流式文字"), let viewport = try? self.transcriptFrame() else { return false }
            return row.frame.height > viewport.height + 80 && row.label.count < expected.count - 300
        }
        guard let growing = visibleText("测量本地流式文字") else { throw Failure("assertion", "流式正文消失") }
        let initial = growing.label.count
        try scroll("up", in: transcriptElement(), pages: 2)
        try wait("流式中滚动没有真正离开尾部") {
            guard let row = self.visibleText("测量本地流式文字"), let viewport = try? self.transcriptFrame() else { return false }
            return row.frame.maxY > viewport.maxY + 20
        }
        try type("流式中草稿", into: composer)
        try wait("流式期间无法编辑真实草稿") { (try? self.fieldValue(self.composer)) == "流式中草稿" }
        try wait("编辑草稿期间流式正文停止推进", timeout: 20) {
            self.app.staticTexts.allElementsBoundByIndex.contains { $0.label.hasPrefix("测量本地流式文字") && $0.label.count > initial + 30 && $0.label.count < expected.count }
        }
        try replace("", in: composer)
        if app.buttons["scroll-to-bottom"].isHittable { try tap(app.buttons["scroll-to-bottom"]) }
        else { try scroll("down", in: transcriptElement(), pages: 50) }
        try wait("流式终稿未完整渲染并跟随最后一段", timeout: 130) {
            let final = self.app.staticTexts[expected].firstMatch
            guard final.exists, let viewport = try? self.transcriptFrame() else { return false }
            return final.frame.maxY <= viewport.maxY + 2 && final.frame.maxY >= viewport.minY + 16
        }
        let draft = try fieldValue(composer)
        try require(draft.isEmpty || draft == "发消息…", "assertion", "流式编辑后的草稿未清空")
        return ["credential": "mac-perf-scripted", "conversationID": fixture.streamConversationID, "characters": String(expected.count), "seconds": String(CACurrentMediaTime() - started)]
    }

    private func transcriptElement() throws -> XCUIElement {
        let main = app.windows.allElementsBoundByIndex.first { $0.frame.width >= 980 }
        guard let main else { throw Failure("setup", "主窗 AX 丢失") }
        let codeText = main.staticTexts.allElementsBoundByIndex.first { $0.isHittable && $0.label.contains("The source record is appended") }
        let inputX = composer.isHittable ? composer.frame.midX : (codeText?.frame.midX ?? main.frame.midX)
        guard let scroller = main.scrollViews.allElementsBoundByIndex.filter({
            $0.isHittable && $0.frame.height > 150 && $0.frame.minX <= inputX && $0.frame.maxX >= inputX
        }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw Failure("setup", "实际 AX 没有可唯一定位的正文滚动区；不以非空节点替代 frame 断言")
        }
        return scroller
    }

    private func transcriptFrame() throws -> CGRect { try transcriptElement().frame }
    private func visibleText(_ fragment: String) -> XCUIElement? {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).allElementsBoundByIndex.first { $0.isHittable }
    }
    private func near(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2 && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }
    private func describe(_ frame: CGRect) -> String { "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)" }

    private func snapshot() throws -> Snapshot {
        var request = CUARequest(pid: pid, session: session, window_id: windowID)
        request.include_screenshot = false
        request.max_elements = 4000
        request.timeout_ms = 5000
        let snapshot = try decoder.decode(Snapshot.self, from: cua("get_window_state", request))
        try require(snapshot.pid == pid && snapshot.window_id == windowID, "environment", "AX 快照 PID/窗口不符")
        try require(snapshot.elements_complete != false && snapshot.truncated != true, "environment", "AX 快照不完整，拒绝非空过关")
        try require(!snapshot.elements.contains { $0.role == "AXSheet" || $0.role == "AXDialog" }, "environment", "自持窗口有弹框；不代点授权")
        return snapshot
    }

    private func token(for element: XCUIElement) throws -> String {
        try require(element.exists && element.isHittable, "assertion", "目标 UI 控件不存在或不可交互：\(element.label)")
        let frame = element.frame
        let state = try snapshot()
        let candidates = state.elements.filter {
            guard let bounds = $0.frame else { return false }
            return abs(bounds.x - frame.minX) <= 2 && abs(bounds.y - frame.minY) <= 2
                && abs(bounds.w - frame.width) <= 2 && abs(bounds.h - frame.height) <= 2
        }
        guard var current = candidates.first(where: { $0.label == element.label || ($0.label == nil && element.label.isEmpty) })
                ?? (candidates.count == 1 ? candidates.first : nil) else {
            throw Failure("setup", "实际 AX 没有该控件的精确 frame：\(element.label)")
        }
        while true {
            if ["AXTextField", "AXTextArea", "AXScrollArea", "AXOpaqueProviderGroup", "AXRow"].contains(current.role)
                || (current.actions ?? []).contains("AXPress") {
                guard let token = current.element_token else { break }
                return token
            }
            guard let parent = current.parent_index,
                  let ancestor = state.elements.first(where: { $0.element_index == parent }) else { break }
            current = ancestor
        }
        throw Failure("setup", "实际 AX 没有可操作的语义祖先：\(element.label)")
    }

    private func fieldValue(_ field: XCUIElement) throws -> String {
        let state = try snapshot()
        guard let value = state.elements.first(where: {
            guard let bounds = $0.frame else { return false }
            return $0.role == "AXTextField" && near(bounds.rect, field.frame)
        })?.value else { throw Failure("environment", "真实原生文本框没有 AXValue") }
        return value
    }

    private func tap(_ element: XCUIElement) throws {
        var request = CUARequest(pid: pid, session: session, window_id: windowID)
        request.element_token = try token(for: element)
        _ = try cua("click", request)
    }
    private func type(_ text: String, into field: XCUIElement) throws {
        var request = CUARequest(pid: pid, session: session, window_id: windowID)
        request.element_token = try token(for: field); request.text = text
        _ = try cua("type_text", request)
    }
    private func key(_ name: String, at field: XCUIElement) throws {
        var request = CUARequest(pid: pid, session: session, window_id: windowID)
        request.element_token = try token(for: field); request.key = name
        _ = try cua("press_key", request)
    }
    private func replace(_ text: String, in field: XCUIElement) throws {
        var request = CUARequest(pid: pid, session: session, window_id: windowID)
        request.element_token = try token(for: field); request.keys = ["cmd", "a"]
        _ = try cua("hotkey", request)
        if text.isEmpty { try key("delete", at: field) } else { try type(text, into: field) }
    }
    private func scroll(_ direction: String, in element: XCUIElement, pages: Int) throws {
        var request = CUARequest(pid: pid, session: session, window_id: windowID)
        request.element_token = try token(for: element); request.direction = direction; request.by = "page"; request.amount = pages
        _ = try cua("scroll", request)
    }
    private func scrollbarValue(in viewport: CGRect) throws -> Double {
        let bars = try snapshot().elements.filter {
            guard let frame = $0.frame else { return false }
            return $0.role == "AXScrollBar" && frame.h > frame.w && frame.x > viewport.midX
                && frame.x <= viewport.maxX + 2 && frame.y >= viewport.minY - 2 && frame.y < viewport.maxY
        }
        guard bars.count == 1, let text = bars[0].value, let value = Double(text), value > 0 && value < 1 else {
            throw Failure("setup", "离底 Code 滚动条没有唯一真实归一化位置")
        }
        return value
    }

    private func windows() throws -> [Window] {
        try decoder.decode(WindowList.self, from: cua("list_windows", CUARequest(pid: pid, session: session))).windows.filter { $0.pid == pid }
    }
    private func mainWindow() throws -> Window {
        guard let window = try windows().first(where: { $0.window_id == windowID }) else { throw Failure("environment", "自持主窗消失") }
        return window
    }
    private func cua(_ operation: String, _ request: CUARequest) throws -> Data {
        try identity()
        try require(request.pid == pid && request.session == session, "setup", "拒绝无自持 PID 的 cua 请求")
        let outputURL = try inside(root.appendingPathComponent("perf/ui-cua-\(UUID().uuidString).json").path)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: driver)
        process.arguments = ["call", operation, String(decoding: try encoder.encode(request), as: UTF8.self)]
        var clientEnvironment = ProcessInfo.processInfo.environment
        clientEnvironment["HOME"] = try required(clientEnvironment, "MP_UI_CUA_HOME")
        clientEnvironment["CFFIXED_USER_HOME"] = clientEnvironment["HOME"]
        process.environment = clientEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw Failure("environment", "cua 自持子进程超时：\(operation)")
        }
        let data = try Data(contentsOf: outputURL)
        try require(process.terminationStatus == 0, "environment", "cua \(operation) 失败：\(String(decoding: data.prefix(2048), as: UTF8.self))")
        return data
    }

    private func appendCode(_ code: Fixture.Code, text: String) throws {
        let url = try inside(code.path)
        let name = url.deletingPathExtension().lastPathComponent
        let id = "ui-\(UUID().uuidString)"
        let row = CodeRow(type: "assistant", uuid: id, sessionId: name,
                          cwd: try inside(root.appendingPathComponent("perf/code-project").path).path,
                          timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                          message: .init(id: id, role: "assistant", model: "mac-perf-fixture", content: [.init(type: "text", text: text)]))
        var data = try encoder.encode(row); data.append(0x0a)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
    }
    private func control(_ operation: String) throws -> ControlResponse {
        let env = ProcessInfo.processInfo.environment
        let requestURL = try inside(try required(env, "MP_UI_CONTROL_REQUEST"))
        let responseURL = try inside(try required(env, "MP_UI_CONTROL_RESPONSE"))
        let request = ControlRequest(id: UUID().uuidString, operation: operation)
        try encoder.encode(request).write(to: requestURL, options: .atomic)
        var response: ControlResponse?
        try wait("自持运行器控制无回应：\(operation)", timeout: 60) {
            guard let value: ControlResponse = try? self.decode(responseURL), value.id == request.id else { return false }
            response = value; return true
        }
        guard let response, response.status == "ok", response.pid > 1 else {
            throw Failure("environment", response?.error ?? "自持运行器拒绝\(operation)")
        }
        return response
    }
    private func waitGuard(_ ready: @escaping (MainThreadCheckpoint) -> Bool) throws -> MainThreadCheckpoint {
        var checkpoint: MainThreadCheckpoint?
        try wait("缺少覆盖本次窗口的真实主线程观察器 checkpoint", timeout: 35) {
            guard let value: MainThreadCheckpoint = try? self.decode(self.root.appendingPathComponent("perf/ui-main-thread.json")),
                  value.pid == self.pid, ready(value) else { return false }
            checkpoint = value; return true
        }
        guard let checkpoint else { throw Failure("setup", "主线程观察前置缺失") }
        return checkpoint
    }
    private func checkGuard(_ checkpoint: MainThreadCheckpoint, from start: Double, through end: Double) throws {
        try require(!checkpoint.overflow && checkpoint.startedAt <= start && checkpoint.observedThrough >= end
                    && end > start && checkpoint.maximumBlockSeconds.isFinite && checkpoint.maximumBlockSeconds >= 0
                    && checkpoint.longBlocks.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }),
                    "environment", "主线程观察器覆盖不足、溢出或无效")
        try require(!checkpoint.longBlocks.contains { $0.start < end && $0.end > start && $0.end - $0.start > 1 },
                    "assertion", "独立 UI 窗口内有真实 >1s 主线程忙段")
    }
    private func runCase(_ name: String, _ body: () throws -> [String: String]) throws {
        let started = CACurrentMediaTime()
        do {
            let evidence = try body()
            results.append(.init(caseID: name, status: "passed", failures: [], startedAt: started, endedAt: CACurrentMediaTime(), evidence: evidence))
        } catch {
            results.append(.init(caseID: name, status: "failed", failures: [String(describing: error)], startedAt: started, endedAt: CACurrentMediaTime(), evidence: [:]))
            try encoder.encode(CaseResults(cases: results)).write(to: root.appendingPathComponent("perf/ui-case-results.json"), options: .atomic)
            throw error
        }
        try encoder.encode(CaseResults(cases: results)).write(to: root.appendingPathComponent("perf/ui-case-results.json"), options: .atomic)
    }
    private func wait(_ message: String, timeout: Double = 15, _ predicate: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else { throw Failure("assertion", message) }
    }
    private func require(_ condition: Bool, _ category: String, _ message: String) throws {
        if !condition { throw Failure(category, message) }
    }
    private func required(_ env: [String: String], _ key: String) throws -> String {
        guard let value = env[key], !value.isEmpty else { throw Failure("setup", "缺少\(key)") }
        return value
    }
    private func inside(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw Failure("setup", "拒绝读取/写入本次隔离根外路径")
        }
        return url
    }
    private func decode<T: Decodable>(_ url: URL) throws -> T { try decoder.decode(T.self, from: Data(contentsOf: inside(url.path))) }

    private struct Failure: Error, CustomStringConvertible {
        let category: String; let message: String
        init(_ category: String, _ message: String) { self.category = category; self.message = message }
        var description: String { "[\(category)] \(message)" }
    }
    private struct Fixture: Decodable {
        struct Chat: Decodable { let name, profileID, conversationID: String; let orderedPath: [String]; let longNodeID: String }
        struct Code: Decodable { let name, key, path: String; let minimumBytes: UInt64 }
        struct Load: Decodable { let level: String; let pid: pid_t; let heartbeatPath: String; let files: [String]; let codeKey: String? }
        let revision: String; let profiles: [String]; let chats: [Chat]; let code: [Code]; let loads: [Load]
        let streamConversationID, streamPresetID: String
    }
    private struct CUARequest: Encodable {
        let pid: pid_t; let session: String; var window_id: Int? = nil
        var element_token: String?; var text: String?; var key: String?; var keys: [String]?
        var direction: String?; var by: String?; var amount: Int?; var delivery_mode: String?
        var include_screenshot: Bool?; var max_elements: Int?; var timeout_ms: Int?
    }
    private struct WindowList: Decodable { let windows: [Window] }
    private struct Window: Decodable {
        struct Bounds: Decodable { let x, y, width, height: Double }
        let pid: pid_t; let window_id: Int; let bounds: Bounds; let is_on_screen: Bool
    }
    private struct Snapshot: Decodable {
        struct Element: Decodable {
            struct Frame: Decodable { let x, y, w, h: Double; var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) } }
            let role: String; let label, value, element_token: String?; let actions: [String]?; let frame: Frame?
            let element_index: Int; let parent_index: Int?
        }
        let pid: pid_t; let window_id: Int; let elements: [Element]; let elements_complete, truncated: Bool?
    }
    private struct CodeRow: Encodable {
        struct Message: Encodable {
            struct Block: Encodable { let type, text: String }
            let id, role, model: String; let content: [Block]
        }
        let type, uuid, sessionId, cwd: String; let timestamp: Int64; let message: Message
    }
    private struct Heartbeat: Decodable { let pid: pid_t; let completedWorkUnits: Int; let elapsed: Double }
    private struct ControlRequest: Encodable { let id, operation: String }
    private struct ControlResponse: Decodable { let id, status: String; let pid: pid_t; let error: String? }
    private struct MainThreadCheckpoint: Decodable {
        struct Block: Decodable { let start, end: Double }
        let pid: pid_t; let startedAt, observedThrough, maximumBlockSeconds: Double; let longBlocks: [Block]; let overflow: Bool
    }
    private struct CaseResults: Encodable { let cases: [CaseResult] }
    private struct CaseResult: Encodable {
        let caseID, status: String; let failures: [String]; let startedAt, endedAt: Double; let evidence: [String: String]
        enum CodingKeys: String, CodingKey { case caseID = "case", status, failures, startedAt, endedAt, evidence }
    }

    // 与当前 macSidebarGroups/macTabs 一致；每页核正文副标题，不以侧栏标题或非空树通过。
    private static let settingsPages: [(String, String)] = [
        ("通用", "管理楼层与消息标签。"), ("Mac 工作区", "管理 Dock 图标、分组、面板布局与编程会话入口。"),
        ("外观", "调整主题、文字、聊天显示与气泡。"), ("权限", "管理 AI 访问范围、自动行为与系统授权。"),
        ("右栏", "选择右栏工具与面板内容。"), ("模型和API", "管理 API Keys、模型、联网搜索与预算。"),
        ("用量", "查看各模型、各卡片的调用次数、Token 与花费。"), ("Prompt", "编辑预设、提示词插槽与请求参数。"),
        ("小芽", "小芽助手的人设。"), ("记忆", "管理记忆提取、注入策略与记忆条目。"),
        ("朗读", "设置系统朗读、语速与语音消息。"), ("MCP", "连接与管理 MCP 工具服务。"),
        ("让手机连这台 Mac", "启动 hub、配对手机，设置 Agent 干活的目录。"), ("Claude Code", "配置 Claude Code 连接与会话行为。"),
        ("Codex", "查看 Codex 桥连接与会话使用说明。"), ("Agent", "管理 Agent、定时任务与自动行为。"),
        ("贴纸", "管理贴纸来源、图库与触发选项。"), ("健康", "设置健康数据访问与记录权限。"),
        ("日历", "设置月历样子、日记与纪念日给不给 AI 看。"), ("交易", "设置交易数据访问与研究权限。"),
        ("书房", "选择自主读书与共读使用的模型。"), ("单词", "设置出词顺序、复习与提问模板。"),
        ("群聊", "设置群聊开关、发言模式与节奏。"), ("附件", "设置图片发送数量与图片转述。"),
        ("文件库", "管理文件存储、同步与清理。"), ("数据与备份", "导入、导出、同步与备份数据。"),
        ("config", "导入与导出应用配置。"), ("文档", "查看应用功能说明与使用文档。"),
        ("开发调试", "查看诊断信息、反馈与调试工具。"), ("关于", "版本信息与开源致谢。"),
        ("世界书", "查看与管理当前楼层绑定的世界书。"), ("正则", "管理消息处理与显示用的正则规则。")
    ]
}
