import Combine
import Observation
import XCTest
@testable import 记忆花园

/// plan-hub-perf K1 第 4b 步：hub 推的 send_status 解析 + 重发帧 + 重发原帧缓存
final class CCSendStatusTests: XCTestCase {
    private func frame(_ status: Any?, reason: Any? = nil, messageId: Any? = "m1") -> [String: Any] {
        var f: [String: Any] = ["type": "send_status", "chat_id": "c1", "session_name": "mp-cc-abc"]
        if let messageId { f["message_id"] = messageId }
        if let status { f["status"] = status }
        if let reason { f["reason"] = reason }
        return f
    }

    func testParsesAllThreeStates() {
        for state in [CCSendStatus.State.uncertain, .delivered, .failed] {
            let s = CCSendStatus(frame: frame(state.rawValue))
            XCTAssertEqual(s, CCSendStatus(chatId: "c1", messageId: "m1", sessionName: "mp-cc-abc", state: state, reason: nil))
        }
    }

    func testFailedCarriesReason() {
        let s = CCSendStatus(frame: frame("failed", reason: "重发也没进输入框"))
        XCTAssertEqual(s?.state, .failed)
        XCTAssertEqual(s?.reason, "重发也没进输入框")
        XCTAssertEqual(s?.displayReason, "重发也没进输入框")
    }

    func testEnglishReasonStaysOffBubble() {
        let s = CCSendStatus(frame: frame("failed", reason: "tmux control timeout"))
        XCTAssertEqual(s?.reason, "tmux control timeout")
        XCTAssertNil(s?.displayReason, "tmux 原文不上气泡")
        XCTAssertNil(CCSendStatus(frame: frame("failed", reason: ""))?.reason, "空串当没有")
    }

    func testMissingOrUnknownFieldsIgnored() {
        XCTAssertNil(CCSendStatus(frame: frame(nil)), "缺 status")
        XCTAssertNil(CCSendStatus(frame: frame("uncertain", messageId: nil)), "缺 message_id")
        XCTAssertNil(CCSendStatus(frame: frame("uncertain", messageId: "")), "空 message_id")
        XCTAssertNil(CCSendStatus(frame: frame("lost")), "不认识的 status")
        XCTAssertNil(CCSendStatus(frame: frame(1)), "status 类型不对")
        // chat_id / session_name 缺了不影响按 message_id 标记
        let bare = CCSendStatus(frame: ["type": "send_status", "message_id": "m9", "status": "uncertain"])
        XCTAssertEqual(bare?.messageId, "m9")
        XCTAssertEqual(bare?.chatId, "")
    }

    func testRetryFrameIsSendFramePlusRetry() {
        let original = CCBridgeWebSocketClient.sendFrame(chatId: "c1", messageId: "m1", content: "hi", user: "u",
                                                         session: "mp-cc-abc", replyTo: "r0", attachments: [], effort: "high")
        XCTAssertNil(original["retry"], "首发不带 retry")
        let retry = CCBridgeWebSocketClient.retryFrame(from: original)
        XCTAssertEqual(retry["retry"] as? Bool, true)
        XCTAssertEqual(retry["type"] as? String, "send")
        XCTAssertEqual(retry["message_id"] as? String, "m1", "message_id 不变")
        var stripped = retry
        stripped.removeValue(forKey: "retry")
        XCTAssertEqual(NSDictionary(dictionary: stripped), NSDictionary(dictionary: original), "其余字段原样")
    }

    // MARK: - 订阅范围（sol P1-1）：每条一个 entry，标记只订阅自己那条

    private final class Flag: @unchecked Sendable { var fired = false }

    /// 照标记视图的读法登记订阅（state / canRetry / visibleReason 读到全部四个属性）；返回「是否收到失效通知」的探针
    private func observe(_ entry: CCSendStatusEntry) -> () -> Bool {
        let flag = Flag()
        withObservationTracking {
            _ = entry.state
            _ = entry.canRetry
            _ = entry.visibleReason
            _ = entry.retryable
            _ = entry.hasFrame
        } onChange: { flag.fired = true }
        return { flag.fired }
    }

    func testOtherEntryChangesDoNotInvalidateThisOne() {
        let store = CCSendStatusStore()
        store.set("a", state: .uncertain, reason: nil, retryable: true, hasFrame: true)
        store.set("b", state: .uncertain, reason: nil, retryable: true, hasFrame: true)
        let a = store.entry("a")!
        let aFired = observe(a)
        store.set("b", state: .failed, reason: "没进输入框", retryable: true, hasFrame: true)   // 别的消息变状态
        store.set("c", state: .uncertain, reason: nil, retryable: true, hasFrame: true)        // 新建别的消息
        store.remove("b")                                     // 删别的消息
        XCTAssertFalse(aFired(), "别的消息变化不能让 a 的标记失效")
        store.set("a", state: .failed, reason: nil, retryable: true, hasFrame: true)
        XCTAssertTrue(aFired(), "自己变了才失效")
    }

    func testTrackerTrafficOnOtherMessagesDoesNotInvalidateThisOne() {
        let t = CCSendTracker()
        t.didSend("a", frame: ["type": "send", "content": "x"])
        t.didReceive(CCSendStatus(chatId: "c", messageId: "a", sessionName: "s", state: .failed, reason: "没进输入框"))
        let aFired = observe(t.store.entry("a")!)
        for i in 0..<5 { t.didSend("n\(i)", frame: ["type": "send", "content": "x"]) }   // 正常发送
        t.didReceive(CCSendStatus(chatId: "c", messageId: "n1", sessionName: "s", state: .uncertain, reason: nil))
        t.didReceive(CCSendStatus(chatId: "c", messageId: "n1", sessionName: "s", state: .failed, reason: nil))
        t.didReceive(CCSendStatus(chatId: "c", messageId: "n2", sessionName: "s", state: .delivered, reason: nil))
        t.didReceive(CCSendStatus(chatId: "c", messageId: "a", sessionName: "s", state: .failed, reason: "没进输入框"))   // 同值重发布
        XCTAssertFalse(aFired())
    }

    func testSamePublishSkipsWrite() {
        let store = CCSendStatusStore()
        store.set("a", state: .failed, reason: "没进输入框", retryable: true, hasFrame: true)
        let fired = observe(store.entry("a")!)
        store.set("a", state: .failed, reason: "没进输入框", retryable: true, hasFrame: true)
        XCTAssertFalse(fired(), "同值重复发布不写、不失效")
    }

    func testMembershipOnlyOnCreateAndRemove() {
        let store = CCSendStatusStore()
        var events: [String] = []
        let sub = store.membership.sink { events.append($0) }
        store.set("a", state: .uncertain, reason: nil, retryable: true, hasFrame: true)   // 建
        store.set("a", state: .failed, reason: nil, retryable: true, hasFrame: true)      // 改：走 entry 自己的 Observation
        store.set("a", state: .failed, reason: nil, retryable: true, hasFrame: true)      // 同值
        store.remove("a")                                // 删
        store.remove("a")                                // 已经没了
        XCTAssertEqual(events, ["a", "a"])
        sub.cancel()
    }

    func testTrackerCreatesNoEntryForNormalSend() {
        let t = CCSendTracker()
        t.didSend("m1", frame: ["type": "send", "message_id": "m1", "content": "hi"])
        XCTAssertNil(t.store.entry("m1"), "正常发送不建对象")
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .uncertain, reason: nil))
        XCTAssertEqual(t.store.entry("m1")?.state, .uncertain)
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .delivered, reason: nil))
        XCTAssertNil(t.store.entry("m1"), "送到了就删对象")
    }

    func testTrackerRetryFlow() {
        let t = CCSendTracker()
        t.didSend("m1", frame: ["type": "send", "message_id": "m1", "content": "hi"])
        XCTAssertNil(t.beginRetry("m1"), "没 failed 不能重发")
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .failed, reason: "tmux timeout"))
        XCTAssertNil(t.store.entry("m1")?.reason, "英文原因不上气泡")
        let frame = t.beginRetry("m1")
        XCTAssertEqual(frame?["retry"] as? Bool, true)
        XCTAssertEqual(t.store.entry("m1")?.state, .uncertain)
        t.retryNotSent("m1")
        XCTAssertEqual(t.store.entry("m1")?.state, .failed)
        XCTAssertTrue(t.canRetry("m1"), "没交给 WS：原帧还在，还能再点")
    }

    func testFrameCacheKeepsRecentAndPinned() {
        var cache = CCSendFrameCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<CCSendFrameCache.keepCount {
            cache.remember("m\(i)", ["type": "send", "message_id": "m\(i)", "content": "x"], now: t0)
        }
        cache.pin("m0")   // 收到 uncertain：钉住
        let later = t0.addingTimeInterval(CCSendFrameCache.graceAge + 1)
        cache.remember("new1", ["type": "send", "content": "x"], now: later)
        cache.remember("new2", ["type": "send", "content": "x"], now: later)
        XCTAssertNotNil(cache.frame("m0"), "钉住的不被挤掉")
        XCTAssertNil(cache.frame("m1"), "超条数挤掉最老的")
        XCTAssertNotNil(cache.frame("new2"))
        cache.release("m0")   // delivered：放掉
        XCTAssertNil(cache.frame("m0"))
    }

    // MARK: - 发出后 120 秒内不按条数挤（sol P2-5）

    func testFramesWithinGraceSurviveCountLimit() {
        var cache = CCSendFrameCache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(CCSendFrameCache.keepCount + 10) {
            cache.remember("m\(i)", ["type": "send", "content": "x"], now: t0.addingTimeInterval(TimeInterval(i)))
        }
        XCTAssertNotNil(cache.frame("m0"), "120 秒内的帧不按条数挤")
        // 过了宽限期再发一条：超出的老帧按条数挤掉，只剩 keepCount 条没钉住的
        let evicted = cache.remember("late", ["type": "send", "content": "x"],
                                     now: t0.addingTimeInterval(CCSendFrameCache.graceAge + 100))
        XCTAssertEqual(evicted.count, 11)
        XCTAssertNil(cache.frame("m0"))
        XCTAssertNotNil(cache.frame("late"))
    }

    func testFramesWithinGraceStillBoundByBytes() {
        var cache = CCSendFrameCache()
        let half = CCSendFrameCache.keepBytes / 2 + 1
        let now = Date()
        cache.remember("a", ["type": "send", "files": [["b64": String(repeating: "a", count: half)]]], now: now)
        let evicted = cache.remember("b", ["type": "send", "files": [["b64": String(repeating: "a", count: half)]]], now: now)
        XCTAssertEqual(evicted, ["a"], "宽限期内也受总预算约束")
    }

    func testTrackerUncertainAfterManySendsStillRetryable() {
        let t = CCSendTracker()
        let t0 = Date()
        t.didSend("slow", frame: ["type": "send", "content": "x"], now: t0)
        for i in 0..<(CCSendFrameCache.keepCount + 5) {
            t.didSend("m\(i)", frame: ["type": "send", "content": "x"], now: t0.addingTimeInterval(TimeInterval(i)))
        }
        t.didReceive(CCSendStatus(chatId: "c", messageId: "slow", sessionName: "s", state: .failed, reason: nil),
                     now: t0.addingTimeInterval(60))
        XCTAssertEqual(t.store.entry("slow")?.canRetry, true, "uncertain / failed 到之前原帧没被条数挤掉")
    }

    // MARK: - 有界（sol P1-2）：recent + pinned 一起算预算；单帧超预算不缓存；状态条数 / TTL

    private func bigFrame(_ size: Int) -> [String: Any] {
        ["type": "send", "images": [["b64": String(repeating: "a", count: size)]]]
    }

    func testFrameCacheByteBudgetEvictsOldest() {
        var cache = CCSendFrameCache()
        let half = CCSendFrameCache.keepBytes / 2 + 1
        cache.remember("a", bigFrame(half))
        XCTAssertEqual(cache.remember("b", bigFrame(half)), ["a"], "超字节挤掉老的")
        XCTAssertNotNil(cache.frame("b"))
        XCTAssertLessThanOrEqual(cache.totalBytes, CCSendFrameCache.keepBytes)
    }

    func testOversizedFrameNotCached() {
        var cache = CCSendFrameCache()
        cache.remember("a", ["type": "send", "content": "x"])
        XCTAssertEqual(cache.remember("huge", bigFrame(CCSendFrameCache.keepBytes + 1)), [])
        XCTAssertNil(cache.frame("huge"), "单帧超预算不缓存")
        XCTAssertNotNil(cache.frame("a"), "也不为它挤别人")
    }

    func testPinnedFramesCountTowardBudget() {
        var cache = CCSendFrameCache()
        let third = CCSendFrameCache.keepBytes / 3 + 1
        cache.remember("p1", bigFrame(third)); cache.pin("p1")
        cache.remember("p2", bigFrame(third)); cache.pin("p2")
        XCTAssertEqual(cache.remember("n", bigFrame(third)), ["p1"], "钉住的也算预算，超了挤最老的钉住帧")
        XCTAssertLessThanOrEqual(cache.totalBytes, CCSendFrameCache.keepBytes)
        XCTAssertNotNil(cache.frame("p2"))
        XCTAssertNotNil(cache.frame("n"))
    }

    func testTrackerOversizedFailureIsNotRetryable() {
        let t = CCSendTracker()
        t.didSend("m1", frame: bigFrame(CCSendFrameCache.keepBytes + 1))
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .failed, reason: nil))
        let e = t.store.entry("m1")
        XCTAssertEqual(e?.canRetry, false)
        XCTAssertEqual(e?.visibleReason, "原消息没留住，请重新发一遍")
        XCTAssertNil(t.beginRetry("m1"))
    }

    func testTrackerMarksEvictedFrameNotRetryable() {
        let t = CCSendTracker()
        let half = CCSendFrameCache.keepBytes / 2 + 1
        t.didSend("m1", frame: bigFrame(half))
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .failed, reason: "重发也没进输入框"))
        XCTAssertEqual(t.store.entry("m1")?.canRetry, true)
        t.didSend("m2", frame: bigFrame(half))   // 钉住的 m1 被预算挤掉
        XCTAssertEqual(t.store.entry("m1")?.canRetry, false)
        XCTAssertEqual(t.store.entry("m1")?.visibleReason, "重发也没进输入框。原消息没留住，请重新发一遍")
    }

    // MARK: - retryable + 连上后的快照（sol P1-4 / P2-6）

    func testRetryableParsingAndDefault() {
        XCTAssertEqual(CCSendStatus(frame: frame("failed"))?.retryable, true, "缺省：failed 当可重发")
        XCTAssertEqual(CCSendStatus(frame: frame("uncertain"))?.retryable, false)
        var f = frame("failed"); f["retryable"] = false
        XCTAssertEqual(CCSendStatus(frame: f)?.retryable, false)
    }

    func testHubSaysNotRetryableHidesButton() {
        let t = CCSendTracker()
        t.didSend("m1", frame: ["type": "send", "content": "hi"])
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .failed, reason: "重发被拒：没有这条的失败记录", retryable: false))
        let e = t.store.entry("m1")
        XCTAssertEqual(e?.canRetry, false, "按钮只看 retryable")
        XCTAssertEqual(e?.visibleReason, "重发被拒：没有这条的失败记录", "只显示原因")
        XCTAssertNil(t.beginRetry("m1"))
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m2", sessionName: "s", state: .failed, reason: "tmux gone", retryable: false))
        XCTAssertEqual(t.store.entry("m2")?.visibleReason, "请重新发一遍", "没有中文原因时兜底")
    }

    func testSnapshotFrameParsing() {
        let items: [[String: Any]] = [frame("uncertain"), frame("bogus"), ["status": "failed"], frame("failed", messageId: "m2")]
        let list = CCSendStatus.snapshot(frame: ["type": "send_status_snapshot", "statuses": items])
        XCTAssertEqual(list?.map(\.messageId), ["m1", "m2"], "坏条目单条跳过")
        XCTAssertNil(CCSendStatus.snapshot(frame: ["type": "send_status_snapshot"]), "没有 statuses 整帧忽略")
        XCTAssertEqual(CCSendStatus.snapshot(frame: ["type": "send_status_snapshot", "statuses": []])?.count, 0)
    }

    func testSnapshotOverridesAndMarksMissing() {
        let t = CCSendTracker()
        for id in ["u1", "u2", "f1", "f2"] { t.didSend(id, frame: ["type": "send", "content": id]) }
        t.didReceive(CCSendStatus(chatId: "c", messageId: "u1", sessionName: "s", state: .uncertain, reason: nil))
        t.didReceive(CCSendStatus(chatId: "c", messageId: "u2", sessionName: "s", state: .uncertain, reason: nil))
        t.didReceive(CCSendStatus(chatId: "c", messageId: "f1", sessionName: "s", state: .failed, reason: nil))
        t.didReceive(CCSendStatus(chatId: "c", messageId: "f2", sessionName: "s", state: .failed, reason: nil))
        // 离线期间：u1 hub 判 failed；u2、f2 hub 账没了；f1 还是 failed
        t.didReceiveSnapshot([
            CCSendStatus(chatId: "c", messageId: "u1", sessionName: "s", state: .failed, reason: "补 Enter 也没提交"),
            CCSendStatus(chatId: "c", messageId: "f1", sessionName: "s", state: .failed, reason: nil),
        ])
        XCTAssertEqual(t.store.entry("u1")?.state, .failed)
        XCTAssertEqual(t.store.entry("u1")?.canRetry, true)
        XCTAssertEqual(t.store.entry("u2")?.state, .failed, "不能永远确认中")
        XCTAssertEqual(t.store.entry("u2")?.canRetry, false)
        XCTAssertEqual(t.store.entry("u2")?.visibleReason, CCSendTracker.missingOnHubUncertain)
        XCTAssertEqual(t.store.entry("f1")?.canRetry, true)
        XCTAssertEqual(t.store.entry("f2")?.canRetry, false, "hub 账没了，重发必被拒")
        XCTAssertEqual(t.store.entry("f2")?.visibleReason, CCSendTracker.missingOnHubFailed)
    }

    func testSnapshotDeliveredRemoves() {
        let t = CCSendTracker()
        t.didSend("m1", frame: ["type": "send", "content": "x"])
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .uncertain, reason: nil))
        t.didReceiveSnapshot([CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .delivered, reason: nil)])
        XCTAssertNil(t.store.entry("m1"))
    }

    func testNotRetryableReleasesFrame() {
        let t = CCSendTracker()
        t.didSend("m1", frame: ["type": "send", "content": "abc"])
        t.didSend("m2", frame: ["type": "send", "content": "defg"])
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .failed, reason: nil, retryable: false))
        XCTAssertEqual(t.cachedBytes, 4, "hub 判不可重发：原帧放掉")
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m2", sessionName: "s", state: .uncertain, reason: nil))
        t.didReceiveSnapshot([])
        XCTAssertEqual(t.cachedBytes, 0, "快照里缺席：原帧放掉")
        XCTAssertEqual(t.store.entry("m2")?.visibleReason, CCSendTracker.missingOnHubUncertain)
    }

    // MARK: - VoiceOver（sol P2-8）

    func testAccessibilityCarriesFullReasonAndRetryHint() {
        let long = "补 Enter 也没提交，输入框里还留着这条，电脑那边已经卡了很久，建议先看一眼终端再决定"
        let t = CCSendTracker()
        t.didSend("m1", frame: ["type": "send", "content": "x"])
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .failed, reason: long))
        XCTAssertEqual(t.store.entry("m1")?.accessibilityValue, long, "完整原因进 value")
        XCTAssertNotNil(t.store.entry("m1")?.accessibilityHint, "能重发才有 hint")
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .failed, reason: long, retryable: false))
        XCTAssertNil(t.store.entry("m1")?.accessibilityHint, "不能重发不给 hint")
        XCTAssertEqual(t.store.entry("m1")?.accessibilityValue, long)
    }

    // MARK: - 同一个 id 再发（sol P1-3：重新生成复用用户节点 id）

    func testResendSameIdReplacesPinnedFrameAndClearsStatus() {
        let t = CCSendTracker()
        t.didSend("m1", frame: ["type": "send", "message_id": "m1", "content": "旧", "effort": "low"])
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .failed, reason: nil))
        XCTAssertNotNil(t.store.entry("m1"))
        var events: [String] = []
        let sub = t.store.membership.sink { events.append($0) }
        t.didSend("m1", frame: ["type": "send", "message_id": "m1", "content": "新", "effort": "high"])
        XCTAssertNil(t.store.entry("m1"), "重新生成：旧状态清掉")
        XCTAssertEqual(events, ["m1"], "标记摘掉")
        t.didReceive(CCSendStatus(chatId: "c", messageId: "m1", sessionName: "s", state: .failed, reason: nil))
        let retry = t.beginRetry("m1")
        XCTAssertEqual(retry?["content"] as? String, "新", "重发的是新帧，不是钉住的旧帧")
        XCTAssertEqual(retry?["effort"] as? String, "high")
        sub.cancel()
    }

    func testFrameCacheResendReplacesPinned() {
        var cache = CCSendFrameCache()
        cache.remember("m1", ["type": "send", "content": "旧"]); cache.pin("m1")
        cache.remember("m1", ["type": "send", "content": "新"])
        XCTAssertEqual(cache.frame("m1")?["content"] as? String, "新")
        XCTAssertEqual(cache.totalBytes, "新".utf8.count, "旧帧不再占预算")
    }

    func testStorePrunesByTTLAndCount() {
        let store = CCSendStatusStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        store.set("old", state: .uncertain, reason: nil, retryable: true, hasFrame: false, now: t0)
        for i in 0..<CCSendStatusStore.maxEntries {
            store.set("m\(i)", state: .failed, reason: nil, retryable: true, hasFrame: false, now: t0.addingTimeInterval(TimeInterval(3000 + i)))
        }
        let dropped = store.prune(now: t0.addingTimeInterval(CCSendStatusStore.ttl + 1))
        XCTAssertEqual(dropped, ["old"], "一小时没更新的清掉")
        store.set("new", state: .failed, reason: nil, retryable: true, hasFrame: false, now: t0.addingTimeInterval(4000))
        XCTAssertEqual(store.prune(now: t0.addingTimeInterval(4000)), ["m0"], "超量清最久没更新的")
        XCTAssertEqual(store.count, CCSendStatusStore.maxEntries)
    }
}
