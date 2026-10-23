import XCTest
@testable import 记忆花园

/// CR-7 P2：框选相交（OCRStore.selection）+ Note.rects 兼容。
final class PDFSelectionTests: XCTestCase {

    private func line(_ text: String, x: Double, y: Double, w: Double, h: Double) -> OCRStore.Line {
        OCRStore.Line(text: text, bbox: [x, y, w, h])
    }

    func testSelectionPicksIntersectingLinesInReadingOrder() {
        // PDF 原点左下：y 越大越靠上。三行竖排，框住上两行。
        let lines = [
            line("第三行", x: 50, y: 100, w: 200, h: 20),
            line("第一行", x: 50, y: 200, w: 200, h: 20),
            line("第二行", x: 50, y: 150, w: 200, h: 20),
        ]
        let sel = OCRStore.selection(from: lines, in: CGRect(x: 40, y: 140, width: 220, height: 100))
        XCTAssertEqual(sel?.quote, "第一行\n第二行", "按阅读序（y 降序）拼接")
        XCTAssertEqual(sel?.rects.count, 2)
        XCTAssertEqual(sel?.rects[0][1], 200, "rects 与 quote 同序")
    }

    func testSelectionSkipsBarelyTouchedLines() {
        // 只擦到 10% 且中心在框外 → 不收
        let lines = [
            line("正身", x: 50, y: 100, w: 200, h: 20),
            line("擦边", x: 50, y: 118, w: 200, h: 20),   // 框顶只盖到它底部 2pt
        ]
        let sel = OCRStore.selection(from: lines, in: CGRect(x: 40, y: 60, width: 220, height: 60))
        XCTAssertEqual(sel?.quote, "正身")
    }

    func testSelectionEmptyBoxReturnsNil() {
        let lines = [line("字", x: 50, y: 100, w: 200, h: 20)]
        XCTAssertNil(OCRStore.selection(from: lines, in: CGRect(x: 300, y: 300, width: 50, height: 50)))
        XCTAssertNil(OCRStore.selection(from: [], in: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }

    func testNoteDecodingWithoutRectsDefaultsNil() throws {
        let legacy = """
        [{"id":"n1","chapter":1,"anchorText":"a","anchorStart":0,"anchorEnd":1,
          "kind":"note","content":"c","role":"user","createdAt":"2026-01-01T00:00:00Z"}]
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let notes = try d.decode([BookStore.Note].self, from: Data(legacy.utf8))
        XCTAssertNil(notes[0].rects)
    }

    func testNoteRectsRoundTrip() throws {
        var note = BookStore.Note(
            id: "n2", chapter: 42, anchorText: "quote", anchorStart: 0, anchorEnd: 0,
            kind: "highlight", content: "", role: "user", messageId: nil, createdAt: Date())
        note.rects = [[10, 20, 100, 14], [10, 40, 80, 14]]
        let data = try JSONEncoder().encode(note)
        let back = try JSONDecoder().decode(BookStore.Note.self, from: data)
        XCTAssertEqual(back.rects?.count, 2)
        XCTAssertEqual(back.rects?[1], [10, 40, 80, 14])
    }
}
