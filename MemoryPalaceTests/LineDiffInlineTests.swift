import XCTest
@testable import 记忆花园

/// 版本 diff 页：行内（词级）高亮 + 折叠没变的段
final class LineDiffInlineTests: XCTestCase {
    private func highlighted(_ old: String, _ new: String) -> [(LineDiff.Line, [String])] {
        let lines = LineDiff.compute(old: old, new: new).lines
        let marks = LineDiff.inlineHighlights(lines)
        return zip(lines, marks).map { line, ranges in
            let characters = Array(line.text)
            return (line, ranges.map { String(characters[$0]) })
        }
    }

    // MARK: - 行内高亮

    func testChineseInsertOnlyMarksInsertedCharacters() {
        let rows = highlighted("今天天气很好，适合出门。\n", "今天天气真的很好，适合出门。\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].0.change, .removed)
        XCTAssertEqual(rows[0].1, [])
        XCTAssertEqual(rows[1].0.change, .added)
        XCTAssertEqual(rows[1].1, ["真的"])
    }

    func testChineseReplaceMarksBothSides() {
        let rows = highlighted("我今天很开心地去了公园散步\n", "我今天很难过地去了公园散步\n")
        XCTAssertEqual(rows[0].1, ["开心"])
        XCTAssertEqual(rows[1].1, ["难过"])
    }

    /// 粟粟截图那种：一行中间插了几个字并多出一个换行，一行变两行
    func testInsertWithNewlineSplitsLine() {
        let old = "第一行不动\n春天的花开了，夏天的雨来了，秋天的叶子落了。\n最后一行\n"
        let new = "第一行不动\n春天的花开了，mi mimi m\n夏天的雨来了，秋天的叶子落了。\n最后一行\n"
        let rows = highlighted(old, new)
        let changed = rows.filter { $0.0.change != .unchanged }
        XCTAssertEqual(changed.map(\.0.change), [.removed, .added, .added])
        XCTAssertEqual(changed[0].1, [], "旧行一个字没删，不该有深色")
        XCTAssertEqual(changed[1].1, ["mi mimi m"])
        XCTAssertEqual(changed[2].1, [], "换行本身不画，下一行全是原字")
    }

    func testEnglishMarksWholeWord() {
        let rows = highlighted("hello world, nice day\n", "hello word, nice day\n")
        XCTAssertEqual(rows[0].1, ["world"])
        XCTAssertEqual(rows[1].1, ["word"])
    }

    func testPureAddAndPureRemoveHaveNoInlineMarks() {
        let added = LineDiff.compute(old: "a\nb\n", new: "a\nnew line\nb\n").lines
        XCTAssertTrue(LineDiff.inlineHighlights(added).allSatisfy(\.isEmpty))
        let removed = LineDiff.compute(old: "a\nold line\nb\n", new: "a\nb\n").lines
        XCTAssertTrue(LineDiff.inlineHighlights(removed).allSatisfy(\.isEmpty))
    }

    func testRewriteFallsBackToWholeLine() {
        let rows = highlighted("今天去公园散步\n", "明年要学钢琴课\n")
        XCTAssertEqual(rows.map(\.1), [[], []])
    }

    func testOversizedMiddleFallsBackToWholeLine() {
        let old = String(repeating: "甲乙丙丁", count: 1000) + "\n"
        let new = String(repeating: "丁丙乙甲", count: 1000) + "\n"
        let lines = LineDiff.compute(old: old, new: new).lines
        let started = Date()
        XCTAssertTrue(LineDiff.inlineHighlights(lines).allSatisfy(\.isEmpty))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testLongParagraphSmallEditStillHighlighted() {
        let body = String(repeating: "这是一段很长的正文。", count: 800)
        let rows = highlighted(body + "结尾\n", body + "新的结尾\n")
        XCTAssertEqual(rows[1].1, ["新的"])
    }

    func testShortCommonFragmentsMergeIntoOneMark() {
        // 中间零星撞上的同字不该把高亮切成碎片：夏秋冬 → 花秋月 是一整块，不是「夏」「冬」两块
        let rows = highlighted("前面，春夏秋冬，后面\n", "前面，春花秋月，后面\n")
        XCTAssertEqual(rows[0].1, ["夏秋冬"])
        XCTAssertEqual(rows[1].1, ["花秋月"])
    }

    // MARK: - 折叠

    func testFoldKeepsThreeLinesOfContext() {
        let old = (1...20).map { "行\($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "行10\n", with: "行十\n")
        let lines = LineDiff.compute(old: old, new: new).lines
        XCTAssertEqual(lines.count, 21)
        // 0…5 没变（6 行），6…8 上文，9 删 10 增，11…13 下文，14…20 没变
        XCTAssertEqual(LineDiff.segments(lines), [.folded(0..<6), .shown(6..<14), .folded(14..<21)])
    }

    func testSingleHiddenLineIsNotFolded() {
        let old = (1...5).map { "行\($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "行5\n", with: "行五\n")
        let lines = LineDiff.compute(old: old, new: new).lines
        XCTAssertEqual(LineDiff.segments(lines), [.shown(0..<6)])
    }

    func testFoldBetweenTwoChanges() {
        let old = (1...20).map { "行\($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "行1\n", with: "行一\n")
            .replacingOccurrences(of: "行20\n", with: "行二十\n")
        let lines = LineDiff.compute(old: old, new: new).lines
        // 0 删 1 增，2…4 下文，5…16 没变，17…19 上文，20 删 21 增
        XCTAssertEqual(lines.count, 22)
        XCTAssertEqual(LineDiff.segments(lines), [.shown(0..<5), .folded(5..<17), .shown(17..<22)])
    }

    func testNoChangesFoldsEverything() {
        let text = "a\nb\nc\n"
        let lines = LineDiff.compute(old: text, new: text).lines
        XCTAssertEqual(LineDiff.segments(lines), [.folded(0..<3)])
        XCTAssertEqual(LineDiff.segments([]), [])
    }
}
