import XCTest
@testable import 记忆花园

/// #047：Gemini Takeout（My Activity → Gemini Apps）解析。全部合成样本，结构依据 docs/research-import-gemini.md §1.1–1.2，
/// 不是 Google 真实导出。
final class GeminiTakeoutParserTests: XCTestCase {

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func record(_ title: String?, time: String?, html: [String] = [], url: String? = nil,
                        subtitles: [String] = [], header: String = "Gemini Apps", extra: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = ["header": header, "products": [header]]
        if let title { r["title"] = title }
        if let time { r["time"] = time }
        if !html.isEmpty { r["safeHtmlItem"] = html.map { ["html": $0] } }
        if let url { r["details"] = [["name": "Conversation", "url": url]] }
        if !subtitles.isEmpty { r["subtitles"] = subtitles.map { ["name": "Prompt", "value": $0] } }
        for (k, v) in extra { r[k] = v }
        return r
    }

    private func parse(_ records: [[String: Any]]) throws -> GeminiImportResult {
        let data = try JSONSerialization.data(withJSONObject: records)
        return try GeminiTakeoutParser.parseJSON(data: data, calendar: utc)
    }

    private func segments(_ node: ImportedNodePayload) throws -> [MessageSegment] {
        try JSONDecoder().decode([MessageSegment].self, from: XCTUnwrap(node.segmentsData))
    }

    // MARK: - 识别

    func testDetection() {
        XCTAssertTrue(GeminiTakeoutParser.isTakeoutJSON([record("Prompted hi", time: "2026-01-02T03:04:05Z")]))
        XCTAssertFalse(GeminiTakeoutParser.isTakeoutJSON([record("Searched for x", time: "2026-01-02T03:04:05Z", header: "Search")]))
        XCTAssertFalse(GeminiTakeoutParser.isTakeoutJSON([[String: Any]]()))
        XCTAssertFalse(GeminiTakeoutParser.isTakeoutJSON(["chunkedPrompt": ["chunks": []]]))
        XCTAssertThrowsError(try GeminiTakeoutParser.parseJSON(data: Data("[{\"mapping\":{},\"id\":\"x\"}]".utf8)))
    }

    func testDuplicateActivityKeysCountedPerConversation() throws {
        let same = { (chat: String) in self.record("Prompted 一样", time: "2026-01-01T10:00:00Z", html: ["<p>一样</p>"],
                                                url: "https://gemini.google.com/app/\(chat)") }
        let both = try parse([same("c1"), same("c2")])
        let onlyC2 = try parse([same("c2")])
        let idsBoth = Set(try XCTUnwrap(both.payloads.first { $0.id == "c2@gemini" }).nodes.map(\.id))
        let idsOnly = Set(try XCTUnwrap(onlyC2.payloads.first).nodes.map(\.id))
        XCTAssertEqual(idsBoth, idsOnly, "删掉别的会话，这段的消息 id 不变")
    }

    func testConversationIdsDifferInFirstEightChars() throws {
        let r = try parse([
            record("Prompted 一", time: "2026-01-01T10:00:00Z", html: ["<p>1</p>"], url: "https://gemini.google.com/app/aaaa1111"),
            record("Prompted 二", time: "2026-01-01T10:00:00Z", html: ["<p>2</p>"], url: "https://gemini.google.com/app/aaaa2222"),
            record("Prompted 三", time: "2026-01-02T10:00:00Z", html: ["<p>3</p>"]),
            record("Prompted 四", time: "2026-01-03T10:00:00Z", html: ["<p>4</p>"]),
        ])
        XCTAssertEqual(r.payloads.count, 4)
        // 附件目录按对话 id 前 8 位分、硬删也按它删（AttachmentStore）：固定前缀会让多段对话共用、一删全删
        XCTAssertEqual(Set(r.payloads.map { $0.id.prefix(8) }).count, 4, "\(r.payloads.map(\.id))")
    }

    // MARK: - 单条活动

    func testPromptedTitleAndResponse() throws {
        let r = try parse([record("Prompted 你好，解释 1 + 1", time: "2026-01-02T03:04:05.123456Z",
                                  html: ["<p>答案是 <strong>2</strong>。</p>", "<p>补充</p>"])])
        XCTAssertEqual(r.payloads.count, 1)
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(p.provider, "gemini")
        XCTAssertEqual(p.title, "你好，解释 1 + 1")
        XCTAssertEqual(p.nodes.map(\.role), ["user", "assistant"])
        XCTAssertEqual(try segments(p.nodes[0]), [.text("你好，解释 1 + 1")])
        XCTAssertEqual(try segments(p.nodes[1]), [.text("答案是 **2**。\n\n补充")])
        XCTAssertEqual(p.nodes[1].parentId, p.nodes[0].id)
        XCTAssertEqual(p.nodes[0].childrenIds, [p.nodes[1].id])
        XCTAssertEqual(p.currentNodeId, p.nodes[1].id)
        let t = try XCTUnwrap(p.nodes[0].createTime).timeIntervalSince1970
        XCTAssertEqual(t, 1_767_323_045.123456, accuracy: 0.000_01)
        XCTAssertNotNil(p.nodes[1].sourceMetadata, "原始记录留在回答节点上")
        XCTAssertNil(p.nodes[0].sourceMetadata)
        XCTAssertEqual(r.inferredConversationCount, 1)
        XCTAssertEqual(r.notes.count, 1)
    }

    func testSubtitlesPromptShape() throws {
        let r = try parse([record("Used Gemini Apps", time: "2026-01-02T03:04:05Z", html: ["<p>好</p>"], subtitles: ["写一首诗", " "])])
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(try segments(p.nodes[0]), [.text("写一首诗")])
        XCTAssertEqual(r.unconfirmedPromptCount, 0)
    }

    func testUnconfirmedPromptImportsResponseOnlyOrSkips() throws {
        let r = try parse([
            record("Created Gemini Canvas titled 计划", time: "2026-01-02T03:00:00Z", html: ["<p>画布正文</p>"]),
            record("Used an Assistant feature", time: "2026-01-03T03:00:00Z"),
        ])
        XCTAssertEqual(r.unconfirmedPromptCount, 2)
        XCTAssertEqual(r.payloads.count, 1)
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(p.nodes.map(\.role), ["assistant"])
        XCTAssertEqual(p.title, "Gemini 对话 · 2026-01-02")
    }

    func testMissingResponseCounted() throws {
        let r = try parse([record("Prompted 在吗", time: "2026-01-02T03:04:05Z")])
        XCTAssertEqual(r.missingResponseCount, 1)
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(p.nodes.map(\.role), ["user"])
        XCTAssertNotNil(p.nodes[0].sourceMetadata, "没回答时原始记录留在提问节点")
    }

    func testOtherProductsSkipped() throws {
        let r = try parse([
            record("Searched for 天气", time: "2026-01-02T03:04:05Z", header: "Search"),
            record("Prompted 天气怎样", time: "2026-01-02T03:04:06Z", html: ["<p>晴</p>"]),
        ])
        XCTAssertEqual(r.otherProductCount, 1)
        XCTAssertEqual(r.activityCount, 1)
        XCTAssertEqual(r.payloads.count, 1)
    }

    func testAttachmentPlaceholders() throws {
        let r = try parse([record("Prompted 看看这个", time: "2026-01-02T03:04:05Z", html: ["<p>看了</p>"],
                                  extra: ["imageFile": "photo.jpg", "attachedFiles": ["notes.txt", ["name": "a.pdf"]]])])
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(try segments(p.nodes[0]), [.text("看看这个"), .file(name: "photo.jpg", uuid: ""),
                                                  .file(name: "notes.txt", uuid: ""), .file(name: "a.pdf", uuid: "")])
        XCTAssertEqual(r.attachmentPlaceholderCount, 3)
    }

    // MARK: - 分组

    func testNewestFirstInputIsSortedAndGroupedByChatURL() throws {
        let url = "https://gemini.google.com/app/abc123"
        let r = try parse([
            record("Prompted 第三", time: "2026-01-05T10:00:00Z", html: ["<p>3</p>"], url: url),
            record("Prompted 中间插的别的", time: "2026-01-02T10:00:00Z", html: ["<p>x</p>"]),
            record("Prompted 第二", time: "2026-01-01T10:05:00Z", html: ["<p>2</p>"], url: url),
            record("Prompted 第一", time: "2026-01-01T10:00:00Z", html: ["<p>1</p>"], url: url),
        ])
        XCTAssertEqual(r.explicitConversationCount, 1)
        XCTAssertEqual(r.inferredConversationCount, 1)
        let p = try XCTUnwrap(r.payloads.first { $0.id == "abc123@gemini" })
        XCTAssertEqual(try p.nodes.filter { $0.role == "user" }.map { try segments($0) }, [[.text("第一")], [.text("第二")], [.text("第三")]])
        XCTAssertEqual(p.title, "第一")
        XCTAssertEqual(p.createTime, GeminiImportSupport.parseISO("2026-01-01T10:00:00Z"))
        XCTAssertEqual(p.updateTime, GeminiImportSupport.parseISO("2026-01-05T10:00:00Z"))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(p.sourceMetadata)) as? [String: Any])
        XCTAssertEqual(meta["groupingBasis"] as? String, "explicitURL")
        XCTAssertEqual(meta["chatURL"] as? String, url)
    }

    func testChatURLValidation() {
        XCTAssertEqual(GeminiTakeoutParser.chatId(fromURL: "https://gemini.google.com/app/abc123"), "abc123")
        XCTAssertEqual(GeminiTakeoutParser.chatId(fromURL: "https://gemini.google.com/app/abc123/"), "abc123")
        XCTAssertNil(GeminiTakeoutParser.chatId(fromURL: "https://gemini.google.com/app/activitycontrols"))
        XCTAssertNil(GeminiTakeoutParser.chatId(fromURL: "https://gemini.google.com/app/a/b"))
        XCTAssertNil(GeminiTakeoutParser.chatId(fromURL: "http://gemini.google.com/app/abc"))
        XCTAssertNil(GeminiTakeoutParser.chatId(fromURL: "https://evil.example/app/abc"))
        XCTAssertNil(GeminiTakeoutParser.chatId(fromURL: "https://gemini.google.com/gems/abc"))
    }

    func testTitleUrlAlsoGroups() throws {
        let r = try parse([record("Prompted a", time: "2026-01-01T10:00:00Z", html: ["<p>1</p>"],
                                  extra: ["titleUrl": "https://gemini.google.com/app/zzz"])])
        XCTAssertEqual(r.payloads.first?.id, "zzz@gemini")
    }

    func testTimeGapSplitting() throws {
        let r = try parse([
            record("Prompted 一", time: "2026-01-01T10:00:00Z", html: ["<p>1</p>"]),
            record("Prompted 二", time: "2026-01-01T10:30:00Z", html: ["<p>2</p>"]),
            record("Prompted 三", time: "2026-01-01T11:00:01Z", html: ["<p>3</p>"]),
            record("Prompted 四", time: "2026-01-01T23:50:00Z", html: ["<p>4</p>"]),
            record("Prompted 五", time: "2026-01-02T00:05:00Z", html: ["<p>5</p>"]),
        ])
        XCTAssertEqual(r.inferredConversationCount, 4, "30 分钟内同一段；超过 30 分钟或跨天切开")
        XCTAssertEqual(r.payloads.map(\.title), ["一", "三", "四", "五"])
        XCTAssertEqual(r.payloads[0].nodes.count, 4)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.payloads[0].sourceMetadata)) as? [String: Any])
        XCTAssertEqual(meta["groupingBasis"] as? String, "timeGap")
    }

    func testMissingAndBadTimeKeepsOrderAndCounts() throws {
        let r = try parse([
            record("Prompted 后", time: nil, html: ["<p>b</p>"]),
            record("Prompted 前", time: "2026-01-01T10:00:00Z", html: ["<p>a</p>"]),
            record("Prompted 坏", time: "yesterday", html: ["<p>c</p>"]),
        ])
        XCTAssertEqual(r.unreadableTimeCount, 2)
        // 倒过来当底序：坏(无时间,排最前) → 前 → 后(无时间,沿用「前」的时间)；开头那条没时间的自成一段
        XCTAssertEqual(r.payloads.count, 2)
        XCTAssertEqual(try r.payloads.map { try $0.nodes.filter { $0.role == "user" }.map { try segments($0) } },
                       [[[.text("坏")]], [[.text("前")], [.text("后")]]])
        XCTAssertEqual(r.payloads[1].nodes.last?.createTime, nil)
    }

    // MARK: - ID

    func testIdsAreDeterministicAndPrefixedByConversation() throws {
        let records = [
            record("Prompted 同样", time: "2026-01-01T10:00:00Z", html: ["<p>同</p>"]),
            record("Prompted 同样", time: "2026-01-01T10:00:00Z", html: ["<p>同</p>"]),
        ]
        let a = try parse(records), b = try parse(records)
        XCTAssertEqual(a.payloads.map(\.id), b.payloads.map(\.id))
        XCTAssertEqual(a.payloads.flatMap { $0.nodes.map(\.id) }, b.payloads.flatMap { $0.nodes.map(\.id) })
        let ids = a.payloads.flatMap { $0.nodes.map(\.id) }
        XCTAssertEqual(Set(ids).count, 4, "完全相同的两条活动也不撞 id")
        for p in a.payloads {
            XCTAssertTrue(p.id.hasSuffix("@gemini-t"))
            XCTAssertTrue(p.nodes.allSatisfy { $0.id.hasPrefix(p.id + "/") })
        }
    }

    func testNewerExportKeepsConversationId() throws {
        let old = try parse([record("Prompted 一", time: "2026-01-01T10:00:00Z", html: ["<p>1</p>"])])
        let newer = try parse([
            record("Prompted 二", time: "2026-01-01T10:10:00Z", html: ["<p>2</p>"]),
            record("Prompted 一", time: "2026-01-01T10:00:00Z", html: ["<p>1</p>"]),
        ])
        XCTAssertEqual(old.payloads.map(\.id), newer.payloads.map(\.id))
        XCTAssertTrue(Set(old.payloads[0].nodes.map(\.id)).isSubset(of: Set(newer.payloads[0].nodes.map(\.id))))
    }

    // MARK: - HTML 入口

    private func htmlCell(_ header: String, _ content: String) -> String {
        """
        <div class="outer-cell mdl-cell mdl-cell--12-col mdl-shadow--2dp"><div class="mdl-grid">
        <div class="header-cell mdl-cell mdl-cell--12-col"><p class="mdl-typography--title">\(header)<br></p></div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">\(content)</div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1 mdl-typography--text-right"></div>
        <div class="content-cell mdl-cell mdl-cell--12-col mdl-typography--caption"><b>Products:</b><br>&emsp;\(header)<br></div>
        </div></div>
        """
    }

    private func htmlDoc(_ cells: [String]) -> Data {
        Data(("<html><head><style>.x{}</style></head><body><div class=\"mdl-grid\">" + cells.joined() + "</div></body></html>").utf8)
    }

    func testHTMLEntry() throws {
        let data = htmlDoc([
            htmlCell("Gemini Apps", "Prompted&nbsp;第二句<br>Jan 2, 2026, 3:10:00 AM UTC<br><p>回答 <b>二</b></p>"),
            htmlCell("Search", "Searched for x<br>Jan 2, 2026, 3:05:00 AM UTC<br>"),
            htmlCell("Gemini Apps", #"Prompted&nbsp;<a href="https://gemini.google.com/app/h1">第一句</a><br>Jan 2, 2026, 3:00:00\#u{202F}AM UTC<br><p>回答一</p><ul><li>点</li></ul>"#),
        ])
        XCTAssertTrue(GeminiTakeoutParser.isTakeoutHTML(data))
        let r = try GeminiTakeoutParser.parseHTML(data: data, calendar: utc)
        XCTAssertEqual(r.otherProductCount, 1)
        XCTAssertEqual(r.activityCount, 2)
        XCTAssertEqual(r.unreadableTimeCount, 0)
        let linked = try XCTUnwrap(r.payloads.first { $0.id == "h1@gemini" })
        XCTAssertEqual(try segments(linked.nodes[0]), [.text("第一句")])
        XCTAssertEqual(try segments(linked.nodes[1]), [.text("回答一\n\n- 点")])
        XCTAssertEqual(linked.nodes[0].createTime, GeminiImportSupport.parseISO("2026-01-02T03:00:00Z"))
        let other = try XCTUnwrap(r.payloads.first { $0.id != "h1@gemini" })
        XCTAssertEqual(try segments(other.nodes[1]), [.text("回答 **二**")])
    }

    func testHTMLUnreadableTimeFallsBackToBreak() throws {
        let data = htmlDoc([htmlCell("Gemini Apps", "Prompted&nbsp;问<br>某个看不懂的日期<br><p>答</p>")])
        let r = try GeminiTakeoutParser.parseHTML(data: data, calendar: utc)
        XCTAssertEqual(r.unreadableTimeCount, 1)
        let p = try XCTUnwrap(r.payloads.first)
        XCTAssertEqual(try segments(p.nodes[0]), [.text("问")])
        XCTAssertEqual(p.nodes.count, 2)
    }

    func testHTMLTimeFormats() {
        XCTAssertNotNil(GeminiTakeoutParser.parseHTMLTime("Jan 2, 2026, 3:04:05 PM PST"))
        XCTAssertNotNil(GeminiTakeoutParser.parseHTMLTime("Jan 2, 2026, 3:04:05\u{202F}PM UTC"))
        XCTAssertNotNil(GeminiTakeoutParser.parseHTMLTime("2026年1月2日 15:04:05 GMT+08:00"))
        XCTAssertTrue(GeminiTakeoutParser.looksLikeHTMLTime("2026年1月2日 15:04:05 CST"))
        XCTAssertFalse(GeminiTakeoutParser.looksLikeHTMLTime("Prompted hi"))
    }

    func testNonActivityHTMLRejected() {
        XCTAssertThrowsError(try GeminiTakeoutParser.parseHTML(data: Data("<html><body><p>hi</p></body></html>".utf8)))
    }
}
