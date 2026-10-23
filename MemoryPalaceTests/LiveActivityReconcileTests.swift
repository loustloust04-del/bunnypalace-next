import Foundation
import XCTest
@testable import 记忆花园

// M4b2 ③：冷启动对账的三分支。app 被杀是正常工作模式 → 本地有岛 ≠ 那一轮还在跑，
// 也 ≠ 那一轮已经死了。只有 hub 明确说不认识才 end。
final class LiveActivityReconcileTests: XCTestCase {
    private let working = CCLiveActivityAlive(phase: "working", runId: "r-1", sessionName: "mp-cc")

    func testHubKnowsIt_reattach() {
        let actions = reconcileLiveActivities(
            liveIds: ["A"], alive: ["A": working], answered: ["A"]
        )
        XCTAssertEqual(actions, [.reattach(activityId: "A")])
    }

    func testHubSaysNull_end() {
        let actions = reconcileLiveActivities(
            liveIds: ["A"], alive: [:], answered: ["A"]
        )
        XCTAssertEqual(actions, [.end(activityId: "A")])
    }

    /// hub 压根没回这一格（帧里少了 / 超时前只回了一部分）→ 不动，不猜。
    func testHubSilentAboutIt_noAction() {
        let actions = reconcileLiveActivities(
            liveIds: ["A"], alive: [:], answered: []
        )
        XCTAssertEqual(actions, [])
    }

    /// 一次问多个：各判各的，互不影响。
    func testMixed() {
        let actions = reconcileLiveActivities(
            liveIds: ["A", "B", "C"],
            alive: ["A": working],
            answered: ["A", "B"]
        )
        XCTAssertEqual(actions, [.reattach(activityId: "A"), .end(activityId: "B")])
    }

    // ── T13 · 陌生岛宽限（远程 start 起的岛 token 接续）──

    /// 本地注册表里没有 token 记录的岛**不进 query 集**：hub 判活只看它自己的 update token
    /// 记录，这时候问必得 null → 判死 → cancel 掉正在等 token 的监听 → token 永远上不了岸。
    func testStrangerActivityIsNotQueried() {
        XCTAssertEqual(
            liveActivityIdsToQuery(liveIds: ["KNOWN", "STRANGER"], registeredIds: ["KNOWN"]),
            ["KNOWN"]
        )
    }

    /// token 报上去之后下一轮 recheck 它就是「已知的」，自然纳入对账（宽限只推迟一轮，不是永久豁免）。
    func testStrangerJoinsQueryOnceTokenRegistered() {
        XCTAssertEqual(
            liveActivityIdsToQuery(liveIds: ["KNOWN", "STRANGER"], registeredIds: ["KNOWN", "STRANGER"]),
            ["KNOWN", "STRANGER"]
        )
    }

    /// phase 任意都算活（idle/done 也是 hub 认识的一轮）——判活的条件在 hub 侧，app 不二次解读。
    func testAnyPhaseCountsAsAlive() {
        let done = CCLiveActivityAlive(phase: "done", runId: nil, sessionName: "mp-cc")
        XCTAssertEqual(
            reconcileLiveActivities(liveIds: ["A"], alive: ["A": done], answered: ["A"]),
            [.reattach(activityId: "A")]
        )
    }
}
