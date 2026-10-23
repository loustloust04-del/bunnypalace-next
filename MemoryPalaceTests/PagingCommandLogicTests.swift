import XCTest
@testable import 记忆花园

/// 翻页命令通道语义（plan-paging-decouple §3.2 / §7 B-core 单测）：同页短路、代际、注册前暂存
final class PagingCommandLogicTests: XCTestCase {
    func testGestureWritebackIsShortCircuited() {
        // 手势落定：分页壳先把 currentPage 设成新页，再回写 iOSPage → 命令目标 == currentPage
        var logic = PagingCommandLogic()
        XCTAssertEqual(logic.receive(target: 0, currentPage: 0), .alreadyThere)
        XCTAssertNil(logic.inFlight)
    }

    func testProgrammaticWriteRuns() {
        var logic = PagingCommandLogic()
        guard case .run(let gen) = logic.receive(target: 1, currentPage: 0) else { return XCTFail("应当真的翻") }
        XCTAssertTrue(logic.isCurrent(gen))
        XCTAssertEqual(logic.inFlight, 1)
        logic.started(gen)
        XCTAssertNil(logic.inFlight)
    }

    func testNewerCommandSupersedesOlder() {
        var logic = PagingCommandLogic()
        guard case .run(let first) = logic.receive(target: 1, currentPage: 0) else { return XCTFail() }
        guard case .run(let second) = logic.receive(target: 2, currentPage: 0) else { return XCTFail() }
        XCTAssertFalse(logic.isCurrent(first), "旧命令的完成回调作废")
        XCTAssertTrue(logic.isCurrent(second))
        XCTAssertEqual(logic.inFlight, 2)
        // 旧命令迟到的 started 不能清掉新命令的在途标记
        logic.started(first)
        XCTAssertEqual(logic.inFlight, 2)
    }

    func testWritebackCancelsWaitingCommand() {
        // 命令在等内容就绪时，用户手势翻回了当前页：回写推进代际，在等的命令放弃
        var logic = PagingCommandLogic()
        guard case .run(let waiting) = logic.receive(target: 1, currentPage: 0) else { return XCTFail() }
        XCTAssertEqual(logic.receive(target: 0, currentPage: 0), .alreadyThere)
        XCTAssertFalse(logic.isCurrent(waiting))
        XCTAssertNil(logic.inFlight)
    }

    func testCommandsBeforeRegistrationKeepOnlyLatest() {
        var logic = PagingCommandLogic()
        XCTAssertEqual(logic.receive(target: 2, currentPage: nil), .stored)
        XCTAssertEqual(logic.receive(target: 0, currentPage: nil), .stored)
        XCTAssertEqual(logic.takePending(), 0)
        XCTAssertNil(logic.takePending(), "只执行一次")
    }

    func testRegisteredCommandClearsStalePending() {
        var logic = PagingCommandLogic()
        _ = logic.receive(target: 2, currentPage: nil)
        _ = logic.receive(target: 1, currentPage: 0)
        XCTAssertNil(logic.takePending(), "注册后的命令已经覆盖了注册前的目标")
    }

    func testInvalidateDropsInFlight() {
        // 楼层切换 / dismantle：旧注册上的在途命令作废
        var logic = PagingCommandLogic()
        guard case .run(let gen) = logic.receive(target: 2, currentPage: 1) else { return XCTFail() }
        logic.invalidate()
        XCTAssertFalse(logic.isCurrent(gen))
        XCTAssertNil(logic.inFlight)
    }
}
