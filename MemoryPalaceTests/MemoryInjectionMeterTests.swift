import MemoryCore
import XCTest
@testable import 记忆花园

/// 旧记录兼容和 CC 未注入标记；逐轮账与 wire 一致由真实路径套件验证。
final class MemoryInjectionMeterTests: XCTestCase {

    let pid = "xctest-meter"
    override func setUp() {
        super.setUp()
        MemoryInjectionMeter.clear(profileId: pid)
    }

    override func tearDown() {
        MemoryInjectionMeter.clear(profileId: pid)
        super.tearDown()
    }


    /// cc-bridge 那一轮照实记「CC 没收到」；之后走普通 provider 的一轮会覆盖回实际注入量
    func testCCBridgeRecordOverridesAndNormalTurnRestores() {
        let record = MemoryInjectionRecord(tokens: 42, stableCount: 1, hitCount: 2, at: Date())
        MemoryInjectionMeter.record(profileId: pid, record: record)
        MemoryInjectionMeter.recordCCBridge(profileId: pid)
        let cc = MemoryInjectionMeter.load(profileId: pid)
        XCTAssertEqual(cc?.viaCCBridge, true)
        XCTAssertEqual(cc?.tokens, 0)
        MemoryInjectionMeter.record(profileId: pid, record: record)
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid), record)
    }

    func testRecordsExactSubmittedSnapshotWithoutRecomputingCountsOrTime() {
        var receipt = RecallTurnReceipt(decision: RecallTurnDecision(
            turnId: "star-user", branchAnchor: "cloud-window", origin: .user, gateReason: .search,
            tuning: RecallTestTuning.make(), topicAnchor: "星砚在云桥城", selected: [], candidates: [],
            suppressions: [], ignored: [], thawed: [], stateAfterResponse: RecallConversationState()))
        let snapshot = MemoryInjectionRecord(tokens: 137, stableCount: 2, hitCount: 1,
                                             at: Date(timeIntervalSince1970: 1_792_880_000),
                                             selfTokens: 23, selfCount: 1,
                                             timelineKeys: ["2026-10-24|cloud-window|last-node"],
                                             contextKeys: ["cloud-window|summary-node"])
        receipt.injectionRecord = snapshot
        MemoryInjectionMeter.record(profileId: pid, receipt: receipt)
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid), snapshot)
        MemoryInjectionMeter.record(profileId: pid, record: snapshot)
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid)?.at, snapshot.at,
                       "重放同轮真实快照不能改成当前时间或重算选择")

        let emptyTurn = MemoryInjectionRecord(tokens: 0, stableCount: 0, hitCount: 0,
                                              at: snapshot.at.addingTimeInterval(1),
                                              selfTokens: 0, selfCount: 0, timelineKeys: [], contextKeys: [])
        MemoryInjectionMeter.record(profileId: pid, record: emptyTurn)
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid), emptyTurn,
                       "本轮没有注入也必须覆盖上轮数据，不沿用旧命中或时间轴")
    }

    /// 刀5 时期写下的旧记录（没有 viaCCBridge 字段）照常能读
    func testLegacyRecordWithoutCCFieldDecodes() {
        let legacy = #"{"hitCount":0,"stableCount":0,"tokens":0,"at":812550109.362346}"#
        UserDefaults.standard.set(Data(legacy.utf8), forKey: "mem_last_injection_\(pid)")
        let r = MemoryInjectionMeter.load(profileId: pid)
        XCTAssertNotNil(r)
        XCTAssertNil(r?.viaCCBridge)
    }

    /// 新记录带窗口 id；没有这个键的老记录照常解（可选字段，缺键 = nil）
    func testConversationIdRoundTripAndOldRecordDecodes() {
        let record = MemoryInjectionRecord(tokens: 7, stableCount: 1, hitCount: 2,
                                           at: Date(timeIntervalSince1970: 1), conversationId: "cloud-window")
        MemoryInjectionMeter.record(profileId: pid, record: record)
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid)?.conversationId, "cloud-window")
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid), record)
        let legacy = #"{"hitCount":2,"stableCount":1,"tokens":7,"at":1}"#
        UserDefaults.standard.set(Data(legacy.utf8), forKey: "mem_last_injection_\(pid)")
        let decoded = MemoryInjectionMeter.load(profileId: pid)
        XCTAssertEqual(decoded?.tokens, 7)
        XCTAssertEqual(decoded?.hitCount, 2)
        XCTAssertNil(decoded?.conversationId)
    }

}
