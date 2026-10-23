import XCTest
@testable import 记忆花园

/// page1 卡片遗留（TASK page1-卡片-03 / 04 / 05，粟粟 10-02：都修）
@MainActor
final class CardLeftoverTests: XCTestCase {

    // MARK: - 03 音乐卡

    final class Engine: MusicEngine {
        var onTime: ((Int, Double, Double) -> Void)?
        var onEnd: ((Int) -> Void)?
        var onFail: ((Int) -> Void)?
        var onState: ((Int, MusicEngineState) -> Void)?
        var generation = 0
        var seeks: [Double] = []
        func load(_ url: URL) -> Int { generation += 1; return generation }
        func play() {}
        func pause() {}
        func seek(to seconds: Double) { seeks.append(seconds) }
        func stop() {}
        func setVolume(_ v: Float) {}
        func currentLevel() -> Float? { nil }
    }

    private static let song = URL(string: "https://x.com/a.mp3")!

    private func playing(_ engine: Engine, now: @escaping () -> Date = Date.init) -> MusicCardPlayer {
        let player = MusicCardPlayer(engine: engine, isOffline: { false }, willPlay: {}, now: now)
        player.toggle(key: "A", url: Self.song)
        engine.onTime?(1, 0, 200)
        XCTAssertEqual(player.phase(for: "A"), .playing)
        return player
    }

    /// 来电：系统把播放器停了，按钮要变回「暂停」
    func testExternalPauseShowsPaused() {
        let engine = Engine()
        let player = playing(engine)
        engine.onState?(1, .paused)
        XCTAssertEqual(player.phase(for: "A"), .paused)
    }

    /// 断网：在等数据就显示加载中，恢复了回到在放
    func testStallShowsLoadingThenRecovers() {
        let engine = Engine()
        let player = playing(engine)
        engine.onState?(1, .waiting)
        XCTAssertEqual(player.phase(for: "A"), .loading)
        engine.onState?(1, .playing)
        XCTAssertEqual(player.phase(for: "A"), .playing)
    }

    /// 自己点的暂停不被引擎的「在等」翻回加载中；旧代号的状态不认
    func testOwnPauseAndStaleStatesIgnored() {
        let engine = Engine()
        let player = playing(engine)
        player.toggle(key: "A", url: Self.song)
        XCTAssertEqual(player.phase(for: "A"), .paused)
        engine.onState?(1, .waiting)
        engine.onState?(1, .playing)
        XCTAssertEqual(player.phase(for: "A"), .paused)
        player.toggle(key: "A", url: Self.song)
        engine.onState?(0, .paused)
        XCTAssertEqual(player.phase(for: "A"), .playing, "旧代号")
    }

    /// 直播流没有总时长：进度在走就算在放，不卡在加载中
    func testLiveStreamWithoutDurationPlays() {
        let engine = Engine()
        let player = MusicCardPlayer(engine: engine, isOffline: { false }, willPlay: {})
        player.toggle(key: "A", url: Self.song)
        engine.onTime?(1, 0, .nan)
        XCTAssertEqual(player.phase(for: "A"), .loading)
        engine.onTime?(1, 0.5, .nan)
        XCTAssertEqual(player.phase(for: "A"), .playing)
        XCTAssertEqual(player.duration, 0)
    }

    /// 拖完后播放器还会报几次拖动前的位置：不跟着跳回去
    func testSeekIgnoresStaleTicks() {
        let engine = Engine()
        var clock = Date(timeIntervalSince1970: 1000)
        let player = playing(engine, now: { clock })
        engine.onTime?(1, 10, 200)
        player.seek(fraction: 0.5)
        XCTAssertEqual(player.current, 100)
        engine.onTime?(1, 10.25, 200)
        XCTAssertEqual(player.current, 100, "旧位置不认")
        engine.onTime?(1, 100.3, 200)
        XCTAssertEqual(player.current, 100.3, "到了新位置就接着走")
        engine.onTime?(1, 100.6, 200)
        XCTAssertEqual(player.current, 100.6)
    }

    func testSeekGuardExpires() {
        let engine = Engine()
        var clock = Date(timeIntervalSince1970: 1000)
        let player = playing(engine, now: { clock })
        player.seek(fraction: 0.5)
        clock = clock.addingTimeInterval(4)
        engine.onTime?(1, 20, 200)
        XCTAssertEqual(player.current, 20, "跳转一直没落地：过一会儿就信播放器")
    }

    // MARK: - 04 计时器

    /// 授权回调回来前已经暂停 / 重置：这次预约作废，不再设提醒
    func testNotificationGateDropsCancelledSchedules() {
        let gate = TimerNotificationGate()
        let first = gate.begin("c-1")
        XCTAssertTrue(gate.isCurrent("c-1", first))
        gate.invalidate("c-1")
        XCTAssertFalse(gate.isCurrent("c-1", first))
        let second = gate.begin("c-1")
        XCTAssertFalse(gate.isCurrent("c-1", first), "旧的那次回调来晚了也不认")
        XCTAssertTrue(gate.isCurrent("c-1", second))
        XCTAssertFalse(gate.isCurrent("c-2", second))
    }

    func testTimerZeroHint() {
        XCTAssertEqual(TimerCard.composerHint(hours: 0, minutes: 0, seconds: 0), "至少 1 秒")
        XCTAssertNil(TimerCard.composerHint(hours: 0, minutes: 0, seconds: 1))
        XCTAssertNil(TimerCard.composerHint(hours: 23, minutes: 59, seconds: 59))
    }

    // MARK: - 05 外链

    func testUnusualPrivateAddressesBlocked() {
        for raw in ["http://127.1/", "http://2130706433/", "http://0x7f000001/", "http://0177.0.0.1/", "http://10.1/",
                    "http://[::ffff:127.0.0.1]/", "http://[::ffff:c0a8:0101]/", "http://router/", "http://nas.lan/",
                    "http://svc.internal/", "http://box.home.arpa/", "http://localhost./", "http://224.0.0.1/",
                    "http://[fe80::1]/", "http://0.0.0.0/"] {
            XCTAssertFalse(LinkPreviewStore.isPublicTarget(URL(string: raw)!), raw)
        }
        for raw in ["https://example.com/", "https://8.8.8.8/", "https://[2606:4700::1111]/", "https://news.ycombinator.com/"] {
            XCTAssertTrue(LinkPreviewStore.isPublicTarget(URL(string: raw)!), raw)
        }
    }

    /// 气泡模式：已经写完的网页块不用等整条消息结束（图表 / 音乐仍按原设计等）
    func testFinishedHTMLBlockDetection() {
        XCTAssertTrue(ChatCardRegistry.isFinishedHTMLBlock("```html\n<p>hi</p>\n```"))
        XCTAssertFalse(ChatCardRegistry.isFinishedHTMLBlock("```html\n<p>hi</p>"), "没写完")
        XCTAssertFalse(ChatCardRegistry.isFinishedHTMLBlock("```card-chart\n{}\n```"))
        XCTAssertFalse(ChatCardRegistry.isFinishedHTMLBlock("普通一段话"))
    }

    final class Fetcher: LinkMetadataFetching {
        var calls: [String] = []
        var gates: [CheckedContinuation<Void, Never>] = []
        func fetch(_ url: URL) async -> LinkPreviewFetchResult? {
            calls.append(url.host ?? "")
            await withCheckedContinuation { gates.append($0) }
            return LinkPreviewFetchResult(title: url.host, imageData: nil, iconData: nil)
        }
        func releaseOne() { if !gates.isEmpty { gates.removeFirst().resume() } }
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    /// 快速滑过一串链接：排队的里面后来的先抓（屏幕上那张），滑走了的不抓
    func testQueuedFetchesNewestFirstAndDropAbandoned() async {
        let fetcher = Fetcher()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lp-\(UUID().uuidString)")
        let store = LinkPreviewStore(directory: dir, fetcher: fetcher, isOffline: { false }, now: Date.init, maxConcurrent: 1)
        let a = Task { await store.preview(for: URL(string: "https://a.example.com")!) }
        await settle()
        let b = Task { await store.preview(for: URL(string: "https://b.example.com")!) }
        let c = Task { await store.preview(for: URL(string: "https://c.example.com")!) }
        let d = Task { await store.preview(for: URL(string: "https://d.example.com")!) }
        await settle()
        c.cancel()                                                // c 滑出屏幕
        await settle()
        XCTAssertEqual(fetcher.calls, ["a.example.com"])
        fetcher.releaseOne(); await settle()
        XCTAssertEqual(fetcher.calls, ["a.example.com", "d.example.com"], "后来的先抓")
        fetcher.releaseOne(); await settle()
        fetcher.releaseOne(); await settle()
        XCTAssertEqual(fetcher.calls, ["a.example.com", "d.example.com", "b.example.com"], "c 没人要了，不抓")
        _ = await (a.value, b.value, d.value)
        let cResult = await c.value
        XCTAssertNil(cResult.title)
        XCTAssertNil(store.cached(URL(string: "https://c.example.com")!), "没抓的不记失败，回来还能再抓")
    }
}
