import MemoryCore
import XCTest
@testable import 记忆花园

/// v5 §八：注入只带「没做完」；c2c3-v2 第 7 段起待续单独一段（「- 《窗口》：a；b」），不跟在时间轴条目后面；
/// 没迁移的楼层照读老条目里的老字段
final class PendingInjectionTests: XCTestCase {

    private func entry(_ conv: String, hour: Int, pending: String) -> TimelineEntry {
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: hour))!
        return TimelineEntry(start: start, end: start.addingTimeInterval(600), conversationId: conv, title: "T\(conv)",
                             text: "- 话题\(hour)", pending: pending, day: "2026-10-14", lastNodeId: "n\(hour)")
    }

    private func text(_ list: [TimelineEntry], _ open: [String: [String]]?) -> String {
        TimelineStore.injection(records: [:], entries: ["2026-10-14": list], today: "2026-10-14", currentConversationId: "",
                                windowIds: [], openPending: open).text ?? ""
    }

    func testNotMigratedReadsOldField() {
        let t = text([entry("c1", hour: 9, pending: "早上的"), entry("c1", hour: 11, pending: "a\nb")], nil)
        XCTAssertTrue(t.contains("[待续]") && t.contains("- 《Tc1》conv c1：a；b"), t)
        XCTAssertFalse(t.contains("早上的"), "只取最新那条")
    }

    func testMigratedReadsOpenFromStore() {
        let t = text([entry("c1", hour: 9, pending: ""), entry("c2", hour: 10, pending: "老字段")], ["c1": ["问结果", "买药"]])
        XCTAssertTrue(t.contains("- 《Tc1》conv c1：问结果；买药"), t)
        XCTAssertFalse(t.contains("老字段"), "迁移过就不读条目里的老字段")
        XCTAssertTrue(t.contains("话题9"), "条目照带")
    }

    /// astra #5：迁移过但缓存没热（空的）→ 这一轮谁都不带待续，不回退到老字段
    func testMigratedButColdBringsNothing() {
        let t = text([entry("c1", hour: 9, pending: "早就做完的")], [:])
        XCTAssertFalse(t.contains("待续"), t)
    }
}
