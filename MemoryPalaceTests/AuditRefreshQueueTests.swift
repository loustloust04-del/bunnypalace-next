import XCTest
@testable import 记忆花园

/// 审计台现场数字的刷新排队（astra P2）：重叠的合成一次、旧票不回写、切楼层 / 取消作废
@MainActor
final class AuditRefreshQueueTests: XCTestCase {

    /// 可控的一次「读盘」：跑起来先挂住，测试决定什么时候回来
    private final class Probe {
        var gates: [CheckedContinuation<Void, Never>] = []
        var runs = 0
        var written: [Int] = []
    }

    private func work(_ q: AuditRefreshQueue, _ probe: Probe) -> AuditRefreshQueue.Work {
        { ticket in
            probe.runs += 1
            let run = probe.runs
            await withCheckedContinuation { probe.gates.append($0) }
            if q.isCurrent(ticket) { probe.written.append(run) }
        }
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    /// `.task` / 记忆变动 / C3 跑完三路同时要：只跑两次（一份在跑 + 合成一份排后面），跑着那份的旧结果不回写
    func testOverlappingRequestsCoalesceAndStaleResultIsDropped() async {
        let q = AuditRefreshQueue(), probe = Probe()
        q.request(work(q, probe))
        await settle { probe.gates.count == 1 }
        q.request(work(q, probe))
        q.request(work(q, probe))
        probe.gates[0].resume()
        await settle { probe.gates.count == 2 }
        XCTAssertEqual(probe.runs, 2, "跑着时再要的两次合成一次")
        probe.gates[1].resume()
        await settle { q.isIdle }
        XCTAssertTrue(q.isIdle)
        XCTAssertEqual(probe.written, [2], "第一次读的是改之前的数，后面还有人要刷新：扔掉，不盖新数")
    }

    /// 没人插队：一次请求跑一次、照常回写
    func testSingleRequestWrites() async {
        let q = AuditRefreshQueue(), probe = Probe()
        q.request(work(q, probe))
        await settle { probe.gates.count == 1 }
        probe.gates[0].resume()
        await settle { q.isIdle }
        XCTAssertEqual(probe.written, [1])
    }

    /// 切楼层：飞着的那张作废
    func testInvalidateDropsInFlight() async {
        let q = AuditRefreshQueue(), probe = Probe()
        q.request(work(q, probe))
        await settle { probe.gates.count == 1 }
        q.invalidate()
        probe.gates[0].resume()
        await settle { q.isIdle }
        XCTAssertEqual(probe.runs, 1)
        XCTAssertTrue(probe.written.isEmpty, "切了楼层的旧读取不回写")
    }

    /// 页面走了：取消，飞着的作废、排着的不跑；之后再要照常跑
    func testCancelDropsInFlightAndPending() async {
        let q = AuditRefreshQueue(), probe = Probe()
        q.request(work(q, probe))
        await settle { probe.gates.count == 1 }
        q.request(work(q, probe))
        q.cancel()
        XCTAssertTrue(q.isIdle)
        probe.gates[0].resume()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(probe.runs, 1, "排着的那份不跑")
        XCTAssertTrue(probe.written.isEmpty)

        q.request(work(q, probe))
        await settle { probe.gates.count == 2 }
        probe.gates[1].resume()
        await settle { q.isIdle }
        XCTAssertEqual(probe.written, [2], "回到页面再要：照常跑、回写")
    }
}
