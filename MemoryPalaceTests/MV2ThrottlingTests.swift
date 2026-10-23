import XCTest
@testable import 记忆花园

/// MV2 提取降敏 特征测试。
/// 测两件：① ExtractScheduler.tick 决策（含首轮必跑/间隔归零/边界）；② prompt 规则 8/11 扩展可见。
final class MV2ThrottlingTests: XCTestCase {

    // MARK: - ExtractScheduler.tick

    func testFirstRunFiresRegardlessOfCounter() {
        // hasEverRun=false → 必跑，counter 归 0
        let r = ExtractScheduler.tick(counter: 0, interval: 3, hasEverRun: false)
        XCTAssertTrue(r.shouldRun, "首轮必跑")
        XCTAssertEqual(r.newCounter, 0)
    }

    func testFirstRunFiresEvenWithHighCounter() {
        // 防御：即使外部传入异常 counter，hasEverRun=false 仍走首轮分支
        let r = ExtractScheduler.tick(counter: 999, interval: 3, hasEverRun: false)
        XCTAssertTrue(r.shouldRun)
        XCTAssertEqual(r.newCounter, 0)
    }

    func testCounterAccumulatesUntilInterval() {
        // 模拟 N=3 间隔：第 1、2 轮跳过，counter 累计；第 3 轮触发归零
        var counter = 0
        var hasRun = true   // 首轮已跑过

        let r1 = ExtractScheduler.tick(counter: counter, interval: 3, hasEverRun: hasRun)
        XCTAssertFalse(r1.shouldRun); XCTAssertEqual(r1.newCounter, 1)
        counter = r1.newCounter

        let r2 = ExtractScheduler.tick(counter: counter, interval: 3, hasEverRun: hasRun)
        XCTAssertFalse(r2.shouldRun); XCTAssertEqual(r2.newCounter, 2)
        counter = r2.newCounter

        let r3 = ExtractScheduler.tick(counter: counter, interval: 3, hasEverRun: hasRun)
        XCTAssertTrue(r3.shouldRun, "counter+1 达到 interval 时触发"); XCTAssertEqual(r3.newCounter, 0)
    }

    func testIntervalOneRunsEveryRound() {
        // mem_extract_interval=1 退回 MV0 每轮提取行为
        let r1 = ExtractScheduler.tick(counter: 0, interval: 1, hasEverRun: true)
        XCTAssertTrue(r1.shouldRun); XCTAssertEqual(r1.newCounter, 0)
        let r2 = ExtractScheduler.tick(counter: 0, interval: 1, hasEverRun: true)
        XCTAssertTrue(r2.shouldRun)
    }

    func testZeroOrNegativeIntervalClampedToOne() {
        // 边界：interval <1 当 1 处理（防御非法 defaults）
        let r0 = ExtractScheduler.tick(counter: 0, interval: 0, hasEverRun: true)
        XCTAssertTrue(r0.shouldRun, "interval=0 当 1 处理→每轮跑")
        let rNeg = ExtractScheduler.tick(counter: 0, interval: -5, hasEverRun: true)
        XCTAssertTrue(rNeg.shouldRun)
    }

    func testTenRoundCycleN3() {
        // 端到端：10 轮 N=3 应该触发 4 次（首轮 + 第 4、7、10 轮）
        var counter = 0
        var hasRun = false
        var fireCount = 0
        for _ in 1...10 {
            let r = ExtractScheduler.tick(counter: counter, interval: 3, hasEverRun: hasRun)
            counter = r.newCounter
            if r.shouldRun {
                fireCount += 1
                hasRun = true
            }
        }
        XCTAssertEqual(fireCount, 4, "10 轮 N=3 触发 4 次：首轮 + 第 4/7/10 轮")
    }

    // MARK: - prompt 规则扩展可见

    func testRule8MentionsRepeatedFacts() {
        let prompt = MemoryExtractor.buildPrompt(existingMemories: [], profile: nil, systemPrompt: "")
        XCTAssertTrue(prompt.contains("同一轮里重复说的"), "不记同一轮重复说的（第二刀改写后措辞）")
    }

    func testRule11CoversBothProfileAndMemory() {
        let prompt = MemoryExtractor.buildPrompt(existingMemories: [], profile: nil, systemPrompt: "")
        XCTAssertTrue(prompt.contains("画像或现有档案已经涵盖的别 add"), "统一表述'画像或现有档案'")
        XCTAssertTrue(prompt.contains("用 update 改写那一条"), "引导 update 替代 add")
    }

    func testMemoryFlagsExtractIntervalDefault() {
        UserDefaults.standard.removeObject(forKey: "mem_extract_interval")
        XCTAssertEqual(MemoryFlags.extractInterval, 3, "默认 N=3")
        UserDefaults.standard.set(5, forKey: "mem_extract_interval")
        XCTAssertEqual(MemoryFlags.extractInterval, 5, "defaults write 可调")
        UserDefaults.standard.set(0, forKey: "mem_extract_interval")
        XCTAssertEqual(MemoryFlags.extractInterval, 3, "0 视作未设置走默认")
        UserDefaults.standard.removeObject(forKey: "mem_extract_interval")
    }
}
