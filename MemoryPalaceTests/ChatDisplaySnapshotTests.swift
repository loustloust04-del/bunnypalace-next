import XCTest
@testable import 记忆花园

/// L4 A3：共享显示数据快照与原每泡写法等价（正则 / 引用预览 / segments 缓存失效）
final class ChatDisplaySnapshotTests: XCTestCase {

    private func node(_ id: String, _ content: String = "", cc: String? = nil, replyTo: String? = nil, quote: String? = nil) -> MessageNode {
        let n = MessageNode(id: id, role: "user", content: content, contentType: "text", createTime: nil,
                            parentId: nil, childrenIds: [], conversationId: "c")
        n.ccMessageId = cc
        n.replyToId = replyTo
        n.replyQuote = quote
        return n
    }

    private func rule(_ id: String) -> RegexScript {
        var s = RegexScript()
        s.id = id
        s.scriptName = id
        s.findRegex = "/X/g"
        s.markdownOnly = true
        return s
    }

    func testRegexScriptsMatchPipeline() {
        var p = Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚")
        p.regexScripts = [rule("old")]
        var pre = Preset(name: "t")
        pre.regexScripts = [rule("p1")]
        let snap = ChatDisplaySnapshot(path: [], profile: p, preset: pre, cards: [])
        XCTAssertEqual(snap.regexScripts, RegexPipeline.scripts(profile: p, preset: pre, cards: []))
        XCTAssertEqual(ChatDisplaySnapshot(path: [], profile: nil, preset: pre, cards: []).regexScripts, [])
    }

    /// 原写法：选段优先；否则 `first(where: id == rid || ccMessageId == rid)` 截前 50 字
    private func legacyQuoted(_ n: MessageNode, path: [MessageNode]) -> String? {
        if let rq = n.replyQuote, !rq.isEmpty { return String(rq.prefix(50)) }
        guard let rid = n.replyToId, let t = path.first(where: { $0.id == rid || $0.ccMessageId == rid }) else { return nil }
        let s = t.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(50))
    }

    func testQuotedPreviewMatchesLegacyLookup() {
        let long = String(repeating: "长", count: 80)
        let a = node("a", "  第一条  ", cc: "s_b")       // ccMessageId 撞上后面某条的 id：先到先得
        let b = node("s_b", "第二条")
        let c = node("c", long, cc: "s_c")
        let d = node("d", "   ")
        let path = [a, b, c, d]
        let readers = [
            node("r1", replyTo: "s_b"), node("r2", replyTo: "s_c"), node("r3", replyTo: "c"),
            node("r4", replyTo: "d"), node("r5", replyTo: "missing"), node("r6", replyTo: "a", quote: "选段原文"),
            node("r7"),
        ]
        let snap = ChatDisplaySnapshot(path: path, profile: nil, preset: nil, cards: [])
        for r in readers {
            XCTAssertEqual(snap.quotedPreview(for: r), legacyQuoted(r, path: path), r.id)
        }
        XCTAssertEqual(snap.quotedPreview(for: readers[0]), "第一条")
        XCTAssertEqual(snap.quotedPreview(for: readers[1])?.count, 50)
        // 被引用消息改了内容：同一快照里也读到新文字（预览不进索引）
        b.content = "改过"
        XCTAssertEqual(snap.quotedPreview(for: node("r8", replyTo: "s_b")), "第一条")
        a.content = "改过的第一条"
        XCTAssertEqual(snap.quotedPreview(for: readers[0]), "改过的第一条")
    }

    func testSegmentsCacheInvalidatesOnDataChange() throws {
        let n = node("seg-\(UUID().uuidString)")
        XCTAssertNil(ChatDisplaySnapshot.segments(of: n, enabled: true))
        n.segmentsData = try JSONEncoder().encode([MessageSegment.text("甲乙")])
        XCTAssertEqual(ChatDisplaySnapshot.segments(of: n, enabled: true), [.text("甲乙")])
        XCTAssertEqual(ChatDisplaySnapshot.segments(of: n, enabled: true), n.segments)
        // 同长度改写也要失效（不用指纹）
        n.segmentsData = try JSONEncoder().encode([MessageSegment.text("丙丁")])
        XCTAssertEqual(ChatDisplaySnapshot.segments(of: n, enabled: true), [.text("丙丁")])
        n.segmentsData = nil
        XCTAssertNil(ChatDisplaySnapshot.segments(of: n, enabled: true))
        n.segmentsData = try JSONEncoder().encode([MessageSegment.text("戊")])
        XCTAssertEqual(ChatDisplaySnapshot.segments(of: n, enabled: false), [.text("戊")])
    }
}
