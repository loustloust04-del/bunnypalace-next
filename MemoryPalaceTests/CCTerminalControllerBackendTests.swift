import XCTest
@testable import 记忆花园

/// #045 T2：controller 抽出 `TerminalBackend` 后，attach 状态机 / 去抖 / 离线提示的行为不变（plan-terminal-t2 §4）。
@MainActor
final class CCTerminalControllerBackendTests: XCTestCase {

    final class FakeBackend: TerminalBackend {
        var isReachable = true
        var emulatorOwnsModes = false
        var attaches: [(cols: Int, rows: Int)] = []
        var resizes: [(cols: Int, rows: Int)] = []
        var detaches = 0
        var sent: [Data] = []
        var pastes: [(String, Bool)] = []
        var refreshes = 0
        var reconnectPreps = 0
        var pendingOnSent: ((Bool) -> Void)?
        var events: TerminalBackendEvents?

        func attach(cols: Int, rows: Int, openedAt: Date?, events: TerminalBackendEvents, onSent: @escaping (Bool) -> Void) {
            attaches.append((cols, rows))
            self.events = events
            pendingOnSent = onSent
        }
        func resize(cols: Int, rows: Int) { resizes.append((cols, rows)) }
        func detach() { detaches += 1 }
        func send(_ bytes: Data, completion: @escaping (Error?) -> Void) { sent.append(bytes); completion(nil) }
        func paste(_ text: String, bracketed: Bool, completion: @escaping (TerminalPasteOutcome) -> Void) {
            pastes.append((text, bracketed))
            completion(.delivered)
        }
        func refresh() { refreshes += 1 }
        func prepareReconnect() { reconnectPreps += 1 }
    }

    private func make(_ backend: FakeBackend) -> CCTerminalController {
        CCTerminalController(sessionName: "ish-1", backend: backend)
    }

    private func wait(_ seconds: TimeInterval) {
        let e = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 1)
    }

    func testFirstSizeAttachesOnceThenResizesAfterSent() {
        let backend = FakeBackend()
        let c = make(backend)
        c.attachOrResize(cols: 50, rows: 20)
        // attach 在途：新尺寸只记下来，不重复 attach、也不 resize
        c.attachOrResize(cols: 60, rows: 22)
        XCTAssertEqual(backend.attaches.count, 1)
        XCTAssertEqual(backend.attaches[0].cols, 50)
        XCTAssertTrue(backend.resizes.isEmpty)
        backend.pendingOnSent?(true)
        XCTAssertEqual(backend.resizes.count, 1)
        XCTAssertEqual(backend.resizes[0].cols, 60)
        XCTAssertEqual(backend.resizes[0].rows, 22)
    }

    func testResizeAfterAttachIsDebouncedToLast() {
        let backend = FakeBackend()
        let c = make(backend)
        c.attachOrResize(cols: 50, rows: 20)
        backend.pendingOnSent?(true)
        c.attachOrResize(cols: 51, rows: 20)
        c.attachOrResize(cols: 52, rows: 20)
        c.attachOrResize(cols: 53, rows: 21)
        XCTAssertTrue(backend.resizes.isEmpty)
        wait(0.3)
        XCTAssertEqual(backend.resizes.count, 1)
        XCTAssertEqual(backend.resizes[0].cols, 53)
        XCTAssertEqual(backend.resizes[0].rows, 21)
    }

    func testNotSentLeavesRoomForRetry() {
        let backend = FakeBackend()
        let c = make(backend)
        c.attachIfNotYet(cols: 80, rows: 24)
        backend.pendingOnSent?(false)
        // 没交出去 → 不锁，下一次兜底还能再 attach
        c.attachIfNotYet(cols: 80, rows: 24)
        XCTAssertEqual(backend.attaches.count, 2)
    }

    func testInitSnapshotMarksAttachedAndClearsError() {
        let backend = FakeBackend()
        let c = make(backend)
        c.attachIfNotYet(cols: 80, rows: 24)
        c.error = "boom"
        backend.events?.onInit(Data("hi".utf8), true)
        XCTAssertTrue(c.hasShownSnapshot)
        XCTAssertNil(c.error)
        XCTAssertEqual(c.mouseAny, true)
        // 快照到了就算 attach 活了：尺寸变化走 resize 而不是再 attach
        c.attachOrResize(cols: 90, rows: 30)
        XCTAssertEqual(backend.attaches.count, 1)
    }

    func testUnreachableShowsHintAndSendsNothing() {
        let backend = FakeBackend()
        backend.isReachable = false
        let c = make(backend)
        c.sendInput(Data("ls\r".utf8))
        XCTAssertTrue(backend.sent.isEmpty)
        XCTAssertTrue(c.showsOfflineInputHint)
    }

    func testReachableSendsAndClearsStaleError() {
        let backend = FakeBackend()
        let c = make(backend)
        c.error = "没发出去"
        c.sendInput(Data("a".utf8))
        XCTAssertEqual(backend.sent, [Data("a".utf8)])
        XCTAssertNil(c.error)
    }

    func testDetachResetsSoReattachWorks() {
        let backend = FakeBackend()
        let c = make(backend)
        c.attachIfNotYet(cols: 80, rows: 24)
        backend.pendingOnSent?(true)
        c.detach()
        XCTAssertEqual(backend.detaches, 1)
        c.attachIfNotYet(cols: 80, rows: 24)
        XCTAssertEqual(backend.attaches.count, 2)
    }

    func testReconnectDetachesPreparesThenAttachesWithLastSize() {
        let backend = FakeBackend()
        let c = make(backend)
        c.attachOrResize(cols: 70, rows: 25)
        backend.pendingOnSent?(true)
        c.reconnect()
        XCTAssertEqual(backend.detaches, 1)
        XCTAssertEqual(backend.reconnectPreps, 1)
        XCTAssertEqual(backend.attaches.count, 2)
        XCTAssertEqual(backend.attaches[1].cols, 70)
        XCTAssertEqual(backend.attaches[1].rows, 25)
    }

    func testPasteForwardsAndRefreshForwards() {
        let backend = FakeBackend()
        let c = make(backend)
        var outcome: TerminalPasteOutcome?
        c.paste("a\nb") { outcome = $0 }
        XCTAssertEqual(backend.pastes.count, 1)
        XCTAssertEqual(backend.pastes[0].0, "a\nb")
        XCTAssertFalse(backend.pastes[0].1)
        if case .delivered = outcome {} else { XCTFail("应透传 backend 的结果") }
        c.refresh()
        XCTAssertEqual(backend.refreshes, 1)
    }

    func testMouseModeSource() {
        let hubLike = FakeBackend()
        let c1 = make(hubLike)
        c1.mouseAny = true
        XCTAssertEqual(c1.mouseMode, .forwarding)

        let local = FakeBackend()
        local.emulatorOwnsModes = true
        let c2 = make(local)
        c2.mouseAny = true   // 本地模拟器说了算，hub 字段不看
        XCTAssertEqual(c2.mouseMode, .local)
    }

    func testDefaultBackendIsHub() {
        let c = CCTerminalController(sessionName: "mp-cc")
        XCTAssertTrue(c.backend is HubTerminalBackend)
    }

    func testHubPasteRoute() {
        XCTAssertEqual(HubTerminalBackend.pasteRoute(hubSupportsPaste: nil, bracketed: true), .hubPaste)
        XCTAssertEqual(HubTerminalBackend.pasteRoute(hubSupportsPaste: true, bracketed: false), .hubPaste)
        XCTAssertEqual(HubTerminalBackend.pasteRoute(hubSupportsPaste: false, bracketed: true), .rawInput(wrap: true))
        XCTAssertEqual(HubTerminalBackend.pasteRoute(hubSupportsPaste: false, bracketed: false), .rawInput(wrap: false))
    }
}
