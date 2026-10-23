import Observation
import XCTest
@testable import 记忆花园

/// 底部模型胶囊「cc-模型名」（粟粟 10-11）：hub 的 session_model 帧 → 按会话存 → 胶囊只读当前会话那一项
@MainActor
final class CCSessionModelTests: XCTestCase {
    func testParseFrame() {
        let m = CCSessionModel(frame: ["type": "session_model", "session_name": "mp-cc-1", "model": "opus-4.6-1m", "model_id": "claude-opus-4-6[1m]"])
        XCTAssertEqual(m?.sessionName, "mp-cc-1")
        XCTAssertEqual(m?.model, "opus-4.6-1m")
        XCTAssertEqual(m?.modelId, "claude-opus-4-6[1m]")
        XCTAssertEqual(CCSessionModel(frame: ["session_name": "mp-cc-1", "model": "opus"])?.modelId, "opus", "老 hub 没带 model_id 用短名顶上")
        XCTAssertNil(CCSessionModel(frame: ["session_name": "mp-cc-1"]))
        XCTAssertNil(CCSessionModel(frame: ["session_name": "", "model": "opus"]))
        XCTAssertNil(CCSessionModel(frame: ["session_name": "mp-cc-1", "model": ""]))
    }

    /// 审查 R1-9：hub 不知道了（model: null）→ 清掉后缀
    func testNullModelClears() {
        let store = CCSessionModelStore()
        store.apply(CCSessionModel(frame: ["session_name": "mp-codex-1", "model": "gpt-5.2-codex"])!)
        let clear = CCSessionModel(frame: ["session_name": "mp-codex-1", "model": NSNull(), "model_id": NSNull()])
        XCTAssertNotNil(clear)
        XCTAssertNil(clear?.model)
        store.apply(clear!)
        XCTAssertNil(store.entry(for: "mp-codex-1").model)
    }

    /// 审查 R1-9：有上限、久没碰的清掉；先清最久没碰的，刚读过的留着
    func testStoreBoundedAndExpires() {
        let store = CCSessionModelStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let kept = store.entry(for: "mp-cc-keep", now: t0)
        for i in 0..<(CCSessionModelStore.maxEntries + 20) {
            _ = store.entry(for: "mp-cc-keep", now: t0.addingTimeInterval(Double(i)))   // 胶囊一直在读
            store.apply(CCSessionModel(frame: ["session_name": "mp-cc-\(i)", "model": "opus-5.5"])!, now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertLessThanOrEqual(store.count, CCSessionModelStore.maxEntries)
        XCTAssertTrue(store.entry(for: "mp-cc-keep", now: t0.addingTimeInterval(500)) === kept)
        _ = store.entry(for: "mp-cc-new", now: t0.addingTimeInterval(CCSessionModelStore.ttl + 1000))
        XCTAssertEqual(store.count, 1)
    }

    /// 审查 R1-6：ChatInputBar 取那一项（ModelCapsule.entry）只查索引、不读模型 → 父视图不订阅；胶囊自己读 title 才订阅
    func testParentLookupDoesNotObserveModel() {
        let store = CCSessionModelStore()
        store.apply(CCSessionModel(frame: ["session_name": "mp-cc-a", "model": "opus-5.5"])!)
        let parent = Flag()
        let entry = withObservationTracking {
            ModelCapsule.entry(isCCBridge: true, sessionName: "mp-cc-a", store: store)
        } onChange: { parent.fired = true }
        let capsule = ModelCapsule(cardName: "cc", entry: entry, onTap: {})
        let child = Flag()
        withObservationTracking { _ = capsule.title } onChange: { child.fired = true }
        XCTAssertEqual(capsule.title, "cc-opus-5.5")

        store.apply(CCSessionModel(frame: ["session_name": "mp-cc-a", "model": "sonnet-5"])!)
        XCTAssertFalse(parent.fired, "父视图那一侧不该因为模型变了重算")
        XCTAssertTrue(child.fired)
        XCTAssertEqual(capsule.title, "cc-sonnet-5")

        XCTAssertNil(ModelCapsule.entry(isCCBridge: false, sessionName: "mp-cc-a", store: store), "别的卡不带后缀")
        XCTAssertNil(ModelCapsule.entry(isCCBridge: true, sessionName: nil, store: store), "还没绑会话不带后缀")
        XCTAssertEqual(ModelCapsule(cardName: "GPT", entry: nil, onTap: {}).title, "GPT")
    }

    func testCapsuleTitle() {
        XCTAssertEqual(CCSessionModelStore.capsuleTitle(cardName: "cc", model: "opus-4.6-1m"), "cc-opus-4.6-1m")
        XCTAssertEqual(CCSessionModelStore.capsuleTitle(cardName: "Codex", model: "gpt-5.2-codex"), "Codex-gpt-5.2-codex")
        XCTAssertEqual(CCSessionModelStore.capsuleTitle(cardName: "cc", model: nil), "cc")
        XCTAssertEqual(CCSessionModelStore.capsuleTitle(cardName: "cc", model: ""), "cc")
    }

    func testStoreKeepsOneStableEntryPerSession() {
        let store = CCSessionModelStore()
        let e = store.entry(for: "mp-cc-a")
        XCTAssertNil(e.model, "还没收到帧：胶囊只显示卡名")
        store.apply(CCSessionModel(frame: ["session_name": "mp-cc-a", "model": "opus-5.5"])!)
        XCTAssertTrue(store.entry(for: "mp-cc-a") === e, "先读后到帧：还是同一个对象，读过它的胶囊能收到变化")
        XCTAssertEqual(e.model, "opus-5.5")
        store.apply(CCSessionModel(frame: ["session_name": "mp-cc-b", "model": "sonnet-5"])!)
        XCTAssertEqual(e.model, "opus-5.5")
        XCTAssertEqual(store.entry(for: "mp-cc-b").model, "sonnet-5")
    }

    private final class Flag: @unchecked Sendable { var fired = false }

    /// 只有这一项真变了才通知读它的视图；别的会话换模型、hub 重连补发同值都不通知
    func testOnlyRealChangeOfThisSessionNotifies() {
        let store = CCSessionModelStore()
        store.apply(CCSessionModel(frame: ["session_name": "mp-cc-a", "model": "opus-5.5"])!)
        let e = store.entry(for: "mp-cc-a")
        let flag = Flag()
        withObservationTracking { _ = e.model } onChange: { flag.fired = true }

        store.apply(CCSessionModel(frame: ["session_name": "mp-cc-a", "model": "opus-5.5"])!)
        store.apply(CCSessionModel(frame: ["session_name": "mp-cc-b", "model": "sonnet-5"])!)
        _ = store.entry(for: "mp-cc-c")
        XCTAssertFalse(flag.fired)

        store.apply(CCSessionModel(frame: ["session_name": "mp-cc-a", "model": "sonnet-5"])!)
        XCTAssertTrue(flag.fired)
        XCTAssertEqual(e.model, "sonnet-5")
    }
}
