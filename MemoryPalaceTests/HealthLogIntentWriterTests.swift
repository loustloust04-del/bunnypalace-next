import XCTest
import SwiftData
@testable import 记忆花园

/// 健康对话式录入（plan-health-chat-entry §4 矩阵）：
/// 提取/weight/med 匹配与 slot 规则/替换幂等/未知 type。
@MainActor
final class HealthLogIntentWriterTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let pid = "xctest-health-intent"

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: MessageNode.self, WeightEntry.self, Medication.self, MedicationLog.self, CycleDay.self, IntimacyEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func at(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    @discardableResult
    private func seedNode(_ content: String, role: String = "assistant") -> MessageNode {
        let node = MessageNode(
            id: UUID().uuidString, role: role, content: content, contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [], conversationId: "conv-1",
            profileId: pid
        )
        context.insert(node)
        try! context.save()
        return node
    }

    @discardableResult
    private func seedMed(_ name: String = "维生素 D", times: [Int] = [480]) -> Medication {
        let med = Medication(profileId: pid, name: name, dosage: "1 片", timesOfDay: times)
        context.insert(med)
        try! context.save()
        return med
    }

    private func block(_ json: String) -> String {
        "```health-log\n\(json)\n```"
    }

    // MARK: 提取与守卫

    func testNoBlockZeroCost() {
        let node = seedNode("普通回复没有块")
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertEqual(node.content, "普通回复没有块")
    }

    func testUserRoleIgnored() {
        let node = seedNode(block("{\"type\": \"weight\", \"kg\": 52.3}"), role: "user")
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("```health-log"), "user 消息不处理")
    }

    func testMultipleBlocksReverseReplaced() {
        seedMed()
        let node = seedNode("先记体重\n\(block("{\"type\": \"weight\", \"kg\": 52.3}"))\n再打卡\n\(block("{\"type\": \"med\", \"name\": \"维生素\"}"))")
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context, now: at(hour: 9))
        XCTAssertFalse(node.content.contains("```health-log"))
        XCTAssertTrue(node.content.contains("♥ 已记体重 52.3 公斤"), node.content)
        XCTAssertTrue(node.content.contains("♥ 已打卡：维生素 D 8:00"), node.content)
    }

    func testIdempotentSecondRun() {
        let node = seedNode(block("{\"type\": \"weight\", \"kg\": 52.3}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        let after = node.content
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertEqual(node.content, after, "二跑零变化")
        XCTAssertEqual(HealthLogStore.fetchRecentWeights(context: context, profileId: pid).count, 1)
    }

    // MARK: weight

    func testWeightLandsAndSameDayOverwrites() {
        let n1 = seedNode(block("{\"type\": \"weight\", \"kg\": 52.5}"))
        HealthLogIntentWriter.processChatIntents(nodeId: n1.id, context: context)
        let n2 = seedNode(block("{\"type\": \"weight\", \"kg\": 52.1}"))
        HealthLogIntentWriter.processChatIntents(nodeId: n2.id, context: context)
        let weights = HealthLogStore.fetchRecentWeights(context: context, profileId: pid)
        XCTAssertEqual(weights.count, 1)
        XCTAssertEqual(weights[0].weightKg, 52.1, accuracy: 0.001)
    }

    func testWeightWithPastDate() {
        let node = seedNode(block("{\"type\": \"weight\", \"kg\": 53.0, \"date\": \"2026-07-01\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 已记体重 53.0 公斤（7 月 1 日）"), node.content)
    }

    func testWeightFutureDateRejected() {
        let node = seedNode(block("{\"type\": \"weight\", \"kg\": 53.0, \"date\": \"2077-01-01\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 未来的日期记不了"), node.content)
        XCTAssertTrue(HealthLogStore.fetchRecentWeights(context: context, profileId: pid).isEmpty)
    }

    func testWeightInvalidValue() {
        let node = seedNode(block("{\"type\": \"weight\", \"kg\": -5}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 记录格式无效"), node.content)
    }

    // MARK: med 匹配

    func testMedUniqueFuzzyMatch() {
        seedMed("维生素 D")
        let node = seedNode(block("{\"type\": \"med\", \"name\": \"维生素\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context, now: at(hour: 9))
        XCTAssertTrue(node.content.contains("♥ 已打卡：维生素 D 8:00"), node.content)
    }

    func testMedZeroMatch() {
        seedMed("维生素 D")
        let node = seedNode(block("{\"type\": \"med\", \"name\": \"褪黑素\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 没找到叫「褪黑素」的药"), node.content)
    }

    func testMedMultiMatch() {
        seedMed("维生素 D")
        seedMed("维生素 C")
        let node = seedNode(block("{\"type\": \"med\", \"name\": \"维生素\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("对上了好几种药"), node.content)
    }

    // MARK: med slot 规则

    func testMedExplicitTimeHitsSlot() {
        let med = seedMed(times: [480, 1260])
        let node = seedNode(block("{\"type\": \"med\", \"name\": \"维生素\", \"time\": \"21:00\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context, now: at(hour: 12))
        XCTAssertTrue(node.content.contains("♥ 已打卡：维生素 D 21:00"), node.content)
        let logs = HealthLogStore.fetchTodayLogs(context: context, profileId: pid, now: at(hour: 12))
        XCTAssertEqual(logs.first?.scheduledAt, HealthLogStore.scheduledDate(minuteOfDay: 1260, on: at(hour: 12)))
        _ = med
    }

    func testMedExplicitNonSlotTimeIsExtra() {
        seedMed(times: [480])
        let node = seedNode(block("{\"type\": \"med\", \"name\": \"维生素\", \"time\": \"15:30\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context, now: at(hour: 16))
        XCTAssertTrue(node.content.contains("♥ 已记：维生素 D 计划外补服"), node.content)
        let logs = HealthLogStore.fetchTodayLogs(context: context, profileId: pid, now: at(hour: 16))
        XCTAssertNil(logs.first?.scheduledAt)
    }

    func testMedOmittedTimeNearestUnlogged() {
        let med = seedMed(times: [480, 1260])
        // 20:00 说吃了：8:00 和 21:00 都没打过，21:00 距现在更近
        let node = seedNode(block("{\"type\": \"med\", \"name\": \"维生素\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context, now: at(hour: 20))
        XCTAssertTrue(node.content.contains("♥ 已打卡：维生素 D 21:00"), node.content)
        _ = med
    }

    func testMedAllLoggedBecomesExtra() {
        let med = seedMed(times: [480])
        let now = at(hour: 9)
        HealthLogStore.logIntake(context: context, profileId: pid, medication: med, minuteOfDay: 480, now: now)
        let node = seedNode(block("{\"type\": \"med\", \"name\": \"维生素\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context, now: now)
        XCTAssertTrue(node.content.contains("♥ 已记：维生素 D 计划外补服"), node.content)
    }

    func testMedDuplicateSlotNotRelogged() {
        let med = seedMed(times: [480])
        let now = at(hour: 9)
        HealthLogStore.logIntake(context: context, profileId: pid, medication: med, minuteOfDay: 480, now: now)
        let node = seedNode(block("{\"type\": \"med\", \"name\": \"维生素\", \"time\": \"8:00\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context, now: now)
        XCTAssertTrue(node.content.contains("♥ 维生素 D 8:00 已经打过卡了"), node.content)
        XCTAssertEqual(HealthLogStore.fetchTodayLogs(context: context, profileId: pid, now: now).count, 1, "不重复落")
    }

    // MARK: 其他

    func testUnknownType() {
        let n1 = seedNode(block("{\"type\": \"steps\", \"count\": 100}"))
        HealthLogIntentWriter.processChatIntents(nodeId: n1.id, context: context)
        XCTAssertTrue(n1.content.contains("♥ 记录格式无效"), n1.content)
    }

    // MARK: intimacy（第三刀接真落地，结果行文案克制）

    func testIntimacyLands() {
        let node = seedNode(block("{\"type\": \"intimacy\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context, now: at(hour: 12))
        XCTAssertTrue(node.content.contains("♥ 已记下了"), node.content)
        XCTAssertNotNil(HealthLogStore.fetchIntimacy(context: context, profileId: pid, date: at(hour: 12)))
    }

    func testIntimacyNoteStored() {
        let node = seedNode(block("{\"type\": \"intimacy\", \"note\": \"晚上\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context, now: at(hour: 12))
        XCTAssertTrue(node.content.contains("♥ 已记下了"), node.content)
        XCTAssertFalse(node.content.contains("晚上"), "结果行不复述 note")
        XCTAssertEqual(HealthLogStore.fetchIntimacy(context: context, profileId: pid, date: at(hour: 12))?.note, "晚上")
    }

    func testIntimacyBackdate() {
        let node = seedNode(block("{\"type\": \"intimacy\", \"date\": \"2026-07-01\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 已记下了（7 月 1 日）"), node.content)
    }

    func testIntimacyFutureDateRejected() {
        let node = seedNode(block("{\"type\": \"intimacy\", \"date\": \"2077-01-01\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 未来的日期记不了"), node.content)
        XCTAssertNil(HealthLogStore.fetchIntimacy(context: context, profileId: pid, date: Date()))
    }

    // MARK: cycle（第二刀接真落地）

    func testCycleLands() {
        let node = seedNode(block("{\"type\": \"cycle\", \"flow\": \"medium\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 已记：经期打点（中）"), node.content)
        XCTAssertEqual(HealthCycleStore.fetchDays(context: context, profileId: pid).count, 1)
    }

    func testCycleChineseFlowMapped() {
        let node = seedNode(block("{\"type\": \"cycle\", \"flow\": \"点滴\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 已记：经期打点（点滴）"), node.content)
        XCTAssertEqual(HealthCycleStore.fetchDays(context: context, profileId: pid).first?.flow, "spotting")
    }

    func testCycleInvalidFlow() {
        let node = seedNode(block("{\"type\": \"cycle\", \"flow\": \"洪水\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 记录格式无效"), node.content)
        XCTAssertTrue(HealthCycleStore.fetchDays(context: context, profileId: pid).isEmpty)
    }

    func testCycleBackdate() {
        let node = seedNode(block("{\"type\": \"cycle\", \"flow\": \"heavy\", \"date\": \"2026-07-01\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 已记：经期打点（多，7 月 1 日）"), node.content)
    }

    func testCycleFutureDateRejected() {
        let node = seedNode(block("{\"type\": \"cycle\", \"flow\": \"light\", \"date\": \"2077-01-01\"}"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 未来的日期记不了"), node.content)
        XCTAssertTrue(HealthCycleStore.fetchDays(context: context, profileId: pid).isEmpty)
    }

    func testMalformedJSON() {
        let node = seedNode(block("{not json"))
        HealthLogIntentWriter.processChatIntents(nodeId: node.id, context: context)
        XCTAssertTrue(node.content.contains("♥ 记录格式无效"), node.content)
    }

    func testParseMinute() {
        XCTAssertEqual(HealthLogIntentWriter.parseMinute("8:00"), 480)
        XCTAssertEqual(HealthLogIntentWriter.parseMinute("21:30"), 1290)
        XCTAssertNil(HealthLogIntentWriter.parseMinute("25:00"))
        XCTAssertNil(HealthLogIntentWriter.parseMinute("8点"))
    }
}
