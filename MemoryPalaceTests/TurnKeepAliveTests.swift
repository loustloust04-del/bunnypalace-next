import XCTest
@testable import 记忆花园

@MainActor
final class TurnKeepAliveTests: XCTestCase {
    private final class FakeSystem: TurnKeepAliveSystem {
        var isForeground = true
        var submitError: Error?
        var submits = 0
        var cancels = 0
        func submit() throws {
            if let submitError { throw submitError }
            submits += 1
        }
        func cancelPending() { cancels += 1 }
    }

    private final class FakeTask: TurnKeepAliveTask {
        var updates: [(String, Int)] = []
        var finished: Bool?
        func update(subtitle: String, tick: Int) { updates.append((subtitle, tick)) }
        func finish(success: Bool) { finished = success }
    }

    private struct Boom: Error {}

    private func make(enabled: Bool = true) -> (TurnKeepAliveCore, FakeSystem) {
        let system = FakeSystem()
        return (TurnKeepAliveCore(system: system, isEnabled: { enabled }), system)
    }

    func testOffDoesNothing() {
        let (core, system) = make(enabled: false)
        core.turnBegan(onExpire: {})
        XCTAssertEqual(core.state, .idle)
        XCTAssertEqual(system.submits, 0)
    }

    func testBackgroundStartDoesNotSubmit() {
        let (core, system) = make()
        system.isForeground = false
        core.turnBegan(onExpire: {})
        XCTAssertEqual(core.state, .idle)
        XCTAssertEqual(system.submits, 0)
    }

    func testSubmitFailureLeavesTurnAlone() {
        let (core, system) = make()
        system.submitError = Boom()
        var expired = false
        core.turnBegan(onExpire: { expired = true })
        XCTAssertEqual(core.state, .idle)
        core.turnEnded()
        XCTAssertEqual(system.cancels, 0)
        XCTAssertFalse(expired)
    }

    func testNormalTurnFinishesTaskWithSuccess() {
        let (core, system) = make()
        let task = FakeTask()
        core.turnBegan(onExpire: {})
        XCTAssertEqual(core.state, .requested)
        core.systemStarted(task)
        XCTAssertEqual(core.state, .running)
        core.tick()
        XCTAssertEqual(task.updates.map(\.1), [1, 2])
        core.turnEnded()
        XCTAssertEqual(task.finished, true)
        XCTAssertEqual(core.state, .idle)
        XCTAssertEqual(system.cancels, 0)
    }

    func testTurnEndsBeforeSystemStartsCancelsRequest() {
        let (core, system) = make()
        core.turnBegan(onExpire: {})
        core.turnEnded()
        XCTAssertEqual(system.cancels, 1)
        let late = FakeTask()
        core.systemStarted(late)
        XCTAssertEqual(late.finished, true)
        XCTAssertEqual(core.state, .idle)
    }

    func testExpiryStopsTheTurnOnce() {
        let (core, _) = make()
        let task = FakeTask()
        var expired = 0
        core.turnBegan(onExpire: { expired += 1 })
        core.systemStarted(task)
        core.systemExpired()
        XCTAssertEqual(task.finished, false)
        XCTAssertEqual(expired, 1)
        XCTAssertEqual(core.state, .idle)
        core.systemExpired()
        core.turnEnded()
        XCTAssertEqual(expired, 1)
    }

    func testSecondTurnWhileRunningDoesNotResubmit() {
        let (core, system) = make()
        core.turnBegan(onExpire: {})
        core.systemStarted(FakeTask())
        core.turnBegan(onExpire: {})
        XCTAssertEqual(system.submits, 1)
    }

    func testTicksIgnoredWhenNotRunning() {
        let (core, _) = make()
        core.tick()
        XCTAssertEqual(core.ticks, 0)
    }
}
