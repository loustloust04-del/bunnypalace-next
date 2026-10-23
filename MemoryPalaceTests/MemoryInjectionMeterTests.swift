import XCTest
@testable import 记忆花园

/// 修复第一刀·刀5：「实际注入量」= 注入器真实命中按同一计费公式累加。
final class MemoryInjectionMeterTests: XCTestCase {

    let pid = "xctest-meter"
    private let touchedKeys = ["mem_inject_catalog", "mem_inject_keyword", "mem_inject_vector", "mem_inject_full"]

    override func setUp() {
        super.setUp()
        touchedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        MemoryInjectionMeter.clear(profileId: pid)
    }

    override func tearDown() {
        touchedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        MemoryInjectionMeter.clear(profileId: pid)
        super.tearDown()
    }

    private func mems() -> [Memory] {
        [Memory(content: "钉住：我们约好每周日一起散步", category: "fact", profileId: pid, isUserExplicit: true),
         Memory(content: "用户最近在学日语", category: "goal", profileId: pid),
         Memory(content: "用户喜欢暖奶白配色", category: "preference", profileId: pid)]
    }

    func testFullTextTokensEqualInjectedMemoriesTokenCount() {
        let ms = mems()
        let r = MemoryInjector.buildInjectionSplit(memories: ms, recentMessages: [])
        let m = MemoryInjectionMeter.measure(hits: r.hits, memories: ms)
        let injectedIds = Set(r.hits.map(\.memoryId))
        XCTAssertEqual(m.tokens, ms.filter { injectedIds.contains($0.id) }.reduce(0) { $0 + $1.tokenCount })
        XCTAssertEqual(m.stable + m.hit, r.hits.count)
        XCTAssertEqual(m.stable, 1, "纯全量模式常驻层 = 钉住的那一条")
    }

    func testCatalogTokensUseCatalogLineCost() {
        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        let ms = mems()
        let r = MemoryInjector.buildInjectionSplit(memories: ms, recentMessages: [])
        let m = MemoryInjectionMeter.measure(hits: r.hits, memories: ms)
        let expected = r.hits.reduce(0) { sum, h in
            let mem = ms.first { $0.id == h.memoryId }!
            return sum + (h.catalog ? Memory.estimateTokens(MemoryInjector.catalogLine(mem)) : mem.tokenCount)
        }
        XCTAssertEqual(m.tokens, expected)
    }

    /// cc-bridge 那一轮照实记「CC 没收到」；之后走普通 provider 的一轮会覆盖回实际注入量
    func testCCBridgeRecordOverridesAndNormalTurnRestores() {
        let ms = mems()
        let r = MemoryInjector.buildInjectionSplit(memories: ms, recentMessages: [])
        MemoryInjectionMeter.record(profileId: pid, hits: r.hits, memories: ms)
        MemoryInjectionMeter.recordCCBridge(profileId: pid)
        let cc = MemoryInjectionMeter.load(profileId: pid)
        XCTAssertEqual(cc?.viaCCBridge, true)
        XCTAssertEqual(cc?.tokens, 0)
        MemoryInjectionMeter.record(profileId: pid, hits: r.hits, memories: ms)
        XCTAssertNotEqual(MemoryInjectionMeter.load(profileId: pid)?.viaCCBridge, true, "普通一轮覆盖掉 CC 记录")
        XCTAssertGreaterThan(MemoryInjectionMeter.load(profileId: pid)?.tokens ?? 0, 0)
    }

    /// 刀5 时期写下的旧记录（没有 viaCCBridge 字段）照常能读
    func testLegacyRecordWithoutCCFieldDecodes() {
        let legacy = #"{"hitCount":0,"stableCount":0,"tokens":0,"at":812550109.362346}"#
        UserDefaults.standard.set(Data(legacy.utf8), forKey: "mem_last_injection_\(pid)")
        let r = MemoryInjectionMeter.load(profileId: pid)
        XCTAssertNotNil(r)
        XCTAssertNil(r?.viaCCBridge)
    }

    func testRecordRoundTripAndSkipsUnchanged() {
        let ms = mems()
        let r = MemoryInjector.buildInjectionSplit(memories: ms, recentMessages: [])
        MemoryInjectionMeter.record(profileId: pid, hits: r.hits, memories: ms)
        let first = MemoryInjectionMeter.load(profileId: pid)
        XCTAssertNotNil(first)
        MemoryInjectionMeter.record(profileId: pid, hits: r.hits, memories: ms)
        XCTAssertEqual(MemoryInjectionMeter.load(profileId: pid)?.at, first?.at, "没变就不重写")
    }
}
