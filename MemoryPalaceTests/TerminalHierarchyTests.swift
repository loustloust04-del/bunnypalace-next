import XCTest
@testable import 记忆花园

/// 终端层级改造（plan-terminal-hierarchy 刀A/刀B/刀D）里跟帧相关的纯逻辑。
/// UI 在 `#if os(iOS)` 里，这个 target 是 macOS —— 所以能测的都被刻意放在跨端类型上。
final class TerminalHierarchyTests: XCTestCase {

    // MARK: - A2 滚动/点击判据三态

    /// hub 说开了鼠标上报 → 转发 SGR 滚轮，哪怕它是个 mp-win- 裸壳窗口
    /// （裸 shell 里 ssh 进对面的 CC / 开 vim 就是这种情况）
    func testMouseAnyTrueForwardsRegardlessOfPrefix() {
        XCTAssertEqual(TerminalMouseMode.resolve(mouseAny: true, sessionName: "mp-win-3f2a"), .forwarding)
        XCTAssertEqual(TerminalMouseMode.resolve(mouseAny: true, sessionName: "mp-cc"), .forwarding)
    }

    /// hub 说没开 → 本地滚，哪怕它是对话绑定的 CC session（退出 CC 回到 shell 就是这种情况）
    func testMouseAnyFalseGoesLocalRegardlessOfPrefix() {
        XCTAssertEqual(TerminalMouseMode.resolve(mouseAny: false, sessionName: "mp-cc"), .local)
        XCTAssertEqual(TerminalMouseMode.resolve(mouseAny: false, sessionName: "mp-win-3f2a"), .local)
    }

    /// nil = 老 hub 没发字段 → 退回前缀老规则。
    /// **这条是滚炸案（`65;1;1M` 刷屏）的唯一防线**：mp-win-* 必须判成 local，一个字节都不发。
    func testMouseAnyNilFallsBackToPrefixRule() {
        XCTAssertEqual(TerminalMouseMode.resolve(mouseAny: nil, sessionName: "mp-win-3f2a"), .local)
        XCTAssertEqual(TerminalMouseMode.resolve(mouseAny: nil, sessionName: "mp-cc"), .forwarding)
        XCTAssertEqual(TerminalMouseMode.resolve(mouseAny: nil, sessionName: "mp-cc-夜聊"), .forwarding)
    }

    // MARK: - A4 terminal_state 帧解析

    /// hub 对全局窗口发短 code、对对话 session 发完整 session 名 —— 两条轴归一
    func testStateFrameNormalizesWindowAndSessionCodes() {
        XCTAssertEqual(TerminalStateEntry.normalize("3f2a"), .window(code: "3f2a"))
        XCTAssertEqual(TerminalStateEntry.normalize("mp-win-3f2a"), .window(code: "3f2a"))
        XCTAssertEqual(TerminalStateEntry.normalize("mp-cc"), .session(name: "mp-cc"))
        XCTAssertEqual(TerminalStateEntry.normalize("mp-cc-3f2a"), .session(name: "mp-cc-3f2a"))
        XCTAssertNil(TerminalStateEntry.normalize(""))
        XCTAssertNil(TerminalStateEntry.normalize("mp-win-"))
    }

    func testStateFrameParsesAllFields() {
        let entry = TerminalStateEntry(frame: [
            "code": "3f2a", "title": "susu@nas", "engine": "shell",
            "phase": "waiting", "alive": true,
        ])
        XCTAssertEqual(entry?.target, .window(code: "3f2a"))
        XCTAssertEqual(entry?.title, "susu@nas")
        XCTAssertEqual(entry?.engine, "shell")
        XCTAssertEqual(entry?.phase, "waiting")
        XCTAssertEqual(entry?.alive, true)
    }

    /// 缺字段不该整条丢：帧里出现就是活的，其余留 nil 交给兜底链
    func testStateFrameToleratesMissingFields() {
        let entry = TerminalStateEntry(frame: ["code": "3f2a"])
        XCTAssertEqual(entry?.target, .window(code: "3f2a"))
        XCTAssertNil(entry?.title)
        XCTAssertNil(entry?.phase)
        XCTAssertEqual(entry?.alive, true)
        XCTAssertNil(TerminalStateEntry(frame: ["title": "没有 code"]))
    }

    /// 本地缓存是老版本写的（没有 title/engine/phase 三个新字段）也必须能解出来 ——
    /// 解不出来整份缓存作废，离线时导航条会空掉
    func testWindowCacheDecodesWithoutNewFields() throws {
        let json = """
        [{"code":"3f2a","createdAt":"2026-08-31T10:00:00Z","alive":true},
         {"code":"c1d4","createdAt":"2026-08-31T10:02:00Z","alive":true,"closedAt":"2026-08-31T10:05:00Z"}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([TerminalWindowInfo].self, from: json)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertFalse(decoded[0].isClosed)
        XCTAssertTrue(decoded[1].isClosed)
        XCTAssertNil(decoded[0].title)
    }

    // MARK: - A4 标题兜底链

    /// hub 算好的 title 是单一真相源，压过一切
    func testTitleChainPrefersFrameTitle() {
        XCTAssertEqual(
            TerminalTitle.resolve(title: "夜聊", engine: "codex", code: "3f2a"),
            "夜聊"
        )
        // 全空白的 title 等于没有
        XCTAssertEqual(
            TerminalTitle.resolve(title: "   ", engine: "codex", code: "3f2a"),
            "codex"
        )
    }

    /// 不显示对话名（粟粟 08-31：对话和终端窗不是同一个东西）——引擎名就是兜底身份
    func testTitleChainFallsBackByEngine() {
        XCTAssertEqual(TerminalTitle.resolve(title: nil, engine: "claude", code: "mp-cc-3f2a"), "claude")
        XCTAssertEqual(TerminalTitle.resolve(title: nil, engine: "codex", code: "3f2a"), "codex")
        // engine nil 不猜（全局窗口老 hub 下恒 nil，多半 shell）→ code 后四位；
        // 对话终端的引擎兜底由调用方传 engine（TerminalEngine.forAgentSession）
        XCTAssertEqual(TerminalTitle.resolve(title: nil, engine: nil, code: "ab3f2a"), "3f2a")
        XCTAssertEqual(TerminalTitle.resolve(title: nil, engine: "shell", code: "ab3f2a"), "3f2a")
    }

    // MARK: - A4 帧落到 store

    /// 全量替换 windows；已知窗口沿用本地 createdAt（顺序不跳）；对话 session 走旁路不进横滚条
    @MainActor
    func testApplyStateReplacesWindowsAndRoutesSessions() {
        let store = TerminalWindowStore.shared
        store.applyState([
            TerminalStateEntry(target: .window(code: "aaaa"), title: "一号", phase: "working"),
            TerminalStateEntry(target: .window(code: "bbbb"), phase: "idle"),
            TerminalStateEntry(target: .session(name: "mp-cc"), title: "夜聊", engine: "claude", phase: "waiting"),
        ])
        XCTAssertEqual(store.windows.map(\.code), ["aaaa", "bbbb"])
        XCTAssertEqual(store.windows.first?.title, "一号")
        XCTAssertEqual(store.windows.first?.phase, "working")
        XCTAssertEqual(store.sessionStates["mp-cc"]?.phase, "waiting")
        XCTAssertFalse(store.isStale)
        let createdAt = store.windows.first?.createdAt

        // 第二帧：aaaa 还在（createdAt 不变）、bbbb 没了、cccc 新增
        store.applyState([
            TerminalStateEntry(target: .window(code: "aaaa"), title: "一号改", phase: "done"),
            TerminalStateEntry(target: .window(code: "cccc")),
        ])
        XCTAssertEqual(store.windows.map(\.code), ["aaaa", "cccc"])
        XCTAssertEqual(store.windows.first?.createdAt, createdAt)
        XCTAssertEqual(store.windows.first?.title, "一号改")
        XCTAssertTrue(store.sessionStates.isEmpty)

        store.applyState([])
    }

    func testTitleTruncation() {
        XCTAssertEqual(TerminalTitle.truncate("susu@nas"), "susu@nas")          // 正好 8，不截
        XCTAssertEqual(TerminalTitle.truncate("susu@nas-2"), "susu@nas…")
        XCTAssertEqual(TerminalTitle.truncate("小克夜聊记录本"), "小克夜聊记录本")
    }
}
