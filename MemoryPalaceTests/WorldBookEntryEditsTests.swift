import XCTest
@testable import 记忆花园

/// 世界书面板搜索：过滤后行序≠原下标，改 / 开关 / 删必须按条目 id 落回原位置
final class WorldBookEntryEditsTests: XCTestCase {

    private func entry(_ comment: String, content: String = "", keys: [String] = []) -> WorldBookEntry {
        var e = WorldBookEntry()
        e.comment = comment
        e.content = content
        e.keys = keys
        return e
    }

    private lazy var entries: [WorldBookEntry] = [
        entry("甲", content: "无关"),
        entry("乙", content: "有苹果"),
        entry("丙"),
        entry("丁", keys: ["苹果树"]),
    ]

    func testVisibleFiltersByCommentContentKeysAndBookName() {
        let hits = WorldBookEntryEdits.visible(entries, keyword: "苹果", bookName: "书")
        XCTAssertEqual(hits.map(\.comment), ["乙", "丁"])
        XCTAssertEqual(WorldBookEntryEdits.visible(entries, keyword: nil, bookName: "书").count, 4)
        XCTAssertEqual(WorldBookEntryEdits.visible(entries, keyword: "书", bookName: "设定书").count, 4)
        var secondary = entry("戊")
        secondary.secondaryKeys = ["苹果"]
        XCTAssertTrue(WorldBookEntryEdits.matches(secondary, keyword: "苹果", bookName: "书"))
    }

    func testToggleFilteredRowHitsOriginalEntry() {
        let hits = WorldBookEntryEdits.visible(entries, keyword: "苹果", bookName: "书")
        // 过滤后第 0 行是原第 1 条「乙」；按过滤序号改会改到「甲」
        let out = WorldBookEntryEdits.settingEnabled(entries, id: hits[0].id, false)
        XCTAssertEqual(out?.map(\.isEnabled), [true, false, true, true])
    }

    func testRemoveFilteredRowRemovesOriginalEntry() {
        let hits = WorldBookEntryEdits.visible(entries, keyword: "苹果", bookName: "书")
        let out = WorldBookEntryEdits.removing(entries, id: hits[1].id)
        XCTAssertEqual(out?.map(\.comment), ["甲", "乙", "丙"])
    }

    func testReplaceFilteredRowReplacesOriginalEntry() {
        let hits = WorldBookEntryEdits.visible(entries, keyword: "苹果", bookName: "书")
        var edited = hits[1]
        edited.content = "改过"
        let out = WorldBookEntryEdits.replacing(entries, with: edited)
        XCTAssertEqual(out?.map(\.content), ["无关", "有苹果", "", "改过"])
    }

    func testUnknownIdIsNoOp() {
        XCTAssertNil(WorldBookEntryEdits.settingEnabled(entries, id: UUID(), false))
        XCTAssertNil(WorldBookEntryEdits.removing(entries, id: UUID()))
        XCTAssertNil(WorldBookEntryEdits.replacing(entries, with: WorldBookEntry()))
    }
}
