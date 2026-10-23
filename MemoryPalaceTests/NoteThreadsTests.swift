import XCTest
@testable import 记忆花园

final class NoteThreadsTests: XCTestCase {
    typealias Note = BookStore.Note

    private func note(_ id: String, _ s: Int = 0, _ e: Int = 4, kind: String = "highlight", content: String = "",
                      role: String = "user", t: TimeInterval, replyTo: String? = nil) -> Note {
        Note(id: id, chapter: 1, anchorText: "abcd", anchorStart: s, anchorEnd: e, kind: kind, content: content,
             role: role, messageId: nil, createdAt: Date(timeIntervalSince1970: t), replyTo: replyTo)
    }

    func testIdenticalRangeIsOnePlaceHungOnEarliest() {
        let notes = [note("b", t: 2), note("a", t: 1), note("c", 1, 4, t: 3)]
        let places = NoteThreads.places(for: ["b", "a", "c"], in: notes)
        XCTAssertEqual(places.map(\.id), ["a", "c"])
        XCTAssertEqual(places[0].strokes.map(\.id), ["a", "b"])
    }

    func testReplyResolvesToItsPlace() {
        let notes = [note("a", t: 1), note("b", t: 2), note("r", kind: "note", content: "x", t: 3, replyTo: "b")]
        XCTAssertEqual(NoteThreads.place(of: "r", in: notes)?.id, "a")
        XCTAssertEqual(NoteThreads.entries(of: NoteThreads.place(of: "a", in: notes)!, in: notes).map(\.id), ["r"])
    }

    func testAddEntryFillsBareHighlightThenReplies() {
        var notes = [note("a", t: 1)]
        let p = NoteThreads.place(of: "a", in: notes)!
        XCTAssertEqual(NoteThreads.addEntry("第一次", to: p, in: &notes, now: Date(timeIntervalSince1970: 5)), "a")
        XCTAssertEqual(notes[0].kind, "note")
        let id2 = NoteThreads.addEntry("重读", to: NoteThreads.place(of: "a", in: notes)!, in: &notes, now: Date(timeIntervalSince1970: 9))
        XCTAssertNotEqual(id2, "a")
        XCTAssertEqual(NoteThreads.entries(of: NoteThreads.place(of: "a", in: notes)!, in: notes).map(\.content), ["第一次", "重读"])
    }

    func testDeleteRootKeepsStrokeAndReplies() {
        var notes = [note("a", kind: "note", content: "根", t: 1), note("r", kind: "note", content: "回", t: 2, replyTo: "a")]
        NoteThreads.deleteEntry("a", in: &notes)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].content, "")
        XCTAssertEqual(notes[0].kind, "highlight")
        XCTAssertEqual(NoteThreads.entries(of: NoteThreads.place(of: "a", in: notes)!, in: notes).map(\.id), ["r"])
    }

    func testDeleteReplyNeverCascades() {
        var notes = [note("a", t: 1), note("r1", kind: "note", content: "1", t: 2, replyTo: "a"),
                     note("r2", kind: "note", content: "2", t: 3, replyTo: "a")]
        NoteThreads.deleteEntry("r1", in: &notes)
        XCTAssertEqual(notes.map(\.id), ["a", "r2"])
    }

    func testRemoveStrokeHandsThreadToNextStroke() {
        var notes = [note("a", kind: "note", content: "写过", t: 1), note("b", t: 2),
                     note("r", kind: "note", content: "回", t: 3, replyTo: "a")]
        NoteThreads.removeStroke("a", in: &notes)
        let p = NoteThreads.place(of: "b", in: notes)!
        XCTAssertEqual(p.strokes.map(\.id), ["b"])
        XCTAssertEqual(NoteThreads.entries(of: p, in: notes).map(\.content), ["写过", "回"])
    }

    func testRemovePlaceKeepsAIWriting() {
        var notes = [note("a", t: 1), note("u", kind: "note", content: "我", t: 2, replyTo: "a"),
                     note("ai", kind: "note", content: "AI", role: "ai", t: 3, replyTo: "a")]
        NoteThreads.removePlace(NoteThreads.place(of: "a", in: notes)!, in: &notes)
        XCTAssertEqual(notes.map(\.id), ["ai"])
        XCTAssertNil(notes[0].replyTo)
    }

    /// 落盘时间只到秒：同一秒写的几条重读后并列，按写入先后排，不按随机 id
    func testSameSecondKeepsWriteOrder() {
        let notes = [note("z", kind: "note", content: "先", t: 1), note("m", t: 1),
                     note("a", kind: "note", content: "后", t: 1, replyTo: "z")]
        let p = NoteThreads.place(of: "z", in: notes)!
        XCTAssertEqual(p.strokes.map(\.id), ["z", "m"])
        XCTAssertEqual(NoteThreads.entries(of: p, in: notes).map(\.content), ["先", "后"])
    }

    func testSummaryCountsWholeThread() {
        let notes = [note("a", kind: "note", content: "一", t: 1), note("r", kind: "note", content: "二", t: 2, replyTo: "a")]
        let s = NoteThreads.summary(of: NoteThreads.place(of: "a", in: notes)!, in: notes)
        XCTAssertEqual(s.latest, "二")
        XCTAssertEqual(s.count, 2)
    }
}
