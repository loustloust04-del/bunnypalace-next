import XCTest
@testable import 记忆花园

/// 编辑旧消息带上原附件（docs/plan-edit-attachments.md）
final class EditAttachmentRestoreTests: XCTestCase {

    typealias B = ChatAttachmentPromptBuilder

    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
    let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7, 8])

    func image(_ name: String, _ data: Data) -> PendingChatAttachment {
        try! .image(name: name, typeDescription: "图片", mimeType: "image/jpeg", data: data)
    }

    func file(_ name: String, type: String = "文本", text: String, bytes: Data? = Data("raw".utf8)) -> PendingChatAttachment {
        .text(name: name, typeDescription: type, extractedText: text, byteCount: text.utf8.count, fileData: bytes, fileMime: "text/plain")
    }

    let todo = ChatCard.todo(TodoCard(id: "t-1", title: "买菜", items: [.init(text: "葱", done: false)]))

    // MARK: - R4：userMessage 与旧 sendMessage 逐字相同

    /// 旧 sendMessage（2410–2414 + 2437 + 2446）的原公式，照抄当锁
    func legacy(_ base: String, _ atts: [PendingChatAttachment]) -> (String, String, String, [MessageSegment]?) {
        let displayText = B.appendingCards(to: base, from: atts)
        let nonCards = atts.filter { $0.kind != .card }
        let modelText = B.modelInput(text: displayText, attachments: nonCards)
        return (displayText, modelText, nonCards.isEmpty ? "text" : "segmented",
                nonCards.isEmpty ? nil : B.segments(text: displayText, attachments: nonCards))
    }

    func assertMatchesLegacy(_ base: String, _ atts: [PendingChatAttachment], file: StaticString = #filePath, line: UInt = #line) {
        let parts = B.userMessage(displayBase: base, attachments: atts)
        let old = legacy(base, atts)
        XCTAssertEqual(parts.displayText, old.0, file: file, line: line)
        XCTAssertEqual(parts.modelText, old.1, file: file, line: line)
        XCTAssertEqual(parts.contentType, old.2, file: file, line: line)
        XCTAssertEqual(parts.segments, old.3, file: file, line: line)
    }

    func testUserMessageMatchesLegacyPlainText() {
        assertMatchesLegacy("你好", [])
        XCTAssertEqual(B.userMessage(displayBase: "你好", attachments: []).modelText, "你好")
    }

    func testUserMessageMatchesLegacyCardOnly() {
        assertMatchesLegacy("", [.card(todo)])
        let parts = B.userMessage(displayBase: "", attachments: [.card(todo)])
        XCTAssertEqual(parts.contentType, "text")
        XCTAssertNil(parts.segments)
        XCTAssertEqual(parts.modelText, todo.blockText)
    }

    func testUserMessageMatchesLegacyImageCardFile() {
        let atts = [image("a.jpg", jpg), .card(todo), file("n.txt", text: "内容")]
        assertMatchesLegacy("看看", atts)
        let parts = B.userMessage(displayBase: "看看", attachments: atts)
        XCTAssertEqual(parts.modelText, "看看\n\n\(todo.blockText)\n\n[图片附件：a.jpg · 图片]\n\n[附件：n.txt · 文本]\n内容\n[/附件]")
        XCTAssertEqual(parts.contentType, "segmented")
    }

    // MARK: - restore（read / extract 用替身）

    func restore(_ parts: ChatAttachmentPromptBuilder.UserMessageParts, segments: [MessageSegment]? = nil,
                 replyToId: String? = nil, replyQuote: String? = nil,
                 disk: [String: Data] = [:], extract: [String: PendingChatAttachment] = [:]) -> B.RestoredComposer {
        B.restore(content: parts.modelText, segments: segments ?? parts.segments,
                  replyToId: replyToId, replyQuote: replyQuote,
                  read: { disk[$0] }, extract: { extract[$0] })
    }

    func testRestorePlainText() {
        let r = restore(B.userMessage(displayBase: "你好\n第二行", attachments: []))
        XCTAssertEqual(r.text, "你好\n第二行")
        XCTAssertTrue(r.attachments.isEmpty)
        XCTAssertEqual(r.missingCount, 0)
    }

    func testRestoreImagesAndTextHasNoShells() {
        let r = restore(B.userMessage(displayBase: "看这两张", attachments: [image("a.jpg", jpg), image("b.png", png)]))
        XCTAssertEqual(r.text, "看这两张")
        XCTAssertEqual(r.attachments.map(\.name), ["a.jpg", "b.png"])
        XCTAssertEqual(r.attachments.map(\.imageData), [jpg, png])
        XCTAssertFalse(r.text.contains("[图片附件"))
    }

    /// E1：类型描述是「文本」、段里只存 MIME——类型和 > 4000 字的全文都从壳里拿回
    func testRestoreFileTypeAndFullTextFromShell() {
        let long = String(repeating: "长", count: 5000)
        let r = restore(B.userMessage(displayBase: "读一下", attachments: [file("n.txt", type: "文本", text: long)]))
        XCTAssertEqual(r.text, "读一下")
        let f = try! XCTUnwrap(r.attachments.first)
        XCTAssertEqual(f.name, "n.txt")
        XCTAssertEqual(f.typeDescription, "文本")
        XCTAssertEqual(f.extractedText, long)
        XCTAssertEqual(f.fileData, Data("raw".utf8))
    }

    /// E3：两个同名同类型不同内容的文件按顺序各拿各的；全文里自带 `\n[/附件]` 不截断
    func testRestoreSameNameFilesInOrderAndEmbeddedCloseMarker() {
        let tricky = "前\n[/附件]\n后"
        let atts = [file("x.txt", text: tricky, bytes: Data("1".utf8)), file("x.txt", text: "第二份", bytes: Data("2".utf8))]
        let r = restore(B.userMessage(displayBase: "", attachments: atts))
        XCTAssertEqual(r.attachments.map(\.extractedText), [tricky, "第二份"])
        XCTAssertEqual(r.attachments.map(\.fileData), [Data("1".utf8), Data("2".utf8)])
    }

    /// 她自己打的字里有假壳：从正文后面开始找，不被骗
    func testRestoreIgnoresFakeShellInTypedText() {
        let base = "[附件：n.txt · 文本]\n假的\n[/附件]"
        let r = restore(B.userMessage(displayBase: base, attachments: [file("n.txt", text: "真的")]))
        XCTAssertEqual(r.text, base)
        XCTAssertEqual(r.attachments.first?.extractedText, "真的")
    }

    func testRestoreStandardCardBecomesChip() {
        let r = restore(B.userMessage(displayBase: "记一下", attachments: [.card(todo), image("a.jpg", jpg)]))
        XCTAssertEqual(r.text, "记一下")
        XCTAssertEqual(r.attachments.map(\.kind), [.image, .card])
        XCTAssertEqual(r.attachments.last?.chatCard, todo)
    }

    /// E2：手打的非规范卡片块原样找不到 → 留在文字里、不建 chip，重发不会多一份
    func testRestoreNonCanonicalCardStaysInText() {
        let typed = "```card-todo\n{}\n```"
        XCTAssertFalse(ChatCardExtractor.cards(in: typed).isEmpty, "前提：这块能解析成卡")
        let r = restore(B.userMessage(displayBase: typed, attachments: []))
        XCTAssertEqual(r.text, typed)
        XCTAssertTrue(r.attachments.isEmpty)
    }

    func testRestoreImageRefReadsDiskAndKeepsRef() {
        let segs: [MessageSegment] = [.imageRef(name: "a.jpg", type: "图片", path: "attachments/x/a.jpg"), .text("hi")]
        let r = restore(B.userMessage(displayBase: "hi", attachments: []), segments: segs, disk: ["attachments/x/a.jpg": jpg])
        XCTAssertEqual(r.attachments.first?.imageData, jpg)
        XCTAssertEqual(r.attachments.first?.storedRef, "attachments/x/a.jpg")
        XCTAssertEqual(r.missingCount, 0)
    }

    func testRestoreMissingRefAndLegacyFileCountAsMissing() {
        let segs: [MessageSegment] = [.imageRef(name: "a.jpg", type: nil, path: "gone"), .text("hi"),
                                      .file(name: "old.pdf", uuid: "u1"), .fileDataRef(name: "f.bin", mime: "application/octet-stream", path: "gone2")]
        let r = restore(B.userMessage(displayBase: "hi", attachments: []), segments: segs)
        XCTAssertEqual(r.missingCount, 3)
        XCTAssertTrue(r.attachments.isEmpty)
        XCTAssertEqual(r.text, "hi")
    }

    /// 壳对不上（例如导入数据）→ 用磁盘原文件重抽
    func testRestoreFileRefFallsBackToExtract() {
        let segs: [MessageSegment] = [.text("hi"), .fileDataRef(name: "r.md", mime: "text/markdown", path: "p/r.md")]
        let extracted = PendingChatAttachment.text(name: "r.md", typeDescription: "Markdown", extractedText: "# 标题", byteCount: 8)
        let r = restore(B.userMessage(displayBase: "hi", attachments: []), segments: segs,
                        disk: ["p/r.md": Data("# 标题".utf8)], extract: ["p/r.md": extracted])
        let f = try! XCTUnwrap(r.attachments.first)
        XCTAssertEqual(f.typeDescription, "Markdown")
        XCTAssertEqual(f.extractedText, "# 标题")
        XCTAssertEqual(f.storedRef, "p/r.md")
    }

    func testRestoreQuoteNeedsBothFields() {
        let parts = B.userMessage(displayBase: "hi", attachments: [])
        XCTAssertEqual(restore(parts, replyToId: "n1", replyQuote: "原话").quoteReplyTo, "n1")
        XCTAssertNil(restore(parts, replyToId: "n1", replyQuote: nil).quoteReplyTo)
        XCTAssertNil(restore(parts, replyToId: nil, replyQuote: "原话").quotePreview)
    }

    /// R2：没动过的原图写回时仍是同一个 ref 段，不会变成要重新落盘 / 压缩的内联图
    func testStoredRefWritesBackAsRef() {
        var att = image("a.jpg", jpg)
        att.storedRef = "attachments/x/a.jpg"
        let segs = B.segments(text: "hi", attachments: [att])
        XCTAssertEqual(segs.first, .imageRef(name: "a.jpg", type: "图片", path: "attachments/x/a.jpg"))
        XCTAssertFalse(segs.contains { if case .image = $0 { return true } else { return false } })
    }
}
