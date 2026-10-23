import XCTest
@testable import 记忆花园

/// 复习卡文件存储：cards.json 原子写 roundtrip + review-log.jsonl append。
/// 全部注入 tmp 目录，tearDown 清理。
final class VocabCardStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-vocab-cards-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testSaveLoadRoundtrip() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var card = VocabCard(word: "ephemeral", source: "manual", now: now)
        card.reps = 3
        card.intervalDays = 7.5
        card.lastReviewedAt = now
        VocabCardStore.save([card], dir: dir)
        let loaded = VocabCardStore.load(dir: dir)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].word, "ephemeral")
        XCTAssertEqual(loaded[0].reps, 3)
        XCTAssertEqual(loaded[0].intervalDays, 7.5)
        XCTAssertNotNil(loaded[0].lastReviewedAt)
    }

    func testLoadMissingFileReturnsEmpty() {
        XCTAssertEqual(VocabCardStore.load(dir: dir), [])
    }

    func testLoadCorruptJSONReturnsEmpty() {
        try? "not json{{".data(using: .utf8)?
            .write(to: dir.appendingPathComponent("cards.json"))
        XCTAssertEqual(VocabCardStore.load(dir: dir), [])
    }

    func testAppendLogTwoLines() throws {
        let e1 = VocabReviewLogEntry(word: "a", ts: Date(), exercise: "read", rating: "good", intervalBefore: 0)
        let e2 = VocabReviewLogEntry(word: "b", ts: Date(), exercise: "spell", rating: "again", intervalBefore: 3)
        VocabCardStore.appendLog(e1, dir: dir)
        VocabCardStore.appendLog(e2, dir: dir)
        let content = try String(contentsOf: dir.appendingPathComponent("review-log.jsonl"), encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"read\""))
        XCTAssertTrue(lines[1].contains("\"again\""))
    }

    func testAddIfAbsent() {
        XCTAssertTrue(VocabCardStore.addIfAbsent(word: "reading-word", source: "reading", dir: dir))
        XCTAssertFalse(VocabCardStore.addIfAbsent(word: "reading-word", source: "notebook", dir: dir), "重复 false")
        let cards = VocabCardStore.load(dir: dir)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].source, "reading", "首个来源保留")
    }

    func testSM2Mapping() {
        var card = VocabCard(word: "x", source: "manual", now: Date())
        XCTAssertEqual(card.sm2, SM2State(ease: 2.5, intervalDays: 0, reps: 0, lapses: 0))
        card.sm2 = SM2State(ease: 1.9, intervalDays: 12, reps: 4, lapses: 2)
        XCTAssertEqual(card.ease, 1.9)
        XCTAssertEqual(card.intervalDays, 12)
        XCTAssertEqual(card.reps, 4)
        XCTAssertEqual(card.lapses, 2)
    }
}
